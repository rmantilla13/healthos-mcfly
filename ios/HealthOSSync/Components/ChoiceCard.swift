import SwiftUI

/// A radio card (.ai-choice on the web): a round mark, a name and a muted line, and anything else under them (a Badge).
/// The chosen one has a sage edge over a faint green wash.
///
///     ChoiceCard("Anthropic", subtitle: "Claude", isOn: provider == .anthropic) { provider = .anthropic }
struct ChoiceCard<Accessory: View>: View {
    let title: String
    var subtitle: String?
    let isOn: Bool
    let action: () -> Void
    @ViewBuilder var accessory: Accessory
    @Environment(\.isEnabled) private var isEnabled

    init(_ title: String, subtitle: String? = nil, isOn: Bool, action: @escaping () -> Void, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.subtitle = subtitle
        self.isOn = isOn
        self.action = action
        self.accessory = accessory()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.field, style: .continuous)
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                RadioMark(isOn: isOn).padding(.top, 1)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.app(.subheadline, weight: .medium)).foregroundStyle(Palette.ink)
                    if let subtitle { Text(subtitle).font(.app(.footnote)).foregroundStyle(Palette.ink3) }
                    accessory
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 68, alignment: .topLeading)
            .background {
                if isOn { GradientFill(.choiceWash).clipShape(shape) } else { shape.fill(Palette.surface) }
            }
            .overlay(shape.strokeBorder(isOn ? Palette.choiceBorder : Palette.border))
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.7)
        }
        .buttonStyle(.plain)
        // Choosing one card turns another off: only the one chosen taps.
        .sensoryFeedback(.selection, trigger: isOn) { _, on in on }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}

extension ChoiceCard where Accessory == EmptyView {
    init(_ title: String, subtitle: String? = nil, isOn: Bool, action: @escaping () -> Void) {
        self.init(title, subtitle: subtitle, isOn: isOn, action: action) { EmptyView() }
    }
}

/// A radio button's round mark, as the web's radio (a native one with the accent as its accent-color) draws in light and
/// dark: an empty ring, on white in light mode and on a grey disc in dark mode; once chosen, an accent ring, a white band
/// and an accent dot.
struct RadioMark: View {
    let isOn: Bool
    /// The empty radio's disc and ring in dark mode, the browser's own (light keeps the app's surface and ink).
    private static let offFill = Themed(CSSColor(0xFFFFFF), CSSColor(0x3B3B3B)).color
    private static let offRing = Themed(CSSColor(0x5F6661), CSSColor(0x858585)).color

    var body: some View {
        ZStack {
            if isOn {
                Circle().fill(Palette.accent)
                Circle().fill(Color.white).padding(1)
                Circle().fill(Palette.accent).padding(3)
            } else {
                Circle().fill(Self.offFill)
                Circle().strokeBorder(Self.offRing, lineWidth: 1)
            }
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }
}

/// A chip that turns on and off (.onb-chip on the web): a soft field, its edge sage and its fill pale green while on.
/// Its translucent field is solid under Reduce Transparency.
///
///     ChipToggle("Running", isOn: $running)
struct ChipToggle: View {
    let title: String
    @Binding var isOn: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    init(_ title: String, isOn: Binding<Bool>) {
        self.title = title
        _isOn = isOn
    }

    // onboarding.css: --onb-field, --onb-field-border and --onb-chip-on, light and dark.
    private static let field = Themed(CSSColor.rgba(255, 255, 255, 0.82), .rgba(255, 255, 255, 0.04)).color
    private static let fieldBorder = Themed(CSSColor.rgba(36, 49, 42, 0.1), .rgba(255, 255, 255, 0.1)).color
    private static let on = Themed(0xE3ECDB, 0x26352A).color

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.field, style: .continuous)
        Button { isOn.toggle() } label: {
            Text(title)
                .font(.app(.subheadline))
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, 18)
                .frame(minHeight: 44)
                .background(isOn ? Self.on : reduceTransparency ? Palette.surface : Self.field, in: shape)
                .overlay(shape.strokeBorder(isOn ? Palette.choiceBorder : Self.fieldBorder))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: isOn)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}
