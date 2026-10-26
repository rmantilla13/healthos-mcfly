import SwiftUI

// The figure beside your vitals, in the perspective you chose (src/components/Figure.tsx): your own photo ('portrait',
// OrganicHome.swift's PortraitFigure), the digital human ('digital', or a portrait without a photo yet: DigitalFigure.swift),
// or none at all ('stats'). Each callout points at its place on the body with the latest reading, animated by it.
// Home's set is blood oxygen and heart on the left, breathing on the right; Body shows the same.

/// How the person chose to see themselves (settings.perspective): nil from servers older than onboarding, read as the
/// portrait, as the web does.
enum Perspective: String {
    case portrait, digital, stats

    static func of(_ settings: ServerStatus.Settings?) -> Perspective {
        settings?.perspective.flatMap(Perspective.init(rawValue:)) ?? .portrait
    }
}

/// A callout's vital (Figure.tsx CalloutKey).
enum CalloutKey: String, CaseIterable, Hashable {
    case temp, breathing, heart, spo2

    /// Home's (and Body's) set: blood oxygen, breathing and heart; temperature stays on Sleep.
    static let home: [CalloutKey] = [.spo2, .breathing, .heart]
    /// The set elsewhere (DEFAULT_CALLOUTS): temperature, breathing and heart.
    static let standard: [CalloutKey] = [.temp, .breathing, .heart]
}

/// What one callout says and how its dot moves (Figure.tsx CalloutLabel, display, levelOf and liveVars).
struct CalloutText: Equatable {
    let key: CalloutKey
    /// "Heart", or the vital's own label ("Breathing", "Blood oxygen", "Wrist temp").
    let name: String
    /// The reading ("62", "14.6"); nil draws a dash, still with its unit ("— %").
    let value: String?
    let unit: String
    /// The dot's colour: green, amber or red against the person's usual; the figure's gold (`.neutral`) without a level,
    /// for a reading older than the day shown, and for the heart while the timeline is scrubbed.
    let level: VitalLevel
    /// The words under the value; nil without a reading (nothing to compare).
    let status: String?
    /// The level's dot beside the words, when there's a level.
    let statusLevel: VitalLevel?
    /// The heart while Home's timeline is scrubbed: that hour's average rather than the resting rate.
    var scrubbed = false
    /// What VoiceOver reads.
    let spoken: String
    /// The beats or breaths a minute the dot moves at; nil holds it still (no reading). Temperature glows with any
    /// reading; blood oxygen doesn't move.
    let rate: Double?

    /// The vital behind a callout. Servers before the blood oxygen callout send none: shown as no reading.
    static func vital(_ key: CalloutKey, _ vitals: Summary.Vitals?) -> Vital? {
        switch key {
        case .temp: vitals?.temp
        case .breathing: vitals?.breathing
        case .heart: vitals?.heart
        case .spo2: vitals?.spo2 ?? Vital(label: "Blood oxygen", latest: nil, status: nil, level: nil)
        }
    }

    /// A watch or band's temperature goes at the wrist; a thermometer's on the forehead.
    static func atWrist(_ vitals: Summary.Vitals?) -> Bool { ["Wrist temp", "Skin temp"].contains(vitals?.temp?.label ?? "") }

    static func of(_ key: CalloutKey, vitals: Summary.Vitals?, asOf: String, units: Units = .metric, scrub: HeartScrub? = nil) -> CalloutText {
        let v = vital(key, vitals)
        if key == .heart, let scrub {
            let value = scrub.bpm.map { Fmt.number($0) }
            return CalloutText(key: key, name: "Heart", value: value, unit: "bpm", level: .neutral, status: scrub.label, statusLevel: nil, scrubbed: true,
                               spoken: value.map { "Heart, \($0) beats per minute, \(scrub.spoken)" } ?? "Heart, \(scrub.spoken)",
                               rate: scrub.bpm.flatMap(Self.beats))
        }
        let n = v?.latest?.value
        let value: String?, unit: String, spokenUnit: String
        switch key {
        case .heart: (value, unit, spokenUnit) = (n.map { Fmt.number($0) }, "bpm", "beats per minute")
        case .breathing: (value, unit, spokenUnit) = (n.map { Fmt.number($0, 1) }, "/min", "breaths per minute")
        case .spo2: (value, unit, spokenUnit) = (n.map { Fmt.number($0, $0.truncatingRemainder(dividingBy: 1) == 0 ? 0 : 1) }, "%", "percent")
        case .temp:
            let t = units.temp(n ?? 0)
            (value, unit, spokenUnit) = (n.map { _ in Fmt.number(t.value, 1) }, t.unit, t.unit)
        }
        let name = key == .heart ? "Heart" : v?.label ?? CalloutKey.defaultName(key)
        let level = VitalLevel.of(v, asOf: asOf)
        let status = v?.latest == nil ? nil : VitalLevel.statusLine(v, asOf: asOf)
        let spoken = value.map { "\(name), \($0) \(spokenUnit)" + (status.map { ", \($0)" } ?? "") } ?? "\(name), no reading"
        let rate: Double? = switch key {
        case .heart: n.flatMap(Self.beats)
        case .breathing: n.flatMap(Self.breaths)
        case .temp, .spo2: nil
        }
        return CalloutText(key: key, name: name, value: value, unit: unit, level: level, status: status,
                           statusLevel: level == .neutral ? nil : level, spoken: spoken, rate: rate)
    }

    /// The heart's rate for its beat, clamped as the web's liveVars clamps it (30–220), so a bad row can't freeze or
    /// strobe the dot; nil without a positive reading.
    static func beats(_ bpm: Double) -> Double? { bpm > 0 && bpm.isFinite ? min(220, max(30, bpm)) : nil }
    /// Breathing's, 4–40 a minute.
    static func breaths(_ rpm: Double) -> Double? { rpm > 0 && rpm.isFinite ? min(40, max(4, rpm)) : nil }
}

extension CalloutKey {
    static func defaultName(_ key: CalloutKey) -> String {
        switch key {
        case .temp: "Temperature"
        case .breathing: "Breathing"
        case .heart: "Heart"
        case .spo2: "Blood oxygen"
        }
    }
}

// MARK: - The dots' motion (styles.css "vitals animations")

/// Each callout moves at its own number: the heart dot beats once every 60/bpm s with a ring leaving it, the throat's
/// halo breathes once every 60/rpm s, and temperature glows over 6 s. Values from the keyframes in styles.css.
enum CalloutMotion {
    /// Where `t` seconds falls in a cycle of `period` seconds, 0…1.
    static func phase(_ t: Double, period: Double) -> Double {
        guard period > 0 else { return 0 }
        let p = t.truncatingRemainder(dividingBy: period) / period
        return p < 0 ? p + 1 : p
    }

    /// Between keyframes, eased in and out.
    static func keyframes(_ frames: [(Double, Double)], at p: Double) -> Double {
        guard let first = frames.first else { return 0 }
        if p <= first.0 { return first.1 }
        for (a, b) in zip(frames, frames.dropFirst()) where p <= b.0 {
            let u = (p - a.0) / max(0.0001, b.0 - a.0)
            let eased = u * u * (3 - 2 * u)
            return a.1 + (b.1 - a.1) * eased
        }
        return frames.last?.1 ?? first.1
    }

    /// vital-beat: a lub-dub, 1 → 1.42 → 1.04 → 1.24 → 1, then still to the next beat.
    static func beat(_ p: Double) -> Double { keyframes([(0, 1), (0.10, 1.42), (0.20, 1.04), (0.29, 1.24), (0.44, 1), (1, 1)], at: p) }
    /// vital-beat-ring: the ring grows from 0.45 to 2.1 by 72% of the beat, appearing at 8% and gone by then.
    static func ring(_ p: Double) -> (scale: Double, opacity: Double) {
        guard p < 0.72 else { return (2.1, 0) }
        let u = p / 0.72
        let scale = 0.45 + (2.1 - 0.45) * (1 - (1 - u) * (1 - u))
        return (scale, keyframes([(0, 0), (0.08, 0.75), (0.72, 0)], at: p))
    }
    /// vital-breathe: in quicker (40%) than out, 0.78 → 1.25 in size and 0.7 → 1 in strength.
    static func breathe(_ p: Double) -> (scale: Double, opacity: Double) {
        (keyframes([(0, 0.78), (0.4, 1.25), (1, 0.78)], at: p), keyframes([(0, 0.7), (0.4, 1), (1, 0.7)], at: p))
    }
    /// vital-warmth, over 6 s: 0.9 → 1.08 in size, 0.55 → 0.95 in strength.
    static func warmth(_ p: Double) -> (scale: Double, opacity: Double) {
        (keyframes([(0, 0.9), (0.5, 1.08), (1, 0.9)], at: p), keyframes([(0, 0.55), (0.5, 0.95), (1, 0.55)], at: p))
    }
}

/// A callout's dot and halo, in its level's colour, moving at its own number (Figure.tsx CalloutMark). Reduce Motion
/// holds it still; the colours stay.
struct CalloutMark: View {
    let text: CalloutText
    /// The halo's and the dot's radius, in points.
    let halo: CGFloat
    let dot: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let moves = !reduceMotion && (text.rate != nil || (text.key == .temp && text.value != nil))
        TimelineView(.animation(paused: !moves)) { context in
            mark(t: moves ? context.date.timeIntervalSinceReferenceDate : nil)
        }
        .frame(width: halo * 5, height: halo * 5)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func mark(t: Double?) -> some View {
        let color = text.level.color
        let levelled = text.level != .neutral
        let rate = text.rate ?? 60
        let beat = t.map { CalloutMotion.beat(CalloutMotion.phase($0, period: 60 / rate)) } ?? 1
        let ring = t.map { CalloutMotion.ring(CalloutMotion.phase($0, period: 60 / rate)) }
        let breath = t.map { CalloutMotion.breathe(CalloutMotion.phase($0, period: 60 / rate)) } ?? (1, 1)
        let warmth = t.map { CalloutMotion.warmth(CalloutMotion.phase($0, period: 6)) } ?? (1, 0.8)
        return ZStack {
            if text.key == .temp, text.value != nil {
                Circle()
                    .fill(RadialGradient(stops: [.init(color: color.opacity(0.85), location: 0), .init(color: color.opacity(0.4), location: 0.45),
                                                 .init(color: color.opacity(0), location: 1)], center: .center, startRadius: 0, endRadius: halo * 2.4))
                    .frame(width: halo * 4.8, height: halo * 4.8)
                    .scaleEffect(warmth.0)
                    .opacity(warmth.1)
            }
            Circle()
                .fill(levelled ? color.opacity(0.16) : Palette.calloutRing.opacity(0.18))
                .overlay(Circle().stroke(levelled ? color.opacity(0.5) : Palette.calloutRing, lineWidth: 1))
                .frame(width: halo * 2, height: halo * 2)
                .scaleEffect(text.key == .breathing && text.rate != nil ? breath.0 : 1)
                .opacity(text.key == .breathing && text.rate != nil ? breath.1 : 1)
            if text.key == .heart, let ring, text.rate != nil {
                Circle().stroke(Palette.vitalHeart, lineWidth: 1.5)
                    .frame(width: halo * 2, height: halo * 2)
                    .scaleEffect(ring.scale)
                    .opacity(ring.opacity)
            }
            Circle().fill(color)
                .overlay(Circle().stroke(Palette.surface, lineWidth: 1.5))
                .frame(width: dot * 2, height: dot * 2)
                .scaleEffect(text.key == .heart && text.rate != nil ? beat : 1)
        }
    }
}

/// A callout's words: the vital's name, the value with its unit (a dash without one), and its status with the level's
/// dot (styles.css .callout: 11px name, 18px value, 11px status).
struct CalloutLabel: View {
    let text: CalloutText
    /// The digital human's labels stay on one line, each on a soft plate in dark mode.
    var digital = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(text.name).font(.app(size: 11, relativeTo: .caption2)).foregroundStyle(Palette.ink2)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(text.value ?? "—")
                    .font(.app(size: 18, weight: text.value == nil ? .bold : .medium, relativeTo: .headline))
                    .tracking(-0.36)
                    .foregroundStyle(Palette.ink)
                Text(text.unit).font(.app(size: 11, relativeTo: .caption2)).foregroundStyle(Palette.ink2)
            }
            if let status = text.status {
                HStack(alignment: .center, spacing: 5) {
                    if let level = text.statusLevel { Circle().fill(level.color).frame(width: 8, height: 8) }
                    Text(status)
                        .font(.app(size: 11, relativeTo: .caption2))
                        .foregroundStyle(text.scrubbed ? Palette.ink2 : Palette.ink3)
                        .lineLimit(digital || text.scrubbed ? 1 : 3)
                        .frame(maxWidth: digital ? nil : 120, alignment: .leading)
                }
            }
        }
        .fixedSize(horizontal: digital, vertical: true)
        // Beyond this the words no longer fit beside the figure; VoiceOver and the cards have them in full.
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .modifier(LabelBacking(digital: digital, dark: scheme == .dark, solid: reduceTransparency))
    }
}

/// Behind a digital human's label: in the light theme a soft halo in the page colour, so a label over an arm stays
/// readable; in the dark one a dark glass plate (figure.css), solid with Reduce Transparency.
private struct LabelBacking: ViewModifier {
    let digital: Bool
    let dark: Bool
    let solid: Bool

    func body(content: Content) -> some View {
        if !digital {
            content
        } else if dark {
            content.background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(solid ? Palette.page : Color(red: 14 / 255, green: 16 / 255, blue: 14 / 255).opacity(0.88))
                    .background { if !solid { RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.ultraThinMaterial) } }
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.cardEdge))
                    .padding(.horizontal, -8)
                    .padding(.vertical, -1)
            }
        } else {
            content.shadow(color: Palette.page, radius: 1.5).shadow(color: Palette.page, radius: 5)
        }
    }
}

// MARK: - Home's figure

/// Home's figure in the person's perspective, with the note about where a portrait comes from (Home.tsx home-figure):
/// nothing for 'stats', the photo for a portrait with one (the digital human if it can't be loaded), and the digital
/// human otherwise. The heart's callout opens live heart rate.
struct HomeFigure: View {
    let summary: Summary
    /// The timeline's marker, while it's moved on this same day.
    let scrub: HeartScrub?
    @Environment(Dashboard.self) private var dashboard
    @State private var liveOpen = false
    /// The photo's version that couldn't be loaded: the digital human stands in for it.
    @State private var failedPhoto: Double?

    var body: some View {
        let settings = dashboard.status?.settings
        let perspective = Perspective.of(settings)
        let photo = dashboard.status?.photo
        if perspective != .stats {
            VStack(alignment: .leading, spacing: 14) {
                if perspective == .portrait, let photo, failedPhoto != photo.version {
                    PortraitFigure(vitals: summary.vitals, asOf: summary.date, photo: photo, units: dashboard.units, scrub: scrub,
                                onHeart: { liveOpen = true }, onFailed: { failedPhoto = photo.version })
                } else {
                    DigitalFigure(vitals: summary.vitals, asOf: summary.date, variant: FigureVariant.of(settings).drawn, units: dashboard.units,
                                  scrub: scrub, onHeart: { liveOpen = true })
                }
                // A portrait is made from photos in Profile; until then the digital human stands in.
                if perspective == .portrait, photo == nil { PortraitNote() }
            }
            .sheet(isPresented: $liveOpen) { LiveHeartRateView() }
        }
    }
}

/// Where a portrait comes from, as true for this server (Home.tsx PortraitNote): made from your photos on an OpenAI
/// key, yours or the server's. "Not on this server" only when the server said both are missing; while it hasn't said,
/// the plain invitation.
struct PortraitNote: View {
    @Environment(Dashboard.self) private var dashboard

    /// The note's words before the link, and whether the link follows.
    static func words(byok: Bool?, portraits: Bool?) -> (text: String, link: Bool) {
        if portraits == false, byok == false { return (ServerWords.homePortraitNotHere, false) }
        return ("Your portrait appears here once it's made. \(portraits == false ? "Connect an OpenAI key and add" : "Add") photos in ", true)
    }

    static let link = "Profile → Your portrait photos"

    var body: some View {
        let (text, link) = Self.words(byok: dashboard.availability.byok, portraits: dashboard.availability.portraits)
        Text(attributed(text, link: link))
            .font(.app(.caption))
            .foregroundStyle(Palette.ink3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 360, alignment: .leading)
            .padding(.horizontal, 4)
            .environment(\.openURL, OpenURLAction { url in dashboard.open(url: url) ? .handled : .systemAction })
            .accessibilityIdentifier("portraitNote")
    }

    private func attributed(_ text: String, link: Bool) -> AttributedString {
        var out = AttributedString(text)
        guard link else { return out }
        var l = AttributedString(Self.link)
        l.link = URL(string: "healthos://profile")
        l.foregroundColor = Palette.accentText
        l.underlineStyle = .single
        out.append(l)
        out.append(AttributedString("."))
        return out
    }
}
