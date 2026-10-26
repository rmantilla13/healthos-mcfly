import SwiftUI

/// One digital-human artwork and where its callouts go (Figure.tsx Art): each callout's dot, where its label's top-left
/// goes, and where the leader line from the dot ends beside the label, as fractions of the art's width and height.
/// Temperature has two places, the forehead and the wrist (a watch or band's reading).
struct DigitalArt {
    struct Spot: Equatable {
        let dot: CGPoint
        let label: CGPoint
        let line: CGPoint
        let left: Bool
    }

    let asset: String
    let width: CGFloat
    let height: CGFloat
    let spots: [CalloutKey: Spot]
    let wrist: Spot

    var ratio: CGFloat { height / width }

    /// The man (figures/digital-man.webp, 640×600), with Figure.tsx's MAN table.
    static let man = DigitalArt(
        asset: FigureVariant.man.assetName, width: 640, height: 600,
        spots: [
            .spo2: Spot(dot: CGPoint(x: 0.397, y: 0.2095), label: CGPoint(x: 0.016, y: 0.163), line: CGPoint(x: 0.094, y: 0.18), left: true),
            .breathing: Spot(dot: CGPoint(x: 0.495, y: 0.17), label: CGPoint(x: 0.92, y: 0.15), line: CGPoint(x: 0.909, y: 0.165), left: false),
            .heart: Spot(dot: CGPoint(x: 0.534, y: 0.2505), label: CGPoint(x: 0.016, y: 0.28), line: CGPoint(x: 0.07, y: 0.297), left: true),
            .temp: Spot(dot: CGPoint(x: 0.494, y: 0.075), label: CGPoint(x: 0.6, y: 0.0), line: CGPoint(x: 0.592, y: 0.035), left: false),
        ],
        wrist: Spot(dot: CGPoint(x: 0.0625, y: 0.233), label: CGPoint(x: 0.016, y: 0.135), line: CGPoint(x: 0.06, y: 0.2), left: true))

    /// The art for a figure: the woman uses the man's places until her render arrives (and FigureVariant.drawn draws the
    /// man's art until then).
    static func of(_ variant: FigureVariant) -> DigitalArt {
        variant == .woman ? DigitalArt(asset: FigureVariant.woman.assetName, width: man.width, height: man.height, spots: man.spots, wrist: man.wrist) : man
    }

    func spot(_ key: CalloutKey, wrist atWrist: Bool) -> Spot { key == .temp && atWrist ? wrist : spots[key]! }

    /// How far each label moves from its place in the table (DigitalFigure's nudge), in points: down, below the label
    /// above it on the same side with 6pt between (a reading adds a status line, and a small figure has less room), and
    /// left, to stay inside the figure.
    func nudges(_ keys: [CalloutKey], sizes: [CalloutKey: CGSize], width: CGFloat, wrist: Bool) -> [CalloutKey: CGVector] {
        let height = width * ratio
        var out: [CalloutKey: CGVector] = [:]
        for left in [true, false] {
            var bottom = -CGFloat.infinity
            for key in keys.filter({ spot($0, wrist: wrist).left == left }).sorted(by: { spot($0, wrist: wrist).label.y < spot($1, wrist: wrist).label.y }) {
                guard let size = sizes[key] else { continue }
                let s = spot(key, wrist: wrist)
                let top = s.label.y * height
                let dy = max(0, bottom + 6 - top)
                let dx = min(0, width - (s.label.x * width + size.width))
                out[key] = CGVector(dx: dx, dy: dy)
                bottom = top + dy + size.height
            }
        }
        return out
    }
}

/// The digital human (Figure.tsx DigitalFigure): the artwork, a leader line from each callout's dot to its label, and
/// the dots, which move at their own numbers. The labels are measured and moved so they never overlap or leave the
/// figure. The heart's label opens live heart rate.
struct DigitalFigure: View {
    let vitals: Summary.Vitals?
    let asOf: String
    var variant: FigureVariant = .man
    var units: Units = .metric
    var scrub: HeartScrub?
    var callouts: [CalloutKey] = CalloutKey.home
    var onHeart: (() -> Void)?
    @Environment(\.colorScheme) private var scheme
    @State private var sizes: [CalloutKey: CGSize] = [:]

    var body: some View {
        let art = DigitalArt.of(variant)
        // The art sets the figure's size from the width it's given (never a width kept from an earlier layout), and
        // the callouts are drawn over it in that size.
        Image(art.asset)
            .resizable()
            .aspectRatio(art.width / art.height, contentMode: .fit)
            .frame(maxWidth: .infinity)
            // The porcelain figure, a little dimmer on a dark page.
            .colorMultiply(scheme == .dark ? Color(white: 0.84) : .white)
            .accessibilityHidden(true)
            .overlay { GeometryReader { geo in callouts(art, width: geo.size.width) } }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Digital \(variant == .woman ? "woman" : "man") with your vitals")
            .accessibilityIdentifier("figure-digital")
    }

    private func callouts(_ art: DigitalArt, width: CGFloat) -> some View {
        let height = width * art.ratio
        let wrist = CalloutText.atWrist(vitals)
        let nudge = art.nudges(callouts, sizes: sizes, width: width, wrist: wrist)
        return ZStack(alignment: .topLeading) {
            Canvas { ctx, _ in
                for key in callouts {
                    let s = art.spot(key, wrist: wrist)
                    let d = nudge[key] ?? .zero
                    var line = Path()
                    line.move(to: CGPoint(x: s.dot.x * width, y: s.dot.y * height))
                    line.addLine(to: CGPoint(x: s.line.x * width + d.dx, y: s.line.y * height + d.dy))
                    ctx.stroke(line, with: .color(Palette.calloutLine), lineWidth: 1)
                }
            }
            .frame(width: width, height: height)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            ForEach(callouts, id: \.self) { key in
                let text = CalloutText.of(key, vitals: vitals, asOf: asOf, units: units, scrub: scrub)
                let s = art.spot(key, wrist: wrist)
                CalloutMark(text: text, halo: 9, dot: 3.5)
                    .position(x: s.dot.x * width, y: s.dot.y * height)
                let d = nudge[key] ?? .zero
                label(text)
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { sizes[key] = $0 }
                    .offset(x: s.label.x * width + d.dx, y: s.label.y * height + d.dy)
                    // Hidden until measured, so a label never shows over the art before it's moved into place.
                    .opacity(sizes[key] == nil ? 0 : 1)
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
    }

    @ViewBuilder private func label(_ text: CalloutText) -> some View {
        if text.key == .heart, let onHeart {
            Button(action: onHeart) { CalloutLabel(text: text, digital: true).contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .accessibilityLabel(text.spoken)
                .accessibilityHint("Opens live heart rate")
                .accessibilityIdentifier("callout-heart")
        } else {
            CalloutLabel(text: text, digital: true)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(text.spoken)
                .accessibilityIdentifier("callout-\(text.key.rawValue)")
        }
    }
}
