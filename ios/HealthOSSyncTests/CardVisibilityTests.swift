import XCTest
@testable import HealthOSSync

/// The web's card rules (shared/cards.ts): optional cards are off until turned on (shownCards), the rest are on until
/// hidden (hiddenCards), and an older server without shownCards shows every card unless it's hidden.
@MainActor
final class CardVisibilityTests: XCTestCase {
    /// A status as the server sends it; shown nil is a server older than optional cards.
    private func status(hidden: [String], shown: [String]?) throws -> ServerStatus {
        var settings: [String: Any] = ["name": "Sam", "hiddenCards": hidden]
        if let shown { settings["shownCards"] = shown }
        return try JSONDecoder().decode(ServerStatus.self, from: JSONSerialization.data(withJSONObject: ["settings": settings]))
    }

    private func dashboard(hidden: [String], shown: [String]?) throws -> Dashboard {
        let d = Dashboard()
        d.apply(status: try status(hidden: hidden, shown: shown))
        return d
    }

    private func json(_ fields: [String: Any]) throws -> String {
        String(decoding: try APIClient.settingsBody(fields), as: UTF8.self)
    }

    /// What the server does with a PUT /settings body (server/app.ts, withCardToggled): an optional card moves in or
    /// out of shown, and the other way in hidden; any other card only in hidden; a whole list replaces hidden.
    private func serve(_ fields: [String: Any], hidden: inout [String], shown: inout [String]) {
        if let list = fields["hiddenCards"] as? [String] {
            hidden = list
        } else if let c = fields["cardShown"] as? [String: Any], let id = c["id"] as? String, let on = c["shown"] as? Bool {
            if Cards.optional.contains(id) { shown = on ? shown + [id] : shown.filter { $0 != id } }
            hidden = Cards.toggled(hidden, id: id, shown: on)
        }
    }

    func testTheRule() {
        // An optional card shows only once it's turned on, whatever the hidden list says.
        XCTAssertFalse(Cards.shows("home.week", hidden: [], shown: []))
        XCTAssertTrue(Cards.shows("home.week", hidden: [], shown: ["home.week"]))
        XCTAssertTrue(Cards.shows("home.week", hidden: ["home.week"], shown: ["home.week"]))
        // Any other card shows unless it's hidden.
        XCTAssertTrue(Cards.shows("home.hrv", hidden: [], shown: []))
        XCTAssertFalse(Cards.shows("home.hrv", hidden: ["home.hrv"], shown: ["home.hrv"]))
        // An older server sends no shown list: optional cards are ordinary ones there.
        XCTAssertTrue(Cards.shows("home.week", hidden: [], shown: nil))
        XCTAssertFalse(Cards.shows("home.week", hidden: ["home.week"], shown: nil))
    }

    func testTodayLeavesOutTheOptionalCardsByDefault() throws {
        let d = try dashboard(hidden: [], shown: [])
        XCTAssertTrue(d.optionalCards)
        XCTAssertEqual(Cards.visible(Cards.todayGrid, hidden: d.cardsOff), ["home.readiness", "home.spo2", "home.hrv", "home.sleep"])
        for id in ["home.week", "home.timeline", "home.insights", "home.load", "home.activity"] {
            XCTAssertFalse(d.cardShown(id), id)
            XCTAssertTrue(d.cardsOff.contains(id), id)
        }
        XCTAssertFalse(Cards.allHidden(in: .home, hidden: d.cardsOff))

        // Turned on (on the web or here), they show.
        let on = try dashboard(hidden: [], shown: ["home.week", "home.load"])
        XCTAssertEqual(Cards.visible(Cards.todayGrid, hidden: on.cardsOff), ["home.readiness", "home.spo2", "home.hrv", "home.sleep", "home.load"])
        XCTAssertTrue(on.cardShown("home.week"))
        XCTAssertFalse(on.cardShown("home.timeline"))
    }

    func testAnOlderServerStillShowsEveryCard() throws {
        let d = try dashboard(hidden: ["home.hrv"], shown: nil)
        XCTAssertFalse(d.optionalCards)
        XCTAssertEqual(Cards.visible(Cards.todayGrid, hidden: d.cardsOff), ["home.readiness", "home.spo2", "home.sleep", "home.load", "home.activity"])
        XCTAssertTrue(Cards.all.filter { $0.id != "home.hrv" }.allSatisfy { d.cardShown($0.id) })
    }

    func testHiddenDefaultsLeaveOutTheOptionalCards() {
        // An optional card turned off is in the hidden list too (for older iPhone builds), but it isn't hidden from a default.
        let hidden = ["home.week", "home.hrv", "home.food", "sleep.rhr"]
        XCTAssertEqual(Cards.hiddenDefaults(hidden, optionalCards: true), ["home.hrv", "sleep.rhr"])
        XCTAssertEqual(Cards.hiddenDefaults(hidden, optionalCards: false), hidden, "no optional cards on an older server")
        // The Settings row and Show all count the same: default cards offered there only.
        XCTAssertEqual(Cards.hiddenOffered(Set(hidden), nutrition: true, optionalCards: true), ["home.hrv", "sleep.rhr"])
        // On an older server every hidden card it knows counts. home.week isn't one of them: it came with the optional
        // cards, so that server never stores it, and Settings doesn't offer it there.
        XCTAssertEqual(Cards.hiddenOffered(Set(hidden), nutrition: true, optionalCards: false), ["home.hrv", "home.food", "sleep.rhr"],
                       "every hidden card on an older server, in the registry's order")
        XCTAssertEqual(Cards.hiddenOffered(["home.week", "home.load"], nutrition: false, optionalCards: true), [], "All shown, and no Show all")
    }

    /// main's shared/cards.ts, the registry of a server older than optional cards, in its order.
    private let olderServerCards = [
        "home.readiness", "home.spo2", "home.hrv", "home.sleep", "home.load", "home.activity", "home.food", "home.timeline", "home.insights",
        "sleep.score", "sleep.total", "sleep.rhr", "sleep.stages", "sleep.insights", "sleep.timeline",
        "body.rhr", "body.hrv", "body.strain", "body.recovery", "body.heart", "body.metrics", "body.energy", "body.steps", "body.workout",
        "body.glucose", "body.composition", "body.biomarkers",
        "nutrition.energy", "nutrition.protein", "nutrition.water", "nutrition.logged", "nutrition.macros", "nutrition.insights",
    ]

    func testAnOlderServerIsOfferedOnlyTheCardsItKnows() throws {
        // It answers 400 to a change to any other card, and the switch would flip back with that error.
        XCTAssertEqual(olderServerCards.count, 33)
        let offered = Cards.pages(nutrition: true, optionalCards: false).flatMap(\.cards).map(\.id)
        XCTAssertEqual(offered.count, 33)
        XCTAssertEqual(Set(offered), Set(olderServerCards))
        XCTAssertEqual(Set(Cards.all.map(\.id)).subtracting(olderServerCards), Cards.newerThanOlderServers, "the newer ones, and only those")
        XCTAssertEqual(Cards.pages(nutrition: true).flatMap(\.cards).count, 41, "a current server is offered every card")

        // There the sleep score still hides sleep efficiency too, as before it had its card, and keeps that server's name.
        let d = try dashboard(hidden: ["sleep.score"], shown: nil)
        XCTAssertFalse(d.cardShown("sleep.efficiency"))
        XCTAssertEqual(Cards.visible(Cards.ids(in: .sleep), hidden: d.cardsOff), ["sleep.total", "sleep.stages"])
        XCTAssertTrue(try dashboard(hidden: [], shown: nil).cardShown("sleep.efficiency"))
        let score = try XCTUnwrap(Cards.card("sleep.score"))
        XCTAssertEqual(Cards.label(score, optionalCards: false), "Sleep score")
        XCTAssertEqual(Cards.label(score, optionalCards: true), "Sleep performance")
        // A current server keeps them apart (testSleepEfficiencyIsItsOwnCard).
        XCTAssertTrue(try dashboard(hidden: ["sleep.score"], shown: []).cardShown("sleep.efficiency"))
    }

    func testAnOptionalCardTurnedOnShowsEvenWhileStillInHidden() throws {
        // PUT /settings takes a whole shownCards list without touching hidden, so a card can be in both. On is on, as
        // the web's cardShown has it.
        let d = try dashboard(hidden: ["home.load"], shown: ["home.load"])
        XCTAssertTrue(d.cardShown("home.load"))
        XCTAssertFalse(d.cardsOff.contains("home.load"))
        XCTAssertEqual(Cards.visible(Cards.todayGrid, hidden: d.cardsOff), ["home.readiness", "home.spo2", "home.hrv", "home.sleep", "home.load"])
        // A newer server's card stays in the list of those off; no screen here shows it anyway.
        XCTAssertTrue(Cards.off(hidden: ["future.card"], shown: []).contains("future.card"))
    }

    private func summaryJSON() throws -> Any {
        let url = Bundle(for: Self.self).url(forResource: "summary", withExtension: "json")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/summary.json")
        return try JSONSerialization.jsonObject(with: Data(contentsOf: url))
    }

    func testAHostedStatusCachedByTheLastBuildLeavesTheOptionalCardsOff() throws {
        let base = try XCTUnwrap(URL(string: "https://cards-cache.invalid"))
        defer { SummaryCache.clear(for: base) }
        // The build before this one never kept shownCards, so its cache has none even from a server with optional cards.
        func cacheAsTheLastBuild(_ settings: [String: Any], hosted: Bool? = true) throws {
            var status: [String: Any] = ["settings": settings]
            if let hosted { status["hosted"] = hosted }
            let entry: [String: Any] = ["summary": try summaryJSON(), "status": status, "version": "v1", "loadedOn": "2026-10-24"]
            try JSONSerialization.data(withJSONObject: entry).write(to: SummaryCache.file(for: base))
        }
        try cacheAsTheLastBuild(["name": "Sam", "hiddenCards": ["home.hrv"]])
        let cached = try XCTUnwrap(SummaryCache.load(for: base))
        XCTAssertEqual(cached.status?.settings?.shownCards, [], "off until the first status read says otherwise")
        XCTAssertEqual(cached.status?.settings?.hiddenCards, ["home.hrv"])
        XCTAssertEqual(cached.version, "v1")
        let d = Dashboard()
        d.apply(status: try XCTUnwrap(cached.status))
        XCTAssertFalse(d.cardShown("home.week"))
        XCTAssertFalse(d.cardShown("home.load"))

        // A server older than card hiding has no lists at all: nothing to fill in.
        try cacheAsTheLastBuild(["name": "Sam"])
        XCTAssertNil(try XCTUnwrap(SummaryCache.load(for: base)).status?.settings?.shownCards)

        // A Mac or LAN server may be older than optional cards (main has none): every card stays on unless hidden, as
        // before the update, until its first status read says otherwise. Offline away from home, that can be days.
        for hosted in [false, nil] as [Bool?] {
            try cacheAsTheLastBuild(["name": "Sam", "hiddenCards": ["home.hrv"]], hosted: hosted)
            let local = try XCTUnwrap(SummaryCache.load(for: base))
            XCTAssertNil(local.status?.settings?.shownCards)
            let l = Dashboard()
            l.apply(status: try XCTUnwrap(local.status))
            XCTAssertTrue(l.cardShown("home.week"))
            XCTAssertTrue(l.cardShown("home.load"))
            XCTAssertFalse(l.cardShown("home.hrv"))
        }

        // This build keeps what the server sent: no shownCards is an older server, where every card shows.
        SummaryCache.save(summary: cached.summary, status: try status(hidden: [], shown: nil), version: "v2", loadedOn: "2026-10-25", for: base)
        let older = try XCTUnwrap(SummaryCache.load(for: base))
        XCTAssertNil(older.status?.settings?.shownCards)
        SummaryCache.save(summary: cached.summary, status: try status(hidden: [], shown: ["home.week"]), version: "v3", loadedOn: "2026-10-25", for: base)
        XCTAssertEqual(try XCTUnwrap(SummaryCache.load(for: base)).status?.settings?.shownCards, ["home.week"])
    }

    func testShowAllLeavesTheOptionalCardsOff() async throws {
        XCTAssertEqual(Cards.afterShowAll(["home.hrv", "home.week", "sleep.rhr", "home.food"], optionalCards: true), ["home.week", "home.food"])
        XCTAssertEqual(Cards.afterShowAll(["home.hrv", "home.week"], optionalCards: false), [], "an older server gets every card back")

        let d = try dashboard(hidden: ["home.hrv", "home.week"], shown: ["home.load"])
        var hidden = ["home.hrv", "home.week"], shown = ["home.load"]
        var bodies: [String] = []
        try await d.changeCards(.list(Cards.afterShowAll(d.hiddenCards, optionalCards: d.optionalCards))) { fields in
            bodies.append(try self.json(fields))
            XCTAssertTrue(d.cardShown("home.hrv"), "back at once")
            XCTAssertFalse(d.cardShown("home.week"), "still off")
            XCTAssertTrue(d.cardShown("home.load"), "still on")
            self.serve(fields, hidden: &hidden, shown: &shown)
            return try self.status(hidden: hidden, shown: shown)
        }
        XCTAssertEqual(bodies, [#"{"hiddenCards":["home.week"]}"#])
        XCTAssertNil(d.pendingCards)
        XCTAssertEqual(d.hiddenCards, ["home.week"])
        XCTAssertEqual(d.shownCards, ["home.load"])
    }

    func testTurningAnOptionalCardOnOrOffMovesBothLists() throws {
        // As withCardToggled: on joins shown and leaves hidden; off leaves shown and joins hidden.
        let lists = CardLists(hidden: ["home.week", "home.hrv"], shown: ["home.load"])
        XCTAssertEqual(CardChange.card("home.week", shown: true).applied(to: lists), CardLists(hidden: ["home.hrv"], shown: ["home.load", "home.week"]))
        XCTAssertEqual(CardChange.card("home.load", shown: false).applied(to: lists), CardLists(hidden: ["home.week", "home.hrv", "home.load"], shown: []))
        // Any other card: only hidden.
        XCTAssertEqual(CardChange.card("home.spo2", shown: false).applied(to: lists), CardLists(hidden: ["home.week", "home.hrv", "home.spo2"], shown: ["home.load"]))
        // An older server has no shown list to change.
        XCTAssertEqual(CardChange.card("home.week", shown: true).applied(to: CardLists(hidden: ["home.week"], shown: nil)), CardLists(hidden: [], shown: nil))
        // A whole list replaces hidden only.
        XCTAssertEqual(CardChange.list([]).applied(to: lists), CardLists(hidden: [], shown: ["home.load"]))
    }

    func testAnOptionalCardShowsAtOnceThenFollowsTheServer() async throws {
        let d = try dashboard(hidden: [], shown: [])
        var hidden: [String] = [], shown: [String] = []
        var bodies: [String] = []
        try await d.changeCards(.card("home.week", shown: true)) { fields in
            bodies.append(try self.json(fields))
            XCTAssertTrue(d.cardShown("home.week"), "on before the server answers")
            self.serve(fields, hidden: &hidden, shown: &shown)
            return try self.status(hidden: hidden, shown: shown)
        }
        XCTAssertEqual(bodies, [#"{"cardShown":{"id":"home.week","shown":true}}"#], "one change, no retry")
        XCTAssertTrue(d.cardShown("home.week"))
        XCTAssertEqual(d.shownCards, ["home.week"])

        try await d.changeCards(.card("home.week", shown: false)) { fields in
            XCTAssertFalse(d.cardShown("home.week"))
            self.serve(fields, hidden: &hidden, shown: &shown)
            return try self.status(hidden: hidden, shown: shown)
        }
        XCTAssertFalse(d.cardShown("home.week"))
        XCTAssertEqual(d.hiddenCards, ["home.week"])
        XCTAssertEqual(d.shownCards, [])
        XCTAssertNil(d.pendingCards)
    }

    func testARefusedOptionalCardGoesBack() async throws {
        let d = try dashboard(hidden: [], shown: [])
        do {
            try await d.changeCards(.card("home.week", shown: true)) { _ in
                XCTAssertTrue(d.cardShown("home.week"))
                throw APIError.server(400, "Unknown card, or not a list of cards.")
            }
            XCTFail("the error reaches the caller")
        } catch APIError.server(400, _) {}
        XCTAssertFalse(d.cardShown("home.week"))
        XCTAssertEqual(d.shownCards, [])
    }

    func testSleepEfficiencyIsItsOwnCard() throws {
        let sleep = Cards.ids(in: .sleep)
        XCTAssertEqual(Cards.visible(sleep, hidden: try dashboard(hidden: ["sleep.efficiency"], shown: []).cardsOff), ["sleep.total", "sleep.score", "sleep.stages"])
        XCTAssertEqual(Cards.visible(sleep, hidden: try dashboard(hidden: ["sleep.score"], shown: []).cardsOff), ["sleep.total", "sleep.efficiency", "sleep.stages"])
        // Without WHOOP there's no performance card to show, so the rest hidden is all of them.
        let noPerformance = sleep.filter { $0 != "sleep.score" }
        XCTAssertTrue(Cards.allHidden(noPerformance, hidden: ["sleep.total", "sleep.efficiency", "sleep.stages"]))
        XCTAssertFalse(Cards.allHidden(sleep, hidden: ["sleep.total", "sleep.efficiency", "sleep.stages"]))
        XCTAssertFalse(Cards.allHidden([], hidden: []), "nothing to hide, so no note")
    }
}
