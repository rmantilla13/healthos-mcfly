import SwiftUI

/// Home's "Your health journal" (src/components/home/JournalPrompt.tsx): an invitation to write today's check-in
/// (journal?new=1 opens a new one), or, once there is one today (GET /api/journal?days=1), its mood and first line, and
/// an invitation to add another. Home reads the journal (HomeReads) and leaves the card out on a server without one (an
/// older one). Check-ins are private to the person and this is their own Home: what's read is held in memory only, for
/// this card, never kept on disk or logged. Its orb follows today's readings against your own usual (Summary.standing),
/// and a line says the same in words, so it never rests on colour alone.
struct JournalPromptCard: View {
    /// Today's latest check-in; nil while there's none (or it's still being read).
    var latest: JournalEntry? = nil
    /// Today's readings against your usual; nil without any (no watch or WHOOP, an older server): the orb as drawn, no line.
    var standing: Standing? = nil
    @Environment(Dashboard.self) private var dashboard
    @Environment(\.colorScheme) private var scheme
    /// The card's width inside its padding, for the words' two thirds.
    @State private var inner: CGFloat = 303
    @Environment(\.dynamicTypeSize) private var typeSize

    /// What the card says: the latest of today's check-ins, its mood's word and first line, and how today's readings stand.
    struct Model: Equatable {
        let mood: String?
        /// The first line with words in it, or "A check-in at 08:10".
        let line: String?
        let button: String
        /// What the orb shows, in words (standingWords in JournalPrompt.tsx).
        let standing: String?

        /// From GET /api/journal?days=1: the first of today's is the latest (newest first).
        init(_ data: JournalData?, standing: Standing? = nil) { self.init(latest: data?.todays.first, standing: standing) }

        init(latest: JournalEntry?, standing: Standing? = nil) {
            mood = latest?.mood?.label
            line = latest.map { $0.firstLine ?? "A check-in at \($0.time)" }
            button = latest == nil ? "Write a check-in" : "Add another"
            self.standing = standing.map(Self.words)
        }

        /// The web's words for a reason, inside a sentence.
        static let reasons = ["recovery": "recovery", "hrv": "HRV", "resting_hr": "resting heart rate", "sleep": "sleep"]

        /// Today's readings against your own last 30 days, the Family board's rule.
        static func words(_ s: Standing) -> String {
            let named = s.reasons.compactMap { reasons[$0] }
            let off = named.count < 2 ? named.joined() : "\(named.dropLast().joined(separator: ", ")) and \(named.last!)"
            switch s.status {
            case .good: return "Your readings are within your usual."
            case .off: return "Off your usual: \(off)."
            case .check: return "Off your usual: \(off). A good day to check in."
            case .learning: return "Still learning your usual."
            case .quiet: return "No recent readings to go by."
            }
        }
    }

    var body: some View { card(Model(latest: latest, standing: standing)) }

    private func card(_ m: Model) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        return Button { dashboard.open(AppRoute(.journal, query: ["new": "1"])) } label: {
            CardMinHeight(min: 236 - 38, fills: true) {
                VStack(alignment: .leading, spacing: 0) {
                    words(m)
                        // The words keep to the left two thirds; the orb takes the rest (home.css, 560px and below). At
                        // the accessibility text sizes they take the whole card, over the orb's side.
                        .frame(maxWidth: typeSize.isAccessibilitySize ? .infinity : inner * 0.66, alignment: .leading)
                    Spacer(minLength: 16)
                    HStack(spacing: 7) {
                        Text(m.button)
                        Image(systemName: "arrow.up.right").font(.system(size: 12, weight: .medium))
                    }
                    .font(.app(.footnote, weight: .medium))
                    .foregroundStyle(Palette.ink2)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 34)
                    .background(Palette.surface, in: Capsule())
                    .tokenShadow(.pill, in: Capsule())
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { inner = $0 }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ZStack {
                    GradientFill(CardTint.blush.gradient)
                    orb
                }
                .clipShape(shape)
                .overlay(shape.strokeBorder(Palette.cardEdge))
                .tokenShadow(.card, in: shape)
            }
            .contentShape(shape)
        }
        .buttonStyle(CardPressStyle())
        .accessibilityLabel(["Your health journal", "How are you feeling today?", m.mood, m.line ?? "A thought, a feeling, a little context.", m.standing].compactMap { $0 }.joined(separator: ". "))
        .accessibilityHint(m.button == "Write a check-in" ? "Writes a check-in" : "Adds another check-in")
        .accessibilityIdentifier("card-home.journal")
    }

    private func words(_ m: Model) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Your health journal").font(.app(.footnote, weight: .medium)).foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text("How are you feeling today?")
                .font(.app(size: 22, weight: .medium, relativeTo: .title2))
                .tracking(-0.22)
                .lineSpacing(2)
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 16)
            if let line = m.line {
                HomeFlowRow(spacing: 8, lineSpacing: 6) {
                    if let mood = m.mood { Badge(mood, tone: .sage) }
                    Text(line).font(.app(.footnote)).foregroundStyle(Palette.ink2).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 12)
            } else {
                Text("A thought, a feeling, a little context.").font(.app(.caption)).foregroundStyle(Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }
            if let standing = m.standing {
                Text(standing).font(.app(.caption)).foregroundStyle(Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
        }
    }

    /// The journal's orb in the card's right half, running past its edge (JournalOrb.place); the card's shape trims it.
    private var orb: some View {
        GeometryReader { geo in
            let place = JournalOrb.place(in: geo.size)
            JournalOrb(diameter: place.diameter, state: standing?.status)
                .position(place.center)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The journal's orb (src/components/JournalOrb.tsx, .journal-orb in styles.css): a soft glass ball in the blush family,
/// peach and rose into a lavender edge, kept apart from McFly's red Orb. Its colours drift and turn inside it and its
/// glow breathes, on the web's loops (JournalOrbMotion). Reduce Motion holds it still, as the web draws it unanimated,
/// and Reduce Transparency leaves out the glow, as Orb does. One Canvas, drawn at most 30 times a second. With a
/// `state` it follows today's readings (JournalOrbLook).
struct JournalOrb: View {
    let diameter: CGFloat
    var state: Standing.Status? = nil
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// The canvas, as a share of the ball: room for the glow (30% past the ball, .journal-orb-halo's inset) at the top of
    /// its breath.
    static let canvas: CGFloat = 1.8

    /// Where the orb sits in a card of `size`: home.css's .home-journal .journal-orb-area at 560px and below, the card's
    /// right 48% running 8% past its edge, and the orb as wide as 88% of that or as tall as 78% of the card, whichever is
    /// less (.journal-orb's --d).
    static func place(in size: CGSize) -> (center: CGPoint, diameter: CGFloat) {
        let width = size.width * 0.48
        return (CGPoint(x: size.width * 1.08 - width / 2, y: size.height / 2), min(width * 0.88, size.height * 0.78))
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            let look = JournalOrbLook.of(state)
            // Slower the further off: each loop's length times the pace.
            let moment = JournalOrbMotion.state(at: reduceMotion ? nil : context.date.timeIntervalSinceReferenceDate / look.pace)
            Canvas { ctx, size in draw(moment, look, in: &ctx, size: size) }
        }
        .frame(width: diameter * Self.canvas, height: diameter * Self.canvas)
        .accessibilityHidden(true)
    }

    private static func circle(_ c: CGPoint, _ r: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
    }

    /// A colour fading to nothing at its edge (radial-gradient(closest-side, colour, transparent)).
    private static func fade(_ color: Color, at c: CGPoint, _ r: CGFloat) -> GraphicsContext.Shading {
        .radialGradient(Gradient(colors: [color, color.opacity(0)]), center: c, startRadius: 0, endRadius: r)
    }

    private func draw(_ s: JournalOrbMotion.State, _ look: JournalOrbLook, in ctx: inout GraphicsContext, size: CGSize) {
        func color(_ token: Themed<CSSColor>) -> Color { token(scheme).color }
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let d = diameter * s.breathe
        // The glow: the halo colour out to 52% of its reach, then fading to nothing.
        if !reduceTransparency {
            let r = d * 0.8 * s.haloScale, halo = color(JournalOrbColors.halo).opacity(look.halo)
            var glow = ctx
            glow.opacity = s.haloOpacity
            glow.fill(Self.circle(center, r), with: .radialGradient(Gradient(stops: [.init(color: halo, location: 0), .init(color: halo, location: 0.52),
                                                                                    .init(color: halo.opacity(0), location: 1)]),
                                                                  center: center, startRadius: 0, endRadius: r))
        }
        let ball = CGRect(x: center.x - d / 2, y: center.y - d / 2, width: d, height: d)
        ctx.drawLayer { l in
            l.clip(to: Path(ellipseIn: ball))
            // Lit from inside: radial-gradient(circle at 42% 36%, core 0%, mid 38%, edge 92%), out to the farthest corner.
            l.fill(Path(ball), with: .radialGradient(Gradient(stops: [.init(color: color(JournalOrbColors.core), location: 0),
                                                                      .init(color: color(JournalOrbColors.mid), location: 0.38),
                                                                      .init(color: color(JournalOrbColors.edge), location: 0.92)]),
                                                     center: CGPoint(x: ball.minX + d * 0.42, y: ball.minY + d * 0.36),
                                                     startRadius: 0, endRadius: d * (0.58 * 0.58 + 0.64 * 0.64).squareRoot()))
            // The colours, in a swirl 24% wider than the ball that turns about its middle, each drifting on its own loop
            // by shares of its own size. On a dark card they add up as light.
            var swirl = l
            swirl.translateBy(x: center.x, y: center.y)
            swirl.rotate(by: .degrees(s.spin * 360))
            swirl.blendMode = scheme == .dark ? .screen : .normal
            let span = d * 1.24
            for blob in JournalOrbMotion.Blob.allCases {
                let w = blob.frame.size * span, drift = s.drift[blob] ?? .init()
                let c = CGPoint(x: -span / 2 + blob.frame.x * span + w * (0.5 + drift.x), y: -span / 2 + blob.frame.y * span + w * (0.5 + drift.y))
                let r = w / 2 * drift.scale
                swirl.fill(Self.circle(c, r), with: Self.fade(color(blob.color).opacity(look.share(blob)), at: c, r))
            }
            // The state's veil over the colours, under the shine.
            if look.veil > 0 { l.fill(Path(ball), with: .color(color(JournalOrbColors.veil).opacity(look.veil))) }
            // The shine up on the left and its reflection low on the right (radial-gradient(24% 17% at 36% 22%) and
            // (30% 12% at 58% 88%)).
            for (at, rx, ry, token) in [(CGPoint(x: 0.36, y: 0.22), 0.24, 0.17, JournalOrbColors.shine), (CGPoint(x: 0.58, y: 0.88), 0.3, 0.12, JournalOrbColors.rim)] {
                var shine = l
                shine.translateBy(x: ball.minX + d * at.x, y: ball.minY + d * at.y)
                shine.scaleBy(x: 1, y: ry / rx)
                shine.fill(Self.circle(.zero, d * rx), with: Self.fade(color(token), at: .zero, d * rx))
            }
            // The web's inset shadows as rings fading inward: the rim light all round, and a little shade at the bottom
            // (its centre raised, so the ring is deepest below).
            let rim = color(JournalOrbColors.rim), shade = color(JournalOrbColors.shade)
            l.fill(Path(ball), with: .radialGradient(Gradient(stops: [.init(color: rim.opacity(0), location: 0.8), .init(color: rim.opacity(0.6), location: 0.93),
                                                                      .init(color: rim, location: 1)]),
                                                     center: center, startRadius: 0, endRadius: d / 2))
            l.fill(Path(ball), with: .radialGradient(Gradient(stops: [.init(color: shade.opacity(0), location: 0.7), .init(color: shade, location: 1)]),
                                                     center: CGPoint(x: center.x, y: center.y - d * 0.08), startRadius: 0, endRadius: d * 0.58))
            // The very edge feathered (a mask of radial-gradient(closest-side, #000 95%, transparent 100%)).
            l.blendMode = .destinationIn
            l.fill(Path(ball), with: .radialGradient(Gradient(stops: [.init(color: .black, location: 0.95), .init(color: .black.opacity(0), location: 1)]),
                                                     center: center, startRadius: 0, endRadius: d / 2))
        }
    }
}

/// The orb's colours: styles.css's --journal-orb-*, light and dark (the test reads them there; --journal-orb-blend is
/// the swirl's .screen on a dark card).
enum JournalOrbColors {
    static let core = Themed<CSSColor>(0xFFF2EC, 0xFFD0C4)
    static let mid = Themed<CSSColor>(0xF6BCC2, 0xC4608C)
    static let edge = Themed<CSSColor>(0xC6AEF0, 0x452C84)
    static let rose = Themed<CSSColor>(.rgba(244, 136, 176, 0.85), .rgba(255, 104, 158, 0.62))
    static let peach = Themed<CSSColor>(.rgba(255, 182, 128, 0.85), .rgba(255, 166, 116, 0.55))
    static let lilac = Themed<CSSColor>(.rgba(166, 140, 248, 0.8), .rgba(132, 102, 255, 0.85))
    static let glow = Themed<CSSColor>(.rgba(255, 247, 240, 0.95), .rgba(255, 224, 210, 0.5))
    static let rim = Themed<CSSColor>(.rgba(255, 255, 255, 0.55), .rgba(255, 186, 214, 0.5))
    static let shade = Themed<CSSColor>(.rgba(150, 86, 140, 0.28), .rgba(22, 8, 32, 0.4))
    static let shine = Themed<CSSColor>(.rgba(255, 255, 255, 0.85), .rgba(255, 240, 236, 0.65))
    static let halo = Themed<CSSColor>(.rgba(240, 164, 182, 0.42), .rgba(222, 104, 150, 0.34))
    /// The state's veil (JournalOrbLook.veil).
    static let veil = Themed<CSSColor>(0xECE6F4, 0x3B3453)

    /// By the CSS's names, for the test that reads styles.css.
    static let all: [String: Themed<CSSColor>] = [
        "journal-orb-core": core, "journal-orb-mid": mid, "journal-orb-edge": edge, "journal-orb-rose": rose, "journal-orb-peach": peach,
        "journal-orb-lilac": lilac, "journal-orb-glow": glow, "journal-orb-rim": rim, "journal-orb-shade": shade, "journal-orb-shine": shine,
        "journal-orb-halo": halo, "journal-orb-veil": veil,
    ]
}

/// What the orb shows of today's readings (styles.css's .journal-orb-area[data-state]): how lively it is (its loops'
/// lengths times `pace`) and how much of each colour, its veil and its glow come through, the same in light and dark.
/// Within your usual, or without a state, it's the orb as drawn; one reading off, cooler and slower; several, calm
/// lavender and slower still; nothing recent or no usual yet, pale and slow.
struct JournalOrbLook: Equatable {
    var pace: Double = 1
    var peach: Double = 1
    var rose: Double = 1
    var lilac: Double = 1
    var glow: Double = 1
    var veil: Double = 0
    var halo: Double = 1

    static func of(_ state: Standing.Status?) -> JournalOrbLook {
        switch state {
        case .off: JournalOrbLook(pace: 1.35, peach: 0.5, rose: 0.8, glow: 0.85, veil: 0.16, halo: 0.8)
        case .check: JournalOrbLook(pace: 1.7, peach: 0.2, rose: 0.45, lilac: 0.95, glow: 0.7, veil: 0.34, halo: 0.6)
        case .quiet, .learning: JournalOrbLook(pace: 2.4, peach: 0.15, rose: 0.25, lilac: 0.35, glow: 0.6, veil: 0.62, halo: 0.4)
        case .good, nil: JournalOrbLook()
        }
    }

    func share(_ blob: JournalOrbMotion.Blob) -> Double {
        switch blob {
        case .rose: rose
        case .peach: peach
        case .lilac: lilac
        case .glow: glow
        }
    }
}

/// The orb's loops (styles.css's @keyframes journal-orb-*): the ball breathes and its glow swells every 9s, the swirl turns
/// once in 48s, and each blob drifts by shares of its own size on its own loop. Between keyframes they ease in and out,
/// near the CSS's ease-in-out.
enum JournalOrbMotion {
    struct Drift: Equatable {
        var x: CGFloat = 0, y: CGFloat = 0, scale: CGFloat = 1
    }

    struct Key {
        let at: Double
        let drift: Drift
    }

    enum Blob: CaseIterable {
        case rose, peach, lilac, glow

        /// Its place in the swirl, as shares of it: the top-left corner and the size (.journal-orb-blob[data-blob]).
        var frame: (x: CGFloat, y: CGFloat, size: CGFloat) {
            switch self {
            case .rose: (0.02, 0.04, 0.58)
            case .peach: (0.4, 0.36, 0.58)
            case .lilac: (0.1, 0.36, 0.62)
            case .glow: (0.46, 0.16, 0.4)
            }
        }

        var color: Themed<CSSColor> {
            switch self {
            case .rose: JournalOrbColors.rose
            case .peach: JournalOrbColors.peach
            case .lilac: JournalOrbColors.lilac
            case .glow: JournalOrbColors.glow
            }
        }

        /// Its keyframes, its loop's length and whether it runs backwards (the glow's `reverse`).
        var loop: (keys: [Key], period: Double, reversed: Bool) {
            switch self {
            case .rose: (JournalOrbMotion.driftA, 17, false)
            case .peach: (JournalOrbMotion.driftB, 13, false)
            case .lilac: (JournalOrbMotion.driftC, 21, false)
            case .glow: (JournalOrbMotion.driftB, 11, true)
            }
        }
    }

    struct State: Equatable {
        var breathe: CGFloat = 1
        var haloScale: CGFloat = 1
        var haloOpacity: Double = 1
        /// Turns of the swirl.
        var spin: Double = 0
        var drift: [Blob: Drift] = [:]
    }

    static let breathePeriod = 9.0
    static let spinPeriod = 48.0

    private static func key(_ at: Double, _ x: CGFloat, _ y: CGFloat, _ scale: CGFloat) -> Key { Key(at: at, drift: Drift(x: x, y: y, scale: scale)) }
    static let driftA = [key(0, 0, 0, 1), key(0.33, 0.22, 0.14, 1.12), key(0.66, 0.06, 0.3, 0.92), key(1, 0, 0, 1)]
    static let driftB = [key(0, 0, 0, 1), key(0.4, -0.26, -0.12, 0.9), key(0.7, -0.08, -0.28, 1.14), key(1, 0, 0, 1)]
    static let driftC = [key(0, 0, 0, 1), key(0.3, 0.18, -0.2, 1.1), key(0.65, 0.3, -0.04, 0.94), key(1, 0, 0, 1)]

    /// Where a loop of `period` seconds is at `t`, from 0 to 1.
    static func phase(_ t: Double, _ period: Double) -> Double {
        let p = t.truncatingRemainder(dividingBy: period) / period
        return p < 0 ? p + 1 : p
    }

    /// Ease in and out (smoothstep), close to the CSS's ease-in-out between two keyframes.
    private static func ease(_ u: Double) -> Double { u * u * (3 - 2 * u) }

    private static func mix(_ a: CGFloat, _ b: CGFloat, _ u: Double) -> CGFloat { a + (b - a) * CGFloat(u) }

    static func drift(_ keys: [Key], at p: Double) -> Drift {
        guard let next = keys.firstIndex(where: { $0.at > p }), next > 0 else { return keys.last?.drift ?? Drift() }
        let a = keys[next - 1], b = keys[next]
        let u = ease((p - a.at) / (b.at - a.at))
        return Drift(x: mix(a.drift.x, b.drift.x, u), y: mix(a.drift.y, b.drift.y, u), scale: mix(a.drift.scale, b.drift.scale, u))
    }

    /// The orb at `t` seconds, or still (nil, Reduce Motion): the web's unanimated orb, its glow full and nothing moved.
    static func state(at t: Double?) -> State {
        guard let t else { return State(drift: Dictionary(uniqueKeysWithValues: Blob.allCases.map { ($0, Drift()) })) }
        // 0% and 100% at rest, 50% at the top of the breath.
        let breath = ease(1 - abs(phase(t, breathePeriod) * 2 - 1))
        var state = State(breathe: 1 + 0.035 * breath, haloScale: 0.95 + 0.11 * breath, haloOpacity: 0.7 + 0.3 * breath, spin: phase(t, spinPeriod))
        for blob in Blob.allCases {
            let loop = blob.loop, p = phase(t, loop.period)
            state.drift[blob] = drift(loop.keys, at: loop.reversed ? 1 - p : p)
        }
        return state
    }
}

