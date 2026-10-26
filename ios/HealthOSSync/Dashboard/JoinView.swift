import SwiftUI

/// "Join with an invite code" (Login.tsx's code step): the code the admin gave, or the whole invite link, then the page
/// it opens (AccountLinkView). The same step takes a reset link, pasted (only the iPhone has it: the web opens one in the
/// browser). A pasted link of the other kind opens its own page.
///
/// A code or link that can't be one is turned down here, never sent: a failed check counts toward the sign-in lockout
/// that a whole household shares.
struct JoinView: View {
    let kind: AccountLinkKind
    let back: () -> Void
    let open: (AccountLinkKind, String) -> Void
    @State private var code = ""
    @State private var error: String?
    @FocusState private var focus: Bool?

    var body: some View {
        WelcomeCard {
            WelcomeHead(eyebrow: kind == .invite ? SignInWords.joinEyebrow : SignInWords.resetEyebrow,
                        title: kind == .invite ? SignInWords.joinTitle : SignInWords.resetLinkTitle,
                        lede: kind == .invite ? SignInWords.joinLede : SignInWords.resetLinkLede)
            WelcomeField(kind == .invite ? SignInWords.codeLabel : SignInWords.resetLinkLabel, text: $code, focus: $focus, field: true, invalid: error != nil)
                // Codes are ABCD-EFGH, in capitals as you type; a pasted link keeps its case (link tokens are
                // case-sensitive).
                .textInputAutocapitalization(kind == .invite ? .characters : .never)
                .keyboardType(kind == .invite ? .asciiCapable : .URL)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .onSubmit(next)
                .onChange(of: code) { _, _ in error = nil }
                .accessibilityIdentifier("inviteCode")
            if let error { ErrorNote(error).accessibilityIdentifier("codeError") }
            WelcomeFoot {
                Button(action: back) { BackLabel(SignInWords.backToSignIn) }
                    .buttonStyle(.welcomeLink)
                    .accessibilityIdentifier("backToSignIn")
            } main: {
                Button(action: next) { WelcomeButtonLabel(SignInWords.continueButton, arrow: true) }
                    .buttonStyle(.accentPill)
                    .disabled(!AccountLink.filled(code))
                    .accessibilityIdentifier("continue")
            }
        }
        .onAppear { focus = true }
        .keyboardDismissal()
    }

    private func next() {
        guard AccountLink.filled(code) else { return }
        switch AccountLink.entered(code, on: kind) {
        case .success(let (kind, token)):
            focus = nil
            open(kind, token)
        case .failure(let shape):
            error = shape.localizedDescription
        }
    }
}
