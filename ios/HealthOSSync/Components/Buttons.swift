import SwiftUI

/// How big a pill is: `.regular` for a page's or a sheet's own buttons, `.compact` beside a row (Profile's rows).
enum PillSize {
    case regular, compact

    var font: Font { self == .regular ? .app(.subheadline, weight: .medium) : .app(.footnote, weight: .medium) }
    var height: CGFloat { self == .regular ? 44 : 34 }
    var padding: CGFloat { self == .regular ? 20 : 15 }
}

/// The web's primary button (.btn-primary): white words on the forest gradient, in a pill with a soft shadow, a shade
/// lighter while pressed. A step forward (Continue) has the ↗ glyph after its words, as on the web's sign-in and
/// onboarding.
///
///     Button("Continue") { … }.buttonStyle(.accentPill(arrow: true))
struct AccentPillStyle: ButtonStyle {
    var arrow = false
    var size: PillSize = .regular
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 7) {
            configuration.label
            if arrow { Image(systemName: "arrow.up.right").imageScale(.small).accessibilityHidden(true) }
        }
        .font(size.font)
        .foregroundStyle(Palette.accentInk)
        .lineLimit(1)
        .padding(.horizontal, size.padding)
        .frame(minHeight: size.height)
        .background { GradientFill(configuration.isPressed ? .accentGradHover : .accentGrad).clipShape(Capsule()) }
        .tokenShadow(.pill, in: Capsule())
        .contentShape(Capsule())
        .opacity(isEnabled ? 1 : 0.5)
        .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// The web's quiet pill (.btn and .pill): ink words on a white pill with a soft shadow. Refresh, Manage sources, a
/// Profile row's Change, a sheet's Cancel.
struct QuietPillStyle: ButtonStyle {
    var size: PillSize = .regular
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(size.font)
            .foregroundStyle(configuration.isPressed ? Palette.ink : Palette.ink2)
            .lineLimit(1)
            .padding(.horizontal, size.padding)
            .frame(minHeight: size.height)
            .background(Palette.surface, in: Capsule())
            .tokenShadow(.pill, in: Capsule())
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.5)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == AccentPillStyle {
    static var accentPill: AccentPillStyle { AccentPillStyle() }
    static func accentPill(arrow: Bool = false, size: PillSize = .regular) -> AccentPillStyle { AccentPillStyle(arrow: arrow, size: size) }
}

extension ButtonStyle where Self == QuietPillStyle {
    static var quietPill: QuietPillStyle { QuietPillStyle() }
    static func quietPill(size: PillSize) -> QuietPillStyle { QuietPillStyle(size: size) }
}

/// The web's switch (.switch): green when on (--good), in light and dark alike. It's the system's own switch, so it keeps
/// its feel, haptics and VoiceOver; only its colour is the web's. The app's tint (sage words in dark mode) would make a
/// pale track the white knob barely shows on. Set for the whole app at the root, and in SheetScaffold.
struct AppSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Toggle(configuration).toggleStyle(.switch).tint(Palette.good)
    }
}

extension ToggleStyle where Self == AppSwitchStyle {
    static var appSwitch: AppSwitchStyle { AppSwitchStyle() }
}
