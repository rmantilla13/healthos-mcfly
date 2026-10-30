import Foundation

/// Sleep's cards in this app (shared/cards.ts page 'sleep'): all seven are on the Sleep page's Overview, so Profile →
/// Cards says "Sleep" for each.
enum SleepCards {
    static let places: [String: CardPlace] = [
        "sleep.total": .sleep,
        "sleep.score": .sleep,
        "sleep.efficiency": .sleep,
        "sleep.rhr": .sleep,
        "sleep.stages": .sleep,
        "sleep.insights": .sleep,
        "sleep.timeline": .sleep,
    ]
}
