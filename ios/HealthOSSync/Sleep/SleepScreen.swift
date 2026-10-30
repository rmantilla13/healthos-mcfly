import SwiftUI

/// The Sleep page (src/pages/Sleep.tsx), under More: "Your night, in perspective." with its four tabs. Overview is one
/// night (the day picker's, shared with Home as the web shares its date); Stages, Trends and Coaching look across nights.
/// `tab` is the web's ?tab= (stages, trends, coaching), for the page to open on; the same link opened again while the
/// page is up applies its tab again.
///
/// On the iPhone Duo open in landscape the page is a chart page: one scrolling page split on the fold, its cards two to a
/// row, one each side, so both sides carry the night (or the nights) and twice as many show at once. The tabs keep to the
/// leading side, the day or range picker to the trailing. On every iPhone, the outer display and the inner display
/// upright, it's the web's one column, the three signals 3-up in the medium band as the web has them.
struct SleepScreen: View {
    var tab: String?
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        PhaseGate {
            // One person's, on one server: someone else signing in, or another server, starts the page anew, so nothing
            // read for the last person is ever on screen for the next.
            SleepPage(linkTab: tab).id(identity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.page)
    }

    private var identity: String {
        "\(Config.serverURL()?.absoluteString ?? "")|\(dashboard.status?.user?.id ?? dashboard.account?.id ?? "")"
    }
}

/// The page itself: its model, loaders and refresh sit on the DuoPage, which a fold never rebuilds (P4, P14); the tab's
/// layout is chosen inside it.
struct SleepPage: View {
    let linkTab: String?
    @Environment(Dashboard.self) private var dashboard
    @Environment(\.sleepReads) private var reads
    @State private var model: SleepModel

    init(linkTab: String?, model: SleepModel? = nil) {
        self.linkTab = linkTab
        _model = State(initialValue: model ?? SleepModel(tab: SleepTab(query: linkTab)))
    }

    var body: some View {
        let generation = dashboard.generation
        let days = SleepPage.rangeDays(dashboard.rangeDays)
        DuoPage { _ in
            SleepTabContent(model: model)
        }
        .refreshable { await dashboard.load() }
        // The night decides whether this server has the Overview, and bed and wake times whether it has Coaching, so both
        // are read whatever the tab.
        .task(id: "\(dashboard.date ?? "today")|\(generation)") {
            await model.loadNight(date: dashboard.date, generation: generation, reads: reads, dashboard: dashboard)
        }
        .task(id: generation) {
            await model.loadTiming(generation: generation, reads: reads, dashboard: dashboard)
        }
        .task(id: generation) {
            await model.loadPatterns(generation: generation, reads: reads, dashboard: dashboard)
        }
        .task(id: "\(model.shownTab == .stages)|\(days)|\(generation)") {
            guard model.shownTab == .stages else { return }
            await model.loadTrends(stages: true, days: days, generation: generation, reads: reads, dashboard: dashboard)
        }
        .task(id: "\(model.shownTab == .trends)|\(days)|\(generation)") {
            guard model.shownTab == .trends else { return }
            await model.loadTrends(stages: false, days: days, generation: generation, reads: reads, dashboard: dashboard)
        }
        // A link to Sleep opened again while the page is up (its path doesn't change): its tab, once per opening.
        .task(id: dashboard.request(for: .sleep)?.id ?? 0) {
            let request = dashboard.request(for: .sleep)
            // The first look: the link there is the one that opened the page, whose tab the page started on.
            guard let handled = model.linkHandled else {
                model.linkHandled = request?.id ?? 0
                return
            }
            guard let request, request.id != handled else { return }
            model.tab = SleepTab(query: request.route.query["tab"])
            model.linkHandled = request.id
        }
    }

    /// The range in days: the shared range, with Day (which Sleep doesn't offer) read as 30 days, as on the web.
    static func rangeDays(_ shared: Int) -> Int { shared == ChartRange.day.days ? 30 : shared }
}

/// The tab on screen: one scroll view for the page, which a fold keeps (P14); each tab chooses its rows inside it, and
/// a new tab opens at its top, as the web's tabs (each its own link) do.
private struct SleepTabContent: View {
    let model: SleepModel

    var body: some View {
        DuoScroll {
            SleepRows {
                switch model.shownTab {
                case .overview: SleepOverviewTab(model: model)
                case .stages: SleepStagesTab(model: model)
                case .trends: SleepTrendsTab(model: model)
                case .coaching: SleepCoachingTab(model: model)
                }
            }
        }
        .id(model.shownTab)
    }
}

// MARK: - The intro, tabs and pickers

/// The page's intro (PageIntro with Manage sources), then the tabs and the tab's picker: on one row from the medium band
/// up, as the web's at 669, else the picker under the tabs on the trailing side. On a page split on the fold, the tabs
/// keep to the leading side and the picker to the trailing one, never across the fold.
private struct SleepHeader<Tools: View>: View {
    let model: SleepModel
    var sub = SleepWords.sub
    var showsTabs = true
    @ViewBuilder let tools: Tools
    @Environment(\.duoBand) private var band
    @Environment(\.duoFold) private var fold

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageIntro(SleepWords.title, sub: sub) { SleepManageSources() }
            if showsTabs {
                if fold.splits {
                    // The tabs fill the leading side (duoOneSide); the picker, no wider than the narrower side, sits at the
                    // trailing edge, so wholly on the trailing side.
                    ZStack(alignment: .trailing) {
                        tabs
                        tools
                    }
                } else if band == .compact {
                    tabs
                    tools.frame(maxWidth: .infinity, alignment: .trailing)
                } else {
                    HStack(alignment: .center, spacing: 12) {
                        tabs
                        tools
                    }
                }
            }
        }
        .padding(.bottom, 4)
    }

    private var tabs: some View {
        PageTabs(tabs: model.tabs.map { PageTab(id: $0.rawValue, label: $0.label) },
                 selection: Binding(get: { model.shownTab.rawValue }, set: { model.tab = SleepTab(query: $0) }),
                 label: SleepWords.tabsLabel)
            .accessibilityIdentifier("sleep-tabs")
    }
}

extension SleepHeader where Tools == EmptyView {
    init(model: SleepModel) {
        self.init(model: model) { EmptyView() }
    }
}

/// "Manage sources ↗" (ManageSources in PageIntro.tsx): a quiet pill to Integrations.
private struct SleepManageSources: View {
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        Button { dashboard.open(.integrations) } label: {
            HStack(spacing: 5) {
                Text("Manage sources")
                Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .semibold)).accessibilityHidden(true)
            }
        }
        .buttonStyle(.quietPill)
        .accessibilityHint("Opens Integrations")
        .accessibilityIdentifier("sleep-manage-sources")
    }
}

/// The range picker over the shared range, Day shown as 30 days.
private struct SleepRange: View {
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        RangeFilters(days: Binding(get: { SleepPage.rangeDays(dashboard.rangeDays) }, set: { dashboard.rangeDays = $0 }))
    }
}

/// A page's line in place of what couldn't be shown (.page-message).
private struct SleepMessage: View {
    let text: String

    var body: some View {
        Text(text).font(.app(.footnote)).foregroundStyle(Palette.ink2).multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: 120)
            .accessibilityIdentifier("sleep-message")
    }
}

private struct SleepLoading: View {
    var body: some View { ProgressView().frame(maxWidth: .infinity, minHeight: 120) }
}

/// A read's place on the page while it isn't there yet: a spinner, or the web's words for a failure.
@ViewBuilder
private func pending<V>(_ read: SleepRead<V>) -> some View {
    switch read {
    case .failed(let message): SleepMessage(text: SleepWords.couldntLoad(message))
    case .missing: EmptyView()
    default: SleepLoading()
    }
}

/// The page's column of rows.
private struct SleepRows<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }
            .padding(.vertical, 16)
    }
}

// MARK: - Overview

private struct SleepOverviewTab: View {
    let model: SleepModel
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        let night = model.night.value
        let context = night.map { SleepNightContext(night: $0, status: dashboard.status) }
        SleepHeader(model: model, sub: night?.noNights == true ? SleepWords.subNone : SleepWords.sub, showsTabs: context?.bare != true) {
            if let night {
                DayNav(today: night.today, date: Binding(get: { dashboard.date }, set: { d in Task { await dashboard.show(date: d) } }),
                       label: { SleepWords.nightLabel($0, today: night.today) })
            }
        }
        if let context {
            SleepOverviewCards(model: model, context: context)
        } else {
            pending(model.night)
        }
    }
}

/// The night's cards. The web's one column: the three cards (3-up in the medium band), then stages beside insights and
/// the timeline beside resting heart rate, each pair stacked as on the web below 1080. On a page split on the fold,
/// every card shown goes two to a row, one each side: the three and resting heart rate, then stages beside insights,
/// then the timeline. A hidden card closes up the rows rather than leaving half of one empty.
private struct SleepOverviewCards: View {
    let model: SleepModel
    let context: SleepNightContext
    @Environment(Dashboard.self) private var dashboard
    @Environment(\.duoFold) private var fold

    var body: some View {
        let night = context.night
        let s = summary(night)
        if fold.splits {
            let ids = SleepOverviewCards.splitOrder.filter { shows($0) }
            if !ids.isEmpty {
                DuoGrid(ids, id: \.self) { id in card(id, summary: s) }
            }
        } else {
            let signals = ["sleep.total", "sleep.score", "sleep.efficiency"].filter(dashboard.cardShown)
            if !signals.isEmpty {
                DuoGrid(signals, id: \.self, medium: 3) { id in card(id, summary: s) }
            }
            if !context.bare {
                let stages = shows("sleep.stages"), insights = shows("sleep.insights")
                if stages || insights {
                    DuoPair {
                        if stages { card("sleep.stages", summary: s) }
                    } second: {
                        if insights { card("sleep.insights", summary: s) }
                    }
                }
                let timeline = shows("sleep.timeline"), rhr = shows("sleep.rhr")
                if timeline || rhr {
                    DuoPair {
                        if timeline { card("sleep.timeline", summary: s) }
                    } second: {
                        if rhr { card("sleep.rhr", summary: s) }
                    }
                }
            }
        }
        if allHidden { AllCardsHiddenNote(text: "All the cards on this page are hidden.") }
    }

    /// The cards on a split page, in the order they pair up.
    static let splitOrder = ["sleep.total", "sleep.score", "sleep.efficiency", "sleep.rhr", "sleep.stages", "sleep.insights", "sleep.timeline"]

    /// The three signals show on a bare night too; the rest only once there's a night to show.
    private func shows(_ id: String) -> Bool {
        guard dashboard.cardShown(id) else { return false }
        return ["sleep.total", "sleep.score", "sleep.efficiency"].contains(id) || !context.bare
    }

    @ViewBuilder private func card(_ id: String, summary s: Summary?) -> some View {
        let night = context.night
        switch id {
        case "sleep.stages": SleepStagesCard(night: night, open: open)
        case "sleep.insights": SleepInsightsCard(rows: insightRows(night), open: open)
        case "sleep.timeline": SleepTimelineCard(night: night)
        case "sleep.rhr": SleepRestingHrCard(summary: s, points: model.restingHr)
        default: SleepNightCard(id: id, context: context, summary: s, open: open)
        }
    }

    private func open(_ tab: SleepTab) { model.tab = tab }

    /// Today's summary, when it's for this night.
    private func summary(_ night: SleepNightDetail) -> Summary? {
        dashboard.summary.flatMap { $0.date == night.date ? $0 : nil }
    }

    private func insightRows(_ night: SleepNightDetail) -> [SleepInsightRow] {
        SleepInsightRow.rows(night: night, home: summary(night)?.insights ?? [], patterns: model.patterns.value?.patterns ?? [])
    }

    /// Every card on this page is hidden (known once the person's settings are in).
    private var allHidden: Bool {
        dashboard.status?.settings != nil && Cards.all.filter { $0.page == .sleep }.allSatisfy { !dashboard.cardShown($0.id) }
    }
}

// MARK: - Stages

private struct SleepStagesTab: View {
    let model: SleepModel

    var body: some View {
        // The range of the nights on screen (a new range's stay the last one's until they come).
        let days = model.stagesDays
        let nights = model.stagesTrends.value.map { SleepStageNights($0, days: days) }
        SleepHeader(model: model) { SleepRange() }
        if let nights {
            // The web's one column (grid-1); split on the fold, the nights beside the average night.
            let ids = nights.nights.isEmpty ? ["nights"] : ["nights", "average"]
            DuoGrid(ids, id: \.self, medium: 1) { id in
                if id == "nights" { SleepStagesChartCard(nights: nights, days: days) } else { SleepAverageNightCard(nights: nights) }
            }
        } else {
            pending(model.stagesTrends)
        }
    }
}

// MARK: - Trends

private struct SleepTrendsTab: View {
    let model: SleepModel

    var body: some View {
        SleepHeader(model: model) { SleepRange() }
        if let specs = model.trendsTrends.value.map(SleepTrendCards.specs) {
            // One column as the web's grid-2 is at this width and below; split on the fold, two to a row, one each side.
            DuoGrid(specs, id: \.id, medium: 1) { s in
                SleepTrendCard(title: s.title, points: s.points, format: s.format, tick: s.tick, unitNote: s.note, color: s.color)
            }
        } else {
            pending(model.trendsTrends)
        }
    }
}

// MARK: - Coaching

private struct SleepCoachingTab: View {
    let model: SleepModel

    var body: some View {
        SleepHeader(model: model)
        if let st = model.timing.value?.stats {
            if st.nights < 7 {
                SleepCoachingAlone { SleepCoachingWaits(nights: st.nights) }
            } else {
                SleepCoachingCards(stats: st, patterns: model.patterns.value)
            }
        } else if model.timing.value != nil {
            // Answered without its numbers: as the web, nothing to coach on yet.
            SleepCoachingAlone { SleepCoachingWaits(nights: 0) }
        } else {
            pending(model.timing)
        }
    }
}

/// A lone card: full width, or on a split page the leading side, never across the fold.
private struct SleepCoachingAlone<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        DuoGrid(["one"], id: \.self) { _ in content }
    }
}

/// Coaching's cards. The web's: your need and your debt (2-up in the medium band), usual times on its own, then what
/// goes with your better nights across the page. Split on the fold, two to a row, one each side: need beside debt, then
/// usual times beside the patterns. The patterns card is there as on the web whether or not /patterns has answered
/// (loading, failed, or an older server without it): no rows, "Nothing stands out yet" and the note.
private struct SleepCoachingCards: View {
    let stats: SleepTiming.Stats
    let patterns: Patterns?
    @Environment(\.duoFold) private var fold

    var body: some View {
        if fold.splits {
            DuoGrid(["need", "debt", "times", "patterns"], id: \.self) { card($0) }
        } else {
            DuoGrid(["need", "debt", "times"], id: \.self, medium: 2, loneSpans: false) { card($0) }
            SleepPatternsCard(patterns: patterns)
        }
    }

    @ViewBuilder private func card(_ id: String) -> some View {
        let st = stats
        switch id {
        case "need":
            SleepCoachCard(title: "Your sleep need", value: st.need.map(Fmt.hoursMinutes) ?? String.emptyValue, unit: "a night",
                           foot: st.need != nil ? SleepWords.needNote : SleepWords.needTwoWeeks)
        case "debt":
            SleepCoachCard(title: "Sleep debt, last 7 days", value: st.debt.map(Fmt.hoursMinutes) ?? String.emptyValue,
                           unit: st.debt != nil ? "over \(st.debtNights) night\(st.debtNights == 1 ? "" : "s")" : "short of your need",
                           foot: SleepWords.debtNote)
        case "patterns":
            SleepPatternsCard(patterns: patterns)
        default:
            SleepUsualTimesCard(stats: st)
        }
    }
}

extension SleepModel {
    /// The range the Stages tab's nights on screen were read for, in days (30 until they're read).
    var stagesDays: Int { stagesKey.flatMap { Int($0.prefix { $0 != "|" }) } ?? 30 }
}
