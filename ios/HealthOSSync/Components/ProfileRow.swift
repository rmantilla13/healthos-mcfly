import SwiftUI

/// A card of rows on Profile (.profile-card): a title over its rows.
struct ProfileCard<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                Text(title)
                    .font(.app(size: 17, weight: .medium, relativeTo: .headline))
                    .tracking(-0.17)
                    .foregroundStyle(Palette.ink)
                    .padding(.bottom, 4)
                    .accessibilityAddTraits(.isHeader)
            }
            content
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { CardSurface(shape: RoundedRectangle(cornerRadius: Radius.card, style: .continuous)) }
    }
}

/// One of Profile's rows (.profile-row): a title and a muted line or two, its action under them as on the web's phone
/// layout, and a hairline under the row unless it's the card's last.
///
///     ProfileRow("Units & daily goal", lines: ["Metric · 10,000 steps"], divider: false) {
///         Button("Change") { … }.buttonStyle(.quietPill(size: .compact))
///     }
struct ProfileRow<Detail: View, Action: View>: View {
    let title: String
    var divider = true
    @ViewBuilder var detail: Detail
    @ViewBuilder var action: Action

    init(_ title: String, divider: Bool = true, @ViewBuilder detail: () -> Detail, @ViewBuilder action: () -> Action) {
        self.title = title
        self.divider = divider
        self.detail = detail()
        self.action = action()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.app(.subheadline, weight: .medium)).foregroundStyle(Palette.ink)
                VStack(alignment: .leading, spacing: 2) { detail }
                    .font(.app(.footnote))
                    .lineSpacing(3)
                    .foregroundStyle(Palette.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            HStack(spacing: 6) { action }
        }
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            if divider { Rectangle().fill(Palette.border).frame(height: 1) }
        }
    }
}

extension ProfileRow where Detail == ProfileRowLines {
    /// A row whose detail is plain muted lines.
    init(_ title: String, lines: [String], divider: Bool = true, @ViewBuilder action: () -> Action) {
        self.init(title, divider: divider, detail: { ProfileRowLines(lines: lines) }, action: action)
    }
}

struct ProfileRowLines: View {
    let lines: [String]
    var body: some View {
        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in Text(line) }
    }
}
