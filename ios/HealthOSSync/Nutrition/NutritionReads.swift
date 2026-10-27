import SwiftUI

/// What Nutrition's views read from the server: Today's day (POST /api/nutrition/log/day), the totals over a range
/// (GET /api/nutrition) and the Log's days (GET /api/nutrition/log). Each view reads from the view that builds its page
/// (above the panes the open iPhone Duo swaps on a fold, P4), so a fold never reads again. They're closures so the tests
/// can hand made-up answers in and count the reads.
struct NutritionReads {
    var day: @MainActor (Dashboard, _ date: String?) async throws -> FoodLogDay?
    var totals: @MainActor (Dashboard, _ days: Int, _ insights: Bool) async throws -> NutritionData?
    var log: @MainActor (Dashboard, _ days: Int) async throws -> FoodLog?

    static var live: NutritionReads {
        NutritionReads(day: { try await $0.loadFoodLogDay(date: $1) },
                       totals: { try await $0.nutrition(days: $1, insights: $2) },
                       log: { try await $0.loadFoodLog(days: $1) })
    }
}

private struct NutritionReadsKey: EnvironmentKey {
    static var defaultValue: NutritionReads { .live }
}

extension EnvironmentValues {
    /// Nutrition's reads; tests put their own in.
    var nutritionReads: NutritionReads {
        get { self[NutritionReadsKey.self] }
        set { self[NutritionReadsKey.self] = newValue }
    }
}
