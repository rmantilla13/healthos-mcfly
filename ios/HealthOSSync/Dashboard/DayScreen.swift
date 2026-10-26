import Charts
import SwiftUI

// The Day view (src/pages/Detail.tsx DayCard, src/charts/Day.tsx): one day hour by hour next to a typical day,
// from GET /api/day. Home's card ("Steps so far today", named for its metric) pushes it over Home (AppRoute.day).

/// Steps, active energy and heart rate by hour for one day, with a date stepper that never goes past today.
struct DayScreen: View {
    /// The day to open on; nil means today.
    var date: String?
    @Environment(Dashboard.self) private var dashboard
    /// The day on screen; nil means today. Kept here, so stepping days doesn't move Today's own date.
    @State private var picked: String?
    @State private var data: DayData?
    @State private var loaded = false
    @State private var error: String?

    init(date: String? = nil) {
        self.date = date
        _picked = State(initialValue: date)
    }

    var body: some View {
        // The server's today wins (the person's time zone), then the summary's, then the phone's.
        let today = data?.today ?? dashboard.summary?.today ?? Day.today()
        let current = picked ?? today
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header(current: current, today: today)
                if let data, !data.metrics.isEmpty {
                    let stale = data.date != current
                    VStack(spacing: 14) {
                        if let s = data.steps { HoursCard(metric: .steps, series: s, data: data, goal: dashboard.stepGoal) }
                        if let e = data.activeEnergy { HoursCard(metric: .energy, series: e, data: data) }
                        if let hr = data.heartRate { HoursCard(metric: .heart, series: hr, data: data) }
                    }
                    .opacity(stale ? 0.6 : 1)
                    .animation(.easeInOut(duration: 0.2), value: stale)
                } else if let error {
                    Unavailable("Couldn't load this day", systemImage: "chart.xyaxis.line", description: error)
                } else if loaded {
                    Text("No hourly readings yet. They come from the healthOS app on your iPhone, after a sync.")
                        .font(.app(.footnote)).foregroundStyle(Palette.ink3)
                        .card()
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding(16)
        }
        .background(Palette.page)
        .navigationTitle("Day")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .refreshable { await dashboard.load() }
        .task(id: "\(picked ?? "today")|\(dashboard.generation)") {
            do {
                data = try await dashboard.day(date: picked)
                error = nil
            } catch {
                // A fetch cancelled by stepping to another day isn't an error.
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
                data = nil
            }
            loaded = true
        }
    }

    private func header(current: String, today: String) -> some View {
        let isToday = current >= today
        let ago = Fmt.daysBetween(current, today)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 2) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Fmt.day(current, "EEEEMMMd")).font(.app(.title2, weight: .semibold)).foregroundStyle(Palette.ink)
                    if ago < 7 { Text(Fmt.relativeDay(current, today: today)).font(.app(.subheadline)).foregroundStyle(Palette.ink3) }
                }
                Spacer()
                Group {
                    Button { step(current, -1, today: today) } label: {
                        Image(systemName: "chevron.left").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Previous day")
                    Button { step(current, 1, today: today) } label: {
                        Image(systemName: "chevron.right").frame(width: 44, height: 44)
                    }
                    .disabled(isToday)
                    .accessibilityLabel("Next day")
                }
                .foregroundStyle(Palette.ink2)
                .buttonStyle(.plain)
            }
            if !isToday {
                Button("Back to today") { picked = nil }.font(.app(.footnote))
            }
        }
    }

    private func step(_ current: String, _ days: Int, today: String) {
        let next = Day.add(current, days)
        picked = next >= today ? nil : next
    }
}

/// Today's mini Day view: the running total so far against a typical day. Tapping opens DayScreen.
struct DayCard: View {
    let data: DayData
    /// The day Today shows; nil means today.
    let date: String?

    var body: some View {
        if let picked = Self.pick(data) {
            let (metric, series) = picked
            let reading = DayReading(metric: metric, series: series, data: data)
            let isToday = data.date >= data.today
            let title = Self.title(metric.title, running: metric.kind == .running, isToday: isToday)
            NavigationLink(value: AppRoute.day(date)) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title).font(.app(.headline)).foregroundStyle(Palette.ink)
                            if isToday { Text("By the hour").font(.app(.caption)).foregroundStyle(Palette.ink3) }
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Palette.ink3)
                    }
                    BigValue(value: reading.value.map { Fmt.number($0) } ?? "—", unit: metric.unit, size: 26)
                    Text(reading.note).font(.app(.caption)).foregroundStyle(Palette.ink3).fixedSize(horizontal: false, vertical: true)
                    if reading.through != nil {
                        HoursChart(metric: metric, series: series, reading: reading, compact: true).frame(height: 64)
                    }
                }
                .contentShape(Rectangle())
                .card()
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(title), by the hour: \(reading.value.map(metric.format) ?? "no readings"), \(reading.note)")
            .accessibilityHint("Opens the day by hour")
        }
    }

    /// The card names what it shows: "Steps so far today" (a running total, today), "Heart rate today" (hourly
    /// averages, today), or "Steps by hour" for a past day.
    static func title(_ metric: String, running: Bool, isToday: Bool) -> String {
        guard isToday else { return "\(metric) by hour" }
        return running ? "\(metric) so far today" : "\(metric) today"
    }

    /// Steps when there are any, else active energy, else heart rate.
    private static func pick(_ data: DayData) -> (HourMetric, DaySeries)? {
        if let s = data.steps { return (.steps, s) }
        if let e = data.activeEnergy { return (.energy, e) }
        if let hr = data.heartRate { return (.heart, hr) }
        return nil
    }
}

// MARK: - Metrics and day math (src/charts/day.ts)

enum HoursKind {
    /// A running total climbing from zero at midnight, plotted at the end of each hour (steps, energy).
    case running
    /// An hourly average at the middle of each hour, with its low–high band (heart rate).
    case hourly
}

struct HourMetric {
    let title: String
    let kind: HoursKind
    let unit: String
    let color: Color

    func format(_ v: Double) -> String { "\(Fmt.number(v)) \(unit)" }
    func axis(_ v: Double) -> String { kind == .running ? Fmt.compact(v) : Fmt.number(v) }

    static let steps = HourMetric(title: "Steps", kind: .running, unit: "steps", color: Palette.series1)
    static let energy = HourMetric(title: "Active energy", kind: .running, unit: "kcal", color: Palette.series2)
    static let heart = HourMetric(title: "Heart rate", kind: .hourly, unit: "bpm", color: Palette.series2)
}

private enum DayMath {
    /// The last hour to draw. A past day is complete, so it runs to 23:00; today stops at the latest synced hour,
    /// so a lagging phone doesn't read as a flat afternoon.
    static func through(date: String, today: String, asOf: Int?) -> Int? {
        guard let asOf else { return nil }
        return date < today ? 23 : min(max(asOf, 0), 23)
    }

    /// Running total by the end of each hour, through `through`. Hours without readings add nothing; later hours are nil.
    static func cumulative(_ hours: [Double?], through: Int?) -> [Double?] {
        var sum = 0.0
        return hours.enumerated().map { h, v in
            guard let through, h <= through else { return nil }
            sum += v ?? 0
            return sum
        }
    }

    /// The latest hour, at or before `through`, with a reading.
    static func lastReading(_ hours: [Double?], through: Int?) -> Int? {
        guard let through, !hours.isEmpty else { return nil }
        for h in stride(from: min(through, hours.count - 1), through: 0, by: -1) where hours[h] != nil { return h }
        return nil
    }

    static func extent(_ lists: [Double?]...) -> ClosedRange<Double>? {
        let vs = lists.flatMap { $0 }.compactMap { $0 }.filter(\.isFinite)
        guard let lo = vs.min(), let hi = vs.max() else { return nil }
        return lo...hi
    }

    /// Clean axis ticks: 1, 2, 2.5 or 5 times a power of ten (niceTicks in src/charts/core.tsx).
    static func ticks(_ lo: Double, _ hi: Double, count: Double = 4) -> [Double] {
        var lo = lo, hi = hi
        if lo == hi { lo -= 1; hi += 1 }
        let raw = (hi - lo) / count
        let pow = Foundation.pow(10, floor(log10(raw)))
        let step = [1, 2, 2.5, 5, 10].map { $0 * pow }.first { $0 >= raw } ?? raw
        var out: [Double] = []
        var t = floor(lo / step) * step
        while t <= hi + step * 0.001 {
            out.append((t * 1e10).rounded() / 1e10)
            t += step
        }
        if let last = out.last, last < hi { out.append(last + step) }
        return out
    }

    /// "14:00"; 24 is the midnight that ends the day.
    static func clock(_ h: Int) -> String { String(format: "%02d:00", h) }
    static func by(_ h: Int) -> String { h >= 24 ? "midnight" : clock(h) }
    /// "14:00–15:00" for the hour starting at h.
    static func span(_ h: Int) -> String { "\(clock(h))–\(clock(h + 1))" }
}

/// What one metric's day says: the line to draw and the headline (the web DayCard's value and note).
struct DayReading {
    let through: Int?
    /// Running totals or hourly averages, nil after `through`.
    let shown: [Double?]
    let value: Double?
    let note: String

    init(metric: HourMetric, series: DaySeries, data: DayData) {
        let through = DayMath.through(date: data.date, today: data.today, asOf: data.asOf)
        let isToday = data.date >= data.today
        self.through = through
        switch metric.kind {
        case .running: shown = DayMath.cumulative(series.hours, through: through)
        case .hourly: shown = series.hours.enumerated().map { h, v in through.map { h <= $0 } == true ? v : nil }
        }

        guard let through else {
            if metric.kind == .running, let total = series.total {
                // No hours for this day (the phone didn't sync it), but the day has a count, as Today shows it.
                value = total.value
                note = "\(isToday ? "so far" : "whole day")\(total.source == "whoop" ? ", from WHOOP" : "") · no hourly readings"
            } else {
                value = nil
                note = "No readings on this day"
            }
            return
        }
        switch metric.kind {
        case .running:
            let soFar = shown[through] ?? 0
            if let total = series.total, total.source == "whoop", total.value > soFar {
                // WHOOP counted clearly more than the phone or Watch did: that's the day's figure, as on Today; the
                // hours (WHOOP has none) are the phone's or Watch's share of it.
                value = total.value
                note = "\(isToday ? "so far" : "whole day"), from WHOOP · hourly line from iPhone or Apple Watch (\(metric.format(soFar)))"
            } else {
                value = soFar
                var n = isToday ? "by \(DayMath.by(through + 1))" : "whole day"
                if let typical = series.typical[through] { n += " · typical \(isToday ? "by now " : "")\(metric.format(typical))" }
                note = n
            }
        case .hourly:
            guard let h = DayMath.lastReading(series.hours, through: through), let v = series.hours[h] else {
                value = nil
                note = "No readings on this day"
                return
            }
            let upTo = { (l: [Double?]?) in Array((l ?? []).prefix(through + 1)) }
            let range = DayMath.extent(upTo(series.min), upTo(series.max)) ?? DayMath.extent(upTo(series.hours))
            value = v
            var n = "\(DayMath.span(h)) average"
            if let range { n += " · \(isToday ? "today" : "that day") \(metric.axis(range.lowerBound))–\(metric.format(range.upperBound))" }
            note = n
        }
    }
}

// MARK: - Cards and chart

/// One metric's day on DayScreen: headline, the chart you can scrub, and the legend.
private struct HoursCard: View {
    let metric: HourMetric
    let series: DaySeries
    let data: DayData
    var goal: Double?

    var body: some View {
        let reading = DayReading(metric: metric, series: series, data: data)
        let dayLabel = data.date >= data.today ? "Today" : Fmt.day(data.date, "EEEMMMd")
        VStack(alignment: .leading, spacing: 6) {
            Text(metric.title).font(.app(.subheadline, weight: .medium)).foregroundStyle(Palette.ink2)
            Text(reading.value.map(metric.format) ?? "—").font(.app(.title2, weight: .semibold)).foregroundStyle(Palette.ink).monospacedDigit()
            Text(reading.note).font(.app(.caption)).foregroundStyle(Palette.ink3).fixedSize(horizontal: false, vertical: true)
            if reading.through != nil, DayMath.extent(reading.shown, series.typical) != nil {
                HoursChart(metric: metric, series: series, reading: reading, goal: goal, label: "\(metric.title) by hour, \(dayLabel)")
                    .frame(height: 200)
                    .padding(.top, 6)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 14) { legend(dayLabel) }
                    VStack(alignment: .leading, spacing: 4) { legend(dayLabel) }
                }
            } else {
                Text(series.total != nil ? "No hourly readings on this day" : "No readings on this day")
                    .font(.app(.footnote)).foregroundStyle(Palette.ink3)
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
        }
        .card()
    }

    @ViewBuilder private func legend(_ dayLabel: String) -> some View {
        LegendKey(color: metric.color, dashed: false, label: dayLabel)
        LegendKey(color: Palette.ink2, dashed: true, label: "Typical (median of the last 30 days)")
    }
}

private struct LegendKey: View {
    let color: Color
    let dashed: Bool
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            Path { p in
                p.move(to: CGPoint(x: 0, y: 1))
                p.addLine(to: CGPoint(x: 16, y: 1))
            }
            .stroke(color, style: StrokeStyle(lineWidth: dashed ? 1.25 : 2, lineCap: .round, dash: dashed ? [3, 3] : []))
            .frame(width: 16, height: 2)
            Text(label).font(.app(.caption2)).foregroundStyle(Palette.ink3).lineLimit(1)
        }
    }
}

private struct HourPoint: Identifiable {
    let x: Double
    let y: Double
    let run: Int
    var id: String { "\(run)|\(x)" }
}

private struct BandPoint: Identifiable {
    let x: Double
    let lo: Double
    let hi: Double
    let run: Int
    var id: String { "\(run)|\(x)" }
}

/// The day against the dashed typical day (src/charts/Day.tsx DayChart). `compact` is Today's mini version: no axes,
/// no goal and no scrubbing. Vitals and Body draw a day with it too.
struct HoursChart: View {
    let metric: HourMetric
    let series: DaySeries
    let reading: DayReading
    var goal: Double?
    var compact = false
    var label = ""
    @State private var selectedX: Double?

    private var running: Bool { metric.kind == .running }

    /// Each point sits at the end of its hour for a running total, in the middle of it for an average.
    private func x(_ h: Int) -> Double { running ? Double(h + 1) : Double(h) + 0.5 }

    /// Runs of consecutive hours with values, so a gap isn't drawn through. Running totals start at zero at midnight.
    private func points(_ values: [Double?]) -> [HourPoint] {
        var out: [HourPoint] = []
        var run = 0
        var open = false
        for (h, v) in values.enumerated() {
            guard let v else {
                if open { run += 1 }
                open = false
                continue
            }
            if !open, running, h == 0 { out.append(HourPoint(x: 0, y: 0, run: run)) }
            out.append(HourPoint(x: x(h), y: v, run: run))
            open = true
        }
        return out
    }

    private var band: [BandPoint] {
        guard !running, let lo = series.min, let hi = series.max, let through = reading.through else { return [] }
        var out: [BandPoint] = []
        var run = 0
        for h in 0...through {
            if let a = lo[h], let b = hi[h] {
                out.append(BandPoint(x: x(h), lo: a, hi: b, run: run))
            } else {
                run += 1
            }
        }
        // A one-hour band has no width to fill.
        let counts = Dictionary(grouping: out, by: \.run).mapValues(\.count)
        return out.filter { counts[$0.run, default: 0] > 1 }
    }

    /// The hour picked by scrubbing, snapped and kept within what's drawn.
    private var picked: Int? {
        guard let s = selectedX, let through = reading.through else { return nil }
        let h = running ? Int((s - 1).rounded()) : Int(s.rounded(.down))
        return min(max(h, 0), through)
    }

    var body: some View {
        let line = points(reading.shown)
        let typical = points(series.typical)
        let bandPoints = band
        let span = DayMath.extent(reading.shown, series.typical, bandPoints.map(\.lo), bandPoints.map(\.hi), goal.map { [$0] } ?? [])
        let ticks = span.map { DayMath.ticks(running ? 0 : $0.lowerBound, $0.upperBound) } ?? [0, 1]
        let domain = (ticks.first ?? 0)...max((ticks.last ?? 1), (ticks.first ?? 0) + 1)
        let lineRuns = Dictionary(grouping: line, by: \.run).mapValues(\.count)
        let endH = running ? reading.through : DayMath.lastReading(reading.shown, through: reading.through)
        let focus = picked ?? endH

        Chart {
            if let goal, !compact {
                RuleMark(y: .value("Goal", goal))
                    .foregroundStyle(Palette.good.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    // Left, where the running total is still low: on the right it would sit on the line's end.
                    .annotation(position: .top, alignment: .leading) {
                        Text("Goal \(Fmt.compact(goal))").font(.app(.caption2)).foregroundStyle(Palette.goodText)
                    }
            }
            ForEach(bandPoints) { p in
                AreaMark(x: .value("Hour", p.x), yStart: .value("Low", p.lo), yEnd: .value("High", p.hi), series: .value("Part", "band \(p.run)"))
                    .foregroundStyle(metric.color.opacity(0.16))
                    .interpolationMethod(.monotone)
            }
            ForEach(typical) { p in
                LineMark(x: .value("Hour", p.x), y: .value("Typical", p.y), series: .value("Part", "typical \(p.run)"))
                    .foregroundStyle(Palette.ink2.opacity(0.75))
                    .lineStyle(StrokeStyle(lineWidth: 1.25, dash: [4, 4]))
                    .interpolationMethod(.monotone)
            }
            if running {
                ForEach(line) { p in
                    AreaMark(x: .value("Hour", p.x), yStart: .value("Base", domain.lowerBound), yEnd: .value(metric.title, p.y), series: .value("Part", "area \(p.run)"))
                        .foregroundStyle(metric.color.opacity(0.1))
                        .interpolationMethod(.monotone)
                }
            }
            ForEach(line) { p in
                if lineRuns[p.run, default: 0] > 1 {
                    LineMark(x: .value("Hour", p.x), y: .value(metric.title, p.y), series: .value("Part", "day \(p.run)"))
                        .foregroundStyle(metric.color)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                } else {
                    PointMark(x: .value("Hour", p.x), y: .value(metric.title, p.y))
                        .foregroundStyle(metric.color)
                        .symbolSize(28)
                }
            }
            if let p = picked {
                RuleMark(x: .value("Hour", x(p)))
                    .foregroundStyle(Palette.ink3.opacity(0.5))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) { tooltip(p) }
            }
            if let h = focus, let v = reading.shown[h] {
                PointMark(x: .value("Hour", x(h)), y: .value(metric.title, v))
                    .foregroundStyle(metric.color)
                    .symbolSize(compact ? 30 : 50)
            }
        }
        .chartXScale(domain: 0...24)
        .chartYScale(domain: domain)
        .modifier(HoursAxes(compact: compact, ticks: ticks, format: metric.axis, selectedX: $selectedX))
        .accessibilityLabel(label)
        .accessibilityValue("\(reading.value.map(metric.format) ?? "No readings"). \(reading.note)")
        .accessibilityHidden(compact)
    }

    private func tooltip(_ h: Int) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(DayMath.span(h)).font(.app(.caption2)).foregroundStyle(Palette.ink3)
            if running {
                Text("\(metric.format(reading.shown[h] ?? 0)) so far").font(.app(.caption, weight: .semibold))
                Text("\(metric.format(series.hours[h] ?? 0)) this hour").font(.app(.caption2))
            } else if let v = reading.shown[h] {
                Text("\(metric.format(v)) average").font(.app(.caption, weight: .semibold))
                if let lo = series.min?[h], let hi = series.max?[h] {
                    Text("range \(metric.axis(lo))–\(metric.format(hi))").font(.app(.caption2))
                }
            } else {
                Text("No reading").font(.app(.caption, weight: .semibold))
            }
            if let t = series.typical[h] {
                Text("typical\(running ? " by then" : "") \(metric.format(t))").font(.app(.caption2)).foregroundStyle(Palette.ink2)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Palette.surface2, in: RoundedRectangle(cornerRadius: 8))
        .foregroundStyle(Palette.ink)
    }
}

/// Hour axis and value axis with scrubbing, or nothing at all for the compact chart.
private struct HoursAxes: ViewModifier {
    let compact: Bool
    let ticks: [Double]
    let format: (Double) -> String
    @Binding var selectedX: Double?

    @ViewBuilder func body(content: Content) -> some View {
        if compact {
            content
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
        } else {
            content
                .chartXSelection(value: $selectedX)
                .chartYAxis {
                    AxisMarks(position: .leading, values: ticks) { v in
                        AxisGridLine().foregroundStyle(Palette.grid)
                        AxisValueLabel { if let n = v.as(Double.self) { Text(format(n)) } }.font(.app(.caption2))
                    }
                }
                // Labels sit just after their hour, as in Health; the day's end needs none.
                .chartXAxis {
                    AxisMarks(values: [0.0, 6, 12, 18]) { v in
                        AxisTick().foregroundStyle(Palette.grid)
                        AxisValueLabel { Text(DayMath.clock(Int(v.as(Double.self) ?? 0))) }.font(.app(.caption2))
                            .foregroundStyle(Palette.ink3)
                    }
                }
        }
    }
}
