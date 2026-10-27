import SwiftUI

// What the Vitals page shows, worked out apart from its views (src/pages/Detail.tsx Vitals), so tests can check each
// word and rule against the web's file: the intro's line, which signals count, when the trends show, whether the Day
// view or a range is on screen, and the trend cards in the web's order with their notes.

enum VitalsWords {
    static let title = "A closer look at your signals."
    /// The trends' heading.
    static let trends = "Your trends"
    /// Under the Day view's heart rate.
    static let dayFootnote = "Recovery, HRV, blood oxygen, breathing and temperature are measured once a night. Pick a range to see them."

    /// The intro's line: how many of the five signals have a reading, or, before the summary comes, where they're from.
    static func sub(count: Int?) -> String {
        guard let count else { return "Overnight readings from your connected sources." }
        return "\(count) available measurement\(count == 1 ? "" : "s") from your connected sources."
    }

    /// The summary couldn't be read and none is kept.
    static func summaryFailed(_ message: String) -> String { "Couldn't load your latest readings: \(message)" }

    /// The trends couldn't be read (the web would show each card empty; here it says so, in the server's words or the
    /// connection's, never as a feature the server lacks).
    static func trendsFailed(_ message: String) -> String { "Couldn't load your trends: \(message)" }

    /// How many of the five signals have a reading (Signals.tsx signalCount): resting heart rate, blood oxygen, HRV,
    /// WHOOP's recovery (not VO₂ max) and respiratory rate. Sleep is the Sleep page's.
    static func signalCount(_ s: Summary) -> Int {
        let readings: [Bool] = [
            (s.restingHr?.latest ?? s.vitals?.heart?.latest) != nil,
            s.spo2?.latest != nil,
            s.hrv?.latest != nil,
            s.readiness?.kind == "recovery",
            (s.respRate?.latest ?? s.vitals?.breathing?.latest) != nil,
        ]
        return readings.filter { $0 }.count
    }

    /// Who measures HRV as RMSSD, for its trend's note (rmssdNote): WHOOP when it's connected, Fitbit when its last
    /// export had it; WHOOP's alone when neither is known.
    static func rmssdNote(_ status: ServerStatus?) -> String {
        var by: [String] = []
        if status?.whoop?.connected == true { by.append("WHOOP") }
        if status?.fitbit?.lastImport?.metrics.contains("hrv_rmssd") == true { by.append("Fitbit") }
        return "\(by.isEmpty ? "WHOOP" : by.joined(separator: " or ")), during sleep"
    }
}

/// The five signal cards, in the web's order (RestingHrCard, Spo2Card, HrvCard, RecoveryCard, RespRateCard), drawn
/// compact by Home's SignalCard. Each opens its metric's sheet with "Open Vitals" (its page).
enum VitalsSignals {
    static func all(_ s: Summary) -> [Signal] {
        [.restingHr(s, variant: .compact), .spo2(s, variant: .compact), .hrv(s, variant: .compact),
         .recovery(s, variant: .compact), .respRate(s, variant: .compact)]
    }
}

/// What "Your trends" shows: a range of nightly readings, one day of heart rate by the hour, or nothing yet while it's
/// not known whether the day has any (the web's useDay mode).
enum VitalsMode: Equatable {
    case range, day, pending

    /// `range` is the shared range (1 is Day). Day shows only once GET /day has answered with heart rate; until it has
    /// answered at all, Day waits; when it can't (an older server, no hourly data, a failure), it's the range.
    static func of(range: Int, available: Bool, settled: Bool) -> VitalsMode {
        range != ChartRange.day.days ? .range : available ? .day : settled ? .range : .pending
    }

    /// The days a range covers: Day, when it can't be shown, is 30 days.
    static func days(_ range: Int) -> Int { range == ChartRange.day.days ? 30 : range }

    /// The ranges offered: Day first once the day has heart rate.
    static func ranges(dayAvailable: Bool) -> [ChartRange] { dayAvailable ? ChartRange.withDay : ChartRange.standard }

    /// Whether there's anything to chart: anything ever sent (the summary's latest data day). Without a summary (it
    /// failed), the trends still show what they have.
    static func charted(summary: Summary?, summaryFailed: Bool) -> Bool {
        if let summary { return summary.latestDataDate != nil }
        return summaryFailed
    }
}

/// One trend card on Vitals: what VitalsTrendCard draws.
struct VitalsTrend: Identifiable {
    /// The metric it charts ("resting_hr"): the card's row on the page.
    let metric: String
    let title: String
    let points: [Point]
    let format: (Double) -> String
    var note: String?
    var color: Color = Palette.series1
    var id: String { metric }
}

/// One cell of the trends' grid: a web trend card, or one of the iPhone's own.
enum VitalsTrendItem: Identifiable, Equatable {
    case trend(VitalsTrend)
    case tempDeviation, bloodPressure, glucose, breathing

    var id: String {
        switch self {
        case .trend(let t): t.metric
        case .tempDeviation: "temp-deviation"
        case .bloodPressure: "blood-pressure"
        case .glucose: "glucose"
        case .breathing: "breathing-disturbances"
        }
    }

    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
}

enum VitalsTrendCards {
    /// The card's table (Detail.tsx Trend): Date and the card's title, a row a reading, the date with its year.
    static func table(_ trend: VitalsTrend) -> SheetTable {
        SheetTable(columns: ["Date", trend.title], rows: trend.points.map { [Fmt.day($0.date, "yMMMd"), trend.format($0.value)] })
    }

    /// GET /api/trends?metrics=…, as the web asks.
    static let metrics = ["resting_hr", "hrv_rmssd", "hrv_sdnn", "spo2", "resp_rate", "wrist_temp", "skin_temp", "body_temp", "recovery"]
    /// What only the iPhone shows on Vitals, asked for with the same request (the server takes up to 20): blood
    /// pressure, glucose and breathing disturbances, each shown only with readings.
    static let phoneMetrics = ["blood_pressure_systolic", "blood_pressure_diastolic", "glucose", "breathing_disturbances"]

    /// The web's cards in its order. Recovery, the second HRV and the temperatures show only with readings; HRV
    /// (RMSSD) shows when it has readings or SDNN has none. Temperatures are in the person's units, their axis too.
    static func cards(_ t: Trends, status: ServerStatus?, units: Units) -> [VitalsTrend] {
        let has = { (m: String) in !(t[m]?.isEmpty ?? true) }
        var out: [VitalsTrend] = []
        if has("recovery") { out.append(VitalsTrend(metric: "recovery", title: "Recovery", points: t["recovery"] ?? [], format: { "\(Fmt.number($0))%" }, color: Palette.series3)) }
        out.append(VitalsTrend(metric: "resting_hr", title: "Resting heart rate", points: t["resting_hr"] ?? [], format: { "\(Fmt.number($0)) bpm" }, color: Palette.series2))
        if has("hrv_rmssd") || !has("hrv_sdnn") {
            out.append(VitalsTrend(metric: "hrv_rmssd", title: "HRV (RMSSD)", points: t["hrv_rmssd"] ?? [], format: { "\(Fmt.number($0)) ms" }, note: VitalsWords.rmssdNote(status)))
        }
        if has("hrv_sdnn") { out.append(VitalsTrend(metric: "hrv_sdnn", title: "HRV (SDNN)", points: t["hrv_sdnn"] ?? [], format: { "\(Fmt.number($0)) ms" }, note: "Apple Watch")) }
        out.append(VitalsTrend(metric: "spo2", title: "Blood oxygen", points: t["spo2"] ?? [], format: { "\(Fmt.number($0, 1))%" }, color: Palette.series2))
        out.append(VitalsTrend(metric: "resp_rate", title: "Respiratory rate", points: t["resp_rate"] ?? [], format: { "\(Fmt.number($0, 1)) rpm" }))
        let unit = units.temp(0).unit
        for (m, title, note) in [("body_temp", "Body temperature", nil), ("wrist_temp", "Wrist temperature", "Apple Watch, during sleep"),
                                 ("skin_temp", "Skin temperature", "WHOOP")] as [(String, String, String?)] where has(m) {
            // Drawn in the person's unit, so the axis reads °F for them too.
            let points = (t[m] ?? []).map { Point(date: $0.date, value: units.temp($0.value).value) }
            out.append(VitalsTrend(metric: m, title: title, points: points, format: { "\(Fmt.number($0, 1)) \(unit)" }, note: note))
        }
        return out
    }

    /// Every trend card the page shows, in order: the web's, then what only the iPhone has (the nightly temperature
    /// against your usual, blood pressure, glucose and breathing disturbances), each of those only with readings to
    /// draw, so a grid of them never holds an empty cell.
    static func items(_ t: Trends, history: Trends?, days: Int, end: String, status: ServerStatus?, units: Units) -> [VitalsTrendItem] {
        let has = { (m: String) in !(t[m]?.isEmpty ?? true) }
        var out = cards(t, status: status, units: units).map(VitalsTrendItem.trend)
        if let history, TempDeviationCard.pick(history, from: Day.add(end, -(days - 1))) != nil { out.append(.tempDeviation) }
        if has("blood_pressure_systolic") || has("blood_pressure_diastolic") { out.append(.bloodPressure) }
        if has("glucose") { out.append(.glucose) }
        if has("breathing_disturbances") { out.append(.breathing) }
        return out
    }

    /// The line under the value (Trend's note): the latest reading's day, the range's average and the card's own note,
    /// or "No data in this range".
    static func note(_ trend: VitalsTrend) -> String {
        guard let last = trend.points.last else { return "No data in this range" }
        var s = Fmt.day(last.date)
        if let avg = trend.points.average { s += " · average \(trend.format(avg))" }
        if let note = trend.note { s += " · \(note)" }
        return s
    }

    /// The range's median, dashed on the chart once there are five readings (medianOf in src/charts/Charts.tsx).
    static func median(_ values: [Double]) -> Double? {
        guard values.count >= 5 else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}

/// What Vitals reads beside the summary Home already loaded: the trends for a range (the web's metrics with the
/// iPhone's own, and the temperatures from 30 days earlier for the nightly temperature card), and one day of heart rate
/// by the hour. Each is this person's only: an answer that lands after a sign-out, someone else's sign-in or another
/// server is dropped (`fetchForThisSession`, which `Dashboard.trends` goes through too). Closures, so tests answer in
/// the server's place and count the reads.
struct VitalsReads {
    var readTrends: @MainActor (Dashboard, _ metrics: [String], _ days: Int) async throws -> Trends
    /// nil: a server without GET /day (an older one), so no Day view.
    var readDay: @MainActor (Dashboard, _ date: String?) async throws -> DayData?

    static var live: VitalsReads {
        VitalsReads(readTrends: { dashboard, metrics, days in try await dashboard.trends(metrics, days: days) },
                    readDay: { dashboard, date in
                        try await dashboard.fetchForThisSession { try await $0.day(date: date, metrics: ["heart_rate"]) }
                    })
    }
}

private struct VitalsReadsKey: EnvironmentKey {
    static var defaultValue: VitalsReads { .live }
}

extension EnvironmentValues {
    /// Vitals' reads for its trends and its Day view; tests put their own in.
    var vitalsReads: VitalsReads {
        get { self[VitalsReadsKey.self] }
        set { self[VitalsReadsKey.self] = newValue }
    }
}
