import SwiftUI

/// The welcome (src/pages/Onboarding.tsx): a new account's three steps, "Make this space yours", or the same steps to
/// edit from Profile. The shell shows it full screen whenever `dashboard.onboarding` says (Shell/Welcome.swift). Slice A
/// builds it here, ending a new account's with `onboarding: null` through `dashboard.save(settings:)`, and an edit's with
/// `dashboard.closeWelcome()`.
///
/// Until then it says so, and never writes `onboarding`: a new account can sign out or put it off for this session.
struct OnboardingView: View {
    let mode: OnboardingMode
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Eyebrow("Welcome")
                Text(mode == .new ? "Make this space yours" : "Edit preferences")
                    .font(.app(size: 24, weight: .medium, relativeTo: .title2))
                    .foregroundStyle(Palette.ink)
                    .accessibilityAddTraits(.isHeader)
                Text("The welcome steps are coming in this build.")
                    .font(.app(.subheadline))
                    .foregroundStyle(Palette.ink2)
                HStack(spacing: 10) {
                    if mode == .edit {
                        Button("Back to Profile") { dashboard.closeWelcome() }.buttonStyle(.accentPill)
                    } else {
                        Button("Not now") { dashboard.putOffOnboarding() }.buttonStyle(.accentPill)
                        if dashboard.signOutOffered {
                            Button("Sign out") { Task { await dashboard.signOut() } }.buttonStyle(.quietPill)
                        }
                    }
                }
                .padding(.top, 6)
            }
            .card()
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.page)
        .font(.app(.body))
        .tint(Palette.tint)
        .toggleStyle(.appSwitch)
    }
}
