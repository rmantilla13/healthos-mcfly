import Foundation

extension APIClient {
    /// One metric over a day, week, month or year (GET /api/metric/:key?range=&date=). nil when this server has no sheet
    /// for it: one older than the sheets has no /api/metric at all (its catch-all "Not found"), and one from before a
    /// metric had a sheet (sleep performance and efficiency came later) answers its own "Unknown metric". The sheet then
    /// shows what GET /api/trends can (MetricSheetFallback).
    func metricSheet(_ key: MetricKey, range: MetricRange, date: String?) async throws -> MetricSheetData? {
        var query = [URLQueryItem(name: "range", value: range.rawValue)]
        if let date = date.flatMap(SheetDate.valid) { query.append(URLQueryItem(name: "date", value: date)) }
        do {
            return try await optional("/metric/\(key.rawValue)", query: query)
        } catch let error as APIError where MetricSheetFallback.unknownMetric(error) {
            return nil
        }
    }
}

/// A sheet built on the phone for a server without one for this metric: the window's values from GET /api/trends (the
/// readings TrendsLoader shows), or the day's hours from GET /api/day, with the figures the server would put beside them.
/// The server's own parts (where the latest reading sits, its sentence, which devices sent what) need the server, so
/// they're left out rather than guessed. It reads through the Dashboard (`trends`, `day(date:)`), so what it reads also
/// sits in the Dashboard's in-memory caches that every page shares: kept past the sheet, cleared on sign-out.
enum MetricSheetFallback {
    /// The metric route is there but doesn't know this metric: a server from before it had a sheet.
    static func unknownMetric(_ error: APIError) -> Bool {
        if case .server(404, "Unknown metric") = error { return true }
        return false
    }

    /// The sheet for `range`, ending on `date` (nil is today), from what the server has.
    @MainActor
    static func load(_ key: MetricKey, range: MetricRange, date: String?, dashboard: Dashboard) async throws -> MetricSheetData {
        let today = dashboard.summary?.today ?? Day.today()
        let to = date.flatMap(SheetDate.valid).map { min($0, today) } ?? today
        guard let n = range.days else {
            let day = try await dashboard.day(date: to == today ? nil : to)
            return daySheet(key, day: day, date: to, today: today, goal: key == .steps ? dashboard.stepGoal : nil)
        }
        // GET /api/trends ends today, so a past day's window asks for the days since too.
        let days = n + max(0, Fmt.daysBetween(to, today))
        let metric: String
        let points: [Point]
        if key == .hrv {
            // Whichever of RMSSD (WHOOP) and SDNN (Apple Watch) the dashboard shows: the two are never mixed.
            let trends = try await dashboard.trends(["hrv_rmssd", "hrv_sdnn"], days: days)
            let rmssd = trends["hrv_rmssd"] ?? [], sdnn = trends["hrv_sdnn"] ?? []
            metric = dashboard.summary?.hrv?.metric ?? (rmssd.isEmpty && !sdnn.isEmpty ? "hrv_sdnn" : "hrv_rmssd")
            points = metric == "hrv_sdnn" ? sdnn : rmssd
        } else {
            metric = key.trendMetric(hrv: nil) ?? key.rawValue
            points = try await dashboard.trends([metric], days: days)[metric] ?? []
        }
        return windowSheet(key, range: range, metric: metric, points: points, to: to, today: today, units: dashboard.units,
                           goal: key == .steps ? dashboard.stepGoal : nil)
    }

    /// A week, month or year from the day's values, as server/metricsheet.ts puts its figures together: the window's
    /// average, its lowest and highest day and the latest, today's unfinished total drawn but not counted, a mass in the
    /// person's units, and a year as weekly averages.
    static func windowSheet(_ key: MetricKey, range: MetricRange, metric: String, points all: [Point], to: String, today: String,
                            units: Units, goal: Double?) -> MetricSheetData {
        let info = key.info
        let n = range.days ?? 1
        let from = Day.add(to, -(n - 1))
        let unit = key.isMass ? units.mass(0).unit : info.unit
        let shown = all.filter { $0.date >= from && $0.date <= to }
            .sorted { $0.date < $1.date }
            .map { Point(date: $0.date, value: key.isMass ? units.mass($0.value).value : $0.value) }
        let partialToday = key.isSummed && shown.last?.date == today
        let counted = partialToday ? Array(shown.dropLast()) : shown
        let average = counted.isEmpty ? nil : counted.reduce(0) { $0 + $1.value } / Double(counted.count)
        let possible = n - (partialToday ? 1 : 0)
        let low = counted.reduce(nil as Point?) { a, p in a == nil || p.value < a!.value ? p : a }
        let high = counted.reduce(nil as Point?) { a, p in a == nil || p.value > a!.value ? p : a }
        let last = shown.last
        // Glucose's day is the mean of its readings, and its figures say so.
        let per = key == .glucose ? " daily average" : ""
        let tiles = [
            MetricFigure(label: key.isSummed ? "Lowest day" : "Lowest\(per)", value: low?.value, unit: unit, date: low?.date),
            MetricFigure(label: key.isSummed ? "Highest day" : "Highest\(per)", value: high?.value, unit: unit, date: high?.date),
            MetricFigure(label: "Latest\(per)", value: last?.value, unit: unit, date: last?.date, note: partialToday ? "so far today" : nil),
        ]
        let headline = MetricFigure(
            label: key.isSummed ? "Daily average" : info.duration ? "Average a night" : "Average",
            value: average, unit: unit,
            note: "\(counted.count) of \(possible) days with data\(partialToday ? "; today isn't counted until it's over" : "")")
        return MetricSheetData(
            key: key, metric: metric, unit: unit, range: range, ranges: info.ranges, from: from, to: to, today: today,
            // A year's weeks average whole days: today's unfinished total would pull its week down.
            points: range == .year ? weeklyMeans(counted) : shown,
            days: counted.count, partialToday: partialToday, headline: headline, tiles: tiles, latest: last, goal: goal)
    }

    /// One day by the hour from GET /api/day, headlined as the Day view says it (DayReading). nil `day` (a server
    /// without hours, or none for this metric) has nothing to show, and the sheet says where hours come from.
    static func daySheet(_ key: MetricKey, day: DayData?, date: String, today: String, goal: Double?) -> MetricSheetData {
        let info = key.info
        let on = day?.date ?? date
        let isToday = on >= (day?.today ?? today)
        let series = day?.metrics[key.rawValue]
        let own = day.map { DayData(date: $0.date, today: $0.today, asOf: $0.asOf, metrics: series.map { [key.rawValue: $0] } ?? [:]) }
        var headline = MetricFigure(label: isToday ? "Today" : "That day", value: nil, unit: info.unit)
        if let own, let series, let hour = key.hourMetric {
            let reading = DayReading(metric: hour, series: series, data: own)
            let label = hour.kind == .running ? (isToday ? "So far today" : "Whole day") : (isToday ? "Latest hour" : "Last hour with a reading")
            headline = MetricFigure(label: label, value: reading.value, unit: info.unit, note: reading.note)
        }
        return MetricSheetData(key: key, range: .day, ranges: info.ranges, from: on, to: on, today: day?.today ?? today, day: own,
                               days: headline.value == nil ? 0 : 1, headline: headline, goal: goal)
    }

    /// Weekly averages of daily values, each dated its Monday (weeklyMeans in server/metricsheet.ts).
    static func weeklyMeans(_ points: [Point]) -> [Point] {
        var order: [String] = []
        var weeks: [String: [Double]] = [:]
        for p in points {
            let monday = Point.weekStart(p.date)
            if weeks[monday] == nil { order.append(monday) }
            weeks[monday, default: []].append(p.value)
        }
        return order.map { m in Point(date: m, value: weeks[m]!.reduce(0, +) / Double(weeks[m]!.count)) }
    }
}
