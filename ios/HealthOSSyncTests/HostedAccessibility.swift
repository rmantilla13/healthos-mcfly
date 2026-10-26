import SwiftUI
import XCTest

/// Shows a SwiftUI view in a window, as on screen, and hands back its accessibility elements (what VoiceOver reaches, in
/// order), so a test can press a real button with `accessibilityActivate()`, as VoiceOver or a tap would.
///
/// SwiftUI only builds its accessibility elements while the simulator's accessibility automation is on, and that is a
/// setting of the simulator, left on or off by whatever drove its UI last. So this turns it on, through the simulator's
/// own libAccessibility, and puts back what it found when it's done (as MetricSheetTests does).
@MainActor
enum HostedAccessibility {
    static func onScreen(_ view: some View, width: CGFloat = 402, height: CGFloat = 874, run: ([NSObject]) async throws -> Void) async throws {
        let root = ProcessInfo.processInfo.environment["IPHONE_SIMULATOR_ROOT"] ?? ""
        guard let lib = dlopen(root + "/usr/lib/libAccessibility.dylib", RTLD_LOCAL) ?? dlopen("/usr/lib/libAccessibility.dylib", RTLD_LOCAL),
              let get = dlsym(lib, "_AXSAutomationEnabled"), let set = dlsym(lib, "_AXSSetAutomationEnabled") else {
            XCTFail("the simulator's libAccessibility can't be loaded, so what VoiceOver reaches can't be read")
            return
        }
        let enabled = unsafeBitCast(get, to: (@convention(c) () -> Int32).self)
        let setEnabled = unsafeBitCast(set, to: (@convention(c) (Int32) -> Void).self)
        let before = enabled()
        setEnabled(1)
        defer { setEnabled(before) }

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let host = UIHostingController(rootView: view)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: height)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        // Wait for the elements to be built and to settle (the same number twice running), up to three seconds.
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

    /// Each element once: one reached both as a view's element and through its subviews, or from two views over the
    /// same place, is the one element VoiceOver reaches (same label and place on screen).
    private static func walk(_ o: NSObject, into out: inout [NSObject]) {
        if o.isAccessibilityElement, !out.contains(where: { same($0, o) }) { out.append(o) }
        let n = o.accessibilityElementCount()
        if n != NSNotFound, n > 0 {
            for i in 0..<n { if let e = o.accessibilityElement(at: i) as? NSObject { walk(e, into: &out) } }
        }
        for sub in (o as? UIView)?.subviews ?? [] { walk(sub, into: &out) }
    }

    private static func same(_ a: NSObject, _ b: NSObject) -> Bool {
        a === b || (a.accessibilityLabel == b.accessibilityLabel && a.accessibilityFrame == b.accessibilityFrame
            && a.accessibilityValue == b.accessibilityValue)
    }
}
