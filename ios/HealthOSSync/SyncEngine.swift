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
    var last: SyncReport?

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
    case finished(SyncReport)
}

/// Runs syncs one at a time. Triggers that arrive mid-sync (the Sync button, observer queries for
/// several types at once) fold into one more pass instead of queuing a sync each.
actor SyncEngine {
    static let shared = SyncEngine()

    private var inFlight: Task<SyncReport, Never>?
    private var again = false
    private var listener: (@Sendable (SyncEvent) async -> Void)?

    func setListener(_ listener: (@Sendable (SyncEvent) async -> Void)?) {
        self.listener = listener
    }

    @discardableResult
    func sync() async -> SyncReport {
        if let inFlight {
            again = true
            return await inFlight.value
        }
        let task = Task { await self.drain() }
        inFlight = task
        return await task.value
    }

    /// Forget what was sent, so the next sync uploads all history again (e.g. after clearing the server).
    func reset() async {
        _ = await inFlight?.value
        var state = SyncState.load()
        state = SyncState(last: state.last)
        try? state.save()
    }

    private func drain() async -> SyncReport {
        var report: SyncReport
        repeat {
            again = false
            report = await runOnce()
        } while again
        inFlight = nil
        await listener?(.finished(report))
        return report
    }

    private func emit(_ message: String) async {
        await listener?(.progress(message))
    }

    private func runOnce() async -> SyncReport {
        var state = SyncState.load()
        do {
            guard Health.shared.isAvailable else { throw SyncError("Health data isn't available on this device.") }
            guard let base = Config.serverURL() else { throw SyncError("Enter the healthOS server URL.") }
            let token = Config.token
            guard !token.isEmpty else { throw SyncError("Enter the ingest token (HEALTHOS_INGEST_TOKEN in the server's .env).") }

            // A different server has none of our history: start over.
            if state.server != base.absoluteString {
                state = SyncState(server: base.absoluteString, since: Config.history.start(from: Date()), last: state.last)
            }

            // 1. Which days changed since the last sync.
            var dirty = Set<String>()
            var anchors = state.anchors
            let types = HealthTypes.sampleTypes
            for (i, type) in types.enumerated() {
                await emit("Checking \(HealthTypes.label(type)) (\(i + 1)/\(types.count))")
                let anchor = state.anchors[type.identifier].flatMap {
                    try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: $0)
                }
                let changes = try await Health.shared.changes(for: type, after: anchor, since: state.since)
                dirty.formUnion(changes.dates)
                // Deleted samples don't say which day they were on. Recheck the last month; older edits need "Upload all history".
                if changes.sawDeletions, anchor != nil {
                    dirty.formUnion((0..<30).map { Day.add(Day.today(), -$0) })
                }
                if let a = changes.anchor {
                    anchors[type.identifier] = try NSKeyedArchiver.archivedData(withRootObject: a, requiringSecureCoding: true)
                }
            }
            let floor = state.since.map(Day.of)
            let latest = Day.add(Day.today(), 1)
            dirty = dirty.filter { $0 <= latest && (floor == nil || $0 >= floor!) }
            state.anchors = anchors
            state.pending = Set(state.pending).union(dirty).sorted()
            try state.save()

            // 2. Re-read each pending day in full and upload it, a week at a time.
            let client = IngestClient(base: base, token: token)
            let windows = Self.windows(state.pending)
            var days = 0, rows = 0
            for (i, window) in windows.enumerated() {
                await emit(windows.count == 1 && window.count == 1 ? "Uploading \(window[0])" : "Uploading \(window.first!) – \(window.last!) (\(i + 1)/\(windows.count))")
                let payload = try await Health.shared.payload(for: window)
                try await client.send(payload)
                let sent = Set(window)
                state.pending.removeAll { sent.contains($0) }
                try state.save()
                days += window.count
                rows += payload.rowCount
            }
            state.last = SyncReport(finishedAt: Date(), ok: true, message: days == 0 ? "Up to date" : "Sent \(days) day\(days == 1 ? "" : "s") (\(rows) rows)")
        } catch {
            let message = (error as? HKError)?.code == .errorDatabaseInaccessible
                ? "Health data is locked while the phone is locked. Will retry."
                : error.localizedDescription
            state.last = SyncReport(finishedAt: Date(), ok: false, message: message)
        }
        try? state.save()
        return state.last!
    }

    /// Groups sorted dates into runs spanning at most 7 days, so one read covers a run and memory stays bounded.
    static func windows(_ dates: [String]) -> [[String]] {
        var out: [[String]] = []
        for date in dates {
            if let first = out.last?.first, date <= Day.add(first, 6) {
                out[out.count - 1].append(date)
            } else {
                out.append([date])
            }
        }
        return out
    }
}
