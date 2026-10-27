import SwiftUI

/// Nutrition's own colours (src/styles/nutrition.css, light and dark): Today's three soft pastels for protein, carbs
/// and fat (never a colour for more or less), the empty balance ring's pale loop, your messages' bubble, the send
/// button while it can't send, and the composer's field. NutritionConversationTests reads nutrition.css and checks
/// each value here, so change both together. Trends' macro balance keeps the chart series colours, as on the web.
enum NutriColor: String, CaseIterable {
    case protein = "nutri-protein", carbs = "nutri-carbs", fat = "nutri-fat"
    case bubble = "nutri-bubble", sendOff = "nutri-send-off", field = "nutri-field"

    var value: Themed<CSSColor> {
        switch self {
        case .protein: Themed(0x9CC78C, 0x7FAE70)
        case .carbs: Themed(0xF0B07E, 0xD0905E)
        case .fat: Themed(0xB2A6E6, 0x9387D2)
        case .bubble: Themed(0xEAF2E5, 0x253128)
        case .sendOff: Themed(0xB3BDAF, 0x3A433C)
        case .field: Themed(0xFFFFFF, 0x1F221F)
        }
    }

    var color: Color { value.color }

    /// The colour a macro is drawn in on Today.
    static func macro(_ key: String) -> Color {
        switch key {
        case "protein_g": protein.color
        case "carbs_g": carbs.color
        default: fat.color
        }
    }

    /// --nutri-ring: conic-gradient(from 210deg, …), the balance ring with nothing in it.
    static let ring: Themed<[CSSColor]> = Themed(
        [CSSColor(0xE3EEDB), CSSColor(0xF6ECD8), CSSColor(0xEBE5F6), CSSColor(0xE0EDE0), CSSColor(0xE3EEDB)],
        [CSSColor(0x2C3A2A), CSSColor(0x3D3526), CSSColor(0x332E44), CSSColor(0x2A3A2E), CSSColor(0x2C3A2A)])
    /// Where the ring's loop starts: CSS's 210deg from twelve o'clock, clockwise.
    static let ringFrom: Double = 210
}

/// The empty balance ring's pale loop (--nutri-ring), drawn as CSS draws a conic gradient: from 210° clockwise from
/// the top, the five colours evenly round.
struct NutriRingLoop: View {
    var thickness: CGFloat = 11
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let colors = NutriColor.ring(scheme).map(\.color)
        // SwiftUI's angles start at three o'clock; CSS's conic gradients at twelve.
        Circle()
            .strokeBorder(AngularGradient(colors: colors, center: .center, startAngle: .degrees(NutriColor.ringFrom - 90),
                                          endAngle: .degrees(NutriColor.ringFrom - 90 + 360)), lineWidth: thickness)
            .accessibilityHidden(true)
    }
}
