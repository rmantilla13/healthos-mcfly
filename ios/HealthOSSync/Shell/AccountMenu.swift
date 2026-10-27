import SwiftUI

/// Your avatar, at the top right of every page, opening the account menu ("Your workspace").
struct AccountMenu: View {
    var size: CGFloat = 30
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        Button { dashboard.accountMenuOpen = true } label: {
            Avatar(photo: signedIn ? dashboard.status?.photo : nil, name: name, size: size)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Your workspace")
        .accessibilityHint("Opens Profile, Integrations, Privacy & data and Sign out")
        .accessibilityIdentifier("accountMenu")
    }

    /// Only while the dashboard shows someone: before the server says who (a cached status at launch) or signed out,
    /// no one's photo or initial sits above the sign-in screen.
    private var signedIn: Bool { dashboard.phase == .ready }
    private var name: String? { signedIn ? dashboard.summary?.name ?? dashboard.status?.settings?.name : nil }
}

/// What the account menu can do; the shell does it once the menu has gone (`AccountMenuItem.run`), since a page or a
/// sheet asked for while the menu is still closing never shows.
enum AccountMenuItem {
    case profile, integrations, privacy, admin, signOut

    @MainActor func run(_ dashboard: Dashboard) {
        switch self {
        case .profile: dashboard.open(.profile)
        case .integrations: dashboard.open(.integrations)
        // Public and static on every server: no sign-in needed in the web view.
        case .privacy: dashboard.showWeb("privacy.html")
        case .admin: dashboard.open(.admin)
        case .signOut: Task { await dashboard.signOut() }
        }
    }
}

/// The account menu as the web's phone shows it (src/components/shell/AccountMenu.tsx and Menu.tsx under 820px): a
/// sheet from the bottom on the pale green menu gradient, "YOUR WORKSPACE" over Profile, Integrations, Privacy & data
/// and Admin for admins, then Sign out in the quiet grey while signed in on a server with sign-in. DM Sans in ink with
/// the icons in sage, which the system's menu can't draw. As tall as its rows, scrolling at the largest text sizes.
struct AccountMenuSheet: View {
    /// What was chosen, for the shell to do once the sheet has gone.
    let choose: (AccountMenuItem) -> Void
    @Environment(Dashboard.self) private var dashboard
    @State private var height: CGFloat = 320

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Eyebrow("Your workspace", size: 10)
                    .padding(.horizontal, 12)
                    .padding(.top, 2)
                    .padding(.bottom, 8)
                    .accessibilityHidden(true)
                item(.profile, "Profile", AppPage.profile.symbol)
                item(.integrations, "Integrations", AppPage.integrations.symbol)
                item(.privacy, "Privacy & data", "checkmark.shield")
                if dashboard.isAdmin { item(.admin, "Admin", AppPage.admin.symbol) }
                if dashboard.signOutOffered {
                    Rectangle().fill(Palette.border).frame(height: 1).padding(.horizontal, 10).padding(.vertical, 6)
                    item(.signOut, "Sign out", "rectangle.portrait.and.arrow.right", quiet: true)
                        .accessibilityIdentifier("signOut")
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 14)
            .padding(.bottom, 10)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .font(.app(.body))
        .presentationDetents([.height(height)])
        .presentationCornerRadius(22)
        .presentationBackground { GradientFill(.menuBg) }
        // The menu is named as a whole; each row keeps its own name.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Your workspace")
    }

    /// One row (.menu-item at phone width): its icon in sage, its name in ink at 15pt, at least 46pt tall; Sign out is
    /// all in the quiet grey.
    private func item(_ item: AccountMenuItem, _ title: String, _ symbol: String, quiet: Bool = false) -> some View {
        Button { choose(item) } label: {
            HStack(spacing: 12) {
                RowIcon(systemName: symbol, width: 22, color: quiet ? Palette.ink3 : Palette.accentText)
                Text(title)
                    .font(.app(size: 15, relativeTo: .body))
                    .foregroundStyle(quiet ? Palette.ink3 : Palette.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuRowStyle())
    }
}

/// A menu row's press: the soft chip behind it, as the web's hover and focus.
private struct MenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Palette.chip : .clear, in: RoundedRectangle(cornerRadius: Radius.nav, style: .continuous))
    }
}

extension View {
    /// Your avatar at the top right, opening the account menu, as on the web's phone top bar. Home has its own in its
    /// header, which hides the bar.
    func accountMenu() -> some View {
        toolbar {
            if #available(iOS 26, *) {
                // The avatar has its own ring: no glass bubble around it, as on the web's top bar.
                ToolbarItem(placement: .topBarTrailing) { AccountMenu() }.sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .topBarTrailing) { AccountMenu() }
            }
        }
    }
}
