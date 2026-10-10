import AppKit
import SwiftUI
import Darwin
import Network
import ServiceManagement
import SystemConfiguration

/// Reads 64-bit byte counters for every interface. `getifaddrs` only offers 32-bit counters, which wrap every 4 GB.
func readCounters() throws -> [InterfaceCounters] {
    var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
    var length = 0
    guard sysctl(&mib, 6, nil, &length, nil, 0) == 0 else { throw Failure("Cannot list network interfaces (\(errno))") }
    // The list can grow between the two calls, so leave room.
    length += length / 4
    var buffer = [UInt8](repeating: 0, count: length)
    guard sysctl(&mib, 6, &buffer, &length, nil, 0) == 0 else { throw Failure("Cannot read network counters (\(errno))") }
    return buffer.withUnsafeBytes { raw in
        var result: [InterfaceCounters] = []
        var offset = 0
        while offset + MemoryLayout<if_msghdr>.size <= length {
            let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
            guard header.ifm_msglen > 0 else { break }
            if Int32(header.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= length {
                let message = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                if if_indextoname(UInt32(message.ifm_index), &name) != nil {
                    let running = IFF_UP | IFF_RUNNING
                    result.append(InterfaceCounters(name: String(cString: name), received: message.ifm_data.ifi_ibytes,
                                                    sent: message.ifm_data.ifi_obytes,
                                                    isActive: message.ifm_flags & running == running))
                }
            }
            offset += Int(header.ifm_msglen)
        }
        return result
    }
}

/// User-facing names such as "Wi-Fi" or "Thunderbolt Ethernet", keyed by BSD name.
func interfaceDisplayNames() -> [String: String] {
    var names: [String: String] = [:]
    for interface in (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface]) ?? [] {
        if let bsd = SCNetworkInterfaceGetBSDName(interface) as String?,
           let name = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? {
            // Some names already end in the BSD name, as in "Ethernet Adapter (en6)"; the UI shows it separately.
            names[bsd] = name.hasSuffix(" (\(bsd))") ? String(name.dropLast(bsd.count + 3)) : name
        }
    }
    return names
}

/// Seconds on a clock that keeps counting during sleep and ignores wall-clock changes.
func monotonicSeconds() -> TimeInterval { Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1e9 }

/// Times a tiny HTTPS request to the chosen server. It takes the same route as other traffic, through any VPN or proxy,
/// so it measures the delay websites actually see, like Happ's "real delay". Nothing is sent while it is stopped or offline.
final class Pinger {
    static let intervalChoices: [TimeInterval] = [1, 2, 5, 10, 30, 60]
    /// Real replies are well under 1 KB. A longer one is cut off and counts as no reply.
    static let replyLimit = 64 * 1024
    var onChange: ((PingReading) -> Void)?
    private(set) var reading = PingReading() { didSet { if reading != oldValue { onChange?(reading) } } }
    private(set) var server: PingServer
    private(set) var service: LocationService
    /// Seconds between pings. A new interval starts a new graph, since its spacing depends on the interval.
    var interval: TimeInterval {
        didSet {
            guard interval != oldValue else { return }
            reading.history = PingHistory()
            if timer != nil { startTimer() }
        }
    }
    private var places = LocationState()
    /// Not reset with `places`, so clearing the location never lets lookups crowd together.
    private var pacer = LookupPacer()
    private var session: URLSession?
    private var timer: Timer?
    private var monitor: NWPathMonitor?
    /// When the ping now in flight was sent, if one is.
    private var sentAt: TimeInterval?
    /// Bumped whenever the session is replaced, so replies to cancelled requests are ignored.
    private var generation = 0
    init(server: PingServer = .cloudflare, service: LocationService = .cloudflare, interval: TimeInterval = 5) {
        self.server = server; self.service = service; self.interval = interval
    }

    /// Collects one successful reply of at most `replyLimit` bytes, and its request-to-first-byte time: one network
    /// round trip, without DNS, TCP, and TLS setup. Hands back nil data for errors and non-2xx statuses.
    private final class Exchange: NSObject, URLSessionDataDelegate {
        private let completion: (Data?, TimeInterval?) -> Void
        private var data = Data()
        private var roundTrip: TimeInterval?
        private init(_ completion: @escaping (Data?, TimeInterval?) -> Void) { self.completion = completion }
        static func send(_ request: URLRequest, on session: URLSession, completion: @escaping (Data?, TimeInterval?) -> Void) {
            let task = session.dataTask(with: request)
            task.delegate = Exchange(completion)
            task.resume()
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard self.data.count + data.count <= Pinger.replyLimit else { dataTask.cancel(); return }
            self.data.append(data)
        }
        /// Redirects are not followed, so requests only ever go to the host chosen in Settings. A redirect counts as no reply.
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
            guard let last = metrics.transactionMetrics.last, let start = last.requestStartDate,
                  let end = last.responseStartDate else { return }
            roundTrip = end.timeIntervalSince(start)
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
            completion(error == nil && (200..<300).contains(status) ? data : nil, roundTrip)
        }
    }

    func start() {
        guard timer == nil else { return }
        startTimer()
        // Reports the current path at once, which sends the first ping, then again on every change, such as a VPN connecting.
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in self?.networkChanged(online: path.status != .unsatisfied) }
        monitor.start(queue: .main)
        self.monitor = monitor
    }
    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = interval / 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
    func stop() {
        timer?.invalidate(); timer = nil
        monitor?.cancel(); monitor = nil
        resetSession(); session = nil
        places = LocationState()
        reading = PingReading()
    }
    /// Keeps the ping graph, but forgets the location and pings again at once.
    func use(_ server: PingServer, _ service: LocationService) {
        guard server != self.server || service != self.service else { return }
        self.server = server; self.service = service
        places = LocationState()
        reading.location = nil
        if timer != nil { networkChanged(online: !reading.offline) }
    }
    /// The route may have changed, as when a VPN connects, so nothing measured on the old one is shown. Old connections
    /// may still use it, so start fresh. Without a connection, nothing is sent.
    private func networkChanged(online: Bool) {
        resetSession()
        places = LocationState()
        var next = reading
        next.latency = nil; next.failed = false; next.location = nil; next.offline = !online
        reading = next
        session = online ? Self.makeSession() : nil
        ping()
    }
    private func resetSession() {
        session?.invalidateAndCancel()
        generation += 1; sentAt = nil
    }
    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        // Generous, because through some VPNs the first TLS handshake alone takes several seconds. Later pings reuse the connection.
        configuration.timeoutIntervalForRequest = 15
        // The request timeout only covers silence; without this, a server sending a byte now and then could hold a ping
        // open for the default 7 days, and no new ping would go out.
        configuration.timeoutIntervalForResource = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration, delegate: nil, delegateQueue: .main)
    }
    private func tick() {
        // Offline time shows in the graph as lost pings, without sending anything.
        if reading.offline { return reading.history.record(PingSample(time: monotonicSeconds(), latency: nil)) }
        // A ping still unanswered after a whole interval means the last reading no longer holds.
        if let sentAt, monotonicSeconds() - sentAt >= interval { reading.latency = nil; reading.failed = true }
        ping()
    }
    // Requests are created at once, on the main queue, where the session is replaced. A request created later could find
    // its session already invalidated, which raises an exception.
    private func ping() {
        guard let session, sentAt == nil else { return }
        let generation = generation, server = server, started = monotonicSeconds()
        sentAt = started
        Exchange.send(URLRequest(url: server.url), on: session) { [weak self] data, roundTrip in
            guard let self, generation == self.generation else { return }
            self.sentAt = nil
            var next = self.reading
            guard let data else {
                // The exit may change before the next reply, as when a VPN reconnects, so the location is found afresh.
                self.places = LocationState()
                next.latency = nil; next.failed = true; next.location = nil
                next.history.record(PingSample(time: monotonicSeconds(), latency: nil))
                self.reading = next
                return
            }
            // Metrics use the wall clock, which can jump mid-request; the monotonic time since sending bounds them.
            let elapsed = monotonicSeconds() - started
            next.latency = roundTrip.flatMap { (0...elapsed).contains($0) ? $0 : nil } ?? elapsed; next.failed = false
            next.history.record(PingSample(time: monotonicSeconds(), latency: next.latency))
            if self.service != .off {
                if server.reportsAddress, let found = Cloudflare.trace(String(decoding: data, as: UTF8.self)) { self.places.trace(found) }
                next.location = self.places.location
            }
            self.reading = next
            let now = monotonicSeconds()
            if self.service != .off, self.places.needsLookup(at: now, interval: LocationService.interval), self.pacer.allows(at: now) {
                self.lookUp(session, generation: generation)
            }
        }
    }
    /// Adds the city and network operator. Best effort: with Cloudflare pings, the trace alone gives the country.
    private func lookUp(_ session: URLSession, generation: Int) {
        let service = service, now = monotonicSeconds()
        let traced = places.lookingUp(at: now)
        pacer.record(at: now)
        func attempt(_ requests: ArraySlice<URLRequest>) {
            guard let request = requests.first else { return }
            Exchange.send(request, on: session) { [weak self] data, _ in
                // A lookup that finishes after a lost ping may describe the old exit.
                guard let self, generation == self.generation, service == self.service, !self.reading.failed else { return }
                guard let data, let found = service.location(from: data) else { return attempt(requests.dropFirst()) }
                self.places.found(found, for: traced)
                self.reading.location = self.places.location
            }
        }
        attempt(service.requests[...])
    }
}

struct ActiveInterface: Identifiable {
    let name: String
    let title: String
    let rate: Throughput
    var id: String { name }
}

final class TrafficModel: ObservableObject {
    static let historyLength = 60
    @Published private(set) var rate = Throughput()
    @Published private(set) var history: [Throughput] = []
    @Published private(set) var usage: DailyUsage
    /// Totals for past days, bounded by `retention`. The speed graph (`history`) is never saved.
    @Published private(set) var past: UsageHistory
    @Published private(set) var active: [ActiveInterface] = []
    @Published private(set) var error: String?
    @Published var loginMessage: String?
    /// Graph sample under the pointer, if any.
    @Published var hoveredSample: Int?
    @Published var hoveredPing: Int?

    @Published var style = MenuBarStyle(rawValue: UserDefaults.standard.string(forKey: "style") ?? "") ?? .uploadFirst {
        didSet { defaults.set(style.rawValue, forKey: "style"); onLayoutChange?() }
    }
    @Published var unit = SpeedUnit(rawValue: UserDefaults.standard.string(forKey: "unit") ?? "") ?? .bytes {
        didSet { defaults.set(unit.rawValue, forKey: "unit"); onLayoutChange?() }
    }
    /// Two stacked lines are the default: the narrowest layout.
    @Published var stacked = UserDefaults.standard.object(forKey: "stacked") as? Bool ?? true {
        didSet { defaults.set(stacked, forKey: "stacked"); onLayoutChange?() }
    }
    @Published var showsPerSecond = UserDefaults.standard.object(forKey: "showsPerSecond") as? Bool ?? true {
        didSet { defaults.set(showsPerSecond, forKey: "showsPerSecond"); onLayoutChange?() }
    }
    @Published var showsUsage = UserDefaults.standard.bool(forKey: "showsUsage") {
        didSet { defaults.set(showsUsage, forKey: "showsUsage"); onLayoutChange?() }
    }
    /// Off by default: with it off, Jarian makes no network requests of its own.
    @Published var measuresPing = UserDefaults.standard.bool(forKey: "measuresPing") {
        didSet { defaults.set(measuresPing, forKey: "measuresPing"); updatePinger(); onLayoutChange?() }
    }
    @Published var showsPing = UserDefaults.standard.object(forKey: "showsPing") as? Bool ?? true {
        didSet { defaults.set(showsPing, forKey: "showsPing"); onLayoutChange?() }
    }
    /// Like Baadgir's heat colours: a slow ping turns yellow, a bad one red.
    @Published var colorsPing = UserDefaults.standard.object(forKey: "colorsPing") as? Bool ?? true {
        didSet { defaults.set(colorsPing, forKey: "colorsPing"); onLayoutChange?() }
    }
    @Published var pingServer = PingServer(rawValue: UserDefaults.standard.string(forKey: "pingServer") ?? "") ?? .cloudflare {
        didSet { defaults.set(pingServer.rawValue, forKey: "pingServer"); pinger.use(pingServer, locationService) }
    }
    @Published var locationService = LocationService(rawValue: UserDefaults.standard.string(forKey: "locationService") ?? "") ?? .cloudflare {
        didSet { defaults.set(locationService.rawValue, forKey: "locationService"); pinger.use(pingServer, locationService) }
    }
    @Published var pingInterval = Pinger.intervalChoices.first { $0 == UserDefaults.standard.double(forKey: "pingInterval") } ?? 5 {
        didSet { defaults.set(pingInterval, forKey: "pingInterval"); pinger.interval = pingInterval }
    }
    @Published private(set) var ping = PingReading()
    /// BSD name of the interface whose speed is shown, or "" for all physical interfaces.
    @Published var interface = UserDefaults.standard.string(forKey: "interface") ?? "" {
        didSet { defaults.set(interface, forKey: "interface"); history.removeAll() }
    }
    @Published var interval = [1.0, 2, 5].first { $0 == UserDefaults.standard.double(forKey: "interval") } ?? 1 {
        didSet { defaults.set(interval, forKey: "interval"); history.removeAll(); onIntervalChange?() }
    }
    /// Days of totals to keep, counting today.
    @Published var retention = UsageHistory.retentionChoices.first { $0 == UserDefaults.standard.integer(forKey: "historyDays") } ?? 30 {
        didSet {
            defaults.set(retention, forKey: "historyDays")
            past.retention = retention; past.trim(today: usage.day); saveUsage()
        }
    }
    var onUpdate: (() -> Void)?
    var onLayoutChange: (() -> Void)?
    var onIntervalChange: (() -> Void)?

    private let defaults = UserDefaults.standard
    private var sampler = TrafficSampler()
    private var names = interfaceDisplayNames()
    private var namesReadAt = monotonicSeconds()
    /// Usage is saved once a minute while running, and also on sleep, at quit, and at midnight.
    private var savedAt = monotonicSeconds()
    private lazy var pinger = Pinger(server: pingServer, service: locationService, interval: pingInterval)

    init() {
        let today = DailyUsage.key(for: Date())
        // A corrupt or out-of-range value reads as 0; converting it with UInt64(_:) would crash at every launch.
        func count(_ key: String) -> UInt64 { UInt64(exactly: UserDefaults.standard.double(forKey: key).rounded(.down)) ?? 0 }
        let stored = DailyUsage(day: defaults.string(forKey: "usageDay") ?? today,
                                received: count("usageReceived"), sent: count("usageSent"))
        usage = stored.day == today ? stored : DailyUsage(day: today)
        let saved = UserDefaults.standard
        past = UsageHistory(retention: UsageHistory.retentionChoices.first { $0 == saved.integer(forKey: "historyDays") } ?? 30,
                            days: UsageHistory.decode(saved.stringArray(forKey: "usageHistory") ?? []), today: today)
        if stored.day != today { past.record(stored, today: today) }
        saveUsage()  // Writes back any days that aged out while Jarian was not running.
        pinger.onChange = { [weak self] reading in self?.ping = reading; self?.onUpdate?() }
        updatePinger()
    }
    private func updatePinger() { if measuresPing { pinger.start() } else { pinger.stop() } }
    /// Yesterday and the longer spans the retention covers, with their totals.
    var recentTotals: [(title: String, total: UInt64)] {
        var rows: [(String, UInt64)] = []
        if past.retention > 1, let yesterday = DailyUsage.key(usage.day, adding: -1) {
            rows.append(("Yesterday", past.usage(on: yesterday)?.total ?? 0))
        }
        for days in UsageHistory.retentionChoices.dropFirst() where days <= past.retention {
            rows.append(("Last \(days) days", past.total(lastDays: days, today: usage)))
        }
        return rows
    }
    var menuBarItems: [MenuBarItem] {
        MenuBar.items(rate: rate, usage: showsUsage ? usage.total : nil, style: style, unit: unit, perSecond: showsPerSecond)
    }
    /// Flag and country code over the ping, when shown in the menu bar.
    var menuBarPing: [[String]] { measuresPing && showsPing ? MenuBar.pingColumns(ping, stacked: stacked) : [] }
    /// Colour for the ping's quality, or nil when colours are off or no ping has finished.
    var pingLevel: PingReading.Quality? { colorsPing ? ping.quality : nil }
    /// "Ping 42 ms · Tbilisi, Georgia", or nil while ping is off.
    var pingSummary: String? {
        guard measuresPing else { return nil }
        return (["Ping \(ping.text)"] + [ping.location?.place()].compactMap { $0 }).joined(separator: " · ")
    }
    var interfaceTitle: String {
        interface.isEmpty ? "All interfaces" : "\(title(for: interface)) (\(interface))"
    }
    func title(for name: String) -> String { names[name] ?? name }
    /// Physical interfaces that are up, plus the chosen one even while it is down.
    var interfaceChoices: [String] {
        let names = active.map(\.name)
        return interface.isEmpty || names.contains(interface) ? names : names + [interface]
    }
    func speed(_ value: Double) -> String { Format.speed(value, unit: unit) }

    func refresh() {
        let counters: [InterfaceCounters]
        do { counters = try readCounters(); error = nil } catch {
            self.error = "\(error)"; rate = Throughput(); onUpdate?(); return
        }
        let now = monotonicSeconds()
        let sample = sampler.sample(counters, at: now)
        if let finished = usage.add(sample.transfer(where: Interfaces.isPhysical), today: DailyUsage.key(for: Date())) {
            past.record(finished, today: usage.day); saveUsage()
        }
        let selected = interface
        rate = sample.throughput(where: selected.isEmpty ? Interfaces.isPhysical : { $0 == selected })
        if sample.elapsed != nil {
            history.append(rate)
            if history.count > Self.historyLength { history.removeFirst(history.count - Self.historyLength) }
        }
        let shown = counters.filter { $0.isActive && Interfaces.isPhysical($0.name) && ($0.received > 0 || $0.sent > 0) }
        // An interface macOS has no name for would otherwise trigger a lookup every second.
        if shown.contains(where: { names[$0.name] == nil }), now - namesReadAt >= 30 { names = interfaceDisplayNames(); namesReadAt = now }
        active = shown.map { ActiveInterface(name: $0.name, title: title(for: $0.name),
                                             rate: sample.throughput(where: { [name = $0.name] in $0 == name })) }
        if now - savedAt >= 60 { saveUsage() }
        onUpdate?()
    }
    func resetUsage() {
        usage = DailyUsage(day: DailyUsage.key(for: Date()))
        saveUsage(); onUpdate?()
    }
    func clearHistory() {
        past.clear()
        saveUsage(); onUpdate?()
    }
    func saveUsage() {
        savedAt = monotonicSeconds()
        defaults.set(usage.day, forKey: "usageDay")
        defaults.set(Double(usage.received), forKey: "usageReceived")
        defaults.set(Double(usage.sent), forKey: "usageSent")
        defaults.set(past.encoded, forKey: "usageHistory")
    }

    var opensAtLogin: Bool { SMAppService.mainApp.status == .enabled }
    func setOpensAtLogin(_ enabled: Bool) {
        loginMessage = nil
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch { loginMessage = error.localizedDescription }
        if SMAppService.mainApp.status == .requiresApproval {
            loginMessage = "Allow Jarian in System Settings → General → Login Items."
            SMAppService.openSystemSettingsLoginItems()
        }
        objectWillChange.send()
    }
}

extension NSColor {
    private static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        func color(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
                    blue: CGFloat(hex & 0xff) / 255, alpha: 1)
        }
        return NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? color(dark) : color(light) }
    }
    static let download = dynamic(light: 0x2a78d6, dark: 0x3987e5)
    static let upload = dynamic(light: 0xeb6834, dark: 0xd95926)
    /// A good ping keeps the menu bar's own text colour; only a slow or failing one stands out.
    static func ping(_ quality: PingReading.Quality) -> NSColor? {
        switch quality {
        case .good: return nil
        case .fair: return .systemYellow
        case .poor: return .systemRed
        }
    }
}
extension Color {
    init(_ quality: PingReading.Quality) {
        switch quality {
        case .good: self = .green
        case .fair: self = .yellow
        case .poor: self = .red
        }
    }
}

/// Maps values and ages to points in a graph's plot area. The newest value sits at the right edge.
struct GraphGeometry {
    let plot: CGRect
    let top: Double
    /// Seconds the plot spans, from its left edge to now.
    let span: TimeInterval
    func x(age: TimeInterval) -> CGFloat { plot.maxX - CGFloat(age / span) * plot.width }
    func y(_ value: Double) -> CGFloat { plot.maxY - CGFloat(min(max(value / top, 0), 1)) * plot.height }
    /// Index of the sample nearest `x`, for samples `interval` seconds apart with the last one now.
    func index(at x: CGFloat, count: Int, interval: TimeInterval) -> Int? {
        guard count > 0 else { return nil }
        let age = Double((plot.maxX - x) / plot.width) * span
        return min(max(count - 1 - Int((age / interval).rounded()), 0), count - 1)
    }
    func age(_ index: Int, count: Int, interval: TimeInterval) -> TimeInterval { Double(count - 1 - index) * interval }
}

/// Grid lines with value labels on the right and time labels below, around a plot drawn by `content`.
struct GraphFrame<Content: View>: View {
    let scale: GraphScale
    let span: TimeInterval
    let label: (Double) -> String
    @ViewBuilder let content: (GraphGeometry) -> Content
    /// Shared by every graph so their plot areas line up.
    static var gutter: CGFloat { 54 }
    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            // Room above for the top label, and below for the time labels.
            let layout = GraphGeometry(plot: CGRect(x: 0, y: 6, width: max(size.width - Self.gutter, 1), height: max(size.height - 22, 1)),
                                       top: scale.top, span: span)
            let plot = layout.plot
            let times = TimeTick.ticks(span: span)
            ZStack(alignment: .topLeading) {
                Path { path in
                    for tick in scale.ticks.dropFirst() {
                        path.move(to: CGPoint(x: plot.minX, y: layout.y(tick))); path.addLine(to: CGPoint(x: plot.maxX, y: layout.y(tick)))
                    }
                    for tick in times.dropFirst() where tick.age < span {
                        let x = layout.x(age: tick.age)
                        path.move(to: CGPoint(x: x, y: plot.minY)); path.addLine(to: CGPoint(x: x, y: plot.maxY))
                    }
                }
                .stroke(Color.secondary.opacity(0.18), style: StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
                Path { $0.move(to: CGPoint(x: plot.minX, y: plot.maxY)); $0.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY)) }
                    .stroke(Color.secondary.opacity(0.4), lineWidth: 1)
                content(layout)
                ForEach(scale.ticks, id: \.self) { tick in
                    axisText(label(tick)).frame(width: Self.gutter - 6, alignment: .leading)
                        .position(x: plot.maxX + Self.gutter / 2 + 3, y: layout.y(tick))
                }
                ForEach(times, id: \.age) { tick in
                    // The oldest label lines up with the plot's left edge instead of hanging past it.
                    let x = layout.x(age: tick.age)
                    axisText(tick.label).frame(width: 48, alignment: x - 24 < plot.minX ? .leading : .center)
                        .position(x: max(x, plot.minX + 24), y: plot.maxY + 9)
                }
            }
        }
    }
    private func axisText(_ text: String) -> some View {
        Text(text).font(.system(size: 9.5)).monospacedDigit().foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
    }
}

/// Vertical hover line across the plot, at the sample under the pointer.
private func hoverLine(_ x: CGFloat, in plot: CGRect) -> some View {
    Path { $0.move(to: CGPoint(x: x, y: plot.minY)); $0.addLine(to: CGPoint(x: x, y: plot.maxY)) }
        .stroke(Color.secondary.opacity(0.6), lineWidth: 1)
}
private func hoverMarker(_ center: CGPoint, _ color: Color) -> some View {
    Circle().fill(color)
        .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
        .frame(width: 8, height: 8).position(center)
}

/// The last minute of download and upload speed on one shared axis.
struct SpeedGraph: View {
    let history: [Throughput]
    let capacity: Int
    let interval: TimeInterval
    let unit: SpeedUnit
    @Binding var hovered: Int?
    var body: some View {
        // Scaled in the chosen unit so the ticks are round in it. Never below 10 KB/s so idle noise stays flat.
        let factor: Double = unit == .bits ? 8 : 1
        let peak = history.map { max($0.received, $0.sent) }.max() ?? 0
        GraphFrame(scale: GraphScale(peak: peak * factor, minimum: 10_000 * factor),
                   span: Double(capacity) * interval, label: { Format.speedTick($0 / factor, unit: unit) }) { layout in
            graph(layout, factor: factor)
        }
        .accessibilityElement()
        .accessibilityLabel("Speed graph for the last \(history.count) samples")
    }
    private func points(_ layout: GraphGeometry, _ value: KeyPath<Throughput, Double>, _ factor: Double) -> [CGPoint] {
        history.enumerated().map { index, sample in
            CGPoint(x: layout.x(age: layout.age(index, count: history.count, interval: interval)), y: layout.y(sample[keyPath: value] * factor))
        }
    }
    private func graph(_ layout: GraphGeometry, factor: Double) -> some View {
        let stroke = StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round)
        let upload = points(layout, \.sent, factor), download = points(layout, \.received, factor)
        let plot = layout.plot
        return ZStack(alignment: .topLeading) {
            area(download, plot).fill(LinearGradient(colors: [Color(nsColor: .download).opacity(0.22), Color(nsColor: .download).opacity(0.02)],
                                                     startPoint: .top, endPoint: .bottom))
            area(upload, plot).fill(LinearGradient(colors: [Color(nsColor: .upload).opacity(0.16), Color(nsColor: .upload).opacity(0.02)],
                                                   startPoint: .top, endPoint: .bottom))
            line(upload).stroke(Color(nsColor: .upload), style: stroke)
            line(download).stroke(Color(nsColor: .download), style: stroke)
            if let hovered, history.indices.contains(hovered) {
                hoverLine(download[hovered].x, in: plot)
                hoverMarker(upload[hovered], Color(nsColor: .upload))
                hoverMarker(download[hovered], Color(nsColor: .download))
            }
        }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let location): hovered = layout.index(at: location.x, count: history.count, interval: interval)
            case .ended: hovered = nil
            }
        }
    }
    private func line(_ points: [CGPoint]) -> Path { Path { $0.addLines(points) } }
    private func area(_ points: [CGPoint], _ plot: CGRect) -> Path {
        Path { path in
            guard let first = points.first, let last = points.last else { return }
            path.move(to: CGPoint(x: first.x, y: plot.maxY))
            for point in points { path.addLine(to: point) }  // `addLines` would start a new subpath.
            path.addLine(to: CGPoint(x: last.x, y: plot.maxY))
            path.closeSubpath()
        }
    }
}

/// Recent pings: the round trip as a line, and a red band wherever a ping got no reply.
struct PingGraph: View {
    let samples: [PingSample]
    let capacity: Int
    let interval: TimeInterval
    @Binding var hovered: Int?
    var body: some View {
        // Never below 100 ms, so a steady fast connection stays low and flat.
        GraphFrame(scale: GraphScale(peak: samples.compactMap(\.latency).max() ?? 0, minimum: 0.1),
                   span: Double(capacity) * interval, label: Format.pingTick) { layout in
            graph(layout)
        }
        .accessibilityElement()
        .accessibilityLabel("Ping graph for the last \(samples.count) pings, \(samples.filter { $0.latency == nil }.count) without a reply")
    }
    private func graph(_ layout: GraphGeometry) -> some View {
        let plot = layout.plot
        let step = plot.width / CGFloat(capacity)
        func x(_ index: Int) -> CGFloat { layout.x(age: layout.age(index, count: samples.count, interval: interval)) }
        let green = Color(nsColor: .systemGreen), red = Color(nsColor: .systemRed)
        return ZStack(alignment: .topLeading) {
            Path { path in
                for (index, sample) in samples.enumerated() where sample.latency == nil {
                    path.addRect(CGRect(x: x(index) - step / 2, y: plot.minY, width: max(step, 2), height: plot.height))
                }
            }
            .fill(red.opacity(0.25))
            // The line breaks at each lost ping; a reply between two losses is drawn as a dot.
            Path { path in
                var drawing = false
                for (index, sample) in samples.enumerated() {
                    guard let latency = sample.latency else { drawing = false; continue }
                    let point = CGPoint(x: x(index), y: layout.y(latency))
                    if drawing { path.addLine(to: point) } else { path.move(to: point) }
                    let next = samples.indices.contains(index + 1) ? samples[index + 1].latency : nil
                    if !drawing && next == nil { path.addEllipse(in: CGRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2)) }
                    drawing = true
                }
            }
            .stroke(green, style: StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round))
            if let hovered, samples.indices.contains(hovered) {
                hoverLine(x(hovered), in: plot)
                if let latency = samples[hovered].latency { hoverMarker(CGPoint(x: x(hovered), y: layout.y(latency)), green) }
            }
        }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let location): hovered = layout.index(at: location.x, count: samples.count, interval: interval)
            case .ended: hovered = nil
            }
        }
    }
}

struct PopoverView: View {
    @ObservedObject var model: TrafficModel
    let quit: () -> Void
    var openSettings: () -> Void = {}
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                if let icon = NSImage(named: "app-icon") {
                    Image(nsImage: icon).resizable().frame(width: 36, height: 36).accessibilityHidden(true)
                } else { Image(systemName: "arrow.up.arrow.down").font(.title2).accessibilityHidden(true) }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Jarian").font(.headline)
                    Text(model.interfaceTitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack(alignment: .top, spacing: 12) {
                reading("Download", "↓", model.rate.received, .download)
                reading("Upload", "↑", model.rate.sent, .upload)
            }
            VStack(alignment: .leading, spacing: 6) {
                SpeedGraph(history: model.history, capacity: TrafficModel.historyLength, interval: model.interval, unit: model.unit,
                           hovered: $model.hoveredSample)
                    .frame(height: 132)
                Text(graphCaption).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
            if let error = model.error {
                Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
            if model.measuresPing {
                Divider()
                pingRow
                VStack(alignment: .leading, spacing: 6) {
                    PingGraph(samples: model.ping.history.samples, capacity: PingHistory.capacity, interval: model.pingInterval,
                              hovered: $model.hoveredPing)
                        .frame(height: 96)
                    Text(pingCaption).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Today").font(.headline)
                    Spacer()
                    Text(Format.amount(model.usage.total)).monospacedDigit()
                }
                HStack {
                    Text("↓ \(Format.amount(model.usage.received))   ↑ \(Format.amount(model.usage.sent))")
                        .monospacedDigit()
                    Spacer()
                    Button("Reset", action: model.resetUsage).buttonStyle(.plain).foregroundStyle(.secondary)
                }
                .font(.caption).foregroundStyle(.secondary)
                ForEach(model.recentTotals, id: \.title) { row in
                    HStack {
                        Text(row.title)
                        Spacer()
                        Text(Format.amount(row.total)).monospacedDigit()
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !model.active.isEmpty {
                Divider()
                ForEach(model.active) { interface in
                    HStack {
                        Text(interface.title).lineLimit(1)
                        Text(interface.name).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text("↓ \(model.speed(interface.rate.received))  ↑ \(model.speed(interface.rate.sent))")
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            HStack {
                Button("Settings…", action: openSettings).buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer()
                Button("Quit Jarian", action: quit).buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
    }
    private var pingCaption: String {
        let samples = model.ping.history.samples
        if let hovered = model.hoveredPing, samples.indices.contains(hovered) {
            let sample = samples[hovered]
            return "\(Format.age(monotonicSeconds() - sample.time)) · \(sample.latency.map(Format.ping) ?? "no reply")"
        }
        return model.ping.history.summary(interval: model.pingInterval)
    }
    private var graphCaption: String {
        if let hovered = model.hoveredSample, model.history.indices.contains(hovered) {
            let sample = model.history[hovered]
            let age = Int(Double(model.history.count - 1 - hovered) * model.interval)
            return "\(age == 0 ? "Now" : "\(age) s ago") · ↓ \(model.speed(sample.received)) · ↑ \(model.speed(sample.sent))"
        }
        let peak = model.history.map(\.received).max() ?? 0
        return "Last \(Int(Double(TrafficModel.historyLength) * model.interval)) s · peak ↓ \(model.speed(peak))"
    }
    /// Exit location and ping, laid out like a server row in a VPN client.
    private var pingRow: some View {
        let location = model.ping.location
        let color = model.pingLevel.map(Color.init) ?? (model.ping.quality == nil ? .secondary : .primary)
        return HStack(spacing: 10) {
            Text(location?.flag ?? "🌐").font(.system(size: 26)).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(location?.place() ?? (model.ping.offline ? "No network connection"
                                           : model.ping.failed ? "No reply from \(model.pingServer.title)"
                                           : model.locationService == .off ? "Ping to \(model.pingServer.title)" : "Finding location…"))
                    .lineLimit(1)
                if let location {
                    Text(([location.ip] + [location.organization].compactMap { $0 }).joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(model.ping.text).font(.system(size: 17, weight: .medium, design: .rounded)).monospacedDigit().foregroundStyle(color)
                Text("Ping · \(location.flatMap { $0.colo.isEmpty ? nil : $0.colo } ?? model.pingServer.title)")
                    .font(.caption).foregroundStyle(.secondary)
                    .help(location.flatMap { $0.colo.isEmpty ? nil : "Measured to Cloudflare's \($0.colo) data center" }
                          ?? "Measured to \(model.pingServer.url.host ?? "")")
            }
        }
        .accessibilityElement(children: .combine)
    }
    private func reading(_ title: String, _ symbol: String, _ value: Double, _ color: NSColor) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 1).fill(Color(nsColor: color)).frame(width: 10, height: 3)
                Text("\(symbol) \(title)").font(.caption).foregroundStyle(.secondary)
            }
            Text(model.speed(value))
                .font(.system(size: 22, weight: .medium, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct SettingsView: View {
    @ObservedObject var model: TrafficModel
    private var pingFooter: String {
        let server = model.pingServer, service = model.locationService
        let every = model.pingInterval == 1 ? "second" : model.pingInterval == 60 ? "minute" : "\(Int(model.pingInterval)) seconds"
        var text = "Every \(every), Jarian times a small HTTPS request to \(server.url.host ?? server.title)."
        if let host = service.host {
            let when = server.reportsAddress ? "when your address changes" : "every minute and when the network changes"
            text += " Location comes from \(host), looked up \(when)."
        }
        if model.colorsPing { text += " Ping turns yellow from 150 ms, and red from 400 ms or when there is no reply." }
        return text + " Requests take the same route as your other traffic, through any VPN or proxy, so they show what websites see. When ping is off, Jarian makes no network requests."
    }
    var body: some View {
        Form {
            Section {
                Picker("Layout", selection: $model.stacked) {
                    Text("Stacked").tag(true)
                    Text("Side by side").tag(false)
                }
                .pickerStyle(.segmented)
                Picker("Show", selection: $model.style) {
                    Text("↑ Upload  ↓ Download").tag(MenuBarStyle.uploadFirst)
                    Text("↓ Download  ↑ Upload").tag(MenuBarStyle.downloadFirst)
                    Text("⇅ Combined").tag(MenuBarStyle.combined)
                }
                Toggle("Show “/s” after speeds", isOn: $model.showsPerSecond)
                Toggle("Show today's data usage", isOn: $model.showsUsage)
                Picker("Units", selection: $model.unit) {
                    Text("Bytes (MB/s)").tag(SpeedUnit.bytes)
                    Text("Bits (Mb/s)").tag(SpeedUnit.bits)
                }
            } header: {
                Text("Menu Bar")
            } footer: {
                Text("Usage appears after “=”. 1 KB = 1000 bytes, as in Finder.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Picker("Interface", selection: $model.interface) {
                    Text("All interfaces").tag("")
                    ForEach(model.interfaceChoices, id: \.self) { name in
                        Text("\(model.title(for: name)) (\(name))").tag(name)
                    }
                }
                Picker("Update every", selection: $model.interval) {
                    Text("1 second").tag(1.0)
                    Text("2 seconds").tag(2.0)
                    Text("5 seconds").tag(5.0)
                }
            } header: {
                Text("Monitoring")
            } footer: {
                Text("“All interfaces” adds up Wi-Fi, Ethernet, and other physical links. VPN, bridge, loopback, and virtual machine interfaces are skipped so no traffic is counted twice; a virtual machine's internet traffic still counts, on the physical link it uses.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Toggle("Measure ping and location", isOn: $model.measuresPing)
                Picker("Ping server", selection: $model.pingServer) {
                    ForEach(PingServer.allCases) { Text($0.title).tag($0) }
                }
                .disabled(!model.measuresPing)
                Picker("Ping every", selection: $model.pingInterval) {
                    ForEach(Pinger.intervalChoices, id: \.self) { seconds in
                        Text(seconds == 1 ? "1 second" : seconds == 60 ? "1 minute" : "\(Int(seconds)) seconds").tag(seconds)
                    }
                }
                .disabled(!model.measuresPing)
                Picker("Location from", selection: $model.locationService) {
                    ForEach(LocationService.allCases.filter { $0 != .off }) { Text($0.title).tag($0) }
                    Divider()
                    Text(LocationService.off.title).tag(LocationService.off)
                }
                .disabled(!model.measuresPing)
                Toggle("Show location and ping in menu bar", isOn: $model.showsPing).disabled(!model.measuresPing)
                Toggle("Color ping by speed", isOn: $model.colorsPing).disabled(!model.measuresPing)
            } header: {
                Text("Ping")
            } footer: {
                Text(pingFooter)
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Toggle("Open at login", isOn: Binding(get: { model.opensAtLogin }, set: { model.setOpensAtLogin($0) }))
                if let message = model.loginMessage {
                    Text(message).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Text("Today: \(Format.amount(model.usage.total))").monospacedDigit()
                    Spacer()
                    Button("Reset Today", action: model.resetUsage)
                }
            } header: {
                Text("General")
            }
            Section {
                Picker("Keep daily totals for", selection: $model.retention) {
                    Text("Today only").tag(1)
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                }
                HStack {
                    Text("\(model.past.days.count) past \(model.past.days.count == 1 ? "day" : "days") saved").foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear History", action: model.clearHistory).disabled(model.past.days.isEmpty)
                }
            } header: {
                Text("History")
            } footer: {
                Text("Saved on disk: one total per day for the days you keep, at most 90, so it never grows over time. The speed graph stays in memory. Usage counts all physical interfaces while Jarian is running. No logs are written.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Draws the menu bar readings.
struct MenuBarRenderer {
    let stacked: Bool
    let unit: SpeedUnit
    let perSecond: Bool
    init(model: TrafficModel) { stacked = model.stacked; unit = model.unit; perSecond = model.showsPerSecond }
    /// Fully monospaced, so stacked lines line up character for character.
    var font: NSFont {
        .monospacedSystemFont(ofSize: stacked ? 10 : NSFont.systemFontSize - 1, weight: stacked ? .medium : .regular)
    }
    private func width(_ text: String) -> CGFloat { ceil((text as NSString).size(withAttributes: [.font: font]).width) }
    /// Widths of the symbol and value columns, sized for the widest values so the item never shifts.
    private var columns: (symbol: CGFloat, value: CGFloat) {
        let samples = [8.88e6, 88.8e6, 888e6]
        let values = samples.map { Format.speed($0, unit: unit, perSecond: perSecond) } + samples.map { Format.amount(UInt64($0 * 1000)) }
        return (["↑", "↓", "⇅", "="].map(width).max() ?? 0, values.map(width).max() ?? 0)
    }
    /// Widths of the location and ping lines, also sized for the widest values.
    private var pingWidths: (location: CGFloat, ping: CGFloat) {
        (width("🇺🇸 WW"), ["timeout", "offline", "9999 ms"].map(width).max() ?? 0)
    }
    /// The readings, then the ping columns, if any. Without ping this is a template image, so it follows the menu bar's
    /// light, dark, and tinted styles. A flag needs its colors, so with ping the text is drawn in `textColor` instead.
    /// `pingColor` tints the ping itself, the last line of the last ping column.
    func image(_ items: [MenuBarItem], ping: [[String]] = [], textColor: NSColor = .labelColor, pingColor: NSColor? = nil) -> NSImage {
        let height = NSStatusBar.system.thickness
        let columns = columns
        let gap: CGFloat = stacked ? 6 : 3, spacing: CGFloat = 7
        let column = columns.symbol + gap + columns.value
        let groups = MenuBar.columns(items, stacked: stacked)
        let widths = pingWidths
        // Stacked, location and ping share one column; side by side, the ping comes last.
        let pingColumnWidths = stacked ? ping.map { $0.count > 1 ? max(widths.location, widths.ping) : widths.ping }
            : ping.indices.map { $0 == ping.count - 1 ? widths.ping : widths.location }
        let font = font
        let lineHeight = ceil(font.ascender - font.descender)
        let allWidths = Array(repeating: column, count: groups.count) + pingColumnWidths
        let size = NSSize(width: allWidths.reduce(0, +) + CGFloat(max(allWidths.count - 1, 0)) * spacing, height: height)
        let color = ping.isEmpty ? NSColor.black : textColor
        let image = NSImage(size: size, flipped: true) { _ in
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            // A column with one line is centred vertically.
            func top(_ lines: Int, _ line: Int) -> CGFloat { (height - CGFloat(lines) * lineHeight) / 2 + CGFloat(line) * lineHeight }
            for (index, group) in groups.enumerated() {
                for (line, entry) in group.enumerated() {
                    let x = CGFloat(index) * (column + spacing)
                    let y = top(group.count, line)
                    let symbol = NSAttributedString(string: entry.symbol, attributes: attributes)
                    symbol.draw(at: CGPoint(x: x + (columns.symbol - symbol.size().width) / 2, y: y))
                    let value = NSAttributedString(string: entry.value, attributes: attributes)
                    value.draw(at: CGPoint(x: x + column - value.size().width, y: y))  // Right-aligned so digits stay put.
                }
            }
            var x = CGFloat(groups.count) * (column + spacing)
            for (column, (lines, width)) in zip(ping, pingColumnWidths).enumerated() {
                for (line, text) in lines.enumerated() {
                    var attributes = attributes
                    if let pingColor, column == ping.count - 1, line == lines.count - 1 { attributes[.foregroundColor] = pingColor }
                    let value = NSAttributedString(string: text, attributes: attributes)
                    value.draw(at: CGPoint(x: x + width - value.size().width, y: top(lines.count, line)))
                }
                x += width + spacing
            }
            return true
        }
        image.isTemplate = ping.isEmpty
        return image
    }
}

final class MenuApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let model = TrafficModel()
    let popover = NSPopover()
    var timer: Timer?
    // Changing the status item while its menu is open can dismiss the menu, so updates wait until it closes.
    private var menuOpen = false
    /// Redraws the colored ping image when the menu bar turns light or dark.
    private var appearanceObservation: NSKeyValueObservation?
    func applicationDidFinishLaunching(_ notification: Notification) {
        item.button?.imagePosition = .imageOnly
        item.button?.setAccessibilityLabel("Jarian network speed")
        item.button?.target = self; item.button?.action = #selector(statusItemClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        popover.behavior = .transient
        let host = NSHostingController(rootView: PopoverView(model: model, quit: { [weak self] in self?.quitApp() },
                                                             openSettings: { [weak self] in self?.openSettings() }))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        model.onUpdate = { [weak self] in self?.refreshStatusItem() }
        model.onLayoutChange = { [weak self] in self?.refreshStatusItem() }
        model.onIntervalChange = { [weak self] in self?.startTimer() }
        appearanceObservation = item.button?.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { self?.refreshStatusItem() }
        }
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(save), name: NSWorkspace.willSleepNotification, object: nil)
        startTimer()
        model.refresh()
    }
    private func startTimer() {
        timer?.invalidate()
        timer = Timer(timeInterval: model.interval, repeats: true) { [weak self] _ in self?.model.refresh() }
        timer?.tolerance = model.interval / 10
        RunLoop.main.add(timer!, forMode: .common)
    }
    private func refreshStatusItem() {
        guard !menuOpen else { return }
        let items = model.menuBarItems
        // The menu bar's own appearance follows the wallpaper, so it can differ from the app's.
        var textColor = NSColor.labelColor
        item.button?.effectiveAppearance.performAsCurrentDrawingAppearance { textColor = NSColor.labelColor.usingColorSpace(.sRGB) ?? .labelColor }
        item.button?.image = MenuBarRenderer(model: model).image(items, ping: model.menuBarPing, textColor: textColor,
                                                                 pingColor: model.pingLevel.flatMap(NSColor.ping))
        let summary = "Download \(model.speed(model.rate.received)), upload \(model.speed(model.rate.sent)), today \(Format.amount(model.usage.total))"
            + (model.pingSummary.map { "\n\($0)" } ?? "")
        item.button?.setAccessibilityValue(summary)
        item.button?.toolTip = model.error ?? "Jarian · \(model.interfaceTitle)\n\(summary)"
    }
    @objc func statusItemClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true { showMenu() }
        else { togglePopover() }
    }
    func showMenu() {
        popover.performClose(nil)
        let menu = NSMenu()
        func info(_ title: String) {
            let entry = NSMenuItem(title: title, action: nil, keyEquivalent: ""); entry.isEnabled = false
            menu.addItem(entry)
        }
        info("↓ \(model.speed(model.rate.received))   ↑ \(model.speed(model.rate.sent))")
        info("Today: \(Format.amount(model.usage.total)) (↓ \(Format.amount(model.usage.received)) · ↑ \(Format.amount(model.usage.sent)))")
        if let ping = model.pingSummary { info(ping) }
        info(model.interfaceTitle)
        menu.addItem(.separator())
        let measure = NSMenuItem(title: "Measure Ping", action: #selector(togglePing), keyEquivalent: "")
        measure.target = self; measure.state = model.measuresPing ? .on : .off; menu.addItem(measure)
        let reset = NSMenuItem(title: "Reset Today's Usage", action: #selector(resetUsage), keyEquivalent: "")
        reset.target = self; menu.addItem(reset)
        menu.addItem(.separator())
        let open = NSMenuItem(title: "Open Jarian", action: #selector(togglePopover), keyEquivalent: "")
        open.target = self; menu.addItem(open)
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self; menu.addItem(settings)
        let quit = NSMenuItem(title: "Quit Jarian", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self; menu.addItem(quit)
        // Attach only while open so a left click still shows the popover.
        menu.delegate = self
        menuOpen = true
        item.menu = menu
        item.button?.performClick(nil)
    }
    func menuDidClose(_ menu: NSMenu) {
        guard menu === item.menu else { return }
        item.menu = nil
        menuOpen = false
        refreshStatusItem()
    }
    @objc func resetUsage() { model.resetUsage() }
    @objc func togglePing() { model.measuresPing.toggle() }
    @objc func togglePopover() {
        guard let button = item.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    private var settingsWindow: NSWindow?
    @objc func openSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView(model: model))
            host.sizingOptions = .preferredContentSize
            let window = NSWindow(contentViewController: host)
            window.title = "Jarian Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            // Size to the SwiftUI content first; centering the default-sized window leaves it off-center once it grows.
            window.setContentSize(host.view.fittingSize)
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
    @objc func save() { model.saveUsage() }
    @objc func quitApp() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) { model.saveUsage() }
}

// No logs: `--probe` prints the current counters to the terminal only.
if CommandLine.arguments.contains("--probe") {
    do {
        let names = interfaceDisplayNames()
        for counter in try readCounters() where counter.received > 0 || counter.sent > 0 {
            let kind = Interfaces.isPhysical(counter.name) ? "physical" : "virtual"
            print("\(counter.name) (\(names[counter.name] ?? "—"), \(kind)\(counter.isActive ? "" : ", down")): "
                  + "↓ \(Format.amount(counter.received)) ↑ \(Format.amount(counter.sent))")
        }
    } catch { fputs("\(error)\n", stderr); exit(1) }
} else if CommandLine.arguments.contains("--ping") {
    // Prints each change for 30 seconds, then exits. Unchanged readings are not repeated.
    let saved = UserDefaults.standard
    let pinger = Pinger(server: PingServer(rawValue: saved.string(forKey: "pingServer") ?? "") ?? .cloudflare,
                        service: LocationService(rawValue: saved.string(forKey: "locationService") ?? "") ?? .cloudflare,
                        interval: Pinger.intervalChoices.first { $0 == saved.double(forKey: "pingInterval") } ?? 5)
    print("Pinging \(pinger.server.url.host ?? "") every \(Int(pinger.interval)) s, location from \(pinger.service.host ?? "nowhere (off)")")
    pinger.onChange = { reading in
        let location = reading.location.map { "\($0.flag ?? "") \($0.place()) · \($0.ip) · \($0.organization ?? "—")" + ($0.colo.isEmpty ? "" : " · via \($0.colo)") }
        print("\(reading.text)\(location.map { "  \($0)" } ?? "")")
    }
    pinger.start()
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 30))
} else {
    let app = NSApplication.shared
    let delegate = MenuApp()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
