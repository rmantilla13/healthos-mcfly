import Foundation
import HealthKit

/// Food logged on this iPhone goes to Apple Health, and comes back from it only once.
///
/// - Written: entries made here (origin "iphone"), once saved, never drafts. One food correlation of the dietary samples
///   (water included) at the entry's local date and time, and alcohol as its own sample, which a correlation can't hold.
///   Every object carries the entry's sync identifier ("healthos.food.<id>"), its version and its name.
/// - Only the amounts the phone was sent: no calories in "no_energy", nothing at all in "none". The person chose not to
///   see those numbers, and Health would show them.
/// - Never read back: the sync skips every sample with that sync identifier (`isOurs`), food and water alike; the
///   server counts the log itself.
/// - HealthKit replaces a sample of the same type and sync identifier, but leaves a type the new version no longer has,
///   and deleting the correlation leaves its samples. So a rewrite first deletes everything with the entry's identifier.
enum FoodHealth {
    static let prefix = "healthos.food."

    static func syncID(_ entryID: String) -> String { prefix + entryID.lowercased() }

    /// One of ours: skipped wherever Health is read, so a logged meal or glass of water never counts twice.
    static func isOurs(_ metadata: [String: Any]?) -> Bool {
        (metadata?[HKMetadataKeySyncIdentifier] as? String)?.hasPrefix(prefix) == true
    }

    /// An entry's amount and the Health type it goes to.
    struct Kind {
        let key: String
        let identifier: HKQuantityTypeIdentifier
        let unit: HKUnit
        var type: HKQuantityType { HKQuantityType(identifier) }
    }

    static let kinds: [Kind] = [
        Kind(key: "energy_kcal", identifier: .dietaryEnergyConsumed, unit: .kilocalorie()),
        Kind(key: "protein_g", identifier: .dietaryProtein, unit: .gram()),
        Kind(key: "carbs_g", identifier: .dietaryCarbohydrates, unit: .gram()),
        Kind(key: "fat_g", identifier: .dietaryFatTotal, unit: .gram()),
        Kind(key: "fiber_g", identifier: .dietaryFiber, unit: .gram()),
        Kind(key: "sugar_g", identifier: .dietarySugar, unit: .gram()),
        Kind(key: "sat_fat_g", identifier: .dietaryFatSaturated, unit: .gram()),
        Kind(key: "sodium_mg", identifier: .dietarySodium, unit: .gramUnit(with: .milli)),
        Kind(key: "water_ml", identifier: .dietaryWater, unit: .literUnit(with: .milli)),
        Kind(key: "alcohol_drinks", identifier: .numberOfAlcoholicBeverages, unit: .count()),
    ]

    /// What this app asks to write, only when the first entry is saved here. Nothing else is ever written.
    static var shareTypes: Set<HKSampleType> { Set(kinds.map(\.type)) }

    /// The keys of an entry Health takes, sorted: what a copy in Health holds.
    static func keys(_ e: FoodEntry) -> [String] {
        kinds.map(\.key).filter { (e.values[$0] ?? 0) > 0 }
    }

    /// The moment an entry was logged: its local date and HH:MM in the person's time zone.
    static func date(_ e: FoodEntry, in zone: TimeZone) -> Date? {
        let d = e.date.split(separator: "-").compactMap { Int($0) }, t = e.time.split(separator: ":").compactMap { Int($0) }
        guard d.count == 3, t.count == 2 else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        return cal.date(from: DateComponents(year: d[0], month: d[1], day: d[2], hour: t[0], minute: t[1]))
    }

    /// The objects one entry becomes in Health: a food correlation of its dietary samples, and alcohol on its own.
    /// Empty when there's nothing to write (no amounts shown, or none Health takes). `allowed` says which types the
    /// person lets this app write; the rest are left out.
    static func objects(for e: FoodEntry, in zone: TimeZone, allowed: (HKQuantityType) -> Bool = { _ in true }) -> [HKObject] {
        guard let at = date(e, in: zone) else { return [] }
        let meta: [String: Any] = [
            HKMetadataKeyFoodType: e.name,
            HKMetadataKeySyncIdentifier: syncID(e.id),
            HKMetadataKeySyncVersion: e.version,
            HKMetadataKeyTimeZone: zone.identifier,
        ]
        var food = Set<HKSample>()
        var alone: [HKObject] = []
        for k in kinds where allowed(k.type) {
            guard let v = e.values[k.key], v.isFinite, v > 0 else { continue }
            let s = HKQuantitySample(type: k.type, quantity: HKQuantity(unit: k.unit, doubleValue: v), start: at, end: at, metadata: meta)
            if k.identifier == .numberOfAlcoholicBeverages { alone.append(s) } else { food.insert(s) }
        }
        let correlation: [HKObject] = food.isEmpty ? [] : [HKCorrelation(type: HKCorrelationType(.food), start: at, end: at, objects: food, metadata: meta)]
        return correlation + alone
    }

    /// What this phone wrote for one entry: enough to tell when Health's copy is out of date, and which day it's on.
    struct Written: Codable, Equatable {
        var version: Int
        var date: String
        var keys: [String]
    }

    /// The entries to write (new here, edited anywhere, or shown with different amounts since the setting changed) and
    /// the ids to remove (deleted anywhere, or now with nothing to write). Only days inside `start`…`end` are judged,
    /// so an entry older than the window is never taken out of Health just because it wasn't in the reply.
    static func plan(entries: [FoodEntry], written: [String: Written], start: String, end: String) -> (write: [FoodEntry], remove: [String]) {
        let mine = entries.filter { $0.origin == "iphone" }
        var write: [FoodEntry] = []
        var keep = Set<String>()
        for e in mine {
            let keys = keys(e)
            if keys.isEmpty { continue }
            keep.insert(e.id)
            let w = written[e.id]
            if w?.version != e.version || w?.keys != keys || w?.date != e.date { write.append(e) }
        }
        let remove = written.filter { id, w in !keep.contains(id) && w.date >= start && w.date <= end }.map(\.key).sorted()
        return (write, remove)
    }
}

/// Writes and removes logged food in Apple Health, and keeps the record of what this phone wrote. One at a time.
actor FoodHealthStore {
    static let shared = FoodHealthStore()

    private let store = Health.shared.store
    private var lastReconcile: Date?
    private var loaded = false
    private var written: [String: FoodHealth.Written] = [:]

    private static var file: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("food-health.json")
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let data = try? Data(contentsOf: Self.file), let w = try? JSONDecoder().decode([String: FoodHealth.Written].self, from: data) { written = w }
    }

    private func save() {
        try? JSONEncoder().encode(written).write(to: Self.file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Asks Health for write access to the food types, if it hasn't been asked: called when the person saves an entry
    /// here, never at launch. A refusal leaves logging as it is.
    func askIfNeeded() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let undecided = FoodHealth.shareTypes.contains { store.authorizationStatus(for: $0) == .notDetermined }
        guard undecided else { return }
        try? await store.requestAuthorization(toShare: FoodHealth.shareTypes, read: [])
    }

    /// Writes these entries (the ones made here), replacing any earlier copy, in the person's time zone.
    func write(_ entries: [FoodEntry], zone: TimeZone, ask: Bool = false) async {
        load()
        let mine = entries.filter { $0.origin == "iphone" && !FoodHealth.keys($0).isEmpty }
        guard !mine.isEmpty, HKHealthStore.isHealthDataAvailable() else { return }
        if ask { await askIfNeeded() }
        let allowed = { (t: HKQuantityType) in self.store.authorizationStatus(for: t) == .sharingAuthorized }
        for e in mine {
            let objects = FoodHealth.objects(for: e, in: zone, allowed: allowed)
            // Nothing this app may write: leave it unrecorded, so a later reconcile writes it once allowed.
            guard !objects.isEmpty else { continue }
            await deleteAll(FoodHealth.syncID(e.id))
            do {
                try await store.save(objects)
                written[e.id] = FoodHealth.Written(version: e.version, date: e.date, keys: FoodHealth.keys(e))
            } catch {
                print("[healthos] couldn't save food to Health: \(error.localizedDescription)")
            }
        }
        save()
    }

    /// Takes these entries out of Health (deleted anywhere, or nothing left to show).
    func remove(_ ids: [String]) async {
        load()
        guard !ids.isEmpty, HKHealthStore.isHealthDataAvailable() else { return }
        for id in ids {
            await deleteAll(FoodHealth.syncID(id))
            written[id] = nil
        }
        save()
    }

    /// Brings Health in line with the log: writes what's new or changed, takes out what's gone. At most once a minute
    /// unless `force`, since every write wakes the sync, which would reconcile again.
    func reconcile(_ log: FoodLog, zone: TimeZone, force: Bool = false) async {
        if !force, let lastReconcile, Date().timeIntervalSince(lastReconcile) < 60 { return }
        lastReconcile = Date()
        load()
        guard log.enabled else { return }
        let plan = FoodHealth.plan(entries: log.entries, written: written, start: log.start, end: log.end)
        await remove(plan.remove)
        await write(plan.write, zone: zone)
    }

    /// Every object with this sync identifier: the correlation, then each type (deleting a correlation keeps its samples).
    private func deleteAll(_ syncID: String) async {
        let predicate = HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeySyncIdentifier, allowedValues: [syncID])
        let types: [HKObjectType] = [HKCorrelationType(.food)] + FoodHealth.kinds.map(\.type)
        for type in types {
            if let q = type as? HKQuantityType, store.authorizationStatus(for: q) != .sharingAuthorized { continue }
            _ = try? await store.deleteObjects(of: type, predicate: predicate)
        }
    }
}
