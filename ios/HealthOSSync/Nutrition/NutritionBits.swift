import SwiftUI

// The small pieces Nutrition's pages share, drawn as the web draws them (src/styles.css and src/styles/nutrition.css):
// quiet text buttons, the food fields, a field's label, the chip buttons for water, the red note, and a row that wraps.

/// The web's quiet button (.btn-quiet): no fill, the muted ink, ink while pressed. At least 44pt to tap.
struct QuietTextButtonStyle: ButtonStyle {
    var size: CGFloat = 13
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.app(size: size, weight: .medium, relativeTo: .footnote))
            .foregroundStyle(configuration.isPressed ? Palette.ink : Palette.ink3)
            .padding(.horizontal, 6)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.5)
    }
}

extension ButtonStyle where Self == QuietTextButtonStyle {
    static var quietText: QuietTextButtonStyle { QuietTextButtonStyle() }
    static func quietText(size: CGFloat) -> QuietTextButtonStyle { QuietTextButtonStyle(size: size) }
}

/// The web's .chip-btn: a white field with a hairline edge, ink words (water's "+ Glass, 250 mL").
struct ChipButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        configuration.label
            .font(.app(size: 13, relativeTo: .footnote))
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(minHeight: 44)
            .background(configuration.isPressed ? Palette.surfaceHover : Palette.surface, in: shape)
            .overlay(shape.strokeBorder(Palette.border))
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.5)
    }
}

extension ButtonStyle where Self == ChipButtonStyle {
    static var chip: ChipButtonStyle { ChipButtonStyle() }
}

extension View {
    /// A food field (.food-log input on the web): the soft second surface, a hairline edge, rounded 10. `raised` is the
    /// white field inside an opened result (.food-result.is-open .food-pick input).
    func foodInput(raised: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return self
            .font(.app(size: 14, relativeTo: .subheadline))
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(minHeight: 40)
            .background(raised ? Palette.surface : Palette.surface2, in: shape)
            .overlay(shape.strokeBorder(Palette.border))
    }

    /// The web's small muted text (.muted.small).
    func mutedSmall() -> some View {
        font(.app(size: 12, relativeTo: .caption)).foregroundStyle(Palette.ink3).fixedSize(horizontal: false, vertical: true)
    }
}

/// A field's label over it ("Name", "How many").
struct FieldLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).mutedSmall().accessibilityHidden(true)
    }
}

/// Something went wrong, in the server's or the web's words (.note-bad): the critical red, with the alert mark.
struct NoteBad: View {
    let text: String
    var icon = false
    var size: CGFloat = 13

    init(_ text: String, icon: Bool = false, size: CGFloat = 13) {
        self.text = text
        self.icon = icon
        self.size = size
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if icon { Image(systemName: "exclamationmark.circle").imageScale(.small).accessibilityHidden(true) }
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.app(size: size, relativeTo: .footnote))
        .foregroundStyle(Palette.critical)
    }
}

/// Views in a row that wrap onto the next line when they don't fit (flex-wrap), each its own size.
struct NutritionFlow: Layout {
    var spacing: CGFloat = 8
    var rowSpacing: CGFloat = 6

    private struct Row {
        var items: [(index: Int, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height } + rowSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for item in row.items {
                subviews[item.index].place(at: CGPoint(x: x, y: y + (row.height - item.size.height) / 2), proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += row.height + rowSpacing
        }
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

/// A card's head: its title and something small on the right (.nutri-card-head), wrapping under at the largest sizes.
struct NutriCardHead<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                heading
                Spacer(minLength: 0)
                trailing
            }
            VStack(alignment: .leading, spacing: 6) {
                heading
                trailing
            }
        }
    }

    private var heading: some View {
        Text(title)
            .font(.app(size: 14.5, weight: .medium, relativeTo: .subheadline))
            .foregroundStyle(Palette.ink)
            .accessibilityAddTraits(.isHeader)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Text with the app's own healthos:// links ("Change it in [your Profile](healthos://profile).") opening their page.
struct LinkedText: View {
    let markdown: String
    @Environment(Dashboard.self) private var dashboard

    init(_ markdown: String) { self.markdown = markdown }

    /// The links underlined, as the web's text links are.
    static func underlined(_ markdown: String) -> AttributedString {
        var text = (try? AttributedString(markdown: markdown)) ?? AttributedString(markdown)
        for run in text.runs where run.link != nil { text[run.range].underlineStyle = .single }
        return text
    }

    var body: some View {
        Text(Self.underlined(markdown))
            .tint(Palette.accentText)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.openURL, OpenURLAction { url in dashboard.open(url: url) ? .handled : .systemAction })
    }
}

/// A pill button's words, wrapping at the largest text sizes instead of being cut off (the pill styles keep one line,
/// and the innermost line limit wins).
struct PillLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .lineLimit(nil)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 6)
    }
}
