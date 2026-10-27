import Charts
import SwiftUI

/// One of "Your trends" (Detail.tsx Trend on TrendChart): the latest value, its date with the range's average and the
/// card's note, and the line over the range with its median dashed and the latest reading ringed. A tap, or a finger
/// moved sideways along the line, reads one day; a drag up or down scrolls the page (`chartScrub`), as the web's charts
/// do on a phone. The chart is 200 pt tall on a phone and beside the fold, a third taller on the inner display upright.
struct VitalsTrendCard: View {
    let trend: VitalsTrend
    @State private var selected: Date?
    /// The web's chart and table switch (ChartCard): the chart until the person picks the table.
    @State private var asTable = false
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let points = trend.points
        VStack(alignment: .leading, spacing: 6) {
            // The switch beside the words, as the web's head; under them at the accessibility sizes.
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) {
                    head
                    if !points.isEmpty { ViewSwitch(asTable: $asTable, title: trend.title) }
                }
            } else {
                HStack(alignment: .top, spacing: 12) {
                    head
                    Spacer(minLength: 0)
                    if !points.isEmpty { ViewSwitch(asTable: $asTable, title: trend.title) }
                }
            }
            if !points.isEmpty {
                if asTable {
                    SheetTableView(table: VitalsTrendCards.table(trend))
                        .padding(.top, 6)
                } else {
                    VitalsTrendChart(trend: trend, selected: $selected)
                        .duoChartHeight(200)
                        .padding(.top, 6)
                }
            }
        }
        // As tall as its row, where cards share one.
        .frame(maxHeight: .infinity, alignment: .top)
        .card()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("vitals-trend-\(trend.id)")
    }

    private var head: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(trend.title).font(.app(.subheadline, weight: .medium)).foregroundStyle(Palette.ink2)
                .accessibilityAddTraits(.isHeader)
            Text(trend.points.last.map { trend.format($0.value) } ?? String.emptyValue)
                .font(.app(.title2, weight: .semibold)).foregroundStyle(Palette.ink).monospacedDigit()
            Text(VitalsTrendCards.note(trend))
                .font(.app(.caption)).foregroundStyle(Palette.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The line itself (TrendChart): a soft area under a smooth line, the range's median dashed with its label once there
/// are five readings, the latest reading ringed, and the day under the finger with its value.
private struct VitalsTrendChart: View {
    let trend: VitalsTrend
    @Binding var selected: Date?

    var body: some View {
        let points = trend.points
        let values = points.map(\.value)
        let lo = values.min() ?? 0, hi = values.max() ?? 1
        let pad = Swift.max((hi - lo) * 0.15, 0.5)
        let domain = (lo - pad)...(hi + pad)
        let median = VitalsTrendCards.median(values)
        let picked = selected.flatMap { s in points.min { abs(Fmt.chartDate($0.date).timeIntervalSince(s)) < abs(Fmt.chartDate($1.date).timeIntervalSince(s)) } }
        let color = trend.color
        Chart {
            ForEach(points) { p in
                AreaMark(x: .value("Day", Fmt.chartDate(p.date)), yStart: .value("Base", domain.lowerBound), yEnd: .value(trend.title, p.value))
                    .foregroundStyle(LinearGradient(colors: [color.opacity(0.22), color.opacity(0)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Day", Fmt.chartDate(p.date)), y: .value(trend.title, p.value))
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                    .interpolationMethod(.monotone)
                    .accessibilityLabel(Fmt.day(p.date))
                    .accessibilityValue(trend.format(p.value))
            }
            if let median {
                // Dashed; its label is drawn over the plot (labels, below), as the web writes it.
                RuleMark(y: .value("Median", median))
                    .foregroundStyle(Palette.ink3)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .accessibilityHidden(true)
            }
            if let last = points.last, picked == nil {
                PointMark(x: .value("Day", Fmt.chartDate(last.date)), y: .value(trend.title, last.value))
                    .foregroundStyle(color)
                    .symbolSize(40)
                    .accessibilityHidden(true)
            }
            if let picked {
                RuleMark(x: .value("Day", Fmt.chartDate(picked.date)))
                    .foregroundStyle(Palette.ink3.opacity(0.5))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        VStack(spacing: 1) {
                            Text(trend.format(picked.value)).font(.app(.caption, weight: .semibold))
                            Text(Fmt.day(picked.date)).font(.app(.caption2))
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Palette.surface2, in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(Palette.ink)
                    }
                    .accessibilityHidden(true)
                PointMark(x: .value("Day", Fmt.chartDate(picked.date)), y: .value(trend.title, picked.value))
                    .foregroundStyle(color)
                    .accessibilityHidden(true)
            }
        }
        .chartYScale(domain: domain)
        // The median's label and the latest reading's, placed from the chart's own scale: Swift Charts' mark
        // annotations didn't draw here (a RuleMark's and a PointMark's), so they're laid over the plot instead.
        .chartOverlay { proxy in
            VitalsTrendLabels(proxy: proxy, trend: trend, median: median, last: picked == nil ? points.last : nil)
        }
        // A tap or a sideways drag picks a day; a drag up or down scrolls the page (README: charts and scrolling).
        .chartScrub($selected)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(Palette.grid)
                AxisValueLabel().font(.axis).foregroundStyle(Palette.ink3)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                AxisValueLabel(format: .dateTime.month(.abbreviated).day()).font(.axis).foregroundStyle(Palette.ink3)
            }
        }
        .accessibilityLabel(median.map { "\(trend.title) trend, median \(trend.format($0))" } ?? "\(trend.title) trend")
    }
}

/// The web's two labels on a trend line (Charts.tsx MedianLabel and end-label): "Median …" just above the dashed line at
/// the plot's leading edge (below it when that would run into the plot's top), and the latest value above its dot,
/// ending at the dot. Drawn over the plot, never taking a touch.
struct VitalsTrendLabels: View {
    let proxy: ChartProxy
    let trend: VitalsTrend
    let median: Double?
    let last: Point?

    var body: some View {
        GeometryReader { geo in
            let plot = proxy.plotFrame.map { geo[$0] } ?? CGRect(origin: .zero, size: geo.size)
            // Each label in a frame of the chart's own size, so its guides place it from the chart's top-leading corner.
            ZStack(alignment: .topLeading) {
                if let median, let y = proxy.position(forY: median) {
                    // Above the line, unless that would run into the plot's top (the web's MedianLabel).
                    let above = y - 6 >= 14
                    Text("Median \(trend.format(median))")
                        .font(.app(.caption2))
                        .foregroundStyle(Palette.ink2)
                        .fixedSize()
                        .alignmentGuide(.leading) { _ in -(plot.minX + 4) }
                        .alignmentGuide(.top) { d in -(plot.minY + y + (above ? -6 : 4)) + (above ? d.height : 0) }
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                }
                if let last, let x = proxy.position(forX: Fmt.chartDate(last.date)), let y = proxy.position(forY: last.value) {
                    Text(trend.format(last.value))
                        .font(.app(.caption, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                        .fixedSize()
                        .alignmentGuide(.leading) { d in -(plot.minX + x) + d.width }
                        // Above the dot, kept inside the chart when the dot is at the plot's top.
                        .alignmentGuide(.top) { d in -max(0, plot.minY + y - 8 - d.height) }
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
