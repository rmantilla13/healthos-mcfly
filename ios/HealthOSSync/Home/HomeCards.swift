import Foundation

/// Home's cards in this app (shared/cards.ts page 'home'): every one the web's Home has, so Profile → Cards says each
/// shows on Home. The rows' orders are Home.tsx's.
enum HomeCards {
    static let places: [String: CardPlace] = [
        "home.rhr": .home,
        "home.spo2": .home,
        "home.hrv": .home,
        "home.sleep": .home,
        "home.readiness": .home,
        "home.resp": .home,
        "home.nutrition": .home,
        "home.journal": .home,
        "home.week": .home,
        // Today's timeline, and with it the figure's heart following its marker.
        "home.timeline": .home,
        "home.insights": .home,
        "home.load": .home,
        "home.activity": .home,
        // Only with Nutrition on.
        "home.food": .home,
    ]

    /// The signal cards, the first row (Home.tsx `home-signals`).
    static let signals = Signal.ids
    /// Today's nutrition and Your health journal, the pair under them (`home-lower`).
    static let lower = ["home.nutrition", "home.journal"]
    /// The optional row: strain or active energy, activity, and food totals with Nutrition on.
    static let optionalRow = ["home.load", "home.activity", "home.food"]
}
