import Foundation

/// The way in's words, quoted from src/pages/Login.tsx (sign-in, the code step and AccountLinkPage), so the iPhone says
/// what the web says. AccountLinkTests checks each against that file; keep them in step. The iPhone's own lines (Change
/// server, the reset link it takes pasted, Try again) are marked.
enum SignInWords {
    static let welcomeBack = "Welcome back"
    static let welcome = "Welcome"
    static let signInTitle = "Sign in to healthOS"
    /// A server with no account yet: the first sign-in creates the admin's.
    static let setupTitle = "Create your admin account"
    static let setupLede = "First sign-in: enter your email and the password you set with the setup script. This creates your admin account."
    static let misconfigured = "Sign-in isn't available right now. Please try again later."
    static let haveInvite = "Have an invite code?"
    static let forgot = "Forgot your password? Ask the admin for a reset link."
    static let signIn = "Sign in"
    static let signingIn = "Signing in…"

    static let joinEyebrow = "Join healthOS"
    static let joinTitle = "Join with an invite code"
    static let joinLede = "Enter the code the admin gave you, like ABCD-EFGH."
    static let codeLabel = "Invite code"
    static let backToSignIn = "Back to sign-in"
    static let continueButton = "Continue"

    static let resetEyebrow = "Reset your password"
    static let createTitle = "Create your account"
    static let resetTitle = "Choose a new password"
    static let resetLede = "Setting a new password signs you out everywhere else."
    static let checking = "Checking your link…"
    static let newLink = "Ask the admin for a new link."
    static let goToSignIn = "Go to sign-in"
    static let passwordsDiffer = "The passwords don't match."
    static let nextSteps = "Next, three short steps to make this space yours."
    static let createAccount = "Create account"
    static let setPassword = "Set password"
    static let saving = "Saving…"

    /// "At least 10 characters."
    static var passwordHint: String { "At least \(AccountLink.minPassword) characters." }

    // Only the iPhone's: the web opens a reset link in the browser; here it's pasted on the code step's twin.
    static let haveResetLink = "Have a reset link?"
    static let resetLinkTitle = "Use your reset link"
    static let resetLinkLede = "Paste the reset link the admin gave you."
    static let resetLinkLabel = "Reset link"
}
