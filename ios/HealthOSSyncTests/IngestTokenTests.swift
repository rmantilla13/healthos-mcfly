import XCTest
@testable import HealthOSSync

/// The ingest token belongs to one account: Sign out pauses the sync, the same account resumes it, and anyone else
/// signing in removes the token, so a phone that changes hands never sends the new person's Health data to the last.
final class IngestTokenOwnerTests: XCTestCase {
    private let sam = IngestTokenOwner.Account(server: "https://health.example", id: "u1", email: "u1@example.com")
    private let alex = IngestTokenOwner.Account(server: "https://health.example", id: "u2", email: "u2@example.com")

    func testSigningOutPausesAndTheSameAccountResumes() {
        var o = IngestTokenOwner(account: sam)
        o.signedOut(sam, hasToken: true, lastEmail: "u1@example.com")
        XCTAssertTrue(o.paused)
        XCTAssertFalse(o.signedIn(sam, hasToken: true), "the token stays")
        XCTAssertFalse(o.paused)
        XCTAssertEqual(o.account, sam)
        XCTAssertFalse(o.setUpAgain)
    }

    func testSomeoneElseSigningInRemovesTheToken() {
        var o = IngestTokenOwner(account: sam)
        o.signedOut(sam, hasToken: true, lastEmail: "u1@example.com")
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

    func testASessionThatEndsKeepsAKnownOwnersSync() {
        // The fixed 30-day session ran out, or was ended elsewhere: nobody tapped Sign out, and the token's owner is
        // known, so the sync goes on, as before owners were kept. If someone else has the phone now, their sign-in
        // removes the token.
        var o = IngestTokenOwner(account: sam)
        o.sessionEnded(hasToken: true, lastEmail: "u1@example.com")
        XCTAssertFalse(o.paused)
        XCTAssertEqual(o.account, sam)
        XCTAssertTrue(o.signedIn(alex, hasToken: true))

        // A pause from Sign out stays, however often the app finds there's no session (each launch).
        var p = IngestTokenOwner(account: sam)
        p.signedOut(sam, hasToken: true, lastEmail: "u1@example.com")
        p.sessionEnded(hasToken: true, lastEmail: "u1@example.com")
        p.sessionEnded(hasToken: true, lastEmail: "u1@example.com")
        XCTAssertTrue(p.paused)
        XCTAssertEqual(p.account, sam)
    }

    func testTheSameIdOnAnotherServerIsSomeoneElse() {
        // "owner" is the first account on every server.
        var o = IngestTokenOwner(account: .init(server: "https://a.example", id: "owner", email: "sam@example.com"))
        XCTAssertTrue(o.signedIn(.init(server: "https://b.example", id: "owner", email: "alex@example.com"), hasToken: true))
        // Without emails to go by (a record from before they were kept, a server without sign-in), never the same.
        var p = IngestTokenOwner(account: .init(server: "https://a.example", id: "owner"))
        XCTAssertTrue(p.signedIn(.init(server: "https://b.example", id: "owner"), hasToken: true))
        var q = IngestTokenOwner(account: .init(server: "https://a.example", id: "owner"))
        XCTAssertTrue(q.signedIn(.init(server: "https://b.example", id: "owner", email: "sam@example.com"), hasToken: true))
        // Another id with the same email is another account.
        var r = IngestTokenOwner(account: sam)
        XCTAssertTrue(r.signedIn(.init(server: "http://192.168.1.20:8790", id: "u9", email: "u1@example.com"), hasToken: true))
    }

    func testTheSameAccountAtAnotherAddressKeepsItsToken() {
        // A Mac server reached as mac.local at home and by its IP elsewhere: the same id and email is the same account.
        let home = IngestTokenOwner.Account(server: "http://mac.local:8790", id: "owner", email: "sam@example.com")
        let away = IngestTokenOwner.Account(server: "http://192.168.1.20:8790", id: "owner", email: " Sam@Example.com")
        var o = IngestTokenOwner(account: home)
        o.signedOut(home, hasToken: true, lastEmail: "sam@example.com")
        XCTAssertFalse(o.signedIn(away, hasToken: true), "the token stays")
        XCTAssertFalse(o.paused)
        XCTAssertFalse(o.setUpAgain)
        XCTAssertEqual(o.account?.server, away.server, "kept under the address it's reached at now")
        XCTAssertFalse(o.signedIn(home, hasToken: true), "and back at home")

        // On the same server the id decides: an email changed on the web is the same account.
        var p = IngestTokenOwner(account: sam)
        XCTAssertFalse(p.signedIn(.init(server: sam.server, id: "u1", email: "new@example.com"), hasToken: true))
        XCTAssertEqual(p.account?.email, "new@example.com")
        // A record from before emails were kept, on the same server: the id still decides.
        var q = IngestTokenOwner(account: .init(server: sam.server, id: "u1"))
        XCTAssertFalse(q.signedIn(sam, hasToken: true))
        XCTAssertEqual(q.account, sam)
    }

    func testATokenFromBeforeOwnersWereKeptIsAdopted() {
        // The first launch after the update, signed in: the token is that account's.
        var o = IngestTokenOwner()
        XCTAssertFalse(o.signedIn(sam, hasToken: true))
        XCTAssertEqual(o.account, sam)
        // Signed out before anyone was seen: it's the one signing out's.
        var p = IngestTokenOwner()
        p.signedOut(alex, hasToken: true, lastEmail: "u2@example.com")
        XCTAssertEqual(p.account, alex)
        XCTAssertTrue(p.signedIn(sam, hasToken: true))
    }

    func testANewAccountNeverKeepsAnOldToken() {
        // An account made from an invite a moment ago can't have made a token: the one here is someone else's.
        var unknown = IngestTokenOwner()
        XCTAssertTrue(unknown.signedIn(alex, hasToken: true, newAccount: true))
        var known = IngestTokenOwner(account: sam)
        XCTAssertTrue(known.signedIn(nil, hasToken: true, newAccount: true), "even before the server says who")
        var byEmail = IngestTokenOwner(claim: .lastEmail, email: "u2@example.com")
        XCTAssertTrue(byEmail.signedIn(alex, hasToken: true, newAccount: true), "even with the email last signed in with here")
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
        // Looking while signed out with no token claims nothing for an email.
        var p = IngestTokenOwner()
        p.sessionEnded(hasToken: false, lastEmail: "u1@example.com")
        XCTAssertEqual(p.claim, .firstSeen)
        XCTAssertNil(p.email)
    }

    func testItSurvivesARelaunch() throws {
        let o = IngestTokenOwner(account: sam, paused: true, setUpAgain: false)
        XCTAssertEqual(try JSONDecoder().decode(IngestTokenOwner.self, from: JSONEncoder().encode(o)), o)
        let p = IngestTokenOwner(claim: .nobody, paused: true)
        XCTAssertEqual(try JSONDecoder().decode(IngestTokenOwner.self, from: JSONEncoder().encode(p)), p)
        let q = IngestTokenOwner(claim: .lastEmail, email: "u1@example.com")
        XCTAssertEqual(try JSONDecoder().decode(IngestTokenOwner.self, from: JSONEncoder().encode(q)), q)
        // A record without the newer fields, or with one it can't read, keeps the rest.
        let older = try JSONDecoder().decode(IngestTokenOwner.self, from: Data(#"{"paused":true,"setUpAgain":false,"claim":"later"}"#.utf8))
        XCTAssertEqual(older, IngestTokenOwner(claim: .firstSeen, paused: true))
        // An account kept before emails were.
        let noEmail = try JSONDecoder().decode(IngestTokenOwner.self, from: Data(#"{"account":{"server":"https://health.example","id":"u1"}}"#.utf8))
        XCTAssertEqual(noEmail.account, IngestTokenOwner.Account(server: "https://health.example", id: "u1"))
    }

    func testAnOlderBuildsTokenFirstSeenSignedOutIsTheLastEmails() {
        // The session ran out (or Sign out was tapped) in an older build, which kept no owner but did keep the email
        // last signed in with here. The token is taken to be that email's, and goes on syncing, as it did there.
        var o = IngestTokenOwner()
        o.sessionEnded(hasToken: true, lastEmail: " U1@Example.com")
        XCTAssertEqual(o.claim, .lastEmail)
        XCTAssertEqual(o.email, "u1@example.com")
        XCTAssertNil(o.account)
        XCTAssertFalse(o.paused)
        // Looking again changes nothing.
        o.sessionEnded(hasToken: true, lastEmail: " U1@Example.com")
        XCTAssertEqual(o.claim, .lastEmail)
        // That person signing back in keeps it: no new token to make and paste.
        var same = o
        XCTAssertFalse(same.signedIn(sam, hasToken: true), "the token stays")
        XCTAssertEqual(same.account, sam)
        XCTAssertFalse(same.setUpAgain)
        // Anyone else removes it.
        var other = o
        XCTAssertTrue(other.signedIn(alex, hasToken: true), "the token goes")
        XCTAssertTrue(other.setUpAgain)
        // Sign out tapped on a server with one password (nobody named) goes by the email the same way.
        var tapped = IngestTokenOwner()
        tapped.signedOut(nil, hasToken: true, lastEmail: "u1@example.com")
        XCTAssertEqual(tapped.claim, .lastEmail)
        XCTAssertTrue(tapped.paused, "Sign out pauses")
    }

    func testAnOlderBuildsTokenWithNoEmailToGoByIsNobodys() {
        // A reinstall: Keychain items (the token) stay, the email doesn't. It can't be told whose: paused, and whoever
        // signs in next doesn't get it, the same person included.
        var o = IngestTokenOwner()
        o.sessionEnded(hasToken: true, lastEmail: "")
        XCTAssertTrue(o.paused)
        XCTAssertEqual(o.claim, .nobody)
        XCTAssertNil(o.account)
        XCTAssertTrue(o.signedIn(sam, hasToken: true), "the token goes")
        XCTAssertTrue(o.setUpAgain)
        XCTAssertFalse(o.paused)

        // Still nobody's after another look while signed out, and Sign out can't make it the one signing out's.
        var p = IngestTokenOwner()
        p.sessionEnded(hasToken: true, lastEmail: "")
        p.signedOut(sam, hasToken: true, lastEmail: "u1@example.com")
        p.sessionEnded(hasToken: true, lastEmail: "u1@example.com")
        XCTAssertEqual(p.claim, .nobody)
        XCTAssertNil(p.account)
        XCTAssertTrue(p.signedIn(sam, hasToken: true))

        // An older server with one password has one person: it stays theirs.
        var q = IngestTokenOwner()
        q.sessionEnded(hasToken: true, lastEmail: "")
        XCTAssertFalse(q.signedIn(nil, hasToken: true))
    }

    func testATokenPastedWhileSignedOutIsTheNextSignIns() {
        var o = IngestTokenOwner(account: sam, paused: true)
        o.tokenChanged(hasToken: true, signedIn: nil)
        XCTAssertEqual(o.claim, .nextSignIn)
        XCTAssertNil(o.account)
        // Another look while signed out (the next launch) doesn't take it away, nor give it to the last email.
        o.sessionEnded(hasToken: true, lastEmail: "u1@example.com")
        XCTAssertEqual(o.claim, .nextSignIn)
        XCTAssertTrue(o.paused, "nothing goes up before the sign-in: nobody knows whose it is yet")
        XCTAssertFalse(o.signedIn(alex, hasToken: true))
        XCTAssertEqual(o.account, alex)
        XCTAssertFalse(o.paused)
    }

    func testAServerWithoutSignInLeavesAnotherServersPauseAlone() {
        // Signed out on health.example, then a local server with no sign-in: the token is still that account's, and
        // going back there mustn't find the pause gone before the server says who's signed in.
        var o = IngestTokenOwner(account: sam)
        o.signedOut(sam, hasToken: true, lastEmail: "u1@example.com")
        o.noSignIn(on: "http://192.168.1.20:8788")
        XCTAssertTrue(o.paused)
        // The same server, now without sign-in: one person.
        o.noSignIn(on: "https://health.example")
        XCTAssertFalse(o.paused)

        var nobody = IngestTokenOwner()
        nobody.sessionEnded(hasToken: true, lastEmail: "")
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

    private func auth(authenticated: Bool, user id: String? = nil) throws -> AuthState {
        var json: [String: Any] = ["mode": "required", "authenticated": authenticated, "setup": false]
        if let id { json["user"] = ["id": id, "email": "\(id)@example.com"] }
        return try JSONDecoder().decode(AuthState.self, from: JSONSerialization.data(withJSONObject: json))
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
        let store = MemoryTokenStore(token: "t0ken", lastEmail: "u1@example.com")
        let d = try signedIn(as: "u1", store: store)
        XCTAssertEqual(store.owner.account?.id, "u1", "adopted: first seen while signed in")
        XCTAssertEqual(store.owner.account?.email, "u1@example.com")
        d.ingestSignedOut()
        d.phase = .signIn
        XCTAssertTrue(store.owner.paused)
        XCTAssertTrue(d.ingestOwner.paused, "Settings says so")
        XCTAssertTrue(d.ingestWaitsForSignIn, "and so does the sign-in screen")

        d.account = try user("u1")
        d.signedIn()
        XCTAssertFalse(store.owner.paused)
        XCTAssertEqual(store.token, "t0ken")
        XCTAssertFalse(d.ingestOwner.setUpAgain)
        XCTAssertFalse(d.ingestWaitsForSignIn)
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

    func testASessionThatEndsKeepsAKnownOwnersSync() throws {
        // The cookie ran out, or a password change elsewhere ended it: a 401 sets .signIn. Nobody tapped Sign out and
        // the token's owner is known, so the sync goes on, as before owners were kept.
        let store = MemoryTokenStore(token: "t0ken", lastEmail: "u1@example.com")
        let d = try signedIn(as: "u1", store: store)
        d.phase = .signIn
        XCTAssertFalse(store.owner.paused, "no button tapped: Health data still goes up")
        XCTAssertFalse(d.ingestWaitsForSignIn, "so the sign-in screen doesn't say it waits")
        XCTAssertEqual(store.owner.account?.id, "u1", "still u1's")
        // The next launch finds no session either.
        d.apply(auth: try auth(authenticated: false), host: nil)
        XCTAssertFalse(store.owner.paused)
        d.account = try user("u1")
        d.signedIn()
        XCTAssertEqual(store.token, "t0ken")
    }

    func testAnExpiredSessionThenSomeoneElseRemovesIt() throws {
        // Never signed out here: the session ran out, and the next person signed in.
        let store = MemoryTokenStore(token: "t0ken")
        let d = try signedIn(as: "u1", store: store)
        d.phase = .signIn
        d.account = try user("u2")
        d.signedIn()
        XCTAssertEqual(store.token, "")
        XCTAssertTrue(d.ingestOwner.setUpAgain)
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
        d.checkIngestToken(signedInAs: d.status?.user)
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
        d.checkIngestToken(signedInAs: try user("owner"))
        XCTAssertFalse(store.owner.paused, "a local server has one person")
        XCTAssertEqual(store.token, "t0ken")
        XCTAssertNil(store.owner.account)
    }

    func testAnOlderBuildsTokenSignedOutAtLaunchIsTheLastEmails() throws {
        // The first launch of this build, after the session lapsed in an older one: a token, no owner kept, no session,
        // and the email that build last signed in with. The token is that email's and goes on syncing.
        let store = MemoryTokenStore(token: "t0ken", lastEmail: "U1@example.com")
        let d = Dashboard(tokenStore: store)
        d.apply(auth: try auth(authenticated: false), host: nil)
        XCTAssertEqual(d.phase, .signIn)
        XCTAssertEqual(store.owner.claim, .lastEmail)
        XCTAssertFalse(store.owner.paused)
        XCTAssertFalse(d.ingestWaitsForSignIn)
        // The same person signs back in: the token stays, nothing to set up again.
        d.account = try user("u1")
        d.signedIn()
        XCTAssertEqual(store.token, "t0ken")
        XCTAssertEqual(store.owner.account?.id, "u1")
        XCTAssertFalse(d.ingestOwner.setUpAgain)

        // Someone else signs in instead: it goes.
        let other = MemoryTokenStore(token: "t0ken", lastEmail: "u1@example.com")
        let e = Dashboard(tokenStore: other)
        e.apply(auth: try auth(authenticated: false), host: nil)
        e.account = try user("u2")
        e.signedIn()
        XCTAssertEqual(other.token, "", "the token goes")
        XCTAssertTrue(e.ingestOwner.setUpAgain)
    }

    func testATokenNobodyCanBeToldTheOwnerOfWaitsAtLaunch() throws {
        // A reinstall over an older build: a token, no owner kept, no email, and no session. Nothing goes up before
        // anyone signs in, the sign-in screen says so, and the first to sign in doesn't get the token.
        let store = MemoryTokenStore(token: "t0ken")
        let d = Dashboard(tokenStore: store)
        d.apply(auth: try auth(authenticated: false), host: nil)
        XCTAssertTrue(store.owner.paused)
        XCTAssertTrue(d.ingestOwner.paused, "Settings says so")
        XCTAssertTrue(d.ingestWaitsForSignIn, "and so does the sign-in screen")
        XCTAssertEqual(store.owner.claim, .nobody)
        d.account = try user("u2")
        d.signedIn()
        XCTAssertEqual(store.token, "", "the token goes")
        XCTAssertTrue(d.ingestOwner.setUpAgain)
        XCTAssertFalse(store.owner.paused)
    }

    func testTheStartLooksAtTheTokenEvenWithTheSignInScreenUpAlready() throws {
        // Offline at launch with a cached summary: the sign-in mode isn't known. A 401 then puts the sign-in screen
        // up, and nothing is looked at. The next start's "no session" must still pause a token nobody can be told the
        // owner of, although the phase doesn't change.
        let store = MemoryTokenStore(token: "t0ken")
        let d = Dashboard(tokenStore: store)
        d.phase = .ready
        d.phase = .signIn
        XCTAssertFalse(store.owner.paused, "the sign-in mode isn't known yet")
        d.apply(auth: try auth(authenticated: false), host: nil)
        XCTAssertTrue(store.owner.paused)
        XCTAssertEqual(store.owner.claim, .nobody)
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
