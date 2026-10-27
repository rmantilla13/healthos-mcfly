import SwiftUI

// The welcome's illustrations (Onboarding.tsx: BustArt, HumanArt, StatsArt, PeerBars), drawn here from the web's own
// shapes and onboarding.css's colours, light and dark. None of them says anything VoiceOver needs: each is hidden from
// it, as the web's are aria-hidden.

/// "Your own portrait": a soft beige bust, the head resting on the shoulders (a 100 × 100 drawing).
struct BustArt: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let light = WelcomeLook.bustLight(scheme), dark = WelcomeLook.bustDark(scheme)
        Canvas { ctx, size in
            let k = min(size.width, size.height) / 100
            ctx.translateBy(x: (size.width - 100 * k) / 2, y: (size.height - 100 * k) / 2)
            ctx.scaleBy(x: k, y: k)
            var body = Path()
            body.move(to: CGPoint(x: 12, y: 100))
            body.addCurve(to: CGPoint(x: 50, y: 50), control1: CGPoint(x: 12, y: 66), control2: CGPoint(x: 30, y: 50))
            body.addCurve(to: CGPoint(x: 88, y: 100), control1: CGPoint(x: 70, y: 50), control2: CGPoint(x: 88, y: 66))
            body.closeSubpath()
            // SVG radial gradients in the shape's own box: the body's light at 36% 20% to its dark by 75%, r 95%; the
            // head's at 38% 32%, r 75%.
            Self.fill(body, in: CGRect(x: 12, y: 50, width: 76, height: 50), ctx: ctx,
                      gradient: .radial(0.95, 0.95, at: 0.36, 0.2, [(light, 0), (dark, 0.75)]))
            let head = CGRect(x: 33, y: 6, width: 34, height: 46)
            Self.fill(Path(ellipseIn: head), in: head, ctx: ctx, gradient: .radial(0.75, 0.75, at: 0.38, 0.32, [(light, 0), (dark, 1)]))
        }
        .accessibilityHidden(true)
    }

    private static func fill(_ path: Path, in box: CGRect, ctx: GraphicsContext, gradient: CSSGradient) {
        var ctx = ctx
        ctx.clip(to: path)
        ctx.translateBy(x: box.minX, y: box.minY)
        gradient.draw(in: ctx, size: box.size)
    }
}

/// "Digital human": the figure's artwork, the man's while the woman's isn't there (FigureVariant.drawn), a little
/// dimmer on a dark page (as .figure-art).
struct HumanArt: View {
    let variant: FigureVariant
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Image(variant.drawn.assetName)
            .resizable()
            .scaledToFit()
            .colorMultiply(scheme == .dark ? Color(white: 0.84) : .white)
            .accessibilityHidden(true)
    }
}

/// "Just the statistics": four sage bars, each at its own height and sitting a little higher or lower.
struct StatsArt: View {
    var barWidth: CGFloat = 19
    var gap: CGFloat = 9
    var height: CGFloat = 96

    /// Each bar's height and how far up it sits, as shares of the row (STAT_BARS).
    static let bars: [(height: CGFloat, bottom: CGFloat)] = [(0.42, 0.25), (0.73, 0.08), (0.58, 0.17), (0.94, 0)]

    var body: some View {
        HStack(alignment: .bottom, spacing: gap) {
            ForEach(Array(Self.bars.enumerated()), id: \.offset) { _, bar in
                // linear-gradient(180deg, --onb-bar-bottom, --onb-bar-top): the deeper sage at the top.
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(LinearGradient(colors: [WelcomeLook.barBottom.color, WelcomeLook.barTop.color], startPoint: .top, endPoint: .bottom))
                    .frame(width: barWidth, height: height * bar.height)
                    .padding(.bottom, height * bar.bottom)
            }
        }
        .frame(height: height, alignment: .bottom)
        .accessibilityHidden(true)
    }
}

/// Step 3: a spread of readings, you the amber one in the middle (a 176 × 120 drawing).
struct PeerBars: View {
    static let heights: [CGFloat] = [22, 38, 74, 50, 92, 110, 96, 24, 50, 74, 50]

    var body: some View {
        Canvas { ctx, size in
            let k = min(size.width / 176, size.height / 120)
            ctx.scaleBy(x: k, y: k)
            for (i, h) in Self.heights.enumerated() {
                let rect = CGRect(x: CGFloat(i) * 16 + 3, y: 60 - h / 2, width: 10, height: h)
                let you = i == 5
                let top = you ? WelcomeLook.youTop : WelcomeLook.barTop
                let bottom = you ? WelcomeLook.youBottom : WelcomeLook.barBottom
                let shading = GraphicsContext.Shading.linearGradient(
                    Gradient(colors: [ctx.environment.colorScheme == .dark ? top.dark.color : top.light.color,
                                      ctx.environment.colorScheme == .dark ? bottom.dark.color : bottom.light.color]),
                    startPoint: CGPoint(x: rect.midX, y: rect.minY), endPoint: CGPoint(x: rect.midX, y: rect.maxY))
                ctx.fill(Path(roundedRect: rect, cornerRadius: 5), with: shading)
            }
        }
        .aspectRatio(176 / 120, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

/// The choice cards' art area: the soft shadow the illustrations stand in (--onb-art-shade, from the bottom).
struct ArtShade: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GradientLayers(layers: Themed(
            [.radial(0.6, 0.46, at: 0.5, 1, [(WelcomeLook.artShade.light, 0), (.rgba(0, 0, 0, 0), 0.72)])],
            [.radial(0.6, 0.46, at: 0.5, 1, [(WelcomeLook.artShade.dark, 0), (.rgba(0, 0, 0, 0), 0.72)])]))
    }
}
