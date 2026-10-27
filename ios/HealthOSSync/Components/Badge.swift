import SwiftUI

/// A short state in a small pill (.badge on the web): "Signed in", "0 results", "Ready to connect".
struct Badge: View {
    enum Tone {
        /// Good or done.
        case sage
        /// Waiting or worth a look.
        case peach
        /// Plain information.
        case muted
        /// Something's wrong.
        case bad

        var background: Color {
            switch self {
            case .sage: ColorToken.badgeSageBg.color
            case .peach: ColorToken.badgePeachBg.color
            case .muted: ColorToken.badgeMutedBg.color
            case .bad: ColorToken.badgeBadBg.color
            }
        }

        var ink: Color {
            switch self {
            case .sage: ColorToken.badgeSageInk.color
            case .peach: ColorToken.badgePeachInk.color
            case .muted: ColorToken.badgeMutedInk.color
            case .bad: ColorToken.badgeBadInk.color
            }
        }
    }

    let text: String
    var tone: Tone = .muted
    var systemImage: String?

    init(_ text: String, tone: Tone = .muted, systemImage: String? = nil) {
        self.text = text
        self.tone = tone
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage).imageScale(.small).accessibilityHidden(true) }
            Text(text)
        }
        .font(.app(size: 11, weight: .medium, relativeTo: .caption2))
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .foregroundStyle(tone.ink)
        .background(tone.background, in: Capsule())
    }
}
