import XCTest
@testable import HealthOSSync

/// One person's data never shows, or is saved, for another (Dashboard's `session`): a new session reads its own status
/// before anything of the dashboard shows, and an answer that lands after a Sign out, a 401 or someone else's sign-in
/// is dropped. The requests go out through APIClient to a stub on 127.0.0.1 (AIStubServer) with made-up answers.
@MainActor
final class SessionTests: XCTestCase {
    private func use(_ server: AIStubServer) {
        let saved = UserDefaults.standard.string(forKey: "serverURL")
        addTeardownBlock {
            server.stop()
            SummaryCache.clear(for: server.url)
            if let saved { UserDefaults.standard.set(saved, forKey: "serverURL") } else { UserDefaults.standard.removeObject(forKey: "serverURL") }
        }
        Config.serverText = server.url.absoluteString
    }

    private func fixture(_ name: String) throws -> String {
        let url = Bundle(for: Self.self).url(forResource: name, withExtension: "json")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name).json")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// A status as the server sends it for `id`, in this phone's time zone (so no time zone is sent).
    private func statusJSON(_ id: String, onboarding: Int?) -> String {
        let step = onboarding.map(String.init) ?? "null"
        return #"{"user":{"id":"\#(id)","email":"\#(id)@example.test","role":"member"},"settings":{"perspective":"portrait","onboarding":\#(step),"timeZone":"\#(TimeZone.current.identifier)","units":"metric"}}"#
    }

    private func status(_ id: String, onboarding: Int? = nil) throws -> ServerStatus {
        try JSONDecoder().decode(ServerStatus.self, from: Data(statusJSON(id, onboarding: onboarding).utf8))
    }

    private func me(_ id: String) -> String {
        #"{"mode":"required","authenticated":true,"setup":false,"user":{"id":"\#(id)","email":"\#(id)@example.test","role":"member"}}"#
    }

    /// The server answers for Alex, a new account still on the welcome's first step; the summary and status take a
    /// moment.
    private func alexsServer(statusDelay: TimeInterval = 0.4) async throws -> AIStubServer {
        try await AIStubServer.start([
            "GET /api/auth/me": .json(200, me("u-alex")),
            "GET /api/summary": .json(200, try fixture("summary"), delay: statusDelay),
            "GET /api/status": .json(200, statusJSON("u-alex", onboarding: 1), delay: statusDelay),
            "GET /api/version": .json(200, #"{"version":"v1"}"#),
        ])
    }

    // MARK: Item 1: a new session

    /// The web's App renders nothing until the status is known, so a new account goes straight to its welcome. Here the
    /// sign-in screen stays up until Alex's own status is read: no moment shows the dashboard (.ready) without it, or
    /// with the last person's status (Sam's, put back behind the sign-in screen by a save that landed late).
    func testANewAccountGoesStraightToItsWelcome() async throws {
        let server = try await alexsServer()
        use(server)
        let d = Dashboard()
        d.authMode = "required"
        d.phase = .signIn
        d.apply(status: try status("u-sam"))

        var samples: [(Dashboard.Phase, OnboardingMode?, String?)] = []
        let started = Task { await d.sessionStarted(email: "alex@example.test", newAccount: true) }
        var done = false
        Task { await started.value; done = true }
        while !done {
            samples.append((d.phase, d.onboarding, d.status?.user?.id))
            try await Task.sleep(for: .milliseconds(5))
        }
        samples.append((d.phase, d.onboarding, d.status?.user?.id))

        XCTAssertGreaterThan(samples.count, 20, "sampled while the status was on its way")
        for (phase, onboarding, person) in samples where phase == .ready {
            XCTAssertEqual(onboarding, .new, "the dashboard never shows before the welcome")
            XCTAssertEqual(person, "u-alex", "never Sam's status")
        }
        XCTAssertTrue(samples.contains { $0.0 == .signIn && $0.2 == nil }, "while it's read, the sign-in screen stays up with nobody's status")
        XCTAssertEqual(d.phase, .ready)
        XCTAssertEqual(d.onboarding, .new)
        XCTAssertEqual(d.status?.user?.id, "u-alex")
        XCTAssertNotNil(d.summary)
        XCTAssertEqual(server.requests("GET /api/status").count, 1, "read once, before the dashboard opened")
    }

    /// A 401 while the new session's status is read: the session didn't take, so the sign-in screen stays.
    func testA401WhileTheStatusIsReadKeepsTheSignInScreen() async throws {
        let server = try await AIStubServer.start([
            "GET /api/auth/me": .json(200, me("u-alex")),
            "GET /api/summary": .json(401, #"{"error":"Sign in required"}"#),
            "GET /api/status": .json(401, #"{"error":"Sign in required"}"#),
        ])
        use(server)
        let d = Dashboard()
        d.authMode = "required"
        d.phase = .signIn
        await d.sessionStarted(email: "alex@example.test")
        XCTAssertEqual(d.phase, .signIn)
        XCTAssertNil(d.status)
        XCTAssertNil(d.summary)
    }

    /// signedIn() (and so every sign-in) starts from nothing of the last person: no status, no summary, nothing that
    /// says what they chose.
    func testSigningInForgetsTheLastPersonsStatus() throws {
        let d = Dashboard()
        d.authMode = "required"
        d.apply(status: try status("u-sam"))
        d.summary = try JSONDecoder().decode(Summary.self, from: Data(fixture("summary").utf8))
        d.signedIn()
        XCTAssertEqual(d.phase, .ready)
        XCTAssertNil(d.status, "Sam's settings are never shown, or saved, as Alex's")
        XCTAssertNil(d.summary)
        XCTAssertNil(d.onboarding)
    }

    /// A load on its way when the person signs out (or the session ends with a 401, or someone else signs in) is
    /// nobody's when it lands: nothing of it goes into memory or onto disk.
    func testALoadThatLandsAfterTheSessionEndedIsDropped() async throws {
        let server = try await alexsServer(statusDelay: 0.5)
        use(server)
        let base = try XCTUnwrap(Config.serverURL())

        for end in ["401", "someone else"] {
            let d = Dashboard()
            d.authMode = "required"
            d.account = AuthState.User(id: "u-alex", email: "alex@example.test", name: nil, role: "member")
            d.phase = .ready
            let asked = server.requests("GET /api/status").count
            let load = Task { await d.load() }
            let onItsWay = await AIStubServer.wait { server.requests("GET /api/status").count > asked }
            XCTAssertTrue(onItsWay, "the load is on its way")
            if end == "401" {
                d.phase = .signIn
            } else {
                d.phase = .signIn
                d.account = AuthState.User(id: "u-sam", email: "sam@example.test", name: nil, role: "member")
                d.signedIn()
            }
            await load.value
            XCTAssertNil(d.status, "\(end): Alex's status isn't in memory")
            XCTAssertNil(d.summary, "\(end): nor the summary")
            XCTAssertNil(SummaryCache.load(for: base), "\(end): nor on disk")
        }
    }

    /// The same load, still for the person who asked: it shows, as always.
    func testALoadForThePersonStillHereShows() async throws {
        let server = try await alexsServer(statusDelay: 0)
        use(server)
        let d = Dashboard()
        d.authMode = "required"
        d.account = AuthState.User(id: "u-alex", email: "alex@example.test", name: nil, role: "member")
        d.phase = .ready
        await d.load()
        XCTAssertEqual(d.status?.user?.id, "u-alex")
        XCTAssertNotNil(d.summary)
    }
}
