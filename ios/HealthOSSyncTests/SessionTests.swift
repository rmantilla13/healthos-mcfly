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

    // MARK: Item 3: what the server can do, portraits and the food log

    private func person(_ id: String) -> AuthState.User { AuthState.User(id: id, email: "\(id)@example.test", name: nil, role: "member") }

    /// Alex signed in on the stub.
    private func alexHere() -> Dashboard {
        let d = Dashboard()
        d.authMode = "required"
        d.account = person("u-alex")
        d.phase = .ready
        return d
    }

    /// The ways a session ends while an answer is on its way.
    private let endings: [(String, @MainActor (Dashboard) -> Void)] = [
        ("signed out", { $0.phase = .signIn }),
        ("someone else signed in", { d in
            d.phase = .signIn
            d.account = AuthState.User(id: "u-sam", email: "sam@example.test", name: nil, role: "member")
            d.signedIn()
        }),
        // The account read again names someone else, with nothing forgotten in between (Availability's own
        // generation can't see this one; the person in `session` does).
        ("another person, nothing forgotten", { d in d.account = AuthState.User(id: "u-sam", email: "sam@example.test", name: nil, role: "member") }),
    ]

    /// Starts `call` on a stub whose answer to `key` takes a moment, ends the session while it's on its way, and hands
    /// back what the call did.
    private func whileOnItsWay(_ server: AIStubServer, _ key: String, end: @MainActor (Dashboard) -> Void, d: Dashboard,
                               _ call: @escaping @MainActor () async throws -> Void) async -> Error? {
        let asked = server.requests(key).count
        let task = Task { @MainActor () -> Error? in
            do {
                try await call()
                return nil
            } catch {
                return error
            }
        }
        _ = await AIStubServer.wait { server.requests(key).count > asked }
        end(d)
        return await task.value
    }

    /// GET /api/ai answered once the person has gone: what the server can do for them says nothing for whoever is here.
    func testWhatTheServerCanDoForOnePersonNeverReachesTheNext() async throws {
        let server = try await AIStubServer.start(["GET /api/ai": .json(200, #"{"byok":true,"portraits":true,"voice":true}"#, delay: 0.3)])
        use(server)
        for (name, end) in endings {
            let d = alexHere()
            _ = await whileOnItsWay(server, "GET /api/ai", end: end, d: d) { await d.loadAI(force: true) }
            XCTAssertEqual(d.availability.ai, .unknown, "\(name)")
            XCTAssertNil(d.availability.byok, "\(name)")
        }
        // Still Alex: it's known.
        let d = alexHere()
        await d.loadAI(force: true)
        XCTAssertEqual(d.availability.byok, true)
    }

    /// A reference photo kept, or a portrait deleted, answered once the person has gone: the caller hears a
    /// CancellationError (which it stays quiet about) rather than the photo or the list, and Availability hears nothing.
    func testAPortraitAnswerForOnePersonNeverReachesTheNext() async throws {
        let list = try fixture("portraits")
        let server = try await AIStubServer.start([
            "POST /api/portraits/reference": .json(200, #"{"portrait":{"id":"r9","kind":"reference","status":"ready"}}"#, delay: 0.3),
            "DELETE /api/portraits/r1": .json(200, list, delay: 0.3),
        ])
        use(server)
        let photo = PreparedPhoto(jpeg: Data([0xFF, 0xD8, 0xFF, 0xD9]), width: 1, height: 1)
        for (name, end) in endings {
            let d = alexHere()
            let added = await whileOnItsWay(server, "POST /api/portraits/reference", end: end, d: d) { _ = try await d.addReference(photo) }
            XCTAssertTrue(added is CancellationError, "\(name): addReference, \(String(describing: added))")
            let e = alexHere()
            let deleted = await whileOnItsWay(server, "DELETE /api/portraits/r1", end: end, d: e) { try await e.deletePortrait(id: "r1") }
            XCTAssertTrue(deleted is CancellationError, "\(name): deletePortrait, \(String(describing: deleted))")
            XCTAssertNil(e.availability.portraits, "\(name): nothing said about the next person's portraits")
        }
        // Still Alex: the photo comes back with its id, and the list says whether one can be made.
        let d = alexHere()
        let kept = try await d.addReference(photo)
        XCTAssertEqual(kept.id, "r9")
        _ = try await d.deletePortrait(id: "r1")
        XCTAssertNotNil(d.availability.portraits)
    }

    /// The food log's `can` (estimates, voice notes) answered once the person has gone says nothing for whoever is here.
    func testAFoodLogDayForOnePersonNeverReachesTheNext() async throws {
        let server = try await AIStubServer.start(["POST /api/nutrition/log/day": .json(200, try fixture("food-log-day"), delay: 0.3)])
        use(server)
        for (name, end) in endings {
            let d = alexHere()
            let error = await whileOnItsWay(server, "POST /api/nutrition/log/day", end: end, d: d) { _ = try await d.loadFoodLogDay(date: nil) }
            XCTAssertTrue(error is CancellationError, "\(name): \(String(describing: error))")
            XCTAssertNil(d.availability.estimate, "\(name)")
            XCTAssertNil(d.availability.voice, "\(name)")
        }
        let d = alexHere()
        let day = try await d.loadFoodLogDay(date: nil)
        XCTAssertNotNil(day)
        XCTAssertNotNil(d.availability.estimate, "still Alex: heard")
    }

    /// A 401 is the server saying the session that asked has ended. The last person's request, refused after they
    /// signed out, says nothing about whoever signed in since: they stay signed in. The same person's still signs out.
    func testALate401NeverSignsOutWhoeverSignedInSince() async throws {
        let refused = #"{"error":"Sign in required"}"#
        let server = try await AIStubServer.start([
            "POST /api/portraits/reference": .json(401, refused, delay: 0.3),
            "PUT /api/settings": .json(401, refused, delay: 0.3),
        ])
        use(server)
        let photo = PreparedPhoto(jpeg: Data([0xFF, 0xD8, 0xFF, 0xD9]), width: 1, height: 1)
        let someoneElse = endings[1].1

        let d = alexHere()
        let added = await whileOnItsWay(server, "POST /api/portraits/reference", end: someoneElse, d: d) { _ = try await d.addReference(photo) }
        XCTAssertTrue(added is CancellationError, String(describing: added))
        XCTAssertEqual(d.phase, .ready, "Sam stays signed in")

        let e = alexHere()
        let saved = await whileOnItsWay(server, "PUT /api/settings", end: someoneElse, d: e) { try await e.save(settings: ["units": "imperial"]) }
        XCTAssertTrue(saved is CancellationError, String(describing: saved))
        XCTAssertEqual(e.phase, .ready, "Sam stays signed in")

        // Still Alex's session: the 401 brings up sign-in, as always.
        let f = alexHere()
        do {
            _ = try await f.addReference(photo)
            XCTFail("refused")
        } catch {
            guard case .signInRequired? = error as? APIError else { return XCTFail("a 401: \(error)") }
        }
        XCTAssertEqual(f.phase, .signIn)
    }
}
