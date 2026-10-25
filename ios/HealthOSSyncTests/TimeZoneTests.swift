import XCTest
@testable import HealthOSSync

/// The hosted server runs in UTC, so the app tells it the phone's time zone after a status read (src/App.tsx), once.
@MainActor
final class TimeZoneTests: XCTestCase {
    private func status(zone: String?) throws -> ServerStatus {
        var settings: [String: Any] = ["name": "Sam", "hiddenCards": []]
        settings["timeZone"] = zone ?? NSNull()
        return try JSONDecoder().decode(ServerStatus.self, from: JSONSerialization.data(withJSONObject: ["settings": settings]))
    }

    private func dashboard(zone: String?) throws -> Dashboard {
        let d = Dashboard()
        d.phase = .ready
        d.apply(status: try status(zone: zone))
        return d
    }

    func testADifferentZoneIsSentOnce() async throws {
        let d = try dashboard(zone: nil)
        var bodies: [String] = []
        let changed = await d.followTimeZone("Europe/Paris") { fields in
            bodies.append(String(decoding: try APIClient.settingsBody(fields), as: UTF8.self))
            return try self.status(zone: "Europe/Paris")
        }
        XCTAssertTrue(changed, "so the day is read again")
        XCTAssertEqual(bodies, [#"{"timeZone":"Europe\/Paris"}"#], "JSON may escape the slash; the server reads it the same")
        XCTAssertEqual(d.status?.settings?.timeZone, "Europe/Paris", "the answer is shown")
        // The next read finds it set: nothing more to send.
        let again = await d.followTimeZone("Europe/Paris") { _ in
            XCTFail("sent again")
            return try self.status(zone: "Europe/Paris")
        }
        XCTAssertFalse(again)
    }

    func testTheSameZoneSendsNothing() async throws {
        let d = try dashboard(zone: "Europe/Paris")
        let changed = await d.followTimeZone("Europe/Paris") { _ in
            XCTFail("nothing to send")
            return try self.status(zone: "Europe/Paris")
        }
        XCTAssertFalse(changed)
    }

    func testAServerThatKeepsItsOwnZoneIsNotAskedAgain() async throws {
        let d = try dashboard(zone: "UTC")
        var sent = 0
        let send: @MainActor ([String: Any]) async throws -> ServerStatus = { _ in
            sent += 1
            return try self.status(zone: "UTC") // ignored, as an older or odd server might
        }
        let first = await d.followTimeZone("Europe/Paris", send: send)
        XCTAssertFalse(first, "nothing changed, so no reload")
        for _ in 0..<3 { _ = await d.followTimeZone("Europe/Paris", send: send) }
        XCTAssertEqual(sent, 1, "no loop of sends")

        // The phone moved to another zone: that one goes once.
        _ = await d.followTimeZone("America/New_York", send: send)
        XCTAssertEqual(sent, 2)
    }

    func testUnreachableOrFailingSendsAreTriedAgain() async throws {
        // Offline, a server error (a cold start's 500 or 504) or the 503 behind `misconfigured`: the next read tries again.
        let failures: [Error] = [APIError.network("Can't reach the server."), APIError.server(500, ""), APIError.server(504, "Gateway Timeout"),
                                 APIError.misconfigured("Not set up yet."), CancellationError()]
        let d = try dashboard(zone: "UTC")
        var sent = 0
        for failure in failures {
            let changed = await d.followTimeZone("Europe/Paris") { _ in
                sent += 1
                throw failure
            }
            XCTAssertFalse(changed)
        }
        XCTAssertEqual(sent, failures.count, "each failure left it to the next read")
        let changed = await d.followTimeZone("Europe/Paris") { _ in
            sent += 1
            return try self.status(zone: "Europe/Paris")
        }
        XCTAssertTrue(changed)
        XCTAssertEqual(d.status?.settings?.timeZone, "Europe/Paris")
    }

    func testARefusedSendIsNotTriedAgain() async throws {
        // A 4xx is the server's answer: sending the same zone again would get the same one.
        let d = try dashboard(zone: "UTC")
        var sent = 0
        let send: @MainActor ([String: Any]) async throws -> ServerStatus = { _ in
            sent += 1
            throw APIError.server(400, "Unknown time zone.")
        }
        for _ in 0..<3 { _ = await d.followTimeZone("Europe/Paris", send: send) }
        XCTAssertEqual(sent, 1, "not asked again this session")
    }

    func testNothingIsSentBeforeTheStatusOrWhileSignedOut() async throws {
        let none = Dashboard()
        none.phase = .ready
        let noStatus = await none.followTimeZone("Europe/Paris") { _ in
            XCTFail("no status read yet")
            return try self.status(zone: "Europe/Paris")
        }
        XCTAssertFalse(noStatus)

        let d = try dashboard(zone: "UTC")
        d.phase = .signIn
        let signedOut = await d.followTimeZone("Europe/Paris") { _ in
            XCTFail("signed out")
            return try self.status(zone: "Europe/Paris")
        }
        XCTAssertFalse(signedOut)
    }

    func testANewSessionSendsItAgain() async throws {
        let d = try dashboard(zone: "UTC")
        var sent = 0
        let send: @MainActor ([String: Any]) async throws -> ServerStatus = { _ in
            sent += 1
            return try self.status(zone: "UTC")
        }
        _ = await d.followTimeZone("Europe/Paris", send: send)
        // Someone else signs in: their account gets the phone's zone too.
        d.signedIn()
        d.apply(status: try status(zone: "UTC"))
        _ = await d.followTimeZone("Europe/Paris", send: send)
        XCTAssertEqual(sent, 2)
    }
}
