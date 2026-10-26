import Foundation

/// Nutrition's cards in this app (shared/cards.ts page 'nutrition'): the overview's, which Profile → Cards says show
/// on Nutrition · Overview. Cards.nutritionOverview lays them out.
enum NutritionCards {
    static let places: [String: CardPlace] = [
        "nutrition.energy": .nutritionOverview,
        "nutrition.protein": .nutritionOverview,
        "nutrition.water": .nutritionOverview,
        "nutrition.logged": .nutritionOverview,
        "nutrition.macros": .nutritionOverview,
        "nutrition.insights": .nutritionOverview,
    ]
}
