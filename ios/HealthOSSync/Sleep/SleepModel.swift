import SwiftUI

// The Sleep page's state (src/pages/Sleep.tsx): its tabs, the web's words, what it reads and what came back. The page
// holds one SleepModel above its DuoPage, so a fold or a band change never reads anything again or loses a tab, and its
// identity is one person's on one server (SleepScreen), so nothing read for the last person is ever on screen for the next.

/// The page's four tabs (Sleep.tsx TABS); the web's ?tab= picks one, anything else is the Overview.
enum SleepTab: String, CaseIterable, Identifiable {
    case overview, stages, trends, coaching

    var id: String { rawValue }

    var label: String {
        switch self {
        case .overview: "Overview"
        case .stages: "Stages"
        case .trends: "Trends"
        case .coaching: "Coaching"
        }
    }

    /// The tab a link's ?tab= names; the Overview for none, or one the page doesn't have.
    init(query: String?) { self = query.flatMap(SleepTab.init(rawValue:)) ?? .overview }
}

/// The web's words on the Sleep page, quoted from Sleep.tsx (SleepTests checks them against it).
enum SleepWords {
    static let title = "Your night, in perspective."
    static let sub = "Understand and improve your rest. Each night counts on the day you wake up."
    /// Before the first night from any source.
    static let subNone = "Connect a wearable to see your sleep."
    static let noNight = "No sleep recorded for this night."
    static let tabsLabel = "Sleep"
    static func couldntLoad(_ message: String) -> String { "Couldn't load your sleep: \(message)" }

    /// "Last night" for the latest night, else "Night to Tue, Oct 20".
    static func nightLabel(_ date: String, today: String) -> String {
        date == today ? "Last night" : "Night to \(Fmt.day(date, "EEEMMMd"))"
    }

    // The three cards.
    static let performanceFoot = "WHOOP: the sleep you got against the sleep you needed"
    static let efficiencyFoot = "Time asleep as a share of time in bed"
    static let performanceNoReading = ["No reading yet", "Sleep performance comes from WHOOP"]
    static let whoopOnly = "WHOOP only"
    static let noWhoopNight = "No WHOOP sleep for this night"
    static let efficiencyNoReading = ["No reading for this night", "It needs time asleep and time in bed from one device"]
    static let sleepChange = "This week's average night against last week's"

    // The night's cards.
    static let noStages = "No stages for this night. Apple Watch, WHOOP and Fitbit all record them."
    static let whoopStages = "WHOOP shares each stage's total, not when in the night it happened."
    static let fitbitStages = "The Fitbit export has this night's stage totals, not when in the night each happened."
    static let resentStages = "The stages through the night arrive once the healthOS iPhone app is updated and syncs."
    static let oldStages = "The stages through the night aren't available for this night."
    static let insightsEmpty = "Insights appear after a week or two of nights."
    static let whoopTimeline = "From WHOOP's sleep record: when it started and ended."
    static let noRestingHr = "No resting heart rate yet."

    // Coaching.
    static func needsAWeek(_ nights: Int) -> String {
        "This needs a week of nights. " + (nights == 1 ? "There is 1 so far." : "There are \(nights) so far.")
    }
    static let needNote = "Your own median over the last 60 nights, held within 7–9 hours"
    static let needTwoWeeks = "Needs two weeks of nights"
    static let debtNote = "Hours short of your need, added up"
    static let patternsEmpty = "Nothing stands out yet. Patterns need a few months of days with and without each habit."
    static let patternsNote = "These are your own days compared with each other. They show what tends to go together, not what causes what."

    /// The iPhone app sends the last month's nights again once, with their stages (SyncState.recentDays).
    static let resentDays = 30

    /// Under the stages chart, for a night with totals but no stages through it: why, by its source and age.
    static func stagesNote(source: String?, date: String, today: String) -> String {
        switch source {
        case "whoop": whoopStages
        case "fitbit": fitbitStages
        default: Fmt.daysBetween(date, today) <= resentDays ? resentStages : oldStages
        }
    }

    /// Good, Fair or Low for a 0–100 score (Sleep.tsx band).
    static func band(_ value: Double) -> String { value >= 85 ? "Good" : value >= 70 ? "Fair" : "Low" }

    /// "Weekends run 48m later than weekdays" when the gap is half an hour or more, else "Over 31 nights".
    static func usualTimesFoot(_ stats: SleepTiming.Stats) -> String {
        if let jetlag = stats.socialJetlag, abs(jetlag) >= 30 {
            return "Weekends run \(Fmt.hoursMinutes(abs(jetlag) / 60)) \(jetlag > 0 ? "later" : "earlier") than weekdays"
        }
        return "Over \(stats.nights) nights"
    }

    /// Minutes after 18:00 as a clock time (330 is 23:30), and minutes after midnight as one (Sleep.tsx fromSix, ofDay).
    static func fromSix(_ minutes: Double) -> String {
        let t = (Int((minutes + 18 * 60).rounded()) % 1440 + 1440) % 1440
        return String(format: "%02d:%02d", t / 60, t % 60)
    }

    static func ofDay(_ minutes: Double) -> String {
        String(format: "%02d:%02d", (Int(minutes / 60) % 24 + 24) % 24, Int(minutes.truncatingRemainder(dividingBy: 60).rounded()))
    }
}

/// What the page reads, as closures so the tests can answer in the server's place and count the reads. Each live one
/// goes through `fetchForThisSession` (the Dashboard's own reads do too), so an answer that lands after a sign-out,
/// someone else's sign-in or another server is dropped, never shown.
struct SleepReads {
    /// GET /sleep/night?date=; nil from a server without it.
    var night: @MainActor (Dashboard, String?) async throws -> SleepNightDetail?
    /// GET /trends?metrics=resting_hr&days=14&date=.
    var restingHr: @MainActor (Dashboard, String?) async throws -> [Point]
    /// GET /patterns; nil from a server without it.
    var patterns: @MainActor (Dashboard) async throws -> Patterns?
    /// GET /sleep?days=60; nil from a server without it.
    var timing: @MainActor (Dashboard) async throws -> SleepTiming?
    /// GET /trends for the Stages and Trends tabs.
    var trends: @MainActor (Dashboard, [String], Int) async throws -> Trends

    static var live: SleepReads {
        SleepReads(night: { d, date in try await d.fetchForThisSession { try await $0.sleepNight(date: date) } },
                   restingHr: { d, date in try await d.fetchForThisSession { try await $0.sleepRestingHr(date: date) } },
                   patterns: { try await $0.patterns() },
                   timing: { try await $0.sleepTiming(days: 60) },
                   trends: { d, metrics, days in try await d.trends(metrics, days: days) })
    }
}

private struct SleepReadsKey: EnvironmentKey {
    static var defaultValue: SleepReads { .live }
}

extension EnvironmentValues {
    /// The Sleep page's reads; tests put their own in.
    var sleepReads: SleepReads {
        get { self[SleepReadsKey.self] }
        set { self[SleepReadsKey.self] = newValue }
    }
}

/// Where one read stands.
enum SleepRead<Value> {
    /// Not answered yet.
    case loading
    case loaded(Value)
    /// The server has no such route (an older one): the feature hides.
    case missing
    /// Offline or a server error: the message, never "not set up".
    case failed(String)

    var value: Value? {
        if case .loaded(let v) = self { return v }
        return nil
    }

    var isMissing: Bool {
        if case .missing = self { return true }
        return false
    }
}

/// The page's state, held above its DuoPage. Each read is for one key (its date, range and the Dashboard's load), and
/// an answer for a key that isn't the current one any more (the night changed, the range changed, a newer load) is
/// dropped when it lands.
@MainActor @Observable
final class SleepModel {
    /// The tab on screen.
    var tab: SleepTab
    /// The night and what's read with it, for `nightKey`.
    private(set) var night: SleepRead<SleepNightDetail> = .loading
    private(set) var restingHr: [Point] = []
    private(set) var nightKey: String?
    /// GET /patterns: nil until read; `.missing` hides them.
    private(set) var patterns: SleepRead<Patterns> = .loading
    private(set) var patternsKey: Int?
    /// GET /sleep?days=60 for Coaching.
    private(set) var timing: SleepRead<SleepTiming> = .loading
    private(set) var timingKey: Int?
    /// The Stages and Trends tabs' reads, by "metrics|days|load".
    private(set) var stagesTrends: SleepRead<Trends> = .loading
    private(set) var trendsTrends: SleepRead<Trends> = .loading
    private(set) var stagesKey: String?
    private(set) var trendsKey: String?
    /// The link last acted on (`dashboard.request(for: .sleep)?.id`), so a link opened again applies its tab again.
    var linkHandled: Int?
    /// Reads asked for, for the tests (a fold or a band change asks for none).
    @ObservationIgnored private(set) var readCount = 0
    /// What the night read is for now, so an answer for an older night is dropped.
    @ObservationIgnored private var wantedNight: String?
    @ObservationIgnored private var wantedStages: String?
    @ObservationIgnored private var wantedTrends: String?

    init(tab: SleepTab = .overview) {
        self.tab = tab
    }

    static let stageMetrics = ["sleep_hours", "sleep_deep", "sleep_light", "sleep_rem", "sleep_awake"]
    static let trendMetrics = ["sleep_hours", "sleep_in_bed", "sleep_performance", "sleep_efficiency", "sleep_consistency", "sleep_deep", "sleep_rem"]

    /// The night that ended on `date` (nil: today's) and its 14 days of resting heart rate, once per date and load.
    func loadNight(date: String?, generation: Int, reads: SleepReads, dashboard: Dashboard) async {
        let key = "\(date ?? "today")|\(generation)"
        guard nightKey != key || night.value == nil else { return }
        wantedNight = key
        if nightKey?.hasPrefix("\(date ?? "today")|") != true { night = .loading }
        readCount += 2
        async let rhr = try? reads.restingHr(dashboard, date)
        do {
            let got = try await reads.night(dashboard, date)
            guard wantedNight == key, !Task.isCancelled else { return }
            night = got.map { .loaded($0) } ?? .missing
        } catch is CancellationError {
            return
        } catch {
            guard wantedNight == key, !Task.isCancelled else { return }
            night = .failed(error.localizedDescription)
        }
        let points = await rhr ?? []
        guard wantedNight == key, !Task.isCancelled else { return }
        restingHr = points
        nightKey = key
    }

    /// GET /patterns, once per load (the Dashboard keeps the answer until its next load).
    func loadPatterns(generation: Int, reads: SleepReads, dashboard: Dashboard) async {
        guard patternsKey != generation else { return }
        readCount += 1
        do {
            let got = try await reads.patterns(dashboard)
            guard !Task.isCancelled else { return }
            patterns = got.map { .loaded($0) } ?? .missing
            patternsKey = generation
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            patterns = .failed(error.localizedDescription)
        }
    }

    /// GET /sleep?days=60 for Coaching, once per load.
    func loadTiming(generation: Int, reads: SleepReads, dashboard: Dashboard) async {
        guard timingKey != generation else { return }
        readCount += 1
        do {
            let got = try await reads.timing(dashboard)
            guard !Task.isCancelled else { return }
            timing = got.map { .loaded($0) } ?? .missing
            timingKey = generation
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            timing = .failed(error.localizedDescription)
        }
    }

    /// The Stages tab's nights (`stages`) or the Trends tab's metrics over `days`, once per range and load. What's on
    /// screen stays while another range is read.
    func loadTrends(stages: Bool, days: Int, generation: Int, reads: SleepReads, dashboard: Dashboard) async {
        let metrics = stages ? Self.stageMetrics : Self.trendMetrics
        let key = "\(days)|\(generation)"
        if stages {
            guard stagesKey != key || stagesTrends.value == nil else { return }
            wantedStages = key
        } else {
            guard trendsKey != key || trendsTrends.value == nil else { return }
            wantedTrends = key
        }
        readCount += 1
        let result: SleepRead<Trends>
        do {
            result = .loaded(try await reads.trends(dashboard, metrics, days))
        } catch is CancellationError {
            return
        } catch {
            result = .failed(error.localizedDescription)
        }
        guard !Task.isCancelled else { return }
        // A failure leaves a range already on screen (and its key) as it was.
        if stages {
            guard wantedStages == key else { return }
            if result.value != nil { stagesKey = key }
            if result.value != nil || stagesTrends.value == nil { stagesTrends = result }
        } else {
            guard wantedTrends == key else { return }
            if result.value != nil { trendsKey = key }
            if result.value != nil || trendsTrends.value == nil { trendsTrends = result }
        }
    }

    /// The tabs this server has: no Overview where it has no night (an older server), no Coaching where it has no
    /// bed and wake times.
    var tabs: [SleepTab] {
        SleepTab.allCases.filter { t in
            switch t {
            case .overview: !night.isMissing
            case .coaching: !timing.isMissing
            default: true
            }
        }
    }

    /// The tab to draw: the one chosen, unless this server doesn't have it.
    var shownTab: SleepTab { tabs.contains(tab) ? tab : (tabs.first ?? .stages) }
}

/// What the Overview's three cards need to know about the night and the person's sources (Sleep.tsx NightCtx).
struct SleepNightContext {
    let night: SleepNightDetail
    /// No source and no night ever: the cards' empty state as designed.
    let bare: Bool
    /// "Last night", "Night to Tue, Oct 20".
    let label: String
    let demo: Bool
    /// WHOOP is connected, was, or the demo stands in for it: the only source of sleep performance.
    let whoop: Bool

    init(night: SleepNightDetail, status: ServerStatus?) {
        self.night = night
        bare = night.noNights && !Self.hasSleepSource(status)
        label = SleepWords.nightLabel(night.date, today: night.today)
        demo = status?.demo == true
        whoop = status.map { $0.demo == true || $0.whoop?.connected == true || $0.whoop?.lastSync != nil } ?? false
    }

    /// Some source that can record a night is set up: WHOOP, the iPhone app or an export, a Fitbit export, or the demo.
    static func hasSleepSource(_ status: ServerStatus?) -> Bool {
        guard let s = status else { return false }
        return s.demo == true || s.whoop?.connected == true || s.apple?.lastSync != nil || s.apple?.lastImport != nil || s.fitbit?.lastImport != nil
    }

    /// The device in words for the Sleep card's foot (Sleep.tsx SOURCE_NAME), "Demo data" while demo data shows.
    var source: String? {
        if demo { return "Demo data" }
        switch night.source {
        case "apple": return "Apple Health"
        case "whoop": return "WHOOP"
        case "fitbit": return "Fitbit"
        default: return nil
        }
    }
}

/// The rows of the Sleep insights card (Sleep.tsx InsightsCard): the night's own, then Home's sleep insights that say
/// something the night's don't (sleep debt, need, timing), then the sleep patterns; four at most. Each opens a tab.
struct SleepInsightRow: Identifiable, Equatable {
    let id: String
    let icon: String
    let text: String
    var note: String?
    let tab: SleepTab

    static func rows(night: SleepNightDetail, home: [Insight], patterns: [Pattern]) -> [SleepInsightRow] {
        let own = night.insights.map { SleepInsightRow(id: $0.id, icon: $0.icon, text: $0.text, tab: $0.id == "latency" ? .stages : .trends) }
        let fromHome = home
            .filter { i in i.page == "sleep" && !night.insights.contains { $0.id == i.id || ($0.id == "consistency" && i.id == "bedtime") } }
            .map { SleepInsightRow(id: "home-\($0.id)", icon: $0.icon, text: $0.text, tab: .coaching) }
        let fromPatterns = patterns.filter { $0.page == "sleep" }
            .map { SleepInsightRow(id: $0.id, icon: $0.icon ?? "spark", text: $0.text, note: $0.detail, tab: .coaching) }
        return Array((own + fromHome + fromPatterns).prefix(4))
    }

    /// The icon and its tone (Home.tsx INSIGHT_TONE, with the patterns' spark in blue).
    static func style(_ icon: String) -> (String, Tone) {
        icon == "spark" ? ("sparkles", .blue) : HomeInsightsCard.style(icon)
    }
}

/// The Stages tab's nights (Sleep.tsx StagesTab): each night's hours by stage, week averages past 90 days (each week's
/// sums over its nights), the average night by stage and each stage's share.
struct SleepStageNights {
    struct Row: Identifiable, Equatable {
        let date: String
        let values: [String: Double]
        var id: String { date }
    }

    /// Deep, Light / core, REM and Awake (Detail.tsx STAGES), bottom to top.
    static let stages: [(key: String, label: String, color: Color)] = [
        ("sleep_deep", "Deep", Palette.stageDeep),
        ("sleep_light", "Light / core", Palette.stageLight),
        ("sleep_rem", "REM", Palette.stageRem),
        ("sleep_awake", "Awake", Palette.stageAwake),
    ]

    /// Nights with any stage, oldest first.
    let nights: [Row]
    /// What the chart draws: the nights, or past 90 days one row per week.
    let rows: [Row]
    let weekly: Bool
    /// Average time asleep over the range.
    let average: Double?

    init(_ t: Trends, days: Int) {
        var byDate: [String: [String: Double]] = [:]
        for s in Self.stages { for p in t[s.key] ?? [] { byDate[p.date, default: [:]][s.key] = p.value } }
        nights = byDate.keys.sorted().map { Row(date: $0, values: byDate[$0] ?? [:]) }
        weekly = days > 90
        if weekly {
            var order: [String] = []
            var weeks: [String: (n: Int, values: [String: Double])] = [:]
            for r in nights {
                let k = Point.weekStart(r.date)
                if weeks[k] == nil { order.append(k) }
                var w = weeks[k] ?? (0, [:])
                w.n += 1
                for (key, v) in r.values { w.values[key, default: 0] += v }
                weeks[k] = w
            }
            rows = order.map { k in Row(date: k, values: (weeks[k]?.values ?? [:]).mapValues { $0 / Double(weeks[k]?.n ?? 1) }) }
        } else {
            rows = nights
        }
        average = (t["sleep_hours"] ?? []).average
    }

    /// A stage's average over the nights that recorded stages.
    func mean(_ key: String) -> Double {
        nights.isEmpty ? 0 : nights.reduce(0) { $0 + ($1.values[key] ?? 0) } / Double(nights.count)
    }

    /// Each stage's average and its share of the night (Sleep.tsx: of the sum of the averages).
    var totals: [(key: String, label: String, color: Color, hours: Double, share: Int)] {
        let hours = Self.stages.map { mean($0.key) }
        let sum = hours.reduce(0, +)
        let whole = sum == 0 ? 1 : sum
        return zip(Self.stages, hours).map { s, h in (s.key, s.label, s.color, h, Int((h / whole * 100).rounded())) }
    }

    /// A night's (or week's) total, for the tooltip and the table.
    static func total(_ row: Row) -> Double { stages.reduce(0) { $0 + (row.values[$1.key] ?? 0) } }
}
