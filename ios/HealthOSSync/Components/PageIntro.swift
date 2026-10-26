import SwiftUI

/// A small capitalised line over a heading ("YOUR WORKSPACE", "UNDERSTAND YOUR BLOOD OXYGEN"). VoiceOver reads the
/// words as written, not letter by letter.
struct Eyebrow: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .textCase(.uppercase)
            .font(.app(size: 11, weight: .medium, relativeTo: .caption2))
            .tracking(11 * 0.12)
            .foregroundStyle(Palette.ink3)
    }
}

extension String {
    /// The web's mark for a value there isn't: a dash, never a zero.
    static let emptyValue = "—"
}

/// A value there isn't, as the web shows it ("—" in the muted ink), read by VoiceOver as "No data".
struct EmptyValue: View {
    var body: some View {
        Text(String.emptyValue)
            .foregroundStyle(Palette.ink3)
            .accessibilityLabel("No data")
    }
}

/// A page's intro (PageIntro.tsx): a heading and a line about the page, its actions (pills) beside them or, when
/// there's no room, under them, and an optional slot below for the page's tabs or range picker.
///
///     PageIntro("Vitals", sub: "Your heart, breathing and temperature.") {
///         Button("Manage sources") { … }.buttonStyle(.quietPill)
///     }
struct PageIntro<Actions: View, Slot: View>: View {
    var title: String?
    var sub: String?
    @ViewBuilder var actions: Actions
    @ViewBuilder var slot: Slot

    init(_ title: String? = nil, sub: String? = nil, @ViewBuilder actions: () -> Actions, @ViewBuilder slot: () -> Slot) {
        self.title = title
        self.sub = sub
        self.actions = actions()
        self.slot = slot()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    text
                    Spacer(minLength: 0)
                    HStack(spacing: 10) { actions }
                }
                VStack(alignment: .leading, spacing: 12) {
                    text
                    HStack(spacing: 10) { actions }
                }
            }
            slot
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title)
                    .font(.app(size: 20, weight: .medium, relativeTo: .title3))
                    .tracking(-0.2)
                    .foregroundStyle(Palette.ink)
                    .accessibilityAddTraits(.isHeader)
            }
            if let sub { Text(sub).font(.app(.footnote)).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

extension PageIntro where Slot == EmptyView {
    init(_ title: String? = nil, sub: String? = nil, @ViewBuilder actions: () -> Actions) {
        self.init(title, sub: sub, actions: actions) { EmptyView() }
    }
}

extension PageIntro where Actions == EmptyView, Slot == EmptyView {
    init(_ title: String? = nil, sub: String? = nil) {
        self.init(title, sub: sub, actions: { EmptyView() }) { EmptyView() }
    }
}
