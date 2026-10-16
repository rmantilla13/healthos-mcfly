import SwiftUI
import UIKit

/// Color tokens from src/styles.css, light and dark.
enum Palette {
    static let page = dynamic(0xF3F3F1, 0x0D0D0D)
    static let surface = dynamic(0xFFFFFF, 0x1A1A19)
    static let surface2 = dynamic(0xF6F6F4, 0x222221)
    static let border = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.08) : UIColor(white: 0.04, alpha: 0.07) })
    static let ink = dynamic(0x0B0B0B, 0xF0EFEC)
    static let ink2 = dynamic(0x52514E, 0xC3C2B7)
    static let ink3 = dynamic(0x898781, 0x898781)
    static let grid = dynamic(0xECEBE6, 0x2C2C2A)

    static let series1 = dynamic(0x2A78D6, 0x3987E5)
    static let series2 = dynamic(0xEB6834, 0xD95926)
    static let series3 = dynamic(0x1BAF7A, 0x199E70)
    static let bar = dynamic(0x9EC5F4, 0x256ABF)
    static let barNeutral = dynamic(0xD9D8D2, 0x3A3A37)
    static let barNeutralAccent = dynamic(0x3B3A37, 0xE8E7E2)

    static let stageDeep = dynamic(0x0D366B, 0x9EC5F4)
    static let stageLight = dynamic(0x1C5CAB, 0x5598E7)
    static let stageRem = dynamic(0x3987E5, 0x2A78D6)
    static let stageAwake = dynamic(0x86B6EF, 0x184F95)

    static let good = dynamic(0x0CA30C, 0x0CA30C)
    static let goodText = dynamic(0x006300, 0x0CA30C)
    static let warning = dynamic(0xFAB219, 0xFAB219)
    static let serious = dynamic(0xEC835A, 0xEC835A)
    static let critical = dynamic(0xD03B3B, 0xD03B3B)

    static let goalTrack = dynamic(0xD8F0D0, 0x1F3A1C)
    static let gaugeTrack = dynamic(0xF3C3CF, 0x5A2A38)
    static let gaugeFill = dynamic(0xD9537A, 0xE8668C)
    static let chip = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.08) : UIColor(white: 1, alpha: 0.7) })

    static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// Soft background tones for insight icons and chips (tone-* in the CSS).
enum Tone {
    case green, peach, blue, yellow, pink, neutral

    var background: Color {
        switch self {
        case .green: Palette.dynamic(0xDFF3D8, 0x1D3A1B)
        case .peach: Palette.dynamic(0xFFE4D4, 0x432617)
        case .blue: Palette.dynamic(0xE1E7FB, 0x1F2747)
        case .yellow: Palette.dynamic(0xFDF0CC, 0x3D3112)
        case .pink: Palette.dynamic(0xFDE2E8, 0x3F1D28)
        case .neutral: Palette.surface2
        }
    }

    var ink: Color {
        switch self {
        case .green: Palette.dynamic(0x1F6B1F, 0x8FDC85)
        case .peach: Palette.dynamic(0xA2471F, 0xF4A97F)
        case .blue: Palette.dynamic(0x3A4FB0, 0xA7B4F3)
        case .yellow: Palette.dynamic(0x8A6400, 0xF0C95A)
        case .pink: Palette.dynamic(0xA33A57, 0xF19AB2)
        case .neutral: Palette.ink2
        }
    }
}

/// The gradient washes behind the recovery, blood oxygen and strain cards.
enum CardTint {
    case plain, green, peach, pink

    func background(_ scheme: ColorScheme) -> AnyShapeStyle {
        let dark = scheme == .dark
        let stops: [UInt32]
        let center: UnitPoint
        switch self {
        case .plain: return AnyShapeStyle(Palette.surface)
        case .green: stops = dark ? [0x1F3A1C, 0x1B261A, 0x1A1A19] : [0xD4F0CB, 0xE9F6E3, 0xF9FCF7]; center = .topLeading
        case .peach: stops = dark ? [0x4A2A1A, 0x2F201D, 0x1D1A1B] : [0xFFD6B8, 0xFFE6DC, 0xFDF0F2]; center = .topTrailing
        case .pink: stops = dark ? [0x3D2028, 0x2A1D21, 0x1C1A1B] : [0xFDE0E6, 0xFDEDF0, 0xFEFAFB]; center = .top
        }
        return AnyShapeStyle(RadialGradient(colors: stops.map { Color(UIColor(hex: $0)) }, center: center, startRadius: 0, endRadius: 260))
    }
}

struct CardStyle: ViewModifier {
    var tint: CardTint = .plain
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.background(scheme), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Palette.border))
    }
}

extension View {
    func card(_ tint: CardTint = .plain) -> some View { modifier(CardStyle(tint: tint)) }
}

/// Big number with a small unit after it, the dashboard's main figure style.
struct BigValue: View {
    let value: String
    let unit: String
    var size: CGFloat = 34

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value).font(.system(size: size, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(unit).font(.subheadline).foregroundStyle(Palette.ink3)
        }
        .foregroundStyle(Palette.ink)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }
}

struct Chip: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Palette.chip, in: Capsule())
            .foregroundStyle(Palette.ink2)
    }
}
