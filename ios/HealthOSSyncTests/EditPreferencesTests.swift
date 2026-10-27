import SwiftUI
import XCTest
@testable import HealthOSSync

/// Profile's "Edit preferences" (slice D) opens the welcome's steps again in edit mode (slice A's OnboardingView), as the
/// web's Profile links #/welcome; Back to Profile and Save preferences come back to Profile. So does the comparison
/// card's "Edit preferences" link.
@MainActor
final class EditPreferencesTests: XCTestCase {
    private var savedServer: String?

    override func setUp() async throws {
        savedServer = UserDefaults.standard.string(forKey: "serverURL")
        // Nothing listens here: Profile's own reads (keys, portraits, the comparison) fail at once and change nothing.
        Config.serverText = "http://127.0.0.1:9"
    }

    override func tearDown() async throws {
        if let savedServer { UserDefaults.standard.set(savedServer, forKey: "serverURL") } else { UserDefaults.standard.removeObject(forKey: "serverURL") }
    }

    private func web(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard let text = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) else { throw XCTSkip("\(path) isn't next to the app") }
        return text
    }

    /// Sam, signed in, done with the welcome long ago, on Profile under More.
    private func samOnProfile(_ settings: String = #"{"perspective":"digital","age":40,"peerComparison":true}"#) throws -> Dashboard {
        let d = Dashboard()
        d.authMode = "required"
        d.account = AuthState.User(id: "u-sam", email: "sam@example.test", name: "Sam", role: "member")
        d.phase = .ready
        d.apply(status: try JSONDecoder().decode(ServerStatus.self, from: Data(#"{"user":{"id":"u-sam"},"settings":\#(settings)}"#.utf8)))
        d.open(.profile)
        return d
    }

    func testProfilesEditPreferencesOpensTheWelcomeToEdit() async throws {
        XCTAssertTrue(try web("src/pages/Profile.tsx").contains("""
                      <a className="btn" href={href('welcome')}>
                        Edit preferences
                      </a>
        """), "the web's Profile links the welcome")
        XCTAssertTrue(try web("src/App.tsx").contains("page === 'welcome' ? 'edit' : null"))

        let d = try samOnProfile()
        XCTAssertNil(d.onboarding, "done with the welcome: nothing over Profile")
        try await HostedAccessibility.onScreen(ProfileScreen().environment(d).environment(AppModel())) { elements in
            let edit = try XCTUnwrap(elements.first { $0.accessibilityLabel == "Edit preferences" }, "Profile offers it")
            XCTAssertTrue(edit.accessibilityActivate())
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(d.onboarding, .edit, "the shell shows OnboardingView(mode: .edit) over the app")
        XCTAssertEqual(OnboardingFlow.startStep(onboarding: d.status?.settings?.onboarding, mode: .edit), .perspective, "from its first step")
        XCTAssertEqual(OnboardingFlow.answers(from: d.status?.settings).perspective, .digital, "with Sam's own answers")

        // Back to Profile (and Save preferences, which ends the same way): the welcome goes, and Profile is there.
        d.closeWelcome()
        XCTAssertNil(d.onboarding)
        XCTAssertEqual(d.tab, .more)
        XCTAssertEqual(d.paths[.more], [.profile])
    }

    /// The comparison card's "Turn it on in Edit preferences" (healthos://welcome) opens the same.
    func testTheComparisonsLinkOpensItToo() throws {
        let d = try samOnProfile()
        XCTAssertTrue(d.open(url: try XCTUnwrap(URL(string: "healthos://welcome"))))
        XCTAssertEqual(d.onboarding, .edit)
    }

    /// A server older than the welcome (its status names no perspective) ignores what the welcome saves: Profile offers
    /// no Edit preferences there, and nothing opens.
    func testAServerWithoutTheWelcomeHasNone() async throws {
        let d = try samOnProfile(#"{"units":"metric"}"#)
        try await HostedAccessibility.onScreen(ProfileScreen().environment(d).environment(AppModel())) { elements in
            XCTAssertNil(elements.first { $0.accessibilityLabel == "Edit preferences" })
        }
        d.open(.welcome)
        XCTAssertNil(d.onboarding)
    }

    /// A new account's welcome isn't an edit: it shows as itself, and Edit preferences doesn't turn it into one.
    func testANewAccountsWelcomeStaysNew() throws {
        let d = try samOnProfile(#"{"perspective":"portrait","onboarding":2}"#)
        XCTAssertEqual(d.onboarding, .new)
        d.open(.welcome)
        XCTAssertEqual(d.onboarding, .new)
    }
}
