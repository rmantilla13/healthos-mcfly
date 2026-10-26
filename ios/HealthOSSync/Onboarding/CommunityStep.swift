import SwiftUI

/// Step 3, "Your progress, in perspective." (Onboarding.tsx CommunityStep): what anonymous peer comparisons are, and the
/// choice to take part, unticked until the person ticks it and only open with an adult age. The numbers are the
/// server's (shared/peers.ts, `Peers`).
struct CommunityStep: View {
    @Bindable var model: OnboardingModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let age = OnboardingFlow.parseAge(model.answers.age)
        let adult = OnboardingFlow.canJoinPeers(age)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                PeerBars().frame(width: 140, height: 96)
                VStack(alignment: .leading, spacing: 12) {
                    Text(OnboardingWords.peersTitle)
                        .font(.app(size: 14, weight: .medium, relativeTo: .subheadline))
                        .foregroundStyle(Palette.ink)
                    Text(OnboardingWords.peersText)
                        .font(.app(size: 13, relativeTo: .footnote))
                        .lineSpacing(4)
                        .foregroundStyle(Palette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 28)
            consent(age: age, adult: adult).padding(.top, 24)
            WelcomeNote(OnboardingWords.peersNote)
                .padding(.top, 14)
        }
    }

    private func consent(age: Int?, adult: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        // Sharing in a comparison is the person's choice, never a default.
        return Toggle(isOn: Binding(get: { adult && model.answers.peer }, set: { model.answers.peer = $0 })) {
            VStack(alignment: .leading, spacing: 8) {
                Text(OnboardingWords.consentTitle)
                    .font(.app(size: 14, weight: .medium, relativeTo: .subheadline))
                    .foregroundStyle(adult ? Palette.ink : Palette.ink3)
                Text(OnboardingWords.consentText)
                    .font(.app(size: 12, relativeTo: .footnote))
                    .lineSpacing(3)
                    .foregroundStyle(Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                if !adult {
                    Text(age == nil ? OnboardingWords.consentNeedsAge : OnboardingWords.consentAdults)
                        .font(.app(size: 12, relativeTo: .footnote))
                        .foregroundStyle(ColorToken.badgePeachInk.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("consentWhy")
                }
            }
        }
        .toggleStyle(CheckboxStyle())
        .disabled(!adult)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { GradientLayers(layers: WelcomeLook.consentBg).clipShape(shape) }
        .overlay(shape.strokeBorder(WelcomeLook.consentBorder.color))
        .accessibilityIdentifier("peerConsent")
    }
}

/// The web's checkbox (an input in --accent): a rounded square, ticked in white on the accent. The whole row taps, as
/// the web's label does; VoiceOver reads it as a switch, on or off.
struct CheckboxStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled
    /// The box grows with the text beside it, up to a point.
    @ScaledMetric(relativeTo: .subheadline) private var box: CGFloat = 18

    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(configuration.isOn ? Palette.accent : Palette.surface)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(configuration.isOn ? Palette.accent : Palette.ink3, lineWidth: 1)
                    if configuration.isOn {
                        Image(systemName: "checkmark")
                            .font(.app(fixedSize: 11, weight: .bold))
                            .foregroundStyle(Palette.accentInk)
                    }
                }
                .frame(width: min(box, 30), height: min(box, 30))
                .padding(.top, 1)
                .opacity(isEnabled ? 1 : 0.5)
                configuration.label
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: configuration.isOn)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}
