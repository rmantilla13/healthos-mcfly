import SwiftUI

/// One scope (§3): a page, a pane or a sheet. A GeometryReader at its root measures it in the first layout pass, outside
/// any scroll view. On iOS 27.1 it reads its own bar edge, the container margins and the `.division` region in its own
/// coordinates; in drawn tests it converts the `duoDisplayOverride` with its frame(in: .global). It sets `duoBand`,
/// `duoFold`, `duoMargins`, `duoBarEdge` and `duoContentWidth` for `content`, and hands `content` the same values.
/// Its structure never changes, so nothing under it is rebuilt when the band or the fold changes.
struct DuoScope<Content: View>: View {
    enum Kind: Equatable {
        /// A page: it may split; `.leadingOfFold` keeps it to the leading side; `maxWidth` caps its content.
        case page(side: DuoSide, maxWidth: CGFloat?)
        /// A pane of DuoPanes: never splits. `margins` nil reads its own (the 27.1 path, beside the system's
        /// arrangement); given, they're the pane's side of the page's (the HStack path).
        case pane(margins: DuoMargins?)
        /// A sheet: never splits; its column is at most `maxWidth` wide (its padding included), padded `padding` on
        /// each side. Its margins are that padding plus half of whatever is wider than `maxWidth`.
        case sheet(maxWidth: CGFloat, padding: CGFloat)

        /// One of DuoPanes' panes (`duoInPane` inside).
        var isPane: Bool {
            if case .pane = self { true } else { false }
        }
    }

    private let kind: Kind
    private let content: (DuoScopeValues) -> Content
    @Environment(\.duoDisplayOverride) private var display
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.layoutDirection) private var direction

    init(_ kind: Kind, @ViewBuilder content: @escaping (DuoScopeValues) -> Content) {
        self.kind = kind
        self.content = content
    }

    var body: some View {
        DuoBarEdgeReader { systemEdge in
            GeometryReader { proxy in
                let values = values(proxy, systemEdge: systemEdge)
                content(values)
                    .environment(\.duoBand, values.band)
                    .environment(\.duoFold, values.fold)
                    .environment(\.duoMargins, values.margins)
                    .environment(\.duoBarEdge, values.barEdge)
                    .environment(\.duoContentWidth, values.contentWidth)
                    .environment(\.duoScopeHeight, proxy.size.height)
                    .environment(\.duoInPane, kind.isPane)
            }
        }
    }

    private func values(_ proxy: GeometryProxy, systemEdge: HorizontalEdge?) -> DuoScopeValues {
        let width = proxy.size.width
        let edge: HorizontalEdge?
        var margins: DuoMargins
        var division: ClosedRange<CGFloat>?
        var active = false
        if let display {
            edge = display.barEdge
            margins = .measured(barEdge: edge)
            division = display.verticalFold(in: proxy.frame(in: .global), direction: direction)
            active = display.foldActive
        } else {
            edge = systemEdge
            let reading = DuoSystemReading.read(proxy, barEdge: edge)
            margins = reading.margins ?? .phone
            division = reading.division
            active = reading.divisionActive
        }
        switch kind {
        case let .page(side, maxWidth):
            return .resolve(width: width, margins: margins, division: division, active: active, typeSize: typeSize,
                            side: side, maxWidth: maxWidth, barEdge: edge)
        case let .pane(given):
            if let given { margins = given }
            return .resolve(width: width, margins: margins, division: nil, active: false, typeSize: typeSize, splits: false, barEdge: edge)
        case let .sheet(maxWidth, padding):
            // The column is centred at most `maxWidth` wide: whatever's wider goes to its sides, half each.
            let side = padding + max(0, (width - maxWidth) / 2)
            let column = width - 2 * side
            return DuoScopeValues(margins: DuoMargins(leading: side, trailing: side),
                                  band: DuoBand.of(contentWidth: column, typeSize: typeSize), fold: .none,
                                  contentWidth: max(0, column), barEdge: edge)
        }
    }
}
