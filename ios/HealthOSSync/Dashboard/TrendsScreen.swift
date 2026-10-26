import Charts
import SwiftUI

/// Charts over 7 days, 30 days, 90 days or a year (src/pages/Detail.tsx): what the Vitals, Body, Sleep and Cycle pages
/// show until each is built here. One section, or Body's two (Body and Activity) as chips.
struct TrendsPage: View {
    let sections: [TrendsSection]
    @Binding var selection: TrendsSection
    @Environment(Dashboard.self) private var dashboard
    @AppStorage("trendsDays") private var days = 30
    @Environment(\.dynamicTypeSize) private var typeSize

    /// One section, no chips.
    init(_ section: TrendsSection) {
        sections = [section]
        _selection = .constant(section)
    }

    init(sections: [TrendsSection], selection: Binding<TrendsSection>) {
        self.sections = sections
        _selection = selection
    }

    var body: some View {
        Group {
            if dashboard.signInRequired {
                SignInView()
            } else if dashboard.phase == .noServer {
                Unavailable("No server yet", systemImage: "server.rack", description: "Add your healthOS address in Profile.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if sections.count > 1 { TrendsSectionChips(selection: $selection, sections: sections) }
                        // At the accessibility text sizes the range goes under the line, so "30 days" never breaks.
                        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout())
                        layout {
                            Text(subtitle).font(.app(.footnote)).foregroundStyle(Palette.ink3)
                            if !typeSize.isAccessibilitySize { Spacer() }
                            // The cycle view has its own span.
                            if selection != .cycle {
                                Picker("Range", selection: $days) {
                                    Text("7 days").tag(7)
                                    Text("30 days").tag(30)
                                    Text("90 days").tag(90)
                                    Text("1 year").tag(365)
                                }
                                .pickerStyle(.menu)
                                .fixedSize()
                            }
                        }
                        switch selection {
                        case .vitals: VitalsTrends(days: days)
                        case .sleep: SleepTrends(days: days)
                        case .activity: ActivityTrends(days: days)
                        case .body: BodyTrends(days: days)
                        case .cycle: CycleTrends()
                        }
                    }
                    .padding(16)
                }
                .refreshable { await dashboard.load() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.page)
    }

    private var subtitle: String {
        switch selection {
        case .vitals: "Overnight readings from WHOOP and Apple Watch."
        case .sleep: "Each night counts on the day you wake up."
        case .activity: "Movement from iPhone and Apple Watch, strain from WHOOP."
        case .body: "Weight and composition from Apple Health."
        case .cycle: "Cycle days and estimates from what you log."
        }
    }
}

/// The sections as a row of chips that scrolls sideways, so more of them would still fit at phone width.
private struct TrendsSectionChips: View {
    @Binding var selection: TrendsSection
    let sections: [TrendsSection]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(sections) { s in
                        let on = s == selection
                        Button { selection = s } label: {
                            Text(s.rawValue)
                                .font(.app(.subheadline, weight: .medium))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .foregroundStyle(on ? Palette.surface : Palette.ink2)
                                .background(on ? Palette.ink : Palette.surface, in: Capsule())
                                .overlay(Capsule().strokeBorder(on ? Color.clear : Palette.border))
                        }
                        .buttonStyle(.plain)
                        .id(s)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 16)
            }
            // Edge to edge, past the screen padding, so chips scroll under the margins.
            .padding(.horizontal, -16)
            .onAppear { proxy.scrollTo(selection, anchor: .center) }
            .onChange(of: selection) { _, s in withAnimation { proxy.scrollTo(s, anchor: .center) } }
        }
    }
}

/// Loads one set of trend metrics for the chosen range and hands them to `content`.
private struct TrendsLoader<Content: View>: View {
    let metrics: [String]
    let days: Int
    @ViewBuilder let content: (Trends) -> Content
    @Environment(Dashboard.self) private var dashboard
    @State private var trends: Trends?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 14) {
            if let trends {
                content(trends)
            } else if let error {
                Unavailable("Couldn't load trends", systemImage: "chart.line.downtrend.xyaxis", description: error)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            }
        }
        .task(id: "\(days)|\(dashboard.summary?.date ?? "")|\(dashboard.generation)") {
            // A new load clears an old failure, so a retry shows progress rather than the stale message.
            if trends == nil { error = nil }
            do {
                trends = try await dashboard.trends(metrics, days: days)
                error = nil
            } catch is CancellationError {
                // Replaced by a newer load (a refresh landed, or the range changed): not a failure.
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: - Sections

private struct VitalsTrends: View {
    let days: Int
    @Environment(Dashboard.self) private var dashboard
    /// Temperatures from 30 days before the range, for the nightly deviation (its own request).
    @State private var tempHistory: Trends?

    var body: some View {
        // 13 metrics; the server takes at most 20 per request.
        TrendsLoader(metrics: ["resting_hr", "hrv_rmssd", "hrv_sdnn", "spo2", "resp_rate", "wrist_temp", "skin_temp", "body_temp", "recovery",
                               "blood_pressure_systolic", "blood_pressure_diastolic", "glucose", "breathing_disturbances"], days: days) { t in
            let has = { (m: String) in !(t[m]?.isEmpty ?? true) }
            let units = dashboard.units
            let temp = { (c: Double) in units.temp(c).text(1) }
            if has("recovery") { TrendCard(title: "Recovery", points: t["recovery"]!, format: { "\(Fmt.number($0))%" }, color: Palette.series3) }
            TrendCard(title: "Resting heart rate", points: t["resting_hr"] ?? [], format: { "\(Fmt.number($0)) bpm" }, color: Palette.series2)
            if has("hrv_rmssd") || !has("hrv_sdnn") {
                TrendCard(title: "HRV (RMSSD)", points: t["hrv_rmssd"] ?? [], format: { "\(Fmt.number($0)) ms" }, note: "WHOOP, during sleep")
            }
            if has("hrv_sdnn") { TrendCard(title: "HRV (SDNN)", points: t["hrv_sdnn"]!, format: { "\(Fmt.number($0)) ms" }, note: "Apple Watch") }
            TrendCard(title: "Blood oxygen", points: t["spo2"] ?? [], format: { "\(Fmt.number($0, 1))%" }, color: Palette.series2)
            TrendCard(title: "Respiratory rate", points: t["resp_rate"] ?? [], format: { "\(Fmt.number($0, 1)) rpm" })
            if let tempHistory { TempDeviationCard(trends: tempHistory, days: days, end: dashboard.summary?.today ?? Day.today(), units: units) }
            if has("body_temp") { TrendCard(title: "Body temperature", points: t["body_temp"]!, format: temp) }
            if has("wrist_temp") { TrendCard(title: "Wrist temperature", points: t["wrist_temp"]!, format: temp, note: "Apple Watch, during sleep") }
            if has("skin_temp") { TrendCard(title: "Skin temperature", points: t["skin_temp"]!, format: temp, note: "WHOOP") }
            BloodPressureCard(systolic: t["blood_pressure_systolic"] ?? [], diastolic: t["blood_pressure_diastolic"] ?? [])
            GlucoseCard(points: t["glucose"] ?? [])
            BreathingDisturbancesCard(points: t["breathing_disturbances"] ?? [])
        }
        .task(id: "\(days)|\(dashboard.generation)") {
            tempHistory = try? await dashboard.trends(TempDeviationCard.metrics, days: days + 30)
        }
    }
}

private struct SleepTrends: View {
    let days: Int
    @Environment(Dashboard.self) private var dashboard
    /// Bed and wake times (GET /api/sleep); stays nil on servers without it, which hides the card.
    @State private var timing: SleepTiming?

    static let stages: [(key: String, label: String, color: Color)] = [
        ("sleep_deep", "Deep", Palette.stageDeep),
        ("sleep_light", "Light / core", Palette.stageLight),
        ("sleep_rem", "REM", Palette.stageRem),
        ("sleep_awake", "Awake", Palette.stageAwake),
    ]

    var body: some View {
        TrendsLoader(metrics: ["sleep_hours", "sleep_deep", "sleep_light", "sleep_rem", "sleep_awake", "sleep_performance", "sleep_efficiency"], days: days) { t in
            let hours = t["sleep_hours"] ?? []
            // The web Sleep overview's cards hidden in Profile → Cards (shared/cards.ts) are left out here too.
            let hidden = dashboard.cardsOff
            let performance = t["sleep_performance"] ?? []
            // Sleep performance is WHOOP's alone: without any, its card has nothing to show, so it doesn't count below.
            let cards = Cards.ids(in: .trends(.sleep)).filter { $0 != "sleep.score" || !performance.isEmpty }
            if !hidden.contains("sleep.stages") { StagesCard(trends: t, days: days, average: hours.average) }
            if let timing { SleepConsistencyCard(timing: timing) }
            if !hidden.contains("sleep.total") { TrendCard(title: "Time asleep", points: hours, format: Fmt.hoursMinutes) }
            // Each its own card, as on the web: hiding one leaves the other.
            if !hidden.contains("sleep.score"), !performance.isEmpty {
                TrendCard(title: "Sleep performance", points: performance, format: { "\(Fmt.number($0))%" }, note: "WHOOP: sleep vs sleep needed", color: Palette.series3)
            }
            if !hidden.contains("sleep.efficiency") {
                TrendCard(title: "Sleep efficiency", points: t["sleep_efficiency"] ?? [], format: { "\(Fmt.number($0))%" }, note: "time asleep ÷ time in bed", color: Palette.series3)
            }
            if Cards.allHidden(cards, hidden: hidden) {
                AllCardsHiddenNote(text: timing == nil ? "All the cards on this page are hidden." : "Your stages, total sleep, performance and efficiency cards are hidden.")
            }
        }
        .task(id: "\(days)|\(dashboard.generation)") {
            timing = try? await dashboard.sleepTiming(days: min(max(days, 7), 365))
        }
    }

    private struct StagesCard: View {
        let trends: Trends
        let days: Int
        let average: Double?

        struct Bar: Identifiable {
            let date: String
            let stage: String
            let hours: Double
            var id: String { date + stage }
        }

        var body: some View {
            let bars = SleepTrends.stages.flatMap { s in (trends[s.key] ?? []).weekly(days: days).map { Bar(date: $0.date, stage: s.label, hours: $0.value) } }
            VStack(alignment: .leading, spacing: 10) {
                Text(days > 90 ? "Sleep stages, weekly average" : "Sleep stages").font(.app(.subheadline, weight: .medium)).foregroundStyle(Palette.ink2)
                Text(average.map(Fmt.hoursMinutes) ?? "—").font(.app(.title2, weight: .semibold)).monospacedDigit()
                Text("average time asleep").font(.app(.caption)).foregroundStyle(Palette.ink3)
                if bars.isEmpty {
                    Text("No sleep stages in this range.").font(.app(.footnote)).foregroundStyle(Palette.ink3)
                } else {
                    Chart(bars) { b in
                        BarMark(x: .value("Night", Fmt.chartDate(b.date), unit: days > 90 ? .weekOfYear : .day), y: .value("Hours", b.hours))
                            .foregroundStyle(by: .value("Stage", b.stage))
                    }
                    .chartForegroundStyleScale(domain: SleepTrends.stages.map(\.label), range: SleepTrends.stages.map(\.color))
                    .chartLegend(position: .bottom, alignment: .leading) { ChartLegend(SleepTrends.stages.map { ($0.label, $0.color) }) }
                    .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { v in
                        AxisGridLine().foregroundStyle(Palette.grid)
                        AxisValueLabel { if let h = v.as(Double.self) { Text("\(Fmt.number(h))h") } }.font(.app(.caption2))
                    } }
                    .chartXAxis { dateAxis() }
                    .frame(height: 200)
                }
            }
            .card()
        }
    }
}

private struct ActivityTrends: View {
    let days: Int
    @Environment(Dashboard.self) private var dashboard
    /// Strain and active energy over a fixed 16 weeks for the weekly load, whatever the range (its own request).
    @State private var load: Trends?

    var body: some View {
        TrendsLoader(metrics: ["steps", "strain", "active_energy", "exercise_min",
                               "walking_speed", "walking_steadiness", "walking_asymmetry", "flights", "stand_hours", "daylight_min"], days: days) { t in
            StepsCard(points: t["steps"] ?? [], days: days, goal: dashboard.stepGoal)
            if let load { WeeklyLoadCard(strain: load["strain"] ?? [], energy: load["active_energy"] ?? [], today: dashboard.summary?.today ?? Day.today()) }
            if !(t["strain"]?.isEmpty ?? true) {
                TrendCard(title: "Day strain", points: t["strain"]!, format: { Fmt.number($0, 1) }, note: "WHOOP, 0–21", color: Palette.series2, zero: true)
            }
            TrendCard(title: "Active energy", points: t["active_energy"] ?? [], format: { "\(Fmt.number($0)) kcal" }, color: Palette.series2, zero: true)
            if !(t["exercise_min"]?.isEmpty ?? true) {
                TrendCard(title: "Exercise minutes", points: t["exercise_min"]!, format: { "\(Fmt.number($0)) min" }, color: Palette.series3, zero: true)
            }
            MobilityCard(speed: t["walking_speed"] ?? [], steadiness: t["walking_steadiness"] ?? [], asymmetry: t["walking_asymmetry"] ?? [], units: dashboard.units)
            FlightsStandCard(flights: t["flights"] ?? [], standHours: t["stand_hours"] ?? [], days: days)
            DaylightCard(points: t["daylight_min"] ?? [], days: days)
            WorkoutsCard(days: days)
        }
        .task(id: dashboard.generation) {
            load = try? await dashboard.trends(["strain", "active_energy"], days: WeeklyLoadCard.days)
        }
    }

    private struct StepsCard: View {
        let points: [Point]
        let days: Int
        let goal: Double

        var body: some View {
            let bars = points.weekly(days: days)
            VStack(alignment: .leading, spacing: 10) {
                Text(days > 90 ? "Steps, weekly daily average" : "Steps").font(.app(.subheadline, weight: .medium)).foregroundStyle(Palette.ink2)
                Text(points.average.map { "\(Fmt.number($0)) / day" } ?? "—").font(.app(.title2, weight: .semibold)).monospacedDigit()
                Text("goal \(Fmt.number(goal))").font(.app(.caption)).foregroundStyle(Palette.ink3)
                if !bars.isEmpty {
                    Chart {
                        ForEach(bars) { p in
                            BarMark(x: .value("Day", Fmt.chartDate(p.date), unit: days > 90 ? .weekOfYear : .day), y: .value("Steps", p.value))
                                .foregroundStyle(p.value >= goal ? Palette.series1 : Palette.bar)
                        }
                        RuleMark(y: .value("Goal", goal))
                            .foregroundStyle(Palette.good)
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                            .annotation(position: .top, alignment: .trailing) {
                                Text("Goal \(Fmt.compact(goal))").font(.app(.caption2)).foregroundStyle(Palette.goodText)
                            }
                    }
                    .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { v in
                        AxisGridLine().foregroundStyle(Palette.grid)
                        AxisValueLabel { if let n = v.as(Double.self) { Text(Fmt.compact(n)) } }.font(.app(.caption2))
                    } }
                    .chartXAxis { dateAxis() }
                    .frame(height: 200)
                }
            }
            .card()
        }
    }
}

private struct WorkoutsCard: View {
    let days: Int
    @Environment(Dashboard.self) private var dashboard
    @State private var workouts: [Workout]?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Workouts").font(.app(.headline)).foregroundStyle(Palette.ink)
                Spacer()
                if let workouts { Text("\(workouts.count) in this range").font(.app(.caption)).foregroundStyle(Palette.ink3) }
            }
            if let workouts {
                if workouts.isEmpty { Text("No workouts in this range.").font(.app(.footnote)).foregroundStyle(Palette.ink3) }
                ForEach(workouts.prefix(60)) { w in
                    WorkoutListRow(workout: w, units: dashboard.units)
                    if w.id != workouts.prefix(60).last?.id { Divider().overlay(Palette.border) }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .card()
        .task(id: "\(days)|\(dashboard.generation)") { workouts = (try? await dashboard.workouts(days: days)) ?? [] }
    }
}

private struct WorkoutListRow: View {
    let workout: Workout
    let units: Units

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: Self.symbol(workout.sport))
                .font(.body.weight(.semibold))
                .foregroundStyle(Palette.series2)
                .frame(width: 38, height: 38)
                .background(Tone.peach.background, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(workout.sport).font(.app(.subheadline, weight: .medium)).foregroundStyle(Palette.ink)
                    Spacer()
                    Text(Fmt.day(workout.date, "EEEMMMd")).font(.app(.caption)).foregroundStyle(Palette.ink3)
                }
                Text(details).font(.app(.caption)).foregroundStyle(Palette.ink2).monospacedDigit()
                Text(source).font(.app(.caption2)).foregroundStyle(Palette.ink3)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var details: String {
        var parts = [Fmt.duration(minutes: workout.durationMin)]
        if let e = workout.energyKcal, e > 0 { parts.append("\(Fmt.number(e)) kcal") }
        if let d = workout.distanceM, d > 0 { parts.append(units.distance(d).text(2)) }
        if let hr = workout.avgHr { parts.append("\(Fmt.number(hr)) bpm avg") }
        if let s = workout.strain { parts.append("strain \(Fmt.number(s, 1))") }
        return parts.joined(separator: " · ")
    }

    private var source: String {
        switch workout.source {
        case "apple": "Apple Health"
        case "whoop": "WHOOP"
        case "demo": "Demo"
        default: workout.source
        }
    }

    static func symbol(_ sport: String) -> String {
        let s = sport.lowercased()
        if s.contains("run") { return "figure.run" }
        if s.contains("walk") { return "figure.walk" }
        if s.contains("hik") { return "figure.hiking" }
        if s.contains("cycl") || s.contains("bik") { return "figure.outdoor.cycle" }
        if s.contains("swim") { return "figure.pool.swim" }
        if s.contains("yoga") { return "figure.yoga" }
        if s.contains("pilates") { return "figure.pilates" }
        if s.contains("row") { return "figure.rower" }
        if s.contains("strength") || s.contains("weight") { return "figure.strengthtraining.traditional" }
        if s.contains("interval") || s.contains("hiit") { return "figure.highintensity.intervaltraining" }
        if s.contains("tennis") || s.contains("pickleball") { return "figure.tennis" }
        if s.contains("soccer") { return "figure.indoor.soccer" }
        if s.contains("basketball") { return "figure.basketball" }
        if s.contains("dance") { return "figure.dance" }
        if s.contains("mind") || s.contains("medit") || s.contains("breath") { return "figure.mind.and.body" }
        return "figure.mixed.cardio"
    }
}

private struct BodyTrends: View {
    let days: Int
    @Environment(Dashboard.self) private var dashboard
    /// VO₂ max over a year when the range is shorter: it moves over months, not weeks.
    @State private var vo2Year: [Point]?

    var body: some View {
        TrendsLoader(metrics: ["weight", "body_fat", "lean_mass", "vo2max", "caffeine_mg", "water_ml"], days: days) { t in
            let units = dashboard.units
            let weight = t["weight"] ?? [], fat = t["body_fat"] ?? [], lean = t["lean_mass"] ?? []
            let vo2Long = days < 365 ? vo2Year : nil
            TrendCard(title: "Weight", points: weight, format: { units.mass($0).text(1) }, smoothed: weight.rolling(days: 7))
            TrendCard(title: "Body fat", points: fat, format: { "\(Fmt.number($0, 1))%" }, color: Palette.series2, smoothed: fat.rolling(days: 7))
            TrendCard(title: "Cardio fitness (VO₂ max)", points: vo2Long ?? t["vo2max"] ?? [], format: { Fmt.number($0, 1) },
                      note: vo2Long == nil ? "mL/kg·min" : "mL/kg·min · last 12 months, since it changes slowly", color: Palette.series3)
            if !lean.isEmpty { TrendCard(title: "Lean body mass", points: lean, format: { units.mass($0).text(1) }, smoothed: lean.rolling(days: 7)) }
            CaffeineCard(points: t["caffeine_mg"] ?? [], days: days)
            WaterCard(points: t["water_ml"] ?? [], days: days, units: units)
        }
        .task(id: "\(days)|\(dashboard.generation)") {
            guard days < 365 else { return }
            vo2Year = try? await dashboard.trends(["vo2max"], days: 365)["vo2max"]
        }
    }
}

// MARK: - Trend card

/// One metric over the range: latest value, average, and a line you can scrub.
struct TrendCard: View {
    let title: String
    let points: [Point]
    let format: (Double) -> String
    var note: String?
    var color: Color = Palette.series1
    var zero = false
    /// Drawn as the line instead, with each reading a faint dot (weight and body composition: a 7-day rolling mean).
    var smoothed: [Point]? = nil
    @State private var selected: Date?

    var body: some View {
        let last = points.last
        let avg = points.average
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.app(.subheadline, weight: .medium)).foregroundStyle(Palette.ink2)
            Text(last.map { format($0.value) } ?? "—").font(.app(.title2, weight: .semibold)).foregroundStyle(Palette.ink).monospacedDigit()
            Text(noteText(last: last, avg: avg)).font(.app(.caption)).foregroundStyle(Palette.ink3)
            if !points.isEmpty { chart.frame(height: 150).padding(.top, 6) }
        }
        .card()
    }

    private func noteText(last: Point?, avg: Double?) -> String {
        guard let last else { return "No data in this range" }
        var s = Fmt.day(last.date)
        if let avg { s += " · average \(format(avg))" }
        if let note { s += " · \(note)" }
        if smoothed != nil { s += " · line: 7-day average" }
        return s
    }

    private var chart: some View {
        let values = points.map(\.value)
        let lo = values.min() ?? 0, hi = values.max() ?? 1
        let pad = Swift.max((hi - lo) * 0.15, 0.5)
        let domain = zero ? 0...(hi + pad) : (lo - pad)...(hi + pad)
        let picked = selected.flatMap { s in points.min { abs(Fmt.chartDate($0.date).timeIntervalSince(s)) < abs(Fmt.chartDate($1.date).timeIntervalSince(s)) } }
        return Chart {
            ForEach(points) { p in
                if smoothed == nil {
                    AreaMark(x: .value("Day", Fmt.chartDate(p.date)), yStart: .value("Base", domain.lowerBound), yEnd: .value(title, p.value))
                        .foregroundStyle(LinearGradient(colors: [color.opacity(0.22), color.opacity(0)], startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Day", Fmt.chartDate(p.date)), y: .value(title, p.value))
                        .foregroundStyle(color)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                        .interpolationMethod(.monotone)
                } else {
                    PointMark(x: .value("Day", Fmt.chartDate(p.date)), y: .value(title, p.value))
                        .foregroundStyle(color.opacity(0.4))
                        .symbolSize(18)
                }
            }
            if let smoothed {
                ForEach(smoothed) { p in
                    LineMark(x: .value("Day", Fmt.chartDate(p.date)), y: .value("7-day average", p.value))
                        .foregroundStyle(color)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                        .interpolationMethod(.monotone)
                        .accessibilityLabel("7-day average, \(Fmt.day(p.date))")
                        .accessibilityValue(format(p.value))
                }
            }
            if let picked {
                RuleMark(x: .value("Day", Fmt.chartDate(picked.date)))
                    .foregroundStyle(Palette.ink3.opacity(0.5))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        VStack(spacing: 1) {
                            Text(format(picked.value)).font(.app(.caption, weight: .semibold))
                            Text(Fmt.day(picked.date)).font(.app(.caption2))
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Palette.surface2, in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(Palette.ink)
                    }
                PointMark(x: .value("Day", Fmt.chartDate(picked.date)), y: .value(title, picked.value)).foregroundStyle(color)
            }
        }
        .chartYScale(domain: domain)
        .chartXSelection(value: $selected)
        .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
            AxisGridLine().foregroundStyle(Palette.grid)
            AxisValueLabel().font(.app(.caption2)).foregroundStyle(Palette.ink3)
        } }
        .chartXAxis { dateAxis() }
        .accessibilityLabel(smoothed == nil ? "\(title) trend" : "\(title) trend, each reading with a 7-day average line")
    }
}

private func dateAxis() -> some AxisContent {
    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
        AxisValueLabel(format: .dateTime.month(.abbreviated).day()).font(.app(.caption2)).foregroundStyle(Palette.ink3)
    }
}
