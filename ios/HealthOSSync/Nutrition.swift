import Foundation
import HealthKit

/// One day of food totals by app (POST /api/apple/ingest `nutrition`, server/nutrition.ts). Each day sent is that
/// day's complete set from Health and replaces it on the server; `apps: []` clears the day.
struct NutritionDay: Codable, Equatable {
    var date: String
    var apps: [NutritionApp]
}

/// One app's totals for a day. Apps copy each other's logs through Health, so the server shows one app a day, never a sum.
struct NutritionApp: Codable, Equatable {
    var app: String
    /// Nutrient name (energy_kcal, protein_g, …) to the day's total.
    var values: [String: Double]
}

/// One food type read from Health and the nutrient it feeds. Same table as NUTRITION_TYPES in server/apple/import.ts.
struct Nutrient {
    let identifier: HKQuantityTypeIdentifier
    let name: String
    let unit: HKUnit
    /// Above any real day's total (MAX in server/nutrition.ts). The server refuses a whole push over one bigger value,
    /// daily rows and all, so such a total (a unit mix-up, not a meal) is left out here.
    let max: Double
    let label: String

    var type: HKQuantityType { HKQuantityType(identifier) }
}

/// Food totals from the apps people log meals in. Read only while the person has Nutrition on in healthOS and the
/// server lists the nutrients it takes: off, no food type is read, asked about or observed. Never written (the
/// simulator's sample data leaves food out, since these aren't in HealthTypes.quantities). Caffeine and water stay
/// daily metrics.
enum NutritionTypes {
    static let all: [Nutrient] = [
        .init(identifier: .dietaryEnergyConsumed, name: "energy_kcal", unit: .kilocalorie(), max: 30_000, label: "food energy"),
        .init(identifier: .dietaryProtein, name: "protein_g", unit: .gram(), max: 2_000, label: "protein"),
        .init(identifier: .dietaryCarbohydrates, name: "carbs_g", unit: .gram(), max: 3_000, label: "carbohydrates"),
        .init(identifier: .dietaryFatTotal, name: "fat_g", unit: .gram(), max: 2_000, label: "fat"),
        .init(identifier: .dietaryFiber, name: "fiber_g", unit: .gram(), max: 500, label: "fiber"),
        .init(identifier: .dietarySugar, name: "sugar_g", unit: .gram(), max: 2_000, label: "sugar"),
        .init(identifier: .dietaryFatSaturated, name: "sat_fat_g", unit: .gram(), max: 1_000, label: "saturated fat"),
        .init(identifier: .dietarySodium, name: "sodium_mg", unit: .gramUnit(with: .milli), max: 50_000, label: "sodium"),
        .init(identifier: .numberOfAlcoholicBeverages, name: "alcohol_drinks", unit: .count(), max: 100, label: "alcoholic drinks"),
    ]

    /// The one food type with background delivery: a logged meal writes its energy with the rest, and a Food
    /// correlation can't be observed.
    static let energy = HKQuantityType(.dietaryEnergyConsumed)

    static var types: [HKSampleType] { all.map(\.type) }

    static func nutrient(of type: HKSampleType) -> Nutrient? { all.first { $0.type == type } }
    static func nutrient(named name: String) -> Nutrient? { all.first { $0.name == name } }

    /// The food types to read: none while Nutrition is off or the server doesn't take food, else the ones it takes.
    static func reading(accepted: [String]?, on: Bool) -> [Nutrient] {
        guard on, let accepted else { return [] }
        let names = Set(accepted)
        return all.filter { names.contains($0.name) }
    }

    /// What the last sync learned, for asking Health and background delivery. A sync uses its own state instead.
    static var current: [Nutrient] { SyncState.load().foodNutrients }
}

/// One food sample as the folding sees it (free of HealthKit so tests can build them).
struct FoodSample {
    /// The HealthKit UUID: a sample is counted once, however often it's seen (for one, inside a Food correlation).
    let id: String
    let date: String
    let app: String
    let nutrient: String
    let value: Double
}

/// Turns food samples into each day's totals by app, as the server's importer does: per app, never summed across
/// apps; a correlated sample counted once; dated by the sample's local start.
enum NutritionFolder {
    static let maxApps = 20
    static let maxAppName = 100

    /// Days in `dates` with food. Days in `clearing` (a food sample was deleted there) that end up with none come back as
    /// `apps: []`, which clears that day on the server. Other empty days are left out: Health reads as empty when access
    /// to food is off, and sending them would wipe what's stored.
    static func fold(_ samples: [FoodSample], dates: Set<String>, clearing: Set<String> = []) -> [NutritionDay] {
        var seen = Set<String>()
        // date -> app -> nutrient -> total
        var totals: [String: [String: [String: Double]]] = [:]
        for s in samples where dates.contains(s.date) && s.value.isFinite && s.value >= 0 {
            guard NutritionTypes.nutrient(named: s.nutrient) != nil, seen.insert(s.id).inserted else { continue }
            totals[s.date, default: [:]][appName(s.app), default: [:]][s.nutrient, default: 0] += s.value
        }
        var days: [NutritionDay] = []
        for (date, byApp) in totals {
            let apps = byApp.compactMap { app, values -> NutritionApp? in
                var kept: [String: Double] = [:]
                for (name, total) in values {
                    guard let n = NutritionTypes.nutrient(named: name), total <= n.max else { continue }
                    kept[name] = (total * 100).rounded() / 100
                }
                return kept.isEmpty ? nil : NutritionApp(app: app, values: kept)
            }
            guard !apps.isEmpty else { continue }
            days.append(NutritionDay(date: date, apps: Array(ranked(apps).prefix(maxApps)).sorted { $0.app < $1.app }))
        }
        for date in clearing.intersection(dates) where !days.contains(where: { $0.date == date }) {
            days.append(NutritionDay(date: date, apps: []))
        }
        return days.sorted { $0.date < $1.date }
    }

    /// Most energy first, then the most nutrients, then by name: the order the server picks a day's app in.
    private static func ranked(_ apps: [NutritionApp]) -> [NutritionApp] {
        apps.sorted { a, b in
            let (ea, eb) = (a.values["energy_kcal"] ?? 0, b.values["energy_kcal"] ?? 0)
            if ea != eb { return ea > eb }
            if a.values.count != b.values.count { return a.values.count > b.values.count }
            return a.app < b.app
        }
    }

    /// The source's name, as the server takes it: trimmed, 1–100 characters ("unknown" when blank, like the importer).
    static func appName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "unknown" : String(trimmed.prefix(maxAppName)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Keeps the nutrients a server takes. A day whose apps all lose every value is left out rather than sent empty,
    /// so only the deliberate `apps: []` days clear anything.
    static func keep(_ days: [NutritionDay], nutrients: Set<String>) -> [NutritionDay] {
        days.compactMap { day in
            guard !day.apps.isEmpty else { return day }
            let apps = day.apps.compactMap { a -> NutritionApp? in
                let values = a.values.filter { nutrients.contains($0.key) }
                return values.isEmpty ? nil : NutritionApp(app: a.app, values: values)
            }
            return apps.isEmpty ? nil : NutritionDay(date: day.date, apps: apps)
        }
    }

    /// A Health amount in the nutrient's unit: kJ to kcal, g of sodium to mg, mg of fiber to g.
    static func value(_ quantity: HKQuantity, as nutrient: Nutrient) -> Double {
        quantity.doubleValue(for: nutrient.unit)
    }

    static func samples(_ list: [HKQuantitySample], as nutrient: Nutrient) -> [FoodSample] {
        list.map { s in
            FoodSample(id: s.uuid.uuidString, date: s.startStamp.localDate(), app: s.sourceName, nutrient: nutrient.name, value: value(s.quantity, as: nutrient))
        }
    }
}
