import Foundation
import Observation
import SwiftUI

/// Reviewing McFly's draft (useEstimateReview in src/pages/FoodLog.tsx): rename, change how many or the time, or leave
/// items out, then save what's left (or discard it all). Nothing counts until then. Today's conversation and the Log
/// tab each draw it their own way. Saving or discarding names its estimate (batch), so a newer one made on another
/// device is left alone.
@MainActor
@Observable
final class EstimateReview {
    /// One item still in: its name and how many, as typed.
    struct Kept: Identifiable, Equatable {
        let id: String
        var name: String
        var quantity: String
    }

    /// The writes a review makes, so tests can check what it sends.
    struct Writes {
        /// PATCH /api/nutrition/log/:id on a draft (never written to Health: it doesn't count yet).
        var change: (FoodEntry, [String: Any]) async throws -> Void
        /// POST /api/nutrition/log/save: the entries saved.
        var save: (String, [String]) async throws -> [FoodEntry]
        /// POST /api/nutrition/log/discard.
        var discard: (String) async throws -> Void

        @MainActor static func dashboard(_ d: Dashboard) -> Writes {
            Writes(change: { entry, body in try await d.changeFood(entry, body, draft: true) },
                   save: { batch, ids in try await d.saveDrafts(batch: batch, ids: ids) },
                   discard: { batch in try await d.discardDrafts(batch: batch) })
        }
    }

    let drafts: [FoodEntry]
    let batch: String
    var kept: [Kept]
    /// "HH:MM", for all of them.
    var time: String
    private(set) var busy = false
    private(set) var error: String?

    init(drafts: [FoodEntry], batch: String) {
        self.drafts = drafts
        self.batch = batch
        kept = drafts.map { Kept(id: $0.id, name: $0.name, quantity: FoodText.quantityText($0.quantity)) }
        time = drafts.first?.time ?? "12:00"
    }

    var byID: [String: FoodEntry] { Dictionary(drafts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }) }

    func leaveOut(_ id: String) { kept.removeAll { $0.id == id } }

    /// One kept item's name or how many, for its field; nothing once it's left out.
    func binding(_ id: String, _ key: WritableKeyPath<Kept, String>) -> Binding<String> {
        Binding(get: { self.kept.first { $0.id == id }?[keyPath: key] ?? "" },
                set: { v in if let i = self.kept.firstIndex(where: { $0.id == id }) { self.kept[i][keyPath: key] = v } })
    }

    /// "Save 1 item", "Save 3 items", "Saving…".
    var saveTitle: String { busy ? "Saving…" : kept.count == 1 ? "Save 1 item" : "Save \(kept.count) items" }

    /// An item's amounts at the quantity typed, as the setting shows them ("" with no amounts, or no usable quantity).
    func line(_ k: Kept, mode: NutritionMode, units: Units) -> String {
        guard mode != .none, let d = byID[k.id], let q = foodQuantity(k.quantity), d.quantity > 0 else { return "" }
        return FoodText.amounts(FoodText.scaled(d.values, by: q / d.quantity), units: units)
    }

    /// The kept items added up at the quantities typed, when there's more than one ("Altogether …").
    func altogether(mode: NutritionMode, units: Units) -> String {
        guard mode != .none, kept.count > 1 else { return "" }
        let ids = byID
        var total: [String: Double] = [:]
        for k in kept {
            guard let d = ids[k.id], let q = foodQuantity(k.quantity), d.quantity > 0 else { continue }
            for (key, v) in FoodText.scaled(d.values, by: q / d.quantity) { total[key, default: 0] += v }
        }
        return FoodText.amounts(total, units: units)
    }

    /// Only what changed on one draft; throws the server's own words for a name or amount it would refuse.
    static func patch(_ d: FoodEntry, _ k: Kept, time: String) throws -> [String: Any] {
        var patch: [String: Any] = [:]
        let name = k.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { throw FoodError("Give it a name.") }
        if name != d.name { patch["name"] = name }
        guard let q = foodQuantity(k.quantity) else { throw FoodError("Choose an amount above 0 and up to 50.") }
        if q != d.quantity { patch["quantity"] = q }
        if !time.isEmpty, time != d.time { patch["time"] = time }
        return patch
    }

    /// Saves what's kept, as reviewed; the number saved, or nil when it couldn't be (the error says why).
    func save(_ writes: Writes) async -> Int? {
        busy = true
        error = nil
        defer { busy = false }
        do {
            let ids = byID
            for k in kept {
                guard let d = ids[k.id] else { continue }
                let patch = try Self.patch(d, k, time: time)
                if !patch.isEmpty { try await writes.change(d, patch) }
            }
            return try await writes.save(batch, kept.map(\.id)).count
        } catch {
            if !APIClient.isCancellation(error) { self.error = error.foodMessage }
            return nil
        }
    }

    /// Throws the estimate away; true once it's gone.
    func discard(_ writes: Writes) async -> Bool {
        busy = true
        error = nil
        defer { busy = false }
        do {
            try await writes.discard(batch)
            return true
        } catch {
            if !APIClient.isCancellation(error) { self.error = error.foodMessage }
            return false
        }
    }
}
