import SwiftUI

/// Home's "Edit widgets" (src/components/shell/EditWidgets.tsx with CardChoices.tsx's one-page form): which cards Home
/// shows, the optional ones included, as a sheet. The same choices as Profile → Cards, for Home only: each switch shows
/// at once and goes to the server in order, one card's change at a time (`Dashboard.setCard`, which puts it back if the
/// server says no).
struct EditWidgetsSheet: View {
    /// Close it, then open Profile ("Every page's cards").
    var onEveryPage: () -> Void
    @Environment(Dashboard.self) private var dashboard
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

    static let intro = "Choose what Home shows. Hiding a widget only changes the page; your data stays."

    /// Home's cards in the two groups (CardChoices with `page`): the ones it shows by default, then the extras. Nutrition's
    /// only with it on. A server older than optional cards has no extras, and knows only its own cards.
    static func groups(nutrition: Bool, optionalCards: Bool) -> (onPage: [DashboardCard], more: [DashboardCard]) {
        let home = Cards.pages(nutrition: nutrition, optionalCards: optionalCards).first { $0.page == .home }?.cards ?? []
        let extra = { (c: DashboardCard) in optionalCards && c.optional }
        return (home.filter { !extra($0) }, home.filter(extra))
    }

    var body: some View {
        let groups = Self.groups(nutrition: dashboard.status?.settings?.nutrition == true, optionalCards: dashboard.optionalCards)
        SheetScaffold(eyebrow: "Home", title: "Edit widgets") {
            Text(Self.intro).font(.app(.footnote)).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true)
            group("On this page", groups.onPage)
            if !groups.more.isEmpty { group("More you can add", groups.more) }
            if let error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.app(.footnote))
                    .foregroundStyle(Palette.critical)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("editWidgetsError")
            }
        } footer: {
            Self.Footer(everyPage: {
                dismiss()
                onEveryPage()
            }, done: { dismiss() })
        }
    }

    /// The sheet's two buttons (.sheet-foot: on the right, wrapping): side by side when they fit, else Done on a line of
    /// its own under Every page's cards, whose words wrap rather than being cut off.
    struct Footer: View {
        let everyPage: () -> Void
        let done: () -> Void

        var body: some View {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { everyPageButton; doneButton }
                VStack(alignment: .trailing, spacing: 10) { everyPageButton; doneButton }
            }
        }

        private var everyPageButton: some View {
            Button("Every page's cards", action: everyPage)
                .buttonStyle(HomeQuietButtonStyle())
                .accessibilityHint("Opens Profile")
                .accessibilityIdentifier("everyPagesCards")
        }

        private var doneButton: some View {
            Button("Done", action: done)
                .buttonStyle(.accentPill)
                .accessibilityIdentifier("editWidgetsDone")
        }
    }

    private func group(_ title: String, _ cards: [DashboardCard]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.app(.caption, weight: .semibold)).foregroundStyle(Palette.ink2).accessibilityAddTraits(.isHeader)
                .padding(.bottom, 2)
            ForEach(cards) { card in
                Toggle(isOn: Binding(get: { dashboard.cardShown(card.id) }, set: { set(card.id, shown: $0) })) {
                    Text(Cards.label(card, optionalCards: dashboard.optionalCards)).font(.app(.subheadline)).foregroundStyle(Palette.ink)
                }
                .toggleStyle(CheckboxToggleStyle())
                .accessibilityIdentifier("widget-\(card.id)")
            }
        }
        .padding(.top, 2)
    }

    private func set(_ id: String, shown: Bool) {
        error = nil
        Task {
            do {
                try await dashboard.setCard(id, shown: shown)
            } catch is CancellationError {
            } catch {
                // The server's own words (EditWidgets.tsx shows the error as it is); the switch has gone back.
                self.error = error.localizedDescription
            }
        }
    }
}

/// The web's checkbox (.card-choices input: 16px, ink when ticked): a box and its words, the whole row to tap. VoiceOver
/// reads it as a switch, on or off.
struct CheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(configuration.isOn ? Palette.ink : Palette.surface)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(configuration.isOn ? Palette.ink : Palette.ink3, lineWidth: 1)
                    if configuration.isOn {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy)).foregroundStyle(Palette.surface)
                    }
                }
                .frame(width: 17, height: 17)
                configuration.label
                Spacer(minLength: 0)
            }
            .frame(minHeight: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}
