import SwiftUI
import UIKit
import XCTest
@testable import HealthOSSync

/// Nutrition on iPhone Duo (design §7, §9c slice G; decisions.md Q5): each of its views drawn in the Duo's states, light
/// and dark, at the default text size and AX3, with made-up answers in place of the server's; nothing tappable on the
/// fold in any folded state; and what a fold must keep: Today's draft, its keyboard and its + menu across the pane swap,
/// no read again, and the views and what's typed in the Log across a band change. Run with
/// TEST_RUNNER_DUO_SHOTS=<folder> to get the pictures (`d-<view>-<state>-<light|dark>[-<size>].png`).
@MainActor
final class NutritionDuoTests: XCTestCase {
    private var savedServer: String?

    override func setUp() async throws {
        savedServer = UserDefaults.standard.string(forKey: "serverURL")
        // Nothing listens here: the page's own probes (the Log, Health's catch-up) fail at once and change nothing.
        Config.serverText = "http://127.0.0.1:9"
    }

    override func tearDown() async throws {
        if let savedServer { UserDefaults.standard.set(savedServer, forKey: "serverURL") } else { UserDefaults.standard.removeObject(forKey: "serverURL") }
    }

    // MARK: Made-up answers

    static let dayJSON = NutritionMadeUp.dayJSON
    static let logJSON = NutritionMadeUp.logJSON

    private func fixture(_ name: String) throws -> Data {
        let url = Bundle(for: Self.self).url(forResource: name, withExtension: "json")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name).json")
        return try Data(contentsOf: url)
    }

    /// The page's reads, answered here and counted.
    @MainActor final class Reads {
        var day = 0, totals = 0, log = 0
        let dayAnswer: FoodLogDay
        let totalsAnswer: NutritionData
        let logAnswer: FoodLog

        init(day: FoodLogDay, totals: NutritionData, log: FoodLog) {
            dayAnswer = day
            totalsAnswer = totals
            logAnswer = log
        }

        var reads: NutritionReads {
            NutritionReads(day: { [self] d, _ in
                day += 1
                d.availability.heard(foodCan: dayAnswer.can)
                return dayAnswer
            }, totals: { [self] _, _, _ in
                totals += 1
                return totalsAnswer
            }, log: { [self] d, _ in
                log += 1
                d.availability.heard(foodCan: logAnswer.can)
                return logAnswer
            })
        }
    }

    private func reads() throws -> Reads {
        Reads(day: try JSONDecoder().decode(FoodLogDay.self, from: Data(Self.dayJSON.utf8)),
              totals: try JSONDecoder().decode(NutritionData.self, from: fixture("nutrition-all")),
              log: try JSONDecoder().decode(FoodLog.self, from: Data(Self.logJSON.utf8)))
    }

    private func dashboard(on: Bool = true) throws -> Dashboard {
        let d = Dashboard()
        d.phase = .ready
        let settings = on ? #"{"settings":{"nutrition":true,"nutritionNumbers":"all"}}"# : #"{"settings":{"nutrition":false}}"#
        d.apply(status: try JSONDecoder().decode(ServerStatus.self, from: Data(settings.utf8)))
        return d
    }

    /// Nutrition turned off: the page that turns it on (NutritionIntro), with the server able to.
    private func offPage() throws -> some View {
        NutritionScreen().environment(try dashboard(on: false)).environment(AppModel()).environment(\.nutritionReads, try reads().reads)
    }

    /// The Nutrition tab as the shell shows it (without its navigation bar), opened on `tab` as a link does.
    private func page(_ tab: NutritionTab, _ d: Dashboard, _ r: Reads) -> some View {
        if tab != .today { d.open(AppRoute(.nutrition, query: ["tab": tab.rawValue])) }
        return NutritionScreen().environment(d).environment(\.nutritionReads, r.reads)
    }

    private func drawn(_ tab: NutritionTab) throws -> some View {
        page(tab, try dashboard(), try reads())
    }

    // MARK: Drawn (d)

    /// The outer display: the phone's layout in a 382 pt column, 20 / 0 margins beside the bar.
    func testOuter() async throws {
        for tab in NutritionTab.allCases { try await both(tab, .outer) }
        for tab in NutritionTab.allCases { try await DuoSnapshot.draw(try drawn(tab), as: .outer, typeSize: .accessibility3, name: "d-\(tab.rawValue)") }
    }

    /// The inner display upright (medium): the web at 669, Trends' four cards 2 × 2.
    func testInnerPortrait() async throws {
        for tab in NutritionTab.allCases { try await both(tab, .innerPortrait()) }
        for tab in NutritionTab.allCases { try await DuoSnapshot.draw(try drawn(tab), as: .innerPortrait(), typeSize: .accessibility3, name: "d-\(tab.rawValue)") }
    }

    /// The inner display in landscape, split on the fold (Q5): Today's two panes under the intro, the range views' lead
    /// beside their columns, the Log's day beside its add card.
    func testInnerLandscape() async throws {
        for tab in NutritionTab.allCases { try await both(tab, .innerLandscape()) }
        for tab in NutritionTab.allCases { try await DuoSnapshot.draw(try drawn(tab), as: .innerLandscape(), typeSize: .accessibility3, name: "d-\(tab.rawValue)") }
    }

    func testInnerLandscapeBarLeading() async throws {
        for tab in NutritionTab.allCases { try await both(tab, .innerLandscape(bar: .leading)) }
    }

    func testInnerLandscapeFoldActive() async throws {
        for tab in NutritionTab.allCases { try await both(tab, .innerLandscape(foldActive: true)) }
        for tab in NutritionTab.allCases {
            try await DuoSnapshot.draw(try drawn(tab), as: .innerLandscape(foldActive: true), typeSize: .accessibility3, name: "d-\(tab.rawValue)")
        }
    }

    /// Split View, either side: compact, the phone's layout.
    func testInnerSplitView() async throws {
        for tab in NutritionTab.allCases {
            try await both(tab, .innerSplit(bar: .leading))
            try await both(tab, .innerSplit(bar: .trailing))
        }
    }

    /// Nutrition off (the page that turns it on): every state, light and dark, and AX3 where the layout changes.
    func testTheOffPage() async throws {
        for state in DuoState.all + [.innerLandscape(foldActive: true)] {
            for dark in [false, true] { try await DuoSnapshot.draw(try offPage(), as: state, dark: dark, name: "d-off") }
        }
        for state: DuoState in [.outer, .innerPortrait(), .innerLandscape(), .innerLandscape(foldActive: true)] {
            try await DuoSnapshot.draw(try offPage(), as: state, typeSize: .accessibility3, name: "d-off")
        }
    }

    private func both(_ tab: NutritionTab, _ state: DuoState) async throws {
        for dark in [false, true] { try await DuoSnapshot.draw(try drawn(tab), as: state, dark: dark, name: "d-\(tab.rawValue)") }
    }

    // MARK: The fold (P6, D10)

    func testNothingTappableOnTheFoldFlat() async throws {
        for state: DuoState in [.innerLandscape(), .innerLandscape(bar: .leading)] {
            for size: DynamicTypeSize in [.large, .accessibility3] {
                for tab in NutritionTab.allCases {
                    try await DuoFoldAssertions.assertNothingTappableOnTheFold(try drawn(tab), state: state, typeSize: size)
                }
                try await DuoFoldAssertions.assertNothingTappableOnTheFold(try offPage(), state: state, typeSize: size)
            }
        }
    }

    func testNothingTappableOnTheFoldActive() async throws {
        for state: DuoState in [.innerLandscape(foldActive: true), .innerLandscape(foldActive: true, bar: .leading)] {
            for size: DynamicTypeSize in [.large, .accessibility3] {
                for tab in NutritionTab.allCases {
                    try await DuoFoldAssertions.assertNothingTappableOnTheFold(try drawn(tab), state: state, typeSize: size)
                }
                try await DuoFoldAssertions.assertNothingTappableOnTheFold(try offPage(), state: state, typeSize: size)
            }
        }
    }

    // MARK: What a fold keeps (P4, P14)

    /// Today's pane swap (one column ↔ two panes): what's typed stays, the composer keeps the keyboard, and nothing is
    /// read again.
    func testTheDraftAndTheKeyboardSurviveAPaneSwap() async throws {
        let d = try dashboard(), r = try reads()
        let host = try await DuoHost(page(.today, d, r), as: .outer)
        defer { host.close() }
        let composer = try XCTUnwrap(Self.composer(in: host.window), "the composer")
        composer.becomeFirstResponder()
        composer.insertText("two eggs and toast")
        try await host.settle()
        XCTAssertEqual(r.day, 1)
        for state: DuoState in [.innerLandscape(), .outer, .innerLandscape(bar: .leading), .innerPortrait(), .innerLandscape()] {
            try await host.set(state)
            let now = try XCTUnwrap(Self.composer(in: host.window), "the composer in \(state)")
            XCTAssertEqual(now.text, "two eggs and toast", "the draft in \(state)")
            XCTAssertTrue(now.isFirstResponder, "the composer still has the keyboard in \(state)")
        }
        XCTAssertEqual(r.day, 1, "a fold never reads the day again")
        Self.composer(in: host.window)?.resignFirstResponder()
    }

    /// + 's menu is the page's: a pane swap leaves it up (G4(h)).
    func testThePlusMenuSurvivesAPaneSwap() async throws {
        let d = try dashboard(), r = try reads()
        let host = try await DuoHost(page(.today, d, r), as: .outer)
        defer { host.close() }
        let elements = try await host.elements()
        let plus = try XCTUnwrap(elements.first { Self.identifier($0) == "nutritionPlus" }, "+")
        XCTAssertTrue(plus.accessibilityActivate())
        try await Task.sleep(for: .milliseconds(800))
        let menu = try XCTUnwrap(host.controller.presentedViewController, "the menu is up")
        for state: DuoState in [.innerLandscape(), .outer, .innerLandscape()] {
            try await host.set(state)
            XCTAssertTrue(host.controller.presentedViewController === menu, "the same menu, still up, in \(state)")
        }
    }

    /// The conversation fills its pane on the open Duo: the leading pane doesn't scroll, the thread does inside it, and
    /// the composer sits at the pane's foot, clear of the fold.
    func testTheConversationIsPinnedInItsPane() async throws {
        let host = try await DuoHost(try drawn(.today), as: .innerLandscape())
        defer { host.close() }
        let composer = try XCTUnwrap(Self.composer(in: host.window))
        let frame = composer.convert(composer.bounds, to: host.window)
        XCTAssertLessThan(frame.maxX, 475.5 - DuoFold.clearance, "the composer is on the leading side")
        XCTAssertGreaterThan(frame.maxY, host.window.bounds.height - 34 - 200, "the composer is at the pane's foot: \(frame)")
        let panes = Self.scrollViews(in: host.window).filter {
            let f = $0.convert($0.bounds, to: host.window)
            return f.minX < 100 && f.height > 300 && !($0 is UITextView)
        }
        let pane = try XCTUnwrap(panes.max { $0.bounds.height < $1.bounds.height }, "the leading pane")
        let room = pane.bounds.height - pane.adjustedContentInset.top - pane.adjustedContentInset.bottom
        XCTAssertLessThanOrEqual(pane.contentSize.height, room + 1, "the leading pane has nothing to scroll")
    }

    /// The range views and the Log persist across every band change (P14): the view chosen stays, nothing is read
    /// again, and what's typed into the Log's search stays.
    func testTheViewsSurviveABandChange() async throws {
        for tab: NutritionTab in [.trends, .macros, .hydration] {
            let d = try dashboard(), r = try reads()
            let host = try await DuoHost(page(tab, d, r), as: .outer)
            defer { host.close() }
            XCTAssertEqual(r.totals, 1, "\(tab)")
            for state: DuoState in [.innerPortrait(), .innerLandscape(), .innerSplit(bar: .trailing), .outer] {
                try await host.set(state)
                let elements = try await host.elements()
                let selected = elements.first { Self.identifier($0) == "nutritionView-\(tab.rawValue)" }
                XCTAssertTrue(selected?.accessibilityTraits.contains(.selected) == true, "\(tab) still chosen in \(state)")
            }
            XCTAssertEqual(r.totals, 1, "\(tab): a fold never reads again")
        }

    }

    /// The Log's two panes (Q5) swap with one column on a fold: what's typed in the add card (the search, the way in
    /// chosen, the amounts) and an entry being edited all stay, as P4 asks, and the Log isn't read again.
    func testTheLogKeepsWhatsTypedAcrossAPaneSwap() async throws {
        let d = try dashboard(), r = try reads()
        let host = try await DuoHost(page(.log, d, r), as: .outer)
        defer { host.close() }
        try await type("lentil", into: try XCTUnwrap(DuoKitTests.textField(in: host.window), "the Log's search"), host)
        try await activate("Edit Greek yogurt", host)
        try await type(" plain", into: try XCTUnwrap(Self.textField("Greek yogurt", in: host.window), "the entry's name"), host)
        for state: DuoState in [.innerLandscape(), .innerPortrait(), .innerLandscape(bar: .leading), .outer] {
            try await host.set(state)
            XCTAssertNotNil(Self.textField("lentil", in: host.window), "the search in \(state)")
            XCTAssertNotNil(Self.textField("Greek yogurt plain", in: host.window), "the editor, open with its typing, in \(state)")
        }
        // Amounts: the way in chosen and what's typed stay too.
        let ways = try XCTUnwrap(Self.segments(in: host.window), "the ways in")
        let quick = try XCTUnwrap((0..<ways.numberOfSegments).first { ways.titleForSegment(at: $0) == FoodAddMode.quick.rawValue })
        ways.selectedSegmentIndex = quick
        ways.sendActions(for: .valueChanged)
        try await host.settle()
        try await type("toast", into: try XCTUnwrap(Self.textField("", placeholder: "Quick add", in: host.window), "the quick add's name"), host)
        for state: DuoState in [.innerLandscape(), .outer, .innerLandscape()] {
            try await host.set(state)
            XCTAssertEqual(Self.segments(in: host.window)?.selectedSegmentIndex, quick, "Quick add still chosen in \(state)")
            XCTAssertNotNil(Self.textField("toast", in: host.window), "the amounts' name in \(state)")
        }
        XCTAssertEqual(r.log, 1, "the Log isn't read again")
        host.window.endEditing(true)
    }

    /// Nutrition off: choosing what to see, once asked for, stays up across the pane swap (its state is above the panes).
    func testTheOffPageKeepsItsChoiceAcrossAPaneSwap() async throws {
        let host = try await DuoHost(try offPage(), as: .outer)
        defer { host.close() }
        try await activate("Turn on Nutrition", host)
        for state: DuoState in [.innerLandscape(), .outer, .innerLandscape(bar: .leading), .innerPortrait()] {
            try await host.set(state)
            let ids = try await host.elements().compactMap { Self.identifier($0) }
            XCTAssertTrue(ids.contains("nutritionChoice-all"), "the choices still shown in \(state)")
        }
    }

    /// Today's journal: an entry being edited stays open with what's typed when a fold swaps the panes.
    func testAnEntryEditorSurvivesAPaneSwap() async throws {
        let d = try dashboard(), r = try reads()
        let host = try await DuoHost(page(.today, d, r), as: .outer)
        defer { host.close() }
        try await activate("Edit Greek yogurt", host)
        try await type(" plain", into: try XCTUnwrap(Self.textField("Greek yogurt", in: host.window), "the entry's name"), host)
        for state: DuoState in [.innerLandscape(), .outer, .innerLandscape(bar: .leading), .innerPortrait()] {
            try await host.set(state)
            XCTAssertNotNil(Self.textField("Greek yogurt plain", in: host.window), "the editor, open with its typing, in \(state)")
        }
        XCTAssertEqual(r.day, 1)
        host.window.endEditing(true)
    }

    /// A chart's table view stays across the range views' pane swap.
    func testAChartsTableViewSurvivesAPaneSwap() async throws {
        let d = try dashboard(), r = try reads()
        let host = try await DuoHost(page(.macros, d, r), as: .outer)
        defer { host.close() }
        let tables = try await host.elements().filter { $0.accessibilityLabel == "Table" }
        let first = try XCTUnwrap(tables.first, "the charts' table toggles")
        XCTAssertTrue(first.accessibilityActivate())
        try await host.settle()
        let before = try await host.elements().filter { $0.accessibilityLabel == "Table" && $0.accessibilityTraits.contains(.selected) }.count
        XCTAssertEqual(before, 1, "one chart as a table")
        for state: DuoState in [.innerLandscape(), .outer, .innerLandscape()] {
            try await host.set(state)
            let now = try await host.elements().filter { $0.accessibilityLabel == "Table" && $0.accessibilityTraits.contains(.selected) }.count
            XCTAssertEqual(now, 1, "the chart still a table in \(state)")
        }
    }

    /// A fold hands the row at the top between the one column and the pane that scrolls the content (§4). Macros: a
    /// chart well down the trailing pane, not its first row, so a pane opening at its top fails. The off page: its last
    /// card, which the one column shows at its end and the pane, where both cards fit, shows whole. (With the made-up
    /// day, Today's journal and the Log's add card are the last rows and can't reach the top of the one column; the
    /// Log's pane has that one row.)
    func testAFoldKeepsTheRowAtTheTop() async throws {
        let cases: [(String, () throws -> AnyView, String)] = [
            ("Macros", { AnyView(self.page(.macros, try self.dashboard(), try self.reads())) }, "Sugar"),
            ("Off", { AnyView(try self.offPage()) }, "What stays private"),
        ]
        for (name, make, row) in cases {
            let host = try await DuoHost(try make(), as: .outer)
            defer { host.close() }
            let scroll = try XCTUnwrap(Self.scrollViews(in: host.window).filter { $0.contentSize.height > $0.bounds.height }
                .max { $0.bounds.height < $1.bounds.height }, "\(name): the page's scroll view")
            let start = try await headerFrame(row, host)
            let end = scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height
            DuoScrollTests.drag(scroll, by: min(start.minY - scroll.convert(scroll.bounds, to: nil).minY - 8, end - scroll.contentOffset.y))
            try await host.settle()
            try await assertNearTop(row, host, "\(name), one column", strict: name == "Macros")
            try await host.set(.innerLandscape())
            let unfolded = try await assertNearTop(row, host, "\(name), unfolded", strict: name == "Macros")
            XCTAssertGreaterThan(unfolded.minX, 475.5, "\(name): on the trailing side")
            try await host.set(.outer)
            try await assertNearTop(row, host, "\(name), folded again", strict: name == "Macros")
        }
    }

    // MARK: Helpers

    private func activate(_ label: String, _ host: DuoHost) async throws {
        let element = try await host.elements().first { $0.accessibilityLabel == label }
        XCTAssertTrue(try XCTUnwrap(element, label).accessibilityActivate(), label)
        try await host.settle()
    }

    private func type(_ text: String, into field: UITextField, _ host: DuoHost) async throws {
        field.becomeFirstResponder()
        field.insertText(text)
        try await host.settle()
    }

    /// The frame (window points) of the header `label`, the lowest if there are several.
    private func headerFrame(_ label: String, _ host: DuoHost) async throws -> CGRect {
        let found = try await host.elements().filter { $0.accessibilityLabel == label && $0.accessibilityTraits.contains(.header) }
        return try XCTUnwrap(found.map(\.accessibilityFrame).max { $0.minY < $1.minY }, "the header \(label)")
    }

    /// The header sits just under the top of the scroll view it's in: the row was handed over. Or, where the scroll view
    /// can't bring it that far (not `strict`), the scroll view is at its end with the header in view.
    @discardableResult
    private func assertNearTop(_ label: String, _ host: DuoHost, _ what: String, strict: Bool = false) async throws -> CGRect {
        let frame = try await headerFrame(label, host)
        let scroll = try XCTUnwrap(Self.scrollViews(in: host.window).filter {
            let f = $0.convert($0.bounds, to: nil)
            return f.height > 200 && f.minX <= frame.midX && f.maxX >= frame.midX && f.minY <= frame.minY
        }.max { $0.bounds.height < $1.bounds.height }, "\(what): the scroll view")
        let shown = scroll.convert(scroll.bounds, to: nil)
        let top = shown.minY + scroll.adjustedContentInset.top
        let end = max(-scroll.adjustedContentInset.top, scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height)
        if !strict, scroll.contentOffset.y >= end - 1, frame.maxY <= shown.maxY - scroll.adjustedContentInset.bottom + 1 {
            XCTAssertGreaterThanOrEqual(frame.minY, top - 1, "\(what): \(label) in view")
            return frame
        }
        XCTAssertGreaterThanOrEqual(frame.minY, top - 1, "\(what): \(label) at \(frame.minY), the top at \(top)")
        XCTAssertLessThan(frame.minY, top + 80, "\(what): \(label) at \(frame.minY), the top at \(top)")
        return frame
    }

    /// A text field showing `text` (or empty, with `placeholder`).
    static func textField(_ text: String, placeholder: String? = nil, in view: UIView) -> UITextField? {
        if let field = view as? UITextField, (field.text ?? "") == text, placeholder == nil || field.placeholder == placeholder { return field }
        for sub in view.subviews { if let found = textField(text, placeholder: placeholder, in: sub) { return found } }
        return nil
    }

    static func segments(in view: UIView) -> UISegmentedControl? {
        if let s = view as? UISegmentedControl { return s }
        for sub in view.subviews { if let found = segments(in: sub) { return found } }
        return nil
    }

    /// The composer: a text view (TextField with a vertical axis), the one whose identifier is nutritionComposer.
    static func composer(in view: UIView) -> UITextView? {
        if let text = view as? UITextView, text.isEditable { return text }
        for sub in view.subviews { if let found = composer(in: sub) { return found } }
        return nil
    }

    /// Every scroll view (not text views), scrolling or not.
    static func scrollViews(in view: UIView) -> [UIScrollView] {
        var out: [UIScrollView] = []
        if let scroll = view as? UIScrollView, !(view is UITextView) { out.append(scroll) }
        for sub in view.subviews { out += scrollViews(in: sub) }
        return out
    }

    private static func identifier(_ e: NSObject) -> String? {
        let get = NSSelectorFromString("accessibilityIdentifier")
        guard e.responds(to: get) else { return nil }
        return e.perform(get)?.takeUnretainedValue() as? String
    }
}

/// A voice note on the open Duo (design §4): it's sent only when the finger lifts. A hold that ends any other way, and
/// a fold or unfold while it records, throw the recording away (it never leaves memory) and say so.
@MainActor
final class VoiceNoteHoldTests: XCTestCase {
    private final class Recorder: VoiceRecording {
        var audio: Data? = Data(repeating: 1, count: 2_000)
        var started = 0, stopped = 0, cancelled = 0
        var waits = false
        var gate: CheckedContinuation<Void, Never>?

        func start() async throws {
            started += 1
            if waits { await withCheckedContinuation { gate = $0 } }
        }
        func stop() -> Data? {
            stopped += 1
            return audio
        }
        func cancel() { cancelled += 1 }
    }

    private final class Clock { var now = Date(timeIntervalSince1970: 0) }

    private func note() -> (VoiceNote, Recorder, Clock, () -> Int) {
        let recorder = Recorder(), clock = Clock()
        var sent = 0
        let voice = VoiceNote(recorder: recorder, transcribe: { _ in sent += 1; return "two eggs" }, now: { clock.now })
        return (voice, recorder, clock, { sent })
    }

    private func settle(_ voice: VoiceNote) async {
        for _ in 0..<200 where voice.state != .idle { try? await Task.sleep(for: .milliseconds(5)) }
    }

    /// The finger lifting sends the note, as before.
    func testAHeldNoteIsSentWhenTheFingerLifts() async {
        let (voice, _, clock, sent) = note()
        await voice.start(.press)
        XCTAssertEqual(voice.state, .recording)
        clock.now = clock.now.addingTimeInterval(3)
        voice.release()
        // The hold's end is checked after the lift: it changes nothing now.
        voice.holdCancelled()
        await settle(voice)
        XCTAssertEqual(sent(), 1)
        XCTAssertNil(voice.error)
    }

    /// A hold the system took away (a scroll, the button going with its pane) sends nothing.
    func testCancelledHoldIsNotSent() async {
        let (voice, recorder, clock, sent) = note()
        await voice.start(.press)
        clock.now = clock.now.addingTimeInterval(3)
        voice.holdCancelled()
        XCTAssertEqual(voice.state, .idle)
        XCTAssertEqual(recorder.stopped, 0, "the recording is never read")
        XCTAssertEqual(recorder.cancelled, 1, "it's thrown away")
        // On any iPhone a scroll can take the touch: the line says what happened, not that the screen changed.
        XCTAssertEqual(voice.error, VoiceNote.touchTakenWords)
        voice.release()
        await settle(voice)
        XCTAssertEqual(sent(), 0)
        XCTAssertEqual(voice.error, "Stopped before you let go, so nothing was sent. Hold to talk again.")
    }

    /// A fold that takes the touch: whichever comes first, the touch's end or the size change, the line says it was the
    /// screen, and nothing is sent.
    func testAFoldThatTakesTheTouchSaysTheScreenChanged() async {
        for touchFirst in [true, false] {
            let (voice, _, clock, sent) = note()
            await voice.start(.press)
            clock.now = clock.now.addingTimeInterval(3)
            if touchFirst {
                voice.holdCancelled()
                voice.screenChanged()
            } else {
                voice.screenChanged()
                voice.holdCancelled()
            }
            voice.release()
            await settle(voice)
            XCTAssertEqual(voice.error, VoiceNote.stoppedWords, "touch first: \(touchFirst)")
            XCTAssertEqual(sent(), 0)
        }
        // A size change long after a scroll took the touch leaves the scroll's words.
        let (voice, _, clock, _) = note()
        await voice.start(.press)
        clock.now = clock.now.addingTimeInterval(3)
        voice.holdCancelled()
        clock.now = clock.now.addingTimeInterval(5)
        voice.screenChanged()
        XCTAssertEqual(voice.error, VoiceNote.touchTakenWords)
    }

    /// A fold or unfold mid-note: thrown away, and the finger lifting after it sends nothing; held or from VoiceOver.
    func testSizeChangeDuringHoldDiscards() async {
        for how: VoiceNote.Via in [.press, .toggle] {
            let (voice, recorder, clock, sent) = note()
            await voice.start(how)
            clock.now = clock.now.addingTimeInterval(3)
            voice.screenChanged()
            XCTAssertEqual(voice.state, .idle, "\(how)")
            XCTAssertEqual(recorder.cancelled, 1, "\(how)")
            if how == .press { voice.release() }
            await settle(voice)
            XCTAssertEqual(sent(), 0, "\(how)")
            XCTAssertEqual(recorder.stopped, 0, "\(how)")
        }
    }

    /// A fold while the microphone is still starting: it never records.
    func testAFoldWhileStartingNeverRecords() async {
        let (voice, recorder, _, sent) = note()
        recorder.waits = true
        voice.press()
        for _ in 0..<100 where recorder.gate == nil { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(voice.state, .starting)
        voice.screenChanged()
        recorder.gate?.resume()
        for _ in 0..<100 where recorder.cancelled < 2 { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(voice.state, .idle)
        XCTAssertEqual(recorder.cancelled, 2, "the start that came back stops its own recording")
        XCTAssertEqual(voice.error, VoiceNote.stoppedWords)
        XCTAssertEqual(sent(), 0)
    }

    /// The microphone's permission question takes the touch before it records: as a release then, nothing recorded.
    func testATouchTakenWhileStartingIsAsBefore() async {
        let (voice, recorder, _, sent) = note()
        recorder.waits = true
        voice.press()
        for _ in 0..<100 where recorder.gate == nil { try? await Task.sleep(for: .milliseconds(5)) }
        voice.holdCancelled()
        recorder.gate?.resume()
        for _ in 0..<100 where voice.state != .idle { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(voice.error, "Hold the button while you talk, then let go.")
        XCTAssertEqual(sent(), 0)
    }

    /// A note already sent and being written down goes on through a fold: its words still come.
    func testAFoldLeavesANoteBeingWrittenDown() async {
        let (voice, _, clock, sent) = note()
        var words: [String] = []
        voice.onText = { words.append($0) }
        await voice.start(.press)
        clock.now = clock.now.addingTimeInterval(3)
        voice.release()
        voice.screenChanged()
        await settle(voice)
        XCTAssertEqual(sent(), 1)
        XCTAssertEqual(words, ["two eggs"])
    }
}
