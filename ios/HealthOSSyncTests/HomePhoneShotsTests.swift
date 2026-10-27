import SwiftUI
import UIKit
import XCTest
@testable import HealthOSSync

// Home on an iPhone 18 Pro (402×874, its safe area: 62 top, 34 bottom), drawn screen by screen from the top to the end,
// light and dark, at the default text size and AX5, with the digital human and with "Just the statistics", from the
// local demo server's made-up day (Fixtures/summary.json and status.json). For comparing Home's phone layout pixel for
// pixel before and after a change (the iPhone Duo pass must leave it as it was). Each screen is drawn three times a
// moment apart, and what moved between them (the callouts' beating dots, McFly's orb) is written as a mask beside it,
// so a comparison can leave out what moves on its own. Only with TEST_RUNNER_HOME_PHONE_SHOTS=<folder>; skipped
// otherwise. Nothing reaches a server: every request is answered here as a server without the route. Slice B owns this.

private final class HomePhoneStub: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"error":"Not found"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
final class HomePhoneShotsTests: XCTestCase {
    private static let size = CGSize(width: 402, height: 874)
    private static let insets = EdgeInsets(top: 62, leading: 0, bottom: 34, trailing: 0)

    private func data(_ name: String) throws -> Data {
        let url = Bundle(for: Self.self).url(forResource: name, withExtension: "json")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name).json")
        return try Data(contentsOf: url)
    }

    private func status(perspective: String?) throws -> ServerStatus {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data("status")) as? [String: Any])
        var settings = try XCTUnwrap(json["settings"] as? [String: Any])
        settings["hiddenCards"] = [String]()
        settings["shownCards"] = ["home.load", "home.activity", "home.timeline", "home.week", "home.insights"]
        settings["familySharing"] = true
        settings["familyNoticeSeen"] = false
        if let perspective { settings["perspective"] = perspective }
        json["settings"] = settings
        return try JSONDecoder().decode(ServerStatus.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private var reads: HomeReads {
        HomeReads(readFood: { _ in nil },
                  readJournal: { _ in try JSONDecoder().decode(JournalData.self, from: Data(#"{"today":"2026-10-16","entries":[]}"#.utf8)) },
                  readCutout: { _, _ in nil })
    }

    func testHomeOnThePhoneScreenByScreen() async throws {
        guard let path = ProcessInfo.processInfo.environment["HOME_PHONE_SHOTS"], !path.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_HOME_PHONE_SHOTS to a folder to draw Home on the phone.")
        }
        let folder = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        APIClient.answering(with: [HomePhoneStub.self])
        defer { APIClient.answering(with: []) }
        for perspective in [nil, "stats"] as [String?] {
            for dark in [false, true] {
                for size: DynamicTypeSize in [.large, .accessibility5] {
                    try await shoot(perspective: perspective, dark: dark, size: size, folder: folder)
                }
            }
        }
    }

    private func shoot(perspective: String?, dark: Bool, size: DynamicTypeSize, folder: URL) async throws {
        let dashboard = Dashboard()
        dashboard.apply(status: try status(perspective: perspective))
        let summary = try JSONDecoder().decode(Summary.self, from: data("summary"))
        let page = TodayContent(summary: summary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.page)
            .environment(dashboard)
            .environment(AppModel())
            .environment(\.homeReads, reads)
            .environment(\.dynamicTypeSize, size)
            .safeAreaPadding(Self.insets)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let controller = UIHostingController(rootView: AnyView(page))
        controller.safeAreaRegions = []
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: Self.size)
        window.overrideUserInterfaceStyle = dark ? .dark : .light
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await settle(window, seconds: 1.5)
        let scroll = try XCTUnwrap(Self.verticalScroll(in: window), "Home's scroll view")
        let start = scroll.contentOffset.y
        let end = max(start, scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height)
        let name = "home-\(perspective ?? "digital")-\(dark ? "dark" : "light")\(size == .large ? "" : "-\(size)")"
        var offset = start, part = 1
        while true {
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: offset), animated: false)
            try await settle(window, seconds: 0.6)
            var images: [CGImage] = []
            for _ in 0..<3 {
                images.append(try XCTUnwrap(Self.draw(window).cgImage))
                try await Task.sleep(for: .milliseconds(230))
            }
            let file = "\(name)-\(part)"
            try XCTUnwrap(UIImage(cgImage: images[0]).pngData()).write(to: folder.appendingPathComponent("\(file).png"))
            if let moving = Self.moving(images) {
                try XCTUnwrap(UIImage(cgImage: moving).pngData()).write(to: folder.appendingPathComponent("\(file).moving.png"))
            }
            if offset >= end { break }
            offset = min(end, offset + 600)
            part += 1
        }
    }

    private func settle(_ window: UIWindow, seconds: Double) async throws {
        for _ in 0..<3 {
            window.rootViewController?.view.setNeedsLayout()
            window.rootViewController?.view.layoutIfNeeded()
            try await Task.sleep(for: .seconds(seconds / 3))
        }
    }

    private static func draw(_ window: UIWindow) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    /// The page's own scroll view: the tallest vertical one.
    private static func verticalScroll(in view: UIView) -> UIScrollView? {
        var found: [UIScrollView] = []
        func walk(_ v: UIView) {
            if let s = v as? UIScrollView, !(v is UITextView), s.contentSize.height > s.bounds.height { found.append(s) }
            v.subviews.forEach(walk)
        }
        walk(view)
        return found.max { $0.contentSize.height < $1.contentSize.height }
    }

    private static func pixels(_ image: CGImage) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: image.width * image.height * 4)
        if let ctx = CGContext(data: &px, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return px
    }

    /// White where the drawings differ (what moves on its own), black elsewhere; nil when nothing moved.
    private static func moving(_ images: [CGImage]) -> CGImage? {
        guard let first = images.first else { return nil }
        let base = pixels(first)
        var mask = [UInt8](repeating: 0, count: first.width * first.height)
        var any = false
        for other in images.dropFirst() {
            let px = pixels(other)
            guard px.count == base.count else { continue }
            for i in 0..<mask.count where mask[i] == 0 {
                let j = i * 4
                if px[j] != base[j] || px[j + 1] != base[j + 1] || px[j + 2] != base[j + 2] || px[j + 3] != base[j + 3] {
                    mask[i] = 255
                    any = true
                }
            }
        }
        guard any, let ctx = CGContext(data: &mask, width: first.width, height: first.height, bitsPerComponent: 8, bytesPerRow: first.width,
                                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        return ctx.makeImage()
    }
}
