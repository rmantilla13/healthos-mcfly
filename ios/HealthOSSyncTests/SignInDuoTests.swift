import SwiftUI
import UIKit
import XCTest
@testable import HealthOSSync

/// The way in on iPhone Duo (duo/design.md §7, decisions.md Q5): sign-in, the invite code, a pasted reset link, Create
/// your account and Choose a new password, drawn in the Duo's states with the fold put in (DuoSnapshot), nothing
/// tappable on the fold, and a fold that keeps what's typed and asks the server nothing again (P4, P14).
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

    // MARK: The fold (P6, D10)

    func testNothingTappableOnTheFold() async throws {
        for step: SignInStep in [.signIn, .code(.invite), .code(.reset), .link(.invite, token: code)] {
            try await Self.assertClearOfTheFold(page(step), "\(step)")
        }
        server.set("POST /api/auth/link", .json(200, #"{"kind":"reset","email":null}"#))
        try await Self.assertClearOfTheFold(page(.link(.reset, token: resetToken)), "new password")
    }

    /// In a split the whole column keeps to the leading side, and the aside to the trailing one (Q5): the card ends
    /// before the fold's band and the aside starts after it. Upright, the card is the web's 520, in the middle.
    func testTheCardKeepsToItsSideAndTheAsideToTheOther() async throws {
        let host = try await DuoHost(page(), as: .innerLandscape())
        defer { host.close() }
        let band = try XCTUnwrap(DuoFoldAssertions.band(.innerLandscape()))
        let elements = try await host.elements()
        let signIn = try XCTUnwrap(elements.first { $0.accessibilityLabel == SignInWords.signIn }, "the Sign in button")
        XCTAssertLessThanOrEqual(signIn.accessibilityFrame.maxX, band.lowerBound, "Sign in ends before the fold")
        XCTAssertGreaterThanOrEqual(signIn.accessibilityFrame.minX, 20, "after the system's margin")
        let aside = try XCTUnwrap(elements.first { ($0.accessibilityLabel ?? "").contains(WelcomeLook.about) }, "the aside")
        XCTAssertGreaterThanOrEqual(aside.accessibilityFrame.minX, band.upperBound, "the aside is past the fold")
        XCTAssertFalse(aside.accessibilityTraits.contains(.button))

        try await host.set(.innerPortrait())
        let upright = try await host.elements()
        let button = try XCTUnwrap(upright.first { $0.accessibilityLabel == SignInWords.signIn })
        // The card is 520 wide in the middle of the 669 window (16 a side, 637 of content); the button is the card's
        // width less its 20 a side.
        XCTAssertEqual(button.accessibilityFrame.width, 480, accuracy: 1)
        XCTAssertEqual(button.accessibilityFrame.midX, 669 / 2, accuracy: 1)
        XCTAssertFalse(upright.contains { ($0.accessibilityLabel ?? "").contains(WelcomeLook.about) }, "no aside upright")

        try await host.set(.outer)
        let closed = try await host.elements()
        XCTAssertFalse(closed.contains { ($0.accessibilityLabel ?? "").contains(WelcomeLook.about) }, "no aside closed")
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

    /// Every state, light and dark, at the default size and AX3.
    static func drawAll(_ view: some View, name: String) async throws {
        for typeSize: DynamicTypeSize in [.large, .accessibility3] {
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

    /// Nothing tappable on the fold in each folded state (flat and active, the bar either side), at default text and AX3.
    static func assertClearOfTheFold(_ view: some View, _ name: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        for state in DuoState.folded {
            for typeSize: DynamicTypeSize in [.large, .accessibility3] {
                let host = try await DuoHost(view, as: state, typeSize: typeSize)
                let found = try await DuoFoldAssertions.offenders(in: host)
                host.window.endEditing(true)
                host.close()
                XCTAssert(found.isEmpty, "\(name) on the fold in \(state) at \(typeSize): \(found.joined(separator: "; "))", file: file, line: line)
            }
        }
    }

    static func textFields(in view: UIView) -> [UITextField] {
        if let field = view as? UITextField { return [field] }
        return view.subviews.flatMap(textFields(in:))
    }
}
