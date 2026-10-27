import SwiftUI
import UIKit
import XCTest
@testable import HealthOSSync

// Vitals on the iPhone Duo (duo/design.md §7 and §8.2, decisions.md Q5), drawn on the iPhone 18 Pro's iOS 27.0 with the
// Duo's sizes and fold injected: one column on the outer display and in Split View, the signals 2-up on the inner
// display upright with the trends one to a row, and opened out sideways Q5's frame: the lead (the intro and the five
// signals, two to a row) still on the leading side, "Your trends" scrolling on the trailing side with each chart across
// it. Nothing tappable on the fold, flat or active, at the default text size and AX3; the day picked, the range, what
// was read and the place survive every fold.
//
// TEST_RUNNER_DUO_SHOTS=<folder> writes the d-*.png pictures (`d-<state>-<light|dark>[-<size>].png` for the page's
// first screen, `d-trends-…` scrolled to "Your trends", `d-day-…` with the Day view up, `d-extras-…` scrolled to the
// end with the iPhone's own cards).

@MainActor
final class VitalsDuoTests: XCTestCase {
    /// §8.2's states, with the fold active too.
    static let states: [DuoState] = [.outer, .innerPortrait(), .innerLandscape(), .innerLandscape(foldActive: true),
                                     .innerLandscape(bar: .leading), .innerSplit(bar: .leading), .innerSplit(bar: .trailing)]

    /// Waits until the page has had its answers, then lets it draw them.
    private func ready(_ host: DuoHost, _ until: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let end = Date().addingTimeInterval(10)
        while !until(), Date() < end { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(until(), "the page's reads", file: file, line: line)
        try await host.settle()
    }

    /// Scrolls the scroll view that holds "Your trends" so the heading is near its top.
    private func scrollToTrends(_ host: DuoHost) async throws {
        let elements = try await host.elements()
        guard let heading = elements.first(where: { $0.accessibilityLabel == VitalsWords.trends }) else { return }
        let frame = heading.accessibilityFrame
        for scroll in DuoScrollTests.verticalScrollViews(in: host.window) {
            let box = scroll.convert(scroll.bounds, to: nil)
            guard box.minX <= frame.midX, frame.midX <= box.maxX else { continue }
            let target = scroll.contentOffset.y + frame.minY - box.minY - 12
            let most = max(0, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: min(max(0, target), most)), animated: false)
        }
        try await host.settle()
    }

    // MARK: Drawn

    func testDrawnInEveryState() async throws {
        for state in Self.states {
            for dark in [false, true] {
                for size: DynamicTypeSize in [.large, .accessibility3] {
                    let fixtures = try VitalsFixtures()
                    let host = try await DuoHost(fixtures.page(fixtures.dashboard()), as: state, dark: dark, typeSize: size)
                    defer { host.close() }
                    try await ready(host) { fixtures.trends == 1 && fixtures.days.count == 1 }
                    // Once laid out, the lead fits its pane and stays put: only the trailing pane scrolls. (DuoStillPaneLog
                    // counts a first pass, before the pane's width is known, that tries the scrolling fallback.)
                    if case .innerLandscape = state, !size.isAccessibilitySize {
                        XCTAssertEqual(DuoScrollTests.verticalScrollViews(in: host.window).count, 1, "\(state): the lead fits its pane, still")
                    }
                    let top = host.image()
                    XCTAssertEqual(top.size, state.size, "\(state)")
                    DuoSnapshot.write(top, name: "d", state: state, dark: dark, typeSize: size)
                    try await scrollToTrends(host)
                    DuoSnapshot.write(host.image(), name: "d-trends", state: state, dark: dark, typeSize: size)
                }
            }
        }
    }

    func testTheDayViewDrawn() async throws {
        for state: DuoState in [.outer, .innerPortrait(), .innerLandscape(), .innerSplit(bar: .trailing)] {
            for dark in [false, true] {
                let fixtures = try VitalsFixtures()
                let host = try await DuoHost(fixtures.page(fixtures.dashboard(range: 1)), as: state, dark: dark)
                defer { host.close() }
                try await ready(host) { fixtures.days.count == 1 }
                try await scrollToTrends(host)
                DuoSnapshot.write(host.image(), name: "d-day", state: state, dark: dark)
            }
        }
    }

    /// The iPhone's own cards (blood pressure, glucose, breathing disturbances, nightly temperature) after the web's:
    /// each a row of its own, as wide as the web's cards, none crossing the fold; drawn scrolled to the page's end.
    func testThePhonesOwnCards() async throws {
        for state: DuoState in [.outer, .innerPortrait(), .innerLandscape()] {
            for dark in [false, true] {
                let fixtures = try VitalsFixtures()
                fixtures.addPhoneMetrics()
                let host = try await DuoHost(fixtures.page(fixtures.dashboard()), as: state, dark: dark)
                defer { host.close() }
                try await ready(host) { fixtures.trends == 1 && fixtures.tempHistory == 1 }
                for scroll in DuoScrollTests.verticalScrollViews(in: host.window) {
                    let most = max(0, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
                    scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: most), animated: false)
                }
                try await host.settle()
                DuoSnapshot.write(host.image(), name: "d-extras", state: state, dark: dark)
                guard !dark else { continue }
                let elements = try await host.elements()
                func frame(_ label: String) -> CGRect? { elements.first { $0.accessibilityLabel == label }?.accessibilityFrame }
                // Each title where the web's cards' titles are: a row of its own, on the trailing side opened out.
                let web = try XCTUnwrap(frame("Resting heart rate").flatMap { _ in
                    elements.first { $0.accessibilityLabel == "Resting heart rate" && $0.accessibilityTraits.contains(.header) }?.accessibilityFrame
                }, "\(state)")
                for title in ["Nightly temperature", "Blood pressure", "Blood glucose", "Breathing disturbances"] {
                    let r = try XCTUnwrap(frame(title), "\(state): \(title)")
                    XCTAssertEqual(r.minX, web.minX, accuracy: 1, "\(state): \(title) a row of its own, lined up with the web's")
                    if let band = DuoFoldAssertions.band(state) {
                        XCTAssertGreaterThanOrEqual(r.minX, band.upperBound, "\(state): \(title) on the trailing side")
                    }
                }
            }
        }
    }

    /// Opened out sideways the page splits on the fold: every card wholly on one side, the signals and the trend cards
    /// two to a row (one each side), so both sides carry cards; the intro's words leading and Manage sources trailing.
    /// Upright, the signals two to a row with the fifth alone and the trends one to a row (the web's); on the outer
    /// display, one to a row.
    func testWhereTheCardsGo() async throws {
        struct Placed { var cards: [String: CGRect] = [:]; var trends: [String: CGRect] = [:]; var named: [String: CGRect] = [:]; var scrolls = 0 }
        func frames(_ state: DuoState, _ size: DynamicTypeSize = .large) async throws -> Placed {
            let fixtures = try VitalsFixtures()
            let host = try await DuoHost(fixtures.page(fixtures.dashboard()), as: state, typeSize: size)
            defer { host.close() }
            try await ready(host) { fixtures.trends == 1 }
            var out = Placed()
            out.scrolls = DuoScrollTests.verticalScrollViews(in: host.window).count
            for e in try await host.elements() {
                let r = e.accessibilityFrame
                guard let label = e.accessibilityLabel else { continue }
                if let hint = e.accessibilityHint, hint.hasPrefix("Opens "), hint.hasSuffix(" details") {
                    out.cards[String(hint.dropFirst(6).dropLast(8))] = r
                } else if [VitalsWords.title, VitalsWords.trends, "Manage sources"].contains(label) {
                    out.named[label] = r
                } else if e.accessibilityTraits.contains(.header) {
                    // A trend card's title ("Resting heart rate"): the signal cards' are inside their buttons.
                    out.trends[label] = r
                }
            }
            return out
        }
        func oneSide(_ r: CGRect, _ band: ClosedRange<CGFloat>) -> Bool { r.maxX <= band.lowerBound || r.minX >= band.upperBound }

        for state: DuoState in [.innerLandscape(), .innerLandscape(bar: .leading), .innerLandscape(foldActive: true)] {
            let band = try XCTUnwrap(DuoFoldAssertions.band(state))
            let open = try await frames(state)
            XCTAssertEqual(open.cards.count, 5, "\(state)")
            XCTAssertGreaterThanOrEqual(open.trends.count, 2, "\(state)")
            XCTAssertEqual(open.scrolls, 1, "\(state): only the trailing pane scrolls; the lead stays put")
            // Q5: the lead, the intro and the five signals two to a row, all on the leading side.
            for (name, r) in open.cards { XCTAssertLessThanOrEqual(r.maxX, band.lowerBound, "\(state): signal \(name) leading") }
            let rhr = try XCTUnwrap(open.cards["Resting heart rate"]), spo2 = try XCTUnwrap(open.cards["Blood oxygen"])
            XCTAssertEqual(rhr.minY, spo2.minY, accuracy: 1, "\(state): two signals to a row")
            XCTAssertEqual(try XCTUnwrap(open.cards["Respiratory rate"]).width, rhr.width, accuracy: 1, "the fifth stays short")
            let title = try XCTUnwrap(open.named[VitalsWords.title]), pill = try XCTUnwrap(open.named["Manage sources"])
            XCTAssertLessThanOrEqual(title.maxX, band.lowerBound, "\(state): the intro leading")
            XCTAssertLessThanOrEqual(pill.maxX, band.lowerBound, "\(state): Manage sources with it")
            let resp = try XCTUnwrap(open.cards["Respiratory rate"])
            XCTAssertGreaterThan(pill.minX, resp.maxX, "\(state): Manage sources in the cell beside the fifth signal")
            XCTAssertLessThanOrEqual(pill.maxY, resp.maxY + 1, "\(state)")
            // The rest on the trailing side: "Your trends" at the pane's top, each chart a row across it.
            let heading = try XCTUnwrap(open.named[VitalsWords.trends])
            XCTAssertGreaterThanOrEqual(heading.minX, band.upperBound, "\(state): Your trends trailing")
            XCTAssertLessThan(heading.minY, rhr.maxY, "\(state): Your trends at the top, beside the lead")
            for (name, r) in open.trends { XCTAssertGreaterThanOrEqual(r.minX, band.upperBound, "\(state): \(name) trailing") }
            let first = try XCTUnwrap(open.trends["Recovery"]), second = try XCTUnwrap(open.trends["Resting heart rate"])
            XCTAssertGreaterThan(second.minY, first.maxY, "\(state): one chart to a row")
        }

        let upright = try await frames(.innerPortrait())
        XCTAssertEqual(try XCTUnwrap(upright.cards["Resting heart rate"]).minY, try XCTUnwrap(upright.cards["Blood oxygen"]).minY, accuracy: 1, "2-up upright")
        XCTAssertEqual(try XCTUnwrap(upright.cards["Respiratory rate"]).width, try XCTUnwrap(upright.cards["HRV"]).width, accuracy: 1, "short last row")
        XCTAssertGreaterThan(try XCTUnwrap(upright.trends["HRV (RMSSD)"]).minY,
                             try XCTUnwrap(upright.trends["Resting heart rate"]).maxY, "trends one to a row upright, as the web's")

        let outer = try await frames(.outer)
        XCTAssertGreaterThan(try XCTUnwrap(outer.cards["Blood oxygen"]).minY, try XCTUnwrap(outer.cards["Resting heart rate"]).maxY, "one to a row outside")
        XCTAssertGreaterThan(try XCTUnwrap(outer.trends["HRV (RMSSD)"]).minY, try XCTUnwrap(outer.trends["Resting heart rate"]).maxY)

        // At AX3 opened out: still the lead leading and the trends trailing.
        let band = try XCTUnwrap(DuoFoldAssertions.band(.innerLandscape()))
        let large = try await frames(.innerLandscape(), .accessibility3)
        for (name, r) in large.cards { XCTAssertLessThanOrEqual(r.maxX, band.lowerBound, "AX3: \(name) leading") }
        for (name, r) in large.trends { XCTAssertGreaterThanOrEqual(r.minX, band.upperBound, "AX3: \(name) trailing") }
    }

    /// The Day view opened out: the signals stay on the leading side and the hours, with its footnote, on the trailing
    /// side, so neither side is left empty.
    func testTheDayViewOpenedOut() async throws {
        let fixtures = try VitalsFixtures()
        let host = try await DuoHost(fixtures.page(fixtures.dashboard(range: 1)), as: .innerLandscape())
        defer { host.close() }
        try await ready(host) { fixtures.days.count == 1 }
        let band = try XCTUnwrap(DuoFoldAssertions.band(.innerLandscape()))
        let elements = try await host.elements()
        let signals = elements.filter { ($0.accessibilityHint ?? "").hasSuffix(" details") }.map(\.accessibilityFrame)
        XCTAssertEqual(signals.count, 5)
        XCTAssertTrue(signals.allSatisfy { $0.maxX <= band.lowerBound }, "the signals leading")
        let typical = try XCTUnwrap(elements.first { $0.accessibilityLabel == "Typical (median of the last 30 days)" })
        XCTAssertGreaterThanOrEqual(typical.accessibilityFrame.minX, band.upperBound, "the hours trailing")
        let heading = try XCTUnwrap(elements.first { $0.accessibilityLabel == VitalsWords.trends })
        XCTAssertGreaterThanOrEqual(heading.accessibilityFrame.minX, band.upperBound)
    }

    // MARK: The fold

    func testNothingTappableOnTheFold() async throws {
        for state in DuoState.folded {
            for size: DynamicTypeSize in [.large, .accessibility3] {
                for range in [30, 1] {
                    let fixtures = try VitalsFixtures()
                    let host = try await DuoHost(fixtures.page(fixtures.dashboard(range: range)), as: state, typeSize: size)
                    defer { host.close() }
                    try await ready(host) { fixtures.days.count == 1 && (range == 1 || fixtures.trends == 1) }
                    try await DuoFoldAssertions.assertNothingTappableOnTheFold(in: host)
                    // And with the trends on screen: the range picker, the day picker and every chart.
                    try await scrollToTrends(host)
                    try await DuoFoldAssertions.assertNothingTappableOnTheFold(in: host)
                }
            }
        }
    }

    // MARK: What survives a fold

    /// The day picked, and the Day view with it, survive every fold, and no fold reads anything again (P4, P14).
    func testTheDayPickedSurvivesAFoldAndNothingIsReadAgain() async throws {
        let fixtures = try VitalsFixtures()
        let d = fixtures.dashboard(range: 1)
        let host = try await DuoHost(fixtures.page(d), as: .outer)
        defer { host.close() }
        try await ready(host) { fixtures.days.count == 1 }
        let elements = try await host.elements()
        let previous = try XCTUnwrap(elements.first { $0.accessibilityLabel == "Previous day" })
        XCTAssertTrue(previous.accessibilityActivate())
        try await ready(host) { fixtures.days.count == 2 }
        let yesterday = Day.add(fixtures.dayReply!.today, -1)
        XCTAssertEqual(fixtures.days, [nil, yesterday])
        for state: DuoState in [.innerLandscape(), .innerPortrait(), .innerLandscape(foldActive: true, bar: .leading),
                                .innerSplit(bar: .trailing), .outer] {
            try await host.set(state)
            let words = try await host.elements().compactMap(\.accessibilityLabel)
            XCTAssertTrue(words.contains("Yesterday"), "\(state): the day picked is still the day shown")
            XCTAssertTrue(words.contains("Typical (median of the last 30 days)"), "\(state): the Day view is still up")
            XCTAssertEqual(fixtures.days, [nil, yesterday], "\(state): nothing read again")
            XCTAssertEqual(fixtures.trends, 0, "\(state)")
            XCTAssertEqual(d.rangeDays, 1)
        }
    }

    func testTheRangeSurvivesAFoldAndNothingIsReadAgain() async throws {
        let fixtures = try VitalsFixtures()
        let d = fixtures.dashboard(range: 90)
        let host = try await DuoHost(fixtures.page(d), as: .outer)
        defer { host.close() }
        try await ready(host) { fixtures.trends == 1 && fixtures.tempHistory == 1 && fixtures.days.count == 1 }
        for state: DuoState in [.innerLandscape(), .innerPortrait(), .innerLandscape(bar: .leading), .innerSplit(bar: .leading), .outer] {
            try await host.set(state)
            let elements = try await host.elements()
            let ninety = try XCTUnwrap(elements.first { $0.accessibilityLabel == "90 days" }, "\(state)")
            XCTAssertTrue(ninety.accessibilityTraits.contains(.selected), "\(state): 90 days still chosen")
            XCTAssertEqual(fixtures.trends, 1, "\(state): the trends aren't read again")
            XCTAssertEqual(fixtures.tempHistory, 1, "\(state)")
            XCTAssertEqual(fixtures.days.count, 1, "\(state)")
        }
    }

    /// Scrolled down to a trend card, then opened out and folded again: the trailing pane opens on that card (the fold
    /// hands the row over by its id) and the one column comes back on it; nothing is read again.
    func testAFoldKeepsThePlace() async throws {
        let fixtures = try VitalsFixtures()
        let host = try await DuoHost(fixtures.page(fixtures.dashboard()), as: .outer)
        defer { host.close() }
        try await ready(host) { fixtures.trends == 1 }
        /// How far the HRV card's title sits below the top of the scroll view that holds it.
        func hrvBelowTop() async throws -> CGFloat {
            let elements = try await host.elements()
            let title = try XCTUnwrap(elements.first { $0.accessibilityLabel == "HRV (RMSSD)" && $0.accessibilityTraits.contains(.header) })
            let r = title.accessibilityFrame
            let scroll = try XCTUnwrap(DuoScrollTests.verticalScrollViews(in: host.window).first { s in
                let box = s.convert(s.bounds, to: nil)
                return box.minX <= r.midX && r.midX <= box.maxX
            })
            return r.minY - scroll.convert(scroll.bounds, to: nil).minY
        }
        let column = try XCTUnwrap(DuoScrollTests.verticalScrollView(in: host.window))
        DuoScrollTests.drag(column, by: try await hrvBelowTop() - 8)
        try await host.settle()
        let before = try await hrvBelowTop()
        XCTAssertLessThan(before, 80, "scrolled to the HRV card")
        for state: DuoState in [.innerLandscape(), .outer] {
            try await host.set(state)
            let now = try await hrvBelowTop()
            XCTAssertGreaterThanOrEqual(now, -1, "\(state): the HRV card's row at the top")
            XCTAssertLessThan(now, 80, "\(state): the HRV card's row at the top")
            XCTAssertEqual(fixtures.trends, 1, "\(state): nothing read again")
        }
        // Upright is the same one column as outside, kept as it is (no handoff between them): still well down the page.
        try await host.set(.innerPortrait())
        let upright = try XCTUnwrap(DuoScrollTests.verticalScrollView(in: host.window))
        XCTAssertGreaterThan(upright.contentOffset.y, 100, "upright: still scrolled down")
        XCTAssertEqual(fixtures.trends, 1, "upright: nothing read again")
    }
}
