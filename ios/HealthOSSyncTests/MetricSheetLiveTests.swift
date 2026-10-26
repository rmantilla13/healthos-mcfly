import SwiftUI
import XCTest
@testable import HealthOSSync

/// The sheet against a running server, presented as the shell presents it, for looking at by eye until Home's cards
/// open it (slice B). Only when asked for: TEST_RUNNER_METRIC_SHEET_SERVER (a scratch server, never the hosted one),
/// TEST_RUNNER_METRIC_SHEET_SESSION (a session cookie's value for it) and TEST_RUNNER_METRIC_SHEET_SHOTS (where the
/// PNGs go). Otherwise every test here is skipped. The session and server address are put back as they were after.
@MainActor
final class MetricSheetLiveTests: XCTestCase {
    private var folder: URL!
    private var savedServer: String?

    override func setUp() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let server = env["METRIC_SHEET_SERVER"], let session = env["METRIC_SHEET_SESSION"], let shots = env["METRIC_SHEET_SHOTS"],
              let url = URL(string: server), ["localhost", "127.0.0.1"].contains(url.host() ?? "") else {
            throw XCTSkip("Set TEST_RUNNER_METRIC_SHEET_SERVER (a local server), _SESSION and _SHOTS to draw the sheet against it.")
        }
        folder = URL(fileURLWithPath: shots)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        savedServer = UserDefaults.standard.string(forKey: "serverURL")
        Config.serverText = server
        let base = try XCTUnwrap(Config.serverURL())
        SessionStore.update(from: "\(SessionStore.name)=\(session); Path=/; HttpOnly", url: base, base: base)
        XCTAssertNotNil(SessionStore.cookie(for: base))
    }

    override func tearDown() async throws {
        guard folder != nil else { return }
        SessionStore.clear()
        if let savedServer { Config.serverText = savedServer } else { UserDefaults.standard.removeObject(forKey: "serverURL") }
    }

    /// Presents the sheet over a page, as the shell does, waits for the server, and keeps a picture of the screen.
    private func show(_ request: MetricRequest, _ name: String, dark: Bool = false, size: DynamicTypeSize = .large, wait: Double = 3) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let dashboard = Dashboard()
        let host = UIHostingController(rootView: AnyView(Presenter(request: request).environment(dashboard).environment(\.dynamicTypeSize, size)))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.overrideUserInterfaceStyle = dark ? .dark : .light
        window.rootViewController = host
        window.makeKeyAndVisible()
        try await Task.sleep(for: .seconds(wait))
        XCTAssertEqual(dashboard.phase == .signIn, false, "the session was taken")
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        window.rootViewController?.dismiss(animated: false)
        window.isHidden = true
        try XCTUnwrap(image.pngData()).write(to: folder.appendingPathComponent("live-\(name)-\(dark ? "dark" : "light")\(size == .large ? "" : "-\(size)").png"))
    }

    private struct Presenter: View {
        let request: MetricRequest
        @State private var shown: MetricRequest?

        var body: some View {
            Palette.page.ignoresSafeArea()
                .sheet(item: $shown) { MetricSheetView(request: $0) }
                .onAppear { shown = request }
        }
    }

    func testTheSheetsAgainstTheServer() async throws {
        let cases: [(MetricRequest, String)] = [
            (MetricRequest(key: .hrv, section: "Your signals", page: .vitals), "hrv"),
            (MetricRequest(key: .restingHr, section: "Your signals", page: .vitals, range: .week), "rhr-week"),
            (MetricRequest(key: .steps, section: "Body", page: .activity, range: .day), "steps-day"),
            (MetricRequest(key: .steps, section: "Your signals", page: .activity), "steps"),
            (MetricRequest(key: .heartRate, section: "Body", page: .vitals), "heart-rate"),
            (MetricRequest(key: .sleepHours, section: "Your signals", page: .sleep, range: .year), "sleep-year"),
            (MetricRequest(key: .sleepEfficiency, section: "Sleep", page: AppRoute(.sleep, query: ["tab": "trends"])), "sleep-efficiency"),
            (MetricRequest(key: .glucose, section: "Body", page: .body), "glucose"),
            (MetricRequest(key: .leanMass, section: "Body", page: .body), "lean-mass"),
            (MetricRequest(key: .vo2max, section: "Body", page: AppRoute(.body, query: ["tab": "cardiovascular"])), "vo2max"),
            (MetricRequest(key: .recovery, section: "Your signals", page: AppRoute(.body, query: ["tab": "recovery"])), "recovery"),
        ]
        for (request, name) in cases {
            try await show(request, name)
            try await show(request, name, dark: true)
        }
        try await show(cases[0].0, "hrv", size: .accessibility5)
        try await show(cases[3].0, "steps", size: .accessibility5)
    }
}
