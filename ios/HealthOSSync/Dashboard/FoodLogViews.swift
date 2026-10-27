import SwiftUI
import VisionKit

// The Nutrition page's Log (src/pages/FoodLog.tsx): what a person logs in healthOS itself. A day's entries, each
// editable, beside one card to add more: a food database search (or a barcode), McFly's estimate from a photo or a few
// words (a draft to check and save, never saved on its own), or amounts typed in. The server has already removed every
// number the person chose not to see, and saves a database food from its own copy, so the phone never needs them.
// Same tone as the rest of Nutrition: no score, no "remaining", no colour for more or less. Today's conversation
// (Nutrition/NutritionToday.swift) reuses the pieces here, as the web's NutritionChat.tsx reuses FoodLog.tsx's.

/// The Log view: a day of the last two weeks, and the card that adds to it. One column on a phone, the outer display and
/// the inner display upright, as before. On the open iPhone Duo, split on the fold (decisions.md Q5: the lead on the
/// left, the rest on the right), two panes: the views and the day in the leading pane, staying put unless it's taller
/// than the pane, and the card that adds to it in the trailing pane, scrolling on its own as a search grows. A fold
/// swaps the two layouts, so everything they hold is here, above the panes (P4): the day and its read, what's chosen,
/// typed and found in the add card (`FoodAddState`), the entries being edited (`FoodEntryEdits`), and the photo picker
/// and camera an estimate opens. A fold hands the row at the top between the one column and the trailing pane (§4).
struct FoodLogTab<Header: View>: View {
    @ViewBuilder let header: () -> Header
    @Environment(Dashboard.self) private var dashboard
    @Environment(\.nutritionReads) private var reads
    @State private var log: FoodLog?
    @State private var error: String?
    @State private var loading = false
    @State private var day: String?
    @State private var counted: NutritionData?
    @State private var add = FoodAddState()
    @State private var edits = FoodEntryEdits()

    var body: some View {
        DuoPage { _ in
            DuoPanes(anchor: .secondary) {
                VStack(alignment: .leading, spacing: 16) {
                    header()
                    if let log { dayCard(log) } else { status }
                }
                .dimmed(loading && log != nil)
                .padding(.vertical, 16)
            } secondary: {
                VStack(alignment: .leading, spacing: 16) {
                    if let log { addCard(log).id("log.add") }
                }
                .scrollTargetLayout()
                .dimmed(loading && log != nil)
                .padding(.vertical, 16)
            } single: {
                VStack(alignment: .leading, spacing: 16) {
                    header().id("log.views")
                    if let log {
                        dayCard(log).id("log.day")
                        addCard(log).id("log.add")
                    } else {
                        status.id("log.status")
                    }
                }
                .scrollTargetLayout()
                .dimmed(loading && log != nil)
                .padding(.vertical, 16)
            }
        }
        .environment(\.foodEntryEdits, edits)
        .mealPhotoPicker(pick: Bindable(add.estimate).pick) { add.estimate.photo = $0 } failed: {
            add.estimate.error = "That photo couldn't be opened here. Try a JPEG or PNG, or describe it instead."
        }
        // Another day's entries are other rows: the editors open on this one close, as they always have.
        .onChange(of: log.map(selectedDay)) { edits.open = [:] }
        .scrollDismissesKeyboard(.interactively)
        .background(Palette.page)
        .refreshable { await dashboard.load() }
        .task(id: "\(dashboard.generation)|\(dashboard.nutritionMode?.rawValue ?? "off")") { await reload() }
        // Health's write question for what was just added here (no sheet is up to cover it).
        .onChange(of: dashboard.foodHealthAskPending) { _, pending in
            if pending { Task { await dashboard.askFoodHealthIfPending() } }
        }
    }

    private func dayCard(_ log: FoodLog) -> some View {
        let selected = selectedDay(log)
        return FoodLogDayCard(log: log, day: selected, entries: log.entries.filter { $0.date == selected },
                              counted: counted?.days.first { $0.date == selected }?.app) { step in
            day = Day.add(selected, step)
        }
    }

    private func addCard(_ log: FoodLog) -> some View {
        FoodAddCard(log: log, date: selectedDay(log), units: dashboard.units, state: add)
    }

    @ViewBuilder private var status: some View {
        if let error {
            Text("Couldn't load your food log: \(error)").font(.app(.footnote)).foregroundStyle(Palette.ink2).card()
        } else {
            ProgressView().frame(maxWidth: .infinity, minHeight: 200)
        }
    }

    private func selectedDay(_ log: FoodLog) -> String {
        if let day, day >= log.start, day <= log.today { return day }
        return log.today
    }

    private func reload() async {
        loading = true
        defer { loading = false }
        do {
            log = try await reads.log(dashboard, 14)
            error = nil
            counted = try? await reads.totals(dashboard, 14, false)
        } catch {
            guard !Task.isCancelled, !APIClient.isCancellation(error) else { return }
            self.error = error.foodMessage
        }
    }
}


private extension View {
    /// Faded while the Log reads again, as before.
    func dimmed(_ on: Bool) -> some View {
        opacity(on ? 0.6 : 1).animation(.easeOut(duration: 0.2), value: on)
    }
}

// MARK: - What a fold must keep (P4)

/// An entry's editor, open: what's typed into it and its save.
@MainActor @Observable
final class FoodEntryDraft {
    var name: String
    var time: String
    var quantity: String
    var typed: [String: String]
    var busy = false
    var error: String?

    init(entry: FoodEntry, mode: NutritionMode, units: Units) {
        name = entry.name
        time = entry.time
        quantity = FoodText.quantityText(entry.quantity)
        typed = Dictionary(uniqueKeysWithValues: FoodField.typed(mode).map { ($0.key, $0.text(entry.values[$0.key], units: units)) })
    }
}

/// The entries open for editing on a page, by entry id: held by Today and the Log above the open Duo's panes (P4), so
/// a fold that swaps them leaves each editor open with what's typed.
@MainActor @Observable
final class FoodEntryEdits {
    var open: [String: FoodEntryDraft] = [:]
}

private struct FoodEntryEditsKey: EnvironmentKey {
    static var defaultValue: FoodEntryEdits? { nil }
}

extension EnvironmentValues {
    /// The page's open entry editors; nil: each row keeps its own.
    var foodEntryEdits: FoodEntryEdits? {
        get { self[FoodEntryEditsKey.self] }
        set { self[FoodEntryEditsKey.self] = newValue }
    }
}

/// Everything the Log's "Add food or drink" holds, above the open Duo's panes (P4): the way in chosen, the time picked,
/// McFly's note, each way's typing and results, and the review of an estimate's drafts.
@MainActor @Observable
final class FoodAddState {
    var mode: FoodAddMode = .search
    var picked: String?
    var note = ""
    let search = FoodSearchState()
    let scan = FoodScanState()
    let estimate = FoodEstimateState()
    let quick = FoodQuickState()
    let water = FoodWaterState()
    @ObservationIgnored private var reviews: [String: EstimateReview] = [:]

    /// The review of these drafts: the one being checked, or a new one (the others go).
    func review(batch: String, drafts: [FoodEntry]) -> EstimateReview {
        let key = "\(batch)|\(drafts.map(\.id).joined(separator: ","))"
        if let kept = reviews[key] { return kept }
        let made = EstimateReview(drafts: drafts, batch: batch)
        reviews = [key: made]
        return made
    }
}

/// A food search's typing and what it found.
@MainActor @Observable
final class FoodSearchState {
    var query = ""
    var found: FoodSearch?
    var barcode = false
    var busy = false
    var error: String?
    var open: String?
    var added: String?
    var scanning = false
    var lastScanned: String?
    let picks = FoodResultPicks()
}

/// A barcode typed or read, and what it found.
@MainActor @Observable
final class FoodScanState {
    var code = ""
    var found: FoodSearch?
    var busy = false
    var error: String?
    var lastScanned: String?
    var open: String?
    var added: String?
    let picks = FoodResultPicks()
}

/// An estimate's words and photo, and how it went.
@MainActor @Observable
final class FoodEstimateState {
    var description = ""
    var photo: AttachedPhoto?
    var choosing = false
    var pick: MealPhotoPick?
    var busy = false
    var error: String?
    var note: String?
}

/// Amounts typed in.
@MainActor @Observable
final class FoodQuickState {
    var name = ""
    var typed: [String: String] = [:]
    var busy = false
    var error: String?
    var added: String?
}

/// Water in one tap: the add under way and what it said.
@MainActor @Observable
final class FoodWaterState {
    var busy = false
    var done: String?
    var error: String?
}

/// A food found: its portion and how many.
@MainActor @Observable
final class FoodResultPick {
    var portion = 0
    var quantity = "1"
    var busy = false
    var error: String?
}

/// Each food found's pick, by its id. Each row watches only its own.
@MainActor @Observable
final class FoodResultPicks {
    @ObservationIgnored private var picks: [String: FoodResultPick] = [:]

    func pick(_ id: String) -> FoodResultPick {
        if let p = picks[id] { return p }
        let p = FoodResultPick()
        picks[id] = p
        return p
    }
}

/// One day of the Log (.food-day): the day, its entries, what they add up to, and which app counts that day.
private struct FoodLogDayCard: View {
    let log: FoodLog
    let day: String
    let entries: [FoodEntry]
    /// The app whose totals count that day on the other views.
    let counted: String?
    let step: (Int) -> Void
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        let units = dashboard.units
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                stepButton("chevron.left", "Day before", enabled: day > log.start) { step(-1) }
                Spacer(minLength: 0)
                VStack(spacing: 2) {
                    Text(Fmt.relativeDay(day, today: log.today)).font(.app(.headline, weight: .medium)).foregroundStyle(Palette.ink)
                        .accessibilityAddTraits(.isHeader)
                    Text(Fmt.day(day, "EEEEMMMMd")).mutedSmall()
                }
                .multilineTextAlignment(.center)
                Spacer(minLength: 0)
                stepButton("chevron.right", "Day after", enabled: day < log.today) { step(1) }
            }
            if entries.isEmpty {
                Text("Nothing logged in healthOS on this day.").font(.app(size: 14, relativeTo: .subheadline)).foregroundStyle(Palette.ink3)
                    .padding(.vertical, 8)
            } else {
                FoodEntryList(entries: entries, mode: log.mode, units: units)
            }
            let sum = FoodText.amounts(FoodText.addUp(entries), units: units)
            if !entries.isEmpty, log.mode != .none, !sum.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Logged here").mutedSmall()
                    Text(sum).font(.app(size: 14, relativeTo: .subheadline)).foregroundStyle(Palette.ink)
                }
                .padding(.top, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) { Rectangle().fill(Palette.border).frame(height: 1) }
                .accessibilityElement(children: .combine)
            }
            if let counted, !entries.isEmpty, counted != "healthOS" {
                Text("This day's totals on the other tabs come from \(counted). When two apps log the same day, one app's totals count and the other's aren't added in, because apps copy each other's food through Apple Health. You can choose which app counts on the Macros tab.")
                    .mutedSmall()
            }
            // Only the iPhone writes to Apple Health.
            Text(log.mode == .none
                 ? "You chose to see no amounts, so what you log here isn't saved to Apple Health."
                 : "Food you log on this iPhone is saved to Apple Health too, with only the amounts you see. healthOS doesn't count it twice.")
                .mutedSmall()
        }
        .card()
    }

    private func stepButton(_ symbol: String, _ name: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.footnote.weight(.semibold))
                .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                .foregroundStyle(Palette.ink2)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(name)
    }
}

// MARK: - Entries

/// A day's entries, a hairline between each (.food-entries).
struct FoodEntryList: View {
    let entries: [FoodEntry]
    let mode: NutritionMode
    let units: Units

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { i, e in
                FoodEntryRow(entry: e, mode: mode, units: units)
                    .overlay(alignment: .top) { if i > 0 { Rectangle().fill(Palette.border).frame(height: 1) } }
            }
        }
    }
}

/// One entry (EntryRow): when, what and how much, and its Edit and Delete. Delete asks once ("Delete it?") for four
/// seconds, as on the web.
struct FoodEntryRow: View {
    let entry: FoodEntry
    let mode: NutritionMode
    let units: Units
    @Environment(Dashboard.self) private var dashboard
    @Environment(\.dynamicTypeSize) private var typeSize
    /// The time's column: the web's 44 at the usual size, growing with the time's own text.
    @ScaledMetric(relativeTo: .caption) private var timeColumn: CGFloat = 44
    /// The page's open editors (above the open Duo's panes, P4), or nil: this row keeps its own.
    @Environment(\.foodEntryEdits) private var edits
    @State private var ownDraft: FoodEntryDraft?
    @State private var confirming = false
    @State private var error: String?

    /// The open editor's typing; nil while it's closed.
    private var draft: FoodEntryDraft? {
        if let edits { return edits.open[entry.id] }
        return ownDraft
    }

    private var editing: Bool { draft != nil }

    private func setDraft(_ new: FoodEntryDraft?) {
        if let edits { edits.open[entry.id] = new } else { ownDraft = new }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    time
                    text
                    actions
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    // On one line at every size below the accessibility ones ("08:05", never "08:0" over "5"), in a
                    // column that grows with it, so the names still line up.
                    time.fixedSize().frame(minWidth: timeColumn, alignment: .leading)
                    text.frame(maxWidth: .infinity, alignment: .leading)
                    actions
                }
            }
            if let error { NoteBad(error, size: 12) }
            if let draft { FoodEntryEditor(entry: entry, mode: mode, units: units, draft: draft) { setDraft(nil) } }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
        .task(id: confirming) {
            guard confirming else { return }
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { confirming = false }
        }
    }

    private var time: some View {
        Text(entry.time).mutedSmall().accessibilityLabel("At \(entry.time)")
    }

    private var text: some View {
        let line = FoodText.amounts(entry.values, units: units)
        let detail = FoodText.detail(entry)
        return VStack(alignment: .leading, spacing: 2) {
            Text(entry.name).font(.app(size: 14, weight: .medium, relativeTo: .subheadline)).foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
            if !detail.isEmpty { Text(detail).mutedSmall() }
            if !line.isEmpty { Text(line).font(.app(size: 12, relativeTo: .caption)).foregroundStyle(Palette.ink).fixedSize(horizontal: false, vertical: true) }
        }
        .accessibilityElement(children: .combine)
    }

    private var actions: some View {
        HStack(spacing: 2) {
            Button(editing ? "Close" : "Edit") { setDraft(editing ? nil : FoodEntryDraft(entry: entry, mode: mode, units: units)) }
                .buttonStyle(.quietText(size: 12))
                .accessibilityLabel(editing ? "Close" : "Edit \(entry.name)")
            Button(confirming ? "Delete it?" : "Delete", action: remove)
                .buttonStyle(.quietText(size: 12))
                .accessibilityLabel(confirming ? "Delete \(entry.name)? Press again to delete" : "Delete \(entry.name)")
        }
    }

    private func remove() {
        guard confirming else { return confirming = true }
        error = nil
        Task {
            do {
                try await dashboard.deleteFood(entry)
            } catch {
                guard !APIClient.isCancellation(error) else { return }
                self.error = error.foodMessage
            }
        }
    }
}

/// Fields side by side where they fit (.food-fields), two to a row at a phone's width as on the web, one at the largest text sizes.
struct FoodFields<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        LazyVGrid(columns: typeSize.isAccessibilitySize ? [GridItem(.flexible())] : [GridItem(.adaptive(minimum: 140), spacing: 10, alignment: .bottomLeading)],
                  alignment: .leading, spacing: 10) {
            content
        }
    }
}

/// One labelled field.
struct FoodLabeled<Field: View>: View {
    let label: String
    @ViewBuilder var field: Field

    init(_ label: String, @ViewBuilder field: () -> Field) {
        self.label = label
        self.field = field()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            FieldLabel(label)
            field
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A clock time in the person's time zone (an entry's "HH:MM"), as a compact picker.
struct FoodTimePicker: View {
    let label: String
    @Binding var time: String
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        let zone = dashboard.timeZone
        DatePicker(label, selection: Binding(get: { FoodBody.date(forTime: time, in: zone) }, set: { time = FoodBody.time($0, in: zone) }),
                   displayedComponents: .hourAndMinute)
            .labelsHidden()
            .environment(\.timeZone, zone)
            .accessibilityLabel(label)
    }
}

/// "Today at" and the time: side by side, or the words over the picker where they don't fit, never a word broken.
struct FoodWhenPicker: View {
    let label: String
    @Binding var time: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                Text(label).mutedSmall()
                FoodTimePicker(label: "Time", time: $time)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(label).mutedSmall()
                FoodTimePicker(label: "Time", time: $time)
            }
        }
    }
}

/// Name, time, how many, and the amounts this person sees (EntryEditor). Only what changed is sent.
struct FoodEntryEditor: View {
    let entry: FoodEntry
    let mode: NutritionMode
    let units: Units
    /// What's typed, held by the row's page (FoodEntryEdits) so a fold that swaps the open Duo's panes keeps it.
    @Bindable var draft: FoodEntryDraft
    let onDone: () -> Void
    @Environment(Dashboard.self) private var dashboard

    private var name: String { get { draft.name } nonmutating set { draft.name = newValue } }
    private var time: String { get { draft.time } nonmutating set { draft.time = newValue } }
    private var quantity: String { get { draft.quantity } nonmutating set { draft.quantity = newValue } }
    private var typed: [String: String] { get { draft.typed } nonmutating set { draft.typed = newValue } }
    private var busy: Bool { get { draft.busy } nonmutating set { draft.busy = newValue } }
    private var error: String? { get { draft.error } nonmutating set { draft.error = newValue } }

    var body: some View {
        let fields = FoodField.typed(mode)
        VStack(alignment: .leading, spacing: 10) {
            FoodLabeled("Name") {
                TextField("Name", text: $draft.name).foodInput().onChange(of: name) { _, v in if v.count > 100 { name = String(v.prefix(100)) } }
                    .accessibilityLabel("Name").accessibilityIdentifier("editName")
            }
            FoodFields {
                FoodLabeled("Time") { FoodTimePicker(label: "Time", time: $draft.time) }
                FoodLabeled("How many \(entry.portion.isEmpty ? "" : "(\(entry.portion))")") {
                    TextField("1", text: $draft.quantity).keyboardType(.decimalPad).foodInput()
                        .accessibilityLabel("How many").accessibilityIdentifier("editQuantity")
                }
                ForEach(fields) { f in
                    FoodLabeled("\(f.label) (\(f.unit(units)))") {
                        TextField("–", text: Binding(get: { typed[f.key] ?? "" }, set: { typed[f.key] = $0 })).keyboardType(.decimalPad).foodInput()
                            .accessibilityLabel("\(f.label) in \(f.unit(units))")
                    }
                }
            }
            if !fields.isEmpty { Text("Amounts are for the whole entry. Changing only how many scales them all.").mutedSmall() }
            if let error { NoteBad(error, size: 12) }
            HStack(spacing: 8) {
                Button(busy ? "Saving…" : "Save") { save(fields) }
                    .buttonStyle(.accentPill(size: .compact))
                    .disabled(busy)
                    .accessibilityIdentifier("saveEntry")
                Button("Cancel", action: onDone).buttonStyle(.quietText)
            }
        }
        .padding(12)
        .background(Palette.surface2.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func save(_ fields: [FoodField]) {
        do {
            guard let body = try FoodBody.patch(entry, name: name, time: time, quantity: foodQuantity(quantity), typed: typed, fields: fields, units: units) else {
                return onDone()
            }
            busy = true
            error = nil
            Task {
                do {
                    try await dashboard.changeFood(entry, body)
                    onDone()
                } catch {
                    if !APIClient.isCancellation(error) { self.error = error.foodMessage }
                }
                busy = false
            }
        } catch {
            self.error = error.foodMessage
        }
    }
}

// MARK: - Adding

enum FoodAddMode: String, CaseIterable, Identifiable {
    // "Estimate" where the web says "Photo or words": four segments leave a phone too little room for it. Scan is the
    // iPhone's own (VisionKit's barcode reader).
    case search = "Search", scan = "Scan", estimate = "Estimate", quick = "Quick add"
    var id: String { rawValue }

    /// No estimate where McFly can't (can.estimate), no quick add where amounts are hidden.
    static func available(_ log: FoodLog) -> [FoodAddMode] {
        allCases.filter { m in
            switch m {
            case .estimate: log.can.estimate
            case .quick: log.mode != .none
            default: true
            }
        }
    }
}

/// The Log's "Add food or drink" (AddFood): when, water in one tap, then the other ways in. An estimate waiting to be
/// checked takes its place until it's saved or discarded.
private struct FoodAddCard: View {
    let log: FoodLog
    let date: String
    let units: Units
    /// What's chosen, typed and found, held by the Log's page above the open Duo's panes (P4).
    let state: FoodAddState
    private var s: FoodAddState { state }
    @Environment(Dashboard.self) private var dashboard
    @State private var tick = 0

    private var mode: FoodAddMode { get { s.mode } nonmutating set { s.mode = newValue } }
    /// A time the person picked; nil: now on today (worked out when they add), midday on a past day.
    private var picked: String? { get { s.picked } nonmutating set { s.picked = newValue } }
    /// McFly's note on what it assumed, kept while its estimate is reviewed (it isn't stored with the drafts).
    private var note: String { get { s.note } nonmutating set { s.note = newValue } }

    var body: some View {
        let modes = FoodAddMode.available(log)
        let current = modes.contains(mode) ? mode : .search
        VStack(alignment: .leading, spacing: 12) {
            NutritionFlow(spacing: 12, rowSpacing: 8) {
                Text("Add food or drink")
                    .font(.app(.headline, weight: .medium)).foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if log.drafts.isEmpty {
                    FoodWhenPicker(label: "\(Fmt.relativeDay(date, today: log.today)) at", time: Binding(get: { picked ?? defaultTime }, set: { picked = $0 }))
                }
            }
            if !log.drafts.isEmpty {
                FoodLogReview(review: s.review(batch: log.draftBatch ?? "", drafts: log.drafts), note: note, mode: log.mode, units: units)
                    .id(log.drafts.map(\.id).joined(separator: ","))
            } else {
                if log.mode != .none { FoodWaterButtons(when: when, units: units, state: s.water) }
                if modes.count > 1 {
                    Picker("How to add", selection: Bindable(s).mode) {
                        ForEach(modes) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("addModes")
                }
                switch current {
                case .search: FoodSearchPanel(when: when, units: units, usda: log.can.usda, state: s.search)
                case .scan: FoodScanPanel(when: when, units: units, quick: modes.contains(.quick), state: s.scan) { mode = .quick }
                case .estimate: FoodEstimatePanel(when: when, can: log.can, state: s.estimate) { note = $0 }
                case .quick: FoodQuickPanel(when: when, mode: log.mode, units: units, state: s.quick)
                }
            }
        }
        .card()
        .onChange(of: date) { _, _ in picked = nil }
        // "Now" moves on while the card is open.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                tick += 1
            }
        }
    }

    private var defaultTime: String {
        _ = tick
        return date == log.today ? FoodBody.time(Date(), in: dashboard.timeZone) : "12:00"
    }

    private func when() -> FoodMoment {
        FoodMoment(date: date, time: picked ?? (date == log.today ? FoodBody.time(Date(), in: dashboard.timeZone) : "12:00"))
    }
}

/// Water in one tap (WaterButtons): a glass or a bottle in the person's units, logged as a quick entry. Any other
/// amount goes through typed amounts.
struct FoodWaterButtons: View {
    let when: () -> FoodMoment
    let units: Units
    /// What's typed and found: the page's (above the open Duo's panes, P4), or this view's own.
    var state: FoodWaterState? = nil
    @State private var own = FoodWaterState()
    private var s: FoodWaterState { state ?? own }
    @Environment(Dashboard.self) private var dashboard

    private var busy: Bool { get { s.busy } nonmutating set { s.busy = newValue } }
    private var done: String? { get { s.done } nonmutating set { s.done = newValue } }
    private var error: String? { get { s.error } nonmutating set { s.error = newValue } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Water").mutedSmall()
            NutritionFlow(spacing: 8, rowSpacing: 8) {
                ForEach(FoodWater.choices(units)) { w in
                    Button("+ \(w.label)") { add(w) }
                        .buttonStyle(.chip)
                        .disabled(busy)
                        .accessibilityLabel("Add \(w.label)")
                        .accessibilityIdentifier("water-\(Int(w.ml.rounded()))")
                }
            }
            if let done { Text(done).font(.app(size: 12, relativeTo: .caption)).foregroundStyle(Palette.ink) }
            if let error { NoteBad(error, size: 12) }
        }
        .task(id: done) {
            guard done != nil else { return }
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { done = nil }
        }
    }

    private func add(_ w: FoodWater) {
        busy = true
        error = nil
        let at = when()
        Task {
            do {
                _ = try await dashboard.addFood(w.body(date: at.date, time: at.time))
                done = w.added
                AccessibilityNotification.Announcement(w.added).post()
            } catch {
                if !APIClient.isCancellation(error) { self.error = error.foodMessage }
            }
            busy = false
        }
    }
}

/// Search foods, or type a barcode (SearchFood): USDA (when the server has its key) and Open Food Facts. Digits are
/// looked up as a barcode, as the server decides. `scan` adds the iPhone's barcode reader where it has a camera.
struct FoodSearchPanel: View {
    let when: () -> FoodMoment
    let units: Units
    let usda: Bool
    var scan = false
    /// What's typed and found: the page's (above the open Duo's panes, P4), or this view's own.
    var state: FoodSearchState? = nil
    @State private var own = FoodSearchState()
    private var s: FoodSearchState { state ?? own }
    @Environment(Dashboard.self) private var dashboard
    @Environment(\.dynamicTypeSize) private var typeSize

    private var canScan: Bool { scan && DataScannerViewController.isSupported && DataScannerViewController.isAvailable }

    private var query: String { get { s.query } nonmutating set { s.query = newValue } }
    private var found: FoodSearch? { get { s.found } nonmutating set { s.found = newValue } }
    private var barcode: Bool { get { s.barcode } nonmutating set { s.barcode = newValue } }
    private var busy: Bool { get { s.busy } nonmutating set { s.busy = newValue } }
    private var error: String? { get { s.error } nonmutating set { s.error = newValue } }
    private var open: String? { get { s.open } nonmutating set { s.open = newValue } }
    private var added: String? { get { s.added } nonmutating set { s.added = newValue } }
    private var scanning: Bool { get { s.scanning } nonmutating set { s.scanning = newValue } }
    private var lastScanned: String? { get { s.lastScanned } nonmutating set { s.lastScanned = newValue } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            let field = TextField("Search foods, or type a barcode", text: Bindable(s).query)
                .submitLabel(.search)
                .onSubmit(search)
                .autocorrectionDisabled()
                .foodInput()
                .onChange(of: query) { _, v in if v.count > 100 { query = String(v.prefix(100)) } }
                .accessibilityLabel("Search foods, or type a barcode")
                .accessibilityIdentifier("foodQuery")
            let button = Button(action: search) { PillLabel(busy ? "Searching…" : "Search") }
                .buttonStyle(.accentPill(size: .compact))
                .disabled(busy || query.trimmingCharacters(in: .whitespaces).count < 2)
                .accessibilityIdentifier("foodSearch")
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) { field; button }
            } else {
                HStack(spacing: 8) { field; button }
            }
            if canScan {
                Button(scanning ? "Stop scanning" : "Scan a barcode") { scanning.toggle() }
                    .buttonStyle(.quietPill(size: .compact))
                if scanning {
                    FoodBarcodeReader { code in
                        guard code != lastScanned, !busy else { return }
                        lastScanned = code
                        lookUp(code)
                    }
                }
            }
            if let error { NoteBad(error, size: 12) }
            if let added { Text("Added \(added).").font(.app(size: 12, relativeTo: .caption)).foregroundStyle(Palette.ink) }
            if let found {
                ForEach(found.notes, id: \.self) { Text($0).mutedSmall() }
                if found.results.isEmpty {
                    Text(barcode ? "That barcode isn’t in \(usda ? "USDA FoodData Central or " : "")Open Food Facts. Quick add from the label instead."
                                 : "Nothing found. Try fewer or other words.")
                        .font(.app(size: 14, relativeTo: .subheadline)).foregroundStyle(Palette.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    FoodResultsList(results: found.results, open: Bindable(s).open, picks: s.picks, when: when, units: units, barcode: barcode) { name in
                        added = name
                        open = nil
                    }
                }
            }
            Text("Foods from \(usda ? "USDA FoodData Central and " : "")Open Food Facts. healthOS's server sends them your search, never your name.")
                .mutedSmall()
        }
    }

    private func search() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2, !busy else { return }
        busy = true
        error = nil
        added = nil
        let isBarcode = q.range(of: #"^[\d\s-]{8,}$"#, options: .regularExpression) != nil
        Task {
            do {
                let r = try await dashboard.searchFoods(query)
                found = r
                barcode = isBarcode
                open = r.results.count == 1 ? r.results[0].ref : nil
            } catch {
                if !APIClient.isCancellation(error) { self.error = error.foodMessage }
            }
            busy = false
        }
    }

    private func lookUp(_ code: String) {
        busy = true
        error = nil
        added = nil
        query = code
        Task {
            do {
                let r = try await dashboard.barcode(code)
                found = r
                barcode = true
                open = r.results.count == 1 ? r.results[0].ref : nil
                scanning = false
            } catch {
                if !APIClient.isCancellation(error) { self.error = error.foodMessage }
            }
            busy = false
        }
    }
}

/// Foods found, each opening in place to pick a portion and how many (.food-results).
private struct FoodResultsList: View {
    let results: [FoodResult]
    @Binding var open: String?
    /// Each food's portion and how many, kept by the panel's state.
    let picks: FoodResultPicks
    let when: () -> FoodMoment
    let units: Units
    let barcode: Bool
    let onAdded: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(results.enumerated()), id: \.element.id) { i, r in
                FoodResultRow(food: r, open: open == r.ref, toggle: { open = open == r.ref ? nil : r.ref }, when: when, units: units,
                              barcode: barcode, state: picks.pick(r.id), onAdded: onAdded)
                    .overlay(alignment: .top) { if i > 0 { Rectangle().fill(Palette.border).frame(height: 1) } }
            }
        }
    }
}

/// One database food (ResultRow): which portion, how many, what that comes to (only the amounts the setting shows),
/// then Add.
private struct FoodResultRow: View {
    let food: FoodResult
    let open: Bool
    let toggle: () -> Void
    let when: () -> FoodMoment
    let units: Units
    let barcode: Bool
    /// What's typed and found: the page's (above the open Duo's panes, P4), or this view's own.
    var state: FoodResultPick? = nil
    @State private var own = FoodResultPick()
    private var s: FoodResultPick { state ?? own }
    let onAdded: (String) -> Void
    @Environment(Dashboard.self) private var dashboard
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var portion: Int { get { s.portion } nonmutating set { s.portion = newValue } }
    private var quantity: String { get { s.quantity } nonmutating set { s.quantity = newValue } }
    private var busy: Bool { get { s.busy } nonmutating set { s.busy = newValue } }
    private var error: String? { get { s.error } nonmutating set { s.error = newValue } }

    var body: some View {
        let q = FoodText.number(quantity)
        let values = food.portions.indices.contains(portion) ? food.portions[portion].values : [:]
        let preview = q.map { $0 > 0 ? FoodText.amounts(FoodText.scaled(values, by: $0), units: units) : "" } ?? ""
        VStack(alignment: .leading, spacing: 10) {
            Button(action: toggle) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(food.name).font(.app(size: 14, weight: .medium, relativeTo: .subheadline)).foregroundStyle(Palette.ink)
                            .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                        Text([food.brand, food.source == "usda" ? "USDA" : "Open Food Facts"].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                            .mutedSmall().multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Palette.ink3)
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: open)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(open ? .isSelected : [])
            .accessibilityHint(open ? "" : "Opens it to choose a portion")
            if open {
                VStack(alignment: .leading, spacing: 10) {
                    FoodLabeled("Portion") {
                        Picker("Portion", selection: Bindable(s).portion) {
                            ForEach(Array(food.portions.enumerated()), id: \.offset) { i, p in Text(p.label).tag(i) }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .tint(Palette.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .foodInput(raised: true)
                        .accessibilityLabel("Portion")
                    }
                    FoodFields {
                        FoodLabeled("How many") {
                            TextField("1", text: Bindable(s).quantity).keyboardType(.decimalPad).foodInput(raised: true)
                                .accessibilityLabel("How many").accessibilityIdentifier("pickQuantity")
                        }
                    }
                    if !preview.isEmpty { Text(preview).font(.app(size: 12, relativeTo: .caption)).foregroundStyle(Palette.ink) }
                    if let error { NoteBad(error, size: 12) }
                    Button(busy ? "Adding…" : "Add") { add(q) }
                        .buttonStyle(.accentPill(size: .compact))
                        .disabled(busy || !((q ?? 0) > 0) || food.portions.isEmpty)
                        .accessibilityLabel("Add \(food.name)")
                        .accessibilityIdentifier("pickAdd")
                }
                .padding(10)
                .background(Palette.surface2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .padding(.vertical, 10)
    }

    private func add(_ q: Double?) {
        guard let q, q > 0 else { return }
        busy = true
        error = nil
        let at = when()
        Task {
            do {
                // The server rounds how many to hundredths, and refuses more than 50 in its own words.
                let e = try await dashboard.addFood(FoodBody.food(ref: food.ref, portionIndex: portion, quantity: q, barcode: barcode, date: at.date, time: at.time))
                onAdded(e.name)
                AccessibilityNotification.Announcement("Added \(e.name).").post()
            } catch {
                if !APIClient.isCancellation(error) { self.error = error.foodMessage }
            }
            busy = false
        }
    }
}

/// The iPhone's barcode reader in a card (§2.8): at most 480 wide, centred in its card, so a wide sheet or column never
/// makes it a thin strip; 220 tall. It starts reading again whenever its size changes (a fold, an unfold) and when it
/// comes back on screen: BarcodeScanner (Components/) starts once, as it's made, so here it's made anew then.
private struct FoodBarcodeReader: View {
    let onCode: (String) -> Void
    static let widest: CGFloat = 480
    @State private var size: CGSize?
    @State private var run = 0
    @State private var shown = false

    var body: some View {
        BarcodeScanner(onCode: onCode)
            .id(run)
            .frame(maxWidth: Self.widest)
            .frame(height: 220)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGSize.self, of: { $0.size }) { new in
                if let size, size != new { run += 1 }
                size = new
            }
            .onAppear {
                if shown { run += 1 }
                shown = true
            }
            .accessibilityLabel("Barcode reader")
    }
}

/// A barcode: the iPhone's reader where it has a camera, or the numbers typed (also when the camera is off).
private struct FoodScanPanel: View {
    let when: () -> FoodMoment
    let units: Units
    let quick: Bool
    /// What's typed and found: the page's (above the open Duo's panes, P4), or this view's own.
    var state: FoodScanState? = nil
    @State private var own = FoodScanState()
    private var s: FoodScanState { state ?? own }
    let toQuick: () -> Void
    @Environment(Dashboard.self) private var dashboard

    private var canScan: Bool { DataScannerViewController.isSupported && DataScannerViewController.isAvailable }

    private var code: String { get { s.code } nonmutating set { s.code = newValue } }
    private var found: FoodSearch? { get { s.found } nonmutating set { s.found = newValue } }
    private var busy: Bool { get { s.busy } nonmutating set { s.busy = newValue } }
    private var error: String? { get { s.error } nonmutating set { s.error = newValue } }
    private var lastScanned: String? { get { s.lastScanned } nonmutating set { s.lastScanned = newValue } }
    private var open: String? { get { s.open } nonmutating set { s.open = newValue } }
    private var added: String? { get { s.added } nonmutating set { s.added = newValue } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if canScan {
                FoodBarcodeReader { scanned in
                    guard scanned != lastScanned, !busy else { return }
                    lastScanned = scanned
                    code = scanned
                    lookUp()
                }
            } else {
                Text("Scanning needs the camera. Type the numbers under the barcode instead.").font(.app(size: 14, relativeTo: .subheadline)).foregroundStyle(Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                TextField("Barcode", text: Bindable(s).code).keyboardType(.numberPad).foodInput().accessibilityLabel("Barcode").accessibilityIdentifier("barcodeField")
                Button(action: lookUp) { PillLabel(busy ? "Looking up…" : "Look up") }
                    .buttonStyle(.accentPill(size: .compact))
                    .disabled(busy || code.filter(\.isNumber).count < 8)
                    .accessibilityIdentifier("barcodeLookUp")
            }
            if let error { NoteBad(error, size: 12) }
            if let added { Text("Added \(added).").font(.app(size: 12, relativeTo: .caption)).foregroundStyle(Palette.ink) }
            if let found {
                ForEach(found.notes, id: \.self) { Text($0).mutedSmall() }
                if found.results.isEmpty {
                    Text("That barcode isn’t in USDA FoodData Central or Open Food Facts." + (quick ? " Quick add from the label instead." : ""))
                        .font(.app(size: 14, relativeTo: .subheadline)).foregroundStyle(Palette.ink3).fixedSize(horizontal: false, vertical: true)
                    if quick { Button("Quick add from the label", action: toQuick).buttonStyle(.quietPill(size: .compact)) }
                } else {
                    FoodResultsList(results: found.results, open: Bindable(s).open, picks: s.picks, when: when, units: units, barcode: true) { name in
                        added = name
                        open = nil
                    }
                }
            }
            Text("Barcodes are looked up in Open Food Facts, then USDA FoodData Central. healthOS's server sends them the code, never your name.")
                .mutedSmall()
        }
    }

    private func lookUp() {
        let digits = code.filter(\.isNumber)
        guard digits.count >= 8 else { return }
        busy = true
        error = nil
        added = nil
        Task {
            do {
                let r = try await dashboard.barcode(digits)
                found = r
                open = r.results.count == 1 ? r.results[0].ref : nil
            } catch {
                if !APIClient.isCancellation(error) { self.error = error.foodMessage }
            }
            busy = false
        }
    }
}

/// McFly's estimate from a photo, a few words or both (EstimateFood): a draft to check, never saved on its own.
private struct FoodEstimatePanel: View {
    let when: () -> FoodMoment
    let can: FoodLog.Can
    /// What's typed and attached, held by the Log's page above the open Duo's panes (P4), which presents the photo picker.
    let state: FoodEstimateState
    private var s: FoodEstimateState { state }
    let onNote: (String) -> Void
    @Environment(Dashboard.self) private var dashboard

    private var description: String { get { s.description } nonmutating set { s.description = newValue } }
    private var photo: AttachedPhoto? { get { s.photo } nonmutating set { s.photo = newValue } }
    private var choosing: Bool { get { s.choosing } nonmutating set { s.choosing = newValue } }
    private var pick: MealPhotoPick? { get { s.pick } nonmutating set { s.pick = newValue } }
    private var busy: Bool { get { s.busy } nonmutating set { s.busy = newValue } }
    private var error: String? { get { s.error } nonmutating set { s.error = newValue } }
    private var note: String? { get { s.note } nonmutating set { s.note = newValue } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("What did you have? For example: pasta with pesto, cooked in olive oil, about half a plate.", text: Bindable(s).description, axis: .vertical)
                .lineLimit(3...8)
                .foodInput()
                .onChange(of: description) { _, v in
                    let capped = NutritionChat.prefix(v, utf16: NutritionChat.maxDescription)
                    if capped != v { description = capped }
                }
                .accessibilityLabel("What did you have?")
                .accessibilityIdentifier("estimateText")
            if let photo {
                HStack(spacing: 10) {
                    Image(uiImage: photo.preview).resizable().scaledToFill().frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .accessibilityLabel("Your photo, as it will be sent")
                    Button("Remove photo") { self.photo = nil }.buttonStyle(.quietText)
                }
            } else {
                Button("Add a photo") { choosing = true }.buttonStyle(.quietPill(size: .compact))
                    // The question on its button (a popover on it at regular width, P10).
                    .mealPhotoChoice(isPresented: Bindable(s).choosing, pick: Bindable(s).pick)
            }
            Text("\(NutritionChat.estimatePrivacy(can)) Estimates are rough, often a third off on calories, so you check them before anything is saved. A few words about oil, sauces or portion size help most.")
                .mutedSmall()
            if let note { Text(note).font(.app(size: 14, relativeTo: .subheadline)).foregroundStyle(Palette.ink3).fixedSize(horizontal: false, vertical: true) }
            if let error { NoteBad(error, size: 12) }
            Button(action: estimate) { PillLabel(busy ? "Estimating…" : "Estimate") }
                .buttonStyle(.accentPill(size: .compact))
                .disabled(busy || (description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && photo == nil))
                .accessibilityIdentifier("estimate")
        }
        // What "Add a photo" opens, Photos or the camera, is presented by the Log's page, above the panes (P4).
    }

    private func estimate() {
        busy = true
        error = nil
        note = nil
        let at = when()
        Task {
            do {
                let r = try await dashboard.estimateFood(FoodBody.estimate(description: NutritionChat.words(description), jpeg: photo?.jpeg, date: at.date, time: at.time))
                if r.drafts.isEmpty {
                    note = r.note.flatMap { $0.isEmpty ? nil : $0 } ?? "McFly didn't find food or drink to estimate."
                } else {
                    onNote(r.note ?? "")
                    description = ""
                    photo = nil
                }
                await dashboard.estimated()
            } catch {
                if !APIClient.isCancellation(error) { self.error = error.foodMessage }
            }
            busy = false
        }
    }
}

/// McFly's draft on the Log (EstimateReview): rename, change how many, or drop items, then save what's left.
private struct FoodLogReview: View {
    let note: String
    let mode: NutritionMode
    let units: Units
    @Environment(Dashboard.self) private var dashboard
    /// The page's review of these drafts (FoodAddState), so a fold that swaps the open Duo's panes keeps what's typed.
    let review: EstimateReview

    init(review: EstimateReview, note: String, mode: NutritionMode, units: Units) {
        self.review = review
        self.note = note
        self.mode = mode
        self.units = units
    }

    var body: some View {
        let byID = review.byID
        VStack(alignment: .leading, spacing: 10) {
            (Text("McFly's estimate").font(.app(size: 12, weight: .semibold, relativeTo: .caption)).foregroundStyle(Palette.ink)
             + Text(" for \(review.drafts.first?.time ?? ""). Check it, then save. Nothing counts until you do.").font(.app(size: 12, relativeTo: .caption)).foregroundStyle(Palette.ink3))
                .fixedSize(horizontal: false, vertical: true)
            if !note.isEmpty { NutriNote(text: note) }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(review.kept.enumerated()), id: \.element.id) { i, k in
                    let d = byID[k.id]
                    VStack(alignment: .leading, spacing: 8) {
                        FoodLabeled(d?.portion.isEmpty == false ? d!.portion : "Item") {
                            TextField("Name", text: review.binding(k.id, \.name)).foodInput().accessibilityLabel("Name")
                        }
                        FoodFields {
                            FoodLabeled("How many") {
                                TextField("1", text: review.binding(k.id, \.quantity)).keyboardType(.decimalPad).foodInput().accessibilityLabel("How many of \(k.name)")
                            }
                        }
                        Button("Leave out") { review.leaveOut(k.id) }
                            .buttonStyle(.quietText(size: 12))
                            .accessibilityLabel("Leave out \(k.name)")
                        let line = review.line(k, mode: mode, units: units)
                        if !line.isEmpty { Text(line).font(.app(size: 12, relativeTo: .caption)).foregroundStyle(Palette.ink) }
                    }
                    .padding(.vertical, 10)
                    .overlay(alignment: .top) { if i > 0 { Rectangle().fill(Palette.border).frame(height: 1) } }
                }
            }
            if let error = review.error { NoteBad(error, size: 12) }
            HStack(spacing: 8) {
                Button {
                    Task { _ = await review.save(.dashboard(dashboard)) }
                } label: { PillLabel(review.saveTitle) }
                .buttonStyle(.accentPill(size: .compact))
                .disabled(review.busy || review.kept.isEmpty)
                .accessibilityIdentifier("saveDrafts")
                Button("Discard") { Task { _ = await review.discard(.dashboard(dashboard)) } }
                    .buttonStyle(.quietText)
                    .disabled(review.busy)
            }
            Text("You can fix any amount after saving, with Edit.").mutedSmall()
        }
    }
}

/// McFly's note on what it assumed (.nutri-note, .food-note).
struct NutriNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.app(size: 13, relativeTo: .footnote))
            .foregroundStyle(Palette.ink2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Amounts typed in (QuickAdd): an optional name, calories (only when they're shown), protein, carbs, fat and water.
struct FoodQuickPanel: View {
    let when: () -> FoodMoment
    let mode: NutritionMode
    let units: Units
    /// What's typed and found: the page's (above the open Duo's panes, P4), or this view's own.
    var state: FoodQuickState? = nil
    @State private var own = FoodQuickState()
    private var s: FoodQuickState { state ?? own }
    @Environment(Dashboard.self) private var dashboard

    private var name: String { get { s.name } nonmutating set { s.name = newValue } }
    private var typed: [String: String] { get { s.typed } nonmutating set { s.typed = newValue } }
    private var busy: Bool { get { s.busy } nonmutating set { s.busy = newValue } }
    private var error: String? { get { s.error } nonmutating set { s.error = newValue } }
    private var added: String? { get { s.added } nonmutating set { s.added = newValue } }

    var body: some View {
        let fields = FoodField.typed(mode)
        VStack(alignment: .leading, spacing: 10) {
            FoodLabeled("Name (optional)") {
                TextField("Quick add", text: Bindable(s).name).foodInput()
                    .onChange(of: name) { _, v in if v.count > 100 { name = String(v.prefix(100)) } }
                    .accessibilityLabel("Name (optional)").accessibilityIdentifier("quickName")
            }
            FoodFields {
                ForEach(fields) { f in
                    FoodLabeled("\(f.label) (\(f.unit(units)))") {
                        TextField("", text: Binding(get: { typed[f.key] ?? "" }, set: { typed[f.key] = $0 })).keyboardType(.decimalPad).foodInput()
                            .accessibilityLabel("\(f.label) in \(f.unit(units))")
                            .accessibilityIdentifier("quick-\(f.key)")
                    }
                }
            }
            if let error { NoteBad(error, size: 12) }
            if let added { Text("Added \(added).").font(.app(size: 12, relativeTo: .caption)).foregroundStyle(Palette.ink) }
            Button(busy ? "Adding…" : "Add") { add(fields) }
                .buttonStyle(.accentPill(size: .compact))
                .disabled(busy)
                .accessibilityIdentifier("quickAdd")
        }
    }

    private func add(_ fields: [FoodField]) {
        var values: [String: Double] = [:]
        for f in fields {
            guard let v = f.amount(typed[f.key] ?? "", units: units) else { continue }
            guard v.isFinite, v >= 0 else { return error = "\(f.label) should be a number." }
            values[f.key] = v
        }
        guard !values.isEmpty else { return error = "Enter at least one amount." }
        busy = true
        error = nil
        let at = when()
        Task {
            do {
                let e = try await dashboard.addFood(FoodBody.quick(name: name, values: values, date: at.date, time: at.time))
                added = e.name
                AccessibilityNotification.Announcement("Added \(e.name).").post()
                name = ""
                typed = [:]
            } catch {
                if !APIClient.isCancellation(error) { self.error = error.foodMessage }
            }
            busy = false
        }
    }
}
