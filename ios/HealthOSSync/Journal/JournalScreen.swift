import SwiftUI

/// The Journal page (src/pages/Journal.tsx), under More: "How are you feeling today?". A private check-in (a few words,
/// and a mood if you like), the earlier ones by day, each changed in place or deleted, and the privacy line with
/// "Delete all check-ins". `new` is the web's ?new=1 (Home's "Write a check-in"), which puts the cursor in the composer
/// once. Check-ins are the person's alone: held in memory for this page only, never kept on disk or logged.
///
/// On the open Duo in landscape it's two screens (decisions.md Q4(b), Q5): the composer, the privacy line and the journal
/// art on the leading side of the fold, the check-ins on the trailing side, each scrolling on its own. Everywhere else it's the web's one column.
struct JournalScreen: View {
    var new = false
    @Environment(Dashboard.self) private var dashboard
    /// The links to the Journal already applied, kept above the page so a page made again (another person, another
    /// server) doesn't apply the last one again either.
    @State private var link = JournalLink()

    var body: some View {
        PhaseGate {
            // One person's, on one server: someone else signing in, or another server, gets a page of their own, with
            // nothing of the last person's in it. Signed out, PhaseGate shows sign-in and the page goes.
            JournalPage(new: new, link: $link).id(identity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.page)
    }

    private var identity: String {
        "\(Config.serverURL()?.absoluteString ?? "")|\(dashboard.account?.id ?? dashboard.status?.user?.id ?? "")"
    }
}

private struct JournalCallsKey: EnvironmentKey {
    static let defaultValue: JournalModel.Calls? = nil
}

extension EnvironmentValues {
    /// The Journal page's calls to the server; nil (the app) means the live ones. Tests put their own in.
    var journalCalls: JournalModel.Calls? {
        get { self[JournalCallsKey.self] }
        set { self[JournalCallsKey.self] = newValue }
    }
}

/// The rows the panes hand between them when a fold swaps one column for two panes (DuoPanes' scroll handoff): the same
/// ids in the single column and in the panes.
enum JournalRow {
    static let intro = "journal.intro"
    static let composer = "journal.composer"
    static let history = "journal.history"
    static let privacy = "journal.privacy"
}

/// The page's state lives here, above the DuoPage (P4): the model with the draft, the check-ins being changed and what
/// was read, the link applied, and the composer's focus. A fold that rebuilds the panes keeps all of it.
private struct JournalPage: View {
    let new: Bool
    @Binding var link: JournalLink
    @Environment(Dashboard.self) private var dashboard
    @Environment(\.journalCalls) private var injected
    @State private var model: JournalModel?
    /// A link asked for the composer; it's focused once the check-ins are here (the web's wantsNew && ready).
    @State private var wantsComposer = false
    @FocusState private var composerFocused: Bool

    var body: some View {
        Group {
            if let model {
                JournalContent(model: model, composerFocused: $composerFocused)
            } else {
                Color.clear
            }
        }
        .onAppear {
            if link.start(new: new, current: dashboard.request(for: .journal)) { wantsComposer = true }
        }
        .task {
            guard model == nil else { return }
            let made = JournalModel(calls: injected ?? .live(dashboard))
            model = made
            await made.load()
        }
        // Home's card tapped again while the page is up: the same link, a request of its own.
        .onChange(of: dashboard.request(for: .journal)?.id) {
            if link.take(dashboard.request(for: .journal)) { wantsComposer = true }
        }
        .onChange(of: wantsComposer && model?.data != nil, initial: true) { _, ready in
            guard ready else { return }
            wantsComposer = false
            Task {
                // After the push settles, or the field isn't there to take the focus.
                try? await Task.sleep(for: .milliseconds(400))
                composerFocused = true
            }
        }
    }
}

private struct JournalContent: View {
    let model: JournalModel
    var composerFocused: FocusState<Bool>.Binding
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        Group {
            if model.missing {
                // An older server's catch-all 404, never a failed read. Left of the fold on the open Duo, as one screen.
                DuoPage(side: .leadingOfFold) { _ in
                    Unavailable(AppPage.journal.title, systemImage: AppPage.journal.symbol, description: JournalWords.notHere)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if let data = model.data {
                ScrollViewReader { proxy in
                    DuoPage { _ in
                        // Both sides scroll (a composer above check-ins that grow): the leading one only when the
                        // composer and what's under it are taller than the pane (the larger text sizes).
                        // With no check-ins to show, the trailing side would be one short card: the privacy line
                        // (Delete all) and the art go under it there, as the single column has them after the
                        // check-ins, so neither side is left mostly empty. Each row is in one pane only (its id).
                        let historyEmpty = model.groups.isEmpty
                        DuoPanes(anchor: .secondary, leadScrolls: true) {
                            JournalRows {
                                lead
                                // The privacy line and Delete all under the composer, and the journal art (the web's,
                                // beside its composer above 640) below them: the leading side used, not left empty.
                                if !historyEmpty { privacyAndArt }
                            }
                        } secondary: {
                            JournalRows {
                                JournalHistory(model: model, data: data, split: true)
                                    .id(JournalRow.history)
                                if historyEmpty { privacyAndArt }
                            }
                        } single: {
                            JournalRows {
                                lead
                                entries(data)
                            }
                        }
                    }
                    .onChange(of: composerFocused.wrappedValue) { _, focused in
                        if focused { withAnimation { proxy.scrollTo(JournalRow.composer) } }
                    }
                }
            } else {
                // Opening, or a failed read: one short column, left of the fold on the open Duo.
                DuoPage(side: .leadingOfFold) { _ in
                    DuoScroll {
                        opening.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 16)
                    }
                }
            }
        }
        // Above the DuoPage, so a fold never rebuilds them (P4): both panes pull to refresh.
        .refreshable { await model.load() }
        .scrollDismissesKeyboard(.interactively)
    }

    /// The page's lead, the leading side of the fold when it splits: the line and the composer.
    @ViewBuilder private var lead: some View {
        PageIntro(JournalWords.title, sub: JournalWords.sub)
            .id(JournalRow.intro)
        JournalComposer(model: model, focused: composerFocused, timeZone: dashboard.status?.settings?.timeZone)
            .id(JournalRow.composer)
    }

    /// The privacy line and Delete all, then the journal art, in whichever pane has the room.
    @ViewBuilder private var privacyAndArt: some View {
        JournalPrivacy(model: model)
            .id(JournalRow.privacy)
        // Kept to what's left of the pane at the default text sizes, so the side stays put.
        JournalArt(width: 200, maxHeight: 160)
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
    }

    /// The check-ins and the privacy line, the single column.
    @ViewBuilder private func entries(_ data: JournalData) -> some View {
        JournalHistory(model: model, data: data)
            .id(JournalRow.history)
        JournalPrivacy(model: model)
            .id(JournalRow.privacy)
    }

    /// Opening the journal, or what went wrong (a 500, offline: never "not on this server").
    @ViewBuilder private var opening: some View {
        if model.failed {
            VStack(alignment: .leading, spacing: 12) {
                ErrorNote(JournalWords.couldNotOpen)
                Button(JournalWords.tryAgain) { Task { await model.load() } }
                    .buttonStyle(.quietPill)
                    .disabled(model.loading)
                    .accessibilityIdentifier("journal.tryAgain")
            }
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(JournalWords.opening).font(.app(size: 12, relativeTo: .caption)).foregroundStyle(Palette.accentText)
            }
            .accessibilityElement(children: .combine)
            .padding(.top, 4)
        }
    }
}

/// One pane's rows (or the single column's): a flat stack, each block a row with its id, as the fold's handoff reads
/// them. The page's content has no side padding of its own (DuoScroll's margins), only its top and bottom.
private struct JournalRows<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) { content }
            .scrollTargetLayout()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 16)
    }
}

/// Earlier check-ins, by day (.journal-history).
private struct JournalHistory: View {
    let model: JournalModel
    let data: JournalData
    /// Beside the composer on the open Duo, not under it: the empty line doesn't say "above".
    var split = false
    @AccessibilityFocusState private var headingFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(JournalWords.history)
                .font(.app(size: 15, weight: .medium, relativeTo: .headline))
                .foregroundStyle(Palette.ink)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($headingFocused)
                .padding(.bottom, 6)
            let groups = model.groups
            if groups.isEmpty {
                Text(model.emptyLine(split: split))
                    .font(.app(size: 13, relativeTo: .footnote))
                    .foregroundStyle(Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 18)
                    .padding(.bottom, 8)
                    .accessibilityIdentifier("journal.empty")
            } else {
                ForEach(Array(groups.enumerated()), id: \.element.date) { index, group in
                    let day = JournalText.day(group.date, today: data.today)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(day)
                            .font(.app(size: 12, weight: .semibold, relativeTo: .caption))
                            .foregroundStyle(Palette.ink2)
                            .accessibilityAddTraits(.isHeader)
                            .padding(.top, 8)
                            .padding(.bottom, 4)
                        ForEach(group.entries) { entry in
                            JournalEntryRow(entry: entry, day: day, model: model) { headingFocused = true }
                        }
                    }
                    .padding(.top, index == 0 ? 0 : 14)
                }
            }
            if model.moreFailed {
                ErrorNote(JournalWords.moreFailed).padding(.top, 8)
            }
            if model.showsMore {
                Button(model.busyMore ? JournalWords.loading : JournalWords.showEarlier) {
                    Task { await model.showEarlier() }
                }
                .buttonStyle(.quietPill)
                .padding(.top, 12)
                // Not disabled while they load, as the web keeps its button's focus (aria-disabled).
                .accessibilityAddTraits(model.busyMore ? .updatesFrequently : [])
                .accessibilityIdentifier("journal.more")
            }
        }
        .card()
    }
}

/// The privacy line, and clearing the journal (.journal-privacy).
private struct JournalPrivacy: View {
    let model: JournalModel
    @State private var asking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(JournalWords.privacy).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "checkmark.shield").accessibilityHidden(true)
            }
            .labelStyle(JournalPrivacyLabelStyle())
            .font(.app(size: 12, relativeTo: .caption))
            .foregroundStyle(Palette.ink3)
            if model.hasAny {
                Button(JournalWords.deleteAll) { asking = true }
                    .buttonStyle(JournalQuietButtonStyle(danger: true, size: 12, padding: 4))
                    .accessibilityIdentifier("journal.deleteAll")
                    // On its button, its anchor at regular width (P10).
                    .confirmationDialog(JournalWords.deleteAllAsk, isPresented: $asking, titleVisibility: .visible) {
                        Button(JournalWords.deleteAll, role: .destructive) { Task { await model.deleteAll() } }
                        Button(JournalWords.cancel, role: .cancel) {}
                    }
            }
            if let error = model.deleteAllError { ErrorNote(error) }
        }
        .padding(.horizontal, 4)
        .padding(.top, -4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The shield beside the privacy line, on its first line of words.
private struct JournalPrivacyLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            configuration.icon
            configuration.title
        }
    }
}

/// The web's .btn-quiet: just its words, in the muted ink (in the critical colour for .btn-danger), a little darker
/// while pressed. Its tap area is the row's height at least, whatever the words' size.
struct JournalQuietButtonStyle: ButtonStyle {
    var danger = false
    var size: CGFloat = 12
    var padding: CGFloat = 10
    var height: CGFloat = 28
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.app(size: size, weight: .medium, relativeTo: .caption))
            .foregroundStyle(danger ? Palette.critical : configuration.isPressed ? Palette.ink : Palette.ink3)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, padding)
            .frame(minHeight: height)
            // Taller to the touch than it looks, never wider: its frame keeps clear of the fold beside it.
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .padding(.vertical, -8)
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.5)
    }
}
