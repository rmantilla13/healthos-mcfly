import SwiftUI
import XCTest
@testable import HealthOSSync

/// Pictures of the metric sheet's states, drawn from the local demo server's answers (Fixtures/metric-*.json) in light
/// and dark and at the largest text size, for comparing with the web's sheet by eye. Only when asked for: run the tests
/// with TEST_RUNNER_METRIC_SHEET_SHOTS=<folder> and the PNGs are written there. Otherwise every test here is skipped.
@MainActor
final class MetricSheetSnapshotTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        guard let path = ProcessInfo.processInfo.environment["METRIC_SHEET_SHOTS"], !path.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_METRIC_SHEET_SHOTS to a folder to draw the sheet's states.")
        }
        folder = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private func fixture(_ name: String) throws -> MetricSheetData {
        let url = Bundle(for: Self.self).url(forResource: name, withExtension: "json")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name).json")
        return try JSONDecoder().decode(MetricSheetData.self, from: try Data(contentsOf: url))
    }

    /// One state: the sheet as the shell shows it (its scaffold on the sheet gradient), and its content alone, to measure.
    private struct Shot {
        let page: AnyView
        let content: AnyView
    }

    private func shot(_ key: MetricKey, section: String = "Your signals", sheet: MetricSheetData?, range: MetricRange? = nil, picked: Bool = false,
                      note: String? = nil, loading: Bool = false, error: String? = nil, openPage: String? = "Vitals") -> Shot {
        let content = MetricSheetContent(key: key, range: range ?? sheet?.range ?? key.info.initial, sheet: sheet, picked: picked, note: note,
                                         loading: loading, error: error, openPage: openPage)
        let page = SheetScaffold(eyebrow: section, title: key.info.label, onClose: {}) { content }
            .background(GradientFill(.gradSheet).ignoresSafeArea())
        return Shot(page: AnyView(page), content: AnyView(content.padding(.horizontal, 18)))
    }

    private func draw(_ shot: Shot, _ name: String, dark: Bool = false, size: DynamicTypeSize = .large) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let width: CGFloat = 402
        // The sheet scrolls as one, so it's as tall as its content plus its header and margins.
        let measure = UIHostingController(rootView: AnyView(shot.content.environment(\.dynamicTypeSize, size)))
        let fits = measure.sizeThatFits(in: CGSize(width: width, height: 20_000))
        let host = UIHostingController(rootView: AnyView(shot.page.environment(\.dynamicTypeSize, size)))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: min(fits.height + (size.isAccessibilitySize ? 300 : 160), 2700))
        window.overrideUserInterfaceStyle = dark ? .dark : .light
        window.rootViewController = host
        window.makeKeyAndVisible()
        // Fonts, charts and the first layout pass.
        try await Task.sleep(for: .milliseconds(1200))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        window.isHidden = true
        let file = folder.appendingPathComponent("\(name)-\(dark ? "dark" : "light")\(size == .large ? "" : "-\(size)").png")
        try XCTUnwrap(image.pngData()).write(to: file)
    }

    private func both(_ shot: Shot, _ name: String) async throws {
        try await draw(shot, name)
        try await draw(shot, name, dark: true)
    }

    func testAMeasuredMonth() async throws {
        let s = try fixture("metric-hrv-month")
        try await both(shot(.hrv, sheet: s), "hrv-month")
        try await draw(shot(.hrv, sheet: s), "hrv-month", size: .accessibility5)
        // Loading another range: the month stays up, dimmed.
        try await both(shot(.hrv, sheet: s, range: .year, loading: true), "hrv-loading-year")
    }

    func testAWeekOfBars() async throws {
        let s = try fixture("metric-steps-week")
        // From Home's Activity card, which the web links to #/activity: "Open Activity".
        try await both(shot(.steps, sheet: s, openPage: "Activity"), "steps-week")
        for size: DynamicTypeSize in [.xxxLarge, .accessibility3, .accessibility5] {
            try await draw(shot(.steps, sheet: s, openPage: "Activity"), "steps-week", size: size)
        }
        try await draw(shot(.steps, sheet: s, openPage: "Activity"), "steps-week", dark: true, size: .accessibility5)
    }

    func testAYearOfWeeks() async throws {
        try await both(shot(.sleepHours, section: "Sleep", sheet: try fixture("metric-sleep-year"), openPage: "Sleep"), "sleep-year")
    }

    func testTheTables() async throws {
        let year = shot(.sleepHours, section: "Sleep", sheet: try fixture("metric-sleep-year"), openPage: "Sleep")
        try await both(Shot(page: AnyView(year.page.environment(\.sheetChartOpensOnTable, true)),
                            content: AnyView(year.content.environment(\.sheetChartOpensOnTable, true))), "sleep-year-table")
        // The Day's tables: every cell on one line at every text size, scrolling sideways when wider than the sheet.
        let heart = table(shot(.heartRate, section: "Body", sheet: try fixture("metric-heart-rate-day")))
        let steps = table(shot(.steps, section: "Body", sheet: stepsDay(), openPage: "Activity on Body"))
        for (s, name) in [(heart, "heart-rate-day-table"), (steps, "steps-day-table")] {
            try await both(s, name)
            for size: DynamicTypeSize in [.xxxLarge, .accessibility3, .accessibility5] {
                try await draw(s, name, size: size)
            }
            try await draw(s, name, dark: true, size: .accessibility3)
        }
    }

    private func table(_ s: Shot) -> Shot {
        Shot(page: AnyView(s.page.environment(\.sheetChartOpensOnTable, true)), content: AnyView(s.content.environment(\.sheetChartOpensOnTable, true)))
    }

    /// Made-up steps by the hour until 6 AM, against a made-up typical day.
    private func stepsDay() -> MetricSheetData {
        let hours: [Double?] = [0, 0, 0, 0, 0, 420, 1260] + Array(repeating: nil, count: 17)
        let typical: [Double?] = [0, 0, 0, 0, 30, 380, 1850] + Array(repeating: nil, count: 17)
        let day = DayData(date: "2026-10-26", today: "2026-10-26", asOf: 6, metrics: ["steps": DaySeries(hours: hours, typical: typical)])
        return MetricSheetFallback.daySheet(.steps, day: day, date: "2026-10-26", today: "2026-10-26", goal: 10_000)
    }

    func testADayByTheHour() async throws {
        // From Body's own card, which the web links to #/body?tab=activity: "Open Activity on Body".
        try await both(shot(.steps, section: "Body", sheet: try fixture("metric-steps-day"), openPage: "Activity on Body"), "steps-day")
        try await both(shot(.heartRate, section: "Body", sheet: try fixture("metric-heart-rate-day"), openPage: "Vitals"), "heart-rate-day")
    }

    func testNeverMeasured() async throws {
        let s = try fixture("metric-glucose-never")
        try await both(shot(.glucose, section: "Body", sheet: s, openPage: "Body"), "glucose-never")
        // Manage connections grows with the text: one line to xxxLarge, then its words wrap inside the sheet.
        for size: DynamicTypeSize in [.xxxLarge, .accessibility1, .accessibility3, .accessibility5] {
            try await draw(shot(.glucose, section: "Body", sheet: s, openPage: "Body"), "glucose-never", size: size)
        }
        try await draw(shot(.glucose, section: "Body", sheet: s, openPage: "Body"), "glucose-never", dark: true, size: .accessibility5)
        let lean = MetricSheetData(key: .leanMass, range: .month, headline: MetricFigure(label: "Average", value: nil, unit: "kg"), everMeasured: false)
        try await both(shot(.leanMass, section: "Body", sheet: lean, openPage: "Body"), "lean-never")
    }

    func testLoadingAndFailing() async throws {
        try await both(shot(.restingHr, sheet: nil, loading: true), "loading")
        try await both(shot(.restingHr, sheet: nil, error: "Something went wrong"), "error")
    }

    /// A point picked under the finger: the crosshair or lit bar, and the tooltip on that day, inside the chart.
    func testTheTooltips() async throws {
        let month = shot(.hrv, sheet: try fixture("metric-hrv-month"))
        let week = shot(.steps, sheet: try fixture("metric-steps-week"), openPage: "Activity")
        let year = shot(.sleepHours, section: "Sleep", sheet: try fixture("metric-sleep-year"), openPage: "Sleep")
        for (s, index, name) in [(month, 18, "hrv-month-tooltip"), (month, 29, "hrv-month-tooltip-end"), (week, 2, "steps-week-tooltip"),
                                 (week, 5, "steps-week-tooltip-end"), (year, 10, "sleep-year-tooltip")] {
            try await both(Shot(page: AnyView(s.page.environment(\.sheetChartPicksPoint, index)),
                                content: AnyView(s.content.environment(\.sheetChartPicksPoint, index))), name)
        }
    }

    func testAnEmptyMonthMovedToTheYear() async throws {
        // Made-up readings: one estimate 50 days back, as the web's own test has it.
        let year = MetricSheetFallback.windowSheet(.vo2max, range: .year, metric: "vo2max", points: [Point(date: "2026-09-06", value: 42.5)],
                                                   to: "2026-10-26", today: "2026-10-26", units: .metric, goal: nil)
        let month = MetricSheetFallback.windowSheet(.vo2max, range: .month, metric: "vo2max", points: [], to: "2026-10-26", today: "2026-10-26",
                                                    units: .metric, goal: nil)
        var r = SheetRanges(key: .vo2max, asked: nil)
        r.heard(month, current: true)
        try await both(shot(.vo2max, section: "Body", sheet: year, range: r.range, note: r.note(shown: year), openPage: "Cardiovascular on Body"),
                       "vo2max-widened")
        // The year it moved to, pressed: a pick, so the note goes and it stays.
        r.pick(.year)
        try await both(shot(.vo2max, section: "Body", sheet: year, range: r.range, picked: r.picked, note: r.note(shown: year),
                            openPage: "Cardiovascular on Body"), "vo2max-year-pressed")
        // The month pressed again: empty, and it says where to look.
        try await both(shot(.vo2max, section: "Body", sheet: month, picked: true, openPage: "Cardiovascular on Body"), "vo2max-month-empty")
    }
}
