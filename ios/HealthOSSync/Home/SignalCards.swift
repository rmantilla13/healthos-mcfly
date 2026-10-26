import SwiftUI

// Your signals, as pastel cards (src/components/home/Signals.tsx on VitalCard.tsx): resting heart rate, blood oxygen, HRV,
// sleep, recovery and respiratory rate, from GET /api/summary. Home shows them tall (`.home`), with each one's mini chart;
// Vitals and Sleep show them short (`.compact`), with the value and its status. A tap opens the metric's sheet, with a
// reading or not. Without one, a card is the design's empty state; Recovery is WHOOP's, so an Apple-only person sees it
// empty (their cardio fitness is on Body).
//
//     RestingHrCard(summary: s)                      // Home
//     HrvCard(summary: s, variant: .compact)         // Vitals, Sleep

/// A signal's words under its value: a level's dot (green, amber or red; the words carry it too), the words, and the
/// reading's date when it isn't the day shown.
struct SignalStatus: Equatable {
    var words: String
    /// The dot beside the words; nil for none (no baseline yet, or a level this app doesn't know).
    var level: VitalLevel?
    /// The reading's day ("Oct 23") when it isn't the day the card shows.
    var stale: String?
    /// Recovery's zone label: its words in ink, a little heavier.
    var zone = false

    /// The figure's status words for a vital (Signals.tsx VitalStatus): nil without a reading. Unlike the figure's dots,
    /// a card keeps the level of an older reading, with its date beside it.
    static func vital(_ v: Vital?, latest: Latest?, asOf: String) -> SignalStatus? {
        guard let latest else { return nil }
        let status = v?.status
        let level: VitalLevel?
        if status == nil {
            level = nil
        } else {
            switch v?.level ?? (status == "normal" ? "normal" : "unusual") {
            case "normal": level = .normal
            case "unusual": level = .unusual
            case "off": level = .off
            default: level = nil
            }
        }
        let up = status == "high"
        let words = status == nil ? "Building baseline" : status == "normal" ? "Normal"
            : level == .off ? (up ? "Well above usual" : "Well below usual") : up ? "Above usual" : "Below usual"
        return SignalStatus(words: words, level: level, stale: stale(latest.date, asOf))
    }

    /// The reading's date when it isn't `asOf` (Signals.tsx Stale).
    static func stale(_ date: String, _ asOf: String) -> String? { date == asOf ? nil : Fmt.day(date) }
}

/// What a signal card shows, worked out from the summary (one per card id), so tests can check every word against
/// Signals.tsx and VitalCard.tsx.
struct Signal: Equatable {
    enum Chart: Equatable {
        case none
        /// A smooth line over the days, its area faintly filled, the latest day ringed (Mini.tsx MiniLine).
        case line([Point], color: Color, height: CGFloat)
        /// Blood oxygen's line on 90 to 100, then where the latest sits on that scale (RangeScale).
        case spo2([Point], value: Double)
        /// One dot per night over the usual band (Mini.tsx MiniDots).
        case dots([Point], baseline: Double?)
        /// Recovery's rings beside the value, and where it sits on 0 to 100 in its zones.
        case recovery(Double)
    }

    let id: String
    let title: String
    let tint: CardTint
    let unit: String
    /// The reading as it reads ("62", "7.4"); nil when there's none, which draws the empty card.
    let value: String?
    let metric: MetricKey
    /// The card's own page, for the sheet's "Open {Page}".
    let page: AppRoute
    var status: SignalStatus?
    var chart: Chart = .none
    var footLeft: String?
    var footRight: String?
    /// HRV's key for the band: a small swatch before "usual".
    var swatch = false

    /// The unit in words, for VoiceOver.
    static let spokenUnits = ["bpm": "beats per minute", "%": "percent", "ms": "milliseconds", "hours": "hours", "breaths/min": "breaths per minute"]

    /// What VoiceOver reads: the title, the reading with its unit in words, and the status.
    var spoken: String {
        guard let value else { return "\(title), no reading yet" }
        var parts = ["\(title), \(value) \(Self.spokenUnits[unit] ?? unit)"]
        if let status { parts.append(status.words + (status.stale.map { ", \($0)" } ?? "")) }
        return parts.joined(separator: ", ")
    }

    // MARK: The six cards (Signals.tsx)

    static func restingHr(_ s: Summary, variant: MetricCardVariant = .home) -> Signal {
        let v = s.vitals?.heart
        let latest = s.restingHr?.latest ?? v?.latest
        let series = s.restingHr?.series ?? []
        let home = variant == .home && series.count > 1
        return Signal(id: "home.rhr", title: "Resting heart rate", tint: .green, unit: "bpm", value: latest.map { Fmt.number($0.value) },
                      metric: .restingHr, page: .vitals, status: SignalStatus.vital(v, latest: latest, asOf: s.date),
                      chart: home ? .line(series, color: Palette.series3, height: 52) : .none,
                      footLeft: home ? "Last 30 days" : nil)
    }

    static func spo2(_ s: Summary, variant: MetricCardVariant = .home) -> Signal {
        let l = s.spo2?.latest
        let home = variant == .home
        // The card calls anything not below the usual range "Normal" (the sheet's status says "at or above" for a high one).
        let status = l.map { l in
            SignalStatus(words: s.spo2?.status.map { $0 == "low" ? "Below your range" : "Normal" } ?? "Building baseline",
                         stale: SignalStatus.stale(l.date, s.date))
        }
        let chart: Chart = if home, let l { .spo2(s.spo2?.series ?? [], value: l.value) } else { .none }
        return Signal(id: "home.spo2", title: "Blood oxygen", tint: .peach, unit: "%",
                      value: l.map { Fmt.number($0.value, $0.value.truncatingRemainder(dividingBy: 1) == 0 ? 0 : 1) },
                      metric: .spo2, page: .vitals, status: status, chart: chart,
                      footLeft: home ? "90" : nil, footRight: home ? "100" : nil)
    }

    static let hrvWords = ["optimal": "Optimal", "normal": "Normal", "low": "Below baseline"]

    static func hrv(_ s: Summary, variant: MetricCardVariant = .home) -> Signal {
        let l = s.hrv?.latest
        let kind = s.hrv?.metric == "hrv_rmssd" ? "RMSSD" : "SDNN"
        let status = l.map { l in
            SignalStatus(words: s.hrv?.status.flatMap { hrvWords[$0] } ?? "Building baseline", stale: SignalStatus.stale(l.date, s.date))
        }
        let home = variant == .home
        return Signal(id: "home.hrv", title: "HRV", tint: .blue, unit: "ms", value: l.map { Fmt.number($0.value) },
                      metric: .hrv, page: .vitals, status: status,
                      chart: home && l != nil ? .dots(s.hrv?.series ?? [], baseline: s.hrv?.baseline) : .none,
                      footLeft: l == nil ? nil : home ? "usual · \(kind)" : kind, swatch: home && l != nil)
    }

    static func sleep(_ s: Summary, variant: MetricCardVariant = .home) -> Signal {
        let l = s.sleep?.latest
        let home = variant == .home && l != nil
        return Signal(id: "home.sleep", title: "Sleep", tint: .lavender, unit: "hours", value: l.map { Fmt.number($0.value, 1) },
                      metric: .sleepHours, page: .sleep,
                      status: l.map { SignalStatus(words: $0.value >= 7 ? "Good" : $0.value >= 6 ? "Fair" : "Short", stale: SignalStatus.stale($0.date, s.date)) },
                      chart: home ? .line(s.sleep?.series ?? [], color: Palette.series1, height: 48) : .none,
                      footLeft: home ? "Last 14 nights" : nil,
                      footRight: home ? s.sleep?.change.map { "\(Fmt.signed($0 * 100))% wk" } : nil)
    }

    static let zoneWords = ["red": "Low", "yellow": "Moderate", "green": "High"]

    static func recovery(_ s: Summary, variant: MetricCardVariant = .home) -> Signal {
        // WHOOP's recovery only: VO₂ max, which Apple Watch gives, is Body's.
        let r = s.readiness?.kind == "recovery" ? s.readiness : nil
        let zone = r.map { $0.zone ?? ($0.latest.value >= 67 ? "green" : $0.latest.value >= 34 ? "yellow" : "red") }
        let level: VitalLevel? = switch zone {
        case "green": .normal
        case "yellow": .unusual
        case "red": .off
        default: nil
        }
        let home = variant == .home
        let delta = r.flatMap { r in r.average.map { r.latest.value - $0 } }
        let chart: Chart = if home, let r { .recovery(r.latest.value) } else { .none }
        return Signal(id: "home.readiness", title: "Recovery", tint: .pink, unit: "%", value: r.map { Fmt.number($0.latest.value) },
                      metric: .recovery, page: .vitals,
                      status: r.map { SignalStatus(words: zone.flatMap { zoneWords[$0] } ?? zone ?? "", level: level, stale: SignalStatus.stale($0.latest.date, s.date), zone: true) },
                      chart: chart, footLeft: home ? delta.map { "\(Fmt.signed($0)) vs 30-day avg" } : nil)
    }

    static func respRate(_ s: Summary, variant: MetricCardVariant = .home) -> Signal {
        let v = s.vitals?.breathing
        let latest = s.respRate?.latest ?? v?.latest
        let series = s.respRate?.series ?? []
        let home = variant == .home && series.count > 1
        return Signal(id: "home.resp", title: "Respiratory rate", tint: .mint, unit: "breaths/min", value: latest.map { Fmt.number($0.value, 1) },
                      metric: .respRate, page: .vitals, status: SignalStatus.vital(v, latest: latest, asOf: s.date),
                      chart: home ? .line(series, color: Palette.series3, height: 52) : .none,
                      footLeft: home ? "Last 30 days" : nil)
    }

    /// Home's signal card for a card id; nil for an id that isn't one.
    static func of(_ id: String, _ s: Summary, variant: MetricCardVariant = .home) -> Signal? {
        switch id {
        case "home.rhr": restingHr(s, variant: variant)
        case "home.spo2": spo2(s, variant: variant)
        case "home.hrv": hrv(s, variant: variant)
        case "home.sleep": sleep(s, variant: variant)
        case "home.readiness": recovery(s, variant: variant)
        case "home.resp": respRate(s, variant: variant)
        default: nil
        }
    }

    /// The six, in Home's order (Home.tsx's first row).
    static let ids = ["home.rhr", "home.spo2", "home.hrv", "home.sleep", "home.readiness", "home.resp"]
}

// MARK: - The cards, for Home, Vitals and Sleep

struct RestingHrCard: View {
    let summary: Summary
    var variant: MetricCardVariant = .home
    var body: some View { SignalCard(signal: .restingHr(summary, variant: variant), date: summary.date, variant: variant) }
}

struct Spo2Card: View {
    let summary: Summary
    var variant: MetricCardVariant = .home
    var body: some View { SignalCard(signal: .spo2(summary, variant: variant), date: summary.date, variant: variant) }
}

struct HrvCard: View {
    let summary: Summary
    var variant: MetricCardVariant = .home
    var body: some View { SignalCard(signal: .hrv(summary, variant: variant), date: summary.date, variant: variant) }
}

struct SleepCard: View {
    let summary: Summary
    var variant: MetricCardVariant = .home
    var body: some View { SignalCard(signal: .sleep(summary, variant: variant), date: summary.date, variant: variant) }
}

struct RecoveryCard: View {
    let summary: Summary
    var variant: MetricCardVariant = .home
    var body: some View { SignalCard(signal: .recovery(summary, variant: variant), date: summary.date, variant: variant) }
}

struct RespRateCard: View {
    let summary: Summary
    var variant: MetricCardVariant = .home
    var body: some View { SignalCard(signal: .respRate(summary, variant: variant), date: summary.date, variant: variant) }
}

/// The card's frame (VitalCard.tsx): the title and its ↗, the value with its unit, and its status, chart and foot, or
/// without a reading the bold dash, "Connect a source to get started" and a Connect link to Integrations. The whole card
/// opens the metric's sheet; Connect is its own button over it.
struct SignalCard: View {
    let signal: Signal
    /// The day the card shows, where the sheet's window ends.
    let date: String
    var variant: MetricCardVariant = .home
    var section = "Your signals"
    @Environment(Dashboard.self) private var dashboard
    @State private var width: CGFloat = 343

    var body: some View {
        let empty = signal.value == nil
        MetricCard(title: signal.title, route: signal.page, tint: signal.tint, variant: variant, metric: signal.metric, section: section,
                   date: date, minHeight: Self.minHeight(variant, empty: empty, width: width), spoken: signal.spoken) {
            VStack(alignment: .leading, spacing: 0) {
                valueRow(empty: empty)
                if empty { emptyBody } else { readingBody }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .overlay(alignment: .topTrailing) {
            if case .recovery(let value) = signal.chart {
                SignalRings(value: value / 100).frame(width: 84, height: 84).padding(.top, 52).padding(.trailing, 14)
            }
        }
        // Connect is a button of its own, drawn over the card where its words are, so a tap there goes to
        // Integrations and not to the sheet.
        .cardLink("Connect a source", hint: "Opens Integrations", id: "connect-\(signal.id)", action: { dashboard.open(.integrations) }) { connectLabel }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("card-\(signal.id)")
    }

    /// Home's card with a reading grows to fit its chart (at least 236pt); an empty one keeps the design's 1.55:1, and
    /// a compact one 3.6:1, each with its floor (VitalCard's .vital-home and .vital-compact, home.css).
    static func minHeight(_ variant: MetricCardVariant, empty: Bool, width: CGFloat) -> CGFloat {
        switch variant {
        case .home: empty ? max(210, width / 1.55) : 236
        case .compact: max(176, width / 3.6)
        }
    }

    // MARK: Parts

    private func valueRow(empty: Bool) -> some View {
        HStack(alignment: empty ? .bottom : .lastTextBaseline, spacing: 8) {
            if empty {
                // No reading: a short bold bar, its unit small at its lower right.
                Capsule().fill(Palette.ink).frame(width: 22, height: 3).padding(.top, 14).padding(.bottom, 2)
            } else {
                Text(signal.value ?? "")
                    .font(.app(size: 38, weight: .medium, relativeTo: .largeTitle))
                    .tracking(-0.03 * 38)
                    .foregroundStyle(Palette.ink)
            }
            Text(signal.unit)
                .font(.app(size: 11, relativeTo: .caption2))
                .foregroundStyle(Palette.ink2)
                .padding(.bottom, empty ? 0 : 3)
                .offset(y: empty ? 6 : 0)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        // The card's own spacing (6) is already under the title: 16 in all, as .vital-value's margin.
        .padding(.top, 10)
    }

    @ViewBuilder private var emptyBody: some View {
        if variant == .compact { note("No reading yet").padding(.top, 12) }
        note("Connect a source to get started").padding(.top, variant == .compact ? 10 : 28)
        Spacer(minLength: 0)
        SignalFootRow {
            Text(variant == .compact ? "Awaiting data" : "No reading yet")
        } trailing: {
            // Where Connect goes: the real button is drawn over this (the overlay above).
            connectLabel.cardLinkSpot()
        }
        .padding(.top, 12)
    }

    private var connectLabel: some View {
        HStack(spacing: 3) {
            Text("Connect")
            if variant == .home { Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold)) }
        }
        .font(.app(size: 11.5, relativeTo: .caption2))
        .foregroundStyle(Palette.ink2)
    }

    @ViewBuilder private var readingBody: some View {
        if let status = signal.status {
            SignalStatusLine(status: status).padding(.top, 10)
        }
        Spacer(minLength: 0)
        if signal.chart != .none {
            chart.padding(.top, 12)
        }
        if signal.footLeft != nil || signal.footRight != nil {
            SignalFootRow {
                HStack(spacing: 5) {
                    if signal.swatch {
                        RoundedRectangle(cornerRadius: 2).fill(Palette.series1.opacity(0.18)).frame(width: 12, height: 8)
                    }
                    Text(signal.footLeft ?? "")
                }
            } trailing: {
                Text(signal.footRight ?? "")
            }
            .padding(.top, 12)
        }
    }

    @ViewBuilder private var chart: some View {
        VStack(spacing: 6) {
            switch signal.chart {
            case .none: EmptyView()
            case .line(let points, let color, let height):
                SignalLine(points: points, color: color).frame(height: height)
            case .spo2(let points, let value):
                SignalLine(points: points, color: Palette.series2, domain: 90...100).frame(height: 44)
                RangeScale(value: value, range: 90...100).padding(.top, 2)
            case .dots(let points, let baseline):
                SignalDots(points: points, baseline: baseline).frame(height: 56)
            case .recovery(let value):
                RangeScale(value: value, range: 0...100, zones: [(33, Palette.critical), (66, Palette.warning), (100, Palette.good)]).padding(.top, 2)
            }
        }
        .accessibilityHidden(true)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.app(size: 11.5, relativeTo: .caption2)).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true)
    }
}

/// A status line under a value: the level's dot, the words, and the date of an older reading.
struct SignalStatusLine: View {
    let status: SignalStatus

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            if let level = status.level {
                Circle().fill(level.color).frame(width: 8, height: 8)
            }
            Text(status.words)
                .font(.app(.caption, weight: status.zone ? .medium : .regular))
                .foregroundStyle(status.zone ? Palette.ink : Palette.ink2)
            if let stale = status.stale {
                Text(stale).font(.app(size: 11, relativeTo: .caption2)).foregroundStyle(Palette.ink3)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A card's foot: one thing on the left, one on the right; at large text sizes, when they don't fit side by side, one
/// under the other, so neither is cut off.
struct SignalFootRow<Leading: View, Trailing: View>: View {
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 8) {
                leading
                Spacer(minLength: 8)
                trailing
            }
            .lineLimit(1)
            VStack(alignment: .leading, spacing: 4) {
                leading
                trailing
            }
        }
        .font(.app(size: 11.5, relativeTo: .caption2))
        .foregroundStyle(Palette.ink2)
    }
}

// MARK: - Mini charts (src/charts/Mini.tsx)

/// The smooth line through points (charts/core.tsx smoothPath): a monotone cubic, so it never overshoots a day.
enum SmoothPath {
    static func path(_ pts: [CGPoint]) -> Path {
        var p = Path()
        let n = pts.count
        guard n > 0 else { return p }
        p.move(to: pts[0])
        guard n > 1 else { return p }
        var dx: [CGFloat] = [], slope: [CGFloat] = []
        for i in 0..<(n - 1) {
            dx.append(pts[i + 1].x - pts[i].x)
            slope.append((pts[i + 1].y - pts[i].y) / (dx[i] == 0 ? 1 : dx[i]))
        }
        var tangent: [CGFloat] = [slope[0]]
        if n > 2 { for i in 1..<(n - 1) { tangent.append(slope[i - 1] * slope[i] <= 0 ? 0 : (slope[i - 1] + slope[i]) / 2) } }
        tangent.append(slope[n - 2])
        for i in 0..<(n - 1) {
            if slope[i] == 0 {
                tangent[i] = 0
                tangent[i + 1] = 0
                continue
            }
            let a = tangent[i] / slope[i], b = tangent[i + 1] / slope[i]
            let h = a * a + b * b
            if h > 9 {
                let t = 3 / h.squareRoot()
                tangent[i] = t * a * slope[i]
                tangent[i + 1] = t * b * slope[i]
            }
        }
        for i in 0..<(n - 1) {
            let h = dx[i] / 3
            p.addCurve(to: pts[i + 1], control1: CGPoint(x: pts[i].x + h, y: pts[i].y + tangent[i] * h),
                       control2: CGPoint(x: pts[i + 1].x - h, y: pts[i + 1].y - tangent[i + 1] * h))
        }
        return p
    }
}

/// Mini.tsx MiniLine: the line, its area at a tenth of its colour, and the latest day as a ringed dot.
struct SignalLine: View {
    let points: [Point]
    let color: Color
    var domain: ClosedRange<Double>?

    /// Each point's place in a box (6pt in from every edge), as the web's xOf and yOf.
    static func places(_ points: [Point], size: CGSize, domain: ClosedRange<Double>?) -> [CGPoint] {
        let values = points.map(\.value)
        guard let first = values.first else { return [] }
        let lo = domain?.lowerBound ?? values.min() ?? first, hi = domain?.upperBound ?? values.max() ?? first
        let span = hi - lo == 0 ? 1 : hi - lo
        let pad: CGFloat = 6, n = points.count
        return values.enumerated().map { i, v in
            let x = n <= 1 ? size.width / 2 : pad + CGFloat(i) / CGFloat(n - 1) * (size.width - pad * 2)
            let y = pad + (1 - CGFloat((min(hi, max(lo, v)) - lo) / span)) * (size.height - pad * 2)
            return CGPoint(x: x, y: y)
        }
    }

    var body: some View {
        Canvas { ctx, size in
            let pts = Self.places(points, size: size, domain: domain)
            guard let first = pts.first, let last = pts.last else { return }
            let line = SmoothPath.path(pts)
            var area = line
            area.addLine(to: CGPoint(x: last.x, y: size.height))
            area.addLine(to: CGPoint(x: first.x, y: size.height))
            area.closeSubpath()
            ctx.fill(area, with: .color(color.opacity(0.1)))
            ctx.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            let dot = Path(ellipseIn: CGRect(x: last.x - 4, y: last.y - 4, width: 8, height: 8))
            ctx.stroke(dot, with: .color(Palette.ringOnCard), lineWidth: 4)
            ctx.fill(dot, with: .color(color))
        }
        .accessibilityHidden(true)
    }
}

/// Mini.tsx MiniDots: one dot per night over the usual band (the mean, ± one standard deviation of the nights before the
/// latest), the latest larger, in the accent and ringed.
struct SignalDots: View {
    let points: [Point]
    let baseline: Double?

    struct Scale: Equatable {
        let mean: Double
        let sd: Double
        let lo: Double
        let hi: Double
    }

    static func scale(_ points: [Point], baseline: Double?) -> Scale? {
        let values = points.map(\.value)
        guard let first = values.first else { return nil }
        let prior = Array(values.dropLast())
        let mean = baseline ?? (prior.isEmpty ? first : prior.reduce(0, +) / Double(prior.count))
        let sd = prior.count > 1 ? (prior.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(prior.count - 1)).squareRoot() : 0
        return Scale(mean: mean, sd: sd, lo: min(values.min() ?? first, mean - sd) * 0.96, hi: max(values.max() ?? first, mean + sd) * 1.04)
    }

    var body: some View {
        Canvas { ctx, size in
            guard let s = Self.scale(points, baseline: baseline) else { return }
            let pad: CGFloat = 6, n = points.count
            let x = { (i: Int) -> CGFloat in n <= 1 ? size.width / 2 : pad + CGFloat(i) / CGFloat(n - 1) * (size.width - pad * 2) }
            let y = { (v: Double) -> CGFloat in pad + (1 - CGFloat((v - s.lo) / (s.hi - s.lo == 0 ? 1 : s.hi - s.lo))) * (size.height - pad * 2) }
            if s.sd > 0 {
                let band = CGRect(x: 0, y: y(s.mean + s.sd), width: size.width, height: y(s.mean - s.sd) - y(s.mean + s.sd))
                ctx.fill(Path(roundedRect: band, cornerRadius: 4), with: .color(Palette.series1.opacity(0.09)))
            }
            var mid = Path()
            mid.move(to: CGPoint(x: 0, y: y(s.mean)))
            mid.addLine(to: CGPoint(x: size.width, y: y(s.mean)))
            ctx.stroke(mid, with: .color(Palette.series1.opacity(0.25)), lineWidth: 1)
            for (i, p) in points.enumerated() {
                let latest = i == n - 1
                let r: CGFloat = latest ? 4.5 : 3
                let dot = Path(ellipseIn: CGRect(x: x(i) - r, y: y(p.value) - r, width: r * 2, height: r * 2))
                if latest { ctx.stroke(dot, with: .color(Palette.ringOnCard), lineWidth: 4) }
                ctx.fill(dot, with: .color(latest ? Palette.barAccent : Palette.bar))
            }
        }
        .accessibilityHidden(true)
    }
}

/// Mini.tsx RangeScale: a hairline track, optional zones on it, and a marker at the value.
struct RangeScale: View {
    let value: Double
    let range: ClosedRange<Double>
    var zones: [(Double, Color)] = []

    /// How far along the scale the value sits, 0…1.
    static func position(_ value: Double, in range: ClosedRange<Double>) -> Double {
        min(1, max(0, (value - range.lowerBound) / (range.upperBound - range.lowerBound)))
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let span = range.upperBound - range.lowerBound
            ZStack(alignment: .topLeading) {
                Capsule().fill(Palette.axis).frame(width: w, height: 2).offset(y: 4)
                ForEach(Array(zones.enumerated()), id: \.offset) { i, zone in
                    let from = i == 0 ? range.lowerBound : zones[i - 1].0
                    Capsule().fill(zone.1)
                        .frame(width: max(0, (zone.0 - from) / span * w - 2), height: 4)
                        .offset(x: (from - range.lowerBound) / span * w, y: 3)
                }
                Circle().fill(Palette.ink)
                    .background(Circle().fill(Palette.surface).padding(-2))
                    .frame(width: 10, height: 10)
                    .offset(x: Self.position(value, in: range) * w - 5)
            }
        }
        .frame(height: 10)
        .accessibilityHidden(true)
    }
}

/// Recovery's decorative rings: the dot sits at the score's place on the outer one (Signals.tsx Rings).
struct SignalRings: View {
    let value: Double

    /// Where the dot sits on a 120-wide box: the outer ring, from 135° round to 45°.
    static func dot(_ value: Double) -> CGPoint {
        let a = Double.pi * (0.75 - 1.5 * min(1, max(0, value)))
        return CGPoint(x: 60 + 56 * cos(a), y: 60 - 56 * sin(a))
    }

    var body: some View {
        Canvas { ctx, size in
            let scale = min(size.width, size.height) / 120
            for r in [56.0, 44, 32, 20] {
                let rr = r * scale
                ctx.stroke(Path(ellipseIn: CGRect(x: size.width / 2 - rr, y: size.height / 2 - rr, width: rr * 2, height: rr * 2)),
                           with: .color(Palette.ink.opacity(0.09)), lineWidth: 1)
            }
            let d = Self.dot(value)
            let p = CGPoint(x: size.width / 2 + (d.x - 60) * scale, y: size.height / 2 + (d.y - 60) * scale)
            let r = 3.5 * scale
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)), with: .color(Palette.ink2))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
