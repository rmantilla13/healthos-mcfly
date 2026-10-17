import SwiftUI

/// Create an account from an invite code (or a pasted invite link), then sign in. Same fields and
/// rules as the web's invite page.
struct JoinView: View {
    @Environment(Dashboard.self) private var dashboard
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var confirm = ""
    @State private var error: String?
    @State private var busy = false
    @FocusState private var focus: Field?

    private enum Field { case code, name, email, password, confirm }

    static let minPassword = 10

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // Codes are ABCD-EFGH; capitals as you type. A pasted link keeps its case (old links are case-sensitive).
                    TextField("Invite code, e.g. ABCD-EFGH", text: $code)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .focused($focus, equals: .code)
                        .onSubmit { focus = .name }
                        .accessibilityIdentifier("inviteCode")
                } footer: {
                    Text("From the person who runs this healthOS. You can also paste the whole invite link.")
                }
                Section {
                    TextField("Name", text: $name)
                        .textContentType(.name)
                        .submitLabel(.next)
                        .focused($focus, equals: .name)
                        .onSubmit { focus = .email }
                    TextField("Email", text: $email)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .focused($focus, equals: .email)
                        .onSubmit { focus = .password }
                    SecureField("Password", text: $password)
                        .textContentType(.newPassword)
                        .submitLabel(.next)
                        .focused($focus, equals: .password)
                        .onSubmit { focus = .confirm }
                    SecureField("Confirm password", text: $confirm)
                        .textContentType(.newPassword)
                        .submitLabel(.join)
                        .focused($focus, equals: .confirm)
                        .onSubmit(submit)
                } footer: {
                    Text(passwordHint)
                }
                if let error {
                    Section { Text(error).foregroundStyle(Palette.critical) }
                }
                Section {
                    Button(action: submit) {
                        HStack {
                            Text("Create account").bold()
                            Spacer()
                            if busy { ProgressView() }
                        }
                    }
                    .disabled(!ready || busy)
                    .accessibilityIdentifier("createAccount")
                }
            }
            .navigationTitle("Join healthOS")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Join", action: submit).disabled(!ready || busy)
                }
            }
            .keyboardDismissal()
            .onAppear { focus = .code }
        }
    }

    private var passwordHint: String {
        if !password.isEmpty, password.count < Self.minPassword { return "Use at least \(Self.minPassword) characters." }
        if !confirm.isEmpty, confirm != password { return "The passwords don't match." }
        return "At least \(Self.minPassword) characters."
    }

    private var ready: Bool {
        !APIClient.inviteToken(from: code).isEmpty && email.contains("@") && password.count >= Self.minPassword && password == confirm
    }

    private func submit() {
        guard ready, !busy else { return }
        focus = nil
        busy = true
        error = nil
        Task {
            do {
                try await dashboard.join(code: code, name: name.trimmingCharacters(in: .whitespaces), email: email.trimmingCharacters(in: .whitespaces), password: password)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}
