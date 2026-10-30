import HealthKit

/// HealthKit access: authorization, change detection with anchored queries, window reads, and
/// background delivery. HKHealthStore is thread-safe, so this is shared freely.
final class Health: @unchecked Sendable {
    static let shared = Health()
    let store = HKHealthStore()
    private var observers: [HKObserverQuery] = []
    private let lock = NSLock()

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    /// One request for everything, every time: on iOS 27 a request that leaves out one direction of a type it asked
    /// about before (writing food, after it was allowed) asks again and resets that direction.
    func requestAuthorization() async throws {
        try await store.requestAuthorization(toShare: Self.shareTypes, read: HealthTypes.readTypes)
    }

    /// What this app asks to write: the simulator's sample data, and the food logged here once the person has been asked.
    static var shareTypes: Set<HKSampleType> { SampleData.shareTypes.union(Config.foodHealthAsked ? FoodHealth.shareTypes : []) }

    struct Changes {
        var dates: Set<String> = []
        var sawDeletions = false
        /// Ingest ids ("hk-<uuid>") of deleted workouts and mindful sessions, which are keyed by UUID on the server.
        var deletedIDs: [String] = []
        /// Cycle types only: the day of each added sample, and the UUIDs of deleted ones (to clear emptied days).
        var addedDays: [String: String] = [:]
        var deletedUUIDs: [String] = []
        var anchor: HKQueryAnchor?
        var samples = 0
    }

    /// The local dates touched by samples added since `anchor`, and the new anchor. The samples
    /// themselves are dropped: a changed day is re-read in full later, because one new sample
    /// changes that day's total, average or winning sleep source.
    func changes(for type: HKSampleType, after anchor: HKQueryAnchor?, since: Date?) async throws -> Changes {
        let predicate = since.map { HKQuery.predicateForSamples(withStart: $0, end: nil, options: []) }
        let pageSize = 10_000
        var out = Changes(anchor: anchor)
        while true {
            let query = HKAnchoredObjectQueryDescriptor(predicates: [.sample(type: type, predicate: predicate)], anchor: out.anchor, limit: pageSize)
            // Not asked about yet (a type a newer build reads): no changes, and the anchor stays put so
            // the type's whole history comes through once it's allowed.
            guard let page = try await Self.unlessUndetermined({ try await query.result(for: store) }) else { return Changes(anchor: anchor) }
            // WHOOP's copies never change a day's result (the aggregation skips them), so they don't make it dirty.
            let metric = type == HKQuantityType(.stepCount) ? "steps" : ""
            // Nor does the food logged here (`FoodHealth.isOurs`, skipped when a day is read): rewriting or removing it
            // must not re-send, or clear, a month of food. A deleted object keeps its sync identifier for this.
            for sample in page.addedSamples where sample.writtenBy.counts(metric) && !FoodHealth.isOurs(sample.metadata) { out.dates.formUnion(Self.days(of: sample)) }
            out.samples += page.addedSamples.count
            if page.deletedObjects.contains(where: { !FoodHealth.isOurs($0.metadata) }) { out.sawDeletions = true }
            if type == HealthTypes.workout || type == HealthTypes.mindful {
                out.deletedIDs += page.deletedObjects.map { "hk-" + $0.uuid.uuidString.lowercased() }
            }
            if CycleTypes.all.contains(type) {
                for sample in page.addedSamples where !sample.writtenBy.isReadDirectly { out.addedDays[sample.uuid.uuidString] = Self.day(of: sample) }
                out.deletedUUIDs += page.deletedObjects.map(\.uuid.uuidString)
            }
            out.anchor = page.newAnchor
            if page.addedSamples.count + page.deletedObjects.count < pageSize { return out }
        }
    }

    /// The day a sample counts toward: sleep and the Watch's sleeping wrist temperature by when you woke up, everything
    /// else by start time.
    static func day(of sample: HKSample) -> String {
        sample.sampleType == HealthTypes.sleep || sample.sampleType == HealthTypes.wristTemp ? sample.endStamp.localDate(shift: Day.rollover) : sample.startStamp.localDate()
    }

    /// The days a new sample makes dirty. Wrist temperature also names the evening the night began, where older builds
    /// dated it: sending that day again clears the row they left there.
    static func days(of sample: HKSample) -> Set<String> {
        sample.sampleType == HealthTypes.wristTemp ? [day(of: sample), sample.startStamp.localDate()] : [day(of: sample)]
    }

    func samples<S: HKSample>(_ predicate: HKSamplePredicate<S>) async throws -> [S] {
        try await Self.unlessUndetermined({ try await HKSampleQueryDescriptor(predicates: [predicate], sortDescriptors: []).result(for: store) }) ?? []
    }

    /// The effort score of each workout in `window`, by its UUID (iOS 18): Health's most relevant one, which is the person's
    /// own rating when there is one and the Watch's estimate otherwise. None before effort is asked about; any other error
    /// fails the sync like a failed read, so the days go up again rather than being marked sent without their effort.
    func efforts(in window: NSPredicate) async throws -> [UUID: Double] {
        guard #available(iOS 18.0, *) else { return [:] }
        let query = HKWorkoutEffortRelationshipQueryDescriptor(predicate: window, anchor: nil, option: .mostRelevant)
        guard let result = try await Self.unlessUndetermined({ try await query.result(for: store) }) else { return [:] }
        var out: [UUID: Double] = [:]
        for r in result.relationships {
            let score = r.samples?.lazy.compactMap { ($0 as? HKQuantitySample)?.quantity.doubleValue(for: .appleEffortScore()) }.first
            if let score { out[r.workout.uuid] = score }
        }
        return out
    }

    /// Runs a query, returning nil when the person hasn't been asked about that type yet, so one new type
    /// doesn't fail a whole background sync. Every other error still throws.
    static func unlessUndetermined<T>(_ query: () async throws -> T) async throws -> T? {
        do {
            return try await query()
        } catch let error as HKError where error.code == .errorAuthorizationNotDetermined {
            return nil
        }
    }

    /// Complete rows for `days` (sorted local dates), read from HealthKit in one padded window.
    /// `clearCycle`: days where a cycle sample was deleted; sent as `{date}` when nothing is left, so the server forgets them.
    /// `food`: the food types to read (none while Nutrition is off); `clearFood` works like `clearCycle`, as `apps: []`.
    func payload(for days: [String], clearCycle: Set<String> = [], food: [Nutrient] = [], clearFood: Set<String> = []) async throws -> IngestPayload {
        // Pad by two days: a local day spans UTC offsets from -12h to +14h, and a night can start the evening before.
        let from = Day.midnightUTC(days.first!).addingTimeInterval(-2 * 86_400)
        let to = Day.midnightUTC(days.last!).addingTimeInterval(3 * 86_400)
        let window = HKQuery.predicateForSamples(withStart: from, end: to, options: [])
        // Food and water logged here and written to Health: left out of the query itself, as well as when adding up.
        let notOurs = NSCompoundPredicate(andPredicateWithSubpredicates: [window, FoodHealth.notOurs])
        let agg = DayAggregator(dates: Set(days))
        for q in HealthTypes.quantities {
            agg.add(try await samples(.quantitySample(type: q.type, predicate: FoodHealth.isDietary(q.type) ? notOurs : window)), as: q)
        }
        agg.add(sleep: try await samples(.categorySample(type: HealthTypes.sleep, predicate: window)))
        agg.add(mindful: try await samples(.categorySample(type: HealthTypes.mindful, predicate: window)))
        agg.add(standHours: try await samples(.categorySample(type: HealthTypes.standHour, predicate: window)))
        let workouts = try await samples(.workout(window))
        agg.add(workouts: workouts, effort: workouts.isEmpty ? [:] : try await efforts(in: window))
        if agg.sawWhoopSteps { Config.sawWhoopSteps = true }
        var payload = agg.finish()
        if CycleTypes.active {
            var records: [CycleRecord] = []
            for type in CycleTypes.categories {
                records += CycleFolder.records(category: try await samples(.categorySample(type: type, predicate: window)))
            }
            records += CycleFolder.records(bbt: try await samples(.quantitySample(type: CycleTypes.bbt, predicate: window)))
            // Only days with records: a day sent with nothing would clear what an export import stored there.
            let days = CycleFolder.fold(records, dates: Set(days), clearing: clearCycle)
            payload.cycle = days.isEmpty ? nil : days
        }
        if !food.isEmpty {
            // Quantity samples only: a Food correlation's samples are these same samples, and reading both would count
            // a meal twice.
            var samples: [FoodSample] = []
            for n in food {
                samples += NutritionFolder.samples(try await self.samples(.quantitySample(type: n.type, predicate: notOurs)), as: n)
            }
            let days = NutritionFolder.fold(samples, dates: Set(days), clearing: clearFood)
            payload.nutrition = days.isEmpty ? nil : days
        }
        return payload
    }

    // MARK: Background delivery

    /// Registers an observer query per type and asks HealthKit to wake the app when any of them
    /// changes. Must run at every launch (HealthKit relaunches the app in the background).
    func startObserving(onChange: @escaping @Sendable () async -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard observers.isEmpty else { return }
        for type in HealthTypes.observedTypes {
            let query = HKObserverQuery(sampleType: type, predicate: nil) { _, completion, error in
                if error != nil { return completion() }
                Task {
                    await onChange()
                    completion()
                }
            }
            store.execute(query)
            observers.append(query)
            store.enableBackgroundDelivery(for: type, frequency: Self.deliveryFrequency(type)) { _, error in
                if let error { print("[healthos] background delivery for \(type.identifier) failed: \(error.localizedDescription)") }
            }
        }
    }

    /// Heart rate arrives every few minutes from a Watch: hourly wakes are plenty and save battery. Steps, energy,
    /// distance, flights, daylight, stand hours and walking metrics are hourly at most anyway. Everything else (sleep,
    /// workouts, mindful, body, heart rate recovery) is rare, so immediate.
    static func deliveryFrequency(_ type: HKSampleType) -> HKUpdateFrequency {
        let hourly: Set<String> = [
            HKQuantityTypeIdentifier.heartRate.rawValue, HKQuantityTypeIdentifier.stepCount.rawValue,
            HKQuantityTypeIdentifier.activeEnergyBurned.rawValue, HKQuantityTypeIdentifier.basalEnergyBurned.rawValue,
            HKQuantityTypeIdentifier.distanceWalkingRunning.rawValue,
            HKQuantityTypeIdentifier.appleExerciseTime.rawValue, HKQuantityTypeIdentifier.respiratoryRate.rawValue,
            HKQuantityTypeIdentifier.flightsClimbed.rawValue, HKQuantityTypeIdentifier.timeInDaylight.rawValue,
            HKQuantityTypeIdentifier.walkingSpeed.rawValue, HKQuantityTypeIdentifier.appleWalkingSteadiness.rawValue,
            HKQuantityTypeIdentifier.walkingAsymmetryPercentage.rawValue, HKCategoryTypeIdentifier.appleStandHour.rawValue,
        ]
        return hourly.contains(type.identifier) ? .hourly : .immediate
    }

    func stopObserving() {
        lock.lock()
        defer { lock.unlock() }
        observers.forEach(store.stop)
        observers = []
        store.disableAllBackgroundDelivery { _, _ in }
    }

    /// Registers everything again, for when the food types read changed. Background delivery outlasts the app, so food
    /// energy's goes with the rest before the current types come back.
    func restartObserving(onChange: @escaping @Sendable () async -> Void) async {
        lock.withLock {
            observers.forEach(store.stop)
            observers = []
        }
        try? await store.disableAllBackgroundDelivery()
        startObserving(onChange: onChange)
    }
}
