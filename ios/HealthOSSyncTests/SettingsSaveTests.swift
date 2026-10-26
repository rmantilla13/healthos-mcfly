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
}
