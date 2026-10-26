import Foundation

// A metric's detail sheet as GET /api/metric/:key answers it (MetricSheet in shared/metrics.ts), and the rules the web's
// sheet follows with it: when an empty window moves to a longer range, what it says then, and its source line. Ported
// from shared/metrics.ts and src/components/MetricSheet.tsx, case for case (MetricSheetTests).

/// One figure on the sheet: a value with its unit, and what it is (its date, or a note such as "so far today").
struct MetricFigure: Codable, Equatable {
    var label: String
    var value: Double?
    var unit: String
    var date: String?
    var note: String?

    init(label: String, value: Double?, unit: String, date: String? = nil, note: String? = nil) {
        self.label = label
        self.value = value
        self.unit = unit
        self.date = date
        self.note = note
    }

    private enum CodingKeys: String, CodingKey { case label, value, unit, date, note }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = (try? c.decodeIfPresent(String.self, forKey: .label)) ?? ""
        value = (try? c.decodeIfPresent(Double.self, forKey: .value)).flatMap { $0 }
        unit = (try? c.decodeIfPresent(String.self, forKey: .unit)) ?? ""
        date = (try? c.decodeIfPresent(String.self, forKey: .date)).flatMap { $0 }.flatMap(SheetDate.valid)
        note = (try? c.decodeIfPresent(String.self, forKey: .note)).flatMap { $0 }
    }
}

/// Where the latest reading sits, in the words the dashboard's cards use for it ("Within your usual", "High zone, 67–100").
struct MetricStatus: Codable, Equatable {
    let text: String
    /// "below", "within", "above", "at_or_above" or "band".
    let position: String
}

/// A sheet's window, as the server sends it. Only the metric, its range and the headline are needed: an older server
/// leaves later fields out (everMeasured missing means measured), and a field that can't be read is left empty rather
/// than failing the sheet.
struct MetricSheetData: Decodable {
    /// What one chart point is: an hour (Day), a day (Week, Month), or a week's average of its days (Year).
    enum Resolution: String {
        case hour, day, week
    }

    let key: MetricKey
    /// The stored metric behind the sheet (HRV: hrv_rmssd or hrv_sdnn); nil for heart rate by the hour.
    var metric: String?
    var label: String
    /// In the person's units (lb for a mass on imperial).
    var unit: String
    var digits: Int
    var range: MetricRange
    /// The ranges this person has: Day only once their phone has sent hours.
    var ranges: [MetricRange]
    /// The window shown, first and last day (the same day for a Day range).
    var from: String
    var to: String
    var today: String
    var resolution: Resolution
    /// Daily values for Week and Month; weekly averages (each dated its Monday) for Year; empty for Day.
    var points: [Point]
    /// The Day range's hours, as GET /api/day gives them for this one metric.
    var day: DayData?
    /// Which devices the values in the window came from ("apple", "whoop", "manual", "demo").
    var sources: [String]
    /// Days with a value in the window.
    var days: Int
    /// A daily total whose today isn't over: drawn, but left out of the figures.
    var partialToday: Bool
    /// The big number: the window's average, or a day's total so far.
    var headline: MetricFigure
    /// Lowest, highest and latest (or a Day's own three).
    var tiles: [MetricFigure]
    /// The latest reading as the card shows it (it may be older than the window).
    var latest: Point?
    var status: MetricStatus?
    /// Steps: the daily goal, for the chart's goal line.
    var goal: Double?
    /// One plain sentence the server builds from the figures.
    var narrative: String?
    /// false: never measured at all, "No measurement yet". nil (an older server) counts as measured.
    var everMeasured: Bool?

    init(key: MetricKey, metric: String? = nil, unit: String? = nil, digits: Int? = nil, range: MetricRange, ranges: [MetricRange]? = nil,
         from: String = "", to: String = "", today: String = "", resolution: Resolution? = nil, points: [Point] = [], day: DayData? = nil,
         sources: [String] = [], days: Int = 0, partialToday: Bool = false, headline: MetricFigure, tiles: [MetricFigure] = [],
         latest: Point? = nil, status: MetricStatus? = nil, goal: Double? = nil, narrative: String? = nil, everMeasured: Bool? = nil) {
        let info = key.info
        self.key = key
        self.metric = metric
        label = info.label
        self.unit = unit ?? info.unit
        self.digits = digits ?? info.digits
        self.range = range
        self.ranges = ranges ?? info.ranges
        self.from = from
        self.to = to
        self.today = today
        self.resolution = resolution ?? Self.resolution(of: range)
        self.points = points
        self.day = day
        self.sources = sources
        self.days = days
        self.partialToday = partialToday
        self.headline = headline
        self.tiles = tiles
        self.latest = latest
        self.status = status
        self.goal = goal
        self.narrative = narrative
        self.everMeasured = everMeasured
    }

    private static func resolution(of range: MetricRange) -> Resolution {
        switch range {
        case .day: .hour
        case .year: .week
        case .week, .month: .day
        }
    }

    private enum CodingKeys: String, CodingKey {
        case key, metric, label, unit, digits, range, ranges, from, to, today, resolution, points, day, sources, days, partialToday
        case headline, tiles, latest, status, goal, narrative, everMeasured
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let key = MetricKey(rawValue: try c.decode(String.self, forKey: .key)) else {
            throw DecodingError.dataCorruptedError(forKey: .key, in: c, debugDescription: "Unknown metric")
        }
        guard let range = MetricRange(rawValue: try c.decode(String.self, forKey: .range)) else {
            throw DecodingError.dataCorruptedError(forKey: .range, in: c, debugDescription: "Unknown range")
        }
        let info = key.info
        self.key = key
        self.range = range
        headline = try c.decode(MetricFigure.self, forKey: .headline)
        func text(_ k: CodingKeys) -> String? { (try? c.decodeIfPresent(String.self, forKey: k)).flatMap { $0 } }
        metric = text(.metric)
        label = text(.label) ?? info.label
        unit = text(.unit) ?? info.unit
        digits = (try? c.decodeIfPresent(Int.self, forKey: .digits)).flatMap { $0 } ?? info.digits
        let offered = ((try? c.decodeIfPresent([String].self, forKey: .ranges)).flatMap { $0 } ?? []).compactMap(MetricRange.init(rawValue:))
        ranges = offered.isEmpty ? info.ranges : offered
        from = text(.from).flatMap(SheetDate.valid) ?? ""
        to = text(.to).flatMap(SheetDate.valid) ?? ""
        today = text(.today).flatMap(SheetDate.valid) ?? ""
        resolution = text(.resolution).flatMap(Resolution.init(rawValue:)) ?? Self.resolution(of: range)
        points = try c.decode(LossyArray<Point>.self, forKey: .points).wrappedValue.filter { SheetDate.valid($0.date) != nil }
        day = try c.decode(Lossy<DayData>.self, forKey: .day).wrappedValue
        sources = ((try? c.decodeIfPresent([Lossy<String>].self, forKey: .sources)).flatMap { $0 } ?? []).compactMap(\.wrappedValue)
        days = (try? c.decodeIfPresent(Int.self, forKey: .days)).flatMap { $0 } ?? 0
        partialToday = (try? c.decodeIfPresent(Bool.self, forKey: .partialToday)).flatMap { $0 } ?? false
        tiles = try c.decode(LossyArray<MetricFigure>.self, forKey: .tiles).wrappedValue
        latest = try c.decode(Lossy<Point>.self, forKey: .latest).wrappedValue.flatMap { SheetDate.valid($0.date) == nil ? nil : $0 }
        status = try c.decode(Lossy<MetricStatus>.self, forKey: .status).wrappedValue
        goal = (try? c.decodeIfPresent(Double.self, forKey: .goal)).flatMap { $0 }
        narrative = text(.narrative).flatMap { $0.isEmpty ? nil : $0 }
        everMeasured = (try? c.decodeIfPresent(Bool.self, forKey: .everMeasured)).flatMap { $0 }
    }
}

/// "YYYY-MM-DD" days, checked before they're formatted (a malformed one is dropped, never a crash).
enum SheetDate {
    static func valid(_ day: String) -> String? {
        let parts = day.split(separator: "-", omittingEmptySubsequences: false)
        guard day.count == 10, parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let month = Int(parts[1]), let date = Int(parts[2]), (1...12).contains(month), (1...31).contains(date) else { return nil }
        return day
    }
}

// MARK: - The web's rules (shared/metrics.ts)

extension MetricSheetData {
    /// The range a sheet moves to when the one it opened on has nothing in it: its longest (widerRange). nil to stay: a
    /// Day (which says why it's empty), a window with data, one that's already the longest, or a metric never measured.
    /// A point without a headline is today's unfinished total, drawn but not counted: not an empty window.
    var widerRange: MetricRange? {
        if everMeasured == false || range == .day || headline.value != nil || !points.isEmpty { return nil }
        guard let longest = ranges.last, longest != range else { return nil }
        return longest
    }

    /// What an empty window says when a longer range may have something (emptyWindowText): "Nothing in the last 30 days.
    /// Year shows the last 12 months." nil for a Day or the longest range.
    var emptyWindowText: String? {
        guard range != .day, points.isEmpty, let longest = ranges.last, longest != .day, longest != range,
              let now = range.window, let longer = longest.window else { return nil }
        return "Nothing in \(now). \(longest.label) shows \(longer)."
    }

    /// The note a sheet shows when it moved to a longer range by itself (widenedNote): "Nothing in the last 30 days, so
    /// this shows the last 12 months."
    static func widenedNote(from: MetricRange, to: MetricRange) -> String? {
        guard from != .day, to != .day, from != to, let a = from.window, let b = to.window else { return nil }
        return "Nothing in \(a), so this shows \(b)."
    }

    /// Whether the window the sheet opened on is still empty as this longer range shows it (stillEmpty): no latest
    /// reading, or one from before that window's first day. A reading synced since the move makes the note untrue.
    func stillEmpty(from opened: MetricRange) -> Bool {
        guard let latest else { return true }
        guard SheetDate.valid(to) != nil else { return true }
        return latest.date < Day.add(to, -((opened.days ?? 1) - 1))
    }

    /// Nothing to show for its window (nothingToShow): no average, and no unfinished total for today either.
    var nothingToShow: Bool { headline.value == nil && !partialToday }

    /// Whether this sheet is shown while `asked` is the range asked for (showSheet). Not one about to move to a longer
    /// range by itself, nor, while the range asked for loads, another range's empty one: either would flash "Nothing in
    /// the last 30 days" on the way to a range that has something.
    func shows(asked: MetricRange, picked: Bool) -> Bool {
        range == asked ? picked || widerRange == nil : !nothingToShow
    }

    /// Never measured at all: "No measurement yet", with no ranges to try. An older server doesn't say, and counts as
    /// measured.
    var neverMeasured: Bool { everMeasured == false }

    /// The line over the figures (sourceLine): where the values came from, how HRV was measured, what one day's value is,
    /// and the window's days. "From Apple Health and WHOOP · Oct 1 – Oct 30, 2026".
    var sourceLine: String {
        // Devices are "From …"; entries the person typed in are said apart: "From Apple Health, and added by you".
        let names = sources.filter { $0 != "manual" }.map { SheetWords.sources[$0] ?? $0 }
        let devices = names.isEmpty ? "" : "From \(names.joined(separator: " and "))"
        let origin = sources.contains("manual") ? (devices.isEmpty ? SheetWords.sources["manual"]! : "\(devices), and added by you") : devices
        let method = key == .hrv ? (metric == "hrv_sdnn" ? "SDNN, from Apple Watch" : "RMSSD, measured during sleep") : ""
        var span = ""
        if SheetDate.valid(from) != nil, SheetDate.valid(to) != nil {
            span = from == to
                ? Fmt.day(from, "EEEMMMdyyyy")
                : "\(Fmt.day(from, from.prefix(4) == to.prefix(4) ? "MMMd" : "MMMdyyyy")) – \(Fmt.day(to, "MMMdyyyy"))"
        }
        return [origin, method, SheetWords.dayNotes[key] ?? "", span].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// The line where the figures would be, for a window with nothing to show.
    var emptyMessage: String {
        if range == .day, day?.metrics[key.rawValue] == nil { return SheetWords.noHours }
        return emptyWindowText ?? SheetWords.empty[key] ?? SheetWords.nothingRecorded
    }
}

/// Which range the sheet shows, and why (the web sheet's range, picked and widened, with its two effects).
struct SheetRanges: Equatable {
    let key: MetricKey
    private(set) var range: MetricRange
    /// Set once the person presses a range: from then on the sheet shows the one they chose, empty or not.
    private(set) var picked = false
    /// The range it opened on, when it moved to a longer one by itself because that one had nothing in it.
    private(set) var widened: MetricRange?

    /// Opens on the range asked for when the metric has it, else its own default.
    init(key: MetricKey, asked: MetricRange?) {
        self.key = key
        let info = key.info
        range = asked.flatMap { info.ranges.contains($0) ? $0 : nil } ?? info.initial
    }

    mutating func pick(_ range: MetricRange) {
        picked = true
        self.range = range
    }

    /// A sheet arrived. Only one that's current and for the range on screen moves anything: a range this person doesn't
    /// have (Day, before the phone has sent hours) falls back to the first one they do, and an empty one, until the
    /// person picks a range themselves, moves to the longest. The card may show a reading older than the window (a
    /// weigh-in two months ago), which the sheet shouldn't deny. An older copy kept from before a sync may be empty
    /// where the window now isn't, so it never moves the range.
    mutating func heard(_ sheet: MetricSheetData, current: Bool) {
        guard sheet.key == key, sheet.range == range, current else { return }
        if !sheet.ranges.contains(range) {
            if let first = sheet.ranges.first { range = first }
            return
        }
        if !picked, let wider = sheet.widerRange {
            widened = range
            range = wider
        }
    }

    /// Why a range the person didn't press is the pressed one, said only while the range shown bears it out.
    func note(shown: MetricSheetData?) -> String? {
        guard let widened, !picked, let shown, shown.range == range, shown.stillEmpty(from: widened) else { return nil }
        return MetricSheetData.widenedNote(from: widened, to: range)
    }
}

// MARK: - Formatting (formatter, tickFormatter and bigValue in MetricSheet.tsx)

/// A sheet's values as the cards write them.
struct SheetFormat {
    let key: MetricKey
    let unit: String
    let digits: Int

    init(key: MetricKey, unit: String, digits: Int) {
        self.key = key
        self.unit = unit
        self.digits = digits
    }

    init(_ sheet: MetricSheetData) { self.init(key: sheet.key, unit: sheet.unit, digits: sheet.digits) }

    /// A value with its unit: "54 bpm", "96.5%", "7h 05m", "8,400 steps", "12.4" (strain has none).
    func value(_ v: Double) -> String {
        if key.info.duration { return Self.hoursMinutes(v) }
        let n = Self.number(v, digits)
        return unit == "%" ? "\(n)%" : unit.isEmpty ? n : "\(n) \(unit)"
    }

    /// An axis label: steps and energy compact (8K), the rest with at least the decimals the tick step needs, so 0.25
    /// steps don't round to repeated or wrong labels. Sleep is in hours, with the step's decimals too: the web writes
    /// whole hours, which repeats a label on half-hour steps ("8h, 8h, 7h").
    func tick(_ v: Double, step: Double?) -> String {
        if key.info.duration { return "\(Self.number(v, Self.stepDigits(step)))h" }
        if key == .steps || key == .activeEnergy { return Self.compact(v) }
        return Self.number(v, max(digits != 0 && abs(v) < 100 ? 1 : 0, Self.stepDigits(step)))
    }

    /// The big number and its unit, set smaller as on the cards; sleep is all one ("7h 05m"), and a missing value "—".
    func big(_ figure: MetricFigure) -> (value: String, unit: String?) {
        guard let v = figure.value else { return (String.emptyValue, nil) }
        if key.info.duration { return (Self.hoursMinutes(v), nil) }
        return (Self.number(v, digits), figure.unit.isEmpty ? nil : figure.unit == "%" ? "%" : figure.unit)
    }

    /// A tile's value: in the sheet's unit as the cards write it, or its own ("5 hours").
    func tile(_ figure: MetricFigure) -> String {
        guard let v = figure.value else { return String.emptyValue }
        return figure.unit == unit ? value(v) : "\(Self.number(v)) \(figure.unit)"
    }

    /// A number as the web and the server write it (toLocaleString): grouped, with these decimals, a half rounded away
    /// from zero, so a figure reads as it does in the server's sentence beside it (68.5 ms is "69 ms" in both).
    static func number(_ value: Double, _ digits: Int = 0) -> String {
        let f = numberFormatters[digits] ?? {
            let f = NumberFormatter()
            f.numberStyle = .decimal
            f.minimumFractionDigits = digits
            f.maximumFractionDigits = digits
            f.roundingMode = .halfUp
            numberFormatters[digits] = f
            return f
        }()
        return f.string(from: NSNumber(value: value)) ?? String(value)
    }

    private static var numberFormatters: [Int: NumberFormatter] = [:]

    /// 12,400 -> "12.4K"; 10,000 -> "10K" (compact in src/lib.ts).
    static func compact(_ value: Double) -> String {
        abs(value) >= 1000 ? number(value / 1000, value.truncatingRemainder(dividingBy: 1000) == 0 ? 0 : 1) + "K" : number(value)
    }

    /// 7.42 hours -> "7h 25m"; 0.75 -> "45m"; rounded to the minute first, so 59.6 minutes is "1h 00m" (duration in
    /// src/lib.ts).
    static func hoursMinutes(_ hours: Double) -> String {
        let total = Int((hours * 60).rounded())
        let h = total / 60, m = total % 60
        return h != 0 ? "\(h)h \(String(format: "%02d", m))m" : "\(m)m"
    }

    /// Decimals a tick step needs (stepDigits in src/charts/core.tsx): 0.5 needs one, 0.25 two.
    static func stepDigits(_ step: Double?) -> Int {
        guard let step, step != 0, step.isFinite else { return 0 }
        var text = String(format: "%.10f", step)
        while text.hasSuffix("0") { text.removeLast() }
        guard let dot = text.firstIndex(of: ".") else { return 0 }
        return text.distance(from: dot, to: text.endIndex) - 1
    }

    /// "2 PM" (the phone's own form) for hour 0–24; 24 is midnight at the end of the day (hourLabel in src/charts/day.ts).
    static func hourLabel(_ h: Int) -> String {
        hourFormatter.string(from: Date(timeIntervalSince1970: 946_684_800 + Double(((h % 24) + 24) % 24) * 3600))
    }

    /// "2 PM–3 PM" for the hour starting at h.
    static func hourSpan(_ h: Int) -> String { "\(hourLabel(h))–\(hourLabel(h + 1))" }

    private static let hourFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.setLocalizedDateFormatFromTemplate("j")
        return f
    }()
}

/// The chart maths the web's charts share (src/charts/core.tsx).
enum SheetMath {
    /// Clean axis ticks: 1, 2, 2.5 or 5 times a power of ten (niceTicks).
    static func niceTicks(_ low: Double, _ high: Double, count: Double = 4) -> [Double] {
        guard low.isFinite, high.isFinite else { return [] }
        var lo = low, hi = high
        if lo == hi {
            lo -= 1
            hi += 1
        }
        let raw = (hi - lo) / count
        let power = pow(10, floor(log10(raw)))
        let step = [1, 2, 2.5, 5, 10].map { $0 * power }.first { $0 >= raw } ?? raw
        var out: [Double] = []
        var t = floor(lo / step) * step
        while t <= hi + step * 0.001 {
            out.append(Double(String(format: "%.10f", t)) ?? t)
            t += step
        }
        if let last = out.last, last < hi { out.append(last + step) }
        return out
    }

    /// The middle value (the mean of the two middle values for an even count); nil when there are none.
    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        let mid = s.count / 2
        return s.count % 2 == 1 ? s[mid] : (s[mid - 1] + s[mid]) / 2
    }

    /// Fewer points than this and a "typical" level means little, so no median line is drawn (MEDIAN_MIN_POINTS).
    static let medianMinPoints = 5

    /// The x-axis labels' points (xLabels in src/charts/Charts.tsx): two to six, evenly spread by index, one per 90 points
    /// of width; a span over 200 days is labelled by month and year.
    static func xLabels(_ dates: [String], width: CGFloat) -> [(index: Int, text: String)] {
        guard let first = dates.first, let last = dates.last else { return [] }
        let span = Fmt.daysBetween(first, last)
        let count = max(2, min(6, Int((width / 90).rounded(.down))))
        var out: [(index: Int, text: String)] = []
        for k in 0..<count {
            let i = Int((Double(k) / Double(count - 1) * Double(dates.count - 1)).rounded())
            if !out.contains(where: { $0.index == i }) { out.append((i, Fmt.day(dates[i], span > 200 ? "MMMyy" : "MMMd"))) }
        }
        return out
    }

    /// Where the line breaks: points further apart than `gapDays` start a new run, numbered from 0.
    static func runs(_ points: [Point], gapDays: Int) -> [Int] {
        var out: [Int] = []
        var run = 0
        for (i, p) in points.enumerated() {
            if i > 0, Fmt.daysBetween(points[i - 1].date, p.date) > gapDays { run += 1 }
            out.append(run)
        }
        return out
    }
}

/// "Open Vitals", "Open Recovery on Body": the card's own page, named (pageName in MetricSheet.tsx).
enum SheetPage {
    static func name(_ route: AppRoute) -> String {
        let page = route.page.title
        guard let tab = route.query["tab"], let first = tab.first else { return page }
        return "\(first.uppercased())\(tab.dropFirst()) on \(page)"
    }
}

extension Dashboard {
    /// The page on screen under the sheet, as the web reads its address: the top page pushed on this tab, else the tab's
    /// own page with the query its last link carried. nil under More's list, which is no page of the web's.
    var pageOnScreen: AppRoute? {
        if let top = paths[tab]?.last { return top }
        let page: AppPage? = switch tab {
        case .home: .home
        case .vitals: .vitals
        case .body: .body
        case .nutrition: .nutrition
        case .more, .settings: nil
        }
        guard let page else { return nil }
        return requests[page]?.route ?? AppRoute(page)
    }
}
