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
    /// Gentle heads-ups (resting heart rate up, with or without a raised temperature). Element by element:
    /// one the app can't read drops only itself. Empty from servers older than flags.
    @LossyArray var flags: [Flag]

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

/// A gentle flag on Today (Summary.flags). Never mentions the cycle; the app adds that context itself.
struct Flag: Codable, Identifiable {
    let id: String
    /// "caution" | "info"
    let tone: String?
    let title: String
    let text: String
    /// Web page it links to; "vitals" for now.
    let page: String?

    var caution: Bool { tone == "caution" }
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

/// One day by local hour (GET /api/day): steps, active energy and heart rate next to a typical day.
struct DayData: Codable {
    let date: String
    /// The person's today, in their time zone.
    let today: String
    /// The last hour (0–23) with any reading on `date`; nil when the day has none.
    let asOf: Int?
    /// Only metrics the person has hourly data for at all ("steps", "active_energy", "heart_rate"); empty means no
    /// Day view. A metric the app can't read is left out instead of failing the day.
    let metrics: [String: DaySeries]

    var steps: DaySeries? { metrics["steps"] }
    var activeEnergy: DaySeries? { metrics["active_energy"] }
    var heartRate: DaySeries? { metrics["heart_rate"] }

    private enum CodingKeys: String, CodingKey { case date, today, asOf, metrics }

    init(date: String, today: String, asOf: Int?, metrics: [String: DaySeries]) {
        self.date = date
        self.today = today
        self.asOf = asOf
        self.metrics = metrics
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decode(String.self, forKey: .date)
        today = try c.decode(String.self, forKey: .today)
        asOf = try? c.decodeIfPresent(Int.self, forKey: .asOf)
        metrics = ((try? c.decodeIfPresent([String: Lossy<DaySeries>].self, forKey: .metrics)) ?? [:]).compactMapValues(\.wrappedValue)
    }
}

/// One metric's day. Every array has 24 entries (index 0 = midnight to 1 AM), padded if the server sent fewer.
struct DaySeries: Codable {
    struct Total: Codable {
        let value: Double
        let source: String
    }

    /// A sum per hour (steps, active energy) or an average (heart rate); nil where nothing was recorded.
    let hours: [Double?]
    /// The median per hour over the previous 30 days: for sums the running total by the end of that hour
    /// ("typical by now"), for heart rate the typical hourly average. nil where fewer than 3 days qualify.
    let typical: [Double?]
    /// Heart rate only: the lowest and highest reading in each hour.
    let min: [Double?]?
    let max: [Double?]?
    /// Steps only: the day's count as Today shows it and where it came from. A WHOOP total is larger than the
    /// hours add up to (those come from the iPhone or Watch).
    let total: Total?

    private enum CodingKeys: String, CodingKey { case hours, typical, min, max, total }

    init(hours: [Double?], typical: [Double?], min: [Double?]? = nil, max: [Double?]? = nil, total: Total? = nil) {
        self.hours = Self.day(hours)
        self.typical = Self.day(typical)
        self.min = min.map(Self.day)
        self.max = max.map(Self.day)
        self.total = total
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hours = Self.day(try c.decode([Double?].self, forKey: .hours))
        typical = Self.day((try? c.decodeIfPresent([Double?].self, forKey: .typical)) ?? [])
        min = (try? c.decodeIfPresent([Double?].self, forKey: .min))?.map(Self.day)
        max = (try? c.decodeIfPresent([Double?].self, forKey: .max))?.map(Self.day)
        total = try? c.decodeIfPresent(Total.self, forKey: .total)
    }

    /// Exactly 24 hours, so views can index any hour.
    private static func day(_ values: [Double?]) -> [Double?] {
        Array((values + Array(repeating: nil, count: Swift.max(0, 24 - values.count))).prefix(24))
    }
}

/// Cycle tracking (GET /api/cycle), the part the app shows. Reproductive-health data: only fetched while the
/// person has cycle tracking on, and never part of the summary, patterns, flags or the digest.
struct CycleData: Codable {
    struct Period: Codable {
        let start: String
        let end: String
        let days: Int
    }

    /// Medians over recent cycles, in days.
    struct Stats: Codable {
        let cycleDays: Int?
        let periodDays: Int?
        let shortest: Int?
        let longest: Int?
    }

    struct Current: Codable {
        let start: String
        /// Cycle day, 1 on the first day of the period.
        let day: Int
    }

    struct Estimate: Codable {
        struct NextPeriod: Codable {
            let date: String
            let earliest: String
            let latest: String
        }

        struct Fertile: Codable {
            let start: String
            let end: String
        }

        /// The most likely first day of the next period, and the range it usually falls in.
        let nextPeriod: NextPeriod
        let ovulation: String
        /// The five days before ovulation, ovulation day, and the day after.
        let fertile: Fertile
        /// "calendar" | "lh_test" | "bbt"
        let basis: String?
        /// How many recent cycles it rests on.
        let cycles: Int?
    }

    let enabled: Bool
    let today: String
    /// Logged days in the window asked for, oldest first (CycleDay, the same shape the app sends).
    @LossyArray var days: [CycleDay]
    /// Detected periods over all history, oldest first.
    @LossyArray var periods: [Period]
    @Lossy var stats: Stats?
    @Lossy var current: Current?
    /// nil until two complete cycles are logged, or when the latest period is long past (see noEstimate).
    @Lossy var estimate: Estimate?
    /// Why there's no estimate: "cycles" | "stale".
    let noEstimate: String?
    /// Missing from servers older than the phase.
    @Lossy var phase: CyclePhase?
}

/// Where today sits in the cycle (CycleData.phase).
struct CyclePhase: Codable {
    /// "menstrual" | "follicular" | "ovulatory" | "luteal"
    let name: String
    /// Cycle day.
    let day: Int
    /// Days until the next period is expected; nil without an estimate.
    let nextPeriodIn: Int?
    /// "logged" | "estimate"
    let basis: String?

    var luteal: Bool { name == "luteal" }
    var menstrual: Bool { name == "menstrual" }
}

/// Bed and wake times (GET /api/sleep): consistency, weekday vs weekend, sleep need and debt.
struct SleepTiming: Codable {
    /// The main night per wake date (naps excluded).
    struct Night: Codable, Identifiable {
        /// Wake date.
        let date: String
        /// ISO strings carrying the wearer's own offset; the wall time is what's shown.
        let bed: String
        let wake: String
        /// Minutes after 18:00 local (23:30 → 330, 01:10 → 430).
        let bedMin: Double
        /// Minutes after midnight on the wake date.
        let wakeMin: Double
        /// Sleep midpoint, minutes after 18:00.
        let midMin: Double
        /// Hours asleep that night (blended), else the time in bed.
        let hours: Double?
        /// The wake date is a Saturday or Sunday.
        let weekend: Bool

        var id: String { date }
    }

    struct Stats: Codable {
        let nights: Int
        /// Minutes after 18:00 (bed) and after midnight (wake).
        let avgBedMin: Double?
        let avgWakeMin: Double?
        /// Standard deviation in minutes; needs at least 7 nights.
        let bedSd: Double?
        let wakeSd: Double?
        /// Midpoints, minutes after 18:00; need at least 2 nights each.
        let midWeekday: Double?
        let midWeekend: Double?
        /// midWeekend − midWeekday, in minutes.
        let socialJetlag: Double?
        /// Hours: the median sleep of the last 60 nights, clamped to 7–9; needs at least 14 nights.
        let need: Double?
        /// Hours short of `need` over the last 7 nights.
        let debt: Double?
        /// Nights with data among the last 7 days: not necessarily in a row, nor including last night.
        let debtNights: Int
    }

    /// Oldest first.
    @LossyArray var nights: [Night]
    @Lossy var stats: Stats?
}

/// Correlations from the person's own last 180 days (GET /api/patterns), strongest first. Correlational wording
/// only: "on days with…, you tend to…".
struct Patterns: Codable {
    let start: String
    let end: String
    @LossyArray var patterns: [Pattern]
}

struct Pattern: Codable, Identifiable {
    let id: String
    /// "moon" | "heart" | "steps" | "sun" | "spark" | "trend-up" | "trend-down"
    let icon: String?
    /// One sentence, e.g. "On days with 10k+ steps, you tend to sleep 24 min longer that night."
    let text: String
    /// e.g. "Based on 41 days with 10k+ steps and 96 without, last 180 days."
    let detail: String?
    /// Days in the smaller group.
    let n: Int?
    /// Signed difference, in `unit`: "min" | "ms" | "%" | "bpm" | "points".
    let effect: Double?
    let unit: String?
    /// "vitals" | "sleep" | "activity" | "body"
    let page: String?
}

/// McFly's weekly recap (GET /api/mcfly/digest). `digest` stays nil when McFly isn't set up, is off, is over
/// today's limit with nothing cached, or the week had too little data (`reason`).
struct DigestReply: Codable {
    struct Digest: Codable {
        /// The last completed Monday–Sunday.
        let weekStart: String
        let weekEnd: String
        /// Markdown, at most about 120 words.
        let text: String
        let generatedAt: String?
    }

    let configured: Bool
    @Lossy var digest: Digest?
    /// "not_configured" | "off" | "limit" | "no_data"
    let reason: String?
}

/// The Family board (GET /api/family): a small daily tile for everyone who shares, each against their own last
/// 30 days, never against each other. `sharing` false means the viewer turned it off: no today, no members.
struct FamilyBoard: Codable {
    let sharing: Bool
    /// The viewer's today, in their time zone.
    let today: String?
    /// The viewer first, then by name, as the server orders them. A member the app can't read drops only itself.
    @LossyArray var members: [FamilyMember]
}

/// One person's tile: all another member learns about them. Enum-like fields stay strings, so a status, device or
/// reason the app doesn't know yet shows nothing instead of failing the board.
struct FamilyMember: Codable, Identifiable {
    struct Sleep: Codable {
        let hours: Double
        /// Dated by the morning they woke: yesterday's means last night's hasn't synced yet.
        let date: String
        let usual: Double?
        /// Phone-only time in bed: shown, never judged.
        let inBed: Bool?
    }

    /// kind "recovery" (WHOOP, %) or "hrv" (ms; metric "hrv_rmssd" or "hrv_sdnn").
    struct Readiness: Codable {
        let kind: String
        let metric: String?
        let value: Double
        let date: String?
        let usual: Double?
    }

    /// Against their usual from the same device ("low" | "normal" | "high"), once there's a week to compare with.
    /// value and usual (whole bpm) are nil from servers older than the 30-day board.
    struct RestingHr: Codable {
        let status: String
        let date: String?
        let value: Double?
        let usual: Double?
    }

    /// Today's steps. asOfHour and usualByNow only when the phone or Watch counted them hour by hour.
    struct Steps: Codable {
        let value: Double
        /// "apple" | "whoop"
        let source: String?
        let asOfHour: Int?
        let usualByNow: Double?
    }

    let id: String
    let name: String
    let isYou: Bool
    let demo: Bool
    /// Their today, in their own time zone.
    let today: String
    /// Photo version for /api/family/:id/avatar.png; nil without one.
    let avatar: Double?
    /// "whoop" | "watch" | "iphone"
    let devices: [String]
    let latestDataDate: String?
    /// With status quiet: the newest data (or, with fresh phone data, the newest watch or WHOOP data).
    let quietSince: String?
    /// "good" | "off" | "check" | "quiet" | "learning"; nil for phone-only people (nothing to compare).
    let status: String?
    /// "recovery" | "hrv" | "resting_hr" | "sleep", only next to off or check.
    let reasons: [String]
    let sleep: Sleep?
    let readiness: Readiness?
    let restingHr: RestingHr?
    let steps: Steps?
    /// "period" | "follicular" | "luteal"; absent near the next period, so it can never imply "late".
    let cyclePhase: String?
    /// The last 30 days, for the tile's small charts and the person's page; nil from servers older than that board.
    let history: History?

    /// The avatar URL's `v`: an integer, never "1.7e+12".
    var avatarKey: String? { avatar.map { String(Int64($0)) } }

    /// The last 30 days of each metric, oldest first, as the person's own dashboard shows it. Each part decodes on
    /// its own: one the app can't read is empty or nil, and the rest still draw.
    struct History: Codable {
        /// Nights a watch or WHOOP measured; `inBed` when only the phone logged them (time in bed, marked as such).
        struct Sleep: Codable {
            let inBed: Bool
            @LossyArray var points: [Point]

            init(inBed: Bool, points: [Point]) {
                self.inBed = inBed
                self.points = points
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                inBed = (try? c.decodeIfPresent(Bool.self, forKey: .inBed)) ?? false
                _points = try c.decode(LossyArray<Point>.self, forKey: .points)
            }
        }

        /// readiness: "recovery" | "hrv_rmssd" | "hrv_sdnn"; load: "strain" (WHOOP, 0–21) | "energy" (active kcal).
        struct Series: Codable {
            let kind: String
            @LossyArray var points: [Point]

            init(kind: String, points: [Point]) {
                self.kind = kind
                self.points = points
            }
        }

        @Lossy var sleep: Sleep?
        @Lossy var readiness: Series?
        @LossyArray var steps: [Point]
        /// From one device: the one the latest reading came from.
        @LossyArray var restingHr: [Point]
        @Lossy var load: Series?

        init(sleep: Sleep?, readiness: Series?, steps: [Point], restingHr: [Point], load: Series?) {
            self.sleep = sleep
            self.readiness = readiness
            self.steps = steps
            self.restingHr = restingHr
            self.load = load
        }
    }
}

extension FamilyMember {
    private enum CodingKeys: String, CodingKey {
        case id, name, isYou, demo, today, avatar, devices, latestDataDate, quietSince, status, reasons, sleep, readiness, restingHr, steps, cyclePhase,
             history
    }

    /// Only the id is required; anything else missing or unreadable falls back, so one odd field can't hide a person.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys) -> T? { try? c.decodeIfPresent(T.self, forKey: key) }
        self.init(
            id: try c.decode(String.self, forKey: .id),
            name: value(.name) ?? "",
            isYou: value(.isYou) ?? false,
            demo: value(.demo) ?? false,
            today: value(.today) ?? "",
            avatar: value(.avatar),
            devices: (value(.devices) as [Lossy<String>]?)?.compactMap(\.wrappedValue) ?? [],
            latestDataDate: value(.latestDataDate),
            quietSince: value(.quietSince),
            status: value(.status),
            reasons: (value(.reasons) as [Lossy<String>]?)?.compactMap(\.wrappedValue) ?? [],
            sleep: value(.sleep),
            readiness: value(.readiness),
            restingHr: value(.restingHr),
            steps: value(.steps),
            cyclePhase: value(.cyclePhase),
            history: value(.history))
    }
}

struct ServerStatus: Codable {
    struct Settings: Codable {
        let name: String?
        let stepGoal: Double?
        let units: String?
        let timeZone: String?
        let sex: String?
        let cycleTracking: Bool?
        /// On the Family board (on unless turned off). Mutual: off, you neither see anyone nor are seen.
        /// nil from servers older than the Family board.
        let familySharing: Bool?
        /// Your cycle phase on your Family tile; only while cycle tracking and sharing are on.
        let shareCyclePhase: Bool?
        /// The one-time note that the Family board shows your daily status was dismissed.
        let familyNoticeSeen: Bool?
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
    /// Face box [x, y, w, h], 0–1 within the cut-out. Labels stay off it.
    let face: [Double]?
    @Lossy var dots: Dots?

    var versionKey: String { String(Int64(version)) }

    static func == (a: PhotoMeta, b: PhotoMeta) -> Bool { a.version == b.version && a.width == b.width && a.height == b.height && a.face == b.face && a.dots == b.dots }
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

/// Decodes an array element by element, dropping the ones it can't read; a missing, null or malformed array is empty.
@propertyWrapper
struct LossyArray<Element: Codable>: Codable {
    var wrappedValue: [Element]

    init(wrappedValue: [Element]) {
        self.wrappedValue = wrappedValue
    }

    init(from decoder: Decoder) throws {
        // Lossy never throws, so every element is consumed, readable or not.
        wrappedValue = ((try? [Lossy<Element>](from: decoder)) ?? []).compactMap(\.wrappedValue)
    }

    func encode(to encoder: Encoder) throws {
        try wrappedValue.encode(to: encoder)
    }
}

extension KeyedDecodingContainer {
    func decode<V>(_ type: Lossy<V>.Type, forKey key: Key) throws -> Lossy<V> {
        (try? decodeIfPresent(type, forKey: key)) ?? Lossy(wrappedValue: nil)
    }

    func decode<E>(_ type: LossyArray<E>.Type, forKey key: Key) throws -> LossyArray<E> {
        (try? decodeIfPresent(type, forKey: key)) ?? LossyArray(wrappedValue: [])
    }
}
