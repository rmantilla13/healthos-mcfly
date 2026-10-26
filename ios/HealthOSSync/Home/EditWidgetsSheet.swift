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
            Button("Every page's cards") {
                dismiss()
                onEveryPage()
            }
            .buttonStyle(.quietPill)
            .accessibilityHint("Opens Profile")
            .accessibilityIdentifier("everyPagesCards")
            Button("Done") { dismiss() }
                .buttonStyle(.accentPill)
                .accessibilityIdentifier("editWidgetsDone")
        }
    }

    private func group(_ title: String, _ cards: [DashboardCard]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.app(.caption, weight: .semibold)).foregroundStyle(Palette.ink2).accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                ForEach(cards) { card in
                    Toggle(isOn: Binding(get: { dashboard.cardShown(card.id) }, set: { set(card.id, shown: $0) })) {
                        Text(Cards.label(card, optionalCards: dashboard.optionalCards)).font(.app(.subheadline)).foregroundStyle(Palette.ink)
                    }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("widget-\(card.id)")
                    if card.id != cards.last?.id { Divider().overlay(Palette.border) }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.field, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.field, style: .continuous).strokeBorder(Palette.border))
        }
        .padding(.top, 4)
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
