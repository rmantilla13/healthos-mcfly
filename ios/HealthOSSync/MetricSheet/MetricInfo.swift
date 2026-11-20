import Foundation

// What a metric's detail sheet knows about each metric before the server answers (METRIC_INFO in shared/metrics.ts),
// and the sheet's own words (src/components/MetricSheet.tsx). The server's answer carries the values, the unit in the
// person's units and the sentence; "What this means" isn't in it, so it's bundled here. MetricSheetTests reads both
// web files and fails if a word here differs.

/// How the sheet draws a metric over a week, month or year: a line for readings, bars for a day's total.
enum MetricChart: String {
    case trend, bars
}

/// The sheet's "What this means": the metric in one plain sentence, what to keep in mind about it, and a reputable page
/// to read on.
struct MetricAbout: Equatable {
    let what: String
    let caveat: String
    let sourceLabel: String
    let sourceURL: URL
}

/// One metric as the sheet shows it (MetricInfo in shared/metrics.ts).
struct MetricInfo: Equatable {
    let label: String
    /// The stored unit. Mass is converted to the person's units (kg or lb) by the server, so a sheet's own unit wins.
    let unit: String
    /// Decimal places a value is shown with.
    let digits: Int
    /// Hours shown as hours and minutes (sleep).
    var duration = false
    let chart: MetricChart
    /// In the order the sheet offers them.
    let ranges: [MetricRange]
    /// The range a sheet opens on.
    let initial: MetricRange
    let about: MetricAbout
}

extension MetricRange {
    /// The range's button (RANGE_LABEL).
    var label: String {
        switch self {
        case .day: "Day"
        case .week: "Week"
        case .month: "Month"
        case .year: "Year"
        }
    }

    /// The rolling window's length, ending on the day asked for (RANGE_DAYS); nil for a Day.
    var days: Int? {
        switch self {
        case .day: nil
        case .week: 7
        case .month: 30
        case .year: 365
        }
    }

    /// The window as the sheet says it (RANGE_WINDOW); nil for a Day.
    var window: String? {
        switch self {
        case .day: nil
        case .week: "the last 7 days"
        case .month: "the last 30 days"
        case .year: "the last 12 months"
        }
    }
}

extension MetricKey {
    private static let all: [MetricRange] = [.week, .month, .year]
    private static let withDay: [MetricRange] = [.day, .week, .month, .year]
    private static let wearable = "A wearable reading is a signal to put in context, not a diagnosis."
    private static let score = "A score is a signal to put in context, not a diagnosis."

    private static func about(_ what: String, _ caveat: String, _ label: String, _ href: String) -> MetricAbout {
        MetricAbout(what: what, caveat: caveat, sourceLabel: label, sourceURL: URL(string: href)!)
    }

    private static func clevelandHR(_ what: String, _ caveat: String) -> MetricAbout {
        about(what, caveat, "Cleveland Clinic · Heart rate", "https://my.clevelandclinic.org/health/diagnostics/heart-rate")
    }

    private static func muscleFat(_ what: String, _ caveat: String) -> MetricAbout {
        about(what, caveat, "Cleveland Clinic · Muscle weight vs. fat weight", "https://health.clevelandclinic.org/muscle-vs-fat-weight")
    }

    /// The bundled copy of METRIC_INFO.
    var info: MetricInfo {
        switch self {
        case .restingHr:
            MetricInfo(label: "Resting heart rate", unit: "bpm", digits: 0, chart: .trend, ranges: Self.all, initial: .month, about: Self.clevelandHR(
                "How many times a minute your heart beats while you're fully at rest. WHOOP reads it as you sleep; Apple Watch and Fitbit also use still moments in the day.",
                "\(Self.wearable) Illness, alcohol, heat, stress and a hard day's training can all raise it for a while."))
        case .hrv:
            MetricInfo(label: "Heart rate variability", unit: "ms", digits: 0, chart: .trend, ranges: Self.all, initial: .month, about: Self.about(
                "How much the time between your heartbeats varies, a sign of how your body is balancing stress and rest. It's personal: compare it with your own usual.",
                "\(Self.wearable) WHOOP and Fitbit measure RMSSD as you sleep and Apple Watch measures SDNN, so the two don't compare.",
                "Cleveland Clinic · Heart rate variability", "https://my.clevelandclinic.org/health/symptoms/21773-heart-rate-variability-hrv"))
        case .sleepHours:
            MetricInfo(label: "Sleep", unit: "h", digits: 1, duration: true, chart: .trend, ranges: Self.all, initial: .week, about: Self.about(
                "The time you spent asleep, not just in bed. Most adults need between 7 and 9 hours a night.",
                "\(Self.wearable) A device estimates sleep from movement and heart rate, so short wakings are its best guess.",
                "NHLBI · How much sleep is enough?", "https://www.nhlbi.nih.gov/health/sleep/how-much-sleep"))
        case .recovery:
            MetricInfo(label: "Recovery", unit: "%", digits: 0, chart: .trend, ranges: Self.all, initial: .month, about: Self.about(
                "WHOOP's daily score, 0 to 100%, of how ready your body is to take on strain, mostly from your heart rate variability, resting heart rate and sleep.",
                "\(Self.score) It's WHOOP's own measure, judged against your own baseline.",
                "WHOOP · How does WHOOP Recovery work?", "https://www.whoop.com/us/en/thelocker/how-does-whoop-recovery-work-101/"))
        case .strain:
            MetricInfo(label: "Day strain", unit: "", digits: 1, chart: .bars, ranges: Self.all, initial: .week, about: Self.about(
                "WHOOP's measure, from 0 to 21, of the load on your heart and muscles over a day. Each point takes more effort than the last.",
                "\(Self.score) Stress or illness that keeps your heart rate up counts toward it too.",
                "WHOOP · How does WHOOP Strain work?", "https://www.whoop.com/us/en/thelocker/how-does-whoop-strain-work-101/"))
        case .steps:
            MetricInfo(label: "Steps", unit: "steps", digits: 0, chart: .bars, ranges: Self.withDay, initial: .week, about: Self.about(
                "The steps you took in a day. In large studies, more steps a day went with better long-term health, more than how fast they were taken.",
                "A count is a signal to put in context, not a diagnosis. A phone left on a desk misses steps, and cycling or swimming barely counts.",
                "NIH · Number of steps per day more important than step intensity",
                "https://www.nih.gov/news-events/nih-research-matters/number-steps-day-more-important-step-intensity"))
        case .activeEnergy:
            MetricInfo(label: "Active energy", unit: "kcal", digits: 0, chart: .bars, ranges: Self.withDay, initial: .week, about: Self.about(
                "The calories you burned by moving, on top of what your body uses at rest. It's what Apple Watch's Move ring counts.",
                "An estimate from movement and heart rate, so a signal to put in context rather than an exact count. Without a watch, your iPhone estimates it from your steps.",
                "Apple · Track daily activity with Apple Watch", "https://support.apple.com/guide/watch/track-daily-activity-apd3bf6d85a6/watchos"))
        case .spo2:
            MetricInfo(label: "Blood oxygen", unit: "%", digits: 1, chart: .trend, ranges: Self.all, initial: .month, about: Self.about(
                "An estimate of the percentage of oxygen-saturated haemoglobin in your blood. Higher is better: 95 to 100% is normal for most people, and 92% or lower is low.",
                "\(Self.wearable) Sensor fit and measurement conditions matter, and it can read lower at altitude or with a lung condition such as COPD, where your clinician may give you your own target.",
                "Cleveland Clinic · Blood oxygen level", "https://my.clevelandclinic.org/health/diagnostics/22447-blood-oxygen-level"))
        case .respRate:
            MetricInfo(label: "Respiratory rate", unit: "breaths/min", digits: 1, chart: .trend, ranges: Self.all, initial: .month, about: Self.about(
                "How many breaths you take a minute, measured as you sleep. Most adults breathe 12 to 18 times a minute at rest.",
                "\(Self.wearable) A rise above your own usual often comes with illness, heat or a hard day.",
                "Cleveland Clinic · Vital signs", "https://my.clevelandclinic.org/health/articles/10881-vital-signs"))
        case .glucose:
            MetricInfo(label: "Glucose", unit: "mg/dL", digits: 0, chart: .trend, ranges: Self.all, initial: .month, about: Self.about(
                "The sugar in your blood, from a continuous glucose monitor or a meter. Each day here is the average of that day's readings.",
                "A day's average hides its highs and lows, so it's a signal to put in context, not a diagnosis. Your clinician can tell you your own targets.",
                "NIDDK · Continuous glucose monitoring",
                "https://www.niddk.nih.gov/health-information/diabetes/overview/managing-diabetes/continuous-glucose-monitoring"))
        case .weight:
            MetricInfo(label: "Weight", unit: "kg", digits: 1, chart: .trend, ranges: Self.all, initial: .month, about: Self.about(
                "Your body weight. It moves from day to day with water, food and salt, so the trend over weeks says more than one weigh-in.",
                "A signal to put in context, not a diagnosis. Weigh at the same time of day on the same scale, so readings compare.",
                "NHS · Healthy weight", "https://www.nhs.uk/live-well/healthy-weight/"))
        case .bodyFat:
            MetricInfo(label: "Body fat", unit: "%", digits: 1, chart: .trend, ranges: Self.all, initial: .month, about: Self.muscleFat(
                "The share of your weight that's fat. A smart scale estimates it by sending a small electrical current through your body.",
                "An estimate that can be several points off and moves with how much water you carry, so it's a signal to put in context, not a diagnosis."))
        case .leanMass:
            MetricInfo(label: "Lean body mass", unit: "kg", digits: 1, chart: .trend, ranges: Self.all, initial: .month, about: Self.muscleFat(
                "Everything in your body that isn't fat: muscle, bone, organs and water. A smart scale estimates it from your weight and body fat.",
                "An estimate that moves with how much water you carry, so it's a signal to put in context, not a diagnosis."))
        case .vo2max:
            MetricInfo(label: "Cardio fitness (VO₂ max)", unit: "mL/kg·min", digits: 1, chart: .trend, ranges: Self.all, initial: .month, about: Self.about(
                "The most oxygen your body can use in hard exercise, a measure of cardio fitness. Apple Watch estimates it from outdoor walks, runs and hikes.",
                "An estimate, not a lab test, so a signal to put in context rather than a diagnosis. Medicines that limit your heart rate can make it read high.",
                "Apple · Track your cardio fitness levels", "https://support.apple.com/en-us/108790"))
        case .heartRate:
            MetricInfo(label: "Heart rate", unit: "bpm", digits: 0, chart: .trend, ranges: [.day], initial: .day, about: Self.clevelandHR(
                "Your heart rate through the day: each hour is the average of that hour's readings, with its lowest and highest.",
                "\(Self.wearable) Exercise, caffeine, stress and heat all raise it for a while."))
        case .sleepPerformance:
            MetricInfo(label: "Sleep performance", unit: "%", digits: 0, chart: .trend, ranges: Self.all, initial: .month, about: Self.about(
                "WHOOP's score for a night, 0 to 100%: how much of the sleep you needed you got, and in its newer version how consistent, efficient and calm that sleep was.",
                "\(Self.score) It's WHOOP's own measure, and its formula has changed over time.",
                "WHOOP · WHOOP Sleep", "https://support.whoop.com/s/article/WHOOP-Sleep?language=en_US"))
        case .sleepEfficiency:
            MetricInfo(label: "Sleep efficiency", unit: "%", digits: 0, chart: .trend, ranges: Self.all, initial: .month, about: Self.about(
                "The share of your time in bed that you spent asleep. A slow start to the night or long wakings lower it.",
                "\(Self.wearable) A device estimates when you're asleep, and reading in bed counts as time awake.",
                "WHOOP · Sleep efficiency", "https://www.whoop.com/us/en/thelocker/app-feature-improve-sleep-efficiency/"))
        }
    }

    /// The daily metric GET /api/trends keeps it under, for a server without the sheet (HRV: the one the summary shows;
    /// heart rate has only hours).
    func trendMetric(hrv: String?) -> String? {
        switch self {
        case .hrv: hrv ?? "hrv_rmssd"
        case .heartRate: nil
        default: rawValue
        }
    }

    /// Kept in kg and shown in the person's units.
    var isMass: Bool { self == .weight || self == .leanMass }

    /// A day's running total (steps, energy, strain): today's isn't over, so it's drawn but left out of the figures.
    var isSummed: Bool { self == .strain || self == .steps || self == .activeEnergy }

    /// The chart's colour (SheetChart): strain, energy and the heart rates in the warm series, the rest in blue.
    var warmSeries: Bool { self == .strain || self == .activeEnergy || self == .restingHr || self == .heartRate }

    /// The Day view's metric for its hours (HoursChart): steps and energy as a running total, heart rate by hour.
    var hourMetric: HourMetric? {
        switch self {
        case .steps: .steps
        case .activeEnergy: .energy
        case .heartRate: .heart
        default: nil
        }
    }
}

/// Blood glucose: mg/dL per mmol/L (MG_DL_PER_MMOL_L, glucose's molar mass over 10).
enum Glucose {
    static let mgDlPerMmolL = 18.016
    static func mmol(fromMgDl mgDl: Double) -> Double { mgDl / mgDlPerMmolL }
}

/// The sheet's own words (MetricSheet.tsx).
enum SheetWords {
    /// Where values came from (SOURCE).
    static let sources: [String: String] = ["apple": "Apple Health", "whoop": "WHOOP", "fitbit": "Fitbit", "manual": "Added by you", "demo": "Demo data"]

    /// What one day's value is, where it isn't simply the day's reading (DAY_NOTE).
    static let dayNotes: [MetricKey: String] = [
        .glucose: "each day is the average of that day's readings",
        .weight: "each day is that day's last weigh-in",
        .bodyFat: "each day is that day's last reading",
        .leanMass: "each day is that day's last reading",
        .sleepHours: "each night counts toward the morning it ends",
        .sleepPerformance: "each night counts toward the morning it ends",
        .sleepEfficiency: "each night counts toward the morning it ends",
    ]

    /// How to add a reading by hand (OWN_ENTRY).
    static let ownEntry = "Add an entry on Body, or connect a smart scale through Apple Health."

    /// An empty window's line when no longer range can help, by metric (EMPTY).
    static let empty: [MetricKey: String] = [
        .glucose: "Glucose appears when a CGM or meter writes to Apple Health.",
        .weight: ownEntry,
        .bodyFat: ownEntry,
        .leanMass: ownEntry,
        .recovery: "Recovery comes from WHOOP.",
        .strain: "Day strain comes from WHOOP.",
        .vo2max: "Cardio fitness comes from Apple Watch, after outdoor walks and runs.",
        .sleepPerformance: "Sleep performance comes from WHOOP.",
        .sleepEfficiency: "Sleep efficiency comes from WHOOP or Fitbit, or from Apple Watch nights that record time in bed.",
    ]

    /// Metrics a person can type in themselves (Body): a never-measured one says how (OWN_ENTRIES).
    static let ownEntries: Set<MetricKey> = [.weight, .bodyFat, .leanMass]

    static let neverTitle = "No measurement yet."
    static let neverText = "Connect a source or import measured data to see your trend."
    static let manageConnections = "Manage connections"
    static let noHours = "Hour-by-hour readings come from Apple Watch and iPhone, through the healthOS iPhone app."
    static let nothingRecorded = "Nothing recorded in this range."
    static let loading = "Loading…"
    static let couldNotLoad = "Couldn't load this: "
    static let whatThisMeans = "What this means"
    static let understandYour = "Understand your "
    static let byTheHourRunning = "By the hour, running total"
    static let byTheHour = "By the hour"
    static let typicalNote = "Dashed: your typical day, the median of the last 30 days"
    static let weekly = "Weekly averages of the daily values"
    static let eachNight = "Each night"
    static let eachDay = "Each day"
    static let todaySoFar = "Today's bar is so far today"
    static let latestReading = " (the latest reading)"
    /// A reply without the server's own words, as the web says it (parse in src/lib.ts).
    static let somethingWrong = "Something went wrong. Try again in a moment."
}
