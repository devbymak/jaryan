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
    /// Loopback, tunnel (VPN), bridge, and Apple peer-to-peer (AWDL, Wi-Fi Aware) interfaces. Their traffic is either local
    /// or also crosses a physical interface, so counting it would count the same bytes twice.
    static let virtualPrefixes = ["lo", "utun", "ipsec", "ppp", "gif", "stf", "bridge", "awdl", "llw", "anpi", "ap", "nan", "vmenet", "feth"]
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
    /// Starts a fresh count when `today` differs from the stored day.
    mutating func add(_ transfer: Transfer, today: String) {
        if today != day { self = DailyUsage(day: today) }
        received &+= transfer.received
        sent &+= transfer.sent
    }
    static func key(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
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
}
