import SwiftUI

/// The More tab: the pages the tab bar has no room for (the web's More menu in MobileNav.tsx), each pushed on this tab.
/// Family shows on a server with the board and Cycle while tracking is on. Always there, signed in or not, so Profile
/// (and the server address on it) can be reached before sign-in.
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

/// One page: its icon in the accent, its name, a chevron (the web's .menu-item at phone width).
private struct MoreRow: View {
    let page: AppPage
    let divider: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: page.symbol)
                .font(.body)
                .foregroundStyle(Palette.accentText)
                .frame(width: 26)
                .accessibilityHidden(true)
            Text(page.title).font(.app(size: 15, relativeTo: .body)).foregroundStyle(Palette.ink)
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Palette.ink3)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            if divider { Rectangle().fill(Palette.border).frame(height: 1).padding(.leading, 52) }
        }
    }
}
