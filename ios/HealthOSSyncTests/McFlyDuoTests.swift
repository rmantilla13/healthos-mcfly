import SwiftUI
import UIKit
import XCTest
@testable import HealthOSSync

// Ask McFly on iPhone Duo (duo/design.md §7 and §9c, slice E; decisions.md Q5): the page drawn in the Duo's states with
// the fold put in, nothing tappable on the fold, the page kept whole across a band change (what's typed, the focus,
// the thread's scroll view, the sheet, and nothing read again), the pill's corner, the key sheets, and the follow
// across a reflow. The server is AIStubServer on 127.0.0.1, with made-up answers; nothing reaches a real server.
//
// TEST_RUNNER_DUO_SHOTS=<folder> writes the drawings (DuoSnapshot): d-<state>-<light|dark>[-<size>].png for the
// conversation with charts, and d-empty-…, d-unavailable-…, d-pill-…, d-sheet-chatbot-…, d-sheet-openai-….

/// What the page's conversation holds in a drawing.
private enum McFlyScene: String, CaseIterable {
    /// Two answers: a bar chart, then a comparison, a list of sports and two tiles (McFlyPreview "charts").
    case charts = "d"
    /// Nothing asked yet: the questions to start with.
    case empty = "d-empty"
    /// No assistant on this server: why not, and "Connect your own key".
    case unavailable = "d-unavailable"
}

@MainActor
final class McFlyDuoTests: XCTestCase {
    private var savedServer: String?
    private var stub: AIStubServer!

    /// The shared assistant with 26 questions left today, and keys of your own allowed (no key yet).
    private static let mcflyJSON = #"{"configured":true,"limit":30,"usedToday":4,"provider":"anthropic","source":"shared","limited":true}"#
    private static let aiJSON = #"{"byok":true,"shared":true,"keys":[],"chat":null,"chatChoice":"shared","estimate":null,"voice":false,"portraits":false}"#

    override func setUp() async throws {
        savedServer = UserDefaults.standard.string(forKey: "serverURL")
        stub = try await AIStubServer.start([
            "GET /api/mcfly": .json(200, Self.mcflyJSON),
            "GET /api/ai": .json(200, Self.aiJSON),
        ])
        Config.serverText = stub.url.absoluteString
    }

    override func tearDown() async throws {
        stub.stop()
        if let savedServer { UserDefaults.standard.set(savedServer, forKey: "serverURL") } else { UserDefaults.standard.removeObject(forKey: "serverURL") }
    }

    // MARK: Fixtures

    /// `heardAI`: GET /api/ai already answered (so the page doesn't read it again), as after the shell's load.
    private func dashboard(_ scene: McFlyScene, heardAI: Bool = true) throws -> Dashboard {
        let d = Dashboard()
        d.phase = .ready
        d.apply(status: try JSONDecoder().decode(ServerStatus.self, from: Data(#"{"hosted":false,"settings":{},"user":{"id":"duo-e","role":"member"}}"#.utf8)))
        if heardAI { d.availability.heard(ai: try JSONDecoder().decode(AiStatus.self, from: Data(Self.aiJSON.utf8))) }
        switch scene {
        case .charts: McFlyPreview.apply("charts", to: d.mcfly)
        case .empty: McFlyPreview.apply("empty", to: d.mcfly)
        case .unavailable:
            let off = McFlyStatus(configured: false, limit: 0, usedToday: 0)
            d.mcfly.preview = off
            d.mcfly.status = off
        }
        return d
    }

    private func page(_ d: Dashboard) -> some View { McFlyScreen(chat: d.mcfly).environment(d) }

    /// Each scene in `state`, light and dark, at default text and AX3.
    private func drawScenes(_ state: DuoState) async throws {
        for scene in McFlyScene.allCases {
            for dark in [false, true] {
                for size: DynamicTypeSize in [.large, .accessibility3] {
                    try await DuoSnapshot.draw(page(try dashboard(scene)), as: state, dark: dark, typeSize: size, name: scene.rawValue)
                }
            }
        }
    }

    // MARK: Drawn states (d)

    func testOuter() async throws { try await drawScenes(.outer) }
    func testInnerPortrait() async throws { try await drawScenes(.innerPortrait()) }
    func testInnerLandscape() async throws { try await drawScenes(.innerLandscape()) }
    func testInnerLandscapeBarLeading() async throws { try await drawScenes(.innerLandscape(bar: .leading)) }
    func testInnerSplitView() async throws {
        try await drawScenes(.innerSplit(bar: .leading))
        try await drawScenes(.innerSplit(bar: .trailing))
    }

    func testInnerLandscapeFlatFold() async throws {
        try await assertNothingOnTheFold(in: [.innerLandscape(), .innerLandscape(bar: .leading)])
    }

    func testInnerLandscapeActiveFold() async throws {
        try await drawScenes(.innerLandscape(foldActive: true))
        try await assertNothingOnTheFold(in: [.innerLandscape(foldActive: true), .innerLandscape(foldActive: true, bar: .leading)])
    }

    private func assertNothingOnTheFold(in states: [DuoState]) async throws {
        for state in states {
            for size: DynamicTypeSize in [.large, .accessibility3] {
                for scene in McFlyScene.allCases {
                    try await DuoFoldAssertions.assertNothingTappableOnTheFold(page(try dashboard(scene)), state: state, typeSize: size)
                }
            }
        }
    }

    // MARK: The two sides (Q5)

    /// Split on the fold: the conversation and its composer on the leading side, what it showed on the trailing side,
    /// in two columns at default text (one at AX3), and the chart no longer in the thread. Upright and folded, one
    /// column with the chart in the thread.
    func testTheConversationLeadsAndWhatItShowedIsBeside() async throws {
        let d = try dashboard(.charts)
        let host = try await DuoHost(page(d), as: .innerLandscape())
        defer { host.close() }
        let fold = try XCTUnwrap(DuoFoldAssertions.band(.innerLandscape()))
        var elements = try await host.elements()
        let question = try XCTUnwrap(elements.first { $0.accessibilityLabel == "Your question" })
        XCTAssertLessThanOrEqual(question.accessibilityFrame.maxX, fold.lowerBound, "the composer keeps to the leading side")
        let chart = try XCTUnwrap(elements.first { $0.accessibilityLabel == "Bar chart: Sleep this week" })
        XCTAssertGreaterThanOrEqual(chart.accessibilityFrame.minX, fold.upperBound, "the chart is beside the conversation")
        XCTAssertTrue(elements.contains { $0.accessibilityLabel == "Chart: Sleep this week, beside the conversation" })
        // The comparison and the sports go two to a row, side by side on the trailing side.
        let compare = try XCTUnwrap(elements.first { $0.accessibilityLabel == "This month" })
        let sport = try XCTUnwrap(elements.first { $0.accessibilityLabel == "Running" })
        XCTAssertEqual(compare.accessibilityFrame.minY, sport.accessibilityFrame.minY, accuracy: 40, "one row")
        XCTAssertLessThan(compare.accessibilityFrame.maxX, sport.accessibilityFrame.minX, "two columns")

        try await host.set(.innerLandscape(), typeSize: .accessibility3)
        elements = try await host.elements()
        let compareAX = try XCTUnwrap(elements.first { $0.accessibilityLabel == "This month" })
        let sportAX = try XCTUnwrap(elements.first { $0.accessibilityLabel == "Running" })
        XCTAssertGreaterThan(sportAX.accessibilityFrame.minY, compareAX.accessibilityFrame.maxY, "one column at AX3")

        try await host.set(.innerLandscape(), typeSize: .large)
        // One column: the newest answer's tiles are in the thread again (the thread is at its newest words).
        for state: DuoState in [.innerPortrait(), .outer, .innerSplit(bar: .trailing)] {
            try await host.set(state)
            elements = try await host.elements()
            XCTAssertTrue(elements.contains { $0.accessibilityLabel == "Your heart this week" }, "\(state)")
            XCTAssertFalse(elements.contains { ($0.accessibilityLabel ?? "").hasSuffix("beside the conversation") }, "\(state): one column")
        }
    }

    /// Nothing asked yet, beside: the questions to start with are on the trailing side, two to a row, and the thread
    /// doesn't repeat them. McFly can't answer here: nothing beside, the card keeps to the leading side.
    func testBesideAnEmptyConversationAreTheQuestionsToStartWith() async throws {
        let host = try await DuoHost(page(try dashboard(.empty)), as: .innerLandscape())
        defer { host.close() }
        let fold = try XCTUnwrap(DuoFoldAssertions.band(.innerLandscape()))
        let chips = try await host.elements().filter { McFlyWords.suggestions.contains($0.accessibilityLabel ?? "") }
        XCTAssertEqual(chips.count, McFlyWords.suggestions.count, "each once")
        XCTAssertTrue(chips.allSatisfy { $0.accessibilityFrame.minX >= fold.upperBound })
        XCTAssertEqual(Set(chips.map { $0.accessibilityFrame.minX.rounded() }).count, 2, "two columns")

        let unavailable = try await DuoHost(page(try dashboard(.unavailable)), as: .innerLandscape())
        defer { unavailable.close() }
        let all = try await unavailable.elements()
        let connect = try XCTUnwrap(all.first { $0.accessibilityLabel == McFlyWords.connect })
        XCTAssertLessThanOrEqual(connect.accessibilityFrame.maxX, fold.lowerBound)
        XCTAssertFalse(all.contains { McFlyWords.suggestions.contains($0.accessibilityLabel ?? "") }, "nothing beside")
    }

    // MARK: Band changes (P4, P14)

    /// A fold or a turn lays the page out again without making the conversation again: the same field, still focused,
    /// with what's typed (McFlyChat.draft); the same thread scroll view; the key sheet still up.
    func testStateSurvivesBandChange() async throws {
        let d = try dashboard(.charts)
        let host = try await DuoHost(page(d), as: .outer)
        defer { host.close() }
        let field = try XCTUnwrap(Self.questionField(in: host.window))
        XCTAssertTrue(field.becomeFirstResponder())
        (field as? UITextInput)?.insertText("And my steps?")
        try await host.settle()
        XCTAssertEqual(d.mcfly.draft, "And my steps?")
        let thread = try XCTUnwrap(DuoScrollTests.verticalScrollViews(in: host.window).first, "the thread scrolls")
        for state: DuoState in [.innerLandscape(), .innerPortrait(), .innerLandscape(bar: .leading), .innerSplit(bar: .trailing),
                                .innerLandscape(foldActive: true), .outer] {
            try await host.set(state)
            XCTAssertTrue(Self.questionField(in: host.window) === field, "\(state): the same field, never made again")
            XCTAssertTrue(field.isFirstResponder, "\(state): still focused")
            XCTAssertEqual(d.mcfly.draft, "And my steps?", "\(state)")
            XCTAssertNotNil(thread.window, "\(state): the same thread")
        }
        field.resignFirstResponder()
        XCTAssertEqual(d.mcfly.messages.count, 4, "the conversation")

        // The key sheet opened from "Connect your own key" stays up through a fold.
        let off = try dashboard(.unavailable)
        let other = try await DuoHost(page(off), as: .outer)
        defer { other.close() }
        let offElements = try await other.elements()
        let connect = try XCTUnwrap(offElements.first { $0.accessibilityLabel == McFlyWords.connect })
        XCTAssertTrue(connect.accessibilityActivate())
        let up = await AIStubServer.wait { other.controller.presentedViewController != nil }
        XCTAssertTrue(up, "the chatbot sheet")
        let sheet = other.controller.presentedViewController
        for state: DuoState in [.innerLandscape(), .innerPortrait(), .outer] {
            try await other.set(state)
            XCTAssertTrue(other.controller.presentedViewController === sheet, "\(state): the sheet stays")
        }
        other.controller.presentedViewController?.dismiss(animated: false)
    }

    /// The page's loaders are above the Duo's page block: a band change reads neither McFly's status nor GET /api/ai again.
    func testBandChangeDoesNotReload() async throws {
        let d = try dashboard(.charts, heardAI: false)
        d.mcfly.preview = nil // so the page reads the stub's status
        let host = try await DuoHost(page(d), as: .outer)
        defer { host.close() }
        let read = await AIStubServer.wait { [stub] in
            !(stub?.requests("GET /api/mcfly").isEmpty ?? true) && !(stub?.requests("GET /api/ai").isEmpty ?? true)
        }
        XCTAssertTrue(read, "the page read McFly's status and the keys once")
        try await host.settle()
        let before = (stub.requests("GET /api/mcfly").count, stub.requests("GET /api/ai").count)
        for state: DuoState in [.innerLandscape(), .innerPortrait(), .innerLandscape(foldActive: true, bar: .leading), .innerSplit(bar: .leading), .outer] {
            try await host.set(state)
        }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(stub.requests("GET /api/mcfly").count, before.0)
        XCTAssertEqual(stub.requests("GET /api/ai").count, before.1)
    }

    // MARK: The pill and the key sheets

    /// Home's pill: bottom-trailing, and bottom-leading beside a leading bar; never centred.
    func testThePillKeepsToTheBarsSide() async throws {
        let d = try dashboard(.empty)
        let home = Color.clear.safeAreaInset(edge: .bottom) { AskMcFlyEntry() }.background(Palette.page).environment(d)
        for state: DuoState in [.outer, .innerPortrait(), .innerLandscape(), .innerLandscape(bar: .leading), .innerSplit(bar: .leading)] {
            for dark in [false, true] {
                let host = try await DuoHost(home, as: state, dark: dark)
                defer { host.close() }
                DuoSnapshot.write(host.image(), name: "d-pill", state: state, dark: dark)
                let elements = try await host.elements()
                let pill = try XCTUnwrap(elements.first { $0.accessibilityLabel == "Ask McFly" }, "\(state)")
                let frame = pill.accessibilityFrame
                let content = state.size.width - state.insets.trailing
                if state.barEdge == .leading {
                    XCTAssertEqual(frame.minX, state.insets.leading + 16, accuracy: 1, "\(state): bottom-leading")
                } else {
                    XCTAssertEqual(frame.maxX, content - 16, accuracy: 1, "\(state): bottom-trailing")
                }
                XCTAssertGreaterThan(abs(frame.midX - state.size.width / 2), 40, "\(state): never centred")
            }
        }
    }

    /// The key sheets in the Duo's states: Manage chatbot AI at the web's md (650), Connect AI key at its sm (480).
    func testTheKeySheets() async throws {
        let d = try dashboard(.empty)
        let sheets: [(String, AnyView, CGFloat)] = [
            ("d-sheet-chatbot", AnyView(ChatbotSheet().environment(d)), SheetSize.md.maxWidth),
            ("d-sheet-openai", AnyView(OpenAIKeySheet().environment(d)), SheetSize.sm.maxWidth),
        ]
        for (name, sheet, cap) in sheets {
            for state: DuoState in [.outer, .innerPortrait(), .innerLandscape(), .innerSplit(bar: .trailing)] {
                for (dark, size) in [(false, DynamicTypeSize.large), (true, .large), (false, .accessibility3)] {
                    let reads = stub.requests("GET /api/ai").count
                    let host = try await DuoHost(sheet, as: state, dark: dark, typeSize: size)
                    defer { host.close() }
                    let asked = await AIStubServer.wait { [stub] in (stub?.requests("GET /api/ai").count ?? 0) > reads }
                    XCTAssertTrue(asked, "\(name) \(state) read GET /api/ai")
                    try await host.settle()
                    let elements = try await host.elements()
                    XCTAssertFalse(elements.contains { $0.accessibilityLabel == "Loading…" }, "\(name) \(state): loaded")
                    DuoSnapshot.write(host.image(), name: name, state: state, dark: dark, typeSize: size)
                    // The sheet's column never runs wider than its size.
                    let widest = elements.map(\.accessibilityFrame.width).max() ?? 0
                    XCTAssertLessThanOrEqual(widest, cap + 1, "\(name) \(state)")
                }
            }
        }
    }

    // MARK: The model

    /// What sits beside the conversation: each answer with a chart, the newest first, under its question.
    func testWhatTheConversationShowedNewestFirst() throws {
        let d = try dashboard(.charts)
        let shown = McFlyShownAnswer.all(d.mcfly.messages)
        XCTAssertEqual(shown.map(\.question), [McFlyWords.suggestions[3], McFlyWords.suggestions[0]])
        XCTAssertEqual(shown.map { $0.visuals.map(\.title) }, [["Steps a day", "Workouts this month", "Your heart this week"], ["Sleep this week"]])
        XCTAssertEqual(shown.first?.visuals.map(\.wide), [false, false, false], "two to a row")
        XCTAssertEqual(shown.last?.visuals.map(\.wide), [true], "a chart along the days takes the width")
        XCTAssertTrue(McFlyShownAnswer.all(try dashboard(.empty).mcfly.messages).isEmpty)
    }

    /// The draft is McFlyChat's: New chat keeps it, a sign-out (forget) clears it with the rest of the person.
    func testTheDraftIsTheConversationsAndGoesWithASignOut() throws {
        let chat = McFlyChat()
        chat.draft = "How did I sleep?"
        chat.newChat()
        XCTAssertEqual(chat.draft, "How did I sleep?")
        chat.forget()
        XCTAssertEqual(chat.draft, "")
    }

    // MARK: Helpers

    /// The composer's field, the page's one place to type: a vertical TextField is a UITextView (a UITextField on
    /// older systems).
    static func questionField(in view: UIView) -> UIView? {
        if let text = view as? UITextView, text.isEditable { return text }
        if view is UITextField { return view }
        for sub in view.subviews { if let found = questionField(in: sub) { return found } }
        return nil
    }
}

/// Ask McFly's follow across a reflow (§4): a size change (a fold, a turn, the keyboard) flows the words again, which
/// moves the content's top edge without anyone scrolling; within half a second of it that doesn't let go.
final class McFlyFollowTests: XCTestCase {
    func testReflowKeepsFollowing() {
        let follow = McFlyFollow()
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)
        follow.viewportBottom = 500
        follow.contentMoved(top: 0, bottom: 1200, at: t0)
        XCTAssertTrue(follow.following)
        follow.resized(at: t0.addingTimeInterval(1))
        // The words flow narrower: the top moves down 60 pt, the bottom far below the viewport.
        follow.contentMoved(top: 60, bottom: 1400, at: t0.addingTimeInterval(1.2))
        XCTAssertTrue(follow.following, "a reflow isn't the reader scrolling up")
        // The same move later is the reader scrolling up to reread.
        follow.contentMoved(top: 120, bottom: 1460, at: t0.addingTimeInterval(1.8))
        XCTAssertFalse(follow.following)
        // Back to within 80 pt of the bottom: following again, reflow or not.
        follow.contentMoved(top: -400, bottom: 560, at: t0.addingTimeInterval(2))
        XCTAssertTrue(follow.following)
    }

    func testScrollingUpStillLetsGoWithoutAReflow() {
        let follow = McFlyFollow()
        follow.viewportBottom = 500
        follow.contentMoved(top: 0, bottom: 1200)
        follow.contentMoved(top: 40, bottom: 1240)
        XCTAssertFalse(follow.following)
        follow.sent()
        XCTAssertTrue(follow.following)
        follow.chartTouched()
        XCTAssertFalse(follow.following)
    }
}
