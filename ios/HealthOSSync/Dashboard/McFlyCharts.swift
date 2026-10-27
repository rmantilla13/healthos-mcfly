import Charts
import SwiftUI

// McFly's charts: the pictures in an answer (the SSE `visual` event from server/mcfly.ts, McflyVisual in
// shared/types.ts, drawn on the web by src/components/McflyVisual.tsx). The server read every number from the
// person's own data, in their units; this only draws them.

enum McFlyVisual: Equatable {
    case series(Series)
    case compare(Compare)
    case stats(Stats)
    case stages(Stages)
    case sports(Sports)

    /// kind "trend" (a line) or "bars": one value per day, or weekly averages over a long range.
    struct Series: Equatable {
        enum Style: String { case trend, bars }
        var style: Style
        var title: String
        var unit: String
        /// "day", "week" or "month"; anything but "day" is a period average, like the web.
        var resolution: String
        var points: [Point]
        /// The average of the daily values (weekly charts too), over `days` days.
        var mean: Double?
        var days: Int?
        /// A daily total whose today isn't over: left out of the average, drawn lighter.
        var partialToday: Bool
        var goal: Double?

        var weekly: Bool { resolution != "day" }
    }

    struct Compare: Equatable {
        struct Period: Equatable {
            var label: String
            var from: String
            var to: String
            var mean: Double?
            var days: Int
            var partialToday: Bool
        }
        var title: String
        var unit: String
        var periods: [Period]
    }

    struct Stats: Equatable {
        struct Item: Equatable {
            var label: String
            var value: Double?
            var unit: String
            /// "average of 7 days", "No data", or the day of the latest reading (YYYY-MM-DD).
            var note: String
            var from: String?
            var to: String?
        }
        var title: String
        var items: [Item]
    }

    /// Hours of each sleep stage per night, keyed sleep_deep, sleep_light, sleep_rem, sleep_awake.
    struct Stages: Equatable {
        struct Night: Equatable {
            var date: String
            var values: [String: Double]
        }
        var title: String
        var rows: [Night]
    }

    struct Sports: Equatable {
        struct Item: Equatable {
            var sport: String
            var count: Int
            var minutes: Double
        }
        var title: String
        var items: [Item]
    }

    var title: String {
        switch self {
        case .series(let v): v.title
        case .compare(let v): v.title
        case .stats(let v): v.title
        case .stages(let v): v.title
        case .sports(let v): v.title
        }
    }

    /// The one line a chart leaves in the conversation McFly reads back next time (visualNote on the web).
    var note: String { "[Showed a chart: \(title)]" }

    /// It needs a row's width to itself: a chart along the days, or more tiles than two. On the open iPhone Duo, where
    /// what McFly showed sits beside the conversation in two columns, these take both columns and the rest (a
    /// comparison, a list of sports, one or two tiles) go two to a row.
    var wide: Bool {
        switch self {
        case .series, .stages: true
        case .stats(let v): v.items.count > 2
        case .compare, .sports: false
        }
    }

    /// The order and colours the stage charts use everywhere (STAGES in src/pages/Detail.tsx).
    static let stageKeys: [(key: String, label: String, color: Color)] = [
        ("sleep_deep", "Deep", Palette.stageDeep),
        ("sleep_light", "Light / core", Palette.stageLight),
        ("sleep_rem", "REM", Palette.stageRem),
        ("sleep_awake", "Awake", Palette.stageAwake),
    ]

    private static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// A real "YYYY-MM-DD" day. The date helpers the charts use trap on anything else, so a newer or odd server
    /// can't crash the app: what doesn't pass is left out.
    static func isDay(_ s: String) -> Bool {
        s.utf8.count == 10 && s.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil && dayParser.date(from: s) != nil
    }
}

// MARK: - Decoding

/// Decodes leniently: a kind this app doesn't know, or a known kind with nothing drawable, throws (the caller
/// drops the visual and the stream carries on); a single bad point, row or tile is left out on its own.
extension McFlyVisual: Decodable {
    private enum Keys: String, CodingKey {
        case kind, title, unit, resolution, points, mean, days, partialToday, goal, periods, items, rows
    }

    private struct Unreadable: Error {}

    /// One element of an array that may not decode, so one bad element doesn't sink the rest.
    private struct Lossy<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }

    private struct RawPoint: Decodable { let date: String; let value: Double }
    private struct RawPeriod: Decodable { let label: String?; let from: String; let to: String; let mean: Double?; let days: Double?; let partialToday: Bool? }
    private struct RawStat: Decodable { let label: String; let value: Double?; let unit: String?; let note: String?; let from: String?; let to: String? }
    private struct RawNight: Decodable { let date: String; let values: [String: Lossy<Double>]? }
    private struct RawSport: Decodable { let sport: String; let count: Double?; let minutes: Double? }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        let title = try c.decode(String.self, forKey: .title)
        func list<T: Decodable>(_ key: Keys, _ type: T.Type) -> [T] {
            ((try? c.decodeIfPresent([Lossy<T>].self, forKey: key)) ?? nil)?.compactMap(\.value) ?? []
        }
        let unit = (try? c.decodeIfPresent(String.self, forKey: .unit)) ?? nil

        switch kind {
        case "trend", "bars":
            let points = list(.points, RawPoint.self).filter { Self.isDay($0.date) }.map { Point(date: $0.date, value: $0.value) }
            guard !points.isEmpty else { throw Unreadable() }
            let days = (try? c.decodeIfPresent(Double.self, forKey: .days)) ?? nil
            let goal = (try? c.decodeIfPresent(Double.self, forKey: .goal)) ?? nil
            self = .series(Series(
                style: kind == "bars" ? .bars : .trend,
                title: title,
                unit: unit ?? "",
                resolution: ((try? c.decodeIfPresent(String.self, forKey: .resolution)) ?? nil) ?? "day",
                points: points,
                mean: (try? c.decodeIfPresent(Double.self, forKey: .mean)) ?? nil,
                days: days.map { Int($0.rounded()) },
                partialToday: ((try? c.decodeIfPresent(Bool.self, forKey: .partialToday)) ?? nil) ?? false,
                goal: goal.flatMap { $0 > 0 ? $0 : nil }
            ))
        case "compare":
            let periods = list(.periods, RawPeriod.self).filter { Self.isDay($0.from) && Self.isDay($0.to) }.enumerated().map { i, p in
                Compare.Period(label: p.label ?? "Period \(i + 1)", from: p.from, to: p.to, mean: p.mean, days: Int((p.days ?? 0).rounded()), partialToday: p.partialToday ?? false)
            }
            guard !periods.isEmpty else { throw Unreadable() }
            self = .compare(Compare(title: title, unit: unit ?? "", periods: periods))
        case "stats":
            let items = list(.items, RawStat.self).map { s in
                Stats.Item(label: s.label, value: s.value, unit: s.unit ?? "", note: s.note ?? "",
                           from: s.from.flatMap { Self.isDay($0) ? $0 : nil }, to: s.to.flatMap { Self.isDay($0) ? $0 : nil })
            }
            guard !items.isEmpty else { throw Unreadable() }
            self = .stats(Stats(title: title, items: items))
        case "stages":
            let rows = list(.rows, RawNight.self).filter { Self.isDay($0.date) }.map { r in
                Stages.Night(date: r.date, values: (r.values ?? [:]).compactMapValues(\.value))
            }
            guard !rows.isEmpty else { throw Unreadable() }
            self = .stages(Stages(title: title, rows: rows))
        case "sports":
            let items = list(.items, RawSport.self).map { s in
                Sports.Item(sport: s.sport, count: Int((s.count ?? 0).rounded()), minutes: max(0, s.minutes ?? 0))
            }
            guard !items.isEmpty else { throw Unreadable() }
            self = .sports(Sports(title: title, items: items))
        default:
            // From a newer server: leave it out.
            throw Unreadable()
        }
    }
}

// MARK: - Formatting

/// How a unit's values read, the same as formats() in src/components/McflyVisual.tsx: hours as "7h 24m", per-unit
/// decimals (a fever of 100.4 °F keeps its .4), and axis ticks with a decimal only when the range is narrow.
struct McFlyFormat {
    let value: (Double) -> String
    let tick: (Double) -> String

    static let oneDecimal: Set<String> = ["°C", "°F", "kg", "lb", "km", "mi", "mph", "km/h", "breaths/min", "mL/kg/min"]
    static let whole: Set<String> = ["steps", "kcal", "bpm", "min", "mL", "ms", "mg", "flights", "hours", "mmHg", "mg/dL"]

    init(unit: String, values: [Double]) {
        let range = (values.max() ?? 0) - (values.min() ?? 0)
        if unit == "h" {
            value = { Self.hoursMinutes($0) }
            tick = { range < 3 ? "\(Fmt.number($0, 1))h" : "\(Fmt.number($0))h" }
            return
        }
        let decimals = Self.oneDecimal.contains(unit) ? 1 : Self.whole.contains(unit) ? 0 : values.contains { $0.rounded() != $0 } ? 1 : 0
        let suffix = unit.isEmpty ? "" : unit == "%" ? "%" : " \(unit)"
        let biggest = values.map(abs).max() ?? 0
        value = { "\(Fmt.number($0, decimals))\(suffix)" }
        tick = { biggest >= 10_000 ? Fmt.compact($0) : Fmt.number($0, range < 5 ? Swift.max(decimals, 1) : 0) }
    }

    /// "7h 24m", rounded to the minute first so 6.9999 h reads "7h 00m", not "6h 60m".
    static func hoursMinutes(_ hours: Double) -> String { duration(minutes: hours * 60) }
    static func duration(minutes: Double) -> String { Fmt.duration(minutes: Swift.max(0, minutes.rounded())) }

    static func plural(_ n: Int, _ one: String, _ many: String) -> String { "\(Fmt.number(Double(n))) \(n == 1 ? one : many)" }
    /// "Tue, Mar 3"
    static func dayLabel(_ day: String) -> String { Fmt.day(day, "EEEMMMd") }
    static func weekLabel(_ day: String) -> String { "Week of \(Fmt.day(day))" }
    static func monthLabel(_ day: String) -> String { Fmt.day(day, "yMMMM") }
}

extension McFlyVisual.Series {
    /// The line under the headline, word for word the web's.
    var note: String {
        let n = days ?? points.count
        let first = weekly ? "daily average over \(McFlyFormat.plural(n, "day", "days")) · shown as \(resolution == "month" ? "monthly" : "weekly") averages"
                           : "average of \(McFlyFormat.plural(n, "day", "days"))"
        return partialToday ? "\(first) · today isn't counted until it's over" : first
    }

    func periodLabel(_ day: String) -> String {
        resolution == "month" ? McFlyFormat.monthLabel(day) : weekly ? McFlyFormat.weekLabel(day) : McFlyFormat.dayLabel(day)
    }

    /// What VoiceOver reads for the whole chart.
    func summary(_ f: McFlyFormat) -> String {
        var parts: [String] = []
        if let mean { parts.append("\(f.value(mean)), \(note)") } else { parts.append(note.prefix(1).uppercased() + String(note.dropFirst())) }
        if let lo = points.min(by: { $0.value < $1.value }), let hi = points.max(by: { $0.value < $1.value }), points.count > 1 {
            parts.append("Lowest \(f.value(lo.value)), \(periodLabel(lo.date)). Highest \(f.value(hi.value)), \(periodLabel(hi.date))")
        }
        if let last = points.last { parts.append("Latest \(f.value(last.value)), \(periodLabel(last.date))\(partialToday ? ", so far" : "")") }
        if let goal { parts.append("Goal \(f.value(goal))") }
        return parts.joined(separator: ". ") + "."
    }

    /// Runs of points without a gap longer than `gapDays`: the line breaks across missing stretches, like the web.
    static func runs(_ points: [Point], gapDays: Int) -> [[Point]] {
        var out: [[Point]] = []
        for p in points {
            if let prev = out.last?.last, Fmt.daysBetween(prev.date, p.date) <= gapDays { out[out.count - 1].append(p) } else { out.append([p]) }
        }
        return out
    }

    var gapDays: Int { resolution == "month" ? 40 : weekly ? 10 : 3 }
}

extension McFlyVisual.Compare {
    /// The first period against the second, in percent; nil when either has no data.
    var change: Double? {
        guard periods.count == 2, let a = periods[0].mean, let b = periods[1].mean, b != 0 else { return nil }
        return (a - b) / abs(b) * 100
    }
}

extension McFlyVisual.Compare.Period {
    var caption: String {
        "\(Fmt.day(from)) – \(Fmt.day(to)) · \(McFlyFormat.plural(days, "day", "days")) with data" + (partialToday ? " · today isn't counted yet" : "")
    }
}

extension McFlyVisual.Stats.Item {
    var caption: String {
        if McFlyVisual.isDay(note) { return McFlyFormat.dayLabel(note) }
        if let from, let to, value != nil { return "\(note), \(Fmt.day(from)) – \(Fmt.day(to))" }
        return note
    }
}

// MARK: - Views

private struct McFlyChartTouchedKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    /// Called while a finger is on one of McFly's charts, so the thread stops scrolling it away to follow new text.
    var mcflyChartTouched: () -> Void {
        get { self[McFlyChartTouchedKey.self] }
        set { self[McFlyChartTouchedKey.self] = newValue }
    }
}

/// One of McFly's pictures, as its own card between the answer's paragraphs.
struct McFlyVisualView: View {
    let visual: McFlyVisual

    var body: some View {
        switch visual {
        case .series(let v): SeriesCard(series: v)
        case .compare(let v): CompareCard(compare: v)
        case .stats(let v): StatsCard(stats: v)
        case .stages(let v): StagesCard(stages: v)
        case .sports(let v): SportsCard(sports: v)
        }
    }
}

private struct CardTitle: View {
    let text: String
    var body: some View {
        Text(text).font(.app(.subheadline, weight: .medium)).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true)
    }
}

private func yAxis(_ f: McFlyFormat) -> some AxisContent {
    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { v in
        AxisGridLine().foregroundStyle(Palette.grid)
        AxisValueLabel { if let n = v.as(Double.self) { Text(f.tick(n)).font(.axis).foregroundStyle(Palette.ink3) } }
    }
}

private func dateAxis(monthly: Bool) -> some AxisContent {
    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
        if monthly {
            AxisValueLabel(format: .dateTime.month(.abbreviated).year(.twoDigits)).font(.axis).foregroundStyle(Palette.ink3)
        } else {
            AxisValueLabel(format: .dateTime.month(.abbreviated).day()).font(.axis).foregroundStyle(Palette.ink3)
        }
    }
}

// MARK: trend and bars

private struct SeriesCard: View {
    let series: McFlyVisual.Series
    @State private var selected: Date?
    @Environment(\.mcflyChartTouched) private var touched

    private var format: McFlyFormat { McFlyFormat(unit: series.unit, values: series.points.map(\.value)) }

    var body: some View {
        let f = format
        VStack(alignment: .leading, spacing: 6) {
            CardTitle(text: series.title)
            if let mean = series.mean {
                Text(f.value(mean)).font(.app(.title2, weight: .semibold)).foregroundStyle(Palette.ink).monospacedDigit()
            }
            Text(series.note).font(.app(.caption)).foregroundStyle(Palette.ink3).fixedSize(horizontal: false, vertical: true)
            chart(f).duoChartHeight(170).padding(.top, 6)
        }
        .card()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(series.style == .bars ? "Bar chart: \(series.title)" : "Line chart: \(series.title)")
        .accessibilityValue(series.summary(f))
    }

    private struct Plot: Identifiable {
        let point: Point
        let run: String
        var id: String { point.date }
    }

    private var unit: Calendar.Component { series.resolution == "month" ? .month : series.weekly ? .weekOfYear : .day }

    private func domain(_ extra: [Double]) -> ClosedRange<Double> {
        let values = series.points.map(\.value) + extra
        let lo = values.min() ?? 0, hi = values.max() ?? 1
        let pad = Swift.max((hi - lo) * 0.15, Swift.max(abs(hi) * 0.02, 0.5))
        if series.style == .bars { return Swift.min(0, lo)...(hi + pad) }
        let bottom = lo >= 0 ? Swift.max(0, lo - pad) : lo - pad
        return bottom...(hi + pad)
    }

    @ViewBuilder
    private func chart(_ f: McFlyFormat) -> some View {
        let points = series.points
        let partial = series.partialToday ? points.last : nil
        let solid = partial == nil ? points : Array(points.dropLast())
        let domain = domain([series.mean, series.goal].compactMap { $0 })
        let picked = selected.flatMap { s in points.min { abs(Fmt.chartDate($0.date).timeIntervalSince(s)) < abs(Fmt.chartDate($1.date).timeIntervalSince(s)) } }
        let runs = McFlyVisual.Series.runs(solid, gapDays: series.gapDays)
        let plots = runs.enumerated().flatMap { i, run in run.map { Plot(point: $0, run: "run\(i)") } }
        let lone = Set(runs.filter { $0.count == 1 }.map { $0[0].date })

        Chart {
            if series.style == .bars {
                ForEach(points) { p in
                    let isLast = p.date == points.last?.date
                    let accent = series.goal.map { p.value >= $0 } ?? isLast
                    BarMark(x: .value("Date", Fmt.chartDate(p.date), unit: unit), y: .value(series.title, p.value))
                        .foregroundStyle(accent ? Palette.series1 : Palette.bar)
                        .opacity(partial != nil && isLast ? 0.4 : 1)
                        .cornerRadius(3)
                }
            } else {
                ForEach(plots) { p in
                    AreaMark(x: .value("Date", Fmt.chartDate(p.point.date)), yStart: .value("Base", domain.lowerBound), yEnd: .value(series.title, p.point.value), series: .value("Run", p.run))
                        .foregroundStyle(LinearGradient(colors: [Palette.series1.opacity(0.22), Palette.series1.opacity(0)], startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Date", Fmt.chartDate(p.point.date)), y: .value(series.title, p.point.value), series: .value("Run", p.run))
                        .foregroundStyle(Palette.series1)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                        .interpolationMethod(.monotone)
                    if lone.contains(p.point.date) {
                        PointMark(x: .value("Date", Fmt.chartDate(p.point.date)), y: .value(series.title, p.point.value))
                            .foregroundStyle(Palette.series1)
                            .symbolSize(24)
                    }
                }
                if let partial {
                    // Today so far: a dashed step to an open dot, since the day isn't over.
                    if let prev = solid.last, Fmt.daysBetween(prev.date, partial.date) <= series.gapDays {
                        ForEach([prev, partial]) { p in
                            LineMark(x: .value("Date", Fmt.chartDate(p.date)), y: .value(series.title, p.value), series: .value("Run", "partial"))
                                .foregroundStyle(Palette.series1.opacity(0.7))
                                .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [3, 3]))
                        }
                    }
                    PointMark(x: .value("Date", Fmt.chartDate(partial.date)), y: .value(series.title, partial.value))
                        .symbol {
                            Circle().strokeBorder(Palette.series1, lineWidth: 2)
                                .background(Circle().fill(Palette.surface))
                                .frame(width: 9, height: 9)
                        }
                }
            }
            if let mean = series.mean {
                RuleMark(y: .value("Average", mean))
                    .foregroundStyle(Palette.ink3)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                    .annotation(position: .top, alignment: .leading, spacing: 2) {
                        Text("Average").font(.app(.caption2)).foregroundStyle(Palette.ink3)
                            .padding(.horizontal, 4)
                            .background(Palette.surface.opacity(0.85), in: Capsule())
                    }
            }
            if let goal = series.goal {
                RuleMark(y: .value("Goal", goal))
                    .foregroundStyle(Palette.good)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .annotation(position: .top, alignment: .trailing, spacing: 2) {
                        Text("Goal \(Fmt.compact(goal))").font(.app(.caption2)).foregroundStyle(Palette.goodText)
                            .padding(.horizontal, 4)
                            .background(Palette.surface.opacity(0.85), in: Capsule())
                    }
            }
            if let picked {
                RuleMark(x: series.style == .bars ? .value("Date", Fmt.chartDate(picked.date), unit: unit) : .value("Date", Fmt.chartDate(picked.date)))
                    .foregroundStyle(Palette.ink3.opacity(0.5))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        VStack(spacing: 1) {
                            Text(f.value(picked.value)).font(.app(.caption, weight: .semibold))
                            Text(series.periodLabel(picked.date) + (partial?.date == picked.date ? " · so far" : "")).font(.app(.caption2))
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Palette.surface2, in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(Palette.ink)
                    }
            }
        }
        .chartYScale(domain: domain)
        // A tap or a sideways drag picks a day; up or down scrolls the conversation.
        .chartScrub($selected)
        .chartYAxis { yAxis(f) }
        .chartXAxis { dateAxis(monthly: series.resolution == "month") }
        .chartLegend(.hidden)
        .onChange(of: selected) { _, picked in if picked != nil { touched() } }
    }
}

// MARK: compare and sports: a row per bar, so long names wrap instead of squeezing the bars

/// One bar against a shared scale (0...max), drawn with Swift Charts on a soft track.
private struct TrackBar: View {
    let value: Double
    let max: Double
    let color: Color

    var body: some View {
        Chart {
            BarMark(xStart: .value("Start", 0), xEnd: .value("Track", max), y: .value("Row", "row"), height: .ratio(1))
                .foregroundStyle(Palette.surface2)
                .cornerRadius(5)
            if value > 0 {
                BarMark(xStart: .value("Start", 0), xEnd: .value("Value", Swift.min(value, max)), y: .value("Row", "row"), height: .ratio(1))
                    .foregroundStyle(color)
                    .cornerRadius(5)
            }
        }
        .chartXScale(domain: 0...max)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .frame(height: 10)
        .accessibilityHidden(true)
    }
}

private struct BarRow: View {
    let label: String
    let caption: String
    let value: String
    let amount: Double
    let max: Double
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(.app(.footnote, weight: .medium)).foregroundStyle(Palette.ink)
                    Text(caption).font(.app(.caption2)).foregroundStyle(Palette.ink3)
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Text(value).font(.app(.subheadline, weight: .semibold)).monospacedDigit().foregroundStyle(Palette.ink)
            }
            TrackBar(value: amount, max: max, color: color)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("\(value), \(caption)")
    }
}

private struct CompareCard: View {
    let compare: McFlyVisual.Compare

    var body: some View {
        let f = McFlyFormat(unit: compare.unit, values: compare.periods.map { $0.mean ?? 0 })
        let top = Swift.max(compare.periods.map { abs($0.mean ?? 0) }.max() ?? 0, 1e-9)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                CardTitle(text: compare.title)
                Spacer(minLength: 8)
                if let chip = changeChip { chip }
            }
            ForEach(Array(compare.periods.enumerated()), id: \.offset) { i, p in
                BarRow(label: p.label, caption: p.caption, value: p.mean.map(f.value) ?? "No data",
                       amount: abs(p.mean ?? 0), max: top, color: i == 0 ? Palette.series1 : Palette.bar)
            }
        }
        .card()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(compare.title)
    }

    private var changeChip: AnyView? {
        guard let pct = compare.change, pct.isFinite, abs(pct.rounded()) >= 1 else { return nil }
        let up = pct > 0
        let a = compare.periods[0].label, b = compare.periods[1].label.lowercased()
        let n = Fmt.number(abs(pct.rounded()))
        return AnyView(
            Label("\(n)%", systemImage: up ? "arrow.up.right" : "arrow.down.right")
                .labelStyle(.titleAndIcon)
                .font(.app(.caption, weight: .semibold))
                .monospacedDigit()
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Tone.neutral.background, in: Capsule())
                .foregroundStyle(Tone.neutral.ink)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(a) is \(n)% \(up ? "higher" : "lower") than \(b)")
        )
    }
}

private struct SportsCard: View {
    let sports: McFlyVisual.Sports

    var body: some View {
        let top = Swift.max(sports.items.map(\.minutes).max() ?? 0, 1)
        VStack(alignment: .leading, spacing: 12) {
            CardTitle(text: sports.title)
            ForEach(Array(sports.items.enumerated()), id: \.offset) { _, it in
                BarRow(label: it.sport, caption: McFlyFormat.plural(it.count, "workout", "workouts"),
                       value: McFlyFormat.duration(minutes: it.minutes), amount: it.minutes, max: top, color: Palette.series1)
            }
        }
        .card()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(sports.title)
    }
}

// MARK: stats

private struct StatsCard: View {
    let stats: McFlyVisual.Stats

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardTitle(text: stats.title)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 10)], alignment: .leading, spacing: 10) {
                ForEach(Array(stats.items.enumerated()), id: \.offset) { _, it in
                    let value = it.value.map { McFlyFormat(unit: it.unit, values: [$0]).value($0) } ?? "—"
                    VStack(alignment: .leading, spacing: 3) {
                        Text(it.label).font(.app(.caption)).foregroundStyle(Palette.ink2)
                        Text(value).font(.app(.title3, weight: .medium)).monospacedDigit().foregroundStyle(Palette.ink)
                            .lineLimit(1).minimumScaleFactor(0.7)
                        Text(it.caption).font(.app(.caption2)).foregroundStyle(Palette.ink3).fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(Palette.surface2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(it.label)
                    .accessibilityValue(it.value == nil ? "No data" : "\(value), \(it.caption)")
                }
            }
        }
        .card()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(stats.title)
    }
}

// MARK: sleep stages

private struct StagesCard: View {
    let stages: McFlyVisual.Stages

    private struct Bar: Identifiable {
        let date: String
        let stage: String
        let hours: Double
        var id: String { date + stage }
    }

    private func average(_ key: String) -> Double {
        stages.rows.map { $0.values[key] ?? 0 }.reduce(0, +) / Double(Swift.max(stages.rows.count, 1))
    }

    private var summary: String {
        let each = McFlyVisual.stageKeys.map { "\($0.label) \(McFlyFormat.hoursMinutes(average($0.key)))" }.joined(separator: ", ")
        return "\(McFlyFormat.plural(stages.rows.count, "night", "nights")). Average a night: \(each)."
    }

    var body: some View {
        let keys = McFlyVisual.stageKeys
        let bars = stages.rows.flatMap { r in keys.map { Bar(date: r.date, stage: $0.label, hours: r.values[$0.key] ?? 0) } }
        VStack(alignment: .leading, spacing: 6) {
            CardTitle(text: stages.title)
            Text(McFlyFormat.plural(stages.rows.count, "night", "nights")).font(.app(.caption)).foregroundStyle(Palette.ink3)
            Chart(bars) { b in
                BarMark(x: .value("Night", Fmt.chartDate(b.date), unit: .day), y: .value("Hours", b.hours))
                    .foregroundStyle(by: .value("Stage", b.stage))
            }
            .chartForegroundStyleScale(domain: keys.map(\.label), range: keys.map(\.color))
            .chartLegend(position: .bottom, alignment: .leading) { ChartLegend(keys.map { ($0.label, $0.color) }) }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { v in
                    AxisGridLine().foregroundStyle(Palette.grid)
                    AxisValueLabel { if let h = v.as(Double.self) { Text("\(Fmt.number(h))h").font(.axis).foregroundStyle(Palette.ink3) } }
                }
            }
            .chartXAxis { dateAxis(monthly: false) }
            .duoChartHeight(200)
            .padding(.top, 6)
        }
        .card()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Stacked bar chart: \(stages.title)")
        .accessibilityValue(summary)
    }
}
