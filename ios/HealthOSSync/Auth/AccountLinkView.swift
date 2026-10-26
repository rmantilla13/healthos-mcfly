import SwiftUI

/// The page an invite code or a reset link opens (Login.tsx AccountLinkPage): "Checking your link…", then the form, or
/// the server's words for a link it doesn't know. An invite asks for an email (locked when the invite is for one), a
/// name and a password, and lands the new account on the welcome; a reset asks for a new password, which signs out
/// every other session, and lands on the dashboard.
struct AccountLinkView: View {
    let kind: AccountLinkKind
    let token: String
    let leave: () -> Void
    @Environment(Dashboard.self) private var dashboard
    /// nil while checking.
    @State private var check: LinkCheckResult?

    var body: some View {
        Group {
            switch check {
            case nil:
                WelcomeCard {
                    Text(SignInWords.checking)
                        .font(.app(size: 13, relativeTo: .subheadline))
                        .foregroundStyle(Palette.ink2)
                        .accessibilityIdentifier("checkingLink")
                }
            case .bad(let error):
                WelcomeCard {
                    WelcomeHead(eyebrow: eyebrow, title: title)
                    ErrorNote(error).accessibilityIdentifier("linkError")
                    WelcomeNote(SignInWords.newLink)
                    WelcomeFoot {
                        Button(action: leave) { WelcomeButtonLabel(SignInWords.goToSignIn) }
                            .buttonStyle(.accentPill)
                            .accessibilityIdentifier("goToSignIn")
                    }
                }
            case .ok(let email):
                LinkForm(kind: kind, token: token, lockedEmail: email)
            case .unchecked:
                LinkForm(kind: kind, token: token, lockedEmail: nil)
            }
        }
        .task {
            guard check == nil else { return }
            guard let client = APIClient.current() else {
                check = .bad("Enter the server address in Profile.")
                return
            }
            check = await AccountLink.check(token, kind: kind) { try await client.checkLink($0) }
        }
    }

    private var eyebrow: String { kind == .invite ? SignInWords.joinEyebrow : SignInWords.resetEyebrow }
    private var title: String { kind == .invite ? SignInWords.createTitle : SignInWords.resetTitle }
}

/// Create your account, or Choose a new password.
private struct LinkForm: View {
    let kind: AccountLinkKind
    let token: String
    let lockedEmail: String?
    @Environment(Dashboard.self) private var dashboard
    @State private var email = ""
    @State private var name = ""
    @State private var password = ""
    @State private var confirm = ""
    @State private var error: String?
    @State private var busy = false
    @FocusState private var focus: Field?

    private enum Field { case email, name, password, confirm }

    var body: some View {
        WelcomeCard {
            WelcomeHead(eyebrow: kind == .invite ? SignInWords.joinEyebrow : SignInWords.resetEyebrow,
                        title: kind == .invite ? SignInWords.createTitle : SignInWords.resetTitle,
                        lede: kind == .invite ? AccountLink.inviteLede(token) : SignInWords.resetLede)
            if kind == .invite {
                VStack(alignment: .leading, spacing: 14) {
                    WelcomeField("Email", text: $email, readOnly: lockedEmail != nil, focus: $focus, field: .email, id: "joinEmail")
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .onSubmit { focus = .name }
                    WelcomeField("Name", text: $name, focus: $focus, field: .name, id: "joinName")
                        .textContentType(.givenName)
                        .submitLabel(.next)
                        .onSubmit { focus = .password }
                        .onChange(of: name) { _, now in
                            if now.count > AccountLink.maxName { name = String(now.prefix(AccountLink.maxName)) }
                        }
                }
            }
            VStack(alignment: .leading, spacing: 14) {
                WelcomeField("Password", text: $password, secure: true, focus: $focus, field: .password, invalid: tooShort, id: "newPassword") {
                    Text(SignInWords.passwordHint)
                        .font(.app(size: 12, relativeTo: .caption))
                        .foregroundStyle(tooShort ? Palette.critical : Palette.ink3)
                }
                .textContentType(.newPassword)
                .submitLabel(.next)
                .onSubmit { focus = .confirm }
                WelcomeField("Confirm password", text: $confirm, secure: true, focus: $focus, field: .confirm, invalid: mismatch, id: "confirmPassword") {
                    if mismatch {
                        Text(SignInWords.passwordsDiffer)
                            .font(.app(size: 12, relativeTo: .caption))
                            .foregroundStyle(Palette.critical)
                    }
                }
                .textContentType(.newPassword)
                .submitLabel(kind == .invite ? .join : .done)
                .onSubmit(submit)
            }
            if let error { ErrorNote(error).accessibilityIdentifier("formError") }
            WelcomeFoot(hasStart: kind == .invite) {
                Text(SignInWords.nextSteps)
                    .font(.app(size: 12, relativeTo: .footnote))
                    .foregroundStyle(Palette.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 6)
            } main: {
                Button(action: submit) { WelcomeButtonLabel(busy ? SignInWords.saving : kind == .invite ? SignInWords.createAccount : SignInWords.setPassword, arrow: !busy) }
                    .buttonStyle(.accentPill)
                    .disabled(!ready || busy)
                    .accessibilityIdentifier(kind == .invite ? "createAccount" : "setPassword")
            }
        }
        .onAppear {
            if let lockedEmail { email = lockedEmail }
            focus = kind == .reset ? .password : lockedEmail != nil ? .name : .email
        }
        .keyboardDismissal()
    }

    private var tooShort: Bool { !password.isEmpty && password.count < AccountLink.minPassword }
    private var mismatch: Bool { !confirm.isEmpty && confirm != password }
    private var ready: Bool {
        password.count >= AccountLink.minPassword && password == confirm && (kind == .reset || !email.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    private func submit() {
        guard ready, !busy else { return }
        focus = nil
        busy = true
        error = nil
        Task {
            do {
                if kind == .invite {
                    try await dashboard.join(code: token, name: name.trimmingCharacters(in: .whitespaces),
                                             email: email.trimmingCharacters(in: .whitespaces), password: password)
                } else {
                    try await dashboard.resetPassword(token: token, password: password)
                }
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}
