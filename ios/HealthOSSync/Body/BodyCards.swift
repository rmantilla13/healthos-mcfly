import Foundation

/// Body's cards in this app (shared/cards.ts page 'body'), all on the Body page's Overview: the figure, the three
/// measurements (one switch, body.composition), the story, and "From your devices". Profile → Cards says "Body ·
/// Overview" for each.
enum BodyCards {
    static let ids = ["body.figure", "body.composition", "body.story", "body.rhr", "body.hrv", "body.strain", "body.recovery", "body.heart",
                      "body.metrics", "body.energy", "body.steps", "body.workout", "body.glucose", "body.biomarkers"]

    static let places: [String: CardPlace] = Dictionary(uniqueKeysWithValues: ids.map { ($0, CardPlace(.body, tab: "overview")) })
}
