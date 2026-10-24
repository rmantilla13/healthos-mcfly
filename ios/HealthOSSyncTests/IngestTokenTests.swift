import XCTest
@testable import HealthOSSync

/// The ingest token belongs to one account: signing out pauses the sync, the same account resumes it, and anyone else
/// signing in removes the token, so a phone that changes hands never sends the new person's Health data to the last.
final class IngestTokenOwnerTests: XCTestCase {
    private let sam = IngestTokenOwner.Account(server: "https://health.example", id: "u1")
    private let alex = IngestTokenOwner.Account(server: "https://health.example", id: "u2")

    func testSigningOutPausesAndTheSameAccountResumes() {
        var o = IngestTokenOwner(account: sam)
        o.signedOut(sam, hasToken: true)
        XCTAssertTrue(o.paused)
        XCTAssertFalse(o.signedIn(sam, hasToken: true), "the token stays")
        XCTAssertFalse(o.paused)
        XCTAssertEqual(o.account, sam)
        XCTAssertFalse(o.setUpAgain)
    }

    func testSomeoneElseSigningInRemovesTheToken() {
        var o = IngestTokenOwner(account: sam)
        o.signedOut(sam, hasToken: true)
        XCTAssertTrue(o.signedIn(alex, hasToken: true), "the token goes")
        XCTAssertFalse(o.paused, "nothing is sent anyway: there's no token")
        XCTAssertNil(o.account)
        XCTAssertTrue(o.setUpAgain)
        // Alex sets this iPhone up: the new token is theirs, and the note goes.
        o.tokenChanged(hasToken: true, signedIn: alex)
        XCTAssertEqual(o.account, alex)
        XCTAssertFalse(o.setUpAgain)
        XCTAssertFalse(o.signedIn(alex, hasToken: true))
    }

    func testTheSameIdOnAnotherServerIsSomeoneElse() {
        // "owner" is the first account on every server.
        var o = IngestTokenOwner(account: .init(server: "https://a.example", id: "owner"))
        XCTAssertTrue(o.signedIn(.init(server: "https://b.example", id: "owner"), hasToken: true))
    }

    func testATokenFromBeforeOwnersWereKeptIsAdopted() {
        // The first launch after the update, signed in: the token is that account's.
        var o = IngestTokenOwner()
        XCTAssertFalse(o.signedIn(sam, hasToken: true))
        XCTAssertEqual(o.account, sam)
        // Signed out before anyone was seen: it's the one signing out's.
        var p = IngestTokenOwner()
        p.signedOut(alex, hasToken: true)
        XCTAssertEqual(p.account, alex)
        XCTAssertTrue(p.signedIn(sam, hasToken: true))
    }

    func testANewAccountNeverKeepsAnOldToken() {
        // An account made from an invite a moment ago can't have made a token: the one here is someone else's.
        var unknown = IngestTokenOwner()
        XCTAssertTrue(unknown.signedIn(alex, hasToken: true, newAccount: true))
        var known = IngestTokenOwner(account: sam)
        XCTAssertTrue(known.signedIn(nil, hasToken: true, newAccount: true), "even before the server says who")
        var none = IngestTokenOwner()
        XCTAssertFalse(none.signedIn(alex, hasToken: false, newAccount: true), "no token, nothing to remove")
        XCTAssertFalse(none.setUpAgain)
    }

    func testAnOlderServerWithOnePasswordIsOnePerson() {
        var o = IngestTokenOwner(account: nil, paused: true)
        XCTAssertFalse(o.signedIn(nil, hasToken: true))
        XCTAssertFalse(o.paused)
    }

    func testNoTokenNoOwner() {
        var o = IngestTokenOwner(account: sam)
        XCTAssertFalse(o.signedIn(alex, hasToken: false))
        XCTAssertNil(o.account)
        o.tokenChanged(hasToken: true, signedIn: nil)
        XCTAssertNil(o.account, "pasted while signed out: whoever signs in next")
        XCTAssertFalse(o.signedIn(alex, hasToken: true))
        XCTAssertEqual(o.account, alex)
    }

    func testItSurvivesARelaunch() throws {
        let o = IngestTokenOwner(account: sam, paused: true, setUpAgain: false)
        XCTAssertEqual(try JSONDecoder().decode(IngestTokenOwner.self, from: JSONEncoder().encode(o)), o)
    }
}

/// The dashboard's side: when it checks who's signed in, and what it does to the token it keeps.
@MainActor
final class IngestTokenDashboardTests: XCTestCase {
    private func status(user: String?) throws -> ServerStatus {
        var json: [String: Any] = ["settings": ["name": "Sam"]]
        if let user { json["user"] = ["id": user, "email": "\(user)@example.com", "name": user, "role": "user"] }
        return try JSONDecoder().decode(ServerStatus.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func user(_ id: String) throws -> AuthState.User {
        try JSONDecoder().decode(AuthState.User.self, from: Data(#"{"id":"\#(id)","email":"\#(id)@example.com"}"#.utf8))
    }

    /// Signed in as `id` on a server with accounts, with a token.
    private func signedIn(as id: String, store: MemoryTokenStore) throws -> Dashboard {
        let d = Dashboard(tokenStore: store)
        d.authMode = "required"
        d.usesAccounts = true
        d.account = try user(id)
        d.signedIn()
        return d
    }

    func testSignOutPausesThenTheSameAccountResumes() throws {
        let store = MemoryTokenStore(token: "t0ken")
        let d = try signedIn(as: "u1", store: store)
        XCTAssertEqual(store.owner.account?.id, "u1", "adopted: first seen while signed in")
        d.ingestSignedOut()
        XCTAssertTrue(store.owner.paused)
        XCTAssertTrue(d.ingestOwner.paused, "Settings says so")

        d.phase = .signIn
        d.account = try user("u1")
        d.signedIn()
        XCTAssertFalse(store.owner.paused)
        XCTAssertEqual(store.token, "t0ken")
        XCTAssertFalse(d.ingestOwner.setUpAgain)
    }

    func testSomeoneElseSigningInRemovesTheToken() throws {
        let store = MemoryTokenStore(token: "t0ken")
        let d = try signedIn(as: "u1", store: store)
        d.ingestSignedOut()
        d.account = try user("u2")
        d.signedIn()
        XCTAssertEqual(store.token, "", "the token goes")
        XCTAssertFalse(store.owner.paused)
        XCTAssertTrue(d.ingestOwner.setUpAgain, "Settings asks to set this iPhone up again")
    }

    func testAnExpiredSessionThenSomeoneElseAlsoRemovesIt() throws {
        // Never signed out here: the session ran out, and the next person signed in.
        let store = MemoryTokenStore(token: "t0ken")
        let d = try signedIn(as: "u1", store: store)
        d.phase = .signIn
        d.account = try user("u2")
        d.signedIn()
        XCTAssertEqual(store.token, "")
    }

    func testAStatusReadSaysWhoWhenTheSignInCouldNot() throws {
        let store = MemoryTokenStore(token: "t0ken", owner: IngestTokenOwner(account: .init(server: "", id: "u1"), paused: true))
        let d = Dashboard(tokenStore: store)
        d.authMode = "required"
        d.usesAccounts = true
        d.account = nil // /auth/me didn't answer just after the sign-in
        d.signedIn()
        XCTAssertTrue(store.owner.paused, "can't tell who yet, so it stays paused")
        XCTAssertEqual(store.token, "t0ken")
        // The first status read names the account.
        d.apply(status: try status(user: "u2"))
        d.checkIngestToken(signedInAs: d.status?.user?.id)
        XCTAssertEqual(store.token, "")
    }

    func testAnInviteNeverKeepsAToken() throws {
        let store = MemoryTokenStore(token: "t0ken")
        let d = Dashboard(tokenStore: store)
        d.authMode = "required"
        d.usesAccounts = true
        d.account = try user("new")
        d.signedIn(newAccount: true)
        XCTAssertEqual(store.token, "")
        XCTAssertTrue(d.ingestOwner.setUpAgain)
    }

    func testAServerWithoutSignInNeverPauses() throws {
        let store = MemoryTokenStore(token: "t0ken", owner: IngestTokenOwner(paused: true))
        let d = Dashboard(tokenStore: store)
        d.authMode = "open"
        d.ingestSignedOut()
        XCTAssertTrue(store.owner.paused, "unchanged: there's no signing out there")
        d.phase = .ready
        d.checkIngestToken(signedInAs: "owner")
        XCTAssertFalse(store.owner.paused, "a local server has one person")
        XCTAssertEqual(store.token, "t0ken")
        XCTAssertNil(store.owner.account)
    }

    func testATokenSetWhileSignedInIsThatAccounts() throws {
        let store = MemoryTokenStore()
        let d = try signedIn(as: "u1", store: store)
        XCTAssertNil(store.owner.account, "no token yet")
        store.token = "pasted"
        d.ingestTokenChanged()
        XCTAssertEqual(store.owner.account?.id, "u1")

        // Pasted while signed out: whoever signs in next.
        d.ingestSignedOut()
        d.phase = .signIn
        store.token = "another"
        d.ingestTokenChanged()
        XCTAssertNil(store.owner.account)
        d.account = try user("u2")
        d.signedIn()
        XCTAssertEqual(store.token, "another")
        XCTAssertEqual(store.owner.account?.id, "u2")
        XCTAssertFalse(store.owner.paused)
    }
}
