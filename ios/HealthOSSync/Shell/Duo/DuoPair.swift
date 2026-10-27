import SwiftUI

/// Two blocks that scroll with the page, a full-width child of the page's content: side by side when duoFold splits
/// (each half compact, with no fold), split on the fold; stacked otherwise. One AnyLayout, so neither is rebuilt. Side
/// by side, each half is offered the taller one's height, as the web's pairs stretch.
///
///     DuoPair { NutritionCard() } second: { JournalCard() }
struct DuoPair<First: View, Second: View>: View {
    private let spacing: CGFloat
    private let first: First
    private let second: Second
    @Environment(\.duoFold) private var fold
    @Environment(\.duoBand) private var band

    init(spacing: CGFloat = 14, @ViewBuilder first: () -> First, @ViewBuilder second: () -> Second) {
        self.spacing = spacing
        self.first = first()
        self.second = second()
    }

    var body: some View {
        let split = fold.splits
        let layout = split
            ? AnyLayout(DuoColumnsLayout(columns: 2, spacing: spacing, fold: fold.span, loneSpans: false))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: spacing))
        layout {
            first
            second
        }
        .environment(\.duoFold, .none)
        .environment(\.duoBand, Self.halfBand(split: split, band: band))
    }

    /// The band inside each half: compact side by side (each half is one side of the fold), the page's when stacked.
    static func halfBand(split: Bool, band: DuoBand) -> DuoBand { split ? .compact : band }
}
