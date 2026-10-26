import SwiftUI

// The frame of the way in (src/components/WelcomeShell.tsx, src/styles/onboarding.css): sign-in, an invite's "Create
// your account", a reset link's new password and the welcome's three steps share it, so joining reads as one flow. The
// healthOS mark top left, a link top right (Change server, Sign out, Back to Profile), a glass card, and the tagline
// under it, on a warm page with a peach glow top right and a sage one bottom left. Full screen, as the web's phone shows
// these pages: no tab bar and no navigation bar.

/// onboarding.css's own tokens, light and dark (its :root block and its dark block). WelcomeLookTests reads the CSS
/// and checks each one, so change both together.
enum WelcomeLook {
    /// --onb-step-off: a step tab not reached yet.
    static let stepOff = Themed<CSSColor>(0xB4B8B2, 0x5D625D)
    /// --onb-field and --onb-field-border: fields and chips, nearly white over the card's sheen, with a hairline edge.
    static let field = Themed<CSSColor>(.rgba(255, 255, 255, 0.82), .rgba(255, 255, 255, 0.04))
    static let fieldBorder = Themed<CSSColor>(.rgba(36, 49, 42, 0.1), .rgba(255, 255, 255, 0.1))
    /// --onb-chip-on: a chosen chip, in sage.
    static let chipOn = Themed<CSSColor>(0xE3ECDB, 0x26352A)
    /// --onb-card-bg: a perspective card not chosen.
    static let cardBg = Themed<CSSColor>(.rgba(255, 255, 255, 0.55), .rgba(255, 255, 255, 0.025))
    /// --onb-art-shade: the soft shadow the step 1 illustrations stand in.
    static let artShade = Themed<CSSColor>(.rgba(36, 49, 42, 0.07), .rgba(0, 0, 0, 0.35))
    /// --onb-bust-light and --onb-bust-dark: "Your own portrait"'s bust.
    static let bustLight = Themed<CSSColor>(0xEFD8C1, 0x8D7763)
    static let bustDark = Themed<CSSColor>(0xC99D77, 0x5D4A3B)
    /// --onb-bar-top and --onb-bar-bottom: the sage bars; --onb-you-top and --onb-you-bottom: you, in amber.
    static let barTop = Themed<CSSColor>(0xDCEAD6, 0x46664A)
    static let barBottom = Themed<CSSColor>(0xA9C7A1, 0x2E4733)
    static let youTop = Themed<CSSColor>(0xEFCC9F, 0xDCAA6A)
    static let youBottom = Themed<CSSColor>(0xD39B61, 0xA6713C)
    /// --onb-consent-border: the peer comparisons' consent.
    static let consentBorder = Themed<CSSColor>(.rgba(126, 157, 134, 0.3), .rgba(143, 179, 154, 0.2))

    /// --onb-peach: step 2's preview card, white into peach.
    static let peach = Themed<[CSSGradient]>(
        [.linear(100, [(.rgba(255, 255, 255, 0.78), 0), (.rgba(255, 248, 242, 0.9), 0.55), (CSSColor(0xFDEEE2), 1)])],
        [.linear(100, [(.rgba(255, 255, 255, 0.02), 0), (.rgba(122, 78, 44, 0.16), 0.6), (.rgba(122, 78, 44, 0.3), 1)])])
    /// --onb-consent-bg.
    static let consentBg = Themed<[CSSGradient]>(
        [.linear(160, [(CSSColor(0xF2F7EE), 0), (CSSColor(0xF8FBF6), 1)])],
        [.linear(160, [(CSSColor(0x1D2820), 0), (CSSColor(0x1A201C), 1)])])
    /// --onb-bg, its layers from the top, over --page: a peach glow top right, a sage one bottom left, the page's own
    /// glow in the middle.
    static let background = Themed<[CSSGradient]>(
        [.radial(0.6, 0.55, at: 0.92, 0.06, [(.rgba(251, 228, 208, 0.55), 0), (.rgba(251, 228, 208, 0), 0.72)]),
         .radial(0.55, 0.55, at: 0.04, 0.98, [(.rgba(221, 234, 214, 0.6), 0), (.rgba(221, 234, 214, 0), 0.72)]),
         .radial(0.6, 0.6, at: 0.5, 0.3, [(ColorToken.pageGlow.value.light, 0), (.rgba(251, 250, 247, 0), 0.7)])],
        [.radial(0.6, 0.55, at: 0.92, 0.06, [(.rgba(122, 78, 44, 0.16), 0), (.rgba(122, 78, 44, 0), 0.72)]),
         .radial(0.55, 0.55, at: 0.04, 0.98, [(.rgba(60, 92, 54, 0.2), 0), (.rgba(60, 92, 54, 0), 0.72)]),
         .radial(0.6, 0.6, at: 0.5, 0.3, [(ColorToken.pageGlow.value.dark, 0), (.rgba(22, 25, 22, 0), 0.7)])])

    /// The tagline under every card.
    static let tagline = "Your health, in perspective. Only yours."
}

/// CSS gradient layers filling the frame, the first on top, over an optional base colour.
struct GradientLayers: View {
    let layers: Themed<[CSSGradient]>
    var base: Themed<CSSColor>?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let layers = layers(scheme)
        let base = base?(scheme)
        Canvas { ctx, size in
            if let base { ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(base.color)) }
            for layer in layers.reversed() { layer.draw(in: ctx, size: size) }
        }
        .accessibilityHidden(true)
    }
}

/// The frame itself: the mark and "healthOS", `end` at the top right, the content, the tagline.
struct WelcomeFrame<End: View, Content: View>: View {
    /// Space above the card: a short form sits lower than the welcome's steps (.onb-body on a phone).
    var spacing: CGFloat = 24
    @ViewBuilder var end: End
    @ViewBuilder var content: Content

    init(spacing: CGFloat = 24, @ViewBuilder end: () -> End, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.end = end()
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    HStack(spacing: 10) {
                        BrandMark().frame(width: 30, height: 30)
                        Text("healthOS")
                            .font(.app(size: 18, weight: .medium, relativeTo: .title3))
                            .tracking(-0.18)
                            .foregroundStyle(Palette.ink)
                            .lineLimit(1)
                    }
                    .accessibilityElement(children: .combine)
                    Spacer(minLength: 0)
                    end
                }
                // The mark and the link stop growing at xxLarge, so "healthOS" is never cut short; VoiceOver reads both.
                .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                content.padding(.top, spacing)
                Text(WelcomeLook.tagline)
                    .font(.app(size: 12, relativeTo: .caption))
                    .foregroundStyle(Palette.ink3)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 26)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .background { GradientLayers(layers: WelcomeLook.background, base: ColorToken.page.value).ignoresSafeArea() }
        // The web shows these pages on their own, outside the dashboard: no bars over or under them.
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .font(.app(.body))
        .tint(Palette.tint)
    }
}

extension WelcomeFrame where End == EmptyView {
    init(spacing: CGFloat = 24, @ViewBuilder content: () -> Content) {
        self.init(spacing: spacing, end: { EmptyView() }, content: content)
    }
}

/// The glass card (.card.onb-card): the dashboard's card surface, padded as the web's phone pads it. `narrow` is the
/// sign-in pages' card (.onb-card-narrow), its parts 18pt apart.
struct WelcomeCard<Content: View>: View {
    var narrow = true
    @ViewBuilder var content: Content

    init(narrow: Bool = true, @ViewBuilder content: () -> Content) {
        self.narrow = narrow
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: narrow ? 18 : 0) { content }
            .padding(.horizontal, 20)
            .padding(.top, narrow ? 26 : 24)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { CardSurface(shape: RoundedRectangle(cornerRadius: Radius.card, style: .continuous)) }
    }
}

/// A card's eyebrow, title and lede (.onb-head). The title is the page's heading.
struct WelcomeHead: View {
    var eyebrow: String?
    let title: String
    var lede: String?
    /// 26 on a phone, for the sign-in pages and the welcome's steps alike.
    var size: CGFloat = 26
    var lede14 = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let eyebrow {
                Text(eyebrow)
                    .textCase(.uppercase)
                    .font(.app(size: 11, weight: .medium, relativeTo: .caption2))
                    .tracking(11 * 0.16)
                    .foregroundStyle(Palette.ink3)
                    .padding(.bottom, 16)
            }
            Text(title)
                .font(.app(size: size, weight: .medium, relativeTo: .title))
                .tracking(-0.02 * size)
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if let lede {
                Text(lede)
                    .font(.app(size: lede14 ? 14 : 13, relativeTo: .subheadline))
                    .lineSpacing(3)
                    .foregroundStyle(Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A labelled field (.onb-field): the label over a soft, rounded field, and an optional line under it.
struct WelcomeField<Focus: Hashable, Below: View>: View {
    let label: String
    @Binding var text: String
    var secure = false
    var readOnly = false
    var focus: FocusState<Focus?>.Binding
    let field: Focus
    var invalid = false
    /// The text field's own accessibility identifier (for UI tests), not the label's or the hint's.
    var id: String
    @ViewBuilder var below: Below
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    init(_ label: String, text: Binding<String>, secure: Bool = false, readOnly: Bool = false, focus: FocusState<Focus?>.Binding, field: Focus,
         invalid: Bool = false, id: String, @ViewBuilder below: () -> Below) {
        self.label = label
        _text = text
        self.secure = secure
        self.readOnly = readOnly
        self.focus = focus
        self.field = field
        self.invalid = invalid
        self.id = id
        self.below = below()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.field, style: .continuous)
        let focused = focus.wrappedValue == field
        VStack(alignment: .leading, spacing: 7) {
            Text(label)
                .font(.app(size: 13, weight: .medium, relativeTo: .footnote))
                .foregroundStyle(Palette.ink)
                .accessibilityHidden(true)
            Group {
                if secure {
                    SecureField(label, text: $text, prompt: Text(""))
                } else {
                    TextField(label, text: $text, prompt: Text(""))
                }
            }
            .font(.app(size: 15, relativeTo: .subheadline))
            .foregroundStyle(readOnly ? Palette.ink2 : Palette.ink)
            .focused(focus, equals: field)
            .disabled(readOnly)
            .accessibilityIdentifier(id)
            // The whole field takes the tap, not only the line of text in it.
            .frame(minHeight: 44)
            .padding(.horizontal, 14)
            .background {
                if readOnly { Color.clear } else { (reduceTransparency ? Palette.surface : WelcomeLook.field.color).clipShape(shape) }
            }
            .overlay(shape.strokeBorder(invalid ? Palette.critical : WelcomeLook.fieldBorder.color))
            // The web's focus ring (:focus-visible): 2pt of --focus just outside the field.
            .overlay {
                if focused, !readOnly {
                    RoundedRectangle(cornerRadius: Radius.field + 3, style: .continuous).strokeBorder(Palette.focus, lineWidth: 2).padding(-3)
                }
            }
            below
        }
    }
}

extension WelcomeField where Below == EmptyView {
    init(_ label: String, text: Binding<String>, secure: Bool = false, readOnly: Bool = false, focus: FocusState<Focus?>.Binding, field: Focus,
         invalid: Bool = false, id: String) {
        self.init(label, text: text, secure: secure, readOnly: readOnly, focus: focus, field: field, invalid: invalid, id: id) { EmptyView() }
    }
}

/// A form's last row (WelcomeFoot): a hairline, then Back and a helper line, then the main button across the card.
struct WelcomeFoot<Start: View, Main: View>: View {
    var top: CGFloat = 4
    /// Whether there's a Back or a helper line; without one the button sits right under the hairline.
    var hasStart = true
    @ViewBuilder var start: Start
    @ViewBuilder var main: Main

    init(top: CGFloat = 4, hasStart: Bool = true, @ViewBuilder start: () -> Start, @ViewBuilder main: () -> Main) {
        self.top = top
        self.hasStart = hasStart
        self.start = start()
        self.main = main()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Palette.border).frame(height: 1).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 12) {
                if hasStart { start }
                main.frame(maxWidth: .infinity)
            }
            .padding(.top, hasStart ? 14 : 20)
        }
        .padding(.top, top)
    }
}

extension WelcomeFoot where Start == EmptyView {
    init(top: CGFloat = 4, @ViewBuilder main: () -> Main) {
        self.init(top: top, hasStart: false, start: { EmptyView() }, main: main)
    }
}

/// The main button's words across the card, centred with the ↗ of a step forward after them (the web's .onb-next
/// at phone width). They shrink a little rather than be cut off at the largest text sizes. Use it with `.accentPill`
/// without its own arrow.
struct WelcomeButtonLabel: View {
    let text: String
    var arrow = false
    init(_ text: String, arrow: Bool = false) {
        self.text = text
        self.arrow = arrow
    }

    var body: some View {
        HStack(spacing: 7) {
            Text(text).minimumScaleFactor(0.6)
            if arrow { Image(systemName: "arrow.up.right").imageScale(.small).accessibilityHidden(true) }
        }
        .frame(maxWidth: .infinity)
    }
}

/// A quiet text button (.onb-back, .onb-top-link): Back, Have an invite code?, Change server, Sign out. Tall enough to
/// tap, however small its words.
struct WelcomeLinkStyle: ButtonStyle {
    var size: CGFloat = 12
    var color: Color = Palette.ink2
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.app(size: size, relativeTo: .footnote))
            .foregroundStyle(configuration.isPressed ? Palette.ink : color)
            .padding(.horizontal, 2)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.5)
    }
}

extension ButtonStyle where Self == WelcomeLinkStyle {
    /// In the card: Back, Have an invite code?
    static var welcomeLink: WelcomeLinkStyle { WelcomeLinkStyle() }
    /// The frame's top right: Change server, Sign out, Back to Profile.
    static var welcomeTopLink: WelcomeLinkStyle { WelcomeLinkStyle(color: Palette.ink3) }
}

/// "← Back", "← Back to sign-in".
struct BackLabel: View {
    let text: String
    init(_ text: String = "Back") { self.text = text }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.left").imageScale(.small).accessibilityHidden(true)
            Text(text)
        }
    }
}

/// What went wrong (.note-bad with its alert icon), in the server's own words when it gave any. VoiceOver reads it
/// out when it appears, as the web's role="alert".
struct ErrorNote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.circle").imageScale(.small).accessibilityHidden(true)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.app(size: 13, relativeTo: .footnote))
        .foregroundStyle(Palette.critical)
        .accessibilityElement(children: .combine)
        .onAppear { AccessibilityNotification.Announcement(text).post() }
        .onChange(of: text) { _, now in AccessibilityNotification.Announcement(now).post() }
    }
}

/// A small muted line under a form (.onb-note).
struct WelcomeNote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.app(size: 11, relativeTo: .caption2))
            .lineSpacing(2)
            .foregroundStyle(Palette.ink3)
            .fixedSize(horizontal: false, vertical: true)
    }
}
