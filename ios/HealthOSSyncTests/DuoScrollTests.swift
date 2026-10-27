import SwiftUI
import UIKit
import XCTest
@testable import HealthOSSync

/// iPhone Duo (§4): a DuoPanes page keeps its place across a fold. Going between one column and two panes rebuilds the
/// scroll view, so DuoPanes hands the top row (by id) from the one going to the one coming: the single column's and
/// the anchored pane's. A row only in the other pane leaves it at its top. The row is DuoPanes' own state, so a new page
/// (opened again, another day or person, a reset, a sign-out) starts at its top; nothing is kept anywhere else.
@MainActor
final class DuoScrollTests: XCTestCase {
    private func rows(_ prefix: String, _ probe: DuoProbe, count: Int = 40) -> some View {
        VStack(spacing: 0) {
            // The rows' ids are Strings, as a page's are: a ForEach's own ids are what the scroll position reads.
            ForEach((1...count).map { "\(prefix)\($0)" }, id: \.self) { id in
                probe.view(id).frame(height: 60)
            }
        }
        .scrollTargetLayout()
    }

    /// The top of the page's scroll view, in window points (the Duo's outer display has no top inset).
    private let top: CGFloat = 0

    /// A page whose scrolling content is its secondary pane (Home's cards beside its figure): the single column's row is
    /// handed to that pane on unfolding, and the pane's back to the single column on folding.
    func testAFoldHandsTheRowBetweenTheColumnAndThePane() async throws {
        let probe = DuoProbe()
        let page = DuoPage { _ in
            DuoPanes(anchor: .secondary) {
                self.rows("p", probe)
            } secondary: {
                self.rows("s", probe)
            } single: {
                self.rows("s", probe)
            }
        }
        let host = try await DuoHost(page.environment(probe), as: .outer)
        defer { host.close() }
        XCTAssertEqual(try XCTUnwrap(probe.frames["s1"]).minY, top, accuracy: 1, "a new page opens at its top")
        // Scrolled by hand in one column (a drag, as the scroll view's delegate sees one): 900 pt is 15 rows of 60.
        Self.drag(try XCTUnwrap(Self.verticalScrollView(in: host.window)), by: 900)
        try await host.settle()
        XCTAssertEqual(try XCTUnwrap(probe.frames["s16"]).minY, top, accuracy: 1)
        // Unfolded: the cards' pane opens on the same row, and the figure's pane at its top.
        try await host.set(.innerLandscape())
        XCTAssertEqual(try XCTUnwrap(probe.frames["s16"]).minY, top, accuracy: 1, "the secondary pane on the kept row")
        XCTAssertEqual(try XCTUnwrap(probe.frames["p1"]).minY, top, accuracy: 1, "the primary at its top")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(probe.frames["s16"]).minX, 475.5 + DuoFold.clearance, "on the trailing side")
        // Scrolled further in the pane, then folded: the single column comes back on the pane's row.
        let pane = try XCTUnwrap(Self.verticalScrollViews(in: host.window).first { $0.convert($0.bounds, to: nil).minX > 400 })
        Self.drag(pane, by: 300)
        try await host.settle()
        XCTAssertEqual(try XCTUnwrap(probe.frames["s21"]).minY, top, accuracy: 1)
        try await host.set(.outer)
        XCTAssertEqual(try XCTUnwrap(probe.frames["s21"]).minY, top, accuracy: 1, "one column, on the pane's row")
    }

    /// The anchored pane (the primary unless said) has no such row: it stays at its top, and the other pane isn't moved.
    func testARowOnlyInTheOtherPaneLeavesItAtTheTop() async throws {
        let probe = DuoProbe()
        let page = DuoPage { _ in
            DuoPanes {
                self.rows("p", probe)
            } secondary: {
                self.rows("s", probe)
            } single: {
                VStack(spacing: 0) {
                    ForEach((1...5).map { "p\($0)" }, id: \.self) { id in probe.view(id).frame(height: 60) }
                    ForEach((1...40).map { "s\($0)" }, id: \.self) { id in probe.view(id).frame(height: 60) }
                }
                .scrollTargetLayout()
            }
        }
        let host = try await DuoHost(page.environment(probe), as: .outer)
        defer { host.close() }
        Self.drag(try XCTUnwrap(Self.verticalScrollView(in: host.window)), by: 1200)
        try await host.settle()
        XCTAssertEqual(try XCTUnwrap(probe.frames["s16"]).minY, top, accuracy: 1, "20 rows down: s16")
        try await host.set(.innerLandscape())
        XCTAssertEqual(try XCTUnwrap(probe.frames["p1"]).minY, top, accuracy: 1, "the primary has no s16: its top")
        XCTAssertEqual(try XCTUnwrap(probe.frames["s1"]).minY, top, accuracy: 1, "the secondary keeps no row")
        XCTAssertLessThanOrEqual(try XCTUnwrap(probe.frames["p1"]).maxX, 475.5 - DuoFold.clearance, "the primary pane on the leading side")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(probe.frames["s1"]).minX, 475.5 + DuoFold.clearance, "the secondary on the trailing side")
        // Folded again, untouched in between: the one column comes back on its own row.
        try await host.set(.outer)
        XCTAssertEqual(try XCTUnwrap(probe.frames["s16"]).minY, top, accuracy: 1)
    }

    /// The review's repro: a page scrolled down, then a new one of the same kind (pushed again, another date or person,
    /// a tab reset to its root): the new one opens at its top. Here the new page is the same view with a new identity.
    func testANewPageOpensAtItsTop() async throws {
        let probe = DuoProbe()
        let generation = Generation()
        let pages = Regenerated(generation: generation) {
            DuoPage { _ in
                DuoPanes(anchor: .secondary) { self.rows("p", probe) } secondary: { self.rows("s", probe) } single: { self.rows("s", probe) }
            }
        }
        let host = try await DuoHost(pages.environment(probe), as: .outer)
        defer { host.close() }
        Self.drag(try XCTUnwrap(Self.verticalScrollView(in: host.window)), by: 900)
        try await host.settle()
        XCTAssertEqual(try XCTUnwrap(probe.frames["s16"]).minY, top, accuracy: 1)
        generation.value += 1
        try await host.settle()
        XCTAssertEqual(try XCTUnwrap(probe.frames["s1"]).minY, top, accuracy: 1, "the new page at its top")
        try await host.set(.innerLandscape())
        XCTAssertEqual(try XCTUnwrap(probe.frames["s1"]).minY, top, accuracy: 1, "and unfolded, still at its top")
        // A plain page too: nothing carries over to a new scroll view.
        let plainProbe = DuoProbe()
        let plain = Regenerated(generation: generation) { DuoPage { _ in DuoScroll { self.rows("r", plainProbe) } } }
        let plainHost = try await DuoHost(plain.environment(plainProbe), as: .outer)
        defer { plainHost.close() }
        Self.drag(try XCTUnwrap(Self.verticalScrollView(in: plainHost.window)), by: 600)
        try await plainHost.settle()
        generation.value += 1
        try await plainHost.settle()
        XCTAssertEqual(try XCTUnwrap(plainProbe.frames["r1"]).minY, top, accuracy: 1)
    }

    /// The row is handed only between the page's own scroll views, never to or from one nested inside them.
    func testTheHandoffDoesNotReachANestedScrollView() async throws {
        let probe = DuoProbe()
        let column = VStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(spacing: 0) { ForEach((1...20).map { "h\($0)" }, id: \.self) { id in probe.view(id).frame(width: 100, height: 40) } }
                    .scrollTargetLayout()
            }
            .frame(height: 40)
            // Static rows with .id(_:), as Home's are, then a ForEach of String ids.
            probe.view("r1").frame(height: 60).id("r1")
            probe.view("r2").frame(height: 60).id("r2")
            ForEach((3...30).map { "r\($0)" }, id: \.self) { id in probe.view(id).frame(height: 60) }
        }
        .scrollTargetLayout()
        let page = DuoPage { _ in DuoPanes(anchor: .secondary) { probe.view("figure") } secondary: { column } single: { column } }
        let host = try await DuoHost(page.environment(probe), as: .outer)
        defer { host.close() }
        Self.drag(try XCTUnwrap(Self.verticalScrollView(in: host.window)), by: 40 + 60 * 9)
        try await host.settle()
        XCTAssertEqual(try XCTUnwrap(probe.frames["r10"]).minY, top, accuracy: 1)
        try await host.set(.innerLandscape())
        XCTAssertEqual(try XCTUnwrap(probe.frames["r10"]).minY, top, accuracy: 1, "the pane on the column's row")
        XCTAssertEqual(try XCTUnwrap(probe.frames["h1"]).minX, 488, accuracy: 1, "the nested row isn't scrolled")
    }

    /// A finger's drag of `distance` points, as the scroll view's delegate hears it (SwiftUI updates the position when a
    /// drag ends, not for a programmatic offset alone).
    static func drag(_ scroll: UIScrollView, by distance: CGFloat) {
        scroll.delegate?.scrollViewWillBeginDragging?(scroll)
        scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: scroll.contentOffset.y + distance), animated: false)
        scroll.delegate?.scrollViewDidScroll?(scroll)
        var target = scroll.contentOffset
        scroll.delegate?.scrollViewWillEndDragging?(scroll, withVelocity: .zero, targetContentOffset: &target)
        scroll.delegate?.scrollViewDidEndDragging?(scroll, willDecelerate: false)
    }

    static func verticalScrollView(in view: UIView) -> UIScrollView? {
        verticalScrollViews(in: view).first
    }

    /// Every scroll view that scrolls vertically (content taller than its frame), in the order they're found.
    static func verticalScrollViews(in view: UIView) -> [UIScrollView] {
        var out: [UIScrollView] = []
        if let scroll = view as? UIScrollView, !(view is UITextView), scroll.contentSize.height > scroll.bounds.height { out.append(scroll) }
        for sub in view.subviews { out += verticalScrollViews(in: sub) }
        return out
    }
}

/// A view given a new identity whenever `generation` changes: what a page pushed again or a tab reset gives.
@MainActor @Observable
private final class Generation {
    var value = 0
}

private struct Regenerated<Content: View>: View {
    let generation: Generation
    @ViewBuilder let content: () -> Content

    var body: some View {
        content().id(generation.value)
    }
}
