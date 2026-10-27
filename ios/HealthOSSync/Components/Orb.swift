import SwiftUI

/// McFly's mark (Orb.tsx): a glowing red orb, a dark red core into an orange-red rim, softly blurred at the edge. The
/// healthOS brand keeps its sunburst (BrandMark). `busy` pulses it gently while McFly works; Reduce Motion holds it
/// still, and Reduce Transparency draws it solid, without the glow or the soft edge.
struct Orb: View {
    var size: CGFloat = 24
    var busy = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// The glow (.orb's box-shadow), and a stop between mid and rim that styles.css writes in place.
    private static let glow = CSSColor.rgba(241, 105, 64, 0.42)
    private static let ember = CSSColor(0xD93A22)

    var body: some View {
        if busy && !reduceMotion {
            PhaseAnimator([false, true]) { up in
                orb(pulse: up)
            } animation: { _ in .easeInOut(duration: 0.8) }
        } else {
            orb(pulse: false)
        }
    }

    private func orb(pulse: Bool) -> some View {
        // radial-gradient(circle at 50% 46%, …): a circle out to the farthest corner of the box.
        let reach = size * (0.5 * 0.5 + 0.54 * 0.54).squareRoot()
        let rim = reduceTransparency ? Palette.orbRim : Palette.orbRim.opacity(0)
        return Circle()
            .fill(RadialGradient(stops: [
                .init(color: Palette.orbCore, location: 0),
                .init(color: Palette.orbCore, location: 0.16),
                .init(color: Palette.orbMid, location: 0.46),
                .init(color: Self.ember.color, location: 0.66),
                .init(color: Palette.orbRim, location: 0.82),
                .init(color: rim, location: 1),
            ], center: UnitPoint(x: 0.5, y: 0.46), startRadius: 0, endRadius: reach))
            .blur(radius: reduceTransparency ? 0 : size * 0.015)
            .background {
                if !reduceTransparency {
                    // box-shadow: 0 0 (0.32 → 0.55 × size) (0.02 → 0.06 × size), stronger at the top of a pulse.
                    Circle()
                        .fill(Self.glow.color.opacity(pulse ? 0.55 / 0.42 : 1))
                        .padding(-size * (pulse ? 0.06 : 0.02))
                        .blur(radius: size * (pulse ? 0.55 : 0.32) / 2)
                }
            }
            .scaleEffect(pulse ? 1.08 : 1)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
