import SwiftUI

// iPhone Duo (§4): a DuoPanes page keeps its place across a fold. Going between one column and two panes is the one
// thing a fold rebuilds (P14), so DuoPanes hands the row at the top of the scroll view going away, by its id, to the one
// coming: the single column's, or the anchored pane's (`DuoPanes(anchor:)`). The row is DuoPanes' own state, so it goes
// with the page: a page opened again, another day, another person, a tab reset to its root and a sign-out all start at
// the top, as they always have. A plain DuoScroll page needs nothing: its scroll view persists across a fold. A row the
// new scroll view doesn't have (one only in the other pane) leaves it at its top.
//
// The rows are one flat stack with String ids (a ForEach of String ids, or `.id("…")` on fixed rows), marked
// `.scrollTargetLayout()`, in the anchored pane and the single column alike.

/// The row at the top of a DuoPanes page's anchored scroll view, by its id, handed to the scroll view a fold brings.
/// DuoPanes keeps one as its @State. Nothing redraws on it.
@MainActor
final class DuoScrollHandoff {
    var row: String?
}

private struct DuoScrollHandoffKey: EnvironmentKey { static let defaultValue: DuoScrollHandoff? = nil }

extension EnvironmentValues {
    /// Set by DuoPanes on the scroll views that hand its row over (the single column's and the anchored pane's);
    /// DuoScroll reads it, and clears it for what's inside, so a nested scroll view never takes it.
    var duoScrollHandoff: DuoScrollHandoff? {
        get { self[DuoScrollHandoffKey.self] }
        set { self[DuoScrollHandoffKey.self] = newValue }
    }
}

/// DuoScroll's part: the scroll position by row id, written into the handoff as it settles on a row, and brought back
/// from it once the scroll view is up (a VStack's scroll view ignores the position it starts with; only a lazy stack's
/// honours it). Nothing without a handoff.
struct DuoScrollAnchoring: ViewModifier {
    let handoff: DuoScrollHandoff?
    @State private var position: String?

    func body(content: Content) -> some View {
        if let handoff {
            content
                .scrollPosition(id: $position, anchor: .top)
                .onAppear { if let row = handoff.row { position = row } }
                .onChange(of: position) { _, row in
                    if let row { handoff.row = row }
                }
        } else {
            content
        }
    }
}
