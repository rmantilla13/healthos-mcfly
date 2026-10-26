import SwiftUI

/// Sign-in for the hosted dashboard, with the same account as the website: email and password on
/// servers with per-person accounts, the password alone on older ones.
struct SignInView: View {
    @Environment(Dashboard.self) private var dashboard
    @State private var email = Config.lastEmail
    @State private var password = ""
    @State private var error: String?
    @State private var busy = false
    @State private var joining = false
    @FocusState private var focus: Field?

    private enum Field { case email, password }

    var body: some View {
        VStack(spacing: 18) {
            BrandMark().frame(width: 72, height: 72)
            VStack(spacing: 4) {
                Text("healthOS").font(.app(.largeTitle, weight: .bold)).foregroundStyle(Palette.ink)
                Text("Sign in to \(Config.serverURL()?.host ?? "your dashboard")").font(.app(.subheadline)).foregroundStyle(Palette.ink3)
            }
            // Otherwise nothing here says why the background uploads stopped (IngestTokenOwner).
            if dashboard.ingestWaitsForSignIn {
                Label("This iPhone's Apple Health uploads wait until you sign in.", systemImage: "pause.circle")
                    .font(.app(.footnote))
                    .foregroundStyle(Palette.ink3)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("uploadsWait")
            }
            // Shown unless the server is known to sign in with a password alone (older single-user servers).
            if dashboard.usesAccounts || dashboard.authMode == nil {
                TextField("Email", text: $email)
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.next)
                    .focused($focus, equals: .email)
                    .onSubmit { focus = .password }
                    .padding(14)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.border))
                    .accessibilityIdentifier("email")
            }
            SecureField("Password", text: $password)
                .textContentType(.password)
                .submitLabel(.go)
                .focused($focus, equals: .password)
                .onSubmit(submit)
                .padding(14)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.border))
                .accessibilityIdentifier("password")
            if let error {
                Text(error).font(.app(.footnote)).foregroundStyle(Palette.critical).multilineTextAlignment(.center)
            }
            Button(action: submit) {
                Group {
                    if busy { ProgressView().tint(Palette.accentInk) } else { Text("Sign in") }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.accentPill)
            .disabled(!ready || busy)
            .accessibilityIdentifier("signIn")
            if dashboard.usesAccounts {
                Button("Have an invite code?") { joining = true }
                    .font(.app(.subheadline))
                    .accessibilityIdentifier("haveInvite")
            }
            Button("Change server") { dashboard.tab = .settings }
                .font(.app(.footnote))
        }
        .padding(28)
        .frame(maxWidth: 420)
        .onAppear { focus = dashboard.usesAccounts && email.isEmpty ? .email : .password }
        .sheet(isPresented: $joining) { JoinView() }
        .keyboardDismissal()
    }

    private var ready: Bool { !password.isEmpty && (!dashboard.usesAccounts || email.contains("@")) }

    private func submit() {
        guard ready, !busy else { return }
        focus = nil
        busy = true
        error = nil
        Task {
            do {
                try await dashboard.signIn(email: email.trimmingCharacters(in: .whitespaces), password: password)
                password = ""
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}
