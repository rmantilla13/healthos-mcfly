import SwiftUI

// What the Body page reads and keeps (src/pages/Body.tsx): the figure and the measurements as of today, one day of a
// device's readings for the shared date, and each tab's trends for its range. The model lives on the page's root, above
// DuoPage, so a fold (the iPhone Duo going between one column and two panes) never reads anything again (P4, P14).
// Everything in it is one person's on one server: a sign-out, someone else's sign-in or another server clears it, and an
// answer that lands for an earlier session, or for an earlier day or range, is dropped. Memory only.

/// One read: still on its way, its answer, or why it failed (the words to show).
enum BodyRead<T> {
    case loading
    case done(T)
    case failed(String)

    var value: T? {
        if case .done(let v) = self { return v }
        return nil
    }

    var failure: String? {
        if case .failed(let words) = self { return words }
        return nil
    }
}

/// What Body reads, as closures so the tests answer in the server's place and count the reads. Each goes through the
/// Dashboard's own reads (cached for the person) or `fetchForThisSession`, so the last person's answer is never kept.
struct BodyReads {
    /// GET /api/summary for a day; nil is today.
    var summary: @MainActor (Dashboard, String?) async throws -> Summary
    /// GET /api/trends ending on a day (nil is today).
    var trends: @MainActor (Dashboard, [String], Int, String?) async throws -> Trends
    /// GET /api/body/latest; nil from a server without it.
    var latest: @MainActor (Dashboard) async throws -> BodyLatest?
    /// GET /api/body/entries for one metric; nil from a server without it.
    var entries: @MainActor (Dashboard, BodyMetric) async throws -> BodyEntries?
    /// POST /api/body/entries.
    var add: @MainActor (Dashboard, [String: Any]) async throws -> Void
    /// DELETE /api/body/entries/:id.
    var delete: @MainActor (Dashboard, String) async throws -> Void
    /// GET /api/day for a day (nil is today); nil from a server without it.
    var day: @MainActor (Dashboard, String?) async throws -> DayData?
    /// GET /api/workouts over `days` ending on a day (nil is today).
    var workouts: @MainActor (Dashboard, Int, String?) async throws -> [Workout]
    /// GET /api/metric/glucose?range=month ending on a day; nil from a server without the sheet.
    var glucose: @MainActor (Dashboard, String) async throws -> MetricSheetData?
    /// GET /api/labs.
    var labs: @MainActor (Dashboard) async throws -> LabsData

    static var live: BodyReads {
        BodyReads(
            summary: { d, date in try await d.fetchForThisSession { try await $0.summary(date: date) } },
            trends: { d, metrics, days, date in
                // Today's ranges are the Dashboard's, cached for the person; another day's are read as asked.
                if let date { return try await d.fetchForThisSession { try await $0.bodyTrends(metrics, days: days, date: date) } }
                return try await d.trends(metrics, days: days)
            },
            latest: { d in try await d.fetchForThisSession { try await $0.bodyLatest() } },
            entries: { d, metric in try await d.fetchForThisSession { try await $0.bodyEntries(metric) } },
            add: { d, body in try await d.fetchForThisSession { try await $0.addBodyEntry(body) } },
            delete: { d, id in try await d.fetchForThisSession { try await $0.deleteBodyEntry(id: id) } },
            day: { d, date in try await d.day(date: date) },
            workouts: { d, days, date in
                if let date { return try await d.fetchForThisSession { try await $0.bodyWorkouts(days: days, date: date) } }
                return try await d.workouts(days: days)
            },
            glucose: { d, date in try await d.fetchForThisSession { try await $0.metricSheet(.glucose, range: .month, date: date) } },
            labs: { d in try await d.fetchForThisSession { try await $0.labs() } }
        )
    }
}

private struct BodyReadsKey: EnvironmentKey {
    static var defaultValue: BodyReads { .live }
}

extension EnvironmentValues {
    /// Body's reads; tests put their own in.
    var bodyReads: BodyReads {
        get { self[BodyReadsKey.self] }
        set { self[BodyReadsKey.self] = newValue }
    }
}

/// Body's tabs (TABS in Body.tsx), by the route's `tab` query.
enum BodyTab: String, CaseIterable, Identifiable {
    case overview, recovery, strain, activity, temperature, cardiovascular, metabolism

    var id: String { rawValue }

    var label: String {
        switch self {
        case .overview: "Overview"
        case .recovery: "Recovery"
        case .strain: "Strain"
        case .activity: "Activity"
        case .temperature: "Temperature"
        case .cardiovascular: "Cardiovascular"
        case .metabolism: "Metabolism"
        }
    }

    /// The tab a link names; Overview for none or one this build doesn't know.
    static func of(_ query: [String: String]) -> BodyTab { query["tab"].flatMap(BodyTab.init(rawValue:)) ?? .overview }

    static let pageTabs = allCases.map { PageTab(id: $0.rawValue, label: $0.label) }
}

/// One day of what a device recorded, for "From your devices" (DeviceRows in Body.tsx): the day's trends (45 days, for
/// the temperature row's own usual), its hours, the latest workouts, glucose and the lab results.
struct BodyDevices {
    /// The day it's for; nil is today.
    var date: String?
    var trends: BodyRead<Trends> = .loading
    var day: BodyRead<DayData?> = .loading
    var workouts: BodyRead<[Workout]> = .loading
    var glucose: BodyRead<MetricSheetData?> = .loading
    var labs: BodyRead<LabsData> = .loading
}

/// The Activity tab's range: its trends and workouts (Detail.tsx Activity).
struct BodyActivity {
    var days: Int
    var trends: BodyRead<Trends> = .loading
    var workouts: BodyRead<[Workout]> = .loading
}

@MainActor @Observable
final class BodyModel {
    /// Whose data this is: the session it was read under. Another person, another server or a sign-out clears it.
    private(set) var owner: Dashboard.Session?
    /// Today's summary, read only while the shared date is another day (the figure and measurements are as of today).
    private(set) var today: Summary?
    /// Weight, body fat and lean mass over the cards' 120 days, as stored (kg and %).
    private(set) var measured: BodyRead<Trends> = .loading
    /// Where each latest value came from; nil inside `.done` is a server without /body/latest (no entries there).
    private(set) var latest: BodyRead<BodyLatest?> = .loading
    /// The shared date's device readings, once the person has any.
    private(set) var devices: BodyDevices?
    /// The trend tabs' reads, by "tab|days".
    private(set) var tabs: [String: BodyRead<Trends>] = [:]
    /// The Activity tab's range.
    private(set) var activity: BodyActivity?
    /// The Activity tab's Day view: its own day (nil is today, as the web's useDay), and what came for it.
    var activityDate: String?
    private(set) var activityDay: BodyRead<DayData?> = .loading
    /// The day the Day view's answer is for, so another day's never shows.
    private(set) var activityDayFor: String??

    /// Each load takes a ticket; an answer for an older ticket (another day, range or tab asked since) is dropped.
    @ObservationIgnored private var overviewTicket = 0
    @ObservationIgnored private var tabTicket = 0
    @ObservationIgnored private var dayTicket = 0

    /// Today's summary, as the figure and measurement cards read it: the Dashboard's while it's today's, else the one
    /// read for today. Nil until this model's reads are the person's here now, so the page shows its spinner rather
    /// than the last person's measurements and device readings beside the next person's summary.
    func now(_ dashboard: Dashboard) -> Summary? {
        guard owner == dashboard.session else { return nil }
        return dashboard.date == nil ? dashboard.summary : today
    }

    /// The person's ticks: nothing of the last person's stays (the page keeps them; this only says whose they are).
    func owns(_ dashboard: Dashboard) -> Bool { owner == dashboard.session }

    /// The data is someone else's, or another server's: it goes before anything is shown.
    func adopt(_ session: Dashboard.Session) {
        guard owner != session else { return }
        owner = session
        today = nil
        measured = .loading
        latest = .loading
        devices = nil
        tabs = [:]
        activity = nil
        activityDate = nil
        activityDay = .loading
        activityDayFor = nil
    }

    /// What a failed read says, or nil for one that was only cancelled.
    static func words(_ error: Error) -> String? {
        if error is CancellationError || APIClient.isCancellation(error) { return nil }
        return error.localizedDescription
    }

    /// One read into a `BodyRead`; nil when it was cancelled or its answer is for someone else now.
    private func read<T>(_ asked: Dashboard.Session, _ dashboard: Dashboard, _ body: () async throws -> T) async -> BodyRead<T>? {
        do {
            let value = try await body()
            return dashboard.session == asked ? .done(value) : nil
        } catch {
            guard dashboard.session == asked, let words = Self.words(error) else { return nil }
            return .failed(words)
        }
    }

    // MARK: Overview

    /// The overview's reads for the shared date: today's summary when it's another day, the measurements and their
    /// sources, then, once a device has sent anything, that day's readings for the cards that show.
    func loadOverview(_ dashboard: Dashboard, reads: BodyReads) async {
        let asked = dashboard.session
        adopt(asked)
        overviewTicket += 1
        let ticket = overviewTicket
        func current() -> Bool { ticket == overviewTicket && dashboard.session == asked }
        let date = dashboard.date

        if date != nil {
            if case .done(let s)? = await read(asked, dashboard, { try await reads.summary(dashboard, nil) }), current() { today = s }
        } else {
            // Today's, kept for when the day picker moves: the figure stays up while today's is read again.
            today = dashboard.summary
        }
        guard current() else { return }
        if let m = await read(asked, dashboard, { try await reads.trends(dashboard, BodyMetric.allCases.map(\.rawValue), BodyMath.measureDays, nil) }),
           current() {
            // A failed read again keeps what's on screen.
            if m.failure == nil || measured.value == nil { measured = m }
        }
        if let l = await read(asked, dashboard, { try await reads.latest(dashboard) }), current() {
            // A failed read of the sources keeps the cards (and Add entry) as they are; only a missing route hides adding.
            if l.failure == nil || latest.value == nil { latest = l }
        }
        guard current() else { return }

        // A weigh-in typed in doesn't count (latestDataDate leaves it out): this part waits for a device's readings.
        guard let s = dashboard.summary, now(dashboard)?.latestDataDate != nil else {
            devices = nil
            return
        }
        // Today's date is nil, as a first open's missing record is: compare the record, not only its date.
        if devices == nil || devices?.date != date { devices = BodyDevices(date: date) }
        let shown = dashboard.cardShown
        if let t = await read(asked, dashboard, { try await reads.trends(dashboard, BodyOverviewMath.trendMetrics, 45, date) }), current() {
            devices?.trends = t
        }
        if shown("body.heart") || shown("body.energy") || shown("body.steps") {
            if let d = await read(asked, dashboard, { try await reads.day(dashboard, date) }), current() { devices?.day = d }
        }
        if shown("body.workout") {
            if let w = await read(asked, dashboard, { try await reads.workouts(dashboard, BodyWorkoutMath.days, date) }), current() { devices?.workouts = w }
        }
        if shown("body.glucose") {
            if let g = await read(asked, dashboard, { try await reads.glucose(dashboard, s.date) }), current() { devices?.glucose = g }
        }
        if shown("body.biomarkers") {
            if let l = await read(asked, dashboard, { try await reads.labs(dashboard) }), current() { devices?.labs = l }
        }
    }

    // MARK: Trend tabs

    /// A trend tab's metrics over its range (TrendTab and Metabolism in Body.tsx and Detail.tsx), or the Activity tab's.
    func loadTab(_ tab: BodyTab, days: Int, _ dashboard: Dashboard, reads: BodyReads) async {
        let asked = dashboard.session
        adopt(asked)
        tabTicket += 1
        let ticket = tabTicket
        func current() -> Bool { ticket == tabTicket && dashboard.session == asked }
        if tab == .activity {
            if activity?.days != days { activity = BodyActivity(days: days) }
            if let t = await read(asked, dashboard, { try await reads.trends(dashboard, BodyActivityMath.metrics, days, nil) }), current() {
                activity?.trends = t
            }
            if let w = await read(asked, dashboard, { try await reads.workouts(dashboard, days, nil) }), current() { activity?.workouts = w }
            return
        }
        let specs = BodyTrendSpec.specs(tab)
        guard !specs.isEmpty else { return }
        let key = "\(tab.rawValue)|\(days)"
        if let t = await read(asked, dashboard, { try await reads.trends(dashboard, specs.map(\.key), days, nil) }), current() {
            if t.failure == nil || tabs[key]?.value == nil { tabs[key] = t }
        }
    }

    func tabTrends(_ tab: BodyTab, days: Int) -> BodyRead<Trends> { tabs["\(tab.rawValue)|\(days)"] ?? .loading }

    /// The Activity tab's Day view (useDay): steps and active energy by the hour for its own day. Read once the tab is
    /// open, so the Day option shows only where the server has hourly data.
    func loadActivityDay(_ dashboard: Dashboard, reads: BodyReads) async {
        let asked = dashboard.session
        adopt(asked)
        dayTicket += 1
        let ticket = dayTicket
        let date = activityDate
        if activityDayFor != .some(date) { activityDay = .loading }
        if let d = await read(asked, dashboard, { try await reads.day(dashboard, date) }), ticket == dayTicket, dashboard.session == asked {
            activityDay = d
            activityDayFor = .some(date)
        }
    }

    /// The Day view exists once the day's read answered with steps or energy (useDay's `available`).
    var dayAvailable: Bool {
        guard let day = activityDay.value ?? nil else { return false }
        return day.steps != nil || day.activeEnergy != nil
    }

    /// The Day view's read has answered either way (useDay's `settled`).
    var daySettled: Bool {
        if case .loading = activityDay { return false }
        return true
    }
}

/// The overview's own constants (Body.tsx).
enum BodyOverviewMath {
    /// OVERVIEW_TRENDS: the device rows' trends, 45 days so the temperature row has its own month before its latest.
    static let trendMetrics = ["resting_hr", "recovery", "resp_rate", "body_temp", "wrist_temp", "skin_temp", "active_energy"]
    /// DEVICE_CARDS: with every one hidden, "From your devices" and its day picker go too.
    static let deviceCards = ["body.rhr", "body.hrv", "body.strain", "body.recovery", "body.heart", "body.metrics", "body.energy", "body.steps",
                              "body.workout", "body.glucose", "body.biomarkers"]
    static let title = "Your body, in perspective."
    static let sub = "Measurements you add. Progress you can see."
}

/// The Activity tab's constants (Detail.tsx Activity).
enum BodyActivityMath {
    static let metrics = ["steps", "strain", "active_energy", "exercise_min"]
}
