import SwiftUI

/// Settings isn't a tab: each tab's navigation bar has a gear in its top-right corner that opens it as a sheet over
/// that tab (Today, which hides its bar, opens it from the avatar in its header).
private struct SettingsButton: ViewModifier {
    @Environment(Dashboard.self) private var dashboard

    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { dashboard.tab = .settings } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
                .accessibilityIdentifier("settingsGear")
            }
        }
    }
}

extension View {
    /// The gear that opens Settings, for a tab's root screen.
    func settingsButton() -> some View { modifier(SettingsButton()) }
}
