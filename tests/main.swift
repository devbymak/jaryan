import Foundation

var checks = 0
func check(_ condition: @autoclosure () throws -> Bool, _ description: String) rethrows {
    guard try condition() else { fatalError("FAILED: \(description)") }
    checks += 1
}
func counters(_ values: [String: (UInt64, UInt64)]) -> [InterfaceCounters] {
    values.map { InterfaceCounters(name: $0.key, received: $0.value.0, sent: $0.value.1) }
}

// Interface filtering
for name in ["en0", "en7", "pdp_ip0"] { check(Interfaces.isPhysical(name), "\(name) is physical") }
for name in ["lo0", "utun3", "ipsec0", "bridge0", "awdl0", "llw0", "anpi1", "ap1", "nan0", "gif0", "stf0",
             "vmenet0", "vmnet8", "vnic0", "vboxnet0"] {
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
check(DailyUsage.key("2026-03-01", adding: -1, calendar: calendar) == "2026-02-28", "Day arithmetic crosses months")
check(DailyUsage.key("2027-01-01", adding: -1, calendar: calendar) == "2026-12-31", "Day arithmetic crosses years")
check(DailyUsage.key("nonsense", adding: 1) == nil, "Invalid keys are rejected")
var rolling = DailyUsage(day: "2026-10-10", received: 9, sent: 1)
check(rolling.add(Transfer(received: 1, sent: 0), today: "2026-10-10") == nil, "No day ends within a day")
check(rolling.add(Transfer(received: 2, sent: 3), today: "2026-10-11") == DailyUsage(day: "2026-10-10", received: 10, sent: 1),
      "The finished day is returned at rollover")

// Bounded daily history
func day(_ key: String, _ total: UInt64) -> DailyUsage { DailyUsage(day: key, received: total, sent: 0) }
var past = UsageHistory(retention: 7, today: "2026-10-10")
past.record(day("2026-10-09", 100), today: "2026-10-10")
past.record(day("2026-10-05", 50), today: "2026-10-10")
past.record(day("2026-10-09", 1), today: "2026-10-10")
past.record(day("2026-10-08", 0), today: "2026-10-10")
check(past.days.map(\.day) == ["2026-10-09", "2026-10-05"] && past.usage(on: "2026-10-09")?.total == 101,
      "Days are merged, empty days skipped, newest first")
past.record(day("2026-10-03", 7), today: "2026-10-10")
check(past.usage(on: "2026-10-03") == nil, "A day older than the retention is never stored")
let todayUsage = day("2026-10-10", 1000)
check(past.total(lastDays: 2, today: todayUsage) == 1101 && past.total(lastDays: 7, today: todayUsage) == 1151, "Totals over recent days")
past.trim(today: "2026-10-15")
check(past.days.map(\.day) == ["2026-10-09"], "Days age out as time passes")
past.retention = 1; past.trim(today: "2026-10-15")
check(past.days.isEmpty, "Today only keeps no past days")
var many = UsageHistory(retention: 90, today: "2026-12-31")
for offset in 1...400 { many.record(day(DailyUsage.key("2026-12-31", adding: -offset)!, 1), today: "2026-12-31") }
check(many.days.count == 89, "History never holds more than the retention, however long it runs")
check(UsageHistory.decode(many.encoded) == many.days, "Saved history round-trips")
check(UsageHistory.decode(["2026-10-09 5 6", "garbage", "2026-13-40 1 1", "2026-10-08 x 1"]) == [DailyUsage(day: "2026-10-09", received: 5, sent: 6)],
      "Corrupt saved entries are dropped")
check(UsageHistory(retention: 7, days: [day("2026-01-01", 5), day("2026-10-09", 5)], today: "2026-10-10").days.count == 1,
      "Old saved days are trimmed on load")

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
check(Format.speedTick(0, unit: .bytes) == "0" && Format.speedTick(500, unit: .bytes) == "500 B/s", "Small axis labels")
check(Format.speedTick(2_500_000, unit: .bytes) == "2.5 MB/s" && Format.speedTick(1_000_000, unit: .bytes) == "1 MB/s",
      "Axis labels drop trailing zeros")
check(Format.speedTick(125_000, unit: .bits) == "1 Mb/s" && Format.speedTick(.nan, unit: .bits) == "0", "Axis labels in bits")
check(Format.pingTick(0) == "0" && Format.pingTick(0.05) == "50 ms" && Format.pingTick(0.15000000000000002) == "150 ms", "Ping axis labels")

// Graph axes
check(GraphScale(peak: 0, minimum: 10_000).ticks == [0, 5_000, 10_000], "An idle graph keeps its minimum scale")
check(GraphScale(peak: 1_230_000, minimum: 10_000).ticks == [0, 500_000, 1_000_000, 1_500_000], "Round steps above the peak")
check(GraphScale(peak: 3_000_000, minimum: 10_000).top == 3_000_000, "A peak on a round value is the top")
check(GraphScale(peak: 0.3, minimum: 0.1).ticks.count == 4 && GraphScale(peak: .infinity, minimum: 0.1).top == 0.1,
      "Ping scale, and invalid input never crashes")
for peak in [1.0, 7.3, 42, 99, 101, 777, 12_345, 9_999_999] {
    let scale = GraphScale(peak: peak, minimum: 1)
    check(scale.top >= peak && scale.ticks.count >= 2 && scale.ticks.count <= 4, "Scale for \(peak) fits in 1 to 3 steps")
}
check(TimeTick.ticks(span: 60).map(\.label) == ["Now", "15 s", "30 s", "45 s", "60 s"], "One-minute axis")
check(TimeTick.ticks(span: 120).map(\.label) == ["Now", "30 s", "60 s", "90 s", "120 s"], "Two-minute axis")
check(TimeTick.ticks(span: 600).map(\.label) == ["Now", "2 min", "4 min", "6 min", "8 min", "10 min"], "Ten-minute axis")
check(TimeTick.ticks(span: 7200).count == 5 && TimeTick.ticks(span: 7200).last?.label == "120 min", "Two-hour axis")

// Menu bar text
let rate = Throughput(received: 2_000_000, sent: 30_000)
check(MenuBar.items(rate: rate, usage: nil, style: .uploadFirst, unit: .bytes)
      == [MenuBarItem(symbol: "↑", value: "30.0 KB"), MenuBarItem(symbol: "↓", value: "2.00 MB")], "Upload first")
check(MenuBar.items(rate: rate, usage: nil, style: .downloadFirst, unit: .bytes).map(\.symbol) == ["↓", "↑"], "Download first")
check(MenuBar.items(rate: rate, usage: 5_000_000_000, style: .combined, unit: .bytes)
      == [MenuBarItem(symbol: "⇅", value: "2.03 MB"), MenuBarItem(symbol: "=", value: "5.00 GB")], "Combined with usage")
check(MenuBar.items(rate: rate, usage: nil, style: .downloadFirst, unit: .bytes, perSecond: true).map(\.value)
      == ["2.00 MB/s", "30.0 KB/s"], "Stacked layout keeps /s")
let separate = MenuBar.items(rate: rate, usage: 1, style: .uploadFirst, unit: .bytes)
check(MenuBar.columns(separate, stacked: true).map { $0.map(\.symbol) } == [["↑", "↓"], ["="]], "Stacked usage gets its own column")
check(MenuBar.columns(separate, stacked: false).map(\.count) == [1, 1, 1], "Side by side: one entry per column")
let combined = MenuBar.items(rate: rate, usage: 1, style: .combined, unit: .bytes)
check(MenuBar.columns(combined, stacked: true).map { $0.map(\.symbol) } == [["⇅", "="]], "Combined and usage stack together")
check(MenuBar.columns(MenuBar.items(rate: rate, usage: nil, style: .combined, unit: .bytes), stacked: true).map(\.count) == [1],
      "A lone combined speed is one line")


// Ping and location
check(Format.ping(0.0424) == "42 ms" && Format.ping(0.0001) == "1 ms" && Format.ping(.nan) == "1 ms", "Ping in whole milliseconds")
check(PingReading().text == "– ms" && PingReading(failed: true).text == "timeout", "Ping before a reply and after a failure")
check(PingReading(latency: 0.05, offline: true).text == "offline" && PingReading(offline: true).quality == .poor, "Offline hides the last ping")
check(PingReading(latency: 0.05).quality == .good && PingReading(latency: 0.2).quality == .fair
      && PingReading(latency: 0.5).quality == .poor && PingReading(failed: true).quality == .poor && PingReading().quality == nil,
      "Ping quality")
let trace = Cloudflare.trace("fl=1\nh=speed.cloudflare.com\nip=104.28.200.67\ncolo=SOF\nloc=GE\nwarp=on\n")
check(trace == NetworkLocation(ip: "104.28.200.67", country: "GE", colo: "SOF"), "Trace gives address, country, and data center")
check(Cloudflare.trace("<html>blocked</html>") == nil, "A page without an address is not a trace")
let located = NetworkLocation(ip: "104.28.200.67", country: "GE", city: "Tbilisi", colo: "SOF")
let english = Locale(identifier: "en_US")
check(located.place(locale: english) == "Tbilisi, Georgia" && trace?.place(locale: english) == "Georgia", "Place names")
check(located.flag == "🇬🇪" && NetworkLocation(ip: "", country: "XX", colo: "").flag == nil
      && NetworkLocation(ip: "", country: "T1", colo: "").flag == nil, "Flags only for real regions")
let reading = PingReading(latency: 0.291, location: located)
check(MenuBar.pingColumns(reading, stacked: true) == [["🇬🇪 GE", "291 ms"]], "Stacked: flag and country over the ping")
check(MenuBar.pingColumns(reading, stacked: false) == [["🇬🇪 GE"], ["291 ms"]], "Side by side: location, then ping")
check(MenuBar.pingColumns(PingReading(failed: true), stacked: true) == [["timeout"]], "Only the ping until the location is known")
check(MenuBar.pingColumns(PingReading(latency: 0.05, location: NetworkLocation(ip: "1.2.3.4", country: "T1", colo: "")), stacked: true)
      == [["T1", "50 ms"]], "A code without a flag is shown alone")

// Location services, from real responses
func located(_ service: LocationService, _ json: String) -> NetworkLocation? { service.location(from: Data(json.utf8)) }
check(located(.ipinfo, #"{"ip":"104.28.200.67","city":"Tbilisi","country":"GE","org":"AS13335 Cloudflare, Inc."}"#)
      == NetworkLocation(ip: "104.28.200.67", country: "GE", city: "Tbilisi", organization: "Cloudflare, Inc.", colo: ""), "ipinfo.io")
check(located(.geojs, #"{"city":"Tbilisi","country":"Georgia","country_code":"GE","ip":"104.28.200.67","organization":"AS13335 Cloudflare, Inc.","organization_name":"Cloudflare, Inc."}"#)
      == NetworkLocation(ip: "104.28.200.67", country: "GE", city: "Tbilisi", organization: "Cloudflare, Inc.", colo: ""), "GeoJS")
check(located(.ipsb, #"{"organization":"Cloudflare Warp","isp":"Cloudflare Warp","city":"Tbilisi","ip":"104.28.200.67","country":"Georgia","country_code":"GE"}"#)
      == NetworkLocation(ip: "104.28.200.67", country: "GE", city: "Tbilisi", organization: "Cloudflare Warp", colo: ""), "IP.SB")
check(located(.ifconfig, #"{"ip":"104.28.200.67","country":"Georgia","country_iso":"GE","city":"Tbilisi","asn":"AS13335","asn_org":"CLOUDFLARENET"}"#)
      == NetworkLocation(ip: "104.28.200.67", country: "GE", city: "Tbilisi", organization: "CLOUDFLARENET", colo: ""), "ifconfig.co")
check(located(.cloudflare, "ip=1.2.3.4\nloc=DE\ncolo=FRA\n") == NetworkLocation(ip: "1.2.3.4", country: "DE", colo: "FRA"),
      "Cloudflare reads the trace")
check(located(.ipinfo, #"{"error":"rate limited"}"#) == nil && located(.geojs, "<html>") == nil && located(.off, "{}") == nil,
      "Errors and pages are not locations")
check(LocationService.withoutASN("AS13335 Cloudflare, Inc.") == "Cloudflare, Inc." && LocationService.withoutASN("ASUS Net") == "ASUS Net",
      "Only a real AS number is dropped")
check(LocationService.withoutASN("AS1  X") == "X" && LocationService.withoutASN("AS1 ") == "AS1 " && LocationService.withoutASN("AS X") == "AS X",
      "No leading space, and a bare AS number is kept")
check(LocationService.allCases.allSatisfy { $0.requests.allSatisfy { $0.allHTTPHeaderFields?.isEmpty ?? true } },
      "Lookups send no made-up headers")
check(LocationService.off.requests.isEmpty && LocationService.cloudflare.requests.count == 1
      && LocationService.allCases.allSatisfy { $0.requests.allSatisfy { $0.url?.scheme == "https" } }, "Lookups use HTTPS only")
check(PingServer.allCases.allSatisfy { $0.url.scheme == "https" } && PingServer.cloudflare.reportsAddress && !PingServer.google.reportsAddress,
      "Ping servers")

// Replies are cleaned before they are shown
check(Cloudflare.trace("ip=<script>\nloc=DE\n") == nil && Cloudflare.trace("ip=1.2.3.4.5.6.7.8.9.0.1.2.3.4.5.6.7.8.9.0.1.2.3.4.5.6.7\n") == nil,
      "An address must look like one")
check(Cloudflare.trace("ip=::1\nloc=Germany\ncolo=FRANKFURT\n") == NetworkLocation(ip: "::1", country: "", colo: ""),
      "Country and data center codes must have their usual shape")
check(Cloudflare.trace("ip=1.2.3.4\nloc=de\ncolo=fra\n") == NetworkLocation(ip: "1.2.3.4", country: "DE", colo: "FRA"), "Codes are uppercased")
let noisy = located(.ipinfo, #"{"ip":"1.2.3.4","country":"GE","city":"Tbi\u202Elisi\nX","org":"AS1 \#(String(repeating: "x", count: 500))"}"#)
check(noisy?.city == "TbilisiX" && (noisy?.organization?.count ?? 99) <= 60, "Text loses control characters and is capped")
check(NetworkLocation.text(" \n ") == nil && NetworkLocation.text("Sofia") == "Sofia", "Blank text is nothing")
let piled = NetworkLocation.text("A" + String(repeating: "\u{0301}", count: 5000))
check((piled?.unicodeScalars.count ?? 99) <= 60, "Combining marks piled on one letter are capped too")
check(NetworkLocation.text("Tbi\u{2028}lisi\u{2029}") == "Tbilisi", "Line and paragraph separators are removed")
check(NetworkLocation.text("Zu\u{0308}rich") == "Z\u{00FC}rich", "Accents stay, combined with their letters")
check(NetworkLocation.text(String(repeating: "a", count: 59) + " b") == String(repeating: "a", count: 59), "No trailing space after the cap")

// Combining traced and looked-up locations
let v4 = NetworkLocation(ip: "104.28.200.67", country: "GE", colo: "SOF")
let details = NetworkLocation(ip: "2a09:bac5::1", country: "GE", city: "Tbilisi", organization: "Cloudflare, Inc.", colo: "")
var state = LocationState()
check(state.needsLookup(at: 0, interval: 60) && state.location == nil, "Look up at first")
var forIP = state.lookingUp(at: 0)
check(!state.needsLookup(at: 30, interval: 60) && state.needsLookup(at: 60, interval: 60), "Without a trace, look up every minute")
state.found(details, for: forIP)
check(state.location == details, "Untraced details are shown as found")
state = LocationState(); state.trace(v4)
check(state.location == v4 && state.needsLookup(at: 0, interval: 60), "A trace is shown until details arrive")
forIP = state.lookingUp(at: 0)
check(!state.needsLookup(at: 600, interval: 60), "With a trace, once per address however long it runs")
state.found(details, for: forIP)
check(state.location?.city == "Tbilisi" && state.location?.colo == "SOF", "Details looked up from IPv6 still match the IPv4 trace")
state.trace(NetworkLocation(ip: "104.28.200.67", country: "GE", colo: "IST"))
check(state.location?.colo == "IST" && state.location?.city == "Tbilisi", "Same address, new data center: details stay")
state.trace(NetworkLocation(ip: "5.6.7.8", country: "NL", colo: "AMS"))
check(state.location?.city == nil && state.location?.country == "NL" && state.needsLookup(at: 0, interval: 60),
      "A new address hides old details and looks up again")
let stale = state.lookingUp(at: 1)
state.trace(NetworkLocation(ip: "9.9.9.9", country: "US", colo: "SJC"))
state.found(details, for: stale)
check(state.location?.city == nil, "A lookup for an older address is dropped")
var pacer = LookupPacer()
check(pacer.allows(at: 0), "The first lookup goes out at once")
pacer.record(at: 0)
check(!pacer.allows(at: LookupPacer.gap - 1) && pacer.allows(at: LookupPacer.gap), "Lookups stay apart")

// Ping history
var pings = PingHistory()
check(pings.summary(interval: 5) == "Last 10 min" && pings.average == nil, "Empty history")
pings.record(PingSample(time: 1, latency: 0.2))
pings.record(PingSample(time: 2, latency: nil))
pings.record(PingSample(time: 3, latency: 0.4))
check(pings.lost == 1 && pings.average.map { abs($0 - 0.3) < 1e-9 } == true, "Loss and average ignore lost pings in the average")
check(pings.summary(interval: 5) == "Last 10 min · avg 300 ms · 1 lost", "History summary")
for index in 0..<300 { pings.record(PingSample(time: Double(index), latency: 0.1)) }
check(pings.samples.count == PingHistory.capacity && pings.lost == 0, "History is bounded and old losses age out")
check(pings.summary(interval: 5).hasSuffix("no loss"), "No loss")
check(TimeTick.ago(1) == "Now" && TimeTick.ago(25) == "25 s ago" && TimeTick.ago(120) == "2 min ago" && TimeTick.ago(185) == "3 min 5 s ago",
      "Ages")

print("All \(checks) checks passed")
