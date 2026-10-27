import SwiftUI

// Body's tabs over a range (Body.tsx TREND_TABS and Detail.tsx Activity and Metabolism): Recovery, Strain, Activity,
// Temperature, Cardiovascular and Metabolism, each with the range picker (the range follows you from page to page, as
// the web's does in a session). Activity also has a Day view, once the server has hourly data, and the range's workouts.

/// One chart on a trend tab (Spec in Body.tsx): its metric, title, how its values read, and whether it shows with nothing
/// in the range (`always`) or only once there's something.
struct BodyTrendSpec: Identifiable {
    let key: String
    let title: String
    let format: (Double, Units) -> String
    var tick: ((Double, Units) -> String)?
    var note: String?
    var color: Color = Palette.series1
    var zero = false
    var always = false

    var id: String { key }

    private static func temp(_ c: Double, _ u: Units) -> String { "\(Fmt.number(u.temp(c).value, 1)) \(u.temp(c).unit)" }
    private static func tempTick(_ c: Double, _ u: Units) -> String { Fmt.number(u.temp(c).value, 1) }
    private static func mass(_ kg: Double, _ u: Units) -> String { "\(Fmt.number(u.mass(kg).value, 1)) \(u.mass(kg).unit)" }
    private static func whole(_ v: Double, _: Units) -> String { Fmt.number(v) }

    static let restingHr = BodyTrendSpec(key: "resting_hr", title: "Resting heart rate", format: { v, _ in "\(Fmt.number(v)) bpm" }, tick: whole,
                                         color: Palette.series2, always: true)
    static let rmssd = BodyTrendSpec(key: "hrv_rmssd", title: "HRV (RMSSD)", format: { v, _ in "\(Fmt.number(v)) ms" }, tick: whole, note: "WHOOP, during sleep")
    static let sdnn = BodyTrendSpec(key: "hrv_sdnn", title: "HRV (SDNN)", format: { v, _ in "\(Fmt.number(v)) ms" }, tick: whole, note: "Apple Watch")
    static let vo2max = BodyTrendSpec(key: "vo2max", title: "Cardio fitness (VO₂ max)", format: { v, _ in Fmt.number(v, 1) }, note: "mL/kg·min", color: Palette.series3)
    static let activeEnergy = BodyTrendSpec(key: "active_energy", title: "Active energy", format: { v, _ in "\(Fmt.number(v)) kcal" },
                                            tick: { v, _ in Fmt.compact(v) }, color: Palette.series2, zero: true, always: true)
    static let strain = BodyTrendSpec(key: "strain", title: "Day strain", format: { v, _ in Fmt.number(v, 1) }, note: "WHOOP, 0–21", color: Palette.series2, zero: true)
    static let exercise = BodyTrendSpec(key: "exercise_min", title: "Exercise minutes", format: { v, _ in "\(Fmt.number(v)) min" }, tick: whole,
                                        color: Palette.series3, zero: true)

    /// Each tab's charts, in the web's order.
    static func specs(_ tab: BodyTab) -> [BodyTrendSpec] {
        switch tab {
        case .overview, .activity: []
        case .recovery:
            [BodyTrendSpec(key: "recovery", title: "Recovery", format: { v, _ in "\(Fmt.number(v))%" }, note: "WHOOP", color: Palette.series3), rmssd, sdnn, restingHr]
        case .strain: [strain, activeEnergy, exercise]
        case .temperature:
            [BodyTrendSpec(key: "body_temp", title: "Body temperature", format: temp, tick: tempTick),
             BodyTrendSpec(key: "wrist_temp", title: "Wrist temperature", format: temp, tick: tempTick, note: "Apple Watch, during sleep"),
             BodyTrendSpec(key: "skin_temp", title: "Skin temperature", format: temp, tick: tempTick, note: "WHOOP")]
        case .cardiovascular:
            [restingHr, rmssd, sdnn,
             BodyTrendSpec(key: "spo2", title: "Blood oxygen", format: { v, _ in "\(Fmt.number(v, 1))%" }, tick: whole, color: Palette.series2, always: true),
             BodyTrendSpec(key: "resp_rate", title: "Respiratory rate", format: { v, _ in "\(Fmt.number(v, 1)) rpm" }, tick: { v, _ in Fmt.number(v, 1) }, always: true),
             vo2max]
        case .metabolism:
            // Weight and composition (Detail.tsx Metabolism): weight, body fat and VO₂ max always, lean mass once there's any.
            [BodyTrendSpec(key: "weight", title: "Weight", format: mass, tick: { v, u in Fmt.number(u.mass(v).value, 1) }, always: true),
             BodyTrendSpec(key: "body_fat", title: "Body fat", format: { v, _ in "\(Fmt.number(v, 1))%" }, color: Palette.series2, always: true),
             BodyTrendSpec(key: "vo2max", title: "Cardio fitness (VO₂ max)", format: { v, _ in Fmt.number(v, 1) }, note: "mL/kg·min", color: Palette.series3, always: true),
             BodyTrendSpec(key: "lean_mass", title: "Lean body mass", format: mass, tick: { v, u in Fmt.number(u.mass(v).value, 1) })]
        }
    }

    /// The charts that show: the `always` ones, and the rest once the range has anything.
    static func shown(_ specs: [BodyTrendSpec], in trends: Trends) -> [BodyTrendSpec] {
        specs.filter { $0.always || !(trends[$0.key]?.isEmpty ?? true) }
    }
}

/// One spec drawn as a trend card.
struct BodySpecCard: View {
    let spec: BodyTrendSpec
    let points: [Point]
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        let units = dashboard.units
        BodyTrendCard(title: spec.title, points: points, format: { spec.format($0, units) }, tick: spec.tick.map { t in { t($0, units) } },
                      note: spec.note, color: spec.color, zero: spec.zero)
            .accessibilityIdentifier("trend.\(spec.key)")
    }
}

/// A range that couldn't be read: the server's words, never "not set up".
struct BodyReadFailed: View {
    let title: String
    let words: String

    var body: some View {
        Unavailable(title, systemImage: "chart.line.downtrend.xyaxis", description: words) { EmptyView() }
            .frame(maxWidth: .infinity, minHeight: 200)
    }
}

/// "Nothing recorded in this range." (TrendTab's empty card).
struct BodyNothingInRange: View {
    var body: some View {
        Text("Nothing recorded in this range.").font(.app(.footnote)).foregroundStyle(Palette.ink2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
    }
}

// MARK: - Activity

/// How the Activity tab shows (useDay's mode): one day by the hour, the range, or waiting to hear whether the server has
/// hourly data at all (Day was picked before, here or on another page).
enum BodyActivityMode: Equatable {
    case day, range, pending

    static func of(rangeDays: Int, available: Bool, settled: Bool) -> BodyActivityMode {
        rangeDays != ChartRange.day.days ? .range : available ? .day : settled ? .range : .pending
    }
}

/// One metric's day on the Activity tab (Detail.tsx DayCard): the running total by now against a typical day, with the
/// step goal. A tap or drag on it doesn't pick an hour here: the page keeps its scroll.
struct BodyDayCard: View {
    let metric: HourMetric
    let series: DaySeries
    let data: DayData
    var goal: Double?

    var body: some View {
        let reading = DayReading(metric: metric, series: series, data: data)
        let dayLabel = data.date >= data.today ? "Today" : Fmt.day(data.date, "EEEMMMd")
        VStack(alignment: .leading, spacing: 6) {
            Text(metric.title).font(.app(.footnote, weight: .medium)).foregroundStyle(Palette.ink)
            Text(reading.value.map(metric.format) ?? String.emptyValue).font(.app(size: 28, weight: .medium, relativeTo: .title)).tracking(-0.5)
                .foregroundStyle(Palette.ink)
            Text(reading.note).font(.app(.caption)).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true)
            if reading.through != nil {
                HoursChart(metric: metric, series: series, reading: reading, goal: goal, label: "\(metric.title) by hour, \(dayLabel)")
                    .duoChartHeight(200)
                    // HoursChart picks an hour with Swift Charts' own selection, which would take every drag on it.
                    .allowsHitTesting(false)
                    .padding(.top, 6)
                ChartLegend([(label: dayLabel, color: metric.color), (label: "Typical (median of the last 30 days)", color: Palette.ink2)])
            } else {
                Text("No readings on this day").font(.app(.footnote)).foregroundStyle(Palette.ink3).frame(maxWidth: .infinity, minHeight: 120)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("activity.day.\(metric.title == "Steps" ? "steps" : "energy")")
    }
}

/// The range's workouts, newest first (Activity's Workouts table): each one's sport, day, figures and where it came
/// from, up to 200.
struct BodyWorkoutsCard: View {
    let read: BodyRead<[Workout]>
    @Environment(Dashboard.self) private var dashboard

    static let most = 200

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Workouts").font(.app(.headline, weight: .medium)).foregroundStyle(Palette.ink).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Text("\(read.value?.count ?? 0) in this range").font(.app(.caption)).foregroundStyle(Palette.ink3)
            }
            switch read {
            case .loading: ProgressView().frame(maxWidth: .infinity)
            case .failed(let words): Text("Couldn't load your workouts: \(words)").font(.app(.footnote)).foregroundStyle(Palette.ink2)
            case .done(let list):
                if list.isEmpty { Text("No workouts in this range.").font(.app(.footnote)).foregroundStyle(Palette.ink3) }
                let shown = Array(list.prefix(Self.most))
                ForEach(shown) { w in
                    WorkoutListRow(workout: w, units: dashboard.units)
                    if w.id != shown.last?.id { Divider().overlay(Palette.border) }
                }
            }
        }
        .card()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("activity.workouts")
    }
}
