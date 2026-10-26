import Foundation

/// The welcome's words, quoted from src/pages/Onboarding.tsx, so the iPhone says what the web says. The steps' own
/// headings are `OnboardingStep`, the views `PerspectiveStep.views`, the genders `Gender.label` and the photo's notes
/// `ReferencePhoto`. OnboardingTests checks them all against that file; keep them in step.
enum OnboardingWords {
    static let eyebrow = "Make this space yours"
    static let backToProfile = "Back to Profile"
    static let signOut = "Sign out"
    static let saving = "Saving…"
    static let continueButton = "Continue"
    static let savePreferences = "Save preferences"
    static let enterWorkspace = "Enter my workspace"
    static let defaultBadge = "Default"

    // Step 1's reference photo.
    static let referenceTitle = "The reference for your portrait"
    static let referenceText = "Choose a clear photo of just you. We use it to create your portrait, with the healthOS figure as the style reference."
    static let referenceSaving = "Saving your photo…"
    static let referenceSaved = "Saved for your portrait studio."
    static let referenceEarlier = "A photo you added earlier is saved for your portrait studio."
    static let choosePhoto = "Choose photo"
    static let change = "Change"
    static let remove = "Remove"
    static let referenceAfter = "Your photo stays private; it is not displayed on your dashboard. You can do this later."
    static let referenceAlt = "The photo you chose"

    // Step 2.
    static let genderQuestion = "How do you describe yourself?"
    static let genderNote = "Used for your profile, not to assume a body type or assign a health score."
    static let ageLabel = "Your age"
    static let ageUnit = "years"
    static let ageError = "Enter your age in whole years."
    static var ageNote: String { "Your age is kept private. Peer comparisons are for people aged \(Peers.minAge) and over." }
    static let showMeAs = "Show me as"

    // Step 3.
    static let peersTitle = "A private place in the bigger picture."
    static var peersText: String {
        "Compare \(Peers.windowDays)-day averages within your age group, using the same measurement and source. In comparisons, your name, photo and individual readings are never shown to anyone else: others see only group figures."
    }
    static let consentTitle = "Include me in anonymous peer comparisons"
    static var consentText: String {
        "Your \(Peers.windowDays)-day averages count toward the group's median and quartiles. Results need at least \(Peers.minOthers) other participating people and \(Peers.minDays) recorded days per person. You can leave anytime in Profile."
    }
    static let consentNeedsAge = "Add your age on step 2 to take part."
    static var consentAdults: String { "Peer comparisons are for people aged \(Peers.minAge) and over." }
    static let peersNote = "You see which quarter of this healthOS group your average sits in. Sitting higher in the group does not necessarily mean better health. No public profiles or global health scores."
}
