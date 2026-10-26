import SwiftUI

/// Home's "Your health journal" (src/components/home/JournalPrompt.tsx): an invitation to write today's check-in
/// (journal?new=1 opens a new one), or, once there is one today (GET /api/journal?days=1), its mood and first line, and
/// an invitation to add another. Check-ins are private to the person and this is their own Home: what's read is held in
/// memory only, for this card, never kept on disk or logged. A server without the journal (an older one) hides the card.
struct JournalPromptCard: View {
    @Environment(Dashboard.self) private var dashboard
    @Environment(\.colorScheme) private var scheme
    /// Today's latest check-in once read; nil while there's none (or it's still being read).
    @State private var latest: JournalEntry?
    /// The server answered that it has no journal.
    @State private var missing = false
    /// The card's width inside its padding, for the words' two thirds.
    @State private var inner: CGFloat = 303

    /// What the card says: the latest of today's check-ins, its mood's word and first line.
    struct Model: Equatable {
        let mood: String?
        /// The first line with words in it, or "A check-in at 08:10".
        let line: String?
        let button: String

        /// From GET /api/journal?days=1: the first of today's is the latest (newest first).
        init(_ data: JournalData?) { self.init(latest: data?.todays.first) }

        init(latest: JournalEntry?) {
            mood = latest?.mood?.label
            line = latest.map { $0.firstLine ?? "A check-in at \($0.time)" }
            button = latest == nil ? "Write a check-in" : "Add another"
        }
    }

    var body: some View {
        Group {
            if !missing { card(Model(latest: latest)) }
        }
        .task(id: dashboard.generation) {
            do {
                if let data = try await dashboard.journal(days: 1) {
                    latest = data.todays.first
                    missing = false
                } else {
                    latest = nil
                    missing = true
                }
            } catch {
                // Offline or a server error: the invitation stays, as it shows while reading.
            }
        }
    }

    private func card(_ m: Model) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        return Button { dashboard.open(AppRoute(.journal, query: ["new": "1"])) } label: {
            CardMinHeight(min: 236 - 38) {
                VStack(alignment: .leading, spacing: 0) {
                    words(m)
                        // The words keep to the left two thirds; the art takes the rest (home.css, 560px and below).
                        .frame(width: inner * 0.66, alignment: .leading)
                    Spacer(minLength: 16)
                    HStack(spacing: 7) {
                        Text(m.button)
                        Image(systemName: "arrow.up.right").font(.system(size: 12, weight: .medium))
                    }
                    .font(.app(.footnote, weight: .medium))
                    .foregroundStyle(Palette.ink2)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 34)
                    .background(Palette.surface, in: Capsule())
                    .tokenShadow(.pill, in: Capsule())
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { inner = $0 }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ZStack {
                    GradientFill(CardTint.blush.gradient)
                    art
                }
                .clipShape(shape)
                .overlay(shape.strokeBorder(Palette.cardEdge))
                .tokenShadow(.card, in: shape)
            }
            .contentShape(shape)
        }
        .buttonStyle(CardPressStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(["Your health journal", "How are you feeling today?", m.mood, m.line ?? "A thought, a feeling, a little context."].compactMap { $0 }.joined(separator: ". "))
        .accessibilityHint(m.button == "Write a check-in" ? "Writes a check-in" : "Adds another check-in")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("card-home.journal")
    }

    private func words(_ m: Model) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Your health journal").font(.app(.footnote, weight: .medium)).foregroundStyle(Palette.ink)
            Text("How are you feeling today?")
                .font(.app(size: 22, weight: .medium, relativeTo: .title2))
                .tracking(-0.22)
                .lineSpacing(2)
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 16)
            if let line = m.line {
                FlowRow(spacing: 8, lineSpacing: 6) {
                    if let mood = m.mood { Badge(mood, tone: .sage) }
                    Text(line).font(.app(.footnote)).foregroundStyle(Palette.ink2).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 12)
            } else {
                Text("A thought, a feeling, a little context.").font(.app(.caption)).foregroundStyle(Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }
        }
    }

    /// The journal art bleeding off the right edge (home.css .home-journal-art): 112% of the card's height, at most 46% of
    /// its width, 2% past its right edge, fading into the card on the words' side and at the bottom, and a little dimmer
    /// on a dark card.
    private var art: some View {
        GeometryReader { geo in
            let height = geo.size.height * 1.12
            let width = min(geo.size.width * 0.46, height * 220 / 250)
            Image("JournalGut")
                .resizable()
                .scaledToFit()
                .frame(width: width, height: height)
                .mask {
                    LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.28)], startPoint: .leading, endPoint: .trailing)
                        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.22)], startPoint: .bottom, endPoint: .top))
                }
                .colorMultiply(scheme == .dark ? Color(white: 0.8) : .white)
                .opacity(scheme == .dark ? 0.75 : 1)
                .position(x: geo.size.width * 1.02 - width / 2, y: geo.size.height / 2)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
