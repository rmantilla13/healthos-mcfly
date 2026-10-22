import Charts
import SwiftUI

// The Nutrition section of Trends (src/pages/Nutrition.tsx): what a person logs in a food app, read through Apple
// Health, laid out like the web's Neka page (tabs, four cards, macro balance and insights). Only while Nutrition is
// on. The server has already removed every number the person chose not to see; this screen hides them again and adds
// no judgement of its own: no score, no "remaining" or "on track", nothing over or under, no red or green. A target
// is one the person set, drawn as a plain dashed line. A day with nothing logged is a gap, never a zero.

enum NutritionTab: String, CaseIterable, Identifiable {
    case overview = "Overview", log = "Log", macros = "Macros", hydration = "Hydration"
    var id: String { rawValue }

    /// With no amounts, there's nothing for Macros and Hydration to show, but food can still be logged. Log only where
    /// the server has the food log.
    static func visible(_ mode: NutritionMode, logging: Bool = true) -> [NutritionTab] {
        (mode == .none ? [.overview, .log] : allCases).filter { $0 != .log || logging }
    }
}

/// The arithmetic behind the cards, apart from the views so tests can check it. Every date comes from the reply's own
/// `end` and `today`, never the phone's clock, so a phone in another time zone shows the same week as the web.
enum FoodMath {
    struct DayValue: Identifiable, Equatable {
        let date: String
        /// nil: nothing logged that day (a gap, not a zero).
        let value: Double?
        var id: String { date }
    }

    struct Part: Identifiable {
        let key: String
        let label: String
        let grams: Double
        let percent: Int
        var id: String { key }
    }

    static let names: [String: (name: String, unit: String)] = [
        "energy_kcal": ("Energy", "kcal"), "protein_g": ("Protein", "g"), "carbs_g": ("Carbs", "g"), "fat_g": ("Fat", "g"),
        "fiber_g": ("Fiber", "g"), "sugar_g": ("Sugar", "g"), "sat_fat_g": ("Saturated fat", "g"), "sodium_mg": ("Sodium", "mg"),
        "alcohol_drinks": ("Alcoholic drinks", "drinks"),
    ]
    /// The order nutrients are shown in (NUTRIENTS in server/nutrition.ts).
    static let order = ["energy_kcal", "protein_g", "carbs_g", "fat_g", "fiber_g", "sugar_g", "sat_fat_g", "sodium_mg", "alcohol_drinks"]
    /// The three that make up most of a day's food, shown as one split of grams.
    static let macros = ["protein_g", "carbs_g", "fat_g"]

    static func name(_ nutrient: String) -> String { names[nutrient]?.name ?? nutrient }

    /// "1,150 kcal", "65 g", "1 drink", "2 drinks".
    static func amount(_ nutrient: String, _ value: Double) -> String {
        let unit = nutrient == "alcohol_drinks" ? (value.rounded() == 1 ? "drink" : "drinks") : names[nutrient]?.unit ?? ""
        return "\(Fmt.number(value)) \(unit)"
    }

    /// `count` calendar days ending at `end`, oldest first.
    static func dates(to end: String, count: Int) -> [String] {
        (0..<count).map { Day.add(end, $0 - count + 1) }
    }

    /// Every day from `start` to `end`.
    static func dates(from start: String, to end: String) -> [String] {
        dates(to: end, count: max(0, Fmt.daysBetween(start, end) + 1))
    }

    static func series(_ nutrient: String, _ dates: [String], _ days: [FoodDay]) -> [DayValue] {
        let byDate = Dictionary(days.map { ($0.date, $0) }, uniquingKeysWith: { $1 })
        return dates.map { DayValue(date: $0, value: byDate[$0]?.values[nutrient]) }
    }

    static func series(_ points: [Point], _ dates: [String]) -> [DayValue] {
        let byDate = Dictionary(points.map { ($0.date, $0.value) }, uniquingKeysWith: { $1 })
        return dates.map { DayValue(date: $0, value: byDate[$0]) }
    }

    /// The latest day with something logged.
    static func last(_ days: [DayValue]) -> (date: String, value: Double)? {
        days.last { $0.value != nil }.map { ($0.date, $0.value!) }
    }

    /// The average of the logged days in `week` less that of `before`. Logged days only, at least three on each side:
    /// a week of gaps isn't a week of eating less.
    static func change(_ week: [DayValue], _ before: [DayValue]) -> Double? {
        let now = week.compactMap(\.value), then = before.compactMap(\.value)
        guard now.count >= 3, then.count >= 3 else { return nil }
        return now.reduce(0, +) / Double(now.count) - then.reduce(0, +) / Double(then.count)
    }

    /// A neutral line about the change: no colour, no better or worse.
    static func changeText(_ delta: Double, unit: String = "g") -> String {
        abs(delta) < 1 ? "About the same as the week before" : "\(delta > 0 ? "+" : "−")\(Fmt.number(abs(delta))) \(unit) a day vs the week before"
    }

    /// Glasses of 250 mL, to the nearest half.
    static func glasses(_ ml: Double) -> Double { (ml / 250 * 2).rounded() / 2 }

    static func glassesText(_ ml: Double) -> String {
        let g = glasses(ml)
        return Fmt.number(g, g.truncatingRemainder(dividingBy: 1) == 0 ? 0 : 1)
    }

    /// "750 mL", "1.8 L", or fl oz in imperial.
    static func water(_ ml: Double, units: Units) -> String {
        if units == .imperial { return "\(Fmt.number(ml / 29.5735)) fl oz" }
        return ml >= 1000 ? "\(Fmt.number(ml / 1000, 1)) L" : "\(Fmt.number(ml)) mL"
    }

    static func glassSize(_ units: Units) -> String { units == .imperial ? "8.5 fl oz" : "250 mL" }

    /// Protein, carbs and fat by weight, with each one's share (as the web rounds it).
    static func parts(_ day: FoodDay) -> [Part] {
        let present = macros.compactMap { key in day.values[key].map { (key, $0) } }
        let total = present.reduce(0) { $0 + $1.1 }
        guard total > 0 else { return [] }
        return present.map { Part(key: $0.0, label: name($0.0), grams: $0.1, percent: Int(($0.1 / total * 100).rounded())) }
    }

    /// "1 day", "12 days".
    static func days(_ n: Int) -> String { "\(n) \(n == 1 ? "day" : "days")" }
}

// MARK: - The section

/// The Nutrition tab while it's on: tabs, then the tab's cards. Overview reads the last 14 days; Macros and Hydration a
/// range; Log is its own List (swipe to delete needs one), so each tab holds its own scrolling.
struct NutritionTrends: View {
    @Environment(Dashboard.self) private var dashboard
    @AppStorage("nutritionTab") private var tab = NutritionTab.overview.rawValue
    @AppStorage("nutritionDays") private var days = 30

    var body: some View {
        let tabs = NutritionTab.visible(dashboard.nutritionMode ?? .none, logging: dashboard.foodLogAvailable == true)
        let current = tabs.first { $0.rawValue == tab } ?? .overview
        Group {
            if current == .log {
                FoodLogTab { header(tabs) }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        header(tabs)
                        if current != .overview {
                            HStack {
                                Spacer()
                                Picker("Range", selection: $days) {
                                    Text("7 days").tag(7)
                                    Text("30 days").tag(30)
                                    Text("90 days").tag(90)
                                }
                                .pickerStyle(.menu)
                            }
                        }
                        switch current {
                        case .overview, .log: NutritionLoader(days: 14, insights: true) { NutritionOverview(data: $0, units: dashboard.units) }
                        case .macros: NutritionLoader(days: days, insights: false) { NutritionMacros(data: $0) }
                        case .hydration: NutritionLoader(days: days, insights: false) { NutritionHydration(data: $0, units: dashboard.units) }
                        }
                    }
                    .padding(16)
                }
                .refreshable { await dashboard.load() }
            }
        }
        // Whether this server has the food log decides the Log tab; Health catches up with the log on opening.
        .task(id: "\(dashboard.generation)|\(dashboard.nutritionOn)") {
            await dashboard.probeFoodLog()
            await dashboard.reconcileFoodHealth()
        }
    }

    private func header(_ tabs: [NutritionTab]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("From the food app you log in, through Apple Health, or logged here. Only you can see it.")
                .font(.footnote).foregroundStyle(Palette.ink3)
            if tabs.count > 1 {
                Picker("Nutrition", selection: $tab) {
                    ForEach(tabs) { Text($0.rawValue).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("nutritionTabs")
            }
        }
    }
}

/// Reads GET /api/nutrition for its content, and says why when it can't.
private struct NutritionLoader<Content: View>: View {
    let days: Int
    let insights: Bool
    @ViewBuilder let content: (NutritionData) -> Content
    @Environment(Dashboard.self) private var dashboard
    @State private var data: NutritionData?
    @State private var loaded = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 14) {
            if let data {
                content(data)
            } else if let error {
                ContentUnavailableView("Couldn't load your nutrition", systemImage: "fork.knife", description: Text(error))
            } else if loaded {
                Text("Nutrition isn't available from this server yet.")
                    .font(.footnote).foregroundStyle(Palette.ink3)
                    .card()
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            }
        }
        .task(id: "\(dashboard.generation)|\(dashboard.nutritionMode?.rawValue ?? "off")|\(days)|\(insights)") {
            do {
                data = try await dashboard.nutrition(days: days, insights: insights)
                error = nil
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
            loaded = true
        }
    }
}

// MARK: - Overview

private struct NutritionOverview: View {
    let data: NutritionData
    let units: Units
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        let week = FoodMath.dates(to: data.end, count: 7)
        let latest = data.days.last
        // Cards hidden in Settings → Cards (shared/cards.ts) are left out, and the rest close up.
        let layout = Cards.nutritionOverview(mode: data.mode, hidden: dashboard.hiddenCardSet)
        if latest == nil && data.water.isEmpty {
            FoodNothingLoggedCard()
        } else if data.mode == .none {
            if layout.row.contains("nutrition.logged") { FoodLoggedCard(data: data) }
            FoodNoAmountsCard(latest: latest, today: data.today, logging: dashboard.foodLogAvailable == true)
        } else if layout.allHidden {
            AllCardsHiddenNote(text: "All the cards on this page are hidden.")
        } else {
            FoodOverviewCards(data: data, week: week, units: units, ids: layout.row)
            if layout.pair.contains("nutrition.macros") {
                if let latest {
                    MacroBalanceCard(day: latest, today: data.today, mode: data.mode, caffeine: data.caffeine.first { $0.date == latest.date }?.value)
                } else {
                    FoodNothingLoggedCard()
                }
            }
            if layout.pair.contains("nutrition.insights") { FoodInsightsCard(insights: data.insights) }
        }
    }
}

/// Energy (only when everything is shown), protein, water and days logged: two to a row, without the hidden ones.
/// An odd last card takes the whole row, so hiding one leaves no hole.
private struct FoodOverviewCards: View {
    let data: NutritionData
    let week: [String]
    let units: Units
    let ids: [String]

    var body: some View {
        Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            ForEach(Array(Cards.rows(ids, max: 2).enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(row, id: \.self) { id in
                        card(id, wide: row.count == 1).gridCellColumns(row.count == 1 ? 2 : 1)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func card(_ id: String, wide: Bool) -> some View {
        switch id {
        case "nutrition.energy":
            FoodEnergyCard(week: FoodMath.series("energy_kcal", week, data.days), target: data.targets?["energy_kcal"], today: data.today)
        case "nutrition.protein":
            let before = FoodMath.dates(to: Day.add(data.end, -7), count: 7)
            FoodProteinCard(week: FoodMath.series("protein_g", week, data.days), before: FoodMath.series("protein_g", before, data.days),
                            target: data.targets?["protein_g"], today: data.today)
        case "nutrition.water":
            FoodWaterCard(week: FoodMath.series(data.water, week), target: data.targets?["water_ml"], today: data.today, units: units)
        case "nutrition.logged":
            FoodLoggedCard(data: data, compact: !wide)
        default:
            EmptyView()
        }
    }
}

private struct FoodCardHead: View {
    let title: String
    let day: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.subheadline.weight(.medium)).foregroundStyle(Palette.ink2)
            Spacer(minLength: 4)
            if let day { Text(day).font(.caption).foregroundStyle(Palette.ink3).lineLimit(1) }
        }
    }
}

/// The bottom line of a small card: what it covers, and the person's own target when they set one.
private struct FoodCardFoot: View {
    let text: String
    let target: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(text)
            if let target { Text("Your target \(target)") }
        }
        .font(.caption2).foregroundStyle(Palette.ink3)
    }
}

private struct FoodEnergyCard: View {
    let week: [FoodMath.DayValue]
    let target: Double?
    let today: String

    var body: some View {
        let last = FoodMath.last(week)
        VStack(alignment: .leading, spacing: 8) {
            FoodCardHead(title: "Energy", day: last.map { Fmt.relativeDay($0.date, today: today) })
            if let last {
                BigValue(value: Fmt.number(last.value), unit: "kcal", size: 26)
            } else {
                Text("No calories logged this week.").font(.caption).foregroundStyle(Palette.ink3)
            }
            Spacer(minLength: 0)
            FoodDayBars(days: week, target: target, label: "Energy, last 7 days") { "\(Fmt.number($0)) kcal" }
            FoodCardFoot(text: "Last 7 days", target: target.map { "\(Fmt.number($0)) kcal" })
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .card(.peach)
    }
}

private struct FoodProteinCard: View {
    let week: [FoodMath.DayValue]
    let before: [FoodMath.DayValue]
    let target: Double?
    let today: String

    var body: some View {
        let last = FoodMath.last(week)
        VStack(alignment: .leading, spacing: 8) {
            FoodCardHead(title: "Protein", day: last.map { Fmt.relativeDay($0.date, today: today) })
            if let last {
                BigValue(value: Fmt.number(last.value), unit: "grams", size: 26)
            } else {
                Text("No protein logged this week.").font(.caption).foregroundStyle(Palette.ink3)
            }
            if let delta = FoodMath.change(week, before) {
                Text(FoodMath.changeText(delta))
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Palette.surface2, in: Capsule())
                    .foregroundStyle(Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            FoodDayBars(days: week, target: target, label: "Protein, last 7 days") { "\(Fmt.number($0)) g" }
            FoodCardFoot(text: "Last 7 days", target: target.map { "\(Fmt.number($0)) g" })
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .card()
    }
}

private struct FoodWaterCard: View {
    let week: [FoodMath.DayValue]
    let target: Double?
    let today: String
    let units: Units

    var body: some View {
        let last = FoodMath.last(week)
        VStack(alignment: .leading, spacing: 8) {
            FoodCardHead(title: "Water", day: last.map { Fmt.relativeDay($0.date, today: today) })
            if let last {
                BigValue(value: FoodMath.glassesText(last.value), unit: FoodMath.glasses(last.value) == 1 ? "glass" : "glasses", size: 26)
                Text(FoodMath.water(last.value, units: units)).font(.caption).foregroundStyle(Palette.ink3)
            } else {
                Text("No water logged this week.").font(.caption).foregroundStyle(Palette.ink3)
            }
            Spacer(minLength: 0)
            GlassBars(days: week, target: target, label: "Water in glasses, last 7 days") { "\(FoodMath.glassesText($0)) glasses, \(FoodMath.water($0, units: units))" }
            FoodCardFoot(text: "1 glass = \(FoodMath.glassSize(units))", target: target.map { FoodMath.water($0, units: units) })
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .card()
    }
}

/// Every day of the window, filled where something was logged. A plain record, not a streak.
private struct FoodLoggedCard: View {
    let data: NutritionData
    var compact = false

    var body: some View {
        let logged = Set(data.days.map(\.date))
        let dates = FoodMath.dates(from: data.start, to: data.end)
        let cell: CGFloat = dates.count > 31 ? 8 : compact ? 11 : 14
        VStack(alignment: .leading, spacing: 8) {
            FoodCardHead(title: "Days logged", day: nil)
            Text("\(logged.count) of \(FoodMath.days(dates.count))")
                .font(.system(size: compact ? 20 : 22, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(Palette.ink)
            Spacer(minLength: 0)
            FamilyWrap(spacing: 4, rowSpacing: 4) {
                ForEach(dates, id: \.self) { d in
                    RoundedRectangle(cornerRadius: cell > 10 ? 4 : 2, style: .continuous)
                        .fill(logged.contains(d) ? Palette.series1 : Palette.grid)
                        .frame(width: cell, height: cell)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Logged on \(logged.count) of the last \(FoodMath.days(dates.count))")
            HStack {
                Text(Fmt.day(data.start))
                Spacer()
                Text(Fmt.day(data.end))
            }
            .font(.caption2).foregroundStyle(Palette.ink3)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .card()
    }
}

private struct FoodNoAmountsCard: View {
    let latest: FoodDay?
    let today: String
    /// The Log tab is there (a server with the food log), showing what was logged.
    let logging: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(latest.map { Fmt.relativeDay($0.date, today: today) } ?? "Nothing logged lately").font(.headline).foregroundStyle(Palette.ink)
            Text((latest.map { "You logged food \($0.app == "healthOS" ? "here" : "in \($0.app)"). " } ?? "")
                + "You chose to see no amounts, so this shows only the days you logged\(logging ? ", and the Log tab what you logged" : ""). Change it on the web, in Settings.")
                .font(.footnote).foregroundStyle(Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .card()
    }
}

private struct FoodNothingLoggedCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Nothing logged yet").font(.headline).foregroundStyle(Palette.ink)
            Text("healthOS reads what your food app writes to Apple Health: MyFitnessPal, Cronometer, Lose It!, MacroFactor and Yazio all can. Turn on its Apple Health connection in that app, and allow healthOS to read nutrition when Health asks.")
                .font(.footnote).foregroundStyle(Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .card()
    }
}

// MARK: - Macro balance and insights

private enum MacroColor {
    static func of(_ key: String) -> Color {
        switch key {
        case "protein_g": Palette.series1
        case "carbs_g": Palette.series3
        default: Palette.series2
        }
    }
}

/// Protein, carbs and fat by weight for the latest day, the rest of the day's food beneath.
private struct MacroBalanceCard: View {
    let day: FoodDay
    let today: String
    let mode: NutritionMode
    let caffeine: Double?

    var body: some View {
        let parts = FoodMath.parts(day)
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Macro balance").font(.headline).foregroundStyle(Palette.ink)
                Spacer()
                Text("\(Fmt.relativeDay(day.date, today: today)) · \(day.app)").font(.caption).foregroundStyle(Palette.ink3).lineLimit(1)
            }
            if parts.isEmpty {
                Text("No protein, carbs or fat logged that day.").font(.footnote).foregroundStyle(Palette.ink3)
            } else {
                HStack(spacing: 18) {
                    MacroDonut(parts: parts, energy: mode == .all ? day.values["energy_kcal"] : nil)
                        .frame(width: 124, height: 124)
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(parts) { p in
                            HStack(spacing: 8) {
                                Circle().fill(MacroColor.of(p.key)).frame(width: 8, height: 8)
                                Text(p.label).font(.subheadline).foregroundStyle(Palette.ink2)
                                Spacer(minLength: 4)
                                Text("\(Fmt.number(p.grams)) g").font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(Palette.ink)
                                Text("\(p.percent)%").font(.caption).monospacedDigit().foregroundStyle(Palette.ink3).frame(minWidth: 30, alignment: .trailing)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
            MacroFooter(day: day, caffeine: caffeine)
            if !day.otherApps.isEmpty {
                Text("Also logged in \(day.otherApps.joined(separator: ", ")), not added in.").font(.caption).foregroundStyle(Palette.ink3)
            }
        }
        .card()
    }
}

private struct MacroDonut: View {
    let parts: [FoodMath.Part]
    let energy: Double?

    var body: some View {
        ZStack {
            Chart(parts) { p in
                SectorMark(angle: .value(p.label, p.grams), innerRadius: .ratio(0.78), angularInset: 1.5)
                    .foregroundStyle(MacroColor.of(p.key))
                    .cornerRadius(2)
            }
            .chartLegend(.hidden)
            VStack(spacing: 0) {
                if let energy {
                    Text(Fmt.number(energy)).font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(Palette.ink)
                    Text("kcal").font(.caption2).foregroundStyle(Palette.ink3)
                } else {
                    Text("by weight").font(.caption2).foregroundStyle(Palette.ink3)
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("By weight: " + parts.map { "\($0.label.lowercased()) \($0.percent)%" }.joined(separator: ", "))
        .accessibilityValue(energy.map { "\(Fmt.number($0)) kcal" } ?? "")
    }
}

/// Fiber, sugar (total), sodium and that day's caffeine, the ones there are.
private struct MacroFooter: View {
    let day: FoodDay
    let caffeine: Double?

    var body: some View {
        let rows = ["fiber_g", "sugar_g", "sodium_mg"].compactMap { n in
            day.values[n].map { (n == "sugar_g" ? "Sugar (total)" : FoodMath.name(n), FoodMath.amount(n, $0)) }
        } + (caffeine.map { [("Caffeine", "\(Fmt.number($0)) mg")] } ?? [])
        if !rows.isEmpty {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                ForEach(Array(stride(from: 0, to: rows.count, by: 2)), id: \.self) { i in
                    GridRow {
                        FoodFooterCell(label: rows[i].0, value: rows[i].1)
                        if i + 1 < rows.count { FoodFooterCell(label: rows[i + 1].0, value: rows[i + 1].1) } else { Color.clear.gridCellUnsizedAxes([.horizontal, .vertical]) }
                    }
                }
            }
            .padding(.top, 10)
            .overlay(alignment: .top) { Rectangle().fill(Palette.border).frame(height: 1) }
        }
    }
}

private struct FoodFooterCell: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption).foregroundStyle(Palette.ink3)
            Text(value).font(.subheadline.weight(.medium)).monospacedDigit().foregroundStyle(Palette.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct FoodInsightsCard: View {
    let insights: [Pattern]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Insights").font(.headline).foregroundStyle(Palette.ink)
            if insights.isEmpty {
                Text("Patterns show up here once there are a few weeks of logs to compare: caffeine and that night's sleep, and drinks and the next morning's HRV.")
                    .font(.footnote).foregroundStyle(Palette.ink3).fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(insights) { p in
                    let (symbol, tone) = InsightsCard.style(p.icon ?? "")
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: symbol)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(tone.ink)
                            .frame(width: 34, height: 34)
                            .background(tone.background, in: Circle())
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.text).font(.subheadline).foregroundStyle(Palette.ink)
                            Text(((p.detail ?? "") + " Days that go together, not proof that one causes the other.").trimmingCharacters(in: .whitespaces))
                                .font(.caption).foregroundStyle(Palette.ink3)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .card()
    }
}

// MARK: - Macros

private struct NutritionMacros: View {
    let data: NutritionData

    var body: some View {
        if let latest = data.days.last {
            FoodDayCard(day: latest, today: data.today, mode: data.mode)
            FoodLoggedCard(data: data)
            ForEach(FoodMath.order.filter { n in data.days.contains { $0.values[n] != nil } }, id: \.self) { n in
                let target = n == "energy_kcal" || n == "protein_g" ? data.targets?[n] : nil
                FoodChartCard(title: FoodMath.name(n), points: data.days.compactMap { d in d.values[n].map { Point(date: d.date, value: $0) } },
                              start: data.start, end: data.end, target: target, format: { FoodMath.amount(n, $0) })
            }
            Text("Days with nothing logged are left out, not counted as zero. When two apps logged the same day, one is shown and the other isn't added in, because food apps often copy each other's entries through Apple Health.")
                .font(.caption).foregroundStyle(Palette.ink3).fixedSize(horizontal: false, vertical: true)
        } else {
            FoodNothingLoggedCard()
        }
    }
}

/// The latest logged day: each nutrient, and protein, carbs and fat as one split by weight.
private struct FoodDayCard: View {
    let day: FoodDay
    let today: String
    let mode: NutritionMode

    var body: some View {
        let shown = FoodMath.order.filter { day.values[$0] != nil }
        let parts = FoodMath.parts(day)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(Fmt.relativeDay(day.date, today: today)).font(.headline).foregroundStyle(Palette.ink)
                Spacer()
                Text(day.app)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Palette.surface2, in: Capsule())
                    .foregroundStyle(Palette.ink2)
            }
            if mode == .none || shown.isEmpty {
                Text("You logged food in \(([day.app] + day.otherApps).joined(separator: ", ")).").font(.footnote).foregroundStyle(Palette.ink2)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    ForEach(Array(stride(from: 0, to: shown.count, by: 2)), id: \.self) { i in
                        GridRow {
                            FoodFooterCell(label: FoodMath.name(shown[i]), value: FoodMath.amount(shown[i], day.values[shown[i]]!))
                            if i + 1 < shown.count {
                                FoodFooterCell(label: FoodMath.name(shown[i + 1]), value: FoodMath.amount(shown[i + 1], day.values[shown[i + 1]]!))
                            } else {
                                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                            }
                        }
                    }
                }
                if parts.count == 3 { MacroSplit(parts: parts) }
                if !day.otherApps.isEmpty {
                    Text("Also logged in \(day.otherApps.joined(separator: ", ")), not added in.").font(.caption).foregroundStyle(Palette.ink3)
                }
            }
        }
        .card()
    }
}

private struct MacroSplit: View {
    let parts: [FoodMath.Part]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                let total = parts.reduce(0) { $0 + $1.grams }
                HStack(spacing: 2) {
                    ForEach(parts) { p in
                        Capsule().fill(MacroColor.of(p.key)).frame(width: max(2, (geo.size.width - 4) * p.grams / total))
                    }
                }
            }
            .frame(height: 8)
            HStack(spacing: 10) {
                ForEach(parts) { p in
                    HStack(spacing: 4) {
                        Circle().fill(MacroColor.of(p.key)).frame(width: 7, height: 7)
                        Text("\(p.label) \(p.percent)%")
                    }
                }
                Text("by weight").foregroundStyle(Palette.ink3)
            }
            .font(.caption).foregroundStyle(Palette.ink2)
        }
        .accessibilityElement()
        .accessibilityLabel("By weight: " + parts.map { "\($0.label.lowercased()) \($0.percent)%" }.joined(separator: ", "))
    }
}

// MARK: - Hydration

private struct NutritionHydration: View {
    let data: NutritionData
    let units: Units

    var body: some View {
        if data.water.isEmpty && data.caffeine.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("No water or caffeine logged").font(.headline).foregroundStyle(Palette.ink)
                Text("Apps that log drinks, like WaterMinder or your food app, write water and caffeine to Apple Health, and they show up here.")
                    .font(.footnote).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true)
            }
            .card()
        } else {
            FoodChartCard(title: "Water", points: data.water, start: data.start, end: data.end, target: data.targets?["water_ml"],
                          note: "1 glass = \(FoodMath.glassSize(units))", format: { FoodMath.water($0, units: units) },
                          axis: { units == .imperial ? Fmt.number($0 / 29.5735) : Fmt.number($0) })
            FoodChartCard(title: "Caffeine", points: data.caffeine, start: data.start, end: data.end, target: nil,
                          note: "daily total", format: { "\(Fmt.number($0)) mg" })
        }
    }
}

// MARK: - Charts

/// One bar per logged day across the whole window (days with nothing logged stay empty, never zero), the median as a
/// faint line, and the person's own target as a plain dashed one. Every bar is one colour.
private struct FoodChartCard: View {
    let title: String
    let points: [Point]
    let start: String
    let end: String
    let target: Double?
    var note: String?
    let format: (Double) -> String
    var axis: (Double) -> String = { Fmt.compact($0) }
    @State private var selected: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.medium)).foregroundStyle(Palette.ink2)
            Text(([FoodMath.days(points.count) + " logged", "median line"] + [note].compactMap { $0 }).joined(separator: " · "))
                .font(.caption).foregroundStyle(Palette.ink3)
            if !points.isEmpty { chart.frame(height: 180).padding(.top, 6) }
        }
        .card()
    }

    private var median: Double? {
        let v = points.map(\.value).sorted()
        guard !v.isEmpty else { return nil }
        return v.count % 2 == 1 ? v[v.count / 2] : (v[v.count / 2 - 1] + v[v.count / 2]) / 2
    }

    private var chart: some View {
        let from = Fmt.chartDate(start).addingTimeInterval(-12 * 3600)
        let to = Fmt.chartDate(end).addingTimeInterval(12 * 3600)
        let picked = selected.flatMap { s in points.min { abs(Fmt.chartDate($0.date).timeIntervalSince(s)) < abs(Fmt.chartDate($1.date).timeIntervalSince(s)) } }
        return Chart {
            ForEach(points) { p in
                BarMark(x: .value("Day", Fmt.chartDate(p.date), unit: .day), y: .value(title, p.value))
                    .foregroundStyle(p.id == picked?.id || (picked == nil && p.id == points.last?.id) ? Palette.series1 : Palette.bar)
                    .cornerRadius(2)
                    .accessibilityLabel(Fmt.day(p.date))
                    .accessibilityValue(format(p.value))
            }
            if let median {
                RuleMark(y: .value("Median", median))
                    .foregroundStyle(Palette.ink3.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 0.75))
            }
            if let target {
                RuleMark(y: .value("Your target", target))
                    .foregroundStyle(Palette.ink2)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .annotation(position: .top, alignment: .trailing) {
                        Text("Your target").font(.caption2).foregroundStyle(Palette.ink2)
                            .padding(.horizontal, 4)
                            .background(Palette.surface.opacity(0.9), in: RoundedRectangle(cornerRadius: 4))
                    }
            }
            if let picked {
                RuleMark(x: .value("Day", Fmt.chartDate(picked.date), unit: .day))
                    .foregroundStyle(Palette.ink3.opacity(0.3))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        VStack(spacing: 1) {
                            Text(format(picked.value)).font(.caption.weight(.semibold))
                            Text(Fmt.day(picked.date)).font(.caption2)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Palette.surface2, in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(Palette.ink)
                    }
            }
        }
        .chartXScale(domain: from...to)
        .chartXSelection(value: $selected)
        .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { v in
            AxisGridLine().foregroundStyle(Palette.grid)
            AxisValueLabel { if let n = v.as(Double.self) { Text(axis(n)) } }.foregroundStyle(Palette.ink3)
        } }
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in
            AxisValueLabel(format: .dateTime.month(.abbreviated).day()).foregroundStyle(Palette.ink3)
        } }
        .accessibilityLabel("\(title) by day")
    }
}

/// A run of calendar days as small bars: a day with nothing logged is a faint dot, never a zero bar, and a target the
/// person set is a plain dashed line. The latest day is the accent.
struct FoodDayBars: View {
    let days: [FoodMath.DayValue]
    let target: Double?
    var height: CGFloat = 54
    let label: String
    let format: (Double) -> String

    var body: some View {
        let top = max(days.compactMap(\.value).max() ?? 0, target ?? 0, 1) * 1.05
        let accent = days.lastIndex { $0.value != nil }
        Canvas { ctx, size in
            let n = days.count
            guard n > 0 else { return }
            let slot = size.width / CGFloat(n)
            let barW = max(4, min(14, slot - 8))
            func y(_ v: Double) -> CGFloat { size.height - CGFloat(v / top) * (size.height - 6) }
            for (i, d) in days.enumerated() {
                let x = slot * (CGFloat(i) + 0.5)
                if let v = d.value {
                    let rect = CGRect(x: x - barW / 2, y: y(v), width: barW, height: max(1, size.height - y(v)))
                    let shape = UnevenRoundedRectangle(topLeadingRadius: min(4, barW / 2), topTrailingRadius: min(4, barW / 2), style: .continuous)
                    ctx.fill(shape.path(in: rect), with: .color(i == accent ? Palette.series1 : Palette.bar))
                } else {
                    ctx.fill(Path(ellipseIn: CGRect(x: x - 2, y: size.height - 4, width: 4, height: 4)), with: .color(Palette.ink3.opacity(0.35)))
                }
            }
            if let target {
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y(target)))
                line.addLine(to: CGPoint(x: size.width, y: y(target)))
                ctx.stroke(line, with: .color(Palette.ink2), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(days.map { "\(Fmt.day($0.date, "EEE")) \($0.value.map(format) ?? "nothing logged")" }.joined(separator: ", "))
    }
}

/// Water as glasses of 250 mL stacked per day: only the glasses drunk, no empty ones to fill.
struct GlassBars: View {
    let days: [FoodMath.DayValue]
    let target: Double?
    var height: CGFloat = 60
    let label: String
    let format: (Double) -> String

    var body: some View {
        let most = max(days.compactMap { $0.value.map { $0 / 250 } }.max() ?? 0, (target ?? 0) / 250, 1)
        let top = most.rounded(.up)
        let accent = days.lastIndex { $0.value != nil }
        Canvas { ctx, size in
            let n = days.count
            guard n > 0 else { return }
            let slot = size.width / CGFloat(n)
            let glassW = max(6, min(14, slot - 8))
            let step = (size.height - 6) / CGFloat(top)
            let gap = min(2, step / 4)
            for (i, d) in days.enumerated() {
                let x = slot * (CGFloat(i) + 0.5) - glassW / 2
                guard let ml = d.value else {
                    ctx.fill(Path(ellipseIn: CGRect(x: x + glassW / 2 - 2, y: size.height - 4, width: 4, height: 4)), with: .color(Palette.ink3.opacity(0.35)))
                    continue
                }
                let glasses = ml / 250
                let color = i == accent ? Palette.series1 : Palette.bar
                for g in 0..<Int(glasses.rounded(.up)) {
                    let fill = min(1, glasses - Double(g))
                    let h = max(1, (step - gap) * CGFloat(fill))
                    let y0 = size.height - CGFloat(g + 1) * step + (step - gap) * CGFloat(1 - fill) + gap
                    // A glass narrows a little toward its base.
                    let inset = glassW * 0.12
                    var p = Path()
                    p.move(to: CGPoint(x: x + inset, y: y0 + h))
                    p.addLine(to: CGPoint(x: x, y: y0))
                    p.addLine(to: CGPoint(x: x + glassW, y: y0))
                    p.addLine(to: CGPoint(x: x + glassW - inset, y: y0 + h))
                    p.closeSubpath()
                    ctx.fill(p, with: .color(color))
                }
            }
            if let target {
                let y = size.height - CGFloat(target / 250 / top) * (size.height - 6)
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y))
                line.addLine(to: CGPoint(x: size.width, y: y))
                ctx.stroke(line, with: .color(Palette.ink2), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(days.map { "\(Fmt.day($0.date, "EEE")) \($0.value.map(format) ?? "nothing logged")" }.joined(separator: ", "))
    }
}
