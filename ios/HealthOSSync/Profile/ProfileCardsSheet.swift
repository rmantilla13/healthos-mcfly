import SwiftUI

/// Profile → Cards (G24, the web's CardsSheet and CardChoices): a box per card, grouped as the web's pages (Home,
/// "Sleep · Overview", "Body · Overview", and "Nutrition · Overview" while Nutrition is on). Optional cards say so;
/// they're off until ticked. Under each, where this app shows it, or that it changes the web dashboard only. Each box
/// moves at once and its change goes to the server on its own, after any still on their way; one the server refuses
/// goes back with the reason. Show all, while a default card is hidden, brings every default card back and leaves the
/// optional ones as they are. Only the layout changes: nothing is deleted.
struct ProfileCardsSheet: View {
    let close: () -> Void
    @Environment(Dashboard.self) private var dashboard
    @State private var error: String?

    var body: some View {
        let nutrition = dashboard.status?.settings?.nutrition == true
        let optional = dashboard.optionalCards
        SheetScaffold(eyebrow: "Profile", title: "Cards", onClose: close) {
            VStack(alignment: .leading, spacing: 20) {
                ProfileFine("\(ProfileWords.cardPages(nutrition: nutrition)) \(ProfileWords.cardsNote)")
                // A server older than optional cards gets only the cards it knows: it refuses the newer ones.
                ForEach(Cards.pages(nutrition: nutrition, optionalCards: optional)) { group in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.page.label)
                            .font(.app(size: 12, weight: .semibold, relativeTo: .caption))
                            .foregroundStyle(Palette.ink2)
                            .padding(.bottom, 4)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(group.cards) { card in
                            Toggle(isOn: Binding(get: { dashboard.cardShown(card.id) }, set: { set(card.id, shown: $0) })) {
                                ProfileCardLabel(name: Cards.label(card, optionalCards: optional), optional: optional && card.optional,
                                                 place: card.place?.label)
                            }
                            .toggleStyle(ProfileCheckboxStyle())
                            .accessibilityIdentifier("card-\(card.id)")
                        }
                    }
                }
                if let error { ProfileNote(text: error, good: false) }
            }
        } footer: {
            // As on the web: while any default card is hidden (shared/cards.ts hiddenDefaults).
            if !Cards.hiddenDefaults(dashboard.hiddenCards, optionalCards: optional).isEmpty {
                Button("Show all") { showAll() }
                    .buttonStyle(ProfileQuietStyle(size: .regular))
                    .accessibilityHint("Shows every default card again; optional cards stay as they are")
                    .accessibilityIdentifier("cardsShowAll")
            }
            Button("Done", action: close).buttonStyle(.accentPill).accessibilityIdentifier("cardsDone")
        }
    }

    private func set(_ id: String, shown: Bool) {
        error = nil
        Task {
            do {
                try await dashboard.setCard(id, shown: shown)
            } catch is CancellationError {
            } catch {
                guard dashboard.phase == .ready else { return }
                let name = Cards.card(id).map { Cards.label($0, optionalCards: dashboard.optionalCards) } ?? "that card"
                self.error = "Couldn't \(shown ? "show" : "hide") \(name). \(error.localizedDescription)"
            }
        }
    }

    private func showAll() {
        error = nil
        Task {
            do {
                try await dashboard.showAllCards()
            } catch is CancellationError {
            } catch {
                guard dashboard.phase == .ready else { return }
                self.error = "Couldn't show every card. \(error.localizedDescription)"
            }
        }
    }
}

/// A card's name, "Optional" on the right for one that's off until ticked (the web's small muted word), and under the
/// name where this app shows it.
private struct ProfileCardLabel: View {
    let name: String
    let optional: Bool
    let place: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(name).font(.app(size: 13, relativeTo: .footnote)).foregroundStyle(Palette.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if optional {
                    Text("Optional").font(.app(size: 11, relativeTo: .caption2)).foregroundStyle(Palette.ink3)
                }
            }
            Text(place.map { "On this iPhone: \($0)" } ?? "Only on the web dashboard")
                .font(.app(size: 11, relativeTo: .caption2))
                .foregroundStyle(Palette.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
