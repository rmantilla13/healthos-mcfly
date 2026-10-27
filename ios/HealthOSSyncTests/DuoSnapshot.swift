import SwiftUI
import UIKit
import XCTest
@testable import HealthOSSync

// iPhone Duo, layer 2 (duo/design.md §8.2): a view drawn at the Duo's sizes with the fold injected, on the iPhone 18
// Pro's iOS 27.0 simulator, where no iOS 27.1 branch runs. A UIWindow on the test host's scene with a
// UIHostingController, drawn with drawHierarchy (which draws ScrollViews; ImageRenderer skips them). The safe area is
// the Duo's, not the test iPhone's: the host's safeAreaRegions are [] and the root gets `.safeAreaPadding(state.insets)`,
// so a top inset of 0 really is 0. Pages read the state through `duoDisplayOverride`, which each scope converts with
// its own frame, and `duoBarEdge`.
//
// PNGs are written only when TEST_RUNNER_DUO_SHOTS=<folder> is set; otherwise a drawing only asserts that something
// was drawn. Nothing here skips.

/// One of the Duo's drawn states.
enum DuoState: Equatable, CustomStringConvertible {
    /// The outer display, 466×678: compact / regular, the bar trailing (84), bottom 34.
    case outer
    /// The inner display in portrait, 669×951: regular / regular, no bar, bottom 34, the fold horizontal.
    case innerPortrait(foldActive: Bool = false)
    /// The inner display in landscape, 951×669: regular / regular, the bar on `bar`'s edge (84), bottom 34, the fold
    /// vertical. `bar: .leading` is unmeasured (§2.1).
    case innerLandscape(foldActive: Bool = false, bar: HorizontalEdge = .trailing)
    /// One of two apps in Split View, ≈471×669: compact / regular (assumed; M1 records it), 84 on the bar's side.
    case innerSplit(bar: HorizontalEdge)

    /// Every state a page's drawn tests cover (the fold flat), in §8.2's order.
    static let all: [DuoState] = [.outer, .innerPortrait(), .innerLandscape(), .innerLandscape(bar: .leading),
                                  .innerSplit(bar: .leading), .innerSplit(bar: .trailing)]
    /// The states with a vertical fold inside the window, flat and active, for the fold assertion.
    static let folded: [DuoState] = [.innerLandscape(), .innerLandscape(foldActive: true), .innerLandscape(bar: .leading),
                                     .innerLandscape(foldActive: true, bar: .leading)]

    var size: CGSize {
        switch self {
        case .outer: DuoDisplay.outerSize
        case .innerPortrait: DuoDisplay.innerPortraitSize
        case .innerLandscape: DuoDisplay.innerLandscapeSize
        case .innerSplit: DuoDisplay.innerSplitSize
        }
    }

    var horizontalSizeClass: UIUserInterfaceSizeClass {
        switch self {
        case .outer, .innerSplit: .compact
        case .innerPortrait, .innerLandscape: .regular
        }
    }

    var verticalSizeClass: UIUserInterfaceSizeClass { .regular }

    var insets: EdgeInsets {
        switch self {
        case .outer: EdgeInsets(top: 0, leading: 0, bottom: 34, trailing: 84)
        case .innerPortrait: EdgeInsets(top: 0, leading: 0, bottom: 34, trailing: 0)
        case let .innerLandscape(_, bar), let .innerSplit(bar):
            EdgeInsets(top: 0, leading: bar == .leading ? 84 : 0, bottom: 34, trailing: bar == .trailing ? 84 : 0)
        }
    }

    var display: DuoDisplay {
        switch self {
        case .outer: .outer
        case let .innerPortrait(active): .innerPortrait(foldActive: active)
        case let .innerLandscape(active, bar): .innerLandscape(foldActive: active, bar: bar)
        case let .innerSplit(bar): .innerSplit(bar: bar)
        }
    }

    var barEdge: HorizontalEdge? { display.barEdge }

    /// The file name's part for this state (§8.3: outer, portrait, landscape, landscape-bar-leading, split-view…).
    var description: String {
        switch self {
        case .outer: "outer"
        case let .innerPortrait(active): active ? "portrait-fold-active" : "portrait"
        case let .innerLandscape(active, bar):
            "landscape" + (bar == .leading ? "-bar-leading" : "") + (active ? "-fold-active" : "")
        case let .innerSplit(bar): "split-view" + (bar == .leading ? "-bar-leading" : "-bar-trailing")
        }
    }
}

/// What the hosted root reads, so a state can change under the same hosted view (the band-change tests, P4 and P14).
@MainActor @Observable
final class DuoHostBox {
    var state: DuoState
    var typeSize: DynamicTypeSize

    init(state: DuoState, typeSize: DynamicTypeSize) {
        self.state = state
        self.typeSize = typeSize
    }
}

private struct DuoHostRoot<Content: View>: View {
    let box: DuoHostBox
    let content: Content

    var body: some View {
        content
            .environment(\.duoDisplayOverride, box.state.display)
            .environment(\.duoBarEdge, box.state.barEdge)
            .environment(\.dynamicTypeSize, box.typeSize)
            .safeAreaPadding(box.state.insets)
    }
}

/// One view hosted in a window at a Duo state. `set(_:)` changes the state under the same hosted view (its @State and
/// models stay), as a fold does; `image()` draws it; `elements()` reads what VoiceOver reaches.
@MainActor
final class DuoHost {
    let window: UIWindow
    let controller: UIHostingController<AnyView>
    let box: DuoHostBox

    init(_ view: some View, as state: DuoState, dark: Bool = false, typeSize: DynamicTypeSize = .large) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        box = DuoHostBox(state: state, typeSize: typeSize)
        controller = UIHostingController(rootView: AnyView(DuoHostRoot(box: box, content: view)))
        controller.safeAreaRegions = []
        window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = dark ? .dark : .light
        window.rootViewController = controller
        apply(state)
        window.makeKeyAndVisible()
        try await settle()
    }

    /// The same hosted view at another state (and text size), as a fold or a rotation gives it.
    func set(_ state: DuoState, typeSize: DynamicTypeSize? = nil) async throws {
        box.state = state
        if let typeSize { box.typeSize = typeSize }
        apply(state)
        try await settle()
    }

    private func apply(_ state: DuoState) {
        window.frame = CGRect(origin: .zero, size: state.size)
        controller.traitOverrides.horizontalSizeClass = state.horizontalSizeClass
        controller.traitOverrides.verticalSizeClass = state.verticalSizeClass
        controller.view.frame = window.bounds
    }

    /// Fonts, the first layout pass and anything a geometry change sets off.
    func settle() async throws {
        for _ in 0..<3 {
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    func image() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    /// What VoiceOver reaches, each element once, with the simulator's accessibility automation on while reading.
    func elements() async throws -> [NSObject] {
        try await DuoAccessibility.whileOn {
            var out: [NSObject] = [], last = -1
            for _ in 0..<40 {
                try await Task.sleep(for: .milliseconds(50))
                out = []
                DuoAccessibility.walk(controller.view, into: &out)
                if !out.isEmpty, out.count == last { break }
                last = out.count
            }
            return out
        }
    }

    /// The frames (in window points) of the horizontal scroll views that really scroll: content wider than the view.
    func sidewaysScrollers() -> [CGRect] {
        var out: [CGRect] = []
        func walk(_ view: UIView) {
            if let scroll = view as? UIScrollView, !(view is UITextView), scroll.contentSize.width > scroll.bounds.width + 0.5 {
                out.append(scroll.convert(scroll.bounds, to: window))
            }
            view.subviews.forEach(walk)
        }
        walk(window)
        return out
    }

    func close() {
        controller.presentedViewController?.dismiss(animated: false)
        window.isHidden = true
    }
}

/// The simulator's accessibility automation, which SwiftUI needs before it builds accessibility elements (as
/// HostedAccessibility does): on while reading, and put back as it was.
@MainActor
enum DuoAccessibility {
    static func whileOn<T>(_ read: () async throws -> T) async throws -> T {
        let root = ProcessInfo.processInfo.environment["IPHONE_SIMULATOR_ROOT"] ?? ""
        guard let lib = dlopen(root + "/usr/lib/libAccessibility.dylib", RTLD_LOCAL) ?? dlopen("/usr/lib/libAccessibility.dylib", RTLD_LOCAL),
              let get = dlsym(lib, "_AXSAutomationEnabled"), let set = dlsym(lib, "_AXSSetAutomationEnabled") else {
            XCTFail("the simulator's libAccessibility can't be loaded, so what VoiceOver reaches can't be read")
            return try await read()
        }
        let enabled = unsafeBitCast(get, to: (@convention(c) () -> Int32).self)
        let setEnabled = unsafeBitCast(set, to: (@convention(c) (Int32) -> Void).self)
        let before = enabled()
        setEnabled(1)
        defer { setEnabled(before) }
        return try await read()
    }

    /// Each element once (one reached as a view's element and through its subviews is the one element).
    static func walk(_ o: NSObject, into out: inout [NSObject]) {
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

@MainActor
enum DuoSnapshot {
    /// The folder TEST_RUNNER_DUO_SHOTS names, or nil (then nothing is written).
    static var folder: URL? {
        guard let path = ProcessInfo.processInfo.environment["DUO_SHOTS"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Draws `view` as the Duo shows it in `state`, and writes `<name>-<state>-<light|dark>[-<size>].png` when asked.
    /// Asserts that something was drawn, and on the open Duo in landscape that the leading pane didn't have to scroll.
    @discardableResult
    static func draw(_ view: some View, as state: DuoState, dark: Bool = false, typeSize: DynamicTypeSize = .large, name: String,
                     file: StaticString = #filePath, line: UInt = #line) async throws -> UIImage {
        DuoStillPaneLog.scrolled = 0
        let host = try await DuoHost(view, as: state, dark: dark, typeSize: typeSize)
        defer { host.close() }
        let image = host.image()
        write(image, name: name, state: state, dark: dark, typeSize: typeSize)
        XCTAssertEqual(image.size, state.size, "\(name) \(state)", file: file, line: line)
        // The open Duo's leading pane stays put: what a page puts there fits it, short of the accessibility sizes.
        if case .innerLandscape = state, !typeSize.isAccessibilitySize {
            XCTAssertEqual(DuoStillPaneLog.scrolled, 0, "\(name) \(state): the leading pane scrolls at \(typeSize)", file: file, line: line)
        }
        return image
    }

    /// Writes a drawing when TEST_RUNNER_DUO_SHOTS is set (`d-` files, as §8.3 names them, are the page slices' to make).
    static func write(_ image: UIImage, name: String, state: DuoState, dark: Bool = false, typeSize: DynamicTypeSize = .large) {
        guard let folder else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let size = typeSize == .large ? "" : "-\(typeSize)"
        try? image.pngData()?.write(to: folder.appendingPathComponent("\(name)-\(state)-\(dark ? "dark" : "light")\(size).png"))
    }

    /// Every state in `DuoState.all`, light and dark.
    static func drawAll(_ view: some View, name: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        for state in DuoState.all {
            for dark in [false, true] { try await draw(view, as: state, dark: dark, name: name, file: file, line: line) }
        }
    }
}

/// The kit on its own test page (Shell/Duo/DuoTestPage.swift): drawn in every state, the fold checked in the folded
/// ones at default text and AX3, and a band change that keeps the page's state.
@MainActor
final class DuoKitTests: XCTestCase {
    func testTheTestPageDrawsInEveryState() async throws {
        try await DuoSnapshot.drawAll(DuoTestContent(), name: "duo-test-page")
        try await DuoSnapshot.draw(DuoTestContent(), as: .innerLandscape(foldActive: true), name: "duo-test-page")
        try await DuoSnapshot.draw(DuoTestContent(), as: .innerLandscape(), typeSize: .accessibility3, name: "duo-test-page")
        try await DuoSnapshot.draw(DuoTestPanes(), as: .innerLandscape(), name: "duo-test-panes")
        try await DuoSnapshot.draw(DuoTestPanes(), as: .outer, name: "duo-test-panes")
    }

    func testNothingTappableOnTheFoldOfTheTestPage() async throws {
        for state in DuoState.folded {
            for size: DynamicTypeSize in [.large, .accessibility3] {
                try await DuoFoldAssertions.assertNothingTappableOnTheFold(DuoTestContent(), state: state, typeSize: size)
                try await DuoFoldAssertions.assertNothingTappableOnTheFold(DuoTestPanes(), state: state, typeSize: size)
            }
        }
    }

    /// The assertion itself catches a button across the fold.
    func testTheFoldAssertionCatchesAButtonOnTheFold() async throws {
        let wide = DuoPage { _ in DuoScroll { Button("Across") {}.frame(maxWidth: .infinity, minHeight: 44) } }
        let host = try await DuoHost(wide, as: .innerLandscape())
        defer { host.close() }
        let offenders = try await DuoFoldAssertions.offenders(in: host)
        XCTAssertEqual(offenders.count, 1, "\(offenders)")
    }

    /// Page tabs that overflow the leading side scroll there (§2.4): a tab the row clips at the side's edge isn't on the
    /// fold, because only what a sideways row shows counts. The review's two cases: AX3 with the bar trailing, and the
    /// bar leading at default text; and the bar leading at AX3 with the fold active.
    func testClippedPageTabsAreNotOnTheFold() async throws {
        let tabs = ["Overview", "Metabolism", "Heart", "Activity", "Composition", "Recovery"].map { PageTab(id: $0, label: $0) }
        let page = DuoPage { _ in
            DuoScroll {
                VStack(alignment: .leading, spacing: 14) {
                    PageTabs(tabs: tabs, selection: .constant("Overview"), label: "Sections")
                    Text("The page")
                }
                .padding(.vertical, 16)
            }
        }
        let cases: [(DuoState, DynamicTypeSize)] = [(.innerLandscape(), .accessibility3), (.innerLandscape(bar: .leading), .large),
                                                    (.innerLandscape(foldActive: true, bar: .leading), .accessibility3)]
        for (state, size) in cases {
            let host = try await DuoHost(page, as: state, typeSize: size)
            defer { host.close() }
            XCTAssertFalse(host.sidewaysScrollers().isEmpty, "the tabs overflow and scroll in \(state) at \(size)")
            try await DuoFoldAssertions.assertNothingTappableOnTheFold(in: host)
        }
    }

    /// A row that scrolls sideways and itself crosses the fold is exempt (D10), as before.
    func testASidewaysRowAcrossTheFoldIsExempt() async throws {
        let row = DuoPage { _ in
            DuoScroll {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) { ForEach(1...20, id: \.self) { n in Button("Day \(n)") {}.frame(width: 90, height: 44) } }
                }
            }
        }
        let host = try await DuoHost(row, as: .innerLandscape())
        defer { host.close() }
        XCTAssertFalse(host.sidewaysScrollers().isEmpty)
        let offenders = try await DuoFoldAssertions.offenders(in: host)
        XCTAssertEqual(offenders, [])
    }

    /// The page persists across a band change: what's typed stays (P14), on the same hosted view.
    func testTheTestPageKeepsItsStateAcrossABandChange() async throws {
        let host = try await DuoHost(DuoTestContent(), as: .outer)
        defer { host.close() }
        let field = try XCTUnwrap(Self.textField(in: host.window))
        field.becomeFirstResponder()
        field.insertText("kept")
        try await host.settle()
        for state: DuoState in [.innerLandscape(), .innerPortrait(), .outer] {
            try await host.set(state)
            XCTAssertEqual(Self.textField(in: host.window)?.text, "kept", "\(state)")
        }
        field.resignFirstResponder()
    }

    static func textField(in view: UIView) -> UITextField? {
        if let field = view as? UITextField { return field }
        for sub in view.subviews { if let field = textField(in: sub) { return field } }
        return nil
    }
}
