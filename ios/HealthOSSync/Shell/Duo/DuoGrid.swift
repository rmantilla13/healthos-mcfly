import SwiftUI

/// A row of cards, a full-width child of the page's content: 1 column in compact; the web's count in medium
/// (fillColumns(n, medium), a short last row spanning when `loneSpans`); 2 when duoFold splits, the gap on the fold
/// (the fold's width plus twice the 12 pt clearance) and a short last row in the leading column. Each cell is offered
/// its row's height, so a card that fills it (`.frame(maxHeight: .infinity)` under its card) matches its row, as the
/// web's rows stretch. Inside a cell there's no fold, and the band is compact wherever cells sit two or more to a row.
///
/// Inside one of DuoPanes' panes (the open Duo's wide layout, decisions.md Q5), `paneColumns` cards go side by side, as
/// long as each column is at least `minColumn` (170) wide and the text isn't an accessibility size; otherwise one
/// column. A cell marked `.duoSpans()` takes a row of its own across the pane there. Everywhere else (every iPhone, the
/// outer display, the inner display upright, a page split on the fold) `paneColumns` and `.duoSpans()` change nothing.
///
///     DuoGrid(signals, id: \.id) { SignalCard(signal: $0) }
///     DuoGrid(sleepSignals, id: \.self, medium: 3) { … }      // Sleep's three signals, 3-up in medium
///     DuoGrid(vitals, id: \.self, loneSpans: false) { … }     // Vitals: a short last row stays short
///     DuoGrid(cards, id: \.id, paneColumns: 2) { card in      // Q5: two columns in the trailing pane
///         if card.isChart { TrendCard(card).duoSpans() } else { StatCard(card) }
///     }
struct DuoGrid<Data: RandomAccessCollection, ID: Hashable, Cell: View>: View {
    private let data: Data
    private let id: KeyPath<Data.Element, ID>
    private let medium: Int
    private let paneColumns: Int
    private let minColumn: CGFloat
    private let loneSpans: Bool
    private let spacing: CGFloat
    private let cell: (Data.Element) -> Cell
    @Environment(\.duoBand) private var band
    @Environment(\.duoFold) private var fold
    @Environment(\.duoInPane) private var inPane
    @Environment(\.duoContentWidth) private var contentWidth
    @Environment(\.dynamicTypeSize) private var typeSize

    init(_ data: Data, id: KeyPath<Data.Element, ID>, medium: Int = 2, paneColumns: Int = 1,
         minColumn: CGFloat = DuoPaneColumns.minColumn, loneSpans: Bool = true, spacing: CGFloat = 14,
         @ViewBuilder cell: @escaping (Data.Element) -> Cell) {
        self.data = data
        self.id = id
        self.medium = medium
        self.paneColumns = paneColumns
        self.minColumn = minColumn
        self.loneSpans = loneSpans
        self.spacing = spacing
        self.cell = cell
    }

    var body: some View {
        let pane = inPane && paneColumns > 1
        let columns = pane
            ? DuoPaneColumns.count(paneColumns, width: contentWidth, spacing: spacing, minColumn: minColumn, typeSize: typeSize)
            : Self.columns(count: data.count, band: band, fold: fold, medium: medium)
        DuoColumnsLayout(columns: columns, spacing: spacing, fold: fold.span, loneSpans: loneSpans, honoursSpans: pane) {
            ForEach(data, id: id) { cell($0) }
        }
        .environment(\.duoFold, .none)
        .environment(\.duoBand, columns > 1 ? .compact : band)
        .environment(\.duoInPane, false)
    }

    /// How many columns `count` cards take (§2.4): 2 in a split, 1 in compact, otherwise the web's count for the row.
    /// (Inside a pane with `paneColumns`, DuoPaneColumns.count instead.)
    static func columns(count: Int, band: DuoBand, fold: DuoFold, medium: Int) -> Int {
        if fold.splits { return 2 }
        if band == .compact { return 1 }
        return fillColumns(count, max: medium)
    }

    /// The web's fillColumns (shared/cards.ts): as few rows as fit, and as even as they go, so 4 cards in a row of at
    /// most 3 are 2 × 2 rather than 3 + 1.
    static func fillColumns(_ count: Int, max: Int) -> Int {
        guard count > 1, max > 1 else { return 1 }
        let rows = (count + max - 1) / max
        return (count + rows - 1) / rows
    }
}

/// The columns inside one of DuoPanes' panes (decisions.md Q5: "two columns on the right side"), as pure math: the
/// columns asked for, as long as each is at least `minColumn` wide in a pane `width` wide (its content, inside the
/// pane's margins) and the text isn't an accessibility size; fewer otherwise, down to one. The panes are about 379–443
/// wide, so two columns are 182–214 each at the default sizes.
enum DuoPaneColumns {
    /// The narrowest a column may be (Q5: "a minimum column of about 170 pt").
    static let minColumn: CGFloat = 170

    static func count(_ wanted: Int, width: CGFloat?, spacing: CGFloat = 14, minColumn: CGFloat = minColumn,
                      typeSize: DynamicTypeSize) -> Int {
        guard wanted > 1, let width, !typeSize.isAccessibilitySize else { return 1 }
        var n = wanted
        while n > 1, (width - spacing * CGFloat(n - 1)) / CGFloat(n) < minColumn { n -= 1 }
        return n
    }
}

private struct DuoSpansKey: LayoutValueKey { static let defaultValue = false }

extension View {
    /// A DuoGrid cell that needs the width (a chart you scrub, week and trend charts, insights, a long form or a table):
    /// inside one of DuoPanes' panes, where `paneColumns` puts small cards side by side, it takes a row of its own
    /// across the pane (Q5). Anywhere else it's an ordinary cell, so it never crosses a fold and the web's counts stand.
    /// Put it on the cell's outermost view.
    func duoSpans() -> some View { layoutValue(key: DuoSpansKey.self, value: true) }
}

/// The math, on its own, so tests check it without drawing.
struct DuoColumnsLayout: Layout {
    /// 1, 2 or 3 (3 only without a fold).
    var columns: Int
    var spacing: CGFloat
    /// The fold's span in this layout's x.
    var fold: ClosedRange<CGFloat>?
    var loneSpans: Bool
    /// A cell marked `.duoSpans()` takes a row of its own (DuoGrid's pane columns only). Never with a fold.
    var honoursSpans: Bool

    init(columns: Int, spacing: CGFloat = 14, fold: ClosedRange<CGFloat>? = nil, loneSpans: Bool = true, honoursSpans: Bool = false) {
        self.columns = columns
        self.spacing = spacing
        self.fold = fold
        self.loneSpans = loneSpans
        self.honoursSpans = honoursSpans
    }

    /// One cell's place in its row.
    struct Slot: Equatable {
        var x: CGFloat
        var width: CGFloat
        var maxX: CGFloat { x + width }
    }

    /// Each cell's x and width, row by row, for `count` cells in a row `width` wide (none spanning).
    func rows(count: Int, width: CGFloat) -> [[Slot]] {
        rows(spans: Array(repeating: false, count: max(0, count)), width: width)
    }

    /// Each cell's x and width, row by row, for cells in a row `width` wide; `spans[i]` says cell i is marked
    /// `.duoSpans()`. With a fold: two columns, the leading one ending half the gap before the fold and the trailing one
    /// starting half the gap after it, and a short last row in the leading column; nothing spans. Without: `columns`
    /// equal columns, and a short last row shares the whole row when `loneSpans` (the web's .fill-row), or keeps its
    /// cells' widths when not. With `honoursSpans` (and no fold), a spanning cell ends the row before it, as a short
    /// row, and takes the next row on its own.
    func rows(spans: [Bool], width: CGFloat) -> [[Slot]] {
        guard !spans.isEmpty else { return [] }
        let cols: [Slot]
        if let fold, let sides = DuoFold(span: fold, active: false).sides(width: width, spacing: spacing) {
            cols = [Slot(x: sides.leading.lowerBound, width: sides.leading.upperBound - sides.leading.lowerBound),
                    Slot(x: sides.trailing.lowerBound, width: sides.trailing.upperBound - sides.trailing.lowerBound)]
        } else {
            let n = max(1, columns)
            let w = max(0, (width - spacing * CGFloat(n - 1)) / CGFloat(n))
            cols = (0..<n).map { Slot(x: CGFloat($0) * (w + spacing), width: w) }
        }
        var out: [[Slot]] = []
        func run(_ count: Int) {
            var left = count
            while left > 0 {
                let k = min(left, cols.count)
                if k < cols.count, fold == nil, loneSpans {
                    let w = max(0, (width - spacing * CGFloat(k - 1)) / CGFloat(k))
                    out.append((0..<k).map { Slot(x: CGFloat($0) * (w + spacing), width: w) })
                } else {
                    out.append(Array(cols.prefix(k)))
                }
                left -= k
            }
        }
        let spanning = honoursSpans && fold == nil && cols.count > 1
        var pending = 0
        for span in spans {
            if spanning, span {
                run(pending)
                pending = 0
                out.append([Slot(x: 0, width: width)])
            } else {
                pending += 1
            }
        }
        run(pending)
        return out
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? idealWidth(subviews)
        let heights = rowHeights(rows(spans: spans(subviews), width: width), subviews)
        let total = heights.reduce(0, +) + spacing * CGFloat(max(0, heights.count - 1))
        return CGSize(width: width, height: total)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = rows(spans: spans(subviews), width: bounds.width)
        let heights = rowHeights(rows, subviews)
        var index = 0
        var y = bounds.minY
        for (row, height) in zip(rows, heights) {
            for slot in row {
                subviews[index].place(at: CGPoint(x: bounds.minX + slot.x, y: y), anchor: .topLeading,
                                      proposal: ProposedViewSize(width: slot.width, height: height))
                index += 1
            }
            y += height + spacing
        }
    }

    private func spans(_ subviews: Subviews) -> [Bool] {
        honoursSpans ? subviews.map { $0[DuoSpansKey.self] } : Array(repeating: false, count: subviews.count)
    }

    private func rowHeights(_ rows: [[Slot]], _ subviews: Subviews) -> [CGFloat] {
        var index = 0
        return rows.map { row in
            row.reduce(CGFloat(0)) { tallest, slot in
                defer { index += 1 }
                return max(tallest, subviews[index].sizeThatFits(ProposedViewSize(width: slot.width, height: nil)).height)
            }
        }
    }

    private func idealWidth(_ subviews: Subviews) -> CGFloat {
        let widest = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        let n = CGFloat(fold == nil ? max(1, columns) : 2)
        return widest * n + spacing * (n - 1)
    }
}
