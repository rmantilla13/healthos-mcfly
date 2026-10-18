import Foundation
import HealthKit

struct SyncReport: Codable, Equatable {
    var finishedAt: Date
    var ok: Bool
    var message: String
}

/// What has been synced, saved between launches. Anchors and the pending days are saved together,
/// so a day whose upload failed is retried on the next sync instead of being lost.
struct SyncState: Codable {
    var server = ""
    var since: Date?
    var anchors: [String: Data] = [:]
    var pending: [String] = []
    /// Days older than the recent month still to send (first upload, or the hourly backfill). Sent newest first, a
    /// few weeks per pass, in the foreground only, so a background wake never uploads years of history.
    var backfill: [String] = []
    var deletedWorkouts: [String] = []
    var deletedEvents: [String] = []
    /// The day of each cycle sample sent (by HealthKit UUID), so a deletion can clear the day it was on.
    var cycleSampleDays: [String: String] = [:]
    /// Days where a cycle sample was deleted, still to send (as `{date}` if nothing is left there).
    var cycleClear: [String] = []
    /// Cycle anchors were reset once so `cycleSampleDays` covers samples sent by older builds.
    var cycleMapBuilt = false
    /// The recent month was re-sent once after WHOOP's steps started counting, to correct existing step rows.
    var whoopStepsResent = false
    var last: SyncReport?
    /// The one-time re-read of history that gives already-synced days their hours, once the server stores them.
    var hourlyBackfillStarted = false
    var hourlyBackfillDone = false
    /// The daily metrics the server listed in its last reply; nil for an older server that doesn't list them.
    var acceptedMetrics: [String]?

    init(server: String = "", since: Date? = nil, last: SyncReport? = nil) {
        self.server = server
        self.since = since
        self.last = last
    }

    // Tolerates state files written by older builds that lack newer fields.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        server = try c.decodeIfPresent(String.self, forKey: .server) ?? ""
        since = try c.decodeIfPresent(Date.self, forKey: .since)
        anchors = try c.decodeIfPresent([String: Data].self, forKey: .anchors) ?? [:]
        pending = try c.decodeIfPresent([String].self, forKey: .pending) ?? []
        backfill = try c.decodeIfPresent([String].self, forKey: .backfill) ?? []
        deletedWorkouts = try c.decodeIfPresent([String].self, forKey: .deletedWorkouts) ?? []
        deletedEvents = try c.decodeIfPresent([String].self, forKey: .deletedEvents) ?? []
        cycleSampleDays = try c.decodeIfPresent([String: String].self, forKey: .cycleSampleDays) ?? [:]
        cycleClear = try c.decodeIfPresent([String].self, forKey: .cycleClear) ?? []
        cycleMapBuilt = try c.decodeIfPresent(Bool.self, forKey: .cycleMapBuilt) ?? false
        whoopStepsResent = try c.decodeIfPresent(Bool.self, forKey: .whoopStepsResent) ?? false
        last = try c.decodeIfPresent(SyncReport.self, forKey: .last)
        hourlyBackfillStarted = try c.decodeIfPresent(Bool.self, forKey: .hourlyBackfillStarted) ?? false
        hourlyBackfillDone = try c.decodeIfPresent(Bool.self, forKey: .hourlyBackfillDone) ?? false
        acceptedMetrics = try c.decodeIfPresent([String].self, forKey: .acceptedMetrics)
    }

    /// Daily metrics every server took before replies listed them (APPLE_METRICS in server/apple/ingest.ts before iOS 1.1).
    static let legacyMetrics: Set<String> = [
        "steps", "active_energy", "exercise_min", "distance_km", "hr_avg", "hr_min", "hr_max", "resting_hr", "hrv_sdnn",
        "hrv_rmssd_watch", "spo2", "resp_rate", "wrist_temp", "body_temp", "weight", "body_fat", "lean_mass", "vo2max",
        "sleep_hours", "sleep_in_bed", "sleep_deep", "sleep_rem", "sleep_light", "sleep_awake",
    ]

    /// The daily metrics this server takes: what its last reply listed, else the legacy set.
    var accepted: Set<String> { acceptedMetrics.map(Set.init) ?? Self.legacyMetrics }

    /// One unknown metric fails a whole ingest, so rows this server wouldn't take are left out.
    func filtered(_ payload: IngestPayload) -> IngestPayload {
        let accepted = accepted
        var p = payload
        p.daily.removeAll { !accepted.contains($0.metric) }
        return p
    }

    /// Learns from a reply which metrics the server takes. One it takes for the first time had its days read (and its
    /// rows left out) while it didn't, so the anchors of the types it comes from are cleared, once, and their history
    /// goes up again through the recent month and the backfill. Returns the identifiers of the types cleared.
    @discardableResult
    mutating func noteAccepted(_ metrics: [String]?, typeOf: (String) -> String? = { HealthTypes.type(producing: $0)?.identifier }) -> Set<String> {
        let added = Set(metrics ?? []).subtracting(accepted)
        acceptedMetrics = metrics
        let types = Set(added.compactMap(typeOf))
        for id in types { anchors[id] = nil }
        return types
    }

    /// Every push goes through here: rows this server wouldn't take are left out, and its reply says what it takes now.
    /// A server that refuses a metric it listed before (it went back to an older version) is asked again, with an empty
    /// push, which it takes; the rows then go up once more without the ones it no longer takes.
    @discardableResult
    mutating func push(_ payload: IngestPayload, send: (IngestPayload) async throws -> IngestClient.Response) async throws -> (reply: IngestClient.Response, rows: Int) {
        var sent = filtered(payload)
        let reply: IngestClient.Response
        do {
            reply = try await send(sent)
        } catch let error as IngestClient.Rejected where error.unknownMetric {
            let probe = try await send(IngestPayload())
            noteAccepted(probe.metrics)
            let fewer = filtered(payload)
            // Nothing more to leave out: the same rows would be refused again.
            guard fewer.daily.map(\.metric) != sent.daily.map(\.metric) else { throw error }
            sent = fewer
            reply = try await send(sent)
        }
        noteAccepted(reply.metrics)
        return (reply, sent.rowCount)
    }

    /// Days only go up again when they change, so hours a server dropped (it didn't store them yet) would never
    /// arrive. The first reply that counts `hourly` starts one full re-read of history.
    mutating func startHourlyBackfill(serverStoresHours: Bool) {
        guard serverStoresHours, !hourlyBackfillStarted, !hourlyBackfillDone else { return }
        hourlyBackfillStarted = true
        anchors = [:]
    }

    /// Done once every pending and backfill day went up and the server confirmed it stored their hours.
    mutating func finishHourlyBackfill(serverStoredHours: Bool) {
        guard hourlyBackfillStarted, pending.isEmpty, backfill.isEmpty, serverStoredHours else { return }
        hourlyBackfillStarted = false
        hourlyBackfillDone = true
    }

    /// Records which day each new cycle sample is on, and returns the days that deleted ones were on.
    /// A deletion we have no day for (sent before this map existed) rechecks the last 60 days.
    mutating func noteCycle(added: [String: String], deleted: [String], today: String) -> Set<String> {
        cycleSampleDays.merge(added) { _, new in new }
        var days = Set<String>()
        for uuid in deleted {
            if let day = cycleSampleDays.removeValue(forKey: uuid) {
                days.insert(day)
            } else {
                days.formUnion((0...60).map { Day.add(today, -$0) })
            }
        }
        cycleClear = Set(cycleClear).union(days).sorted()
        return days
    }

    /// How many days back count as recent: today plus the 30 days before it (the Day view's typical curve).
    static let recentDays = 30

    /// Moves pending days older than the recent month into the backfill queue. State from an older build that was
    /// part-way through sending all of history oldest first gets its recent month sent next, then the rest newest first.
    mutating func splitOld(today: String) {
        let cutoff = Day.add(today, -Self.recentDays)
        let old = pending.filter { $0 < cutoff }
        guard !old.isEmpty else { return }
        pending.removeAll { $0 < cutoff }
        backfill = Set(backfill).union(old).sorted(by: >)
    }

    private static var file: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("sync-state.json")
    }

    static func load() -> SyncState {
        guard let data = try? Data(contentsOf: file), let state = try? JSONDecoder().decode(SyncState.self, from: data) else { return SyncState() }
        return state
    }

    func save() throws {
        // Readable after first unlock, like the token: background deliveries can arrive while locked.
        try JSONEncoder().encode(self).write(to: Self.file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

enum SyncEvent: Sendable {
    case progress(String)
    /// Older history: days still to send, and the newest day of the window going up now (nil between passes).
    case backfill(left: Int, at: String?)
    case finished(SyncReport)
}

/// Runs syncs one at a time. Triggers that arrive mid-sync (the Sync button, observer queries for
/// several types at once) fold into one more pass instead of queuing a sync each. The history backfill runs on
/// the same worker between syncs, in short passes, so a sync never waits behind years of history.
actor SyncEngine {
    static let shared = SyncEngine()

    private var worker: Task<Void, Never>?
    private var syncWanted = false
    private var backfillWanted = false
    private var waiters: [CheckedContinuation<SyncReport, Never>] = []
    private var listener: (@Sendable (SyncEvent) async -> Void)?
    /// Whether a backfill pass may run now (the app is in the foreground, not in Low Power Mode).
    private var backfillAllowed: (@Sendable () async -> Bool)?

    func setListener(_ listener: (@Sendable (SyncEvent) async -> Void)?) {
        self.listener = listener
    }

    func setBackfillGate(_ gate: (@Sendable () async -> Bool)?) {
        backfillAllowed = gate
    }

    /// Sends what changed in the recent month (always including today) and returns. Older days wait for `continueBackfill`.
    @discardableResult
    func sync() async -> SyncReport {
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
            syncWanted = true
            startWorker()
        }
    }

    /// Keeps sending older history, newest first, while the gate allows it.
    func continueBackfill() {
        backfillWanted = true
        startWorker()
    }

    /// Forget what was sent, so the next sync uploads all history again (e.g. after clearing the server).
    func reset() async {
        backfillWanted = false
        while let worker { await worker.value }
        var state = SyncState.load()
        state = SyncState(last: state.last)
        try? state.save()
    }

    private func startWorker() {
        guard worker == nil else { return }
        worker = Task { await self.work() }
    }

    private func work() async {
        while true {
            if syncWanted {
                syncWanted = false
                let report = await runOnce()
                // A trigger that arrived mid-run gets the next run's report, as before.
                if !syncWanted {
                    let done = waiters
                    waiters = []
                    done.forEach { $0.resume(returning: report) }
                    await listener?(.finished(report))
                }
                continue
            }
            if backfillWanted, let gate = backfillAllowed, await gate() {
                if await backfillPass() { continue }
            }
            backfillWanted = false
            // A sync that arrived while the gate or the last pass was awaited must not be left waiting.
            if syncWanted { continue }
            break
        }
        worker = nil
    }

    private func emit(_ event: SyncEvent) async {
        await listener?(event)
    }

    private func runOnce() async -> SyncReport {
        var state = SyncState.load()
        do {
            guard Health.shared.isAvailable else { throw SyncError("Health data isn't available on this device.") }
            guard let base = Config.serverURL() else { throw SyncError("Enter the healthOS server URL.") }
            let token = Config.token
            guard !token.isEmpty else { throw SyncError("Paste your ingest token from the dashboard: Integrations → iPhone app.") }

            // A different server has none of our history: start over.
            if state.server != base.absoluteString {
                state = SyncState(server: base.absoluteString, since: Config.history.start(from: Date()), last: state.last)
            }

            let client = IngestClient(base: base, token: token)
            // Ask (with an empty push, which writes nothing) whether this server stores hours yet, and which daily
            // metrics it takes, before reading changes: a metric it takes for the first time clears its types' anchors.
            var storedHours = false
            if !state.hourlyBackfillDone || !Config.serverStoresCycle || state.acceptedMetrics == nil {
                let probe = try await push(IngestPayload(), via: client, state: &state).reply
                storedHours = probe.hourly != nil
                state.startHourlyBackfill(serverStoresHours: storedHours)
                // Cycle types start with no anchor, so their whole history goes up the first time they're read.
                if probe.cycle != nil { Config.serverStoresCycle = true }
            }

            // Once: read cycle history again so every sent cycle sample's day is known (for deletions).
            if CycleTypes.active, !state.cycleMapBuilt {
                for type in CycleTypes.all { state.anchors[type.identifier] = nil }
                state.cycleMapBuilt = true
            }

            // 1. Which days changed since the last sync.
            var dirty = Set<String>()
            var anchors = state.anchors
            var deletedWorkouts = state.deletedWorkouts, deletedEvents = state.deletedEvents
            let types = HealthTypes.sampleTypes
            for (i, type) in types.enumerated() {
                await emit(.progress("Checking \(HealthTypes.label(type)) (\(i + 1)/\(types.count))"))
                let anchor = state.anchors[type.identifier].flatMap {
                    try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: $0)
                }
                let changes = try await Health.shared.changes(for: type, after: anchor, since: state.since)
                dirty.formUnion(changes.dates)
                if CycleTypes.all.contains(type) {
                    dirty.formUnion(state.noteCycle(added: changes.addedDays, deleted: changes.deletedUUIDs, today: Day.today()))
                }
                if type == HealthTypes.workout { deletedWorkouts += changes.deletedIDs }
                if type == HealthTypes.mindful { deletedEvents += changes.deletedIDs }
                // Deleted samples don't say which day they were on. Recheck the last month; older edits need "Upload all history".
                if changes.sawDeletions, anchor != nil {
                    dirty.formUnion((0...SyncState.recentDays).map { Day.add(Day.today(), -$0) })
                }
                if let a = changes.anchor {
                    anchors[type.identifier] = try NSKeyedArchiver.archivedData(withRootObject: a, requiringSecureCoding: true)
                }
            }
            let today = Day.today()
            let floor = state.since.map(Day.of)
            let latest = Day.add(today, 1)
            dirty = dirty.filter { $0 <= latest && (floor == nil || $0 >= floor!) }
            // Once: WHOOP's steps now compete for each day, so the recent month goes up again with corrected steps.
            if !state.whoopStepsResent {
                dirty.formUnion((0...SyncState.recentDays).map { Day.add(today, -$0) })
                state.whoopStepsResent = true
            }
            let changed = dirty.count
            // Today goes up on every sync, so the dashboard's today and its hours are never behind the phone.
            dirty.insert(today)
            state.anchors = anchors
            state.pending = Set(state.pending).union(dirty).sorted()
            state.splitOld(today: today)
            state.deletedWorkouts = deletedWorkouts
            state.deletedEvents = deletedEvents
            try state.save()

            // 2. Re-read each pending day in full and upload it, newest week first.
            if !state.deletedWorkouts.isEmpty || !state.deletedEvents.isEmpty {
                await emit(.progress("Removing deleted workouts and sessions"))
                try await push(IngestPayload(deleted: .init(workouts: state.deletedWorkouts, events: state.deletedEvents)), via: client, state: &state)
                state.deletedWorkouts = []
                state.deletedEvents = []
                try state.save()
            }
            let windows = Self.windows(state.pending)
            var days = 0, rows = 0
            for (i, window) in windows.enumerated() {
                await emit(.progress(windows.count == 1 && window.count == 1 ? "Uploading \(window[0])" : "Uploading \(window.first!) – \(window.last!) (\(i + 1)/\(windows.count))"))
                let payload = try await Health.shared.payload(for: window, clearCycle: Set(state.cycleClear))
                let (reply, sentRows) = try await push(payload, via: client, state: &state)
                storedHours = reply.hourly != nil
                let sent = Set(window)
                state.pending.removeAll { sent.contains($0) }
                state.cycleClear.removeAll { sent.contains($0) }
                try state.save()
                days += window.count
                rows += sentRows
            }
            state.finishHourlyBackfill(serverStoredHours: storedHours)
            let left = state.backfill.count
            var message = changed == 0 ? "Up to date" : "Sent \(days) day\(days == 1 ? "" : "s") (\(rows) rows)"
            if left > 0 { message += " · \(left) older day\(left == 1 ? "" : "s") to send" }
            state.last = SyncReport(finishedAt: Date(), ok: true, message: message)
        } catch {
            state.last = SyncReport(finishedAt: Date(), ok: false, message: Self.describe(error))
        }
        try? state.save()
        return state.last!
    }

    /// Windows of history sent per backfill pass, so a new sync or the app leaving the foreground is noticed soon.
    static let backfillWindowsPerPass = 4

    /// Sends the next few weeks of the backfill queue, newest first. Returns whether more remain and it went fine.
    private func backfillPass() async -> Bool {
        var state = SyncState.load()
        guard !state.backfill.isEmpty, let base = Config.serverURL(), !Config.token.isEmpty, state.server == base.absoluteString else { return false }
        let client = IngestClient(base: base, token: Config.token)
        do {
            for window in Self.windows(state.backfill).prefix(Self.backfillWindowsPerPass) {
                await emit(.backfill(left: state.backfill.count, at: window.first!))
                let payload = try await Health.shared.payload(for: window, clearCycle: Set(state.cycleClear))
                let reply = try await push(payload, via: client, state: &state).reply
                let sent = Set(window)
                state.backfill.removeAll { sent.contains($0) }
                state.cycleClear.removeAll { sent.contains($0) }
                state.finishHourlyBackfill(serverStoredHours: reply.hourly != nil)
                try state.save()
            }
        } catch {
            // Left in the queue; the next foreground sync picks it up again.
            state.last = SyncReport(finishedAt: Date(), ok: false, message: "Older history: " + Self.describe(error))
            try? state.save()
            await emit(.backfill(left: state.backfill.count, at: nil))
            return false
        }
        // The last report still counts the older days it left; say how many remain now.
        if let last = state.last, last.ok, let cut = last.message.range(of: " · ") {
            let left = state.backfill.count
            let base = String(last.message[..<cut.lowerBound])
            state.last?.message = left == 0 ? base : base + " · \(left) older day\(left == 1 ? "" : "s") to send"
            try? state.save()
        }
        await emit(.backfill(left: state.backfill.count, at: nil))
        return !state.backfill.isEmpty
    }

    /// Every push goes through `SyncState.push`, which leaves out rows the server wouldn't take.
    @discardableResult
    private func push(_ payload: IngestPayload, via client: IngestClient, state: inout SyncState) async throws -> (reply: IngestClient.Response, rows: Int) {
        try await state.push(payload, send: client.send)
    }

    private static func describe(_ error: Error) -> String {
        (error as? HKError)?.code == .errorDatabaseInaccessible
            ? "Health data is locked while the phone is locked. Will retry."
            : error.localizedDescription
    }

    /// Groups dates into runs spanning at most 7 days, so one read covers a run and memory stays bounded.
    /// Newest run first; each run is sorted oldest first, because `Health.payload` reads from its first day to its last.
    static func windows(_ dates: [String]) -> [[String]] {
        var out: [[String]] = []
        for date in Set(dates).sorted(by: >) {
            if let newest = out.last?.first, date >= Day.add(newest, -6) {
                out[out.count - 1].append(date)
            } else {
                out.append([date])
            }
        }
        return out.map { $0.reversed() }
    }
}
