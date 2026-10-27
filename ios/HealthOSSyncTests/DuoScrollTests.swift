import SwiftUI
import UIKit
import XCTest
@testable import HealthOSSync

/// iPhone Duo (§4): a page's place is kept in `Dashboard.scrollAnchors` by the id of its top row, so a fold that
/// rebuilds its scroll view comes back to the same row; on a DuoPanes page the primary pane keeps it, and an anchor only
/// in the other pane falls back to the top.
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

    func testAnAnchorRoundTripsThroughTheDashboard() async throws {
        let dashboard = Dashboard(tokenStore: MemoryTokenStore())
        dashboard.scrollAnchors[.insights] = "r20"
        let probe = DuoProbe()
        let page = DuoPage { _ in DuoScroll { self.rows("r", probe) }.duoScrollAnchor(.insights) }
        let host = try await DuoHost(page.environment(probe).environment(dashboard), as: .outer)
        XCTAssertEqual(try XCTUnwrap(probe.frames["r20"]).minY, top, accuracy: 1, "opened on the kept row")

        // Scrolled by hand (a drag, as the scroll view's delegate sees one): the dashboard follows.
        let scroll = try XCTUnwrap(Self.verticalScrollView(in: host.window))
        Self.drag(scroll, by: 300)
        try await host.settle()
        XCTAssertEqual(dashboard.scrollAnchors[.insights], "r25", "five rows of 60 further")
        host.close()

        // A new scroll view (what a pane swap or a rebuild gives) comes back to it.
        let again = DuoProbe()
        let rebuilt = DuoPage { _ in DuoScroll { self.rows("r", again) }.duoScrollAnchor(.insights) }
        let second = try await DuoHost(rebuilt.environment(again).environment(dashboard), as: .innerLandscape())
        defer { second.close() }
        XCTAssertEqual(try XCTUnwrap(again.frames["r25"]).minY, top, accuracy: 1)
        XCTAssertNil(dashboard.scrollAnchors[.home], "only the page's own anchor")
    }

    func testAPaneOnlyAnchorFallsBackToTheTop() async throws {
        let dashboard = Dashboard(tokenStore: MemoryTokenStore())
        dashboard.scrollAnchors[.labs] = "s20"
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
            .duoScrollAnchor(.labs)
        }
        // Split: the anchor is only in the secondary pane, so the primary stays at its top and the secondary isn't moved.
        let host = try await DuoHost(page.environment(probe).environment(dashboard), as: .innerLandscape())
        defer { host.close() }
        XCTAssertEqual(try XCTUnwrap(probe.frames["p1"]).minY, top, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(probe.frames["s1"]).minY, top, accuracy: 1)
        XCTAssertLessThanOrEqual(try XCTUnwrap(probe.frames["p1"]).maxX, 475.5 - DuoFold.clearance, "the primary pane on the leading side")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(probe.frames["s1"]).minX, 475.5 + DuoFold.clearance, "the secondary on the trailing side")
        // One column: the same anchor is there, so it opens on it.
        try await host.set(.outer)
        XCTAssertEqual(try XCTUnwrap(probe.frames["s20"]).minY, top, accuracy: 1)
    }

    /// A page whose scrolling content is its secondary pane (Home's cards beside its figure) keeps the anchor there.
    func testTheSecondaryPaneCanKeepTheAnchor() async throws {
        let dashboard = Dashboard(tokenStore: MemoryTokenStore())
        dashboard.scrollAnchors[.home] = "s20"
        let probe = DuoProbe()
        let page = DuoPage { _ in
            DuoPanes(anchor: .secondary) {
                self.rows("p", probe)
            } secondary: {
                self.rows("s", probe)
            } single: {
                self.rows("s", probe)
            }
            .duoScrollAnchor(.home)
        }
        let host = try await DuoHost(page.environment(probe).environment(dashboard), as: .innerLandscape())
        defer { host.close() }
        XCTAssertEqual(try XCTUnwrap(probe.frames["s20"]).minY, top, accuracy: 1, "the secondary pane opens on the kept row")
        XCTAssertEqual(try XCTUnwrap(probe.frames["p1"]).minY, top, accuracy: 1, "the primary at its top")
    }

    /// The anchor binds only the page's own scroll view, never a scroll view nested inside it.
    func testTheAnchorDoesNotReachANestedScrollView() async throws {
        let dashboard = Dashboard(tokenStore: MemoryTokenStore())
        dashboard.scrollAnchors[.sleep] = "r10"
        let probe = DuoProbe()
        let page = DuoPage { _ in
            DuoScroll {
                VStack(spacing: 0) {
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
            }
            .duoScrollAnchor(.sleep)
        }
        let host = try await DuoHost(page.environment(probe).environment(dashboard), as: .outer)
        defer { host.close() }
        XCTAssertEqual(try XCTUnwrap(probe.frames["r10"]).minY, top, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(probe.frames["h1"]).minX, 20, accuracy: 1, "the nested row isn't scrolled")
        XCTAssertEqual(dashboard.scrollAnchors[.sleep], "r10", "and doesn't write its own row into the page's anchor")
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
        if let scroll = view as? UIScrollView, !(view is UITextView), scroll.contentSize.height > scroll.bounds.height { return scroll }
        for sub in view.subviews { if let found = verticalScrollView(in: sub) { return found } }
        return nil
    }
}
