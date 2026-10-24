import SwiftUI

// The dashboard cards a person can hide (shared/cards.ts), and where this app shows each one. Cards are hidden in
// Settings → Cards, here or on the web, and the server keeps the lists for both (settings.hiddenCards in GET
// /api/status, and shownCards for the optional cards, which are off until turned on). Only layout: hiding a card
// changes what a screen shows, never what's stored.

/// The web dashboard's pages with cards to hide, named as its Settings names them.
enum CardPage: String, CaseIterable, Identifiable {
    case home, sleep, body, nutrition
    var id: String { rawValue }

    var label: String {
        switch self {
        case .home: "Home"
        case .sleep: "Sleep · Overview"
        case .body: "Body · Overview"
        case .nutrition: "Nutrition · Overview"
        }
    }
}

/// Where this app shows a card.
enum CardPlace: Equatable {
    case today
    case trends(TrendsSection)
    case nutrition

    var label: String {
        switch self {
        case .today: "Today"
        case .trends(let section): "Trends · \(section.rawValue)"
        case .nutrition: "Nutrition · Overview"
        }
    }
}

/// One card from the registry.
struct DashboardCard: Identifiable, Equatable {
    let id: String
    let page: CardPage
    let label: String
    /// Offered only to people with Nutrition on.
    var nutrition = false
    /// Off until the person turns it on (defaultHidden in shared/cards.ts).
    var optional = false
    /// Where this app shows it, and hides it; nil when only the web dashboard hides it.
    var place: CardPlace?
}

/// One page's cards in Settings.
struct CardGroup: Identifiable {
    let page: CardPage
    let cards: [DashboardCard]
    var id: CardPage { page }
}

enum Cards {
    /// shared/cards.ts CARDS, in its order (a test checks them against that file). Each card the app shows has its
    /// place; the rest still change the web dashboard. The Body overview's cards (heart, recovery, strain,
    /// movement, the latest workout and lab results) have no counterpart here.
    static let all: [DashboardCard] = [
        DashboardCard(id: "home.rhr", page: .home, label: "Resting heart rate"),
        DashboardCard(id: "home.spo2", page: .home, label: "Blood oxygen", place: .today),
        DashboardCard(id: "home.hrv", page: .home, label: "HRV", place: .today),
        DashboardCard(id: "home.sleep", page: .home, label: "Sleep", place: .today),
        // Recovery here, or VO₂ max without WHOOP; the id predates the card's name.
        DashboardCard(id: "home.readiness", page: .home, label: "Recovery", place: .today),
        DashboardCard(id: "home.resp", page: .home, label: "Respiratory rate"),
        DashboardCard(id: "home.nutrition", page: .home, label: "Today's nutrition"),
        DashboardCard(id: "home.journal", page: .home, label: "Your health journal"),
        DashboardCard(id: "home.week", page: .home, label: "Week so far", optional: true, place: .today),
        // Today's path, and with it the portrait's heart following its marker.
        DashboardCard(id: "home.timeline", page: .home, label: "Today's timeline", optional: true, place: .today),
        DashboardCard(id: "home.insights", page: .home, label: "Recent insights", optional: true, place: .today),
        DashboardCard(id: "home.load", page: .home, label: "Strain or active energy", optional: true, place: .today),
        DashboardCard(id: "home.activity", page: .home, label: "Activity", optional: true, place: .today),
        DashboardCard(id: "home.food", page: .home, label: "Food totals", nutrition: true, optional: true),
        DashboardCard(id: "sleep.total", page: .sleep, label: "Sleep", place: .trends(.sleep)),
        // WHOOP's sleep performance; efficiency has its own card.
        DashboardCard(id: "sleep.score", page: .sleep, label: "Sleep performance", place: .trends(.sleep)),
        DashboardCard(id: "sleep.efficiency", page: .sleep, label: "Sleep efficiency", place: .trends(.sleep)),
        DashboardCard(id: "sleep.rhr", page: .sleep, label: "Resting heart rate"),
        DashboardCard(id: "sleep.stages", page: .sleep, label: "Sleep stages", place: .trends(.sleep)),
        DashboardCard(id: "sleep.insights", page: .sleep, label: "Sleep insights"),
        DashboardCard(id: "sleep.timeline", page: .sleep, label: "Sleep timeline"),
        DashboardCard(id: "body.figure", page: .body, label: "Your figure"),
        DashboardCard(id: "body.composition", page: .body, label: "Weight, body fat and lean mass"),
        DashboardCard(id: "body.story", page: .body, label: "A picture of your progress"),
        DashboardCard(id: "body.rhr", page: .body, label: "Resting heart rate"),
        DashboardCard(id: "body.hrv", page: .body, label: "HRV"),
        DashboardCard(id: "body.strain", page: .body, label: "Strain"),
        DashboardCard(id: "body.recovery", page: .body, label: "Recovery"),
        DashboardCard(id: "body.heart", page: .body, label: "Heart rate today"),
        DashboardCard(id: "body.metrics", page: .body, label: "Body metrics"),
        DashboardCard(id: "body.energy", page: .body, label: "Energy burned"),
        DashboardCard(id: "body.steps", page: .body, label: "Activity level"),
        DashboardCard(id: "body.workout", page: .body, label: "Latest workout"),
        DashboardCard(id: "body.glucose", page: .body, label: "Glucose"),
        DashboardCard(id: "body.biomarkers", page: .body, label: "Key biomarkers"),
        DashboardCard(id: "nutrition.energy", page: .nutrition, label: "Energy", nutrition: true, place: .nutrition),
        DashboardCard(id: "nutrition.protein", page: .nutrition, label: "Protein", nutrition: true, place: .nutrition),
        DashboardCard(id: "nutrition.water", page: .nutrition, label: "Water", nutrition: true, place: .nutrition),
        DashboardCard(id: "nutrition.logged", page: .nutrition, label: "Days logged", nutrition: true, place: .nutrition),
        DashboardCard(id: "nutrition.macros", page: .nutrition, label: "Macro balance", nutrition: true, place: .nutrition),
        DashboardCard(id: "nutrition.insights", page: .nutrition, label: "Food insights", nutrition: true, place: .nutrition),
    ]

    /// The optional cards (shared/cards.ts OPTIONAL_CARDS): off until the person turns them on.
    static let optional: Set<String> = Set(all.filter(\.optional).map(\.id))

    /// Whether a card shows (shared/cards.ts cardShown): an optional card only once it's turned on, any other unless
    /// it's hidden. `shown` is nil from a server older than optional cards: there every card shows unless it's hidden.
    static func shows(_ id: String, hidden: [String], shown: [String]?) -> Bool {
        if let shown, optional.contains(id) { return shown.contains(id) }
        return !hidden.contains(id)
    }

    /// The cards that don't show, for the screens to leave out: the hidden ones, and the optional ones not turned on.
    static func off(hidden: [String], shown: [String]?) -> Set<String> {
        Set(hidden).union(all.map(\.id).filter { !shows($0, hidden: hidden, shown: shown) })
    }

    /// The hidden cards that are hidden from a default (shared/cards.ts hiddenDefaults). An optional card turned off is
    /// in the hidden list too (for older iPhone builds) without being hidden from a default. With `optionalCards`
    /// false (an older server, where no card is optional) every hidden card counts.
    static func hiddenDefaults(_ hidden: [String], optionalCards: Bool) -> [String] {
        optionalCards ? hidden.filter { !optional.contains($0) } : hidden
    }

    /// The hidden list Show all sends: every default card back on, the optional ones as they are. An optional card
    /// that's off can be in the list, and stays there; an older server has no optional cards, so it gets none.
    static func afterShowAll(_ hidden: [String], optionalCards: Bool) -> [String] {
        optionalCards ? hidden.filter { optional.contains($0) } : []
    }

    static func card(_ id: String) -> DashboardCard? { all.first { $0.id == id } }

    /// Today's metric cards, in the grid's order (the first row of the web's Home page).
    static let todayGrid = ["home.readiness", "home.spo2", "home.hrv", "home.sleep", "home.load", "home.activity"]

    /// The cards this app shows in one place, in the registry's order.
    static func ids(in place: CardPlace) -> [String] { all.filter { $0.place == place }.map(\.id) }

    /// The ids that show, in the order given: every one does except those off (`off(hidden:shown:)`).
    static func visible(_ ids: [String], hidden: Set<String>) -> [String] { ids.filter { !hidden.contains($0) } }

    /// Every card this app shows in `place` is off, so the screen says where to bring them back.
    static func allHidden(in place: CardPlace, hidden: Set<String>) -> Bool { allHidden(ids(in: place), hidden: hidden) }

    /// Every one of these cards is off (and there is one).
    static func allHidden(_ ids: [String], hidden: Set<String>) -> Bool { !ids.isEmpty && visible(ids, hidden: hidden).isEmpty }

    /// The cards Settings offers, by page: Nutrition's only to someone with it on, as on the web.
    static func pages(nutrition: Bool) -> [CardGroup] {
        CardPage.allCases.compactMap { page in
            let cards = all.filter { $0.page == page && (nutrition || !$0.nutrition) }
            return cards.isEmpty ? nil : CardGroup(page: page, cards: cards)
        }
    }

    /// The hidden cards Settings offers now, in the registry's order: no Nutrition card while Nutrition is off, no id
    /// this app doesn't know (a newer server's), and, with `optionalCards`, no optional card (off by default, not
    /// hidden). The Cards row counts these and Show all appears only for them, so the row never says "All shown"
    /// beside a Show all whose switches are all on.
    static func hiddenOffered(_ hidden: Set<String>, nutrition: Bool, optionalCards: Bool = false) -> [String] {
        pages(nutrition: nutrition).flatMap(\.cards).map(\.id).filter { hidden.contains($0) && !(optionalCards && optional.contains($0)) }
    }

    /// The Nutrition overview's cards one setting shows (src/pages/Nutrition.tsx Overview), hidden ones left out.
    struct NutritionCardLayout: Equatable {
        /// The fill row: Energy (only while calories show), protein, water and days logged.
        var row: [String]
        /// Macro balance and food insights side by side.
        var pair: [String]
        /// Every card this setting would show is hidden. Energy doesn't count while calories are hidden (it never
        /// appears then), and with no amounts the page keeps its note, so it's never all hidden.
        var allHidden: Bool
    }

    static func nutritionOverview(mode: NutritionMode, hidden: Set<String>) -> NutritionCardLayout {
        guard mode != .none else {
            return NutritionCardLayout(row: visible(["nutrition.logged"], hidden: hidden), pair: [], allHidden: false)
        }
        let row = (mode == .all ? ["nutrition.energy"] : []) + ["nutrition.protein", "nutrition.water", "nutrition.logged"]
        let pair = ["nutrition.macros", "nutrition.insights"]
        return NutritionCardLayout(row: visible(row, hidden: hidden), pair: visible(pair, hidden: hidden),
                                 allHidden: visible(row + pair, hidden: hidden).isEmpty)
    }

    /// One card shown or hidden, applied to a hidden list. Order and ids this app doesn't know are kept.
    static func toggled(_ hidden: [String], id: String, shown: Bool) -> [String] {
        if shown { return hidden.filter { $0 != id } }
        return hidden.contains(id) ? hidden : hidden + [id]
    }

    /// How many columns `n` cards take in a row of at most `max` (shared/cards.ts fillColumns): as few rows as fit,
    /// as even as they go, so 4 cards in a 3-up row are 2 × 2 rather than 3 + 1.
    static func fillColumns(_ n: Int, max: Int) -> Int {
        guard n > 1, max > 1 else { return 1 }
        let rows = (n + max - 1) / max
        return (n + rows - 1) / rows
    }

    /// The cards that show, in rows of `fillColumns` each. A short last row's cards share its whole width (the web's
    /// stretch rule), so hiding a card leaves no hole: an odd last card in a 2-up grid spans both columns.
    static func rows<T>(_ items: [T], max: Int) -> [[T]] {
        guard !items.isEmpty else { return [] }
        let columns = fillColumns(items.count, max: max)
        return stride(from: 0, to: items.count, by: columns).map { Array(items[$0..<Swift.min($0 + columns, items.count)]) }
    }
}

/// The two lists a person's cards are kept in: settings.hiddenCards, and shownCards for the optional ones.
struct CardLists: Equatable {
    var hidden: [String]
    /// nil from a server older than optional cards.
    var shown: [String]?
}

/// A change to the hidden cards, as PUT /api/settings takes it.
enum CardChange: Equatable {
    /// One card shown or hidden. The server applies it to the list as stored then, so a change made elsewhere
    /// meanwhile (the web, another phone, an admin) isn't undone.
    case card(String, shown: Bool)
    /// The whole list: Show all, and servers from before one-card changes.
    case list([String])

    var body: [String: Any] {
        switch self {
        case .card(let id, let shown):
            let change: [String: Any] = ["id": id, "shown": shown]
            return ["cardShown": change]
        case .list(let ids):
            return ["hiddenCards": ids]
        }
    }

    func applied(to hidden: [String]) -> [String] {
        switch self {
        case .card(let id, let shown): Cards.toggled(hidden, id: id, shown: shown)
        case .list(let ids): ids
        }
    }

    /// Both lists after this change, as the server's withCardToggled makes them: any card moves in or out of `hidden`,
    /// and an optional one in or out of `shown` too (once the server has that list).
    func applied(to lists: CardLists) -> CardLists {
        var next = CardLists(hidden: applied(to: lists.hidden), shown: lists.shown)
        if case .card(let id, let on) = self, let shown = lists.shown, Cards.optional.contains(id) {
            next.shown = on ? (shown.contains(id) ? shown : shown + [id]) : shown.filter { $0 != id }
        }
        return next
    }

    /// What to send again after the server answered with `stored`, its hidden list after this change. A server from
    /// before one-card changes ignores `cardShown` and answers with the list as it was: send the same change again
    /// as a whole list, built on the one it just answered with. nil when the change took (or there's nothing to retry).
    func retry(stored: [String]?) -> CardChange? {
        guard case .card(let id, let shown) = self, let stored, stored.contains(id) == shown else { return nil }
        return .list(applied(to: stored))
    }
}

/// Every card a screen can hide is hidden: say where to choose them again (the web's AllHiddenNote).
struct AllCardsHiddenNote: View {
    /// Today keeps cards that can't be hidden (the portrait and the day), so it doesn't say "all the cards".
    var text = "You've hidden every card you can choose here."
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        Button { dashboard.tab = .settings } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "rectangle.grid.2x2").font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ink3)
                    .accessibilityHidden(true)
                Text("\(text) Choose the ones to show in **Settings → Cards**.")
                    .font(.footnote)
                    .foregroundStyle(Palette.ink2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Palette.ink3)
                    .accessibilityHidden(true)
            }
            .card()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens Settings")
    }
}
