import XCTest
@testable import HealthOSSync

/// Where the app shows each card: each page's own table (Home/HomeCards.swift, Sleep/SleepCards.swift,
/// Body/BodyCards.swift, Nutrition/NutritionCards.swift). The first test holds for every table; each page's own test
/// says what it shows now, and changes with that page.
final class CardPlacesTests: XCTestCase {
    private let tables: [(CardPage, [String: CardPlace])] = [
        (.home, HomeCards.places), (.sleep, SleepCards.places), (.body, BodyCards.places), (.nutrition, NutritionCards.places),
    ]

    func testEveryPlacedCardIsTheRegistrysOnItsOwnPage() {
        var seen: Set<String> = []
        for (page, table) in tables {
            for (id, place) in table {
                let card = Cards.card(id)
                XCTAssertNotNil(card, "\(id) is in shared/cards.ts")
                XCTAssertEqual(card?.page, page, "\(id) is in its own page's table")
                XCTAssertEqual(place.page, page.appPage, "\(id) shows on its own page, on a tab of it at most")
                XCTAssertTrue(seen.insert(id).inserted, "\(id) is placed once")
                XCTAssertEqual(card?.place, place)
            }
        }
        // A card in no table shows on the web dashboard only, and Profile → Cards says so.
        XCTAssertEqual(Set(Cards.all.filter { $0.place != nil }.map(\.id)), seen)
        XCTAssertNil(Cards.place(of: "future.card"))
    }

    func testHomePlaces() {
        // Every card the web's Home has shows on the iPhone's Home, in the registry's order.
        XCTAssertEqual(Cards.ids(in: .home), Cards.all.filter { $0.page == .home }.map(\.id))
        XCTAssertEqual(Cards.ids(in: .home).count, 14)
        // The rows, as Home.tsx lays them out: the signals, the pair, the optional row; then the timeline, the week and
        // insights on their own.
        XCTAssertEqual(HomeCards.signals, ["home.rhr", "home.spo2", "home.hrv", "home.sleep", "home.readiness", "home.resp"])
        XCTAssertEqual(HomeCards.lower, ["home.nutrition", "home.journal"])
        XCTAssertEqual(HomeCards.optionalRow, ["home.load", "home.activity", "home.food"])
        XCTAssertTrue(HomeCards.optionalRow.allSatisfy { Cards.optional.contains($0) })
        XCTAssertTrue((HomeCards.signals + HomeCards.lower).allSatisfy { !Cards.optional.contains($0) })
    }

    func testSleepPlaces() {
        XCTAssertEqual(Cards.ids(in: .sleep), ["sleep.total", "sleep.score", "sleep.efficiency", "sleep.stages"])
    }

    func testBodyPlaces() {
        // Every Body card is on the Body page's Overview, in the registry's order; nothing on its other tabs.
        let body = Cards.all.filter { $0.page == .body }.map(\.id)
        XCTAssertEqual(body.count, 14)
        XCTAssertEqual(Cards.ids(in: CardPlace(.body, tab: "overview")), body)
        XCTAssertTrue(body.allSatisfy { Cards.card($0)?.place?.label == "Body · Overview" })
        XCTAssertTrue(Cards.ids(in: CardPlace(.body)).isEmpty)
        XCTAssertTrue(Cards.ids(in: .bodyActivity).isEmpty)
    }

    func testNutritionPlaces() {
        XCTAssertEqual(Cards.ids(in: .nutritionOverview),
                       ["nutrition.energy", "nutrition.protein", "nutrition.water", "nutrition.logged", "nutrition.macros", "nutrition.insights"])
    }
}
