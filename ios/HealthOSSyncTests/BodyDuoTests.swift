import SwiftUI
import XCTest
@testable import HealthOSSync

/// The Body page drawn at the iPhone Duo's sizes (duo/design.md §8.2), from the local demo server's answers
/// (Fixtures/body.json, server G's made-up demo data): the outer display, the inner display upright, open flat and with
/// the fold active (decisions.md Q5: the figure on the leading side, two columns on the trailing side), and Split View,
/// light and dark, at the default text size and AX3. Nothing tappable meets the fold, and a fold keeps the tab and reads
/// nothing again. With TEST_RUNNER_DUO_SHOTS set, each drawing is written there as d-<state>-<light|dark>[-size].png.
@MainActor
final class BodyDuoTests: XCTestCase {
    /// The fixture's reads, counted.
    final class Counter {
        var reads: [String] = []
    }

    struct Fixture: Decodable {
        struct Past: Decodable {
            let date: String
            let summary: Summary
            let overview: Trends
            let day: DayData
            let workouts: [Workout]
            let glucose: MetricSheetData?
        }

        let summary: Summary
        let status: ServerStatus
        let measured: Trends
        let latest: BodyLatest
        let overview: Trends
        let day: DayData
        let workouts: [Workout]
        let glucose: MetricSheetData?
        let labs: LabsData
        let tabs: [String: Trends]
        let activityWorkouts: [Workout]
        let past: Past
    }

    static func fixture() throws -> Fixture {
        let url = Bundle(for: Self.self).url(forResource: "body", withExtension: "json")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/body.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    /// Reads that answer from the fixture, in the server's place, and count themselves. The device rows are for the
    /// fixture's whole past day (today's can be empty just after midnight), the figure and measurements as of today.
    static func reads(_ f: Fixture, counter: Counter, latest: (() throws -> BodyLatest?)? = nil, entries: [BodyEntry] = []) -> BodyReads {
        BodyReads(
            summary: { _, date in counter.reads.append("summary \(date ?? "today")"); return date == nil ? f.summary : f.past.summary },
            trends: { _, metrics, days, date in
                counter.reads.append("trends \(metrics.joined(separator: ",")) \(days) \(date ?? "today")")
                if metrics == BodyOverviewMath.trendMetrics { return date == nil ? f.overview : f.past.overview }
                if Set(metrics) == Set(BodyMetric.allCases.map(\.rawValue)) { return f.measured }
                if metrics == BodyActivityMath.metrics { return f.tabs["activity"] ?? [:] }
                for (tab, t) in f.tabs where Set(t.keys) == Set(metrics) { _ = tab; return t }
                return [:]
            },
            latest: { _ in counter.reads.append("latest"); return try latest?() ?? f.latest },
            entries: { _, metric in counter.reads.append("entries \(metric.rawValue)"); return BodyEntries(entries: entries) },
            add: { _, _ in counter.reads.append("add") },
            delete: { _, id in counter.reads.append("delete \(id)") },
            day: { _, date in counter.reads.append("day \(date ?? "today")"); return date == nil ? f.day : f.past.day },
            workouts: { _, days, date in counter.reads.append("workouts \(days) \(date ?? "today")"); return date == nil && days != 90 ? f.activityWorkouts : f.past.workouts },
            glucose: { _, date in counter.reads.append("glucose \(date)"); return date == f.past.date ? f.past.glucose : f.glucose },
            labs: { _ in counter.reads.append("labs"); return f.labs }
        )
    }

    /// Signed in with the fixture's status, the shared date on the past day.
    static func dashboard(_ f: Fixture, past: Bool = true) -> Dashboard {
        let d = Dashboard()
        d.authMode = "required"
        d.signedIn()
        d.apply(status: f.status)
        if past {
            d.date = f.past.date
            d.summary = f.past.summary
        } else {
            d.summary = f.summary
        }
        return d
    }

    private func page(_ d: Dashboard, _ reads: BodyReads) -> some View {
        BodyScreen().environment(d).environment(\.bodyReads, reads)
    }

    /// The fixture's status with other settings (a perspective, hidden cards), as the server would answer them.
    static func status(_ f: Fixture, _ change: (inout [String: Any]) -> Void) throws -> ServerStatus {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(f.status)) as? [String: Any])
        var settings = json["settings"] as? [String: Any] ?? [:]
        change(&settings)
        json["settings"] = settings
        return try JSONDecoder().decode(ServerStatus.self, from: JSONSerialization.data(withJSONObject: json))
    }

    /// The Duo's states the task names: the outer display, upright, open flat with the bar on either side, the fold
    /// active, and Split View.
    static let states: [DuoState] = [.outer, .innerPortrait(), .innerLandscape(), .innerLandscape(bar: .leading),
                                     .innerLandscape(foldActive: true), .innerSplit(bar: .leading), .innerSplit(bar: .trailing)]

    // MARK: Drawn

    func testTheOverviewDrawsInEveryState() async throws {
        let f = try Self.fixture()
        for size: DynamicTypeSize in [.large, .accessibility3] {
            for state in Self.states {
                for dark in [false, true] {
                    let d = Self.dashboard(f)
                    try await DuoSnapshot.draw(page(d, Self.reads(f, counter: Counter())), as: state, dark: dark, typeSize: size, name: "d")
                }
            }
        }
    }

    /// "Just the statistics": no figure, so on the open Duo the page splits on the fold, both sides carrying cards.
    func testTheOverviewWithoutAFigureDraws() async throws {
        let f = try Self.fixture()
        let stats = try Self.status(f) { $0["perspective"] = "stats" }
        for state: DuoState in [.outer, .innerPortrait(), .innerLandscape(), .innerLandscape(bar: .leading)] {
            for dark in [false, true] {
                let d = Self.dashboard(f)
                d.apply(status: stats)
                try await DuoSnapshot.draw(page(d, Self.reads(f, counter: Counter())), as: state, dark: dark, name: "d-stats")
            }
        }
    }

    /// Every tab, and the Activity tab's Day view, in the states that change their layout.
    func testTheTabsDraw() async throws {
        let f = try Self.fixture()
        let tabs = ["activity", "recovery", "strain", "temperature", "cardiovascular", "metabolism"]
        for tab in tabs {
            for state: DuoState in [.outer, .innerPortrait(), .innerLandscape(), .innerLandscape(bar: .leading), .innerLandscape(foldActive: true), .innerSplit(bar: .trailing)] {
                for dark in [false, true] {
                    let d = Self.dashboard(f)
                    d.open(AppRoute(.body, query: ["tab": tab]))
                    try await DuoSnapshot.draw(page(d, Self.reads(f, counter: Counter())), as: state, dark: dark, name: "d-\(tab)")
                }
            }
        }
        for size: DynamicTypeSize in [.large, .accessibility3] {
            for state: DuoState in [.outer, .innerLandscape(), .innerLandscape(bar: .leading)] {
                let d = Self.dashboard(f, past: false)
                d.rangeDays = ChartRange.day.days
                d.open(AppRoute(.body, query: ["tab": "activity"]))
                try await DuoSnapshot.draw(page(d, Self.reads(f, counter: Counter())), as: state, typeSize: size, name: "d-activity-day")
            }
        }
    }

    /// The whole page in one tall drawing at the web's phone width (375), for comparing with its references by eye:
    /// written only when TEST_RUNNER_DUO_SHOTS is set.
    func testTheWholePageAtPhoneWidth() async throws {
        guard let folder = DuoSnapshot.folder else { return }
        let f = try Self.fixture()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        for (tab, name) in [(nil, "tall-overview"), ("activity", "tall-activity"), ("metabolism", "tall-metabolism")] as [(String?, String)] {
            for dark in [false, true] {
                for size: DynamicTypeSize in [.large, .accessibility5] {
                    let d = Self.dashboard(f)
                    if let tab { d.open(AppRoute(.body, query: ["tab": tab])) }
                    let host = UIHostingController(rootView: AnyView(page(d, Self.reads(f, counter: Counter())).environment(\.dynamicTypeSize, size)))
                    host.safeAreaRegions = []
                    let window = UIWindow(windowScene: scene)
                    window.frame = CGRect(x: 0, y: 0, width: 375, height: size == .large ? 4400 : 9000)
                    window.overrideUserInterfaceStyle = dark ? .dark : .light
                    window.rootViewController = host
                    window.makeKeyAndVisible()
                    try await Task.sleep(for: .milliseconds(1500))
                    let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
                    window.isHidden = true
                    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try image.pngData()?.write(to: folder.appendingPathComponent("\(name)-\(dark ? "dark" : "light")\(size == .large ? "" : "-\(size)").png"))
                }
            }
        }
    }

    // MARK: The fold

    func testNothingTappableOnTheFold() async throws {
        let f = try Self.fixture()
        for state in DuoState.folded {
            for size: DynamicTypeSize in [.large, .accessibility3] {
                let d = Self.dashboard(f)
                try await DuoFoldAssertions.assertNothingTappableOnTheFold(page(d, Self.reads(f, counter: Counter())), state: state, typeSize: size)
            }
        }
        // The tabs, split on the fold, with the tabs and range picker on the trailing side.
        for tab in ["activity", "cardiovascular", "metabolism"] {
            for state in DuoState.folded {
                for size: DynamicTypeSize in [.large, .accessibility3] {
                    let d = Self.dashboard(f)
                    d.open(AppRoute(.body, query: ["tab": tab]))
                    try await DuoFoldAssertions.assertNothingTappableOnTheFold(page(d, Self.reads(f, counter: Counter())), state: state, typeSize: size)
                }
            }
        }
        // The Day view, and the Overview without a figure.
        let stats = try Self.status(f) { $0["perspective"] = "stats" }
        for state in DuoState.folded {
            let day = Self.dashboard(f, past: false)
            day.rangeDays = ChartRange.day.days
            day.open(AppRoute(.body, query: ["tab": "activity"]))
            try await DuoFoldAssertions.assertNothingTappableOnTheFold(page(day, Self.reads(f, counter: Counter())), state: state, typeSize: .accessibility3)
            let plain = Self.dashboard(f)
            plain.apply(status: stats)
            try await DuoFoldAssertions.assertNothingTappableOnTheFold(page(plain, Self.reads(f, counter: Counter())), state: state, typeSize: .large)
        }
    }

    /// Every element's frame by identifier, containers included (as HomeDuoTests reads them).
    static func frames(_ host: DuoHost) async throws -> [String: CGRect] {
        try await DuoAccessibility.whileOn {
            var out: [String: CGRect] = [:], last = -1
            for _ in 0..<40 {
                try await Task.sleep(for: .milliseconds(50))
                out = [:]
                collect(host.controller.view, into: &out)
                if !out.isEmpty, out.count == last { break }
                last = out.count
            }
            return out
        }
    }

    private static func collect(_ o: NSObject, into out: inout [String: CGRect]) {
        if let id = HomeDuoTests.identifier(o), !id.isEmpty, out[id] == nil { out[id] = o.accessibilityFrame }
        let n = o.accessibilityElementCount()
        if n != NSNotFound, n > 0 {
            for i in 0..<n { if let e = o.accessibilityElement(at: i) as? NSObject { collect(e, into: &out) } }
        }
        for sub in (o as? UIView)?.subviews ?? [] { collect(sub, into: &out) }
    }

    /// The figure card sits wholly on the leading side of the fold, inside the pane, which doesn't scroll; the
    /// measurements on the trailing side, two small cards to a row. With the bar on either side.
    func testTheFigureIsOnTheLeadingSide() async throws {
        let f = try Self.fixture()
        for bar: HorizontalEdge in [.trailing, .leading] {
            let d = Self.dashboard(f)
            let state = DuoState.innerLandscape(bar: bar)
            let host = try await DuoHost(page(d, Self.reads(f, counter: Counter())), as: state)
            defer { host.close() }
            let frames = try await Self.frames(host)
            let fold = try XCTUnwrap(DuoFoldAssertions.band(state))
            let figure = try XCTUnwrap(frames["body.figure"], "the figure card, bar \(bar): \(frames.keys.sorted())")
            XCTAssertLessThan(figure.maxX, fold.lowerBound, "the figure stays left of the fold")
            XCTAssertLessThanOrEqual(figure.maxY, state.size.height - state.insets.bottom + 1, "the figure card fits the pane, bar \(bar)")
            let weight = try XCTUnwrap(frames["body.weight"], "the weight card")
            let fat = try XCTUnwrap(frames["body.body_fat"], "the body fat card")
            XCTAssertGreaterThan(weight.minX, fold.upperBound, "the measurements are right of the fold")
            XCTAssertEqual(weight.minY, fat.minY, accuracy: 1, "two to a row")
            XCTAssertLessThan(weight.maxX, fat.minX)
        }
    }

    /// A tab's charts go one each side of the fold, two to a row; upright, one to a row as on the web.
    func testATabsChartsGoOneEachSideOfTheFold() async throws {
        let f = try Self.fixture()
        let state = DuoState.innerLandscape()
        let d = Self.dashboard(f)
        d.open(AppRoute(.body, query: ["tab": "activity"]))
        let host = try await DuoHost(page(d, Self.reads(f, counter: Counter())), as: state)
        defer { host.close() }
        let fold = try XCTUnwrap(DuoFoldAssertions.band(state))
        var frames = try await Self.frames(host)
        let steps = try XCTUnwrap(frames["activity.steps"], "\(frames.keys.sorted())")
        let tabs = try XCTUnwrap(frames["body.tabs"])
        XCTAssertLessThan(steps.maxX, fold.lowerBound, "steps on the leading side")
        XCTAssertGreaterThan(tabs.minX, fold.upperBound, "the tabs on the trailing side, beside the page's line")
        let besides = frames.filter { $0.key.hasPrefix("activity.") || $0.key.hasPrefix("trend.") }
            .filter { abs($0.value.minY - steps.minY) < 1 && $0.value.minX > fold.upperBound }
        XCTAssertFalse(besides.isEmpty, "a chart beside the steps, across the fold: \(frames.filter { $0.key.hasPrefix("activity.") })")
        try await host.set(.innerPortrait())
        frames = try await Self.frames(host)
        let upright = try XCTUnwrap(frames["activity.steps"])
        XCTAssertGreaterThan(upright.width, 600, "one to a row upright")
    }

    // MARK: State across a fold (P4, P14)

    /// The tab and the page's data stay as the same page goes between one column and two panes, and nothing is read
    /// again.
    func testATabSurvivesAPaneSwapWithoutReadingAgain() async throws {
        let f = try Self.fixture()
        let counter = Counter()
        let d = Self.dashboard(f)
        let host = try await DuoHost(page(d, Self.reads(f, counter: counter)), as: .outer)
        defer { host.close() }
        d.open(AppRoute(.body, query: ["tab": "activity"]))
        try await host.settle()
        let before = counter.reads
        XCTAssertTrue(before.contains { $0.hasPrefix("trends steps") }, "\(before)")
        for state: DuoState in [.innerLandscape(), .outer, .innerLandscape(foldActive: true), .innerPortrait(), .outer] {
            try await host.set(state)
            let ids = try await Self.frames(host).keys
            XCTAssertTrue(ids.contains("activity.steps"), "still the Activity tab in \(state): \(ids.sorted())")
        }
        XCTAssertEqual(counter.reads, before, "a fold reads nothing again")
    }

    /// The Overview's panes: the sheet's metric, chosen above the panes, and the reads stay across a fold.
    func testTheOverviewSurvivesAPaneSwap() async throws {
        let f = try Self.fixture()
        let counter = Counter()
        let d = Self.dashboard(f)
        let host = try await DuoHost(page(d, Self.reads(f, counter: counter)), as: .innerLandscape())
        defer { host.close() }
        let before = counter.reads
        for state: DuoState in [.outer, .innerLandscape(bar: .leading), .innerPortrait(), .innerLandscape(foldActive: true)] {
            try await host.set(state)
            let ids = try await Self.frames(host).keys
            XCTAssertTrue(ids.contains("body.figure"), "the figure in \(state)")
        }
        XCTAssertEqual(counter.reads, before, "a fold reads nothing again")
    }

    /// The page opens before today's summary has come: once it lands, the device rows are read (they wait for it).
    func testTheDeviceRowsAreReadOnceTheSummaryLands() async throws {
        let f = try Self.fixture()
        let counter = Counter()
        let d = Self.dashboard(f, past: false)
        let summary = d.summary
        d.summary = nil
        let host = try await DuoHost(page(d, Self.reads(f, counter: counter)), as: .outer)
        defer { host.close() }
        XCTAssertFalse(counter.reads.contains { $0.hasPrefix("trends \(BodyOverviewMath.trendMetrics.joined(separator: ","))") })
        d.summary = summary
        try await host.settle()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(counter.reads.contains { $0.hasPrefix("trends \(BodyOverviewMath.trendMetrics.joined(separator: ","))") }, "\(counter.reads)")
    }

    /// The entry sheet reads and lists your entries (each with its Delete), and asks before deleting one.
    func testTheEntrySheetListsYourEntries() async throws {
        let f = try Self.fixture()
        let counter = Counter()
        let d = Self.dashboard(f, past: false)
        let entry = BodyEntry(id: "e1", metric: "weight", value: 72.4, date: f.summary.today, method: "scale")
        let sheet = BodyEntrySheet(metric: .weight, today: f.summary.today, demo: false, changed: {}, close: {})
            .environment(d).environment(\.bodyReads, Self.reads(f, counter: counter, entries: [entry]))
        let host = try await DuoHost(sheet, as: .outer)
        defer { host.close() }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(counter.reads.contains("entries weight"), "\(counter.reads)")
        let frames = try await Self.frames(host)
        XCTAssertNotNil(frames["body.entry.list"], "\(frames.keys.sorted())")
        XCTAssertNotNil(frames["body.entry.delete"], "each entry has its own Delete")
        for state: DuoState in [.innerLandscape(), .innerPortrait()] {
            try await host.set(state)
            DuoSnapshot.write(host.image(), name: "d-entry", state: state)
        }
    }

    func testTheOverviewReadsOnceAcrossBandChanges() async throws {
        let f = try Self.fixture()
        let counter = Counter()
        let d = Self.dashboard(f)
        let host = try await DuoHost(page(d, Self.reads(f, counter: counter)), as: .innerPortrait())
        defer { host.close() }
        let before = counter.reads
        XCTAssertEqual(Set(before), ["summary today", "trends weight,body_fat,lean_mass 120 today", "latest",
                                     "trends \(BodyOverviewMath.trendMetrics.joined(separator: ",")) 45 \(f.past.date)", "day \(f.past.date)",
                                     "workouts 90 \(f.past.date)", "glucose \(f.past.date)", "labs"])
        for state: DuoState in [.innerLandscape(), .outer, .innerSplit(bar: .trailing), .innerLandscape(bar: .leading)] {
            try await host.set(state)
        }
        try await host.set(.innerLandscape(), typeSize: .accessibility3)
        XCTAssertEqual(counter.reads, before)
    }
}
