import Foundation

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ description: String) {
    guard condition() else { fatalError("FAILED: \(description)") }
    checks += 1
}
func counters(_ values: [String: (UInt64, UInt64)]) -> [InterfaceCounters] {
    values.map { InterfaceCounters(name: $0.key, received: $0.value.0, sent: $0.value.1) }
}

// Interface filtering
for name in ["en0", "en7", "pdp_ip0"] { check(Interfaces.isPhysical(name), "\(name) is physical") }
for name in ["lo0", "utun3", "ipsec0", "bridge0", "awdl0", "llw0", "anpi1", "ap1", "nan0", "gif0", "stf0"] {
    check(!Interfaces.isPhysical(name), "\(name) is virtual and would double-count")
}

// Sampling
var sampler = TrafficSampler()
let first = sampler.sample(counters(["en0": (1000, 500)]), at: 10)
check(first.elapsed == nil && first.transfers.isEmpty, "First sample has no baseline")
check(first.throughput(where: { _ in true }) == Throughput(), "First sample reports zero speed")
let second = sampler.sample(counters(["en0": (3000, 900), "en1": (50, 50)]), at: 12)
check(second.elapsed == 2, "Elapsed time between samples")
check(second.transfers["en0"] == Transfer(received: 2000, sent: 400), "Deltas of a known interface")
check(second.transfers["en1"] == nil, "A new interface waits for its baseline")
check(second.throughput(where: { _ in true }) == Throughput(received: 1000, sent: 200), "Bytes per second")
let third = sampler.sample(counters(["en0": (100, 1000), "en1": (150, 70)]), at: 13)
check(third.transfers["en0"] == Transfer(received: 0, sent: 100), "A reset counter counts nothing, not a wrap")
check(third.transfer(where: { $0 == "en1" }) == Transfer(received: 100, sent: 20), "Filter by interface")
check(third.transfer(where: { _ in true }) == Transfer(received: 100, sent: 120), "Sum across interfaces")
let stalled = sampler.sample(counters(["en0": (100, 1000)]), at: 13)
check(stalled.elapsed == nil && stalled.throughput(where: { _ in true }) == Throughput(), "No division by zero time")

// Daily usage
var usage = DailyUsage(day: "2026-10-10")
usage.add(Transfer(received: 700, sent: 300), today: "2026-10-10")
usage.add(Transfer(received: 1, sent: 2), today: "2026-10-10")
check(usage.received == 701 && usage.sent == 302 && usage.total == 1003, "Usage accumulates within a day")
usage.add(Transfer(received: 5, sent: 6), today: "2026-10-11")
check(usage == DailyUsage(day: "2026-10-11", received: 5, sent: 6), "Usage restarts on a new day")
var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!
check(DailyUsage.key(for: Date(timeIntervalSince1970: 1_791_590_400), calendar: calendar) == "2026-10-10", "Day key")

// Formatting
check(Format.speed(0, unit: .bytes) == "0.00 KB/s", "Idle keeps two decimals so the width stays steady")
check(Format.speed(420, unit: .bytes) == "0.42 KB/s", "Below a kilobyte stays in KB")
check(Format.speed(8_420, unit: .bytes) == "8.42 KB/s", "Two decimals under 10")
check(Format.speed(84_200, unit: .bytes) == "84.2 KB/s", "One decimal under 100")
check(Format.speed(842_000, unit: .bytes) == "842 KB/s", "No decimals under 1000")
check(Format.speed(999_600, unit: .bytes) == "1.00 MB/s", "Rounding up to the next prefix")
check(Format.speed(1_250_000, unit: .bits) == "10.0 Mb/s", "Bits are bytes × 8")
check(Format.speed(3e9, unit: .bytes, perSecond: false) == "3.00 GB", "Menu bar drops /s")
check(Format.speed(.nan, unit: .bytes) == "0.00 KB/s", "Invalid input never crashes")
check(Format.amount(512) == "512 B" && Format.amount(1_234_000_000) == "1.23 GB", "Amounts")

// Menu bar text
let rate = Throughput(received: 2_000_000, sent: 30_000)
check(MenuBar.items(rate: rate, usage: nil, style: .uploadFirst, unit: .bytes)
      == [MenuBarItem(symbol: "↑", value: "30.0 KB"), MenuBarItem(symbol: "↓", value: "2.00 MB")], "Upload first")
check(MenuBar.items(rate: rate, usage: nil, style: .downloadFirst, unit: .bytes).map(\.symbol) == ["↓", "↑"], "Download first")
check(MenuBar.items(rate: rate, usage: 5_000_000_000, style: .combined, unit: .bytes)
      == [MenuBarItem(symbol: "⇅", value: "2.03 MB"), MenuBarItem(symbol: "=", value: "5.00 GB")], "Combined with usage")
check(MenuBar.items(rate: rate, usage: nil, style: .downloadFirst, unit: .bytes, perSecond: true).map(\.value)
      == ["2.00 MB/s", "30.0 KB/s"], "Stacked layout keeps /s")
check(MenuBar.usageFits(style: .combined, stacked: true) && !MenuBar.usageFits(style: .uploadFirst, stacked: true)
      && MenuBar.usageFits(style: .uploadFirst, stacked: false), "Stacked layout has two lines")

print("All \(checks) checks passed")
