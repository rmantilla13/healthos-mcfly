import Foundation

// The health journal (server/journal.ts, shared/journal.ts): private check-ins, kept apart from everything else. Nothing
// that reads health data (the summary, the Family board, peer comparisons, McFly, the admin screens) reads them, and
// the app never keeps them on disk or logs them. Home's journal card (slice B) and the Journal page (slice K) both read
// them here; the foundation owns this file.

/// How the day feels (MOODS in shared/journal.ts), 1 to 5; a check-in can leave it out.
enum Mood: Int, Codable, CaseIterable, Identifiable {
    case rough = 1, low, okay, good, great

    var id: Int { rawValue }

    /// The web's word for it: Rough, Low, Okay, Good, Great.
    var label: String {
        switch self {
        case .rough: "Rough"
        case .low: "Low"
        case .okay: "Okay"
        case .good: "Good"
        case .great: "Great"
        }
    }
}

enum JournalLimits {
    /// The longest check-in the server keeps (JOURNAL_MAX_CHARS).
    static let maxChars = 4000
}

/// One check-in (JournalEntry in shared/journal.ts). Read field by field: an odd mood or time leaves the rest.
struct JournalEntry: Codable, Identifiable, Equatable {
    let id: String
    /// The person's own day (YYYY-MM-DD) and wall-clock time (HH:MM).
    let date: String
    let time: String
    let mood: Mood?
    let text: String
    let createdAt: Double?
    let updatedAt: Double?

    /// The first line with words in it (Home's card), or nil.
    var firstLine: String? {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
    }

    private enum CodingKeys: String, CodingKey { case id, date, time, mood, text, createdAt, updatedAt }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        date = try c.decode(String.self, forKey: .date)
        time = (try? c.decode(String.self, forKey: .time)) ?? ""
        mood = (try? c.decodeIfPresent(Int.self, forKey: .mood)).flatMap { $0.flatMap(Mood.init(rawValue:)) }
        text = (try? c.decode(String.self, forKey: .text)) ?? ""
        createdAt = try? c.decodeIfPresent(Double.self, forKey: .createdAt)
        updatedAt = try? c.decodeIfPresent(Double.self, forKey: .updatedAt)
    }
}

/// GET /api/journal?days= (JournalData): the person's today, the check-ins newest first, and whether there are older
/// ones before those days (nil from servers before it was sent).
struct JournalData: Codable, Equatable {
    let today: String
    @LossyArray var entries: [JournalEntry]
    @Lossy var older: Bool?

    /// Today's check-ins, newest first (Home's card shows the first).
    var todays: [JournalEntry] { entries.filter { $0.date == today } }
}

/// POST /api/journal and PATCH /api/journal/:id answer with the check-in as kept.
private struct JournalSaved: Decodable {
    let entry: JournalEntry
}

extension APIClient {
    /// The last `days` days of check-ins (1 to 3650); nil from a server older than the journal.
    func journal(days: Int) async throws -> JournalData? {
        try await optional("/journal", query: [URLQueryItem(name: "days", value: String(days))])
    }

    /// A new check-in; its date and time are now in the person's time zone unless given. Marked as made on the iPhone.
    func addJournal(text: String, mood: Mood?, date: String? = nil, time: String? = nil) async throws -> JournalEntry {
        var body: [String: Any] = ["text": text, "mood": mood.map { $0.rawValue as Any } ?? NSNull(), "origin": "iphone"]
        if let date { body["date"] = date }
        if let time { body["time"] = time }
        let saved: JournalSaved = try await sendJSON("POST", "/journal", body)
        return saved.entry
    }

    /// Changes a check-in: the fields given replace the kept ones (`mood: .some(nil)` clears the mood).
    func updateJournal(id: String, text: String? = nil, mood: Mood?? = nil, date: String? = nil, time: String? = nil) async throws -> JournalEntry {
        var body: [String: Any] = [:]
        if let text { body["text"] = text }
        if let mood { body["mood"] = mood.map { $0.rawValue as Any } ?? NSNull() }
        if let date { body["date"] = date }
        if let time { body["time"] = time }
        let saved: JournalSaved = try await sendJSON("PATCH", "/journal/\(id)", body)
        return saved.entry
    }

    /// Deletes one check-in. A 404 ("No such check-in") is the server's own: it's already gone.
    func deleteJournal(id: String) async throws {
        _ = try await request("/journal/\(id)", method: "DELETE")
    }

    /// Deletes every check-in (POST /api/journal/delete: the Journal page's "Delete all check-ins").
    func deleteAllJournal() async throws {
        _ = try await request("/journal/delete", method: "POST", body: Data("{}".utf8))
    }
}

extension Dashboard {
    /// The last `days` days of check-ins (Home's card reads 1); nil from a server without the journal, so hide it.
    func journal(days: Int = 90) async throws -> JournalData? { try await fetch { try await $0.journal(days: days) } }

    func addJournal(text: String, mood: Mood?, date: String? = nil, time: String? = nil) async throws -> JournalEntry {
        try await fetch { try await $0.addJournal(text: text, mood: mood, date: date, time: time) }
    }

    func updateJournal(id: String, text: String? = nil, mood: Mood?? = nil, date: String? = nil, time: String? = nil) async throws -> JournalEntry {
        try await fetch { try await $0.updateJournal(id: id, text: text, mood: mood, date: date, time: time) }
    }

    func deleteJournal(id: String) async throws { try await fetch { try await $0.deleteJournal(id: id) } }

    func deleteAllJournal() async throws { try await fetch { try await $0.deleteAllJournal() } }
}
