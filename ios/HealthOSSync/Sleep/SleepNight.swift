import Foundation

// One night for the Sleep page (GET /api/sleep/night?date=, shared/types.ts SleepNightDetail), the reads the page makes
// beside it, and the clock arithmetic the web's night charts use (src/charts/Neka.tsx). Every figure is from one device
// for that night; nothing here is a score the app makes up.

/// The night that ended on `date` (the wake date). Read field by field: one the app can't read is nil, never the whole
/// night, and a list keeps the entries it can read.
struct SleepNightDetail: Decodable, Equatable {
    /// A stretch of one stage, as the device recorded it. `stage` is "awake", "rem", "light", "deep", "asleep" (asleep
    /// with no stage: older watches, phones) or "in_bed" (in bed, not asleep yet or again). The times carry the offset
    /// they were recorded in, and the wall time is what's shown.
    struct Segment: Codable, Equatable, Identifiable {
        let start: String
        let end: String
        let stage: String
        var id: String { start }
    }

    /// Hours in each stage, from the same device as the stages chart.
    struct Stages: Codable, Equatable {
        let awake: Double
        let rem: Double
        let light: Double
        let deep: Double

        var total: Double { awake + rem + light + deep }
        func hours(_ key: String) -> Double {
            switch key {
            case "awake": awake
            case "rem": rem
            case "light": light
            case "deep": deep
            default: 0
            }
        }
    }

    /// A plain sentence about this night against the person's own recent nights.
    struct Insight: Codable, Equatable, Identifiable {
        let id: String
        /// "moon" | "trend-up" | "trend-down" | "shield" | "sun"
        let icon: String
        let text: String
    }

    /// The latest night with any sleep, from any source (`lastNight`). An older server doesn't send it: then there's no
    /// way to tell, and the page is the full one, as on the web.
    enum LastNight: Equatable {
        case unknown
        case none
        case night(String)
    }

    let date: String
    let today: String
    /// "apple" | "whoop" | "fitbit"; nil when no device recorded the night.
    let source: String?
    /// The first and last moment asleep (Apple), or the sleep record's start and end (WHOOP).
    let fellAsleep: String?
    let wokeUp: String?
    let asleepHours: Double?
    let inBedHours: Double?
    let stages: Stages?
    /// WHOOP's sleep performance, 0–100 (missing from servers older than the Sleep page's three cards).
    let performance: Double?
    /// The night's sleep efficiency, 0–100: the device's own, else asleep ÷ in bed from that one device.
    let efficiency: Double?
    let lastNight: LastNight
    /// Stage by stage through the night, oldest first: only Apple Watch nights the iPhone sent.
    let segments: [Segment]
    let latencyMin: Double?
    /// The middle of the longest stretch of deep sleep.
    let deepPeak: String?
    let insights: [Insight]

    private enum CodingKeys: String, CodingKey {
        case date, today, source, fellAsleep, wokeUp, asleepHours, inBedHours, stages, performance, efficiency, lastNight, segments,
             latencyMin, deepPeak, insights
    }

    init(date: String, today: String, source: String? = nil, fellAsleep: String? = nil, wokeUp: String? = nil, asleepHours: Double? = nil,
         inBedHours: Double? = nil, stages: Stages? = nil, performance: Double? = nil, efficiency: Double? = nil,
         lastNight: LastNight = .unknown, segments: [Segment] = [], latencyMin: Double? = nil, deepPeak: String? = nil,
         insights: [Insight] = []) {
        self.date = date
        self.today = today
        self.source = source
        self.fellAsleep = fellAsleep
        self.wokeUp = wokeUp
        self.asleepHours = asleepHours
        self.inBedHours = inBedHours
        self.stages = stages
        self.performance = performance
        self.efficiency = efficiency
        self.lastNight = lastNight
        self.segments = segments
        self.latencyMin = latencyMin
        self.deepPeak = deepPeak
        self.insights = insights
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys) -> T? { try? c.decodeIfPresent(T.self, forKey: key) }
        date = try c.decode(String.self, forKey: .date)
        today = try c.decode(String.self, forKey: .today)
        source = value(.source)
        fellAsleep = value(.fellAsleep)
        wokeUp = value(.wokeUp)
        asleepHours = value(.asleepHours)
        inBedHours = value(.inBedHours)
        stages = value(.stages)
        performance = value(.performance)
        efficiency = value(.efficiency)
        if !c.contains(.lastNight) {
            lastNight = .unknown
        } else if (try? c.decodeNil(forKey: .lastNight)) == true {
            lastNight = .none
        } else {
            lastNight = (value(.lastNight) as String?).map(LastNight.night) ?? .unknown
        }
        segments = ((value(.segments) as [Lossy<Segment>]?) ?? []).compactMap(\.wrappedValue)
        latencyMin = value(.latencyMin)
        deepPeak = value(.deepPeak)
        insights = ((value(.insights) as [Lossy<Insight>]?) ?? []).compactMap(\.wrappedValue)
    }

    /// No night from any source, ever (the server says so): the page's line asks for a wearable.
    var noNights: Bool { lastNight == .none }

    /// The night has stretches by stage (deep, REM or light), which the hypnogram draws. Watch nights recorded before
    /// stages ("asleep" only) don't.
    var staged: Bool { segments.contains { ["deep", "rem", "light"].contains($0.stage) } }

    /// Hours in each stage: the night's own totals, else added up from its stretches when they have stages (a short
    /// night the Watch scored as core and awake only gets no totals from the phone).
    var stageTotals: Stages? { stages ?? (staged ? SleepClock.totals(segments) : nil) }
}

/// A resting heart rate reading (GET /api/trends?metrics=resting_hr&days=14&date=).
private struct SleepRestingHrTrend: Decodable {
    @LossyArray var resting_hr: [Point]
}

extension APIClient {
    /// The night that ended on `date` (nil: today's); nil from a server without the Sleep page's night (an older one),
    /// which hides the overview.
    func sleepNight(date: String?) async throws -> SleepNightDetail? {
        try await optional("/sleep/night", query: date.map { [URLQueryItem(name: "date", value: $0)] } ?? [])
    }

    /// The 14 days of resting heart rate up to `date`, for the Sleep page's resting heart rate card.
    func sleepRestingHr(date: String?) async throws -> [Point] {
        var query = [URLQueryItem(name: "metrics", value: "resting_hr"), URLQueryItem(name: "days", value: "14")]
        if let date { query.append(URLQueryItem(name: "date", value: date)) }
        let trend: SleepRestingHrTrend = try await get("/trends", query: query)
        return trend.resting_hr
    }
}

/// Instants and wall clocks in a night, as the web works them out (Neka.tsx): a time is read with the offset it was
/// written in, never the phone's time zone, so "woke up 06:34" is the time on the wearer's clock that night.
enum SleepClock {
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let fraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// The instant an ISO timestamp names, in seconds since 1970; nil when it can't be read.
    static func time(_ iso: String) -> TimeInterval? {
        (plain.date(from: iso) ?? fraction.date(from: iso))?.timeIntervalSince1970
    }

    /// Minutes east of UTC in a timestamp's offset ("…-05:00" is −300; "Z" or none is 0).
    static func offset(_ iso: String) -> Int {
        guard let m = iso.firstMatch(of: /([+-])(\d{2}):?(\d{2})$/) else { return 0 }
        let minutes = (Int(m.2) ?? 0) * 60 + (Int(m.3) ?? 0)
        return m.1 == "-" ? -minutes : minutes
    }

    /// "HH:MM" as recorded (lib.ts clock): the timestamp's own wall time.
    static func wall(_ iso: String) -> String {
        let chars = Array(iso)
        guard chars.count >= 16 else { return iso }
        return String(chars[11..<16])
    }

    /// "HH:MM" of an instant, in the offset `offsetIso` was written with.
    static func local(_ t: TimeInterval, offsetIso: String) -> String {
        let seconds = Int((t + Double(offset(offsetIso) * 60)).rounded(.down))
        let minutes = ((seconds / 60) % 1440 + 1440) % 1440
        return String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    /// The wall clock at an instant, in the offset the night was recorded in then: that of the latest timestamp at or
    /// before it, so a night the clocks change on keeps the axis and the facts in step.
    static func at(_ t: TimeInterval, segments: [SleepNightDetail.Segment], fallback: String) -> String {
        var iso = segments.first?.start ?? fallback
        for g in segments {
            if let s = time(g.start), s <= t { iso = g.start }
            if let e = time(g.end), e <= t { iso = g.end }
        }
        return local(t, offsetIso: iso)
    }

    /// Whole local hours between two instants, every `every` hours, each labelled in the offset in force then.
    static func hourTicks(from: TimeInterval, to: TimeInterval, every: Int, offsetIso: String,
                          label: (TimeInterval) -> String) -> [(at: TimeInterval, label: String)] {
        let off = Double(offset(offsetIso) * 60)
        var out: [(at: TimeInterval, label: String)] = []
        var t = ((from + off) / 3600).rounded(.up) * 3600 - off
        while t <= to {
            let text = label(t)
            if let hour = Int(text.prefix(2)), hour % max(1, every) == 0 { out.append((t, text)) }
            t += 3600
        }
        return out
    }

    /// Hours in each stage, added up from a night's stretches ("asleep" counts as light; "in_bed" not at all).
    static func totals(_ segments: [SleepNightDetail.Segment]) -> SleepNightDetail.Stages {
        var awake = 0.0, rem = 0.0, light = 0.0, deep = 0.0
        for g in segments {
            guard let s = time(g.start), let e = time(g.end) else { continue }
            let h = (e - s) / 3600
            switch g.stage {
            case "awake": awake += h
            case "rem": rem += h
            case "light", "asleep": light += h
            case "deep": deep += h
            default: break
            }
        }
        return SleepNightDetail.Stages(awake: awake, rem: rem, light: light, deep: deep)
    }

    /// The stage in words (Neka.tsx STAGE_LABEL).
    static func label(_ stage: String) -> String {
        switch stage {
        case "awake": "Awake"
        case "in_bed": "In bed"
        case "rem": "REM"
        case "light": "Light"
        case "asleep": "Asleep"
        case "deep": "Deep"
        default: stage
        }
    }
}
