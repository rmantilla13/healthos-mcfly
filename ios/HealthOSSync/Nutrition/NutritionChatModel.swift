import Foundation
import Observation
import UIKit

// Nutrition's Today (src/pages/NutritionChat.tsx): a conversation about what you ate, beside the day it adds up to.
// Tell McFly in your own words (typed, a voice note or a photo) and it answers with an estimate to check: rename,
// change how many, leave things out, then save. Nothing counts until you save it, and a follow-up while an estimate
// is open corrects it (the server replaces the draft). The server's drafts are the truth, so an estimate made on the
// web, or one still waiting from before, joins the conversation to be checked here.
//
// The conversation lives in memory only, as privacy.html promises: never on disk, in UserDefaults or a cache. It goes
// with the page when nobody's signed in (PhaseGate swaps it for sign-in), with another person or another server
// (the page is keyed by both), and its photos are small thumbnails drawn in memory. The last estimate's full photo is
// kept, in memory, only so a correction can send it again. Here are the rules, apart from the views so tests can
// check them against the web's.

/// McFly's reply with an estimate (EstimateTurn in NutritionChat.tsx): what it was made from, so a correction can
/// build on it, and what became of it.
struct EstimateTurn: Equatable {
    enum State: Equatable { case open, saved, discarded, replaced }

    let batch: String
    let note: String
    /// The words the estimate was made from.
    let asked: String
    /// It was made from a photo (the photo itself is kept in memory only, for a correction).
    let photo: Bool
    /// Its items as "name (portion)", for a correction once the photo is gone.
    let items: [String]
    let date: String
    let time: String
    var state: State = .open
    /// How many items were saved.
    var saved: Int?
    /// When it arrived: a day read before then doesn't know about it yet.
    let at: Date
    /// Found waiting when the page opened: made on the web, or here before.
    var found = false
}

/// One line of the conversation.
struct ChatTurn: Identifiable, Equatable {
    enum Body: Equatable {
        /// What you said: your words, and a small copy of your photo.
        case you(text: String, thumbnail: UIImage?)
        case estimate(EstimateTurn)
        /// McFly's note: nothing found, or what went wrong (`error`).
        case note(text: String, error: Bool)
    }

    let id: UUID
    var body: Body

    init(_ body: Body, id: UUID = UUID()) {
        self.id = id
        self.body = body
    }

    var estimate: EstimateTurn? {
        if case .estimate(let e) = body { return e }
        return nil
    }
}

/// A date and time to log at ("2026-10-23", "12:00").
struct FoodMoment: Equatable {
    let date: String
    let time: String
}

/// The conversation's rules and words, in the web's.
enum NutritionChat {
    static let maxTurns = 40
    /// The server's limit on a description (server/estimate.ts MAX_DESCRIPTION), counted as the web counts it.
    static let maxDescription = 1000
    /// The long edge of a photo's thumbnail in the thread.
    static let thumbEdge: CGFloat = 240

    /// What a person typed, as one line: runs of spaces and line breaks become one space.
    static func words(_ text: String) -> String {
        text.replacing(/\s+/, with: " ").trimmingCharacters(in: .whitespaces)
    }

    /// The first `limit` UTF-16 units of `s` (JavaScript's slice), never splitting a character.
    static func prefix(_ s: String, utf16 limit: Int) -> String {
        guard s.utf16.count > limit else { return s }
        var count = 0
        var out = ""
        for ch in s {
            let n = String(ch).utf16.count
            if count + n > limit { break }
            count += n
            out.append(ch)
        }
        return out
    }

    /// A correction as one description: what the estimate was made from, then what to change, within the server's limit.
    static func corrected(_ previous: String, _ correction: String) -> String {
        if correction.isEmpty { return prefix(previous, utf16: maxDescription) }
        if previous.isEmpty { return prefix(correction, utf16: maxDescription) }
        let tail = ". Correction: \(correction)"
        let head = previous.replacing(/[\s.]+$/, with: "")
        return tail.utf16.count >= maxDescription ? prefix(correction, utf16: maxDescription) : prefix(head, utf16: maxDescription - tail.utf16.count) + tail
    }

    /// What a correction builds on: the words the estimate was made from, or, for a photo that isn't sent again, what
    /// McFly found in it.
    static func previous(for open: EstimateTurn, resendingPhoto: Bool) -> String {
        let items = open.items.joined(separator: "; ")
        if open.photo && !resendingPhoto {
            return [open.asked, items.isEmpty ? "" : "From a photo: \(items)"].filter { !$0.isEmpty }.joined(separator: ". ")
        }
        return open.asked.isEmpty ? items : open.asked
    }

    /// "Greek yogurt (1 cup (245 g))", or the name alone.
    static func itemText(_ d: FoodEntry) -> String { d.portion.isEmpty ? d.name : "\(d.name) (\(d.portion))" }

    /// "today", or "Thursday, October 23".
    static func dayWords(_ date: String, today: String) -> String { date == today ? "today" : Fmt.day(date, "EEEEMMMMd") }

    /// Where something added from + goes: the day viewed, now on today, midday on a past day. Worked out when it's added,
    /// so a page left open since breakfast doesn't log lunch at breakfast time.
    static func when(viewing: String, today: String, now: Date = Date(), zone: TimeZone) -> FoodMoment {
        FoodMoment(date: viewing, time: viewing == today ? FoodBody.time(now, in: zone) : "12:00")
    }

    /// McFly can estimate a meal here: only once the day is read (the web's `day?.can?.estimate`). Before that, an
    /// estimate waiting from the web or another iPhone hasn't joined the conversation, so a message wouldn't be its
    /// correction, and the server would replace it unseen.
    static func canEstimate(dayRead: Bool, estimate: Bool?) -> Bool { dayRead && estimate == true }

    /// Send is on (the web's `ready`): words or a photo, McFly free, and estimates working here once the day is read.
    static func canSend(dayRead: Bool, estimate: Bool?, busy: Bool, draft: String, photo: Bool) -> Bool {
        canEstimate(dayRead: dayRead, estimate: estimate) && !busy && (!words(draft).isEmpty || photo)
    }

    /// Voice notes can't be written down here: why, in the web's words; nil when they can.
    static func voiceOff(voice: Bool?, byok: Bool?) -> String? {
        if voice == true { return nil }
        return byok == false ? ServerWords.voiceNeedsKeyNotHere : "Connect your OpenAI key for voice notes."
    }

    // MARK: An estimate's line

    /// What an estimate's line shows (EstimateLine).
    enum EstimateShows: Equatable {
        case saved(Int?)
        case discarded
        /// A correction replaced it.
        case replaced(items: String)
        /// The review, with these drafts.
        case review([FoodEntry])
        /// The day hasn't been read yet.
        case waiting(items: String)
        /// It isn't waiting any more.
        case gone(items: String)

        var text: String? {
            switch self {
            case .saved(let n): n == 1 || n == nil ? "Saved to your food journal." : "Saved \(n!) items to your food journal."
            case .discarded: "Discarded. Nothing was saved."
            case .replaced(let items): "\(items). Corrected below."
            case .waiting(let items): items
            case .gone(let items): "\(items). This estimate isn't waiting any more: it was saved or discarded somewhere else, or it went after a day."
            case .review: nil
            }
        }
    }

    /// The day as last read, unless it was read before this estimate arrived: then the estimate's own drafts.
    static func shows(_ turn: EstimateTurn, day: FoodLogDay?, dayAskedAt: Date?, fresh: [FoodEntry]?) -> EstimateShows {
        let items = turn.items.joined(separator: ", ")
        switch turn.state {
        case .saved: return .saved(turn.saved)
        case .discarded: return .discarded
        case .replaced: return .replaced(items: items)
        case .open: break
        }
        if let day, day.draftBatch == turn.batch, !day.drafts.isEmpty { return .review(day.drafts) }
        if let fresh, day == nil || (dayAskedAt ?? .distantPast) < turn.at { return .review(fresh) }
        return day == nil ? .waiting(items: items) : .gone(items: items)
    }

    // MARK: Under the composer

    /// The company a photo and words go to for an estimate, and the name its key goes by in Profile (COMPANY, KEY_LABEL
    /// in src/pages/FoodLog.tsx). A provider this build doesn't know goes by its own name, never another's.
    static func company(_ provider: String) -> String { ["anthropic": "Anthropic", "openai": "OpenAI", "gemini": "Google"][provider] ?? provider }
    static func keyLabel(_ provider: String) -> String { ["anthropic": "Claude", "openai": "OpenAI", "gemini": "Gemini"][provider] ?? provider }

    /// The line under the composer (SetupLine).
    enum SetupLine: Equatable {
        /// "One-time setup: connect your OpenAI key to start.", the middle words a link to Profile's OpenAI sheet.
        case connectOpenAI
        /// Estimates aren't possible on this server.
        case notHere(String)
        /// What reads an estimate, and where the words and photos go.
        case using(String)

        static let connectLead = "One-time setup: "
        static let connectLink = "connect your OpenAI key"
        static let connectTail = " to start."
    }

    /// What reads an estimate, or what's missing for one. nil until both the food log's `can` and GET /api/ai are known.
    static func setupLine(can: FoodLog.Can?, ai: AiStatus?, mode: NutritionMode) -> SetupLine? {
        guard let can, let ai else { return nil }
        if !can.estimate {
            let rest = mode == .none ? "You can still search foods from +." : "You can still search foods, type amounts or add water from +."
            return ai.byok ? .connectOpenAI : .notHere("\(ServerWords.estimatesNeedKeyNotHere) \(rest)")
        }
        // An older server, without estimateProvider, had only Claude.
        let provider = can.estimateProvider ?? "anthropic"
        let place = "your words and photos go to \(company(provider)) for each estimate, and healthOS doesn't keep them."
        // Hold to talk sends the recording to OpenAI to be written down, on the person's own OpenAI key or else the
        // server's. Said here unless the line already names OpenAI.
        let ownOpenAI = ai.keys.contains { $0.provider == "openai" }
        let voice = can.voice == true && provider != "openai" ? " Voice notes are transcribed by OpenAI first, on \(ownOpenAI ? "your key" : "this server's key")." : ""
        let who = can.estimateSource == "own" ? "Using your own \(keyLabel(provider)) key" : "Using healthOS's shared assistant"
        return .using("\(who) · \(place)\(voice)")
    }

    /// Where an estimate's photo and words go, in plain words (estimatePrivacy in src/pages/FoodLog.tsx): the provider
    /// actually used, and whose key pays for it.
    static func estimatePrivacy(_ can: FoodLog.Can) -> String {
        let provider = can.estimateProvider ?? "anthropic"
        let cost = can.estimateSource == "own" ? "It runs on your own \(keyLabel(provider)) key." : "It counts as one McFly question."
        return "The photo and words go to \(company(provider)) for this one estimate, and healthOS doesn't keep them. \(cost)"
    }
}

/// The conversation: memory only, for as long as the page is up (see the top of this file).
@MainActor
@Observable
final class NutritionThread {
    /// The last estimate's full photo, so a correction can send it again.
    struct LastPhoto: Equatable {
        let batch: String
        let jpeg: Data
    }

    /// What one message sends to POST /api/nutrition/estimate.
    struct Ask: Equatable {
        let description: String
        let jpeg: Data?
        let moment: FoodMoment
        /// The estimate this message corrects.
        let correcting: UUID?
    }

    private(set) var turns: [ChatTurn] = []
    /// Each estimate's drafts as it came back, shown until the day is read again.
    private(set) var fresh: [String: [FoodEntry]] = [:]
    private(set) var lastPhoto: LastPhoto?
    /// The composer: what's typed, and the photo attached, kept while the page's other views are looked at.
    var draft = ""
    var photo: AttachedPhoto?
    /// McFly is estimating.
    var busy = false

    var isEmpty: Bool { turns.isEmpty }

    func append(_ turn: ChatTurn) {
        turns.append(turn)
        if turns.count > NutritionChat.maxTurns { turns.removeFirst(turns.count - NutritionChat.maxTurns) }
    }

    /// The estimate being reviewed right now, the one the server is waiting on: a follow-up message corrects it.
    func open(batch: String?) -> (id: UUID, turn: EstimateTurn)? {
        guard let batch else { return nil }
        for t in turns.reversed() {
            if let e = t.estimate, e.state == .open, e.batch == batch { return (t.id, e) }
        }
        return nil
    }

    /// An estimate waiting on the server that this conversation didn't make (the web, or here before) joins it, once.
    func join(waiting day: FoodLogDay, at: Date = Date()) {
        guard let batch = day.draftBatch, let first = day.drafts.first else { return }
        guard !turns.contains(where: { $0.estimate?.batch == batch }) else { return }
        append(ChatTurn(.estimate(EstimateTurn(batch: batch, note: "", asked: "", photo: false, items: day.drafts.map(NutritionChat.itemText),
                                               date: first.date, time: first.time, at: at, found: true))))
    }

    /// Clear: everything but the estimate still waiting to be checked.
    func clear(keeping openID: UUID?) {
        turns = turns.filter { $0.id == openID }
    }

    /// What a message sends: on its own, or, while an estimate is open, as a correction of it, on its day and time with
    /// its photo sent again.
    func ask(words: String, jpeg: Data?, at moment: FoodMoment, openBatch: String?) -> Ask {
        guard let open = open(batch: openBatch) else { return Ask(description: words, jpeg: jpeg, moment: moment, correcting: nil) }
        let image = jpeg ?? (lastPhoto?.batch == open.turn.batch ? lastPhoto?.jpeg : nil)
        let previous = NutritionChat.previous(for: open.turn, resendingPhoto: image != nil)
        return Ask(description: NutritionChat.corrected(previous, words), jpeg: image,
                   moment: FoodMoment(date: open.turn.date, time: open.turn.time), correcting: open.id)
    }

    /// The estimate came back. With drafts it opens for review (replacing the one it corrected); without, McFly says why
    /// (and the server dropped the one it corrected anyway). Returns what VoiceOver hears.
    @discardableResult
    func received(_ r: FoodEstimate, for ask: Ask, at: Date = Date()) -> String {
        if let batch = r.batch, !r.drafts.isEmpty {
            lastPhoto = ask.jpeg.map { LastPhoto(batch: batch, jpeg: $0) }
            fresh = [batch: r.drafts]
            if let id = ask.correcting { mark(id, .replaced) }
            let turn = EstimateTurn(batch: batch, note: r.note ?? "", asked: ask.description, photo: ask.jpeg != nil,
                                    items: r.drafts.map(NutritionChat.itemText), date: ask.moment.date, time: ask.moment.time, at: at)
            append(ChatTurn(.estimate(turn)))
            return "McFly's estimate is ready to check: \(turn.items.joined(separator: ", "))."
        }
        if let id = ask.correcting { mark(id, .discarded) }
        let note = r.note.flatMap { $0.isEmpty ? nil : $0 } ?? "McFly didn't find food or drink to estimate."
        append(ChatTurn(.note(text: note, error: false)))
        return note
    }

    /// The estimate couldn't be made: the server's words, shown as McFly's note.
    func failed(_ message: String) {
        append(ChatTurn(.note(text: message, error: true)))
    }

    /// Saved (how many) or discarded (nil) from its review.
    func finish(_ id: UUID, saved: Int?) {
        guard let i = turns.firstIndex(where: { $0.id == id }), var e = turns[i].estimate else { return }
        e.state = saved == nil ? .discarded : .saved
        e.saved = saved
        turns[i].body = .estimate(e)
    }

    private func mark(_ id: UUID, _ state: EstimateTurn.State) {
        guard let i = turns.firstIndex(where: { $0.id == id }), var e = turns[i].estimate else { return }
        e.state = state
        turns[i].body = .estimate(e)
    }

    /// A small copy of a photo for the thread, drawn in memory, so the full one is never kept for it.
    static func thumbnail(_ jpeg: Data) -> UIImage? {
        guard let image = UIImage(data: jpeg) else { return nil }
        let size = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let scale = min(1, NutritionChat.thumbEdge / max(size.width, size.height, 1))
        let target = CGSize(width: max(1, (size.width * scale).rounded()), height: max(1, (size.height * scale).rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
    }
}

/// The day's saved entries added up (DailyBalance in NutritionChat.tsx): kcal in the ring, protein, carbs and fat by
/// weight beside it, the rest underneath. Nothing logged is a dash, never a zero. No amounts at all: only how many
/// meals were logged.
struct DailyBalanceMath {
    struct Part: Equatable {
        let key: String
        let label: String
        let value: Double
    }

    struct Row: Equatable {
        let key: String
        let label: String
        /// "38" (its unit, g, beside it); nil: nothing logged, a dash.
        let grams: String?
        let percent: String
    }

    /// Protein, carbs and fat, in the design's soft colours.
    static let macros: [(key: String, label: String)] = [("protein_g", "Protein"), ("carbs_g", "Carbs"), ("fat_g", "Fat")]

    let mode: NutritionMode
    let balance: [String: Double]
    let entries: Int
    /// What was logged at one time counts as one meal (an estimate's items share theirs).
    let meals: Int
    let parts: [Part]
    let total: Double
    let units: Units

    init(day: FoodLogDay?, mode: NutritionMode, units: Units) {
        self.mode = mode
        self.units = units
        let b = day?.balance ?? [:]
        balance = b
        entries = day?.entries.count ?? 0
        meals = Set((day?.entries ?? []).map(\.time)).count
        // A part is a macro with something in it: none at all, or zero, is left off the ring.
        parts = Self.macros.compactMap { m in b[m.key].flatMap { $0 > 0 ? Part(key: m.key, label: m.label, value: $0) : nil } }
        total = parts.reduce(0) { $0 + $1.value }
    }

    func percent(_ v: Double?) -> String {
        guard let v, total > 0 else { return .emptyValue }
        return "\(Int((v / total * 100).rounded()))%"
    }

    /// "3 entries" in the head's badge.
    var badge: String { "\(entries) \(entries == 1 ? "entry" : "entries")" }

    /// What the ring says to VoiceOver.
    var label: String {
        if mode == .none { return "\(meals == 0 ? "No" : String(meals)) \(meals == 1 ? "meal" : "meals") logged" }
        if total > 0 { return "By weight: " + parts.map { "\($0.label.lowercased()) \(percent($0.value))" }.joined(separator: ", ") }
        return "No protein, carbs or fat logged"
    }

    /// The ring's middle: a figure (nil for none) over a few words.
    var center: (value: String?, caption: String) {
        switch mode {
        case .none: (meals == 0 ? .emptyValue : String(meals), meals == 1 ? "meal logged" : "meals logged")
        case .all: (balance["energy_kcal"].map { Fmt.number($0) } ?? .emptyValue, "kcal logged")
        case .noEnergy: (total > 0 ? nil : .emptyValue, "by weight")
        }
    }

    /// Each macro's line, a dash where nothing was logged.
    var rows: [Row] {
        Self.macros.map { m in Row(key: m.key, label: m.label, grams: balance[m.key].map(FoodText.grams), percent: percent(balance[m.key])) }
    }

    /// Fiber, sugar, sodium, alcohol and water, the ones logged.
    var extras: [(label: String, value: String)] {
        func shown(_ key: String) -> Double? { balance[key].flatMap { $0 != 0 ? $0 : nil } }
        var out: [(String, String)] = []
        if let v = shown("fiber_g") { out.append(("Fiber", "\(FoodText.grams(v)) g")) }
        if let v = shown("sugar_g") { out.append(("Sugar", "\(FoodText.grams(v)) g")) }
        if let v = shown("sodium_mg") { out.append(("Sodium", "\(Fmt.number(v)) mg")) }
        if let v = shown("alcohol_drinks") {
            let n = (v * 10).rounded() / 10
            out.append(("Alcohol", "\(n == n.rounded() ? String(Int(n)) : String(n)) \(v == 1 ? "drink" : "drinks")"))
        }
        if let v = shown("water_ml") { out.append(("Water", FoodText.water(v, units: units))) }
        return out
    }

    var foot: String { mode == .none ? "Counted from your food journal." : "Estimated from your logged meals." }
}
