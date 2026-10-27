import SwiftUI
import XCTest
@testable import HealthOSSync

/// Integrations (slice M, G54 and G55): the words against the web's own file, what each card shows from the status,
/// the token made for this iPhone (kept as the signed-in account's, never after a sign-out), Remove Apple Health data
/// resetting this iPhone's sync, and Revoke. Nothing here reaches a server, the Keychain token or the sync state of the
/// app on this simulator: the page's requests and its reach into the phone are the tests' own.
@MainActor
final class IntegrationsTests: XCTestCase {
    private var savedServer: String?
    /// Nothing listens here; requests never go to it (the tests answer in the server's place).
    private let base = URL(string: "http://127.0.0.1:9")!

    override func setUp() async throws {
        savedServer = UserDefaults.standard.string(forKey: "serverURL")
        Config.serverText = base.absoluteString
    }

    override func tearDown() async throws {
        SummaryCache.clear(for: base)
        if let savedServer { UserDefaults.standard.set(savedServer, forKey: "serverURL") } else { UserDefaults.standard.removeObject(forKey: "serverURL") }
    }

    /// A file of the web app, its runs of spaces made one and its JSX markup (`<code>`, `{' '}`) taken out, so text
    /// that wraps reads as the sentence it is.
    private func web(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(path)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { throw XCTSkip("\(path) isn't next to the app") }
        return text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "{' '}", with: "")
            .replacingOccurrences(of: #"</?(code|b)>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    static func status(_ json: String) throws -> ServerStatus { try JSONDecoder().decode(ServerStatus.self, from: Data(json.utf8)) }

    private func whoop(_ json: String) throws -> ServerStatus.Whoop {
        try XCTUnwrap(try Self.status(#"{"whoop":\#(json)}"#).whoop)
    }

    private func apple(_ json: String) throws -> ServerStatus.Apple {
        try XCTUnwrap(try Self.status(#"{"apple":\#(json)}"#).apple)
    }

    private func person(_ id: String) -> AuthState.User { AuthState.User(id: id, email: "\(id)@example.test", name: nil, role: "member") }

    // MARK: Words

    func testTheWordsAreTheWebsOwn() throws {
        let page = try web("src/pages/Integrations.tsx")
        let words = [
            IntegrationsWords.title, IntegrationsWords.sub, IntegrationsWords.whoopConnected, IntegrationsWords.whoopFailedMember,
            IntegrationsWords.whoopFailed(""), IntegrationsWords.whoopNotConfiguredLocal, IntegrationsWords.whoopNotConfiguredAdmin,
            IntegrationsWords.whoopNotConfiguredMember, IntegrationsWords.whoopBody, IntegrationsWords.whoopAway, IntegrationsWords.whoopAdminSetup,
            IntegrationsWords.whoopMemberOff, IntegrationsWords.whoopDeveloperApp, IntegrationsWords.whoopStepSignIn, IntegrationsWords.whoopStepRedirect,
            IntegrationsWords.whoopStepScopes, IntegrationsWords.whoopStepEnv, IntegrationsWords.whoopLastError(""), "developer.whoop.com",
            IntegrationsWords.fitbitTitle, IntegrationsWords.fitbitBody, IntegrationsWords.fitbitFoot, IntegrationsWords.fitbitRemoveAsk,
            IntegrationsWords.appleTitle, IntegrationsWords.appleBody, IntegrationsWords.appleExportOnMac, IntegrationsWords.appleAdminImport,
            IntegrationsWords.appleRemoveAsk, IntegrationsWords.appleUploading, IntegrationsWords.appleReading(""), IntegrationsWords.appleSynced(""),
            IntegrationsWords.tokenSet, IntegrationsWords.noToken, IntegrationsWords.tokenScope, IntegrationsWords.tokenShownOnce,
            IntegrationsWords.newTokenAsk, IntegrationsWords.revokeAsk, IntegrationsWords.noteTitle, IntegrationsWords.note,
            IntegrationsWords.demoTitle, IntegrationsWords.demoAuto, "Showing synthetic data. ", "Showing your data. ",
            // Chips, states and buttons.
            "Needs attention", "Syncing…", "Connected", "Ready to connect", "Not available yet", "Needs a developer app",
            "File import available", "Syncing from iPhone", "Importing…", "Imported ", "Syncing now…", "Synced ", "Not synced yet",
            "· syncs every hour", " while healthOS is running", "Sync now", "Re-sync full year", "Disconnect", "Connect WHOOP",
            "Import again", "Import Fitbit data", "Remove Fitbit data", "Remove Apple Health data", "Create a new token", "Revoke",
            "Copy redirect URL", "Copy server address", "Copy token", "Server", "Token", "'day' : 'days'",
        ]
        for w in words { XCTAssertTrue(page.contains(w), "Integrations.tsx says \"\(w)\"") }
        for (value, title) in IntegrationsWords.demoModes {
            XCTAssertTrue(page.contains("'\(value)' ? '\(title)'") || page.contains(": '\(title)'"), title)
        }
        XCTAssertTrue(page.contains("tile=\"W\"") && page.contains("tile=\"G\"") && page.contains("tile=\"⌘\""), "the tiles' letters")
    }

    // MARK: Times and dates

    func testAgoIsTheWebs() {
        let now = ISO8601DateFormatter.lenient("2026-10-27T12:00:00Z")!
        XCTAssertEqual(IntegrationsWords.ago("2026-10-27T11:59:40.000Z", now: now), "just now")
        XCTAssertEqual(IntegrationsWords.ago("2026-10-27T11:48:00Z", now: now), "12 min ago")
        XCTAssertEqual(IntegrationsWords.ago("2026-10-27T07:00:00Z", now: now), "5 h ago")
        XCTAssertEqual(IntegrationsWords.ago("2026-10-25T13:00:00Z", now: now), "47 h ago")
        let day = IntegrationsWords.ago("2026-10-20T09:00:00Z", now: now)
        XCTAssertTrue(day?.contains("2026") == true && day?.contains("20") == true, day ?? "nil")
        XCTAssertNil(IntegrationsWords.ago("not a time", now: now))
    }

    func testSpansAndDays() {
        XCTAssertEqual(IntegrationsWords.days(1), "1 day")
        XCTAssertEqual(IntegrationsWords.days(1204), "\(1204.formatted()) days")
        let span = IntegrationsWords.span("2021-03-02", "2026-10-20")
        XCTAssertTrue(span?.contains("2021") == true && span?.contains("2026") == true && span?.contains(" – ") == true, span ?? "nil")
        XCTAssertNil(IntegrationsWords.span("2021-03-02", nil))
    }

    // MARK: WHOOP

    func testWhoopChipFollowsTheStatus() throws {
        func chip(_ json: String, hosted: Bool = true, admin: Bool = false) throws -> String {
            IntegrationsRules.whoopChip(try whoop(json), hosted: hosted, admin: admin).text
        }
        XCTAssertEqual(try chip(#"{"configured":true,"connected":true,"lastError":"WHOOP said no"}"#), "Needs attention")
        XCTAssertEqual(try chip(#"{"configured":true,"connected":true,"syncing":true}"#), "Syncing…")
        XCTAssertEqual(try chip(#"{"configured":true,"connected":true,"syncing":false}"#), "Connected")
        XCTAssertEqual(try chip(#"{"configured":true,"connected":false}"#), "Ready to connect")
        XCTAssertEqual(try chip(#"{"configured":false,"connected":false}"#), "Not available yet", "a member on the hosted server")
        XCTAssertEqual(try chip(#"{"configured":false,"connected":false}"#, admin: true), "Needs a developer app")
        XCTAssertEqual(try chip(#"{"configured":false,"connected":false}"#, hosted: false), "Needs a developer app")
    }

    func testWhoopState() throws {
        let now = ISO8601DateFormatter.lenient("2026-10-27T12:00:00Z")!
        XCTAssertNil(IntegrationsRules.whoopState(try whoop(#"{"connected":false}"#), hosted: true, now: now))
        XCTAssertEqual(IntegrationsRules.whoopState(try whoop(#"{"connected":true,"syncing":true}"#), hosted: true, now: now), "Syncing now… · syncs every hour")
        XCTAssertEqual(IntegrationsRules.whoopState(try whoop(#"{"connected":true,"lastSync":"2026-10-27T11:48:00Z"}"#), hosted: false, now: now),
                       "Synced 12 min ago · syncs every hour while healthOS is running")
        XCTAssertEqual(IntegrationsRules.whoopState(try whoop(#"{"connected":true}"#), hosted: true, now: now), "Not synced yet · syncs every hour")
    }

    /// Connect WHOOP opens the web's Integrations page in Safari: /api/whoop/connect needs the web's session cookie,
    /// which the app's session isn't.
    func testConnectOpensTheWebsIntegrationsPage() {
        XCTAssertEqual(IntegrationsRules.connectURL(server: URL(string: "http://localhost:8801")!)?.absoluteString, "http://localhost:8801/#/integrations")
        XCTAssertEqual(IntegrationsRules.connectURL(server: URL(string: "https://health.example.test/")!)?.absoluteString,
                       "https://health.example.test/#/integrations")
    }

    func testWhoopBanners() {
        XCTAssertEqual(IntegrationsRules.banner(query: ["whoop": "connected"], hosted: true, admin: false)?.good, true)
        XCTAssertEqual(IntegrationsRules.banner(query: ["whoop": "error", "message": "bad code"], hosted: true, admin: false)?.text,
                       IntegrationsWords.whoopFailedMember, "WHOOP's own words only for admins")
        XCTAssertEqual(IntegrationsRules.banner(query: ["whoop": "error", "message": "bad code"], hosted: true, admin: true)?.text,
                       "WHOOP connection failed: bad code")
        XCTAssertEqual(IntegrationsRules.banner(query: ["whoop": "not-configured"], hosted: false, admin: false)?.text, IntegrationsWords.whoopNotConfiguredLocal)
        XCTAssertNil(IntegrationsRules.banner(query: [:], hosted: true, admin: false))
        XCTAssertNil(IntegrationsRules.banner(query: ["whoop": "something new"], hosted: true, admin: false))
    }

    // MARK: Fitbit and Apple Health

    func testFitbitShowsWhatWasImported() throws {
        let none = try XCTUnwrap(try Self.status(#"{"fitbit":{"lastImport":null}}"#).fitbit)
        XCTAssertEqual(IntegrationsRules.fitbitChip(none).text, "File import available")
        XCTAssertNil(IntegrationsRules.fitbitState(none))
        let some = try XCTUnwrap(try Self.status(#"{"fitbit":{"lastImport":{"days":1,"firstDate":"2026-10-01","lastDate":"2026-10-01","metrics":[],"importedAt":"2026-10-23T10:00:00Z"}}}"#).fitbit)
        XCTAssertTrue(IntegrationsRules.fitbitChip(some).text.hasPrefix("Imported "))
        XCTAssertTrue(IntegrationsRules.fitbitState(some)?.hasPrefix("1 day · ") == true)
        XCTAssertNil(try Self.status(#"{"hosted":true}"#).fitbit, "an older server's status has no fitbit, so the card doesn't show")
    }

    func testAppleChipAndWhenRemoveShows() throws {
        let phone = try apple(#"{"lastSync":{"syncedAt":"2026-10-27T10:00:00Z"},"job":{"state":"idle"}}"#)
        XCTAssertEqual(IntegrationsRules.appleChip(phone, hosted: true).text, "Syncing from iPhone")
        XCTAssertEqual(IntegrationsRules.appleChip(try apple(#"{"iphoneToken":true}"#), hosted: true).text, "Syncing from iPhone")
        XCTAssertEqual(IntegrationsRules.appleChip(try apple(#"{"job":{"state":"parsing"}}"#), hosted: false).text, "Importing…")
        XCTAssertEqual(IntegrationsRules.appleChip(try apple(#"{"job":{"state":"idle"}}"#), hosted: true).text, "Ready to connect")
        XCTAssertEqual(IntegrationsRules.appleChip(try apple(#"{"job":{"state":"idle"}}"#), hosted: false).text, "File import available")
        // Remove shows while the server holds Apple Health data: the iPhone's sync counts, not only an export's import.
        XCTAssertTrue(IntegrationsRules.showsRemoveApple(phone))
        XCTAssertTrue(IntegrationsRules.showsRemoveApple(try apple(#"{"lastImport":{"importedAt":"2026-10-01T10:00:00Z"}}"#)))
        XCTAssertFalse(IntegrationsRules.showsRemoveApple(try apple(#"{"lastImport":{"importedAt":"2026-10-01T10:00:00Z"},"job":{"state":"uploading"}}"#)),
                       "not while an export import runs (the server answers 409)")
        XCTAssertFalse(IntegrationsRules.showsRemoveApple(try apple(#"{"iphoneToken":true}"#)), "a token, but nothing sent yet")
        XCTAssertFalse(IntegrationsRules.showsRemoveApple(nil), "no status part: nothing said")
    }

    func testAppleStaleOnlyOnTheHostedServer() throws {
        let now = ISO8601DateFormatter.lenient("2026-10-27T12:00:00Z")!
        let old = try apple(#"{"lastSync":{"syncedAt":"2026-10-25T10:00:00Z"}}"#)
        XCTAssertTrue(IntegrationsRules.appleStale(old, hosted: true, now: now))
        XCTAssertFalse(IntegrationsRules.appleStale(old, hosted: false, now: now))
        XCTAssertFalse(IntegrationsRules.appleStale(try apple(#"{"lastSync":{"syncedAt":"2026-10-27T10:00:00Z"}}"#), hosted: true, now: now))
        XCTAssertTrue(IntegrationsRules.appleStale(try apple(#"{"iphoneToken":true}"#), hosted: true, now: now), "a token and nothing ever sent")
        XCTAssertFalse(IntegrationsRules.appleStale(try apple(#"{}"#), hosted: true, now: now), "no iPhone")
    }

    func testTheSyncResetsOnlyForThisAccountsToken() {
        let sam = IngestTokenOwner.Account(server: "http://a", id: "u-sam", email: "sam@example.test")
        let alex = IngestTokenOwner.Account(server: "http://a", id: "u-alex", email: "alex@example.test")
        XCTAssertTrue(IntegrationsRules.resetsSync(tokenOwner: sam, signedIn: sam, tokenBefore: "t", tokenNow: "t"))
        XCTAssertTrue(IntegrationsRules.resetsSync(tokenOwner: nil, signedIn: sam, tokenBefore: "", tokenNow: ""), "no token: the next one starts over")
        XCTAssertFalse(IntegrationsRules.resetsSync(tokenOwner: alex, signedIn: sam, tokenBefore: "t", tokenNow: "t"), "another account's sync")
        XCTAssertFalse(IntegrationsRules.resetsSync(tokenOwner: sam, signedIn: sam, tokenBefore: "t", tokenNow: "u"), "a token set up since")
        XCTAssertFalse(IntegrationsRules.resetsSync(tokenOwner: sam, signedIn: nil, tokenBefore: "t", tokenNow: "t"))
    }

    func testSetUpThisIPhoneOnlyWithAccounts() {
        XCTAssertTrue(IntegrationsRules.showsPhoneSetup(authMode: "required", phase: .ready))
        XCTAssertFalse(IntegrationsRules.showsPhoneSetup(authMode: "open", phase: .ready), "no account row to hold a token")
        XCTAssertFalse(IntegrationsRules.showsPhoneSetup(authMode: nil, phase: .ready), "not known yet: nothing said")
        XCTAssertFalse(IntegrationsRules.showsPhoneSetup(authMode: "required", phase: .signIn))
    }

    func testDemoOnlyForTheLocalOwner() throws {
        XCTAssertTrue(IntegrationsRules.showsDemo(try Self.status(#"{"hosted":false,"user":{"id":"owner"}}"#)))
        XCTAssertFalse(IntegrationsRules.showsDemo(try Self.status(#"{"hosted":true,"user":{"id":"owner"}}"#)))
        XCTAssertFalse(IntegrationsRules.showsDemo(try Self.status(#"{"hosted":false,"user":{"id":"u-sam"}}"#)))
        XCTAssertFalse(IntegrationsRules.showsDemo(try Self.status(#"{"user":{"id":"owner"}}"#)), "hosted unknown: not shown")
    }

    // MARK: The model

    /// A phone that keeps its token in a MemoryTokenStore, as AppModel does in the Keychain: setting it tells the
    /// dashboard, which records the signed-in account as its owner.
    private final class FakePhone {
        let store: MemoryTokenStore
        var resets = 0
        var rejected: Bool? = true
        weak var dashboard: Dashboard?

        init(store: MemoryTokenStore) { self.store = store }

        @MainActor var phone: IntegrationsPhone {
            IntegrationsPhone(token: { self.store.token },
                              install: { self.store.token = $0; self.dashboard?.ingestTokenChanged() },
                              remove: { self.store.token = ""; self.dashboard?.ingestTokenChanged() },
                              resetSync: { self.resets += 1 },
                              tokenRejected: { _ in self.rejected })
        }
    }

    private func samSignedIn(_ store: MemoryTokenStore) -> Dashboard {
        let d = Dashboard(tokenStore: store)
        d.authMode = "required"
        d.account = person("u-sam")
        d.signedIn()
        return d
    }

    private let samsStatus = #"{"hosted":true,"user":{"id":"u-sam","email":"u-sam@example.test","role":"member"},"apple":{"lastSync":{"syncedAt":"2026-10-27T10:00:00Z"},"iphoneToken":true},"whoop":{"configured":true,"connected":true,"syncing":false},"fitbit":{"lastImport":null}}"#

    /// Set up this iPhone keeps the token here as the signed-in account's (so sign-out pauses it and anyone else's
    /// sign-in removes it), and shows it once.
    func testSetUpKeepsTheTokenAsThisAccounts() async throws {
        let store = MemoryTokenStore()
        let d = samSignedIn(store)
        let fake = FakePhone(store: store)
        fake.dashboard = d
        let m = IntegrationsModel()
        m.phone = fake.phone
        let status = try Self.status(samsStatus)
        m.requests = IntegrationsRequests(status: { _ in status }, mint: { _ in "made-up-token" })
        m.follow(d.session)
        await m.setUpThisPhone(d)
        XCTAssertEqual(store.token, "made-up-token")
        XCTAssertEqual(d.ingestOwner.account?.id, "u-sam", "the token is Sam's")
        XCTAssertEqual(m.shown, IntegrationsModel.ShownToken(server: base.absoluteString, token: "made-up-token"))
        XCTAssertTrue(m.phoneSetupOpen)
        XCTAssertEqual(d.status?.apple?.iphoneToken, true, "the status read again")

        // Sign out: the sync waits, and nothing of the token stays on the page.
        d.ingestSignedOut()
        d.phase = .signIn
        m.follow(d.session)
        XCTAssertTrue(d.ingestOwner.paused)
        XCTAssertNil(m.shown)
        // Alex signs in on this phone: the token goes, so his Health data never reaches Sam's account.
        d.account = person("u-alex")
        d.signedIn()
        XCTAssertEqual(store.token, "", "removed")
        XCTAssertTrue(d.ingestOwner.setUpAgain)
    }

    /// A token whose answer lands after a sign-out (or anyone else's sign-in, or another server) is never kept or shown:
    /// it would send this phone's Health data to the last person's account.
    func testATokenAnsweredTooLateIsNeverKept() async throws {
        let cases: [(String, @MainActor (Dashboard) -> Void)] = [
            ("signed out", { d in d.phase = .signIn }),
            ("someone else", { d in
                d.phase = .signIn
                d.account = self.person("u-alex")
                d.signedIn()
            }),
            ("another server", { _ in Config.serverText = "http://127.0.0.1:10" }),
        ]
        for (name, meanwhile) in cases {
            Config.serverText = base.absoluteString
            let store = MemoryTokenStore()
            let d = samSignedIn(store)
            let fake = FakePhone(store: store)
            fake.dashboard = d
            let m = IntegrationsModel()
            m.phone = fake.phone
            m.requests = IntegrationsRequests(mint: { _ in
                try await Task.sleep(for: .milliseconds(300))
                return "made-up-token"
            })
            let task = Task { await m.setUpThisPhone(d) }
            try await Task.sleep(for: .milliseconds(60))
            meanwhile(d)
            await task.value
            XCTAssertEqual(store.token, "", name)
            XCTAssertNil(m.shown, name)
            XCTAssertNil(m.tokenError, "\(name): nothing to say")
        }
    }

    func testARefusedSetUpSaysTheServersWords() async throws {
        let store = MemoryTokenStore()
        let d = samSignedIn(store)
        let m = IntegrationsModel()
        m.phone = FakePhone(store: store).phone
        m.requests = IntegrationsRequests(mint: { _ in
            throw APIClient.error(status: 400, message: "Set HEALTHOS_INGEST_TOKEN in .env for the iPhone app on this Mac.", path: "/me/ingest-token")
        })
        await m.setUpThisPhone(d)
        XCTAssertEqual(m.tokenError, "Set HEALTHOS_INGEST_TOKEN in .env for the iPhone app on this Mac.")
        XCTAssertEqual(store.token, "")
    }

    /// Remove Apple Health data: once the server says it's gone, this iPhone's sync starts again from the beginning, if
    /// the token here is this account's.
    func testRemovingAppleHealthResetsThisPhonesSync() async throws {
        let store = MemoryTokenStore()
        let d = samSignedIn(store)
        let fake = FakePhone(store: store)
        fake.dashboard = d
        store.token = "sams-token"
        d.ingestTokenChanged()
        let m = IntegrationsModel()
        m.phone = fake.phone
        let cleared = try Self.status(#"{"hosted":true,"user":{"id":"u-sam"},"apple":{"lastSync":null,"lastImport":null,"iphoneToken":true}}"#)
        m.requests = IntegrationsRequests(clearApple: { _ in cleared })
        await m.removeAppleHealth(d)
        XCTAssertEqual(fake.resets, 1)
        XCTAssertNil(d.status?.apple?.lastSync, "the answer shows")
        XCTAssertNil(m.appleError)

        // Refused (an export import running): nothing reset, the server's words.
        m.requests = IntegrationsRequests(clearApple: { _ in throw APIClient.error(status: 409, message: "An import is running", path: "/apple/clear") })
        await m.removeAppleHealth(d)
        XCTAssertEqual(fake.resets, 1)
        XCTAssertEqual(m.appleError, "An import is running")
    }

    func testRemovingAppleHealthLeavesAnotherAccountsSyncAlone() async throws {
        let store = MemoryTokenStore()
        // The token here is Alex's (it would be removed at Sam's sign-in; here it's put back as if it weren't).
        store.token = "alexs-token"
        store.owner = IngestTokenOwner(account: IngestTokenOwner.Account(server: base.absoluteString, id: "u-alex", email: nil))
        let d = Dashboard(tokenStore: store)
        d.authMode = "required"
        d.account = person("u-sam")
        d.phase = .ready
        let fake = FakePhone(store: store)
        let m = IntegrationsModel()
        m.phone = fake.phone
        let cleared = try Self.status(#"{"user":{"id":"u-sam"},"apple":{}}"#)
        m.requests = IntegrationsRequests(clearApple: { _ in cleared })
        await m.removeAppleHealth(d)
        XCTAssertEqual(fake.resets, 0)
    }

    /// Revoke: the token here, Sam's, stops working on the server, so it goes from this iPhone too; one the server still
    /// takes (or that couldn't be checked) stays.
    func testRevokeRemovesThisPhonesDeadToken() async throws {
        let revoked = try Self.status(#"{"user":{"id":"u-sam"},"apple":{"iphoneToken":false}}"#)
        for (rejected, kept) in [(true as Bool?, false), (false, true), (nil, true)] {
            let store = MemoryTokenStore()
            let d = samSignedIn(store)
            let fake = FakePhone(store: store)
            fake.dashboard = d
            fake.rejected = rejected
            store.token = "sams-token"
            d.ingestTokenChanged()
            let m = IntegrationsModel()
            m.phone = fake.phone
            m.show(IntegrationsModel.ShownToken(server: base.absoluteString, token: "sams-token"))
            m.requests = IntegrationsRequests(revoke: { _ in revoked })
            await m.revoke(d)
            XCTAssertEqual(store.token.isEmpty, !kept, "rejected: \(String(describing: rejected))")
            XCTAssertNil(m.shown)
            XCTAssertEqual(d.status?.apple?.iphoneToken, false)
        }
    }

    func testWhoopActionsShowTheAnswerOrTheServersWords() async throws {
        let store = MemoryTokenStore()
        let d = samSignedIn(store)
        let m = IntegrationsModel()
        let syncing = try Self.status(#"{"whoop":{"configured":true,"connected":true,"syncing":true}}"#)
        m.requests = IntegrationsRequests(syncNow: { _ in syncing },
                                          disconnect: { _ in throw APIClient.error(status: 500, message: "Something went wrong", path: "/whoop/disconnect") })
        await m.whoopSyncNow(d)
        XCTAssertEqual(d.status?.whoop?.syncing, true)
        await m.whoopDisconnect(d)
        XCTAssertEqual(m.whoopError, "Server answered 500: Something went wrong", "a failure, never \"not set up\"")
        XCTAssertEqual(d.status?.whoop?.connected, true, "nothing changed")
    }

    /// While WHOOP syncs, the status is read again until it's done.
    func testWatchingAWhoopSyncStopsWhenItsDone() async throws {
        let store = MemoryTokenStore()
        let d = samSignedIn(store)
        d.apply(status: try Self.status(#"{"whoop":{"configured":true,"connected":true,"syncing":true}}"#))
        let reads = IntegrationsCounter()
        let still = try Self.status(#"{"whoop":{"configured":true,"connected":true,"syncing":true}}"#)
        let done = try Self.status(#"{"whoop":{"configured":true,"connected":true,"syncing":false}}"#)
        let m = IntegrationsModel()
        m.requests = IntegrationsRequests(status: { _ in
            reads.n += 1
            return reads.n < 3 ? still : done
        })
        await m.watchWhoopSync(d, every: .milliseconds(10))
        XCTAssertEqual(reads.n, 3)
    }

    func testAnotherSessionForgetsEverything() {
        let d = Dashboard()
        d.authMode = "required"
        d.account = person("u-sam")
        d.signedIn()
        let m = IntegrationsModel(query: ["whoop": "connected"])
        m.follow(d.session)
        m.show(IntegrationsModel.ShownToken(server: "s", token: "t"))
        m.appleError = "x"
        m.follow(d.session)
        XCTAssertNotNil(m.shown, "the same session keeps it")
        d.account = person("u-alex")
        d.signedIn()
        m.follow(d.session)
        XCTAssertNil(m.shown)
        XCTAssertNil(m.appleError)
        XCTAssertEqual(m.query, [:])
        XCTAssertFalse(m.phoneSetupOpen)
    }
}

/// A count a request closure can bump from wherever it runs.
final class IntegrationsCounter { var n = 0 }

// MARK: - Drawn on the iPhone Duo (duo/design.md §8.2)

/// The page drawn in the Duo's states, light and dark, default text and AX3, with nothing tappable on the fold, and its
/// state (the token shown once, the open disclosure) kept across a fold that swaps its panes. PNGs go to
/// TEST_RUNNER_DUO_SHOTS as d-*.png (a member syncing from this iPhone, WHOOP connected, Fitbit imported, "Set up this
/// iPhone" open), d-owner-*.png (a local server's owner, as the web's references) and d-token-*.png (a made-up token
/// shown once).
@MainActor
final class IntegrationsDuoTests: XCTestCase {
    private var savedServer: String?

    override func setUp() async throws {
        savedServer = UserDefaults.standard.string(forKey: "serverURL")
        Config.serverText = "http://127.0.0.1:9"
    }

    override func tearDown() async throws {
        if let savedServer { UserDefaults.standard.set(savedServer, forKey: "serverURL") } else { UserDefaults.standard.removeObject(forKey: "serverURL") }
    }

    private static func iso(minutesAgo: Double) -> String { ISO8601DateFormatter().string(from: Date().addingTimeInterval(-minutesAgo * 60)) }

    static var memberStatus: String {
        #"{"hosted":true,"demo":false,"user":{"id":"u-sam","email":"sam@example.test","name":"Sam","role":"member"},"settings":{"units":"metric","demo":"auto"},"apple":{"lastImport":null,"lastSync":{"syncedAt":"\#(iso(minutesAgo: 120))"},"job":{"state":"idle"},"iphoneToken":true},"whoop":{"configured":true,"connected":true,"redirectUri":"https://health.example.test/api/whoop/callback","syncing":false,"lastSync":"\#(iso(minutesAgo: 12))","lastError":null},"fitbit":{"lastImport":{"days":1204,"firstDate":"2021-03-02","lastDate":"2026-10-20","metrics":["hr_avg"],"importedAt":"2026-10-23T10:00:00.000Z"}}}"#
    }

    static let ownerStatus = #"{"hosted":false,"demo":true,"user":{"id":"owner","email":null,"name":"Ricky","role":"admin"},"settings":{"demo":"auto"},"apple":{"lastImport":null,"lastSync":null,"job":{"state":"idle"},"iphoneToken":false},"whoop":{"configured":false,"connected":false,"redirectUri":"http://localhost:8801/api/whoop/callback","syncing":false,"lastSync":null,"lastError":null},"fitbit":{"lastImport":null}}"#

    /// A made-up token, shaped like the server's (24 random bytes, base64url).
    static let madeUpToken = "Zm9yLXRlc3RzLW9ubHktbm90LWEtdG9rZW4"

    private let reads = IntegrationsCounter()

    private func page(_ json: String, setupOpen: Bool = false, token: Bool = false, authMode: String = "required",
                      model: IntegrationsModel? = nil) throws -> some View {
        let status = try IntegrationsTests.status(json)
        let d = Dashboard()
        d.authMode = authMode
        d.account = status.user
        d.phase = .ready
        d.apply(status: status)
        let m = model ?? IntegrationsModel()
        let reads = reads
        m.requests = IntegrationsRequests(status: { _ in
            reads.n += 1
            return status
        })
        m.phoneSetupOpen = setupOpen
        if token { m.show(IntegrationsModel.ShownToken(server: "https://health.example.test", token: Self.madeUpToken)) }
        return IntegrationsScreen(model: m).environment(d)
    }

    /// Every state: outer, upright, landscape with the bar on either side, both split views, and the fold active.
    private static let states: [DuoState] = DuoState.all + [.innerLandscape(foldActive: true)]

    func testDrawnInTheDuosStates() async throws {
        for state in Self.states {
            for dark in [false, true] {
                for size: DynamicTypeSize in [.large, .accessibility3] {
                    try await DuoSnapshot.draw(try page(Self.memberStatus, setupOpen: true), as: state, dark: dark, typeSize: size, name: "d")
                    try await DuoSnapshot.draw(try page(Self.ownerStatus), as: state, dark: dark, typeSize: size, name: "d-owner")
                }
            }
        }
        for state: DuoState in [.outer, .innerLandscape(), .innerLandscape(bar: .leading)] {
            for dark in [false, true] {
                try await DuoSnapshot.draw(try page(Self.memberStatus, setupOpen: true, token: true), as: state, dark: dark, name: "d-token")
            }
        }
    }

    func testNothingTappableOnTheFold() async throws {
        for state in DuoState.folded {
            for size: DynamicTypeSize in [.large, .accessibility3] {
                try await DuoFoldAssertions.assertNothingTappableOnTheFold(try page(Self.memberStatus, setupOpen: true, token: true), state: state, typeSize: size)
                try await DuoFoldAssertions.assertNothingTappableOnTheFold(try page(Self.ownerStatus), state: state, typeSize: size)
            }
        }
    }

    /// A fold changes the grid's columns only; the model is above the page (P4), so the token shown once, the open
    /// disclosure and a question being asked stay, and the page doesn't read the status again.
    func testStateSurvivesAFold() async throws {
        let model = IntegrationsModel()
        model.asking = .removeApple
        let host = try await DuoHost(try page(Self.memberStatus, setupOpen: true, token: true, model: model), as: .outer)
        defer { host.close() }
        let readsBefore = reads.n
        XCTAssertEqual(readsBefore, 1, "read once as it opens")
        for state: DuoState in [.innerLandscape(), .outer, .innerLandscape(bar: .leading), .innerPortrait(), .innerLandscape(foldActive: true)] {
            try await host.set(state)
            let labels = try await host.elements().compactMap(\.accessibilityLabel)
            XCTAssertTrue(labels.contains("Token, shown only now"), "the token shown once, in \(state)")
            XCTAssertTrue(labels.contains("Copy token"), "\(state)")
            XCTAssertFalse(labels.contains(Self.madeUpToken), "a secret isn't in the accessibility tree")
            XCTAssertEqual(model.asking, .removeApple, "the question stays up, in \(state)")
            XCTAssertTrue(model.phoneSetupOpen, "\(state)")
        }
        XCTAssertEqual(reads.n, readsBefore, "no read again for a fold")
    }

    /// The open Duo in landscape: the intro on the leading side, the source cards two a row, one each side of the fold
    /// (WHOOP | Fitbit, then Apple | the note), none across it. Upright and outer: one column, the web's order.
    func testTheSourcesGoOneEachSideOfTheFold() async throws {
        for bar: HorizontalEdge in [.trailing, .leading] {
            let state = DuoState.innerLandscape(bar: bar)
            let host = try await DuoHost(try page(Self.memberStatus), as: state)
            defer { host.close() }
            let elements = try await host.elements()
            func frame(_ label: String) throws -> CGRect {
                try XCTUnwrap(elements.first { $0.accessibilityLabel == label }?.accessibilityFrame, label)
            }
            let fold = try XCTUnwrap(DuoFoldAssertions.band(state))
            let title = try frame(IntegrationsWords.title)
            let whoop = try frame("WHOOP"), fitbit = try frame(IntegrationsWords.fitbitTitle)
            let apple = try frame(IntegrationsWords.appleTitle), note = try frame(IntegrationsWords.noteTitle)
            XCTAssertLessThan(title.maxX, fold.lowerBound, "\(state)")
            XCTAssertLessThan(whoop.maxX, fold.lowerBound, "\(state)")
            XCTAssertGreaterThan(fitbit.minX, fold.upperBound, "\(state)")
            XCTAssertEqual(whoop.minY, fitbit.minY, accuracy: 1, "one row, \(state)")
            XCTAssertLessThan(apple.maxX, fold.lowerBound, "\(state)")
            XCTAssertGreaterThan(note.minX, fold.upperBound, "\(state)")
            XCTAssertGreaterThan(apple.minY, whoop.maxY, "\(state)")
        }
        for state: DuoState in [.outer, .innerPortrait()] {
            let host = try await DuoHost(try page(Self.memberStatus), as: state)
            defer { host.close() }
            let elements = try await host.elements()
            let x = { (label: String) in elements.first { $0.accessibilityLabel == label }?.accessibilityFrame.minX ?? -1 }
            let y = { (label: String) in elements.first { $0.accessibilityLabel == label }?.accessibilityFrame.minY ?? .infinity }
            XCTAssertLessThan(y(IntegrationsWords.title), y("WHOOP"), "\(state)")
            XCTAssertLessThan(y("WHOOP"), y(IntegrationsWords.fitbitTitle), "\(state)")
            XCTAssertEqual(x("WHOOP"), x(IntegrationsWords.fitbitTitle), accuracy: 1, "one column, \(state)")
        }
    }

    /// The grid's cells follow the status: a server that doesn't name WHOOP or Fitbit moves nothing else.
    func testTheGridHoldsWhatTheStatusNames() throws {
        let all = try IntegrationsTests.status(Self.memberStatus)
        XCTAssertEqual(IntegrationsCell.cells(all).map(\.rawValue), ["whoop", "fitbit", "apple", "aside"])
        let older = try IntegrationsTests.status(#"{"hosted":true,"apple":{"lastSync":null}}"#)
        XCTAssertEqual(IntegrationsCell.cells(older).map(\.rawValue), ["apple", "aside"])
    }

    /// A server without accounts has no Set up this iPhone.
    func testNoPhoneSetUpWithoutAccounts() async throws {
        let host = try await DuoHost(try page(Self.ownerStatus, authMode: "open"), as: .outer)
        defer { host.close() }
        let labels = try await host.elements().compactMap(\.accessibilityLabel)
        XCTAssertFalse(labels.contains(IntegrationsWords.setUpPhone))
        XCTAssertTrue(labels.contains("Demo data"))
    }
}
