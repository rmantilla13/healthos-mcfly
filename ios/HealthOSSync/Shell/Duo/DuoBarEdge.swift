import SwiftUI

// iPhone Duo: what the system says, read where it's used. Every iOS 27.1 read of the app lives here (D15): the vertical
// bar's edge (toolbarVerticalEdge), the container margins and the reserved regions. Each is copied into plain values
// (HorizontalEdge?, DuoMargins, CGRect), so no iOS 17 type ever stores a 27.1 one. Pages never call these; the scopes
// (DuoScope, DuoFloatingRow) do.
//
// Still to come (F1): readsDuoBarEdge()'s Debug log (-duoLogDisplay), the fold overlay (-duoShowFold) and
// -duoVerticalBar disabled for G0's control run.

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
    /// `duoBarEdge`, for anything outside a scope. Every scope reads its own as well, in its own context.
    /// F1 adds, in Debug builds: -duoLogDisplay YES (the window size, interface orientation, size classes, bar edge,
    /// every .division and .occlusion region and the hinge, on every change), -duoShowFold YES (an active fold drawn in
    /// red) and -duoVerticalBar disabled (G0's control run).
    func readsDuoBarEdge() -> some View {
        DuoBarEdgeReader { edge in self.environment(\.duoBarEdge, edge) }
    }
}
