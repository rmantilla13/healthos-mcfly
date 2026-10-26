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
                    TodayContent(summary: summary)
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
}

/// What Home shows of one summary, in Home.tsx's order. Every card can be hidden in Edit widgets (or Profile → Cards),
/// and the optional ones are off until turned on; hidden cards leave no gap. Two parts only the iPhone has stay: the day
/// by hour (it opens the Day view) and, while cycle tracking is on, the cycle's phase. Live heart rate opens from the
/// heart's callout.
private struct TodayContent: View {
    let summary: Summary
    @Environment(Dashboard.self) private var dashboard
    @Environment(AppModel.self) private var sync
    /// The day by hour (GET /api/day) and the cycle (GET /api/cycle): nil hides their cards.
    @State private var day: DayData?
    @State private var cycle: CycleData?
    /// The timeline's marker, shared with the figure: while it's moved, the figure's heart shows that hour.
    @State private var scrub = TodayScrub()
    @State private var editing = false

    /// Under a resting heart rate flag, in the luteal or menstrual phase. The summary never mentions the cycle.
    private static let cycleNote = "Temperature and resting heart rate often run a little higher in this part of your cycle."

    var body: some View {
        let isToday = summary.date == summary.today
        // The phase is about today, so it says nothing about a past day on screen.
        let phase = isToday && dashboard.cycleTrackingOn ? cycle?.phase : nil
        let off = dashboard.cardsOff
        let stats = HomePerspective.of(dashboard.status?.settings) == .stats
        // Food totals only for people with Nutrition on.
        let optionalRow = HomeCards.optionalRow.filter { $0 != "home.food" || dashboard.nutritionOn }
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HomeHeader(summary: summary, editing: $editing).padding(.bottom, 18)
                banners(phase: phase)
                VStack(alignment: .leading, spacing: 18) {
                    if !stats {
                        VStack(alignment: .leading, spacing: 14) {
                            HomeFigure(summary: summary, scrub: summary.timeline?.date == summary.date ? scrub.heart(on: summary.date) : nil)
                            HomeTagline()
                        }
                    }
                    VStack(spacing: 14) {
                        TodayGrid(summary: summary, ids: Cards.visible(HomeCards.signals, hidden: off), goal: dashboard.stepGoal)
                        if !off.contains("home.nutrition") { TodayNutritionCard(date: summary.date, today: summary.today) }
                        if !off.contains("home.journal") { JournalPromptCard() }
                        // Only the iPhone has these: the day by hour, which opens the Day view, and the cycle's phase.
                        if let day, !day.metrics.isEmpty { DayCard(data: day, date: isToday ? nil : summary.date) }
                        if let cycle, let phase { CycleCard(cycle: cycle, phase: phase) }
                        TodayGrid(summary: summary, ids: Cards.visible(optionalRow, hidden: off), goal: dashboard.stepGoal)
                        if let timeline = summary.timeline, !off.contains("home.timeline") { TodayPath(timeline: timeline, scrubbed: scrub) }
                        if !off.contains("home.week") { WeekCard(week: summary.week, stepGoal: dashboard.stepGoal) }
                        if !off.contains("home.insights") { InsightsCard(insights: summary.insights ?? [], today: summary.today) }
                        if Cards.allHidden(in: .home, hidden: off) { AllCardsHiddenNote(text: "All the cards on this page are hidden.") }
                        if stats { HomeTagline(compact: true) }
                    }
                }
                HomeFooter()
            }
            .padding(16)
            .opacity(dashboard.loading ? 0.6 : 1)
            .animation(.easeInOut(duration: 0.2), value: dashboard.loading)
        }
        .refreshable { await sync.syncAll(force: true) }
        // Ask McFly's pill floats over this, from the shell (Shell/AppShell.swift).
        .sheet(isPresented: $editing) { EditWidgetsSheet { dashboard.open(.profile) } }
        // Newer endpoints: a server without them, or a failed fetch, just hides the card.
        .task(id: "\(summary.date)|\(dashboard.generation)") {
            day = try? await dashboard.day(date: summary.date == summary.today ? nil : summary.date)
        }
        .task(id: "\(dashboard.generation)|\(dashboard.cycleTrackingOn)") {
            cycle = try? await dashboard.cycle()
        }
    }

    /// The lines above the page: a load that failed, nothing connected yet, the one-time family note, and the
    /// summary's heads-ups (only the iPhone shows these).
    @ViewBuilder
    private func banners(phase: CyclePhase?) -> some View {
        let noSources = NoSourcesBanner.shows(dashboard.status)
        let any = dashboard.error != nil || noSources || dashboard.showsFamilyNotice || !summary.flags.isEmpty
        if any {
            VStack(spacing: 10) {
                if let error = dashboard.error {
                    HomeBanner(icon: "wifi.exclamationmark", iconColor: Palette.bannerBadInk, background: Palette.bannerBadBg, ink: Palette.bannerBadInk,
                               weight: .regular, text: Text(error)) { EmptyView() }
                }
                if noSources { NoSourcesBanner() }
                if dashboard.showsFamilyNotice { FamilyNotice() }
                ForEach(summary.flags) { flag in
                    FlagBanner(flag: flag, note: flag.id.hasPrefix("rhr") && phase?.luteal == true ? Self.cycleNote : nil)
                }
            }
            .padding(.bottom, 16)
        }
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
