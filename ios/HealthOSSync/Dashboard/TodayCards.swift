import Charts
import SwiftUI

// The six metric cards, the timeline and the insights from src/pages/Home.tsx.

/// The metric cards that show (hidden ones left out), two to a row like the web's fill row: as many full rows as
/// fit, and an odd last card spans both columns, so hiding a card never leaves a hole.
struct TodayGrid: View {
    let summary: Summary
    /// shared/cards.ts ids in order, hidden ones already removed (Cards.todayGrid).
    let ids: [String]
    let goal: Double

    var body: some View {
        // Every card hidden: nothing at all, not an empty stack, which a parent stack would still space around.
        if !ids.isEmpty {
            VStack(spacing: 12) {
                ForEach(Array(Cards.rows(ids, max: 2).enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(row, id: \.self) { card($0) }
                    }
                    // Both cards in a row as tall as the taller one.
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder private func card(_ id: String) -> some View {
        switch id {
        case "home.readiness": ReadinessCard(summary: summary)
        case "home.spo2": Spo2Card(summary: summary)
        case "home.hrv": HrvCard(summary: summary)
        case "home.sleep": SleepCard(summary: summary)
        case "home.load": LoadCard(summary: summary)
        case "home.activity": ActivityCard(summary: summary, goal: goal)
        default: EmptyView()
        }
    }
}

/// A tappable card that opens the matching Trends section.
private struct MetricCard<Content: View>: View {
    let title: String
    let section: TrendsSection
    var tint: CardTint = .plain
    @ViewBuilder let content: Content
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        Button { dashboard.open(section) } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(title).font(.subheadline.weight(.medium)).foregroundStyle(Palette.ink2)
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.caption.weight(.semibold)).foregroundStyle(Palette.ink3)
                }
                content
            }
            .frame(maxWidth: .infinity, minHeight: 196, maxHeight: .infinity, alignment: .topLeading)
            .card(tint)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens \(section.rawValue)")
    }
}

private struct Empty: View {
    let text: String
    var body: some View {
        Text(text).font(.footnote).foregroundStyle(Palette.ink3).frame(maxHeight: .infinity, alignment: .center)
    }
}

/// The date of a value when it isn't from the day on screen.
private struct Stale: View {
    let date: String
    let asOf: String
    var body: some View {
        if date != asOf { Text(Fmt.day(date)).font(.caption2).foregroundStyle(Palette.ink3) }
    }
}

private struct Foot<Leading: View, Trailing: View>: View {
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            leading
            Spacer(minLength: 4)
            trailing
        }
        .font(.caption)
        .foregroundStyle(Palette.ink3)
        .lineLimit(1)
    }
}

// MARK: - Readiness

struct ReadinessCard: View {
    let summary: Summary

    var body: some View {
        if let r = summary.readiness, r.kind == "vo2max" {
            MetricCard(title: "Cardio fitness", section: .body, tint: .green) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        BigValue(value: Fmt.number(r.latest.value, 1), unit: "VO₂ max", size: 30)
                        if let prev = r.previous { Chip(text: "\(Fmt.signed(r.latest.value - prev, 1)) vs last month") }
                    }
                    Spacer(minLength: 0)
                }
                Rings(value: min(1, (r.latest.value - 25) / 35)).frame(height: 64).frame(maxWidth: .infinity)
                Spacer(minLength: 0)
                Foot { Text("mL/kg·min") } trailing: { Stale(date: r.latest.date, asOf: summary.date) }
            }
        } else if let r = summary.readiness, r.kind == "recovery" {
            let zone = r.zone ?? (r.latest.value >= 67 ? "green" : r.latest.value >= 34 ? "yellow" : "red")
            MetricCard(title: "Recovery", section: .vitals, tint: .green) {
                BigValue(value: Fmt.number(r.latest.value), unit: "%", size: 30)
                if let avg = r.average { Chip(text: "\(Fmt.signed(r.latest.value - avg)) vs 30-day avg") }
                Rings(value: r.latest.value / 100).frame(height: 56).frame(maxWidth: .infinity)
                ZoneScale(value: r.latest.value, range: 0...100, zones: [(33, Palette.critical), (66, Palette.warning), (100, Palette.good)])
                Foot {
                    HStack(spacing: 4) {
                        Circle().fill(Self.zoneColor(zone)).frame(width: 7, height: 7)
                        Text(Self.zoneText(zone)).foregroundStyle(Palette.ink).fontWeight(.medium)
                    }
                } trailing: { Stale(date: r.latest.date, asOf: summary.date) }
            }
        } else {
            MetricCard(title: "Recovery", section: .vitals, tint: .green) {
                Empty(text: "Recovery comes from WHOOP; cardio fitness from Apple Watch.")
            }
        }
    }

    static func zoneText(_ zone: String) -> String { ["red": "Low", "yellow": "Moderate", "green": "High"][zone] ?? zone.capitalized }
    static func zoneColor(_ zone: String) -> Color { ["red": Palette.critical, "yellow": Palette.warning, "green": Palette.good][zone] ?? Palette.ink3 }
}

/// Decorative concentric rings; the dot sits at the score's position on the outer ring (the web's Rings).
struct Rings: View {
    let value: Double

    var body: some View {
        Canvas { ctx, size in
            let scale = min(size.width, size.height) / 120
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            for r in [56.0, 44, 32, 20] {
                let rr = r * scale
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2)), with: .color(Palette.ink.opacity(0.15)), lineWidth: 1)
            }
            let a = Double.pi * (0.75 - 1.5 * min(1, max(0, value)))
            let p = CGPoint(x: c.x + 56 * scale * cos(a), y: c.y - 56 * scale * sin(a))
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)), with: .color(Palette.ink))
        }
        .accessibilityHidden(true)
    }
}

/// A segmented range bar with a marker at the value.
struct ZoneScale: View {
    let value: Double
    let range: ClosedRange<Double>
    let zones: [(Double, Color)]

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let span = range.upperBound - range.lowerBound
            ZStack(alignment: .leading) {
                HStack(spacing: 2) {
                    ForEach(Array(zones.enumerated()), id: \.offset) { i, zone in
                        let from = i == 0 ? range.lowerBound : zones[i - 1].0
                        Capsule().fill(zone.1.opacity(0.55)).frame(width: max(0, (zone.0 - from) / span * w - 2))
                    }
                }
                Circle()
                    .fill(Palette.ink)
                    .overlay(Circle().stroke(Palette.surface, lineWidth: 2))
                    .frame(width: 10, height: 10)
                    .offset(x: min(max(0, (value - range.lowerBound) / span), 1) * (w - 10))
            }
        }
        .frame(height: 10)
        .accessibilityHidden(true)
    }
}

// MARK: - Blood oxygen

struct Spo2Card: View {
    let summary: Summary

    var body: some View {
        MetricCard(title: "Blood oxygen", section: .vitals, tint: .peach) {
            if let l = summary.spo2?.latest {
                HStack(alignment: .firstTextBaseline) {
                    BigValue(value: Fmt.number(l.value, l.value.truncatingRemainder(dividingBy: 1) == 0 ? 0 : 1), unit: "%", size: 30)
                    Spacer(minLength: 0)
                }
                Text(summary.spo2?.status == "low" ? "Below your range" : "Normal").font(.caption.weight(.medium)).foregroundStyle(Palette.ink2)
                MiniLine(points: summary.spo2?.series ?? [], color: Palette.series2, domain: 90...100).frame(height: 56)
                Spacer(minLength: 0)
                Foot { Text("90") } trailing: {
                    HStack(spacing: 8) {
                        Stale(date: l.date, asOf: summary.date)
                        Text("100")
                    }
                }
            } else {
                Empty(text: "No blood oxygen readings yet.")
            }
        }
    }
}

// MARK: - HRV

struct HrvCard: View {
    let summary: Summary

    var body: some View {
        MetricCard(title: "HRV", section: .vitals) {
            if let hrv = summary.hrv, let l = hrv.latest {
                BigValue(value: Fmt.number(l.value), unit: "ms", size: 30)
                MiniDots(points: hrv.series ?? [], baseline: hrv.baseline).frame(height: 64)
                Spacer(minLength: 0)
                Foot {
                    Text(Self.statusText(hrv.status)).foregroundStyle(Palette.ink).fontWeight(.medium)
                } trailing: {
                    Text("usual · \(hrv.metric == "hrv_sdnn" ? "SDNN" : "RMSSD")")
                }
            } else {
                Empty(text: "No HRV readings yet.")
            }
        }
    }

    static func statusText(_ s: String?) -> String {
        switch s {
        case "optimal": "Optimal"
        case "normal": "Normal"
        case "low": "Below baseline"
        default: "Building baseline"
        }
    }
}

// MARK: - Sleep

struct SleepCard: View {
    let summary: Summary

    var body: some View {
        MetricCard(title: "Sleep", section: .sleep) {
            if let l = summary.sleep?.latest {
                BigValue(value: Fmt.number(l.value, 1), unit: "hours", size: 30)
                MiniLine(points: summary.sleep?.series ?? [], color: Palette.series1).frame(height: 56)
                Spacer(minLength: 0)
                Foot {
                    HStack(spacing: 6) {
                        Text(l.value >= 7 ? "Good" : l.value >= 6 ? "Fair" : "Short").foregroundStyle(Palette.ink).fontWeight(.medium)
                        Stale(date: l.date, asOf: summary.date)
                    }
                } trailing: {
                    if let change = summary.sleep?.change { Text("\(Fmt.signed(change * 100))% wk") }
                }
            } else {
                Empty(text: "No sleep recorded yet.")
            }
        }
    }
}

// MARK: - Strain / active energy

struct LoadCard: View {
    let summary: Summary

    var body: some View {
        if let l = summary.load {
            let strain = l.kind == "strain"
            let v = l.latest.value
            let max = strain ? 21 : Swift.max(800, (l.average ?? 0) * 1.6)
            let band = strain ? (v < 10 ? "Light" : v < 14 ? "Moderate" : v < 18 ? "High" : "All out") : v >= (l.average ?? 0) ? "Above usual" : "Below usual"
            MetricCard(title: strain ? "Strain" : "Active energy", section: .activity, tint: .pink) {
                BigValue(value: strain ? Fmt.number(v, 1) : Fmt.number(v), unit: strain ? "of 21" : "kcal", size: 30)
                ArcGauge(fraction: v / max).frame(height: 62).frame(maxWidth: .infinity)
                Spacer(minLength: 0)
                Foot {
                    HStack(spacing: 6) {
                        Text(band).foregroundStyle(Palette.ink).fontWeight(.medium)
                        Stale(date: l.latest.date, asOf: summary.date)
                    }
                } trailing: {
                    if let avg = l.average, avg > 0 { Text("\(Fmt.signed((v - avg) / avg * 100))% vs avg") }
                }
            }
        } else {
            MetricCard(title: "Strain", section: .activity, tint: .pink) {
                Empty(text: "Strain comes from WHOOP; active energy from Apple Health.")
            }
        }
    }
}

struct ArcGauge: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Arc(to: 1).stroke(Palette.gaugeTrack, style: StrokeStyle(lineWidth: 10, lineCap: .round))
            Arc(to: min(1, max(0.02, fraction))).stroke(Palette.gaugeFill, style: StrokeStyle(lineWidth: 10, lineCap: .round))
        }
        .accessibilityHidden(true)
    }

    struct Arc: Shape {
        var to: Double
        func path(in rect: CGRect) -> Path {
            let radius = min(rect.width / 2, rect.height) - 6
            var p = Path()
            p.addArc(center: CGPoint(x: rect.midX, y: rect.maxY - 2), radius: radius, startAngle: .degrees(180), endAngle: .degrees(180 + 180 * to), clockwise: false)
            return p
        }
    }
}

// MARK: - Activity

struct ActivityCard: View {
    let summary: Summary
    let goal: Double

    var body: some View {
        MetricCard(title: "Activity", section: .activity) {
            if let l = summary.activity?.latest {
                BigValue(value: Fmt.number(l.value), unit: "steps", size: 30)
                MiniBars(points: summary.activity?.series ?? []).frame(height: 48)
                Spacer(minLength: 0)
                VStack(spacing: 5) {
                    Foot { Text("\(Int((l.value / goal * 100).rounded()))% of goal") } trailing: { Text(Fmt.compact(goal)) }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Palette.goalTrack)
                            Capsule().fill(Palette.good).frame(width: geo.size.width * min(1, l.value / goal))
                        }
                    }
                    .frame(height: 6)
                }
            } else {
                Empty(text: "No steps recorded yet.")
            }
        }
    }
}

// MARK: - Mini charts

struct MiniLine: View {
    let points: [Point]
    let color: Color
    var domain: ClosedRange<Double>?

    var body: some View {
        let values = points.map(\.value)
        let lo = domain?.lowerBound ?? (values.min() ?? 0)
        let hi = domain?.upperBound ?? (values.max() ?? 1)
        let pad = domain == nil ? Swift.max((hi - lo) * 0.25, 0.5) : 0
        Chart(points) { p in
            AreaMark(x: .value("Day", Fmt.chartDate(p.date)), yStart: .value("Base", lo - pad), yEnd: .value("Value", Swift.min(Swift.max(p.value, lo - pad), hi + pad)))
                .foregroundStyle(LinearGradient(colors: [color.opacity(0.25), color.opacity(0)], startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.catmullRom)
            LineMark(x: .value("Day", Fmt.chartDate(p.date)), y: .value("Value", Swift.min(Swift.max(p.value, lo - pad), hi + pad)))
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                .interpolationMethod(.catmullRom)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: (lo - pad)...(hi + pad))
        .accessibilityHidden(true)
    }
}

struct MiniBars: View {
    let points: [Point]

    var body: some View {
        Chart(Array(points.enumerated()), id: \.offset) { i, p in
            BarMark(x: .value("Day", p.date), y: .value("Steps", p.value), width: .ratio(0.6))
                .foregroundStyle(i == points.count - 1 ? Palette.barNeutralAccent : Palette.barNeutral)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .accessibilityHidden(true)
    }
}

/// HRV dots with the usual level as a dashed line.
struct MiniDots: View {
    let points: [Point]
    let baseline: Double?

    var body: some View {
        let values = points.map(\.value) + (baseline.map { [$0] } ?? [])
        let lo = (values.min() ?? 0) * 0.92
        let hi = (values.max() ?? 1) * 1.08
        Chart {
            if let baseline {
                RuleMark(y: .value("Usual", baseline))
                    .foregroundStyle(Palette.ink3.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            ForEach(Array(points.enumerated()), id: \.offset) { i, p in
                PointMark(x: .value("Night", Fmt.chartDate(p.date)), y: .value("HRV", p.value))
                    .symbolSize(i == points.count - 1 ? 44 : 18)
                    .foregroundStyle(i == points.count - 1 ? Palette.series1 : Palette.series1.opacity(0.45))
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: lo...Swift.max(hi, lo + 1))
        .accessibilityHidden(true)
    }
}

// MARK: - Timeline

struct TimelineCard: View {
    let timeline: Summary.Timeline
    let today: String

    var body: some View {
        let isToday = timeline.date == today
        VStack(alignment: .leading, spacing: 14) {
            Text(isToday ? "Today's timeline" : "Timeline · \(Fmt.day(timeline.date, "EEEMMMd"))").font(.headline).foregroundStyle(Palette.ink)
            Track(timeline: timeline, isToday: isToday)
            if timeline.events.isEmpty {
                Text("Nothing recorded for this day.").font(.footnote).foregroundStyle(Palette.ink3)
            }
            ForEach(timeline.events.suffix(4)) { e in
                HStack(spacing: 10) {
                    Circle().fill(Self.color(e.kind)).frame(width: 9, height: 9)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.title).font(.subheadline.weight(.medium)).foregroundStyle(Palette.ink)
                        Text("\(Fmt.clock(e.start)) – \(Fmt.clock(e.end))\(e.detail.map { " · \($0)" } ?? "")")
                            .font(.caption).foregroundStyle(Palette.ink3).monospacedDigit()
                    }
                    Spacer()
                    let state = Self.state(e, isToday: isToday, today: today)
                    Text(state)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background((state == "In progress" ? Tone.green : state == "Upcoming" ? Tone.blue : Tone.neutral).background, in: Capsule())
                        .foregroundStyle((state == "In progress" ? Tone.green : state == "Upcoming" ? Tone.blue : Tone.neutral).ink)
                }
            }
        }
        .card()
    }

    static func color(_ kind: String) -> Color {
        switch kind {
        case "sleep", "nap": Palette.series1
        case "workout": Palette.series2
        case "mindful": Palette.series3
        default: Palette.ink3
        }
    }

    /// Compares wall times as recorded with the phone's local time, like the web.
    static func state(_ e: TimelineEvent, isToday: Bool, today: String) -> String {
        guard isToday else { return "Completed" }
        let nowLocal = localNow()
        if String(e.end.prefix(16)) <= nowLocal { return "Completed" }
        if String(e.start.prefix(16)) <= nowLocal { return "In progress" }
        return "Upcoming"
    }

    static func localNow() -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: Date())
        return String(format: "%04d-%02d-%02dT%02d:%02d", c.year!, c.month!, c.day!, c.hour!, c.minute!)
    }

    private struct Track: View {
        let timeline: Summary.Timeline
        let isToday: Bool

        var body: some View {
            VStack(spacing: 4) {
                GeometryReader { geo in
                    let w = geo.size.width
                    ZStack(alignment: .leading) {
                        Capsule().fill(Palette.surface2).frame(height: 12)
                        ForEach(timeline.events) { e in
                            // An event that started the evening before is drawn from midnight.
                            let start = e.start.prefix(10) < timeline.date ? 0 : Fmt.minutesOfDay(e.start)
                            let end = e.end.prefix(10) > timeline.date ? 1440 : Fmt.minutesOfDay(e.end)
                            let span = Swift.max(end, start + 12) - start
                            Capsule()
                                .fill(TimelineCard.color(e.kind))
                                .frame(width: Swift.max(4, w * Double(span) / 1440 - 2), height: 12)
                                .offset(x: w * Double(start) / 1440)
                        }
                        if isToday {
                            let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
                            Rectangle().fill(Palette.ink).frame(width: 2, height: 22)
                                .offset(x: w * Double(c.hour! * 60 + c.minute!) / 1440 - 1)
                        }
                    }
                    .frame(height: 22)
                }
                .frame(height: 22)
                HStack {
                    ForEach([0, 6, 12, 18, 24], id: \.self) { h in
                        Text(String(format: "%02d:00", h))
                        if h != 24 { Spacer() }
                    }
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Palette.ink3)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(timeline.events.map { "\($0.title) \(Fmt.clock($0.start)) to \(Fmt.clock($0.end))" }.joined(separator: ", "))
        }
    }
}

// MARK: - Insights

struct InsightsCard: View {
    let insights: [Insight]
    let today: String
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent insights").font(.headline).foregroundStyle(Palette.ink)
            if insights.isEmpty {
                Text("Insights appear after a week or two of data.").font(.footnote).foregroundStyle(Palette.ink3)
            }
            ForEach(insights) { insight in
                let (symbol, tone) = Self.style(insight.icon)
                Button {
                    if let section = TrendsSection(page: insight.page) { dashboard.open(section) }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: symbol)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(tone.ink)
                            .frame(width: 34, height: 34)
                            .background(tone.background, in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(insight.text).font(.subheadline).foregroundStyle(Palette.ink).multilineTextAlignment(.leading)
                            Text(Fmt.relativeDay(insight.date, today: today)).font(.caption).foregroundStyle(Palette.ink3)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Palette.ink3)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .card()
    }

    static func style(_ icon: String) -> (String, Tone) {
        switch icon {
        case "trend-up": ("arrow.up.right", .green)
        case "trend-down": ("arrow.down.right", .peach)
        case "moon": ("moon.fill", .blue)
        case "shield": ("checkmark.shield.fill", .green)
        case "sun": ("sun.max.fill", .yellow)
        case "steps": ("figure.walk", .neutral)
        case "heart": ("heart.fill", .pink)
        default: ("sparkles", .neutral)
        }
    }
}
