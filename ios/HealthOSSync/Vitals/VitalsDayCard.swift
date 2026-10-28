import SwiftUI

/// The Day view's heart rate (Detail.tsx DayCard, kind "hourly"): the latest hour's average and the day's range, the
/// hours you can scrub against the dashed typical day, and its key.
struct VitalsDayCard: View {
    let series: DaySeries
    let data: DayData

    /// "Today", or the day as the web writes it ("Wed, Oct 22").
    static func dayLabel(_ data: DayData) -> String { data.date >= data.today ? "Today" : Fmt.day(data.date, "EEEMMMd") }

    var body: some View {
        let metric = HourMetric.heart
        let reading = DayReading(metric: metric, series: series, data: data)
        let dayLabel = Self.dayLabel(data)
        VStack(alignment: .leading, spacing: 6) {
            Text(metric.title).font(.app(.subheadline, weight: .medium)).foregroundStyle(Palette.ink2)
            Text(reading.value.map(metric.format) ?? String.emptyValue)
                .font(.app(.title2, weight: .semibold)).foregroundStyle(Palette.ink).monospacedDigit()
            Text(reading.note).font(.app(.caption)).foregroundStyle(Palette.ink3).fixedSize(horizontal: false, vertical: true)
            // Drawn whenever there's a line to draw, the day's or the typical one.
            if reading.through != nil, (reading.shown + series.typical).contains(where: { $0 != nil }) {
                // HoursChart is the foundation's (Dashboard/DayScreen.swift): its own chartXSelection still takes a drag
                // that starts on it, so the page scrolls from around it, not from it, until it moves to chartScrub.
                HoursChart(metric: metric, series: series, reading: reading, label: "\(metric.title) by hour, \(dayLabel)")
                    .duoChartHeight(200)
                    .padding(.top, 6)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 14) { legend(dayLabel, color: metric.color) }
                    VStack(alignment: .leading, spacing: 4) { legend(dayLabel, color: metric.color) }
                }
            } else {
                Text("No readings on this day")
                    .font(.app(.footnote)).foregroundStyle(Palette.ink3)
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
        }
        .card()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("vitals-day-heart-rate")
    }

    @ViewBuilder private func legend(_ dayLabel: String, color: Color) -> some View {
        VitalsLegendKey(color: color, dashed: false, label: dayLabel)
        VitalsLegendKey(color: Palette.ink2, dashed: true, label: "Typical (median of the last 30 days)")
    }
}

/// A line's key (Legend kind "line"): a short stroke, dashed for the typical day, and its words.
private struct VitalsLegendKey: View {
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
            .accessibilityHidden(true)
            Text(label).font(.app(.caption2)).foregroundStyle(Palette.ink3).fixedSize(horizontal: false, vertical: true)
        }
    }
}
