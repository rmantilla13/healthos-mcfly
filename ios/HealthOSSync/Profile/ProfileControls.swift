import SwiftUI

// The web's settings pieces as Profile and its sheets use them (src/styles.css .settings, .filters, .switch, .choice,
// .card-choices, .btn-quiet, .btn-danger, .note-good/.note-bad; src/styles/profile.css .profile-sheet). Each sets its
// own ink, so nothing above them needs a foreground style. Profile's own: the names start with Profile so they can't
// meet another page's.

/// A labelled field (.settings label): the label at 500 over its control, and a small muted line under it.
struct ProfileField<Control: View>: View {
    let label: String
    var hint: String?
    /// The hint in the critical colour, as the web's .note-bad small ("At least 10 characters." while too short).
    var hintIsBad = false
    @ViewBuilder var control: Control

    init(_ label: String, hint: String? = nil, hintIsBad: Bool = false, @ViewBuilder control: () -> Control) {
        self.label = label
        self.hint = hint
        self.hintIsBad = hintIsBad
        self.control = control()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.app(size: 14, weight: .medium, relativeTo: .subheadline)).foregroundStyle(Palette.ink)
            control
            if let hint {
                Text(hint)
                    .font(.app(size: 12, relativeTo: .caption))
                    .foregroundStyle(hintIsBad ? Palette.critical : Palette.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension View {
    /// A text field as the web's .settings input: a soft field with a hairline edge, ink words.
    func profileInput() -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return font(.app(size: 14, relativeTo: .subheadline))
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(minHeight: 40)
            .background(Palette.surface2, in: shape)
            .overlay(shape.strokeBorder(Palette.border))
    }
}

/// The web's quiet segmented pills (.filters): the chosen one white with a soft shadow, the others ink-2 on the soft
/// track. They go one under another when they don't fit side by side (long words, the largest text sizes).
struct ProfileSegments<Value: Hashable>: View {
    let label: String
    let options: [(value: Value, title: String)]
    let selection: Value?
    var disabled = false
    let choose: (Value) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            track(stacked: false)
            track(stacked: true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    private func track(stacked: Bool) -> some View {
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2)) : AnyLayout(HStackLayout(spacing: 0))
        let shape = RoundedRectangle(cornerRadius: stacked ? 18 : Radius.pill, style: .continuous)
        return layout {
            ForEach(options, id: \.value) { option in
                let on = option.value == selection
                Button { if !on { choose(option.value) } } label: {
                    Text(option.title)
                        .font(.app(size: 13, weight: .medium, relativeTo: .footnote))
                        .foregroundStyle(on ? Palette.ink : Palette.ink2)
                        .fixedSize(horizontal: !stacked, vertical: true)
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .frame(minHeight: 32)
                        .frame(maxWidth: stacked ? .infinity : nil, alignment: .leading)
                        .background {
                            if on { Capsule().fill(Palette.surface).tokenShadow(.pill, in: Capsule()) }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(disabled)
                .accessibilityAddTraits(on ? [.isSelected] : [])
                .sensoryFeedback(.selection, trigger: on) { _, now in now }
            }
        }
        .padding(3)
        // The track runs the row's width, its pills from the left, as the web's in a settings row.
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface2, in: shape)
        .overlay(shape.strokeBorder(Palette.border))
        .opacity(disabled ? 0.6 : 1)
    }
}

/// A setting with a switch (.settings .cycle-switch-row): its name at 500 and a muted line under it on the left, the
/// web's green switch at the top right. VoiceOver reads it as one switch, the line after the name.
struct ProfileSwitch: View {
    let title: String
    var text: String?
    @Binding var isOn: Bool

    init(_ title: String, text: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.text = text
        _isOn = isOn
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.app(size: 14, weight: .medium, relativeTo: .subheadline)).foregroundStyle(Palette.ink)
                if let text, !text.isEmpty {
                    Text(text)
                        .font(.app(size: 12, relativeTo: .caption))
                        .lineSpacing(2)
                        .foregroundStyle(Palette.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .toggleStyle(ProfileSwitchStyle())
    }
}

/// The switch at the top right of its words, as the web lays it out; the system's switch, in the web's green.
struct ProfileSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        ProfileSwitchBody(configuration: configuration)
    }
}

private struct ProfileSwitchBody: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            configuration.label.frame(maxWidth: .infinity, alignment: .leading)
            Toggle("", isOn: configuration.$isOn).labelsHidden().tint(Palette.good).fixedSize()
        }
        .opacity(isEnabled ? 1 : 0.6)
        .accessibilityElement(children: .ignore)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

/// A box to tick (.card-choices input): a rounded square, filled with the accent and ticked while on, the card's name
/// beside it.
struct ProfileCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        ProfileCheckboxBody(configuration: configuration)
    }
}

private struct ProfileCheckboxBody: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @ScaledMetric(relativeTo: .footnote) private var box: CGFloat = 18

    var body: some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(configuration.isOn ? Palette.accent : Palette.surface)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(configuration.isOn ? Palette.accent : Palette.ink3, lineWidth: 1)
                    if configuration.isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: min(box, 30) * 0.55, weight: .bold))
                            .foregroundStyle(Palette.accentInk)
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

/// The web's radio-like choice (.choice): a soft card with a name at 500 and a muted line; the chosen one white with an
/// ink edge. Nutrition's "What you see".
struct ProfileChoice: View {
    let title: String
    let text: String
    let isOn: Bool
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.app(size: 14, weight: .medium, relativeTo: .subheadline)).foregroundStyle(Palette.ink)
                Text(text).font(.app(size: 12, relativeTo: .caption)).foregroundStyle(Palette.ink3).fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isOn ? Palette.surface : Palette.surface2, in: shape)
            .overlay(shape.strokeBorder(isOn ? Palette.ink : Palette.border))
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.6)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
        .sensoryFeedback(.selection, trigger: isOn) { _, on in on }
    }
}

/// The web's .btn-quiet: just its words in the muted ink, darker while pressed (a row's Change password, a sheet's
/// Show all).
struct ProfileQuietStyle: ButtonStyle {
    var size: PillSize = .compact

    func makeBody(configuration: Configuration) -> some View {
        ProfileQuietBody(configuration: configuration, size: size)
    }
}

private struct ProfileQuietBody: View {
    let configuration: ButtonStyleConfiguration
    let size: PillSize
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(size.font)
            .foregroundStyle(configuration.isPressed ? Palette.ink : Palette.ink3)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(minHeight: size.height)
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.5)
    }
}

/// The web's .btn-danger: the white pill with its words in the critical colour (Delete all cycle data).
struct ProfileDangerStyle: ButtonStyle {
    var size: PillSize = .regular

    func makeBody(configuration: Configuration) -> some View {
        ProfileDangerBody(configuration: configuration, size: size)
    }
}

private struct ProfileDangerBody: View {
    let configuration: ButtonStyleConfiguration
    let size: PillSize
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(size.font)
            .foregroundStyle(Palette.critical)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, size.padding)
            .frame(minHeight: size.height)
            .background(configuration.isPressed ? Palette.surfaceHover : Palette.surface, in: Capsule())
            .tokenShadow(.pill, in: Capsule())
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.5)
    }
}

/// A result line (.note-good / .note-bad): a tick or an alert, and the words in the good or critical colour.
struct ProfileNote: View {
    let text: String
    let good: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: good ? "checkmark" : "exclamationmark.circle")
                .font(.system(size: 12, weight: .semibold))
                .accessibilityHidden(true)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.app(size: 13, relativeTo: .footnote))
        .foregroundStyle(good ? Palette.goodText : Palette.critical)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One part of a settings sheet (.profile-sheet > .card): flat on the sheet, a hairline over it when it follows
/// another, its heading at 15 and a muted line under it.
struct ProfileSheetPart<Content: View>: View {
    var title: String?
    var text: String?
    var divided = false
    @ViewBuilder var content: Content

    init(_ title: String? = nil, text: String? = nil, divided: Bool = false, @ViewBuilder content: () -> Content) {
        self.title = title
        self.text = text
        self.divided = divided
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if title != nil || text != nil {
                VStack(alignment: .leading, spacing: 4) {
                    if let title {
                        Text(title)
                            .font(.app(size: 15, weight: .medium, relativeTo: .headline))
                            .foregroundStyle(Palette.ink)
                            .accessibilityAddTraits(.isHeader)
                    }
                    if let text { ProfileFine(text) }
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, divided ? 20 : 0)
        .overlay(alignment: .top) {
            if divided { Rectangle().fill(Palette.border).frame(height: 1) }
        }
    }
}

/// A muted small line (.muted.small).
struct ProfileFine: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.app(size: 12, relativeTo: .caption))
            .lineSpacing(2)
            .foregroundStyle(Palette.ink3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
