import SwiftUI

/// Two panes that each scroll, inside a DuoPage and in place of the page's DuoScroll. When duoFold splits:
/// ArrangementView(.split.axes(.horizontal)) on 27.1, else (and if G5 fails) an HStack of two DuoScrolls split on
/// the fold. Each pane is its own scope, compact, and scrolls only when its content is taller than it. Inside a pane,
/// `DuoGrid(paneColumns: 2)` and `DuoPair(paneSideBySide: true)` lay out the open Duo's two columns (decisions.md Q5:
/// the page's picture or lead in the primary pane, the rest in two columns in the secondary). `single` (one DuoScroll)
/// otherwise. Switching rebuilds what's inside, so the page keeps its state, sheets and loaders above this (P4). Give it
/// the pane contents, not scroll views: DuoPanes scrolls each one. A `duoScrollAnchor` above it is kept by the `anchor`
/// pane (the primary unless said; Home's cards, beside its figure, are its secondary) and by `single`; the other pane
/// opens at its top.
///
///     DuoPage { _ in
///         DuoPanes {
///             conversation
///         } secondary: {
///             dailyBalance
///             foodJournal
///         } single: {
///             conversation
///             dailyBalance
///             foodJournal
///         }
///     }
///     .sheet(item: $chosen) { … }   // P4: above the panes
struct DuoPanes<Primary: View, Secondary: View, Single: View>: View {
    /// One of the two panes.
    enum Pane: Sendable { case primary, secondary }

    private let anchor: Pane
    private let primary: Primary
    private let secondary: Secondary
    private let single: Single
    @Environment(\.duoFold) private var fold
    @Environment(\.duoMargins) private var margins
    @Environment(\.duoDisplayOverride) private var display

    /// The system's arrangement on iOS 27.1. Set to false if G5 finds it doesn't keep each pane on its own side of the
    /// fold at regular width: every DuoPanes page then takes the HStack path, and no page changes.
    static var usesArrangement: Bool { true }

    init(anchor: Pane = .primary, @ViewBuilder primary: () -> Primary, @ViewBuilder secondary: () -> Secondary,
         @ViewBuilder single: () -> Single) {
        self.anchor = anchor
        self.primary = primary()
        self.secondary = secondary()
        self.single = single()
    }

    var body: some View {
        if let span = fold.span {
            if #available(iOS 27.1, *) {
                DuoArrangedPanes(arranged: display == nil && Self.usesArrangement, anchorsPrimary: anchor == .primary, primary: primary,
                                 secondary: secondary, stacked: stacked(span))
            } else {
                stacked(span)
            }
        } else {
            DuoScroll { single }
        }
    }

    /// The HStack path: the leading pane from the page's leading edge to the fold, the fold's own width empty, and the
    /// trailing pane from the fold to the page's trailing edge. Each pane's content keeps the clearance from the fold
    /// (its margin on the fold's side), so its content ends where a split row's leading column does.
    private func stacked(_ span: ClosedRange<CGFloat>) -> some View {
        let gap = DuoFold.clearance
        let spans = Self.paneSpans(margins: margins, fold: span)
        return HStack(spacing: 0) {
            DuoScope(.pane(margins: DuoMargins(leading: margins.leading, trailing: gap))) { _ in
                DuoScroll { primary }.duoPaneScroll().duoAnchorKept(anchor == .primary)
            }
            .frame(width: spans.primaryWidth)
            Color.clear
                .frame(width: spans.gap)
                .accessibilityHidden(true)
            DuoScope(.pane(margins: DuoMargins(leading: gap, trailing: margins.trailing))) { _ in
                DuoScroll { secondary }.duoPaneScroll().duoAnchorKept(anchor == .secondary)
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// The HStack path's sizes, from the page's leading edge: the leading pane's width (the page's leading margin, the
    /// leading side, and the clearance) and the empty gap between the panes over the fold.
    static func paneSpans(margins: DuoMargins, fold span: ClosedRange<CGFloat>) -> (primaryWidth: CGFloat, gap: CGFloat) {
        let sides = DuoFold(span: span, active: false).sides(width: .greatestFiniteMagnitude, spacing: 0)
        let lead = sides?.leading.upperBound ?? span.lowerBound
        let trail = sides?.trailing.lowerBound ?? span.upperBound
        return (margins.leading + lead + DuoFold.clearance, max(0, trail - lead - 2 * DuoFold.clearance))
    }
}

/// The system's two panes (iOS 27.1): each its own scope, reading its own margins in its own place.
@available(iOS 27.1, *)
private struct DuoArrangedPanes<Primary: View, Secondary: View, Stacked: View>: View {
    let arranged: Bool
    let anchorsPrimary: Bool
    let primary: Primary
    let secondary: Secondary
    let stacked: Stacked

    var body: some View {
        if arranged {
            ArrangementView {
                DuoScope(.pane(margins: nil)) { _ in DuoScroll { primary }.duoPaneScroll().duoAnchorKept(anchorsPrimary) }
            } secondary: {
                DuoScope(.pane(margins: nil)) { _ in DuoScroll { secondary }.duoPaneScroll().duoAnchorKept(!anchorsPrimary) }
            }
            .arrangementViewStyle(.split.axes(.horizontal))
        } else {
            stacked
        }
    }
}

private extension View {
    /// A pane's scroll view moves only when what's in it is taller than the pane: the leading pane's picture stays put
    /// while the trailing pane scrolls (decisions.md Q5).
    func duoPaneScroll() -> some View { scrollBounceBehavior(.basedOnSize, axes: .vertical) }

    /// The page's scroll anchor stays with this pane, or is taken off it (the other pane keeps it).
    @ViewBuilder func duoAnchorKept(_ kept: Bool) -> some View {
        if kept { self } else { environment(\.duoScrollAnchorPage, nil) }
    }
}
