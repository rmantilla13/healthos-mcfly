import SwiftUI
import UIKit
import XCTest
@testable import HealthOSSync

/// Nutrition on an iPhone that isn't a Duo, drawn whole (every view's full height, and + 's menu), against a stub server
/// with made-up answers, so the same test can draw it before and after a change and the pictures be compared pixel for
/// pixel (the phone must look the same, design §0). Only with TEST_RUNNER_NUTRITION_PHONE_SHOTS=<folder>; skipped
/// otherwise. It uses nothing newer than the page's own types, so it builds on the code before the Duo pass too.
@MainActor
final class NutritionPhoneShotsTests: XCTestCase {
    private var folder: URL!
    private var savedServer: String?
    private var server: AIStubServer!

    override func setUp() async throws {
        guard let path = ProcessInfo.processInfo.environment["NUTRITION_PHONE_SHOTS"], !path.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_NUTRITION_PHONE_SHOTS to a folder to draw Nutrition on a phone.")
        }
        folder = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        savedServer = UserDefaults.standard.string(forKey: "serverURL")
        let totals = String(decoding: try fixture("nutrition-all"), as: UTF8.self)
        server = try await AIStubServer.start([
            "POST /api/nutrition/log/day": .json(200, NutritionMadeUp.dayJSON),
            "GET /api/nutrition/log": .json(200, NutritionMadeUp.logJSON),
            "GET /api/nutrition": .json(200, totals),
        ])
        Config.serverText = server.url.absoluteString
    }

    override func tearDown() async throws {
        server?.stop()
        if let savedServer { UserDefaults.standard.set(savedServer, forKey: "serverURL") } else { UserDefaults.standard.removeObject(forKey: "serverURL") }
    }

    private func fixture(_ name: String) throws -> Data {
        let url = Bundle(for: Self.self).url(forResource: name, withExtension: "json")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name).json")
        return try Data(contentsOf: url)
    }

    private func dashboard() throws -> Dashboard {
        let d = Dashboard()
        d.phase = .ready
        d.apply(status: try JSONDecoder().decode(ServerStatus.self, from: Data(#"{"settings":{"nutrition":true,"nutritionNumbers":"all"}}"#.utf8)))
        return d
    }

    /// Each view drawn at its whole height, 402 wide, light and dark, at the default size and AX5.
    func testEveryViewWhole() async throws {
        for tab in NutritionTab.allCases {
            for dark in [false, true] {
                for size: DynamicTypeSize in [.large, .accessibility5] {
                    try await draw(tab, dark: dark, size: size, height: size == .large ? 2400 : 6000)
                }
            }
        }
    }

    /// + 's menu over Today, as tall as its rows.
    func testThePlusMenu() async throws {
        for dark in [false, true] {
            for size: DynamicTypeSize in [.large, .accessibility5] {
                try await draw(.today, dark: dark, size: size, height: 874, menu: true)
            }
        }
    }

    private func draw(_ tab: NutritionTab, dark: Bool, size: DynamicTypeSize, height: CGFloat, menu: Bool = false) async throws {
        let d = try dashboard()
        if tab != .today { d.open(AppRoute(.nutrition, query: ["tab": tab.rawValue])) }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let host = UIHostingController(rootView: AnyView(NutritionScreen().environment(d).environment(\.dynamicTypeSize, size)))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: height)
        window.overrideUserInterfaceStyle = dark ? .dark : .light
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            host.presentedViewController?.dismiss(animated: false)
            window.isHidden = true
        }
        try await Task.sleep(for: .milliseconds(1800))
        if menu {
            try await HostedAccessibilityShots.activate("nutritionPlus", in: host.view)
            try await Task.sleep(for: .milliseconds(1200))
        }
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let name = "\(menu ? "plus-menu" : tab.rawValue)-\(dark ? "dark" : "light")\(size == .large ? "" : "-ax5").png"
        try XCTUnwrap(image.pngData()).write(to: folder.appendingPathComponent(name))
    }
}

/// Activates one element by its identifier, with the simulator's accessibility automation on while it reads.
@MainActor
enum HostedAccessibilityShots {
    static func activate(_ id: String, in view: UIView) async throws {
        let root = ProcessInfo.processInfo.environment["IPHONE_SIMULATOR_ROOT"] ?? ""
        guard let lib = dlopen(root + "/usr/lib/libAccessibility.dylib", RTLD_LOCAL) ?? dlopen("/usr/lib/libAccessibility.dylib", RTLD_LOCAL),
              let get = dlsym(lib, "_AXSAutomationEnabled"), let set = dlsym(lib, "_AXSSetAutomationEnabled") else { return XCTFail("no libAccessibility") }
        let enabled = unsafeBitCast(get, to: (@convention(c) () -> Int32).self)
        let setEnabled = unsafeBitCast(set, to: (@convention(c) (Int32) -> Void).self)
        let before = enabled()
        setEnabled(1)
        defer { setEnabled(before) }
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(50))
            if let found = find(id, in: view) {
                XCTAssertTrue(found.accessibilityActivate())
                return
            }
        }
        XCTFail("\(id) not found")
    }

    private static func find(_ id: String, in o: NSObject) -> NSObject? {
        let sel = NSSelectorFromString("accessibilityIdentifier")
        if o.isAccessibilityElement, o.responds(to: sel), (o.perform(sel)?.takeUnretainedValue() as? String) == id { return o }
        let n = o.accessibilityElementCount()
        if n != NSNotFound, n > 0 {
            for i in 0..<n { if let e = o.accessibilityElement(at: i) as? NSObject, let f = find(id, in: e) { return f } }
        }
        for sub in (o as? UIView)?.subviews ?? [] { if let f = find(id, in: sub) { return f } }
        return nil
    }
}

/// Made-up answers for Nutrition's drawn tests: a day of two entries, and the Log's two weeks with them.
enum NutritionMadeUp {
    static let can = #"{"estimate":true,"usda":false,"estimateProvider":"anthropic","estimateSource":"shared","voice":false}"#
    static let entries = #"""
    [{"id":"e1","date":"2026-10-24","time":"08:10","name":"Greek yogurt","portion":"1 cup (245 g)","quantity":1,"values":{"energy_kcal":146,"protein_g":20,"carbs_g":9,"fat_g":0.9},"method":"barcode","ref":"off:5201054017371","version":1,"origin":"iphone"},
     {"id":"e2","date":"2026-10-24","time":"12:30","name":"Lentil soup","portion":"1 bowl","quantity":1.5,"values":{"energy_kcal":340,"protein_g":18,"carbs_g":45,"fat_g":6,"fiber_g":12},"method":"estimate","ref":null,"version":2,"origin":"web"}]
    """#
    static let dayJSON = #"{"numbers":"all","today":"2026-10-24","date":"2026-10-24","entries":\#(entries),"drafts":[],"draftBatch":null,"balance":{"energy_kcal":486,"protein_g":38,"carbs_g":54,"fat_g":6.9,"fiber_g":12},"countedApp":"healthOS","can":\#(can)}"#
    static let logJSON = #"{"enabled":true,"numbers":"all","today":"2026-10-24","start":"2026-10-11","end":"2026-10-24","entries":\#(entries),"drafts":[],"draftBatch":null,"can":\#(can)}"#
}
