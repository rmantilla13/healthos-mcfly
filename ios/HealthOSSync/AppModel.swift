import Foundation
import Observation

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
        if !healthRequested { await requestHealthAccess() }
        syncing = true
        last = await SyncEngine.shared.sync()
        syncing = false
        progress = ""
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
