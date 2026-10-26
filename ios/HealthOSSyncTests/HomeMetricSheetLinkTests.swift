import SwiftUI
import XCTest
@testable import HealthOSSync

/// Every Home card the web opens a metric's sheet from (Signals.tsx's six, and Home.tsx's LoadCard and ActivityCard)
/// opens slice C's sheet for that metric here, with what the web passes: the section "Your signals", the card's own
/// page for "Open {Page}", no range (the metric's own default), and the day the card shows. Each card is put in a
/// window and pressed through accessibility, as VoiceOver or a tap would.
@MainActor
final class HomeMetricSheetLinkTests: XCTestCase {
    private func web(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard let text = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) else { throw XCTSkip("\(path) isn't next to the app") }
        return text
    }

    private func summary(_ edit: (inout [String: Any]) -> Void = { _ in }) throws -> Summary {
        let url = Bundle(for: Self.self).url(forResource: "summary", withExtension: "json")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/summary.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        edit(&json)
        return try JSONDecoder().decode(Summary.self, from: JSONSerialization.data(withJSONObject: json))
    }

    /// SwiftUI builds accessibility elements only while the simulator's accessibility automation is on; turned on here
    /// and put back as found (as MetricSheetTests does).
    private func withAccessibilityAutomation(_ body: () async throws -> Void) async throws {
        let root = ProcessInfo.processInfo.environment["IPHONE_SIMULATOR_ROOT"] ?? ""
        guard let lib = dlopen(root + "/usr/lib/libAccessibility.dylib", RTLD_LOCAL) ?? dlopen("/usr/lib/libAccessibility.dylib", RTLD_LOCAL),
              let get = dlsym(lib, "_AXSAutomationEnabled"), let set = dlsym(lib, "_AXSSetAutomationEnabled") else {
            XCTFail("the simulator's libAccessibility can't be loaded")
            return
        }
        let enabled = unsafeBitCast(get, to: (@convention(c) () -> Int32).self)
        let setEnabled = unsafeBitCast(set, to: (@convention(c) (Int32) -> Void).self)
        let before = enabled()
        setEnabled(1)
        defer { setEnabled(before) }
        try await body()
    }

    /// Shows a view in a window and hands back its accessibility elements once they've settled.
    private func onScreen(_ view: some View, run: ([NSObject]) async throws -> Void) async throws {
        try await withAccessibilityAutomation {
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let host = UIHostingController(rootView: view)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            func walk(_ o: NSObject, into out: inout [NSObject]) {
                if o.isAccessibilityElement { out.append(o) }
                let n = o.accessibilityElementCount()
                if n != NSNotFound, n > 0 {
                    for i in 0..<n { if let e = o.accessibilityElement(at: i) as? NSObject { walk(e, into: &out) } }
                }
                for sub in (o as? UIView)?.subviews ?? [] { walk(sub, into: &out) }
            }
            var elements: [NSObject] = [], last = -1
            for _ in 0..<60 {
                try await Task.sleep(for: .milliseconds(50))
                elements = []
                walk(host.view, into: &elements)
                if !elements.isEmpty, elements.count == last { break }
                last = elements.count
            }
            try await run(elements)
        }
    }

    /// Presses Home's card `id` (drawn as Home draws it, TodayGrid) and hands back the sheet it asked for.
    private func press(_ id: String, title: String, in summary: Summary) async throws -> MetricRequest? {
        let d = Dashboard()
        d.phase = .ready
        d.summary = summary
        d.tab = .home
        var request: MetricRequest?
        try await onScreen(TodayGrid(summary: summary, ids: [id], goal: 10_000).environment(d).frame(width: 370)) { elements in
            let card = try XCTUnwrap(elements.first { $0.accessibilityHint == "Opens \(title) details" },
                                     "\(id): a card VoiceOver can press, \(elements.map { $0.accessibilityLabel ?? "?" })")
            XCTAssertTrue(card.accessibilityActivate(), id)
            try await Task.sleep(for: .milliseconds(100))
            request = d.metricSheet
            if let request {
                // "Open {Page}", named as the sheet names it over Home.
                XCTAssertNotEqual(d.pageOnScreen?.page, request.page.page, "\(id): Home is under the sheet, not the card's page")
            }
        }
        return request
    }

    func testEachOfHomesCardsOpensItsMetricsSheetAsTheWebDoes() async throws {
        // The web's own links, so a change there shows up here.
        let signals = try web("src/components/home/Signals.tsx")
        for metric in ["resting_hr", "spo2", "hrv", "sleep_hours", "recovery", "resp_rate"] {
            XCTAssertTrue(signals.contains(#"metric="\#(metric)""#), metric)
        }
        XCTAssertTrue(signals.contains("metric=\"sleep_hours\"\n      href={href('sleep')}"), "sleep's sheet links Sleep; the others Vitals")
        let home = try web("src/pages/Home.tsx")
        XCTAssertTrue(home.contains(#"<CardHead title={strain ? 'Strain' : 'Active energy'} to={href('activity')} metric={strain ? 'strain' : 'active_energy'} date={s.date} />"#))
        XCTAssertTrue(home.contains(#"<CardHead title="Strain" to={href('activity')} metric="strain" date={s.date} />"#))
        XCTAssertTrue(home.contains(#"<CardHead title="Activity" to={href('activity')} metric="steps" date={s.date} />"#))

        let s = try summary()
        let expected: [(id: String, title: String, key: MetricKey, page: AppRoute, name: String)] = [
            ("home.rhr", "Resting heart rate", .restingHr, .vitals, "Vitals"),
            ("home.spo2", "Blood oxygen", .spo2, .vitals, "Vitals"),
            ("home.hrv", "HRV", .hrv, .vitals, "Vitals"),
            ("home.sleep", "Sleep", .sleepHours, .sleep, "Sleep"),
            ("home.readiness", "Recovery", .recovery, .vitals, "Vitals"),
            ("home.resp", "Respiratory rate", .respRate, .vitals, "Vitals"),
            ("home.load", "Strain", .strain, .activity, "Activity"),
            ("home.activity", "Activity", .steps, .activity, "Activity"),
        ]
        for card in expected {
            let request = try await press(card.id, title: card.title, in: s)
            let r = try XCTUnwrap(request, "\(card.id) opens a sheet")
            XCTAssertEqual(r.key, card.key, card.id)
            XCTAssertEqual(r.page, card.page, card.id)
            XCTAssertEqual(r.section, "Your signals", card.id)
            XCTAssertNil(r.range, "\(card.id): the web passes no range from Home")
            XCTAssertEqual(r.date, s.date, "\(card.id): the day Home shows")
            XCTAssertEqual(SheetPage.name(r.page, over: .home), card.name, "\(card.id): \"Open \(card.name)\"")
        }
        // Body's own Activity card names Body's tab; Home's say "Open Activity".
        XCTAssertEqual(SheetPage.name(.activity, over: .body), "Activity on Body")
    }

    /// Apple's active energy instead of WHOOP's strain, and no load at all: the same card, its own metric.
    func testTheLoadCardOpensActiveEnergyOrStrainAsItShows() async throws {
        let energy = try summary { json in
            var load = json["load"] as? [String: Any] ?? [:]
            load["kind"] = "active_energy"
            json["load"] = load
        }
        let pressed = try await press("home.load", title: "Active energy", in: energy)
        let r = try XCTUnwrap(pressed)
        XCTAssertEqual(r.key, .activeEnergy)
        XCTAssertEqual(r.page, .activity)

        let none = try summary { $0["load"] = nil }
        let pressedEmpty = try await press("home.load", title: "Strain", in: none)
        let empty = try XCTUnwrap(pressedEmpty)
        XCTAssertEqual(empty.key, .strain, "the empty card still opens strain's sheet, as the web's does")
    }
}
