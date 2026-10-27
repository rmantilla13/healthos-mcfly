import Foundation

// Where everything in the app is: the web's pages (Page in shared/types.ts, titled as src/components/shell/nav.ts titles
// them) by the web's own route ids, so a link from the server (an insight's page, a flag's) opens the same page here.

/// A page of the app. The web's ids ('labs' is Blood records, 'mcfly' is Ask McFly, 'welcome' is the welcome steps again,
/// shown over the app rather than pushed), plus two only the iPhone has: Insights (the weekly digest, patterns, scatter
/// plots and the year heatmap) and one day by hour, opened from Home.
enum AppPage: String, CaseIterable, Hashable {
    case home, family, vitals, sleep, body, nutrition, journal, labs, cycle, mcfly, integrations, profile, admin, welcome
    case insights, day

    /// The header's title (PAGE_META in nav.ts).
    var title: String {
        switch self {
        case .home: "Home"
        case .family: "Family"
        case .vitals: "Vitals"
        case .sleep: "Sleep"
        case .body: "Body"
        case .nutrition: "Nutrition"
        case .journal: "Journal"
        case .labs: "Blood records"
        case .cycle: "Cycle"
        case .mcfly: "Ask McFly"
        case .integrations: "Integrations"
        case .profile: "Profile"
        case .admin: "Admin"
        case .welcome: "Welcome"
        case .insights: "Insights"
        case .day: "Day"
        }
    }

    /// The web's icon for it (src/components/Icon.tsx), as the nearest SF Symbol.
    var symbol: String {
        switch self {
        case .home: "house"
        case .family: "person.2"
        case .vitals: "waveform.path.ecg"
        case .sleep: "moon"
        // The web's standing figure stands for both: Body in the navigation, Profile in the account menu.
        case .body, .profile: "figure.stand"
        case .nutrition: "fork.knife"
        case .journal: "doc.text"
        // A report with a heart on it, so it isn't Cycle's drop or Journal's page of lines.
        case .labs: "heart.text.square"
        case .cycle: "drop"
        case .mcfly: "text.bubble"
        case .integrations: "link"
        case .admin: "person.2.badge.gearshape"
        case .welcome: "sparkles"
        case .insights: "lightbulb"
        case .day: "clock"
        }
    }

    /// The tab that shows it: Home, Vitals, Body and Nutrition have their own (TAB_PAGES in nav.ts), one day opens over
    /// Home, and everything else is under More.
    var tab: AppTab {
        switch self {
        case .home, .day: .home
        case .vitals: .vitals
        case .body: .body
        case .nutrition: .nutrition
        default: .more
        }
    }

    /// More's pages for this person, in the web's order (TabBar in MobileNav.tsx: the main navigation's pages the tab
    /// bar has no room for, then Ask McFly, Profile and Integrations), then Insights, which only the iPhone has. Family
    /// and Cycle only when the web's mainNav() lists them (Dashboard.morePages says when).
    static func more(family: Bool, cycle: Bool) -> [AppPage] {
        (family ? [.family] : []) + (cycle ? [.cycle] : []) + [.journal, .sleep, .labs, .mcfly, .profile, .integrations, .insights]
    }
}

/// The tab bar: the web's phone layout (TabBar in MobileNav.tsx), Home, Vitals, Body, Nutrition and More.
///
/// `settings` isn't a tab: asking for it opens Profile under More, as the web's #/settings opens Profile. The app's
/// "Open Profile", "Change server" and similar buttons ask for it.
enum AppTab: Hashable {
    case home, vitals, body, nutrition, more
    case settings

    /// The tabs in the bar, in order.
    static let bar: [AppTab] = [.home, .vitals, .body, .nutrition, .more]

    var title: String {
        switch self {
        case .home: AppPage.home.title
        case .vitals: AppPage.vitals.title
        case .body: AppPage.body.title
        case .nutrition: AppPage.nutrition.title
        case .more, .settings: "More"
        }
    }

    var symbol: String {
        switch self {
        case .home: AppPage.home.symbol
        case .vitals: AppPage.vitals.symbol
        case .body: AppPage.body.symbol
        case .nutrition: AppPage.nutrition.symbol
        case .more, .settings: "ellipsis"
        }
    }
}

/// A page and its query, as the web's links are: #/body?tab=metabolism, #/sleep?tab=stages, #/nutrition?compose=1,
/// #/journal?new=1, #/family?member=<id>, #/profile?connect=openai. Each page reads its own keys.
struct AppRoute: Hashable {
    let page: AppPage
    var query: [String: String]

    init(_ page: AppPage, query: [String: String] = [:]) {
        self.page = page
        self.query = query
    }

    static let home = AppRoute(.home)
    static let family = AppRoute(.family)
    static let vitals = AppRoute(.vitals)
    static let sleep = AppRoute(.sleep)
    static let body = AppRoute(.body)
    /// Activity is one of Body's tabs now (the web's #/activity still opens it).
    static let activity = AppRoute(.body, query: ["tab": "activity"])
    static let nutrition = AppRoute(.nutrition)
    static let journal = AppRoute(.journal)
    static let labs = AppRoute(.labs)
    static let cycle = AppRoute(.cycle)
    static let mcfly = AppRoute(.mcfly)
    static let integrations = AppRoute(.integrations)
    static let profile = AppRoute(.profile)
    static let admin = AppRoute(.admin)
    /// The welcome's steps again, to edit them (Profile's Edit preferences, Body's "Change my representation"):
    /// `open(.welcome)` shows them over the app.
    static let welcome = AppRoute(.welcome)
    static let insights = AppRoute(.insights)

    /// One day by hour; nil is today.
    static func day(_ date: String?) -> AppRoute { AppRoute(.day, query: date.map { ["date": $0] } ?? [:]) }
    /// One person's last 30 days on the Family board.
    static func familyMember(_ id: String) -> AppRoute { AppRoute(.family, query: ["member": id]) }

    var title: String { page.title }

    /// The web page an insight, pattern or flag names, by the web's id. Its old addresses still work: 'settings' is
    /// Profile and 'activity' is Body's Activity tab (App.tsx). nil for one this app has no page for.
    init?(page id: String, query: [String: String] = [:]) {
        switch id {
        case "settings": self.init(.profile, query: query)
        case "activity": self.init(.body, query: query.merging(["tab": "activity"]) { _, alias in alias })
        default:
            guard let page = AppPage(rawValue: id) else { return nil }
            self.init(page, query: query)
        }
    }

    /// The app's own links in its text, healthos://<page>?<query> (healthos://family, healthos://profile?connect=openai).
    /// They're only for the text's tappable words: no URL scheme is registered, so nothing outside the app opens them.
    init?(url: URL) {
        guard url.scheme == "healthos", let host = url.host() else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let query = Dictionary(items.compactMap { item in item.value.map { (item.name, $0) } }) { first, _ in first }
        self.init(page: host, query: query)
    }
}

/// A link to a page, for that page to apply its query. The tabs' own pages (Home, Vitals, Body, Nutrition) are already
/// on screen, so they watch for this; a page under More gets its query in the route it's pushed with, and watches for
/// this only for the same link opened again while it's still up (Profile's ?connect=). `id` changes every time, so the
/// same link opened twice works twice.
struct RouteRequest: Equatable {
    let route: AppRoute
    let id: Int
}

/// A page of the server's website shown in the app (SafariView): Privacy & data, and the web's Admin until it's
/// built here.
struct WebPage: Identifiable, Equatable {
    let url: URL
    var id: URL { url }
}
