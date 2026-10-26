import SwiftUI

/// The More tab: the pages the tab bar has no room for (the web's More menu in MobileNav.tsx), each pushed on this tab.
/// Family shows while you share on a server with accounts and Cycle while tracking is on, as the web lists them. Always
/// there, signed in or not, so Profile (and the server address on it) can be reached before sign-in.
struct MoreScreen: View {
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        let pages = dashboard.morePages
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Eyebrow("More").padding(.horizontal, 6)
                VStack(spacing: 0) {
                    ForEach(Array(pages.enumerated()), id: \.element) { index, page in
                        NavigationLink(value: AppRoute(page)) {
                            MoreRow(page: page, divider: index < pages.count - 1)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("more.\(page.rawValue)")
                    }
                }
                .padding(.horizontal, 8)
                .background { CardSurface(shape: RoundedRectangle(cornerRadius: Radius.card, style: .continuous)) }
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.page)
    }
}

/// One page: its icon in the accent, its name, a chevron (the web's .menu-item at phone width). At the accessibility
/// text sizes the icon goes over the name, so the name has the row's width, and a one-word name shrinks a little rather
/// than break in the middle ("Integrations").
private struct MoreRow: View {
    let page: AppPage
    let divider: Bool
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var column: CGFloat = RowIcon.column

    var body: some View {
        let stacked = typeSize.isAccessibilitySize
        HStack(spacing: 8) {
            (stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6)) : AnyLayout(HStackLayout(spacing: 14))) {
                RowIcon(systemName: page.symbol)
                Text(page.title)
                    .font(.app(size: 15, relativeTo: .body))
                    .foregroundStyle(Palette.ink)
                    .wholeWords(page.title)
            }
            .padding(.vertical, stacked ? 10 : 0)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                .foregroundStyle(Palette.ink3)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            if divider { Rectangle().fill(Palette.border).frame(height: 1).padding(.leading, stacked ? 12 : 26 + RowIcon.width(column)) }
        }
    }
}
