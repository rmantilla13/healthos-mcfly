import SwiftUI
import os

// iPhone Duo: what the system says, read where it's used. Every iOS 27.1 read of the app lives here (D15): the vertical
// bar's edge (toolbarVerticalEdge), the container margins and the reserved regions. Each is copied into plain values
// (HorizontalEdge?, DuoMargins, CGRect), so no iOS 17 type ever stores a 27.1 one. Pages never call these; the scopes
// (DuoScope, DuoFloatingRow) do.
//
// In Debug builds only (F1, G0's control run, G1 and G2), launch arguments:
// - `-duoLogDisplay YES`: readsDuoBarEdge() logs, on every change, the window size, the interface orientation, the size
//   classes, the bar edge, every .division and .occlusion region (inactive included) and the hinge, as one JSON line,
//   to the app's Documents/duo-display.jsonl and the unified log (subsystem health.mcfly.sync, category duo). Geometry
//   only: nothing of the person.
// - `-duoShowFold YES`: an active fold drawn in red over the app; nothing is drawn while it's inactive.
// - `-duoVerticalBar disabled`: toolbarVerticalBehavior(.disabled) on the shell's TabView (G0's control run).

/// Hands `content` the edge the system would put a vertical bar on, read in `content`'s own context: nil before iOS 27.1
/// and wherever the system never uses a vertical bar. In the same pass, with no state: the 27.1 value is read by a
/// 27.1-only child view, since an iOS 17 view can't hold `@Environment(\.toolbarVerticalEdge)`.
struct DuoBarEdgeReader<Content: View>: View {
    private let content: (HorizontalEdge?) -> Content

    init(@ViewBuilder content: @escaping (HorizontalEdge?) -> Content) {
        self.content = content
    }

    var body: some View {
        if #available(iOS 27.1, *) {
            DuoBarEdgeReading(content: content)
        } else {
            content(nil)
        }
    }
}

@available(iOS 27.1, *)
private struct DuoBarEdgeReading<Content: View>: View {
    let content: (HorizontalEdge?) -> Content
    @Environment(\.toolbarVerticalEdge) private var edge

    var body: some View { content(edge) }
}

/// What iOS 27.1 reports in one GeometryReader's space, as plain values.
struct DuoSystemReading: Equatable {
    /// The container margins (`ContentMarginGuide.container`), read only where a vertical bar is in use.
    var margins: DuoMargins?
    /// The x-span of a vertical `.division` region (inactive included), from the reader's leading edge.
    var division: ClosedRange<CGFloat>?
    var divisionActive = false
    /// A horizontal `.division` region, in the reader's coordinates.
    var horizontalFold: CGRect?
    var horizontalFoldActive = false
    /// The active `.occlusion` regions, in the reader's coordinates.
    var occlusions: [CGRect] = []

    static let nothing = DuoSystemReading()

    /// Reads `proxy` on iOS 27.1 (the default `.mirrors`, so the frames are in a Layout's own coordinates); nothing before.
    /// `occlusions` reads the occlusion regions too (the floating row's).
    static func read(_ proxy: GeometryProxy, barEdge: HorizontalEdge?, occlusions: Bool = false) -> DuoSystemReading {
        guard #available(iOS 27.1, *) else { return .nothing }
        var reading = DuoSystemReading()
        if barEdge != nil {
            let insets = proxy.contentMargins(for: .container, edges: .horizontal)
            reading.margins = DuoMargins(leading: insets.leading, trailing: insets.trailing)
        }
        for region in proxy.reservedRegions(kind: .division, options: .includeInactive) {
            let frame = region.frame
            if frame.height > frame.width {
                guard reading.division == nil else { continue }
                reading.division = DuoFold.rounded(frame.minX)...DuoFold.rounded(frame.maxX)
                reading.divisionActive = region.isActive
            } else if reading.horizontalFold == nil {
                reading.horizontalFold = frame
                reading.horizontalFoldActive = region.isActive
            }
        }
        if occlusions {
            reading.occlusions = proxy.reservedRegions(kind: .occlusion).filter(\.isActive).map(\.frame)
        }
        return reading
    }
}

extension View {
    /// RootView (HealthOSSyncApp.swift), around AppShell: toolbarVerticalEdge from a 27.1-only child view into
    /// `duoBarEdge`, for anything outside a scope (AppShell's More symbol). Every scope reads its own as well, in its own
    /// context. In Debug builds, `-duoLogDisplay YES` logs the display and `-duoShowFold YES` draws an active fold (see
    /// the top of this file).
    func readsDuoBarEdge() -> some View {
        DuoBarEdgeReader { edge in
            self.environment(\.duoBarEdge, edge).modifier(DuoDebugDisplay(barEdge: edge))
        }
    }

    /// AppShell's TabView. Debug builds launched with `-duoVerticalBar disabled` (G0's control run only):
    /// toolbarVerticalBehavior(.disabled), so the iPhone Duo's bars go back to the top and bottom. Nothing otherwise.
    func duoVerticalBarControl() -> some View { modifier(DuoVerticalBarControl()) }
}

private struct DuoVerticalBarControl: ViewModifier {
    func body(content: Content) -> some View {
        #if DEBUG
        if #available(iOS 27.1, *), UserDefaults.standard.string(forKey: "duoVerticalBar") == "disabled" {
            content.toolbarVerticalBehavior(.disabled)
        } else {
            content
        }
        #else
        content
        #endif
    }
}

/// Debug only: `-duoLogDisplay YES` and `-duoShowFold YES` (G1, G2). Over the whole window, ignoring the safe area, so
/// its frames are the window's.
private struct DuoDebugDisplay: ViewModifier {
    let barEdge: HorizontalEdge?

    func body(content: Content) -> some View {
        #if DEBUG
        if DuoDisplayLog.logs || DuoDisplayLog.showsFold {
            content.overlay {
                DuoDisplayWatcher(barEdge: barEdge)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

#if DEBUG
/// What `-duoLogDisplay` writes: one JSON object a line, geometry only.
enum DuoDisplayLog {
    static let logs = UserDefaults.standard.bool(forKey: "duoLogDisplay")
    static let showsFold = UserDefaults.standard.bool(forKey: "duoShowFold")
    private static let logger = Logger(subsystem: "health.mcfly.sync", category: "duo")

    /// Documents/duo-display.jsonl, appended to.
    static var file: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("duo-display.jsonl")
    }

    @MainActor static func write(_ fields: [String: Any]) {
        guard logs else { return }
        var line = fields
        line["time"] = ISO8601DateFormatter().string(from: Date())
        guard let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return }
        logger.notice("DUO \(text, privacy: .public)")
        guard let file else { return }
        let bytes = Data((text + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(bytes)
            try? handle.close()
        } else {
            try? bytes.write(to: file)
        }
    }

    static func rect(_ r: CGRect) -> [String: Double] {
        ["x": Double(r.minX), "y": Double(r.minY), "w": Double(r.width), "h": Double(r.height)]
    }
}

private struct DuoDisplayWatcher: View {
    let barEdge: HorizontalEdge?
    @Environment(\.horizontalSizeClass) private var horizontal
    @Environment(\.verticalSizeClass) private var vertical
    @State private var hinge = "unknown"

    var body: some View {
        GeometryReader { proxy in
            let regions = DuoDebugRegions.read(proxy)
            ZStack(alignment: .topLeading) {
                if DuoDisplayLog.showsFold {
                    ForEach(Array(regions.activeFolds.enumerated()), id: \.offset) { _, fold in
                        Rectangle()
                            .fill(Color.red.opacity(0.45))
                            .frame(width: max(fold.width, 3), height: max(fold.height, 3))
                            .offset(x: fold.width < 3 ? fold.midX - 1.5 : fold.minX, y: fold.height < 3 ? fold.midY - 1.5 : fold.minY)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onChange(of: snapshot(proxy, regions), initial: true) { _, now in DuoDisplayLog.write(now.fields) }
        }
        .modifier(DuoHingeWatcher(hinge: $hinge))
    }

    private func snapshot(_ proxy: GeometryProxy, _ regions: DuoDebugRegions) -> DuoDisplaySnapshot {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first
        return DuoDisplaySnapshot(
            window: proxy.size,
            safeArea: window?.safeAreaInsets ?? .zero,
            orientation: scene.map { Self.name($0.effectiveGeometry.interfaceOrientation) } ?? "unknown",
            horizontal: Self.name(horizontal), vertical: Self.name(vertical),
            barEdge: barEdge.map { $0 == .leading ? "leading" : "trailing" } ?? "none",
            regions: regions, hinge: hinge)
    }

    private static func name(_ o: UIInterfaceOrientation) -> String {
        switch o {
        case .portrait: "portrait"
        case .portraitUpsideDown: "portraitUpsideDown"
        case .landscapeLeft: "landscapeLeft"
        case .landscapeRight: "landscapeRight"
        default: "unknown"
        }
    }

    private static func name(_ c: UserInterfaceSizeClass?) -> String {
        switch c {
        case .compact: "compact"
        case .regular: "regular"
        default: "none"
        }
    }
}

/// The values one line logs; a new line only when one changes.
private struct DuoDisplaySnapshot: Equatable {
    var window: CGSize
    var safeArea: UIEdgeInsets
    var orientation: String
    var horizontal: String
    var vertical: String
    var barEdge: String
    var regions: DuoDebugRegions
    var hinge: String

    var fields: [String: Any] {
        [
            "window": ["w": Double(window.width), "h": Double(window.height)],
            "safeArea": ["top": Double(safeArea.top), "left": Double(safeArea.left), "bottom": Double(safeArea.bottom), "right": Double(safeArea.right)],
            "orientation": orientation,
            "sizeClass": ["horizontal": horizontal, "vertical": vertical],
            "barEdge": barEdge,
            "division": regions.divisions.map { ["frame": DuoDisplayLog.rect($0.frame), "active": $0.active] },
            "divisionFixed": regions.divisionsFixed.map { ["frame": DuoDisplayLog.rect($0.frame), "active": $0.active] },
            "occlusion": regions.occlusions.map { ["frame": DuoDisplayLog.rect($0.frame), "active": $0.active] },
            "hinge": hinge,
        ]
    }
}

/// The reserved regions in the window's points, as plain values (no 27.1 type is stored).
private struct DuoDebugRegions: Equatable {
    struct Region: Equatable { var frame: CGRect; var active: Bool }
    var divisions: [Region] = []
    /// The same, read with `.fixed` (not mirrored for a right-to-left layout).
    var divisionsFixed: [Region] = []
    var occlusions: [Region] = []

    var activeFolds: [CGRect] { divisions.filter(\.active).map(\.frame) }

    static func read(_ proxy: GeometryProxy) -> DuoDebugRegions {
        guard #available(iOS 27.1, *) else { return DuoDebugRegions() }
        func regions(_ kind: ReservedRegion.Kind, _ direction: LayoutDirectionBehavior = .mirrors) -> [Region] {
            proxy.reservedRegions(kind: kind, options: .includeInactive, layoutDirectionBehavior: direction)
                .map { Region(frame: $0.frame, active: $0.isActive) }
        }
        return DuoDebugRegions(divisions: regions(.division), divisionsFixed: regions(.division, .fixed), occlusions: regions(.occlusion))
    }
}

/// The hinge, as a name and an angle ("fullyOpen 180°"), for the log only: no layout reads it (D12).
private struct DuoHingeWatcher: ViewModifier {
    @Binding var hinge: String

    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            content.onHingeChange { _, new in
                guard let h = new.hinge else { hinge = "none"; return }
                let status: String = switch h.status {
                case .closed: "closed"
                case .partiallyOpen: "partiallyOpen"
                case .fullyOpen: "fullyOpen"
                default: "unknown"
                }
                hinge = "\(status) \(Int(h.angle.degrees.rounded()))°"
            }
        } else {
            content
        }
    }
}
#endif
