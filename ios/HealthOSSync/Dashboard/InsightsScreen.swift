import Charts
import SwiftUI

/// McFly's weekly digest, patterns from the person's own history, two scatter plots and a year heatmap.
/// Everything here is correlational: "tends to", never "causes".
struct InsightsScreen: View {
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        NavigationStack {
            Group {
                if dashboard.signInRequired {
                    SignInView()
                } else if dashboard.phase == .noServer {
                    ContentUnavailableView("No server yet", systemImage: "server.rack", description: Text("Add your healthOS address in Settings."))
                } else {
                    ScrollView {
                        InsightsContent().padding(16)
                    }
                    .refreshable { await dashboard.load() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.page)
            .navigationTitle("Insights")
            .settingsButton()
        }
    }
}

/// Fetches for the cards: a card that hides itself (no digest, an older server) would never run its own task.
private struct InsightsContent: View {
    @Environment(Dashboard.self) private var dashboard
    @State private var digest: DigestReply?
    @State private var patterns: Patterns?
    @State private var trends: Trends?
    @State private var trendsError: String?

    /// One year of everything the scatter plots and the heatmap read; the scatter plots use the last 90 days of it.
    private static let metrics = ["steps", "sleep_hours", "recovery", "hrv_rmssd", "hrv_sdnn", "strain"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let digest, DigestCard.shows(digest) { DigestCard(reply: digest) }
            if let patterns { PatternsCard(patterns: patterns) }
            if let trends {
                let end = dashboard.summary?.today ?? Day.today()
                SleepScatter(trends: trends, end: end)
                HrvScatter(trends: trends, end: end)
                YearHeatmapCard(trends: trends, end: end, stepGoal: dashboard.stepGoal)
            } else if let trendsError {
                ContentUnavailableView("Couldn't load your data", systemImage: "chart.dots.scatter", description: Text(trendsError))
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            }
        }
        // Separate tasks: writing a new digest can take McFly a few seconds, and the rest shouldn't wait for it.
        // A failed refetch keeps what's on screen; nil (404) means the server doesn't have the feature.
        .task(id: dashboard.generation) {
            do { digest = try await dashboard.digest() } catch {}
        }
        .task(id: dashboard.generation) {
            do { patterns = try await dashboard.patterns() } catch {}
        }
        .task(id: dashboard.generation) {
            do {
                trends = try await dashboard.trends(Self.metrics, days: 365)
                trendsError = nil
            } catch {
                if trends == nil, !Task.isCancelled { trendsError = error.localizedDescription }
            }
        }
    }
}

/// Only "YYYY-MM-DD" strings go through the date formatters, which can't parse anything else.
private func isDay(_ s: String) -> Bool { s.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil }

/// "Oct 6 – 12", or "Sep 29 – Oct 5" across months.
private func dayRange(_ start: String, _ end: String) -> String? {
    guard isDay(start), isDay(end) else { return nil }
    return "\(Fmt.day(start)) – \(start.prefix(7) == end.prefix(7) ? Fmt.day(end, "d") : Fmt.day(end))"
}

// MARK: - Weekly digest

private struct DigestCard: View {
    let reply: DigestReply

    /// Hidden when McFly isn't set up or is off; a quiet note when it's over today's limit or last week was too thin.
    static func shows(_ r: DigestReply) -> Bool {
        guard r.configured, r.reason != "off", r.reason != "not_configured" else { return false }
        return r.digest != nil || r.reason == "limit" || r.reason == "no_data"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Tone.blue.ink)
                    .frame(width: 34, height: 34)
                    .background(Tone.blue.background, in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Weekly digest").font(.app(.headline)).foregroundStyle(Palette.ink)
                    Text(subtitle).font(.app(.caption)).foregroundStyle(Palette.ink3)
                }
            }
            if let digest = reply.digest {
                LightMarkdown(text: digest.text)
                    .font(.app(.callout))
                    .foregroundStyle(Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if reply.reason == "limit" {
                    Text("McFly is at today's limit, so this is the most recent digest it wrote.").font(.app(.caption)).foregroundStyle(Palette.ink3)
                }
            } else {
                Text(note).font(.app(.footnote)).foregroundStyle(Palette.ink3).fixedSize(horizontal: false, vertical: true)
            }
        }
        .card()
    }

    private var subtitle: String {
        guard let d = reply.digest, let range = dayRange(d.weekStart, d.weekEnd) else { return "From McFly" }
        return "Week of \(range) · from McFly"
    }

    private var note: String {
        reply.reason == "no_data"
            ? "Last week didn't have enough data for a digest. It needs at least three days with readings."
            : "McFly has reached today's limit. Last week's digest will be here tomorrow."
    }
}

// MARK: - Patterns

private struct PatternsCard: View {
    let patterns: Patterns

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Patterns").font(.app(.headline)).foregroundStyle(Palette.ink)
                if let range = dayRange(patterns.start, patterns.end) {
                    Text(range).font(.app(.caption)).foregroundStyle(Palette.ink3)
                }
            }
            if patterns.patterns.isEmpty {
                Text("Patterns appear after a few weeks of data. They compare your own days with each other, like nights after active days and nights after quieter ones.")
                    .font(.app(.footnote)).foregroundStyle(Palette.ink3).fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(patterns.patterns) { PatternRow(pattern: $0) }
                Text("These show what tends to go together in your own days, not what causes what.")
                    .font(.app(.caption)).foregroundStyle(Palette.ink3).fixedSize(horizontal: false, vertical: true)
            }
        }
        .card()
    }
}

private struct PatternRow: View {
    let pattern: Pattern
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        if let section = pattern.page.flatMap(TrendsSection.init(page:)) {
            Button { dashboard.open(section) } label: { row(chevron: true) }
                .buttonStyle(.plain)
        } else {
            row(chevron: false)
        }
    }

    private func row(chevron: Bool) -> some View {
        let (symbol, tone) = InsightsCard.style(pattern.icon ?? "")
        return HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tone.ink)
                .frame(width: 34, height: 34)
                .background(tone.background, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(pattern.text).font(.app(.subheadline)).foregroundStyle(Palette.ink).multilineTextAlignment(.leading)
                if let detail = pattern.detail, !detail.isEmpty {
                    Text(detail).font(.app(.caption)).foregroundStyle(Palette.ink3).multilineTextAlignment(.leading)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if chevron { Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Palette.ink3) }
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Scatter plots

/// Straight-line least-squares fit, with Pearson's r for how closely the points follow it.
private struct LineFit {
    let slope: Double
    let intercept: Double
    let r: Double

    init?(_ pairs: [ScatterPairs.Pair]) {
        guard pairs.count >= 2 else { return nil }
        let n = Double(pairs.count)
        let mx = pairs.reduce(0) { $0 + $1.x } / n
        let my = pairs.reduce(0) { $0 + $1.y } / n
        var sxx = 0.0, syy = 0.0, sxy = 0.0
        for p in pairs {
            sxx += (p.x - mx) * (p.x - mx)
            syy += (p.y - my) * (p.y - my)
            sxy += (p.x - mx) * (p.y - my)
        }
        guard sxx > 0 else { return nil }
        slope = sxy / sxx
        intercept = my - slope * mx
        r = syy > 0 ? sxy / (sxx * syy).squareRoot() : 0
    }

    func y(at x: Double) -> Double { intercept + slope * x }

    /// "higher" / "a little lower", or nil when the points barely follow the line.
    var tendency: String? {
        guard abs(r) >= 0.1 else { return nil }
        return (abs(r) < 0.3 ? "a little " : "") + (slope > 0 ? "higher" : "lower")
    }
}

/// x on day d against y on day d + `lag`, for x days from `start` through `end`.
private struct ScatterPairs {
    struct Pair: Identifiable {
        let date: String
        let x: Double
        let y: Double
        var id: String { date }
    }

    static let needed = 10

    let pairs: [Pair]
    let fit: LineFit?

    init(x: [Point], y: [Point], lag: Int = 0, from start: String, through end: String) {
        let ys = Dictionary(y.map { ($0.date, $0.value) }, uniquingKeysWith: { _, last in last })
        let pairs = x.compactMap { p -> Pair? in
            guard p.date >= start, p.date <= end, let v = ys[lag == 0 ? p.date : Day.add(p.date, lag)] else { return nil }
            return Pair(date: p.date, x: p.value, y: v)
        }
        self.pairs = pairs
        fit = LineFit(pairs)
    }

    var enough: Bool { pairs.count >= Self.needed }

    /// The preferred pairing when it has enough points; otherwise whichever of the two has more.
    static func prefer(_ a: ScatterPairs, over b: ScatterPairs) -> Bool {
        a.enough || (!b.enough && a.pairs.count > b.pairs.count)
    }
}

/// Axis ticks can fall on halves (6.5 h, 12.5 strain): a decimal only when there is one.
private func axisNumber(_ v: Double) -> String { Fmt.number(v, v.rounded() == v ? 0 : 1) }

/// HRV from whichever source read most recently (WHOOP RMSSD or Apple Watch SDNN), like the server's pickMetric.
private func hrvPoints(_ t: Trends) -> [Point] {
    let rmssd = t["hrv_rmssd"] ?? [], sdnn = t["hrv_sdnn"] ?? []
    return (sdnn.last?.date ?? "") > (rmssd.last?.date ?? "") ? sdnn : rmssd
}

/// Recovery (WHOOP) or else HRV against hours slept, the same wake date, last 90 days.
private struct SleepScatter: View {
    let trends: Trends
    let end: String

    var body: some View {
        let start = Day.add(end, -89)
        let sleep = trends["sleep_hours"] ?? []
        let recovery = ScatterPairs(x: sleep, y: trends["recovery"] ?? [], from: start, through: end)
        let hrv = ScatterPairs(x: sleep, y: hrvPoints(trends), from: start, through: end)
        let useRecovery = ScatterPairs.prefer(recovery, over: hrv)
        let data = useRecovery ? recovery : hrv
        let noun = useRecovery ? "recovery" : "HRV"
        ScatterCard(
            title: useRecovery ? "Sleep and recovery" : "Sleep and HRV",
            data: data,
            xLabel: "Sleep (hours)",
            yLabel: useRecovery ? "Recovery (%)" : "HRV (ms)",
            xText: axisNumber,
            caption: data.fit?.tendency.map { "After longer nights, your \(noun) tends to be \($0)." }
                ?? "So far, your \(noun) doesn't follow how long you sleep very closely.",
            unit: "nights",
            color: useRecovery ? Palette.series3 : Palette.series1
        )
    }
}

/// Next-morning HRV (day d + 1) against the day before's strain (WHOOP) or else steps (day d), last 90 days.
private struct HrvScatter: View {
    let trends: Trends
    let end: String

    var body: some View {
        let start = Day.add(end, -89)
        let hrv = hrvPoints(trends)
        let strain = ScatterPairs(x: trends["strain"] ?? [], y: hrv, lag: 1, from: start, through: end)
        let steps = ScatterPairs(x: trends["steps"] ?? [], y: hrv, lag: 1, from: start, through: end)
        let useStrain = ScatterPairs.prefer(strain, over: steps)
        let data = useStrain ? strain : steps
        ScatterCard(
            title: useStrain ? "Strain and next-morning HRV" : "Steps and next-morning HRV",
            data: data,
            xLabel: useStrain ? "Strain, day before" : "Steps, day before",
            yLabel: "HRV next morning (ms)",
            xText: useStrain ? axisNumber : { Fmt.compact($0) },
            caption: data.fit?.tendency.map { "\(useStrain ? "After higher-strain days" : "After days with more steps"), your next-morning HRV tends to be \($0)." }
                ?? "So far, your next-morning HRV doesn't follow the day before's \(useStrain ? "strain" : "steps") very closely.",
            unit: "days",
            color: Palette.series1
        )
    }
}

private struct ScatterCard: View {
    let title: String
    let data: ScatterPairs
    let xLabel: String
    let yLabel: String
    let xText: (Double) -> String
    let caption: String
    /// "nights" or "days", for the counts.
    let unit: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.app(.subheadline, weight: .medium)).foregroundStyle(Palette.ink2)
                Spacer(minLength: 8)
                if !data.pairs.isEmpty { Chip(text: "n = \(data.pairs.count)") }
            }
            if data.enough {
                Text(caption).font(.app(.callout)).foregroundStyle(Palette.ink).fixedSize(horizontal: false, vertical: true)
                chart.frame(height: 210).padding(.top, 6)
                Text("One dot for each of \(data.pairs.count) \(unit) in the last 90 days; the line is a simple straight-line fit.")
                    .font(.app(.caption)).foregroundStyle(Palette.ink3).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Not enough \(unit) yet. This needs at least \(ScatterPairs.needed) with both readings, and there \(data.pairs.count == 1 ? "is" : "are") \(data.pairs.count) in the last 90 days.")
                    .font(.app(.footnote)).foregroundStyle(Palette.ink3).fixedSize(horizontal: false, vertical: true)
            }
        }
        .card()
    }

    private struct FitPoint: Identifiable {
        let id: Int
        let x: Double
        let y: Double
    }

    private var chart: some View {
        let xs = data.pairs.map(\.x)
        let lo = xs.min() ?? 0, hi = xs.max() ?? 1
        let line = data.fit.map { fit in [FitPoint(id: 0, x: lo, y: fit.y(at: lo)), FitPoint(id: 1, x: hi, y: fit.y(at: hi))] } ?? []
        let ys = data.pairs.map(\.y) + line.map(\.y)
        return Chart {
            ForEach(data.pairs) { p in
                PointMark(x: .value(xLabel, p.x), y: .value(yLabel, p.y))
                    .foregroundStyle(color.opacity(0.55))
                    .symbolSize(30)
            }
            ForEach(line) { p in
                LineMark(x: .value(xLabel, p.x), y: .value(yLabel, p.y), series: .value("Series", "Fit"))
                    .foregroundStyle(Palette.ink2)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
            }
        }
        .chartXScale(domain: Self.padded(xs))
        .chartYScale(domain: Self.padded(ys))
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { value in
            AxisGridLine().foregroundStyle(Palette.grid)
            AxisValueLabel { if let v = value.as(Double.self) { Text(xText(v)) } }.foregroundStyle(Palette.ink3)
        } }
        .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
            AxisGridLine().foregroundStyle(Palette.grid)
            AxisValueLabel().foregroundStyle(Palette.ink3)
        } }
        .chartXAxisLabel(position: .bottom, alignment: .center) { Text(xLabel).font(.app(.caption2)).foregroundStyle(Palette.ink3) }
        .chartYAxisLabel(position: .leading, alignment: .center) { Text(yLabel).font(.app(.caption2)).foregroundStyle(Palette.ink3) }
        .accessibilityLabel("\(title): \(yLabel) against \(xLabel), \(data.pairs.count) \(unit)")
        .accessibilityValue(caption)
    }

    /// min…max with a little room, never zero-width (every value the same).
    private static func padded(_ values: [Double]) -> ClosedRange<Double> {
        let lo = values.min() ?? 0, hi = values.max() ?? 1
        let pad = Swift.max((hi - lo) * 0.08, Swift.max(abs(hi) * 0.02, 0.5))
        return (lo - pad)...(hi + pad)
    }
}

// MARK: - Year heatmap

private enum HeatmapMetric: String, CaseIterable, Identifiable {
    case steps, sleep
    var id: String { rawValue }

    var title: String { self == .steps ? "Steps" : "Sleep" }
    var key: String { self == .steps ? "steps" : "sleep_hours" }

    /// 0 = no reading, 1–4 = lightest to darkest.
    func level(_ value: Double?, goal: Double) -> Int {
        guard let value else { return 0 }
        switch self {
        case .steps: return value >= goal ? 4 : value >= goal * 0.7 ? 3 : value >= goal * 0.4 ? 2 : 1
        case .sleep: return value >= 8 ? 4 : value >= 7 ? 3 : value >= 6 ? 2 : 1
        }
    }

    /// Empty days stay visible as faint cells.
    func color(level: Int) -> Color {
        guard level > 0 else { return Palette.grid }
        let base = self == .steps ? Palette.series3 : Palette.series1
        return base.opacity([0.3, 0.5, 0.75, 1][Swift.min(level, 4) - 1])
    }

    func valueText(_ value: Double) -> String {
        self == .steps ? "\(Fmt.number(value)) steps" : Fmt.hoursMinutes(value)
    }

    func scale(goal: Double) -> String {
        switch self {
        case .steps: "Lightest under \(Fmt.compact(goal * 0.4)) steps, darkest at your \(Fmt.compact(goal)) goal."
        case .sleep: "Lightest under 6 hours, darkest 8 hours or more."
        }
    }
}

/// A year of days laid out like a contribution calendar: one column per Monday-start week, one row per weekday.
private struct YearGrid {
    /// Monday of the first column.
    let start: String
    /// Offsets from `start` of the first and last day shown (the days before the first are blank).
    let first: Int
    let last: Int
    let weeks: Int
    /// One value per offset from `start`; nil where there's no reading.
    let values: [Double?]
    /// Columns where a month starts, for the labels along the top.
    let months: [(column: Int, label: String)]

    init(points: [Point], end: String, days: Int = 365) {
        let firstDay = Day.add(end, -(days - 1))
        let start = Point.weekStart(firstDay)
        let last = Fmt.daysBetween(start, end)
        let weeks = last / 7 + 1
        var values = [Double?](repeating: nil, count: weeks * 7)
        for p in points where p.date >= firstDay && p.date <= end {
            values[Fmt.daysBetween(start, p.date)] = p.value
        }
        var months: [(column: Int, label: String)] = []
        for column in 0..<weeks - 1 {
            // The first Monday of each month; none in the last column, where the label wouldn't fit.
            let monday = Day.add(start, column * 7)
            if let d = Int(monday.suffix(2)), d <= 7 { months.append((column: column, label: Fmt.day(monday, "MMM"))) }
        }
        self.start = start
        self.first = Fmt.daysBetween(start, firstDay)
        self.last = last
        self.weeks = weeks
        self.values = values
        self.months = months
    }

    func date(_ offset: Int) -> String { Day.add(start, offset) }

    var readings: [Double] { values.compactMap { $0 } }
}

private struct YearHeatmapCard: View {
    let trends: Trends
    let end: String
    let stepGoal: Double
    @AppStorage("insightsHeatmap") private var metric: HeatmapMetric = .steps

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Past year").font(.app(.subheadline, weight: .medium)).foregroundStyle(Palette.ink2)
                Spacer(minLength: 8)
                Picker("Metric", selection: $metric) {
                    ForEach(HeatmapMetric.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
            }
            // Built here, once per metric or data change; the grid's own selection state doesn't rebuild it.
            HeatmapGrid(grid: YearGrid(points: trends[metric.key] ?? [], end: end), metric: metric, stepGoal: stepGoal)
                .id(metric)
            HStack(spacing: 4) {
                Text("Less")
                ForEach(0..<5, id: \.self) { level in
                    RoundedRectangle(cornerRadius: 3, style: .continuous).fill(metric.color(level: level)).frame(width: 12, height: 12)
                }
                Text("More")
            }
            .font(.app(.caption2))
            .foregroundStyle(Palette.ink3)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Color scale. \(metric.scale(goal: stepGoal))")
            Text("\(metric.scale(goal: stepGoal)) Tap a day, or press and slide, to read it.")
                .font(.app(.caption)).foregroundStyle(Palette.ink3).fixedSize(horizontal: false, vertical: true)
                .accessibilityHidden(true)
        }
        .card()
    }
}

/// Drawn with one Canvas rather than a view per day.
private struct HeatmapGrid: View {
    let grid: YearGrid
    let metric: HeatmapMetric
    let stepGoal: Double
    @State private var selected: Int?

    private let cell: CGFloat = 12
    private let gap: CGFloat = 3
    /// Room for the month labels above the cells.
    private let top: CGFloat = 16
    private var step: CGFloat { cell + gap }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(readout)
                .font(.app(.footnote, weight: .medium))
                .foregroundStyle(Palette.ink2)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            HStack(alignment: .top, spacing: 6) {
                weekdays
                ScrollView(.horizontal) {
                    canvas
                        .frame(width: CGFloat(grid.weeks) * step - gap, height: top + 7 * step - gap)
                }
                .scrollIndicators(.hidden)
                .defaultScrollAnchor(.trailing)
            }
        }
    }

    private var weekdays: some View {
        let symbols = Calendar.current.shortWeekdaySymbols // index 0 is Sunday
        return VStack(alignment: .leading, spacing: gap) {
            ForEach(0..<7, id: \.self) { row in
                Text(row == 0 || row == 2 || row == 4 ? symbols[(row + 1) % 7] : " ")
                    .font(.app(.caption2))
                    .foregroundStyle(Palette.ink3)
                    .frame(height: cell)
            }
        }
        .padding(.top, top)
        .accessibilityHidden(true)
    }

    private var canvas: some View {
        let colors = (0...4).map { metric.color(level: $0) }
        let levels = grid.values.map { metric.level($0, goal: stepGoal) }
        return Canvas { ctx, _ in
            for month in grid.months {
                ctx.draw(Text(month.label).font(.app(.caption2)).foregroundStyle(Palette.ink3), at: CGPoint(x: CGFloat(month.column) * step, y: 0), anchor: .topLeading)
            }
            for i in grid.first...grid.last {
                let rect = CGRect(x: CGFloat(i / 7) * step, y: top + CGFloat(i % 7) * step, width: cell, height: cell)
                let path = Path(roundedRect: rect, cornerRadius: 3, style: .continuous)
                ctx.fill(path, with: .color(colors[levels[i]]))
                if i == selected { ctx.stroke(path, with: .color(Palette.ink), lineWidth: 1.5) }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(coordinateSpace: .local) { location in
            if let i = offset(at: location, clamped: false) { selected = i }
        }
        // Press, then slide across the days. A plain swipe still scrolls the year.
        .gesture(
            LongPressGesture(minimumDuration: 0.25)
                .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
                .onChanged { value in
                    if case .second(true, let drag?) = value, let i = offset(at: drag.location, clamped: true) { selected = i }
                }
        )
        .accessibilityElement()
        .accessibilityLabel("\(metric.title) by day over the past year")
        .accessibilityValue(readout)
        .accessibilityHint("Swipe up or down to move through the days.")
        .accessibilityAdjustableAction { direction in
            let current = selected ?? grid.last
            switch direction {
            case .increment: selected = Swift.min(grid.last, current + 1)
            case .decrement: selected = Swift.max(grid.first, current - 1)
            default: break
            }
        }
    }

    private func offset(at p: CGPoint, clamped: Bool) -> Int? {
        var column = Int((p.x / step).rounded(.down))
        var row = Int(((p.y - top) / step).rounded(.down))
        if clamped {
            column = Swift.min(Swift.max(column, 0), grid.weeks - 1)
            row = Swift.min(Swift.max(row, 0), 6)
        } else if p.y < top || !(0..<7).contains(row) || !(0..<grid.weeks).contains(column) {
            return nil
        }
        let i = column * 7 + row
        return clamped ? Swift.min(Swift.max(i, grid.first), grid.last) : (grid.first...grid.last).contains(i) ? i : nil
    }

    private var readout: String {
        if let selected {
            let value = grid.values[selected].map(metric.valueText) ?? "No data"
            return "\(Fmt.day(grid.date(selected), "yMMMEd")) · \(value)"
        }
        let readings = grid.readings
        guard !readings.isEmpty else { return "No \(metric == .steps ? "steps" : "sleep") recorded in the past year." }
        let avg = readings.reduce(0, +) / Double(readings.count)
        switch metric {
        case .steps:
            let met = readings.filter { $0 >= stepGoal }.count
            return "Average \(Fmt.number(avg)) a day · goal met on \(met) day\(met == 1 ? "" : "s")"
        case .sleep:
            return "Average \(Fmt.hoursMinutes(avg)) a night · \(readings.count) night\(readings.count == 1 ? "" : "s")"
        }
    }
}
