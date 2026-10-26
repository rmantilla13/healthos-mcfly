import SwiftUI

/// What Home reads beside its summary for two of its cards: the food totals (GET /api/nutrition?days=7, Nutrition.tsx
/// NutritionCard) and today's check-ins (GET /api/journal?days=1, JournalPrompt.tsx). Home reads them from its scroll view,
/// which is always there, and hands each card what came. A card can't read for itself: while it has nothing to show it
/// isn't drawn, and a `.task` on a view that isn't drawn never runs, so it would never get anything to show. The figure
/// tries a cut-out that couldn't be loaded again the same way. The reads are closures so the tests can count them.
struct HomeReads {
    var readFood: @MainActor (Dashboard) async throws -> NutritionData?
    var readJournal: @MainActor (Dashboard) async throws -> JournalData?
    /// The photo's cut-out, graded for the theme (ProfileImages, cached in memory once read); nil when it can't be loaded
    /// now, offline say.
    var readCutout: @MainActor (PhotoMeta, _ dark: Bool) async -> UIImage?

    static var live: HomeReads {
        HomeReads(readFood: { try await $0.nutrition(days: 7) }, readJournal: { try await $0.journal(days: 1) },
                  readCutout: { photo, dark in await ProfileImages.image(.cutout, version: photo.versionKey, dark: dark) })
    }

    /// The food totals card's data. Nothing is asked for while the card is off (Nutrition off, or Food not ticked in
    /// Edit widgets). nil hides the card: Nutrition off, a server without it, or a read that failed, as on the web,
    /// where the card shows only once its read has come.
    @MainActor func food(wanted: Bool, dashboard: Dashboard) async -> NutritionData? {
        guard wanted else { return nil }
        return try? await readFood(dashboard)
    }

    /// The journal card after a read: today's latest check-in (or none yet), or `.missing` when the server has no
    /// journal (an older one), which hides the card. Nothing is asked for while the card is hidden, and a read that
    /// fails (offline, a server error) leaves the card as it was.
    @MainActor func journal(wanted: Bool, current: JournalCard, dashboard: Dashboard) async -> JournalCard {
        guard wanted else { return current }
        do {
            guard let data = try await readJournal(dashboard) else { return .missing }
            return .read(data.todays.first)
        } catch {
            return current
        }
    }
}

/// Where Home's journal card stands. What's read is held in memory only, for the card, never kept on disk or logged.
enum JournalCard {
    /// Not read yet: the invitation shows, as on the web while it reads.
    case reading
    /// The server has no journal: no card.
    case missing
    /// Read: today's latest check-in, or nil before the first one.
    case read(JournalEntry?)

    var shows: Bool {
        if case .missing = self { return false }
        return true
    }

    var latest: JournalEntry? {
        if case .read(let entry) = self { return entry }
        return nil
    }
}

private struct HomeReadsKey: EnvironmentKey {
    static var defaultValue: HomeReads { .live }
}

extension EnvironmentValues {
    /// Home's reads for its food totals and journal cards; tests put their own in.
    var homeReads: HomeReads {
        get { self[HomeReadsKey.self] }
        set { self[HomeReadsKey.self] = newValue }
    }
}
