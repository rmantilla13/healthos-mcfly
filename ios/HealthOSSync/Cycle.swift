import Foundation
import HealthKit

/// One day of cycle tracking (POST /api/apple/ingest `cycle`, server/cycle.ts). Each day sent is that day's
/// complete set of Apple records and replaces it on the server.
struct CycleDay: Codable, Equatable {
    var date: String
    var flow: String?
    var periodStart: Bool?
    var spotting: Bool?
    var ovulationTest: String?
    var mucus: String?
    var bbt: Double?
    var sexualActivity: String?
    /// Sorted, from the server's Symptom list.
    var symptoms: [String]?
    /// A morning marked as having an unreliable temperature (logged on the web; Health has no such record).
    var tempDisturbed: String?
}

enum CycleTypes {
    static let flow = HKCategoryType(.menstrualFlow)
    static let spotting = HKCategoryType(.intermenstrualBleeding)
    static let ovulation = HKCategoryType(.ovulationTestResult)
    static let mucus = HKCategoryType(.cervicalMucusQuality)
    static let sexual = HKCategoryType(.sexualActivity)
    static let bbt = HKQuantityType(.basalBodyTemperature)

    /// Health's cycle symptoms, by the name the server uses (Symptom in shared/types.ts).
    static let symptoms: [(type: HKCategoryType, name: String)] = [
        (HKCategoryType(.abdominalCramps), "cramps"),
        (HKCategoryType(.bloating), "bloating"),
        (HKCategoryType(.breastPain), "breast_tenderness"),
        (HKCategoryType(.headache), "headache"),
        (HKCategoryType(.acne), "acne"),
        (HKCategoryType(.fatigue), "fatigue"),
        (HKCategoryType(.moodChanges), "mood_changes"),
        (HKCategoryType(.lowerBackPain), "back_pain"),
        (HKCategoryType(.nausea), "nausea"),
        (HKCategoryType(.appetiteChanges), "appetite_changes"),
        (HKCategoryType(.sleepChanges), "sleep_changes"),
        (HKCategoryType(.hotFlashes), "hot_flashes"),
    ]

    /// The category types read for a day's cycle record.
    static var categories: [HKCategoryType] { [flow, spotting, ovulation, mucus, sexual] + symptoms.map(\.type) }

    static var all: [HKSampleType] { categories + [bbt] }

    /// Read only once the person turned cycle tracking on, and the server stores cycle days.
    static var active: Bool { Config.cycleTracking && Config.serverStoresCycle }
}

/// A cycle record as the folding sees it (free of HealthKit so tests can build them).
struct CycleRecord {
    enum Kind { case flow(String, periodStart: Bool), spotting, ovulation(String), mucus(String), bbt(Double), sexual(String), symptom(String) }
    let date: String
    let at: Date
    let kind: Kind
}

/// Folds a day's records the way the server's importer does: heaviest flow, most positive ovulation test,
/// most fertile mucus, least protected sexual activity, the day's first basal temperature, every symptom once.
enum CycleFolder {
    static let flowOrder = ["none", "unspecified", "light", "medium", "heavy"]
    static let ovulationOrder = ["negative", "indeterminate", "estrogen_surge", "lh_surge"]
    static let mucusOrder = ["dry", "sticky", "creamy", "watery", "egg_white"]
    static let sexualOrder = ["protected", "unspecified", "unprotected"]

    /// Days in `clearing` that end up with no records come back as `{date}` alone, which clears that day on the server.
    /// Other empty days are left out: sending them would clear what an export import stored there.
    static func fold(_ records: [CycleRecord], dates: Set<String>, clearing: Set<String> = []) -> [CycleDay] {
        var days: [String: CycleDay] = [:]
        var bbtAt: [String: Date] = [:]
        func higher(_ a: String?, _ b: String, in order: [String]) -> String {
            guard let a, let ia = order.firstIndex(of: a) else { return b }
            return (order.firstIndex(of: b) ?? -1) > ia ? b : a
        }
        for r in records where dates.contains(r.date) {
            var d = days[r.date] ?? CycleDay(date: r.date)
            switch r.kind {
            case .flow(let v, let start):
                d.flow = higher(d.flow, v, in: flowOrder)
                if start { d.periodStart = true }
            case .spotting: d.spotting = true
            case .ovulation(let v): d.ovulationTest = higher(d.ovulationTest, v, in: ovulationOrder)
            case .mucus(let v): d.mucus = higher(d.mucus, v, in: mucusOrder)
            case .sexual(let v): d.sexualActivity = higher(d.sexualActivity, v, in: sexualOrder)
            case .symptom(let v): d.symptoms = Array(Set(d.symptoms ?? []).union([v])).sorted()
            case .bbt(let c):
                guard (34...40).contains(c) else { break }
                if bbtAt[r.date].map({ r.at < $0 }) ?? true {
                    d.bbt = c
                    bbtAt[r.date] = r.at
                }
            }
            days[r.date] = d
        }
        for date in clearing.intersection(dates) where days[date] == nil { days[date] = CycleDay(date: date) }
        return days.values.sorted { $0.date < $1.date }
    }

    /// HealthKit samples to records, skipping WHOOP's copies; days by the sample's local start date.
    static func records(category samples: [HKCategorySample]) -> [CycleRecord] {
        samples.compactMap { s -> CycleRecord? in
            guard !s.writtenBy.isReadDirectly else { return nil }
            let date = s.startStamp.localDate()
            let kind: CycleRecord.Kind?
            switch s.categoryType {
            case CycleTypes.flow:
                let v = [1: "unspecified", 2: "light", 3: "medium", 4: "heavy", 5: "none"][s.value]
                kind = v.map { .flow($0, periodStart: (s.metadata?[HKMetadataKeyMenstrualCycleStart] as? Bool) == true) }
            case CycleTypes.spotting: kind = .spotting
            case CycleTypes.ovulation: kind = [1: "negative", 2: "lh_surge", 3: "indeterminate", 4: "estrogen_surge"][s.value].map { .ovulation($0) }
            case CycleTypes.mucus: kind = [1: "dry", 2: "sticky", 3: "creamy", 4: "watery", 5: "egg_white"][s.value].map { .mucus($0) }
            case CycleTypes.sexual:
                let used = s.metadata?[HKMetadataKeySexualActivityProtectionUsed] as? Bool
                kind = .sexual(used == true ? "protected" : used == false ? "unprotected" : "unspecified")
            default:
                // Every symptom type uses 1 for "not present" (severity, presence, or appetite's "no change").
                let name = CycleTypes.symptoms.first { $0.type == s.categoryType }?.name
                kind = name.flatMap { s.value == 1 ? nil : .symptom($0) }
            }
            return kind.map { CycleRecord(date: date, at: s.startDate, kind: $0) }
        }
    }

    static func records(bbt samples: [HKQuantitySample]) -> [CycleRecord] {
        samples.compactMap { s in
            guard !s.writtenBy.isReadDirectly else { return nil }
            return CycleRecord(date: s.startStamp.localDate(), at: s.startDate, kind: .bbt(s.quantity.doubleValue(for: .degreeCelsius())))
        }
    }
}
