import SwiftUI
import UIKit
import XCTest
@testable import HealthOSSync

/// iPhone Duo, what the scopes read from the system itself (§8.2, "tests that need a 27.1 destination"). They run on
/// HOS Duo (38E74BE8, iOS 27.1) under the kit's per-device lock, twice: closed, then open (`hinge.sh 38E74BE8 open`
/// first; `xcodebuild test` relaunches the host, which starts on the inner display). Each skips anywhere else: before
/// iOS 27.1 (every other simulator here), and on the display it isn't for.
///
///     lockf -k -t 900 …/uidriver/runs/.lock-38E74BE8-C7FC-4505-84F8-CA0C114D9FC0 xcodebuild test \
///       -destination id=38E74BE8-C7FC-4505-84F8-CA0C114D9FC0 -only-testing:HealthOSSyncTests/DuoReaderTests
///
/// Each records what it read as an attachment, so a failure says what the system gave (G2, G3, G5).
@MainActor
final class DuoReaderTests: XCTestCase {
    // MARK: Closed (the outer display)

    /// A page scope on the outer display reads the bar on the trailing edge, and the container margins beside it.
    func testBarEdgeOuter() async throws {
        let (probe, host) = try await DuoLive.page(display: .outer)
        defer { host.isHidden = true }
        DuoLive.record(probe, "page")
        XCTAssertEqual(probe.edges["page"], .some(.trailing))
        XCTAssertEqual(probe.margins["page"]?.trailing ?? -1, 0, accuracy: 0.5, "no margin beside the bar")
        XCTAssertNil(probe.folds["page"]?.span, "no fold while closed")
    }

    /// A sheet's own scope on the outer display: its own vertical bar, on the trailing edge (O5: Close goes there).
    func testSheetBarEdgeOuter() async throws {
        let (probe, host) = try await DuoLive.sheet(display: .outer)
        defer { host.isHidden = true }
        DuoLive.record(probe, "sheet")
        XCTAssertEqual(probe.edges["sheet"], .some(.trailing))
    }

    // MARK: Open (the inner display): testDivisionRead, testSheetBarEdgeCentred, testPanesEitherSideOfTheFold (G5,
    // design §8.2's DuoPanesArrangementTests)

    /// A page scope gets a vertical division, inactive while flat [U→G2]: the fold at about window x 466–485, so content
    /// x about 446–465 with the bar trailing, not the middle fallback's 423.5.
    func testDivisionRead() async throws {
        let (probe, host) = try await DuoLive.page(display: .inner)
        defer { host.isHidden = true }
        DuoLive.record(probe, "page")
        let fold = try XCTUnwrap(probe.folds["page"], "nothing read")
        let span = try XCTUnwrap(fold.span, "the page didn't split")
        XCTAssertGreaterThan(span.lowerBound, 430, "a division was read, not the middle fallback")
        XCTAssertLessThan(span.upperBound, 480)
        XCTAssertFalse(fold.active, "inactive while flat")
    }

    /// What a centred sheet reports on the inner display (O5, G3): no vertical edge, so the round × stays and its bar is
    /// hidden. If it reads an edge here, O5's fallback applies: the round × everywhere.
    func testSheetBarEdgeCentred() async throws {
        let (probe, host) = try await DuoLive.sheet(display: .inner)
        defer { host.isHidden = true }
        DuoLive.record(probe, "sheet")
        XCTAssertEqual(probe.edges["sheet"], .some(nil))
        XCTAssertEqual(probe.bands["sheet"], .medium, "the centred sheet's band, from its own width")
    }

    /// G5 in a unit test: DuoPanes' two panes (the system's ArrangementView) each on their own side of the fold.
    func testPanesEitherSideOfTheFold() async throws {
        try DuoLive.require(.inner)
        let probe = DuoProbe()
        let window = try DuoLive.window()
        defer { window.isHidden = true }
        // The page's own reading is taken inside its scope (a background of the panes): outside it, as a background of
        // the DuoPage, the fold is still the default .none.
        let page = DuoPage { _ in
            DuoPanes { probe.view("primary") } secondary: { probe.view("secondary") } single: { probe.view("single") }
                .background { probe.view("page") }
        }
        window.rootViewController = UIHostingController(rootView: page.environment(probe))
        window.makeKeyAndVisible()
        try await Task.sleep(for: .seconds(2))
        DuoLive.record(probe, "page")
        DuoLive.record(probe, "primary")
        DuoLive.record(probe, "secondary")
        let fold = try XCTUnwrap(probe.folds["page"]?.span, "the page didn't split")
        let page0 = try XCTUnwrap(probe.frames["page"]), margins = try XCTUnwrap(probe.margins["page"])
        let foldMinX = page0.minX + margins.leading + fold.lowerBound, foldMaxX = page0.minX + margins.leading + fold.upperBound
        let primary = try XCTUnwrap(probe.frames["primary"]), secondary = try XCTUnwrap(probe.frames["secondary"])
        XCTAssertLessThanOrEqual(primary.maxX, foldMinX, "the primary pane ends before the fold")
        XCTAssertGreaterThanOrEqual(secondary.minX, foldMaxX, "the secondary starts after it")
        XCTAssertNil(probe.frames["single"], "both panes, not the single column")
    }
}

/// Hosting on the Duo itself, with nothing injected: the scopes read the system.
@MainActor
enum DuoLive {
    enum Display { case outer, inner }

    /// Skips unless this is iOS 27.1 or later on that display (the outer 466 wide, the inner 951 or 669 wide).
    static func require(_ display: Display) throws {
        try XCTSkipUnless(ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 27, minorVersion: 1, patchVersion: 0)),
                          "iOS 27.1 (the iPhone Duo) only; it runs on HOS Duo in the next stage")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let width = scene.coordinateSpace.bounds.width
        switch display {
        case .outer: try XCTSkipUnless(abs(width - 466) < 1, "closed only: this window is \(width) wide")
        case .inner: try XCTSkipUnless(width > 600, "open only: this window is \(width) wide")
        }
    }

    static func window() throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        return window
    }

    /// A page scope in a full-screen window, its reading recorded as "page".
    static func page(display: Display) async throws -> (DuoProbe, UIWindow) {
        try require(display)
        let probe = DuoProbe()
        let window = try window()
        window.rootViewController = UIHostingController(rootView: DuoPage { _ in probe.view("page") }.environment(probe))
        window.makeKeyAndVisible()
        try await Task.sleep(for: .seconds(2))
        return (probe, window)
    }

    /// A SheetScaffold presented as the app's sheets are, its reading recorded as "sheet".
    static func sheet(display: Display) async throws -> (DuoProbe, UIWindow) {
        try require(display)
        let probe = DuoProbe()
        let window = try window()
        let root = Color.clear.sheet(isPresented: .constant(true)) {
            SheetScaffold(title: "Reader") { probe.view("sheet") }.environment(probe)
        }
        window.rootViewController = UIHostingController(rootView: root)
        window.makeKeyAndVisible()
        try await Task.sleep(for: .seconds(3))
        return (probe, window)
    }

    /// What a probe read, as an attachment on the running test.
    static func record(_ probe: DuoProbe, _ name: String) {
        let text = "frame \(probe.frames[name].map { "\($0)" } ?? "none"); band \(probe.bands[name].map { "\($0)" } ?? "none"); "
            + "fold \(probe.folds[name].map { "\($0)" } ?? "none"); margins \(probe.margins[name].map { "\($0)" } ?? "none"); "
            + "bar edge \(probe.edges[name].map { "\(String(describing: $0))" } ?? "none")"
        let attachment = XCTAttachment(string: text)
        attachment.name = "\(name) read"
        attachment.lifetime = .keepAlways
        XCTContext.runActivity(named: "\(name): \(text)") { $0.add(attachment) }
    }
}
