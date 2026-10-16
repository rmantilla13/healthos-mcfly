import HealthKit

/// HealthKit access: authorization, change detection with anchored queries, window reads, and
/// background delivery. HKHealthStore is thread-safe, so this is shared freely.
final class Health: @unchecked Sendable {
    static let shared = Health()
    let store = HKHealthStore()
    private var observers: [HKObserverQuery] = []
    private let lock = NSLock()

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    func requestAuthorization() async throws {
        try await store.requestAuthorization(toShare: SampleData.shareTypes, read: HealthTypes.readTypes)
    }

    struct Changes {
        var dates: Set<String> = []
        var sawDeletions = false
        /// Ingest ids ("hk-<uuid>") of deleted workouts and mindful sessions, which are keyed by UUID on the server.
        var deletedIDs: [String] = []
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
            let page = try await query.result(for: store)
            for sample in page.addedSamples { out.dates.insert(Self.day(of: sample)) }
            out.samples += page.addedSamples.count
            if !page.deletedObjects.isEmpty { out.sawDeletions = true }
            if type == HealthTypes.workout || type == HealthTypes.mindful {
                out.deletedIDs += page.deletedObjects.map { "hk-" + $0.uuid.uuidString.lowercased() }
            }
            out.anchor = page.newAnchor
            if page.addedSamples.count + page.deletedObjects.count < pageSize { return out }
        }
    }

    /// The day a sample counts toward: sleep by when you woke up, everything else by start time.
    static func day(of sample: HKSample) -> String {
        sample.sampleType == HealthTypes.sleep ? sample.endStamp.localDate(shift: Day.rollover) : sample.startStamp.localDate()
    }

    func samples<S: HKSample>(_ predicate: HKSamplePredicate<S>) async throws -> [S] {
        try await HKSampleQueryDescriptor(predicates: [predicate], sortDescriptors: []).result(for: store)
    }

    /// Complete rows for `days` (sorted local dates), read from HealthKit in one padded window.
    func payload(for days: [String]) async throws -> IngestPayload {
        // Pad by two days: a local day spans UTC offsets from -12h to +14h, and a night can start the evening before.
        let from = Day.midnightUTC(days.first!).addingTimeInterval(-2 * 86_400)
        let to = Day.midnightUTC(days.last!).addingTimeInterval(3 * 86_400)
        let window = HKQuery.predicateForSamples(withStart: from, end: to, options: [])
        let agg = DayAggregator(dates: Set(days))
        for q in HealthTypes.quantities {
            agg.add(try await samples(.quantitySample(type: q.type, predicate: window)), as: q)
        }
        agg.add(sleep: try await samples(.categorySample(type: HealthTypes.sleep, predicate: window)))
        agg.add(mindful: try await samples(.categorySample(type: HealthTypes.mindful, predicate: window)))
        agg.add(workouts: try await samples(.workout(window)))
        return agg.finish()
    }

    // MARK: Background delivery

    /// Registers an observer query per type and asks HealthKit to wake the app when any of them
    /// changes. Must run at every launch (HealthKit relaunches the app in the background).
    func startObserving(onChange: @escaping @Sendable () async -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard observers.isEmpty else { return }
        for type in HealthTypes.sampleTypes {
            let query = HKObserverQuery(sampleType: type, predicate: nil) { _, completion, error in
                if error != nil { return completion() }
                Task {
                    await onChange()
                    completion()
                }
            }
            store.execute(query)
            observers.append(query)
            store.enableBackgroundDelivery(for: type, frequency: .immediate) { _, error in
                if let error { print("[healthos] background delivery for \(type.identifier) failed: \(error.localizedDescription)") }
            }
        }
    }

    func stopObserving() {
        lock.lock()
        defer { lock.unlock() }
        observers.forEach(store.stop)
        observers = []
        store.disableAllBackgroundDelivery { _, _ in }
    }
}
