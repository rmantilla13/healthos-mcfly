import Foundation

// The latest-workout card's arithmetic (shared/workouts.ts): which workout is the latest, that sport's recent sessions,
// pace or speed from distance and duration, and a few general recovery suggestions picked by plain rules. Every figure
// is the workout's own; nothing is estimated or scored. Times are read from the ISO strings, which carry the wearer's
// own offset.

enum BodySportKind: String {
    case run, walk, cycle, swim, strength, mind, other

    /// A broad kind from the sport's name, as Apple Health ("Traditional Strength Training") or WHOOP ("Weightlifting")
    /// writes it (sportKind).
    static func of(_ sport: String) -> BodySportKind {
        let s = sport.lowercased()
        func has(_ pattern: String) -> Bool { s.range(of: pattern, options: .regularExpression) != nil }
        if has("\\brun|jog") { return .run }
        if has("walk|hik") { return .walk }
        if has("cycl|bik|spin") { return .cycle }
        if has("swim") { return .swim }
        if has("strength|weight|lift|functional|crossfit|cross training|core training") { return .strength }
        if has("yoga|pilates|mind|medita|stretch|flexib|tai chi|breath") { return .mind }
        return .other
    }
}

/// Pace (time per distance, on foot or in the water) or speed (a ride).
enum BodyPace: Equatable {
    case pace(seconds: Double, per: String)
    case speed(value: Double, unit: String)

    var isSpeed: Bool { if case .speed = self { true } else { false } }

    /// "5:07 /km", "24.3 km/h" (formatPace).
    var text: String {
        switch self {
        case .speed(let value, let unit): "\(Fmt.number(value, 1)) \(unit)"
        case .pace(let seconds, let per): "\(BodyWorkoutMath.clock(seconds)) /\(per)"
        }
    }
}

/// One general suggestion after a session, and the rule that picked it.
struct BodySuggestion: Equatable, Identifiable {
    let id: String
    let text: String
    let why: String
}

enum BodyWorkoutMath {
    /// How far back the card looks for the latest workout and its sport's earlier sessions.
    static let days = 90
    /// How long after a session the suggestions stay up (SUGGESTION_HOURS).
    static let suggestionHours = 18.0
    static let mileM = 1609.344
    static let yardM = 0.9144

    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// The instant an ISO string names, with or without fractions of a second; nil when it can't be read.
    static func instant(_ iso: String) -> Date? { withFraction.date(from: iso) ?? plain.date(from: iso) }

    /// A positive finite number, or nil (num).
    static func num(_ v: Double?) -> Double? {
        guard let v, v.isFinite, v > 0 else { return nil }
        return v
    }

    /// "HH:MM" as recorded, from the ISO string itself (wallClock).
    static func wallClock(_ iso: String) -> String { String(iso.dropFirst(11).prefix(5)) }

    /// The most recent workout that has finished by `now` (latestWorkout): today's list can hold one that hasn't
    /// happened yet.
    static func latest(_ list: [Workout], now: Date) -> Workout? {
        var best: Workout?
        for w in list {
            if let end = instant(w.end), end > now { continue }
            guard let start = instant(w.start) else { if best == nil { best = w }; continue }
            if let b = best, let bs = instant(b.start), start <= bs { continue }
            best = w
        }
        return best
    }

    /// The same sport's sessions up to and including `w`, oldest first: at most `n` (recentSessions).
    static func recent(_ list: [Workout], _ w: Workout, n: Int = 6) -> [Workout] {
        let sport = w.sport.trimmingCharacters(in: .whitespaces).lowercased()
        let until = instant(w.start) ?? .distantFuture
        return Array(list
            .filter { $0.sport.trimmingCharacters(in: .whitespaces).lowercased() == sport && (instant($0.start) ?? .distantPast) <= until }
            .sorted { (instant($0.start) ?? .distantPast) < (instant($1.start) ?? .distantPast) }
            .suffix(n))
    }

    /// How a distance reads for the sport: metres or yards for a swim, otherwise kilometres or miles (distanceIn).
    static func distance(_ m: Double, units: Units, kind: BodySportKind) -> (value: Double, unit: String, digits: Int) {
        let imperial = units == .imperial
        if kind == .swim { return imperial ? (m / yardM, "yd", 0) : (m, "m", 0) }
        let value = imperial ? m / mileM : m / 1000
        return (value, imperial ? "mi" : "km", value >= 100 ? 0 : value >= 10 ? 1 : 2)
    }

    /// Average pace on foot or in the water, or speed on a bike: duration over distance; nil when either is missing,
    /// for other sports, or when the result can't be a real session (paceOf).
    static func pace(_ w: Workout, units: Units) -> BodyPace? {
        guard let m = num(w.distanceM), let min = num(w.durationMin) else { return nil }
        let imperial = units == .imperial
        switch BodySportKind.of(w.sport) {
        case .run, .walk:
            let seconds = min * 60 / (m / (imperial ? mileM : 1000))
            let perKm = imperial ? seconds / (mileM / 1000) : seconds
            return perKm >= 90 && perKm <= 3600 ? .pace(seconds: seconds, per: imperial ? "mi" : "km") : nil
        case .swim:
            let seconds = min * 60 / (m / (imperial ? 100 * yardM : 100))
            return seconds >= 40 && seconds <= 900 ? .pace(seconds: seconds, per: imperial ? "100 yd" : "100 m") : nil
        case .cycle:
            let value = m / (imperial ? mileM : 1000) / (min / 60)
            return value > 0 && value <= (imperial ? 60 : 100) ? .speed(value: value, unit: imperial ? "mph" : "km/h") : nil
        default:
            return nil
        }
    }

    /// "5:07" or "1:02:30": whole seconds first, so 5:59.7 reads 6:00 (clockDuration).
    static func clock(_ total: Double) -> String {
        let t = Int(total.rounded())
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// What the recent-session bars compare: distance when this session and most of the others have one (barMetric).
    static func barsByDistance(_ sessions: [Workout], latest: Workout) -> Bool {
        let withDistance = sessions.filter { num($0.distanceM) != nil }.count
        return num(latest.distanceM) != nil && withDistance * 2 >= sessions.count
    }

    /// The session ended within the last 18 hours by the real clock (suggestionsApply).
    static func suggestionsApply(_ w: Workout, now: Date) -> Bool {
        guard let end = instant(w.end) else { return false }
        return end <= now && now.timeIntervalSince(end) <= suggestionHours * 3600
    }

    /// Ended at 20:00 or later, or past midnight (endsLate).
    static func endsLate(_ w: Workout) -> Bool {
        String(w.end.prefix(10)) > w.date || (Int(w.end.dropFirst(11).prefix(2)) ?? 0) >= 20
    }

    /// A few general suggestions from the session's length, strain and kind; always at least one (recoverySuggestions).
    static func suggestions(_ w: Workout) -> [BodySuggestion] {
        let min = num(w.durationMin) ?? 0
        let strain = num(w.strain)
        let kind = BodySportKind.of(w.sport)
        let lasted = "Lasted \(Int(min.rounded())) min"
        var out: [BodySuggestion] = []
        if min >= 45 || (strain ?? 0) >= 14 {
            out.append(BodySuggestion(id: "water", text: "Drink some water over the next hour or so",
                                      why: (strain ?? 0) >= 14 ? "High strain (\(String(format: "%.1f", strain!)))" : lasted))
        }
        if kind == .strength || min >= 60 {
            out.append(BodySuggestion(id: "protein", text: "Have a meal or snack with some protein in the next few hours",
                                      why: kind == .strength ? "After strength training" : lasted))
        }
        if endsLate(w) { out.append(BodySuggestion(id: "winddown", text: "Leave some time to wind down before bed", why: "Ended at \(wallClock(w.end))")) }
        if min >= 90 || (strain ?? 0) >= 18 {
            out.append(BodySuggestion(id: "lighter", text: "Think about an easier day next",
                                      why: (strain ?? 0) >= 18 ? "All-out strain (\(String(format: "%.1f", strain!)))" : lasted))
        }
        if out.isEmpty { out.append(BodySuggestion(id: "sleep", text: "Keep to your usual sleep tonight", why: "Sleep is when the body does most of its recovering")) }
        return out
    }

    /// Where a workout came from, in the latest-workout card's words (WorkoutCard.tsx SOURCE): "From Apple Health".
    static func from(_ source: String) -> String {
        switch source {
        case "apple": "From Apple Health"
        case "whoop": "From WHOOP"
        case "apple+whoop": "From Apple Health and WHOOP"
        case "fitbit": "From Fitbit"
        default: "From demo data"
        }
    }
}
