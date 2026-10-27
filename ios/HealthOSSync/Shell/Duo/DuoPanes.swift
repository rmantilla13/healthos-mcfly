import SwiftUI

/// Two panes that each scroll, inside a DuoPage and in place of the page's DuoScroll. When duoFold splits:
/// ArrangementView(.split.axes(.horizontal)) on 27.1, else (and if G5 fails) an HStack of two DuoScrolls split on
/// the fold. Each pane is its own scope, compact, and scrolls only when its content is taller than it. Inside a pane,
/// `DuoGrid(paneColumns: 2)` and `DuoPair(paneSideBySide: true)` lay out the open Duo's two columns (decisions.md Q5:
/// the page's picture or lead in the primary pane, the rest in two columns in the secondary). With the secondary as
/// the anchor (every page), the primary doesn't scroll (DuoStillPane): each page keeps its lead to what fits. `single` (one DuoScroll)
/// otherwise. Switching rebuilds what's inside, so the page keeps its state, sheets and loaders above this (P4). Give it
/// the pane contents, not scroll views: DuoPanes scrolls each one. A fold hands the row at the top (by its String id)
/// between `single` and the `anchor` pane (the primary unless said; Home's cards, beside its figure, are its secondary);
/// the other pane opens at its top.
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
    /// The row a fold hands from one scroll view to the next: this page's own, so a new page starts at its top.
    @State private var handoff = DuoScrollHandoff()

    /// The system's arrangement on iOS 27.1: off. G5 (HOS Duo, open, the shell stage) found that at regular width
    /// ArrangementView splits the page into equal halves (0–433.7 | 433.7–867 of an 867 pt page) and ignores the fold,
    /// a 40 pt region at 435.5–475.5 there, so the secondary pane started on it. Every DuoPanes page takes the HStack
    /// path, which splits on the fold read, and no page changes.
    static var usesArrangement: Bool { false }

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
                DuoArrangedPanes(arranged: display == nil && Self.usesArrangement, anchorsPrimary: anchor == .primary, handoff: handoff,
                                 primary: primary, secondary: secondary, stacked: stacked(span))
            } else {
                stacked(span)
            }
        } else {
            DuoScroll { single }.environment(\.duoScrollHandoff, handoff)
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
                if anchor == .primary {
                    DuoScroll { primary }.duoPaneScroll().duoHandoff(handoff)
                } else {
                    DuoStillPane { primary }
                }
            }
            .frame(width: spans.primaryWidth)
            Color.clear
                .frame(width: spans.gap)
                .accessibilityHidden(true)
            DuoScope(.pane(margins: DuoMargins(leading: gap, trailing: margins.trailing))) { _ in
                DuoScroll { secondary }.duoPaneScroll().duoHandoff(anchor == .secondary ? handoff : nil)
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

/// The leading pane of the open Duo (decisions.md Q5, and the person's own ask: the left screen doesn't scroll): its
/// content stays put, top-aligned and inset by the pane's margins, while the trailing pane scrolls. Each page keeps
/// what it puts there inside the pane at the default text sizes. Where it can't fit (the accessibility text sizes, a
/// long answer at the larger ones), it scrolls after all rather than cutting anything off that VoiceOver or a finger
/// couldn't reach.
struct DuoStillPane<Content: View>: View {
    private let content: Content
    @Environment(\.duoMargins) private var margins

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ViewThatFits(in: .vertical) {
            // At its own height, as in a scroll view (a card that fills its row doesn't stretch to the pane's foot).
            content
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, margins.leading)
                .padding(.trailing, margins.trailing)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            DuoScroll { content }.duoPaneScroll().onAppear { DuoStillPaneLog.scrolled += 1 }
        }
    }
}

/// How many leading panes have had to scroll since the count was reset: the drawn tests check that none does at the
/// open Duo's sizes below the accessibility text sizes (DuoSnapshot).
@MainActor
enum DuoStillPaneLog {
    static var scrolled = 0
}

/// The system's two panes (iOS 27.1): each its own scope, reading its own margins in its own place.
@available(iOS 27.1, *)
private struct DuoArrangedPanes<Primary: View, Secondary: View, Stacked: View>: View {
    let arranged: Bool
    let anchorsPrimary: Bool
    let handoff: DuoScrollHandoff
    let primary: Primary
    let secondary: Secondary
    let stacked: Stacked

    var body: some View {
        if arranged {
            ArrangementView {
                DuoScope(.pane(margins: nil)) { _ in DuoScroll { primary }.duoPaneScroll().duoHandoff(anchorsPrimary ? handoff : nil) }
            } secondary: {
                DuoScope(.pane(margins: nil)) { _ in DuoScroll { secondary }.duoPaneScroll().duoHandoff(anchorsPrimary ? nil : handoff) }
            }
            .arrangementViewStyle(.split.axes(.horizontal))
        } else {
            stacked
        }
    }
}

private extension View {
    /// A pane's scroll view moves only when what's in it is taller than the pane.
    func duoPaneScroll() -> some View { scrollBounceBehavior(.basedOnSize, axes: .vertical) }

    /// The pane's scroll view takes part in the fold's handoff (the anchored pane), or doesn't (nil: the other pane).
    func duoHandoff(_ handoff: DuoScrollHandoff?) -> some View { environment(\.duoScrollHandoff, handoff) }
}
