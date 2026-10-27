import SwiftUI

/// Two blocks that scroll with the page, a full-width child of the page's content: side by side when duoFold splits
/// (each half compact, with no fold), split on the fold; stacked otherwise. One AnyLayout, so neither is rebuilt. Side
/// by side, each half is offered the taller one's height, as the web's pairs stretch.
///
/// Inside one of DuoPanes' panes (decisions.md Q5) a pair stacks, as a chart pair should there (charts span the pane).
/// `paneSideBySide: true` puts a pair of small cards side by side in a pane instead, as long as each half is at least
/// 170 wide and the text isn't an accessibility size (DuoPaneColumns). It changes nothing outside a pane.
///
///     DuoPair { NutritionCard() } second: { JournalCard() }
///     DuoPair(paneSideBySide: true) { NutritionCard() } second: { JournalCard() }   // two small cards, 2-up in a pane
struct DuoPair<First: View, Second: View>: View {
    private let spacing: CGFloat
    private let paneSideBySide: Bool
    private let first: First
    private let second: Second
    @Environment(\.duoFold) private var fold
    @Environment(\.duoBand) private var band
    @Environment(\.duoInPane) private var inPane
    @Environment(\.duoContentWidth) private var contentWidth
    @Environment(\.dynamicTypeSize) private var typeSize

    init(spacing: CGFloat = 14, paneSideBySide: Bool = false, @ViewBuilder first: () -> First, @ViewBuilder second: () -> Second) {
        self.spacing = spacing
        self.paneSideBySide = paneSideBySide
        self.first = first()
        self.second = second()
    }

    var body: some View {
        let split = fold.splits
        let paired = !split && inPane && paneSideBySide
            && DuoPaneColumns.count(2, width: contentWidth, spacing: spacing, typeSize: typeSize) == 2
        let layout = split
            ? AnyLayout(DuoColumnsLayout(columns: 2, spacing: spacing, fold: fold.span, loneSpans: false))
            : paired
                ? AnyLayout(DuoColumnsLayout(columns: 2, spacing: spacing, loneSpans: false))
                : AnyLayout(VStackLayout(alignment: .leading, spacing: spacing))
        layout {
            first
            second
        }
        .environment(\.duoFold, .none)
        .environment(\.duoBand, Self.halfBand(split: split || paired, band: band))
        .environment(\.duoInPane, false)
    }

    /// The band inside each half: compact side by side (each half is one side of the fold, or one column of a pane), the
    /// page's when stacked.
    static func halfBand(split: Bool, band: DuoBand) -> DuoBand { split ? .compact : band }
}
