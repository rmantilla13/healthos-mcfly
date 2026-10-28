import Foundation

// The measurements a person adds themselves (shared/body.ts, server/body.ts): weight, body fat and lean mass from a
// scale, a scan or their records, stored in kg and %. The server mirrors each day's latest entry into `daily` as source
// 'manual', so the charts and sheets read a typed weigh-in like a scale's. GET /api/body/* is newer than main: on a
// server without it (its catch-all "Not found"), the cards show what /api/trends has and nothing can be added.

/// A metric a person can add (BODY_METRICS): its name, stored unit, the range the server takes and its card's wash.
enum BodyMetric: String, CaseIterable, Identifiable, Hashable {
    case weight, bodyFat = "body_fat", leanMass = "lean_mass"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .weight: "Weight"
        case .bodyFat: "Body fat"
        case .leanMass: "Lean body mass"
        }
    }

    /// The range the server takes, in kg or %.
    var min: Double {
        switch self {
        case .weight: 20
        case .bodyFat: 2
        case .leanMass: 10
        }
    }

    var max: Double {
        switch self {
        case .weight: 400
        case .bodyFat: 75
        case .leanMass: 250
        }
    }

    /// The card's wash (MeasurementCard.tsx TONE).
    var tint: CardTint {
        switch self {
        case .weight: .slate
        case .bodyFat: .peach
        case .leanMass: .green
        }
    }

    /// The sheet's title (AddEntrySheet.tsx TITLE).
    var addTitle: String {
        switch self {
        case .weight: "Add weight"
        case .bodyFat: "Add body fat"
        case .leanMass: "Add lean body mass"
        }
    }

    var sheetKey: MetricKey {
        switch self {
        case .weight: .weight
        case .bodyFat: .bodyFat
        case .leanMass: .leanMass
        }
    }

    /// The unit as the person reads it: kg or lb by their units, % for body fat (unitOf).
    func unit(_ units: Units) -> String { self == .bodyFat ? "%" : units.mass(0).unit }

    /// A stored value (kg or %) in the person's units (inUnits).
    func inUnits(_ value: Double, _ units: Units) -> Double { self == .bodyFat ? value : units.mass(value).value }

    /// "72.4 kg", "160.2 lb", "24.1%": a value already in the person's units.
    static func show(_ value: Double, unit: String) -> String { unit == "%" ? "\(Fmt.number(value, 1))%" : "\(Fmt.number(value, 1)) \(unit)" }

    /// The range in the units typed in (the server checks it again in kg): whole pounds inside the kg range.
    func range(unit: String) -> (low: Double, high: Double) {
        unit == "lb" ? ((min * BodyMath.lbPerKg).rounded(.up), (max * BodyMath.lbPerKg).rounded(.down)) : (min, max)
    }

    /// The value field's hint: "In kg, between 20 and 400.", "As a percentage, between 2 and 75."
    func hint(unit: String) -> String {
        let r = range(unit: unit)
        let span = "between \(Fmt.number(r.low)) and \(Fmt.number(r.high))."
        return unit == "%" ? "As a percentage, \(span)" : "In \(unit), \(span)"
    }

    /// The name in a sentence ("Enter your lean body mass as a number.").
    var name: String { label.lowercased() }
}

/// Where an entry is from (BODY_METHODS); 'other' is what the server stores when none was chosen.
enum BodyMethod: String, CaseIterable {
    case scale, scan, records

    var label: String {
        switch self {
        case .scale: "Scale"
        case .scan: "Scan"
        case .records: "Records"
        }
    }

    /// The label for a stored method; nil for 'other' or one this build doesn't know.
    static func label(_ stored: String) -> String? { BodyMethod(rawValue: stored)?.label }
}

/// One entry (BodyEntry): kg for weight and lean mass, % for body fat.
struct BodyEntry: Codable, Identifiable, Equatable {
    let id: String
    let metric: String
    let value: Double
    let date: String
    /// HH:MM, or nil when not given.
    let time: String?
    let method: String
    let note: String

    private enum CodingKeys: String, CodingKey { case id, metric, value, date, time, method, note }

    init(id: String, metric: String, value: Double, date: String, time: String? = nil, method: String = "other", note: String = "") {
        self.id = id
        self.metric = metric
        self.value = value
        self.date = date
        self.time = time
        self.method = method
        self.note = note
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        metric = try c.decode(String.self, forKey: .metric)
        value = try c.decode(Double.self, forKey: .value)
        date = try c.decode(String.self, forKey: .date)
        time = try? c.decodeIfPresent(String.self, forKey: .time)
        method = (try? c.decodeIfPresent(String.self, forKey: .method)) ?? "other"
        note = (try? c.decodeIfPresent(String.self, forKey: .note)) ?? ""
    }
}

/// GET /api/body/entries: newest first. One entry the app can't read leaves out only itself.
struct BodyEntries: Codable {
    @LossyArray var entries: [BodyEntry]
}

/// One metric's latest value as the charts show it, and where it came from (GET /api/body/latest).
struct BodyLatestValue: Codable, Equatable {
    let date: String
    let value: Double
    let source: String

    /// "Added by you", "Apple Health", "WHOOP", "Fitbit", "Demo data" (SOURCE_NAME); nil for one this build doesn't know.
    var sourceName: String? {
        switch source {
        case "manual": "Added by you"
        case "apple": "Apple Health"
        case "whoop": "WHOOP"
        case "fitbit": "Fitbit"
        case "demo": "Demo data"
        default: nil
        }
    }
}

/// GET /api/body/latest: each metric's latest value in the last 120 days, or nil. Each read on its own.
struct BodyLatest: Codable {
    @Lossy var weight: BodyLatestValue?
    @Lossy var bodyFat: BodyLatestValue?
    @Lossy var leanMass: BodyLatestValue?

    private enum CodingKeys: String, CodingKey {
        case weight, bodyFat = "body_fat", leanMass = "lean_mass"
    }

    init(weight: BodyLatestValue? = nil, bodyFat: BodyLatestValue? = nil, leanMass: BodyLatestValue? = nil) {
        self.weight = weight
        self.bodyFat = bodyFat
        self.leanMass = leanMass
    }

    subscript(metric: BodyMetric) -> BodyLatestValue? {
        switch metric {
        case .weight: weight
        case .bodyFat: bodyFat
        case .leanMass: leanMass
        }
    }
}

/// The arithmetic of the measurement cards and the entry form, kept apart so it can be tested on its own.
enum BodyMath {
    static let lbPerKg = 1 / 0.45359237
    /// The cards' window: long enough to find a reading a month before one that's a few weeks old (MEASURE_DAYS).
    static let measureDays = 120
    /// The list shows this many until "Show all" (RECENT).
    static let recent = 8
    /// The longest note the server keeps.
    static let noteMax = 200

    /// The reading closest to `days` before the last one, within `slack` days of it (aboutBefore in shared/metrics.ts).
    static func aboutBefore(_ points: [Point], days: Int = 30, slack: Int = 9) -> Point? {
        guard let last = points.last else { return nil }
        let at = Day.add(last.date, -days)
        var best: Point?
        var bestGap = Int.max
        for p in points {
            let gap = abs(Fmt.daysBetween(at, p.date))
            if gap <= slack, gap < bestGap {
                best = p
                bestGap = gap
            }
        }
        return best
    }

    /// "−0.8 kg since Sep 21", "+0.4 points since Sep 21", "about the same as Sep 21"; nil without a reading about a
    /// month before the latest (changeOf). Points are already in the person's units.
    static func change(_ points: [Point], unit: String) -> String? {
        guard let last = points.last, let then = aboutBefore(points) else { return nil }
        let d = last.value - then.value
        // A change that rounds to nothing has no sign to show.
        if Fmt.number(abs(d), 1) == Fmt.number(0, 1) { return "about the same as \(Fmt.day(then.date))" }
        return "\(Fmt.signed(d, 1)) \(unit == "%" ? "points" : unit) since \(Fmt.day(then.date))"
    }

    /// What was typed, as a number: a comma works as the decimal point too ("72,4"); nil when it isn't one.
    static func value(_ typed: String) -> Double? {
        let t = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        var s = t
        if let comma = s.firstIndex(of: ",") { s.replaceSubrange(comma...comma, with: ".") }
        guard let n = Double(s), n.isFinite else { return nil }
        return n
    }

    /// The body POST /api/body/entries takes: the value in the units typed, its unit, the day, an optional time,
    /// where it's from and a note (left out when empty).
    static func entryBody(metric: BodyMetric, value: Double, unit: String, date: String, time: String?, method: BodyMethod?, note: String) -> [String: Any] {
        var body: [String: Any] = ["metric": metric.rawValue, "value": value, "unit": unit, "date": date, "time": time ?? NSNull()]
        if let method { body["method"] = method.rawValue }
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { body["note"] = trimmed }
        return body
    }

    /// An entry's day and time in the list: "Oct 21, 07:30", with the year when it isn't this one.
    static func when(_ entry: BodyEntry, today: String) -> String {
        let sameYear = entry.date.prefix(4) == today.prefix(4)
        let day = Fmt.day(entry.date, sameYear ? "MMMd" : "MMMdyyyy")
        return entry.time.map { "\(day), \($0)" } ?? day
    }

    /// The line under an entry's value: its day, where it's from and its note, as many as it has.
    static func detail(_ entry: BodyEntry, today: String) -> String {
        [when(entry, today: today), BodyMethod.label(entry.method), entry.note.isEmpty ? nil : entry.note].compactMap { $0 }.joined(separator: " · ")
    }

    /// The words to show for a failed body request: the server's own (validation, "No such entry", the demo's 409),
    /// else the app's.
    static func message(_ error: Error) -> String {
        if case APIError.server(_, let said) = error, !said.isEmpty { return said }
        return error.localizedDescription
    }
}

extension APIClient {
    /// GET /api/body/latest; nil on a server without it.
    func bodyLatest() async throws -> BodyLatest? { try await optional("/body/latest") }

    /// GET /api/body/entries for one metric, every entry back to 1900; nil on a server without it.
    func bodyEntries(_ metric: BodyMetric) async throws -> BodyEntries? {
        try await optional("/body/entries", query: [URLQueryItem(name: "metric", value: metric.rawValue), URLQueryItem(name: "days", value: "36500")])
    }

    /// POST /api/body/entries. The server's words come back for a refusal (a value out of range, a future day, demo data).
    func addBodyEntry(_ body: [String: Any]) async throws {
        _ = try await request("/body/entries", method: "POST", body: try JSONSerialization.data(withJSONObject: body))
    }

    /// DELETE /api/body/entries/:id. Its 404 is "No such entry", not an older server.
    func deleteBodyEntry(id: String) async throws {
        let safe = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? id
        _ = try await request("/body/entries/\(safe)", method: "DELETE")
    }

    /// GET /api/trends ending on `date` (nil is today), for the overview's day rows.
    func bodyTrends(_ metrics: [String], days: Int, date: String?) async throws -> Trends {
        var query = [URLQueryItem(name: "metrics", value: metrics.joined(separator: ",")), URLQueryItem(name: "days", value: String(days))]
        if let date { query.append(URLQueryItem(name: "date", value: date)) }
        return try await get("/trends", query: query)
    }

    /// GET /api/workouts ending on `date` (nil is today), for the latest-workout card.
    func bodyWorkouts(days: Int, date: String?) async throws -> [Workout] {
        var query = [URLQueryItem(name: "days", value: String(days))]
        if let date { query.append(URLQueryItem(name: "date", value: date)) }
        return try await get("/workouts", query: query)
    }
}
