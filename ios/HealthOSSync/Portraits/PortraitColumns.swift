import SwiftUI

// How many to a row inside Profile's two open-in-place cards (duo/design.md §9c, slice F): the portrait studio's tiles
// and the age-group comparison's measurements. These are grids inside a card, so they keep their own counts (P5) and
// work them out from the width the card gives them, in the same layout pass (a Layout, no measuring a pass late).
// Nothing here changes any iPhone: every iPhone's card is compact and under the widths where a count would change.

/// The studio's tiles (src/styles/portraits.css .portrait-grid): two to a row on the phone, as the web's
/// `repeat(2, minmax(0, 1fr))` at ≤560 px, and one at the accessibility text sizes. Wider (the medium and wide bands), as
/// many tiles of at least 156 pt as fit, the web's `repeat(auto-fill, minmax(156px, 1fr))`, rounded down to an even count
/// so a row never ends on a lone tile beside a fold (Apple's even counts), and never fewer than two.
enum PortraitTileColumns {
    /// The web's minmax(156px).
    static let minTile: CGFloat = 156
    /// .portrait-grid's gap.
    static let spacing: CGFloat = 10

    static func count(width: CGFloat, band: DuoBand, accessibility: Bool) -> Int {
        if accessibility { return 1 }
        guard band > .compact else { return 2 }
        let fit = Int(((width + spacing) / (minTile + spacing)).rounded(.down))
        return max(2, fit - fit % 2)
    }
}

/// The comparison's measurements (src/styles/profile.css .profile-peers): the web's `repeat(auto-fill, minmax(300px,
/// 1fr))`, which is one to a row on every iPhone and on the Duo upright. In one of DuoPanes' panes (the open Duo's wide
/// layout, decisions.md Q5: "two columns on the right side") two to a row, as long as each is at least as wide as a
/// portrait tile beside it (156) and the text isn't an accessibility size.
enum PeerColumns {
    /// The web's minmax(300px).
    static let minRow: CGFloat = 300
    /// .profile-peers' gap.
    static let spacing: CGFloat = 10

    static func count(width: CGFloat, inPane: Bool, typeSize: DynamicTypeSize) -> Int {
        if typeSize.isAccessibilitySize { return 1 }
        if inPane {
            return DuoPaneColumns.count(2, width: width, spacing: spacing, minColumn: PortraitTileColumns.minTile, typeSize: typeSize)
        }
        return max(1, Int(((width + spacing) / (minRow + spacing)).rounded(.down)))
    }
}

/// Equal columns, `columns(width)` of them, rows as tall as their tallest cell (each cell is offered its row's height,
/// so one that fills it lines up with its neighbours, as a CSS grid's rows stretch). A short last row keeps the column
/// width (the web's auto-fill leaves the space empty).
struct CardColumnsLayout: Layout {
    var spacing: CGFloat
    var columns: (CGFloat) -> Int

    /// Each cell's x and width, row by row, for `count` cells in a row `width` wide.
    func rows(count: Int, width: CGFloat) -> [[DuoColumnsLayout.Slot]] {
        let n = max(1, columns(width))
        let w = max(0, (width - spacing * CGFloat(n - 1)) / CGFloat(n))
        return stride(from: 0, to: count, by: n).map { start in
            (start..<min(start + n, count)).map { i in DuoColumnsLayout.Slot(x: CGFloat(i - start) * (w + spacing), width: w) }
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? idealWidth(subviews)
        let heights = rowHeights(rows(count: subviews.count, width: width), subviews)
        return CGSize(width: width, height: heights.reduce(0, +) + spacing * CGFloat(max(0, heights.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = rows(count: subviews.count, width: bounds.width)
        var index = 0
        var y = bounds.minY
        for (row, height) in zip(rows, rowHeights(rows, subviews)) {
            for slot in row {
                subviews[index].place(at: CGPoint(x: bounds.minX + slot.x, y: y), anchor: .topLeading,
                                      proposal: ProposedViewSize(width: slot.width, height: height))
                index += 1
            }
            y += height + spacing
        }
    }

    private func rowHeights(_ rows: [[DuoColumnsLayout.Slot]], _ subviews: Subviews) -> [CGFloat] {
        var index = 0
        return rows.map { row in
            row.reduce(CGFloat(0)) { tallest, slot in
                defer { index += 1 }
                return max(tallest, subviews[index].sizeThatFits(ProposedViewSize(width: slot.width, height: nil)).height)
            }
        }
    }

    /// With no width offered (a drawing at its ideal size): the widest cell, once.
    private func idealWidth(_ subviews: Subviews) -> CGFloat {
        subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
    }
}
