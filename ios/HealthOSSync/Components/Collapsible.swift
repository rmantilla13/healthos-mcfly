import SwiftUI

/// A card that opens in place (Profile's .profile-collapse): an icon, a sage title with a muted line under it, and a
/// + or − on the right. Its body is built only while it's open, as on the web.
///
///     Collapsible("Your age group", meta: "Off", systemImage: "person.3") {
///         PeersSection()
///     }
struct Collapsible<Content: View>: View {
    let title: String
    var meta: String?
    var systemImage: String?
    @ViewBuilder var content: Content
    @State private var open: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ title: String, meta: String? = nil, systemImage: String? = nil, startsOpen: Bool = false, @ViewBuilder content: () -> Content) {
        self.title = title
        self.meta = meta
        self.systemImage = systemImage
        self.content = content()
        _open = State(initialValue: startsOpen)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { open.toggle() }
            } label: {
                HStack(spacing: 12) {
                    if let systemImage { RowIcon(systemName: systemImage, width: 22) }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(.app(.subheadline, weight: .medium)).foregroundStyle(Palette.accentText)
                        if let meta, !meta.isEmpty { Text(meta).font(.app(.caption)).foregroundStyle(Palette.ink3) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: open ? "minus" : "plus")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Palette.ink2)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
                .frame(minHeight: 64)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(open ? "Open" : "Closed")
            .accessibilityHint(open ? "Closes this section" : "Opens this section")
            .accessibilityAddTraits(.isHeader)

            if open {
                VStack(alignment: .leading, spacing: 14) { content }
                    .font(.app(.footnote))
                    .padding(.horizontal, 18)
                    .padding(.top, 2)
                    .padding(.bottom, 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { CardSurface(shape: RoundedRectangle(cornerRadius: Radius.card, style: .continuous)) }
    }
}
