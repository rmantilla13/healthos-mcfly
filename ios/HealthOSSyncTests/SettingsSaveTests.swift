import XCTest
@testable import HealthOSSync

/// One way to save settings for every page (Dashboard.save(settings:)): what's sent is what the page asked for, the
/// answer shows at once and is kept for the next launch, and a refusal changes nothing.
@MainActor
final class SettingsSaveTests: XCTestCase {
    private var savedServer: String?
    /// Nothing listens here: the cache is only keyed by it, and no test reaches a server.
    private let base = URL(string: "http://127.0.0.1:9")!

    override func setUp() async throws {
        savedServer = UserDefaults.standard.string(forKey: "serverURL")
        Config.serverText = base.absoluteString
        SummaryCache.clear(for: base)
    }

    override func tearDown() async throws {
        SummaryCache.clear(for: base)
        if let savedServer { UserDefaults.standard.set(savedServer, forKey: "serverURL") } else { UserDefaults.standard.removeObject(forKey: "serverURL") }
    }

    private func status(_ settings: String) throws -> ServerStatus {
        try JSONDecoder().decode(ServerStatus.self, from: Data(#"{"hosted":false,"settings":\#(settings)}"#.utf8))
    }

    private func summary() throws -> Summary {
        let url = Bundle(for: Self.self).url(forResource: "summary", withExtension: "json")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/summary.json")
        return try JSONDecoder().decode(Summary.self, from: Data(contentsOf: url))
    }

    func testTheAnswerShowsAndIsKeptForTheNextLaunch() async throws {
        let d = Dashboard()
        d.phase = .ready
        d.summary = try summary()
        d.apply(status: try status(#"{"units":"metric","perspective":"portrait"}"#))
        var sent: [String: Any]?
        let answer = try status(#"{"units":"imperial","perspective":"digital"}"#)
        let reply = try await d.save(settings: ["perspective": "digital", "units": "imperial"]) { fields in
            sent = fields
            return answer
        }
        XCTAssertEqual(String(decoding: try APIClient.settingsBody(try XCTUnwrap(sent)), as: UTF8.self), #"{"perspective":"digital","units":"imperial"}"#)
        XCTAssertEqual(reply.settings?.perspective, "digital")
        XCTAssertEqual(d.units, .imperial, "shown at once")
        XCTAssertEqual(d.status?.settings?.perspective, "digital")
        XCTAssertEqual(SummaryCache.load(for: base)?.status?.settings?.perspective, "digital", "kept with today's summary")
    }

    func testARefusalChangesNothing() async throws {
        let d = Dashboard()
        d.phase = .ready
        d.apply(status: try status(#"{"nutrition":false,"nutritionNumbers":null}"#))
        do {
            try await d.save(settings: ["nutrition": true]) { _ in throw APIClient.error(status: 400, message: "Choose what to show before turning nutrition on.", path: "/settings") }
            XCTFail("the refusal reaches the page")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Choose what to show before turning nutrition on.", "in the server's words")
        }
        XCTAssertEqual(d.status?.settings?.nutrition, false)
        XCTAssertNil(SummaryCache.load(for: base))
    }

    /// An older server ignores keys it doesn't know and answers with its status as it was: the page reads the answer,
    /// which has no perspective, rather than taking the save's success as the change.
    func testAnOlderServersAnswerSaysWhatItKept() async throws {
        let d = Dashboard()
        d.phase = .ready
        let reply = try await d.save(settings: ["perspective": "stats"]) { _ in try self.status(#"{"units":"metric"}"#) }
        XCTAssertNil(reply.settings?.perspective)
        XCTAssertNil(d.status?.settings?.perspective)
    }

    func testAnotherWritesAnswerIsShownTheSameWay() throws {
        let d = Dashboard()
        d.summary = try summary()
        d.showChanged(try status(#"{"cycleTracking":true}"#))
        XCTAssertTrue(d.cycleTrackingOn)
        XCTAssertEqual(SummaryCache.load(for: base)?.status?.settings?.cycleTracking, true)
        // Not for another day than today: that summary isn't the one kept.
        d.date = "2026-10-01"
        d.showChanged(try status(#"{"cycleTracking":false}"#))
        XCTAssertEqual(SummaryCache.load(for: base)?.status?.settings?.cycleTracking, true)
    }

    // MARK: An answer that lands too late

    private func person(_ id: String) -> AuthState.User { AuthState.User(id: id, email: "\(id)@example.test", name: nil, role: "member") }

    private func samsStatus(perspective: String = "digital") throws -> ServerStatus {
        try JSONDecoder().decode(ServerStatus.self, from: Data(#"{"user":{"id":"u-sam"},"settings":{"units":"metric","perspective":"\#(perspective)"}}"#.utf8))
    }

    /// Sam signed in, with today's summary and his status on screen.
    private func samsDashboard() throws -> Dashboard {
        let d = Dashboard()
        d.authMode = "required"
        d.account = person("u-sam")
        d.phase = .ready
        d.summary = try summary()
        d.apply(status: try samsStatus(perspective: "portrait"))
        return d
    }

    /// A save's answer that lands once the phase has left `.ready`, or someone else (or Sam again) has signed in, or
    /// another server is set, is Sam's settings from before: it's dropped, with nothing shown or kept, and the page hears
    /// a CancellationError, which pages stay quiet about.
    func testASaveAnsweredTooLateIsDropped() async throws {
        let cases: [(String, @MainActor (Dashboard) -> Void)] = [
            ("signed out", { $0.phase = .signIn }),
            ("offline", { $0.phase = .unavailable("offline") }),
            ("someone else signed in", { d in
                d.phase = .signIn
                d.account = self.person("u-alex")
                d.signedIn()
            }),
            ("Sam signed out and in again", { d in
                d.phase = .signIn
                d.account = self.person("u-sam")
                d.signedIn()
            }),
            ("another server", { _ in Config.serverText = "http://127.0.0.1:10" }),
        ]
        for (name, meanwhile) in cases {
            Config.serverText = base.absoluteString
            SummaryCache.clear(for: base)
            let d = try samsDashboard()
            let before = d.status?.settings?.perspective
            do {
                try await d.save(settings: ["perspective": "digital"], reload: true) { _ in
                    meanwhile(d)
                    return try self.samsStatus()
                }
                XCTFail("\(name): the late answer reaches the page as a cancellation")
            } catch {
                XCTAssertTrue(error is CancellationError, "\(name): \(error)")
            }
            XCTAssertNotEqual(d.status?.settings?.perspective, "digital", "\(name): not shown")
            if name == "offline" || name == "another server" { XCTAssertEqual(d.status?.settings?.perspective, before, "\(name): what was there stays") }
            XCTAssertNil(SummaryCache.load(for: base), "\(name): not kept for the next launch")
        }
        Config.serverText = base.absoluteString
    }

    /// The same save, answered while Sam is still here, shows as always.
    func testASaveAnsweredInTimeShows() async throws {
        let d = try samsDashboard()
        try await d.save(settings: ["perspective": "digital"]) { _ in try self.samsStatus() }
        XCTAssertEqual(d.status?.settings?.perspective, "digital")
        XCTAssertEqual(SummaryCache.load(for: base)?.status?.settings?.perspective, "digital")
    }

    /// The other writes that answer with the status follow the same rule: a card change, and the time zone.
    func testCardAndTimeZoneAnswersAnsweredTooLateAreDropped() async throws {
        let d = try samsDashboard()
        do {
            try await d.changeCards(.card("home.load", shown: true)) { _ in
                d.phase = .signIn
                return try self.samsStatus()
            }
            XCTFail("the card change's late answer is a cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertNil(d.status)

        let t = try samsDashboard()
        let zoned = try JSONDecoder().decode(ServerStatus.self, from: Data(#"{"user":{"id":"u-sam"},"settings":{"timeZone":"UTC"}}"#.utf8))
        t.apply(status: zoned)
        let moved = await t.followTimeZone("Europe/Paris") { _ in
            t.phase = .signIn
            return try JSONDecoder().decode(ServerStatus.self, from: Data(#"{"user":{"id":"u-sam"},"settings":{"timeZone":"Europe/Paris"}}"#.utf8))
        }
        XCTAssertFalse(moved)
        XCTAssertNil(t.status, "Sam's settings stay out of memory behind the sign-in screen")
        XCTAssertNil(SummaryCache.load(for: base))
    }

    /// Card changes queued behind a slow one when the session ends are never sent as whoever is here next, and the
    /// lists on their way go with the session.
    func testQueuedCardChangesGoWithTheSession() async throws {
        let d = try samsDashboard()
        var bodies: [String] = []
        var release: CheckedContinuation<Void, Never>?
        let send: @MainActor ([String: Any]) async throws -> ServerStatus = { fields in
            bodies.append(String(decoding: try APIClient.settingsBody(fields), as: UTF8.self))
            // The first one is slow to arrive.
            if bodies.count == 1 { await withCheckedContinuation { release = $0 } }
            return try self.samsStatus()
        }
        let first = Task { try await d.changeCards(.card("home.hrv", shown: false), send: send) }
        for _ in 0..<1000 where release == nil { await Task.yield() }
        let second = Task { try await d.changeCards(.card("home.spo2", shown: false), send: send) }
        for _ in 0..<1000 where !d.hiddenCards.contains("home.spo2") { await Task.yield() }
        XCTAssertEqual(d.hiddenCards, ["home.hrv", "home.spo2"], "both show at once")

        // Sam signs out while the first is on its way.
        d.phase = .signIn
        XCTAssertNil(d.pendingCards, "Sam's lists on their way don't stay for whoever is next")
        XCTAssertEqual(d.hiddenCards, [])
        release?.resume()
        for task in [first, second] {
            do {
                try await task.value
                XCTFail("an answer for Sam's session, once it's over")
            } catch {
                XCTAssertTrue(error is CancellationError, "\(error)")
            }
        }
        XCTAssertEqual(bodies.count, 1, "the change queued behind it is never sent")
        XCTAssertNil(d.pendingCards)
        XCTAssertEqual(d.hiddenCards, [])
    }
}
