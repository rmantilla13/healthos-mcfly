import SwiftUI

/// The web's CardChoices box to tick, for Home's Edit widgets and Profile → Cards alike (EditWidgets.tsx and Profile.tsx
/// draw one component): a rounded square, filled with the accent and ticked in the accent's ink while on, the card's
/// name beside it, the whole row to tap. src/styles.css gives `.card-choices input` the accent: its later rule
/// (`accent-color: var(--accent)`, beside the settings' checkboxes) overrides the earlier ink one. VoiceOver reads it as
/// a switch, on or off.
struct CardChoicesCheckboxStyle: ToggleStyle {
    /// The box's fill while ticked, and its tick.
    static let ticked = Palette.accent
    static let tick = Palette.accentInk

    func makeBody(configuration: Configuration) -> some View {
        CardChoicesCheckboxBody(configuration: configuration)
    }
}

private struct CardChoicesCheckboxBody: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @ScaledMetric(relativeTo: .footnote) private var box: CGFloat = 18

    var body: some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(configuration.isOn ? CardChoicesCheckboxStyle.ticked : Palette.surface)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(configuration.isOn ? CardChoicesCheckboxStyle.ticked : Palette.ink3, lineWidth: 1)
                    if configuration.isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: min(box, 30) * 0.55, weight: .bold))
                            .foregroundStyle(CardChoicesCheckboxStyle.tick)
                    }
                }
                .frame(width: min(box, 30), height: min(box, 30))
                .padding(.top, 1)
                configuration.label.frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 6)
            .frame(minHeight: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.55)
        .sensoryFeedback(.selection, trigger: configuration.isOn)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}
