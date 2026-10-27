import Charts
import SwiftUI

// Body's charts: a metric over a range (Detail.tsx Trend), steps a day against the goal (Activity's BarChart), a day by
// the hour as a curve (Neka.tsx AreaCurve) or as bars (HourBars), and the change chip (Change). A tap or a sideways drag
// picks a point (`chartScrub`); a drag up or down scrolls the page, so a pane can always be scrolled from a chart.

/// The week-on-week change chip (Neka.tsx Change): green when it moved the good way, grey otherwise; nothing under 1%.
struct BodyChange: View {
    let pct: Double?
    /// The way that's good: up (HRV, steps) or down (resting heart rate).
    let better: BodyBetter
    var spoken = "this week against last week"

    enum BodyBetter { case up, down }

    /// The rounded change, or nil when there's none to show (Change's own test).
    static func shown(_ pct: Double?) -> Int? {
        guard let pct, pct.isFinite, abs(pct).rounded() >= 1 else { return nil }
        return Int(abs(pct).rounded())
    }

    var body: some View {
        if let pct, let n = Self.shown(pct) {
            let up = pct > 0
            let good = (better == .up) == up
            HStack(spacing: 4) {
                Image(systemName: up ? "chart.line.uptrend.xyaxis" : "chart.line.downtrend.xyaxis")
                    .font(.system(size: 11, weight: .medium))
                    .accessibilityHidden(true)
                Text("\(n)%")
            }
            .font(.app(.caption, weight: .medium))
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(good ? Palette.chipGreen : Palette.chip, in: Capsule())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(up ? "Up" : "Down") \(n)%, \(spoken)")
        }
    }
}

/// One metric over the range (Detail.tsx Trend): the latest value, its day, the average and a note, and the line you can
/// scrub. Each reading's day is picked with a tap or a sideways drag.
struct BodyTrendCard: View {
    let title: String
    let points: [Point]
    let format: (Double) -> String
    var tick: ((Double) -> String)?
    var note: String?
    var color: Color = Palette.series1
    var zero = false
    @State private var selected: Date?

    /// The line under the value (Trend's note): "Oct 26 · average 52 bpm · WHOOP", or "No data in this range".
    static func note(_ points: [Point], format: (Double) -> String, unitNote: String?) -> String {
        guard let last = points.last else { return "No data in this range" }
        var s = Fmt.day(last.date)
        if let avg = points.average { s += " · average \(format(avg))" }
        if let unitNote { s += " · \(unitNote)" }
        return s
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.app(.footnote, weight: .medium)).foregroundStyle(Palette.ink)
            Text(points.last.map { format($0.value) } ?? String.emptyValue)
                .font(.app(size: 28, weight: .medium, relativeTo: .title))
                .tracking(-0.5)
                .foregroundStyle(Palette.ink)
            Text(Self.note(points, format: format, unitNote: note)).font(.app(.caption)).foregroundStyle(Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
            if !points.isEmpty { chart.duoChartHeight(150).padding(.top, 6) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .accessibilityElement(children: .contain)
    }

    private var chart: some View {
        let values = points.map(\.value)
        let lo = values.min() ?? 0, hi = values.max() ?? 1
        let pad = Swift.max((hi - lo) * 0.15, 0.5)
        let domain = zero ? 0...(hi + pad) : (lo - pad)...(hi + pad)
        let picked = selected.flatMap { s in points.min { abs(Fmt.chartDate($0.date).timeIntervalSince(s)) < abs(Fmt.chartDate($1.date).timeIntervalSince(s)) } }
        return Chart {
            ForEach(points) { p in
                AreaMark(x: .value("Day", Fmt.chartDate(p.date)), yStart: .value("Base", domain.lowerBound), yEnd: .value(title, p.value))
                    .foregroundStyle(LinearGradient(colors: [color.opacity(0.22), color.opacity(0)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Day", Fmt.chartDate(p.date)), y: .value(title, p.value))
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                    .interpolationMethod(.monotone)
            }
            if let picked {
                RuleMark(x: .value("Day", Fmt.chartDate(picked.date)))
                    .foregroundStyle(Palette.ink3.opacity(0.5))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        BodyTooltip(value: format(picked.value), caption: Fmt.day(picked.date))
                    }
                PointMark(x: .value("Day", Fmt.chartDate(picked.date)), y: .value(title, picked.value)).foregroundStyle(color)
            }
        }
        .chartYScale(domain: domain)
        .chartScrub($selected)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { v in
                AxisGridLine().foregroundStyle(Palette.grid)
                AxisValueLabel { if let n = v.as(Double.self) { Text(tick?(n) ?? Fmt.number(n, abs(hi - lo) < 4 ? 1 : 0)) } }.font(.axis).foregroundStyle(Palette.ink3)
            }
        }
        .chartXAxis { BodyAxis.dates() }
        .accessibilityLabel("\(title) trend")
        .accessibilityValue(points.last.map { "Latest \(format($0.value)), \(Fmt.day($0.date))" } ?? "No data")
    }
}

/// The value and day over a picked point.
struct BodyTooltip: View {
    let value: String
    let caption: String

    var body: some View {
        VStack(spacing: 1) {
            Text(value).font(.app(.caption, weight: .semibold))
            Text(caption).font(.app(.caption2))
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Palette.surface2, in: RoundedRectangle(cornerRadius: 8))
        .foregroundStyle(Palette.ink)
    }
}

enum BodyAxis {
    static func dates() -> some AxisContent {
        AxisMarks(values: .automatic(desiredCount: 4)) { _ in
            AxisValueLabel(format: .dateTime.month(.abbreviated).day()).font(.axis).foregroundStyle(Palette.ink3)
        }
    }
}

/// Steps a day, or a week's daily average over longer ranges, against the goal (Activity's BarChart in Detail.tsx).
struct BodyStepsCard: View {
    let points: [Point]
    let days: Int
    let goal: Double
    @State private var selected: Date?

    /// The middle bar's value (an even count: the two middle ones' mean); nil for none.
    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let v = values.sorted()
        return v.count % 2 == 1 ? v[v.count / 2] : (v[v.count / 2 - 1] + v[v.count / 2]) / 2
    }

    var body: some View {
        let bars = points.weekly(days: days)
        VStack(alignment: .leading, spacing: 6) {
            Text(days > 90 ? "Steps, weekly daily average" : "Steps").font(.app(.footnote, weight: .medium)).foregroundStyle(Palette.ink)
            Text(points.average.map { "\(Fmt.number($0)) / day" } ?? String.emptyValue)
                .font(.app(size: 28, weight: .medium, relativeTo: .title)).tracking(-0.5).foregroundStyle(Palette.ink)
            Text("goal \(Fmt.number(goal))").font(.app(.caption)).foregroundStyle(Palette.ink2)
            if !bars.isEmpty {
                let picked = selected.flatMap { s in bars.min { abs(Fmt.chartDate($0.date).timeIntervalSince(s)) < abs(Fmt.chartDate($1.date).timeIntervalSince(s)) } }
                let lit = picked?.date ?? bars.last?.date
                let median = BodyStepsCard.median(bars.map(\.value))
                Chart {
                    ForEach(bars) { p in
                        BarMark(x: .value("Day", Fmt.chartDate(p.date), unit: days > 90 ? .weekOfYear : .day), y: .value("Steps", p.value))
                            .foregroundStyle(p.date == lit ? Palette.barAccent : Palette.bar)
                    }
                    if let median {
                        RuleMark(y: .value("Median", median))
                            .foregroundStyle(Palette.ink2.opacity(0.7))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                            .annotation(position: .top, alignment: .leading) {
                                Text("Median \(Fmt.number(median)) steps").font(.app(.caption2)).foregroundStyle(Palette.ink2)
                            }
                    }
                    RuleMark(y: .value("Goal", goal))
                        .foregroundStyle(Palette.ink3.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                        .annotation(position: .top, alignment: .trailing) {
                            Text("Goal \(Fmt.compact(goal))").font(.app(.caption2)).foregroundStyle(Palette.ink2)
                        }
                    if let picked {
                        RuleMark(x: .value("Day", Fmt.chartDate(picked.date), unit: days > 90 ? .weekOfYear : .day))
                            .foregroundStyle(.clear)
                            .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                                BodyTooltip(value: "\(Fmt.number(picked.value)) steps", caption: days > 90 ? "Week of \(Fmt.day(picked.date))" : Fmt.day(picked.date))
                            }
                    }
                }
                .chartScrub($selected)
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { v in
                        AxisGridLine().foregroundStyle(Palette.grid)
                        AxisValueLabel { if let n = v.as(Double.self) { Text(Fmt.compact(n)) } }.font(.axis).foregroundStyle(Palette.ink3)
                    }
                }
                .chartXAxis { BodyAxis.dates() }
                .duoChartHeight(200)
                .padding(.top, 6)
                .accessibilityLabel("Steps per day")
                .accessibilityValue(points.average.map { "\(Fmt.number($0)) a day on average, goal \(Fmt.number(goal))" } ?? "No data")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .accessibilityElement(children: .contain)
    }
}

// MARK: - A day by the hour

/// A day's hours as a smooth curve from 00:00 to 24:00 (AreaCurve): green up to the marker, orange after it, the typical
/// hour dashed, and the marker's value in a pill.
struct BodyHourCurve: View {
    /// Hourly values; nil where nothing was recorded or after the day's last hour shown.
    let hours: [Double?]
    let typical: [Double?]
    /// The hour marked; the last reading when nil.
    let marker: Int?
    let format: (Double) -> String
    let label: String

    var body: some View {
        let pts = BodyHour.of(hours)
        let usual = BodyHour.of(typical)
        let values = (pts + usual).map(\.v)
        let lo = (values.min() ?? 0) - 5, hi = (values.max() ?? 1) + 5
        let mh = marker ?? pts.last?.h ?? 0
        let mv = hours.indices.contains(mh) ? hours[mh] ?? pts.min { abs($0.h - mh) < abs($1.h - mh) }?.v : pts.last?.v
        Chart {
            ForEach(usual) { p in
                let h = p.h, v = p.v
                LineMark(x: .value("Hour", Double(h) + 0.5), y: .value("Typical", v), series: .value("Line", "typical"))
                    .foregroundStyle(Palette.ink2.opacity(0.75))
                    .lineStyle(StrokeStyle(lineWidth: 1.25, dash: [4, 4]))
                    .interpolationMethod(.monotone)
            }
            ForEach(pts) { p in
                let h = p.h, v = p.v
                AreaMark(x: .value("Hour", Double(h) + 0.5), yStart: .value("Base", lo), yEnd: .value("Heart", v), series: .value("Line", "area"))
                    .foregroundStyle(LinearGradient(colors: [(h <= mh ? Palette.good : Palette.series2).opacity(0.26), .clear], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Hour", Double(h) + 0.5), y: .value("Heart", v), series: .value("Line", "day"))
                    .foregroundStyle(h <= mh ? Palette.good : Palette.series2)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                    .interpolationMethod(.monotone)
            }
            if let mv {
                RuleMark(x: .value("Hour", Double(mh) + 0.5))
                    .foregroundStyle(Palette.ink)
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        Text(format(mv)).font(.app(.caption2, weight: .semibold)).foregroundStyle(Palette.surface)
                            .padding(.horizontal, 10).padding(.vertical, 3)
                            .background(Palette.ink, in: Capsule())
                    }
                PointMark(x: .value("Hour", Double(mh) + 0.5), y: .value("Heart", mv)).foregroundStyle(Palette.good).symbolSize(50)
            }
        }
        .chartXScale(domain: 0...24)
        .chartYScale(domain: lo...hi)
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: [0.0, 6, 12, 18, 24]) { v in
                AxisValueLabel { Text(String(format: "%02d:00", Int(v.as(Double.self) ?? 0))) }.font(.axis).foregroundStyle(Palette.ink3)
            }
        }
        .accessibilityLabel(label)
        .accessibilityValue(mv.map { "\(format($0)) at \(String(format: "%02d:00", mh))" } ?? "No readings")
    }
}

/// One hour's value.
struct BodyHour: Identifiable {
    let h: Int
    let v: Double
    var id: Int { h }

    static func of(_ hours: [Double?]) -> [BodyHour] { hours.enumerated().compactMap { h, v in v.map { BodyHour(h: h, v: $0) } } }
}

/// A day's hours as bars from `from` to 23:00, the accent hour darker, with a clock label every three hours (HourBars).
struct BodyHourBars: View {
    let hours: [Double?]
    var from = 0
    var accent: Int?
    let bar: Color
    let accentBar: Color
    let label: String

    /// From 6:00, or the first hour with a reading if earlier (firstHour in Body.tsx).
    static func firstHour(_ hours: [Double?]) -> Int {
        let first = hours.firstIndex { ($0 ?? 0) > 0 } ?? 0
        return min(6, max(0, first))
    }

    var body: some View {
        let shown = Array(hours.dropFirst(from).prefix(24 - from))
        VStack(spacing: 4) {
            Canvas { ctx, size in
                guard !shown.isEmpty else { return }
                let top = max(1, shown.compactMap { $0 }.max() ?? 1)
                let slot = size.width / CGFloat(shown.count)
                let w = max(3, min(12, slot - 3))
                for (i, v) in shown.enumerated() {
                    guard let v, v > 0 else { continue }
                    let h = max(2, CGFloat(v / top) * (size.height - 4))
                    let x = CGFloat(i) * slot + (slot - w) / 2
                    let r = min(3, w / 2, h)
                    let rect = CGRect(x: x, y: size.height - h, width: w, height: h)
                    ctx.fill(Path(roundedRect: rect, cornerRadii: RectangleCornerRadii(topLeading: r, topTrailing: r)),
                             with: .color(from + i == accent ? accentBar : bar))
                }
            }
            GeometryReader { geo in
                let slot = geo.size.width / CGFloat(max(1, shown.count))
                ForEach(Array(shown.indices), id: \.self) { i in
                    if (from + i) % 3 == 0 {
                        Text("\(from + i):00").font(.axis).foregroundStyle(Palette.ink3).fixedSize()
                            .position(x: CGFloat(i) * slot + slot / 2, y: 7)
                    }
                }
            }
            .frame(height: 14)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }
}
