import XCTest
@testable import HealthOSSync

/// What a refused request says: the server's own words where it writes them for people, as the web shows them.
final class ServerErrorTests: XCTestCase {
    private func text(_ status: Int, _ message: String?, path: String = "/settings") -> String? {
        APIClient.error(status: status, message: message, path: path).errorDescription
    }

    func testThePlainWordsShowAsTheyAre() {
        XCTAssertEqual(text(400, "Choose what to show before turning nutrition on."), "Choose what to show before turning nutrition on.")
        XCTAssertEqual(text(403, "Only an admin can do that."), "Only an admin can do that.")
        XCTAssertEqual(text(409, "Turn on Nutrition to log food.", path: "/nutrition/log"), "Turn on Nutrition to log food.")
        XCTAssertEqual(text(429, "Too many tries. Wait a minute."), "Too many tries. Wait a minute.")
    }

    func testTheCodeShowsWhereThereAreNoWords() {
        XCTAssertEqual(text(400, nil), "Server answered 400: \(HTTPURLResponse.localizedString(forStatusCode: 400))")
        XCTAssertEqual(text(429, ""), "Server answered 429: \(HTTPURLResponse.localizedString(forStatusCode: 429))")
        // Other codes keep it, words or not.
        XCTAssertEqual(text(404, "Not found"), "Server answered 404: Not found")
        XCTAssertEqual(text(500, "Something broke"), "Server answered 500: Something broke")
        XCTAssertEqual(text(502, nil), "Server answered 502: \(HTTPURLResponse.localizedString(forStatusCode: 502))")
    }

    func testTheCodeStillReachesCallers() {
        // Callers match on the code (older servers' 404s, /whoop/sync's 400), so it stays a .server error.
        guard case .server(404, "Not found") = APIClient.error(status: 404, message: "Not found", path: "/journal") else { return XCTFail() }
        guard case .server(400, "") = APIClient.error(status: 400, message: nil, path: "/whoop/sync") else { return XCTFail() }
        guard case .misconfigured("McFly isn't set up on this server yet.") = APIClient.error(status: 503, message: "McFly isn't set up on this server yet.", path: "/mcfly") else { return XCTFail() }
    }

    func testAccountForms() {
        // The sign-in itself: a 401 is a wrong password, shown as written.
        guard case .network("Wrong email or password.") = APIClient.error(status: 401, message: "Wrong email or password.", path: "/auth/login") else { return XCTFail() }
        guard case .network("Use a password of at least 10 characters.") = APIClient.error(status: 400, message: "Use a password of at least 10 characters.", path: "/auth/invite") else { return XCTFail() }
        // Changing the password: its 403 is written for people too.
        XCTAssertEqual(text(403, "Your current password is wrong.", path: "/auth/password"), "Your current password is wrong.")
        guard case .network = APIClient.error(status: 403, message: "Your current password is wrong.", path: "/auth/password") else { return XCTFail() }
        // But it needs a session: a 401 there means signed out, not a wrong password.
        guard case .signInRequired = APIClient.error(status: 401, message: "Sign in required", path: "/auth/password") else { return XCTFail() }
        guard case .signInRequired = APIClient.error(status: 401, message: "Sign in required", path: "/summary") else { return XCTFail() }
    }

    func testFoodMessagesFallBackWithoutWords() {
        XCTAssertEqual(APIError.server(409, "Turn on Nutrition to log food.").foodMessage, "Turn on Nutrition to log food.")
        XCTAssertEqual(APIError.server(404, "No such entry").foodMessage, "No such entry")
        XCTAssertEqual(APIError.server(500, "").foodMessage, "Server answered 500: \(HTTPURLResponse.localizedString(forStatusCode: 500))")
    }
}
