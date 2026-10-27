import Foundation

/// Body's cards in this app (shared/cards.ts page 'body'). The Body overview (the figure, measurements, heart,
/// recovery, strain, movement, the latest workout and lab results) isn't built here yet, so none shows: every Body
/// card changes the web dashboard only. A card on a tab of Body goes on that tab (`CardPlace(.body, tab: "overview")`).
enum BodyCards {
    static let places: [String: CardPlace] = [:]
}
