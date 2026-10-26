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
        if settings.onboarding != nil { return .new }
        return welcomeEditing ? .edit : nil
    }

    /// At launch, before the server has said who's signed in (`.starting`), the status kept from the last launch says
    /// this person's welcome isn't done: the shell shows a plain page in place of the app rather than draw Home's frame
    /// first, as the web shows nothing until the status is known. Signed in, the welcome takes its place at once; signed
    /// out, the page goes and the sign-in screen shows.
    var welcomeHeld: Bool {
        guard phase == .starting, let settings = status?.settings, settings.perspective != nil else { return false }
        return settings.onboarding != nil
    }

    /// The welcome asked for from Profile is done or left: back to Profile, as the web's "Back to Profile" and its Save.
    func closeWelcome() {
        welcomeEditing = false
        open(.profile)
    }
}
