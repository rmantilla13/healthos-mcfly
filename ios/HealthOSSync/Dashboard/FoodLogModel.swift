import Foundation

/// The food log's reads and writes, and keeping Apple Health in step with them. Every change reloads what the other
/// Nutrition tabs show: healthOS's log is one of the apps a day's totals are picked from.
extension Dashboard {
    /// The last `days` days of the log; nil from a server without it (the Log tab then hides).
    func loadFoodLog(days: Int = 14) async throws -> FoodLog? {
        let log = try await fetch { try await $0.foodLog(days: days) }
        foodLogAvailable = log != nil
        return log
    }

    /// Asks once per server whether it has the food log, so the Log tab shows only where it works.
    func probeFoodLog() async {
        guard foodLogAvailable == nil, nutritionOn else { return }
        _ = try? await loadFoodLog(days: 1)
    }

    /// A new entry: written to Health once saved (asking for write access the first time), then everything reloads.
    @discardableResult
    func addFood(_ body: [String: Any]) async throws -> FoodEntry {
        let entry = try await fetch { try await $0.addFood(body) }
        await FoodHealthStore.shared.write([entry], zone: timeZone, ask: true)
        await refreshIfChanged(includeStatus: false)
        return entry
    }

    /// `draft`: one of McFly's drafts under review, which never goes to Health until it's saved.
    @discardableResult
    func changeFood(_ entry: FoodEntry, _ body: [String: Any], draft: Bool = false) async throws -> FoodEntry {
        let changed = try await fetch { try await $0.changeFood(id: entry.id, body) }
        if changed.origin == "iphone", !draft {
            if FoodHealth.keys(changed).isEmpty { await FoodHealthStore.shared.remove([changed.id]) }
            else { await FoodHealthStore.shared.write([changed], zone: timeZone) }
        }
        await refreshIfChanged(includeStatus: false)
        return changed
    }

    func deleteFood(_ entry: FoodEntry) async throws {
        try await fetch { try await $0.deleteFood(id: entry.id) }
        await FoodHealthStore.shared.remove([entry.id])
        await refreshIfChanged(includeStatus: false)
    }

    /// Saves McFly's reviewed drafts (the rest are discarded); they count, and go to Health, from now on.
    func saveDrafts(ids: [String]) async throws {
        let saved = try await fetch { try await $0.saveDrafts(ids: ids) }
        await FoodHealthStore.shared.write(saved, zone: timeZone, ask: true)
        await refreshIfChanged(includeStatus: false)
    }

    func discardDrafts() async throws {
        try await fetch { try await $0.discardDrafts() }
    }

    func searchFoods(_ query: String) async throws -> FoodSearch { try await fetch { try await $0.searchFoods(query) } }

    func barcode(_ code: String) async throws -> FoodSearch { try await fetch { try await $0.barcode(code) } }

    func estimateFood(_ body: [String: Any]) async throws -> FoodEstimate { try await fetch { try await $0.estimateFood(body) } }

    /// Health in line with the last week of the log: edits made on the web rewritten, deletions taken out. On opening
    /// Nutrition and after a sync; at most once a minute unless `force`.
    func reconcileFoodHealth(force: Bool = false) async {
        guard nutritionOn, foodLogAvailable != false, let log = try? await loadFoodLog(days: 7) else { return }
        await FoodHealthStore.shared.reconcile(log, zone: timeZone, force: force)
    }
}
