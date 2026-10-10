import AppKit
import SwiftUI
import Darwin
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
    @Published private(set) var active: [ActiveInterface] = []
    @Published private(set) var error: String?
    @Published var loginMessage: String?
    /// Graph sample under the pointer, if any.
    @Published var hoveredSample: Int?

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
    /// BSD name of the interface whose speed is shown, or "" for all physical interfaces.
    @Published var interface = UserDefaults.standard.string(forKey: "interface") ?? "" {
        didSet { defaults.set(interface, forKey: "interface"); history.removeAll() }
    }
    @Published var interval = [1.0, 2, 5].first { $0 == UserDefaults.standard.double(forKey: "interval") } ?? 1 {
        didSet { defaults.set(interval, forKey: "interval"); history.removeAll(); onIntervalChange?() }
    }
    var onUpdate: (() -> Void)?
    var onLayoutChange: (() -> Void)?
    var onIntervalChange: (() -> Void)?

    private let defaults = UserDefaults.standard
    private var sampler = TrafficSampler()
    private var names = interfaceDisplayNames()
    private var refreshes = 0

    init() {
        let today = DailyUsage.key(for: Date())
        let stored = DailyUsage(day: defaults.string(forKey: "usageDay") ?? today,
                                received: UInt64(max(0, defaults.double(forKey: "usageReceived"))),
                                sent: UInt64(max(0, defaults.double(forKey: "usageSent"))))
        usage = stored.day == today ? stored : DailyUsage(day: today)
    }
    var showsUsageInMenuBar: Bool { showsUsage && MenuBar.usageFits(style: style, stacked: stacked) }
    var menuBarItems: [MenuBarItem] {
        MenuBar.items(rate: rate, usage: showsUsageInMenuBar ? usage.total : nil, style: style, unit: unit, perSecond: showsPerSecond)
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
        let sample = sampler.sample(counters, at: monotonicSeconds())
        usage.add(sample.transfer(where: Interfaces.isPhysical), today: DailyUsage.key(for: Date()))
        let selected = interface
        rate = sample.throughput(where: selected.isEmpty ? Interfaces.isPhysical : { $0 == selected })
        if sample.elapsed != nil {
            history.append(rate)
            if history.count > Self.historyLength { history.removeFirst(history.count - Self.historyLength) }
        }
        let shown = counters.filter { $0.isActive && Interfaces.isPhysical($0.name) && $0.received + $0.sent > 0 }
        if shown.contains(where: { names[$0.name] == nil }) { names = interfaceDisplayNames() }
        active = shown.map { ActiveInterface(name: $0.name, title: title(for: $0.name),
                                             rate: sample.throughput(where: { [name = $0.name] in $0 == name })) }
        refreshes += 1
        if refreshes % 10 == 0 { saveUsage() }
        onUpdate?()
    }
    func resetUsage() {
        usage = DailyUsage(day: DailyUsage.key(for: Date()))
        saveUsage(); onUpdate?()
    }
    func saveUsage() {
        defaults.set(usage.day, forKey: "usageDay")
        defaults.set(Double(usage.received), forKey: "usageReceived")
        defaults.set(Double(usage.sent), forKey: "usageSent")
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
}

/// Maps graph samples to points in a view of a given size.
struct GraphLayout {
    let history: [Throughput]
    let capacity: Int
    let size: CGSize
    /// Highest value on the shared axis, never below 10 KB/s so idle noise stays flat.
    var peak: Double { max(history.map { max($0.received, $0.sent) }.max() ?? 0, 10_000) }
    var step: CGFloat { size.width / CGFloat(max(capacity - 1, 1)) }
    /// Newest sample sits at the right edge; a partial history starts part-way across.
    var start: CGFloat { CGFloat(capacity - history.count) * step }
    func point(_ index: Int, _ value: Double) -> CGPoint {
        CGPoint(x: start + CGFloat(index) * step, y: size.height - 3 - CGFloat(value / peak) * (size.height - 6))
    }
    func line(_ value: KeyPath<Throughput, Double>) -> Path {
        Path { path in
            for (index, sample) in history.enumerated() {
                let next = point(index, sample[keyPath: value])
                if index == 0 { path.move(to: next) } else { path.addLine(to: next) }
            }
        }
    }
    func index(at x: CGFloat) -> Int? {
        history.isEmpty ? nil : min(max(Int(((x - start) / step).rounded()), 0), history.count - 1)
    }
}

/// The last minute of download and upload speed on one shared axis.
struct SpeedGraph: View {
    let history: [Throughput]
    let capacity: Int
    @Binding var hovered: Int?
    var body: some View {
        GeometryReader { geometry in
            graph(GraphLayout(history: history, capacity: capacity, size: geometry.size))
        }
        .accessibilityElement()
        .accessibilityLabel("Speed graph for the last \(history.count) samples")
    }
    private func graph(_ layout: GraphLayout) -> some View {
        let size = layout.size
        let stroke = StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
        return ZStack(alignment: .topLeading) {
            Path { $0.move(to: CGPoint(x: 0, y: size.height - 0.5)); $0.addLine(to: CGPoint(x: size.width, y: size.height - 0.5)) }
                .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
            layout.line(\.sent).stroke(Color(nsColor: .upload), style: stroke)
            layout.line(\.received).stroke(Color(nsColor: .download), style: stroke)
            if let hovered, history.indices.contains(hovered) {
                Path { path in
                    let x = layout.point(hovered, 0).x
                    path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height))
                }
                .stroke(Color.secondary.opacity(0.5), lineWidth: 1)
                marker(layout.point(hovered, history[hovered].sent), .upload)
                marker(layout.point(hovered, history[hovered].received), .download)
            }
        }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let location): hovered = layout.index(at: location.x)
            case .ended: hovered = nil
            }
        }
    }
    private func marker(_ center: CGPoint, _ color: NSColor) -> some View {
        Circle().fill(Color(nsColor: color))
            .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
            .frame(width: 7, height: 7).position(center)
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
            VStack(alignment: .leading, spacing: 4) {
                SpeedGraph(history: model.history, capacity: TrafficModel.historyLength, hovered: $model.hoveredSample).frame(height: 56)
                Text(graphCaption).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
            if let error = model.error {
                Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
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
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
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
    var body: some View {
        Form {
            Section {
                HStack {
                    Spacer()
                    Image(nsImage: MenuBarRenderer(model: model).image(model.menuBarItems))
                        .renderingMode(.template).foregroundStyle(.primary)
                        .padding(.horizontal, 10)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12)))
                        .accessibilityLabel("Menu bar preview")
                    Spacer()
                }
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
                    .disabled(!MenuBar.usageFits(style: model.style, stacked: model.stacked))
                Picker("Units", selection: $model.unit) {
                    Text("Bytes (MB/s)").tag(SpeedUnit.bytes)
                    Text("Bits (Mb/s)").tag(SpeedUnit.bits)
                }
            } header: {
                Text("Menu Bar")
            } footer: {
                Text(MenuBar.usageFits(style: model.style, stacked: model.stacked)
                     ? "Usage appears after “=”. 1 KB = 1000 bytes, as in Finder."
                     : "Two stacked speeds leave no room for usage. Choose Combined or Side by side to show it.")
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
                Text("“All interfaces” adds up Wi-Fi, Ethernet, and other physical links. VPN, bridge, and loopback interfaces are skipped so no traffic is counted twice.")
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
                    Button("Reset Usage", action: model.resetUsage)
                }
            } header: {
                Text("General")
            } footer: {
                Text("Usage counts all physical interfaces while Jarian is running and restarts at midnight. Only today's total is saved; no logs are written.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Draws the menu bar readings. Shared by the status item and the Settings preview.
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
    /// A template image, so the readings follow the menu bar's light, dark, and tinted styles.
    func image(_ items: [MenuBarItem]) -> NSImage {
        let height = NSStatusBar.system.thickness
        let columns = columns
        let gap: CGFloat = stacked ? 6 : 3, spacing: CGFloat = 7
        let column = columns.symbol + gap + columns.value
        let count = stacked ? 1 : items.count  // One column of stacked lines, or columns side by side.
        let font = font
        let lineHeight = ceil(font.ascender - font.descender)
        let size = NSSize(width: CGFloat(count) * column + CGFloat(count - 1) * spacing, height: height)
        let stacked = stacked
        let image = NSImage(size: size, flipped: true) { _ in
            for (index, entry) in items.enumerated() {
                let x = stacked ? 0 : CGFloat(index) * (column + spacing)
                let y = stacked ? (height - 2 * lineHeight) / 2 + CGFloat(index) * lineHeight : (height - lineHeight) / 2
                let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
                let symbol = NSAttributedString(string: entry.symbol, attributes: attributes)
                symbol.draw(at: CGPoint(x: x + (columns.symbol - symbol.size().width) / 2, y: y))
                let value = NSAttributedString(string: entry.value, attributes: attributes)
                value.draw(at: CGPoint(x: x + column - value.size().width, y: y))  // Right-aligned so digits stay put.
            }
            return true
        }
        image.isTemplate = true
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
        item.button?.image = MenuBarRenderer(model: model).image(items)
        let summary = "Download \(model.speed(model.rate.received)), upload \(model.speed(model.rate.sent)), today \(Format.amount(model.usage.total))"
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
        info(model.interfaceTitle)
        menu.addItem(.separator())
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
        for counter in try readCounters() where counter.received + counter.sent > 0 {
            let kind = Interfaces.isPhysical(counter.name) ? "physical" : "virtual"
            print("\(counter.name) (\(names[counter.name] ?? "—"), \(kind)\(counter.isActive ? "" : ", down")): "
                  + "↓ \(Format.amount(counter.received)) ↑ \(Format.amount(counter.sent))")
        }
    } catch { fputs("\(error)\n", stderr); exit(1) }
} else {
    let app = NSApplication.shared
    let delegate = MenuApp()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
