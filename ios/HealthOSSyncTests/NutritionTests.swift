import HealthKit
import XCTest
@testable import HealthOSSync

/// Food totals read from Health. These mirror the server's test/nutrition.test.ts: the importer's per-app day
/// (MyFitnessPal's correlated breakfast counted once, Cronometer's other units), what the ingest validates, the
/// payload shape, and nothing read while Nutrition is off.
final class NutritionTests: XCTestCase {
    private let names = NutritionTypes.all.map(\.name)

    private func food(_ id: String, _ app: String, _ nutrient: String, _ value: Double, on date: String = "2026-10-01") -> FoodSample {
        FoodSample(id: id, date: date, app: app, nutrient: nutrient, value: value)
    }

    /// A Health amount in another unit, read as the nutrient's own (kJ as kcal, and so on).
    private func amount(_ value: Double, _ unit: String, as name: String) -> Double {
        NutritionFolder.value(HKQuantity(unit: HKUnit(from: unit), doubleValue: value), as: NutritionTypes.nutrient(named: name)!)
    }

    private var energy: String { NutritionTypes.energy.identifier }

    func testTheNutrientsAndLimitsAreTheServers() {
        // NUTRIENTS and MAX in server/nutrition.ts, in the order they're shown.
        XCTAssertEqual(names, ["energy_kcal", "protein_g", "carbs_g", "fat_g", "fiber_g", "sugar_g", "sat_fat_g", "sodium_mg", "alcohol_drinks"])
        XCTAssertEqual(NutritionTypes.all.map(\.max), [30_000, 2_000, 3_000, 2_000, 500, 2_000, 1_000, 50_000, 100])
        XCTAssertEqual(NutritionTypes.all.map(\.identifier), [
            .dietaryEnergyConsumed, .dietaryProtein, .dietaryCarbohydrates, .dietaryFatTotal, .dietaryFiber, .dietarySugar,
            .dietaryFatSaturated, .dietarySodium, .numberOfAlcoholicBeverages,
        ])
    }

    func testEachAppKeepsItsOwnTotalsAndACorrelatedMealCountsOnce() {
        // The importer test's day: MyFitnessPal's breakfast is a Food correlation (its two samples seen again inside it)
        // plus a lunch; Cronometer logs energy in kJ, sodium in g, fiber in mg, and two drinks.
        let breakfast = [food("mfp-1", "MyFitnessPal", "energy_kcal", 500), food("mfp-2", "MyFitnessPal", "protein_g", 30)]
        let samples = breakfast + breakfast + [
            food("mfp-3", "MyFitnessPal", "energy_kcal", 700),
            food("cr-1", "Cronometer", "energy_kcal", amount(4184, "kJ", as: "energy_kcal")),
            food("cr-2", "Cronometer", "sodium_mg", amount(1.2, "g", as: "sodium_mg")),
            food("cr-3", "Cronometer", "fiber_g", amount(2500, "mg", as: "fiber_g")),
            food("cr-4", "Cronometer", "alcohol_drinks", amount(2, "count", as: "alcohol_drinks")),
        ]
        XCTAssertEqual(NutritionFolder.fold(samples, dates: ["2026-10-01"]), [
            NutritionDay(date: "2026-10-01", apps: [
                NutritionApp(app: "Cronometer", values: ["alcohol_drinks": 2, "energy_kcal": 1000, "fiber_g": 2.5, "sodium_mg": 1200]),
                NutritionApp(app: "MyFitnessPal", values: ["energy_kcal": 1200, "protein_g": 30]),
            ]),
        ])
    }

    func testAppsThatCopyEachOtherStaySeparateForTheServerToPickOne() {
        // The ingest test's last day: Lose It! copied MyFitnessPal's energy through Health. Never summed here.
        let samples = [
            food("a", "MyFitnessPal", "energy_kcal", 1200), food("b", "MyFitnessPal", "energy_kcal", 860), food("c", "MyFitnessPal", "protein_g", 106),
            food("d", "Lose It!", "energy_kcal", 2060),
        ]
        XCTAssertEqual(NutritionFolder.fold(samples, dates: ["2026-10-01"]).first?.apps, [
            NutritionApp(app: "Lose It!", values: ["energy_kcal": 2060]),
            NutritionApp(app: "MyFitnessPal", values: ["energy_kcal": 2060, "protein_g": 106]),
        ])
    }

    func testValuesTheServerWouldRefuseNeverLeaveThePhone() {
        // One refused value fails a whole push, daily rows and all, and the window would stay pending for good.
        let samples = [
            food("1", " Cronometer ", "energy_kcal", 1800),
            food("2", " Cronometer ", "fiber_g", 31),
            food("3", "Cronometer", "protein_g", -4),
            food("4", "Cronometer", "carbs_g", .nan),
            food("5", "Cronometer", "vitamin_secret", 3),
            food("6", "Broken", "energy_kcal", 2_100_000),
            // Fine one at a time, over the cap together: a unit mix-up, not a meal.
            food("7", "Doubled", "sodium_mg", 30_000), food("8", "Doubled", "sodium_mg", 30_000), food("9", "Doubled", "protein_g", 120),
            food("10", "   ", "energy_kcal", 400),
            food("11", String(repeating: "x", count: 150), "energy_kcal", 300),
        ]
        XCTAssertEqual(NutritionFolder.fold(samples, dates: ["2026-10-01"]).first?.apps, [
            NutritionApp(app: "Cronometer", values: ["energy_kcal": 1800, "fiber_g": 31]),
            NutritionApp(app: "Doubled", values: ["protein_g": 120]),
            NutritionApp(app: "unknown", values: ["energy_kcal": 400]),
            NutritionApp(app: String(repeating: "x", count: 100), values: ["energy_kcal": 300]),
        ])

        // At most 20 apps a day: the ones most likely to be picked (the most energy) stay.
        let many = (1...25).map { food("app-\($0)", "App \($0)", "energy_kcal", Double($0) * 100) }
        let kept = NutritionFolder.fold(many, dates: ["2026-10-01"]).first?.apps.map(\.app) ?? []
        XCTAssertEqual(kept.count, 20)
        XCTAssertEqual(Set(kept), Set((6...25).map { "App \($0)" }))
    }

    func testOnlyADayWhereFoodWasDeletedGoesUpEmpty() {
        // Health reads as empty when food access is off, so an empty day clears the server's only after a deletion.
        let samples = [food("1", "Yazio", "energy_kcal", 1900, on: "2026-10-01"), food("2", "Yazio", "energy_kcal", 500, on: "2026-09-29")]
        let days = NutritionFolder.fold(samples, dates: ["2026-10-01", "2026-10-02", "2026-10-03"], clearing: ["2026-10-01", "2026-10-02", "2026-10-09"])
        XCTAssertEqual(days, [
            NutritionDay(date: "2026-10-01", apps: [NutritionApp(app: "Yazio", values: ["energy_kcal": 1900])]),
            NutritionDay(date: "2026-10-02", apps: []),
        ], "the padded read's 09-29 and the clear outside the window are left out")
    }

    func testThePayloadIsWhatTheIngestTakes() throws {
        var payload = IngestPayload()
        func json() throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any]) }
        XCTAssertNil(try json()["nutrition"], "no key at all unless food is sent")

        payload.nutrition = [
            NutritionDay(date: "2026-10-17", apps: [NutritionApp(app: "MyFitnessPal", values: ["energy_kcal": 2060, "protein_g": 106])]),
            NutritionDay(date: "2026-10-16", apps: []),
        ]
        let days = try XCTUnwrap(try json()["nutrition"] as? [[String: Any]])
        XCTAssertEqual(days.count, 2)
        XCTAssertEqual(Set(days[0].keys), ["date", "apps"])
        XCTAssertEqual(days[0]["date"] as? String, "2026-10-17")
        let apps = try XCTUnwrap(days[0]["apps"] as? [[String: Any]])
        XCTAssertEqual(Set(apps[0].keys), ["app", "values"])
        XCTAssertEqual(apps[0]["app"] as? String, "MyFitnessPal")
        XCTAssertEqual(apps[0]["values"] as? [String: Double], ["energy_kcal": 2060, "protein_g": 106])
        XCTAssertEqual((days[1]["apps"] as? [Any])?.count, 0, "a day with no apps clears it")
        // Food isn't counted in the sync summary's rows.
        XCTAssertEqual(payload.rowCount, 0)
    }

    private var foodPayload: IngestPayload {
        var payload = IngestPayload()
        payload.daily = [DailyRow(date: "2026-10-17", metric: "steps", value: 9000)]
        payload.nutrition = [
            NutritionDay(date: "2026-10-15", apps: [NutritionApp(app: "Untappd", values: ["alcohol_drinks": 2])]),
            NutritionDay(date: "2026-10-16", apps: []),
            NutritionDay(date: "2026-10-17", apps: [
                NutritionApp(app: "MyFitnessPal", values: ["energy_kcal": 2100, "protein_g": 90, "alcohol_drinks": 1]),
                NutritionApp(app: "Untappd", values: ["alcohol_drinks": 1]),
            ]),
        ]
        return payload
    }

    func testFoodGoesOnlyToAServerThatTakesItWhileNutritionIsOn() {
        var state = SyncState(server: "https://health.mcfly.bot")
        XCTAssertNil(state.filtered(foodPayload).nutrition, "a fresh install: off")
        state.noteNutrition(nil, on: true)
        XCTAssertNil(state.filtered(foodPayload).nutrition, "a server that doesn't list nutrients gets none")
        state.noteNutrition(names, on: false)
        XCTAssertNil(state.filtered(foodPayload).nutrition, "off")
        state.noteNutrition(names, on: true)
        XCTAssertEqual(state.filtered(foodPayload).nutrition, foodPayload.nutrition)
        XCTAssertEqual(state.filtered(foodPayload).daily, foodPayload.daily)

        // A server that takes fewer nutrients: the others go, and a day left with nothing is skipped, not cleared.
        state.noteNutrition(["energy_kcal", "protein_g"], on: true)
        XCTAssertEqual(state.filtered(foodPayload).nutrition, [
            NutritionDay(date: "2026-10-16", apps: []),
            NutritionDay(date: "2026-10-17", apps: [NutritionApp(app: "MyFitnessPal", values: ["energy_kcal": 2100, "protein_g": 90])]),
        ])
    }

    func testTurningNutritionOnReadsHistoryAndOffForgetsWhereItStopped() throws {
        var state = SyncState(server: "https://health.mcfly.bot")
        for type in HealthTypes.sampleTypes(food: NutritionTypes.all) { state.anchors[type.identifier] = Data([1]) }
        let steps = HKQuantityType(.stepCount).identifier, sugar = HKQuantityType(.dietarySugar).identifier
        func foodAnchors() -> [Data?] { NutritionTypes.types.map { state.anchors[$0.identifier] } }

        // A server with Nutrition, still off: no food type is read, and no food anchor is kept.
        XCTAssertFalse(state.noteNutrition(names, on: false))
        XCTAssertEqual(foodAnchors(), Array(repeating: nil, count: 9))
        XCTAssertEqual(state.anchors[steps], Data([1]))

        // Turned on: every food type is read from no anchor, so its whole history goes up.
        XCTAssertTrue(state.noteNutrition(names, on: true))
        XCTAssertEqual(state.foodNutrients.map(\.name), names)
        XCTAssertEqual(foodAnchors(), Array(repeating: nil, count: 9))
        for type in NutritionTypes.types { state.anchors[type.identifier] = Data([2]) }
        XCTAssertFalse(state.noteNutrition(names, on: true), "still on: where reading stopped is kept")
        XCTAssertEqual(state.anchors[energy], Data([2]))

        // A nutrient the server stops taking isn't read; if it takes it again, its history goes up again.
        XCTAssertTrue(state.noteNutrition(names.filter { $0 != "sugar_g" }, on: true))
        XCTAssertNil(state.anchors[sugar])
        XCTAssertEqual(state.anchors[energy], Data([2]))

        // Off: nothing read, nothing kept, no clear left to send. Everything else is untouched.
        state.nutritionClear = ["2026-10-16"]
        XCTAssertTrue(state.noteNutrition(names, on: false))
        XCTAssertEqual(foodAnchors(), Array(repeating: nil, count: 9))
        XCTAssertEqual(state.nutritionClear, [])
        XCTAssertEqual(state.anchors[steps], Data([1]))
        XCTAssertTrue(state.foodNutrients.isEmpty)

        // Saved with the rest of the sync state; files from older builds have none of it.
        state.noteNutrition(names, on: true)
        state.nutritionClear = ["2026-10-16"]
        let decoded = try JSONDecoder().decode(SyncState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded.acceptedNutrients, names)
        XCTAssertTrue(decoded.nutritionOn)
        XCTAssertEqual(decoded.nutritionClear, ["2026-10-16"])
        let old = try JSONDecoder().decode(SyncState.self, from: Data(#"{"server":"https://health.mcfly.bot","pending":[]}"#.utf8))
        XCTAssertNil(old.acceptedNutrients)
        XCTAssertFalse(old.nutritionOn)
        XCTAssertEqual(old.nutritionClear, [])
    }

    func testNoFoodTypeIsReadAskedAboutOrObservedWhileOff() {
        let food = Set(NutritionTypes.types)
        XCTAssertTrue(Set(HealthTypes.sampleTypes(food: [])).isDisjoint(with: food))
        XCTAssertTrue(Set(HealthTypes.observedTypes(food: [])).isDisjoint(with: food))
        XCTAssertTrue(SyncState().foodNutrients.isEmpty)

        // On: all nine are read (and asked about), and only energy wakes the app.
        XCTAssertEqual(Set(HealthTypes.sampleTypes(food: NutritionTypes.all)).intersection(food), food)
        XCTAssertEqual(HealthTypes.observedTypes(food: NutritionTypes.all).filter { food.contains($0) }, [NutritionTypes.energy as HKSampleType])
        XCTAssertEqual(HealthTypes.label(NutritionTypes.energy), "food energy")
        XCTAssertEqual(HealthTypes.label(HKQuantityType(.numberOfAlcoholicBeverages)), "alcoholic drinks")
    }

    func testCaffeineAndWaterStayDailyMetricsAndTheAppNeverWritesFood() {
        let food = Set(NutritionTypes.all.map(\.identifier))
        XCTAssertTrue(HealthTypes.quantities.allSatisfy { !food.contains($0.identifier) }, "no nutrient is a daily metric")
        XCTAssertEqual(HealthTypes.quantities.first { $0.metric == "caffeine_mg" }?.aggregation, .sumAll)
        XCTAssertEqual(HealthTypes.quantities.first { $0.metric == "water_ml" }?.aggregation, .sumAll)
        XCTAssertTrue(SampleData.shareTypes.isDisjoint(with: NutritionTypes.types))
    }

    /// An ingest endpoint that takes only some nutrients, refusing the whole request otherwise like server/nutrition.ts.
    private final class FoodServer {
        let takes: Set<String>
        var sent: [[String]] = []
        init(takes: Set<String>) { self.takes = takes }

        func send(_ payload: IngestPayload) throws -> IngestClient.Response {
            let keys = (payload.nutrition ?? []).flatMap { $0.apps.flatMap(\.values.keys) }
            sent.append(Set(keys).sorted())
            if !Set(keys).isSubset(of: takes) {
                throw IngestClient.Rejected(status: 400, detail: "nutrition[0].apps[0].values: unknown nutrient; expected \(takes.sorted().joined(separator: ", "))")
            }
            return IngestClient.Response(daily: payload.daily.count, workouts: 0, events: 0, hourly: 0, cycle: 0, sleepStages: 0, metrics: nil,
                                         nutrients: takes.sorted(), nutritionOn: true, nutrition: payload.nutrition?.count ?? 0)
        }
    }

    func testANutrientTheServerRefusesIsLeftOutAfterAskingAgain() async throws {
        var state = SyncState(server: "https://health.mcfly.bot")
        state.noteNutrition(names, on: true)
        let server = FoodServer(takes: Set(names).subtracting(["alcohol_drinks"]))
        let (reply, _) = try await state.push(foodPayload) { try server.send($0) }
        XCTAssertEqual(server.sent, [["alcohol_drinks", "energy_kcal", "protein_g"], [], ["energy_kcal", "protein_g"]])
        XCTAssertEqual(reply.nutrition, 2)
        XCTAssertEqual(state.acceptedNutrients, server.takes.sorted())
        XCTAssertTrue(IngestClient.Rejected(status: 400, detail: "nutrition[0].apps[0].values: unknown nutrient; expected energy_kcal").unknownNutrient)
        XCTAssertFalse(IngestClient.Rejected(status: 400, detail: "nutrition[0].apps[0].values.energy_kcal: expected a number from 0 to 30000").unknownNutrient)
    }
}
