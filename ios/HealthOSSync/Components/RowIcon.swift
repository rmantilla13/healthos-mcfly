import SwiftUI

/// A row's icon in the accent (More's pages, a Collapsible's title): an SF Symbol that grows with the text up to
/// xxLarge and then stays, in a column that grows with it, so the names beside it line up and never sit under it at the
/// largest text sizes.
struct RowIcon: View {
    let systemName: String
    /// The column's width at the default text size.
    var width: CGFloat = RowIcon.column
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    /// More's column, at the default text size.
    static let column: CGFloat = 26

    var body: some View {
        Image(systemName: systemName)
            .font(.body)
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
            .foregroundStyle(Palette.accentText)
            .frame(width: Self.width(width * scale, base: width))
            .accessibilityHidden(true)
    }

    /// The column for `scaled`, the base width grown with the text: no wider than the symbol gets at xxLarge (about a
    /// quarter more than at the default size).
    static func width(_ scaled: CGFloat, base: CGFloat = column) -> CGFloat { min(scaled, base * 1.3) }
}

extension View {
    /// A one-word name keeps its word whole at the largest text sizes, shrinking a little instead of breaking it in the
    /// middle; a name of several words wraps between them.
    func wholeWords(_ text: String) -> some View {
        let oneWord = !text.contains(" ")
        return lineLimit(oneWord ? 1 : nil).minimumScaleFactor(oneWord ? 0.7 : 1)
    }
}
