import Foundation

/// Which welcome (the web's Onboarding `mode`): a new account's, over everything until it's done, or its steps again
/// for anyone from Profile's Edit preferences (#/welcome).
enum OnboardingMode: String, Identifiable {
    case new, edit
    var id: String { rawValue }
}

extension Dashboard {
    /// The welcome over the app, full screen, as the web shows it instead of the dashboard (App.tsx): `.new` while the
    /// server says this account's onboarding isn't done (after any sign-in, a fresh owner's first one included), `.edit`
    /// once asked for with `open(.welcome)`. Only signed in, and only where the status names `perspective`: an older
    /// server ignores what the welcome saves. The shell shows `OnboardingView(mode:)` (Onboarding/, slice A) for it.
    var onboarding: OnboardingMode? {
        guard phase == .ready, let settings = status?.settings, settings.perspective != nil else { return nil }
        if settings.onboarding != nil, !onboardingPutOff { return .new }
        return welcomeEditing ? .edit : nil
    }

    /// The welcome asked for from Profile is done or left: back to Profile, as the web's "Back to Profile" and its Save.
    func closeWelcome() {
        welcomeEditing = false
        open(.profile)
    }

    /// A new account's welcome put off until the next sign-in or launch. Only the stub offers it, while slice A builds
    /// the flow: the web has no way past its welcome but finishing it or signing out. It never tells the server.
    func putOffOnboarding() { onboardingPutOff = true }
}
