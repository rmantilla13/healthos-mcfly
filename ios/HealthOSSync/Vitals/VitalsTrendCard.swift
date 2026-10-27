import Charts
import SwiftUI

/// One of "Your trends" (Detail.tsx Trend on TrendChart): the latest value, its date with the range's average and the
/// card's note, and the line over the range with its median dashed and the latest reading ringed. A tap, or a finger
/// moved sideways along the line, reads one day; a drag up or down scrolls the page (`chartScrub`), as the web's charts
/// do on a phone. The chart is 200 pt tall on a phone and beside the fold, a third taller on the inner display upright.
struct VitalsTrendCard: View {
    let trend: VitalsTrend
    @State private var selected: Date?

    var body: some View {
        let points = trend.points
        VStack(alignment: .leading, spacing: 6) {
            Text(trend.title).font(.app(.subheadline, weight: .medium)).foregroundStyle(Palette.ink2)
                .accessibilityAddTraits(.isHeader)
            Text(points.last.map { trend.format($0.value) } ?? String.emptyValue)
                .font(.app(.title2, weight: .semibold)).foregroundStyle(Palette.ink).monospacedDigit()
            Text(VitalsTrendCards.note(trend))
                .font(.app(.caption)).foregroundStyle(Palette.ink3)
                .fixedSize(horizontal: false, vertical: true)
            if !points.isEmpty {
                VitalsTrendChart(trend: trend, selected: $selected)
                    .duoChartHeight(200)
                    .padding(.top, 6)
            }
        }
        // As tall as its row opened out, where two cards share one.
        .frame(maxHeight: .infinity, alignment: .top)
        .card()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("vitals-trend-\(trend.id)")
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
            if let median, let first = points.first {
                RuleMark(y: .value("Median", median))
                    .foregroundStyle(Palette.ink3)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .accessibilityHidden(true)
                // Its label above the line's start, as the web writes it: on an invisible point there, since a
                // level rule's own annotation isn't always drawn.
                PointMark(x: .value("Day", Fmt.chartDate(first.date)), y: .value("Median", median))
                    .symbolSize(0)
                    .annotation(position: .topTrailing, alignment: .leading, spacing: 1,
                                overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        Text("Median \(trend.format(median))")
                            .font(.app(.caption2))
                            .foregroundStyle(Palette.ink2)
                            .padding(.horizontal, 3)
                            .background(Palette.surface.opacity(0.8), in: RoundedRectangle(cornerRadius: 4))
                    }
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
