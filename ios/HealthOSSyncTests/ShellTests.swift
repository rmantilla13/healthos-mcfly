import XCTest
@testable import HealthOSSync

/// The shell (Shell/): the tab bar and More as on the web's phone layout, where each link opens, the `.settings` alias,
/// the account menu's items, and what goes with a sign-out.
@MainActor
final class ShellTests: XCTestCase {
    private func status(_ settings: String, user: String = "null") throws -> ServerStatus {
        try JSONDecoder().decode(ServerStatus.self, from: Data(#"{"hosted":false,"settings":\#(settings),"user":\#(user)}"#.utf8))
    }

    /// A file of the web app, next to the iPhone app in the repository.
    private func web(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(path)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { throw XCTSkip("\(path) isn't next to the app") }
        return text
    }

    private func matches(_ pattern: String, in text: String) throws -> [[String]] {
        let regex = try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            (1..<m.numberOfRanges).map { ns.substring(with: m.range(at: $0)) }
        }
    }

    // MARK: Tabs and More

    /// The web's rule (App.tsx): `family = signedIn && familySharing`, and Cycle while tracking is on.
    func testMoreListsFamilyAndCycleOnlyWhenThePersonHasThem() throws {
        let rest: [AppPage] = [.journal, .sleep, .labs, .mcfly, .profile, .integrations, .insights]
        let d = Dashboard()
        d.authMode = "required"
        d.phase = .ready
        XCTAssertEqual(d.morePages, rest, "before any status: no Family, no Cycle")
        // A server older than the Family board doesn't name the setting.
        d.apply(status: try status(#"{"cycleTracking":false}"#))
        XCTAssertEqual(d.morePages, rest)
        d.apply(status: try status(#"{"familySharing":true,"cycleTracking":true}"#))
        XCTAssertEqual(d.morePages, [.family, .cycle] + rest)
        // Sharing off: the web leaves Family out of its navigation (its page still opens from a link, and says so).
        d.apply(status: try status(#"{"familySharing":false,"cycleTracking":true}"#))
        XCTAssertEqual(d.morePages, [.cycle] + rest)
        d.apply(status: try status(#"{"familySharing":true,"cycleTracking":false}"#))
        XCTAssertEqual(d.morePages.prefix(2), [.family, .journal])

        // A server whose status doesn't name the setting, but whose board was read: listed while you share.
        d.apply(status: try status(#"{"cycleTracking":false}"#))
        d.receiveFamily(try JSONDecoder().decode(FamilyBoard.self, from: Data(#"{"sharing":true,"today":"2026-10-17","members":[]}"#.utf8)))
        XCTAssertEqual(d.morePages.first, .family)
    }

    /// No sign-in (a local server): the board needs accounts, so More doesn't offer it, as on the web.
    func testAServerWithoutSignInListsNoFamily() throws {
        let d = Dashboard()
        d.authMode = "open"
        d.phase = .ready
        d.apply(status: try status(#"{"familySharing":true,"cycleTracking":true}"#))
        XCTAssertEqual(d.morePages.prefix(2), [.cycle, .journal])
    }

    /// Signed out: nothing in More says what the last person had on (Cycle tracking, Family), even from a status
    /// cached on the phone before the server answered.
    func testSignedOutMoreNamesNoneOfTheLastPersonsPages() throws {
        let d = Dashboard()
        d.authMode = "required"
        d.apply(status: try status(#"{"familySharing":true,"cycleTracking":true}"#))
        XCTAssertEqual(d.morePages.prefix(1), [.journal], "starting, from a cached status: not yet")
        d.phase = .ready
        XCTAssertEqual(d.morePages.prefix(2), [.family, .cycle])
        d.phase = .signIn
        XCTAssertNil(d.status, "what was loaded for them goes")
        XCTAssertEqual(d.morePages.prefix(1), [.journal])
    }

    /// The tab bar and More are the web's phone layout: TAB_PAGES as tabs, then More holds mainNav()'s other pages in
    /// its order, then MORE_EXTRA (MobileNav.tsx). Insights, which only the iPhone has, comes last.
    func testTabsAndMoreFollowTheWebsNavigation() throws {
        let nav = try web("src/components/shell/nav.ts")
        let mobile = try web("src/components/shell/MobileNav.tsx")
        let navBlock = try XCTUnwrap(nav.range(of: "const NAV: NavItem[] = [").map { String(nav[$0.upperBound...].prefix { $0 != ";" }) })
        let navPages = try matches(#"\{ page: '(\w+)'"#, in: navBlock).map { $0[0] }
        let tabPages = try XCTUnwrap(try matches(#"^export const TAB_PAGES: Page\[\] = \[(.+)\];"#, in: nav).first?[0])
            .components(separatedBy: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " '")) }
        let extraBlock = try XCTUnwrap(mobile.range(of: "const MORE_EXTRA: NavItem[] = [").map { String(mobile[$0.upperBound...].prefix { $0 != ";" }) })
        let extras = try matches(#"\{ page: '(\w+)'"#, in: extraBlock).map { $0[0] }
        XCTAssertEqual(tabPages, ["home", "vitals", "body", "nutrition"])
        XCTAssertEqual(AppTab.bar.dropLast().map { $0.title }, tabPages.map { AppPage(rawValue: $0)!.title })
        XCTAssertEqual(AppTab.bar.last, .more)

        // mainNav(): Family after Home, Cycle after Body.
        let main = navPages.flatMap { $0 == "home" ? [$0, "family"] : $0 == "body" ? [$0, "cycle"] : [$0] }
        let more = main.filter { !tabPages.contains($0) } + extras
        XCTAssertEqual(AppPage.more(family: true, cycle: true).map(\.rawValue), more + ["insights"])
        for page in AppPage.allCases where page != .insights && page != .day && page != .welcome {
            XCTAssertNotEqual(page.tab, .settings)
            XCTAssertEqual(page.tab == .more, more.contains(page.rawValue) || page == .admin, "\(page) is on its own tab or under More")
        }
    }

    /// Each page's title is the web's (PAGE_META in nav.ts).
    func testTitlesAreTheWebs() throws {
        let nav = try web("src/components/shell/nav.ts")
        let meta = Dictionary(try matches(#"^  (\w+): \{ title: '([^']+)' \},"#, in: nav).map { ($0[0], $0[1]) }) { a, _ in a }
        XCTAssertFalse(meta.isEmpty)
        for page in AppPage.allCases where page != .insights && page != .day {
            XCTAssertEqual(page.title, meta[page.rawValue], page.rawValue)
        }
        XCTAssertEqual(meta["settings"], AppPage.profile.title)
        XCTAssertEqual(meta["activity"], AppPage.body.title)
    }

    /// Profile → Cards says where each card shows by the page's name: there's no Today or Trends tab any more.
    func testCardPlacesNameThePages() {
        XCTAssertEqual(CardPlace.home.label, "Home")
        XCTAssertEqual(CardPlace.sleep.label, "Sleep")
        XCTAssertEqual(CardPlace(.vitals).label, "Vitals")
        XCTAssertEqual(CardPlace.bodyActivity.label, "Body · Activity")
        XCTAssertEqual(CardPlace.nutritionOverview.label, "Nutrition · Overview")
        XCTAssertEqual(CardPlace(.sleep, tab: "overview").label, "Sleep · Overview")
        // Each opens where it says.
        XCTAssertEqual(CardPlace.bodyActivity.route, .activity)
        XCTAssertEqual(CardPlace.home.route, .home)
        XCTAssertEqual(CardPlace.nutritionOverview.route, AppRoute(.nutrition, query: ["tab": "overview"]))
    }

    // MARK: Links

    /// Every page the web has (Page in shared/types.ts) opens here, by its id: insights, patterns and flags name them.
    func testEveryWebPageHasARoute() throws {
        let types = try web("shared/types.ts")
        let union = try XCTUnwrap(types.range(of: "export type Page =").map { String(types[$0.upperBound...].prefix { $0 != ";" }) })
        let ids = try matches(#"'(\w+)'"#, in: union).map { $0[0] }
        XCTAssertGreaterThan(ids.count, 10)
        for id in ids {
            XCTAssertNotNil(AppRoute(page: id), id)
        }
        // Onboarding's edit mode, shown over the app.
        XCTAssertEqual(AppRoute(page: "welcome"), .welcome)
        XCTAssertNil(AppRoute(page: "trends"))
        // The old addresses: Settings is Profile, Activity is a tab of Body.
        XCTAssertEqual(AppRoute(page: "settings"), .profile)
        XCTAssertEqual(AppRoute(page: "activity"), .activity)
        XCTAssertEqual(AppRoute.activity.page, .body)
        XCTAssertEqual(AppRoute(page: "labs")?.title, "Blood records")
        // Pages Trends never had now open too.
        XCTAssertEqual(AppRoute(page: "nutrition")?.page.tab, .nutrition)
        XCTAssertEqual(AppRoute(page: "journal")?.page.tab, .more)
    }

    func testTheAppsOwnLinks() throws {
        XCTAssertEqual(AppRoute(url: URL(string: "healthos://family")!), .family)
        XCTAssertEqual(AppRoute(url: URL(string: "healthos://home")!), .home)
        XCTAssertEqual(AppRoute(url: URL(string: "healthos://settings")!), .profile)
        XCTAssertEqual(AppRoute(url: URL(string: "healthos://profile?connect=openai")!), AppRoute(.profile, query: ["connect": "openai"]))
        XCTAssertEqual(AppRoute(url: URL(string: "healthos://body?tab=metabolism")!), AppRoute(.body, query: ["tab": "metabolism"]))
        XCTAssertEqual(AppRoute(url: URL(string: "healthos://activity")!), .activity)
        XCTAssertEqual(AppRoute(url: URL(string: "healthos://family?member=u2")!), .familyMember("u2"))
        XCTAssertNil(AppRoute(url: URL(string: "healthos://nowhere")!))
        XCTAssertNil(AppRoute(url: URL(string: "https://health.mcfly.bot/#/family")!))

        let d = Dashboard()
        XCTAssertTrue(d.open(url: URL(string: "healthos://family")!))
        XCTAssertEqual(d.tab, .more)
        XCTAssertEqual(d.paths[.more], [.family])
        // Anyone else's link is the system's to open, and nothing moves.
        XCTAssertFalse(d.open(url: URL(string: "https://example.com")!))
        XCTAssertEqual(d.tab, .more)
        XCTAssertEqual(d.paths[.more], [.family])
    }

    // MARK: Opening pages

    func testEachPageOpensWhereTheWebsPhoneLayoutHasIt() {
        let d = Dashboard()
        XCTAssertEqual(d.tab, .home)

        // A tab's own page: that tab, back at its top.
        d.paths[.vitals] = [.day(nil)]
        d.open(.vitals)
        XCTAssertEqual(d.tab, .vitals)
        XCTAssertEqual(d.paths[.vitals], [])

        // Under More, pushed on its own over the list.
        d.open(.sleep)
        XCTAssertEqual(d.tab, .more)
        XCTAssertEqual(d.paths[.more], [.sleep])
        d.open(.insights)
        XCTAssertEqual(d.paths[.more], [.insights], "the weekly digest notification opens Insights")
        d.open(.cycle)
        XCTAssertEqual(d.paths[.more], [.cycle])
        // A Family member over the board, so Back goes to the board.
        d.open(.familyMember("u2"))
        XCTAssertEqual(d.paths[.more], [.family, .familyMember("u2")])

        // One day over Home.
        d.open(.day("2026-10-20"))
        XCTAssertEqual(d.tab, .home)
        XCTAssertEqual(d.paths[.home], [.day("2026-10-20")])
        d.open(.home)
        XCTAssertEqual(d.paths[.home], [])
    }

    /// Home's steps and workouts open Body on its Activity tab; the same link twice works twice, so a tab changed by
    /// hand in between moves back.
    func testATabsOwnPageGetsItsLinksQuery() throws {
        let d = Dashboard()
        XCTAssertNil(d.request(for: .body))
        d.open(.activity)
        XCTAssertEqual(d.tab, .body)
        let first = try XCTUnwrap(d.request(for: .body))
        XCTAssertEqual(first.route.query["tab"], "activity")
        d.open(.activity)
        let second = try XCTUnwrap(d.request(for: .body))
        XCTAssertNotEqual(first, second)
        d.open(.body)
        XCTAssertNil(d.request(for: .body)?.route.query["tab"])
        d.open(AppRoute(.nutrition, query: ["compose": "1"]))
        XCTAssertEqual(d.request(for: .nutrition)?.route.query["compose"], "1")
        XCTAssertEqual(d.tab, .nutrition)
    }

    // MARK: Profile, the .settings alias

    /// About eight buttons ask for `.settings` ("Open Profile", "Change server", the hidden-cards note): it opens Profile
    /// under More, as the web's #/settings opens Profile.
    func testSettingsOpensProfileUnderMore() {
        let d = Dashboard()
        d.tab = .nutrition
        d.tab = .settings
        XCTAssertEqual(d.tab, .more)
        XCTAssertEqual(d.paths[.more], [.profile])
        // Over whatever More had open.
        d.open(.sleep)
        d.tab = .settings
        XCTAssertEqual(d.paths[.more], [.profile])
        // An ordinary tab change leaves the pages alone.
        d.tab = .vitals
        XCTAssertEqual(d.tab, .vitals)
        XCTAssertEqual(d.paths[.more], [.profile])
        d.open(.profile)
        XCTAssertEqual(d.tab, .more)
        XCTAssertEqual(d.paths[.more], [.profile])
    }

    /// Before sign-in, or with no server set, Profile still opens: it has the server address.
    func testProfileOpensBeforeSignIn() {
        let d = Dashboard()
        d.phase = .noServer
        d.tab = .settings
        XCTAssertEqual(d.paths[.more], [.profile])
        d.phase = .signIn
        d.tab = .settings
        XCTAssertEqual(d.paths[.more], [.profile])
        XCTAssertEqual(d.morePages.filter { $0 == .profile }, [.profile])
    }

    // MARK: Over the app

    /// The welcome is over everything, as the web shows it instead of the dashboard: a new account's whenever the
    /// server says its onboarding isn't done, and its steps again from #/welcome (Profile's Edit preferences). Not on a
    /// server older than onboarding, and never while signed out.
    func testTheWelcomeShowsOverTheApp() throws {
        let d = Dashboard()
        d.authMode = "required"
        d.phase = .ready
        d.apply(status: try status(#"{"perspective":"portrait","onboarding":1}"#))
        XCTAssertEqual(d.onboarding, .new)
        // The stub's "Not now": this session only, and nothing sent.
        d.putOffOnboarding()
        XCTAssertNil(d.onboarding)
        d.apply(status: try status(#"{"perspective":"portrait","onboarding":null}"#))
        XCTAssertNil(d.onboarding, "done")

        d.open(.welcome)
        XCTAssertEqual(d.onboarding, .edit)
        XCTAssertTrue(d.paths.values.allSatisfy(\.isEmpty), "shown over the app, not pushed")
        d.closeWelcome()
        XCTAssertNil(d.onboarding)
        XCTAssertEqual(d.tab, .more)
        XCTAssertEqual(d.paths[.more], [.profile], "back to Profile, as the web's")

        // An older server doesn't name perspective: it would ignore what the welcome saves.
        d.apply(status: try status(#"{"onboarding":1}"#))
        d.open(.welcome)
        XCTAssertNil(d.onboarding)

        // Signed out: never over the sign-in screen, and an edit asked for doesn't come back with the next person.
        d.apply(status: try status(#"{"perspective":"portrait","onboarding":null}"#))
        XCTAssertEqual(d.onboarding, .edit)
        d.phase = .signIn
        XCTAssertNil(d.onboarding)
        XCTAssertFalse(d.welcomeEditing)
    }

    /// Any card's arrow opens its metric's sheet over the app, with the card's page for "Open {Page}".
    func testAMetricSheetOpensOverTheApp() throws {
        let d = Dashboard()
        d.showMetric(.restingHr, page: .vitals, range: .week, date: "2026-10-20")
        XCTAssertEqual(d.metricSheet?.key, .restingHr)
        XCTAssertEqual(d.metricSheet?.section, "Your signals")
        XCTAssertEqual(d.metricSheet?.page, .vitals)
        XCTAssertEqual(d.metricSheet?.range, .week)
        XCTAssertEqual(d.metricSheet?.date, "2026-10-20")
        XCTAssertEqual(d.tab, .home, "over the page, not instead of it")
        // Gone with the person.
        d.phase = .ready
        d.phase = .signIn
        XCTAssertNil(d.metricSheet)

        // The keys and ranges are the web's (shared/metrics.ts).
        let metrics = try web("shared/metrics.ts")
        let keys = try XCTUnwrap(metrics.range(of: "export type MetricKey =").map { String(metrics[$0.upperBound...].prefix { $0 != ";" }) })
        XCTAssertEqual(try matches(#"'(\w+)'"#, in: keys).map { $0[0] }, MetricKey.allCases.map(\.rawValue))
        let ranges = try XCTUnwrap(metrics.range(of: "export type MetricRange =").map { String(metrics[$0.upperBound...].prefix { $0 != ";" }) })
        XCTAssertEqual(try matches(#"'(\w+)'"#, in: ranges).map { $0[0] }, MetricRange.allCases.map(\.rawValue))
    }

    /// A server whose sign-in isn't set up is its own phase, for the sign-in screens (slice A) to say so as the web does,
    /// not a "Can't load your dashboard" with the host in it.
    func testAMisconfiguredServerIsItsOwnPhase() throws {
        let d = Dashboard()
        let auth = try JSONDecoder().decode(AuthState.self, from: Data(#"{"mode":"misconfigured","authenticated":false}"#.utf8))
        d.apply(auth: auth, host: "health.example.com")
        XCTAssertEqual(d.phase, .misconfigured)
        XCTAssertNil(d.onboarding)
        XCTAssertFalse(d.signOutOffered)
    }

    // MARK: Account menu

    func testTheAccountMenuOffersAdminAndSignOutOnlyWithSignIn() throws {
        let d = Dashboard()
        d.authMode = "open"
        d.phase = .ready
        d.apply(status: try status("{}", user: #"{"id":"owner","role":"admin"}"#))
        // A server without sign-in: there's only you, and nothing to sign out of (the web's signedIn).
        XCTAssertFalse(d.signOutOffered)
        XCTAssertFalse(d.isAdmin)

        d.authMode = "required"
        XCTAssertTrue(d.signOutOffered)
        XCTAssertTrue(d.isAdmin)
        d.apply(status: try status("{}", user: #"{"id":"u2","role":"user"}"#))
        XCTAssertFalse(d.isAdmin)
        XCTAssertTrue(d.signOutOffered)

        d.phase = .signIn
        XCTAssertFalse(d.signOutOffered)
    }

    /// Each of the menu's items opens what the web's does: Profile and Integrations under More, Privacy & data as the
    /// server's page in the app. The shell runs it once the menu has gone, so a page asked for while it closes isn't lost.
    func testTheAccountMenusItemsOpenTheirPages() {
        let saved = UserDefaults.standard.string(forKey: "serverURL")
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: "serverURL") } else { UserDefaults.standard.removeObject(forKey: "serverURL") }
        }
        Config.serverText = "health.example.test"
        let d = Dashboard()
        d.accountMenuOpen = true
        AccountMenuItem.profile.run(d)
        XCTAssertEqual(d.tab, .more)
        XCTAssertEqual(d.paths[.more], [.profile])
        AccountMenuItem.integrations.run(d)
        XCTAssertEqual(d.paths[.more], [.integrations])
        AccountMenuItem.privacy.run(d)
        XCTAssertEqual(d.webPage?.url.absoluteString, "https://health.example.test/privacy.html")
    }

    /// Privacy & data and, until it's built here, Admin are the server's web pages, shown in the app.
    func testWebPagesAreTheServers() {
        let saved = UserDefaults.standard.string(forKey: "serverURL")
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: "serverURL") } else { UserDefaults.standard.removeObject(forKey: "serverURL") }
        }
        let d = Dashboard()
        Config.serverText = "health.example.test"
        d.showWeb("privacy.html")
        XCTAssertEqual(d.webPage?.url.absoluteString, "https://health.example.test/privacy.html")
        d.webPage = nil
        XCTAssertFalse(AdminScreen.native)
        d.open(.admin)
        XCTAssertEqual(d.webPage?.url.absoluteString, "https://health.example.test/#/admin")
        XCTAssertEqual(d.tab, .home, "Admin opens over the page, not as one")

        Config.serverText = "http://localhost:8787/"
        d.showWeb("privacy.html")
        XCTAssertEqual(d.webPage?.url.absoluteString, "http://localhost:8787/privacy.html")

        // No server: nothing to show.
        Config.serverText = ""
        d.webPage = nil
        d.showWeb("privacy.html")
        XCTAssertNil(d.webPage)
    }

    // MARK: What doesn't outlive what it showed

    /// Signed out or the server unreachable: every pushed page goes (a Family member's 30 days, a day), except Profile,
    /// which has the server address.
    func testPagesGoWhenTheDashboardCantBeShown() {
        let d = Dashboard()
        d.phase = .ready
        d.paths = [.more: [.family, .familyMember("u2")], .home: [.day(nil)]]
        d.phase = .signIn
        XCTAssertEqual(d.paths[.more], [])
        XCTAssertEqual(d.paths[.home], [])

        d.phase = .ready
        d.paths[.more] = [.profile]
        d.phase = .unavailable("offline")
        XCTAssertEqual(d.paths[.more], [.profile])

        // Asked to sign in again: the last person's pages went with the sign-in screen, so signing in (maybe as
        // someone else) keeps only what was opened since.
        d.phase = .ready
        d.paths[.more] = [.family, .familyMember("u2")]
        d.phase = .signIn
        XCTAssertEqual(d.paths[.more], [])
        d.signedIn()
        XCTAssertEqual(d.paths[.more], [])
    }

    /// The weekly digest tapped while signed out opens Insights, behind the sign-in screen; signing in there lands on
    /// the digest, not on the More list.
    func testADigestTappedWhileSignedOutShowsAfterSignIn() {
        let d = Dashboard()
        d.authMode = "required"
        d.phase = .signIn
        d.open(.insights)
        XCTAssertEqual(d.tab, .more)
        XCTAssertEqual(d.paths[.more], [.insights])
        d.signedIn()
        XCTAssertEqual(d.phase, .ready)
        XCTAssertEqual(d.tab, .more)
        XCTAssertEqual(d.paths[.more], [.insights])
    }

    /// A session that ends without Sign out (it ran out, or was ended on the web or by an admin): the next read's 401
    /// asks for sign-in, and nothing of the person stays for whoever holds the phone: not McFly's conversation, not
    /// their settings, summary or Family board.
    func testASessionThatEndsForgetsThePerson() throws {
        let d = Dashboard()
        d.authMode = "required"
        d.phase = .ready
        d.apply(status: try status(#"{"name":"Sam","familySharing":true,"cycleTracking":true}"#, user: #"{"id":"u1","role":"user"}"#))
        d.receiveFamily(try JSONDecoder().decode(FamilyBoard.self, from: Data(#"{"sharing":true,"today":"2026-10-17","members":[]}"#.utf8)))
        d.mcfly.messages = [McFlyMessage(role: .user, content: "Why is my heart rate up?"), McFlyMessage(role: .assistant, content: "…")]
        d.mcfly.status = McFlyStatus(configured: true, limit: 30, usedToday: 2)
        d.open(.mcfly)

        d.phase = .signIn // what fetch, a load or a version check does with a 401
        XCTAssertTrue(d.mcfly.messages.isEmpty)
        XCTAssertNil(d.mcfly.status)
        XCTAssertNil(d.status)
        XCTAssertNil(d.summary)
        XCTAssertNil(d.familyBoard)
        XCTAssertEqual(d.paths[.more], [], "Ask McFly's page closes too")
    }

    /// Another server: its pages go too, even when both answer (two servers without sign-in). Not the first connect
    /// at launch, which a tapped notification's page may already be waiting for. Nothing listens on these ports.
    func testAnotherServerClosesThePagesOfTheLast() async {
        let saved = UserDefaults.standard.string(forKey: "serverURL")
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: "serverURL") } else { UserDefaults.standard.removeObject(forKey: "serverURL") }
        }
        let d = Dashboard()
        Config.serverText = "http://127.0.0.1:9"
        d.open(.insights)
        await d.start()
        XCTAssertEqual(d.paths[.more], [.insights], "the first connect keeps what's waiting")

        d.paths = [.more: [.profile], .home: [.day(nil)]]
        Config.serverText = "http://127.0.0.1:7"
        await d.start()
        XCTAssertEqual(d.paths[.home], [])
        XCTAssertEqual(d.paths[.more], [.profile], "Profile, where the address was changed, stays")
    }

    /// Family went away (another server) or cycle tracking turned off while its page was open: back to More.
    func testPagesThatWentAwayLeaveMore() throws {
        let d = Dashboard()
        d.apply(status: try status(#"{"familySharing":true,"cycleTracking":true}"#))
        d.paths[.more] = [.family, .familyMember("u2")]
        d.dropMissingPages()
        XCTAssertEqual(d.paths[.more], [.family, .familyMember("u2")], "still there")
        // Sharing turned off: More stops listing Family, but the page stays open and says so (the web's FamilyOff).
        d.apply(status: try status(#"{"familySharing":false,"cycleTracking":true}"#))
        d.dropMissingPages()
        XCTAssertEqual(d.paths[.more], [.family, .familyMember("u2")])
        d.apply(status: try status(#"{"cycleTracking":true}"#))
        d.dropMissingPages()
        XCTAssertEqual(d.paths[.more], [])

        d.paths[.more] = [.cycle]
        d.apply(status: try status(#"{"cycleTracking":false}"#))
        d.dropMissingPages()
        XCTAssertEqual(d.paths[.more], [])

        d.paths[.more] = [.sleep]
        d.dropMissingPages()
        XCTAssertEqual(d.paths[.more], [.sleep])
    }

    /// Sign out clears what it always did, and now Ask McFly's conversation and the profile photo kept in Caches too,
    /// then goes back to Home with nothing open.
    func testSignOutForgetsThePerson() async throws {
        let saved = UserDefaults.standard.string(forKey: "serverURL")
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: "serverURL") } else { UserDefaults.standard.removeObject(forKey: "serverURL") }
        }
        // No server: Sign out doesn't call one.
        Config.serverText = ""
        let d = Dashboard()
        d.authMode = "required"
        d.phase = .ready
        d.apply(status: try status(#"{"familySharing":true}"#))
        d.mcfly.messages = [McFlyMessage(role: .user, content: "How did I sleep?")]
        d.mcfly.status = McFlyStatus(configured: true, limit: 30, usedToday: 2)
        d.open(.familyMember("u2"))
        d.webPage = WebPage(url: URL(string: "https://health.example.test/privacy.html")!)

        let photos = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("profile", isDirectory: true)
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        let photo = photos.appendingPathComponent("avatar-test.png")
        try Data([1, 2, 3]).write(to: photo)

        await d.signOut()
        XCTAssertEqual(d.phase, .signIn)
        XCTAssertNil(d.status)
        XCTAssertTrue(d.mcfly.messages.isEmpty)
        XCTAssertNil(d.mcfly.status)
        XCTAssertFalse(FileManager.default.fileExists(atPath: photo.path))
        XCTAssertEqual(d.tab, .home)
        XCTAssertTrue(d.paths.values.allSatisfy(\.isEmpty))
        XCTAssertNil(d.webPage)
    }

    /// Another person's sign-in or another server: Ask McFly starts a new conversation.
    func testAnotherSessionStartsANewConversation() {
        let d = Dashboard()
        d.mcfly.messages = [McFlyMessage(role: .user, content: "Hello")]
        d.signedIn()
        XCTAssertTrue(d.mcfly.messages.isEmpty)
        d.mcfly.messages = [McFlyMessage(role: .user, content: "Hello")]
        d.mcfly.forget()
        XCTAssertTrue(d.mcfly.messages.isEmpty)
        XCTAssertFalse(d.mcfly.streaming)
    }
}
