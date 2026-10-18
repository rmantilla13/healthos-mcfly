import BackgroundTasks
import Foundation
import Observation
import UIKit

/// The outcome of one Sync: Apple Health pushed from this phone, WHOOP refreshed on the server.
struct SourcesSyncStatus: Equatable {
    enum Part: Equatable {
        case ok
        /// Nothing went wrong, but this source wasn't synced (not set up, not signed in); the text says why.
        case skipped(String)
        case failed(String)
    }

    var finishedAt: Date
    var apple: Part
    var whoop: Part
    /// A tip that isn't a problem, shown with the notes.
    var hint: String?

    var ok: Bool {
        if case .failed = apple { return false }
        if case .failed = whoop { return false }
        return true
    }

    /// "Apple Health ✓ · WHOOP ✓"
    var summary: String {
        func mark(_ p: Part) -> String {
            switch p {
            case .ok: "✓"
            case .skipped: "–"
            case .failed: "!"
            }
        }
        return "Apple Health \(mark(apple)) · WHOOP \(mark(whoop))"
    }

    /// Plain-words notes for anything not ✓, then the hint.
    var notes: [String] {
        [("Apple Health", apple), ("WHOOP", whoop)].compactMap { name, p in
            switch p {
            case .ok: nil
            case .skipped(let why), .failed(let why): "\(name): \(why)"
            }
        } + [hint].compactMap { $0 }
    }
}

@MainActor
@Observable
final class AppModel {
    var serverText = Config.serverText { didSet { Config.serverText = serverText } }
    var token = Config.token { didSet { Config.token = token } }
    var history = Config.history { didSet { Config.history = history } }
    var backgroundSync = Config.backgroundSync {
        didSet {
            Config.backgroundSync = backgroundSync
            Background.apply()
        }
    }
    var healthRequested = Config.healthRequested

    var syncing = false
    var progress = ""
    var last: SyncReport? = SyncState.load().last
    var notice: String?
    var working = false
    /// The last Sync (Apple Health + WHOOP), shown on Today and in Settings.
    var sources: SourcesSyncStatus?
    var syncingSources = false
    /// Older days still going up in the background of the open app (first upload, or the hourly backfill).
    var backfillLeft = 0
    @ObservationIgnored weak var dashboard: Dashboard?
    @ObservationIgnored private var lastAutoSync: Date?

    init() {
        Task { [weak self] in
            // Also hears about syncs started by background delivery while the app is open.
            await SyncEngine.shared.setListener { event in
                await MainActor.run { self?.handle(event) }
            }
            await SyncEngine.shared.setBackfillGate { await Background.backfillAllowed() }
        }
    }

    private func handle(_ event: SyncEvent) {
        switch event {
        case .progress(let message):
            syncing = true
            progress = message
        case .finished(let report):
            syncing = false
            progress = ""
            last = report
            if report.ok { NotificationCenter.default.post(name: .healthOSSynced, object: nil) }
        case .backfill(let left, _):
            let before = backfillLeft
            backfillLeft = left
            // Once, when the history is all up; between passes the minute check is enough, so the dashboard
            // isn't downloaded again after every few weeks of history.
            if left == 0, before > 0 { NotificationCenter.default.post(name: .healthOSSynced, object: nil) }
        }
    }

    var serverValid: Bool { Config.serverURL(serverText) != nil }

    func requestHealthAccess() async {
        do {
            try await Health.shared.requestAuthorization()
            healthRequested = true
            Config.healthRequested = true
            Background.apply()
        } catch {
            notice = "Health access failed: \(error.localizedDescription)"
        }
    }

    func syncNow() async {
        // Every time, not just the first: Health only asks about types not decided yet, such as ones a newer
        // version of the app reads (Apple Watch RMSSD), and returns at once otherwise.
        await requestHealthAccess()
        syncing = true
        last = await SyncEngine.shared.sync()
        syncing = false
        progress = ""
    }

    /// One Sync for everything: push this phone's Health data, then ask the server to refresh WHOOP and wait
    /// for it, then reload the dashboard. Runs on open, on return to the app, on pull to refresh and from Sync now.
    /// `force` (pull to refresh, Sync now) reloads the dashboard even when the server's data version didn't change.
    func syncAll(force: Bool = false) async {
        guard !syncingSources else { return }
        syncingSources = true
        defer { syncingSources = false }
        lastAutoSync = Date()

        let apple: SourcesSyncStatus.Part
        if Config.serverURL() == nil {
            apple = .skipped("Add your healthOS address in Settings.")
        } else if Config.token.isEmpty {
            apple = .skipped("Paste your ingest token in Settings (dashboard → Integrations → iPhone app).")
        } else {
            await syncNow()
            apple = last.map { $0.ok ? .ok : .failed($0.message) } ?? .failed("Didn't run.")
        }
        let whoop = await syncWhoop()
        // WHOOP's daily steps come from its API either way; its hourly steps need WHOOP to write them into Health.
        let hint: String? = (apple == .ok && whoop == .ok && !Config.sawWhoopSteps)
            ? "For WHOOP steps by the hour, allow Health → Apps → WHOOP → Steps." : nil
        sources = SourcesSyncStatus(finishedAt: Date(), apple: apple, whoop: whoop, hint: hint)
        if force { await dashboard?.load() } else { await dashboard?.refreshIfChanged(includeStatus: true) }
        // Older history keeps going up after today and the recent month are on the server.
        if case .ok = apple { await SyncEngine.shared.continueBackfill() }
    }

    /// The same, on open and on return to the app, at most once a minute; otherwise just a check for new data.
    func syncAllIfStale() async {
        if let lastAutoSync, Date().timeIntervalSince(lastAutoSync) < 60 {
            await dashboard?.refreshIfChanged(includeStatus: true)
            await SyncEngine.shared.continueBackfill()
            return
        }
        await syncAll()
    }

    private func syncWhoop() async -> SourcesSyncStatus.Part {
        guard let client = APIClient.current() else { return .skipped("Add your healthOS address in Settings.") }
        if dashboard?.phase == .signIn {
            return .skipped("Sign in to refresh it now. The server also syncs WHOOP every hour.")
        }
        do {
            await ServerSync.shared.markRequested()
            var status = try await client.syncSources()
            guard status.whoop?.connected == true else {
                return .skipped("Not connected. Connect it on the healthOS website.")
            }
            // A started sync runs on the server; check about every 3 s, for up to 90 s.
            var waited = 0.0
            while status.whoop?.syncing == true, waited < 90 {
                try await Task.sleep(for: .seconds(3))
                waited += 3
                status = try await client.status()
            }
            if let error = status.whoop?.lastError, !error.isEmpty { return .failed(error) }
            if status.whoop?.syncing == true { return .skipped("Still syncing on the server. It'll show up soon.") }
            return .ok
        } catch APIError.signInRequired {
            return .skipped("Sign in to refresh it now. The server also syncs WHOOP every hour.")
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    func testConnection() async {
        guard let base = Config.serverURL(serverText) else { return notice = "That server URL isn't valid." }
        working = true
        defer { working = false }
        do {
            try await IngestClient(base: base, token: token).send(IngestPayload())
            notice = "Connected. The server accepted the token."
        } catch {
            notice = error.localizedDescription
        }
    }

    func uploadAllHistory() async {
        await SyncEngine.shared.reset()
        await syncNow()
        await SyncEngine.shared.continueBackfill()
    }

    #if targetEnvironment(simulator)
    func addSampleData() async {
        if !healthRequested { await requestHealthAccess() }
        working = true
        defer { working = false }
        do {
            let n = try await SampleData.write()
            notice = "Wrote \(n) sample records to Health."
        } catch {
            notice = "Couldn't write sample data: \(error.localizedDescription)"
        }
    }
    #endif
}

/// Background sync: HealthKit observer queries wake the app when Health data changes, and an app refresh task
/// is the backstop when they don't. Either pushes the changed recent days, then asks the server to refresh WHOOP.
enum Background {
    static let refreshTask = "health.mcfly.sync.refresh"

    static func apply() {
        if Config.backgroundSync && Config.healthRequested {
            Health.shared.startObserving { await wake() }
            schedule()
        } else {
            Health.shared.stopObserving()
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: refreshTask)
        }
    }

    /// One background wake: changed recent days only (never the history backfill), then a throttled server refresh.
    /// Skipped in Low Power Mode; the anchors don't move, so the next wake or open catches up.
    static func wake() async {
        let foreground = await MainActor.run { UIApplication.shared.applicationState == .active }
        if !foreground, ProcessInfo.processInfo.isLowPowerModeEnabled { return }
        await SyncEngine.shared.sync()
        // Even when Health couldn't be read (a locked phone), so WHOOP still refreshes on the server.
        if !foreground { await ServerSync.shared.requestIfDue() }
    }

    /// History goes up only while the app is open and not in Low Power Mode.
    static func backfillAllowed() async -> Bool {
        let active = await MainActor.run { UIApplication.shared.applicationState == .active }
        return active && !ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    /// Registers the app refresh handler; must run before launch finishes.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshTask, using: nil) { task in
            schedule()
            let done = Once()
            Task {
                await wake()
                if done.claim() { task.setTaskCompleted(success: true) }
            }
            task.expirationHandler = {
                if done.claim() { task.setTaskCompleted(success: false) }
            }
        }
    }

    /// Asks iOS for a refresh in about an hour; iOS decides when (and whether) it runs.
    static func schedule() {
        guard Config.backgroundSync, Config.healthRequested, !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }
        let request = BGAppRefreshTaskRequest(identifier: refreshTask)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 3600)
        try? BGTaskScheduler.shared.submit(request)
    }
}

/// POST /api/sync from background wakes, so the server refreshes WHOOP too. At most every 15 minutes (counting the
/// app's own Sync), so a stream of step updates doesn't start a WHOOP sync each. Fire and forget: no polling here.
actor ServerSync {
    static let shared = ServerSync()
    /// Saved, because HealthKit often launches the app fresh for a wake.
    private var lastRequest: Date? {
        get { UserDefaults.standard.object(forKey: "serverSyncRequestedAt") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "serverSyncRequestedAt") }
    }

    func markRequested() { lastRequest = Date() }

    func requestIfDue() async {
        if let lastRequest, Date().timeIntervalSince(lastRequest) < 15 * 60 { return }
        guard let client = APIClient.current() else { return }
        lastRequest = Date()
        _ = try? await client.syncSources()
    }
}

/// Lets exactly one of two racing paths (work finished, time expired) complete a background task.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
