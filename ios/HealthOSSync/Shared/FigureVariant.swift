import UIKit

/// Which digital human to show (FigureVariant in src/components/Figure.tsx): the one chosen, else the one that follows
/// gender, else the man. Onboarding (A), Home (B), Profile (D) and Body (I) all show it.
enum FigureVariant: String, CaseIterable {
    case woman, man

    /// The one chosen (`settings.figure`), else the woman for a woman, else the man (figureVariant).
    static func of(_ settings: ServerStatus.Settings?) -> FigureVariant {
        if let chosen = settings?.figure.flatMap(FigureVariant.init(rawValue:)) { return chosen }
        return settings?.gender == "woman" ? .woman : .man
    }

    /// The figure actually drawn for this choice (useDrawnVariant): the woman only once her artwork exists, as the web
    /// falls back to the man's without it. Every label that names the figure uses this, so none says "woman" over the
    /// man's artwork. Only the man's (Assets: DigitalMan) is drawn so far.
    var drawn: FigureVariant { self == .woman && UIImage(named: FigureVariant.woman.assetName) != nil ? .woman : .man }

    /// The artwork in Assets.xcassets: DigitalMan (the web's figures/digital-man.webp), DigitalWoman once it exists.
    var assetName: String { self == .woman ? "DigitalWoman" : "DigitalMan" }
}
