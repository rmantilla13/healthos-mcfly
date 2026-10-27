import Foundation
import Observation

// The Journal page's state (src/pages/Journal.tsx): the check-ins read, the draft and what a save or a delete did. It's
// all in memory, for the page on screen: never kept on disk, never logged, and gone with the page. The web keeps an
// unsaved draft in its tab (sessionStorage); the iPhone keeps it only while the page is open (privacy.html).

/// The page's words, as the web writes them (a test reads them in src/pages/Journal.tsx).
enum JournalWords {
    static let title = "How are you feeling today?"
    static let sub = "A few words, and a mood if you like. Only you can see your journal."
    static let opening = "Opening your private journal…"
    /// The web adds "Try Refresh." (its top bar's button); the iPhone has Try again under it, and pull to refresh.
    static let couldNotOpen = "Couldn't open your journal."
    static let tryAgain = "Try again"
    static let newCheckIn = "New check-in"
    static let moods = "How you feel, if you'd like to say"
    static let box = "Your check-in"
    static let placeholder = "A thought, a feeling, a little context."
    static let save = "Save check-in"
    static let saving = "Saving…"
    static let saved = "Saved. Only you can see this."
    static let stillHere = "Your check-in is still here."
    static let history = "Earlier check-ins"
    static let empty = "Your journal is empty. Write your first check-in above."
    static func noneRecent(_ days: Int) -> String { "No check-ins in the last \(days) days." }
    static let showEarlier = "Show earlier check-ins"
    static let loading = "Loading…"
    static let moreFailed = "Couldn't load your earlier check-ins. Try again."
    static let privacy = "Your journal is private. It isn't shared on the Family board, in peer comparisons, or with Ask McFly."
    static let deleteAll = "Delete all check-ins"
    static let deleteAllAsk = "Delete every check-in in your journal? This can’t be undone."
    static let edit = "Edit"
    static let delete = "Delete"
    static let saveChanges = "Save changes"
    static let cancel = "Cancel"
    static let writeAFew = "Write a few words, or delete the check-in instead."
    static func deleteAsk(_ when: String) -> String { "Delete the check-in from \(when)? It can’t be undone." }
    static func editLabel(_ when: String) -> String { "Edit the check-in from \(when)" }
    static func deleteLabel(_ when: String) -> String { "Delete the check-in from \(when)" }
    static func moodFor(_ when: String) -> String { "Mood for the check-in from \(when)" }
    static func boxFor(_ when: String) -> String { "The check-in from \(when)" }
    /// The iPhone's own: a server older than the journal (its catch-all 404) has none to show.
    static let notHere = "This server doesn't have a journal yet."
}

/// The web's rules for the words and the times a check-in shows.
enum JournalText {
    /// Past this many characters, the box says how many are left (COUNT_FROM).
    static let countFrom = 3500
    /// The first read: the last 90 days. "Show earlier check-ins" reads the rest, ten years, the server's most.
    static let recentDays = 90
    static let allDays = 3650

    /// A check-in's length as the server counts it (JavaScript's `.length`: UTF-16 units), so an emoji counts two.
    static func length(_ text: String) -> Int { text.utf16.count }

    /// The words cut to the server's limit (the web's maxLength), never through the middle of a character.
    static func clamp(_ text: String, to limit: Int = JournalLimits.maxChars) -> String {
        guard length(text) > limit else { return text }
        var out = ""
        var used = 0
        for character in text {
            let units = character.utf16.count
            if used + units > limit { break }
            out.append(character)
            used += units
        }
        return out
    }

    /// "500 characters left", once fewer than 500 are (nil before).
    static func left(_ text: String, locale: Locale = .current) -> String? {
        let left = JournalLimits.maxChars - length(text)
        guard left <= JournalLimits.maxChars - countFrom else { return nil }
        return "\(left.formatted(.number.locale(locale))) \(left == 1 ? "character" : "characters") left"
    }

    /// A kept HH:MM as this device writes times: "9:41 PM", or "21:41" (the device's 12- or 24-hour setting).
    static func clock(_ hhmm: String, locale: Locale = .autoupdatingCurrent) -> String {
        let parts = hhmm.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, let date = utc.date(from: DateComponents(year: 1970, month: 1, day: 1, hour: parts[0], minute: parts[1])) else { return hhmm }
        let format = DateFormatter()
        format.locale = locale
        format.timeZone = utc.timeZone
        format.dateStyle = .none
        format.timeStyle = .short
        return format.string(from: date)
    }

    /// Today, Yesterday, or "Mon, Oct 19" (with the year when it isn't this year), against the person's own today.
    static func day(_ date: String, today: String, locale: Locale = .autoupdatingCurrent) -> String {
        guard let d = parse(date), let t = parse(today) else { return date }
        let apart = utc.dateComponents([.day], from: d, to: t).day ?? 0
        if apart == 0 { return "Today" }
        if apart == 1 { return "Yesterday" }
        let format = DateFormatter()
        format.locale = locale
        format.timeZone = utc.timeZone
        format.setLocalizedDateFormatFromTemplate(date.prefix(4) == today.prefix(4) ? "EEEMMMd" : "EEEMMMdyyyy")
        return format.string(from: d)
    }

    /// How a check-in is named to VoiceOver and in its delete question: "today at 9:41 PM", "Mon, Oct 19 at 8:05 AM".
    static func when(day: String, clock: String) -> String {
        "\(day == "Today" || day == "Yesterday" ? day.lowercased() : day) at \(clock)"
    }

    /// "Friday 9:41 PM" in the person's own time zone (the device's when the server names none, or one it doesn't know).
    static func now(_ now: Date, timeZone: String?, locale: Locale = .autoupdatingCurrent) -> String {
        let zone = timeZone.flatMap(TimeZone.init(identifier:)) ?? .autoupdatingCurrent
        let weekday = DateFormatter()
        weekday.locale = locale
        weekday.timeZone = zone
        weekday.setLocalizedDateFormatFromTemplate("EEEE")
        let time = DateFormatter()
        time.locale = locale
        time.timeZone = zone
        time.dateStyle = .none
        time.timeStyle = .short
        return "\(weekday.string(from: now)) \(time.string(from: now))"
    }

    /// The check-ins by day, in the order they came (newest first).
    static func days(_ entries: [JournalEntry]) -> [(date: String, entries: [JournalEntry])] {
        var out: [(date: String, entries: [JournalEntry])] = []
        for entry in entries {
            if out.last?.date == entry.date { out[out.count - 1].entries.append(entry) } else { out.append((entry.date, [entry])) }
        }
        return out
    }

    /// Softer colours for the harder days, the app's sage for the good ones; the word always says which (MOOD_BADGE).
    static func tone(_ mood: Mood) -> Badge.Tone {
        switch mood {
        case .rough, .low: .peach
        case .okay: .muted
        case .good, .great: .sage
        }
    }

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private static func parse(_ date: String) -> Date? {
        let parts = date.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return utc.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}

/// A link to the Journal (Home's "Write a check-in": journal?new=1), applied once. The page is pushed with its route,
/// whose `new` asks for the composer the first time it shows; the last link stays on the dashboard after that, so a
/// Journal opened later from More (a route with no query) must not take it again. A link that comes while the page is
/// up (Home's card tapped again) is a request of its own, taken once by its id.
struct JournalLink {
    private(set) var handled: Int?
    private(set) var started = false

    /// The page's first showing: whether its route asks for the composer. The request already there is spent.
    mutating func start(new: Bool, current: RouteRequest?) -> Bool {
        guard !started else { return false }
        started = true
        handled = current?.id
        return new
    }

    /// A link to the Journal since: whether it asks for the composer, the first time it's seen.
    mutating func take(_ request: RouteRequest?) -> Bool {
        guard started, let request, request.id != handled else { return false }
        handled = request.id
        return request.route.page == .journal && request.route.query["new"] == "1"
    }
}

/// The check-ins on screen and what the page is doing with them. One person's, on one server: the page makes a new one
/// when either changes, and every answer goes through `fetchForThisSession`, so one that lands for someone else is
/// dropped.
@MainActor @Observable
final class JournalModel {
    /// The server's journal routes; tests put their own in.
    struct Calls {
        var read: @MainActor (Int) async throws -> JournalData?
        var add: @MainActor (String, Mood?) async throws -> JournalEntry
        var update: @MainActor (String, String, Mood?) async throws -> JournalEntry
        var delete: @MainActor (String) async throws -> Void
        var deleteAll: @MainActor () async throws -> Void

        @MainActor static func live(_ dashboard: Dashboard) -> Calls {
            Calls(
                read: { days in try await dashboard.fetchForThisSession { try await $0.journal(days: days) } },
                add: { text, mood in try await dashboard.fetchForThisSession { try await $0.addJournal(text: text, mood: mood) } },
                update: { id, text, mood in try await dashboard.fetchForThisSession { try await $0.updateJournal(id: id, text: text, mood: .some(mood)) } },
                delete: { id in try await dashboard.fetchForThisSession { try await $0.deleteJournal(id: id) } },
                deleteAll: { try await dashboard.fetchForThisSession { try await $0.deleteAllJournal() } })
        }
    }

    let calls: Calls

    /// What's read: kept on screen while earlier check-ins load, or if they fail to.
    private(set) var data: JournalData?
    /// The days asked for: 90, then 3650 after "Show earlier check-ins".
    private(set) var days = JournalText.recentDays
    /// `data` is the answer for `days` (false while earlier check-ins are asked for and not here yet).
    private(set) var current = false
    private(set) var loading = false
    /// The last read failed (a 500, offline): never "not on this server".
    private(set) var failed = false
    /// The server has no journal (an older one's catch-all 404).
    private(set) var missing = false
    @ObservationIgnored private var reads = 0

    /// The draft: memory only, cut to the server's limit as it's typed.
    private(set) var text = ""
    private(set) var mood: Mood?
    private(set) var saving = false
    private(set) var saved = false
    private(set) var saveError: String?
    private(set) var deleteAllError: String?

    init(calls: Calls) { self.calls = calls }

    // MARK: Reading

    /// Earlier check-ins asked for and not here yet: the button stays (Loading… meanwhile) until they come.
    var awaiting: Bool { days == JournalText.allDays && !current && data?.older == true }
    var moreFailed: Bool { awaiting && failed && !loading }
    var busyMore: Bool { awaiting && loading }
    var showsMore: Bool { data?.older == true && (days < JournalText.allDays || awaiting) }
    var groups: [(date: String, entries: [JournalEntry])] { JournalText.days(data?.entries ?? []) }
    /// Delete all shows once there's anything to delete.
    var hasAny: Bool { !(data?.entries.isEmpty ?? true) || data?.older == true }
    var emptyLine: String { data?.older == true ? JournalWords.noneRecent(JournalText.recentDays) : JournalWords.empty }

    /// Reads the check-ins for `days`. Only the latest read's answer is kept.
    func load() async {
        reads += 1
        let mine = reads
        let asked = days
        loading = true
        do {
            let answer = try await calls.read(asked)
            guard mine == reads else { return }
            loading = false
            failed = false
            guard let answer else {
                missing = true
                return
            }
            missing = false
            data = answer
            current = asked == days
            settle(answer.entries)
        } catch is CancellationError {
            // Someone else is here now: the page goes with the person.
            if mine == reads { loading = false }
        } catch {
            guard mine == reads else { return }
            loading = false
            failed = true
        }
    }

    /// "Show earlier check-ins": the rest of the journal, or the same again after it failed.
    func showEarlier() async {
        guard !busyMore else { return }
        if days < JournalText.allDays {
            days = JournalText.allDays
            current = false
        }
        await load()
    }

    // MARK: Writing

    func setText(_ text: String) {
        let kept = JournalText.clamp(text)
        guard kept != self.text else { return }
        saved = false
        self.text = kept
    }

    func setMood(_ mood: Mood?) {
        saved = false
        self.mood = mood
    }

    var canSave: Bool { !saving && !Self.trimmed(text).isEmpty }

    /// Saves the draft as a new check-in, dated now in the person's time zone by the server. On a failure the draft
    /// stays, and the message says so. True when it was saved.
    @discardableResult
    func save() async -> Bool {
        let words = Self.trimmed(text)
        guard !words.isEmpty, !saving else { return false }
        saving = true
        saveError = nil
        saved = false
        do {
            _ = try await calls.add(words, mood)
        } catch is CancellationError {
            saving = false
            return false
        } catch {
            saving = false
            saveError = "\(Self.message(error)) \(JournalWords.stillHere)"
            return false
        }
        saving = false
        text = ""
        mood = nil
        saved = true
        await load()
        return true
    }

    // MARK: Changing a check-in in place

    /// A check-in being changed in place (the web's Entry state). It's kept here, not in the row, so a fold that
    /// rebuilds the entries (the open Duo's panes) keeps the words being typed. Memory only.
    struct Edit: Equatable {
        var text: String
        var mood: Mood?
        var busy = false
        var error: String?
    }

    /// The check-ins open for changing, by id (the web lets several be open at once).
    private(set) var edits: [String: Edit] = [:]
    /// What a change saved, shown until a read brings the check-in as changed (or newer).
    private(set) var justSaved: [String: JournalEntry] = [:]
    /// What went wrong deleting a check-in, under it.
    private(set) var rowErrors: [String: String] = [:]
    /// The check-in whose box takes the cursor once it shows (Edit was pressed); taken once.
    var focusEdit: String?
    /// The Edit button VoiceOver goes back to when a change is closed; taken once.
    var refocusEdit: String?

    /// The words and mood a check-in shows: what was just saved until the read with it comes.
    func shown(_ entry: JournalEntry) -> (text: String, mood: Mood?) {
        let entry = justSaved[entry.id] ?? entry
        return (entry.text, entry.mood)
    }

    /// Edit: the check-in as it is now (it may have changed on another device since), with the cursor after its words.
    func startEdit(_ entry: JournalEntry) {
        let now = justSaved[entry.id] ?? entry
        edits[entry.id] = Edit(text: now.text, mood: now.mood)
        rowErrors[entry.id] = nil
        focusEdit = entry.id
    }

    func setEditText(_ id: String, _ text: String) {
        guard edits[id] != nil else { return }
        let kept = JournalText.clamp(text)
        guard kept != edits[id]?.text else { return }
        edits[id]?.text = kept
    }

    func setEditMood(_ id: String, _ mood: Mood?) {
        edits[id]?.mood = mood
    }

    /// Cancel (Escape on the web): closed, nothing sent, and back to its Edit button. Not while it saves.
    func cancelEdit(_ id: String) {
        guard let edit = edits[id], !edit.busy else { return }
        edits[id] = nil
        refocusEdit = id
    }

    /// Save changes (PATCH): the words and mood replace the kept ones. On a failure the editor stays open with what
    /// was typed and the server's words under it. True when it went through.
    @discardableResult
    func saveEdit(_ entry: JournalEntry) async -> Bool {
        guard let edit = edits[entry.id], !edit.busy else { return false }
        let words = Self.trimmed(edit.text)
        guard !words.isEmpty else {
            edits[entry.id]?.error = JournalWords.writeAFew
            return false
        }
        edits[entry.id]?.busy = true
        edits[entry.id]?.error = nil
        do {
            justSaved[entry.id] = try await calls.update(entry.id, words, edit.mood)
        } catch is CancellationError {
            edits[entry.id]?.busy = false
            return false
        } catch {
            edits[entry.id]?.busy = false
            edits[entry.id]?.error = Self.message(error)
            return false
        }
        edits[entry.id] = nil
        refocusEdit = entry.id
        await load()
        return true
    }

    /// Deletes a check-in, after asking: true when it's gone (a 404 says it already was), else what went wrong shows
    /// under it.
    @discardableResult
    func delete(_ entry: JournalEntry) async -> Bool {
        rowErrors[entry.id] = nil
        do {
            try await calls.delete(entry.id)
        } catch is CancellationError {
            return false
        } catch let error as APIError {
            guard case .server(404, _) = error else {
                rowErrors[entry.id] = Self.message(error)
                return false
            }
        } catch {
            rowErrors[entry.id] = Self.message(error)
            return false
        }
        edits[entry.id] = nil
        await load()
        return true
    }

    /// After a read: what's open for a check-in that's gone goes with it, and a just-saved change goes once the read
    /// has it (or something newer).
    private func settle(_ entries: [JournalEntry]) {
        var byId: [String: JournalEntry] = [:]
        for entry in entries where byId[entry.id] == nil { byId[entry.id] = entry }
        edits = edits.filter { byId[$0.key] != nil }
        rowErrors = rowErrors.filter { byId[$0.key] != nil }
        justSaved = justSaved.filter { id, saved in
            guard let read = byId[id] else { return false }
            return (read.updatedAt ?? 0) < (saved.updatedAt ?? 0)
        }
    }

    /// "Delete all check-ins", after asking.
    func deleteAll() async {
        deleteAllError = nil
        do {
            try await calls.deleteAll()
        } catch is CancellationError {
            return
        } catch {
            deleteAllError = Self.message(error)
            return
        }
        await load()
    }

    /// The server's own words for what went wrong, never the check-in's: the journal's refusals are written for people
    /// ("Write a few words first.", "No such check-in"), so they show as they are, as the web shows them.
    static func message(_ error: Error) -> String {
        if case .server(let code, let words)? = error as? APIError, (400..<500).contains(code), !words.isEmpty { return words }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// Line breaks kept, only the ends trimmed, as the server keeps it.
    static func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
}
