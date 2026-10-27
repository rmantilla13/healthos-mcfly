import SwiftUI
import UIKit
import XCTest
@testable import HealthOSSync

/// The welcome's three steps on iPhone Duo (duo/design.md §7): the phone's form closed and on the leading side of the fold
/// in landscape, the web's ≤720 form upright (every step's name above the card), nothing tappable on the fold, and a
/// fold that keeps the step, what's typed and what was read (P4, P14). Drawn without OnboardingView's navigation stack
/// (blocks.md: a stack in a drawn view takes the test iPhone's safe area), from a model with made-up answers whose saves
/// go nowhere. The portraits list (the reference row's one read) is counted, and fails, so a rebuilt row would read it
/// again. With TEST_RUNNER_DUO_SHOTS=<folder> the drawings are written there as d-welcome-<n>-<state>-….png.
@MainActor
final class WelcomeDuoTests: XCTestCase {
    private var savedServer: String?

    override func setUp() async throws {
        savedServer = UserDefaults.standard.string(forKey: "serverURL")
        // No server: the welcome's own reads (GET /api/ai) ask nobody.
        Config.serverText = ""
    }

    override func tearDown() async throws {
        if let savedServer { UserDefaults.standard.set(savedServer, forKey: "serverURL") } else { UserDefaults.standard.removeObject(forKey: "serverURL") }
    }

    /// How often the reference row read the portraits list.
    private final class Reads { var portraits = 0 }

    private struct Offline: Error {}

    /// A new account's welcome at `step`, signed in, with a Sign out at the top as the app shows it.
    private func welcome(_ step: OnboardingStep, reads: Reads = Reads()) async -> some View {
        let d = Dashboard()
        d.signedIn()
        d.authMode = "required"
        let model = OnboardingModel(mode: .new, settings: nil, save: { _, _ in }, finish: {})
        if step >= .about { await model.go(.about) }
        if step == .community {
            model.setAge("34")
            await model.go(.community)
        }
        let reference = ReferencePhoto(add: { _ in throw Offline() }, delete: { _ in throw Offline() }, list: {
            reads.portraits += 1
            throw Offline()
        })
        return OnboardingSteps(model: model, reference: reference).environment(d)
    }

    // MARK: Drawn (d)

    func testStep1Drawn() async throws { try await SignInDuoTests.drawAll(await welcome(.perspective), name: "d-welcome-1") }

    func testStep2Drawn() async throws { try await SignInDuoTests.drawAll(await welcome(.about), name: "d-welcome-2") }

    func testStep3Drawn() async throws { try await SignInDuoTests.drawAll(await welcome(.community), name: "d-welcome-3") }

    // MARK: The fold (P6, D10)

    func testNothingTappableOnTheFold() async throws {
        for step in OnboardingStep.allCases {
            try await SignInDuoTests.assertClearOfTheFold(await welcome(step), "step \(step.rawValue)")
        }
    }

    /// The same against the fold HOS Duo reports (40 pt wide, not the presets' 0 pt midline), the bar either side.
    func testNothingTappableOnTheMeasuredFold() async throws {
        for step in OnboardingStep.allCases {
            try await SignInDuoTests.assertClearOfTheMeasuredFold(await welcome(step), "step \(step.rawValue)")
        }
    }

    /// Upright (medium) every step keeps its name, as the web above 560; closed, and on the leading side in landscape
    /// (compact there), only the current one does, as the web's phone. VoiceOver reads every name either way, so this
    /// measures the tabs: a tab with its name drawn is far wider than its numeral alone.
    func testStepNamesShowUprightOnly() async throws {
        let host = try await DuoHost(await welcome(.about), as: .outer)
        defer { host.close() }
        let current = [OnboardingStep.about.rawValue]
        let shownClosed = try await Self.named(in: host)
        XCTAssertEqual(shownClosed, current, "closed")
        try await host.set(.innerPortrait())
        let shownUpright = try await Self.named(in: host)
        XCTAssertEqual(shownUpright, [1, 2, 3], "upright")
        try await host.set(.innerLandscape())
        let shownLeading = try await Self.named(in: host)
        XCTAssertEqual(shownLeading, current, "on the leading side in landscape")
        try await host.set(.innerPortrait(), typeSize: .accessibility3)
        let shownAX3 = try await Self.named(in: host)
        XCTAssertEqual(shownAX3, current, "upright at AX3 (the compact band)")
    }

    /// The steps whose tab shows its name: wider than 60 pt (a numeral alone is about 13).
    static func named(in host: DuoHost) async throws -> [Int] {
        let tabs = try await host.elements().filter { ($0.accessibilityLabel ?? "").hasPrefix("Step ") }
        XCTAssertEqual(tabs.count, 3, "three step tabs")
        return OnboardingStep.allCases.map(\.rawValue).filter { n in
            tabs.contains { ($0.accessibilityLabel ?? "").hasPrefix("Step \(n) of 3") && $0.accessibilityFrame.width > 60 }
        }
    }

    /// In landscape the card keeps to the leading side: on every step, the bar either side, every element (the Sign
    /// out at the top and each choice included) ends before the fold's band, so nothing reaches into it or past it.
    func testTheCardKeepsToTheLeadingSide() async throws {
        for step in OnboardingStep.allCases {
            for bar: HorizontalEdge in [.trailing, .leading] {
                let state = DuoState.innerLandscape(bar: bar)
                let host = try await DuoHost(await welcome(step), as: state)
                let band = try XCTUnwrap(DuoFoldAssertions.band(state))
                let elements = try await host.elements()
                host.window.endEditing(true)
                host.close()
                XCTAssertFalse(elements.isEmpty)
                for element in elements {
                    XCTAssertLessThanOrEqual(element.accessibilityFrame.maxX, band.lowerBound,
                                             "step \(step.rawValue), bar \(bar): \(element.accessibilityLabel ?? "?") \(element.accessibilityFrame)")
                }
                if step == .perspective {
                    XCTAssertNotNil(elements.first { ($0.accessibilityLabel ?? "").hasPrefix("Digital human") }, "step 1's choices")
                }
            }
        }
    }

    // MARK: A fold keeps the page (P4, P14)

    /// Step 2's age, typed, stays in its field across folds, the step stays, and the reference row on step 1 read the
    /// portraits list once however often the device folded.
    func testStateSurvivesBandChange() async throws {
        let reads = Reads()
        let first = try await DuoHost(await welcome(.perspective, reads: reads), as: .outer)
        for state: DuoState in [.innerLandscape(), .innerLandscape(foldActive: true), .innerPortrait(), .innerSplit(bar: .leading), .outer] {
            try await first.set(state)
        }
        try await first.set(.innerLandscape(), typeSize: .accessibility3)
        first.close()
        XCTAssertEqual(reads.portraits, 1, "the reference row read the portraits list once")

        let host = try await DuoHost(await welcome(.about), as: .outer)
        defer {
            host.window.endEditing(true)
            host.close()
        }
        let age = try XCTUnwrap(SignInDuoTests.textFields(in: host.window).first)
        age.becomeFirstResponder()
        age.insertText("41")
        try await host.settle()
        for state: DuoState in [.innerLandscape(), .innerPortrait(), .innerLandscape(bar: .leading), .outer] {
            try await host.set(state)
            XCTAssertEqual(SignInDuoTests.textFields(in: host.window).first?.text, "41", "\(state)")
            XCTAssertTrue(SignInDuoTests.textFields(in: host.window).first?.isFirstResponder == true, "still focused in \(state)")
        }
    }

    // MARK: The age's Done (iOS 27.1: none in the keyboard's bar)

    /// Step 2 with the age field focused, as iOS 27.1 shows it (no Done in the keyboard's bar, so the field puts one
    /// up beside it), and that Done's frame. Drawn tests run on 27.0, so the bar is turned off here as 27.1 has it.
    private func focusedAge(_ state: DuoState, display: DuoDisplay? = nil, typeSize: DynamicTypeSize = .large,
                            barHoldsDone: Bool = false) async throws -> (host: DuoHost, done: CGRect?, field: CGRect) {
        var view = AnyView(await welcome(.about).environment(\.duoKeyboardDoneInBar, barHoldsDone))
        if let display { view = AnyView(view.environment(\.duoDisplayOverride, display)) }
        let host = try await DuoHost(view, as: state, typeSize: typeSize)
        let age = try XCTUnwrap(SignInDuoTests.textFields(in: host.window).first)
        age.becomeFirstResponder()
        var done: CGRect?
        for _ in 0..<20 where done == nil {
            try await host.settle()
            done = try await host.elements().first { ProfileDuoTests.identifier($0) == "fieldDone" }?.accessibilityFrame
            if barHoldsDone { break }
        }
        let field = try await host.elements().first { ProfileDuoTests.identifier($0) == "age" }?.accessibilityFrame ?? .null
        return (host, done, field)
    }

    /// Build 23's check: with the Duo open flat, the keyboard bar's centred Done sat on the fold (x 401–466 against the
    /// fold at 455.5–495.5). The age's own Done stays clear of the measured fold and its 12 pt either side, flat and
    /// active, the bar either side, at every text size, and nothing else tappable meets it.
    func testTheAgesDoneIsClearOfTheMeasuredFold() async throws {
        for bar: HorizontalEdge in [.trailing, .leading] {
            for active in [false, true] {
                for typeSize in SignInDuoTests.sizes {
                    let (host, done, field) = try await focusedAge(.innerLandscape(foldActive: active, bar: bar),
                                                                   display: SignInDuoTests.measuredFold(active: active, bar: bar),
                                                                   typeSize: typeSize)
                    let elements = try await host.elements()
                    host.window.endEditing(true)
                    host.close()
                    let name = "bar \(bar), active \(active), at \(typeSize)"
                    let frame = try XCTUnwrap(done, "the age's Done is up, \(name)")
                    XCTAssertLessThanOrEqual(frame.maxX, SignInDuoTests.measuredBand.lowerBound, "Done \(frame), \(name)")
                    XCTAssertTrue(frame.minX >= field.maxX || frame.minY >= field.maxY, "Done \(frame) is beside or under the field \(field), \(name)")
                    for element in elements {
                        let traits = element.accessibilityTraits
                        guard traits.contains(.button) || element is UITextField else { continue }
                        let f = element.accessibilityFrame
                        XCTAssertFalse(f.maxX > SignInDuoTests.measuredBand.lowerBound && f.minX < SignInDuoTests.measuredBand.upperBound,
                                       "\(element.accessibilityLabel ?? "?") \(f) on the measured fold, \(name)")
                    }
                }
            }
        }
    }

    /// The same against the shared presets' folds (DuoFoldAssertions), in every folded state.
    func testTheAgesDoneIsClearOfThePresetFolds() async throws {
        for state in DuoState.folded {
            for typeSize in SignInDuoTests.sizes {
                let (host, done, _) = try await focusedAge(state, typeSize: typeSize)
                XCTAssertNotNil(done, "the age's Done is up in \(state) at \(typeSize)")
                let found = try await DuoFoldAssertions.offenders(in: host)
                host.window.endEditing(true)
                host.close()
                XCTAssert(found.isEmpty, "on the fold in \(state) at \(typeSize): \(found.joined(separator: "; "))")
            }
        }
    }

    /// Closed (the outer display), the keyboard bar's Done sat over "years" beside the field. The age's own Done comes
    /// after the field and its unit, inside the window, at every text size.
    func testTheAgesDoneLeavesItsUnitShowingClosed() async throws {
        for typeSize in SignInDuoTests.sizes {
            let (host, done, field) = try await focusedAge(.outer, typeSize: typeSize)
            let width = host.window.bounds.width
            host.window.endEditing(true)
            host.close()
            let frame = try XCTUnwrap(done, "the age's Done is up at \(typeSize)")
            // Beside: after the field, 14 pt, "years" and 12 pt more; else on a line of its own under the field.
            XCTAssertTrue(frame.minX >= field.maxX + 14 + 20 || frame.minY >= field.maxY, "Done \(frame), field \(field), at \(typeSize)")
            XCTAssertLessThanOrEqual(frame.maxX, width, "Done \(frame) is inside the window at \(typeSize)")
            XCTAssertGreaterThanOrEqual(frame.height, 44, "Done is a full-size target at \(typeSize)")
        }
    }

    /// Where the keyboard's bar holds Done (every iOS before 27.1), the field puts up none of its own.
    func testNoDoneBesideTheAgeWhileTheBarHasOne() async throws {
        let (host, done, _) = try await focusedAge(.outer, barHoldsDone: true)
        host.window.endEditing(true)
        host.close()
        XCTAssertNil(done)
    }
}
