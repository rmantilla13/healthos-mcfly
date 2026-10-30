import SwiftUI

// The Sleep page's Overview: one night (Sleep.tsx Overview). Three short cards first (VitalCard's compact size): time
// asleep, WHOOP's sleep performance and sleep efficiency, each saying why when it has no reading. Then the night's stages
// and insights, and its timeline beside resting heart rate. With no source and no night ever, only the three cards,
// empty, as they'll look once a wearable is connected.

/// Where a card's ↗ goes when there's no metric sheet, and the sheet's "Open …" when there is: the Trends tab.
extension AppRoute {
    static let sleepTrends = AppRoute(.sleep, query: ["tab": "trends"])
}

// MARK: - The three cards

/// A short tappable card (VitalCard's compact frame): its title and ↗, and what it holds. A tap opens the metric's
/// sheet, or runs `action` (another tab of this page).
struct SleepMetricFrame<Content: View>: View {
    let title: String
    let tint: CardTint
    /// An empty card keeps the design's 3.6:1; one with a reading grows to fit its chart (sleep.css), at least 176.
    var empty = false
    /// What VoiceOver reads for the whole card.
    let spoken: String
    let hint: String
    let action: () -> Void
    @ViewBuilder let content: Content
    @State private var width: CGFloat = 343

    var body: some View {
        Button(action: action) {
            CardMinHeight(min: (empty ? SignalCard.minHeight(.compact, empty: true, width: width) : 176) - 38) {
                VStack(alignment: .leading, spacing: 6) {
                    CardHead(title: title)
                    content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .card(tint)
            .contentShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        }
        .buttonStyle(CardPressStyle())
        .accessibilityLabel(spoken)
        .accessibilityHint(hint)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

/// The value with its unit (.vital-value), or the bold dash when there's no reading.
struct SleepValueRow: View {
    let value: String?
    let unit: String

    var body: some View {
        HStack(alignment: value == nil ? .bottom : .lastTextBaseline, spacing: 8) {
            if let value {
                Text(value)
                    .font(.app(size: 38, weight: .medium, relativeTo: .largeTitle))
                    .tracking(-0.03 * 38)
                    .foregroundStyle(Palette.ink)
            } else {
                Capsule().fill(Palette.ink).frame(width: 22, height: 3).padding(.top, 14).padding(.bottom, 2)
            }
            Text(unit)
                .font(.app(size: 11, relativeTo: .caption2))
                .foregroundStyle(Palette.ink2)
                .padding(.bottom, value == nil ? 0 : 3)
                .offset(y: value == nil ? 6 : 0)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .padding(.top, 10)
    }
}

/// A card's foot: one thing on the left, one on the right, or under each other when they don't fit (.vital-foot).
private struct SleepFoot<Trailing: View>: View {
    let leading: String
    @ViewBuilder let trailing: Trailing

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(leading).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                trailing
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(leading).fixedSize(horizontal: false, vertical: true)
                trailing
            }
        }
        .font(.app(size: 11.5, relativeTo: .caption2))
        .foregroundStyle(Palette.ink2)
        .padding(.top, 12)
    }
}

/// The Overview's three cards, by their card ids.
struct SleepNightCard: View {
    let id: String
    let context: SleepNightContext
    /// Today's summary, when it's for this night (its weekly change and 14 nights).
    let summary: Summary?
    let open: (SleepTab) -> Void
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        switch id {
        case "sleep.total": total
        case "sleep.score": performance
        default: efficiency
        }
    }

    private var night: SleepNightDetail { context.night }

    // MARK: Sleep

    @ViewBuilder private var total: some View {
        if let h = night.asleepHours {
            let change = summary?.sleep?.change.map { $0 * 100 }
            let source = context.source
            SleepMetricFrame(title: "Sleep", tint: .lavender,
                             spoken: spoken("Sleep", "\(Fmt.number(h, 1)) hours", change.flatMap { SleepChangeChip.shows($0) ? Self.changeWords($0) : nil }, context.label, source),
                             hint: "Opens Sleep details", action: { sheet(.sleepHours) }) {
                VStack(alignment: .leading, spacing: 0) {
                    SleepValueRow(value: Fmt.number(h, 1), unit: "hours")
                    if let change, SleepChangeChip.shows(change) {
                        SleepChangeChip(pct: change, better: "up", title: SleepWords.sleepChange).padding(.top, 10)
                    }
                    Spacer(minLength: 0)
                    if night.segments.count > 1 {
                        SleepNightBars(segments: night.segments).padding(.top, 12)
                    } else if let series = summary?.sleep?.series, series.count > 1 {
                        SleepMiniBars(points: series).padding(.top, 12)
                    }
                    SleepFoot(leading: context.label) { Text(source ?? "") }
                }
            }
        } else if context.bare {
            empty(id: "sleep.total", title: "Sleep", tint: .lavender, unit: "hours", metric: .sleepHours)
        } else {
            noReading(title: "Sleep", tint: .lavender, unit: "hours", notes: [SleepWords.noNight], foot: context.label)
        }
    }

    // MARK: Performance and efficiency

    @ViewBuilder private var performance: some View {
        let title = "Sleep performance"
        if let v = night.performance {
            score(title: title, tint: .green, value: v, metric: .sleepPerformance, foot: SleepWords.performanceFoot)
        } else if context.bare {
            empty(id: "sleep.score", title: title, tint: .green, unit: "%", metric: .sleepPerformance)
        } else if !context.whoop {
            // Only WHOOP scores a night this way: say so, rather than wait for a reading that won't come.
            noReading(title: title, tint: .green, unit: "%", notes: SleepWords.performanceNoReading, foot: SleepWords.whoopOnly, connect: true)
        } else {
            noReading(title: title, tint: .green, unit: "%", notes: night.asleepHours == nil ? [SleepWords.noNight] : [SleepWords.noWhoopNight],
                      foot: context.label)
        }
    }

    @ViewBuilder private var efficiency: some View {
        let title = "Sleep efficiency"
        if let v = night.efficiency {
            score(title: title, tint: .blue, value: v, metric: .sleepEfficiency, foot: SleepWords.efficiencyFoot)
        } else if context.bare {
            empty(id: "sleep.efficiency", title: title, tint: .blue, unit: "%", metric: .sleepEfficiency)
        } else {
            noReading(title: title, tint: .blue, unit: "%", notes: night.asleepHours == nil ? [SleepWords.noNight] : SleepWords.efficiencyNoReading,
                      foot: context.label)
        }
    }

    /// A score card: the value, Good, Fair or Low, and the bar.
    private func score(title: String, tint: CardTint, value: Double, metric: MetricKey, foot: String) -> some View {
        let band = SleepWords.band(value)
        let text = Self.score(value)
        return SleepMetricFrame(title: title, tint: tint, spoken: spoken(title, "\(text) percent", band, foot),
                                hint: "Opens \(title) details", action: { sheet(metric) }) {
            VStack(alignment: .leading, spacing: 0) {
                SleepValueRow(value: text, unit: "%")
                SleepScorePill(band: band).padding(.top, 10)
                Spacer(minLength: 0)
                SleepScoreBar(value: value, label: "\(title) \(text)%, \(band.lowercased())").padding(.top, 12)
                Text(foot).font(.app(size: 11.5, relativeTo: .caption2)).foregroundStyle(Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            }
        }
    }

    /// The design's empty card (VitalCard with no value): the shared signal card, empty.
    private func empty(id: String, title: String, tint: CardTint, unit: String, metric: MetricKey) -> some View {
        SignalCard(signal: Signal(id: id, title: title, tint: tint, unit: unit, value: nil, metric: metric, page: .sleepTrends),
                   date: night.date, variant: .compact, section: "Sleep")
    }

    /// A card without a reading, for what the shared empty card doesn't cover: a source that doesn't measure this, or a
    /// night with nothing recorded (Sleep.tsx NoReading). Its ↗ opens the Trends tab.
    private func noReading(title: String, tint: CardTint, unit: String, notes: [String], foot: String, connect: Bool = false) -> some View {
        SleepMetricFrame(title: title, tint: tint, empty: true, spoken: spoken(title, "no reading", notes.joined(separator: ". "), foot),
                         hint: "Opens Sleep trends", action: { open(.trends) }) {
            VStack(alignment: .leading, spacing: 0) {
                SleepValueRow(value: nil, unit: unit)
                ForEach(Array(notes.enumerated()), id: \.offset) { i, note in
                    Text(note).font(.app(size: 11.5, relativeTo: .caption2)).foregroundStyle(Palette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, i == 0 ? 12 : 4)
                }
                Spacer(minLength: 0)
                SleepFoot(leading: foot) {
                    if connect { connectLabel.cardLinkSpot() }
                }
            }
        }
        .cardLink("Connect WHOOP", hint: "Opens Integrations", id: "sleep-connect-whoop", action: { dashboard.open(.integrations) }) { connectLabel }
    }

    private var connectLabel: some View {
        Text("Connect").font(.app(size: 11.5, relativeTo: .caption2)).foregroundStyle(Palette.ink2)
    }

    private func sheet(_ metric: MetricKey) {
        dashboard.showMetric(metric, section: "Sleep", page: .sleepTrends, date: night.date)
    }

    private func spoken(_ parts: String?...) -> String { parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ") }

    /// A score as the web writes it: whole numbers without decimals.
    static func score(_ value: Double) -> String { Fmt.number(value, value.rounded() == value ? 0 : 1) }

    static func changeWords(_ pct: Double) -> String {
        "\(SleepWords.sleepChange): \(pct > 0 ? "up" : "down") \(Fmt.number(abs(pct).rounded())) percent"
    }
}

// MARK: - The night's cards

/// A section card's title row: the title and, when it opens another tab, its ↗ (Home.tsx CardHead, .metric-head).
private struct SleepCardTitle: View {
    let title: String
    var size: CGFloat = 13
    var open: (() -> Void)?

    var body: some View {
        let style: Font.TextStyle = size > 14 ? .subheadline : .footnote
        HStack(alignment: .center, spacing: 8) {
            Text(title).font(.app(size: size, weight: .medium, relativeTo: style)).foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            if let open {
                Button(action: open) {
                    Image(systemName: "arrow.up.right").font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.ink2)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, -12)
                .padding(.trailing, -12)
                .accessibilityLabel("Open \(title)")
            }
        }
    }
}

/// The night stage by stage (Sleep.tsx StagesCard): the hypnogram, or the totals as one bar when the night has no stages
/// through it, then each stage's time and share, and why the stages through the night are missing when they are.
struct SleepStagesCard: View {
    let night: SleepNightDetail
    let open: (SleepTab) -> Void

    static let rows: [(key: String, label: String)] = [("awake", "Awake"), ("rem", "REM"), ("light", "Light"), ("deep", "Deep")]

    var body: some View {
        let staged = night.staged
        let st = night.stageTotals
        let total = st?.total ?? 0
        VStack(alignment: .leading, spacing: 0) {
            SleepCardTitle(title: "Sleep stages", open: { open(.stages) })
            if staged {
                SleepHypnogram(segments: night.segments).padding(.top, 8)
            } else if let st, total > 0 {
                SleepStageBar(stages: st)
            }
            if let st, total > 0 {
                SleepFigureGrid(items: Self.rows.map { SleepFigureItem(id: $0.key, label: $0.label, color: SleepStageColor.of($0.key), hours: st.hours($0.key), share: Int((st.hours($0.key) / total * 100).rounded())) }) {
                    SleepStageFigure(label: $0.label, color: $0.color, hours: $0.hours, share: $0.share)
                }
                .padding(.top, 14)
                if !staged {
                    Text(SleepWords.stagesNote(source: night.source, date: night.date, today: night.today))
                        .font(.app(size: 12, relativeTo: .caption)).foregroundStyle(Palette.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 10)
                }
            } else {
                SleepNoData(text: SleepWords.noStages).padding(.top, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("card-sleep.stages")
    }
}

/// One figure in a SleepFigureGrid.
struct SleepFigureItem: Identifiable {
    let id: String
    let label: String
    let color: Color
    let hours: Double
    let share: Int
}

/// A card's line when it has nothing to show (.metric-empty).
private struct SleepNoData: View {
    let text: String
    var body: some View {
        Text(text).font(.app(size: 13, relativeTo: .footnote)).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true)
    }
}

/// Sleep insights (Sleep.tsx InsightsCard): up to four, each opening the tab that says more.
struct SleepInsightsCard: View {
    let rows: [SleepInsightRow]
    let open: (SleepTab) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SleepCardTitle(title: "Sleep insights", size: 15).padding(.bottom, 14)
            if rows.isEmpty {
                Text(SleepWords.insightsEmpty).font(.app(size: 13, relativeTo: .footnote)).foregroundStyle(Palette.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(rows) { row in
                let (symbol, tone) = SleepInsightRow.style(row.icon)
                Button { open(row.tab) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: symbol)
                            .font(.system(size: 15, weight: .semibold))
                            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                            .foregroundStyle(tone.ink)
                            .frame(width: 36, height: 36)
                            .background(tone.background, in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.text).font(.app(size: 13, weight: .medium, relativeTo: .footnote)).foregroundStyle(Palette.ink)
                                .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                            if let note = row.note {
                                Text(note).font(.app(size: 12, relativeTo: .caption)).foregroundStyle(Palette.ink3)
                                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink3)
                    }
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens \(row.tab.label)")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("card-sleep.insights")
    }
}

/// The night from bed to waking (Sleep.tsx TimelineCard): the one-line timeline with the deepest sleep marked, then
/// when you fell asleep, slept deepest, woke up, and the time in bed.
struct SleepTimelineCard: View {
    let night: SleepNightDetail
    @Environment(\.duoBand) private var band
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let segs = night.segments
        let start = segs.first?.start ?? night.fellAsleep
        let end = segs.last?.end ?? night.wokeUp
        VStack(alignment: .leading, spacing: 0) {
            SleepCardTitle(title: "Sleep timeline", size: 15).padding(.bottom, 14)
            if let start, let end {
                SleepStageTimeline(segments: segs, start: start, end: end, marker: night.deepPeak, narrow: band == .compact || typeSize.isAccessibilitySize)
                SleepFigureGrid(items: facts) { fact in
                    HStack(alignment: .top, spacing: 10) {
                        if let color = fact.color {
                            Circle().fill(color).frame(width: 12, height: 12).padding(.top, 2)
                        } else {
                            Image(systemName: "moon").font(.system(size: 14)).foregroundStyle(Palette.ink2).frame(width: 16)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(fact.label).font(.app(size: 12, relativeTo: .caption)).foregroundStyle(Palette.ink2)
                            Text(fact.value).font(.app(size: 15, weight: .medium, relativeTo: .subheadline)).foregroundStyle(Palette.ink)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
                .padding(.top, 18)
                if night.source == "whoop", segs.isEmpty {
                    Text(SleepWords.whoopTimeline).font(.app(size: 12, relativeTo: .caption)).foregroundStyle(Palette.ink3)
                        .fixedSize(horizontal: false, vertical: true).padding(.top, 10)
                }
            } else {
                SleepNoData(text: SleepWords.noNight)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("card-sleep.timeline")
    }

    struct Fact: Identifiable {
        let id: String
        let label: String
        let value: String
        let color: Color?
    }

    private var facts: [Fact] {
        var out: [Fact] = []
        if let t = night.fellAsleep { out.append(Fact(id: "fell", label: "Fell asleep", value: SleepClock.wall(t), color: Palette.hypAwake)) }
        if let t = night.deepPeak { out.append(Fact(id: "deep", label: "Deepest sleep", value: SleepClock.wall(t), color: Palette.stageDeep)) }
        if let t = night.wokeUp { out.append(Fact(id: "woke", label: "Woke up", value: SleepClock.wall(t), color: Palette.stageLight)) }
        if let h = night.inBedHours { out.append(Fact(id: "bed", label: "In bed", value: Fmt.hoursMinutes(h), color: nil)) }
        return out
    }
}

/// Resting heart rate beside the night (Sleep.tsx RestingHrCard): today's reading, this week against last, its last 14
/// days, and where it sits against your usual.
struct SleepRestingHrCard: View {
    let summary: Summary?
    let points: [Point]

    static let statusWords = ["low": "Below your usual", "normal": "Within your usual", "high": "Above your usual"]

    var body: some View {
        let v = summary?.vitals?.heart
        let w = summary?.week?.restingHr
        let change: Double? = w.flatMap { w in w.avg.flatMap { avg in w.prev.flatMap { $0 == 0 ? nil : (avg - $0) / $0 * 100 } } }
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                Text("Resting heart rate").font(.app(.footnote, weight: .medium)).foregroundStyle(Palette.ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                if let change, SleepChangeChip.shows(change) {
                    SleepChangeChip(pct: change, better: "down", title: "This week's average against last week's")
                }
            }
            if let latest = v?.latest {
                VStack(alignment: .leading, spacing: 6) {
                    Text(Fmt.number(latest.value)).font(.app(size: 40, weight: .medium, relativeTo: .largeTitle)).tracking(-1.2).foregroundStyle(Palette.ink)
                    Text("bpm").font(.app(size: 13, relativeTo: .footnote)).foregroundStyle(Palette.ink2)
                }
                .padding(.top, 6)
                .accessibilityElement(children: .combine)
                if points.count > 1 {
                    SignalLine(points: points, color: Palette.series1).frame(height: 52).padding(.top, 10)
                        .accessibilityLabel("Resting heart rate, last 14 days")
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(v?.status.flatMap { Self.statusWords[$0] } ?? "Building your baseline")
                        .font(.app(size: 13, weight: .medium, relativeTo: .footnote)).foregroundStyle(Palette.ink)
                    if let s = summary, latest.date != s.date {
                        Text(Fmt.day(latest.date)).font(.app(size: 11, relativeTo: .caption2)).foregroundStyle(Palette.ink3)
                    }
                }
                .padding(.top, 10)
            } else {
                SleepNoData(text: SleepWords.noRestingHr).padding(.top, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("card-sleep.rhr")
    }
}
