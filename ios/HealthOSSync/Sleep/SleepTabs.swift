import Charts
import SwiftUI

// The Sleep page's other tabs (Sleep.tsx StagesTab, TrendsTab, CoachingTab): the stages over a range of nights, the
// sleep metrics' trends, and coaching from the person's own nights. The charts pick a night under a tap or a sideways
// drag, and a drag up or down scrolls the page (`chartScrub`).

// MARK: - A chart card

/// A chart with its title, value and note, and a switch to see it as a table (Charts.tsx ChartCard). The table lists
/// the newest first, in a window that scrolls.
struct SleepChartCard<Chart: View>: View {
    let title: String
    let value: String
    let note: String
    var legend: [(label: String, color: Color)] = []
    let columns: [String]
    let rows: [[String]]
    @ViewBuilder let chart: Chart
    @State private var table = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.app(size: 13, weight: .medium, relativeTo: .footnote)).foregroundStyle(Palette.ink2)
                        .accessibilityAddTraits(.isHeader)
                    Text(value).font(.app(size: 26, weight: .medium, relativeTo: .title)).tracking(-0.52).foregroundStyle(Palette.ink)
                        .padding(.top, 2)
                    Text(note).font(.app(size: 12, relativeTo: .caption)).foregroundStyle(Palette.ink3).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                SleepChartTableSwitch(title: title, table: $table)
            }
            if !legend.isEmpty { ChartLegend(legend).padding(.top, 14) }
            if table {
                SleepTable(columns: columns, rows: rows).padding(.top, 12)
            } else {
                chart.padding(.top, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
        .accessibilityElement(children: .contain)
    }
}

/// Chart or table (.seg): two icons in a soft well, the one showing raised on white.
private struct SleepChartTableSwitch: View {
    let title: String
    @Binding var table: Bool

    var body: some View {
        HStack(spacing: 0) {
            option("chart.bar", "Chart", on: !table) { table = false }
            option("tablecells", "Table", on: table) { table = true }
        }
        .padding(3)
        .background(Palette.surface2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.border))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title) view")
    }

    private func option(_ symbol: String, _ name: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14, weight: .medium))
                .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                .foregroundStyle(on ? Palette.ink : Palette.ink2)
                .frame(width: 34, height: 30)
                .background { if on { RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.surface).shadow(color: .black.opacity(0.08), radius: 1, y: 1) } }
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, -7)
        .accessibilityLabel(name)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// The chart's values as a table, newest first: one line a cell, scrolling sideways when wider than the card and up and
/// down in its window.
struct SleepTable: View {
    let columns: [String]
    let rows: [[String]]
    @Environment(\.duoTableWindow) private var window

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(columns.enumerated()), id: \.offset) { _, c in
                        Text(c).font(.app(size: 12, weight: .medium, relativeTo: .caption)).foregroundStyle(Palette.ink3).lineLimit(1).fixedSize()
                            .padding(.horizontal, 10).padding(.vertical, 8)
                    }
                }
                Divider().overlay(Palette.grid)
                ForEach(Array(rows.reversed().enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(cell).font(.app(size: 13, relativeTo: .footnote)).foregroundStyle(Palette.ink).lineLimit(1).fixedSize()
                                .padding(.horizontal, 10).padding(.vertical, 8)
                        }
                    }
                    Divider().overlay(Palette.grid)
                }
            }
        }
        .frame(maxHeight: window)
        .accessibilityLabel("Table")
    }
}

// MARK: - Stages

/// The nights' stages stacked (Charts.tsx StackedBars): one bar a night (or a week past 90 days), deep at the bottom.
/// A tap or a sideways drag picks a night and reads its stages and total.
struct SleepStagesChart: View {
    let nights: SleepStageNights
    let days: Int
    @State private var picked: Date?

    struct Bar: Identifiable {
        let date: String
        let stage: String
        let hours: Double
        var id: String { date + stage }
    }

    var body: some View {
        let bars = nights.rows.flatMap { r in SleepStageNights.stages.compactMap { s in r.values[s.key].map { Bar(date: r.date, stage: s.label, hours: $0) } } }
        let unit: Calendar.Component = nights.weekly ? .weekOfYear : .day
        let chosen = picked.flatMap { p in nights.rows.min { abs(Fmt.chartDate($0.date).timeIntervalSince(p)) < abs(Fmt.chartDate($1.date).timeIntervalSince(p)) } }
        if bars.isEmpty {
            Text("No data in this range").font(.app(.footnote)).foregroundStyle(Palette.ink3)
                .frame(maxWidth: .infinity, minHeight: 120)
        } else {
            Chart {
                ForEach(bars) { b in
                    BarMark(x: .value("Night", Fmt.chartDate(b.date), unit: unit), y: .value("Hours", b.hours))
                        .foregroundStyle(by: .value("Stage", b.stage))
                        .opacity(chosen == nil || chosen?.date == b.date ? 1 : 0.55)
                }
                if let chosen {
                    RuleMark(x: .value("Night", Fmt.chartDate(chosen.date), unit: unit))
                        .foregroundStyle(.clear)
                        .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            SleepTooltip(title: nights.weekly ? "Week of \(Fmt.day(chosen.date))" : Fmt.day(chosen.date, "EEEMMMd"),
                                         rows: SleepStageNights.stages.reversed().map { ($0.color, $0.label, Fmt.hoursMinutes(chosen.values[$0.key] ?? 0)) }
                                            + [(nil, "Total", Fmt.hoursMinutes(SleepStageNights.total(chosen)))])
                        }
                }
            }
            .chartForegroundStyleScale(domain: SleepStageNights.stages.map(\.label), range: SleepStageNights.stages.map(\.color))
            .chartLegend(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { v in
                    AxisGridLine().foregroundStyle(Palette.grid)
                    AxisValueLabel { if let h = v.as(Double.self) { Text("\(Fmt.number(h))h") } }.font(.axis).foregroundStyle(Palette.ink3)
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day()).font(.axis).foregroundStyle(Palette.ink3)
                }
            }
            .chartScrub($picked)
            .duoChartHeight(240)
            .accessibilityLabel("Sleep stages per night")
        }
    }
}

/// A chart's reading at the night picked: its date, then each part with its colour (Charts.tsx Tooltip).
struct SleepTooltip: View {
    let title: String
    let rows: [(color: Color?, label: String, value: String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.app(size: 11, weight: .semibold, relativeTo: .caption2))
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                HStack(spacing: 5) {
                    if let c = r.color { RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 8, height: 8) }
                    Text(r.value).font(.app(size: 11, weight: .semibold, relativeTo: .caption2))
                    Text(r.label).font(.app(size: 11, relativeTo: .caption2)).opacity(0.75)
                }
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .foregroundStyle(Palette.tooltipInk)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Palette.tooltip, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// The stages chart in its card, with its table (StagesTab's ChartCard).
struct SleepStagesChartCard: View {
    let nights: SleepStageNights
    let days: Int

    var body: some View {
        SleepChartCard(title: nights.weekly ? "Sleep stages, weekly average" : "Sleep stages",
                       value: nights.average.map(Fmt.hoursMinutes) ?? String.emptyValue, note: "average time asleep",
                       legend: SleepStageNights.stages.map { ($0.label, $0.color) },
                       columns: ["Night"] + SleepStageNights.stages.map(\.label),
                       rows: nights.rows.map { r in [Fmt.day(r.date, "yMMMd")] + SleepStageNights.stages.map { Fmt.hoursMinutes(r.values[$0.key] ?? 0) } }) {
            SleepStagesChart(nights: nights, days: days)
        }
        .accessibilityIdentifier("card-sleep.stagesChart")
    }
}

/// An average night (StagesTab): each stage's time and share over the nights with stages.
struct SleepAverageNightCard: View {
    let nights: SleepStageNights

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 12) { heading; Spacer(minLength: 0); count }
                VStack(alignment: .leading, spacing: 4) { heading; count }
            }
            .padding(.bottom, 14)
            SleepFigureGrid(items: nights.totals.map { SleepFigureItem(id: $0.key, label: $0.label, color: $0.color, hours: $0.hours, share: $0.share) }) {
                SleepStageFigure(label: $0.label, color: $0.color, hours: $0.hours, share: $0.share)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("card-sleep.averageNight")
    }

    private var heading: some View {
        Text("An average night").font(.app(size: 15, weight: .medium, relativeTo: .subheadline)).foregroundStyle(Palette.ink)
            .accessibilityAddTraits(.isHeader)
    }

    private var count: some View {
        Text("\(nights.nights.count) nights with stages").font(.app(.footnote)).foregroundStyle(Palette.ink3)
    }
}

// MARK: - Trends

/// One sleep metric over the range (Detail.tsx Trend): the latest value, its date with the range's average, a line with
/// the range's median dashed across it, and its table. A tap or a sideways drag reads a day.
struct SleepTrendCard: View {
    let title: String
    let points: [Point]
    let format: (Double) -> String
    var tick: ((Double) -> String)?
    var unitNote: String?
    var color: Color = Palette.series1

    var body: some View {
        let last = points.last
        let avg = points.average
        var note = "No data in this range"
        if let last {
            note = Fmt.day(last.date)
            if let avg { note += " · average \(format(avg))" }
            if let unitNote { note += " · \(unitNote)" }
        }
        return SleepChartCard(title: title, value: last.map { format($0.value) } ?? String.emptyValue, note: note,
                              columns: ["Date", title], rows: points.map { [Fmt.day($0.date, "yMMMd"), format($0.value)] }) {
            SleepTrendChart(title: title, points: points, format: format, tick: tick ?? format, color: color)
        }
        .accessibilityIdentifier("card-sleep.trend.\(title)")
    }

    /// The median of what's plotted, once there are five points (Charts.tsx medianOf).
    static func median(_ points: [Point]) -> Double? {
        guard points.count >= 5 else { return nil }
        let s = points.map(\.value).sorted()
        let mid = s.count / 2
        return s.count % 2 == 1 ? s[mid] : (s[mid - 1] + s[mid]) / 2
    }

    /// Runs of points with no gap longer than three days, so the line breaks where nights are missing.
    static func runs(_ points: [Point]) -> [[Point]] {
        var out: [[Point]] = []
        for p in points {
            if let prev = out.last?.last, Fmt.daysBetween(prev.date, p.date) <= 3 { out[out.count - 1].append(p) } else { out.append([p]) }
        }
        return out
    }
}

private struct SleepTrendChart: View {
    let title: String
    let points: [Point]
    let format: (Double) -> String
    let tick: (Double) -> String
    let color: Color
    @State private var picked: Date?

    var body: some View {
        if points.isEmpty {
            Text("No data in this range").font(.app(.footnote)).foregroundStyle(Palette.ink3).frame(maxWidth: .infinity, minHeight: 120)
        } else {
            let values = points.map(\.value)
            let lo = values.min() ?? 0, hi = values.max() ?? 1
            let pad = Swift.max((hi - lo) * 0.15, 0.25)
            let domain = (lo - pad)...(hi + pad)
            let median = SleepTrendCard.median(points)
            let chosen = picked.flatMap { s in points.min { abs(Fmt.chartDate($0.date).timeIntervalSince(s)) < abs(Fmt.chartDate($1.date).timeIntervalSince(s)) } }
            let runs = SleepTrendCard.runs(points)
            Chart {
                ForEach(Array(runs.enumerated()), id: \.offset) { i, run in
                    ForEach(run) { p in
                        AreaMark(x: .value("Day", Fmt.chartDate(p.date)), yStart: .value("Base", domain.lowerBound), yEnd: .value(title, p.value),
                                 series: .value("Run", i))
                            .foregroundStyle(LinearGradient(colors: [color.opacity(0.18), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("Day", Fmt.chartDate(p.date)), y: .value(title, p.value), series: .value("Run", i))
                            .foregroundStyle(color)
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                            .interpolationMethod(.monotone)
                    }
                }
                if let median {
                    RuleMark(y: .value("Median", median))
                        .foregroundStyle(Palette.ink2.opacity(0.75))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .annotation(position: .top, alignment: .leading) {
                            Text("Median \(format(median))").font(.axis).foregroundStyle(Palette.ink2)
                        }
                }
                if let last = points.last {
                    PointMark(x: .value("Day", Fmt.chartDate(last.date)), y: .value(title, last.value)).foregroundStyle(color).symbolSize(40)
                }
                if let chosen {
                    RuleMark(x: .value("Day", Fmt.chartDate(chosen.date)))
                        .foregroundStyle(Palette.ink3.opacity(0.5))
                        .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            SleepTooltip(title: Fmt.day(chosen.date, "EEEMMMd"), rows: [(color, title, format(chosen.value))])
                        }
                    PointMark(x: .value("Day", Fmt.chartDate(chosen.date)), y: .value(title, chosen.value)).foregroundStyle(color)
                }
            }
            .chartYScale(domain: domain)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { v in
                    AxisGridLine().foregroundStyle(Palette.grid)
                    AxisValueLabel { if let d = v.as(Double.self) { Text(tick(d)) } }.font(.axis).foregroundStyle(Palette.ink3)
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day()).font(.axis).foregroundStyle(Palette.ink3)
                }
            }
            .chartScrub($picked)
            .duoChartHeight(200)
            .accessibilityLabel(median.map { "\(title) trend, median \(format($0))" } ?? "\(title) trend")
        }
    }
}

/// The Trends tab's cards (TrendsTab): time asleep always, the rest only when the range has them.
enum SleepTrendCards {
    struct Spec: Identifiable {
        let id: String
        let title: String
        let points: [Point]
        let format: (Double) -> String
        var tick: ((Double) -> String)?
        var note: String?
        var color: Color = Palette.series1
    }

    static func specs(_ t: Trends) -> [Spec] {
        let pct = { (v: Double) in "\(Fmt.number(v))%" }
        let h = { (v: Double) in "\(Fmt.number(v))h" }
        let has = { (m: String) in !(t[m] ?? []).isEmpty }
        var out = [Spec(id: "sleep_hours", title: "Time asleep", points: t["sleep_hours"] ?? [], format: Fmt.hoursMinutes, tick: h)]
        if has("sleep_performance") {
            out.append(Spec(id: "sleep_performance", title: "Sleep performance", points: t["sleep_performance"]!, format: pct, note: "WHOOP: sleep vs sleep needed", color: Palette.series3))
        }
        // WHOOP's and a Fitbit export's own figures; an Apple Watch night's is worked out on the Overview only.
        if has("sleep_efficiency") {
            out.append(Spec(id: "sleep_efficiency", title: "Sleep efficiency", points: t["sleep_efficiency"]!, format: pct, note: "Time asleep ÷ time in bed", color: Palette.series3))
        }
        if has("sleep_in_bed") { out.append(Spec(id: "sleep_in_bed", title: "Time in bed", points: t["sleep_in_bed"]!, format: Fmt.hoursMinutes, tick: h)) }
        if has("sleep_consistency") {
            out.append(Spec(id: "sleep_consistency", title: "Sleep consistency", points: t["sleep_consistency"]!, format: pct, note: "WHOOP", color: Palette.series3))
        }
        if has("sleep_deep") { out.append(Spec(id: "sleep_deep", title: "Deep sleep", points: t["sleep_deep"]!, format: Fmt.hoursMinutes, tick: h, color: Palette.stageDeep)) }
        if has("sleep_rem") { out.append(Spec(id: "sleep_rem", title: "REM sleep", points: t["sleep_rem"]!, format: Fmt.hoursMinutes, tick: h, color: Palette.stageRem)) }
        return out
    }
}

// MARK: - Coaching

/// A coaching number (.card.metric): its name, the figure with a word under it, and what it means at the foot.
struct SleepCoachCard: View {
    let title: String
    let value: String
    let unit: String
    let foot: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.app(.footnote, weight: .medium)).foregroundStyle(Palette.ink).accessibilityAddTraits(.isHeader)
            Text(value).font(.app(size: 40, weight: .medium, relativeTo: .largeTitle)).tracking(-1.2).foregroundStyle(Palette.ink)
                .lineLimit(1).minimumScaleFactor(0.6)
                .padding(.top, 6)
            Text(unit).font(.app(size: 13, relativeTo: .footnote)).foregroundStyle(Palette.ink2).padding(.top, 6)
            Spacer(minLength: 24)
            Text(foot).font(.app(size: 12, relativeTo: .caption)).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(minHeight: 176 - 38, alignment: .topLeading)
        .card()
        .accessibilityElement(children: .combine)
    }
}

/// Usual times (CoachingTab): bedtime and wake time, each with its spread, and how weekends differ.
struct SleepUsualTimesCard: View {
    let stats: SleepTiming.Stats
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Usual times").font(.app(.footnote, weight: .medium)).foregroundStyle(Palette.ink).accessibilityAddTraits(.isHeader)
            let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
            layout {
                time("Bedtime", stats.avgBedMin.map(SleepWords.fromSix), stats.bedSd)
                time("Wake", stats.avgWakeMin.map(SleepWords.ofDay), stats.wakeSd)
            }
            .padding(.top, 10)
            Spacer(minLength: 24)
            Text(SleepWords.usualTimesFoot(stats)).font(.app(size: 12, relativeTo: .caption)).foregroundStyle(Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(minHeight: 176 - 38, alignment: .topLeading)
        .card()
        .accessibilityElement(children: .contain)
    }

    private func time(_ label: String, _ value: String?, _ sd: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.app(size: 12, relativeTo: .caption)).foregroundStyle(Palette.ink3)
            Text(value ?? String.emptyValue).font(.app(size: 30, weight: .medium, relativeTo: .title)).tracking(-0.6).foregroundStyle(Palette.ink)
                .lineLimit(1).minimumScaleFactor(0.6)
            if let sd { Text("± \(Int(sd.rounded())) min").font(.app(size: 12, relativeTo: .caption)).foregroundStyle(Palette.ink3) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// What goes with your better nights (CoachingTab): the sleep patterns from the person's own days, worded as what tends
/// to go together, never as causes, and the web's note saying so.
struct SleepPatternsCard: View {
    /// nil until /patterns answers, or when it can't: the card stays, with no rows and no date range.
    let patterns: Patterns?

    var body: some View {
        let rows = (patterns?.patterns ?? []).filter { $0.page == "sleep" }
        VStack(alignment: .leading, spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 12) { heading; Spacer(minLength: 0); range }
                VStack(alignment: .leading, spacing: 4) { heading; range }
            }
            .padding(.bottom, 14)
            if rows.isEmpty {
                Text(SleepWords.patternsEmpty).font(.app(size: 13, relativeTo: .footnote)).foregroundStyle(Palette.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(rows) { p in
                let (symbol, tone) = SleepInsightRow.style(p.icon ?? "spark")
                HStack(spacing: 12) {
                    Image(systemName: symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                        .foregroundStyle(tone.ink)
                        .frame(width: 36, height: 36)
                        .background(tone.background, in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.text).font(.app(size: 13, weight: .medium, relativeTo: .footnote)).foregroundStyle(Palette.ink).fixedSize(horizontal: false, vertical: true)
                        if let d = p.detail { Text(d).font(.app(size: 12, relativeTo: .caption)).foregroundStyle(Palette.ink3).fixedSize(horizontal: false, vertical: true) }
                    }
                }
                .padding(.vertical, 8)
                .accessibilityElement(children: .combine)
            }
            Text(SleepWords.patternsNote).font(.app(size: 12, relativeTo: .caption)).foregroundStyle(Palette.ink3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("card-sleep.patterns")
    }

    private var heading: some View {
        Text("What goes with your better nights").font(.app(size: 15, weight: .medium, relativeTo: .subheadline)).foregroundStyle(Palette.ink)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder private var range: some View {
        if let patterns {
            Text("\(Fmt.day(patterns.start)) – \(Fmt.day(patterns.end))").font(.app(.footnote)).foregroundStyle(Palette.ink3)
        }
    }
}

/// Coaching with fewer than seven nights: the web's words.
struct SleepCoachingWaits: View {
    let nights: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Coaching").font(.app(size: 15, weight: .medium, relativeTo: .subheadline)).foregroundStyle(Palette.ink).accessibilityAddTraits(.isHeader)
            Text(SleepWords.needsAWeek(nights)).font(.app(.footnote)).foregroundStyle(Palette.ink3).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("card-sleep.coachingWaits")
    }
}
