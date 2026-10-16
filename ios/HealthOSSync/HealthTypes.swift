import HealthKit

enum Aggregation { case sum, avg, last }

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

    static let quantities: [QuantityMetric] = [
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
    ]

    static let sleep = HKCategoryType(.sleepAnalysis)
    static let mindful = HKCategoryType(.mindfulSession)
    static let workout = HKWorkoutType.workoutType()

    static var sampleTypes: [HKSampleType] { quantities.map(\.type) + [sleep, mindful, workout] }
    static var readTypes: Set<HKObjectType> { Set(sampleTypes) }

    static func label(_ type: HKSampleType) -> String {
        if let q = quantities.first(where: { $0.type == type }) { return q.metric.replacingOccurrences(of: "_", with: " ") }
        if type == sleep { return "sleep" }
        if type == mindful { return "mindfulness" }
        return "workouts"
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
