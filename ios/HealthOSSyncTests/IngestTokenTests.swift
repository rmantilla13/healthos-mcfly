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
        let p = IngestTokenOwner(claim: .nobody, paused: true)
        XCTAssertEqual(try JSONDecoder().decode(IngestTokenOwner.self, from: JSONEncoder().encode(p)), p)
        // A record without the newer fields, or with one it can't read, keeps the rest.
        let older = try JSONDecoder().decode(IngestTokenOwner.self, from: Data(#"{"paused":true,"setUpAgain":false,"claim":"later"}"#.utf8))
        XCTAssertEqual(older, IngestTokenOwner(claim: .firstSeen, paused: true))
    }

    func testAnOlderBuildsTokenFirstSeenSignedOutIsNobodys() {
        // Signed out in an older build, or the session ran out before the update: the token's owner was never kept,
        // and nobody's signed in now to say. Paused, and whoever signs in next doesn't get it, the same person included.
        var o = IngestTokenOwner()
        o.signedOut(nil, hasToken: true)
        XCTAssertTrue(o.paused)
        XCTAssertEqual(o.claim, .nobody)
        XCTAssertNil(o.account)
        XCTAssertTrue(o.signedIn(alex, hasToken: true), "the token goes")
        XCTAssertTrue(o.setUpAgain)
        XCTAssertFalse(o.paused)

        // Still nobody's after another look while signed out, and Sign out can't make it the one signing out's.
        var p = IngestTokenOwner()
        p.signedOut(nil, hasToken: true)
        p.signedOut(sam, hasToken: true)
        XCTAssertNil(p.account)
        XCTAssertTrue(p.signedIn(sam, hasToken: true))

        // An older server with one password has one person: it stays theirs.
        var q = IngestTokenOwner()
        q.signedOut(nil, hasToken: true)
        XCTAssertFalse(q.signedIn(nil, hasToken: true))
    }

    func testATokenPastedWhileSignedOutIsTheNextSignIns() {
        var o = IngestTokenOwner(account: sam, paused: true)
        o.tokenChanged(hasToken: true, signedIn: nil)
        XCTAssertEqual(o.claim, .nextSignIn)
        XCTAssertNil(o.account)
        // Another look while signed out (the next launch) doesn't take it away.
        o.signedOut(nil, hasToken: true)
        XCTAssertEqual(o.claim, .nextSignIn)
        XCTAssertTrue(o.paused, "nothing goes up before the sign-in")
        XCTAssertFalse(o.signedIn(alex, hasToken: true))
        XCTAssertEqual(o.account, alex)
        XCTAssertFalse(o.paused)
    }

    func testAServerWithoutSignInLeavesAnotherServersPauseAlone() {
        // Signed out on health.example, then a local server with no sign-in: the token is still that account's, and
        // going back there mustn't find the pause gone before the server says who's signed in.
        var o = IngestTokenOwner(account: sam)
        o.signedOut(sam, hasToken: true)
        o.noSignIn(on: "http://192.168.1.20:8788")
        XCTAssertTrue(o.paused)
        // The same server, now without sign-in: one person.
        o.noSignIn(on: "https://health.example")
        XCTAssertFalse(o.paused)

        var nobody = IngestTokenOwner()
        nobody.signedOut(nil, hasToken: true)
        nobody.noSignIn(on: "http://192.168.1.20:8788")
        XCTAssertTrue(nobody.paused, "a token nobody can be told the owner of never goes")

        var unknown = IngestTokenOwner(paused: true)
        unknown.noSignIn(on: "http://192.168.1.20:8788")
        XCTAssertFalse(unknown.paused, "a token set on a server without sign-in")
    }
}

/// A sync under way checks before each push that it may still send with the token it started with.
final class IngestPushGateTests: XCTestCase {
    func testAPushStopsAfterASignOutOrANewToken() {
        XCTAssertTrue(SyncEngine.maySend(with: "t0ken", owner: IngestTokenOwner(), current: "t0ken"))
        XCTAssertFalse(SyncEngine.maySend(with: "t0ken", owner: IngestTokenOwner(paused: true), current: "t0ken"), "signed out meanwhile")
        XCTAssertFalse(SyncEngine.maySend(with: "t0ken", owner: IngestTokenOwner(), current: ""), "removed: someone else signed in")
        XCTAssertFalse(SyncEngine.maySend(with: "t0ken", owner: IngestTokenOwner(), current: "an0ther"), "replaced")
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

    func testBeingSignedOutAtLaunchPauses() throws {
        // A reinstall over an older build, or a sign-out made in one: a token, no owner kept, and no session. Nothing
        // goes up before anyone signs in, and the first to sign in doesn't get the token.
        let store = MemoryTokenStore(token: "t0ken")
        let d = Dashboard(tokenStore: store)
        d.authMode = "required"
        d.usesAccounts = true
        d.phase = .signIn // what start() sets when /auth/me says there's no session
        XCTAssertTrue(store.owner.paused)
        XCTAssertTrue(d.ingestOwner.paused, "Settings says so")
        XCTAssertEqual(store.owner.claim, .nobody)
        d.account = try user("u2")
        d.signedIn()
        XCTAssertEqual(store.token, "", "the token goes")
        XCTAssertTrue(d.ingestOwner.setUpAgain)
        XCTAssertFalse(store.owner.paused)
    }

    func testASessionThatEndsPausesUntilTheSameAccountSignsIn() throws {
        // The cookie ran out, or a password change elsewhere ended it: a 401 sets .signIn.
        let store = MemoryTokenStore(token: "t0ken")
        let d = try signedIn(as: "u1", store: store)
        XCTAssertFalse(store.owner.paused)
        d.phase = .signIn
        XCTAssertTrue(store.owner.paused, "no button tapped, still paused")
        XCTAssertEqual(store.owner.account?.id, "u1", "and still u1's")
        d.account = try user("u1")
        d.signedIn()
        XCTAssertFalse(store.owner.paused)
        XCTAssertEqual(store.token, "t0ken")
    }

    func testAKeptPauseSurvivesAServerWithoutSignIn() throws {
        // Signed out on the sign-in server, then pointed at a local one without sign-in: the token is still that
        // account's, so the pause stays for when the phone goes back.
        let sam = IngestTokenOwner.Account(server: "https://health.example", id: "u1")
        let store = MemoryTokenStore(token: "t0ken", owner: IngestTokenOwner(account: sam, paused: true))
        let d = Dashboard(tokenStore: store)
        d.authMode = "open"
        d.phase = .ready
        d.checkIngestToken(signedInAs: "owner")
        XCTAssertTrue(store.owner.paused)
        XCTAssertEqual(store.token, "t0ken")
    }

    func testOnlyAServerWithSignInPausesWhenSignedOut() throws {
        let store = MemoryTokenStore(token: "t0ken")
        let d = Dashboard(tokenStore: store)
        d.phase = .signIn // the sign-in mode isn't known yet
        XCTAssertFalse(store.owner.paused)
        XCTAssertEqual(store.owner.claim, .firstSeen)
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
