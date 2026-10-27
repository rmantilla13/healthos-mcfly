import SwiftUI

// Nutrition's Today (src/pages/NutritionChat.tsx), the page's first view: a conversation with McFly about what you
// ate, then the day it adds up to (Your daily balance) and the day's entries (Your food journal), for any day of the
// last year. The day is read with POST /api/nutrition/log/day, so no date is ever in an address. The rules and words
// are in NutritionChatModel.swift.

/// Today: the intro (with the day viewed), the conversation, the balance and the journal. On the open iPhone Duo, where
/// the page splits on the fold, the intro runs above two panes, as the web's wide Today: the conversation on the leading
/// side (its thread scrolling, the composer at its foot) and the day on the trailing side (design §7, decisions.md Q5).
/// Everything a fold must keep lives here, above those panes (P4): the day and its read, the + menu and the sheets it
/// opens, the meal photo's picker and camera, the voice note, the problem line and the journal's open editors. The
/// composer's keyboard is the conversation's (`thread.composerFocused`), so the composer a swap brings takes it back.
struct NutritionToday<Views: View>: View {
    let mode: NutritionMode
    let thread: NutritionThread
    /// The day viewed; nil is today, whichever day that is when the answer comes back.
    @Binding var date: String?
    /// Something asked for the composer (Home's orb: compose=1): the conversation focuses it once, then sets this back.
    @Binding var compose: Bool
    /// The server has no POST /nutrition/log/day (it's older): the page shows the Log instead.
    let routeMissing: () -> Void
    @ViewBuilder let views: () -> Views
    @Environment(Dashboard.self) private var dashboard
    @Environment(\.nutritionReads) private var reads
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var day: FoodLogDay?
    /// When the day shown was asked for: an estimate that arrived after it isn't in it yet.
    @State private var askedAt: Date?
    @State private var error: String?
    @State private var loading = false
    /// The status was read again once for a 409 (Nutrition turned off elsewhere), so it never loops.
    @State private var reloadedForOff = false
    /// + 's menu, what was chosen in it (opened once it has gone) and the sheet that opens.
    @State private var menu = false
    @State private var chosen: NutritionAddChoice?
    @State private var sheet: NutritionAddSheet?
    /// "Add a photo"'s question (on the composer's +), and what its answer opens (here).
    @State private var choosingPhoto = false
    @State private var photoPick: MealPhotoPick?
    /// The line under the composer: a photo that couldn't be opened, or why voice notes are off.
    @State private var problem: String?
    @State private var voice: VoiceNote?
    /// The journal's entries being edited, with what's typed in them: here, so a fold that swaps the panes keeps them.
    @State private var edits = FoodEntryEdits()
    /// Which of the journal's fields has the keyboard, so an editor a swap brings takes it back.
    @State private var focus = FoodFocus()

    var body: some View {
        let today = day?.today ?? Day.today()
        let viewing = date ?? today
        ScrollViewReader { proxy in
            DuoPage { _ in
                NutritionTodayLayout(day: day, mode: mode, units: dashboard.units, viewing: viewing, today: today, date: $date,
                                     failed: day == nil ? error : nil, loading: loading, voice: voice, views: views) { pinnedHeight in
                    NutritionChatCard(thread: thread, day: day, askedAt: askedAt, mode: mode, viewing: viewing, today: today,
                                      compose: $compose, pinned: pinnedHeight != nil, paneHeight: pinnedHeight ?? 0, voice: voice, problem: $problem,
                                      choosingPhoto: $choosingPhoto, photoPick: $photoPick, openMenu: { menu = true }) {
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) { proxy.scrollTo(NutritionChatCard.bottomID, anchor: .bottom) }
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .environment(\.foodEntryEdits, edits)
        .environment(\.foodFocus, focus)
        // Another day's entries are other rows: the editors open on this one close, as they always have.
        .onChange(of: viewing) { edits.open = [:] }
        .background(Palette.page)
        .refreshable { await dashboard.load() }
        // Read again when anything changes (a save, an edit, the background version check) and when the person's
        // numbers setting does.
        .task(id: "\(dashboard.generation)|\(date ?? "today")|\(mode.rawValue)") { await read() }
        .onAppear(perform: makeVoice)
        // Leaving Today (another view, another tab) ends a note, and the keyboard isn't raised again on the way back.
        .onDisappear {
            voice?.cancel()
            thread.composerFocused = false
        }
        // Only the background ends a note: the microphone's permission question (and Control Center) make the app
        // inactive for a moment, and a note started from VoiceOver goes on through that.
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { voice?.cancel() }
        }
        // The problem line is a status on the web (role="status"): VoiceOver hears it as it appears.
        .onChange(of: problem ?? voice?.error) { _, shown in
            if let shown { AccessibilityNotification.Announcement(shown).post() }
        }
        // Health's write question for drafts just saved in the conversation, with no sheet up to cover it.
        .onChange(of: dashboard.foodHealthAskPending) { _, pending in
            if pending, sheet == nil, !menu { askHealth() }
        }
        .sheet(isPresented: $menu, onDismiss: runChoice) {
            NutritionAddMenu(canEstimate: NutritionChat.canEstimate(dayRead: day != nil, estimate: dashboard.availability.estimate), mode: mode) { choice in
                chosen = choice
                menu = false
            }
        }
        .sheet(item: $sheet, onDismiss: askHealth) { s in addSheet(s, viewing: viewing, today: today) }
        .mealPhotoPicker(pick: $photoPick) { photo in
            problem = nil
            thread.photo = photo
            thread.composerFocused = true
        } failed: {
            problem = "That photo couldn't be opened here. Try a JPEG or PNG, or describe it instead."
        }
    }

    private func makeVoice() {
        if voice == nil {
            voice = VoiceNote(recorder: MicrophoneRecorder(), transcribe: { [dashboard] in try await dashboard.transcribe($0) })
        }
        voice?.onText = { [thread] words in
            let typed = thread.draft
            thread.draft = typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? words : "\(typed.trimmingTrailingSpace) \(words)"
            thread.composerFocused = true
            AccessibilityNotification.Announcement("Added to your message: \(words)").post()
        }
    }

    private func read() async {
        let asked = date
        let at = Date()
        loading = true
        defer { loading = false }
        do {
            guard let d = try await reads.day(dashboard, asked) else { return routeMissing() }
            // A reply for a day that's no longer asked for (a quick change of date) is dropped.
            guard asked == date, !Task.isCancelled else { return }
            day = d
            askedAt = at
            error = nil
            thread.join(waiting: d)
        } catch {
            guard !Task.isCancelled, !APIClient.isCancellation(error) else { return }
            self.error = error.foodMessage
            // Nutrition was turned off elsewhere (409 "Turn on Nutrition to log food."): the status here is out of date.
            if case .server(409, _)? = error as? APIError, !reloadedForOff {
                reloadedForOff = true
                await dashboard.load()
            }
        }
    }

    // MARK: +

    private func runChoice() {
        defer { chosen = nil }
        switch chosen {
        case .photo?: choosingPhoto = true
        case .search?: sheet = .search
        case .quick?: sheet = .quick
        case .water?: sheet = .water
        case nil: break
        }
    }

    private func askHealth() {
        Task { await dashboard.askFoodHealthIfPending() }
    }

    @ViewBuilder
    private func addSheet(_ s: NutritionAddSheet, viewing: String, today: String) -> some View {
        let words = NutritionChat.dayWords(viewing, today: today)
        let units = dashboard.units
        let when = { [viewing, today] in NutritionChat.when(viewing: viewing, today: today, zone: dashboard.timeZone) }
        switch s {
        case .search:
            SheetScaffold(eyebrow: "Nutrition", title: "Search foods or a barcode") {
                Text("Adds to \(words).").mutedSmall()
                FoodSearchPanel(when: when, units: units, usda: dashboard.availability.foodCan?.usda == true, scan: true)
            }
        case .quick:
            SheetScaffold(eyebrow: "Nutrition", title: "Type amounts") {
                Text("From a label or another app, for \(words).").mutedSmall()
                FoodQuickPanel(when: when, mode: mode, units: units)
            }
        case .water:
            SheetScaffold(eyebrow: "Nutrition", title: "Water") {
                Text("In one tap, for \(words). Any other amount goes in Type amounts.").mutedSmall()
                FoodWaterButtons(when: when, units: units)
            }
        }
    }
}

/// Today's two layouts (P14: a child of the page, so it reads the page's fold, and nothing around the panes changes on
/// one). One column on a phone, the outer display and the inner display upright: the intro, the conversation, the
/// balance and the journal, scrolling together as before. Split on the fold: the intro above both panes, its words and
/// the views on the leading side and the day picker on the trailing side; the conversation in the leading pane, as tall
/// as the pane (its thread scrolls, the composer stays at its foot); the balance and the journal in the trailing pane.
/// Neither of those is a small card (the ring beside its rows, a journal's entries to edit), so they keep the pane's
/// width rather than going two to a row. A fold that swaps the two hands the row at the top (the balance, the journal)
/// to the trailing pane, and stops a voice note being recorded without sending it.
private struct NutritionTodayLayout<Views: View, Chat: View>: View {
    let day: FoodLogDay?
    let mode: NutritionMode
    let units: Units
    let viewing: String
    let today: String
    @Binding var date: String?
    /// The day couldn't be read: the note in the conversation's place.
    let failed: String?
    let loading: Bool
    let voice: VoiceNote?
    @ViewBuilder let views: () -> Views
    /// The conversation card; `pinned`: as tall as its pane (the height given), the thread scrolling inside it.
    @ViewBuilder let chat: (_ pinned: CGFloat?) -> Chat
    @Environment(\.duoFold) private var fold
    @Environment(\.duoContentWidth) private var width
    @Environment(\.dynamicTypeSize) private var typeSize
    /// The panes' height inside the safe area (the keyboard's included).
    @State private var visible: CGFloat = 0

    static var sub: String { "A conversation about what nourishes you." }

    var body: some View {
        VStack(spacing: 0) {
            if let sides = fold.sides(width: width ?? 0) {
                splitIntro(sides).duoPagePadding().padding(.top, 16)
            }
            DuoPanes(anchor: .secondary) {
                // At the accessibility sizes the card's head and composer alone are about a pane tall, so it scrolls
                // with its pane, as on a phone.
                Group {
                    if let failed { failedNote(failed) } else { chat(typeSize.isAccessibilitySize ? nil : visible) }
                }
                .padding(.vertical, 16)
            } secondary: {
                VStack(alignment: .leading, spacing: 16) {
                    if failed == nil { dayCards }
                }
                .scrollTargetLayout()
                .padding(.vertical, 16)
            } single: {
                VStack(alignment: .leading, spacing: 16) {
                    PageIntro(sub: Self.sub) { ViewingPicker(today: today, date: $date) } slot: { views() }
                        .id("nutrition.intro")
                    if let failed {
                        failedNote(failed).id("nutrition.conversation")
                    } else {
                        chat(nil).id("nutrition.conversation")
                        dayCards
                    }
                }
                .scrollTargetLayout()
                .padding(.vertical, 16)
            }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height - $0.safeAreaInsets.top - $0.safeAreaInsets.bottom }) { visible = $0 }
        }
        // A fold or unfold mid-note: the recording goes, never sent (§4).
        .onChange(of: fold.splits) { voice?.screenChanged() }
        .onChange(of: width) { voice?.screenChanged() }
    }

    @ViewBuilder private var dayCards: some View {
        DailyBalanceCard(day: day, mode: mode, units: units)
            .opacity(loading && day != nil ? 0.6 : 1)
            .animation(.easeOut(duration: 0.2), value: loading)
            .id("nutrition.balance")
        FoodJournalCard(day: day, viewing: viewing, today: today, mode: mode, units: units)
            .opacity(loading && day != nil ? 0.6 : 1)
            .animation(.easeOut(duration: 0.2), value: loading)
            .id("nutrition.journal")
    }

    private func failedNote(_ error: String) -> some View {
        Text("Couldn't load your food log: \(error)")
            .font(.app(.footnote)).foregroundStyle(Palette.ink2)
            .fixedSize(horizontal: false, vertical: true)
            .card()
    }

    /// The intro above the panes: the words and the views on the leading side, the day picker at the end of the
    /// trailing side, each within its side (D10).
    private func splitIntro(_ sides: (leading: ClosedRange<CGFloat>, trailing: ClosedRange<CGFloat>)) -> some View {
        HStack(alignment: .top, spacing: 0) {
            PageIntro(sub: Self.sub, actions: { EmptyView() }) { views() }
                .frame(width: sides.leading.upperBound - sides.leading.lowerBound, alignment: .leading)
            Spacer(minLength: 0)
            ViewingPicker(today: today, date: $date)
                .frame(width: sides.trailing.upperBound - sides.trailing.lowerBound, alignment: .trailing)
        }
    }
}

/// "Viewing" and the day, up to a year back (the input in the web's intro): today or any day of the last 366.
private struct ViewingPicker: View {
    let today: String
    @Binding var date: String?

    /// Days are "YYYY-MM-DD" in the person's zone; the picker shows them as UTC midnights, so no zone moves them.
    private static let utc = TimeZone(identifier: "UTC")!

    var body: some View {
        let oldest = Day.add(today, -366)
        // Side by side, or "Viewing" over the picker where they don't fit (the largest text sizes).
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { label; picker(oldest) }
            VStack(alignment: .leading, spacing: 6) { label; picker(oldest) }
        }
    }

    private var label: some View {
        Text("Viewing").font(.app(size: 12, relativeTo: .caption)).foregroundStyle(Palette.ink3).accessibilityHidden(true)
    }

    private func picker(_ oldest: String) -> some View {
        DatePicker("Viewing", selection: Binding(get: { Day.midnightUTC(date ?? today) }, set: { new in
            let v = Self.string(new)
            // Past either end: keep the day shown.
            guard v >= oldest, v <= today else { return }
            date = v == today ? nil : v
        }), in: Day.midnightUTC(oldest)...Day.midnightUTC(today), displayedComponents: .date)
            .labelsHidden()
            .environment(\.timeZone, Self.utc)
            .environment(\.calendar, { var c = Calendar(identifier: .gregorian); c.timeZone = Self.utc; return c }())
            .accessibilityLabel("Viewing")
            .accessibilityIdentifier("nutritionViewing")
    }

    static func string(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = utc
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
}

// MARK: - The conversation

/// What + offers (the web's menu, a sheet from the bottom on a phone).
enum NutritionAddChoice {
    case photo, search, quick, water
}

/// A sheet + opens.
enum NutritionAddSheet: String, Identifiable {
    case search, quick, water
    var id: String { rawValue }
}

/// The conversation card (NutritionChat): its head, the thread, the composer, and what reads an estimate. What + opens,
/// the voice note and the problem line are the page's (NutritionToday), so a fold that swaps the open Duo's panes keeps
/// them; the card asks for them. `pinned`: as tall as its pane, the thread scrolling inside it above the composer, as
/// the web's wide Today (the open Duo's leading pane).
struct NutritionChatCard: View {
    static let bottomID = "nutritionChatBottom"
    /// The shortest a pinned card gets (the keyboard up in a short pane): its head, the composer and a little thread. The
    /// pane scrolls then, rather than the card squeezing.
    static let pinnedFloor: CGFloat = 380

    let thread: NutritionThread
    let day: FoodLogDay?
    let askedAt: Date?
    let mode: NutritionMode
    let viewing: String
    let today: String
    /// A link asked for the composer: focused once, then set back, so coming back to the page never raises the
    /// keyboard again (the web's ?compose=1 is in one address only).
    @Binding var compose: Bool
    var pinned = false
    /// The pane's visible height, for a pinned card.
    var paneHeight: CGFloat = 0
    let voice: VoiceNote?
    @Binding var problem: String?
    /// "Add a photo"'s question, on +.
    @Binding var choosingPhoto: Bool
    @Binding var photoPick: MealPhotoPick?
    /// Opens + 's menu (the page presents it).
    let openMenu: () -> Void
    /// Brings the newest line and the composer into view.
    let scrollToBottom: () -> Void
    @Environment(Dashboard.self) private var dashboard
    @Environment(\.dynamicTypeSize) private var typeSize
    @FocusState private var focused: Bool

    /// McFly can estimate here, once the day is read (the web's day.can.estimate): until then a message could replace
    /// an estimate waiting from elsewhere that hasn't joined the conversation yet.
    private var canEstimate: Bool { NutritionChat.canEstimate(dayRead: day != nil, estimate: dashboard.availability.estimate) }
    /// Why voice notes can't be written down here; nil when they can, and while the day isn't read yet.
    private var voiceOff: String? { day == nil ? nil : NutritionChat.voiceOff(voice: dashboard.availability.voice, byok: dashboard.availability.byok) }
    private var open: (id: UUID, turn: EstimateTurn)? { thread.open(batch: day?.draftBatch) }

    var body: some View {
        Group {
            if pinned {
                // The pane's own padding (16 above and below) is outside the card.
                VStack(alignment: .leading, spacing: 0) {
                    head
                    GeometryReader { g in
                        ScrollView {
                            VStack(spacing: 0) {
                                threadView.padding(.vertical, 20)
                                Color.clear.frame(height: 1).id(Self.bottomID)
                            }
                            .frame(maxWidth: .infinity, minHeight: g.size.height, alignment: thread.isEmpty && !thread.busy ? .center : .top)
                        }
                        .scrollBounceBehavior(.basedOnSize)
                    }
                    composer
                    under
                }
                // The pane's visible height (inside the safe area), less the pane's padding (16 above and below) and a
                // little room: measured, the pane's scroll view shows 3 pt less than the panes' own height there.
                .frame(height: max(paneHeight - 36, Self.pinnedFloor))
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    head
                    threadView.padding(.vertical, 20)
                    composer
                    under
                    Color.clear.frame(height: 1).id(Self.bottomID)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 22)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { CardSurface(shape: RoundedRectangle(cornerRadius: Radius.card, style: .continuous)) }
        // The keyboard is the conversation's, both ways, so a composer a fold brings takes it back.
        .onAppear { if thread.composerFocused { focused = true } }
        .onChange(of: focused) { _, f in if thread.composerFocused != f { thread.composerFocused = f } }
        .onChange(of: thread.composerFocused) { _, f in if focused != f { focused = f } }
        .onChange(of: thread.turns.count) { old, new in if new > old { scrollToBottom() } }
        .onChange(of: thread.busy) { _, busy in if busy { scrollToBottom() } }
        .task(id: compose) {
            guard compose else { return }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            focused = true
            scrollToBottom()
            compose = false
        }
        .onChange(of: thread.draft) { _, v in
            let capped = NutritionChat.prefix(v, utf16: NutritionChat.maxDescription)
            if capped != v { thread.draft = capped }
        }
    }

    /// Under the composer: the problem line, then what reads an estimate.
    @ViewBuilder private var under: some View {
        if let shown = problem ?? voice?.error {
            Group {
                if shown == voiceOff {
                    Text(shown).font(.app(size: 12, relativeTo: .caption)).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true)
                } else {
                    NoteBad(shown, size: 12)
                }
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.top, 10)
        }
        SetupLineView(line: NutritionChat.setupLine(can: dashboard.availability.foodCan, ai: dashboard.availability.ai.value, mode: mode))
    }

    // MARK: Head

    private var head: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                Text("healthOS nutrition")
                    .textCase(.uppercase)
                    .font(.app(size: 10, weight: .medium, relativeTo: .caption2))
                    .tracking(1.6)
                    .foregroundStyle(Palette.ink3)
                Text("What's on your plate?")
                    .font(.app(size: 23, relativeTo: .title2))
                    .tracking(-0.46)
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
                    .accessibilityAddTraits(.isHeader)
                Text("Tell me in your own words. I'll take care of the numbers.")
                    .font(.app(size: 12.5, relativeTo: .footnote))
                    .foregroundStyle(Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            }
            Spacer(minLength: 0)
            if !thread.isEmpty, !thread.busy {
                Button("Clear") { thread.clear(keeping: open?.id) }
                    .buttonStyle(.quietText(size: 12))
                    .accessibilityLabel("Clear this conversation")
                    .accessibilityIdentifier("clearConversation")
            }
        }
    }

    // MARK: The thread

    @ViewBuilder
    private var threadView: some View {
        if thread.isEmpty, !thread.busy {
            VStack(spacing: 16) {
                Orb(size: 48).padding(.bottom, 14)
                Text("Good food.\nOne simple conversation.")
                    .font(.app(size: 23, relativeTo: .title2))
                    .tracking(-0.46)
                    .lineSpacing(4)
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text("“I had a chicken bowl with rice and avocado.”")
                    .font(.app(size: 12.5, relativeTo: .footnote))
                    .foregroundStyle(Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.center)
            // The card is at least a short screen tall (min-height 460 on the web's phone), the invitation in its middle.
            // Pinned in a pane, the thread's own scroll view centres it in whatever room there is.
            .frame(maxWidth: .infinity, minHeight: pinned ? 0 : 268)
            .padding(.vertical, 24)
            .accessibilityElement(children: .combine)
        } else {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(thread.turns) { turn in
                    switch turn.body {
                    case .you(let text, let thumbnail): YouLine(text: text, thumbnail: thumbnail)
                    case .note(let text, let error):
                        McFlyLine {
                            if error { NoteBad(text, icon: true, size: 14) } else { Text(text).font(.app(size: 14, relativeTo: .subheadline)).foregroundStyle(Palette.ink).fixedSize(horizontal: false, vertical: true) }
                        }
                    case .estimate(let e):
                        McFlyLine {
                            EstimateLineView(id: turn.id, turn: e, thread: thread, day: day, askedAt: askedAt, fresh: thread.fresh[e.batch], today: today, mode: mode) { saved in
                                thread.finish(turn.id, saved: saved)
                                AccessibilityNotification.Announcement(saved == nil ? "Discarded. Nothing was saved." : "Saved to your food journal.").post()
                            }
                        }
                    }
                }
                if thread.busy {
                    McFlyLine(busy: true) {
                        Text("McFly is estimating…").font(.app(size: 14, relativeTo: .subheadline)).foregroundStyle(Palette.ink3)
                    }
                }
            }
        }
    }

    // MARK: The composer

    private var composer: some View {
        let off = day != nil && !canEstimate
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        return VStack(alignment: .leading, spacing: 6) {
            if let photo = thread.photo {
                Image(uiImage: photo.preview)
                    .resizable().scaledToFill()
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.border))
                    .accessibilityLabel("Your photo, as it will be sent")
                    .overlay(alignment: .topTrailing) {
                        Button { thread.photo = nil } label: {
                            Image(systemName: "xmark")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(Palette.ink2)
                                .frame(width: 24, height: 24)
                                .background(Palette.surface, in: Circle())
                                .tokenShadow(.pill, in: Circle())
                                .frame(width: 44, height: 44)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .offset(x: 17, y: -17)
                        .accessibilityLabel("Remove the photo")
                    }
                    .padding(.bottom, 2)
                    .padding(.top, 4)
            }
            TextField(open != nil ? "Anything to correct?" : "I ate…", text: Binding(get: { thread.draft }, set: { thread.draft = $0 }), axis: .vertical)
                .lineLimit(2...8)
                .font(.app(size: 14, relativeTo: .subheadline))
                .foregroundStyle(Palette.ink)
                .focused($focused)
                .disabled(off)
                .frame(minHeight: 44, alignment: .top)
                .accessibilityLabel(open != nil ? "A correction to the estimate" : "What did you eat?")
                .accessibilityIdentifier("nutritionComposer")
            if typeSize.isAccessibilitySize {
                composerRow
                voiceLabel.frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                composerRow
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(NutriColor.field.color, in: shape)
        .overlay(shape.strokeBorder(focused ? Palette.focus : Palette.border, lineWidth: focused ? 2 : 1))
        .tokenShadow(.pill, in: shape)
        .animation(.easeOut(duration: 0.15), value: focused)
        .contentShape(shape)
        .onTapGesture { if !off { focused = true } }
    }

    private var composerRow: some View {
        let ready = sendable
        return HStack(spacing: 8) {
            Button { focused = false; openMenu() } label: {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Palette.accentText)
                    .frame(width: 38, height: 38)
                    .background(Palette.accentSoft, in: Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("More ways to add food")
            .accessibilityIdentifier("nutritionPlus")
            // Its "Add a photo" question is anchored here (a popover on + at regular width, P10); what it opens is the page's.
            .mealPhotoChoice(isPresented: $choosingPhoto, pick: $photoPick)
            Spacer(minLength: 0)
            if !typeSize.isAccessibilitySize { voiceLabel }
            if let voice {
                VoiceButton(voice: voice, on: dashboard.availability.voice == true, voiceOff: voiceOff,
                            disabled: day == nil || thread.busy || (!canEstimate && voiceOff == nil)) {
                    problem = voiceOff
                }
            }
            Button(action: send) {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Palette.accentInk)
                    .frame(width: 38, height: 38)
                    .background {
                        if ready { GradientFill(.accentGrad).clipShape(Circle()) } else { Circle().fill(NutriColor.sendOff.color) }
                    }
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            // Its own style: a plain one dims a disabled button, and the web's is drawn in --nutri-send-off as it is.
            .buttonStyle(SendButtonStyle())
            .disabled(!ready)
            .accessibilityLabel(open != nil ? "Send the correction" : "Send to McFly")
            .accessibilityIdentifier("nutritionSend")
        }
    }

    private var voiceLabel: some View {
        Text(voice?.label ?? "Hold to talk")
            .font(.app(size: 11.5, relativeTo: .caption2))
            .foregroundStyle(Palette.ink3)
            .lineLimit(1)
            .truncationMode(.tail)
            .accessibilityHidden(true)
    }

    /// Send is on: something to send, McFly free, and the day read.
    private var sendable: Bool {
        NutritionChat.canSend(dayRead: day != nil, estimate: dashboard.availability.estimate, busy: thread.busy, draft: thread.draft, photo: thread.photo != nil)
    }

    private func send() {
        let words = NutritionChat.words(thread.draft)
        guard sendable else { return }
        problem = nil
        voice?.clearError()
        let sent = thread.photo
        let ask = thread.ask(words: words, jpeg: sent?.jpeg, at: NutritionChat.when(viewing: viewing, today: today, zone: dashboard.timeZone),
                             openBatch: day?.draftBatch)
        thread.append(ChatTurn(.you(text: words, thumbnail: sent.flatMap { NutritionThread.thumbnail($0.jpeg) })))
        thread.draft = ""
        thread.photo = nil
        thread.busy = true
        AccessibilityNotification.Announcement("McFly is estimating…").post()
        Task {
            do {
                let r = try await dashboard.estimateFood(FoodBody.estimate(description: ask.description, jpeg: ask.jpeg, date: ask.moment.date, time: ask.moment.time))
                let said = thread.received(r, for: ask)
                AccessibilityNotification.Announcement(said).post()
                thread.busy = false
                await dashboard.estimated()
            } catch {
                thread.busy = false
                let message = APIClient.isCancellation(error) ? "McFly couldn't make an estimate just now. Try again, or search or quick add instead." : error.foodMessage
                thread.failed(message)
                AccessibilityNotification.Announcement(message).post()
                // What was sent comes back, to try again.
                if thread.draft.isEmpty { thread.draft = words }
                if thread.photo == nil { thread.photo = sent }
            }
        }
    }
}

/// Send's look as it is, enabled or not: the label draws its own fill (the gradient, or the web's --nutri-send-off).
private struct SendButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.8 : 1)
    }
}

private extension String {
    var trimmingTrailingSpace: String {
        var s = self
        while let last = s.last, last.isWhitespace { s.removeLast() }
        return s
    }
}

/// Your line, on the right in the pale green bubble: your words, and your photo's thumbnail.
private struct YouLine: View {
    let text: String
    let thumbnail: UIImage?

    var body: some View {
        HStack {
            Spacer(minLength: 64)
            VStack(alignment: .trailing, spacing: 8) {
                if let thumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFill()
                        .frame(width: 140, height: 140)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .accessibilityLabel("Your photo")
                }
                if !text.isEmpty {
                    Text(text).font(.app(size: 14, relativeTo: .subheadline)).foregroundStyle(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(NutriColor.bubble.color, in: UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 18, bottomTrailingRadius: 6,
                                                                            topTrailingRadius: 18, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("You: \(text)\(thumbnail != nil ? (text.isEmpty ? "a photo" : ", with a photo") : "")")
        }
    }
}

/// McFly's line: its orb, and what it said.
private struct McFlyLine<Content: View>: View {
    var busy = false
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Orb(size: 20, busy: busy).padding(.top, 2)
            VStack(alignment: .leading, spacing: 8) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
    }
}

/// McFly's reply with an estimate: the review while it waits, then what became of it.
private struct EstimateLineView: View {
    let id: UUID
    let turn: EstimateTurn
    let thread: NutritionThread
    let day: FoodLogDay?
    let askedAt: Date?
    let fresh: [FoodEntry]?
    let today: String
    let mode: NutritionMode
    let onDone: (Int?) -> Void
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        let shows = NutritionChat.shows(turn, day: day, dayAskedAt: askedAt, fresh: fresh)
        switch shows {
        case .review(let drafts):
            ChatReview(turn: turn, review: thread.review(batch: turn.batch, drafts: drafts), today: today, mode: mode, units: dashboard.units, onDone: onDone)
                .id(drafts.map(\.id).joined(separator: ","))
        case .saved:
            line(shows.text ?? "", Palette.ink, 14)
        case .discarded, .gone:
            line(shows.text ?? "", Palette.ink3, 14)
        case .replaced, .waiting:
            line(shows.text ?? "", Palette.ink3, 12)
        }
    }

    private func line(_ text: String, _ color: Color, _ size: CGFloat) -> some View {
        let style: Font.TextStyle = size < 13 ? .caption : .subheadline
        return Text(text).font(.app(size: size, relativeTo: style)).foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The estimate to check, in the conversation (ChatReview): the same review as the Log's, drawn inline. Each item's
/// name and how many, leaving things out, what it all comes to, and when.
private struct ChatReview: View {
    let turn: EstimateTurn
    let today: String
    let mode: NutritionMode
    let units: Units
    let onDone: (Int?) -> Void
    @Environment(Dashboard.self) private var dashboard
    @Environment(\.dynamicTypeSize) private var typeSize
    /// How many's column: 72 at the usual size, wider as the text grows, so "How many" stays on one line.
    @ScaledMetric(relativeTo: .caption) private var quantityWidth: CGFloat = 72
    /// The conversation's, so what's typed in it survives a fold that swaps the open Duo's panes.
    @Bindable var review: EstimateReview

    init(turn: EstimateTurn, review: EstimateReview, today: String, mode: NutritionMode, units: Units, onDone: @escaping (Int?) -> Void) {
        self.turn = turn
        self.review = review
        self.today = today
        self.mode = mode
        self.units = units
        self.onDone = onDone
    }

    var body: some View {
        let byID = review.byID
        let first = review.drafts.first
        let sum = review.altogether(mode: mode, units: units)
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        VStack(alignment: .leading, spacing: 10) {
            (Text(turn.found ? "This estimate is waiting for you to check." : "Here's my estimate.").foregroundStyle(Palette.ink)
             + Text(" Check it, then save. Nothing counts until you do.").foregroundStyle(Palette.ink3))
                .font(.app(size: 14, relativeTo: .subheadline))
                .fixedSize(horizontal: false, vertical: true)
            if !turn.note.isEmpty { NutriNote(text: turn.note) }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(review.kept.enumerated()), id: \.element.id) { i, k in
                    let d = byID[k.id]
                    let line = review.line(k, mode: mode, units: units)
                    VStack(alignment: .leading, spacing: 5) {
                        itemRow(i, k)
                        let detail = [d?.portion ?? "", line].filter { !$0.isEmpty }.joined(separator: " · ")
                        if !detail.isEmpty { Text(detail).mutedSmall() }
                    }
                    .padding(.top, i == 0 ? 2 : 10)
                    .padding(.bottom, 10)
                    .overlay(alignment: .top) { if i > 0 { Rectangle().fill(Palette.border).frame(height: 1) } }
                }
            }
            if review.kept.isEmpty {
                Text("Everything is left out. Discard it, or tell me what you had instead.").mutedSmall()
            }
            if !sum.isEmpty {
                (Text("Altogether ").foregroundStyle(Palette.ink3) + Text(sum).foregroundStyle(Palette.ink))
                    .font(.app(size: 12, relativeTo: .caption))
                    .fixedSize(horizontal: false, vertical: true)
            }
            NutritionFlow(spacing: 16, rowSpacing: 10) {
                FoodWhenPicker(label: "\(first.map { Fmt.relativeDay($0.date, today: today) } ?? "Today") at", time: $review.time)
                HStack(spacing: 8) {
                    Button {
                        Task { if let n = await review.save(.dashboard(dashboard)) { onDone(n) } }
                    } label: { PillLabel(review.saveTitle) }
                    .buttonStyle(.accentPill(size: .compact))
                    .disabled(review.busy || review.kept.isEmpty)
                    .accessibilityIdentifier("saveDrafts")
                    Button("Discard") {
                        Task { if await review.discard(.dashboard(dashboard)) { onDone(nil) } }
                    }
                    .buttonStyle(.quietText)
                    .disabled(review.busy)
                    .accessibilityIdentifier("discardDrafts")
                }
            }
            if let error = review.error { NoteBad(error, size: 12) }
            Text("Not quite right? Tell me what to change, and I'll redo it. Estimates are rough, so you can fix any amount after saving, too.")
                .mutedSmall()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Palette.surface, in: shape)
        .overlay(shape.strokeBorder(Palette.border))
        .tokenShadow(.pill, in: shape)
    }

    /// The name, how many, and Leave out: side by side on a phone, Leave out under them (.nutri-item-row at 560px).
    @ViewBuilder
    private func itemRow(_ i: Int, _ k: EstimateReview.Kept) -> some View {
        let nameBinding = review.binding(k.id, \.name)
        let name = TextField("Name", text: nameBinding)
            .foodInput()
            .onChange(of: k.name) { _, v in if v.count > 100 { nameBinding.wrappedValue = String(v.prefix(100)) } }
            .accessibilityLabel("Item \(i + 1), name")
        let quantity = VStack(alignment: .leading, spacing: 3) {
            FieldLabel("How many").lineLimit(1).fixedSize()
            TextField("1", text: review.binding(k.id, \.quantity)).keyboardType(.decimalPad).foodInput()
                .accessibilityLabel("How many of \(k.name.isEmpty ? "item \(i + 1)" : k.name)")
        }
        let leave = Button("Leave out") { review.leaveOut(k.id) }
            .buttonStyle(.quietText(size: 12))
            .accessibilityLabel("Leave out \(k.name)")
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 6) { name; quantity; leave }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .bottom, spacing: 10) {
                    name
                    quantity.frame(width: quantityWidth)
                }
                leave
            }
        }
    }
}

// MARK: The voice button

/// Hold to talk: McFly's orb, bigger while it records. With voice notes off it still answers a press, to say why.
private struct VoiceButton: View {
    let voice: VoiceNote
    /// Voice notes can be written down here.
    let on: Bool
    let voiceOff: String?
    let disabled: Bool
    let blocked: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Held down. A gesture state goes back to false however the touch ends, cancelled included (the microphone's
    /// permission question, a scroll taking the touch, a fold), so a recording never outlives the finger.
    @GestureState private var held = false

    var body: some View {
        let scale: CGFloat = voice.state == .recording ? 1.4 : voice.state == .starting ? 1.12 : 1
        ZStack {
            if voice.state == .recording { Glow(still: reduceMotion) }
            Orb(size: 20, busy: voice.state == .transcribing)
                .scaleEffect(scale)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: scale)
        }
        .opacity(voiceOff != nil || disabled ? 0.45 : 1)
        .frame(width: 44, height: 44)
        .contentShape(Circle())
        // The finger lifting (the drag's normal end) is the one way a held note is sent (design §4: a fold never sends
        // half a note). A hold that ends any other way is thrown away, with a line saying so: checked once this touch's
        // events are all in, so a normal end has already sent it by then.
        .gesture(DragGesture(minimumDistance: 0)
            .updating($held) { _, state, _ in state = true }
            .onEnded { _ in if on { voice.release() } }, including: disabled ? .none : .all)
        .onChange(of: held) { _, down in
            if down {
                if on { voice.press() } else { blocked() }
            } else if on {
                Task { @MainActor in voice.holdCancelled() }
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: voice.state == .recording) { _, recording in recording }
        .accessibilityElement()
        .accessibilityLabel("Voice note")
        .accessibilityValue(voice.label + voice.more)
        .accessibilityHint(voiceOff ?? (voice.state == .recording ? "Activate again to stop." : "Activate to record, and again to stop."))
        .accessibilityAddTraits(voice.state == .recording ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { if on { voice.toggle() } else { blocked() } }
        .disabled(disabled)
        .accessibilityIdentifier("nutritionVoice")
    }

    /// The recording's glow (nutri-listen), still with Reduce Motion.
    private struct Glow: View {
        let still: Bool
        private static let color = CSSColor.rgba(241, 105, 64, 0.5).color

        var body: some View {
            if still {
                Circle().fill(Self.color.opacity(0.6)).frame(width: 28, height: 28).blur(radius: 6)
            } else {
                PhaseAnimator([false, true]) { up in
                    Circle().fill(Self.color.opacity(up ? 0.75 : 0.5)).frame(width: up ? 36 : 28, height: up ? 36 : 28).blur(radius: up ? 9 : 4)
                } animation: { _ in .easeInOut(duration: 0.6) }
            }
        }
    }
}

// MARK: Under the composer

/// What reads an estimate, or what's missing for one (SetupLine): small and centred.
private struct SetupLineView: View {
    let line: NutritionChat.SetupLine?
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        switch line {
        case .connectOpenAI?:
            // The link as the web's .nutri-setup a: medium, in the accent's words colour, underlined.
            Text(connectLine)
                .font(.app(size: 11.5, relativeTo: .caption2))
                .foregroundStyle(Palette.ink2)
                .environment(\.openURL, OpenURLAction { url in dashboard.open(url: url) ? .handled : .systemAction })
                .modifier(SetupLineLayout())
        case .notHere(let text)?:
            Text(text).font(.app(size: 11.5, relativeTo: .caption2)).foregroundStyle(Palette.ink2).modifier(SetupLineLayout())
        case .using(let text)?:
            Text(text).font(.app(size: 11.5, relativeTo: .caption2)).foregroundStyle(Palette.ink3).modifier(SetupLineLayout())
        case nil:
            EmptyView()
        }
    }

    private var connectLine: AttributedString {
        var link = AttributedString(NutritionChat.SetupLine.connectLink)
        link.link = URL(string: "healthos://profile?connect=openai")
        link.font = .app(size: 11.5, weight: .medium, relativeTo: .caption2)
        link.foregroundColor = Palette.accentText
        link.underlineStyle = .single
        return AttributedString(NutritionChat.SetupLine.connectLead) + link + AttributedString(NutritionChat.SetupLine.connectTail)
    }

    private struct SetupLineLayout: ViewModifier {
        func body(content: Content) -> some View {
            content.multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity).padding(.top, 12)
                .accessibilityIdentifier("nutritionSetupLine")
        }
    }
}

// MARK: - + menu

/// + 's menu, as the web's phone shows its menus: a sheet from the bottom on the pale green menu gradient, as tall as
/// its rows. What's chosen opens once it has gone.
private struct NutritionAddMenu: View {
    let canEstimate: Bool
    let mode: NutritionMode
    let choose: (NutritionAddChoice) -> Void
    @State private var height: CGFloat = 240

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if canEstimate { item(.photo, "Add a photo", "camera") }
                item(.search, "Search foods or a barcode", "magnifyingglass")
                if mode != .none {
                    item(.quick, "Type amounts", "slider.horizontal.3")
                    item(.water, "Water", "drop")
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 14)
            .padding(.bottom, 10)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .font(.app(.body))
        // As tall as its rows; on the open Duo's inner display, a centred sheet fitted to them (§2.7).
        .duoMenuSheet(height: height)
        .presentationCornerRadius(22)
        .presentationBackground { GradientFill(.menuBg) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Add to your food journal")
    }

    private func item(_ choice: NutritionAddChoice, _ title: String, _ symbol: String) -> some View {
        Button { choose(choice) } label: {
            HStack(spacing: 12) {
                RowIcon(systemName: symbol, width: 22, color: Palette.accentText)
                Text(title)
                    .font(.app(size: 15, relativeTo: .body))
                    .foregroundStyle(Palette.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(AddMenuRowStyle())
    }

    private struct AddMenuRowStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .background(configuration.isPressed ? Palette.chip : .clear, in: RoundedRectangle(cornerRadius: Radius.nav, style: .continuous))
        }
    }
}

// MARK: - The day

/// The day's saved entries added up (DailyBalance): kcal in the ring (or meals, or "by weight"), protein, carbs and fat
/// by weight beside it, fiber, sugar, sodium, alcohol and water underneath. A dash where nothing was logged.
struct DailyBalanceCard: View {
    let day: FoodLogDay?
    let mode: NutritionMode
    let units: Units
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let m = DailyBalanceMath(day: day, mode: mode, units: units)
        VStack(alignment: .leading, spacing: 16) {
            NutriCardHead(title: "Your daily balance") { Badge(m.badge, tone: .sage) }
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 18) { BalanceRing(m: m); side(m) }
            } else {
                HStack(spacing: 18) { BalanceRing(m: m); side(m) }
            }
            if !m.extras.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 160 : 84), spacing: 14, alignment: .topLeading)],
                          alignment: .leading, spacing: 8) {
                    ForEach(m.extras, id: \.label) { x in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(x.label).font(.app(size: 11.5, relativeTo: .caption2)).foregroundStyle(Palette.ink2)
                            Text(x.value).font(.app(size: 14, weight: .medium, relativeTo: .subheadline)).foregroundStyle(Palette.ink)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.top, 12)
                .overlay(alignment: .top) { Rectangle().fill(Palette.border).frame(height: 1) }
            }
            Text(m.foot).mutedSmall()
        }
        .card()
    }

    /// A macro's dot and name.
    private func macroName(_ r: DailyBalanceMath.Row) -> some View {
        HStack(spacing: 10) {
            Circle().fill(NutriColor.macro(r.key)).frame(width: 6, height: 6)
            Text(r.label).font(.app(size: 12.5, relativeTo: .footnote)).foregroundStyle(Palette.ink2)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Its grams and its share of the three.
    private func macroAmount(_ r: DailyBalanceMath.Row) -> some View {
        HStack(spacing: 10) {
            Group {
                if let g = r.grams {
                    Text(g).font(.app(size: 20, relativeTo: .title3)).foregroundStyle(Palette.ink)
                        + Text(" g").font(.app(size: 11, relativeTo: .caption2)).foregroundStyle(Palette.ink3)
                } else {
                    Text(String.emptyValue).font(.app(size: 20, relativeTo: .title3)).foregroundStyle(Palette.ink)
                }
            }
            .lineLimit(1)
            Text(r.percent).font(.app(size: 10.5, relativeTo: .caption2)).foregroundStyle(Palette.ink3)
                .lineLimit(1)
                .frame(minWidth: 36, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func side(_ m: DailyBalanceMath) -> some View {
        if mode == .none {
            Text("You chose to see no amounts, so this counts your meals, not what's in them.").mutedSmall()
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(m.rows.enumerated()), id: \.element.key) { i, r in
                    // One line where it fits; at the largest sizes on a narrower phone, or on a day of three-digit
                    // grams, the name over its grams and share, so no word breaks in the middle.
                    // The amount keeps its own width (the line is chosen only where all of it fits), so the row never
                    // shares its width out evenly and cuts the grams short.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) {
                            macroName(r)
                            macroAmount(r).fixedSize()
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            macroName(r)
                            HStack(spacing: 10) {
                                Spacer(minLength: 16)
                                macroAmount(r).layoutPriority(1)
                            }
                        }
                    }
                    .padding(.vertical, 11)
                    .overlay(alignment: .top) { if i > 0 { Rectangle().fill(Palette.border).frame(height: 1) } }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(r.label): \(r.grams.map { "\($0) grams" } ?? "nothing logged")\(r.percent == .emptyValue ? "" : ", \(r.percent)")")
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

/// The balance ring: the pale loop under protein, carbs and fat by weight, and its white middle with a soft edge.
/// 112 points as on the web; at the accessibility text sizes, where the card stacks it over the rows, it grows with
/// the text (to twice that at most), its figure and words with it, so the day's total reads at the size chosen.
private struct BalanceRing: View {
    let m: DailyBalanceMath
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .title2) private var grown: CGFloat = 1
    /// The figure's words ("kcal logged") grow a little below the accessibility sizes too, inside the same ring.
    @ScaledMetric(relativeTo: .caption2) private var captionGrown: CGFloat = 1

    static let base: CGFloat = 112
    static let most: CGFloat = 2

    /// How much bigger than the web's ring it's drawn.
    private var scale: CGFloat { typeSize.isAccessibilitySize ? min(max(grown, 1), Self.most) : 1 }
    private var size: CGFloat { Self.base * scale }
    private var thickness: CGFloat { 11 * scale }
    /// The caption's size: with the ring at the accessibility sizes, up to 1.3 times the web's 10 below them.
    private var captionScale: CGFloat { typeSize.isAccessibilitySize ? scale : min(max(captionGrown, 1), 1.3) }

    var body: some View {
        let parts = m.mode == .none ? [] : m.parts
        let center = m.center
        ZStack {
            NutriRingLoop(thickness: thickness).opacity(m.total > 0 ? 0.45 : 1)
            Canvas { ctx, canvas in
                let total = parts.reduce(0) { $0 + $1.value }
                guard total > 0 else { return }
                let r = (min(canvas.width, canvas.height) - thickness) / 2
                let c = 2 * Double.pi * r
                // A small break between parts, so neighbours of similar colour stay apart.
                let gap = parts.count > 1 ? min(4, c / 60) : 0
                var offset = 0.0
                let mid = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
                for p in parts {
                    let len = p.value / total * c
                    let shown = max(0, len - gap)
                    var arc = Path()
                    arc.addArc(center: mid, radius: r, startAngle: .radians(offset / r - .pi / 2), endAngle: .radians((offset + shown) / r - .pi / 2), clockwise: false)
                    ctx.stroke(arc, with: .color(NutriColor.macro(p.key)), lineWidth: thickness)
                    offset += len
                }
            }
            Circle()
                .fill(Palette.surface)
                .overlay(Circle().strokeBorder(Palette.border))
                .shadow(color: CSSColor.rgba(36, 49, 42, 0.12).color, radius: 4, y: 3)
                .padding(15 * scale)
            VStack(spacing: 1) {
                if let value = center.value {
                    Text(value).font(.app(fixedSize: 28 * scale)).foregroundStyle(Palette.ink).lineLimit(1).minimumScaleFactor(0.6)
                }
                Text(center.caption).font(.app(fixedSize: 10 * captionScale)).foregroundStyle(Palette.ink3)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: min(64 * captionScale, size - 40 * scale))
            }
            .padding(20 * scale)
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel(m.label)
        .accessibilityValue([center.value == .emptyValue ? nil : center.value, center.caption].compactMap { $0 }.joined(separator: " "))
    }
}

/// The day's saved entries, each editable (FoodJournal), and which app's totals count that day.
struct FoodJournalCard: View {
    let day: FoodLogDay?
    let viewing: String
    let today: String
    let mode: NutritionMode
    let units: Units

    var body: some View {
        let entries = day?.entries ?? []
        VStack(alignment: .leading, spacing: 12) {
            NutriCardHead(title: "Your food journal") { Text(Fmt.day(viewing)).mutedSmall() }
            if day == nil {
                Text("Loading…").mutedSmall()
            } else if !entries.isEmpty {
                FoodEntryList(entries: entries, mode: mode, units: units)
            } else {
                let isToday = viewing == today
                VStack(spacing: 6) {
                    Image(systemName: "fork.knife")
                        .font(.title3)
                        .foregroundStyle(Palette.ink2)
                        .padding(.bottom, 16)
                        .accessibilityHidden(true)
                    Text(isToday ? "Your day starts with a bite." : "Nothing logged here that day.")
                        .font(.app(size: 16, weight: .medium, relativeTo: .callout))
                        .foregroundStyle(Palette.ink)
                        .padding(.bottom, 6)
                    Text("\(isToday ? "Tell McFly what you ate." : "Tell McFly what you had, and it goes on this day.")\nYour meals will appear here.")
                        .font(.app(size: 12, relativeTo: .caption))
                        .foregroundStyle(Palette.ink3)
                        .lineSpacing(6)
                }
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 12)
                .padding(.top, 26)
                .padding(.bottom, 40)
                .accessibilityElement(children: .combine)
            }
            if let day, let counted = day.countedApp, counted != "healthOS" {
                LinkedText(entries.isEmpty
                           ? "You logged food in \(counted) that day. Its totals are on [Trends](healthos://nutrition?tab=trends)."
                           : "This day's totals elsewhere in Nutrition come from \(counted). When two apps log the same day, one app's totals count and the other's aren't added in, because apps copy each other's food through Apple Health." + (mode != .none ? " You can choose which app counts on [Macros](healthos://nutrition?tab=macros)." : ""))
                    .font(.app(size: 12, relativeTo: .caption))
                    .foregroundStyle(Palette.ink3)
            }
        }
        .card()
    }
}
