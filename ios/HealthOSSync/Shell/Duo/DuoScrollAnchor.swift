import SwiftUI

// iPhone Duo (§4): a page keeps its place across a fold in `Dashboard.scrollAnchors`, in memory only, by the id of the
// row at the top. A fold that rebuilds the scroll view (DuoPanes going between one column and two panes) comes back to
// that row; an anchor only in the other pane falls back to the top.

extension View {
    /// On a page's DuoScroll (on a DuoPanes page, the primary pane's): .scrollPosition(id:anchor: .top) bound to
    /// Dashboard.scrollAnchors[page]. The content is one flat stack of rows with String ids (`.id("home.week")`),
    /// marked .scrollTargetLayout(). Put it on the DuoScroll (or the DuoPanes); it reaches only that page's own scroll
    /// view, never a scroll view nested inside it.
    func duoScrollAnchor(_ page: AppPage) -> some View {
        environment(\.duoScrollAnchorPage, page)
    }
}

private struct DuoScrollAnchorPageKey: EnvironmentKey { static let defaultValue: AppPage? = nil }

extension EnvironmentValues {
    /// The page whose scroll anchor the next DuoScroll keeps (duoScrollAnchor); DuoScroll clears it for what's inside.
    var duoScrollAnchorPage: AppPage? {
        get { self[DuoScrollAnchorPageKey.self] }
        set { self[DuoScrollAnchorPageKey.self] = newValue }
    }
}

/// DuoScroll's anchor: the scroll position by row id, kept in the Dashboard (nothing when there's no page or no
/// Dashboard in the environment). The position is the scroll view's own state, brought back from the Dashboard once the
/// scroll view is up: a VStack's scroll view ignores the position it starts with (only a lazy stack's honours it), so a
/// new scroll view after a fold comes back to the row only this way. Each row it settles on is written back.
struct DuoScrollAnchoring: ViewModifier {
    let page: AppPage?
    @Environment(Dashboard.self) private var dashboard: Dashboard?
    @State private var position: String?

    func body(content: Content) -> some View {
        if let page, let dashboard {
            content
                .scrollPosition(id: $position, anchor: .top)
                .onAppear { position = dashboard.scrollAnchors[page] }
                .onChange(of: position) { _, row in
                    if let row, dashboard.scrollAnchors[page] != row { dashboard.scrollAnchors[page] = row }
                }
        } else {
            content
        }
    }
}
