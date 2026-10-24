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
        XCTAssertFalse(Cards.allHidden(in: .today, hidden: d.cardsOff))

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
        XCTAssertEqual(Cards.hiddenOffered(Set(hidden), nutrition: true, optionalCards: false), ["home.hrv", "home.week", "home.food", "sleep.rhr"],
                       "every hidden card on an older server, in the registry's order")
        XCTAssertEqual(Cards.hiddenOffered(["home.week", "home.load"], nutrition: false, optionalCards: true), [], "All shown, and no Show all")
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
        let sleep = Cards.ids(in: .trends(.sleep))
        XCTAssertEqual(Cards.visible(sleep, hidden: try dashboard(hidden: ["sleep.efficiency"], shown: []).cardsOff), ["sleep.total", "sleep.score", "sleep.stages"])
        XCTAssertEqual(Cards.visible(sleep, hidden: try dashboard(hidden: ["sleep.score"], shown: []).cardsOff), ["sleep.total", "sleep.efficiency", "sleep.stages"])
        // Without WHOOP there's no performance card to show, so the rest hidden is all of them.
        let noPerformance = sleep.filter { $0 != "sleep.score" }
        XCTAssertTrue(Cards.allHidden(noPerformance, hidden: ["sleep.total", "sleep.efficiency", "sleep.stages"]))
        XCTAssertFalse(Cards.allHidden(sleep, hidden: ["sleep.total", "sleep.efficiency", "sleep.stages"]))
        XCTAssertFalse(Cards.allHidden([], hidden: []), "nothing to hide, so no note")
    }
}
