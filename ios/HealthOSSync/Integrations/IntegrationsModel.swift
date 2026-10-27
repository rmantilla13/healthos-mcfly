import Foundation
import Observation
import UIKit
import UniformTypeIdentifiers

/// Where Integrations reaches this iPhone itself: its ingest token and its Apple Health sync. The app's goes through
/// AppModel (whose token setter records the signed-in account as the token's owner, IngestTokenOwner) and SyncEngine.
/// Tests pass their own, so they never touch the Keychain token or the sync state of the app on the same simulator.
struct IntegrationsPhone {
    /// The token here now ("" for none).
    var token: @MainActor () -> String
    /// A token just made for the signed-in account: kept in the Keychain as theirs.
    var install: @MainActor (String) -> Void
    /// The token here stops being used.
    var remove: @MainActor () -> Void
    /// This iPhone's sync forgets what it sent, so the next sync sends its history again from the start.
    var resetSync: () async -> Void
    /// An empty push with `token` (it writes nothing): true when the server says it isn't a token any more (401), false
    /// when it took it, nil when it couldn't tell (offline).
    var tokenRejected: (String) async -> Bool?

    @MainActor
    static func app(_ sync: AppModel) -> IntegrationsPhone {
        IntegrationsPhone(
            token: { Config.token },
            install: { sync.token = $0 },
            remove: { sync.token = "" },
            resetSync: { await SyncEngine.shared.reset() },
            tokenRejected: { token in
                guard let base = Config.serverURL() else { return nil }
                do {
                    try await IngestClient(base: base, token: token).send(IngestPayload())
                    return false
                } catch let refused as IngestClient.Rejected {
                    return refused.status == 401
                } catch {
                    return nil
                }
            })
    }

    /// Nothing happens: previews and drawn pages.
    static let none = IntegrationsPhone(token: { "" }, install: { _ in }, remove: {}, resetSync: {}, tokenRejected: { _ in nil })
}

/// The page's requests, each made through `Dashboard.fetch` or `fetchForThisSession`. Tests answer in the server's place.
struct IntegrationsRequests {
    var status: (APIClient) async throws -> ServerStatus = { try await $0.status() }
    var syncNow: (APIClient) async throws -> ServerStatus = { try await $0.syncSources() }
    var fullSync: (APIClient) async throws -> ServerStatus = { try await $0.whoopFullSync() }
    var disconnect: (APIClient) async throws -> ServerStatus = { try await $0.whoopDisconnect() }
    var clearApple: (APIClient) async throws -> ServerStatus = { try await $0.clearAppleHealth() }
    var clearFitbit: (APIClient) async throws -> Void = { try await $0.clearFitbit() }
    var mint: (APIClient) async throws -> String = { try await $0.mintIngestToken() }
    var revoke: (APIClient) async throws -> ServerStatus = { try await $0.revokeIngestToken() }
}

/// Integrations' state, held above the page's DuoPage so a fold that swaps its panes keeps it (P4): what's being done,
/// each card's last error, the token shown once, the sheet and the open disclosures. One person's: it's forgotten the
/// moment the session changes (`follow`), and every answer that lands for another session is dropped.
@MainActor
@Observable
final class IntegrationsModel {
    enum Work: Hashable { case whoop, fitbitRemove, appleRemove, token, demo }

    /// The token just made, with the server it's for: shown once, in memory only.
    struct ShownToken: Equatable {
        let server: String
        let token: String
    }

    private(set) var busy: Set<Work> = []
    var whoopError: String?
    var fitbitError: String?
    var appleError: String?
    var tokenError: String?
    var demoError: String?
    private(set) var shown: ShownToken?
    /// The Fitbit import sheet (slice O's FitbitImportSheet).
    var fitbitOpen = false
    /// The question up now, if any: kept here, not in the card that asks, so a fold doesn't close it.
    enum Question: Hashable { case removeFitbit, removeApple, newToken, revokeToken }
    var asking: Question?
    /// "Set up this iPhone" and "Set up a WHOOP developer app", opened in place.
    var phoneSetupOpen = false
    var whoopStepsOpen = false
    /// The route's query: the ?whoop= banner after WHOOP's sign-in.
    var query: [String: String]
    /// Copied: the field whose copy button says so for a moment.
    var copied: String?

    @ObservationIgnored var phone: IntegrationsPhone = .none
    @ObservationIgnored var requests = IntegrationsRequests()
    @ObservationIgnored private var session: Dashboard.Session?

    init(query: [String: String] = [:]) {
        self.query = query
    }

    func isBusy(_ work: Work) -> Bool { busy.contains(work) }

    /// Called with the dashboard's session whenever it changes: another person, another server, a sign-out or a 401
    /// means nothing of the last one's stays (the token shown once above all).
    func follow(_ now: Dashboard.Session) {
        if let session, session != now { forget() }
        session = now
    }

    func forget() {
        busy = []
        whoopError = nil
        fitbitError = nil
        appleError = nil
        tokenError = nil
        demoError = nil
        shown = nil
        fitbitOpen = false
        asking = nil
        phoneSetupOpen = false
        whoopStepsOpen = false
        query = [:]
        copied = nil
    }

    // MARK: Reading the status

    /// The status again, for this person only (a late answer is nobody's).
    func refresh(_ dashboard: Dashboard) async {
        guard dashboard.phase == .ready, let status = try? await dashboard.fetchForThisSession(requests.status) else { return }
        dashboard.apply(status: status)
    }

    /// While the server says WHOOP is syncing (from here, the web or the iPhone's own Sync), the status is read every
    /// 3 seconds until it's done, then the dashboard loads again, as the web's App does.
    func watchWhoopSync(_ dashboard: Dashboard, every interval: Duration = .seconds(3)) async {
        while dashboard.status?.whoop?.syncing == true {
            try? await Task.sleep(for: interval)
            if Task.isCancelled { return }
            guard let status = try? await dashboard.fetchForThisSession(requests.status) else { continue }
            if status.whoop?.syncing == true {
                dashboard.apply(status: status)
            } else {
                // Not in this task: the new status ends it.
                Task { await dashboard.load() }
                return
            }
        }
    }

    // MARK: WHOOP

    func whoopSyncNow(_ dashboard: Dashboard) async { await whoop(dashboard, requests.syncNow) }
    func whoopFullYear(_ dashboard: Dashboard) async { await whoop(dashboard, requests.fullSync) }
    func whoopDisconnect(_ dashboard: Dashboard) async { await whoop(dashboard, requests.disconnect) }

    private func whoop(_ dashboard: Dashboard, _ request: (APIClient) async throws -> ServerStatus) async {
        guard !isBusy(.whoop) else { return }
        whoopError = nil
        busy.insert(.whoop)
        defer { busy.remove(.whoop) }
        do {
            dashboard.showChanged(try await dashboard.fetchForThisSession(request))
        } catch is CancellationError {
        } catch {
            whoopError = error.localizedDescription
        }
    }

    // MARK: Fitbit

    func removeFitbit(_ dashboard: Dashboard) async {
        guard !isBusy(.fitbitRemove) else { return }
        fitbitError = nil
        busy.insert(.fitbitRemove)
        defer { busy.remove(.fitbitRemove) }
        do {
            try await dashboard.fetchForThisSession(requests.clearFitbit)
        } catch is CancellationError {
            return
        } catch {
            fitbitError = error.localizedDescription
        }
        // Gone or not, what the server has now (the web refreshes either way).
        await dashboard.load()
    }

    // MARK: Apple Health

    /// POST /api/apple/clear for the person signed in, then, once the server has removed it, this iPhone's sync starts
    /// again from the beginning (IntegrationsRules.resetsSync). The reset follows the server's yes even if it lands after
    /// a sign-out: the data is gone either way. What's shown follows only for whoever is still here.
    func removeAppleHealth(_ dashboard: Dashboard) async {
        guard !isBusy(.appleRemove) else { return }
        appleError = nil
        busy.insert(.appleRemove)
        defer { busy.remove(.appleRemove) }
        let asked = dashboard.session
        let tokenBefore = phone.token()
        let owner = dashboard.ingestOwner.account
        let who = Self.account(dashboard)
        do {
            let status = try await dashboard.fetch(requests.clearApple)
            if IntegrationsRules.resetsSync(tokenOwner: owner, signedIn: who, tokenBefore: tokenBefore, tokenNow: phone.token()) {
                await phone.resetSync()
            }
            guard dashboard.stillCurrent(asked) else { return }
            dashboard.showChanged(status)
            await dashboard.load()
        } catch is CancellationError {
        } catch {
            if dashboard.stillCurrent(asked) { appleError = error.localizedDescription }
        }
    }

    // MARK: The iPhone app token

    /// Makes a token for the signed-in account and keeps it on this iPhone, as theirs. One that lands after a sign-out,
    /// a 401, someone else's sign-in or another server is never kept or shown: it would send this phone's Health data to
    /// the last person's account. Shown once, with the server's address, for another device.
    func setUpThisPhone(_ dashboard: Dashboard) async {
        guard !isBusy(.token) else { return }
        tokenError = nil
        busy.insert(.token)
        defer { busy.remove(.token) }
        do {
            let minted = try await dashboard.fetchForThisSession(requests.mint)
            phone.install(minted)
            shown = ShownToken(server: dashboard.session.server, token: minted)
            phoneSetupOpen = true
            await refresh(dashboard)
        } catch is CancellationError {
        } catch {
            tokenError = error.localizedDescription
        }
    }

    /// Revokes the account's token. This iPhone's, when it's this account's and the server no longer takes it, goes too,
    /// so the sync stops trying.
    func revoke(_ dashboard: Dashboard) async {
        guard !isBusy(.token) else { return }
        tokenError = nil
        busy.insert(.token)
        defer { busy.remove(.token) }
        let asked = dashboard.session
        do {
            dashboard.showChanged(try await dashboard.fetchForThisSession(requests.revoke))
            shown = nil
            let token = phone.token()
            guard IntegrationsRules.phoneIsThisAccounts(hasToken: !token.isEmpty, tokenOwner: dashboard.ingestOwner.account, signedIn: Self.account(dashboard)),
                  await phone.tokenRejected(token) == true,
                  phone.token() == token, dashboard.stillCurrent(asked) else { return }
            phone.remove()
        } catch is CancellationError {
        } catch {
            tokenError = error.localizedDescription
        }
    }

    // MARK: Demo data

    func setDemo(_ mode: String, _ dashboard: Dashboard) async {
        guard !isBusy(.demo) else { return }
        demoError = nil
        busy.insert(.demo)
        defer { busy.remove(.demo) }
        do {
            try await dashboard.save(settings: ["demo": mode], reload: true)
        } catch is CancellationError {
        } catch {
            demoError = error.localizedDescription
        }
    }

    // MARK: Copying

    /// To the pasteboard, this device only; the token for two minutes.
    func copy(_ value: String, field: String, secret: Bool) {
        var options: [UIPasteboard.OptionsKey: Any] = [.localOnly: true]
        if secret { options[.expirationDate] = Date().addingTimeInterval(120) }
        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: value]], options: options)
        copied = field
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            if self?.copied == field { self?.copied = nil }
        }
    }

    // MARK: Who

    /// The account signed in now, as the token's owner is kept (the sign-in's answer, or the last status read's).
    static func account(_ dashboard: Dashboard) -> IngestTokenOwner.Account? {
        let user = dashboard.account?.id != nil ? dashboard.account : dashboard.status?.user
        return user?.id.map { IngestTokenOwner.Account(server: dashboard.session.server, id: $0, email: user?.email) }
    }

    #if DEBUG
    /// Drawn tests only: a token as if just made.
    func show(_ token: ShownToken) {
        shown = token
        phoneSetupOpen = true
    }
    #endif
}
