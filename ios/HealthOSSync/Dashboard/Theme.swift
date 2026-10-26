import SwiftUI
import UIKit

/// The web's colours (src/styles.css, light and dark), by the names the app uses. Each is a token in Tokens.swift,
/// which ThemeTests checks against the CSS.
enum Palette {
    static let page = ColorToken.page.color
    static let pageGlow = ColorToken.pageGlow.color
    static let sidebar = ColorToken.sidebar.color
    static let sidebarEdge = ColorToken.sidebarEdge.color
    /// Vital callouts on the portrait: temperature's amber, and the heart's pink (web --vital-pulse, styles.css 1991-2006).
    static let vitalTemp = dynamic(0xF2CF63, 0xF2CF63)
    static let vitalHeart = dynamic(0xE0567C, 0xF27798)
    static let surface = ColorToken.surface.color
    static let surface2 = ColorToken.surface2.color
    static let surfaceHover = ColorToken.surfaceHover.color
    static let border = ColorToken.border.color
    /// Green-black ink, and two muted steps of it.
    static let ink = ColorToken.ink.color
    static let ink2 = ColorToken.ink2.color
    static let ink3 = ColorToken.ink3.color
    static let grid = ColorToken.grid.color
    static let axis = ColorToken.axis.color

    static let series1 = ColorToken.series1.color
    static let series2 = ColorToken.series2.color
    static let series3 = ColorToken.series3.color
    static let bar = ColorToken.bar.color
    static let barAccent = ColorToken.barAccent.color
    static let barNeutral = ColorToken.barNeutral.color
    static let barNeutralAccent = ColorToken.barNeutralAccent.color

    static let stageDeep = ColorToken.stageDeep.color
    static let stageLight = ColorToken.stageLight.color
    static let stageRem = ColorToken.stageRem.color
    static let stageAwake = ColorToken.stageAwake.color

    static let good = ColorToken.good.color
    static let goodText = ColorToken.goodText.color
    static let warning = ColorToken.warning.color
    static let serious = ColorToken.serious.color
    static let critical = ColorToken.critical.color

    /// The accent: a dark forest green for primary buttons, a pale sage for the avatar, sage text, and the focus ring.
    static let accent = ColorToken.accent.color
    static let accentInk = ColorToken.accentInk.color
    static let accentText = ColorToken.accentText.color
    static let accentSoft = ColorToken.accentSoft.color
    static let accentSoftInk = ColorToken.accentSoftInk.color
    static let focus = ColorToken.focus.color
    static let navDot = ColorToken.navDot.color
    /// The app's tint: the forest accent. In dark mode it's the accent's text step (--accent-text), as the web uses for
    /// words: the dark accent itself (#4d6b5a) reads under 3:1 as button text on the dark surface.
    static let tint = Themed(ColorToken.accent.value.light, ColorToken.accentText.value.dark).color

    /// A chosen option (radio cards, chips): a sage edge over a faint green wash (GradientToken.choiceWash).
    static let choiceBorder = ColorToken.choiceBorder.color
    static let menuBorder = ColorToken.menuBorder.color
    /// The light blurred veil behind a dialog.
    static let veil = ColorToken.veil.color
    /// A card's white (not dark) edge.
    static let cardEdge = ColorToken.cardEdge.color

    /// The figure's callouts: a gold dot in a thin gold ring, warm grey leader lines.
    static let calloutDot = ColorToken.calloutDot.color
    static let calloutRing = ColorToken.calloutRing.color
    static let calloutLine = ColorToken.calloutLine.color
    static let figureGlow = ColorToken.figureGlow.color
    static let figure1 = ColorToken.figure1.color
    static let figure2 = ColorToken.figure2.color
    static let figure3 = ColorToken.figure3.color
    static let figureShade = ColorToken.figureShade.color
    static let figureShadow = ColorToken.figureShadow.color
    static let figureHighlight = ColorToken.figureHighlight.color
    static let halo = ColorToken.halo.color
    static let haloRing = ColorToken.haloRing.color
    static let ringOnCard = ColorToken.ringOnCard.color

    /// McFly's orb (Orb.swift).
    static let orbCore = ColorToken.orbCore.color
    static let orbMid = ColorToken.orbMid.color
    static let orbRim = ColorToken.orbRim.color

    static let tooltip = ColorToken.tooltip.color
    static let tooltipInk = ColorToken.tooltipInk.color
    static let bannerGoodBg = ColorToken.bannerGoodBg.color
    static let bannerBadBg = ColorToken.bannerBadBg.color
    static let bannerBadInk = ColorToken.bannerBadInk.color

    static let goalTrack = ColorToken.goalTrack.color
    static let gaugeTrack = ColorToken.gaugeTrack.color
    static let gaugeFill = ColorToken.gaugeFill.color

    /// Cycle: a one-hue blue ramp for the chance of conception (darker is higher), peach after ovulation.
    static let fertileMedium = ColorToken.fertileMedium.color
    static let fertileHigh = ColorToken.fertileHigh.color
    static let fertilePeak = ColorToken.fertilePeak.color
    static let fertilePeakInk = ColorToken.fertilePeakInk.color
    static let cycleLuteal = ColorToken.cycleLuteal.color

    /// Sleep and Body: awake time in pink, time in bed a quiet grey; the score bar's lavender-to-green; green and orange bars.
    static let hypAwake = ColorToken.hypAwake.color
    static let hypInbed = ColorToken.hypInbed.color
    static let scoreFrom = ColorToken.scoreFrom.color
    static let scoreMid = ColorToken.scoreMid.color
    static let scoreTo = ColorToken.scoreTo.color
    static let barGreen = ColorToken.barGreen.color
    static let barGreenAccent = ColorToken.barGreenAccent.color
    static let barOrange = ColorToken.barOrange.color

    /// A soft white chip, and the pale green one on metric cards.
    static let chip = ColorToken.chip.color
    static let chipGreen = ColorToken.chipGreen.color

    static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color { Themed(light, dark).color }
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
        case .green: ColorToken.toneGreenBg.color
        case .peach: ColorToken.tonePeachBg.color
        case .blue: ColorToken.toneBlueBg.color
        case .yellow: ColorToken.toneYellowBg.color
        case .pink: ColorToken.tonePinkBg.color
        case .neutral: Palette.surface2
        }
    }

    var ink: Color {
        switch self {
        case .green: ColorToken.toneGreenInk.color
        case .peach: ColorToken.tonePeachInk.color
        case .blue: ColorToken.toneBlueInk.color
        case .yellow: ColorToken.toneYellowInk.color
        case .pink: ColorToken.tonePinkInk.color
        case .neutral: Palette.ink2
        }
    }
}

/// A card's background: the white glass sheen, or the sheen under a colour wash strongest near the bottom
/// (.metric-green … .metric-blue on the web).
enum CardTint: CaseIterable {
    case plain, green, peach, pink, lavender, mint, slate, cream, blush, blue

    var gradient: GradientToken {
        switch self {
        case .plain: .sheen
        case .green: .gradGreen
        case .peach: .gradPeach
        case .pink: .gradPink
        case .lavender: .gradLavender
        case .mint: .gradMint
        case .slate: .gradSlate
        case .cream: .gradCream
        case .blush: .gradBlush
        case .blue: .gradBlue
        }
    }
}

/// A card's surface in any shape: its wash, the white edge and the soft card shadow (.card on the web).
struct CardSurface<S: InsettableShape>: View {
    var tint: CardTint = .plain
    let shape: S

    var body: some View {
        GradientFill(tint.gradient)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Palette.cardEdge))
            .tokenShadow(.card, in: shape)
    }
}

struct CardStyle: ViewModifier {
    var tint: CardTint = .plain

    func body(content: Content) -> some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { CardSurface(tint: tint, shape: RoundedRectangle(cornerRadius: Radius.card, style: .continuous)) }
    }
}

extension View {
    func card(_ tint: CardTint = .plain) -> some View { modifier(CardStyle(tint: tint)) }
}

/// Big number with a small unit after it, the dashboard's main figure style (.metric-value: 500, drawn in tight).
struct BigValue: View {
    let value: String
    let unit: String
    var size: CGFloat = 34

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value).font(.app(size: size, weight: .medium, relativeTo: .largeTitle)).tracking(-0.03 * size)
            Text(unit).font(.app(.footnote)).foregroundStyle(Palette.ink2)
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
            .font(.app(.caption, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Palette.chip, in: Capsule())
            .foregroundStyle(Palette.ink2)
    }
}

/// The healthOS mark, drawn like the dashboard's Logo (src/App.tsx) and the app icon.
struct BrandMark: View {
    var body: some View {
        Canvas { ctx, size in
            let unit = min(size.width, size.height) / 32
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            var rays = Path()
            for i in 0..<24 {
                let a = Double(i) / 24 * .pi * 2
                let r1 = 5 + Double(i % 2) * 1.5
                let r2 = 13 - Double(i % 3)
                rays.move(to: CGPoint(x: c.x + r1 * unit * cos(a), y: c.y + r1 * unit * sin(a)))
                rays.addLine(to: CGPoint(x: c.x + r2 * unit * cos(a), y: c.y + r2 * unit * sin(a)))
            }
            ctx.stroke(rays, with: .color(Palette.ink), style: StrokeStyle(lineWidth: 1.3 * unit, lineCap: .round))
            let r = 2.4 * unit
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(Palette.ink))
        }
        .accessibilityHidden(true)
    }
}
