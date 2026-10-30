import SwiftUI

/// The Home page, the web's (src/pages/Home.tsx under the shell's ShellHeader, as its phone layout shows it): the
/// greeting and top bar, the banners above the page, your figure and its tagline, then the cards one to a row. Its
/// header greets you and has your avatar, so the navigation bar is hidden here.
struct TodayScreen: View {
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        // No server, sign-in and a server whose sign-in isn't set up are the shell's (PhaseGate); the rest is Home's.
        PhaseGate {
            switch dashboard.phase {
            case .unavailable(let message):
                Unavailable("Can't load your dashboard", systemImage: "wifi.exclamationmark", description: message) {
                    Button("Try again") { Task { await dashboard.start() } }
                }
            case .ready:
                if let summary = dashboard.summary {
                    // One person's, on one server, as Nutrition's page: after Change server or someone else's sign-in, the
                    // day by hour, the cycle, the food totals and the journal's check-in start again from nothing.
                    TodayContent(summary: summary).id(Self.identity(of: dashboard))
                } else {
                    ProgressView()
                }
            default:
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.page)
        .toolbar(.hidden, for: .navigationBar)
        .task { await dashboard.startIfNeeded() }
        .onReceive(NotificationCenter.default.publisher(for: .healthOSSynced)) { _ in
            Task { await dashboard.refreshIfChanged(includeStatus: false) }
        }
    }

    /// Whose Home this is: the server and the person, as Nutrition's page (`NutritionScreen.identity`).
    static func identity(of dashboard: Dashboard) -> String {
        NutritionScreen.identity(server: Config.serverURL(), user: dashboard.status?.user?.id ?? dashboard.account?.id)
    }
}

/// What Home shows of one summary, in Home.tsx's order. Every card can be hidden in Edit widgets (or Profile → Cards),
/// and the optional ones are off until turned on; hidden cards leave no gap. Two parts only the iPhone has stay: the day
/// by hour (it opens the Day view) and, while cycle tracking is on, the cycle's phase. Live heart rate opens from the
/// heart's callout, or with "Just the statistics" (no figure, so no heart) from its own button where the figure would be.
///
/// On the iPhone Duo (duo/design.md §7, decisions.md Q5) it's one page block (DuoPage) holding either one scrolling
/// column, as on every iPhone, or, on the open Duo in landscape, two panes: the greeting and the figure on the leading
/// side of the fold, staying put, and every card in two columns that scroll on the trailing side. Each part is a row with
/// its own id, the same in the column and the cards pane, so a fold that swaps them keeps the row at the top. What has to
/// outlast that swap (the reads, Edit widgets, live heart rate, the timeline's marker) is kept here, above it (P4).
struct TodayContent: View {
    let summary: Summary
    @Environment(Dashboard.self) private var dashboard
    @Environment(AppModel.self) private var sync
    @Environment(\.homeReads) private var reads
    @Environment(\.colorScheme) private var scheme
    /// The day by hour (GET /api/day) and the cycle (GET /api/cycle): nil hides their cards.
    @State private var day: DayData?
    @State private var cycle: CycleData?
    /// The food totals card's 7 days (nil: not placed) and the journal card's check-in, read here rather than by the
    /// cards (HomeReads says why).
    @State private var food: NutritionData?
    @State private var journal = HomeJournalRead.reading
    /// The timeline's marker, shared with the figure: while it's moved, the figure's heart shows that hour.
    @State private var scrub = TodayScrub()
    @State private var editing = false
    /// Live heart rate's sheet and a portrait whose cut-out couldn't be loaded, or was read.
    @State private var figure = HomeFigureState()
    /// Today's nutrition's entries for the day, read here for the card.
    @State private var nutrition: [FoodEntry] = []
    /// The timeline card's hourly readings, read here for the card (TodayPath).
    @State private var dayLoad = DayLoad()

    /// Under a resting heart rate flag, in the luteal or menstrual phase. The summary never mentions the cycle.
    private static let cycleNote = "Temperature and resting heart rate often run a little higher in this part of your cycle."

    var body: some View {
        let shown = shown
        DuoPage { _ in
            DuoPanes(anchor: .secondary) {
                HomeLead(summary: summary, editing: $editing, stats: shown.stats, scrub: heart, figure: figure)
                    .modifier(HomeLoading(loading: dashboard.loading))
            } secondary: {
                rows(HomeRows.cards(shown))
            } single: {
                rows(HomeRows.single(shown))
            }
        }
        .refreshable { await sync.syncAll(force: true) }
        // Ask McFly's pill floats over this, from the shell (Shell/AppShell.swift).
        .sheet(isPresented: $editing) { EditWidgetsSheet { dashboard.open(.profile) } }
        .sheet(isPresented: $figure.liveOpen) { LiveHeartRateView() }
        // Newer endpoints: a server without them, or a failed fetch, just hides the card.
        .task(id: "\(summary.date)|\(dashboard.generation)") {
            day = try? await dashboard.day(date: summary.date == summary.today ? nil : summary.date)
        }
        .task(id: "\(dashboard.generation)|\(dashboard.cycleTrackingOn)") {
            cycle = try? await dashboard.cycle()
        }
        // On the page, which is always there: each read runs again after every load, and when its card is turned on,
        // even while the card itself isn't drawn, and not again when a fold swaps the column for the panes.
        .task(id: "\(dashboard.generation)|\(foodWanted)|\(dashboard.nutritionMode?.rawValue ?? "off")") {
            let read = await reads.food(wanted: foodWanted, dashboard: dashboard)
            if !Task.isCancelled { food = read }
        }
        .task(id: "\(dashboard.generation)|\(journalWanted)") {
            let read = await reads.journal(wanted: journalWanted, current: journal, dashboard: dashboard)
            if !Task.isCancelled { journal = read }
        }
        .task(id: "\(dashboard.generation)|\(scheme == .dark)") {
            await figure.retryCutout(dashboard.status?.photo, dark: scheme == .dark, reads: reads)
        }
        // The timeline's own day, which can be earlier than the summary's, only while its card shows.
        .task(id: "\(summary.timeline?.date ?? "")|\(dashboard.generation)|\(shown.timeline)") {
            guard shown.timeline, let date = summary.timeline?.date else { return }
            await TodayPath.fetch(date, today: dashboard.summary?.today ?? Day.today(), dashboard: dashboard, into: $dayLoad)
        }
        // Only while its card shows.
        .task(id: "\(TodayNutritionCard.readKey(date: summary.date, today: summary.today, dashboard: dashboard))|\(lower.contains("home.nutrition"))") {
            guard lower.contains("home.nutrition") else { return }
            if let read = await TodayNutritionCard.entries(date: summary.date, today: summary.today, dashboard: dashboard), !Task.isCancelled {
                nutrition = read
            }
        }
    }

    /// Food totals are asked for only while they'd show: Nutrition on and Food ticked in Edit widgets.
    private var foodWanted: Bool { dashboard.nutritionOn && !dashboard.cardsOff.contains("home.food") }
    private var journalWanted: Bool { !dashboard.cardsOff.contains("home.journal") }

    private var isToday: Bool { summary.date == summary.today }
    /// The phase is about today, so it says nothing about a past day on screen.
    private var phase: CyclePhase? { isToday && dashboard.cycleTrackingOn ? cycle?.phase : nil }
    private var stats: Bool { Perspective.of(dashboard.status?.settings) == .stats }
    /// The figure's heart while the timeline's marker is moved on this same day.
    private var heart: HeartScrub? { summary.timeline?.date == summary.date ? scrub.heart(on: summary.date) : nil }

    private var signals: [String] { Cards.visible(HomeCards.signals, hidden: dashboard.cardsOff) }
    /// Today's nutrition and Your health journal (`home-lower`), each where it shows.
    private var lower: [String] {
        let off = dashboard.cardsOff
        return HomeCards.lower.filter { $0 == "home.nutrition" ? !off.contains($0) : !off.contains($0) && journal.shows }
    }
    /// Food totals only for people with Nutrition on, and once its days have come.
    private var optional: [String] {
        Cards.visible(HomeCards.optionalRow.filter { $0 != "home.food" || (dashboard.nutritionOn && food != nil) }, hidden: dashboard.cardsOff)
    }

    /// Which of Home's parts show.
    private var shown: HomeRows.Shown {
        let off = dashboard.cardsOff
        return HomeRows.Shown(
            banners: dashboard.error != nil || NoSourcesBanner.shows(dashboard.status) || dashboard.showsFamilyNotice || !summary.flags.isEmpty,
            stats: stats, signals: !signals.isEmpty, lower: !lower.isEmpty,
            day: day.map { !$0.metrics.isEmpty && ($0.steps != nil || $0.activeEnergy != nil || $0.heartRate != nil) } ?? false,
            cycle: cycle != nil && phase != nil, optional: !optional.isEmpty,
            timeline: summary.timeline != nil && !off.contains("home.timeline"), week: !off.contains("home.week"),
            insights: !off.contains("home.insights"), allHidden: Cards.allHidden(in: .home, hidden: off))
    }

    /// A scrolling stack of rows, each a direct child with its id (the scroll position's), and the space above it.
    private func rows(_ rows: [HomeRows.Row]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows, id: \.id) { row in
                self.row(row.id).padding(.top, row.top)
            }
        }
        .scrollTargetLayout()
        .padding(.vertical, 16)
        .modifier(HomeLoading(loading: dashboard.loading))
    }

    @ViewBuilder
    private func row(_ id: String) -> some View {
        switch id {
        case HomeRows.header: HomeHeader(summary: summary, editing: $editing)
        case HomeRows.banners: banners
        case HomeRows.figure: HomeFigure(summary: summary, scrub: heart, state: figure)
        case HomeRows.tagline: HomeTagline()
        case HomeRows.live: LiveHeartRateButton(state: figure)
        case HomeRows.signals: TodayGrid(summary: summary, ids: signals, goal: dashboard.stepGoal)
        case HomeRows.lower:
            // Stacked everywhere: on every iPhone and the Duo's inner display upright as the web below 1080, and in the
            // open Duo's cards pane, whose columns are too narrow for the day's track and the journal's art.
            DuoGrid(lower, id: \.self, medium: 1, paneColumns: 1) { id in
                if id == "home.nutrition" {
                    TodayNutritionCard(date: summary.date, today: summary.today, read: nutrition)
                } else {
                    JournalPromptCard(latest: journal.latest, standing: summary.standing)
                }
            }
        // Only the iPhone has these: the day by hour, which opens the Day view, and the cycle's phase.
        case HomeRows.day: if let day { DayCard(data: day, date: isToday ? nil : summary.date) }
        case HomeRows.cycle: if let cycle, let phase { CycleCard(cycle: cycle, phase: phase) }
        case HomeRows.optional: TodayGrid(summary: summary, ids: optional, goal: dashboard.stepGoal, food: food)
        case HomeRows.timeline: if let timeline = summary.timeline { TodayPath(timeline: timeline, scrubbed: scrub, load: dayLoad) }
        case HomeRows.week: WeekCard(week: summary.week, stepGoal: dashboard.stepGoal)
        case HomeRows.insights: HomeInsightsCard(insights: summary.insights ?? [], today: summary.today)
        case HomeRows.allHidden: AllCardsHiddenNote(text: "All the cards on this page are hidden.")
        // Centred in the column, as it was among the cards, where it's narrower than they are (its words over its link).
        case HomeRows.statsTagline: HomeTagline(compact: true).frame(maxWidth: .infinity)
        case HomeRows.footer: HomeFooter()
        default: EmptyView()
        }
    }

    /// The lines above the page: a load that failed, nothing connected yet, the one-time family note, and the
    /// summary's heads-ups (only the iPhone shows these).
    private var banners: some View {
        VStack(spacing: 10) {
            if let error = dashboard.error {
                HomeBanner(icon: "wifi.exclamationmark", iconColor: Palette.bannerBadInk, background: Palette.bannerBadBg, ink: Palette.bannerBadInk,
                           weight: .regular, text: Text(error)) { EmptyView() }
            }
            if NoSourcesBanner.shows(dashboard.status) { NoSourcesBanner() }
            if dashboard.showsFamilyNotice { FamilyNotice() }
            ForEach(summary.flags) { flag in
                FlagBanner(flag: flag, note: flag.id.hasPrefix("rhr") && phase?.luteal == true ? Self.cycleNote : nil)
            }
        }
    }
}

/// Home dimmed a little while it loads.
private struct HomeLoading: ViewModifier {
    let loading: Bool

    func body(content: Content) -> some View {
        content
            .opacity(loading ? 0.6 : 1)
            .animation(.easeInOut(duration: 0.2), value: loading)
    }
}

/// A gentle heads-up from the summary (resting heart rate up, maybe with a raised temperature), in the banner's look.
/// Opens its page, Vitals unless it names another.
private struct FlagBanner: View {
    let flag: Flag
    /// Cycle context the app adds itself.
    let note: String?
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        let tone: Tone = flag.caution ? .peach : .blue
        let route = flag.page.flatMap { AppRoute(page: $0) } ?? .vitals
        Button { dashboard.open(route) } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: flag.caution ? "heart.text.square" : "waveform.path.ecg").font(.system(size: 15, weight: .medium))
                    .foregroundStyle(tone.ink)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(flag.title).font(.app(size: 14, weight: .medium, relativeTo: .subheadline)).foregroundStyle(Palette.ink)
                    Text(flag.text).font(.app(.footnote)).foregroundStyle(Palette.ink2)
                    if let note { Text(note).font(.app(.footnote)).foregroundStyle(Palette.ink3).padding(.top, 3) }
                }
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink3)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(CardPressStyle())
        .accessibilityHint("Opens \(route.title)")
    }
}

/// The week so far, as a widget (Home.tsx WeekCard): the sentences that used to sit under the figure, each figure
/// against the same days last week. A server without it says what Home compares.
struct WeekCard: View {
    let week: WeekSummary?
    let stepGoal: Double

    /// The sentences with their figures in ink and a little heavier (.week-summary b), the rest in ink-2.
    static func text(_ week: WeekSummary, stepGoal: Double) -> AttributedString {
        var s = WeekText.body(week, stepGoal: stepGoal)
        for run in s.runs where run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true {
            s[run.range].inlinePresentationIntent = nil
            s[run.range].font = .app(.subheadline, weight: .semibold)
            s[run.range].foregroundColor = Palette.ink
        }
        return s
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let week {
                Text(WeekText.title(week)).font(.app(.caption, weight: .semibold)).tracking(0.6).textCase(.uppercase).foregroundStyle(Palette.ink3)
                Text(Self.text(week, stepGoal: stepGoal)).font(.app(.subheadline)).lineSpacing(5).foregroundStyle(Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Vitals from your latest night, compared with your own last 30 days.").font(.app(.subheadline)).foregroundStyle(Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .card()
        .accessibilityIdentifier("card-home.week")
    }
}

extension ISO8601DateFormatter {
    /// Accepts timestamps with or without fractional seconds.
    static let flexible: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    func flexibleDate(_ s: String) -> Date? {
        date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}
