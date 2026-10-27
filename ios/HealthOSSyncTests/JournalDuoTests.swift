import SwiftUI
import UIKit
import XCTest
@testable import HealthOSSync

// The Journal page on the iPhone Duo (design §7, decisions.md Q4(b) and Q5), drawn at the Duo's sizes with the fold
// injected (§8.2): the web's one column on the outer display, upright and in Split View; the composer on the leading
// side of the fold and the check-ins on the trailing side in landscape. Nothing tappable on the fold, flat or active,
// at default text and AX3, with a check-in open for changing too; what's typed (the draft and a change in place)
// survives every fold with no second read; and the page is one person's on one server. With
// TEST_RUNNER_DUO_SHOTS=…/duo/shots/b25/k set, the drawings are written as d-<state>-<light|dark>[-<size>].png.
// Every check-in here is made up. Slice K owns this file.

/// Seven made-up check-ins over six days, and older ones.
private let pageJSON = #"""
{"today":"2026-10-26","older":true,"entries":[
 {"id":"e1","date":"2026-10-26","time":"08:10","mood":4,"text":"Made-up morning line.","createdAt":1,"updatedAt":1},
 {"id":"e2","date":"2026-10-25","time":"21:40","mood":3,"text":"A made-up evening: a slow walk after dinner and an early night.","createdAt":2,"updatedAt":2},
 {"id":"e3","date":"2026-10-24","time":"07:55","mood":5,"text":"Made-up: rested, with time for a long breakfast.","createdAt":3,"updatedAt":3},
 {"id":"e4","date":"2026-10-22","time":"22:05","mood":2,"text":"Made-up: a headache in the afternoon.","createdAt":4,"updatedAt":4},
 {"id":"e5","date":"2026-10-21","time":"12:30","mood":null,"text":"Made-up line with no mood.","createdAt":5,"updatedAt":5},
 {"id":"e6","date":"2026-10-19","time":"09:15","mood":1,"text":"Made-up: a rough night.\nBetter by lunch.","createdAt":6,"updatedAt":6},
 {"id":"e7","date":"2026-10-17","time":"20:20","mood":4,"text":"Made-up: a good day out.","createdAt":7,"updatedAt":7}
]}
"""#

@MainActor
final class JournalDuoTests: XCTestCase {
    /// The page as the shell pushes it, without its NavigationStack (blocks.md), on fake calls.
    private func page(_ fake: FakeJournalCalls, dashboard: Dashboard? = nil) -> some View {
        JournalScreen()
            .environment(dashboard ?? Dashboard())
            .environment(\.journalCalls, fake.calls)
    }

    private static let drawn: [DuoState] = [.outer, .innerPortrait(), .innerLandscape(), .innerLandscape(foldActive: true),
                                            .innerLandscape(bar: .leading), .innerSplit(bar: .leading), .innerSplit(bar: .trailing)]

    // MARK: Drawn (d)

    func testDrawnInEveryState() async throws {
        for state in Self.drawn {
            for dark in [false, true] {
                for size: DynamicTypeSize in [.large, .accessibility3] {
                    try await DuoSnapshot.draw(page(FakeJournalCalls(pageJSON)), as: state, dark: dark, typeSize: size, name: "d")
                }
            }
        }
    }

    /// A check-in open for changing, drawn where it shows the most: the outer display and the open Duo.
    func testDrawnWithACheckInOpen() async throws {
        for state: DuoState in [.outer, .innerPortrait(), .innerLandscape()] {
            for dark in [false, true] {
                let host = try await DuoHost(page(FakeJournalCalls(pageJSON)), as: state, dark: dark)
                defer { host.close() }
                try await activate("journal.entry.e1.edit", in: host)
                DuoSnapshot.write(host.image(), name: "d-editing", state: state, dark: dark)
            }
        }
    }

    // MARK: The fold

    func testNothingTappableOnTheFold() async throws {
        for state in DuoState.folded {
            for size: DynamicTypeSize in [.large, .accessibility3] {
                try await DuoFoldAssertions.assertNothingTappableOnTheFold(page(FakeJournalCalls(pageJSON)), state: state, typeSize: size)
                // With a check-in open: its moods, its box, Save changes and Cancel.
                let host = try await DuoHost(page(FakeJournalCalls(pageJSON)), as: state, typeSize: size)
                defer { host.close() }
                try await activate("journal.entry.e1.edit", in: host)
                try await DuoFoldAssertions.assertNothingTappableOnTheFold(in: host)
            }
        }
    }

    /// The open Duo in landscape is two screens: the composer left of the fold, the check-ins right of it.
    func testTheComposerIsLeadingAndTheCheckInsTrailing() async throws {
        for state: DuoState in [.innerLandscape(), .innerLandscape(bar: .leading)] {
            let host = try await DuoHost(page(FakeJournalCalls(pageJSON)), as: state)
            defer { host.close() }
            let band = try XCTUnwrap(DuoFoldAssertions.band(state))
            let elements = try await host.elements()
            let save = try XCTUnwrap(element("journal.save", in: elements))
            let edit = try XCTUnwrap(element("journal.entry.e1.edit", in: elements))
            let deleteAll = try XCTUnwrap(element("journal.deleteAll", in: elements))
            XCTAssertLessThan(save.accessibilityFrame.maxX, band.lowerBound, "Save check-in is on the leading side in \(state)")
            XCTAssertGreaterThan(edit.accessibilityFrame.minX, band.upperBound, "the check-ins are on the trailing side in \(state)")
            // The leading side is used under the composer: the privacy line and Delete all.
            XCTAssertLessThan(deleteAll.accessibilityFrame.maxX, band.lowerBound, "Delete all is on the leading side in \(state)")
            XCTAssertGreaterThan(deleteAll.accessibilityFrame.minY, save.accessibilityFrame.maxY, "under the composer in \(state)")
        }
        // Everywhere else, one column: the check-ins under the composer.
        for state: DuoState in [.outer, .innerPortrait(), .innerSplit(bar: .trailing)] {
            let host = try await DuoHost(page(FakeJournalCalls(pageJSON)), as: state)
            defer { host.close() }
            let elements = try await host.elements()
            let save = try XCTUnwrap(element("journal.save", in: elements))
            if let edit = element("journal.entry.e1.edit", in: elements) {
                XCTAssertGreaterThan(edit.accessibilityFrame.minY, save.accessibilityFrame.maxY, "\(state)")
                if let deleteAll = element("journal.deleteAll", in: elements) {
                    XCTAssertGreaterThan(deleteAll.accessibilityFrame.minY, edit.accessibilityFrame.maxY, "Delete all after the check-ins in \(state)")
                }
            }
        }
    }

    // MARK: State across a fold (P4, P14)

    /// The draft and a change in place survive every fold (the single column and the two panes swap), with no second read.
    func testWhatsTypedSurvivesEveryFoldWithNoSecondRead() async throws {
        let fake = FakeJournalCalls(pageJSON)
        let host = try await DuoHost(page(fake), as: .outer)
        defer { host.close() }
        XCTAssertEqual(fake.reads, [90])

        try await activate("journal.entry.e1.edit", in: host)
        let editBox = try XCTUnwrap(textViews(in: host.window).first { $0.text == "Made-up morning line." }, "the change's box")
        editBox.becomeFirstResponder()
        editBox.selectedRange = NSRange(location: (editBox.text as NSString).length, length: 0)
        editBox.insertText(" More made up.")
        let composer = try XCTUnwrap(textViews(in: host.window).first { $0.text.isEmpty }, "the composer's box")
        composer.becomeFirstResponder()
        composer.insertText("A made-up draft.")
        try await host.settle()

        for state: DuoState in [.innerLandscape(), .innerPortrait(), .innerLandscape(foldActive: true, bar: .leading), .innerSplit(bar: .trailing), .outer] {
            try await host.set(state)
            let texts = textViews(in: host.window).map { $0.text ?? "" }
            XCTAssertTrue(texts.contains("A made-up draft."), "the draft in \(state): \(texts.count) boxes")
            XCTAssertTrue(texts.contains { $0.hasPrefix("Made-up morning line.") && $0.contains("More made up.") }, "the change in \(state)")
            XCTAssertEqual(fake.reads, [90], "no second read in \(state)")
        }
        for state: DuoState in [.innerLandscape(), .outer] {
            try await host.set(state, typeSize: .accessibility3)
            XCTAssertTrue(textViews(in: host.window).map { $0.text ?? "" }.contains("A made-up draft."), "\(state) at AX3")
        }
        host.window.endEditing(true)
    }

    /// Someone else signing in, or another server, gets a page of their own: the last person's draft goes, and their
    /// journal is read for them.
    func testThePageIsOnePersonsOnOneServer() async throws {
        let fake = FakeJournalCalls(pageJSON)
        let dashboard = Dashboard()
        dashboard.account = try JSONDecoder().decode(AuthState.User.self, from: Data(#"{"id":"made-up-1"}"#.utf8))
        let host = try await DuoHost(page(fake, dashboard: dashboard), as: .outer)
        defer { host.close() }
        let composer = try XCTUnwrap(textViews(in: host.window).first { $0.text.isEmpty })
        composer.becomeFirstResponder()
        composer.insertText("A made-up draft.")
        try await host.settle()
        host.window.endEditing(true)

        dashboard.account = try JSONDecoder().decode(AuthState.User.self, from: Data(#"{"id":"made-up-2"}"#.utf8))
        try await host.settle()
        XCTAssertEqual(fake.reads, [90, 90], "read again for the next person")
        XCTAssertFalse(textViews(in: host.window).map { $0.text ?? "" }.contains("A made-up draft."), "nothing of the last person's")
    }

    // MARK: Older servers and failures

    func testAnOlderServerSaysSoAndAFailureNeverDoes() async throws {
        let older = FakeJournalCalls()
        older.answer = { _ in nil }
        var host = try await DuoHost(page(older), as: .outer)
        var labels = try await host.elements().compactMap(\.accessibilityLabel)
        XCTAssertTrue(labels.contains { $0.contains(JournalWords.notHere) }, "\(labels)")
        DuoSnapshot.write(host.image(), name: "d-older-server", state: .outer)
        host.close()
        // On the open Duo it's one screen, left of the fold, with nothing on it.
        for state: DuoState in [.innerLandscape(), .innerLandscape(bar: .leading)] {
            host = try await DuoHost(page(older), as: state)
            DuoSnapshot.write(host.image(), name: "d-older-server", state: state)
            try await DuoFoldAssertions.assertNothingTappableOnTheFold(in: host)
            host.close()
        }

        for error: Error in [APIError.server(500, "Something went wrong"), URLError(.notConnectedToInternet)] {
            let failing = FakeJournalCalls()
            failing.readError = error
            host = try await DuoHost(page(failing), as: .outer)
            labels = try await host.elements().compactMap(\.accessibilityLabel)
            XCTAssertTrue(labels.contains(JournalWords.couldNotOpen), "\(error): \(labels)")
            XCTAssertFalse(labels.contains { $0.contains(JournalWords.notHere) }, "\(error) is never \"not on this server\"")
            if case .server = error as? APIError { DuoSnapshot.write(host.image(), name: "d-failed", state: .outer) }
            host.close()
        }
        let failing = FakeJournalCalls()
        failing.readError = APIError.server(500, "Something went wrong")
        for state: DuoState in [.innerLandscape(), .innerLandscape(foldActive: true, bar: .leading)] {
            for size: DynamicTypeSize in [.large, .accessibility3] {
                host = try await DuoHost(page(failing), as: state, typeSize: size)
                let elements = try await host.elements()
                let tryAgain = try XCTUnwrap(element("journal.tryAgain", in: elements), "Try again in \(state)")
                let band = try XCTUnwrap(DuoFoldAssertions.band(state))
                XCTAssertLessThan(tryAgain.accessibilityFrame.maxX, band.lowerBound, "Try again left of the fold in \(state)")
                try await DuoFoldAssertions.assertNothingTappableOnTheFold(in: host)
                if size == .large { DuoSnapshot.write(host.image(), name: "d-failed", state: state) }
                host.close()
            }
        }
    }

    /// An empty journal on the open Duo: the composer and the privacy line leading, "Your journal is empty" trailing
    /// (nothing made up to fill it).
    func testDrawnEmpty() async throws {
        let empty = FakeJournalCalls(#"{"today":"2026-10-26","older":false,"entries":[]}"#)
        for state: DuoState in [.outer, .innerLandscape()] {
            for dark in [false, true] {
                try await DuoSnapshot.draw(page(empty), as: state, dark: dark, name: "d-empty")
            }
        }
    }

    /// With no check-ins to show on the open Duo, the trailing side isn't one short card: the privacy line (and Delete
    /// all, when older check-ins exist) and the art go under the empty line there, which doesn't say "above". Nothing
    /// tappable on the fold. The single column keeps the web's words.
    func testAnEmptyJournalFillsTheTrailingSide() async throws {
        let none = #"{"today":"2026-10-26","older":false,"entries":[]}"#
        let olderOnly = #"{"today":"2026-10-26","older":true,"entries":[]}"#
        for json in [none, olderOnly] {
            for state: DuoState in [.innerLandscape(), .innerLandscape(bar: .leading)] {
                let host = try await DuoHost(page(FakeJournalCalls(json)), as: state)
                defer { host.close() }
                let band = try XCTUnwrap(DuoFoldAssertions.band(state))
                let elements = try await host.elements()
                let save = try XCTUnwrap(element("journal.save", in: elements))
                let line = try XCTUnwrap(element("journal.empty", in: elements), "the empty line in \(state)")
                let privacy = try XCTUnwrap(element("journal.privacyLine", in: elements), "the privacy line in \(state)")
                XCTAssertLessThan(save.accessibilityFrame.maxX, band.lowerBound, "Save check-in leading in \(state)")
                XCTAssertGreaterThan(line.accessibilityFrame.minX, band.upperBound, "the empty line trailing in \(state)")
                XCTAssertGreaterThan(privacy.accessibilityFrame.minX, band.upperBound, "the privacy line trailing in \(state)")
                XCTAssertGreaterThan(privacy.accessibilityFrame.minY, line.accessibilityFrame.maxY, "under the empty line in \(state)")
                XCTAssertFalse(line.accessibilityLabel?.contains("above") ?? true, "no \"above\" beside the composer")
                if json == olderOnly {
                    XCTAssertEqual(line.accessibilityLabel, JournalWords.noneRecent(JournalText.recentDays))
                    let deleteAll = try XCTUnwrap(element("journal.deleteAll", in: elements), "Delete all in \(state)")
                    XCTAssertGreaterThan(deleteAll.accessibilityFrame.minX, band.upperBound, "Delete all trailing in \(state)")
                } else {
                    XCTAssertEqual(line.accessibilityLabel, JournalWords.emptyBeside)
                }
            }
            for state in DuoState.folded {
                for size: DynamicTypeSize in [.large, .accessibility3] {
                    try await DuoFoldAssertions.assertNothingTappableOnTheFold(page(FakeJournalCalls(json)), state: state, typeSize: size)
                }
            }
        }
        for state: DuoState in [.outer, .innerPortrait(), .innerSplit(bar: .trailing)] {
            let host = try await DuoHost(page(FakeJournalCalls(none)), as: state)
            defer { host.close() }
            let elements = try await host.elements()
            let line = try XCTUnwrap(element("journal.empty", in: elements), "\(state)")
            XCTAssertEqual(line.accessibilityLabel, JournalWords.empty, "the web's words in one column, \(state)")
        }
    }

    // MARK: Helpers

    /// What VoiceOver reaches by its identifier, or else by the label it's known by here (SwiftUI's elements don't all
    /// say they take identifiers, so the identifier is read through the selector).
    private func element(_ id: String, in elements: [NSObject]) -> NSObject? {
        let labels: [String: [String]] = [
            "journal.save": [JournalWords.save], "journal.entry.e1.edit": ["Edit the check-in from today at"],
            "journal.deleteAll": [JournalWords.deleteAll], "journal.tryAgain": [JournalWords.tryAgain],
            "journal.privacyLine": [JournalWords.privacy],
            "journal.empty": ["Your journal is empty", "No check-ins in the last"],
        ]
        let identifier = NSSelectorFromString("accessibilityIdentifier")
        return elements.first { o in
            if o.responds(to: identifier), o.value(forKey: "accessibilityIdentifier") as? String == id { return true }
            guard let prefixes = labels[id], let own = o.accessibilityLabel else { return false }
            return prefixes.contains { own.hasPrefix($0) }
        }
    }

    /// Presses a control as VoiceOver would, by its identifier, then lets the page settle.
    private func activate(_ id: String, in host: DuoHost, file: StaticString = #filePath, line: UInt = #line) async throws {
        let done = try await DuoAccessibility.whileOn { () async throws -> Bool in
            for _ in 0..<40 {
                var all: [NSObject] = []
                DuoAccessibility.walk(host.controller.view, into: &all)
                if let found = element(id, in: all) { return found.accessibilityActivate() }
                try await Task.sleep(for: .milliseconds(50))
            }
            return false
        }
        XCTAssertTrue(done, "\(id) pressed", file: file, line: line)
        try await host.settle()
    }

    private func textViews(in view: UIView) -> [UITextView] {
        var out: [UITextView] = []
        func walk(_ v: UIView) {
            if let t = v as? UITextView { out.append(t) }
            v.subviews.forEach(walk)
        }
        walk(view)
        return out
    }
}
