import SwiftUI
import UIKit
import XCTest
@testable import HealthOSSync

/// Profile on iPhone Duo (slice D, design §7 and decisions.md Q5), drawn at the Duo's sizes with the fold put in: one
/// column on the outer display, the inner display upright and Split View; on the open Duo in landscape, the photo, the
/// name and how you're shown on the leading side of the fold, and every other row as a card, two to a row, on the
/// trailing side. Nothing tappable on the fold, flat or active, at default text and AX3, and what Profile keeps (a sheet
/// it opened, the password form and what's typed in it) stays across a fold.
///
/// The person is made up (Sam, sam@example.test); nothing here reaches a server: the server is a port nothing listens
/// on, so Profile's own reads (keys, portraits, the comparison) fail at once and change nothing.
///
/// TEST_RUNNER_DUO_SHOTS=<folder> writes the pictures (`d-<state>-<light|dark>[-<size>].png`, `d-<state>-2-…` for the
/// page scrolled a screen on), and `r-landscape-<light|dark>.png` for the first look at the open Duo's layout.
@MainActor
final class ProfileDuoTests: XCTestCase {
    private var savedServer: String?

    override func setUp() async throws {
        savedServer = UserDefaults.standard.string(forKey: "serverURL")
        Config.serverText = "http://127.0.0.1:9"
    }

    override func tearDown() async throws {
        if let savedServer { UserDefaults.standard.set(savedServer, forKey: "serverURL") } else { UserDefaults.standard.removeObject(forKey: "serverURL") }
    }

    /// Sam, signed in on a server with everything Profile can show: how they're shown, the comparison, cards, the
    /// Family board, cycle tracking and nutrition.
    static func sam(signedIn: Bool = true) throws -> Dashboard {
        let d = Dashboard()
        d.authMode = "required"
        d.account = AuthState.User(id: "u-sam", email: "sam@example.test", name: "Sam", role: "member")
        d.phase = signedIn ? .ready : .signIn
        let settings = #"{"name":"Sam","stepGoal":10000,"units":"metric","perspective":"digital","age":40,"peerComparison":true,"#
            + #""hiddenCards":[],"familySharing":true,"cycleTracking":false,"sex":"female","nutrition":true,"nutritionNumbers":"all"}"#
        d.apply(status: try JSONDecoder().decode(ServerStatus.self, from: Data(#"{"user":{"id":"u-sam","email":"sam@example.test"},"settings":\#(settings)}"#.utf8)))
        d.open(.profile)
        return d
    }

    /// Profile as the shell shows it under More, without the navigation stack (DuoSnapshot draws pages so). In the app
    /// the navigation bar sits over the page's top, and iOS 26's soft edge at the top of a scroll view lies under it;
    /// drawn with no bar, that edge would blur the page's first heading, so the drawings leave it out.
    static func page(_ d: Dashboard, query: [String: String] = [:], model: AppModel? = nil) -> some View {
        ProfileScreen(query: query).environment(d).environment(model ?? AppModel()).modifier(NoTopScrollEdge())
    }

    private func page() throws -> some View { Self.page(try Self.sam()) }

    // MARK: Drawn, in each state

    /// The open Duo in landscape, as the user first asked to see it: the photo and the name leading, two columns of
    /// cards trailing (`r-landscape-…`).
    func testFirstLookAtTheOpenDuo() async throws {
        for dark in [false, true] {
            let host = try await DuoHost(try page(), as: .innerLandscape(), dark: dark)
            defer { host.close() }
            DuoSnapshot.write(host.image(), name: "r", state: .innerLandscape(), dark: dark)
        }
    }

    func testOuter() async throws {
        for dark in [false, true] { try await drawScrolled(as: .outer, dark: dark) }
    }

    func testInnerPortrait() async throws {
        for dark in [false, true] { try await drawScrolled(as: .innerPortrait(), dark: dark) }
    }

    func testInnerLandscape() async throws {
        for dark in [false, true] { try await drawScrolled(as: .innerLandscape(), dark: dark) }
    }

    func testInnerLandscapeBarLeading() async throws {
        for dark in [false, true] { try await DuoSnapshot.draw(try page(), as: .innerLandscape(bar: .leading), dark: dark, name: "d") }
    }

    func testInnerSplitView() async throws {
        for bar: HorizontalEdge in [.leading, .trailing] {
            for dark in [false, true] { try await DuoSnapshot.draw(try page(), as: .innerSplit(bar: bar), dark: dark, name: "d") }
        }
    }

    func testInnerLandscapeFoldActive() async throws {
        for dark in [false, true] { try await DuoSnapshot.draw(try page(), as: .innerLandscape(foldActive: true), dark: dark, name: "d") }
    }

    /// AX3: one column of cards on the trailing side (no two columns at an accessibility size), still split on the
    /// fold; and the phone's one column.
    func testAX3() async throws {
        for state in [DuoState.outer, .innerPortrait(), .innerLandscape(), .innerLandscape(foldActive: true)] {
            for dark in [false, true] {
                try await DuoSnapshot.draw(try page(), as: state, dark: dark, typeSize: .accessibility3, name: "d")
            }
        }
    }

    /// Signed out: This iPhone alone, on the leading side when open, so the server can be changed there.
    func testSignedOut() async throws {
        let page = Self.page(try Self.sam(signedIn: false))
        for state in [DuoState.outer, .innerLandscape()] {
            try await DuoSnapshot.draw(page, as: state, name: "d-signed-out")
        }
    }

    // MARK: The fold

    /// Nothing tappable meets the fold, flat or active, the bar on either edge, at default text and AX3 (P6).
    func testNothingTappableOnTheFold() async throws {
        for state in DuoState.folded {
            for size: DynamicTypeSize in [.large, .accessibility3] {
                try await DuoFoldAssertions.assertNothingTappableOnTheFold(try page(), state: state, typeSize: size)
            }
        }
    }

    /// The same with the trailing side scrolled to its end (the settings, the comparison, the portrait photos and This
    /// iPhone), and with the password form open across both columns.
    func testNothingTappableOnTheFoldFurtherDown() async throws {
        for size: DynamicTypeSize in [.large, .accessibility3] {
            let host = try await DuoHost(try page(), as: .innerLandscape(), typeSize: size)
            defer { host.close() }
            try await tap("changePassword", in: host)
            try await host.settle()
            for scroll in trailing(host) {
                // Only down: the content's side margins are the scroll view's own insets, so its x stays as it is.
                scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: Self.end(of: scroll)), animated: false)
            }
            try await host.settle()
            try await DuoFoldAssertions.assertNothingTappableOnTheFold(in: host)
        }
    }

    /// Open, the leading side is the photo, the name and how you're shown, and the trailing side the cards, each wholly
    /// on its side of the fold; on the outer display, one column with no photo and name above it.
    func testTheLeadIsOnTheLeadingSide() async throws {
        let host = try await DuoHost(try page(), as: .innerLandscape())
        defer { host.close() }
        let band = try XCTUnwrap(DuoFoldAssertions.band(.innerLandscape()))
        let elements = try await host.elements()
        let identity = try XCTUnwrap(elements.first { Self.identifier($0) == "profileIdentity" }, "the photo and the name")
        let edit = try XCTUnwrap(elements.first { $0.accessibilityLabel == "Edit preferences" })
        let chatbot = try XCTUnwrap(elements.first { $0.accessibilityLabel == "Manage chatbot AI" })
        XCTAssertLessThanOrEqual(identity.accessibilityFrame.maxX, band.lowerBound)
        XCTAssertLessThanOrEqual(edit.accessibilityFrame.maxX, band.lowerBound)
        XCTAssertGreaterThanOrEqual(chatbot.accessibilityFrame.minX, band.upperBound)

        try await host.set(.outer)
        let phone = try await host.elements()
        XCTAssertNil(phone.first { Self.identifier($0) == "profileIdentity" }, "no photo and name above the cards in one column")
        XCTAssertNotNil(phone.first { $0.accessibilityLabel == "Edit preferences" })
    }

    // MARK: What a fold keeps (P4, P14)

    /// The page's state stays across every band change and a fold: the password form open, with what's typed in it,
    /// although a fold swaps the page's one column for its two panes and back.
    func testStateSurvivesBandChange() async throws {
        let host = try await DuoHost(Self.page(try Self.sam()), as: .outer)
        defer { host.close() }
        try await tap("changePassword", in: host)
        try await host.settle()
        let field = try XCTUnwrap(Self.secureField("Current password", in: host.window))
        field.becomeFirstResponder()
        field.insertText("kept-typed")
        field.resignFirstResponder()
        try await host.settle()
        for state: DuoState in [.innerLandscape(), .innerPortrait(), .innerLandscape(foldActive: true), .innerSplit(bar: .trailing), .outer] {
            try await host.set(state)
            let now = try XCTUnwrap(Self.secureField("Current password", in: host.window), "the form is still open in \(state)")
            XCTAssertEqual(now.text, "kept-typed", "\(state)")
        }
    }

    /// Closing Change password forgets what was typed and what came of it, as closing the form always has on every
    /// iPhone: the draft is the page's only so a fold doesn't close the open form.
    func testClosingThePasswordFormForgetsWhatWasTyped() async throws {
        let host = try await DuoHost(Self.page(try Self.sam()), as: .outer)
        defer { host.close() }
        try await tap("changePassword", in: host)
        try await host.settle()
        let field = try XCTUnwrap(Self.secureField("Current password", in: host.window))
        field.becomeFirstResponder()
        field.insertText("typed-then-closed")
        field.resignFirstResponder()
        try await host.settle()
        try await tap("changePassword", in: host)
        try await host.settle()
        XCTAssertNil(Self.secureField("Current password", in: host.window), "closed")
        try await tap("changePassword", in: host)
        try await host.settle()
        let again = try XCTUnwrap(Self.secureField("Current password", in: host.window), "open again")
        XCTAssertEqual(again.text ?? "", "", "nothing kept from before it closed")
    }

    /// The draft itself: closing clears the three fields and the last line; opening keeps nothing from before.
    func testThePasswordDraftClearsWhenClosed() {
        let draft = ProfilePasswordDraft()
        draft.toggle()
        XCTAssertTrue(draft.open)
        draft.current = "a"
        draft.next = "b"
        draft.confirm = "c"
        draft.result = (false, "Your current password is wrong.")
        draft.toggle()
        XCTAssertFalse(draft.open)
        draft.toggle()
        XCTAssertTrue(draft.open)
        XCTAssertEqual([draft.current, draft.next, draft.confirm], ["", "", ""])
        XCTAssertNil(draft.result)
    }

    /// A fold keeps the reader's place (§4, G4(a)): scrolled down to This iPhone in one column, unfolding opens the
    /// trailing pane on This iPhone (as far as the pane goes), and folding again brings the one column back down there,
    /// not to its top. The same row has the same id on both sides (ProfileRowID).
    func testAFoldKeepsThePlace() async throws {
        let host = try await DuoHost(Self.page(try Self.sam()), as: .outer)
        defer { host.close() }
        let column = try XCTUnwrap(DuoScrollTests.verticalScrollView(in: host.window))
        XCTAssertEqual(column.contentOffset.y + column.adjustedContentInset.top, 0, accuracy: 1, "opens at its top")
        let heading = try await frame(of: "This iPhone", in: host)
        // This iPhone's card a little above the top of the scroll view, so it's the row at the top.
        DuoScrollTests.drag(column, by: heading.minY - column.convert(column.bounds, to: nil).minY - 40)
        try await host.settle()
        let past = try await frame(of: "Your profile", in: host)
        XCTAssertLessThan(past.maxY, 0, "scrolled past Your profile")

        try await host.set(.innerLandscape())
        let pane = try XCTUnwrap(trailing(host).first, "the trailing pane scrolls")
        XCTAssertGreaterThan(pane.contentOffset.y + pane.adjustedContentInset.top, 1, "the pane isn't at its top")
        let paneFrame = pane.convert(pane.bounds, to: nil)
        let inPane = try await frame(of: "This iPhone", in: host)
        XCTAssertTrue(paneFrame.intersects(inPane), "This iPhone is in view in the trailing pane: \(inPane) in \(paneFrame)")

        try await host.set(.outer)
        let again = try XCTUnwrap(DuoScrollTests.verticalScrollView(in: host.window))
        XCTAssertGreaterThan(again.contentOffset.y + again.adjustedContentInset.top, 1, "folded, the column isn't back at its top")
        let above = try await frame(of: "Your profile", in: host)
        XCTAssertLessThan(above.maxY, 0, "Your profile is still above")
    }

    /// A sheet Profile opened stays up across a fold, the same sheet: it's the page's, above its panes (P4).
    func testASheetStaysUpAcrossAFold() async throws {
        let host = try await DuoHost(Self.page(try Self.sam()), as: .outer)
        defer { host.close() }
        try await tap("settings-basics", in: host)
        try await waitFor { host.controller.presentedViewController != nil }
        let sheet = try XCTUnwrap(host.controller.presentedViewController)
        for state: DuoState in [.innerLandscape(), .outer, .innerPortrait()] {
            try await host.set(state)
            XCTAssertTrue(host.controller.presentedViewController === sheet, "the same sheet is still up in \(state)")
        }
    }

    /// A fold doesn't do the page's loading again: `?connect=chatbot` opens its sheet once, and a fold that swaps the
    /// page's one column for its two panes doesn't open it again.
    func testBandChangeDoesNotReload() async throws {
        let d = try Self.sam()
        d.availability.heard(ai: AiStatus(byok: true))
        d.open(AppRoute(.profile, query: ["connect": "chatbot"]))
        let host = try await DuoHost(Self.page(d, query: ["connect": "chatbot"]), as: .outer)
        defer { host.close() }
        try await waitFor { host.controller.presentedViewController != nil }
        host.controller.dismiss(animated: false)
        try await waitFor { host.controller.presentedViewController == nil }
        for state: DuoState in [.innerLandscape(), .outer, .innerLandscape(foldActive: true)] {
            try await host.set(state)
            XCTAssertNil(host.controller.presentedViewController, "the link's sheet doesn't open again in \(state)")
        }
    }

    // MARK: Helpers

    /// Draws the first screen, then the page scrolled on a screen at a time (the trailing side when open), as `-2`, `-3`.
    private func drawScrolled(as state: DuoState, dark: Bool) async throws {
        let host = try await DuoHost(try page(), as: state, dark: dark)
        defer { host.close() }
        let first = host.image()
        DuoSnapshot.write(first, name: "d", state: state, dark: dark)
        XCTAssertEqual(first.size, state.size)
        let scrolls = trailing(host)
        for part in 2...4 {
            var moved = false
            for scroll in scrolls {
                let y = min(Self.end(of: scroll), CGFloat(part - 1) * (scroll.bounds.height - 120))
                if y > scroll.contentOffset.y + 1 { moved = true }
                scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: y), animated: false)
            }
            guard moved else { break }
            try await host.settle()
            DuoSnapshot.write(host.image(), name: "d", state: state, dark: dark, part: part)
        }
    }

    /// The furthest down a scroll view goes, its bottom inset (the Duo's 34) included.
    static func end(of scroll: UIScrollView) -> CGFloat {
        max(0, scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height)
    }

    /// The scroll views that move: the trailing pane's when open, the one column's otherwise.
    private func trailing(_ host: DuoHost) -> [UIScrollView] {
        let all = DuoScrollTests.verticalScrollViews(in: host.window)
        let mid = host.window.bounds.midX
        let right = all.filter { $0.convert($0.bounds, to: host.window).minX > mid - 20 }
        return right.isEmpty ? all : right
    }

    /// Where the heading with this label is, in window points.
    private func frame(of heading: String, in host: DuoHost) async throws -> CGRect {
        let elements = try await host.elements()
        let found = try XCTUnwrap(elements.first { $0.accessibilityLabel == heading && $0.accessibilityTraits.contains(.header) },
                                  "\(heading) is a heading on the page")
        return found.accessibilityFrame
    }

    /// Taps the button with this identifier as VoiceOver would.
    private func tap(_ identifier: String, in host: DuoHost) async throws {
        let elements = try await host.elements()
        let button = try XCTUnwrap(elements.first { Self.identifier($0) == identifier }, "\(identifier) is on screen")
        XCTAssertTrue(button.accessibilityActivate(), identifier)
    }

    private func waitFor(_ condition: () -> Bool, seconds: Double = 5) async throws {
        let end = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > end { XCTFail("timed out"); return }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    /// An element's accessibility identifier: SwiftUI's elements answer it without saying they conform.
    static func identifier(_ element: NSObject) -> String? {
        if let id = (element as? UIAccessibilityIdentification)?.accessibilityIdentifier { return id }
        guard element.responds(to: NSSelectorFromString("accessibilityIdentifier")) else { return nil }
        return element.value(forKey: "accessibilityIdentifier") as? String
    }

    static func secureField(_ label: String, in view: UIView) -> UITextField? {
        if let field = view as? UITextField, field.isSecureTextEntry, field.accessibilityLabel == label { return field }
        for sub in view.subviews { if let field = secureField(label, in: sub) { return field } }
        return nil
    }
}

/// iOS 26's soft scroll edge at the top, left out of the drawings (see `ProfileDuoTests.page`).
private struct NoTopScrollEdge: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.scrollEdgeEffectHidden(true, for: .top)
        } else {
            content
        }
    }
}

private extension DuoSnapshot {
    /// A scrolled part of a state's drawing: `<name>-<state>-<part>-<light|dark>.png`, as the web's references name theirs.
    static func write(_ image: UIImage, name: String, state: DuoState, dark: Bool, part: Int) {
        guard let folder else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? image.pngData()?.write(to: folder.appendingPathComponent("\(name)-\(state)-\(part)-\(dark ? "dark" : "light").png"))
    }
}
