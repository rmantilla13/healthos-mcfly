import SwiftUI

/// A server whose sign-in isn't set up (its /auth/me says "misconfigured"), as the web's Login says it, in the welcome
/// frame: anyone can land here before the server knows who they are, so it says only that sign-in isn't available,
/// never why (the fix is in the server's logs). The iPhone adds Try again, which asks the server again (the web reloads
/// the page), and Change server, since this may be the wrong address.
struct SignInUnavailable: View {
    @Environment(Dashboard.self) private var dashboard
    @State private var trying = false

    var body: some View {
        WelcomeFrame {
            Button("Change server") { dashboard.tab = .settings }
                .buttonStyle(.welcomeTopLink)
                .accessibilityIdentifier("changeServer")
        } content: {
            WelcomeCard {
                WelcomeHead(eyebrow: SignInWords.welcome, title: SignInWords.signInTitle, lede: SignInWords.misconfigured)
                Button {
                    trying = true
                    Task {
                        await dashboard.start()
                        trying = false
                    }
                } label: {
                    Text(trying ? "Trying again…" : "Try again")
                }
                .buttonStyle(.quietPill)
                .disabled(trying)
                .accessibilityIdentifier("tryAgain")
            }
        }
    }
}
