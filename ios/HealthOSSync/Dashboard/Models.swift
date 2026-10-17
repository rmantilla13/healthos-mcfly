import Foundation

// Mirrors of the API shapes in shared/types.ts. The server keeps evolving, so everything that
// isn't always present is optional, enum-like fields stay strings, and each Summary section is
// decoded on its own: a section the app can't read hides that card instead of failing the screen.

struct Point: Codable, Hashable, Identifiable {
    let date: String
    let value: Double
    var id: String { date }
}

struct Latest: Codable, Hashable {
    let date: String
    let value: Double
    let source: String?
}

struct Vital: Codable {
    let label: String?
    let latest: Latest?
    /// "low" | "normal" | "high": where the latest value sits against the previous 30 days.
    let status: String?
}

struct Summary: Codable {
    let date: String
    let today: String
    let latestDataDate: String?
    let name: String?
    let demo: Bool?
    let stepGoal: Double?
    @Lossy var vitals: Vitals?
    @Lossy var readiness: Readiness?
    @Lossy var spo2: Spo2?
    @Lossy var hrv: Hrv?
    @Lossy var sleep: Sleep?
    @Lossy var load: Load?
    @Lossy var activity: Activity?
    @Lossy var timeline: Timeline?
    @Lossy var insights: [Insight]?
    @Lossy var week: WeekSummary?

    struct Vitals: Codable {
        let heart: Vital?
        let breathing: Vital?
        let temp: Vital?
    }

    /// kind "recovery" (WHOOP: average, zone) or "vo2max" (Apple Watch: previous).
    struct Readiness: Codable {
        let kind: String
        let latest: Latest
        let average: Double?
        let zone: String?
        let previous: Double?
    }

    struct Spo2: Codable {
        let latest: Latest?
        let series: [Point]?
        let status: String?
    }

    struct Hrv: Codable {
        /// "hrv_rmssd" (WHOOP) or "hrv_sdnn" (Apple Watch).
        let metric: String?
        let latest: Latest?
        let series: [Point]?
        let baseline: Double?
        /// "optimal" | "normal" | "low"
        let status: String?
    }

    struct Sleep: Codable {
        let latest: Latest?
        let series: [Point]?
        let change: Double?
    }

    /// kind "strain" (WHOOP, 0–21) or "energy" (Apple active energy, kcal).
    struct Load: Codable {
        let kind: String
        let latest: Latest
        let average: Double?
        let series: [Point]?
    }

    struct Activity: Codable {
        let latest: Latest?
        let series: [Point]?
    }

    struct Timeline: Codable {
        let date: String
        let events: [TimelineEvent]
    }
}

struct TimelineEvent: Codable, Identifiable {
    let id: String
    /// "sleep" | "nap" | "mindful" | "workout"
    let kind: String
    let title: String
    /// ISO strings carrying the wearer's own offset; the wall time is what's shown.
    let start: String
    let end: String
    let detail: String?
}

struct Insight: Codable, Identifiable {
    let id: String
    let icon: String
    let text: String
    let date: String
    /// Web page the insight links to: vitals, sleep, activity, body...
    let page: String
}

struct WeekSummary: Codable {
    struct Pair: Codable {
        let avg: Double?
        let prev: Double?
    }

    struct Steps: Codable {
        let avg: Double?
        let prev: Double?
        let goalDays: Int
        let daysWithData: Int
    }

    struct Workouts: Codable {
        let count: Int
        let minutes: Double
    }

    let start: String
    let end: String
    let days: Int
    let sleep: Pair
    let steps: Steps
    let workouts: Workouts
    let hrv: Pair
    let restingHr: Pair
    let recovery: Pair
}

struct Workout: Codable, Identifiable {
    let id: String
    let source: String
    let sport: String
    let start: String
    let end: String
    let date: String
    let durationMin: Double
    let energyKcal: Double?
    let distanceM: Double?
    let avgHr: Double?
    let maxHr: Double?
    let strain: Double?

    enum CodingKeys: String, CodingKey {
        case id, source, sport, start, end, date, strain
        case durationMin = "duration_min", energyKcal = "energy_kcal", distanceM = "distance_m", avgHr = "avg_hr", maxHr = "max_hr"
    }
}

typealias Trends = [String: [Point]]

struct ServerStatus: Codable {
    struct Settings: Codable {
        let name: String?
        let stepGoal: Double?
        let units: String?
        let timeZone: String?
    }

    struct Apple: Codable {
        struct Sync: Codable { let syncedAt: String }
        struct Import: Codable { let importedAt: String }
        @Lossy var lastSync: Sync?
        @Lossy var lastImport: Import?
    }

    struct Whoop: Codable {
        let configured: Bool?
        let connected: Bool?
        let syncing: Bool?
        let lastSync: String?
        let lastError: String?
    }

    let hosted: Bool?
    let demo: Bool?
    /// POST /api/sync only: a WHOOP sync started on the server for this request.
    let whoopStarted: Bool?
    @Lossy var photo: PhotoMeta?
    @Lossy var settings: Settings?
    @Lossy var apple: Apple?
    @Lossy var whoop: Whoop?
}

/// The profile photo's metadata (shared/types.ts PhotoMeta). The images come from /api/profile/*.png.
struct PhotoMeta: Codable, Equatable {
    struct Dots: Codable, Equatable {
        let temp: [Double]?
        let breathing: [Double]?
        let heart: [Double]?
    }

    /// Changes with every new photo; the image URLs carry it so caches never show an old photo.
    let version: Double
    let width: Double
    let height: Double
    @Lossy var dots: Dots?

    var versionKey: String { String(Int64(version)) }

    static func == (a: PhotoMeta, b: PhotoMeta) -> Bool { a.version == b.version && a.width == b.width && a.height == b.height && a.dots == b.dots }
}

struct AuthState: Codable {
    struct User: Codable {
        let id: String?
        let email: String?
        let name: String?
        let role: String?
    }

    /// "open" (local server, no sign-in), "required" or "misconfigured".
    let mode: String
    let authenticated: Bool
    /// Present only on servers with per-person accounts (sign in with email and password);
    /// true while no account exists yet. Older servers sign in with a password alone.
    let setup: Bool?
    @Lossy var user: User?

    var usesAccounts: Bool { setup != nil }
}

/// Decodes to nil instead of throwing, and treats a missing key as nil.
@propertyWrapper
struct Lossy<Value: Codable>: Codable {
    var wrappedValue: Value?

    init(wrappedValue: Value?) {
        self.wrappedValue = wrappedValue
    }

    init(from decoder: Decoder) throws {
        wrappedValue = try? Value(from: decoder)
    }

    func encode(to encoder: Encoder) throws {
        try wrappedValue.encode(to: encoder)
    }
}

extension KeyedDecodingContainer {
    func decode<V>(_ type: Lossy<V>.Type, forKey key: Key) throws -> Lossy<V> {
        (try? decodeIfPresent(type, forKey: key)) ?? Lossy(wrappedValue: nil)
    }
}
