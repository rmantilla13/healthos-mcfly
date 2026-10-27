import SwiftUI
import UIKit
import XCTest
@testable import HealthOSSync

/// The metric sheet on iPhone Duo (duo/design.md §7's metric sheet row, §2.7 and §2.8; P1–P14), drawn at the Duo's
/// sizes with the fold put in (DuoSnapshot), from the local demo server's answers (Fixtures/metric-*.json).
///
/// The sheet is drawn where the system puts it. At compact width (the outer display, Split View) it's the full sheet,
/// drawn as the kit draws a page. At regular width (the inner display, upright and open in landscape) the system centres
/// it on the window: 653 by 661, measured open in landscape (x 149–802, so the fold runs down its middle while the device
/// lies flat); upright it's assumed the same, which no run has measured yet. Its content is capped at SheetScaffold's
/// default `.md` (650), its band is medium, its charts are 1.3 times taller (duoChartHeight) and its long tables scroll
/// in the smaller of 360 points and 45% of its height. Whatever can be tapped keeps to one side of its middle
/// (SheetMiddle), so nothing tappable meets the fold the system lays it across.
///
/// PNGs are written when TEST_RUNNER_DUO_SHOTS names a folder: `d-*` for the measured month (as the web's references
/// show), `d-table-*` with its table open, `d-never-*` for a metric never measured, and `d-2-*` scrolled one screen
/// down, as the web's `-2` references are.
@MainActor
final class MetricSheetDuoTests: XCTestCase {
    private func fixture(_ name: String) throws -> MetricSheetData {
        try JSONDecoder().decode(MetricSheetData.self, from: try fixtureData(name))
    }

    private func fixtureData(_ name: String) throws -> Data {
        let url = Bundle(for: Self.self).url(forResource: name, withExtension: "json")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name).json")
        return try Data(contentsOf: url)
    }

    /// The sheet as the shell shows it, its scaffold around one state of its content, where the system presents it.
    private func sheet(_ key: MetricKey, section: String = "Your signals", data: MetricSheetData?, openPage: String? = "Vitals",
                       loading: Bool = false, error: String? = nil, table: Bool = false) -> some View {
        Presented(sheet: SheetScaffold(eyebrow: section, title: key.info.label, onClose: {}) {
            MetricSheetContent(key: key, range: data?.range ?? key.info.initial, sheet: data, picked: false, note: nil, loading: loading,
                               error: error, openPage: openPage)
        }
        .environment(\.sheetChartOpensOnTable, table))
    }

    private var month: some View { get throws { sheet(.hrv, data: try fixture("metric-hrv-month")) } }

    private var never: some View { get throws { sheet(.glucose, section: "Body", data: try fixture("metric-glucose-never"), openPage: "Body") } }

    /// Every content state the fold check goes through: a line, its table, bars, the day's table, never measured, and
    /// a failure.
    private func everyState() throws -> [(String, AnyView)] {
        [
            ("month", AnyView(try month)),
            ("month table", AnyView(sheet(.hrv, data: try fixture("metric-hrv-month"), table: true))),
            ("week of bars", AnyView(sheet(.steps, data: try fixture("metric-steps-week"), openPage: "Activity"))),
            ("day table", AnyView(sheet(.heartRate, section: "Body", data: try fixture("metric-heart-rate-day"), table: true))),
            ("never measured", AnyView(try never)),
            ("failed", AnyView(sheet(.restingHr, data: nil, error: "Something went wrong"))),
        ]
    }

    // MARK: - Drawn in the Duo's states

    /// Light and dark, at the default text size and AX3.
    private func drawFour(_ view: some View, as state: DuoState, name: String) async throws {
        for size: DynamicTypeSize in [.large, .accessibility3] {
            for dark in [false, true] { try await DuoSnapshot.draw(view, as: state, dark: dark, typeSize: size, name: name) }
        }
    }

    func testOuter() async throws {
        try await drawFour(try month, as: .outer, name: "d")
    }

    func testInnerPortrait() async throws {
        try await drawFour(try month, as: .innerPortrait(), name: "d")
    }

    func testInnerLandscape() async throws {
        try await drawFour(try month, as: .innerLandscape(), name: "d")
    }

    func testInnerLandscapeBarLeading() async throws {
        try await drawFour(try month, as: .innerLandscape(bar: .leading), name: "d")
    }

    func testInnerLandscapeActiveFold() async throws {
        try await drawFour(try month, as: .innerLandscape(foldActive: true), name: "d")
    }

    func testInnerSplitView() async throws {
        try await drawFour(try month, as: .innerSplit(bar: .leading), name: "d")
        try await drawFour(try month, as: .innerSplit(bar: .trailing), name: "d")
    }

    /// The table open, and a metric never measured, on each display; and the measured month one screen down, as the
    /// web's `-2` references are, to compare the figures, the sentence and "What this means".
    func testTheTableNeverMeasuredAndScrolled() async throws {
        let table = sheet(.hrv, data: try fixture("metric-hrv-month"), table: true)
        for state: DuoState in [.outer, .innerPortrait(), .innerLandscape()] {
            for dark in [false, true] {
                try await DuoSnapshot.draw(table, as: state, dark: dark, name: "d-table")
                try await DuoSnapshot.draw(try never, as: state, dark: dark, name: "d-never")
                try await drawScrolled(try month, as: state, dark: dark, name: "d-2")
            }
        }
        try await DuoSnapshot.draw(try never, as: .innerLandscape(), typeSize: .accessibility3, name: "d-never")
    }

    /// The sheet scrolled down by its height less 120 points (the web's references overlap 120 inside a sheet).
    private func drawScrolled(_ view: some View, as state: DuoState, dark: Bool, name: String) async throws {
        let host = try await DuoHost(view, as: state, dark: dark)
        defer { host.close() }
        let scroll = try XCTUnwrap(DuoScrollTests.verticalScrollViews(in: host.window).max { $0.bounds.height < $1.bounds.height }, "the sheet scrolls")
        let down = min(scroll.bounds.height - 120, scroll.contentSize.height - scroll.bounds.height)
        scroll.setContentOffset(CGPoint(x: 0, y: down), animated: false)
        try await host.settle()
        DuoSnapshot.write(host.image(), name: name, state: state, dark: dark)
    }

    // MARK: - Nothing tappable on the fold

    /// Flat and active, with the bar trailing and leading, at the default text size and AX3, in every content state: the
    /// range buttons, "Manage connections", the source's link and "Open Vitals" keep to the leading side of the sheet's
    /// middle, and the chart and table switch and Close to the trailing side.
    func testNothingTappableOnTheFold() async throws {
        for (name, view) in try everyState() {
            for state in DuoState.folded {
                for size: DynamicTypeSize in [.large, .accessibility3] {
                    let host = try await DuoHost(view, as: state, typeSize: size)
                    defer { host.close() }
                    let found = try await DuoFoldAssertions.offenders(in: host)
                    XCTAssert(found.isEmpty, "\(name), \(state) at \(size): \(found.joined(separator: "; "))")
                }
            }
        }
    }

    /// The check isn't empty: the sheet's buttons are reached, and the sheet does lie across the fold, centred on it.
    func testTheCentredSheetLiesAcrossTheFold() async throws {
        let host = try await DuoHost(try month, as: .innerLandscape())
        defer { host.close() }
        let band = try XCTUnwrap(DuoFoldAssertions.band(.innerLandscape()))
        let elements = try await host.elements()
        let labels = elements.compactMap(\.accessibilityLabel)
        for label in ["Week", "Month", "Year", "Chart", "Table", "Close", "Open Vitals"] {
            XCTAssert(labels.contains { $0.hasPrefix(label) }, "\(label) is reached: \(labels)")
        }
        let sheet = try XCTUnwrap(DuoScrollTests.verticalScrollViews(in: host.window).max { $0.bounds.height < $1.bounds.height })
        let frame = sheet.convert(sheet.bounds, to: host.window)
        XCTAssertEqual(frame.midX, (band.lowerBound + band.upperBound) / 2, accuracy: 0.5, "centred on the fold")
        XCTAssertEqual(frame.width, Presented<EmptyView>.centred.width, accuracy: 0.5)
    }

    // MARK: - Sizes

    /// One side of the middle in the centred sheet (its column 614: half less 12, less a point), no limit in every compact one.
    func testTheSidesOfTheSheetsMiddle() {
        XCTAssertEqual(SheetMiddle.sideWidth(column: 614), 294)
        XCTAssertEqual(SheetMiddle.sideWidth(column: 653 - 2 * 18), 295)
        XCTAssertNil(SheetMiddle.sideWidth(column: nil), "outside a sheet")
        XCTAssertNil(SheetMiddle.sideWidth(column: 366), "an iPhone 18 Pro's sheet")
        XCTAssertNil(SheetMiddle.sideWidth(column: 404), "an iPhone Pro Max's")
        XCTAssertNil(SheetMiddle.sideWidth(column: 382 - 2 * 18), "the outer display's")
        XCTAssertNil(SheetMiddle.sideWidth(column: 528))
    }

    /// 9 rows whole in 360 points, as always; 7 in the centred sheet's 297.
    func testATableShowsFewerRowsWholeInAShorterWindow() {
        XCTAssertEqual(SheetTableView.rowsShownWhole(in: 360), 9)
        XCTAssertEqual(SheetTableView.rowsShownWhole(in: 297), 7)
        XCTAssertEqual(DuoBand.medium.tableWindow(scopeHeight: Presented<EmptyView>.centred.height), 297)
    }

    /// The charts and the table window follow the sheet: the line 200 points tall and the bars 220, and a 360 window, on
    /// the outer display and in Split View; 60 and 66 points taller (1.3 times) and a 297 window in the centred sheet;
    /// and back to the outer display's at AX3, where the centred sheet's band drops to compact (its table rows stack
    /// there, with no window). The chart's element also holds its axes, so its height is compared with the outer
    /// display's at the same text size. The line, whose element's frame is its marks' since it takes the scroll-friendly
    /// pick, is measured on its own in each band: 200 tall and its 20-point top margin, 1.3 times that in medium.
    func testTheChartsAndTheTableWindowFollowTheSheet() async throws {
        let cases: [(DuoState, DynamicTypeSize, CGFloat, CGFloat?)] = [
            (.outer, .large, 1, 360), (.innerSplit(bar: .trailing), .large, 1, 360),
            (.innerPortrait(), .large, 1.3, 297), (.innerLandscape(), .large, 1.3, 297), (.innerLandscape(bar: .leading), .large, 1.3, 297),
            (.outer, .accessibility3, 1, nil), (.innerLandscape(), .accessibility3, 1, nil),
        ]
        let bars = sheet(.steps, data: try fixture("metric-steps-week"), openPage: "Activity")
        let table = sheet(.hrv, data: try fixture("metric-hrv-month"), table: true)
        let month = try fixture("metric-hrv-month")
        for (band, height) in [(DuoBand.compact, CGFloat(220)), (.medium, 280), (.wide, 280)] {
            let chart = SheetTrendChart(points: month.points, format: SheetFormat(month), color: Palette.series1, label: "HRV", gapDays: 3, period: nil)
                .environment(\.duoBand, band)
            XCTAssertEqual(UIHostingController(rootView: chart).sizeThatFits(in: CGSize(width: 614, height: 2000)).height, height, accuracy: 0.5, "\(band)")
        }
        var outer: [DynamicTypeSize: CGFloat] = [:]
        for size: DynamicTypeSize in [.large, .accessibility3] {
            outer[size] = try await chartHeight(bars, as: .outer, typeSize: size, label: "Steps, week")
        }
        for (state, size, scale, window) in cases {
            let base = try XCTUnwrap(outer[size])
            let drawnBars = try await chartHeight(bars, as: state, typeSize: size, label: "Steps, week")
            XCTAssertEqual(drawnBars - base, 220 * (scale - 1), accuracy: 0.5, "bars, \(state) at \(size)")
            let host = try await DuoHost(table, as: state, typeSize: size)
            defer { host.close() }
            let inner = DuoScrollTests.verticalScrollViews(in: host.window).filter { $0.bounds.height <= 361 }
            if let window {
                XCTAssertEqual(inner.count, 1, "the table's window, \(state)")
                XCTAssertEqual(inner.first?.bounds.height ?? 0, window, accuracy: 0.5, "\(state)")
            } else {
                XCTAssertEqual(inner.count, 0, "stacked rows, no window, \(state) at \(size)")
            }
        }
    }

    /// The chart's height, from the frame VoiceOver gives it: the chart is a container named for what it shows, its
    /// marks inside it.
    private func chartHeight(_ view: some View, as state: DuoState, typeSize: DynamicTypeSize, label: String) async throws -> CGFloat {
        let host = try await DuoHost(view, as: state, typeSize: typeSize)
        defer { host.close() }
        return try await DuoAccessibility.whileOn {
            var found: NSObject?
            for _ in 0..<40 where found == nil {
                try await Task.sleep(for: .milliseconds(50))
                found = Self.named(label, in: host.controller.view)
            }
            return try XCTUnwrap(found, "\(label) in \(state)").accessibilityFrame.height
        }
    }

    /// The first element or container whose label starts with `label`.
    private static func named(_ label: String, in o: NSObject) -> NSObject? {
        if o.accessibilityLabel?.hasPrefix(label) == true { return o }
        let n = o.accessibilityElementCount()
        if n != NSNotFound, n > 0 {
            for i in 0..<n { if let e = o.accessibilityElement(at: i) as? NSObject, let hit = named(label, in: e) { return hit } }
        }
        for sub in (o as? UIView)?.subviews ?? [] { if let hit = named(label, in: sub) { return hit } }
        return nil
    }

    // MARK: - Folding keeps the sheet (P4, P14, D13)

    /// The sheet from the shell (MetricSheetView), its answers from a made-up server: a week picked, its table open,
    /// then folded and unfolded and turned. The same hosted sheet keeps the range the person picked (the model) and the
    /// table they chose (a view's own state), and asks the server nothing more: nothing in it was made again.
    func testStateSurvivesBandChange() async throws {
        try await withMetricServer { dashboard in
            let host = try await DuoHost(Presented(sheet: MetricSheetView(request: MetricRequest(key: .hrv, section: "Your signals", page: .vitals))
                .environment(dashboard)), as: .outer)
            defer { host.close() }
            try await self.waitForAnswers(1)
            try await self.activate("Week", in: host)
            try await self.waitForAnswers(2)
            try await self.activate("Table", in: host)
            for state: DuoState in [.innerLandscape(), .innerPortrait(), .innerLandscape(foldActive: true), .innerSplit(bar: .trailing), .outer] {
                try await host.set(state)
                let elements = try await host.elements()
                let week = try XCTUnwrap(elements.first { $0.accessibilityLabel == "Week" }, "\(state)")
                XCTAssertTrue(week.accessibilityTraits.contains(.selected), "the week the person picked, \(state)")
                XCTAssertTrue(elements.contains { $0.accessibilityLabel?.hasPrefix("Date: ") == true }, "the table they opened, \(state)")
                XCTAssertTrue(elements.contains { $0.accessibilityLabel == "Table" && $0.accessibilityTraits.contains(.selected) }, "\(state)")
            }
            XCTAssertEqual(MetricSheetStub.asked, ["range=month", "range=week"], "nothing asked again")
        }
    }

    /// The loader runs once per range and generation, whatever the display does: opened on the outer display and taken
    /// through every state, the sheet asks for its month once.
    func testBandChangeDoesNotReload() async throws {
        try await withMetricServer { dashboard in
            let host = try await DuoHost(Presented(sheet: MetricSheetView(request: MetricRequest(key: .hrv, section: "Your signals", page: .vitals))
                .environment(dashboard)), as: .outer)
            defer { host.close() }
            try await self.waitForAnswers(1)
            for state in DuoState.all + DuoState.folded + [.outer] {
                try await host.set(state)
            }
            try await host.set(.innerLandscape(), typeSize: .accessibility3)
            try await host.set(.outer, typeSize: .large)
            XCTAssertEqual(MetricSheetStub.asked, ["range=month"])
            let elements = try await host.elements()
            XCTAssertTrue(elements.contains { $0.accessibilityLabel == "Month" && $0.accessibilityTraits.contains(.selected) })
        }
    }

    /// A made-up server (MetricSheetStub, at an address that goes nowhere) answering GET /api/metric/hrv with the demo
    /// month, or the same as a week; the address and the stub put back after.
    private func withMetricServer(_ body: (Dashboard) async throws -> Void) async throws {
        let saved = UserDefaults.standard.string(forKey: "serverURL")
        MetricSheetStub.reset(month: try fixtureData("metric-hrv-month"))
        APIClient.answering(with: [MetricSheetStub.self])
        Config.serverText = "http://metric-sheet-duo.example.test"
        defer {
            APIClient.answering(with: [])
            if let saved { UserDefaults.standard.set(saved, forKey: "serverURL") } else { UserDefaults.standard.removeObject(forKey: "serverURL") }
            MetricSheetStub.reset(month: nil)
        }
        try await body(Dashboard())
    }

    private func waitForAnswers(_ count: Int) async throws {
        for _ in 0..<100 where MetricSheetStub.asked.count < count { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(MetricSheetStub.asked.count, count)
        try await Task.sleep(for: .milliseconds(300))
    }

    /// Presses the button VoiceOver names `label`, as VoiceOver would.
    private func activate(_ label: String, in host: DuoHost) async throws {
        let elements = try await host.elements()
        let element = try XCTUnwrap(elements.first { $0.accessibilityLabel == label }, "\(label) on screen")
        try await DuoAccessibility.whileOn { XCTAssertTrue(element.accessibilityActivate(), label) }
        try await host.settle()
    }
}

/// The sheet where the system presents it (§2.7): at compact width the whole sheet, drawn as the kit draws a page; at
/// regular width 653 by 661, centred on the window over the page, dimmed (measured open in landscape: x 149–802; upright
/// assumed the same), with no safe-area inset of its own where it runs over the home indicator's (UIKit bounds a
/// presented sheet's view by the sheet, so nothing in it reaches past its edge). One structure in both, so a fold changes
/// its frame only and nothing in the sheet is made again, as UIKit keeps a presented sheet's view across a fold.
private struct Presented<Sheet: View>: View {
    static var centred: CGSize { CGSize(width: 653, height: 661) }
    let sheet: Sheet
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        GeometryReader { proxy in
            let centred = sizeClass == .regular
            // Inside the reader nothing has a safe area: the whole sheet gets the window's insets back, the centred one
            // none.
            sheet
                .safeAreaPadding(centred ? EdgeInsets() : proxy.safeAreaInsets)
                .frame(width: centred ? Self.centred.width : nil, height: centred ? Self.centred.height : nil)
                .clipShape(SheetOutline(centred: centred))
                .background {
                    if centred {
                        GradientFill(.gradSheet).clipShape(RoundedRectangle(cornerRadius: Radius.sheet, style: .continuous))
                    } else {
                        GradientFill(.gradSheet).ignoresSafeArea()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    if centred { ZStack { Palette.page; Color.black.opacity(0.2) } }
                }
        }
        .ignoresSafeArea()
    }
}

/// The centred sheet's rounded outline, which clips what's in it; at compact width nothing is clipped.
private struct SheetOutline: Shape {
    let centred: Bool

    func path(in rect: CGRect) -> Path {
        centred ? RoundedRectangle(cornerRadius: Radius.sheet, style: .continuous).path(in: rect) : Path(rect.insetBy(dx: -10_000, dy: -10_000))
    }
}

/// Answers GET /api/metric/hrv as the local demo server does: the month, or the same readings as a week; counts what
/// it's asked, by query.
private final class MetricSheetStub: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var month: Data?
    nonisolated(unsafe) private static var queries: [String] = []

    static var asked: [String] { lock.withLock { queries } }

    static func reset(month data: Data?) {
        lock.withLock {
            month = data
            queries = []
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "metric-sheet-duo.example.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let query = url.query ?? ""
        let body: Data? = Self.lock.withLock {
            Self.queries.append(query)
            guard url.path == "/api/metric/hrv", let month = Self.month else { return nil }
            guard query.contains("range=week") else { return month }
            return String(decoding: month, as: UTF8.self).replacingOccurrences(of: #""range":"month""#, with: #""range":"week""#).data(using: .utf8)
        }
        let status = body == nil ? 404 : 200
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body ?? Data(#"{"error":"Not found"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
