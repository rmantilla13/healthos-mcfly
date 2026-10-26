import XCTest
@testable import HealthOSSync

/// The Nutrition section (src/pages/Nutrition.tsx). Fixtures come from a scratch server on the Neka layout, filled with
/// made-up food, in each of the three modes; the committed server shape (no targets, hydration or insights) must read too.
@MainActor
final class NutritionScreenTests: XCTestCase {
    private func fixture(_ name: String) throws -> NutritionData {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"))
        return try JSONDecoder().decode(NutritionData.self, from: Data(contentsOf: url))
    }

    func testDecodesTheReplyInEachMode() throws {
        let all = try fixture("nutrition-all")
        XCTAssertTrue(all.enabled)
        XCTAssertEqual(all.mode, .all)
        XCTAssertEqual([all.start, all.end, all.today], ["2026-10-06", "2026-10-19", "2026-10-19"])
        XCTAssertEqual(all.days.count, 12)
        XCTAssertEqual(all.days.last?.app, "MyFitnessPal")
        XCTAssertEqual(all.days.last?.otherApps, ["Lose It!"])
        XCTAssertEqual(all.days.last?.values["energy_kcal"], 2150)
        XCTAssertEqual(all.targets, ["energy_kcal": 2200, "protein_g": 120, "water_ml": 2000])
        XCTAssertEqual(all.water.count, 12)
        XCTAssertEqual(all.caffeine.count, 14)
        XCTAssertEqual(all.insights.count, 1)

        let noEnergy = try fixture("nutrition-no-energy")
        XCTAssertEqual(noEnergy.mode, .noEnergy)
        XCTAssertTrue(noEnergy.days.allSatisfy { $0.values["energy_kcal"] == nil })
        XCTAssertNil(noEnergy.targets?["energy_kcal"])
        XCTAssertEqual(noEnergy.targets?["protein_g"], 120)

        let none = try fixture("nutrition-none")
        XCTAssertEqual(none.mode, .none)
        XCTAssertEqual(none.days.count, 12, "the logged days still show")
        XCTAssertTrue(none.days.allSatisfy(\.values.isEmpty))
        XCTAssertEqual(none.targets ?? [:], [:])
        XCTAssertTrue(none.water.isEmpty && none.caffeine.isEmpty && none.insights.isEmpty)
    }

    func testTheCommittedShapeAndAnOddDayStillRead() throws {
        // nutrition-phase1 f48d113: no targets, hydration or insights. One day here has a value the app can't read.
        let json = #"""
        {"enabled":true,"numbers":"all","today":"2026-10-18","start":"2026-09-19","end":"2026-10-18","apps":["MyFitnessPal"],"app":null,
         "days":[{"date":"2026-10-17","app":"MyFitnessPal","values":{"energy_kcal":2100},"otherApps":[]},
                 {"date":"2026-10-18","app":"MyFitnessPal","values":{"energy_kcal":"lots"},"otherApps":[]}]}
        """#
        let d = try JSONDecoder().decode(NutritionData.self, from: Data(json.utf8))
        XCTAssertEqual(d.days.map(\.date), ["2026-10-17"])
        XCTAssertNil(d.targets)
        XCTAssertTrue(d.water.isEmpty && d.caffeine.isEmpty && d.insights.isEmpty)
        // Off: nothing to show, and no mode.
        let off = try JSONDecoder().decode(NutritionData.self, from: Data(#"{"enabled":false,"numbers":null,"today":"2026-10-18","start":"2026-10-18","end":"2026-10-18","apps":[],"app":null,"days":[]}"#.utf8))
        XCTAssertFalse(off.enabled)
    }

    private func status(_ settings: String) throws -> ServerStatus {
        try JSONDecoder().decode(ServerStatus.self, from: Data(#"{"hosted":false,"settings":\#(settings)}"#.utf8))
    }

    func testTheScreenShowsOnlyWhileNutritionIsOnWithAChoice() throws {
        let d = Dashboard()
        d.apply(status: try status(#"{"units":"metric","nutrition":true,"nutritionNumbers":"no_energy","nutritionTargets":{"energy_kcal":null,"protein_g":120,"water_ml":null}}"#))
        XCTAssertEqual(d.nutritionMode, .noEnergy)
        XCTAssertTrue(d.nutritionAvailable)
        XCTAssertEqual(d.status?.settings?.nutritionTargets, NutritionTargets(energy_kcal: nil, protein_g: 120, water_ml: nil))
        // Its own tab: a link to the "nutrition" page opens it.
        XCTAssertEqual(AppRoute(page: "nutrition")?.page.tab, .nutrition)

        // Turned off on the web: the tab offers to turn it on again.
        d.apply(status: try status(#"{"units":"metric","nutrition":false,"nutritionNumbers":"all"}"#))
        XCTAssertNil(d.nutritionMode)
        XCTAssertTrue(d.nutritionAvailable)

        // On without a choice yet, or a mode this build doesn't know: the screen stays off. An older server without
        // Nutrition can't turn it on at all.
        d.apply(status: try status(#"{"nutrition":true,"nutritionNumbers":null}"#))
        XCTAssertNil(d.nutritionMode)
        d.apply(status: try status(#"{"nutrition":true,"nutritionNumbers":"grams_only"}"#))
        XCTAssertNil(d.nutritionMode)
        d.apply(status: try status(#"{"units":"metric"}"#))
        XCTAssertNil(d.nutritionMode)
        XCTAssertFalse(d.nutritionAvailable)
    }

    func testTheChoicesAreTheWebsInItsOrder() {
        // CHOICES in src/pages/Nutrition.tsx: none is chosen in advance, and the server refuses "on" without one.
        XCTAssertEqual(NutritionChoice.all.map(\.mode), [.all, .noEnergy, .none])
        XCTAssertEqual(NutritionChoice.all.map(\.title), ["Everything", "Everything except calories", "No amounts"])
        XCTAssertEqual(NutritionChoice.all.map(\.text), [
            "Calories, protein, carbs, fat, fiber, sugar, sodium and drinks.",
            "The same, with no calories anywhere, Ask McFly included.",
            "No calories or nutrient amounts: only what you logged, and when.",
        ])
    }

    func testAnOddTargetsObjectDoesNotBlankTheSettings() throws {
        let s = try status(#"{"units":"imperial","nutrition":true,"nutritionNumbers":"all","nutritionTargets":"soon"}"#)
        XCTAssertEqual(s.settings?.units, "imperial")
        XCTAssertEqual(s.settings?.nutrition, true)
        XCTAssertNil(s.settings?.nutritionTargets)
    }

    func testTheWeekIsCalendarDaysAndAGapStaysAGap() throws {
        let data = try fixture("nutrition-all")
        let week = FoodMath.dates(to: data.end, count: 7)
        XCTAssertEqual(week, ["2026-10-13", "2026-10-14", "2026-10-15", "2026-10-16", "2026-10-17", "2026-10-18", "2026-10-19"])
        XCTAssertEqual(FoodMath.dates(from: data.start, to: data.end).count, 14)
        let energy = FoodMath.series("energy_kcal", week, data.days)
        // Oct 15 had nothing logged: nil, not 0.
        XCTAssertNil(energy.first { $0.date == "2026-10-15" }?.value)
        XCTAssertEqual(energy.compactMap(\.value).count, 6)
        XCTAssertEqual(FoodMath.last(energy)?.date, "2026-10-19")
        XCTAssertNil(FoodMath.last([.init(date: "2026-10-19", value: nil)]))
        let water = FoodMath.series(data.water, week)
        XCTAssertNil(water.first { $0.date == "2026-10-14" }?.value)
    }

    func testTheProteinChangeComparesLoggedDaysOnly() {
        func days(_ values: [Double?]) -> [FoodMath.DayValue] { values.enumerated().map { .init(date: Day.add("2026-10-01", $0.offset), value: $0.element) } }
        XCTAssertEqual(FoodMath.change(days([100, 110, nil, 120, nil, nil, nil]), days([90, 90, 90, nil, nil, nil, nil])), 20)
        XCTAssertNil(FoodMath.change(days([100, 110, nil, nil, nil, nil, nil]), days([90, 90, 90, 90, 90, 90, 90])), "two logged days aren't a week")
        XCTAssertNil(FoodMath.change(days([100, 100, 100]), days([90, 90, nil])))
        XCTAssertEqual(FoodMath.changeText(20), "+20 g a day vs the week before")
        XCTAssertEqual(FoodMath.changeText(-12.4), "−12 g a day vs the week before")
        XCTAssertEqual(FoodMath.changeText(0.6), "About the same as the week before")
    }

    func testWaterReadsAsGlassesAndAmounts() {
        XCTAssertEqual(FoodMath.glasses(1000), 4)
        XCTAssertEqual(FoodMath.glasses(1100), 4.5)
        XCTAssertEqual(FoodMath.glasses(1180), 4.5)
        XCTAssertEqual(FoodMath.glassesText(1500), "6")
        XCTAssertEqual(FoodMath.glassesText(1625), "6.5")
        XCTAssertEqual(FoodMath.water(750, units: .metric), "750 mL")
        XCTAssertEqual(FoodMath.water(1750, units: .metric), "1.8 L")
        XCTAssertEqual(FoodMath.water(2000, units: .imperial), "68 fl oz")
        XCTAssertEqual(FoodMath.glassSize(.imperial), "8.5 fl oz")
        XCTAssertEqual(FoodMath.amount("alcohol_drinks", 1), "1 drink")
        XCTAssertEqual(FoodMath.amount("alcohol_drinks", 2), "2 drinks")
        XCTAssertEqual(FoodMath.amount("energy_kcal", 2150), "2,150 kcal")
        XCTAssertEqual(FoodMath.amount("sodium_mg", 2476), "2,476 mg")
    }

    func testMacroBalanceIsAShareOfGramsOfWhatWasLogged() throws {
        let day = try XCTUnwrap(try fixture("nutrition-all").days.last)
        let parts = FoodMath.parts(day)
        XCTAssertEqual(parts.map(\.key), ["protein_g", "carbs_g", "fat_g"])
        XCTAssertEqual(parts.map(\.grams), [125, 210, 90])
        XCTAssertEqual(parts.map(\.percent), [29, 49, 21])
        let noFat = FoodDay(date: "2026-10-19", app: "X", values: ["protein_g": 30, "carbs_g": 90], otherApps: [])
        XCTAssertEqual(FoodMath.parts(noFat).map(\.percent), [25, 75])
        XCTAssertTrue(FoodMath.parts(FoodDay(date: "2026-10-19", app: "X", values: ["energy_kcal": 900], otherApps: [])).isEmpty)
    }

    func testNoAmountsMeansOnlyTheOverviewAndTheLog() {
        // The web's tabs: Overview, Log, Macros, Hydration; with no amounts, Overview and Log.
        XCTAssertEqual(NutritionTab.visible(.none), [.overview, .log])
        XCTAssertEqual(NutritionTab.visible(.noEnergy), [.overview, .log, .macros, .hydration])
        XCTAssertEqual(NutritionTab.visible(.all), [.overview, .log, .macros, .hydration])
        // A server without the food log (404): no Log tab.
        XCTAssertEqual(NutritionTab.visible(.all, logging: false), [.overview, .macros, .hydration])
        XCTAssertEqual(NutritionTab.visible(.none, logging: false), [.overview])
    }

    func testTargetRangesAreTheServers() {
        // TARGET_RANGE in server/query.ts: a value outside is left as it was there, so the app refuses it first.
        XCTAssertEqual(NutritionTargetField.all.map(\.key), ["energy_kcal", "protein_g", "water_ml"])
        XCTAssertEqual(NutritionTargetField.all.map(\.range), [500...10_000, 10...500, 250...8_000])
    }
}
