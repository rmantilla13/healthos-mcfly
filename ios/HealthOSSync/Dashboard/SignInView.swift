import SwiftUI

/// The way in (src/pages/Login.tsx), full screen in the welcome frame as the web's phone shows it, with no tab bar: sign
/// in, join with an invite code, or use a reset link, each a step of this one screen. Email and password on servers
/// with accounts (on a brand-new one, the first sign-in creates the admin's), the password alone on older single-user
/// servers. "Change server", at the top right, is the iPhone's own: it opens Profile, where the address is.
struct SignInView: View {
    @Environment(Dashboard.self) private var dashboard
    @State private var step: SignInStep = .signIn

    var body: some View {
        WelcomeFrame {
            switch step {
            case .signIn:
                Button("Change server") { dashboard.tab = .settings }
                    .buttonStyle(.welcomeTopLink)
                    .accessibilityIdentifier("changeServer")
            case .code: EmptyView()
            case .link:
                Button(SignInWords.backToSignIn) { step = .signIn }
                    .buttonStyle(.welcomeTopLink)
                    .accessibilityIdentifier("backToSignIn")
            }
        } content: {
            switch step {
            case .signIn:
                SignInForm(join: { step = .code(.invite) }, reset: { step = .code(.reset) })
            case .code(let kind):
                JoinView(kind: kind, back: { step = .signIn }, open: { kind, token in step = .link(kind, token: token) })
                    .id(kind)
            case .link(let kind, let token):
                AccountLinkView(kind: kind, token: token, leave: { step = .signIn })
                    .id(token)
            }
        }
    }
}

/// Where the sign-in screen is: the form, typing a code or pasting a link, or the page the code or link opens.
enum SignInStep: Equatable {
    case signIn
    case code(AccountLinkKind)
    case link(AccountLinkKind, token: String)
}

/// Sign in to healthOS, or, on a server with no account yet, create the admin's.
private struct SignInForm: View {
    let join: () -> Void
    let reset: () -> Void
    @Environment(Dashboard.self) private var dashboard
    /// Empty, as the web's: the last person's email isn't shown to whoever holds the phone. Password AutoFill offers
    /// the accounts saved on it.
    @State private var email = ""
    @State private var password = ""
    @State private var error: String?
    @State private var busy = false
    /// The server has no account yet (its /auth/me `setup`): the first sign-in creates the admin's. nil until read,
    /// and from older servers.
    @State private var setup: Bool?
    @State private var read = false
    @FocusState private var focus: Field?

    private enum Field { case email, password }

    var body: some View {
        WelcomeCard {
            if read || !dashboard.usesAccounts {
                form
            } else {
                // The web shows nothing until it knows whether this is a new server's first sign-in.
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            }
        }
        .task {
            guard !read else { return }
            if dashboard.usesAccounts, let client = APIClient.current() { setup = try? await client.authState().setup }
            read = true
        }
        .keyboardDismissal()
    }

    private var isSetup: Bool { setup == true }
    /// Shown unless the server is known to sign in with a password alone (older single-user servers).
    private var asksEmail: Bool { dashboard.usesAccounts || dashboard.authMode == nil }

    @ViewBuilder
    private var form: some View {
        WelcomeHead(eyebrow: isSetup ? SignInWords.welcome : SignInWords.welcomeBack,
                    title: isSetup ? SignInWords.setupTitle : SignInWords.signInTitle,
                    lede: isSetup ? SignInWords.setupLede : nil)
        // Otherwise nothing here says why the background uploads stopped (IngestTokenOwner).
        if dashboard.ingestWaitsForSignIn {
            Label("This iPhone's Apple Health uploads wait until you sign in.", systemImage: "pause.circle")
                .font(.app(size: 12, relativeTo: .footnote))
                .foregroundStyle(Palette.ink3)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("uploadsWait")
        }
        VStack(alignment: .leading, spacing: 18) {
            if asksEmail {
                WelcomeField("Email", text: $email, focus: $focus, field: .email, id: "email")
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.next)
                    .onSubmit { focus = .password }
            }
            WelcomeField("Password", text: $password, secure: true, focus: $focus, field: .password, id: "password")
                .textContentType(.password)
                .submitLabel(.go)
                .onSubmit(submit)
        }
        if let error { ErrorNote(error).accessibilityIdentifier("signInError") }
        WelcomeFoot(hasStart: offersLinks) {
            Button(SignInWords.haveInvite, action: join)
                .buttonStyle(.welcomeLink)
                .accessibilityIdentifier("haveInvite")
        } main: {
            Button(action: submit) { WelcomeButtonLabel(busy ? SignInWords.signingIn : SignInWords.signIn, arrow: !busy) }
                .buttonStyle(.accentPill)
                .disabled(!ready || busy)
                .accessibilityIdentifier("signIn")
        }
        if offersLinks {
            VStack(alignment: .leading, spacing: 0) {
                WelcomeNote(SignInWords.forgot)
                // The web opens a reset link in the browser; here it's pasted (only the iPhone has this).
                Button(SignInWords.haveResetLink, action: reset)
                    .buttonStyle(.welcomeLink)
                    .accessibilityIdentifier("haveResetLink")
            }
        }
    }

    /// Invites and reset links: on servers with accounts, once there's an admin to ask.
    private var offersLinks: Bool { dashboard.usesAccounts && !isSetup }

    private var ready: Bool { !password.isEmpty && (!asksEmail || email.contains("@")) }

    private func submit() {
        guard ready, !busy else { return }
        focus = nil
        busy = true
        error = nil
        Task {
            do {
                try await dashboard.signIn(email: asksEmail ? email.trimmingCharacters(in: .whitespaces) : "", password: password)
                password = ""
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}
