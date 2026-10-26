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
        XCTAssertEqual(Cards.ids(in: .home), ["home.spo2", "home.hrv", "home.sleep", "home.readiness", "home.week", "home.timeline", "home.insights", "home.load", "home.activity"])
        XCTAssertEqual(Cards.todayGrid.filter { Cards.card($0)?.place == .home }, Cards.todayGrid, "every grid card is a Home card")
        // No food card on Home yet.
        XCTAssertNil(Cards.card("home.food")?.place)
    }

    func testSleepPlaces() {
        XCTAssertEqual(Cards.ids(in: .sleep), ["sleep.total", "sleep.score", "sleep.efficiency", "sleep.stages"])
    }

    func testBodyPlaces() {
        // Nothing of the Body overview in the app yet.
        XCTAssertTrue(Cards.all.filter { $0.page == .body }.allSatisfy { $0.place == nil })
        XCTAssertTrue(Cards.ids(in: CardPlace(.body)).isEmpty)
        XCTAssertTrue(Cards.ids(in: .bodyActivity).isEmpty)
    }

    func testNutritionPlaces() {
        XCTAssertEqual(Cards.ids(in: .nutritionOverview),
                       ["nutrition.energy", "nutrition.protein", "nutrition.water", "nutrition.logged", "nutrition.macros", "nutrition.insights"])
    }
}
