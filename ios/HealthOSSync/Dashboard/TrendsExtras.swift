import Charts
import SwiftUI

// Trends cards added in 1.1. Each takes what its section loaded and shows nothing without data, so someone with no
// blood pressure cuff, no WHOOP or no logged water never sees an empty card.

// MARK: - Vitals

/// Each night's temperature against your usual: the mean of the 30 nights before it (needs 7 readings). Wrist
/// temperature, else skin temperature, else body temperature. Fed 30 days before the range, so the first night has
/// a baseline too.
struct TempDeviationCard: View {
    /// wrist_temp, skin_temp and body_temp over the range plus the 30 days before it.
    let trends: Trends
    let days: Int
    /// The last day of the range (the person's today).
    let end: String
    let units: Units

    static let metrics = ["wrist_temp", "skin_temp", "body_temp"]
    private static let notes = ["wrist_temp": "Apple Watch, during sleep", "skin_temp": "WHOOP", "body_temp": "Apple Health"]

    struct Night: Identifiable {
        let date: String
        let value: Double
        /// Mean of the readings in the 30 days before this one, °C.
        let usual: Double
        var deviation: Double { value - usual }
        var id: String { date }
    }

    /// Readings from `start` on, each next to the mean of the readings in the 30 calendar days before it. Nights
    /// with fewer than 7 earlier readings in that window are left out.
    static func deviations(_ points: [Point], from start: String) -> [Night] {
        let sorted = points.sorted { $0.date < $1.date }
        var nights: [Night] = []
        var first = 0
        for (i, p) in sorted.enumerated() {
            let windowStart = Day.add(p.date, -30)
            while sorted[first].date < windowStart { first += 1 }
            guard p.date >= start, i - first >= 7 else { continue }
            let usual = sorted[first..<i].reduce(0) { $0 + $1.value } / Double(i - first)
            nights.append(Night(date: p.date, value: p.value, usual: usual))
        }
        return nights
    }

    /// The first of wrist, skin and body temperature that has nights to show.
    static func pick(_ trends: Trends, from start: String) -> (metric: String, nights: [Night])? {
        for m in metrics {
            let nights = deviations(trends[m] ?? [], from: start)
            if !nights.isEmpty { return (m, nights) }
        }
        return nil
    }

    var body: some View {
        if let picked = Self.pick(trends, from: Day.add(end, -(days - 1))), let latest = picked.nights.last {
            // Plotted in the display unit, so the axis lands on round °C or °F steps.
            let unit = units.tempDelta(0).unit
            let bars = picked.nights.map { Point(date: $0.date, value: units.tempDelta($0.deviation).value) }.weekly(days: days)
            let limit = Swift.max((bars.map { abs($0.value) }.max() ?? 0) * 1.2, units == .imperial ? 0.9 : 0.5)
            VStack(alignment: .leading, spacing: 6) {
                Text("Nightly temperature").font(.subheadline.weight(.medium)).foregroundStyle(Palette.ink2)
                Text(units.tempDelta(latest.deviation).signed(1)).font(.title2.weight(.semibold)).foregroundStyle(Palette.ink).monospacedDigit()
                Text("vs your usual · \(Fmt.day(latest.date)) · \(Self.notes[picked.metric] ?? "")").font(.caption).foregroundStyle(Palette.ink3)
                Chart {
                    ForEach(bars) { p in
                        BarMark(x: .value("Night", Fmt.chartDate(p.date), unit: days > 90 ? .weekOfYear : .day), y: .value("Difference", p.value))
                            .foregroundStyle(p.value >= 0 ? Palette.series2 : Palette.series1)
                            .accessibilityLabel(Fmt.day(p.date))
                            .accessibilityValue("\(Measure(value: p.value, unit: unit).signed(1)) vs your usual")
                    }
                    RuleMark(y: .value("Usual", 0)).foregroundStyle(Palette.ink3.opacity(0.6))
                }
                .chartYScale(domain: -limit...limit)
                .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { v in
                    AxisGridLine().foregroundStyle(Palette.grid)
                    AxisValueLabel { if let d = v.as(Double.self) { Text(Fmt.signed(d, 1)).foregroundStyle(Palette.ink3) } }
                } }
                .chartXAxis { extrasDateAxis() }
                .frame(height: 150)
                .padding(.top, 6)
                .accessibilityLabel("Nightly temperature vs your usual, latest \(units.tempDelta(latest.deviation).signed(1))")
                Text(days > 90 ? "Weekly averages, \(unit). Above the line is warmer than usual, below is cooler." : "Above the line is warmer than usual, below is cooler.")
                    .font(.caption2).foregroundStyle(Palette.ink3)
            }
            .card()
        }
    }
}

/// Systolic and diastolic as two lines. The headline is the latest day with both: "121/79 mmHg".
struct BloodPressureCard: View {
    let systolic: [Point]
    let diastolic: [Point]

    private struct Reading: Identifiable {
        let date: String
        let kind: String
        let value: Double
        var id: String { kind + date }
    }

    var body: some View {
        if !systolic.isEmpty || !diastolic.isEmpty {
            let lower = Dictionary(diastolic.map { ($0.date, $0.value) }, uniquingKeysWith: { a, _ in a })
            let readings = systolic.map { Reading(date: $0.date, kind: "Systolic", value: $0.value) } + diastolic.map { Reading(date: $0.date, kind: "Diastolic", value: $0.value) }
            let values = readings.map(\.value)
            let lo = (values.min() ?? 70) - 8, hi = (values.max() ?? 130) + 8
            VStack(alignment: .leading, spacing: 6) {
                Text("Blood pressure").font(.subheadline.weight(.medium)).foregroundStyle(Palette.ink2)
                Text(headline(lower)).font(.title2.weight(.semibold)).foregroundStyle(Palette.ink).monospacedDigit()
                Text(note).font(.caption).foregroundStyle(Palette.ink3)
                Chart(readings) { r in
                    LineMark(x: .value("Day", Fmt.chartDate(r.date)), y: .value("mmHg", r.value), series: .value("Reading", r.kind))
                        .foregroundStyle(by: .value("Reading", r.kind))
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                        .interpolationMethod(.monotone)
                    PointMark(x: .value("Day", Fmt.chartDate(r.date)), y: .value("mmHg", r.value))
                        .foregroundStyle(by: .value("Reading", r.kind))
                        .symbolSize(14)
                        .accessibilityLabel("\(r.kind), \(Fmt.day(r.date))")
                        .accessibilityValue("\(Fmt.number(r.value)) mmHg")
                }
                .chartForegroundStyleScale(domain: ["Systolic", "Diastolic"], range: [Palette.series2, Palette.series1])
                .chartLegend(position: .bottom, alignment: .leading)
                .chartYScale(domain: lo...hi)
                .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine().foregroundStyle(Palette.grid)
                    AxisValueLabel().foregroundStyle(Palette.ink3)
                } }
                .chartXAxis { extrasDateAxis() }
                .frame(height: 180)
                .padding(.top, 6)
                .accessibilityLabel("Blood pressure trend, latest \(headline(lower))")
            }
            .card()
        }
    }

    private func headline(_ lower: [String: Double]) -> String {
        if let s = systolic.last(where: { lower[$0.date] != nil }), let d = lower[s.date] { return "\(Fmt.number(s.value))/\(Fmt.number(d)) mmHg" }
        if let s = systolic.last { return "\(Fmt.number(s.value)) mmHg systolic" }
        if let d = diastolic.last { return "\(Fmt.number(d.value)) mmHg diastolic" }
        return "—"
    }

    private var note: String {
        let last = [systolic.last?.date, diastolic.last?.date].compactMap { $0 }.max()
        var s = last.map { Fmt.day($0) } ?? ""
        if let sys = systolic.average, let dia = diastolic.average { s += " · average \(Fmt.number(sys))/\(Fmt.number(dia))" }
        return s
    }
}

struct GlucoseCard: View {
    let points: [Point]

    var body: some View {
        if !points.isEmpty {
            TrendCard(title: "Blood glucose", points: points, format: { "\(Fmt.number($0)) mg/dL" }, note: "daily average", color: Palette.series3)
        }
    }
}

struct BreathingDisturbancesCard: View {
    let points: [Point]

    var body: some View {
        if !points.isEmpty {
            TrendCard(title: "Breathing disturbances", points: points, format: { Fmt.number($0, 1) }, note: "Apple Watch, during sleep")
        }
    }
}

// MARK: - Sleep

/// Bed and wake times night by night (GET /api/sleep), evening at the top: how much they vary, how weekends shift
/// them, and sleep need and debt.
struct SleepConsistencyCard: View {
    let timing: SleepTiming

    var body: some View {
        let nights = timing.nights
        if !nights.isEmpty {
            let stats = timing.stats
            // One axis for the whole night, minutes after 18:00: wake times (after midnight) sit at wakeMin + 360.
            // Plotted negated, so the evening is on top.
            let top = nights.map(\.bedMin).min() ?? 300
            let bottom = nights.map { $0.wakeMin + 360 }.max() ?? 780
            let step: Double = bottom - top > 600 ? 180 : 120
            let lo = (top / step).rounded(.down) * step
            let hi = Swift.max((bottom / step).rounded(.up) * step, lo + step)
            let width = Swift.max(1, Swift.min(8, 180 / Double(nights.count)))
            VStack(alignment: .leading, spacing: 6) {
                Text("Sleep schedule").font(.subheadline.weight(.medium)).foregroundStyle(Palette.ink2)
                Text(usual(stats)).font(.title2.weight(.semibold)).foregroundStyle(Palette.ink).monospacedDigit()
                Text("usual bedtime and wake time · \(nights.count) night\(nights.count == 1 ? "" : "s")").font(.caption).foregroundStyle(Palette.ink3)
                Chart {
                    ForEach(nights) { n in
                        RuleMark(x: .value("Night", Fmt.chartDate(n.date)), yStart: .value("Bedtime", -n.bedMin), yEnd: .value("Wake time", -(n.wakeMin + 360)))
                            .foregroundStyle(by: .value("Days", n.weekend ? "Weekends" : "Weekdays"))
                            .lineStyle(StrokeStyle(lineWidth: width, lineCap: .round))
                            .accessibilityLabel(Fmt.day(n.date, "EEEMMMd"))
                            .accessibilityValue("Bed \(Fmt.clock(n.bed)), up \(Fmt.clock(n.wake))")
                    }
                    if let bed = stats?.avgBedMin {
                        RuleMark(y: .value("Usual bedtime", -bed))
                            .foregroundStyle(Palette.ink3.opacity(0.6))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                    if let wake = stats?.avgWakeMin {
                        RuleMark(y: .value("Usual wake time", -(wake + 360)))
                            .foregroundStyle(Palette.ink3.opacity(0.6))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                }
                .chartForegroundStyleScale(domain: ["Weekdays", "Weekends"], range: [Palette.series1, Palette.series2])
                .chartLegend(position: .bottom, alignment: .leading)
                .chartYScale(domain: -hi...(-lo))
                .chartYAxis { AxisMarks(position: .leading, values: Array(stride(from: -hi, through: -lo, by: step))) { v in
                    AxisGridLine().foregroundStyle(Palette.grid)
                    AxisValueLabel { if let m = v.as(Double.self) { Text(Fmt.eveningClock(minutesAfter18: -m)).foregroundStyle(Palette.ink3) } }
                } }
                .chartXAxis { extrasDateAxis() }
                .frame(height: 210)
                .padding(.top, 6)
                .accessibilityLabel("Bedtime and wake time by night")
                VStack(alignment: .leading, spacing: 6) {
                    if let s = spread(stats) { ScheduleFact(icon: "clock", text: s) }
                    if let s = weekends(stats) { ScheduleFact(icon: "calendar", text: s) }
                    if let s = Self.need(stats) { ScheduleFact(icon: "bed.double", text: s) }
                }
                .padding(.top, 4)
            }
            .card()
        }
    }

    private func usual(_ stats: SleepTiming.Stats?) -> String {
        guard let bed = stats?.avgBedMin, let wake = stats?.avgWakeMin else { return "—" }
        return "\(Fmt.eveningClock(minutesAfter18: bed)) – \(Fmt.clock(minutesOfDay: wake))"
    }

    private static func minutes(_ m: Double) -> String {
        let r = abs(m).rounded()
        return r < 60 ? "\(Int(r)) min" : Fmt.duration(minutes: r)
    }

    private func spread(_ stats: SleepTiming.Stats?) -> String? {
        switch (stats?.bedSd, stats?.wakeSd) {
        case let (bed?, wake?): "Bedtime varies by about ±\(Self.minutes(bed)), wake time by ±\(Self.minutes(wake))."
        case let (bed?, nil): "Bedtime varies by about ±\(Self.minutes(bed))."
        case let (nil, wake?): "Wake time varies by about ±\(Self.minutes(wake))."
        default: nil
        }
    }

    /// The weekend midpoint against the weekday one.
    private func weekends(_ stats: SleepTiming.Stats?) -> String? {
        guard let shift = stats?.socialJetlag else { return nil }
        if abs(shift) < 10 { return "Weekends: about the same as weekdays" }
        return "Weekends: \(Self.minutes(shift)) \(shift > 0 ? "later" : "earlier")"
    }

    /// Debt counts the nights recorded in the last 7 days, which needn't be in a row or include last night.
    static func need(_ stats: SleepTiming.Stats?) -> String? {
        guard let stats, let need = stats.need else { return nil }
        var s = "Sleep need about \(Fmt.hoursMinutes(need))"
        if let debt = stats.debt, stats.debtNights > 0 {
            let nights = stats.debtNights >= 7 ? "the last 7 nights" : "\(stats.debtNights) of the last 7 nights"
            s += debt >= 0.25 ? " · \(Fmt.hoursMinutes(debt)) short over \(nights)" : " · on track over \(nights)"
        }
        return s
    }
}

private struct ScheduleFact: View {
    let icon: String
    let text: String

    var body: some View {
        Label {
            Text(text).foregroundStyle(Palette.ink2)
        } icon: {
            Image(systemName: icon).foregroundStyle(Palette.ink3)
        }
        .font(.footnote)
    }
}

// MARK: - Activity

/// Load by week: WHOOP strain summed (else active energy) over the last 12 weeks, with the average of the 4 weeks
/// before each one as a line. The status compares the last full week with its 4-week average.
struct WeeklyLoadCard: View {
    /// Days to fetch: the 12 weeks shown plus the 4 before them.
    static let days = 7 * 16
    let strain: [Point]
    let energy: [Point]
    /// The person's today; its week is the last bar, still filling up.
    let today: String

    struct Week: Identifiable {
        /// Monday.
        let start: String
        let total: Double
        /// Mean of the 4 weeks before; nil until there are 4 weeks of data before it.
        let usual: Double?
        let partial: Bool
        var id: String { start }
    }

    enum Status: String {
        case lighter = "Lighter week", steady = "Steady", building = "Building", higher = "Higher than usual"

        var tone: Tone {
            switch self {
            case .lighter: .blue
            case .steady: .green
            case .building: .yellow
            case .higher: .peach
            }
        }
    }

    /// Against the 4-week average: over 1.3× higher than usual, under 0.7× a lighter week, steady between. Building
    /// while there's no average yet (fewer than 4 full weeks of data before it).
    static func status(total: Double, usual: Double?) -> Status {
        guard let usual else { return .building }
        guard usual > 0 else { return total > 0 ? .higher : .steady }
        let ratio = total / usual
        if ratio > 1.3 { return .higher }
        if ratio < 0.7 { return .lighter }
        return .steady
    }

    /// Strain while WHOOP has a reading in the last 4 weeks, else active energy.
    static func usesStrain(_ strain: [Point], today: String) -> Bool {
        let since = Day.add(today, -27)
        return strain.contains { $0.date >= since }
    }

    /// The last `count` Monday-start weeks up to today's (partial) week, each with the mean of the 4 weeks before it.
    /// Weeks before the first reading are left out and never count toward an average.
    static func weeks(_ points: [Point], today: String, count: Int = 12) -> [Week] {
        guard let first = points.map(\.date).min() else { return [] }
        let firstMonday = Point.weekStart(first)
        let current = Point.weekStart(today)
        let sums = points.weeklySums(weeks: count + 4, ending: today)
        return sums.indices.dropFirst(4).compactMap { i in
            let w = sums[i]
            guard w.date >= firstMonday else { return nil }
            let prior = sums[(i - 4)..<i]
            let usual = prior.allSatisfy { $0.date >= firstMonday } ? prior.reduce(0) { $0 + $1.value } / 4 : nil
            return Week(start: w.date, total: w.value, usual: usual, partial: w.date == current)
        }
    }

    var body: some View {
        let isStrain = Self.usesStrain(strain, today: today)
        let weeks = Self.weeks(isStrain ? strain : energy, today: today)
        if !weeks.isEmpty {
            let last = weeks.last { !$0.partial }
            let status = Self.status(total: last?.total ?? 0, usual: last?.usual)
            let format: (Double) -> String = isStrain ? { Fmt.number($0, 1) } : { "\(Fmt.number($0)) kcal" }
            VStack(alignment: .leading, spacing: 6) {
                Text("Weekly load").font(.subheadline.weight(.medium)).foregroundStyle(Palette.ink2)
                Text(last.map { format($0.total) } ?? "—").font(.title2.weight(.semibold)).foregroundStyle(Palette.ink).monospacedDigit()
                Text(isStrain ? "last full week · WHOOP strain, added up" : "last full week · active energy, added up").font(.caption).foregroundStyle(Palette.ink3)
                HStack(spacing: 8) {
                    LoadStatusChip(text: status.rawValue, tone: status.tone)
                    Text(last?.usual.map { "4-week average \(format($0))" } ?? "your usual forms after 4 full weeks").font(.caption).foregroundStyle(Palette.ink3)
                }
                .padding(.top, 2)
                Chart {
                    ForEach(weeks) { w in
                        BarMark(x: .value("Week", Fmt.chartDate(w.start), unit: .weekOfYear), y: .value("Load", w.total), width: .ratio(0.6))
                            .foregroundStyle(w.partial ? Palette.bar.opacity(0.45) : w.id == last?.id ? Palette.series1 : Palette.bar)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                            .accessibilityLabel("Week of \(Fmt.day(w.start))")
                            .accessibilityValue(format(w.total) + (w.partial ? " so far" : ""))
                    }
                    ForEach(weeks.filter { $0.usual != nil }) { w in
                        LineMark(x: .value("Week", Fmt.chartDate(w.start), unit: .weekOfYear), y: .value("4-week average", w.usual ?? 0))
                            .foregroundStyle(Palette.series2)
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                            .interpolationMethod(.monotone)
                            .accessibilityLabel("4-week average, week of \(Fmt.day(w.start))")
                            .accessibilityValue(format(w.usual ?? 0))
                    }
                }
                .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { v in
                    AxisGridLine().foregroundStyle(Palette.grid)
                    AxisValueLabel { if let n = v.as(Double.self) { Text(Fmt.compact(n)).foregroundStyle(Palette.ink3) } }
                } }
                .chartXAxis { extrasDateAxis() }
                .frame(height: 170)
                .padding(.top, 6)
                .accessibilityLabel("Weekly load, last \(weeks.count) weeks")
                // One row when it fits, else stacked (large text sizes).
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { legend(average: weeks.contains { $0.usual != nil }) }
                    VStack(alignment: .leading, spacing: 4) { legend(average: weeks.contains { $0.usual != nil }) }
                }
                .font(.caption2)
                .foregroundStyle(Palette.ink3)
                .accessibilityHidden(true)
            }
            .card()
        }
    }

    @ViewBuilder private func legend(average: Bool) -> some View {
        Label { Text("Weekly total") } icon: { RoundedRectangle(cornerRadius: 2).fill(Palette.bar).frame(width: 10, height: 10) }
        if average { Label { Text("4-week average") } icon: { Capsule().fill(Palette.series2).frame(width: 14, height: 3) } }
        Label { Text("This week so far") } icon: { RoundedRectangle(cornerRadius: 2).fill(Palette.bar.opacity(0.45)).frame(width: 10, height: 10) }
    }
}

private struct LoadStatusChip: View {
    let text: String
    let tone: Tone

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tone.background, in: Capsule())
            .foregroundStyle(tone.ink)
    }
}

/// Walking speed, steadiness and asymmetry from iPhone and Apple Watch: the latest of each with a small line.
struct MobilityCard: View {
    /// km/h.
    let speed: [Point]
    /// 0–100.
    let steadiness: [Point]
    /// 0–100.
    let asymmetry: [Point]
    let units: Units

    var body: some View {
        if !speed.isEmpty || !steadiness.isEmpty || !asymmetry.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Mobility").font(.headline).foregroundStyle(Palette.ink)
                    Spacer()
                    Text("iPhone and Apple Watch").font(.caption).foregroundStyle(Palette.ink3)
                }
                if !speed.isEmpty {
                    MobilityRow(label: "Walking speed", points: speed, format: { units == .imperial ? "\(Fmt.number($0 / 1.609344, 1)) mph" : "\(Fmt.number($0, 1)) km/h" }, color: Palette.series1)
                }
                if !steadiness.isEmpty { MobilityRow(label: "Walking steadiness", points: steadiness, format: { "\(Fmt.number($0))%" }, color: Palette.series3) }
                if !asymmetry.isEmpty { MobilityRow(label: "Walking asymmetry", points: asymmetry, format: { "\(Fmt.number($0, 1))%" }, color: Palette.series2) }
            }
            .card()
        }
    }
}

private struct MobilityRow: View {
    let label: String
    let points: [Point]
    let format: (Double) -> String
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.subheadline.weight(.medium)).foregroundStyle(Palette.ink2)
                Text(points.last.map { format($0.value) } ?? "—").font(.title3.weight(.semibold)).foregroundStyle(Palette.ink).monospacedDigit()
                Text(caption).font(.caption).foregroundStyle(Palette.ink3).lineLimit(1).minimumScaleFactor(0.8)
            }
            Spacer(minLength: 8)
            if points.count > 1 { MiniLine(points: points, color: color).frame(width: 110, height: 44) }
        }
        .accessibilityElement(children: .combine)
    }

    private var caption: String {
        guard let last = points.last else { return "" }
        var s = Fmt.day(last.date)
        if points.count > 1, let avg = points.average { s += " · average \(format(avg))" }
        return s
    }
}

struct FlightsStandCard: View {
    let flights: [Point]
    let standHours: [Point]
    let days: Int

    var body: some View {
        if !flights.isEmpty || !standHours.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                if !flights.isEmpty {
                    DailyBarsBlock(title: "Flights climbed", points: flights, days: days, format: { ExtrasFormat.count($0, "flight", "flights") }, note: "iPhone and Apple Watch", color: Palette.series3)
                }
                if !flights.isEmpty && !standHours.isEmpty { Divider().overlay(Palette.border) }
                if !standHours.isEmpty {
                    DailyBarsBlock(title: "Stand hours", points: standHours, days: days, format: { ExtrasFormat.count($0, "hour", "hours") }, note: "Apple Watch", color: Palette.series1)
                }
            }
            .card()
        }
    }
}

struct DaylightCard: View {
    let points: [Point]
    let days: Int

    var body: some View {
        if !points.isEmpty {
            DailyBarsBlock(title: "Time in daylight", points: points, days: days, format: { "\(Fmt.number($0)) min" }, note: "Apple Watch", color: Palette.warning)
                .card()
        }
    }
}

// MARK: - Body

struct CaffeineCard: View {
    /// mg per day.
    let points: [Point]
    let days: Int

    var body: some View {
        if !points.isEmpty {
            DailyBarsBlock(title: "Caffeine", points: points, days: days, format: { "\(Fmt.number($0)) mg" }, note: "average over days you logged it", color: Palette.series2)
                .card()
        }
    }
}

struct WaterCard: View {
    /// mL per day.
    let points: [Point]
    let days: Int
    let units: Units

    var body: some View {
        if !points.isEmpty {
            // Charted in the unit shown, so the axis reads in litres or fluid ounces.
            let imperial = units == .imperial
            let shown = points.map { Point(date: $0.date, value: imperial ? $0.value / 29.5735 : $0.value / 1000) }
            DailyBarsBlock(title: "Water", points: shown, days: days, format: { imperial ? "\(Fmt.number($0)) fl oz" : "\(Fmt.number($0, 1)) L" }, note: "average over days you logged it", color: Palette.series1)
                .card()
        }
    }
}

// MARK: - Shared

/// A daily total as bars (weekly averages over long ranges), headed by the average a day.
private struct DailyBarsBlock: View {
    let title: String
    let points: [Point]
    let days: Int
    let format: (Double) -> String
    var note: String?
    var color: Color = Palette.bar

    var body: some View {
        let bars = points.weekly(days: days)
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.medium)).foregroundStyle(Palette.ink2)
            Text(points.average.map { "\(format($0)) a day" } ?? "—").font(.title2.weight(.semibold)).foregroundStyle(Palette.ink).monospacedDigit()
            Text(caption).font(.caption).foregroundStyle(Palette.ink3)
            Chart(bars) { p in
                BarMark(x: .value("Day", Fmt.chartDate(p.date), unit: days > 90 ? .weekOfYear : .day), y: .value(title, p.value))
                    .foregroundStyle(color)
                    .accessibilityLabel(Fmt.day(p.date))
                    .accessibilityValue(format(p.value))
            }
            .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { v in
                AxisGridLine().foregroundStyle(Palette.grid)
                AxisValueLabel { if let n = v.as(Double.self) { Text(n >= 1000 ? Fmt.compact(n) : n.formatted()).foregroundStyle(Palette.ink3) } }
            } }
            .chartXAxis { extrasDateAxis() }
            .frame(height: 140)
            .padding(.top, 6)
            .accessibilityLabel("\(title), \(days > 90 ? "weekly averages" : "by day")")
        }
    }

    private var caption: String {
        guard let last = points.last else { return "No data in this range" }
        var s = "\(Fmt.day(last.date)): \(format(last.value))"
        if days > 90 { s += " · bars are weekly averages" }
        if let note { s += " · \(note)" }
        return s
    }
}

private enum ExtrasFormat {
    /// "1 flight", "12 flights".
    static func count(_ value: Double, _ one: String, _ many: String) -> String {
        let n = Fmt.number(value)
        return "\(n) \(n == "1" ? one : many)"
    }
}

private func extrasDateAxis() -> some AxisContent {
    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
        AxisValueLabel(format: .dateTime.month(.abbreviated).day()).foregroundStyle(Palette.ink3)
    }
}
