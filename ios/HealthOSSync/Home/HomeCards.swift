import Foundation

/// Home's cards in this app (shared/cards.ts page 'home'): the ones it shows, which Profile → Cards says show on
/// Home, and the grid's order. A Home card missing here changes the web dashboard only.
enum HomeCards {
    static let places: [String: CardPlace] = [
        "home.spo2": .home,
        "home.hrv": .home,
        "home.sleep": .home,
        "home.readiness": .home,
        "home.week": .home,
        // Today's path, and with it the portrait's heart following its marker.
        "home.timeline": .home,
        "home.insights": .home,
        "home.load": .home,
        "home.activity": .home,
    ]
}

extension Cards {
    /// Home's metric cards, in the grid's order (the first row of the web's Home page).
    static let todayGrid = ["home.readiness", "home.spo2", "home.hrv", "home.sleep", "home.load", "home.activity"]
}
