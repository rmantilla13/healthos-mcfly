import Foundation

// Opening pages: every button, card, insight and text link that goes somewhere calls `dashboard.open(_:)` with a route
// (Shell/AppRoute.swift). The state it moves (the tab, each tab's pushed pages) lives on Dashboard.

extension Dashboard {
    /// Opens a page where the web's phone layout has it: a tab's own page on that tab, back at its top; one day over
    /// Home; anything else pushed under More (a Family member over the board, so Back goes to the board).
    func open(_ route: AppRoute) {
        // Not built here yet: the web dashboard's own page, in the app.
        if route.page == .admin, !AdminScreen.native {
            showWeb("#/admin")
            return
        }
        let tab = route.page.tab
        switch route.page {
        case .home, .vitals, .body, .nutrition:
            requestCount += 1
            requests[route.page] = RouteRequest(route: route, id: requestCount)
            paths[tab] = []
        case .family where route.query["member"] != nil:
            paths[tab] = [.family, route]
        default:
            paths[tab] = [route]
        }
        self.tab = tab
    }

    /// Opens one of the app's own healthos:// links (an OpenURLAction in a text's tappable words). False for any other
    /// link, for the system to open.
    @discardableResult
    func open(url: URL) -> Bool {
        guard let route = AppRoute(url: url) else { return false }
        open(route)
        return true
    }

    /// The last link to a tab's own page, for that page to apply its query (Body's tab=activity); nil until one comes.
    func request(for page: AppPage) -> RouteRequest? { requests[page] }

    /// A page of the server's website over the app (privacy.html, or "#/admin"). It has its own cookies, not the app's
    /// session, so a page that needs sign-in asks for it there.
    func showWeb(_ path: String) {
        guard let base = Config.serverURL(), let url = URL(string: path, relativeTo: base.appendingPathComponent("/"))?.absoluteURL else { return }
        webPage = WebPage(url: url)
    }

    /// Admins see Admin in the account menu (the web's isAdmin: only with sign-in on; the server checks either way).
    var isAdmin: Bool { signOutOffered && (status?.user?.role ?? account?.role) == "admin" }
    /// The account menu offers Sign out: sign-in is on and someone is signed in.
    var signOutOffered: Bool { authMode == "required" && phase == .ready }
    /// The pages under More for this person: Family on a server with the board, Cycle while tracking is on.
    var morePages: [AppPage] { AppPage.more(family: familyAvailable, cycle: cycleTrackingOn) }

    /// Signed out, the server unreachable, another server, or someone else signing in: every pushed page goes, so none
    /// stays open on what it showed (a Family member's page, a day). Profile stays, for the server address.
    func dropPages() {
        for (tab, path) in paths where path.contains(where: { $0.page != .profile }) {
            paths[tab] = path.filter { $0.page == .profile }
        }
    }

    /// After Sign out: Home, with nothing pushed on any tab.
    func resetNavigation() {
        paths = [:]
        requests = [:]
        webPage = nil
        tab = .home
    }

    /// Family or Cycle went away (another server, sharing or tracking turned off) while open under More: back to More.
    func dropMissingPages() {
        let gone: Set<AppPage> = Set([AppPage.family, .cycle]).subtracting(morePages)
        guard let path = paths[.more], path.contains(where: { gone.contains($0.page) }) else { return }
        paths[.more] = Array(path.prefix { !gone.contains($0.page) })
    }
}
