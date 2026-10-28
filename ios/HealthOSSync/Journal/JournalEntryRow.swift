import SwiftUI

/// One check-in (the web's Entry, .journal-entry): its time, its mood and its words, changed in place or deleted after
/// asking. What's being typed into a change lives in the model (`JournalModel.edits`), not here, so a fold that rebuilds
/// the entries keeps it; only the delete question is the row's own (it's attached to its button, P10, and may close on
/// a fold, with nothing lost).
struct JournalEntryRow: View {
    let entry: JournalEntry
    /// The day it's under: Today, Yesterday, "Mon, Oct 19".
    let day: String
    let model: JournalModel
    /// After a delete: VoiceOver goes to the heading, as the web's focus does.
    let onDeleted: () -> Void
    @State private var askingDelete = false
    @FocusState private var boxFocused: Bool
    @AccessibilityFocusState private var editFocused: Bool
    @Environment(\.dynamicTypeSize) private var typeSize
    /// .journal-text's 72ch at 14 pt: a readable line however wide the card.
    @ScaledMetric(relativeTo: .subheadline) private var measure: CGFloat = 585

    private var when: String { JournalText.when(day: day, clock: JournalText.clock(entry.time)) }

    var body: some View {
        let edit = model.edits[entry.id]
        let shown = model.shown(entry)
        VStack(alignment: .leading, spacing: 6) {
            head(mood: edit == nil ? shown.mood : nil, editing: edit != nil)
            if let edit {
                editor(edit)
            } else {
                Text(shown.text)
                    .font(.app(size: 14, relativeTo: .subheadline))
                    .lineSpacing(5)
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: measure, alignment: .leading)
                    .accessibilityIdentifier("journal.entry.\(entry.id)")
            }
            if let error = model.rowErrors[entry.id] { ErrorNote(error) }
        }
        .padding(.top, 12)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(Palette.border).frame(height: 1).accessibilityHidden(true) }
    }

    /// The time, the mood and, while it isn't being changed, Edit and Delete on the right. At the accessibility sizes
    /// they go under the time, so nothing is cut off.
    private func head(mood: Mood?, editing: Bool) -> some View {
        let time = Text(JournalText.clock(entry.time))
            .font(.app(size: 12, relativeTo: .caption))
            .foregroundStyle(Palette.ink3)
        let badge = mood.map { Badge($0.label, tone: JournalText.tone($0)) }
        return Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 6) {
                    JournalFlow(spacing: 10, rowSpacing: 6) {
                        time
                        badge
                    }
                    if !editing { JournalFlow(spacing: 2, rowSpacing: 4) { actions } }
                }
            } else {
                HStack(spacing: 10) {
                    time
                    badge
                    Spacer(minLength: 0)
                    if !editing { HStack(spacing: 2) { actions } }
                }
            }
        }
        .frame(minHeight: 28)
    }

    @ViewBuilder private var actions: some View {
        Button(JournalWords.edit) { model.startEdit(entry) }
            .buttonStyle(JournalQuietButtonStyle())
            .accessibilityLabel(JournalWords.editLabel(when))
            .accessibilityIdentifier("journal.entry.\(entry.id).edit")
            .accessibilityFocused($editFocused)
            .onAppear {
                if model.refocusEdit == entry.id {
                    model.refocusEdit = nil
                    editFocused = true
                }
            }
        Button(JournalWords.delete) { askingDelete = true }
            .buttonStyle(JournalQuietButtonStyle(danger: true))
            .accessibilityLabel(JournalWords.deleteLabel(when))
            .accessibilityIdentifier("journal.entry.\(entry.id).delete")
            .confirmationDialog(JournalWords.deleteAsk(when), isPresented: $askingDelete, titleVisibility: .visible) {
                Button(JournalWords.delete, role: .destructive) {
                    Task { if await model.delete(entry) { onDeleted() } }
                }
                Button(JournalWords.cancel, role: .cancel) {}
            }
    }

    /// Changing it in place (.journal-edit): its mood, its words, Save changes and Cancel.
    private func editor(_ edit: JournalModel.Edit) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            JournalMoodChips(mood: Binding(get: { model.edits[entry.id]?.mood }, set: { model.setEditMood(entry.id, $0) }),
                             label: JournalWords.moodFor(when), id: "journal.entry.\(entry.id).mood")
            JournalTextBox(text: Binding(get: { model.edits[entry.id]?.text ?? "" }, set: { model.setEditText(entry.id, $0) }),
                           label: JournalWords.boxFor(when), id: "journal.entry.\(entry.id).box", focused: $boxFocused)
                .onAppear {
                    guard model.focusEdit == entry.id else { return }
                    model.focusEdit = nil
                    Task { boxFocused = true }
                }
            JournalFlow(spacing: 8, rowSpacing: 8) {
                Button(edit.busy ? JournalWords.saving : JournalWords.saveChanges) {
                    Task { await model.saveEdit(entry) }
                }
                .buttonStyle(.accentPill)
                .disabled(edit.busy || JournalModel.trimmed(edit.text).isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityIdentifier("journal.entry.\(entry.id).saveChanges")
                Button(JournalWords.cancel) { model.cancelEdit(entry.id) }
                    .buttonStyle(JournalQuietButtonStyle(size: 13, padding: 12, height: 36))
                    .disabled(edit.busy)
                    // Escape closes it, as on the web.
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("journal.entry.\(entry.id).cancel")
            }
            if let error = edit.error { ErrorNote(error) }
        }
        .frame(maxWidth: 760, alignment: .leading)
    }
}
