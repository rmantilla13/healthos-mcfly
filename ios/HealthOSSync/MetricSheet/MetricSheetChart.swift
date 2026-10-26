import Charts
import SwiftUI

// The sheet's chart (SheetChart in MetricSheet.tsx): a line for readings, bars for a day's total, or the day by the hour
// against the dashed typical day. It sits on the sheet itself, not in a card (.msheet-chart.card), with the web's
// ChartCard head: its title and note, and a switch between the chart and a table of every value.

/// What a chart's table shows: its columns and rows, oldest first (the table lists them newest first).
struct SheetTable: Equatable {
    let columns: [String]
    let rows: [[String]]
}

/// The chart for a sheet's range, with its head and table.
struct SheetChart: View {
    let sheet: MetricSheetData

    var body: some View {
        let format = SheetFormat(sheet)
        let info = sheet.key.info
        let color = sheet.key.warmSeries ? Palette.series2 : Palette.series1
        if sheet.range == .day {
            if let day = sheet.day, let series = day.metrics[sheet.key.rawValue], let hour = sheet.key.hourMetric {
                let reading = DayReading(metric: hour, series: series, data: day)
                let running = hour.kind == .running
                SheetChartCard(title: running ? SheetWords.byTheHourRunning : SheetWords.byTheHour, note: SheetWords.typicalNote,
                               table: Self.dayTable(series: series, reading: reading, running: running, format: format)) {
                    SheetDayChart(hour: hour, series: series, reading: reading, goal: sheet.goal,
                                  label: "\(info.label) by the hour, \(Fmt.day(day.date, "EEEEMMMMd"))")
                }
            }
        } else if !sheet.points.isEmpty {
            let weekly = sheet.resolution == .week
            let label = "\(info.label), \(sheet.range.label.lowercased())\(weekly ? ", weekly averages" : "")"
            let period: ((String) -> String)? = weekly ? { "Week of \(Fmt.day($0, "MMMd"))" } : nil
            SheetChartCard(title: weekly ? SheetWords.weekly : info.duration ? SheetWords.eachNight : SheetWords.eachDay,
                           note: sheet.partialToday && !weekly ? SheetWords.todaySoFar : nil,
                           table: SheetTable(columns: [weekly ? "Week of" : "Date", info.label],
                                             rows: sheet.points.map { [Fmt.day($0.date, "MMMdyyyy"), format.value($0.value)] })) {
                if info.chart == .bars {
                    SheetBarChart(points: sheet.points, format: format, label: label, period: period,
                                  goal: weekly ? nil : sheet.goal)
                } else {
                    SheetTrendChart(points: sheet.points, format: format, color: color, label: label,
                                    gapDays: weekly ? 10 : 3, period: period)
                }
            }
        }
    }

    /// The Day's table: each hour drawn, with its own value, the running total and the typical by then; heart rate's
    /// average, low, high and typical.
    static func dayTable(series: DaySeries, reading: DayReading, running: Bool, format: SheetFormat) -> SheetTable {
        let cell = { (v: Double?) in v.map(format.value) ?? String.emptyValue }
        let hours = reading.through.map { Array(0...$0) } ?? []
        if running {
            return SheetTable(columns: ["Hour", "This hour", "So far", "Typical by then"],
                              rows: hours.map { [SheetFormat.hourSpan($0), format.value(series.hours[$0] ?? 0), cell(reading.shown[$0]), cell(series.typical[$0])] })
        }
        return SheetTable(columns: ["Hour", "Average", "Low", "High", "Typical"],
                          rows: hours.map { [SheetFormat.hourSpan($0), cell(series.hours[$0]), cell(series.min?[$0]), cell(series.max?[$0]), cell(series.typical[$0])] })
    }
}

/// The web's ChartCard as the sheet has it: no card of its own, its title and note on the left, and the chart and table
/// switch on the right.
struct SheetChartCard<Chart: View>: View {
    let title: String
    let note: String?
    let table: SheetTable
    @ViewBuilder let chart: Chart
    /// The person's choice; until they make one, the chart (or the table, for a picture of it).
    @State private var chosen: Bool?
    @Environment(\.sheetChartOpensOnTable) private var opensOnTable

    private var asTable: Binding<Bool> {
        Binding(get: { chosen ?? opensOnTable }, set: { chosen = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.app(size: 13, weight: .medium, relativeTo: .footnote)).foregroundStyle(Palette.ink2)
                        .accessibilityAddTraits(.isHeader)
                    if let note {
                        Text(note).font(.app(size: 12, relativeTo: .caption)).foregroundStyle(Palette.ink3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                ViewSwitch(asTable: asTable, title: title)
            }
            if asTable.wrappedValue { SheetTableView(table: table) } else { chart }
        }
    }
}

private struct SheetChartOpensOnTable: EnvironmentKey {
    static let defaultValue = false
}

private struct SheetChartPicksPoint: EnvironmentKey {
    static let defaultValue: Int? = nil
}

extension EnvironmentValues {
    /// The sheet's chart shows its table first (pictures of the sheet's states); the chart otherwise.
    var sheetChartOpensOnTable: Bool {
        get { self[SheetChartOpensOnTable.self] }
        set { self[SheetChartOpensOnTable.self] = newValue }
    }

    /// The point a chart opens with picked, as if under the finger, by its index (pictures of the tooltip); none otherwise.
    var sheetChartPicksPoint: Int? {
        get { self[SheetChartPicksPoint.self] }
        set { self[SheetChartPicksPoint.self] = newValue }
    }
}

/// The chart and table buttons (.seg): two icons in a soft well, the chosen one raised on white.
private struct ViewSwitch: View {
    @Binding var asTable: Bool
    let title: String

    var body: some View {
        HStack(spacing: 0) {
            button("chart.bar.xaxis", "Chart", on: !asTable) { asTable = false }
            button("tablecells", "Table", on: asTable) { asTable = true }
        }
        .padding(3)
        .background(Palette.surface2, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.border))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title) view")
    }

    private func button(_ symbol: String, _ name: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .light))
                .foregroundStyle(on ? Palette.ink : Palette.ink2)
                .frame(width: 32, height: 26)
                .background { if on { Capsule().fill(Palette.surface).tokenShadow(.pill, in: Capsule()) } }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// The table twin: every value readable without touching the chart, newest first, as on the web (ChartCard's table in
/// src/charts/Charts.tsx): the columns' names on a white band over hairlines, every cell on one line (td's nowrap), the
/// columns sharing the width when they fit (SheetTableLayout) and the table scrolling sideways when they don't
/// (.table-wrap's overflow), so no word is ever broken, at any text size. VoiceOver reads it a row at a time.
struct SheetTableView: View {
    let table: SheetTable

    var body: some View {
        ViewThatFits(in: .horizontal) {
            window { grid }
            window {
                ScrollView(.horizontal) { grid }
                    .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                    .scrollIndicatorsFlash(onAppear: true)
            }
        }
    }

    /// A long table scrolls inside 360 points (.table-wrap's max-height), as the web's does; a short one is shown whole.
    @ViewBuilder private func window(@ViewBuilder _ content: () -> some View) -> some View {
        if table.rows.count > 9 {
            ScrollView(.vertical) { content() }
                .frame(height: 360)
                .scrollBounceBehavior(.basedOnSize, axes: .vertical)
        } else {
            content()
        }
    }

    private var grid: some View {
        SheetTableLayout(columns: table.columns.count) {
            ForEach(Array(table.columns.enumerated()), id: \.offset) { _, c in
                cell(Text(c).font(.app(size: 12, weight: .medium, relativeTo: .caption)).foregroundStyle(Palette.ink3), band: true)
                    .accessibilityHidden(true)
            }
            ForEach(Array(table.rows.reversed().enumerated()), id: \.offset) { _, row in
                ForEach(Array(row.enumerated()), id: \.offset) { j, value in
                    // The row's one VoiceOver element is its first cell, which reads the whole row; the others are left out.
                    if j == 0 {
                        cell(Text(value).font(.app(size: 13, relativeTo: .footnote)).foregroundStyle(Palette.ink))
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(Self.spoken(table.columns, row))
                    } else {
                        cell(Text(value).font(.app(size: 13, relativeTo: .footnote)).foregroundStyle(Palette.ink))
                            .accessibilityHidden(true)
                    }
                }
            }
        }
    }

    /// One cell: its words on one line, padded as the web's th and td, filling its column and row, over a hairline. The
    /// names' cells are white, so together they're one even band.
    private func cell(_ text: some View, band: Bool = false) -> some View {
        text
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(band ? Palette.surface : .clear)
            .padding(.bottom, 1)
            .overlay(alignment: .bottom) { Rectangle().fill(Palette.grid).frame(height: 1) }
    }

    /// What VoiceOver says for a row: "Hour: 2 AM–3 AM, Average: 57 bpm, …".
    static func spoken(_ columns: [String], _ row: [String]) -> String {
        zip(columns, row).map { "\($0): \($1)" }.joined(separator: ", ")
    }
}

/// The table's cells, a row at a time, laid out as the web's table (width: 100%, auto layout) with its cells kept to one
/// line: each column at least as wide as its widest cell. When every column fits in an even share of the width, the
/// columns are even; otherwise each is its own width and the room left is shared out evenly. Too wide for the room, it
/// takes its full width, which SheetTableView scrolls sideways.
struct SheetTableLayout: Layout {
    let columns: Int

    struct Cache {
        var widths: [CGFloat]
        var heights: [CGFloat]
    }

    func makeCache(subviews: Subviews) -> Cache {
        var widths = Array(repeating: CGFloat(0), count: max(columns, 1))
        var heights: [CGFloat] = []
        for (i, cell) in subviews.enumerated() {
            let size = cell.sizeThatFits(.unspecified)
            let (row, column) = i.quotientAndRemainder(dividingBy: max(columns, 1))
            if row == heights.count { heights.append(0) }
            widths[column] = max(widths[column], size.width)
            heights[row] = max(heights[row], size.height)
        }
        return Cache(widths: widths, heights: heights)
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache = makeCache(subviews: subviews)
    }

    /// The columns' widths across `room`: even when each fits in an even share, else their own and an even share of the rest.
    static func widths(_ own: [CGFloat], room: CGFloat?) -> [CGFloat] {
        let total = own.reduce(0, +)
        guard let room, room.isFinite, room > total, !own.isEmpty else { return own }
        let even = room / CGFloat(own.count)
        if own.allSatisfy({ $0 <= even }) { return own.map { _ in even } }
        return own.map { $0 + (room - total) / CGFloat(own.count) }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        CGSize(width: Self.widths(cache.widths, room: proposal.width).reduce(0, +), height: cache.heights.reduce(0, +))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let widths = Self.widths(cache.widths, room: bounds.width)
        var y = bounds.minY
        var x = bounds.minX
        for (i, cell) in subviews.enumerated() {
            let (row, column) = i.quotientAndRemainder(dividingBy: max(columns, 1))
            if column == 0, i > 0 {
                y += cache.heights[row - 1]
                x = bounds.minX
            }
            cell.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(width: widths[column], height: cache.heights[row]))
            x += widths[column]
        }
    }
}

// MARK: - A line

/// Readings over the window (TrendChart): a soft area under a smooth line that breaks where days are missing, the
/// window's median dashed with its label, the latest value at the line's end, and a crosshair with a tooltip under the
/// finger.
struct SheetTrendChart: View {
    let points: [Point]
    let format: SheetFormat
    let color: Color
    let label: String
    /// Points further apart than this many days are a gap, and the line breaks there (weekly points need more).
    let gapDays: Int
    /// The tooltip's name for a point's period ("Week of Oct 13"); its date otherwise.
    let period: ((String) -> String)?
    @State private var selected: Date?
    @State private var width: CGFloat = 0
    @Environment(\.sheetChartPicksPoint) private var picks

    /// What the chart draws, worked out once.
    private struct Plan {
        let ticks: [Double]
        let lo: Double
        let hi: Double
        let step: Double?
        let median: Double?
        /// Each point's run (a stretch without a gap), and how many points each run has.
        let runs: [Int]
        let sizes: [Int: Int]
        let last: Int
        let picked: Int?
        let labels: [(index: Int, text: String)]
        let domain: ClosedRange<Date>
    }

    private func x(_ p: Point) -> Date { Fmt.chartDate(p.date) }

    private func when(_ p: Point) -> String { period?(p.date) ?? Fmt.day(p.date, "EEEMMMdyyyy") }

    private var plan: Plan {
        let values = points.map(\.value)
        let ticks = SheetMath.niceTicks(values.min() ?? 0, values.max() ?? 1)
        let lo = ticks.first ?? 0
        let runs = SheetMath.runs(points, gapDays: gapDays)
        let picked = selected.flatMap { s in
            points.indices.min { abs(x(points[$0]).timeIntervalSince(s)) < abs(x(points[$1]).timeIntervalSince(s)) }
        }
        let first = x(points[0]), end = x(points[points.count - 1])
        return Plan(ticks: ticks, lo: lo, hi: ticks.last.map { $0 > lo ? $0 : lo + 1 } ?? lo + 1, step: ticks.count > 1 ? ticks[1] - ticks[0] : nil,
                    median: points.count >= SheetMath.medianMinPoints ? SheetMath.median(values) : nil,
                    runs: runs, sizes: Dictionary(grouping: runs, by: { $0 }).mapValues(\.count), last: points.count - 1, picked: picked,
                    labels: SheetMath.xLabels(points.map(\.date), width: width),
                    domain: first == end ? first.addingTimeInterval(-86_400)...end.addingTimeInterval(86_400) : first...end)
    }

    var body: some View {
        let plan = plan
        Chart {
            line(plan)
            RuleMark(y: .value("Base", plan.lo))
                .foregroundStyle(Palette.axis)
                .lineStyle(StrokeStyle(lineWidth: 1))
                .accessibilityHidden(true)
            if let median = plan.median {
                MedianRule(value: median, text: format.value(median))
            }
            if let picked = plan.picked {
                RuleMark(x: .value("Day", x(points[picked])))
                    .foregroundStyle(Palette.ink3)
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .accessibilityHidden(true)
            }
            let focus = points[plan.picked ?? plan.last]
            PointMark(x: .value("Day", x(focus)), y: .value(label, focus.value))
                .symbol { RingDot(color: color) }
                .accessibilityHidden(true)
        }
        .chartXScale(domain: plan.domain)
        .chartYScale(domain: plan.lo...plan.hi)
        .chartYAxis { yAxis(plan) }
        .chartXAxis { xAxis(plan) }
        .chartXSelection(value: $selected)
        // The latest value over the line's end, its right edge on the point, as the web anchors it. Drawn over the chart
        // rather than as a mark's annotation, which Swift Charts moves off the point.
        .chartOverlay { proxy in
            ZStack {
                endLabel(plan, proxy)
                if let picked = plan.picked {
                    TooltipOverlay(proxy: proxy, x: x(points[picked]), y: points[picked].value, floor: nil) {
                        SheetTooltip(color: color, value: format.value(points[picked].value), label: when(points[picked]))
                    }
                }
            }
        }
        // The web's top margin: room for the end label over a high last value.
        .frame(height: 200)
        .padding(.top, 20)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onAppear { if let picks, points.indices.contains(picks) { selected = x(points[picks]) } }
        .accessibilityLabel(plan.median.map { "\(label), median \(format.value($0))" } ?? label)
    }

    /// A soft area under a smooth line for each run of two or more points; a dot for a point on its own.
    @ChartContentBuilder private func line(_ plan: Plan) -> some ChartContent {
        ForEach(Array(points.enumerated()), id: \.offset) { i, p in
            let run = plan.runs[i]
            if plan.sizes[run, default: 0] > 1 {
                AreaMark(x: .value("Day", x(p)), yStart: .value("Base", plan.lo), yEnd: .value(label, p.value), series: .value("Part", "area \(run)"))
                    .foregroundStyle(color.opacity(0.1))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Day", x(p)), y: .value(label, p.value), series: .value("Part", "line \(run)"))
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
                    .accessibilityLabel(when(p))
                    .accessibilityValue(format.value(p.value))
            } else {
                PointMark(x: .value("Day", x(p)), y: .value(label, p.value))
                    .foregroundStyle(color)
                    .symbolSize(28)
                    .accessibilityLabel(when(p))
                    .accessibilityValue(format.value(p.value))
            }
        }
    }

    private func yAxis(_ plan: Plan) -> some AxisContent {
        AxisMarks(position: .leading, values: plan.ticks) { v in
            AxisGridLine().foregroundStyle(Palette.grid)
            AxisValueLabel { if let n = v.as(Double.self) { Text(format.tick(n, step: plan.step)) } }.font(.axis)
                .foregroundStyle(Palette.ink3)
        }
    }

    private func xAxis(_ plan: Plan) -> some AxisContent {
        AxisMarks(values: plan.labels.map { x(points[$0.index]) }) { v in
            if let i = plan.labels.firstIndex(where: { x(points[$0.index]) == v.as(Date.self) }) {
                let anchor: UnitPoint = plan.labels[i].index == 0 ? .topLeading : plan.labels[i].index == plan.last ? .topTrailing : .top
                AxisValueLabel(anchor: anchor) { Text(plan.labels[i].text) }.font(.axis)
                    .foregroundStyle(Palette.ink3)
            }
        }
    }

    private func endLabel(_ plan: Plan, _ proxy: ChartProxy) -> some View {
        GeometryReader { geo in
            let end = points[plan.last]
            if plan.picked == nil, let frame = proxy.plotFrame, let at = proxy.position(for: (x: x(end), y: end.value)) {
                let plot = geo[frame]
                EndLabel(text: format.value(end.value))
                    .fixedSize()
                    .frame(width: 0, height: 0, alignment: .bottomTrailing)
                    .position(x: plot.minX + at.x, y: plot.minY + at.y - 8)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Bars

/// A day's total over the window (BarChart): a bar a day, the latest in the accent blue, the goal as a quiet line, the
/// window's median dashed, and the bar under the finger lit with a tooltip.
struct SheetBarChart: View {
    let points: [Point]
    let format: SheetFormat
    let label: String
    let period: ((String) -> String)?
    /// Steps' daily goal, when the bars are days.
    let goal: Double?
    @State private var selected: String?
    @State private var width: CGFloat = 0
    @Environment(\.sheetChartPicksPoint) private var picks

    var body: some View {
        let values = points.map(\.value)
        let ticks = SheetMath.niceTicks(0, max(values.max() ?? 0, goal ?? 0, 1))
        let hi = max(ticks.last ?? 1, 1)
        let step = ticks.count > 1 ? ticks[1] - ticks[0] : nil
        let mid = points.count >= SheetMath.medianMinPoints ? SheetMath.median(values) : nil
        let n = points.count
        // The web's bar: its slot less a 2-point gap, 24 at most (the plot is the width less its 58 points of margin).
        let slot = n > 0 ? max(0, width - 58) / CGFloat(n) : 0
        let barWidth = max(1, min(24, slot - 2))
        let picked = selected.flatMap { s in points.firstIndex { $0.date == s } }
        let labels = SheetMath.xLabels(points.map(\.date), width: width)
        let dateText = period ?? { Fmt.day($0, "EEEMMMd") }

        Chart {
            ForEach(Array(points.enumerated()), id: \.offset) { i, p in
                BarMark(x: .value("Day", p.date), y: .value(label, p.value), width: .fixed(barWidth))
                    .foregroundStyle(i == picked ? Palette.barAccent.opacity(0.75) : i == n - 1 ? Palette.barAccent : Palette.bar)
                    .cornerRadius(min(4, barWidth / 2))
                    .accessibilityLabel(dateText(p.date))
                    .accessibilityValue(format.value(p.value))
            }
            RuleMark(y: .value("Base", 0))
                .foregroundStyle(Palette.axis)
                .lineStyle(StrokeStyle(lineWidth: 1))
                .accessibilityHidden(true)
            if let goal {
                RuleMark(y: .value("Goal", goal))
                    .foregroundStyle(Palette.ink3.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, alignment: .trailing, spacing: 2) {
                        Text("Goal \(SheetFormat.compact(goal))").font(.axis).foregroundStyle(Palette.ink3)
                    }
                    .accessibilityLabel("Goal")
                    .accessibilityValue(format.value(goal))
            }
            // Over the bars, so the line isn't hidden behind them.
            if let mid {
                MedianRule(value: mid, text: format.value(mid))
            }
        }
        .chartXScale(domain: points.map(\.date))
        .chartYScale(domain: 0...hi)
        .chartYAxis {
            AxisMarks(position: .leading, values: ticks) { v in
                AxisGridLine().foregroundStyle(Palette.grid)
                AxisValueLabel { if let n = v.as(Double.self) { Text(format.tick(n, step: step)) } }.font(.axis)
                    .foregroundStyle(Palette.ink3)
            }
        }
        .chartXAxis {
            AxisMarks(values: labels.map { points[$0.index].date }) { v in
                if let i = labels.firstIndex(where: { points[$0.index].date == v.as(String.self) }) {
                    let anchor: UnitPoint = labels[i].index == 0 ? .topLeading : labels[i].index == n - 1 ? .topTrailing : .top
                    AxisValueLabel(anchor: anchor) { Text(labels[i].text) }.font(.axis)
                        .foregroundStyle(Palette.ink3)
                }
            }
        }
        .chartXSelection(value: $selected)
        .chartOverlay { proxy in
            if let picked {
                // Kept clear of the top, as the web keeps it 20 points into the plot.
                TooltipOverlay(proxy: proxy, x: points[picked].date, y: points[picked].value, floor: 20) {
                    SheetTooltip(color: nil, value: format.value(points[picked].value), label: dateText(points[picked].date))
                }
            }
        }
        .frame(height: 220)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onAppear { if let picks, points.indices.contains(picks) { selected = points[picks].date } }
        .accessibilityLabel(mid.map { "\(label), median \(format.value($0))" } ?? label)
    }
}

// MARK: - The day by the hour

/// One day's hours against the typical day: the Day view's own chart (HoursChart), or, with no hour drawn yet, the
/// web's dashed empty box.
private struct SheetDayChart: View {
    let hour: HourMetric
    let series: DaySeries
    let reading: DayReading
    let goal: Double?
    let label: String

    var body: some View {
        let drawn = reading.shown.contains { $0 != nil } || series.typical.contains { $0 != nil }
        if reading.through != nil, drawn {
            HoursChart(metric: hour, series: series, reading: reading, goal: goal, label: label)
                .frame(height: 220)
        } else {
            Text(series.total != nil ? "No hourly readings on this day" : "No readings on this day")
                .font(.app(.footnote))
                .foregroundStyle(Palette.ink3)
                .frame(maxWidth: .infinity, minHeight: 220)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.axis, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
        }
    }
}

// MARK: - Marks

/// The window's median: a dashed line, labelled at its left end (the latest-value and goal labels sit on the right).
private struct MedianRule: ChartContent {
    let value: Double
    let text: String

    var body: some ChartContent {
        RuleMark(y: .value("Median", value))
            .foregroundStyle(Palette.ink2.opacity(0.75))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            .annotation(position: .top, alignment: .leading, spacing: 2) {
                Text("Median \(text)")
                    .font(.app(fixedSize: 11, weight: .medium))
                    .foregroundStyle(Palette.ink2)
                    // The web's halo in the surface colour, so the label reads over the data.
                    .shadow(color: Palette.surface, radius: 1)
                    .shadow(color: Palette.surface, radius: 1)
                    .padding(.leading, 4)
            }
            .accessibilityLabel("Median")
            .accessibilityValue(text)
    }
}

/// The dot at the line's end, or under the finger: the series colour in a white ring.
private struct RingDot: View {
    let color: Color
    var body: some View {
        Circle().fill(color).frame(width: 9, height: 9).overlay(Circle().stroke(Palette.surface, lineWidth: 2))
    }
}

/// The latest value over the line's end.
private struct EndLabel: View {
    let text: String
    var body: some View {
        Text(text).font(.app(fixedSize: 12, weight: .semibold)).foregroundStyle(Palette.ink)
    }
}

/// Where the web puts its tooltip (Tooltip in src/charts/core.tsx): beside the point, 12 points to its right, or to its
/// left within 150 points of the chart's right edge, and level with it. Drawn over the chart rather than as a mark's
/// annotation, which Swift Charts lifts above the plot onto the chart's head.
private struct TooltipOverlay<X: Plottable, Content: View>: View {
    let proxy: ChartProxy
    let x: X
    let y: Double
    /// The least distance from the plot's top, for a bar's tooltip; none for a line's.
    let floor: CGFloat?
    @ViewBuilder let content: Content

    var body: some View {
        GeometryReader { geo in
            if let frame = proxy.plotFrame, let px = proxy.position(forX: x), let py = proxy.position(forY: y) {
                let plot = geo[frame]
                let flip = plot.minX + px > geo.size.width - 150
                content
                    .fixedSize()
                    .frame(width: 0, height: 0, alignment: flip ? .trailing : .leading)
                    .position(x: plot.minX + px + (flip ? -12 : 12), y: plot.minY + max(py, floor ?? -.infinity))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The tooltip (.tooltip): the series key, the value in bold and what it is, on the dark tooltip ink.
private struct SheetTooltip: View {
    let color: Color?
    let value: String
    let label: String

    var body: some View {
        HStack(spacing: 8) {
            if let color { Capsule().fill(color).frame(width: 12, height: 2) }
            Text(value).font(.app(fixedSize: 12, weight: .semibold))
            Text(label).font(.app(fixedSize: 12)).opacity(0.7)
        }
        .foregroundStyle(Palette.tooltipInk)
        .lineLimit(1)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Palette.tooltip, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 6)
    }
}
