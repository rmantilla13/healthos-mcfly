import SwiftUI

/// A new check-in (.journal-compose): "Today, Friday 9:41 PM", the five optional moods, the words, and Save check-in,
/// on the blush wash. Where the web is wider than 640 (the medium band: the inner display upright) the journal's orb sits
/// on the right and the card is roomier; in the compact band (every iPhone, the outer display, a pane of the open Duo,
/// Split View) it's the web's phone composer, without the orb. The draft is the model's, in memory only.
struct JournalComposer: View {
    let model: JournalModel
    var focused: FocusState<Bool>.Binding
    /// The person's time zone (settings.timeZone), for the line over the moods.
    let timeZone: String?
    @Environment(\.duoBand) private var band
    /// The card's width inside its padding, for the orb's share of it.
    @State private var inner: CGFloat = 600

    /// The web above 640 px.
    private var roomy: Bool { band >= .medium }

    /// The orb's room beside the words (journal.css: clamp(150px, 26%, 200px) of the card's width inside its padding).
    static func artWidth(_ inner: CGFloat) -> CGFloat { min(200, max(150, inner * 0.26)) }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        let art = Self.artWidth(inner)
        HStack(spacing: 24) {
            form
                // .journal-compose-body's 760 (design §2.8): every Duo width undercuts it.
                .frame(maxWidth: 760, alignment: .leading)
            if roomy { Color.clear.frame(width: art) }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { inner = $0 }
        .padding(.horizontal, roomy ? 26 : 16)
        .padding(.vertical, roomy ? 22 : 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            // The orb in that room, as tall as the words and a little past them (margin: -12px -10px -12px auto), under
            // the words and trimmed by the card, as the web's .card hides what runs over.
            if roomy {
                JournalArt(width: art)
                    .padding(.vertical, 10)
                    .padding(.trailing, 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .clipShape(shape)
            }
        }
        .background { CardSurface(tint: .blush, shape: shape) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(JournalWords.newCheckIn)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Kept current, as the web's every 20 seconds.
            TimelineView(.periodic(from: .now, by: 20)) { context in
                Eyebrow("Today, \(JournalText.now(context.date, timeZone: timeZone))")
            }
            JournalMoodChips(mood: Binding(get: { model.mood }, set: { model.setMood($0) }), label: JournalWords.moods, id: "journal.mood")
            VStack(alignment: .trailing, spacing: 6) {
                JournalTextBox(text: Binding(get: { model.text }, set: { model.setText($0) }), placeholder: JournalWords.placeholder,
                               label: JournalWords.box, id: "journal.box", focused: focused)
                if let left = JournalText.left(model.text) {
                    Text(left)
                        .font(.app(size: 12, relativeTo: .caption))
                        .foregroundStyle(Palette.ink3)
                        .onAppear { AccessibilityNotification.Announcement(left).post() }
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) { saveButton; savedLine }
                VStack(alignment: .leading, spacing: 10) { saveButton; savedLine }
            }
            if let error = model.saveError { ErrorNote(error) }
        }
    }

    private var saveButton: some View {
        Button(model.saving ? JournalWords.saving : JournalWords.save) {
            Task {
                if await model.save() { focused.wrappedValue = true }
            }
        }
        .buttonStyle(.accentPill)
        .disabled(!model.canSave)
        // ⌘↩ saves, as on the web; Return alone is a new line.
        .keyboardShortcut(.return, modifiers: .command)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("journal.save")
    }

    @ViewBuilder private var savedLine: some View {
        if model.saved {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)).accessibilityHidden(true)
                Text(JournalWords.saved).fixedSize(horizontal: false, vertical: true)
            }
            .font(.app(size: 13, relativeTo: .footnote))
            .foregroundStyle(Palette.accentText)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("journal.saved")
            .onAppear { AccessibilityNotification.Announcement(JournalWords.saved).post() }
        }
    }
}

/// The journal's art, its orb (JournalOrb, as .journal-orb-area): beside the composer where the web is wider than 640,
/// and under the empty line on the open Duo's trailing side. The orb fits whichever of its room's width and height is
/// less (88% of the width or 78% of the height); its glow runs past the room. Decoration only.
struct JournalArt: View {
    var width: CGFloat = 200
    /// nil: as tall as it's given.
    var height: CGFloat? = nil

    var body: some View {
        GeometryReader { geo in
            JournalOrb(diameter: min(geo.size.width * 0.88, geo.size.height * 0.78))
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .frame(width: width, height: height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Five optional moods, one at a time (.journal-moods): choosing the chosen one again clears it. They wrap onto another
/// line when the text is large.
struct JournalMoodChips: View {
    @Binding var mood: Mood?
    let label: String
    /// The chips' identifiers: `<id>.<Mood>` ("journal.mood.Good").
    var id: String
    @Environment(\.duoBand) private var band

    var body: some View {
        // All five fit on one line of a phone: tighter there (the web at 640 and under).
        let roomy = band >= .medium
        JournalFlow(spacing: roomy ? 8 : 6, rowSpacing: 6) {
            ForEach(Mood.allCases) { choice in
                JournalMoodChip(title: choice.label, chosen: mood == choice, padding: roomy ? 14 : 10) { mood = mood == choice ? nil : choice }
                    .accessibilityIdentifier("\(id).\(choice.label)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

/// One mood (.journal-mood): a white pill with a soft shadow; chosen, a sage edge over the pale green and its word in
/// the accent, not colour alone (VoiceOver hears "Selected").
private struct JournalMoodChip: View {
    let title: String
    let chosen: Bool
    var padding: CGFloat = 10
    let action: () -> Void
    @ScaledMetric(relativeTo: .footnote) private var height: CGFloat = 32

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.app(size: 13, weight: .medium, relativeTo: .footnote))
                .foregroundStyle(chosen ? Palette.accentText : Palette.ink2)
                .lineLimit(1)
                .padding(.horizontal, padding)
                .frame(minHeight: height)
                .background(chosen ? Palette.accentSoft : Palette.surface, in: Capsule())
                .overlay { if chosen { Capsule().strokeBorder(Palette.choiceBorder, lineWidth: 1.5) } }
                .background { if !chosen { Color.clear.tokenShadow(.pill, in: Capsule()) } }
                // The pill is the web's 32 points; its tap area reaches the system's 44.
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, -6)
        .sensoryFeedback(.selection, trigger: chosen)
        .accessibilityAddTraits(chosen ? [.isSelected] : [])
    }
}

/// The box a check-in is written in (.journal-box): the surface with a hairline edge, its placeholder in the faint
/// ink, at least four lines tall, scrolling inside past a dozen or so.
struct JournalTextBox: View {
    @Binding var text: String
    var placeholder: String?
    let label: String
    var id: String
    var focused: FocusState<Bool>.Binding
    @ScaledMetric(relativeTo: .subheadline) private var minHeight: CGFloat = 112

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.field, style: .continuous)
        TextEditor(text: $text)
            .font(.app(size: 14, relativeTo: .subheadline))
            .foregroundStyle(Palette.ink)
            .lineSpacing(3)
            .scrollContentBackground(.hidden)
            .focused(focused)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .frame(minHeight: minHeight, maxHeight: max(minHeight, 300))
            .background(alignment: .topLeading) {
                if text.isEmpty, let placeholder {
                    Text(placeholder)
                        .font(.app(size: 14, relativeTo: .subheadline))
                        .foregroundStyle(Palette.ink3)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 14)
                        .accessibilityHidden(true)
                }
            }
            .background(Palette.surface, in: shape)
            .overlay(shape.strokeBorder(Palette.border))
            .accessibilityLabel(label)
            .accessibilityIdentifier(id)
    }
}

/// Views in a row that wrap onto the next line when they don't fit (flex-wrap), each its own size.
struct JournalFlow: Layout {
    var spacing: CGFloat = 8
    var rowSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + rowSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for (index, size) in row.items {
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + rowSpacing
        }
    }

    private struct Row {
        var items: [(Int, CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for (index, subview) in subviews.enumerated() {
            var size = subview.sizeThatFits(.unspecified)
            if size.width > width {
                // Too wide for a line of its own: as wide as the line, as tall as it then needs.
                size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
                size.width = min(size.width, width)
            }
            let needed = row.items.isEmpty ? size.width : row.width + spacing + size.width
            if needed > width, !row.items.isEmpty {
                rows.append(row)
                row = Row()
            }
            row.width = row.items.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.items.append((index, size))
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}
