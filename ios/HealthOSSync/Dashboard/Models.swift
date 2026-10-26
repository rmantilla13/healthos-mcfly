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
    /// "normal" | "unusual" | "off": how far from usual, on the same band as `status`. nil from older servers.
    let level: String?
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
    /// Resting heart rate and respiratory rate over the last 30 days, for the web's Home cards. nil from older servers.
    @Lossy var restingHr: Reading?
    @Lossy var respRate: Reading?

    /// Each vital on its own, so one the app can't read leaves the others.
    struct Vitals: Codable {
        @Lossy var heart: Vital?
        @Lossy var breathing: Vital?
        @Lossy var temp: Vital?
        /// nil from servers older than the Blood oxygen callout.
        @Lossy var spo2: Vital?
    }

    /// A reading over the last 30 days: the latest, and the days before it.
    struct Reading: Codable {
        @Lossy var latest: Latest?
        @LossyArray var series: [Point]
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

    /// Typical values over recent cycles, in days. The last four are missing from servers before the rebuilt engine.
    struct Stats: Codable {
        let cycleDays: Int?
        let periodDays: Int?
        let shortest: Int?
        let longest: Int?
        /// Longest less shortest; regular when it's 9 days or less (FIGO 2018).
        let variation: Int?
        let regular: Bool?
        let follicularDays: Int?
        let lutealDays: Int?
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
        /// "calendar" | "lh_test" | "bbt" (a temperature rise from any device)
        let basis: String?
        /// How many of the person's own cycles it rests on. Below 2, typical cycles fill in (only in `earlyEstimate`).
        let cycles: Int?
        /// "low" | "medium" | "high"
        let confidence: String?
        /// With basis "bbt": "bbt" (thermometer) | "wrist" (Apple Watch) | "skin" (WHOOP).
        let tempSource: String?
    }

    /// One cycle, from a period's first day to the day before the next.
    struct History: Codable, Identifiable {
        struct Ovulation: Codable {
            let date: String
            /// "bbt" | "lh_test"
            let basis: String
            let tempSource: String?
        }

        struct Temperature: Codable {
            /// "bbt" | "wrist" | "skin"
            let source: String
            let readings: Int
            /// °C deviations: the level the rise had to clear, and how far the readings after it sat above those before.
            let coverline: Double?
            let rise: Double?
        }

        let start: String
        /// nil for the current cycle.
        let end: String?
        /// Length; for the current cycle, days so far.
        let days: Int
        let periodDays: Int?
        @Lossy var ovulation: Ovulation?
        /// "confirmed" | "lh_test" | "waiting" | "not_found" | "no_data"
        let status: String?
        let follicularDays: Int?
        let lutealDays: Int?
        @Lossy var temperature: Temperature?

        var id: String { start }
    }

    /// One night's or morning's temperature, against the person's own level on that device.
    struct Temperature: Codable {
        let date: String
        let source: String
        /// °C as measured.
        let value: Double
        /// °C above or below the person's usual level on that device.
        let deviation: Double
        /// "disturbed" | "outlier" when left out of the analysis.
        let excluded: String?
    }

    /// One day's estimated chance of conception, relative to the most fertile day (1). Only days that matter are listed.
    struct Fertility: Codable {
        let date: String
        let chance: Double
        /// "medium" | "high" | "peak"
        let level: String
        /// "estimate" | "logged"
        let basis: String?
    }

    /// Patterns from the person's own cycles.
    struct Insights: Codable {
        struct Body: Codable {
            /// "resting_hr" | "hrv" | "temperature"
            let metric: String
            let follicular: Double
            let luteal: Double
            /// "bpm" | "ms" | "°C"
            let unit: String
            let cycles: Int
        }

        struct SymptomPattern: Codable {
            let symptom: String
            let days: Int
            let cycles: Int
            /// The phase most of them fall in, nil when they're spread out.
            let phase: String?
        }

        struct Deviation: Codable {
            /// "frequent" | "infrequent" | "irregular" | "prolonged" | "spotting"
            let kind: String
            let count: Int
            let of: Int
            /// irregular only: longest less shortest, in days.
            let spread: Int?
        }

        @LossyArray var body: [Body]
        @LossyArray var symptoms: [SymptomPattern]
        @LossyArray var deviations: [Deviation]
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
    /// With fewer than two complete cycles: the estimate, leaning on typical cycles. Missing from older servers.
    @Lossy var earlyEstimate: Estimate?
    /// Every cycle, oldest first; empty from older servers.
    @LossyArray var history: [History]
    /// Temperatures in the window asked for, oldest first.
    @LossyArray var temperatures: [Temperature]
    /// The current cycle's estimated fertile days, oldest first.
    @LossyArray var fertility: [Fertility]
    @Lossy var insights: Insights?

    /// The estimate to show: the full one, else the early one.
    var shownEstimate: Estimate? { estimate ?? earlyEstimate }
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
    /// shared/types.ts Settings. Each field is read on its own (init(from:) below): one the app can't read is nil, not
    /// the whole settings, so an odd value can't hide the Family tab, switch units or turn Nutrition off. A field an
    /// older server doesn't send is nil too.
    struct Settings: Codable {
        let name: String?
        let stepGoal: Double?
        let units: String?
        /// Demo data while there's none of your own: "auto" | "on" | "off".
        let demo: String?
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
        /// Nutrition is on (the Nutrition section, GET /api/nutrition). Off by default; only the person turns it on.
        let nutrition: Bool?
        /// How much of their nutrition they see: "all" | "no_energy" | "none". nil until chosen.
        let nutritionNumbers: String?
        /// The app whose totals count on a day two apps logged food; nil is whichever logged the most that day.
        let nutritionApp: String?
        /// Targets they set themselves, if any. Shown as a plain line, never scored. Older servers have none.
        let nutritionTargets: NutritionTargets?
        /// Card ids (shared/cards.ts) this person hid. nil from servers older than card hiding.
        let hiddenCards: [String]?
        /// Optional cards (defaultHidden in shared/cards.ts) this person turned on. nil from servers older than
        /// optional cards, where every card shows unless it's hidden. A var for SummaryCache, which fills it in for a
        /// status cached by a build that didn't keep it.
        var shownCards: [String]?
        /// How Home and Body show you: "portrait" | "digital" | "stats". nil from servers older than onboarding, which
        /// read it as "portrait".
        let perspective: String?
        /// How the person describes themselves: "woman" | "man" | "nonbinary" | "unsaid". Never used for health
        /// calculations (that's `sex`).
        let gender: String?
        /// Which digital human to show: "woman" | "man"; nil follows gender.
        let figure: String?
        /// Age in whole years; nil until given.
        let age: Int?
        /// In anonymous peer comparisons. Off unless the person ticked it.
        let peerComparison: Bool?
        /// The onboarding step a new account is on (1, 2 or 3); nil when it's done, and from older servers.
        let onboarding: Int?
    }

    struct Apple: Codable {
        struct Sync: Codable { let syncedAt: String }
        struct Import: Codable { let importedAt: String }
        /// The Mac's export import while it runs (shared/types.ts ImportJob).
        struct Job: Codable {
            /// "idle" | "uploading" | "parsing" | "done" | "error"
            let state: String
            let bytesRead: Double?
            let totalBytes: Double?
            let records: Double?
            let days: Double?
            let error: String?
        }
        @Lossy var lastSync: Sync?
        @Lossy var lastImport: Import?
        @Lossy var job: Job?
        /// This person has made an iPhone app token (Integrations). nil from older servers.
        @Lossy var iphoneToken: Bool?
    }

    /// A Fitbit (Google Takeout) export read in the browser and sent to the server. nil from older servers.
    struct Fitbit: Codable {
        struct Import: Codable {
            let days: Double?
            let firstDate: String?
            let lastDate: String?
            @LossyArray var metrics: [String]
            let importedAt: String
        }
        @Lossy var lastImport: Import?
    }

    struct Whoop: Codable {
        let configured: Bool?
        let connected: Bool?
        let syncing: Bool?
        let lastSync: String?
        let lastError: String?
    }

    // Each part on its own, like the settings: one the app can't read leaves the rest.
    @Lossy var hosted: Bool?
    @Lossy var demo: Bool?
    /// POST /api/sync only: a WHOOP sync started on the server for this request.
    @Lossy var whoopStarted: Bool?
    /// Who's signed in. On a server without sign-in it's the owner, with no email.
    @Lossy var user: AuthState.User?
    @Lossy var photo: PhotoMeta?
    @Lossy var settings: Settings?
    @Lossy var apple: Apple?
    @Lossy var whoop: Whoop?
    @Lossy var fitbit: Fitbit?
}

extension ServerStatus.Settings {
    private enum CodingKeys: String, CodingKey {
        case name, stepGoal, units, demo, timeZone, sex, cycleTracking, familySharing, shareCyclePhase, familyNoticeSeen, nutrition,
             nutritionNumbers, nutritionApp, nutritionTargets, hiddenCards, shownCards, perspective, gender, figure, age, peerComparison,
             onboarding
    }

    /// Field by field: one missing or unreadable is nil, and a card list keeps the ids it can read.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys) -> T? { try? c.decodeIfPresent(T.self, forKey: key) }
        func ids(_ key: CodingKeys) -> [String]? { (value(key) as [Lossy<String>]?)?.compactMap(\.wrappedValue) }
        self.init(
            name: value(.name),
            stepGoal: value(.stepGoal),
            units: value(.units),
            demo: value(.demo),
            timeZone: value(.timeZone),
            sex: value(.sex),
            cycleTracking: value(.cycleTracking),
            familySharing: value(.familySharing),
            shareCyclePhase: value(.shareCyclePhase),
            familyNoticeSeen: value(.familyNoticeSeen),
            nutrition: value(.nutrition),
            nutritionNumbers: value(.nutritionNumbers),
            nutritionApp: value(.nutritionApp),
            nutritionTargets: value(.nutritionTargets),
            hiddenCards: ids(.hiddenCards),
            shownCards: ids(.shownCards),
            perspective: value(.perspective),
            gender: value(.gender),
            figure: value(.figure),
            age: value(.age),
            peerComparison: value(.peerComparison),
            onboarding: value(.onboarding))
    }
}

/// Daily targets a person set for themselves (shared/types.ts NutritionTargets); nil means none. healthOS never suggests one.
struct NutritionTargets: Codable, Equatable {
    var energy_kcal: Double?
    var protein_g: Double?
    var water_ml: Double?
}

/// How much of their nutrition a person chose to see. The server removes everything else before it answers.
enum NutritionMode: String {
    case all
    case noEnergy = "no_energy"
    case none
}

/// GET /api/nutrition (server/nutrition.ts): what a person logs in a food app, read through Apple Health, one app a
/// day, never summed. Empty unless Nutrition is on. Servers before the Neka layout send no targets, hydration or insights.
struct NutritionData: Codable {
    struct Hydration: Codable {
        /// mL by day, from any app (the daily water_ml metric).
        @LossyArray var water: [Point]
        /// mg by day (caffeine_mg).
        @LossyArray var caffeine: [Point]
    }

    let enabled: Bool
    /// "all" | "no_energy" | "none"; nil while Nutrition is off.
    let numbers: String?
    let today: String
    let start: String
    let end: String
    /// Apps with data in the window, most days first.
    @LossyArray var apps: [String]
    /// The app chosen for days two apps logged; nil is automatic.
    let app: String?
    /// Days with something logged, oldest first. A day missing here is a gap, never a zero.
    @LossyArray var days: [FoodDay]
    /// The person's own targets, as far as their setting shows them: energy_kcal, protein_g, water_ml.
    @Lossy var targets: [String: Double]?
    @Lossy var hydration: Hydration?
    /// Food patterns (caffeine and sleep, drinks and HRV), only when asked for with insights=1.
    @LossyArray var insights: [Pattern]

    var mode: NutritionMode { NutritionMode(rawValue: numbers ?? "") ?? .none }
    var water: [Point] { hydration?.water ?? [] }
    var caffeine: [Point] { hydration?.caffeine ?? [] }
}

/// One logged day: the app used that day and its totals, as the setting allows (no energy in "no_energy", empty in "none").
struct FoodDay: Codable, Identifiable {
    let date: String
    let app: String
    let values: [String: Double]
    /// Other apps that logged food that day: shown, never added in, because apps copy each other's logs.
    @LossyArray var otherApps: [String]
    var id: String { date }
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
    /// Where the shoulders are, 0–1 down the cut-out. nil from older servers.
    @Lossy var shoulderY: Double?
    /// The silhouette by row (100 rows, top to bottom): [left, right], 0–1 of the width; [1, 0] where empty.
    @Lossy var outline: [[Double]]?

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

extension Lossy: Equatable where Value: Equatable {}
extension LossyArray: Equatable where Element: Equatable {}

extension KeyedDecodingContainer {
    func decode<V>(_ type: Lossy<V>.Type, forKey key: Key) throws -> Lossy<V> {
        (try? decodeIfPresent(type, forKey: key)) ?? Lossy(wrappedValue: nil)
    }

    func decode<E>(_ type: LossyArray<E>.Type, forKey key: Key) throws -> LossyArray<E> {
        (try? decodeIfPresent(type, forKey: key)) ?? LossyArray(wrappedValue: [])
    }
}
