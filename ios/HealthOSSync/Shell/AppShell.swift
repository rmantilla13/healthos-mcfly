import SwiftUI

/// The app's frame, the web's phone layout (src/components/shell/MobileNav.tsx): the tab bar (Home, Vitals, Body,
/// Nutrition, More), each tab with its own pages pushed over it, your avatar and its account menu at the top right of
/// every page, Ask McFly over Home, and what shows over everything: the welcome, a metric's detail sheet, the account
/// menu and the server's web pages.
struct AppShell: View {
    @Environment(Dashboard.self) private var dashboard
    /// The account menu's choice, done once the menu has gone.
    @State private var chosen: AccountMenuItem?

    var body: some View {
        @Bindable var dashboard = dashboard
        TabView(selection: $dashboard.tab) {
            ForEach(AppTab.bar, id: \.self) { tab in
                TabRoot(tab: tab)
                    .tabItem { Label(tab.title, systemImage: tab.symbol) }
                    .tag(tab)
            }
        }
        .sheet(item: $dashboard.metricSheet) { MetricSheetView(request: $0) }
        .sheet(item: $dashboard.webPage) { SafariView(url: $0.url).ignoresSafeArea() }
        .sheet(isPresented: $dashboard.accountMenuOpen, onDismiss: {
            chosen?.run(dashboard)
            chosen = nil
        }) {
            AccountMenuSheet { item in
                chosen = item
                dashboard.accountMenuOpen = false
            }
        }
        // Whether the server has McFly on and how many questions are left, and what this person's AI requests use
        // (Availability): after every load, while signed in.
        .task(id: "\(dashboard.generation)|\(dashboard.phase == .ready)") {
            guard dashboard.phase == .ready else { return }
            await dashboard.mcfly.refreshStatus()
            await dashboard.loadAI(force: true)
        }
        // Family or Cycle went away (another server, tracking off) while open under More.
        .onChange(of: dashboard.featurePages) { _, _ in dashboard.dropMissingPages() }
        // The welcome, over everything (the web shows it instead of the dashboard): a new account's until it's done,
        // with no swipe away, or its steps again from Profile. It goes with a sign-out or a 401.
        .fullScreenCover(item: welcome) { mode in
            OnboardingView(mode: mode).interactiveDismissDisabled()
        }
    }

    private var welcome: Binding<OnboardingMode?> {
        Binding(get: { dashboard.onboarding }, set: { if $0 == nil { dashboard.welcomeEditing = false } })
    }
}

/// One tab: its page at the bottom of its own navigation, and the pages pushed over it.
private struct TabRoot: View {
    let tab: AppTab
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        NavigationStack(path: path) {
            root.navigationDestination(for: AppRoute.self) { ShellPage(route: $0) }
        }
        // A new stack whenever this tab's pages are taken away other than by Back (Sign out, a session that ends, Family
        // or Cycle going): one emptied while its tab was hidden (More, with the sign-in screen on Home) kept a page it no
        // longer had, and the next push ("Change server") showed it blank.
        .id(dashboard.navigationResets[tab, default: 0])
    }

    private var path: Binding<[AppRoute]> {
        Binding(get: { dashboard.paths[tab] ?? [] }, set: { dashboard.paths[tab] = $0 })
    }

    @ViewBuilder
    private var root: some View {
        switch tab {
        case .home:
            // Ask McFly (slice E's, in McFly.swift), mounted in every phase: it decides whether it shows and what it opens.
            // In the safe area, so it floats above the tab bar instead of under it, with room to breathe; the inset
            // also pads Home's scrolling, so the last card scrolls clear of it. On Home only, not on a day pushed over it.
            ShellPage(route: .home).safeAreaInset(edge: .bottom) { AskMcFlyEntry() }
        case .vitals: ShellPage(route: .vitals)
        case .body: ShellPage(route: .body)
        case .nutrition: ShellPage(route: .nutrition)
        case .more, .settings:
            MoreScreen()
                .navigationTitle("More")
                .navigationBarTitleDisplayMode(.inline)
                .accountMenu()
        }
    }
}

/// A page with the shell's chrome: its title in the bar (the web's phone top bar) and the account menu.
struct ShellPage: View {
    let route: AppRoute

    var body: some View {
        switch route.page {
        // Home hides the bar: its header greets you and has the avatar.
        case .home: TodayScreen()
        // These title themselves: the day's date, the person's name.
        case .day: DayScreen(date: route.query["date"]).accountMenu()
        case .family where route.query["member"] != nil: FamilyPersonScreen(id: route.query["member"] ?? "").accountMenu()
        default: page.navigationTitle(route.title).navigationBarTitleDisplayMode(.inline).accountMenu()
        }
    }

    /// The web's page switch (App.tsx), each page in its own file.
    @ViewBuilder
    private var page: some View {
        switch route.page {
        case .home: TodayScreen()
        case .family: FamilyScreen()
        case .vitals: VitalsScreen()
        case .sleep: SleepScreen(tab: route.query["tab"])
        case .body: BodyScreen()
        case .nutrition: NutritionScreen()
        case .journal: JournalScreen(new: route.query["new"] == "1")
        case .labs: LabsScreen(tab: route.query["tab"])
        case .cycle: CycleScreen()
        case .mcfly: McFlyPage()
        case .integrations: IntegrationsScreen(query: route.query)
        case .profile: ProfileScreen(query: route.query)
        case .admin: AdminScreen()
        // Never pushed: open(.welcome) shows it over the app.
        case .welcome: OnboardingView(mode: .edit)
        case .insights: InsightsScreen()
        case .day: DayScreen(date: route.query["date"])
        }
    }
}
