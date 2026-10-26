import SwiftUI
import UIKit

/// DM Sans, the web's face (`@fontsource-variable/dm-sans`, src/main.tsx), for all of the app's text.
///
/// It's bundled as Fonts/DMSans-Variable.ttf, rebuilt from the web's own latin file, with its licence (Fonts/OFL.txt)
/// beside it, and registered in UIAppFonts. One variable file: each weight is a point on its wght axis, 100 to 1000.
/// Characters outside latin fall back to the system face, as on the web.
///
/// Text sizes follow Dynamic Type: a size is the one at the default text size, scaled like the text style it's relative to.
/// SwiftUI text names the file's own instances (wght 100, 200 … 900), so it follows a text size change while the app
/// is open; a Font made from a UIFont would keep the size it was made at. UIKit (bar titles) sets the axis directly.
///
/// The file has no tabular figures (the web's subset has no tnum), so `.monospacedDigit()` doesn't change DM Sans digits:
/// numbers are proportional here, as on the web.
enum AppFont {
    static let family = "DM Sans 9pt"
    /// The file's default instance (wght 400).
    static let postScriptName = "DMSans9pt-Regular"
    /// The variation axis tag 'wght'.
    static let weightAxis: UInt32 = 0x77676874

    /// Where a weight sits on the wght axis, as CSS numbers it.
    static func axisValue(_ weight: Font.Weight) -> CGFloat {
        switch weight {
        case .ultraLight: 200
        case .thin: 100
        case .light: 300
        case .medium: 500
        case .semibold: 600
        case .bold: 700
        case .heavy: 800
        case .black: 900
        default: 400
        }
    }

    /// The file's named instance for a weight: the same point on the wght axis as `axisValue`.
    static func instanceName(_ weight: Font.Weight) -> String {
        switch weight {
        case .ultraLight: postScriptName + "_ExtraLight"
        case .thin: postScriptName + "_Thin"
        case .light: postScriptName + "_Light"
        case .medium: postScriptName + "_Medium"
        case .semibold: postScriptName + "_SemiBold"
        case .bold: postScriptName + "_Bold"
        case .heavy: postScriptName + "_ExtraBold"
        case .black: postScriptName + "_Black"
        default: postScriptName
        }
    }

    /// The system's own weight for a text style: only the headline is semibold.
    static func defaultWeight(_ style: Font.TextStyle) -> Font.Weight {
        style == .headline ? .semibold : .regular
    }

    /// A text style's size at the default text size (the system's, at Large).
    static func size(_ style: Font.TextStyle) -> CGFloat {
        UIFontDescriptor.preferredFontDescriptor(withTextStyle: style.uiKit, compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)).pointSize
    }

    /// DM Sans at a point on the wght axis, through the font descriptor's variation attribute. With a text style, scaled
    /// for the text size in `traits` (the app's own when nil). The system face if the font isn't registered.
    static func uiFont(size: CGFloat, weight: Font.Weight = .regular, relativeTo style: UIFont.TextStyle? = nil, compatibleWith traits: UITraitCollection? = nil) -> UIFont {
        let variation = UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String)
        let descriptor = UIFontDescriptor(fontAttributes: [
            .name: postScriptName,
            variation: [NSNumber(value: weightAxis): NSNumber(value: Double(axisValue(weight)))],
        ])
        var font = UIFont(descriptor: descriptor, size: size)
        if font.familyName != family { font = .systemFont(ofSize: size, weight: weight.uiKit) }
        guard let style else { return font }
        return UIFontMetrics(forTextStyle: style).scaledFont(for: font, compatibleWith: traits)
    }

    /// Bar titles, tab labels and segmented pickers are drawn by UIKit: DM Sans there too, at the web's heading weight
    /// (500). Set once at launch, before any bar is made.
    @MainActor static func styleBars() {
        let bar = UINavigationBar.appearance()
        let ink = UIColor(Palette.ink)
        bar.titleTextAttributes = [.font: uiFont(size: 17, weight: .medium, relativeTo: .headline), .foregroundColor: ink]
        bar.largeTitleTextAttributes = [.font: uiFont(size: 34, weight: .medium, relativeTo: .largeTitle), .foregroundColor: ink]
        UITabBarItem.appearance().setTitleTextAttributes([.font: uiFont(size: 10, weight: .medium, relativeTo: .caption2)], for: .normal)
        let segments = UISegmentedControl.appearance()
        segments.setTitleTextAttributes([.font: uiFont(size: 13, weight: .medium, relativeTo: .footnote)], for: .normal)
        segments.setTitleTextAttributes([.font: uiFont(size: 13, weight: .semibold, relativeTo: .footnote)], for: .selected)
    }
}

extension Font {
    /// DM Sans in a text style's size, at its own weight (semibold for the headline) unless one is given.
    ///
    ///     Text("Steps").font(.app(.subheadline, weight: .medium))
    static func app(_ style: Font.TextStyle, weight: Font.Weight? = nil) -> Font {
        app(size: AppFont.size(style), weight: weight ?? AppFont.defaultWeight(style), relativeTo: style)
    }

    /// DM Sans in the web's own size (its px are points here), scaled for the text size like `style`.
    ///
    ///     Text("YOUR WORKSPACE").font(.app(size: 11, weight: .medium, relativeTo: .caption2))
    static func app(size: CGFloat, weight: Font.Weight = .regular, relativeTo style: Font.TextStyle = .body) -> Font {
        .custom(AppFont.instanceName(weight), size: size, relativeTo: style)
    }

    /// DM Sans at one size whatever the text size, for text drawn to fit a shape (an avatar's initial, a ring's figure).
    static func app(fixedSize size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom(AppFont.instanceName(weight), fixedSize: size)
    }
}

extension Font.TextStyle {
    var uiKit: UIFont.TextStyle {
        switch self {
        case .largeTitle: .largeTitle
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption1
        case .caption2: .caption2
        default: .body
        }
    }
}

extension Font.Weight {
    var uiKit: UIFont.Weight {
        switch self {
        case .ultraLight: .ultraLight
        case .thin: .thin
        case .light: .light
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        case .black: .black
        default: .regular
        }
    }
}
