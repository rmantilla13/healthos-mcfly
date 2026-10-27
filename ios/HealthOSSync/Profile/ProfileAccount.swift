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
/// nothing to change. While the sign-in mode isn't known yet (offline at launch), the email kept from the last status
/// with nothing to change, and no row at all when there's no email to show. Whether the form is open, and what's typed
/// in it, is the page's (`draft`), so it outlives a fold on the open iPhone Duo.
struct ProfileAccountRow: View {
    let draft: ProfilePasswordDraft
    var divider = true
    @Environment(Dashboard.self) private var dashboard

    /// Whether the row shows at all: something to say, or sign-in to change.
    @MainActor
    static func shown(_ dashboard: Dashboard) -> Bool {
        line(dashboard) != nil || dashboard.signOutOffered
    }

    @MainActor
    private static func line(_ dashboard: Dashboard) -> String? {
        let user = dashboard.status?.user ?? dashboard.account
        return ProfileWords.account(mode: dashboard.authMode, email: user?.email ?? dashboard.account?.email, role: user?.role)
    }

    var body: some View {
        let signedIn = dashboard.signOutOffered
        let line = Self.line(dashboard)
        if line != nil || signedIn {
            row(line: line, signedIn: signedIn)
        }
    }

    private func row(line: String?, signedIn: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ProfileRow("Account", divider: false) {
                if let line {
                    Text(line).accessibilityIdentifier("accountEmail")
                }
            } action: {
                if signedIn {
                    // Side by side, or one over the other at the largest text sizes.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) { actions }
                        VStack(alignment: .leading, spacing: 6) { actions }
                    }
                }
            }
            if signedIn, draft.open {
                ProfilePasswordForm(draft: draft)
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
        Button("Change password") { draft.open.toggle() }
            .buttonStyle(ProfileQuietStyle())
            .accessibilityValue(draft.open ? "Expanded" : "Collapsed")
            .accessibilityIdentifier("changePassword")
    }
}

/// Change password's form as the page keeps it: open or not, the three fields, whether a change is on its way and what
/// came of it. The passwords live only here, in memory, while Profile is up; `reset()` clears them (signed out, someone
/// else signed in), and a change that went through clears them itself.
@MainActor
@Observable
final class ProfilePasswordDraft {
    var open = false
    var current = ""
    var next = ""
    var confirm = ""
    var busy = false
    var result: (ok: Bool, text: String)?

    func reset() {
        open = false
        current = ""
        next = ""
        confirm = ""
        busy = false
        result = nil
    }
}

/// Current, new and confirm (the web's PasswordForm): Change password once the new one is at least 10 characters and
/// typed the same twice. The fields are marked for passwords, so iOS offers to keep the new one. Then the web's
/// "Password changed. Other devices are signed out." or the server's words. The passwords live only in the page's
/// draft while Profile is up, and are cleared once changed.
struct ProfilePasswordForm: View {
    @Bindable var draft: ProfilePasswordDraft
    @Environment(Dashboard.self) private var dashboard
    @FocusState private var focus: Field?

    private enum Field { case current, next, confirm }

    var body: some View {
        let ready = ProfileWords.passwordReady(current: draft.current, next: draft.next, confirm: draft.confirm)
        VStack(alignment: .leading, spacing: 16) {
            ProfileField("Current password") {
                SecureField("", text: $draft.current)
                    .textContentType(.password)
                    .focused($focus, equals: .current)
                    .submitLabel(.next)
                    .onSubmit { focus = .next }
                    .profileInput()
                    .accessibilityLabel("Current password")
                    .accessibilityIdentifier("currentPassword")
            }
            ProfileField("New password", hint: ProfileWords.passwordHint, hintIsBad: !draft.next.isEmpty && draft.next.count < ProfileWords.passwordMinimum) {
                SecureField("", text: $draft.next)
                    .textContentType(.newPassword)
                    .focused($focus, equals: .next)
                    .submitLabel(.next)
                    .onSubmit { focus = .confirm }
                    .profileInput()
                    .accessibilityLabel("New password")
                    .accessibilityIdentifier("newPassword")
            }
            ProfileField("Confirm new password", hint: !draft.confirm.isEmpty && draft.confirm != draft.next ? ProfileWords.passwordsDiffer : nil, hintIsBad: true) {
                SecureField("", text: $draft.confirm)
                    .textContentType(.newPassword)
                    .focused($focus, equals: .confirm)
                    .submitLabel(.go)
                    .onSubmit { if ready { Task { await change() } } }
                    .profileInput()
                    .accessibilityLabel("Confirm new password")
                    .accessibilityIdentifier("confirmPassword")
            }
            Button(draft.busy ? "Changing…" : "Change password") { Task { await change() } }
                .buttonStyle(ProfilePillStyle(.accent, size: .regular))
                .disabled(draft.busy || !ready)
                .accessibilityIdentifier("submitPassword")
            if let result = draft.result {
                ProfileNote(text: result.text, good: result.ok).accessibilityIdentifier("passwordResult")
            }
        }
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .onChange(of: draft.result?.text) { _, text in
            if let text { UIAccessibility.post(notification: .announcement, argument: text) }
        }
    }

    private func change() async {
        guard ProfileWords.passwordReady(current: draft.current, next: draft.next, confirm: draft.confirm), !draft.busy else { return }
        draft.busy = true
        draft.result = nil
        defer { draft.busy = false }
        do {
            let (old, new) = (draft.current, draft.next)
            // Only for the session it was asked under: answered after a Sign out or someone else's sign-in, it says
            // nothing to whoever is here now (and its new session isn't kept, `APIClient.checked`).
            try await dashboard.fetchForThisSession { try await $0.changePassword(current: old, next: new) }
            draft.current = ""
            draft.next = ""
            draft.confirm = ""
            focus = nil
            draft.result = (true, ProfileWords.passwordChanged)
        } catch is CancellationError {
        } catch {
            // A 401 means the session had already gone: the sign-in screen takes over.
            if dashboard.phase == .ready { draft.result = (false, error.localizedDescription) }
        }
    }
}
