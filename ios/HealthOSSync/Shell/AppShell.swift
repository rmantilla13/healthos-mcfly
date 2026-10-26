import SwiftUI

/// The app's frame, the web's phone layout (src/components/shell/MobileNav.tsx): the tab bar (Home, Vitals, Body,
/// Nutrition, More), each tab with its own pages pushed over it, your avatar and its account menu at the top right of
/// every page, Ask McFly's pill over Home, and the server's web pages shown in the app.
struct AppShell: View {
    @Environment(Dashboard.self) private var dashboard
    @State private var chatOpen = false

    var body: some View {
        @Bindable var dashboard = dashboard
        TabView(selection: $dashboard.tab) {
            ForEach(AppTab.bar, id: \.self) { tab in
                TabRoot(tab: tab, chatOpen: $chatOpen)
                    .tabItem { Label(tab.title, systemImage: tab.symbol) }
                    .tag(tab)
            }
        }
        .sheet(isPresented: $chatOpen) {
            McFlySheet(chat: dashboard.mcfly).font(.app(.body))
        }
        .sheet(item: $dashboard.webPage) { SafariView(url: $0.url).ignoresSafeArea() }
        // Whether the server has McFly on, and how many questions are left: after every load, while signed in.
        .task(id: "\(dashboard.generation)|\(dashboard.phase == .ready)") {
            guard dashboard.phase == .ready else { return }
            await dashboard.mcfly.refreshStatus()
        }
        // Family or Cycle went away (another server, sharing or tracking off) while open under More.
        .onChange(of: dashboard.morePages) { _, _ in dashboard.dropMissingPages() }
    }
}

/// One tab: its page at the bottom of its own navigation, and the pages pushed over it.
private struct TabRoot: View {
    let tab: AppTab
    @Binding var chatOpen: Bool
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        NavigationStack(path: path) {
            root.navigationDestination(for: AppRoute.self) { ShellPage(route: $0) }
        }
    }

    private var path: Binding<[AppRoute]> {
        Binding(get: { dashboard.paths[tab] ?? [] }, set: { dashboard.paths[tab] = $0 })
    }

    @ViewBuilder
    private var root: some View {
        switch tab {
        case .home:
            // In the safe area, so it floats above the tab bar instead of under it, with room to breathe; the inset
            // also pads Home's scrolling, so the last card scrolls clear of it. On Home only, not on a day pushed over it.
            ShellPage(route: .home).safeAreaInset(edge: .bottom) {
                if dashboard.phase == .ready, dashboard.summary != nil, dashboard.mcfly.status?.available == true {
                    AskMcFlyPill { chatOpen = true }.padding(.top, 8).padding(.bottom, 18)
                }
            }
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
        case .insights: InsightsScreen()
        case .day: DayScreen(date: route.query["date"])
        }
    }
}
