import SwiftUI
import UIKit
import XCTest
@testable import HealthOSSync

// Home on the iPhone Duo (duo/design.md §7 and §8.2, decisions.md Q5), drawn at the Duo's sizes with the fold put in: the
// outer display and the inner one upright keep one column (the phone's, and the web's counts at 669), and the open Duo
// in landscape has the greeting and the figure on the leading side of the fold, staying put, and every card in two
// scrolling columns on the trailing side. The data is the local demo server's made-up day (Fixtures/summary.json and
// status.json), and nothing here reaches a server: every request is answered here ("not on this server"), and Home's
// own reads are counted stand-ins. Set TEST_RUNNER_DUO_SHOTS to a folder to keep the pictures. Slice B owns this file.

/// Answers every request the page makes as a server without that route does, and counts them.
final class HomeDuoStub: URLProtocol {
    nonisolated(unsafe) static var asked: [String] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.asked.append(request.url?.path ?? "")
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"error":"Not found"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Home's reads, counted, with made-up answers.
@MainActor
final class HomeDuoReads {
    var food = 0, journal = 0, cutout = 0
    var cutoutImage: UIImage?

    var reads: HomeReads {
        HomeReads(
            readFood: { _ in self.food += 1; return nil },
            readJournal: { _ in
                self.journal += 1
                return try JSONDecoder().decode(JournalData.self, from: Data(#"{"today":"2026-10-16","entries":[]}"#.utf8))
            },
            readCutout: { _, _ in self.cutout += 1; return self.cutoutImage })
    }
}

/// The demo day as the fixtures have it, and its Home.
@MainActor
enum HomeDuoFixture {
    static func data(_ name: String) throws -> Data {
        let url = Bundle(for: HomeDuoStub.self).url(forResource: name, withExtension: "json")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name).json")
        return try Data(contentsOf: url)
    }

    static func summary() throws -> Summary { try JSONDecoder().decode(Summary.self, from: data("summary")) }

    /// The demo status, with the optional cards the web's wide Home shows turned on, and the family note not yet seen.
    static func status(perspective: String? = nil, photo: Bool = false, nutrition: Bool = false) throws -> ServerStatus {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data("status")) as? [String: Any])
        var settings = try XCTUnwrap(json["settings"] as? [String: Any])
        settings["hiddenCards"] = [String]()
        settings["shownCards"] = ["home.load", "home.activity", "home.timeline", "home.week", "home.insights"]
        settings["familySharing"] = true
        settings["familyNoticeSeen"] = false
        if let perspective { settings["perspective"] = perspective }
        if nutrition {
            settings["nutrition"] = true
            settings["nutritionNumbers"] = "all"
            settings["shownCards"] = ["home.load", "home.activity", "home.food", "home.timeline", "home.week", "home.insights"]
        }
        json["settings"] = settings
        if photo {
            json["photo"] = ["version": 7, "width": 900, "height": 1200, "face": [0.38, 0.06, 0.24, 0.24], "shoulderY": 0.36,
                             "dots": ["temp": [0.5, 0.1], "breathing": [0.5, 0.3], "heart": [0.56, 0.45]]] as [String: Any]
        }
        return try JSONDecoder().decode(ServerStatus.self, from: JSONSerialization.data(withJSONObject: json))
    }

    static func dashboard(perspective: String? = nil, photo: Bool = false, nutrition: Bool = false) throws -> Dashboard {
        let d = Dashboard()
        d.apply(status: try status(perspective: perspective, photo: photo, nutrition: nutrition))
        return d
    }

    /// Home as TodayScreen shows it: on the page's colour.
    static func page(_ dashboard: Dashboard, reads: HomeDuoReads) throws -> some View {
        TodayContent(summary: try summary())
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.page)
            .environment(dashboard)
            .environment(AppModel())
            .environment(\.homeReads, reads.reads)
    }

    /// A made-up cut-out: a grey figure-shaped block.
    static var cutout: UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 90, height: 120)).image { ctx in
            UIColor.gray.setFill()
            ctx.fill(CGRect(x: 25, y: 5, width: 40, height: 115))
        }
    }
}

@MainActor
final class HomeDuoTests: XCTestCase {
    override func setUp() async throws {
        HomeDuoStub.asked = []
        APIClient.answering(with: [HomeDuoStub.self])
    }

    override func tearDown() async throws {
        APIClient.answering(with: [])
    }

    private func page(perspective: String? = nil, photo: Bool = false, nutrition: Bool = false, reads: HomeDuoReads? = nil) throws -> some View {
        try HomeDuoFixture.page(try HomeDuoFixture.dashboard(perspective: perspective, photo: photo, nutrition: nutrition),
                                reads: reads ?? HomeDuoReads())
    }

    /// The first pictures the user asked for: the open Duo in landscape, light and dark, at the default text size.
    func testEarlyLandscape() async throws {
        for dark in [false, true] {
            try await DuoSnapshot.draw(try page(), as: .innerLandscape(), dark: dark, name: "r")
        }
    }

    // MARK: Drawn (§8.2): d-<state>-<light|dark>[-accessibility3].png, then d-2-…, d-3-… down the page

    /// Each state light and dark, at the default text size and AX3, from the top, then a screen at a time down the
    /// scroll view that holds the most (the page's, or the cards pane's), as the web's references go.
    private func drawn(_ states: [DuoState], name: String = "d", perspective: String? = nil, photo: Bool = false,
                       sizes: [DynamicTypeSize] = [.large, .accessibility3], parts: Int = 6) async throws {
        let reads = HomeDuoReads()
        reads.cutoutImage = HomeDuoFixture.cutout
        for state in states {
            for size in sizes {
                for dark in [false, true] {
                    let host = try await DuoHost(try page(perspective: perspective, photo: photo, reads: reads), as: state, dark: dark, typeSize: size)
                    defer { host.close() }
                    let first = host.image()
                    XCTAssertEqual(first.size, state.size)
                    DuoSnapshot.write(first, name: name, state: state, dark: dark, typeSize: size)
                    guard DuoSnapshot.folder != nil, let scroll = Self.tallestScroll(in: host.window) else { continue }
                    let end = scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height
                    var offset = scroll.contentOffset.y, part = 2
                    while offset < end, part <= parts {
                        offset = min(end, offset + scroll.bounds.height - 140)
                        scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: offset), animated: false)
                        try await host.settle()
                        DuoSnapshot.write(host.image(), name: "\(name)-\(part)", state: state, dark: dark, typeSize: size)
                        part += 1
                    }
                }
            }
        }
    }

    /// The vertical scroll view with the most in it (the page's, or the open Duo's cards pane).
    static func tallestScroll(in view: UIView) -> UIScrollView? {
        verticalScrolls(in: view).max { $0.contentSize.height < $1.contentSize.height }
    }

    static func verticalScrolls(in view: UIView) -> [UIScrollView] {
        var found: [UIScrollView] = []
        func walk(_ v: UIView) {
            if let s = v as? UIScrollView, !(v is UITextView), s.contentSize.height > 0, s.contentSize.width <= s.bounds.width + 0.5 { found.append(s) }
            v.subviews.forEach(walk)
        }
        walk(view)
        return found
    }

    func testOuter() async throws { try await drawn([.outer]) }
    func testInnerPortrait() async throws { try await drawn([.innerPortrait()]) }
    func testInnerLandscape() async throws { try await drawn([.innerLandscape()]) }
    func testInnerLandscapeBarLeading() async throws { try await drawn([.innerLandscape(bar: .leading)]) }
    func testInnerSplitView() async throws { try await drawn([.innerSplit(bar: .leading), .innerSplit(bar: .trailing)], parts: 1) }

    /// The fold active (the book pose): the same panes, and nothing tappable reaches the fold.
    func testInnerLandscapeActiveFold() async throws {
        try await drawn([.innerLandscape(foldActive: true)], parts: 1)
        for size: DynamicTypeSize in [.large, .accessibility3] {
            try await DuoFoldAssertions.assertNothingTappableOnTheFold(try page(), state: .innerLandscape(foldActive: true), typeSize: size)
        }
    }

    /// "Just the statistics" (no figure: Live heart rate and the tagline on the leading side) and a photo portrait.
    func testTheOtherPerspectives() async throws {
        try await drawn([.innerLandscape(), .innerPortrait(), .outer], name: "d-stats", perspective: "stats", sizes: [.large], parts: 1)
        try await drawn([.innerLandscape(), .innerPortrait()], name: "d-photo", perspective: "portrait", photo: true, sizes: [.large], parts: 1)
    }

    /// D10 and P6: nothing tappable on the fold, flat or active, the bar either side, at the default text size and AX3, in
    /// each perspective.
    func testInnerLandscapeFlatFold() async throws {
        for state in DuoState.folded {
            for size: DynamicTypeSize in [.large, .accessibility3] {
                try await DuoFoldAssertions.assertNothingTappableOnTheFold(try page(), state: state, typeSize: size)
                try await DuoFoldAssertions.assertNothingTappableOnTheFold(try page(perspective: "stats"), state: state, typeSize: size)
            }
            let reads = HomeDuoReads()
            reads.cutoutImage = HomeDuoFixture.cutout
            try await DuoFoldAssertions.assertNothingTappableOnTheFold(try page(perspective: "portrait", photo: true, reads: reads), state: state)
        }
    }

    // MARK: Where things go

    /// Every identified part VoiceOver can reach, containers too (a card's, the figure's), and its frame in the window.
    private func frames(_ host: DuoHost) async throws -> [String: CGRect] {
        try await DuoAccessibility.whileOn {
            var out: [String: CGRect] = [:], last = -1
            for _ in 0..<40 {
                try await Task.sleep(for: .milliseconds(50))
                out = [:]
                Self.collect(host.controller.view, into: &out)
                if !out.isEmpty, out.count == last { break }
                last = out.count
            }
            return out
        }
    }

    private static func collect(_ o: NSObject, into out: inout [String: CGRect]) {
        if let id = identifier(o), !id.isEmpty, out[id] == nil { out[id] = o.accessibilityFrame }
        let n = o.accessibilityElementCount()
        if n != NSNotFound, n > 0 {
            for i in 0..<n { if let e = o.accessibilityElement(at: i) as? NSObject { collect(e, into: &out) } }
        }
        for sub in (o as? UIView)?.subviews ?? [] { collect(sub, into: &out) }
    }

    /// An element's accessibility identifier, as the UI tests see it (SwiftUI's elements answer it without declaring
    /// UIAccessibilityIdentification).
    static func identifier(_ e: NSObject) -> String? {
        let get = NSSelectorFromString("accessibilityIdentifier")
        guard e.responds(to: get) else { return nil }
        return e.perform(get)?.takeUnretainedValue() as? String
    }

    /// Q5: the greeting, its controls and the figure on the leading side of the fold, fitted so that pane doesn't
    /// scroll; the signals two to a row on the trailing side; the timeline, week and insights across both its columns.
    func testTheOpenDuoHasTheFigureLeftAndTwoColumnsRight() async throws {
        for bar: HorizontalEdge in [.trailing, .leading] {
            let host = try await DuoHost(try page(), as: .innerLandscape(bar: bar))
            defer { host.close() }
            let f = try await frames(host)
            // The panes (blocks.md): 20–463 and 488–867 in window points with the bar trailing; 84–463 and 488–931 leading.
            let lead: ClosedRange<CGFloat> = bar == .trailing ? 20...463 : 84...463
            let cards: ClosedRange<CGFloat> = bar == .trailing ? 488...867 : 488...931
            for id in ["figure-digital", "editWidgets", "refresh", "previousDay", "nextDay", "demoPill", "yourMeasurements"] {
                let r = try XCTUnwrap(f[id], "\(id) with the bar \(bar)")
                XCTAssert(r.minX >= lead.lowerBound - 0.5 && r.maxX <= lead.upperBound + 0.5, "\(id) \(r) in the leading pane, bar \(bar)")
            }
            let figure = try XCTUnwrap(f["figure-digital"])
            XCTAssertLessThanOrEqual(figure.width, HomeFigure.maxWidth + 0.5)
            XCTAssertLessThanOrEqual(try XCTUnwrap(f["yourMeasurements"]).maxY, 669 - 34 + 0.5, "the leading pane fits, so it stays put")
            let rhr = try XCTUnwrap(f["card-home.rhr"]), spo2 = try XCTUnwrap(f["card-home.spo2"]), hrv = try XCTUnwrap(f["card-home.hrv"])
            XCTAssertEqual(rhr.minY, spo2.minY, accuracy: 0.5, "two to a row")
            XCTAssertGreaterThan(hrv.minY, rhr.maxY)
            XCTAssertEqual(rhr.height, spo2.height, accuracy: 0.5, "a row's cards are as tall as each other")
            XCTAssert(rhr.minX >= cards.lowerBound - 0.5 && spo2.maxX <= cards.upperBound + 0.5, "\(rhr) \(spo2) in the cards pane")
            let timeline = try XCTUnwrap(f["card-home.timeline"])
            XCTAssertEqual(timeline.minX, rhr.minX, accuracy: 0.5)
            XCTAssertEqual(timeline.maxX, spo2.maxX, accuracy: 0.5, "the timeline spans both columns")
            let scrolls = Self.verticalScrolls(in: host.window)
            XCTAssertEqual(scrolls.count, 2, "two panes")
            let leadScroll = try XCTUnwrap(scrolls.min { $0.frame.minX < $1.frame.minX })
            XCTAssertLessThanOrEqual(leadScroll.contentSize.height, leadScroll.bounds.height + 0.5, "the figure's pane doesn't scroll")
        }
    }

    /// The outer display is the phone's layout: the greeting 16pt down, one card to a row; upright on the inner display,
    /// the web at 669: the figure at most 420 and centred, the signals two to a row, Nutrition and Journal stacked.
    func testOuterIsThePhonesAndUprightIsTheWebsAt669() async throws {
        let outer = try await DuoHost(try page(), as: .outer)
        let o = try await frames(outer)
        outer.close()
        XCTAssertEqual(Self.verticalScrolls(in: outer.window).count, 1, "one column")
        let rhr = try XCTUnwrap(o["card-home.rhr"]), spo2 = try XCTUnwrap(o["card-home.spo2"])
        XCTAssertGreaterThan(spo2.minY, rhr.maxY, "one to a row")
        XCTAssertEqual(rhr.minX, 20, accuracy: 0.5, "the container's margin beside the screen's edge")
        XCTAssertEqual(rhr.maxX, 466 - 84, accuracy: 0.5, "and none beside the bar")

        let upright = try await DuoHost(try page(), as: .innerPortrait())
        defer { upright.close() }
        let u = try await frames(upright)
        let figure = try XCTUnwrap(u["figure-digital"])
        XCTAssertEqual(figure.width, HomeFigure.maxWidth, accuracy: 0.5)
        XCTAssertEqual(figure.midX, 669 / 2, accuracy: 1, "centred")
        let r = try XCTUnwrap(u["card-home.rhr"]), s = try XCTUnwrap(u["card-home.spo2"])
        XCTAssertEqual(r.minY, s.minY, accuracy: 0.5, "signals two to a row")
        let nutrition = try XCTUnwrap(u["card-home.nutrition"]), journal = try XCTUnwrap(u["card-journal"] ?? u["card-home.journal"])
        XCTAssertGreaterThan(journal.minY, nutrition.maxY - 0.5, "Nutrition and Journal stacked")
        XCTAssertEqual(nutrition.width, 669 - 32, accuracy: 0.5)
    }

    // MARK: Across a fold (P4, P14)

    /// Edit widgets stays open when a fold swaps Home's column for the panes and back: its state is on the page.
    func testStateSurvivesBandChange() async throws {
        let host = try await DuoHost(try page(), as: .outer)
        defer { host.close() }
        let elements = try await host.elements()
        let edit = try XCTUnwrap(elements.first { Self.identifier($0) == "editWidgets" })
        XCTAssertTrue(edit.accessibilityActivate())
        try await host.settle()
        XCTAssertNotNil(host.controller.presentedViewController, "Edit widgets is up")
        let sheet = host.controller.presentedViewController
        for state: DuoState in [.innerLandscape(), .innerPortrait(), .innerLandscape(bar: .leading), .outer] {
            try await host.set(state)
            XCTAssertTrue(host.controller.presentedViewController === sheet, "Edit widgets still up in \(state)")
        }
    }

    /// A fold reads nothing again: not the food totals, the journal, the photo's cut-out or the food log.
    func testBandChangeDoesNotReload() async throws {
        for (perspective, photo) in [(nil, false), ("portrait", true)] as [(String?, Bool)] {
            let reads = HomeDuoReads()
            reads.cutoutImage = HomeDuoFixture.cutout
            HomeDuoStub.asked = []
            let host = try await DuoHost(try page(perspective: perspective, photo: photo, nutrition: true, reads: reads), as: .outer)
            defer { host.close() }
            try await host.settle()
            let before = (reads.food, reads.journal, reads.cutout, HomeDuoStub.asked.count)
            XCTAssertEqual(before.0, 1, "food totals read once")
            XCTAssertEqual(before.1, 1, "the journal read once")
            XCTAssertEqual(before.2, photo ? 1 : 0, "the cut-out read once")
            for state: DuoState in [.innerLandscape(), .innerPortrait(), .innerLandscape(bar: .leading), .outer] {
                try await host.set(state)
                try await host.settle()
                XCTAssertEqual(reads.food, before.0, "\(state)")
                XCTAssertEqual(reads.journal, before.1, "\(state)")
                XCTAssertEqual(reads.cutout, before.2, "\(state)")
                XCTAssertEqual(HomeDuoStub.asked.count, before.3, "nothing asked of the server again in \(state): \(HomeDuoStub.asked)")
            }
        }
    }
}

/// Home's rows, without drawing.
final class HomeRowsTests: XCTestCase {
    func testTheColumnIsHomeTsxsOrderSpacedAsTheWebsPhone() {
        var s = HomeRows.Shown(banners: true, week: true, insights: true)
        XCTAssertEqual(HomeRows.single(s).map(\.id), ["home.header", "home.banners", "home.figure", "home.tagline", "home.signals", "home.lower",
                                                     "home.week", "home.insights", "home.footer"])
        XCTAssertEqual(HomeRows.single(s).map(\.top), [0, 18, 16, 14, 18, 14, 14, 14, 0])
        s.banners = false
        s.stats = true
        XCTAssertEqual(HomeRows.single(s).map(\.id), ["home.header", "home.live", "home.signals", "home.lower", "home.week", "home.insights",
                                                     "home.statsTagline", "home.footer"])
        XCTAssertEqual(HomeRows.single(s).map(\.top), [0, 18, 18, 14, 14, 14, 14, 0])
        // Every card hidden: the note says so, 18 below the figure's tagline.
        let none = HomeRows.Shown(signals: false, lower: false, allHidden: true)
        XCTAssertEqual(HomeRows.single(none).map(\.id), ["home.header", "home.figure", "home.tagline", "home.allHidden", "home.footer"])
        XCTAssertEqual(HomeRows.single(none)[3].top, 18)
    }

    /// The cards pane has the column's cards under the same ids, so a fold keeps the row at the top; the header, the
    /// figure and the taglines are the leading pane's.
    func testTheCardsPaneSharesTheColumnsIds() {
        let s = HomeRows.Shown(banners: true, stats: true, day: true, cycle: true, optional: true, timeline: true, week: true, insights: true)
        let cards = HomeRows.cards(s).map(\.id)
        XCTAssertEqual(cards, ["home.banners", "home.signals", "home.lower", "home.day", "home.cycle", "home.optional", "home.timeline",
                               "home.week", "home.insights", "home.footer"])
        XCTAssertEqual(HomeRows.cards(s).map(\.top), [0, 16, 14, 14, 14, 14, 14, 14, 14, 0])
        let single = HomeRows.single(s).map(\.id)
        XCTAssertEqual(Set(cards).subtracting(single), [], "every pane row is a column row")
        XCTAssertEqual(Set(single).subtracting(cards), ["home.header", "home.live", "home.statsTagline"])
        XCTAssertEqual(HomeRows.cards(HomeRows.Shown())[0], HomeRows.Row(id: "home.signals", top: 0))
    }

    func testAnEmptyCardIsNoTallerThanThePromaxs() {
        XCTAssertEqual(SignalCard.minHeight(.home, empty: true, width: 370), 370 / 1.55, accuracy: 0.01, "the 18 Pro's, as before")
        XCTAssertEqual(SignalCard.minHeight(.home, empty: true, width: 408), 408 / 1.55, accuracy: 0.01, "the Pro Max's, as before")
        XCTAssertEqual(SignalCard.minHeight(.home, empty: true, width: 637), 408 / 1.55, accuracy: 0.01, "capped on the Duo upright")
        XCTAssertEqual(SignalCard.minHeight(.home, empty: true, width: 182), 210, "its floor")
        XCTAssertEqual(SignalCard.minHeight(.home, empty: false, width: 637), 236)
    }
}
