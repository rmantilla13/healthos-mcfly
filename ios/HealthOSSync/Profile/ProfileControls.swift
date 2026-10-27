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

/// Profile's pills (.btn, .btn-primary and .btn-danger beside a row or in a sheet): the quiet white pill, the forest one,
/// or the white one with critical words. As the shared pills, except that their words wrap at the largest text sizes
/// rather than being cut off ("Manage chatbot AI", "Upload all history again"), the pill growing into a rounded card.
struct ProfilePillStyle: ButtonStyle {
    enum Kind { case quiet, accent, danger }
    var kind: Kind = .quiet
    var size: PillSize = .compact

    init(_ kind: Kind = .quiet, size: PillSize = .compact) {
        self.kind = kind
        self.size = size
    }

    func makeBody(configuration: Configuration) -> some View {
        ProfilePillBody(configuration: configuration, kind: kind, size: size)
    }
}

private struct ProfilePillBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: ProfilePillStyle.Kind
    let size: PillSize
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size.height / 2, style: .continuous)
        configuration.label
            .font(size.font)
            .foregroundStyle(ink)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, size.padding)
            .padding(.vertical, 6)
            .frame(minHeight: size.height)
            .background {
                switch kind {
                case .accent: GradientFill(configuration.isPressed ? .accentGradHover : .accentGrad).clipShape(shape)
                case .quiet, .danger: shape.fill(kind == .danger && configuration.isPressed ? Palette.surfaceHover : Palette.surface)
                }
            }
            .tokenShadow(.pill, in: shape)
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.5)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: configuration.isPressed)
    }

    private var ink: Color {
        switch kind {
        case .accent: Palette.accentInk
        case .danger: Palette.critical
        case .quiet: configuration.isPressed ? Palette.ink : Palette.ink2
        }
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
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .frame(minHeight: size.height)
            .contentShape(Rectangle())
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

/// Views in rows, as the web's flex-wrap: each beside the last while it fits, else on a new row, tops aligned. One
/// wider than a row gets the row to itself, offered the row's width (the largest text sizes).
struct ProfileWrap: Layout {
    var spacing: CGFloat = 12

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for item in row.items {
                subviews[item.index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var items: [(index: Int, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for (index, subview) in subviews.enumerated() {
            let ideal = subview.sizeThatFits(.unspecified)
            if !row.items.isEmpty, row.width + spacing + ideal.width > width {
                rows.append(row)
                row = Row()
            }
            let size = ideal.width > width ? subview.sizeThatFits(ProposedViewSize(width: width, height: nil)) : ideal
            row.width += (row.items.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.items.append((index, size))
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}
