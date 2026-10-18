import HealthKit

/// `sum` keeps a day's best single source (iPhone and Watch both count the same walk); `sumAll` adds every source,
/// for things logged once each, like a coffee in one app and a glass of water in another.
enum Aggregation { case sum, sumAll, avg, last }

/// One HealthKit quantity type and the daily metric it feeds. Same table as QUANTITIES in server/apple/import.ts.
struct QuantityMetric {
    let identifier: HKQuantityTypeIdentifier
    let metric: String
    let aggregation: Aggregation
    let unit: HKUnit
    var scale: Double = 1

    var type: HKQuantityType { HKQuantityType(identifier) }
}

enum HealthTypes {
    static let bpm = HKUnit.count().unitDivided(by: .minute())

    static let quantities: [QuantityMetric] = {
        var list = baseQuantities
        if #available(iOS 27.0, *) {
            // Newer Apple Watch software records RMSSD too: short daytime readings, so its own metric,
            // separate from WHOOP's nightly hrv_rmssd (server/apple/import.ts does the same).
            list.append(.init(identifier: .heartRateVariabilityRMSSD, metric: "hrv_rmssd_watch", aggregation: .avg, unit: .secondUnit(with: .milli)))
        }
        if #available(iOS 18.0, *) {
            // The Watch's nightly count, dated by when the night's reading starts, like every other quantity.
            list.append(.init(identifier: .appleSleepingBreathingDisturbances, metric: "breathing_disturbances", aggregation: .avg, unit: .count()))
        }
        return list
    }()

    private static let baseQuantities: [QuantityMetric] = [
        .init(identifier: .stepCount, metric: "steps", aggregation: .sum, unit: .count()),
        .init(identifier: .activeEnergyBurned, metric: "active_energy", aggregation: .sum, unit: .kilocalorie()),
        .init(identifier: .appleExerciseTime, metric: "exercise_min", aggregation: .sum, unit: .minute()),
        .init(identifier: .distanceWalkingRunning, metric: "distance_km", aggregation: .sum, unit: .meterUnit(with: .kilo)),
        .init(identifier: .heartRate, metric: "hr_avg", aggregation: .avg, unit: bpm),
        .init(identifier: .restingHeartRate, metric: "resting_hr", aggregation: .avg, unit: bpm),
        .init(identifier: .heartRateVariabilitySDNN, metric: "hrv_sdnn", aggregation: .avg, unit: .secondUnit(with: .milli)),
        .init(identifier: .oxygenSaturation, metric: "spo2", aggregation: .avg, unit: .percent(), scale: 100),
        .init(identifier: .respiratoryRate, metric: "resp_rate", aggregation: .avg, unit: bpm),
        .init(identifier: .appleSleepingWristTemperature, metric: "wrist_temp", aggregation: .avg, unit: .degreeCelsius()),
        .init(identifier: .bodyTemperature, metric: "body_temp", aggregation: .avg, unit: .degreeCelsius()),
        .init(identifier: .bodyMass, metric: "weight", aggregation: .last, unit: .gramUnit(with: .kilo)),
        .init(identifier: .bodyFatPercentage, metric: "body_fat", aggregation: .last, unit: .percent(), scale: 100),
        .init(identifier: .leanBodyMass, metric: "lean_mass", aggregation: .last, unit: .gramUnit(with: .kilo)),
        .init(identifier: .vo2Max, metric: "vo2max", aggregation: .last, unit: HKUnit(from: "ml/kg*min")),
        .init(identifier: .bloodPressureSystolic, metric: "blood_pressure_systolic", aggregation: .avg, unit: .millimeterOfMercury()),
        .init(identifier: .bloodPressureDiastolic, metric: "blood_pressure_diastolic", aggregation: .avg, unit: .millimeterOfMercury()),
        .init(identifier: .bloodGlucose, metric: "glucose", aggregation: .avg, unit: HKUnit(from: "mg/dL")),
        .init(identifier: .walkingSpeed, metric: "walking_speed", aggregation: .avg, unit: .meter().unitDivided(by: .second()), scale: 3.6),
        // About one reading a week, so the latest one is the day's.
        .init(identifier: .appleWalkingSteadiness, metric: "walking_steadiness", aggregation: .last, unit: .percent(), scale: 100),
        .init(identifier: .walkingAsymmetryPercentage, metric: "walking_asymmetry", aggregation: .avg, unit: .percent(), scale: 100),
        .init(identifier: .timeInDaylight, metric: "daylight_min", aggregation: .sum, unit: .minute()),
        .init(identifier: .flightsClimbed, metric: "flights", aggregation: .sum, unit: .count()),
        .init(identifier: .dietaryCaffeine, metric: "caffeine_mg", aggregation: .sumAll, unit: .gramUnit(with: .milli)),
        .init(identifier: .dietaryWater, metric: "water_ml", aggregation: .sumAll, unit: .literUnit(with: .milli)),
    ]

    static let sleep = HKCategoryType(.sleepAnalysis)
    static let mindful = HKCategoryType(.mindfulSession)
    static let workout = HKWorkoutType.workoutType()
    /// The Watch's hourly "stood / didn't" record; a day's stand hours are the hours stood.
    static let standHour = HKCategoryType(.appleStandHour)

    /// Cycle types join only once cycle tracking is on (and the server stores cycle days).
    static var sampleTypes: [HKSampleType] { quantities.map(\.type) + [sleep, mindful, workout, standHour] + (CycleTypes.active ? CycleTypes.all : []) }
    static var readTypes: Set<HKObjectType> { Set(sampleTypes) }

    /// The type a daily metric is read from (nil for one this build doesn't read on this iOS version).
    static func type(producing metric: String) -> HKSampleType? {
        if let q = quantities.first(where: { $0.metric == metric }) { return q.type }
        if metric == "hr_min" || metric == "hr_max" { return HKQuantityType(.heartRate) }
        if metric.hasPrefix("sleep_") { return sleep }
        if metric == "stand_hours" { return standHour }
        return nil
    }

    /// Names that read better than the metric's own ("daylight min" → "time in daylight").
    private static let names: [String: String] = [
        "blood_pressure_systolic": "blood pressure (systolic)", "blood_pressure_diastolic": "blood pressure (diastolic)",
        "glucose": "blood glucose", "daylight_min": "time in daylight", "flights": "flights climbed",
        "caffeine_mg": "caffeine", "water_ml": "water",
    ]

    static func label(_ type: HKSampleType) -> String {
        if let q = quantities.first(where: { $0.type == type }) { return names[q.metric] ?? q.metric.replacingOccurrences(of: "_", with: " ") }
        if type == sleep { return "sleep" }
        if type == mindful { return "mindfulness" }
        if type == standHour { return "stand hours" }
        if type == workout { return "workouts" }
        if CycleTypes.all.contains(type) { return "cycle" }
        return "health data"
    }
}

enum SleepStage: Hashable {
    case inBed, awake, unspecified, light, rem, deep

    init?(_ value: Int) {
        guard let v = HKCategoryValueSleepAnalysis(rawValue: value) else { return nil }
        switch v {
        case .inBed: self = .inBed
        case .awake: self = .awake
        case .asleepCore: self = .light
        case .asleepDeep: self = .deep
        case .asleepREM: self = .rem
        default: self = .unspecified // .asleepUnspecified (and the old .asleep, same raw value)
        }
    }
}

/// HKWorkoutActivityType raw values to the names in Apple's export ("HKWorkoutActivityType" + name).
enum WorkoutNames {
    static func name(_ type: HKWorkoutActivityType) -> String { table[type.rawValue] ?? "Other" }

    /// "TraditionalStrengthTraining" -> "Traditional Strength Training" (server `sportName`).
    static func sport(_ name: String) -> String {
        if name.isEmpty { return "Workout" }
        return name
            .replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
            .replacingOccurrences(of: "([A-Z]+)([A-Z][a-z])", with: "$1 $2", options: .regularExpression)
    }

    private static let table: [UInt: String] = [
        1: "AmericanFootball", 2: "Archery", 3: "AustralianFootball", 4: "Badminton", 5: "Baseball", 6: "Basketball",
        7: "Bowling", 8: "Boxing", 9: "Climbing", 10: "Cricket", 11: "CrossTraining", 12: "Curling", 13: "Cycling",
        14: "Dance", 15: "DanceInspiredTraining", 16: "Elliptical", 17: "EquestrianSports", 18: "Fencing", 19: "Fishing",
        20: "FunctionalStrengthTraining", 21: "Golf", 22: "Gymnastics", 23: "Handball", 24: "Hiking", 25: "Hockey",
        26: "Hunting", 27: "Lacrosse", 28: "MartialArts", 29: "MindAndBody", 30: "MixedMetabolicCardioTraining",
        31: "PaddleSports", 32: "Play", 33: "PreparationAndRecovery", 34: "Racquetball", 35: "Rowing", 36: "Rugby",
        37: "Running", 38: "Sailing", 39: "SkatingSports", 40: "SnowSports", 41: "Soccer", 42: "Softball", 43: "Squash",
        44: "StairClimbing", 45: "SurfingSports", 46: "Swimming", 47: "TableTennis", 48: "Tennis", 49: "TrackAndField",
        50: "TraditionalStrengthTraining", 51: "Volleyball", 52: "Walking", 53: "WaterFitness", 54: "WaterPolo",
        55: "WaterSports", 56: "Wrestling", 57: "Yoga", 58: "Barre", 59: "CoreTraining", 60: "CrossCountrySkiing",
        61: "DownhillSkiing", 62: "Flexibility", 63: "HighIntensityIntervalTraining", 64: "JumpRope", 65: "Kickboxing",
        66: "Pilates", 67: "Snowboarding", 68: "Stairs", 69: "StepTraining", 70: "WheelchairWalkPace",
        71: "WheelchairRunPace", 72: "TaiChi", 73: "MixedCardio", 74: "HandCycling", 75: "DiscSports", 76: "FitnessGaming",
        77: "CardioDance", 78: "SocialDance", 79: "Pickleball", 80: "Cooldown", 82: "SwimBikeRun", 83: "Transition",
        84: "UnderwaterDiving", 3000: "Other",
    ]
}
