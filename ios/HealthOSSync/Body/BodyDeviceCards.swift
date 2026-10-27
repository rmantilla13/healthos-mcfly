import SwiftUI

// "From your devices" (Body.tsx DeviceRows): one day of what WHOOP, Apple Watch or a Fitbit export recorded, for the
// shared date. Resting heart rate, HRV, strain (or active energy) and recovery (or cardio fitness); heart rate by the
// hour and the overnight body metrics; energy and steps by the hour; the latest workout, glucose and the latest lab
// results. A card opens its metric's sheet; one without a reading opens its tab. Every number is a reading or a plain
// sum of readings.

/// Where a card leads: its metric's sheet (with the page its "Open …" names, a range and the day), or a page.
enum BodyCardLink {
    case sheet(MetricKey, page: AppRoute, range: MetricRange? = nil, date: String?)
    case page(AppRoute)

    static func tab(_ tab: BodyTab) -> AppRoute { tab == .overview ? .body : AppRoute(.body, query: ["tab": tab.rawValue]) }
}

/// A device card (the web's .card.metric with its CardHead): the title and its ↗, anything beside it (a change chip),
/// and the card's content; the whole card opens its link.
struct BodyCard<Accessory: View, Content: View>: View {
    let title: String
    var tint: CardTint = .plain
    let link: BodyCardLink
    var spoken: String?
    var id: String
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        Button {
            switch link {
            case let .sheet(key, page, range, date): dashboard.showMetric(key, section: "Body", page: page, range: range, date: date)
            case let .page(route): dashboard.open(route)
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 8) {
                    Text(title).font(.app(.footnote, weight: .medium)).foregroundStyle(Palette.ink).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    accessory
                    Image(systemName: "arrow.up.right").font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.ink2)
                        .frame(width: 26, height: 26)
                        .padding(.vertical, -4)
                        .padding(.trailing, -6)
                        .accessibilityHidden(true)
                }
                content.frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .card(tint)
            .contentShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        }
        .buttonStyle(CardPressStyle())
        .modifier(BodySpoken(text: spoken))
        .accessibilityHint({
            switch link {
            case .sheet: "Opens \(title) details"
            case .page(let route): "Opens \(SheetPage.name(route))"
            }
        }())
        .accessibilityIdentifier(id)
    }
}

extension BodyCard where Accessory == EmptyView {
    init(title: String, tint: CardTint = .plain, link: BodyCardLink, spoken: String? = nil, id: String, @ViewBuilder content: () -> Content) {
        self.init(title: title, tint: tint, link: link, spoken: spoken, id: id, accessory: { EmptyView() }, content: content)
    }
}

private struct BodySpoken: ViewModifier {
    let text: String?
    func body(content: Content) -> some View {
        if let text { content.accessibilityLabel(text) } else { content }
    }
}

/// The card's big figure, its unit on the line below (.metric-value: 40px, 500; small 13px).
struct BodyValue: View {
    let value: String
    let unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value).font(.app(size: 40, weight: .medium, relativeTo: .largeTitle)).tracking(-0.03 * 40).foregroundStyle(Palette.ink)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(unit).font(.app(.footnote)).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 6)
    }
}

/// A card without a reading (NoData): its words at the bottom.
struct BodyNoData: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading) {
            Spacer(minLength: 24)
            Text(text).font(.app(.footnote)).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 90, alignment: .bottomLeading)
    }
}

/// The card's foot: what it is in ink on the left (with the reading's day when it isn't the one shown), a note on the
/// right; stacked when they don't fit side by side.
struct BodyFoot: View {
    let strong: String
    var stale: String?
    var trailing: String?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) {
                lead
                Spacer(minLength: 8)
                if let trailing { Text(trailing).foregroundStyle(Palette.ink2) }
            }
            VStack(alignment: .leading, spacing: 4) {
                lead
                if let trailing { Text(trailing).foregroundStyle(Palette.ink2) }
            }
        }
        .font(.app(.caption))
        .padding(.top, 6)
    }

    private var lead: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(strong).font(.app(.footnote, weight: .medium)).foregroundStyle(Palette.ink)
            if let stale { Text(stale).font(.app(size: 11, relativeTo: .caption2)).foregroundStyle(Palette.ink3) }
        }
    }
}

/// The words the device cards use (Body.tsx STATUS, HRV_STATUS, ZONE and the strain bands), so the tests check them.
enum BodyDeviceWords {
    static let status = ["low": "Below your usual", "normal": "Within your usual", "high": "Above your usual"]
    /// The summary's HRV status: "optimal" is any night at or above the person's mean, as on Home.
    static let hrvStatus = ["optimal": "At or above your usual", "normal": "Within your usual", "low": "Below your usual"]
    static let zone = ["green": (text: "High", range: "67–100"), "yellow": (text: "Moderate", range: "34–66"), "red": (text: "Low", range: "0–33")]

    /// This week against last (weekPct): nil without both.
    static func weekPct(_ w: WeekSummary.Pair?) -> Double? {
        guard let avg = w?.avg, let prev = w?.prev, prev != 0 else { return nil }
        return (avg - prev) / prev * 100
    }

    static func strainBand(_ l: Summary.Load) -> String {
        let v = l.latest.value
        if l.kind == "strain" { return v < 10 ? "Light" : v < 14 ? "Moderate" : v < 18 ? "High" : "All out" }
        return v >= (l.average ?? 0) ? "Above usual" : "Below usual"
    }

    /// The reading's day when it isn't the day shown (Stale).
    static func stale(_ date: String, asOf: String) -> String? { date == asOf ? nil : Fmt.day(date) }
}

// MARK: - The first row

struct BodyRestingHrCard: View {
    let summary: Summary
    let points: [Point]

    var body: some View {
        let v = summary.vitals?.heart
        if let l = v?.latest {
            BodyCard(title: "Resting heart rate", tint: .green,
                     link: .sheet(.restingHr, page: BodyCardLink.tab(.cardiovascular), date: summary.date),
                     spoken: "Resting heart rate, \(Fmt.number(l.value)) beats per minute, \(v?.status.flatMap { BodyDeviceWords.status[$0] } ?? "Building your baseline")",
                     id: "body.rhr") {
                BodyValue(value: Fmt.number(l.value), unit: "bpm")
                BodyChange(pct: BodyDeviceWords.weekPct(summary.week?.restingHr), better: .down)
                if points.count > 1 { MiniLine(points: Array(points.suffix(14)), color: Palette.good).frame(height: 48).padding(.top, 4) }
                Spacer(minLength: 0)
                BodyFoot(strong: v?.status.flatMap { BodyDeviceWords.status[$0] } ?? "Building your baseline",
                         stale: BodyDeviceWords.stale(l.date, asOf: summary.date), trailing: "last 30 days")
            }
        } else {
            BodyCard(title: "Resting heart rate", tint: .green, link: .page(BodyCardLink.tab(.cardiovascular)), id: "body.rhr") {
                BodyNoData(text: "No resting heart rate yet.")
            }
        }
    }
}

struct BodyHrvCard: View {
    let summary: Summary

    var body: some View {
        if let h = summary.hrv, let l = h.latest {
            let status = h.status.flatMap { BodyDeviceWords.hrvStatus[$0] } ?? "Building your baseline"
            BodyCard(title: "HRV", tint: .blue, link: .sheet(.hrv, page: BodyCardLink.tab(.recovery), date: summary.date),
                     spoken: "HRV, \(Fmt.number(l.value)) milliseconds, \(status)", id: "body.hrv") {
                BodyValue(value: Fmt.number(l.value), unit: "ms")
                BodyChange(pct: BodyDeviceWords.weekPct(summary.week?.hrv), better: .up)
                SignalDots(points: h.series ?? [], baseline: h.baseline).frame(height: 56).padding(.top, 4)
                Spacer(minLength: 0)
                BodyFoot(strong: status, stale: BodyDeviceWords.stale(l.date, asOf: summary.date), trailing: h.metric == "hrv_rmssd" ? "RMSSD" : "SDNN")
            }
        } else {
            BodyCard(title: "HRV", tint: .blue, link: .page(BodyCardLink.tab(.recovery)), id: "body.hrv") {
                BodyNoData(text: "No HRV readings yet.")
            }
        }
    }
}

struct BodyStrainCard: View {
    let summary: Summary

    var body: some View {
        if let l = summary.load {
            let strain = l.kind == "strain"
            let v = l.latest.value
            let max = strain ? 21 : Swift.max(800, (l.average ?? 0) * 1.6)
            BodyCard(title: strain ? "Strain" : "Active energy", tint: .pink,
                     link: .sheet(strain ? .strain : .activeEnergy, page: BodyCardLink.tab(.strain), date: summary.date),
                     spoken: "\(strain ? "Strain \(Fmt.number(v, 1)) of 21" : "Active energy \(Fmt.number(v)) kilocalories"), \(BodyDeviceWords.strainBand(l))",
                     id: "body.strain") {
                BodyValue(value: strain ? Fmt.number(v, 1) : Fmt.number(v), unit: strain ? "0–21" : "kcal")
                HalfGauge(fraction: v / max).frame(width: 168, height: 92).frame(maxWidth: .infinity)
                Spacer(minLength: 0)
                BodyFoot(strong: BodyDeviceWords.strainBand(l), stale: BodyDeviceWords.stale(l.latest.date, asOf: summary.date),
                         trailing: l.average.flatMap { $0 > 0 ? "\(Fmt.signed((v - $0) / $0 * 100))% vs avg" : nil })
            }
        } else {
            BodyCard(title: "Strain", tint: .pink, link: .page(BodyCardLink.tab(.strain)), id: "body.strain") {
                BodyNoData(text: "Strain comes from WHOOP; active energy from Apple Health.")
            }
        }
    }
}

struct BodyRecoveryCard: View {
    let summary: Summary
    let points: [Point]

    var body: some View {
        if let r = summary.readiness, r.kind == "vo2max" {
            let delta = r.previous.map { r.latest.value - $0 }
            BodyCard(title: "Cardio fitness", tint: .green, link: .sheet(.vo2max, page: BodyCardLink.tab(.cardiovascular), date: summary.date),
                     spoken: "Cardio fitness, VO₂ max \(Fmt.number(r.latest.value, 1))", id: "body.recovery") {
                BodyValue(value: Fmt.number(r.latest.value, 1), unit: "VO₂ max, mL/kg·min")
                if let delta { Chip(text: "\(Fmt.signed(delta, 1)) vs last month") }
                Spacer(minLength: 0)
                BodyFoot(strong: "From Apple Watch", stale: BodyDeviceWords.stale(r.latest.date, asOf: summary.date))
            }
        } else if let r = summary.readiness {
            let zone = r.zone ?? (r.latest.value >= 67 ? "green" : r.latest.value >= 34 ? "yellow" : "red")
            let z = BodyDeviceWords.zone[zone]
            BodyCard(title: "Recovery", tint: .green, link: .sheet(.recovery, page: BodyCardLink.tab(.recovery), date: summary.date),
                     spoken: "Recovery, \(Fmt.number(r.latest.value)) percent, \(z?.text ?? "")", id: "body.recovery") {
                BodyValue(value: Fmt.number(r.latest.value), unit: "%")
                BodyChange(pct: BodyDeviceWords.weekPct(summary.week?.recovery), better: .up)
                if points.count > 1 { BodyMiniBars(points: Array(points.suffix(14)), bar: Palette.barGreen, accent: Palette.barGreenAccent).frame(height: 50).padding(.top, 4) }
                Spacer(minLength: 0)
                HStack(alignment: .firstTextBaseline) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Circle().fill(BodyZone.color(zone)).frame(width: 8, height: 8)
                        Text(z?.text ?? zone).font(.app(.footnote, weight: .medium)).foregroundStyle(Palette.ink)
                        if let stale = BodyDeviceWords.stale(r.latest.date, asOf: summary.date) {
                            Text(stale).font(.app(size: 11, relativeTo: .caption2)).foregroundStyle(Palette.ink3)
                        }
                    }
                    Spacer(minLength: 8)
                    if let range = z?.range { Text(range).font(.app(.caption)).foregroundStyle(Palette.ink2) }
                }
                .padding(.top, 6)
            }
        } else {
            BodyCard(title: "Recovery", tint: .green, link: .page(BodyCardLink.tab(.recovery)), id: "body.recovery") {
                BodyNoData(text: "Recovery comes from WHOOP; cardio fitness from Apple Watch.")
            }
        }
    }
}

enum BodyZone {
    static func color(_ zone: String) -> Color {
        switch zone {
        case "green": Palette.good
        case "yellow": Palette.warning
        default: Palette.critical
        }
    }
}

/// Mini.tsx MiniBars in a tone: a bar a day with rounded tops, the latest in the darker step.
struct BodyMiniBars: View {
    let points: [Point]
    let bar: Color
    let accent: Color

    var body: some View {
        Canvas { ctx, size in
            let n = points.count
            guard n > 0 else { return }
            let top = max(points.map(\.value).max() ?? 1, 1)
            let slot = size.width / CGFloat(n)
            let w = max(3, min(10, slot - 2))
            for (i, p) in points.enumerated() {
                let h = CGFloat(p.value / top) * (size.height - 4)
                guard h > 0 else { continue }
                let x = CGFloat(i) * slot + slot / 2 - w / 2
                let r = min(4, w / 2, h)
                let rect = CGRect(x: x, y: size.height - h, width: w, height: h)
                ctx.fill(Path(roundedRect: rect, cornerRadii: RectangleCornerRadii(topLeading: r, topTrailing: r)), with: .color(i == n - 1 ? accent : bar))
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - A day by the hour

/// The day's hours as the cards draw them (drawThrough, cumulative and extent in src/charts/day.ts).
enum BodyDayMath {
    /// The last hour to draw: a past day is whole; today stops at its latest synced hour; nil without any.
    static func through(_ day: DayData) -> Int? {
        guard let asOf = day.asOf else { return nil }
        return day.date < day.today ? 23 : min(max(asOf, 0), 23)
    }

    /// The hours up to `through`, nil after it.
    static func upTo(_ hours: [Double?], _ through: Int?) -> [Double?] {
        hours.enumerated().map { h, v in through.map { h <= $0 } == true ? v : nil }
    }

    static func cumulative(_ hours: [Double?], through: Int?) -> [Double?] {
        var sum = 0.0
        return hours.enumerated().map { h, v in
            guard let through, h <= through else { return nil }
            sum += v ?? 0
            return sum
        }
    }

    static func extent(_ lists: [Double?]...) -> ClosedRange<Double>? {
        let vs = lists.flatMap { $0 }.compactMap { $0 }.filter(\.isFinite)
        guard let lo = vs.min(), let hi = vs.max() else { return nil }
        return lo...hi
    }

    static func clock(_ h: Int) -> String { String(format: "%02d:00", h) }
}

/// Heart rate by the hour (HeartTodayCard): the hour now (or the day's average) and the day's range so far, against
/// your typical hour.
struct BodyHeartCard: View {
    let day: DayData?

    /// What the card says: its title, value, unit line and range; nil value means no readings.
    struct Words: Equatable {
        var title: String
        var value: String?
        var unit: String
        var range: String?
        var empty: String
    }

    static func words(_ day: DayData?) -> Words {
        let isToday = day.map { $0.date == $0.today } ?? true
        let title = isToday ? "Heart rate today" : "Heart rate"
        let hr = day?.heartRate
        let through = day.flatMap(BodyDayMath.through)
        let hours = BodyDayMath.upTo(hr?.hours ?? [], through)
        let readings = hours.compactMap { $0 }
        let empty = day != nil && hr == nil ? "Heart rate by the hour comes from Apple Watch, through the healthOS iPhone app." : "No heart rate readings on this day."
        guard let hr, readings.count > 1 else { return Words(title: title, value: nil, unit: "", range: nil, empty: empty) }
        // The day's lowest and highest readings, not the range of the hourly averages (as on Vitals).
        let range = BodyDayMath.extent(BodyDayMath.upTo(hr.min ?? [], through), BodyDayMath.upTo(hr.max ?? [], through)) ?? BodyDayMath.extent(readings)
        let last = isToday ? day?.asOf : nil
        let latest = last.flatMap { hours.indices.contains($0) ? hours[$0] : nil }
        let mean = readings.reduce(0, +) / Double(readings.count)
        let unit = latest != nil && last != nil ? "bpm, \(BodyDayMath.clock(last!))–\(BodyDayMath.clock(last! + 1))" : "bpm, average for the day"
        return Words(title: title, value: Fmt.number(latest ?? mean.rounded()), unit: unit,
                     range: range.map { "\(Fmt.number($0.lowerBound))–\(Fmt.number($0.upperBound)) bpm \(isToday ? "so far" : "that day")" }, empty: empty)
    }

    var body: some View {
        let w = Self.words(day)
        if let day, let hr = day.heartRate, let value = w.value {
            let through = BodyDayMath.through(day)
            let isToday = day.date == day.today
            BodyCard(title: w.title, link: .sheet(.heartRate, page: .vitals, date: day.date),
                     spoken: "\(w.title), \(value) \(w.unit), \(w.range ?? "")", id: "body.heart") {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline) {
                        BodyValue(value: value, unit: w.unit)
                        Spacer(minLength: 8)
                        if let r = w.range { Text(r).font(.app(.caption)).foregroundStyle(Palette.ink2) }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        BodyValue(value: value, unit: w.unit)
                        if let r = w.range { Text(r).font(.app(.caption)).foregroundStyle(Palette.ink2) }
                    }
                }
                BodyHourCurve(hours: BodyDayMath.upTo(hr.hours, through), typical: hr.typical, marker: isToday ? day.asOf : nil,
                              format: { Fmt.number($0) }, label: "Heart rate by the hour, \(isToday ? "today" : Fmt.day(day.date))")
                    .duoChartHeight(170)
                    .allowsHitTesting(false)
                HStack(spacing: 8) {
                    Path { p in p.move(to: CGPoint(x: 0, y: 1)); p.addLine(to: CGPoint(x: 14, y: 1)) }
                        .stroke(Palette.ink2, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])).frame(width: 14, height: 2)
                    Text("Your typical hour, last 30 days").font(.app(.caption)).foregroundStyle(Palette.ink2)
                }
                .padding(.top, 6)
            }
        } else {
            BodyCard(title: w.title, link: .page(.vitals), id: "body.heart") { BodyNoData(text: w.empty) }
        }
    }
}

/// Active energy by the hour (EnergyCard), or the day's total when there are no hours.
struct BodyEnergyCard: View {
    let day: DayData?
    let points: [Point]
    let date: String

    var body: some View {
        let e = day?.activeEnergy
        let through = day.flatMap(BodyDayMath.through)
        let hours = BodyDayMath.upTo(e?.hours ?? [], through)
        let total = hours.compactMap { $0 }.reduce(0, +)
        let daily = points.first { $0.date == date }
        let isToday = day.map { $0.date == $0.today } ?? false
        if let day, e != nil, total > 0 {
            BodyCard(title: "Energy burned", link: .sheet(.activeEnergy, page: BodyCardLink.tab(.strain), range: .day, date: date),
                     spoken: "Energy burned, \(Fmt.number(total)) active kilocalories\(isToday ? " so far" : "")", id: "body.energy") {
                BodyValue(value: Fmt.number(total), unit: "active kcal\(isToday ? " so far" : "")")
                BodyHourBars(hours: hours, from: BodyHourBars.firstHour(hours), accent: isToday ? day.asOf : nil,
                             bar: Palette.barOrange, accentBar: Palette.series2, label: "Active energy by the hour")
                    .frame(height: 120)
                    .padding(.top, 8)
            }
        } else if let daily {
            BodyCard(title: "Energy burned", link: .sheet(.activeEnergy, page: BodyCardLink.tab(.strain), date: date), id: "body.energy") {
                BodyValue(value: Fmt.number(daily.value), unit: "active kcal")
                BodyNoData(text: "No hourly readings for this day.")
            }
        } else {
            BodyCard(title: "Energy burned", link: .page(BodyCardLink.tab(.strain)), id: "body.energy") {
                BodyNoData(text: "No active energy recorded on this day.")
            }
        }
    }
}

/// Steps by the hour (StepsCard, "Activity level"): the day's count against the goal and against your typical count by
/// this hour. Its sheet's "Open …" is Body's Activity tab.
struct BodyStepsDayCard: View {
    let day: DayData?
    let summary: Summary
    let goal: Double

    struct Count: Equatable {
        var value: Double
        var counted: Double
        var whoop: Bool
        var typical: Double?
    }

    /// The day's count (Body.tsx StepsCard): WHOOP's when it counted more than the phone or Watch did, else the hours'.
    static func count(_ day: DayData?, summary: Summary) -> Count {
        let st = day?.steps
        let through = day.flatMap(BodyDayMath.through)
        let run = BodyDayMath.cumulative(st?.hours ?? [], through: through)
        let counted = through.flatMap { run.indices.contains($0) ? run[$0] : nil } ?? 0
        let whoop = st?.total?.source == "whoop" && (st?.total?.value ?? 0) > counted
        let fallback = summary.activity?.latest.flatMap { $0.date == summary.date ? $0.value : nil } ?? 0
        let value = st?.total.map { max($0.value, counted) } ?? (counted > 0 ? counted : fallback)
        let typical = through.flatMap { st?.typical.indices.contains($0) == true ? st?.typical[$0] : nil }
        return Count(value: value, counted: counted, whoop: whoop, typical: typical)
    }

    var body: some View {
        let c = Self.count(day, summary: summary)
        let isToday = day.map { $0.date == $0.today } ?? true
        let through = day.flatMap(BodyDayMath.through)
        let hours = BodyDayMath.upTo(day?.steps?.hours ?? [], through)
        let pct = c.typical.flatMap { $0 > 0 ? (c.counted - $0) / $0 * 100 : nil }
        if c.value > 0 {
            BodyCard(title: "Activity level", link: .sheet(.steps, page: .activity, range: .day, date: summary.date),
                     spoken: "Activity level, \(Fmt.number(c.value)) steps\(isToday ? " so far" : ""), goal \(Fmt.number(goal))", id: "body.steps") {
                BodyChange(pct: pct, better: .up, spoken: isToday ? "against your typical count by this hour" : "against your typical day")
            } content: {
                BodyValue(value: Fmt.number(c.value), unit: "steps\(isToday ? " so far" : "") · goal \(Fmt.compact(goal))")
                if c.counted > 0 {
                    BodyHourBars(hours: hours, from: BodyHourBars.firstHour(hours), accent: isToday ? day?.asOf : nil,
                                 bar: Palette.barGreen, accentBar: Palette.barGreenAccent, label: "Steps by the hour")
                        .frame(height: 120)
                        .padding(.top, 8)
                }
                if c.whoop {
                    Text("The day's count is WHOOP's; the hours are from your iPhone or Apple Watch (\(Fmt.number(c.counted))).")
                        .font(.app(.caption)).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            BodyCard(title: "Activity level", link: .page(.activity), id: "body.steps") { BodyNoData(text: "No steps recorded on this day.") }
        }
    }
}

// MARK: - Body metrics

/// The overnight readings in rows (BodyMetricsCard): temperature against your usual, breathing, blood oxygen and HRV,
/// each opening its tab.
struct BodyMetricsCard: View {
    let summary: Summary
    let trends: Trends
    @Environment(Dashboard.self) private var dashboard
    @Environment(\.duoBand) private var band

    struct Row: Equatable, Identifiable {
        let id: String
        let symbol: String
        let label: String
        let value: String
        let status: String?
        let points: [Point]
        let tab: BodyTab
        var color: Color = Palette.series1
    }

    static let tempMetric = ["Body temp": "body_temp", "Wrist temp": "wrist_temp", "Skin temp": "skin_temp"]

    static func rows(_ s: Summary, trends t: Trends, units: Units) -> [Row] {
        var rows: [Row] = []
        if let tv = s.vitals?.temp, let latest = tv.latest {
            let tm = tempMetric[tv.label ?? ""] ?? "body_temp"
            let pts = t[tm] ?? []
            // A watch or band reads the skin, so its number means little alone: the difference from your usual. The 30
            // days before the latest reading, with seven nights at least: the same window and minimum as its status.
            let prior = pts.filter { $0.date < latest.date && $0.date >= Day.add(latest.date, -30) }.map(\.value)
            let base = tm == "body_temp" || prior.count < 7 ? nil : prior.reduce(0, +) / Double(prior.count)
            let unit = units.temp(0).unit
            let delta = base.map { (latest.value - $0) * (units == .imperial ? 9.0 / 5 : 1) }
            let value: String
            if let delta {
                value = "\(abs(delta) < 0.05 ? "±" : delta > 0 ? "+" : "−")\(Fmt.number(abs(delta), 1)) \(unit)"
            } else {
                value = "\(Fmt.number(units.temp(latest.value).value, 1)) \(unit)"
            }
            let status = tv.status.flatMap { BodyDeviceWords.status[$0] } ?? (delta != nil ? "Against your usual" : tm == "body_temp" ? nil : "Building your baseline")
            let label = tv.label == "Body temp" ? "Body temperature" : "\(tv.label == "Wrist temp" ? "Wrist" : "Skin") temperature"
            rows.append(Row(id: "temp", symbol: "sun.max", label: label, value: value, status: status, points: pts, tab: .temperature, color: Palette.series3))
        }
        if let br = s.vitals?.breathing, let l = br.latest {
            rows.append(Row(id: "resp", symbol: "waveform.path.ecg", label: "Respiratory rate", value: "\(Fmt.number(l.value, 1)) rpm",
                            status: br.status.flatMap { BodyDeviceWords.status[$0] }, points: t["resp_rate"] ?? [], tab: .cardiovascular))
        }
        if let sp = s.spo2, let l = sp.latest {
            rows.append(Row(id: "spo2", symbol: "heart", label: "Blood oxygen",
                            value: "\(Fmt.number(l.value, l.value.truncatingRemainder(dividingBy: 1) == 0 ? 0 : 1))%",
                            status: sp.status.map { $0 == "low" ? "Below your range" : "Normal" }, points: sp.series ?? [], tab: .cardiovascular,
                            color: Palette.series2))
        }
        if let h = s.hrv, let l = h.latest {
            rows.append(Row(id: "hrv", symbol: "chart.line.uptrend.xyaxis", label: "Heart rate variability", value: "\(Fmt.number(l.value)) ms",
                            status: h.status.flatMap { BodyDeviceWords.hrvStatus[$0] }, points: h.series ?? [], tab: .recovery))
        }
        return rows
    }

    var body: some View {
        let rows = Self.rows(summary, trends: trends, units: dashboard.units)
        VStack(alignment: .leading, spacing: 6) {
            Button { dashboard.open(BodyCardLink.tab(.cardiovascular)) } label: {
                HStack {
                    Text("Body metrics").font(.app(.footnote, weight: .medium)).foregroundStyle(Palette.ink)
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right").font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.ink2).accessibilityHidden(true)
                }
                .frame(minHeight: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Body metrics")
            .accessibilityHint("Opens Cardiovascular on Body")
            if rows.isEmpty {
                BodyNoData(text: "Overnight readings appear here once WHOOP or Apple Watch has a night.")
            }
            ForEach(rows) { row in
                Button { dashboard.open(BodyCardLink.tab(row.tab)) } label: { rowView(row) }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(row.label), \(row.value)\(row.status.map { ", \($0)" } ?? "")")
                    .accessibilityHint("Opens \(row.tab.label) on Body")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityIdentifier("body.metrics.\(row.id)")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("body.metrics")
    }

    private func rowView(_ row: Row) -> some View {
        HStack(spacing: 12) {
            Image(systemName: row.symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(Palette.ink2)
                .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                .frame(width: 32, height: 32)
                .background(Palette.surface2, in: Circle())
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    Text(row.label).font(.app(.subheadline)).foregroundStyle(Palette.ink).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    value(row, alignment: .trailing)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.label).font(.app(.subheadline)).foregroundStyle(Palette.ink).fixedSize(horizontal: false, vertical: true)
                    value(row, alignment: .leading)
                }
            }
            if band != .compact, row.points.count > 1 {
                MiniLine(points: Array(row.points.suffix(14)), color: row.color).frame(width: 90, height: 28)
            }
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.ink3).accessibilityHidden(true)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private func value(_ row: Row, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(row.value).font(.app(.subheadline, weight: .semibold)).foregroundStyle(Palette.ink)
            if let status = row.status { Text(status).font(.app(.caption)).foregroundStyle(Palette.ink2) }
        }
    }
}

// MARK: - Glucose and lab results

/// Glucose (GlucoseCard.tsx): the latest daily average in mg/dL and mmol/L, placed only against your own recent days,
/// from the glucose sheet's own read, so the card and the sheet it opens can't disagree.
struct BodyGlucoseCard: View {
    let summary: Summary
    let read: BodyRead<MetricSheetData?>

    static func mmol(_ mgDl: Double) -> Double { mgDl / 18.016 }

    /// "Today", "Oct 26", or "Oct 26, 2025" in another year.
    static func when(_ date: String, today: String) -> String {
        date == today ? "Today" : Fmt.day(date, date.prefix(4) == today.prefix(4) ? "MMMd" : "MMMdyyyy")
    }

    var body: some View {
        let g = read.value.flatMap { $0 }.flatMap { $0.key == .glucose ? $0 : nil }
        if let g, let l = g.latest {
            BodyCard(title: "Glucose", tint: .mint, link: .sheet(.glucose, page: .body, date: summary.date),
                     spoken: "Glucose, \(Fmt.number(l.value)) milligrams per decilitre, daily average", id: "body.glucose") {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline) {
                        BodyValue(value: Fmt.number(l.value), unit: "mg/dL")
                        Spacer(minLength: 8)
                        Text(g.status?.text ?? "Building your baseline").font(.app(.caption)).foregroundStyle(Palette.ink2)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        BodyValue(value: Fmt.number(l.value), unit: "mg/dL")
                        Text(g.status?.text ?? "Building your baseline").font(.app(.caption)).foregroundStyle(Palette.ink2)
                    }
                }
                Text("\(Fmt.number(Self.mmol(l.value), 1)) mmol/L").font(.app(.caption)).foregroundStyle(Palette.ink3)
                if g.points.count > 1 { MiniLine(points: g.points, color: Palette.series3).frame(height: 44).padding(.top, 4) }
                Spacer(minLength: 0)
                BodyFoot(strong: "Daily average", trailing: Self.when(l.date, today: summary.today))
            }
        } else {
            let text: String = switch read {
            case .loading: "Loading…"
            case .failed: "Couldn't load glucose."
            case .done: "Glucose appears when a CGM or meter writes to Apple Health."
            }
            BodyCard(title: "Glucose", tint: .mint, link: .page(.body), id: "body.glucose") { BodyNoData(text: text) }
        }
    }
}

/// Key biomarkers (BiomarkersCard.tsx): the six latest lab results against each lab's own range, newest collection
/// first, the status in words beside each bar; the rest on Blood records.
struct BodyBiomarkersCard: View {
    let read: BodyRead<LabsData>
    @Environment(Dashboard.self) private var dashboard

    static let shown = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { dashboard.open(.labs) } label: {
                HStack {
                    Text("Key biomarkers").font(.app(.footnote, weight: .medium)).foregroundStyle(Palette.ink)
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right").font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.ink2).accessibilityHidden(true)
                }
                .frame(minHeight: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Key biomarkers")
            .accessibilityHint("Opens Blood records")
            switch read {
            case .loading: BodyNoData(text: "Loading…")
            case .failed: BodyNoData(text: "Couldn't load your lab results.")
            case .done(let data):
                let markers = data.latest(Self.shown)
                if markers.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        BodyNoData(text: "No lab results yet. Add a blood test to see each result against the lab's range.")
                        Button("Add lab results") { dashboard.open(.labs) }
                            .font(.app(.footnote, weight: .semibold)).foregroundStyle(Palette.ink).buttonStyle(.plain)
                            .frame(minHeight: 44)
                    }
                } else {
                    ForEach(markers) { m in marker(m) }
                    HStack {
                        Text(data.demo == true ? "Demo results" : "Latest \(Fmt.day(markers[0].latest.collected, "MMMdyyyy"))")
                            .font(.app(.caption)).foregroundStyle(Palette.ink2)
                        Spacer(minLength: 8)
                        Button(data.markers.count > Self.shown ? "View all \(data.markers.count)" : "View all") { dashboard.open(.labs) }
                            .font(.app(.footnote, weight: .semibold)).foregroundStyle(Palette.ink).buttonStyle(.plain)
                            .frame(minHeight: 44)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("body.biomarkers")
    }

    private func marker(_ m: LabMarker) -> some View {
        let out = m.latest.status == .below || m.latest.status == .above
        return VStack(alignment: .leading, spacing: 4) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    Text(m.name).font(.app(.subheadline)).foregroundStyle(Palette.ink)
                    Spacer(minLength: 8)
                    valueText(m)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.name).font(.app(.subheadline)).foregroundStyle(Palette.ink).fixedSize(horizontal: false, vertical: true)
                    valueText(m)
                }
            }
            HStack(spacing: 12) {
                LabRangeBar(result: m.latest, compact: true)
                Text(LabWords.statusLabel(m.latest))
                    .font(.app(size: 11, weight: out ? .semibold : .regular, relativeTo: .caption2))
                    .foregroundStyle(out ? LabColors.outInk.color : Palette.ink2)
                    .fixedSize()
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private func valueText(_ m: LabMarker) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(m.latest.valueText).font(.app(.subheadline, weight: .semibold)).foregroundStyle(Palette.ink)
            if !m.latest.unit.isEmpty { Text(m.latest.unit).font(.app(.caption2)).foregroundStyle(Palette.ink2) }
        }
    }
}
