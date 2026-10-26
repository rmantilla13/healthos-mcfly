import XCTest
@testable import HealthOSSync

/// Profile's nutrition targets (slice D's SettingsScreen.swift, then its Nutrition settings sheet). Slice D owns this file.
final class ProfileTargetsTests: XCTestCase {
    func testTargetRangesAreTheServers() {
        // TARGET_RANGE in server/query.ts: a value outside is left as it was there, so the app refuses it first.
        XCTAssertEqual(NutritionTargetField.all.map(\.key), ["energy_kcal", "protein_g", "water_ml"])
        XCTAssertEqual(NutritionTargetField.all.map(\.range), [500...10_000, 10...500, 250...8_000])
    }
}
