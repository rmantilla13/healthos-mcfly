import SwiftUI

/// The account menu, "Your workspace" (src/components/shell/AccountMenu.tsx), opened from your avatar at the top right
/// of every page: Profile, Integrations, Privacy & data, Admin for admins, and Sign out while signed in on a server with
/// sign-in.
struct AccountMenu: View {
    var size: CGFloat = 30
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        Menu {
            Section("Your workspace") {
                Button { dashboard.open(.profile) } label: { Label("Profile", systemImage: AppPage.profile.symbol) }
                Button { dashboard.open(.integrations) } label: { Label("Integrations", systemImage: AppPage.integrations.symbol) }
                // Public and static on every server: no sign-in needed in the web view.
                Button { dashboard.showWeb("privacy.html") } label: { Label("Privacy & data", systemImage: "checkmark.shield") }
                if dashboard.isAdmin {
                    Button { dashboard.open(.admin) } label: { Label("Admin", systemImage: AppPage.admin.symbol) }
                }
            }
            if dashboard.signOutOffered {
                Section {
                    Button { Task { await dashboard.signOut() } } label: {
                        Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    .accessibilityIdentifier("signOut")
                }
            }
        } label: {
            Avatar(photo: dashboard.status?.photo, name: name, size: size)
        }
        .accessibilityLabel("Your workspace")
        .accessibilityIdentifier("accountMenu")
    }

    private var name: String? { dashboard.summary?.name ?? dashboard.status?.settings?.name }
}

extension View {
    /// Your avatar at the top right, opening the account menu, as on the web's phone top bar. Home has its own in its
    /// header, which hides the bar.
    func accountMenu() -> some View {
        toolbar {
            ToolbarItem(placement: .topBarTrailing) { AccountMenu() }
        }
    }
}
