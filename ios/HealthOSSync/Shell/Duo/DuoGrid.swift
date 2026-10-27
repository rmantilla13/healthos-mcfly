import SwiftUI

/// A row of cards, a full-width child of the page's content: 1 column in compact; the web's count in medium
/// (fillColumns(n, medium), a short last row spanning when `loneSpans`); 2 when duoFold splits, the gap on the fold
/// (the fold's width plus twice the 12 pt clearance) and a short last row in the leading column. Each cell is offered
/// its row's height, so a card that fills it (`.frame(maxHeight: .infinity)` under its card) matches its row, as the
/// web's rows stretch. Inside a cell there's no fold, and the band is compact wherever cells sit two or more to a row.
///
///     DuoGrid(signals, id: \.id) { SignalCard(signal: $0) }
///     DuoGrid(sleepSignals, id: \.self, medium: 3) { … }      // Sleep's three signals, 3-up in medium
///     DuoGrid(vitals, id: \.self, loneSpans: false) { … }     // Vitals: a short last row stays short
struct DuoGrid<Data: RandomAccessCollection, ID: Hashable, Cell: View>: View {
    private let data: Data
    private let id: KeyPath<Data.Element, ID>
    private let medium: Int
    private let loneSpans: Bool
    private let spacing: CGFloat
    private let cell: (Data.Element) -> Cell
    @Environment(\.duoBand) private var band
    @Environment(\.duoFold) private var fold

    init(_ data: Data, id: KeyPath<Data.Element, ID>, medium: Int = 2, loneSpans: Bool = true, spacing: CGFloat = 14,
         @ViewBuilder cell: @escaping (Data.Element) -> Cell) {
        self.data = data
        self.id = id
        self.medium = medium
        self.loneSpans = loneSpans
        self.spacing = spacing
        self.cell = cell
    }

    var body: some View {
        let columns = Self.columns(count: data.count, band: band, fold: fold, medium: medium)
        DuoColumnsLayout(columns: columns, spacing: spacing, fold: fold.span, loneSpans: loneSpans) {
            ForEach(data, id: id) { cell($0) }
        }
        .environment(\.duoFold, .none)
        .environment(\.duoBand, columns > 1 ? .compact : band)
    }

    /// How many columns `count` cards take (§2.4): 2 in a split, 1 in compact, otherwise the web's count for the row.
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

/// The math, on its own, so tests check it without drawing.
struct DuoColumnsLayout: Layout {
    /// 1, 2 or 3 (3 only without a fold).
    var columns: Int
    var spacing: CGFloat
    /// The fold's span in this layout's x.
    var fold: ClosedRange<CGFloat>?
    var loneSpans: Bool

    init(columns: Int, spacing: CGFloat = 14, fold: ClosedRange<CGFloat>? = nil, loneSpans: Bool = true) {
        self.columns = columns
        self.spacing = spacing
        self.fold = fold
        self.loneSpans = loneSpans
    }

    /// One cell's place in its row.
    struct Slot: Equatable {
        var x: CGFloat
        var width: CGFloat
        var maxX: CGFloat { x + width }
    }

    /// Each cell's x and width, row by row, for `count` cells in a row `width` wide. With a fold: two columns, the
    /// leading one ending half the gap before the fold and the trailing one starting half the gap after it, and a short
    /// last row in the leading column. Without: `columns` equal columns, and a short last row shares the whole row when
    /// `loneSpans` (the web's .fill-row), or keeps its cells' widths when not.
    func rows(count: Int, width: CGFloat) -> [[Slot]] {
        guard count > 0 else { return [] }
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
        return out
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? idealWidth(subviews)
        let heights = rowHeights(rows(count: subviews.count, width: width), subviews)
        let total = heights.reduce(0, +) + spacing * CGFloat(max(0, heights.count - 1))
        return CGSize(width: width, height: total)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = rows(count: subviews.count, width: bounds.width)
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
