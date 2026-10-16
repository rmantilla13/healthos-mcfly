import HealthKit

#if targetEnvironment(simulator)
/// Simulator only: fills the simulator's empty Health store with two weeks of plausible data, so the
/// sync can be tried end to end. Device builds never ask for write access.
enum SampleData {
    // Apple-computed types (exercise minutes, sleeping wrist temperature) can't be written by apps.
    static let shareTypes: Set<HKSampleType> = Set(
        HealthTypes.quantities.map(\.identifier)
            .filter { $0 != .appleExerciseTime && $0 != .appleSleepingWristTemperature }
            .map { HKQuantityType($0) as HKSampleType }
    ).union([HealthTypes.sleep, HealthTypes.mindful, HealthTypes.workout])

    /// Writes `days` days ending now. Every sample carries a sync identifier, so running it twice replaces instead of doubling.
    static func write(days: Int = 14) async throws -> Int {
        let store = Health.shared.store
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        var random = SeededRandom(seed: 20_261_016)
        var samples: [HKSample] = []
        var runs: [(start: Date, key: String)] = []

        func meta(_ key: String) -> [String: Any] { [HKMetadataKeySyncIdentifier: "healthos-sample-\(key)", HKMetadataKeySyncVersion: 1] }
        func quantity(_ id: HKQuantityTypeIdentifier, _ value: Double, _ unit: HKUnit, _ start: Date, _ end: Date? = nil, _ key: String) {
            let end = end ?? start
            guard end <= now else { return }
            samples.append(HKQuantitySample(type: HKQuantityType(id), quantity: HKQuantity(unit: unit, doubleValue: value), start: start, end: end, metadata: meta(key)))
        }
        func category(_ type: HKCategoryType, _ value: Int, _ start: Date, _ end: Date, _ key: String) {
            guard end <= now else { return }
            samples.append(HKCategorySample(type: type, value: value, start: start, end: end, metadata: meta(key)))
        }

        for d in 0..<days {
            let day = calendar.date(byAdding: .day, value: -d, to: today)!
            let key = Day.of(day)
            func at(_ hours: Double) -> Date { day.addingTimeInterval(hours * 3600) }

            // Movement: hourly from 7:00 to 22:00.
            let target = 6_000 + random.next() * 6_000
            for h in 7..<22 {
                let steps = (target / 15 * (0.4 + random.next() * 1.2)).rounded()
                let start = at(Double(h)), end = at(Double(h) + 0.9)
                quantity(.stepCount, steps, .count(), start, end, "steps-\(key)-\(h)")
                quantity(.distanceWalkingRunning, steps * 0.76, .meter(), start, end, "dist-\(key)-\(h)")
                quantity(.activeEnergyBurned, steps * 0.045 + 4, .kilocalorie(), start, end, "energy-\(key)-\(h)")
            }
            // Heart rate every 20 minutes, lower at night.
            for m in stride(from: 0, to: 24 * 60, by: 20) {
                let h = Double(m) / 60
                let base = h < 7 || h >= 23 ? 54.0 : 70.0
                quantity(.heartRate, (base + random.next() * 22).rounded(), HealthTypes.bpm, at(h), nil, "hr-\(key)-\(m)")
            }
            quantity(.restingHeartRate, (51 + random.next() * 7).rounded(), HealthTypes.bpm, at(7), nil, "rhr-\(key)")
            quantity(.heartRateVariabilitySDNN, 42 + random.next() * 30, .secondUnit(with: .milli), at(3), nil, "hrv-\(key)")
            for (i, h) in [1.5, 3.5, 5.5].enumerated() {
                quantity(.oxygenSaturation, 0.95 + random.next() * 0.04, .percent(), at(h), nil, "spo2-\(key)-\(i)")
            }
            quantity(.respiratoryRate, 13.5 + random.next() * 3, HealthTypes.bpm, at(4), nil, "resp-\(key)")
            quantity(.bodyTemperature, 36.5 + random.next() * 0.4, .degreeCelsius(), at(7.5), nil, "temp-\(key)")
            let weight = 81.0 + Double(d) * 0.04 + random.next() * 0.4
            let fat = 0.18 + random.next() * 0.01
            quantity(.bodyMass, weight, .gramUnit(with: .kilo), at(7.25), nil, "weight-\(key)")
            quantity(.bodyFatPercentage, fat, .percent(), at(7.25), nil, "fat-\(key)")
            quantity(.leanBodyMass, weight * (1 - fat), .gramUnit(with: .kilo), at(7.25), nil, "lean-\(key)")
            if d % 7 == 0 { quantity(.vo2Max, 44 + random.next() * 2, HKUnit(from: "ml/kg*min"), at(19), nil, "vo2-\(key)") }

            // The night that ends this morning: in bed 22:45-06:45, with stages.
            let sleep = HealthTypes.sleep
            category(sleep, HKCategoryValueSleepAnalysis.inBed.rawValue, at(-1.25), at(6.75), "inbed-\(key)")
            let stages: [(HKCategoryValueSleepAnalysis, Double, Double)] = [
                (.asleepCore, -1.0, 1.0), (.asleepDeep, 1.0, 2.5), (.asleepCore, 2.5, 3.5), (.asleepREM, 3.5, 4.5),
                (.awake, 4.5, 4.75), (.asleepCore, 4.75, 5.75), (.asleepREM, 5.75, 6.5),
            ]
            for (i, (stage, from, to)) in stages.enumerated() {
                category(sleep, stage.rawValue, at(from + random.next() * 0.1), at(to), "sleep-\(key)-\(i)")
            }

            if d % 2 == 0 { category(HealthTypes.mindful, HKCategoryValue.notApplicable.rawValue, at(12.5), at(12.67), "mindful-\(key)") }
            if d % 2 == 1, at(18.6) <= now { runs.append((at(18), key)) }
        }

        try await store.save(samples)
        for run in runs { try await saveRun(store: store, start: run.start, key: run.key, random: &random) }
        return samples.count + runs.count
    }

    private static func saveRun(store: HKHealthStore, start: Date, key: String, random: inout SeededRandom) async throws {
        let config = HKWorkoutConfiguration()
        config.activityType = .running
        config.locationType = .outdoor
        let builder = HKWorkoutBuilder(healthStore: store, configuration: config, device: .local())
        let end = start.addingTimeInterval(35 * 60)
        func meta(_ k: String) -> [String: Any] { [HKMetadataKeySyncIdentifier: "healthos-sample-run-\(key)-\(k)", HKMetadataKeySyncVersion: 1] }
        var samples: [HKSample] = [
            HKQuantitySample(type: HKQuantityType(.activeEnergyBurned), quantity: HKQuantity(unit: .kilocalorie(), doubleValue: 330 + random.next() * 40), start: start, end: end, metadata: meta("energy")),
            HKQuantitySample(type: HKQuantityType(.distanceWalkingRunning), quantity: HKQuantity(unit: .meter(), doubleValue: 5_200 + random.next() * 600), start: start, end: end, metadata: meta("distance")),
        ]
        for m in stride(from: 0, to: 35, by: 2) {
            let t = start.addingTimeInterval(Double(m) * 60)
            samples.append(HKQuantitySample(type: HKQuantityType(.heartRate), quantity: HKQuantity(unit: HealthTypes.bpm, doubleValue: (138 + random.next() * 30).rounded()), start: t, end: t, metadata: meta("hr-\(m)")))
        }
        try await builder.beginCollection(at: start)
        try await builder.addSamples(samples)
        try await builder.addMetadata(meta("workout"))
        try await builder.endCollection(at: end)
        _ = try await builder.finishWorkout()
    }
}

/// Deterministic numbers in [0, 1), so the sample data looks the same on every run.
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(state >> 11) / Double(1 << 53)
    }
}
#else
enum SampleData {
    static let shareTypes: Set<HKSampleType> = []
}
#endif
