import SwiftUI
import UIKit

// The web's design tokens (src/styles.css): light from its :root block (lines 1-160), dark from the
// prefers-color-scheme block (162-276). A token the dark block doesn't name keeps its light value there, as in the CSS.
// ThemeTests reads styles.css and checks every value here against it, so change both together.

/// A colour as the CSS writes it: `#rrggbb`, or `rgba(r, g, b, a)`.
struct CSSColor: Equatable, CustomStringConvertible {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
    var alpha: Double = 1

    init(_ hex: UInt32) {
        self.init(red: UInt8((hex >> 16) & 0xFF), green: UInt8((hex >> 8) & 0xFF), blue: UInt8(hex & 0xFF))
    }

    init(red: UInt8, green: UInt8, blue: UInt8, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    static func rgba(_ red: UInt8, _ green: UInt8, _ blue: UInt8, _ alpha: Double) -> CSSColor {
        CSSColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    var uiColor: UIColor { UIColor(red: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: alpha) }
    var color: Color { Color(uiColor) }

    var description: String { alpha == 1 ? String(format: "#%02x%02x%02x", red, green, blue) : "rgba(\(red), \(green), \(blue), \(alpha))" }
}

/// A token's light and dark values.
struct Themed<Value> {
    let light: Value
    let dark: Value

    init(_ light: Value, _ dark: Value) {
        self.light = light
        self.dark = dark
    }

    func callAsFunction(_ scheme: ColorScheme) -> Value { scheme == .dark ? dark : light }
}

extension Themed: Equatable where Value: Equatable {}

extension Themed where Value == CSSColor {
    init(_ light: UInt32, _ dark: UInt32) { self.init(CSSColor(light), CSSColor(dark)) }
    /// Not in the dark block: the light value in both.
    static func same(_ hex: UInt32) -> Themed { Themed(hex, hex) }
    static func same(_ color: CSSColor) -> Themed { Themed(color, color) }

    /// Follows the trait collection it's drawn in, like the CSS follows prefers-color-scheme.
    var color: Color {
        let light = light.uiColor, dark = dark.uiColor
        return Color(UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }
}

/// Every colour token in styles.css, by its CSS name (`--page` is `.page`).
enum ColorToken: String, CaseIterable {
    case page, pageGlow = "page-glow", sidebar, sidebarEdge = "sidebar-edge"
    case surface, surface2 = "surface-2", surfaceHover = "surface-hover", border
    case ink, ink2 = "ink-2", ink3 = "ink-3", grid, axis
    case series1 = "series-1", series2 = "series-2", series3 = "series-3"
    case bar, barAccent = "bar-accent", barNeutral = "bar-neutral", barNeutralAccent = "bar-neutral-accent"
    case stageDeep = "stage-deep", stageLight = "stage-light", stageRem = "stage-rem", stageAwake = "stage-awake"
    case good, goodText = "good-text", warning, serious, critical
    case chip, chipGreen = "chip-green"
    case accent, accentInk = "accent-ink", accentText = "accent-text", accentSoft = "accent-soft", accentSoftInk = "accent-soft-ink", focus
    case navDot = "nav-dot"
    case badgeSageBg = "badge-sage-bg", badgeSageInk = "badge-sage-ink", badgePeachBg = "badge-peach-bg", badgePeachInk = "badge-peach-ink"
    case badgeMutedBg = "badge-muted-bg", badgeMutedInk = "badge-muted-ink", badgeBadBg = "badge-bad-bg", badgeBadInk = "badge-bad-ink"
    case choiceBorder = "choice-border", menuBorder = "menu-border", veil, cardEdge = "card-edge"
    case calloutDot = "callout-dot", calloutRing = "callout-ring", calloutLine = "callout-line"
    case orbCore = "orb-core", orbMid = "orb-mid", orbRim = "orb-rim"
    case figureGlow = "figure-glow", figure1 = "figure-1", figure2 = "figure-2", figure3 = "figure-3"
    case figureShade = "figure-shade", figureShadow = "figure-shadow", figureHighlight = "figure-highlight"
    case tooltip, tooltipInk = "tooltip-ink"
    case goalTrack = "goal-track", gaugeTrack = "gauge-track", gaugeFill = "gauge-fill", ringOnCard = "ring-on-card"
    case halo, haloRing = "halo-ring"
    case bannerGoodBg = "banner-good-bg", bannerBadBg = "banner-bad-bg", bannerBadInk = "banner-bad-ink"
    case toneGreenBg = "tone-green-bg", toneGreenInk = "tone-green-ink", tonePeachBg = "tone-peach-bg", tonePeachInk = "tone-peach-ink"
    case toneBlueBg = "tone-blue-bg", toneBlueInk = "tone-blue-ink", toneYellowBg = "tone-yellow-bg", toneYellowInk = "tone-yellow-ink"
    case tonePinkBg = "tone-pink-bg", tonePinkInk = "tone-pink-ink"
    case fertileMedium = "fertile-medium", fertileHigh = "fertile-high", fertilePeak = "fertile-peak", fertilePeakInk = "fertile-peak-ink"
    case cycleLuteal = "cycle-luteal"
    case hypAwake = "hyp-awake", hypInbed = "hyp-inbed", scoreFrom = "score-from", scoreMid = "score-mid", scoreTo = "score-to"
    case barGreen = "bar-green", barGreenAccent = "bar-green-accent", barOrange = "bar-orange"

    var color: Color { value.color }

    var value: Themed<CSSColor> {
        switch self {
        case .page: Themed(0xF4F1EE, 0x0E100E)
        case .pageGlow: Themed(0xFBFAF7, 0x161916)
        case .sidebar: Themed(0xF7F6F2, 0x121412)
        case .sidebarEdge: Themed(0xECEBE6, 0x222622)
        case .surface: Themed(0xFFFFFF, 0x1A1C1A)
        case .surface2: Themed(0xF5F4F0, 0x212421)
        case .surfaceHover: Themed(0xEFEEE9, 0x272A27)
        case .border: Themed(.rgba(36, 49, 42, 0.07), .rgba(255, 255, 255, 0.07))
        case .ink: Themed(0x24312A, 0xEEF0EC)
        case .ink2: Themed(0x5F6661, 0xBCC1BA)
        case .ink3: Themed(0x8A8F8A, 0x8C918C)
        case .grid: Themed(0xECEBE6, 0x2C2C2A)
        case .axis: Themed(0xD6D5CE, 0x383835)
        case .series1: Themed(0x2A78D6, 0x3987E5)
        case .series2: Themed(0xEB6834, 0xD95926)
        case .series3: Themed(0x1BAF7A, 0x199E70)
        case .bar: Themed(0x9EC5F4, 0x256ABF)
        case .barAccent: Themed(0x2A78D6, 0x6DA7EC)
        case .barNeutral: Themed(0xD9D8D2, 0x3A3A37)
        case .barNeutralAccent: Themed(0x3B3A37, 0xE8E7E2)
        case .stageDeep: Themed(0x0D366B, 0x9EC5F4)
        case .stageLight: Themed(0x1C5CAB, 0x5598E7)
        case .stageRem: Themed(0x3987E5, 0x2A78D6)
        case .stageAwake: Themed(0x86B6EF, 0x184F95)
        case .good: .same(0x0CA30C)
        case .goodText: Themed(0x006300, 0x0CA30C)
        case .warning: .same(0xFAB219)
        case .serious: .same(0xEC835A)
        case .critical: .same(0xD03B3B)
        case .chip: Themed(.rgba(255, 255, 255, 0.7), .rgba(255, 255, 255, 0.08))
        case .chipGreen: Themed(0xDBEACF, 0x24461F)
        case .accent: Themed(0x2F4A3D, 0x4D6B5A)
        case .accentInk: Themed(0xFFFFFF, 0xFFFFFF)
        case .accentText: Themed(0x3D5A49, 0xA9C9B2)
        case .accentSoft: Themed(0xE6EFE3, 0x263529)
        case .accentSoftInk: Themed(0x74846C, 0xA7BB9F)
        case .focus: Themed(0x7E9D86, 0x8FB39A)
        case .navDot: Themed(0x85947D, 0x8FA894)
        case .badgeSageBg: Themed(0xEDF4E2, 0x243126)
        case .badgeSageInk: Themed(0x6F7F63, 0xA9C19B)
        case .badgePeachBg: Themed(0xFFF4EA, 0x3A2B20)
        case .badgePeachInk: Themed(0x94705C, 0xE2B394)
        case .badgeMutedBg: Themed(0xF1F0EC, 0x262925)
        case .badgeMutedInk: Themed(0x7C817C, 0x9A9F99)
        case .badgeBadBg: Themed(0xFDE8E4, 0x3A1D19)
        case .badgeBadInk: Themed(0x9A3B2C, 0xF2A597)
        case .choiceBorder: Themed(0x9AB09F, 0x6F8F78)
        case .menuBorder: Themed(.rgba(255, 255, 255, 0.9), .rgba(255, 255, 255, 0.06))
        case .veil: Themed(.rgba(244, 241, 238, 0.5), .rgba(8, 10, 8, 0.55))
        case .cardEdge: Themed(.rgba(255, 255, 255, 0.9), .rgba(255, 255, 255, 0.05))
        case .calloutDot: Themed(0xD6A24A, 0xD8A955)
        case .calloutRing: Themed(.rgba(214, 162, 74, 0.55), .rgba(216, 169, 85, 0.5))
        case .calloutLine: Themed(0xCFC6BC, 0x4D4A44)
        case .orbCore: .same(0x7B0D10)
        case .orbMid: .same(0xB81916)
        case .orbRim: .same(0xF16940)
        case .figureGlow: Themed(0xFFFFFF, 0x222220)
        case .figure1: Themed(0xF1ECE7, 0x4A4540)
        case .figure2: Themed(0xE2D9D0, 0x34302C)
        case .figure3: Themed(0xD9CFC5, 0x2A2724)
        case .figureShade: Themed(0xCFC4B9, 0x23201D)
        case .figureShadow: Themed(.rgba(120, 100, 80, 0.18), .rgba(0, 0, 0, 0.5))
        case .figureHighlight: Themed(0xFFFFFF, 0x6F665E)
        case .tooltip: Themed(0x24312A, 0xF0EFEC)
        case .tooltipInk: Themed(0xF4F4F2, 0x0B0B0B)
        case .goalTrack: Themed(0xD8F0D0, 0x1F3A1C)
        case .gaugeTrack: Themed(0xF3C3CF, 0x5A2A38)
        case .gaugeFill: Themed(0xD9537A, 0xE8668C)
        case .ringOnCard: Themed(0xFFFFFF, 0x1A1A19)
        case .halo: Themed(.rgba(255, 255, 255, 0.35), .rgba(255, 255, 255, 0.06))
        case .haloRing: Themed(.rgba(255, 255, 255, 0.95), .rgba(255, 255, 255, 0.35))
        case .bannerGoodBg: Themed(0xE3F5DD, 0x15301A)
        case .bannerBadBg: Themed(0xFDE6E6, 0x3A1919)
        case .bannerBadInk: Themed(0x8F2424, 0xF3A4A4)
        case .toneGreenBg: Themed(0xDFF3D8, 0x1D3A1B)
        case .toneGreenInk: Themed(0x1F6B1F, 0x8FDC85)
        case .tonePeachBg: Themed(0xFFE4D4, 0x432617)
        case .tonePeachInk: Themed(0xA2471F, 0xF4A97F)
        case .toneBlueBg: Themed(0xE1E7FB, 0x1F2747)
        case .toneBlueInk: Themed(0x3A4FB0, 0xA7B4F3)
        case .toneYellowBg: Themed(0xFDF0CC, 0x3D3112)
        case .toneYellowInk: Themed(0x8A6400, 0xF0C95A)
        case .tonePinkBg: Themed(0xFDE2E8, 0x3F1D28)
        case .tonePinkInk: Themed(0xA33A57, 0xF19AB2)
        case .fertileMedium: Themed(0xDBE3FB, 0x2F3B72)
        case .fertileHigh: Themed(0xA9BAF3, 0x4A5EC4)
        case .fertilePeak: Themed(0x4A60C8, 0xA6B3F7)
        case .fertilePeakInk: Themed(0xFFFFFF, 0x0D0D0D)
        case .cycleLuteal: Themed(0xFBE0CF, 0x6A4230)
        case .hypAwake: Themed(0xEE9AA6, 0xC45A6C)
        case .hypInbed: Themed(0xE2E1DB, 0x33332F)
        case .scoreFrom: Themed(0xC3CBF6, 0x46518C)
        case .scoreMid: Themed(0xB48CF0, 0x7B58C8)
        case .scoreTo: Themed(0x34B35F, 0x2FA457)
        case .barGreen: Themed(0xA8DEA0, 0x2A5E2C)
        case .barGreenAccent: Themed(0x2F9E44, 0x5CC665)
        case .barOrange: Themed(0xF7C1A4, 0x6E3A22)
        }
    }
}

/// A CSS gradient: a line at an angle, or an ellipse sized and placed in fractions of the box it fills.
struct CSSGradient: Equatable {
    enum Shape: Equatable {
        /// `linear-gradient(<degrees>deg, …)`: 0 points up, 90 to the right.
        case linear(degrees: Double)
        /// `radial-gradient(<width>% <height>% at <x>% <y>%, …)`, as fractions.
        case radial(width: Double, height: Double, x: Double, y: Double)
    }

    struct Stop: Equatable {
        let color: CSSColor
        /// 0…1 along the line, or out along the ellipse's radius.
        let location: Double
    }

    let shape: Shape
    let stops: [Stop]

    static func linear(_ degrees: Double, _ stops: [(CSSColor, Double)]) -> CSSGradient {
        CSSGradient(shape: .linear(degrees: degrees), stops: stops.map { Stop(color: $0.0, location: $0.1) })
    }

    static func radial(_ width: Double, _ height: Double, at x: Double, _ y: Double, _ stops: [(CSSColor, Double)]) -> CSSGradient {
        CSSGradient(shape: .radial(width: width, height: height, x: x, y: y), stops: stops.map { Stop(color: $0.0, location: $0.1) })
    }

    /// Where a CSS angle's gradient line starts and ends in a box: through the centre, long enough that the corners
    /// sit on 0% and 100% (the CSS Images spec).
    static func line(degrees: Double, in size: CGSize) -> (start: CGPoint, end: CGPoint) {
        let a = degrees * .pi / 180
        let dx = sin(a), dy = -cos(a)
        let half = (abs(size.width * dx) + abs(size.height * dy)) / 2
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        return (CGPoint(x: c.x - dx * half, y: c.y - dy * half), CGPoint(x: c.x + dx * half, y: c.y + dy * half))
    }

    /// Paints the gradient over the whole box.
    func draw(in ctx: GraphicsContext, size: CGSize) {
        let gradient = Gradient(stops: stops.map { .init(color: $0.color.color, location: $0.location) })
        let box = CGRect(origin: .zero, size: size)
        switch shape {
        case .linear(let degrees):
            let line = Self.line(degrees: degrees, in: size)
            ctx.fill(Path(box), with: .linearGradient(gradient, startPoint: line.start, endPoint: line.end))
        case .radial(let width, let height, let x, let y):
            let rx = max(width * size.width, 0.5), ry = max(height * size.height, 0.5)
            let center = CGPoint(x: x * size.width, y: y * size.height)
            // A circle of radius rx, squashed to the ellipse's height around its centre.
            var ctx = ctx
            ctx.translateBy(x: center.x, y: center.y)
            ctx.scaleBy(x: 1, y: ry / rx)
            let scale = rx / ry
            let rect = CGRect(x: -center.x, y: -center.y * scale, width: size.width, height: size.height * scale)
            ctx.fill(Path(rect), with: .radialGradient(gradient, center: .zero, startRadius: 0, endRadius: rx))
        }
    }
}

/// Every gradient token, each as its layers from the top: a card wash is its colour over the sheen.
enum GradientToken: String, CaseIterable {
    /// A card's white glass sheen, under every wash.
    case sheen
    case gradGreen = "grad-green", gradPeach = "grad-peach", gradPink = "grad-pink", gradLavender = "grad-lavender"
    case gradMint = "grad-mint", gradSlate = "grad-slate", gradCream = "grad-cream", gradBlush = "grad-blush", gradBlue = "grad-blue"
    /// Dialogs (Sheet.tsx): pale mint into white.
    case gradSheet = "grad-sheet"
    /// The primary button, and while pressed.
    case accentGrad = "accent-grad", accentGradHover = "accent-grad-hover"
    /// The sidebar's current page.
    case navActive = "nav-active"
    /// A chosen radio card or chip.
    case choiceWash = "choice-wash"
    /// Menus and popovers.
    case menuBg = "menu-bg"

    var layers: Themed<[CSSGradient]> {
        let sheen = Themed(
            CSSGradient.linear(118, [(CSSColor(0xFFFFFF), 0), (CSSColor(0xFAFBF9), 0.26), (CSSColor(0xEFF2EF), 0.44), (CSSColor(0xFBFBFA), 0.6), (CSSColor(0xFFFFFF), 0.76), (CSSColor(0xF6F7F5), 1)]),
            CSSGradient.linear(118, [(CSSColor(0x1C1F1C), 0), (CSSColor(0x1E211E), 0.3), (CSSColor(0x232723), 0.46), (CSSColor(0x1D201D), 0.62), (CSSColor(0x1B1D1B), 0.8), (CSSColor(0x1E201E), 1)]))
        // A wash: three stops of one colour, strongest at the ellipse's centre, gone by 86%.
        func wash(_ width: Double, _ height: Double, at x: Double, _ y: Double, light: [CSSColor], dark: [CSSColor]) -> Themed<[CSSGradient]> {
            func stops(_ c: [CSSColor]) -> [(CSSColor, Double)] { [(c[0], 0), (c[1], 0.5), (c[2], 0.86)] }
            return Themed([.radial(width, height, at: x, y, stops(light)), sheen.light], [.radial(width, height, at: x, y, stops(dark)), sheen.dark])
        }
        func linear(_ degrees: Double, light: [(UInt32, Double)], dark: [(UInt32, Double)]) -> Themed<[CSSGradient]> {
            Themed([.linear(degrees, light.map { (CSSColor($0.0), $0.1) })], [.linear(degrees, dark.map { (CSSColor($0.0), $0.1) })])
        }
        switch self {
        case .sheen: return Themed([sheen.light], [sheen.dark])
        case .gradGreen:
            return wash(0.8, 0.72, at: 0.3, 1, light: [.rgba(209, 233, 194, 0.95), .rgba(220, 237, 206, 0.5), .rgba(220, 237, 206, 0)],
                        dark: [.rgba(74, 112, 64, 0.55), .rgba(60, 92, 54, 0.25), .rgba(60, 92, 54, 0)])
        case .gradPeach:
            return wash(0.8, 0.75, at: 0.78, 1, light: [.rgba(252, 222, 190, 0.95), .rgba(253, 240, 226, 0.55), .rgba(253, 240, 226, 0)],
                        dark: [.rgba(122, 78, 44, 0.55), .rgba(100, 64, 38, 0.25), .rgba(100, 64, 38, 0)])
        case .gradPink:
            return wash(0.8, 0.75, at: 0.75, 1, light: [.rgba(242, 212, 224, 0.95), .rgba(244, 220, 230, 0.5), .rgba(244, 220, 230, 0)],
                        dark: [.rgba(112, 52, 76, 0.55), .rgba(92, 44, 64, 0.25), .rgba(92, 44, 64, 0)])
        case .gradLavender:
            return wash(0.85, 0.75, at: 0.4, 1, light: [.rgba(222, 214, 243, 0.95), .rgba(229, 223, 245, 0.5), .rgba(229, 223, 245, 0)],
                        dark: [.rgba(82, 66, 120, 0.55), .rgba(68, 56, 100, 0.25), .rgba(68, 56, 100, 0)])
        case .gradMint:
            return wash(0.8, 0.75, at: 0.8, 1, light: [.rgba(208, 238, 232, 0.95), .rgba(230, 244, 242, 0.5), .rgba(230, 244, 242, 0)],
                        dark: [.rgba(44, 102, 92, 0.55), .rgba(38, 86, 78, 0.25), .rgba(38, 86, 78, 0)])
        case .gradSlate:
            return wash(0.9, 0.8, at: 0.7, 1, light: [.rgba(221, 229, 237, 0.95), .rgba(232, 237, 242, 0.5), .rgba(232, 237, 242, 0)],
                        dark: [.rgba(64, 76, 90, 0.55), .rgba(54, 64, 76, 0.25), .rgba(54, 64, 76, 0)])
        case .gradCream:
            return wash(0.9, 0.8, at: 0.4, 1, light: [.rgba(248, 239, 216, 0.95), .rgba(250, 245, 230, 0.55), .rgba(250, 245, 230, 0)],
                        dark: [.rgba(104, 92, 56, 0.5), .rgba(88, 78, 48, 0.22), .rgba(88, 78, 48, 0)])
        case .gradBlush:
            return wash(0.9, 0.85, at: 0.85, 0.7, light: [.rgba(250, 219, 205, 0.9), .rgba(251, 233, 224, 0.5), .rgba(251, 233, 224, 0)],
                        dark: [.rgba(118, 66, 52, 0.5), .rgba(98, 56, 44, 0.22), .rgba(98, 56, 44, 0)])
        case .gradBlue:
            return wash(0.8, 0.75, at: 0.8, 1, light: [.rgba(214, 228, 250, 0.95), .rgba(233, 241, 252, 0.55), .rgba(233, 241, 252, 0)],
                        dark: [.rgba(52, 72, 120, 0.6), .rgba(44, 60, 100, 0.25), .rgba(44, 60, 100, 0)])
        case .gradSheet: return linear(165, light: [(0xEEF5EC, 0), (0xF6FAF4, 0.38), (0xFFFFFF, 1)], dark: [(0x1C241E, 0), (0x1B1F1C, 0.4), (0x1A1C1A, 1)])
        case .accentGrad: return linear(180, light: [(0x3B5346, 0), (0x294237, 1)], dark: [(0x4F6E5C, 0), (0x3A5647, 1)])
        case .accentGradHover: return linear(180, light: [(0x46604F, 0), (0x2F4B3E, 1)], dark: [(0x5A7A67, 0), (0x436251, 1)])
        case .navActive: return linear(90, light: [(0xFFFFFF, 0), (0xEEF6EA, 0.7), (0xE6F2E2, 1)], dark: [(0x1D211D, 0), (0x213027, 1)])
        case .choiceWash: return linear(160, light: [(0xF4F9F2, 0), (0xFFFFFF, 0.7)], dark: [(0x1F2A22, 0), (0x1A1C1A, 0.7)])
        case .menuBg: return linear(170, light: [(0xFCFDFB, 0), (0xF1F6EC, 1)], dark: [(0x1F221F, 0), (0x1C241E, 1)])
        }
    }
}

/// One `box-shadow` layer: offset, blur, spread and colour, in the CSS's px (points here).
struct CSSShadow: Equatable {
    let x: Double
    let y: Double
    let blur: Double
    var spread: Double = 0
    let color: CSSColor
}

/// The web's three shadows, each as its layers.
enum ShadowToken: String, CaseIterable {
    /// Cards: a hairline under them and a soft, wide shadow pulled in at the sides.
    case card = "shadow-card"
    /// Pills and buttons.
    case pill = "shadow-pill"
    /// Dialogs, menus and the floating Ask McFly pill.
    case pop = "shadow-pop"

    var layers: Themed<[CSSShadow]> {
        let ink = (36 as UInt8, 49 as UInt8, 42 as UInt8)
        func light(_ a: Double) -> CSSColor { .rgba(ink.0, ink.1, ink.2, a) }
        switch self {
        case .card:
            return Themed([CSSShadow(x: 0, y: 1, blur: 2, color: light(0.04)), CSSShadow(x: 0, y: 16, blur: 38, spread: -18, color: light(0.16))],
                          [CSSShadow(x: 0, y: 1, blur: 2, color: .rgba(0, 0, 0, 0.35)), CSSShadow(x: 0, y: 16, blur: 38, spread: -18, color: .rgba(0, 0, 0, 0.6))])
        case .pill:
            return Themed([CSSShadow(x: 0, y: 1, blur: 2, color: light(0.05)), CSSShadow(x: 0, y: 6, blur: 16, spread: -8, color: light(0.16))],
                          [CSSShadow(x: 0, y: 1, blur: 2, color: .rgba(0, 0, 0, 0.4)), CSSShadow(x: 0, y: 6, blur: 16, spread: -8, color: .rgba(0, 0, 0, 0.5))])
        case .pop:
            return Themed([CSSShadow(x: 0, y: 2, blur: 6, color: light(0.06)), CSSShadow(x: 0, y: 26, blur: 60, spread: -18, color: light(0.26))],
                          [CSSShadow(x: 0, y: 0, blur: 0, spread: 1, color: .rgba(255, 255, 255, 0.04)), CSSShadow(x: 0, y: 26, blur: 60, spread: -18, color: .rgba(0, 0, 0, 0.8))])
        }
    }
}

/// Corner radii (--r-*). Pills are capsules (999px).
enum Radius {
    static let card: CGFloat = 22
    static let sheet: CGFloat = 24
    static let menu: CGFloat = 18
    static let nav: CGFloat = 12
    static let tile: CGFloat = 10
    static let field: CGFloat = 12
    static let pill: CGFloat = 999
}

/// A gradient token filling its frame, light or dark with the colour scheme.
///
/// A Canvas draws into one bitmap, and one taller than 8,192 pixels (about 2,730 points at 3×) isn't drawn at all in a
/// Form or List row, so a card that tall (Profile's at the largest text sizes) showed its shadow where its fill should
/// be. So the fill is drawn in slabs no taller than `slab`, each painting its own part of the one full-size gradient:
/// the same picture at any height, and one Canvas, as before, for anything shorter.
struct GradientFill: View {
    let token: GradientToken
    @Environment(\.colorScheme) private var scheme

    init(_ token: GradientToken) { self.token = token }

    /// The tallest slab, in points: 3,000 pixels at 3×.
    static let slab: CGFloat = 1000

    var body: some View {
        let layers = token.layers(scheme)
        GeometryReader { geo in
            let size = geo.size
            VStack(spacing: 0) {
                ForEach(Self.slabs(height: size.height), id: \.lowerBound) { slab in
                    Canvas { ctx, _ in
                        ctx.translateBy(x: 0, y: -slab.lowerBound)
                        for layer in layers.reversed() { layer.draw(in: ctx, size: size) }
                    }
                    .frame(height: slab.upperBound - slab.lowerBound)
                }
            }
        }
        .accessibilityHidden(true)
    }

    /// Where each slab of a fill `height` points tall starts and ends: whole points from the top, the last one taking
    /// what's left. One for anything up to `slab`.
    static func slabs(height: CGFloat) -> [Range<CGFloat>] {
        guard height > 0 else { return [] }
        return stride(from: 0, to: height, by: slab).map { $0..<min($0 + slab, height) }
    }
}

/// A shadow token behind a shape, drawn the way CSS draws box-shadow: the shape grown by the spread (shrunk when it's
/// negative), moved by the offset and blurred. It sits behind the view, so only what falls outside it shows.
struct TokenShadow<S: InsettableShape>: View {
    let token: ShadowToken
    let shape: S
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            ForEach(Array(token.layers(scheme).enumerated()), id: \.offset) { _, layer in
                shape.inset(by: -layer.spread)
                    .fill(layer.color.color)
                    .offset(x: layer.x, y: layer.y)
                    .blur(radius: layer.blur / 2)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension View {
    /// The token's shadow behind this view, shaped like its background.
    func tokenShadow<S: InsettableShape>(_ token: ShadowToken, in shape: S) -> some View {
        background { TokenShadow(token: token, shape: shape) }
    }
}
