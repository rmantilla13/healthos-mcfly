import Foundation
import Observation

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

    /// Plain-words notes for anything not ✓.
    var notes: [String] {
        [("Apple Health", apple), ("WHOOP", whoop)].compactMap { name, p in
            switch p {
            case .ok: nil
            case .skipped(let why), .failed(let why): "\(name): \(why)"
            }
        }
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
    @ObservationIgnored weak var dashboard: Dashboard?
    @ObservationIgnored private var lastAutoSync: Date?

    init() {
        Task { [weak self] in
            // Also hears about syncs started by background delivery while the app is open.
            await SyncEngine.shared.setListener { event in
                await MainActor.run { self?.handle(event) }
            }
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
            if report.ok, report.message != "Up to date" { NotificationCenter.default.post(name: .healthOSSynced, object: nil) }
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
    func syncAll() async {
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
        sources = SourcesSyncStatus(finishedAt: Date(), apple: apple, whoop: whoop)
        await dashboard?.load()
    }

    /// The same, on open and on return to the app, at most once a minute.
    func syncAllIfStale() async {
        if let lastAutoSync, Date().timeIntervalSince(lastAutoSync) < 60 { return }
        await syncAll()
    }

    private func syncWhoop() async -> SourcesSyncStatus.Part {
        guard let client = APIClient.current() else { return .skipped("Add your healthOS address in Settings.") }
        if dashboard?.phase == .signIn {
            return .skipped("Sign in to refresh it now. The server also syncs WHOOP every 6 hours.")
        }
        do {
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
            return .skipped("Sign in to refresh it now. The server also syncs WHOOP every 6 hours.")
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

/// Background delivery: observer queries that wake the app when Health data changes.
enum Background {
    static func apply() {
        if Config.backgroundSync && Config.healthRequested {
            Health.shared.startObserving { await SyncEngine.shared.sync() }
        } else {
            Health.shared.stopObserving()
        }
    }
}
