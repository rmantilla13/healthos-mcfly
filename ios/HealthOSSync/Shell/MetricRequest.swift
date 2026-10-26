import Foundation

/// A metric with a detail sheet (MetricKey in shared/metrics.ts; GET /api/metric/:key).
enum MetricKey: String, CaseIterable, Hashable {
    case restingHr = "resting_hr", hrv, sleepHours = "sleep_hours", recovery, strain, steps, activeEnergy = "active_energy"
    case spo2, respRate = "resp_rate", glucose, weight, bodyFat = "body_fat", leanMass = "lean_mass", vo2max
    case heartRate = "heart_rate", sleepPerformance = "sleep_performance", sleepEfficiency = "sleep_efficiency"
}

/// A sheet's window (MetricRange in shared/metrics.ts): the day by hour, or the last 7, 30 or 365 days.
enum MetricRange: String, CaseIterable, Hashable {
    case day, week, month, year
}

/// A metric's detail sheet to show, as the web's MetricSheetLink opens one (SheetOptions in MetricSheet.tsx). Slice C's
/// `MetricSheetView(request:)` (MetricSheet/) draws it; the shell shows it over the app.
struct MetricRequest: Identifiable, Equatable {
    let id = UUID()
    let key: MetricKey
    /// The line above the metric's name, in capitals: "Your signals", "Your body".
    var section: String
    /// The card's own page, for the sheet's "Open {Page}" (the address its arrow used to go to).
    var page: AppRoute
    /// The range to open on; the metric's own default when nil.
    var range: MetricRange?
    /// The day the card shows, where the window ends; nil is today.
    var date: String?
}

extension Dashboard {
    /// Opens a metric's detail sheet over the app, from a card's arrow on any page (Home's signal cards, Vitals, Body,
    /// Sleep): `dashboard.showMetric(.hrv, page: .vitals)`.
    func showMetric(_ key: MetricKey, section: String = "Your signals", page: AppRoute, range: MetricRange? = nil, date: String? = nil) {
        metricSheet = MetricRequest(key: key, section: section, page: page, range: range, date: date)
    }
}
