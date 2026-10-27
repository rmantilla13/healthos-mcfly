import SwiftUI
import UIKit
import XCTest
@testable import HealthOSSync

/// The way in on iPhone Duo (duo/design.md §7, blocks.md): sign-in, the invite code, a pasted reset link, Create your
/// account, Choose a new password and "sign-in isn't set up", drawn in the Duo's states with the fold put in
/// (DuoSnapshot), nothing tappable on the fold (the presets' and the measured one), and a fold that keeps what's typed
/// and asks the server nothing again (P4, P14).
///
/// The server is a stub on 127.0.0.1 (AIStubServer) with made-up answers: /auth/me says the server has accounts and an
/// admin, and /auth/link takes the made-up invite or reset link. With TEST_RUNNER_DUO_SHOTS=<folder> the drawings are
/// written there as d-<page>-<state>-<light|dark>[-<size>].png.
@MainActor
final class SignInDuoTests: XCTestCase {
    private var savedServer: String?
    private var server: AIStubServer!

    /// A made-up invite code and reset link token.
    private let code = "ABCD-EFGH"
    private let resetToken = "q3X_9kP-2mZbV7aLr0TtYw4uNcEhGfDs"

    override func setUp() async throws {
        savedServer = UserDefaults.standard.string(forKey: "serverURL")
        server = try await AIStubServer.start([
            "GET /api/auth/me": .json(200, #"{"mode":"required","authenticated":false,"setup":false}"#),
            "POST /api/auth/link": .json(200, #"{"kind":"invite","email":null}"#),
        ])
        Config.serverText = server.url.absoluteString
    }

    override func tearDown() async throws {
        server.stop()
        if let savedServer { UserDefaults.standard.set(savedServer, forKey: "serverURL") } else { UserDefaults.standard.removeObject(forKey: "serverURL") }
    }

    /// Signed out on a server with accounts, as the sign-in screen is shown.
    private func dashboard() -> Dashboard {
        let d = Dashboard()
        d.authMode = "required"
        d.usesAccounts = true
        d.phase = .signIn
        return d
    }

    private func page(_ step: SignInStep = .signIn) -> some View {
        SignInView(step: step).environment(dashboard())
    }

    /// A server whose sign-in isn't set up (its /auth/me "misconfigured"): the same frame, Try again and Change server.
    private func unavailable() -> some View {
        let d = dashboard()
        d.phase = .misconfigured
        return SignInUnavailable().environment(d)
    }

    /// The drawn states: §8.2's six (the fold flat), and the inner display in landscape with the fold active.
    static let states: [DuoState] = DuoState.all + [.innerLandscape(foldActive: true)]

    // MARK: Drawn (d)

    func testSignInDrawn() async throws { try await Self.drawAll(page(), name: "d-signin") }

    func testInviteCodeDrawn() async throws { try await Self.drawAll(page(.code(.invite)), name: "d-invite-code") }

    func testResetLinkDrawn() async throws { try await Self.drawAll(page(.code(.reset)), name: "d-reset-link") }

    func testCreateAccountDrawn() async throws { try await Self.drawAll(page(.link(.invite, token: code)), name: "d-create-account") }

    func testNewPasswordDrawn() async throws {
        server.set("POST /api/auth/link", .json(200, #"{"kind":"reset","email":null}"#))
        try await Self.drawAll(page(.link(.reset, token: resetToken)), name: "d-new-password")
    }

    func testSignInUnavailableDrawn() async throws { try await Self.drawAll(unavailable(), name: "d-signin-unavailable") }

    // MARK: The fold (P6, D10)

    func testNothingTappableOnTheFold() async throws {
        for step: SignInStep in [.signIn, .code(.invite), .code(.reset), .link(.invite, token: code)] {
            try await Self.assertClearOfTheFold(page(step), "\(step)")
        }
        server.set("POST /api/auth/link", .json(200, #"{"kind":"reset","email":null}"#))
        try await Self.assertClearOfTheFold(page(.link(.reset, token: resetToken)), "new password")
        try await Self.assertClearOfTheFold(unavailable(), "sign-in isn't set up")
    }

    /// The same against the fold HOS Duo reports (40 pt wide, not the presets' 0 pt midline), the bar either side.
    func testNothingTappableOnTheMeasuredFold() async throws {
        for step: SignInStep in [.signIn, .code(.invite), .code(.reset), .link(.invite, token: code)] {
            try await Self.assertClearOfTheMeasuredFold(page(step), "\(step)")
        }
        server.set("POST /api/auth/link", .json(200, #"{"kind":"reset","email":null}"#))
        try await Self.assertClearOfTheMeasuredFold(page(.link(.reset, token: resetToken)), "new password")
        try await Self.assertClearOfTheMeasuredFold(unavailable(), "sign-in isn't set up")
    }

    /// In a split the whole page keeps to the leading side (blocks.md: `.leadingOfFold`, nothing for a second side):
    /// every control, the end link at the top included, ends before the fold's band, the bar either side, and nothing
    /// is drawn past the fold but the page's background. Upright, the card is the web's 520, in the middle.
    func testTheCardKeepsToTheLeadingSide() async throws {
        let host = try await DuoHost(page(), as: .innerLandscape())
        defer { host.close() }
        for bar: HorizontalEdge in [.trailing, .leading] {
            let state = DuoState.innerLandscape(bar: bar)
            try await host.set(state)
            let band = try XCTUnwrap(DuoFoldAssertions.band(state))
            let elements = try await host.elements()
            XCTAssertFalse(elements.isEmpty)
            for element in elements {
                XCTAssertLessThanOrEqual(element.accessibilityFrame.maxX, band.lowerBound,
                                         "\(element.accessibilityLabel ?? "?") \(element.accessibilityFrame), bar \(bar)")
            }
            let signIn = try XCTUnwrap(elements.first { $0.accessibilityLabel == SignInWords.signIn }, "the Sign in button")
            XCTAssertGreaterThanOrEqual(signIn.accessibilityFrame.minX, bar == .leading ? 84 : 16, "after the bar and the margin")
            XCTAssertNotNil(elements.first { $0.accessibilityLabel == "Change server" }, "the end link, on the leading side")
        }

        try await host.set(.innerPortrait())
        let upright = try await host.elements()
        let button = try XCTUnwrap(upright.first { $0.accessibilityLabel == SignInWords.signIn })
        // The card is 520 wide in the middle of the 669 window (16 a side, 637 of content); the button is the card's
        // width less its 20 a side.
        XCTAssertEqual(button.accessibilityFrame.width, 480, accuracy: 1)
        XCTAssertEqual(button.accessibilityFrame.midX, 669 / 2, accuracy: 1)
    }

    // MARK: A fold keeps the page (P4, P14)

    /// What's typed stays through every fold and back, and the form asks /auth/me once: the frame isn't rebuilt.
    func testStateSurvivesBandChange() async throws {
        let host = try await DuoHost(page(), as: .outer)
        defer {
            host.window.endEditing(true)
            host.close()
        }
        let fields = Self.textFields(in: host.window)
        XCTAssertEqual(fields.count, 2, "email and password")
        let email = try XCTUnwrap(fields.first { !$0.isSecureTextEntry })
        email.becomeFirstResponder()
        email.insertText("sam@example.test")
        let password = try XCTUnwrap(fields.first { $0.isSecureTextEntry })
        password.becomeFirstResponder()
        password.insertText("made-up")
        try await host.settle()
        for state: DuoState in [.innerLandscape(), .innerLandscape(foldActive: true), .innerPortrait(), .innerSplit(bar: .trailing), .outer] {
            try await host.set(state)
            let now = Self.textFields(in: host.window)
            XCTAssertEqual(now.first { !$0.isSecureTextEntry }?.text, "sam@example.test", "\(state)")
            XCTAssertEqual(now.first { $0.isSecureTextEntry }?.text?.count, 7, "\(state)")
        }
        try await host.set(.outer, typeSize: .accessibility3)
        try await host.set(.innerLandscape())
        XCTAssertEqual(Self.textFields(in: host.window).first { !$0.isSecureTextEntry }?.text, "sam@example.test", "at AX3")
        XCTAssertEqual(server.requests("GET /api/auth/me").count, 1, "the form asked whether this is a new server once")
    }

    /// The invite code step keeps its step and its code across folds: the step is SignInView's, the code JoinView's.
    func testTheStepAndTheCodeSurviveBandChange() async throws {
        let host = try await DuoHost(page(.code(.invite)), as: .innerLandscape())
        defer {
            host.window.endEditing(true)
            host.close()
        }
        let field = try XCTUnwrap(Self.textFields(in: host.window).first)
        field.becomeFirstResponder()
        field.insertText("WXYZ")
        try await host.settle()
        for state: DuoState in [.outer, .innerPortrait(), .innerLandscape(bar: .leading)] {
            try await host.set(state)
            XCTAssertEqual(Self.textFields(in: host.window).first?.text, "WXYZ", "\(state)")
        }
    }

    // MARK: Helpers

    /// The text sizes drawn and fold-checked: the default, AX3 and the largest (P6: at any text size).
    static let sizes: [DynamicTypeSize] = [.large, .accessibility3, .accessibility5]

    /// Every state, light and dark, at each of `sizes`.
    static func drawAll(_ view: some View, name: String) async throws {
        for typeSize in sizes {
            for state in states {
                for dark in [false, true] {
                    let host = try await DuoHost(view, as: state, dark: dark, typeSize: typeSize)
                    let image = host.image()
                    host.window.endEditing(true)
                    host.close()
                    DuoSnapshot.write(image, name: name, state: state, dark: dark, typeSize: typeSize)
                    XCTAssertEqual(image.size, state.size, "\(name) \(state)")
                }
            }
        }
    }

    /// Nothing tappable on the fold in each folded state (flat and active, the bar either side), at each of `sizes`.
    static func assertClearOfTheFold(_ view: some View, _ name: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        for state in DuoState.folded {
            for typeSize in sizes {
                let host = try await DuoHost(view, as: state, typeSize: typeSize)
                let found = try await DuoFoldAssertions.offenders(in: host)
                host.window.endEditing(true)
                host.close()
                XCTAssert(found.isEmpty, "\(name) on the fold in \(state) at \(typeSize): \(found.joined(separator: "; "))", file: file, line: line)
            }
        }
    }

    /// The fold HOS Duo reports (ios-seams.md, gates.md G2): a 40 pt `.division` at window x 455.5–495.5 of the inner
    /// display in landscape, so 423 | 359 beside the bar. The shared presets still put a 0 pt fold on the midline.
    static func measuredFold(active: Bool, bar: HorizontalEdge) -> DuoDisplay {
        DuoDisplay(fold: CGRect(x: 455.5, y: 0, width: 40, height: DuoDisplay.innerLandscapeSize.height), foldActive: active,
                   barEdge: bar, occlusions: [])
    }

    /// The measured fold's band in window points: its frame ±12 pt (DuoFold.clearance).
    static let measuredBand: ClosedRange<CGFloat> = (455.5 - DuoFold.clearance)...(495.5 + DuoFold.clearance)

    /// DuoFoldAssertions' check against the measured fold: the page is given that fold (nearer than the host's preset,
    /// so it wins) and nothing tappable (a button, link, adjustable control or text field, as DuoFoldAssertions counts)
    /// may meet its band, flat and active, the bar either side, at each of `sizes`. These pages have no sideways rows.
    static func assertClearOfTheMeasuredFold(_ view: some View, _ name: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        for bar: HorizontalEdge in [.trailing, .leading] {
            for active in [false, true] {
                for typeSize in sizes {
                    let host = try await DuoHost(view.environment(\.duoDisplayOverride, measuredFold(active: active, bar: bar)),
                                                 as: .innerLandscape(foldActive: active, bar: bar), typeSize: typeSize)
                    let found = try await host.elements().filter { element in
                        let traits = element.accessibilityTraits
                        let tappable = traits.contains(.button) || traits.contains(.link) || traits.contains(.adjustable)
                            || element is UITextField || element is UITextView
                        let frame = element.accessibilityFrame
                        return tappable && frame.width > 0 && frame.height > 0
                            && frame.maxX > measuredBand.lowerBound && frame.minX < measuredBand.upperBound
                    }.map { "\($0.accessibilityLabel ?? "?") \($0.accessibilityFrame)" }
                    host.window.endEditing(true)
                    host.close()
                    XCTAssert(found.isEmpty, "\(name) on the measured fold, bar \(bar), active \(active), at \(typeSize): \(found.joined(separator: "; "))",
                              file: file, line: line)
                }
            }
        }
    }

    static func textFields(in view: UIView) -> [UITextField] {
        if let field = view as? UITextField { return [field] }
        return view.subviews.flatMap(textFields(in:))
    }
}
