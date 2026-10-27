import SwiftUI
import UIKit
import XCTest
@testable import HealthOSSync

/// Profile on the test iPhone itself (not a Duo state): the page as More shows it, in its navigation stack at the
/// iPhone's own size and safe area, drawn a screen at a time from the top to the bottom, light and dark, at the default
/// text size and AX5. Slice D's Duo pass must leave every other iPhone exactly as it was, so these pictures are drawn
/// before and after it and compared pixel for pixel (TEST_RUNNER_DUO_SHOTS=<folder> writes
/// `phone-<n>-<light|dark>[-<size>].png`). Without the folder it only checks something was drawn.
///
/// The person is made up (Sam, sam@example.test) and nothing reaches a server.
@MainActor
final class ProfilePhoneTests: XCTestCase {
    private var savedServer: String?

    override func setUp() async throws {
        savedServer = UserDefaults.standard.string(forKey: "serverURL")
        Config.serverText = "http://127.0.0.1:9"
    }

    override func tearDown() async throws {
        if let savedServer { UserDefaults.standard.set(savedServer, forKey: "serverURL") } else { UserDefaults.standard.removeObject(forKey: "serverURL") }
    }

    func testThePhonesProfile() async throws {
        for size: DynamicTypeSize in [.large, .accessibility5] {
            for dark in [false, true] { try await draw(dark: dark, size: size) }
        }
    }

    /// The question "Upload all history again" asks, as the phone shows it (an action sheet), drawn with the page under
    /// it: `phone-dialog-<light|dark>.png`. Before slice D's pass it was attached to the page; now to its button.
    func testThePhonesUploadQuestion() async throws {
        for dark in [false, true] {
            let (window, controller, scroll) = try await host(dark: dark, size: .large)
            defer { window.isHidden = true }
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x,
                                            y: scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height), animated: false)
            try await settle(controller)
            var elements: [NSObject] = []
            try await DuoAccessibility.whileOn {
                try await Task.sleep(for: .milliseconds(300))
                DuoAccessibility.walk(window, into: &elements)
            }
            let button = try XCTUnwrap(elements.first { $0.accessibilityLabel == "Upload all history again" && $0.accessibilityTraits.contains(.button) })
            XCTAssertTrue(button.accessibilityActivate())
            try await Task.sleep(for: .seconds(1.5))
            XCTAssertNotNil(controller.presentedViewController, "the question is up")
            let image = Self.image(window)
            if let path = ProcessInfo.processInfo.environment["DUO_SHOTS"], !path.isEmpty {
                try? image.pngData()?.write(to: URL(fileURLWithPath: path).appendingPathComponent("phone-dialog-\(dark ? "dark" : "light").png"))
            }
            controller.presentedViewController?.dismiss(animated: false)
        }
    }

    private func host(dark: Bool, size: DynamicTypeSize) async throws -> (UIWindow, UIViewController, UIScrollView) {
        let d = Dashboard()
        d.authMode = "required"
        d.account = AuthState.User(id: "u-sam", email: "sam@example.test", name: "Sam", role: "member")
        d.phase = .ready
        let settings = #"{"name":"Sam","stepGoal":10000,"units":"metric","perspective":"digital","age":40,"peerComparison":true,"#
            + #""hiddenCards":[],"familySharing":true,"cycleTracking":false,"sex":"female","nutrition":true,"nutritionNumbers":"all"}"#
        d.apply(status: try JSONDecoder().decode(ServerStatus.self, from: Data(#"{"user":{"id":"u-sam","email":"sam@example.test"},"settings":\#(settings)}"#.utf8)))
        let page = NavigationStack {
            ProfileScreen().navigationTitle("Profile").navigationBarTitleDisplayMode(.inline)
        }
        .environment(d).environment(AppModel()).environment(\.dynamicTypeSize, size)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = dark ? .dark : .light
        let controller = UIHostingController(rootView: page)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        try await settle(controller)
        let scroll = try XCTUnwrap(DuoScrollTests.verticalScrollViews(in: window).first, "the page scrolls")
        return (window, controller, scroll)
    }

    private func draw(dark: Bool, size: DynamicTypeSize) async throws {
        let d = Dashboard()
        d.authMode = "required"
        d.account = AuthState.User(id: "u-sam", email: "sam@example.test", name: "Sam", role: "member")
        d.phase = .ready
        let settings = #"{"name":"Sam","stepGoal":10000,"units":"metric","perspective":"digital","age":40,"peerComparison":true,"#
            + #""hiddenCards":[],"familySharing":true,"cycleTracking":false,"sex":"female","nutrition":true,"nutritionNumbers":"all"}"#
        d.apply(status: try JSONDecoder().decode(ServerStatus.self, from: Data(#"{"user":{"id":"u-sam","email":"sam@example.test"},"settings":\#(settings)}"#.utf8)))
        let page = NavigationStack {
            ProfileScreen()
                .navigationTitle("Profile")
                .navigationBarTitleDisplayMode(.inline)
        }
        .environment(d)
        .environment(AppModel())
        .environment(\.dynamicTypeSize, size)

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = dark ? .dark : .light
        let controller = UIHostingController(rootView: page)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await settle(controller)

        let scroll = try XCTUnwrap(DuoScrollTests.verticalScrollViews(in: window).first, "the page scrolls")
        let top = -scroll.adjustedContentInset.top
        let end = scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height
        let step = scroll.bounds.height - scroll.adjustedContentInset.top - scroll.adjustedContentInset.bottom - 120
        var y = top
        var n = 1
        while true {
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: min(y, end)), animated: false)
            try await settle(controller)
            let image = Self.image(window)
            XCTAssertEqual(image.size, window.bounds.size)
            write(image, n: n, dark: dark, size: size)
            if y >= end || n >= 30 { break }
            y += step
            n += 1
        }
    }

    private func settle(_ controller: UIViewController) async throws {
        for _ in 0..<3 {
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    private static func image(_ window: UIWindow) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    private func write(_ image: UIImage, n: Int, dark: Bool, size: DynamicTypeSize) {
        guard let path = ProcessInfo.processInfo.environment["DUO_SHOTS"], !path.isEmpty else { return }
        let folder = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suffix = size == .large ? "" : "-\(size)"
        try? image.pngData()?.write(to: folder.appendingPathComponent(String(format: "phone-%02d-%@%@.png", n, dark ? "dark" : "light", suffix)))
    }
}
