import Foundation

/// Sleep's cards in this app (shared/cards.ts page 'sleep'), until the Sleep overview is built here: the ones the
/// Sleep page's charts show. A Sleep card missing here changes the web dashboard only.
enum SleepCards {
    static let places: [String: CardPlace] = [
        "sleep.total": .sleep,
        "sleep.score": .sleep,
        "sleep.efficiency": .sleep,
        "sleep.stages": .sleep,
    ]
}
