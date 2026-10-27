import SwiftUI
import XCTest
@testable import HealthOSSync

/// Where Home (slice B) meets Nutrition (slice G) and Ask McFly (slice E): Home's food cards read the same replies, in the
/// same types, that the Nutrition page reads; the orb on Today's nutrition opens Nutrition's composer, once per tap; and
/// the Ask McFly pill shows where the web's does, on Home only, once.
@MainActor
final class HomeNutritionLinkTests: XCTestCase {
    private var savedServer: String?

    override func setUp() async throws {
        savedServer = UserDefaults.standard.string(forKey: "serverURL")
        // Nothing listens here: the cards' and the shell's own reads fail at once and change nothing.
        Config.serverText = "http://127.0.0.1:9"
    }

    override func tearDown() async throws {
        if let savedServer { UserDefaults.standard.set(savedServer, forKey: "serverURL") } else { UserDefaults.standard.removeObject(forKey: "serverURL") }
    }

    private func web(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard let text = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) else { throw XCTSkip("\(path) isn't next to the app") }
        return text
    }

    private func fixture(_ name: String) throws -> Data {
        let url = Bundle(for: Self.self).url(forResource: name, withExtension: "json")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name).json")
        return try Data(contentsOf: url)
    }

    private func dashboard(nutrition: String?) throws -> Dashboard {
        let d = Dashboard()
        d.phase = .ready
        let settings = nutrition.map { #"{"nutrition":true,"nutritionNumbers":"\#($0)"}"# } ?? #"{"nutrition":false}"#
        d.apply(status: try JSONDecoder().decode(ServerStatus.self, from: Data(#"{"settings":\#(settings)}"#.utf8)))
        return d
    }

    /// An element's accessibility identifier, as the UI tests see it (SwiftUI's elements answer it without declaring
    /// UIAccessibilityIdentification).
    private func identifier(_ e: NSObject) -> String? {
        let get = NSSelectorFromString("accessibilityIdentifier")
        guard e.responds(to: get) else { return nil }
        return e.perform(get)?.takeUnretainedValue() as? String
    }

    // MARK: The orb

    /// The web's orb goes to #/nutrition?compose=1 with Nutrition on, and to Nutrition's page while it's off. Here a tap
    /// opens the Nutrition tab with that link, and the page (NutritionLink) applies it once: Today, with the composer
    /// focused, then nothing more until the next tap, so coming back to the tab never raises the keyboard again.
    func testHomesOrbOpensNutritionsComposerOncePerTap() async throws {
        XCTAssertTrue(try web("src/components/home/TodayNutrition.tsx").contains("href={on ? '#/nutrition?compose=1' : href('nutrition')} aria-label={on ? 'Log food' : 'Open Nutrition'}"))

        let d = try dashboard(nutrition: "all")
        var link = NutritionLink()
        try await HostedAccessibility.onScreen(TodayNutritionCard(date: "2026-10-24", today: "2026-10-24").environment(d).frame(width: 370)) { elements in
            let orb = try XCTUnwrap(elements.first { identifier($0) == "logFood" })
            XCTAssertEqual(orb.accessibilityLabel, "Log food")
            XCTAssertTrue(orb.accessibilityActivate())
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(d.tab, .nutrition)
            XCTAssertEqual(d.request(for: .nutrition)?.route, TodayNutritionCard.logRoute(nutritionOn: true))
            let first = link.take(d.request(for: .nutrition))
            XCTAssertEqual(first?.tab, .today)
            XCTAssertEqual(first?.compose, true, "the composer, focused")
            XCTAssertNil(link.take(d.request(for: .nutrition)), "applied once: back on the tab later, nothing again")

            // Another tap is another link: the composer again, once.
            d.tab = .home
            XCTAssertTrue(orb.accessibilityActivate())
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(link.take(d.request(for: .nutrition))?.compose, true)
            XCTAssertNil(link.take(d.request(for: .nutrition)))
        }

        // Nutrition off: Nutrition's own page, which explains it, with no composer asked for.
        let off = try dashboard(nutrition: nil)
        try await HostedAccessibility.onScreen(TodayNutritionCard(date: "2026-10-24", today: "2026-10-24").environment(off).frame(width: 370)) { elements in
            let orb = try XCTUnwrap(elements.first { identifier($0) == "logFood" })
            XCTAssertEqual(orb.accessibilityLabel, "Open Nutrition")
            XCTAssertTrue(orb.accessibilityActivate())
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(off.tab, .nutrition)
        var offLink = NutritionLink()
        XCTAssertEqual(offLink.take(off.request(for: .nutrition))?.compose, false)
    }

    // MARK: The same replies

    /// Home's two food cards read the replies the Nutrition page reads, decoded into the same types: Today's nutrition
    /// takes the food log's FoodEntry (G's Today shows the same entries, from FoodLogDay), and Food totals takes
    /// GET /api/nutrition's NutritionData and FoodDay with FoodMath (G's Trends, Macros and Hydration). One day read both
    /// ways says the same thing.
    func testHomesFoodCardsReadTheShapesNutritionReads() throws {
        // G's Today day (shared/foodday.ts), as Home's Today's nutrition shows it.
        let day = try JSONDecoder().decode(FoodLogDay.self, from: fixture("food-log-day"))
        let card = TodayNutritionCard.Model(entries: day.entries, date: day.date, today: day.today, mode: day.mode)
        XCTAssertEqual(card.count, day.entries.count, "every entry of the day G's journal lists")
        let newest = try XCTUnwrap(day.entries.max { $0.time < $1.time })
        XCTAssertEqual(card.latest, "Latest: \(newest.name), \(newest.time)")
        XCTAssertEqual(card.kcal, 0, "no energy in \(day.mode.rawValue), as G's balance has none")
        XCTAssertNil(day.balance?["energy_kcal"])
        // The same entries as Home reads them, from GET /api/nutrition/log (shared/types.ts FoodLog).
        let dayJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture("food-log-day")) as? [String: Any])
        let logJSON: [String: Any] = ["enabled": true, "numbers": dayJSON["numbers"] as Any, "today": day.today, "start": day.date, "end": day.today,
                                      "entries": dayJSON["entries"] as Any, "drafts": [], "draftBatch": NSNull(), "can": dayJSON["can"] as Any]
        let log = try JSONDecoder().decode(FoodLog.self, from: JSONSerialization.data(withJSONObject: logJSON))
        XCTAssertEqual(TodayNutritionCard.Model(entries: log.entries, date: day.date, today: day.today, mode: log.mode), card)

        // G's own fixture for GET /api/nutrition (NutritionScreenTests), as Home's Food totals shows it.
        let data = try JSONDecoder().decode(NutritionData.self, from: fixture("nutrition-all"))
        let totals = FoodTotalsCard.Model(data)
        let last = try XCTUnwrap(data.days.last)
        XCTAssertEqual(totals.latest?.date, last.date)
        XCTAssertEqual(totals.note, "\(Fmt.relativeDay(last.date, today: data.today)) · \(last.app)")
        XCTAssertEqual(totals.days.map(\.date), FoodMath.dates(from: data.start, to: data.end))
        XCTAssertEqual(totals.days.filter(\.logged).count, Set(data.days.map(\.date)).count)
        XCTAssertFalse(totals.shown.isEmpty)
        XCTAssertTrue(totals.shown.allSatisfy { last.values[$0] != nil && FoodMath.order.contains($0) })
        XCTAssertTrue(try web("src/pages/Nutrition.tsx").contains("const { data } = useApi<NutritionData>(nutritionPath('/nutrition?days=7', numbers));"),
                      "the web's card reads 7 days, as HomeReads does")
    }

    // MARK: Ask McFly's pill

    /// The web shows the pill on Home only (`{page === 'home' && <AskPill />}`): here it's on Home's own page once, and
    /// not on Vitals, under More (whose list has its own Ask McFly row), on a day pushed over Home, or signed out. The
    /// shell is shown as the app shows it, connected to a stub server (made-up answers) where Sam is signed in.
    func testThePillShowsOnHomeOnlyAndOnce() async throws {
        XCTAssertTrue(try web("src/App.tsx").contains("{page === 'home' && <AskPill />}"))
        let server = try await AIStubServer.start([
            "GET /api/auth/me": .json(200, #"{"mode":"required","authenticated":true,"setup":false,"user":{"id":"u-sam","email":"sam@example.test","role":"member"}}"#),
            "GET /api/summary": .json(200, String(decoding: try fixture("summary"), as: UTF8.self)),
            "GET /api/status": .json(200, #"{"user":{"id":"u-sam","role":"member"},"settings":{"perspective":"digital","onboarding":null,"timeZone":"\#(TimeZone.current.identifier)"}}"#),
            "GET /api/version": .json(200, #"{"version":"v1"}"#),
        ])
        addTeardownBlock {
            server.stop()
            SummaryCache.clear(for: server.url)
        }
        Config.serverText = server.url.absoluteString
        let d = Dashboard()
        await d.start()
        XCTAssertEqual(d.phase, .ready)
        XCTAssertNotNil(d.summary)

        var seen = ""
        func pills(_ setUp: () -> Void) async throws -> (pills: Int, moreRow: Bool) {
            setUp()
            var result = (0, false)
            try await HostedAccessibility.onScreen(AppShell().environment(d).environment(AppModel())) { elements in
                result = (elements.filter { identifier($0) == "askMcFly" }.count, elements.contains { identifier($0) == "more.mcfly" })
                seen = elements.map { "\(identifier($0) ?? "-")|\($0.accessibilityLabel ?? "")" }.joined(separator: "; ")
            }
            return result
        }
        let home = try await pills { d.tab = .home }
        XCTAssertEqual(home.pills, 1, "on Home, once: \(seen)")
        let vitals = try await pills { d.tab = .vitals }
        XCTAssertEqual(vitals.pills, 0, "not on Vitals")
        let more = try await pills { d.tab = .more }
        XCTAssertEqual(more.pills, 0, "not under More")
        XCTAssertTrue(more.moreRow, "where Ask McFly is a row of the list instead")
        let day = try await pills { d.open(.day(nil)) }
        XCTAssertEqual(d.tab, .home)
        XCTAssertEqual(day.pills, 0, "not on a day pushed over Home")
        let signedOut = try await pills {
            d.paths = [:]
            d.phase = .signIn
        }
        XCTAssertEqual(signedOut.pills, 0, "not behind the sign-in screen")
    }

    // MARK: Live heart rate

    /// "Just the statistics" has no figure, so no heart to tap: Live heart rate opens from its own button there. With a
    /// figure, the heart's callout is the way in, and there's no button.
    func testLiveHeartRateHasAWayInWithJustTheStatistics() async throws {
        let summary = try JSONDecoder().decode(Summary.self, from: try fixture("summary"))
        for (perspective, shows) in [("stats", true), ("digital", false)] {
            let d = Dashboard()
            d.phase = .ready
            d.apply(status: try JSONDecoder().decode(ServerStatus.self, from: Data(#"{"settings":{"perspective":"\#(perspective)"}}"#.utf8)))
            try await HostedAccessibility.onScreen(TodayContent(summary: summary).environment(d).environment(AppModel())) { elements in
                let button = elements.first { identifier($0) == "liveHeartRate" }
                XCTAssertEqual(button != nil, shows, perspective)
                if shows { XCTAssertEqual(button?.accessibilityLabel, "Live heart rate") }
            }
        }
    }

    /// Home is one person's on one server (TodayScreen keys TodayContent by `identity(of:)`): another server, or someone
    /// else, makes it anew, so nothing read for the last one (the journal's check-in, the food totals) stays on it.
    func testHomeIsMadeAnewForAnotherServerOrPerson() throws {
        let saved = UserDefaults.standard.string(forKey: "serverURL")
        addTeardownBlock {
            if let saved { UserDefaults.standard.set(saved, forKey: "serverURL") } else { UserDefaults.standard.removeObject(forKey: "serverURL") }
        }
        func status(_ id: String) throws -> ServerStatus {
            try JSONDecoder().decode(ServerStatus.self, from: Data(#"{"user":{"id":"\#(id)","email":"\#(id)@example.test","role":"member"}}"#.utf8))
        }
        let d = Dashboard()
        Config.serverText = "https://one.example.test"
        d.apply(status: try status("owner"))
        let first = TodayScreen.identity(of: d)
        XCTAssertEqual(TodayScreen.identity(of: d), first, "the same person on the same server keeps their Home")
        Config.serverText = "http://192.168.0.2:8080"
        XCTAssertNotEqual(TodayScreen.identity(of: d), first, "the same account id on another server")
        Config.serverText = "https://one.example.test"
        d.apply(status: try status("u-sam"))
        XCTAssertNotEqual(TodayScreen.identity(of: d), first, "someone else on the same server")
    }
}
