import SwiftUI

/// A server whose sign-in isn't set up (its /auth/me says "misconfigured"), as the web's Login says it (Login.tsx):
/// anyone can land here before the server knows who they are, so it says only that sign-in isn't available, never why
/// (the fix is in the server's logs). Slice A gives it the welcome frame; Try again asks the server again.
struct SignInUnavailable: View {
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Eyebrow("Welcome")
                Text("Sign in to healthOS")
                    .font(.app(size: 24, weight: .medium, relativeTo: .title2))
                    .foregroundStyle(Palette.ink)
                    .accessibilityAddTraits(.isHeader)
                Text("Sign-in isn't available right now. Please try again later.")
                    .font(.app(.subheadline))
                    .foregroundStyle(Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try again") { Task { await dashboard.start() } }
                    .buttonStyle(.quietPill)
                    .padding(.top, 6)
            }
            .card()
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.page)
    }
}
