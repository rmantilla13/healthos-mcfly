import SwiftUI

extension APIClient {
    /// POST /api/auth/password {current, next}. The server signs every other device out (it moves the account's session
    /// version on) and answers with a new session cookie for this one, which `checked` keeps, so this phone stays
    /// signed in. Its refusals come in its own words ("Your current password is wrong.").
    func changePassword(current: String, next: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["current": current, "next": next])
        _ = try await request("/auth/password", method: "POST", body: body)
    }
}

/// Profile's Account row (G28): the email (" · admin" for an admin), the Signed in badge and a quiet Change password
/// that opens the form under the row, as the web's does. A server without sign-in is "This Mac, no sign-in", with
/// nothing to change.
struct ProfileAccountRow: View {
    var divider = true
    @Environment(Dashboard.self) private var dashboard
    @State private var open = false

    var body: some View {
        let signedIn = dashboard.signOutOffered
        let user = dashboard.status?.user ?? dashboard.account
        VStack(alignment: .leading, spacing: 0) {
            ProfileRow("Account", divider: false) {
                Text(ProfileWords.account(signedIn: signedIn, email: user?.email ?? dashboard.account?.email, role: user?.role))
                    .accessibilityIdentifier("accountEmail")
            } action: {
                if signedIn {
                    // Side by side, or one over the other at the largest text sizes.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) { actions }
                        VStack(alignment: .leading, spacing: 6) { actions }
                    }
                }
            }
            if signedIn, open {
                ProfilePasswordForm()
                    .padding(.top, 2)
                    .padding(.bottom, 18)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) {
            if divider { Rectangle().fill(Palette.border).frame(height: 1) }
        }
    }

    @ViewBuilder
    private var actions: some View {
        Badge("Signed in", tone: .sage)
        Button("Change password") { open.toggle() }
            .buttonStyle(ProfileQuietStyle())
            .accessibilityValue(open ? "Expanded" : "Collapsed")
            .accessibilityIdentifier("changePassword")
    }
}

/// Current, new and confirm (the web's PasswordForm): Change password once the new one is at least 10 characters and
/// typed the same twice. The fields are marked for passwords, so iOS offers to keep the new one. Then the web's
/// "Password changed. Other devices are signed out." or the server's words. The passwords live only in these fields
/// while the form is open, and are cleared once changed.
struct ProfilePasswordForm: View {
    @Environment(Dashboard.self) private var dashboard
    @State private var current = ""
    @State private var next = ""
    @State private var confirm = ""
    @State private var busy = false
    @State private var result: (ok: Bool, text: String)?
    @FocusState private var focus: Field?

    private enum Field { case current, next, confirm }

    var body: some View {
        let ready = ProfileWords.passwordReady(current: current, next: next, confirm: confirm)
        VStack(alignment: .leading, spacing: 16) {
            ProfileField("Current password") {
                SecureField("", text: $current)
                    .textContentType(.password)
                    .focused($focus, equals: .current)
                    .submitLabel(.next)
                    .onSubmit { focus = .next }
                    .profileInput()
                    .accessibilityLabel("Current password")
                    .accessibilityIdentifier("currentPassword")
            }
            ProfileField("New password", hint: ProfileWords.passwordHint, hintIsBad: !next.isEmpty && next.count < ProfileWords.passwordMinimum) {
                SecureField("", text: $next)
                    .textContentType(.newPassword)
                    .focused($focus, equals: .next)
                    .submitLabel(.next)
                    .onSubmit { focus = .confirm }
                    .profileInput()
                    .accessibilityLabel("New password")
                    .accessibilityIdentifier("newPassword")
            }
            ProfileField("Confirm new password", hint: !confirm.isEmpty && confirm != next ? ProfileWords.passwordsDiffer : nil, hintIsBad: true) {
                SecureField("", text: $confirm)
                    .textContentType(.newPassword)
                    .focused($focus, equals: .confirm)
                    .submitLabel(.go)
                    .onSubmit { if ready { Task { await change() } } }
                    .profileInput()
                    .accessibilityLabel("Confirm new password")
                    .accessibilityIdentifier("confirmPassword")
            }
            Button(busy ? "Changing…" : "Change password") { Task { await change() } }
                .buttonStyle(.accentPill)
                .disabled(busy || !ready)
                .accessibilityIdentifier("submitPassword")
            if let result {
                ProfileNote(text: result.text, good: result.ok).accessibilityIdentifier("passwordResult")
            }
        }
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .onChange(of: result?.text) { _, text in
            if let text { UIAccessibility.post(notification: .announcement, argument: text) }
        }
    }

    private func change() async {
        guard ProfileWords.passwordReady(current: current, next: next, confirm: confirm), !busy else { return }
        busy = true
        result = nil
        defer { busy = false }
        do {
            let (old, new) = (current, next)
            try await dashboard.fetch { try await $0.changePassword(current: old, next: new) }
            current = ""
            next = ""
            confirm = ""
            focus = nil
            result = (true, ProfileWords.passwordChanged)
        } catch is CancellationError {
        } catch {
            // A 401 means the session had already gone: the sign-in screen takes over.
            if dashboard.phase == .ready { result = (false, error.localizedDescription) }
        }
    }
}
