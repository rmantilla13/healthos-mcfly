import SwiftUI

/// A page's body, outside its scroll views. A GeometryReader at its root measures it in the first layout pass. On 27.1
/// it reads the container margins and the .division region in its own coordinates (§3), and sets duoMargins, duoBand
/// and duoFold for `content`. With `side: .leadingOfFold` the whole page keeps left of the fold when it splits: the
/// trailing margin grows to the fold (less the 12 pt clearance), and the band is the leading side's (compact).
/// `maxWidth` caps the content the same way, through the margins (leading-aligned). It persists across every band and
/// fold change: branch on the band only inside its DuoScroll (P14).
///
///     DuoPage { band in
///         DuoScroll {
///             VStack(alignment: .leading, spacing: 14) { … }
///                 .padding(.vertical, 16)
///         }
///     }
struct DuoPage<Content: View>: View {
    private let maxWidth: CGFloat?
    private let side: DuoSide
    private let content: (DuoBand) -> Content

    init(maxWidth: CGFloat? = nil, side: DuoSide = .full, @ViewBuilder content: @escaping (DuoBand) -> Content) {
        self.maxWidth = maxWidth
        self.side = side
        self.content = content
    }

    var body: some View {
        DuoScope(.page(side: side, maxWidth: maxWidth)) { values in content(values.band) }
    }
}

/// The page's own scroll view (used in place of ScrollView for a page's scroll, and for each pane). It insets its
/// content by duoMargins through `.contentMargins(_:_:for: .scrollContent)` (iOS 17), so the scroll view stays full
/// width, card shadows aren't clipped, and the margin strip scrolls. Modifiers nearer a view override those above it
/// (SDK doc), so nested scroll views would inherit the margins: DuoScroll resets them to 0 for everything inside it.
/// Inside DuoPanes, the single column's and the anchored pane's DuoScroll hand their top row to each other when a fold
/// swaps them (Shell/Duo/DuoScrollAnchor.swift); a page's own DuoScroll persists across a fold and needs nothing.
struct DuoScroll<Content: View>: View {
    private let content: Content
    @Environment(\.duoMargins) private var margins
    @Environment(\.duoScrollHandoff) private var handoff

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView {
            content
                .contentMargins(.horizontal, 0, for: .scrollContent)
                .environment(\.duoScrollHandoff, nil)
        }
        .contentMargins(.horizontal, margins.insets, for: .scrollContent)
        .modifier(DuoScrollAnchoring(handoff: handoff))
    }
}

extension View {
    /// A nested horizontal ScrollView row that runs to the screen edges (page tabs on a phone): pulled out by
    /// duoMargins and inset by them inside, so its first item lines up with the page.
    func duoBleed() -> some View { modifier(DuoBleed()) }

    /// A full-width block in a split scope that's tappable or holds controls across its width: kept in the leading
    /// column (left of the fold, less the clearance). Unchanged when the scope doesn't split. The block must start at
    /// the content's leading edge (a full-width child of the page's content, P5); inside it there's no fold, and the band
    /// is the leading side's.
    func duoOneSide() -> some View { modifier(DuoOneSide()) }

    /// Charts: `base` tall in compact; base × 1.3 in medium and wide (band only; no measuring).
    func duoChartHeight(_ base: CGFloat) -> some View { modifier(DuoChartHeight(base: base)) }

    /// A block outside the page's DuoScroll (Nutrition's intro above its DuoPanes): padded by duoMargins, so it lines up
    /// with the scrolling content, as DuoScroll insets its own.
    func duoPagePadding() -> some View { modifier(DuoPagePadding()) }
}

private struct DuoPagePadding: ViewModifier {
    @Environment(\.duoMargins) private var margins

    func body(content: Content) -> some View {
        content.padding(.leading, margins.leading).padding(.trailing, margins.trailing)
    }
}

private struct DuoBleed: ViewModifier {
    @Environment(\.duoMargins) private var margins

    func body(content: Content) -> some View {
        content
            .contentMargins(.horizontal, margins.insets, for: .scrollContent)
            .padding(.leading, -margins.leading)
            .padding(.trailing, -margins.trailing)
    }
}

private struct DuoOneSide: ViewModifier {
    @Environment(\.duoFold) private var fold
    @Environment(\.duoBand) private var band
    @Environment(\.dynamicTypeSize) private var typeSize

    func body(content: Content) -> some View {
        let width = fold.leadingWidth()
        content
            .environment(\.duoFold, .none)
            .environment(\.duoBand, width.map { DuoBand.of(contentWidth: $0, typeSize: typeSize) } ?? band)
            // Without a fold both frames are empty (no size of their own), so nothing moves on an unsplit page.
            .frame(maxWidth: width)
            .frame(maxWidth: width == nil ? nil : .infinity, alignment: .leading)
    }
}

private struct DuoChartHeight: ViewModifier {
    let base: CGFloat
    @Environment(\.duoBand) private var band

    func body(content: Content) -> some View {
        content.frame(height: band.chartHeight(base))
    }
}
