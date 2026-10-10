import Foundation

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

/// Cumulative byte counters for one network interface since it came up.
struct InterfaceCounters: Equatable {
    let name: String
    let received: UInt64
    let sent: UInt64
    var isActive = true
}

enum Interfaces {
    /// Loopback, tunnel (VPN), bridge, Apple peer-to-peer (AWDL, Wi-Fi Aware), and virtual machine (Apple Virtualization,
    /// VMware, Parallels, VirtualBox) interfaces. Their traffic is either local or also crosses a physical interface, so
    /// counting it would count the same bytes twice.
    static let virtualPrefixes = ["lo", "utun", "ipsec", "ppp", "gif", "stf", "bridge", "awdl", "llw", "anpi", "ap", "nan",
                                  "vmenet", "vmnet", "vnic", "vboxnet", "feth"]
    static func isPhysical(_ name: String) -> Bool { !virtualPrefixes.contains { name.hasPrefix($0) } }
}

/// Bytes moved in each direction.
struct Transfer: Equatable {
    var received: UInt64 = 0
    var sent: UInt64 = 0
    static func + (left: Transfer, right: Transfer) -> Transfer {
        Transfer(received: left.received &+ right.received, sent: left.sent &+ right.sent)
    }
}

/// Bytes per second in each direction.
struct Throughput: Equatable {
    var received: Double = 0
    var sent: Double = 0
    var total: Double { received + sent }
}

struct Sample {
    /// Bytes each interface moved since the previous sample. Empty on the first sample.
    let transfers: [String: Transfer]
    /// Seconds since the previous sample, or nil on the first sample.
    let elapsed: TimeInterval?
    func transfer(where include: (String) -> Bool) -> Transfer {
        transfers.filter { include($0.key) }.values.reduce(Transfer(), +)
    }
    func throughput(where include: (String) -> Bool) -> Throughput {
        guard let elapsed, elapsed > 0 else { return Throughput() }
        let transfer = transfer(where: include)
        return Throughput(received: Double(transfer.received) / elapsed, sent: Double(transfer.sent) / elapsed)
    }
}

/// Turns cumulative counters into per-sample transfers.
struct TrafficSampler {
    private var previous: [String: InterfaceCounters] = [:]
    private var previousTime: TimeInterval?
    mutating func sample(_ counters: [InterfaceCounters], at time: TimeInterval) -> Sample {
        var transfers: [String: Transfer] = [:]
        for counter in counters {
            guard let old = previous[counter.name] else { continue }  // New interface: no baseline yet.
            // A counter that went backwards was reset (interface restarted); count nothing rather than guess.
            transfers[counter.name] = Transfer(received: counter.received >= old.received ? counter.received - old.received : 0,
                                               sent: counter.sent >= old.sent ? counter.sent - old.sent : 0)
        }
        let elapsed = previousTime.map { time - $0 }
        previous = Dictionary(counters.map { ($0.name, $0) }, uniquingKeysWith: { _, last in last })
        previousTime = time
        return Sample(transfers: transfers, elapsed: elapsed.flatMap { $0 > 0 ? $0 : nil })
    }
}

/// Data moved on one calendar day.
struct DailyUsage: Equatable {
    var day: String
    var received: UInt64 = 0
    var sent: UInt64 = 0
    var total: UInt64 { received &+ sent }
    /// Starts a fresh count when `today` differs from the stored day, and returns the day that ended.
    @discardableResult
    mutating func add(_ transfer: Transfer, today: String) -> DailyUsage? {
        var finished: DailyUsage?
        if today != day { finished = self; self = DailyUsage(day: today) }
        received &+= transfer.received
        sent &+= transfer.sent
        return finished
    }
    /// Gregorian in the local time zone, so keys stay comparable whatever calendar the user's region shows.
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
        return calendar
    }
    /// "2026-10-10". Keys sort in date order as plain strings.
    static func key(for date: Date, calendar: Calendar = calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
    /// The key `days` days after (or before, if negative) `key`.
    static func key(_ key: String, adding days: Int, calendar: Calendar = calendar) -> String? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
              let shifted = calendar.date(byAdding: .day, value: days, to: date) else { return nil }
        return Self.key(for: shifted, calendar: calendar)
    }
}

/// One total per past day, newest first. Bounded by `retention`, so what is saved never grows over time.
struct UsageHistory: Equatable {
    static let retentionChoices = [1, 7, 30, 90]
    /// Days kept, counting today; 1 keeps no past days.
    var retention: Int
    private(set) var days: [DailyUsage] = []
    init(retention: Int, days: [DailyUsage] = [], today: String) {
        self.retention = max(1, retention); self.days = days
        trim(today: today)
    }
    /// Adds a day that has ended, merging repeats of the same day, then drops days outside the retention.
    mutating func record(_ day: DailyUsage, today: String) {
        if day.total > 0 {
            if let index = days.firstIndex(where: { $0.day == day.day }) {
                days[index].received &+= day.received; days[index].sent &+= day.sent
            } else { days.append(day) }
        }
        trim(today: today)
    }
    mutating func trim(today: String) {
        retention = max(1, retention)
        let oldest = DailyUsage.key(today, adding: -(retention - 1)) ?? today
        days = days.filter { $0.day >= oldest && $0.day < today }.sorted { $0.day > $1.day }
    }
    mutating func clear() { days.removeAll() }
    func usage(on day: String) -> DailyUsage? { days.first { $0.day == day } }
    /// Data moved over the last `count` days, counting `today`.
    func total(lastDays count: Int, today: DailyUsage) -> UInt64 {
        let oldest = DailyUsage.key(today.day, adding: -(count - 1)) ?? today.day
        return days.filter { $0.day >= oldest && $0.day < today.day }.reduce(today.total) { $0 &+ $1.total }
    }
    /// "2026-10-09 1200 340" per day, for saving in preferences.
    var encoded: [String] { days.map { "\($0.day) \($0.received) \($0.sent)" } }
    static func decode(_ lines: [String]) -> [DailyUsage] {
        lines.compactMap { line in
            let parts = line.split(separator: " ")
            guard parts.count == 3, let received = UInt64(parts[1]), let sent = UInt64(parts[2]),
                  DailyUsage.key(String(parts[0]), adding: 0) == String(parts[0]) else { return nil }
            return DailyUsage(day: String(parts[0]), received: received, sent: sent)
        }
    }
}

enum SpeedUnit: String, CaseIterable { case bytes, bits }
enum MenuBarStyle: String, CaseIterable { case uploadFirst, downloadFirst, combined }

enum Format {
    private static let prefixes = ["K", "M", "G", "T", "P"]
    /// Three significant digits: "0.42", "8.42", "84.2", "842". Uses 1 K = 1000, like Finder.
    private static func scaled(_ value: Double, from start: Int) -> String {
        var value = max(0, value.isFinite ? value : 0) / pow(1000, Double(start + 1))
        var index = start
        while value >= 999.5 && index < prefixes.count - 1 { value /= 1000; index += 1 }
        let number: String
        if value < 0.005 { number = "0.00" }
        else if value < 9.995 { number = String(format: "%.2f", value) }
        else if value < 99.95 { number = String(format: "%.1f", value) }
        else { number = String(format: "%.0f", value) }
        return number + " " + prefixes[index]
    }
    /// "842 KB/s" or, with `perSecond` off, "842 KB". Never goes below kilo so the width stays steady.
    static func speed(_ bytesPerSecond: Double, unit: SpeedUnit, perSecond: Bool = true) -> String {
        let value = unit == .bits ? bytesPerSecond * 8 : bytesPerSecond
        return scaled(value, from: 0) + (unit == .bits ? "b" : "B") + (perSecond ? "/s" : "")
    }
    /// "512 B", "1.23 GB".
    static func amount(_ bytes: UInt64) -> String {
        bytes < 1000 ? "\(bytes) B" : scaled(Double(bytes), from: 0) + "B"
    }
    /// "Now", "25 s ago", "3 min 5 s ago".
    static func age(_ seconds: TimeInterval) -> String {
        let whole = Int(max(0, seconds.isFinite ? seconds : 0).rounded())
        if whole < 3 { return "Now" }
        if whole < 60 { return "\(whole) s ago" }
        return "\(whole / 60) min" + (whole % 60 == 0 ? "" : " \(whole % 60) s") + " ago"
    }
    /// "42 ms", never below 1 ms.
    static func ping(_ seconds: TimeInterval) -> String {
        "\(max(1, Int((seconds.isFinite ? seconds : 0) * 1000 + 0.5))) ms"
    }
}

/// Where Cloudflare sees the connection coming from: the exit of any VPN or proxy in use.
struct NetworkLocation: Equatable {
    var ip: String
    /// ISO region code, as in "DE".
    var country: String
    var city: String?
    /// Network operator, such as an ISP or VPN host.
    var organization: String?
    /// Cloudflare data center that answered, as an IATA airport code ("FRA").
    var colo: String
    /// Builds a location from what a server sent, or nil without a valid address. Text loses control and direction
    /// characters and is capped, and codes must have their usual shape, so a bad reply cannot garble the menu bar or popover.
    static func parsed(ip: String?, country: String?, city: String? = nil, organization: String? = nil,
                       colo: String? = nil) -> NetworkLocation? {
        let digits = CharacterSet(charactersIn: "0123456789abcdefABCDEF.:")
        guard let ip = ip?.trimmingCharacters(in: .whitespaces), (2...45).contains(ip.unicodeScalars.count),
              ip.unicodeScalars.allSatisfy(digits.contains) else { return nil }
        func code(_ value: String?, length: Int, allowing allowed: CharacterSet) -> String {
            let code = (value ?? "").trimmingCharacters(in: .whitespaces).uppercased()
            return code.unicodeScalars.count == length && code.unicodeScalars.allSatisfy(allowed.contains) ? code : ""
        }
        let letters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        // Two characters, as in "DE"; Cloudflare also sends "T1" for Tor.
        return NetworkLocation(ip: ip, country: code(country, length: 2, allowing: letters.union(CharacterSet(charactersIn: "0123456789"))),
                               city: text(city), organization: text(organization), colo: code(colo, length: 3, allowing: letters))
    }
    /// Text on one line of at most `limit` Unicode scalars, or nil if nothing is left. Counting scalars rather than
    /// characters stops a pile of combining marks on one letter from slipping past the cap and drawing over the popover.
    static func text(_ value: String?, limit: Int = 60) -> String? {
        guard let value else { return nil }
        let hidden = CharacterSet.controlCharacters.union(.newlines)  // Newlines include U+2028 and U+2029 separators.
        let printable = String(String.UnicodeScalarView(value.precomposedStringWithCanonicalMapping.unicodeScalars.filter { !hidden.contains($0) }))
            .trimmingCharacters(in: .whitespaces)
        let capped = String(String.UnicodeScalarView(printable.unicodeScalars.prefix(limit))).trimmingCharacters(in: .whitespaces)
        return capped.isEmpty ? nil : capped
    }
    /// The flag emoji for `country`, if it is a real region code. Cloudflare uses "XX" for unknown and "T1" for Tor.
    var flag: String? {
        let code = country.uppercased()
        let letters = code.unicodeScalars
        guard letters.count == 2, code != "XX", letters.allSatisfy({ ("A"..."Z").contains($0) }) else { return nil }
        return String(String.UnicodeScalarView(letters.compactMap { UnicodeScalar(0x1F1E6 - 65 + $0.value) }))
    }
    /// "Frankfurt am Main, Germany", or just the country when the city is unknown.
    func place(locale: Locale = .current) -> String {
        let name = locale.localizedString(forRegionCode: country) ?? country
        return [city, name].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

enum Cloudflare {
    /// "ip=1.2.3.4\nloc=DE\ncolo=FRA\n…" from /cdn-cgi/trace.
    static func trace(_ text: String) -> NetworkLocation? {
        var fields: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let equals = line.firstIndex(of: "=") else { continue }
            fields[String(line[..<equals])] = String(line[line.index(after: equals)...])
        }
        return NetworkLocation.parsed(ip: fields["ip"], country: fields["loc"], colo: fields["colo"])
    }
}

/// Where pings go. Each answers a tiny HTTPS request without needing an account.
enum PingServer: String, CaseIterable, Identifiable {
    case cloudflare, google, apple
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cloudflare: "Cloudflare"
        case .google: "Google"
        case .apple: "Apple"
        }
    }
    /// Cloudflare's reply also reports the address, country, and data center, so a new exit address shows at once.
    var url: URL {
        switch self {
        case .cloudflare: URL(string: "https://speed.cloudflare.com/cdn-cgi/trace")!
        case .google: URL(string: "https://www.gstatic.com/generate_204")!
        case .apple: URL(string: "https://captive.apple.com/hotspot-detect.html")!
        }
    }
    var reportsAddress: Bool { self == .cloudflare }
}

/// Free services that look up where an address is, without an account.
enum LocationService: String, CaseIterable, Identifiable {
    case cloudflare, ipinfo, geojs, ipsb, ifconfig, off
    var id: String { rawValue }
    /// Seconds between lookups when the ping server does not report the address; also bounded by free-use limits.
    static let interval: TimeInterval = 60
    var title: String {
        switch self {
        case .cloudflare: "Cloudflare (country only)"
        case .ipinfo: "ipinfo.io"
        case .geojs: "GeoJS"
        case .ipsb: "IP.SB"
        case .ifconfig: "ifconfig.co"
        case .off: "Off"
        }
    }
    /// Tried in order until one answers.
    var requests: [URLRequest] {
        switch self {
        // Cloudflare's public trace gives the address and country, but no city or network operator.
        case .cloudflare: return [URLRequest(url: PingServer.cloudflare.url)]
        case .ipinfo: return [URLRequest(url: URL(string: "https://ipinfo.io/json")!)]
        case .geojs: return [URLRequest(url: URL(string: "https://get.geojs.io/v1/ip/geo.json")!)]
        case .ipsb: return [URLRequest(url: URL(string: "https://api.ip.sb/geoip")!)]
        case .ifconfig: return [URLRequest(url: URL(string: "https://ifconfig.co/json")!)]
        case .off: return []
        }
    }
    var host: String? { requests.first?.url?.host }
    func location(from data: Data) -> NetworkLocation? {
        if self == .cloudflare { return Cloudflare.trace(String(decoding: data, as: UTF8.self)) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func text(_ key: String) -> String? { NetworkLocation.text(json[key] as? String) }
        let country: String, operators: [String]
        switch self {
        case .ipinfo: (country, operators) = ("country", ["org"])
        case .geojs: (country, operators) = ("country_code", ["organization_name", "organization"])
        case .ipsb: (country, operators) = ("country_code", ["organization", "isp", "asn_organization"])
        case .ifconfig: (country, operators) = ("country_iso", ["asn_org"])
        case .cloudflare, .off: return nil
        }
        return NetworkLocation.parsed(ip: text("ip"), country: text(country), city: text("city"),
                                      organization: operators.lazy.compactMap(text).first.map(Self.withoutASN))
    }
    /// "AS13335 Cloudflare, Inc." → "Cloudflare, Inc." A name that is only an AS number stays as it is.
    static func withoutASN(_ name: String) -> String {
        guard name.hasPrefix("AS"), let space = name.firstIndex(of: " ") else { return name }
        let number = name[name.index(name.startIndex, offsetBy: 2)..<space]
        let rest = name[name.index(after: space)...].trimmingCharacters(in: .whitespaces)
        guard !number.isEmpty, number.allSatisfy({ ("0"..."9").contains($0) }), !rest.isEmpty else { return name }
        return rest
    }
}

/// Keeps location lookups apart. Every lost ping clears the location, so on a flaky connection with pings every
/// second, lookups would otherwise go out every couple of seconds and soon hit the free services' limits.
struct LookupPacer {
    static let gap: TimeInterval = 15
    private var last: TimeInterval?
    func allows(at now: TimeInterval) -> Bool { last.map { now - $0 >= Self.gap } ?? true }
    mutating func record(at now: TimeInterval) { last = now }
}

/// What the ping server reports about the connection, combined with what the location service looked up.
struct LocationState: Equatable {
    /// From each ping reply, when the ping server reports the address, as Cloudflare does.
    private(set) var traced: NetworkLocation?
    private(set) var details: NetworkLocation?
    /// The traced address the details were looked up for. A service may see IPv6 where Cloudflare saw IPv4, so the
    /// details' own address is not compared.
    private var detailsFor: String?
    private var requestedFor: String?
    private var requestedAt: TimeInterval?
    mutating func trace(_ location: NetworkLocation) { traced = location }
    /// With a traced address, once per address; without, every `interval` seconds.
    func needsLookup(at now: TimeInterval, interval: TimeInterval) -> Bool {
        guard let requestedAt else { return true }
        if let traced { return requestedFor != traced.ip }
        return now - requestedAt >= interval
    }
    /// Returns the traced address the lookup is for, to hand back to `found`.
    mutating func lookingUp(at now: TimeInterval) -> String? {
        requestedAt = now; requestedFor = traced?.ip
        return requestedFor
    }
    /// Ignored if the traced address changed while the lookup ran.
    mutating func found(_ location: NetworkLocation, for traced: String?) {
        guard traced == self.traced?.ip else { return }
        details = location; detailsFor = traced
    }
    var location: NetworkLocation? {
        guard let details else { return traced }
        guard let traced else { return details }
        guard detailsFor == traced.ip else { return traced }
        var merged = details
        merged.colo = traced.colo
        return merged
    }
}

/// The latest ping and where the connection exits.
struct PingReading: Equatable {
    enum Quality { case good, fair, poor }
    /// Seconds for the last round trip, or nil if it failed or none has finished yet.
    var latency: TimeInterval?
    var failed = false
    /// No network connection at all, so no ping is sent.
    var offline = false
    var location: NetworkLocation?
    var history = PingHistory()
    var text: String { offline ? "offline" : latency.map(Format.ping) ?? (failed ? "timeout" : "– ms") }
    var quality: Quality? {
        guard let latency else { return failed || offline ? .poor : nil }
        return latency < 0.15 ? .good : latency < 0.4 ? .fair : .poor
    }
}

/// One ping: when it finished, on the monotonic clock, and its round trip, or nil if there was no reply.
struct PingSample: Equatable {
    var time: TimeInterval
    var latency: TimeInterval?
}

/// The last few minutes of pings, kept in memory only.
struct PingHistory: Equatable {
    static let capacity = 120
    private(set) var samples: [PingSample] = []
    mutating func record(_ sample: PingSample) {
        samples.append(sample)
        if samples.count > Self.capacity { samples.removeFirst(samples.count - Self.capacity) }
    }
    var lost: Int { samples.filter { $0.latency == nil }.count }
    var average: TimeInterval? {
        let replies = samples.compactMap(\.latency)
        return replies.isEmpty ? nil : replies.reduce(0, +) / Double(replies.count)
    }
    /// "Last 10 min · avg 245 ms · 2 lost", or "… · no loss".
    func summary(interval: TimeInterval) -> String {
        let window = Int(Double(Self.capacity) * interval / 60)
        return (["Last \(window) min"] + [average.map { "avg \(Format.ping($0))" }].compactMap { $0 }
                + [samples.isEmpty ? nil : lost == 0 ? "no loss" : "\(lost) lost"].compactMap { $0 }).joined(separator: " · ")
    }
}

/// One menu bar entry: a symbol ("↑", "↓", "⇅", "=") and its value.
struct MenuBarItem: Equatable {
    let symbol: String
    let value: String
}

enum MenuBar {
    /// `perSecond` adds "/s"; the side-by-side layout leaves it out to save space.
    static func items(rate: Throughput, usage: UInt64?, style: MenuBarStyle, unit: SpeedUnit, perSecond: Bool = false) -> [MenuBarItem] {
        let up = MenuBarItem(symbol: "↑", value: Format.speed(rate.sent, unit: unit, perSecond: perSecond))
        let down = MenuBarItem(symbol: "↓", value: Format.speed(rate.received, unit: unit, perSecond: perSecond))
        var items: [MenuBarItem]
        switch style {
        case .uploadFirst: items = [up, down]
        case .downloadFirst: items = [down, up]
        case .combined: items = [MenuBarItem(symbol: "⇅", value: Format.speed(rate.total, unit: unit, perSecond: perSecond))]
        }
        if let usage { items.append(MenuBarItem(symbol: "=", value: Format.amount(usage))) }
        return items
    }
    /// Groups entries into menu bar columns: up to two lines each when stacked, one each side by side.
    /// Stacked speeds with usage become two columns: both speeds, then usage on its own.
    static func columns(_ items: [MenuBarItem], stacked: Bool) -> [[MenuBarItem]] {
        guard stacked else { return items.map { [$0] } }
        return stride(from: 0, to: items.count, by: 2).map { Array(items[$0..<min($0 + 2, items.count)]) }
    }
    /// Flag and country code over the ping: one column when stacked, two side by side. Just the ping until the location is known.
    static func pingColumns(_ reading: PingReading, stacked: Bool) -> [[String]] {
        var lines = [reading.text]
        if let location = reading.location, !location.country.isEmpty {
            lines.insert(([location.flag].compactMap { $0 } + [location.country.uppercased()]).joined(separator: " "), at: 0)
        }
        return stacked ? [lines] : lines.map { [$0] }
    }
}
