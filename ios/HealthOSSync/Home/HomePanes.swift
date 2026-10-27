import SwiftUI

// Home on the iPhone Duo (duo/design.md §2.6 and §7, decisions.md Q5): which of Home's rows show and in what order, in
// its one scrolling column (every iPhone, the Duo's outer display, its inner display upright) and in the cards pane of
// the open Duo in landscape; and that pane's neighbour, the leading pane, with the greeting and the figure fitted to it.

/// Home's rows. Each is a direct child of its scrolling stack with a String id, the same in the column and in the cards
/// pane, so a fold that swaps them hands the row at the top from one to the other (Shell/Duo/DuoScrollAnchor.swift). The
/// header, the figure and its tagline are only in the column: on the open Duo they're the leading pane, so a column
/// scrolled no further than them opens the cards pane at its top.
enum HomeRows {
    static let header = "home.header"
    static let banners = "home.banners"
    static let figure = "home.figure"
    static let tagline = "home.tagline"
    static let live = "home.live"
    static let signals = "home.signals"
    static let lower = "home.lower"
    static let day = "home.day"
    static let cycle = "home.cycle"
    static let optional = "home.optional"
    static let timeline = "home.timeline"
    static let week = "home.week"
    static let insights = "home.insights"
    static let allHidden = "home.allHidden"
    static let statsTagline = "home.statsTagline"
    static let footer = "home.footer"

    /// One row and the space above it.
    struct Row: Equatable {
        let id: String
        let top: CGFloat
    }

    /// Which of Home's parts show.
    struct Shown: Equatable {
        var banners = false
        /// "Just the statistics": no figure, Live heart rate where it would be, and the small tagline under the cards.
        var stats = false
        var signals = true
        var lower = true
        var day = false
        var cycle = false
        var optional = false
        var timeline = false
        var week = false
        var insights = false
        var allHidden = false
    }

    /// The column, in Home.tsx's order, spaced as the web's phone layout: the header, the banners (18 below it), the
    /// figure (16 below the banners, or 18 below the header) and its tagline (14), the cards (18 below, then 14 apart),
    /// and the last line, which keeps its own 28.
    static func single(_ s: Shown) -> [Row] {
        var rows = [Row(id: header, top: 0)]
        if s.banners { rows.append(Row(id: banners, top: 18)) }
        let below: CGFloat = s.banners ? 16 : 18
        if s.stats {
            rows.append(Row(id: live, top: below))
        } else {
            rows += [Row(id: figure, top: below), Row(id: tagline, top: 14)]
        }
        rows += cards(s, first: 18, statsTagline: s.stats)
        rows.append(Row(id: footer, top: 0))
        return rows
    }

    /// The open Duo's cards pane: the banners, then every card (two to a row where they're small), then the last line.
    /// The tagline is the leading pane's.
    static func cards(_ s: Shown) -> [Row] {
        var rows: [Row] = []
        if s.banners { rows.append(Row(id: banners, top: 0)) }
        rows += cards(s, first: s.banners ? 16 : 0, statsTagline: false)
        rows.append(Row(id: footer, top: 0))
        return rows
    }

    private static func cards(_ s: Shown, first: CGFloat, statsTagline: Bool) -> [Row] {
        let all: [(String, Bool)] = [(signals, s.signals), (lower, s.lower), (day, s.day), (cycle, s.cycle), (optional, s.optional),
                                     (timeline, s.timeline), (week, s.week), (insights, s.insights), (allHidden, s.allHidden),
                                     (Self.statsTagline, statsTagline)]
        var top = first
        var rows: [Row] = []
        for (id, on) in all where on {
            rows.append(Row(id: id, top: top))
            top = 14
        }
        return rows
    }
}

/// The open Duo's leading pane on Home (decisions.md Q5): the greeting with its controls trailing, and under it the
/// figure or your photo fitted to the pane, so it stays put while the cards scroll beside it, with the tagline under
/// it. "Just the statistics" has no figure: Live heart rate and the tagline.
struct HomeLead: View {
    let summary: Summary
    @Binding var editing: Bool
    let stats: Bool
    let scrub: HeartScrub?
    let figure: HomeFigureState
    /// The pane's height (its scope's), read here inside it.
    @Environment(\.duoScopeHeight) private var height

    /// The stack's own top and bottom padding.
    static let padding: CGFloat = 16

    var body: some View {
        HomeLeadLayout(height: height.map { $0 - 2 * Self.padding }, fits: !stats) {
            HomeHeader(summary: summary, editing: $editing, wide: true)
            if stats {
                LiveHeartRateButton(state: figure)
            } else {
                HomeFigure(summary: summary, scrub: scrub, state: figure)
            }
            HomeTagline()
        }
        .padding(.vertical, Self.padding)
    }
}

/// The leading pane's three parts, one under the other: the header, the figure, the tagline. With `fits`, the figure is
/// as wide as leaves all three inside `height` (the pane, so nothing scrolls), down to `minFigure`; then the pane
/// scrolls, as at the accessibility text sizes. The figure is centred in the pane.
struct HomeLeadLayout: Layout {
    /// The height the three should fit in; nil: each at its own size.
    var height: CGFloat?
    var fits: Bool
    var headerGap: CGFloat = 18
    var taglineGap: CGFloat = 14

    /// The narrowest the figure goes to stay inside the pane: its labels still fit beside it there.
    static let minFigure: CGFloat = 260

    func figureWidth(_ subviews: Subviews, width: CGFloat) -> CGFloat {
        guard fits, let height, subviews.count == 3 else { return width }
        let fixed = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil)).height
            + subviews[2].sizeThatFits(ProposedViewSize(width: width, height: nil)).height + headerGap + taglineGap
        let room = height - fixed
        func tall(_ w: CGFloat) -> CGFloat { subviews[1].sizeThatFits(ProposedViewSize(width: w, height: nil)).height }
        if tall(width) <= room { return width }
        var lo = min(Self.minFigure, width), hi = width
        if tall(lo) > room { return lo }
        for _ in 0..<12 {
            let mid = (lo + hi) / 2
            if tall(mid) <= room { lo = mid } else { hi = mid }
        }
        return lo.rounded(.down)
    }

    private func sizes(_ subviews: Subviews, width: CGFloat) -> [CGSize] {
        let figure = figureWidth(subviews, width: width)
        return subviews.indices.map { i in
            let w = i == 1 ? figure : width
            return CGSize(width: w, height: subviews[i].sizeThatFits(ProposedViewSize(width: w, height: nil)).height)
        }
    }

    private func gap(after i: Int) -> CGFloat { i == 0 ? headerGap : taglineGap }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        let heights = sizes(subviews, width: width).map(\.height)
        let gaps = (0..<max(0, heights.count - 1)).map(gap(after:)).reduce(0, +)
        return CGSize(width: width, height: heights.reduce(0, +) + gaps)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for (i, size) in sizes(subviews, width: bounds.width).enumerated() {
            let x = i == 1 ? bounds.minX + ((bounds.width - size.width) / 2).rounded(.down) : bounds.minX
            subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: size.width, height: size.height))
            y += size.height + gap(after: i)
        }
    }
}
