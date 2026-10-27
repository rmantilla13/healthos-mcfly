import Foundation

/// How the person chose to see themselves (shared/types.ts Perspective, the server's one `settings.perspective`):
/// their own portrait, the digital human, or just the statistics. The welcome (A) asks for it, and Home (B), Profile (D)
/// and Body (I) show it.
///
/// `ServerStatus.Settings.perspective` stays the server's raw field: whether it's there at all is what says the server
/// has the welcome and Edit preferences (an older server sends none), so a value this build doesn't know never hides
/// them. `of` is how every page reads it.
enum Perspective: String, CaseIterable, Identifiable {
    case portrait, digital, stats
    var id: String { rawValue }

    /// The person's, from their settings, as the web reads it (`settings?.perspective ?? 'portrait'` in App.tsx, Body.tsx
    /// and onboardingFlow.ts): a server older than the welcome, or a value this build doesn't know, reads as the portrait.
    static func of(_ settings: ServerStatus.Settings?) -> Perspective {
        settings?.perspective.flatMap(Perspective.init(rawValue:)) ?? .portrait
    }
}
