import Charts
import SwiftUI

// Home's cards from src/pages/Home.tsx: the grid of signal cards (Home/SignalCards.swift) and the optional ones (strain or
// active energy, activity, food totals), the card frame they share with Vitals and Sleep, and Recent insights.

/// Home's cards that show (hidden ones left out), in a DuoGrid: one to a row, as the web's phone layout has them at
/// every text size (styles.css: `.cards.fill-row { --cols: 1 }` at 560px and below), so on every iPhone; on the iPhone
/// Duo's inner display upright, the web's count for the row (`medium`, a short last row spanning it); in the open Duo's
/// cards pane, `paneColumns` to a row (decisions.md Q5).
struct TodayGrid: View {
    let summary: Summary
    /// shared/cards.ts ids in order, hidden ones already removed.
    let ids: [String]
    let goal: Double
    /// The food totals card's days, which Home reads (HomeReads); the card isn't drawn without them.
    var food: NutritionData? = nil
    /// The most cards to a row on the inner display upright (the web's at 561–1080), and in the open Duo's cards pane.
    var medium = 2
    var paneColumns = 2

    var body: some View {
        // Every card hidden: nothing at all, not an empty stack, which a parent stack would still space around.
        if !ids.isEmpty {
            DuoGrid(ids, id: \.self, medium: medium, paneColumns: paneColumns) { card($0) }
                // Side by side, each card is as tall as its row.
                .environment(\.cardFillsRow, true)
        }
    }

    @ViewBuilder private func card(_ id: String) -> some View {
        if let signal = Signal.of(id, summary) {
            SignalCard(signal: signal, date: summary.date)
        } else {
            switch id {
            case "home.load": LoadCard(summary: summary)
            case "home.activity": ActivityCard(summary: summary, goal: goal)
            case "home.food": if let food { FoodTotalsCard(data: food) }
            default: EmptyView()
            }
        }
    }
}

/// The two sizes of the web's signal card (VitalCard.tsx `variant`): Home's tall one, and the short one on Vitals and
/// Sleep.
enum MetricCardVariant {
    case home, compact

    var minHeight: CGFloat { self == .home ? 214 : 176 }
}

/// A tappable card for one metric (the web's .card.metric with its CardHead): Home's, and the compact ones on Vitals and
/// Sleep. With a `metric`, a tap opens its detail sheet, whose "Open {Page}" goes to `route`, as the web's arrow does;
/// without one, it opens `route`. Home's signal cards (SignalCard) take the same `variant`, so Vitals (H) and Sleep (J)
/// show them compact.
struct MetricCard<Content: View>: View {
    let title: String
    let route: AppRoute
    var tint: CardTint = .plain
    var variant: MetricCardVariant = .home
    var metric: MetricKey?
    /// The sheet's line above the metric's name.
    var section = "Your signals"
    /// The day the card shows, where the sheet's window ends; nil is today.
    var date: String?
    /// At least this tall; the variant's own height when nil.
    var minHeight: CGFloat?
    /// What VoiceOver reads for the card; its own words when nil.
    var spoken: String?
    @ViewBuilder let content: Content
    @Environment(Dashboard.self) private var dashboard
    @Environment(\.cardFillsRow) private var fillsRow

    init(title: String, route: AppRoute, tint: CardTint = .plain, variant: MetricCardVariant = .home, metric: MetricKey? = nil,
         section: String = "Your signals", date: String? = nil, minHeight: CGFloat? = nil, spoken: String? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.route = route
        self.tint = tint
        self.variant = variant
        self.metric = metric
        self.section = section
        self.date = date
        self.minHeight = minHeight
        self.spoken = spoken
        self.content = content()
    }

    var body: some View {
        Button {
            if let metric { dashboard.showMetric(metric, section: section, page: route, date: date) } else { dashboard.open(route) }
        } label: {
            // The web's min-height is the whole card's (border-box): the card's padding (20 top, 18 bottom) comes off.
            // As tall as the row it's in, in Home's grid where cards sit side by side (the web's rows stretch).
            CardMinHeight(min: (minHeight ?? variant.minHeight) - 38, fills: fillsRow) {
                VStack(alignment: .leading, spacing: 6) {
                    CardHead(title: title)
                    content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .card(tint)
            .contentShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        }
        .buttonStyle(CardPressStyle())
        .modifier(SpokenLabel(text: spoken))
        .accessibilityHint(metric == nil ? "Opens \(route.title)" : "Opens \(title) details")
    }
}

/// A card's title and its ↗ (Home.tsx CardHead, .metric-head: 13px, 500, ink; the arrow in a 26pt circle, ink-2).
struct CardHead: View {
    let title: String

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(title).font(.app(.footnote, weight: .medium)).foregroundStyle(Palette.ink).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Image(systemName: "arrow.up.right").font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.ink2)
                .frame(width: 26, height: 26)
                .padding(.vertical, -4)
                .padding(.trailing, -6)
                .accessibilityHidden(true)
        }
    }
}

/// A card's label for VoiceOver when one is given.
private struct SpokenLabel: ViewModifier {
    let text: String?
    func body(content: Content) -> some View {
        if let text { content.accessibilityLabel(text) } else { content }
    }
}

/// A card pressed: a shade dimmer, without moving under Reduce Motion.
struct CardPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.92 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.99 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// At least `min` tall, else as tall as its content, and the content is laid out in that height, so a Spacer in it
/// pushes the foot to the bottom (the web's `margin-top: auto` in a card with a min-height). With `fills`, a height it's
/// offered (a row of cards side by side, DuoGrid) is taken too, as the web's rows stretch their cards; a scroll view's
/// stack offers none, so one to a row nothing changes.
struct CardMinHeight: Layout {
    var min: CGFloat
    var fills = false

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let ideal = child.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        let offered = fills ? proposal.height.flatMap { $0.isFinite ? $0 : nil } ?? 0 : 0
        return CGSize(width: proposal.width ?? ideal.width, height: Swift.max(min, ideal.height, offered))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

private struct CardFillsRowKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// A MetricCard takes the height its row offers (Home's TodayGrid); elsewhere it keeps its own.
    var cardFillsRow: Bool {
        get { self[CardFillsRowKey.self] }
        set { self[CardFillsRowKey.self] = newValue }
    }
}

// MARK: - A link inside a card

/// Where a link inside a tappable card sits (an empty card's Connect), so a button of its own can be drawn over it:
/// a button inside the card's own button wouldn't get its taps.
struct CardLinkSpot: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = value ?? nextValue() }
}

extension View {
    /// Marks where the card's link goes: this is drawn hidden in its place, and the real button over it.
    func cardLinkSpot() -> some View { hidden().anchorPreference(key: CardLinkSpot.self, value: .bounds) { $0 } }

    /// Draws the card's link over the spot marked with `cardLinkSpot()`.
    func cardLink<Label: View>(_ spoken: String, hint: String, id: String, action: @escaping () -> Void, @ViewBuilder label: @escaping () -> Label) -> some View {
        overlayPreferenceValue(CardLinkSpot.self) { spot in
            GeometryReader { geo in
                if let spot {
                    let r = geo[spot]
                    Button(action: action) {
                        label().frame(minWidth: Swift.max(44, r.width), minHeight: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .position(x: r.midX, y: r.midY)
                    .accessibilityLabel(spoken)
                    .accessibilityHint(hint)
                    .accessibilityIdentifier(id)
                }
            }
        }
    }
}

/// An optional card without data (Home.tsx Empty): its words, and Connect data, to Integrations.
private struct EmptyMetric: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Spacer(minLength: 0)
            Text(text).font(.app(.footnote)).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true)
            ConnectData().cardLinkSpot()
        }
    }
}

private struct ConnectData: View {
    var body: some View { Text("Connect data").font(.app(.footnote, weight: .semibold)).foregroundStyle(Palette.ink) }
}

/// The date of a value when it isn't from the day on screen (Signals.tsx Stale).
private struct Stale: View {
    let date: String
    let asOf: String
    var body: some View {
        if date != asOf { Text(Fmt.day(date)).font(.app(size: 11, relativeTo: .caption2)).foregroundStyle(Palette.ink3) }
    }
}

/// The big figure of an optional card, its unit on the line below (.metric-value: 40px, 500; small 13px).
private struct MetricValue: View {
    let value: String
    let unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value).font(.app(size: 40, weight: .medium, relativeTo: .largeTitle)).tracking(-0.03 * 40).foregroundStyle(Palette.ink)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(unit).font(.app(.footnote)).foregroundStyle(Palette.ink2)
        }
        .padding(.top, 6)
    }
}

// MARK: - Strain / active energy

/// Home.tsx LoadCard: WHOOP's strain on its 21 scale, or Apple's active energy against the 7-day average.
struct LoadCard: View {
    let summary: Summary
    @Environment(Dashboard.self) private var dashboard

    /// The words under the gauge: strain's band, or active energy against the average.
    static func band(_ l: Summary.Load) -> String {
        let v = l.latest.value
        if l.kind == "strain" { return v < 10 ? "Light" : v < 14 ? "Moderate" : v < 18 ? "High" : "All out" }
        return v >= (l.average ?? 0) ? "Above usual" : "Below usual"
    }

    var body: some View {
        if let l = summary.load {
            let strain = l.kind == "strain"
            let v = l.latest.value
            let max = strain ? 21 : Swift.max(800, (l.average ?? 0) * 1.6)
            MetricCard(title: strain ? "Strain" : "Active energy", route: .activity, tint: .pink, metric: strain ? .strain : .activeEnergy,
                       date: summary.date, spoken: "\(strain ? "Strain \(Fmt.number(v, 1)) of 21" : "Active energy \(Fmt.number(v)) kilocalories"), \(Self.band(l))") {
                VStack(alignment: .leading, spacing: 6) {
                    MetricValue(value: strain ? Fmt.number(v, 1) : Fmt.number(v), unit: strain ? "of 21" : "kcal")
                    HalfGauge(fraction: v / max).frame(width: 168, height: 92).frame(maxWidth: .infinity).padding(.top, -6)
                    Spacer(minLength: 0)
                    SignalFootRow {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(Self.band(l)).font(.app(.footnote, weight: .medium)).foregroundStyle(Palette.ink)
                            Stale(date: l.latest.date, asOf: summary.date)
                        }
                    } trailing: {
                        if let avg = l.average, avg > 0 { Text("\(Fmt.signed((v - avg) / avg * 100))% vs avg") }
                    }
                    .font(.app(.caption))
                }
            }
            .accessibilityIdentifier("card-home.load")
        } else {
            MetricCard(title: "Strain", route: .activity, tint: .pink, metric: .strain, date: summary.date) {
                EmptyMetric(text: "Strain comes from WHOOP; active energy from Apple Health.")
            }
            .cardLink("Connect data", hint: "Opens Integrations", id: "connect-home.load", action: { dashboard.open(.integrations) }) { ConnectData() }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("card-home.load")
        }
    }
}

/// Mini.tsx Gauge: a half circle, its track a lighter step of the fill's hue, 21 ticks inside, and a ringed dot at the
/// value.
struct HalfGauge: View {
    let fraction: Double

    var body: some View {
        Canvas { ctx, size in
            let w: CGFloat = 168, h: CGFloat = 92, r: CGFloat = 72
            let sx = size.width / w, sy = size.height / h
            let c = CGPoint(x: w / 2 * sx, y: (h - 6) * sy)
            let t = min(1, max(0, fraction))
            func point(_ to: Double, radius: CGFloat) -> CGPoint {
                let a = Double.pi * (1 - to)
                return CGPoint(x: c.x + radius * sx * cos(a), y: c.y - radius * sy * sin(a))
            }
            func arc(_ to: Double) -> Path {
                var p = Path()
                p.addArc(center: c, radius: r * sx, startAngle: .degrees(180), endAngle: .degrees(180 + 180 * to), clockwise: false)
                return p
            }
            ctx.stroke(arc(1), with: .color(Palette.gaugeTrack), style: StrokeStyle(lineWidth: 6, lineCap: .round))
            if t > 0 { ctx.stroke(arc(t), with: .color(Palette.gaugeFill), style: StrokeStyle(lineWidth: 6, lineCap: .round)) }
            for i in 0...20 {
                var tick = Path()
                tick.move(to: point(Double(i) / 20, radius: r - 12))
                tick.addLine(to: point(Double(i) / 20, radius: r - (i % 5 == 0 ? 18 : 15)))
                ctx.stroke(tick, with: .color(Palette.ink.opacity(0.18)), lineWidth: 1)
            }
            let e = point(t, radius: r)
            let dot = Path(ellipseIn: CGRect(x: e.x - 5, y: e.y - 5, width: 10, height: 10))
            ctx.stroke(dot, with: .color(Palette.ringOnCard), lineWidth: 4)
            ctx.fill(dot, with: .color(Palette.gaugeFill))
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Activity

/// Home.tsx ActivityCard: today's steps, the last 7 days as bars, and the step goal.
struct ActivityCard: View {
    let summary: Summary
    let goal: Double
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        if let l = summary.activity?.latest {
            let pct = Int((l.value / goal * 100).rounded())
            MetricCard(title: "Activity", route: .activity, metric: .steps, date: summary.date,
                       spoken: "Activity, \(Fmt.number(l.value)) steps, \(pct)% of your \(Fmt.number(goal)) step goal") {
                VStack(alignment: .leading, spacing: 6) {
                    MetricValue(value: Fmt.number(l.value), unit: "steps")
                    MiniBars(points: summary.activity?.series ?? []).frame(height: 52)
                    Spacer(minLength: 0)
                    VStack(spacing: 6) {
                        SignalFootRow { Text("\(pct)% of goal") } trailing: { Text(Fmt.compact(goal)) }
                            .font(.app(.caption))
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Palette.goalTrack)
                                Capsule().fill(Palette.good).frame(width: geo.size.width * min(1, l.value / goal))
                            }
                        }
                        .frame(height: 6)
                    }
                }
            }
            .accessibilityIdentifier("card-home.activity")
        } else {
            MetricCard(title: "Activity", route: .activity, metric: .steps, date: summary.date) {
                EmptyMetric(text: "No steps recorded yet.")
            }
            .cardLink("Connect data", hint: "Opens Integrations", id: "connect-home.activity", action: { dashboard.open(.integrations) }) { ConnectData() }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("card-home.activity")
        }
    }
}

// MARK: - Mini charts

/// A line over days, used by Trends (TrendsExtras.swift). Home's own are SignalLine and SignalDots.
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

/// Mini.tsx MiniBars, neutral: a bar a day with rounded tops, the latest in the darker step.
struct MiniBars: View {
    let points: [Point]

    var body: some View {
        Canvas { ctx, size in
            let n = points.count
            guard n > 0 else { return }
            let top = max(points.map(\.value).max() ?? 1, 1)
            let slot = size.width / CGFloat(n)
            let w = max(3, min(10, slot - 2))
            for (i, p) in points.enumerated() {
                let y = size.height - CGFloat(p.value / top) * (size.height - 4)
                let h = size.height - y
                guard h > 0 else { continue }
                let x = CGFloat(i) * slot + slot / 2 - w / 2
                let r = min(4, w / 2, h)
                let bar = Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadii: RectangleCornerRadii(topLeading: r, topTrailing: r))
                ctx.fill(bar, with: .color(i == n - 1 ? Palette.barNeutralAccent : Palette.barNeutral))
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Timeline colours

enum HomeTimelineCard {
    /// Each kind of event's colour on the track and in the list (Home.tsx KIND_COLOR).
    static func color(_ kind: String) -> Color {
        switch kind {
        case "sleep", "nap": Palette.series1
        case "workout": Palette.series2
        case "mindful": Palette.series3
        default: Palette.ink3
        }
    }

    /// Completed, In progress or Upcoming (Home.tsx TimelineCard state): wall times as recorded against the phone's
    /// local time, like the web; every event of a past day is completed.
    static func state(_ e: TimelineEvent, isToday: Bool, now: String) -> String {
        guard isToday else { return "Completed" }
        if String(e.end.prefix(16)) <= now { return "Completed" }
        if String(e.start.prefix(16)) <= now { return "In progress" }
        return "Upcoming"
    }

    /// Now as a local wall time, "YYYY-MM-DDTHH:MM".
    static func localNow(_ date: Date = Date()) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(format: "%04d-%02d-%02dT%02d:%02d", c.year!, c.month!, c.day!, c.hour!, c.minute!)
    }
}

// MARK: - Insights

/// Home.tsx InsightsCard: the latest insights, each opening its page.
struct HomeInsightsCard: View {
    let insights: [Insight]
    let today: String
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Recent insights").font(.app(size: 15, weight: .medium, relativeTo: .subheadline)).foregroundStyle(Palette.ink)
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, 14)
            if insights.isEmpty {
                Text("Insights appear after a week or two of data.").font(.app(.footnote)).foregroundStyle(Palette.ink3)
            }
            ForEach(insights) { insight in
                let (symbol, tone) = Self.style(insight.icon)
                Button {
                    if let route = AppRoute(page: insight.page) { dashboard.open(route) }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: symbol)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(tone.ink)
                            .frame(width: 36, height: 36)
                            .background(tone.background, in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(insight.text).font(.app(.footnote, weight: .medium)).foregroundStyle(Palette.ink).multilineTextAlignment(.leading)
                            Text(Fmt.relativeDay(insight.date, today: today)).font(.app(.caption)).foregroundStyle(Palette.ink3)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink3)
                    }
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .card()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("card-home.insights")
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
