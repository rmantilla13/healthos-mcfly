import Charts
import SwiftUI

// The Nutrition section of Trends (src/pages/Nutrition.tsx): what a person logs in a food app, read through Apple
// Health, laid out like the web's Neka page (tabs, four cards, macro balance and insights). Only while Nutrition is
// on. The server has already removed every number the person chose not to see; this screen hides them again and adds
// no judgement of its own: no score, no "remaining" or "on track", nothing over or under, no red or green. A target
// is one the person set, drawn as a plain dashed line. A day with nothing logged is a gap, never a zero.

/// The page's views (TABS in src/pages/Nutrition.tsx): Today, then the views over more days. Each has its own link
/// (?tab=trends, as the web's addresses): Trends is the old Overview, and ?tab=overview still opens it.
enum NutritionTab: String, CaseIterable, Identifiable {
    case today, trends, macros, hydration, log
    var id: String { rawValue }

    var label: String {
        switch self {
        case .today: "Today"
        case .trends: "Trends"
        case .macros: "Macros"
        case .hydration: "Hydration"
        case .log: "Log"
        }
    }

    /// With no amounts, there's nothing for Macros and Hydration to show. Today only where the server has one day of
    /// the food log (POST /nutrition/log/day), the Log only where it has the food log.
    static func visible(_ mode: NutritionMode, today: Bool = true, logging: Bool = true) -> [NutritionTab] {
        allCases.filter { tab in
            switch tab {
            case .macros, .hydration: mode != .none
            case .today: today && logging
            case .log: logging
            case .trends: true
            }
        }
    }

    /// The view a link names (tabOf): "overview" is Trends's old name; anything unknown is Today.
    static func of(_ param: String?) -> NutritionTab {
        if param == "overview" { return .trends }
        return param.flatMap(NutritionTab.init(rawValue:)) ?? .today
    }

    /// The view shown for the one asked: itself where it's there, else Today, else the Log (an older server without
    /// one day of the log), else Trends.
    static func current(_ asked: NutritionTab, in tabs: [NutritionTab]) -> NutritionTab {
        [asked, .today, .log, .trends].first { tabs.contains($0) } ?? .trends
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

// MARK: - Reading

/// Which of a view's cards to draw: all of them in one column, or one of the open iPhone Duo's two panes (decisions.md
/// Q5): the lead (beside the intro, staying put) or the rest (two columns that scroll).
enum NutritionPart: Equatable {
    case all, lead, rest

    var lead: Bool { self != .rest }
    var rest: Bool { self != .lead }
}

/// Trends, Macros and Hydration: GET /api/nutrition for the range, and why when it can't be read. One column on a phone,
/// the outer display and the inner display upright. Split on the fold (the open Duo in landscape), Q5's frame: the
/// intro (the views and the range) and the view's lead on the leading side (Trends' macro balance, Macros' average day,
/// Hydration's water chart), and the rest on the trailing side, small cards two to a row. The read is here, above the
/// panes (P4), so a fold never reads again, and so are the charts' table views and picked days (`foodChartPicks`). A
/// fold hands the row at the top between the one column and the trailing pane by its id (§4). The three views are one
/// page, as they were one scroll view, so moving between them keeps it.
struct NutritionRangeTab<Intro: View>: View {
    let tab: NutritionTab
    let days: Int
    let insights: Bool
    @ViewBuilder let intro: () -> Intro
    @Environment(Dashboard.self) private var dashboard
    @Environment(\.nutritionReads) private var reads
    @State private var state = RangeRead(tab: .trends)
    @State private var picks = FoodChartPicks()

    /// One view's read: what came, whether it has, and why it couldn't. Another view starts afresh, as it always has; a
    /// new range or a reload keeps what's shown until the answer comes.
    struct RangeRead {
        let tab: NutritionTab
        var data: NutritionData?
        var loaded = false
        var error: String?
    }

    var body: some View {
        let read = state.tab == tab ? state : RangeRead(tab: tab)
        DuoPage { _ in
            DuoPanes(anchor: .secondary) {
                VStack(alignment: .leading, spacing: 16) {
                    intro()
                    if let data = read.data { content(data, .lead) } else { status(read) }
                }
                .padding(.vertical, 16)
            } secondary: {
                // The rows a fold hands over (§4): each card, or grid, by the same id as in the one column.
                VStack(alignment: .leading, spacing: 16) {
                    if let data = read.data { content(data, .rest) }
                }
                .scrollTargetLayout()
                .padding(.vertical, 16)
            } single: {
                VStack(alignment: .leading, spacing: 16) {
                    intro().id("nutrition.intro")
                    if let data = read.data { content(data, .all) } else { status(read).id("nutrition.status") }
                }
                .scrollTargetLayout()
                .padding(.vertical, 16)
            }
        }
        // A chart's table view and its picked day, above the panes (P4), for this view only.
        .environment(\.foodChartPicks, picks)
        .onChange(of: tab) { picks = FoodChartPicks() }
        .background(Palette.page)
        .refreshable { await dashboard.load() }
        .task(id: "\(dashboard.generation)|\(dashboard.nutritionMode?.rawValue ?? "off")|\(tab.rawValue)|\(days)|\(insights)") { await load() }
    }

    @ViewBuilder
    private func content(_ data: NutritionData, _ part: NutritionPart) -> some View {
        switch tab {
        case .macros: NutritionMacros(data: data, part: part)
        case .hydration: NutritionHydration(data: data, units: dashboard.units, days: days, part: part)
        default: NutritionOverview(data: data, units: dashboard.units, part: part)
        }
    }

    @ViewBuilder
    private func status(_ read: RangeRead) -> some View {
        if let error = read.error {
            Unavailable("Couldn't load your nutrition", systemImage: "fork.knife", description: error)
        } else if read.loaded {
            Text("Nutrition isn't available from this server yet.")
                .font(.app(.footnote)).foregroundStyle(Palette.ink3)
                .card()
        } else {
            ProgressView().frame(maxWidth: .infinity, minHeight: 200)
        }
    }

    private func load() async {
        let asked = tab
        do {
            let data = try await reads.totals(dashboard, days, insights)
            guard !Task.isCancelled, asked == tab else { return }
            state = RangeRead(tab: asked, data: data, loaded: true)
        } catch {
            guard !Task.isCancelled, asked == tab else { return }
            var kept = state.tab == asked ? state : RangeRead(tab: asked)
            kept.error = error.localizedDescription
            kept.loaded = true
            state = kept
        }
    }
}

// MARK: - Overview

/// Trends. On the open Duo (Q5) the macro balance is its lead, beside the intro; the small cards go two to a row and the
/// insights across, on the trailing side.
struct NutritionOverview: View {
    let data: NutritionData
    let units: Units
    var part: NutritionPart = .all
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        let week = FoodMath.dates(to: data.end, count: 7)
        let latest = data.days.last
        // Cards hidden in Profile → Cards (shared/cards.ts) are left out, and the rest close up.
        let layout = Cards.nutritionOverview(mode: data.mode, hidden: dashboard.cardsOff)
        // Each row's id is the same in the one column and in the open Duo's pane, so a fold hands it over (§4).
        if latest == nil && data.water.isEmpty {
            if part.lead { FoodNothingLoggedCard().id("trends.nothing") }
        } else if data.mode == .none {
            if part.rest, layout.row.contains("nutrition.logged") { FoodLoggedCard(data: data).id("trends.logged") }
            if part.lead { FoodNoAmountsCard(latest: latest, today: data.today).id("trends.noAmounts") }
        } else if layout.allHidden {
            if part.lead { AllCardsHiddenNote(text: "All the cards on this page are hidden.").id("trends.hidden") }
        } else {
            if part.rest { FoodOverviewCards(data: data, week: week, units: units, ids: layout.row).id("trends.cards") }
            if part.lead, layout.pair.contains("nutrition.macros") {
                Group {
                    if let latest {
                        MacroBalanceCard(day: latest, today: data.today, mode: data.mode, caffeine: data.caffeine.first { $0.date == latest.date }?.value)
                    } else {
                        FoodNothingLoggedCard()
                    }
                }
                .id("trends.macros")
            }
            if part.rest, layout.pair.contains("nutrition.insights") { FoodInsightsCard(insights: data.insights).id("trends.insights") }
        }
    }
}

/// Energy (only when everything is shown), protein, water and days logged, without the hidden ones: one to a row,
/// as the web's phone lays out its cards (.cards-4 under 560px); the web's count upright on the open Duo (4 as 2 × 2,
/// 3 as 2 and one across); two to a row in the open Duo's trailing pane (Q5).
private struct FoodOverviewCards: View {
    let data: NutritionData
    let week: [String]
    let units: Units
    let ids: [String]

    var body: some View {
        DuoGrid(ids, id: \.self, medium: 2, paneColumns: 2, spacing: 16) { id in card(id, wide: true) }
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

/// A card's figure (.metric-value): the number at 40, its unit under it in the muted ink.
struct FoodMetricValue: View {
    let value: String
    let unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value).font(.app(size: 40, weight: .medium, relativeTo: .largeTitle)).tracking(-1.2).foregroundStyle(Palette.ink)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(unit).font(.app(size: 13, relativeTo: .footnote)).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 6)
        .accessibilityElement(children: .combine)
    }
}

private struct FoodCardHead: View {
    let title: String
    let day: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.app(size: 13, weight: .medium, relativeTo: .footnote)).foregroundStyle(Palette.ink)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 4)
            if let day { Text(day).mutedSmall().lineLimit(1) }
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
        .font(.app(.caption2)).foregroundStyle(Palette.ink3)
    }
}

struct FoodEnergyCard: View {
    let week: [FoodMath.DayValue]
    let target: Double?
    let today: String

    var body: some View {
        let last = FoodMath.last(week)
        VStack(alignment: .leading, spacing: 8) {
            FoodCardHead(title: "Energy", day: last.map { Fmt.relativeDay($0.date, today: today) })
            if let last {
                FoodMetricValue(value: Fmt.number(last.value), unit: "kcal")
            } else {
                Text("No calories logged this week.").font(.app(.caption)).foregroundStyle(Palette.ink3)
            }
            Spacer(minLength: 0)
            FoodDayBars(days: week, target: target, label: "Energy, last 7 days") { "\(Fmt.number($0)) kcal" }
            FoodCardFoot(text: "Last 7 days", target: target.map { "\(Fmt.number($0)) kcal" })
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .card(.peach)
    }
}

struct FoodProteinCard: View {
    let week: [FoodMath.DayValue]
    let before: [FoodMath.DayValue]
    let target: Double?
    let today: String

    var body: some View {
        let last = FoodMath.last(week)
        VStack(alignment: .leading, spacing: 8) {
            FoodCardHead(title: "Protein", day: last.map { Fmt.relativeDay($0.date, today: today) })
            if let last {
                FoodMetricValue(value: Fmt.number(last.value), unit: "grams")
            } else {
                Text("No protein logged this week.").font(.app(.caption)).foregroundStyle(Palette.ink3)
            }
            if let delta = FoodMath.change(week, before) {
                Text(FoodMath.changeText(delta))
                    .font(.app(.caption2, weight: .medium))
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
                FoodMetricValue(value: FoodMath.glassesText(last.value), unit: "\(FoodMath.glasses(last.value) == 1 ? "glass" : "glasses") · \(FoodMath.water(last.value, units: units))")
            } else {
                Text("No water logged this week.").font(.app(.caption)).foregroundStyle(Palette.ink3)
            }
            Spacer(minLength: 0)
            GlassBars(days: week, target: target, label: "Water in glasses, last 7 days") { "\(FoodMath.glassesText($0)) glasses · \(FoodMath.water($0, units: units))" }
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
        let cell: CGFloat = dates.count > 31 ? 9 : compact ? 11 : 14
        VStack(alignment: .leading, spacing: 8) {
            Text("Days logged").font(.app(.headline, weight: .medium)).foregroundStyle(Palette.ink).accessibilityAddTraits(.isHeader)
            Text("\(logged.count) of \(FoodMath.days(dates.count))")
                .font(.app(size: 13, weight: .medium, relativeTo: .footnote))
                .foregroundStyle(Palette.ink)
                .padding(.top, 6)
            Spacer(minLength: 0)
            NutritionFlow(spacing: 4, rowSpacing: 4) {
                ForEach(dates, id: \.self) { d in
                    RoundedRectangle(cornerRadius: cell > 10 ? 4 : 3, style: .continuous)
                        .fill(logged.contains(d) ? Palette.barAccent : Palette.grid)
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
            .font(.app(.caption2)).foregroundStyle(Palette.ink3)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .card()
    }
}

private struct FoodNoAmountsCard: View {
    let latest: FoodDay?
    let today: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(latest.map { Fmt.relativeDay($0.date, today: today) } ?? "Nothing logged lately").font(.app(.headline, weight: .medium)).foregroundStyle(Palette.ink)
            LinkedText((latest.map { "You logged food \($0.app == "healthOS" ? "here" : "in \($0.app)"). " } ?? "")
                + "You chose to see no amounts, so this shows only the days you logged, and Today what you logged. Change it in [your Profile](healthos://profile).")
                .font(.app(size: 14, relativeTo: .subheadline)).foregroundStyle(Palette.ink3)
        }
        .card()
    }
}

/// Nothing logged anywhere yet (NothingYet): where logging happens, and the food apps this iPhone reads through Health.
private struct FoodNothingLoggedCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Nothing logged yet").font(.app(.headline, weight: .medium)).foregroundStyle(Palette.ink).accessibilityAddTraits(.isHeader)
            LinkedText("Tell McFly what you ate on [Today](healthos://nutrition), or search foods and type amounts on the [Log](healthos://nutrition?tab=log) tab.")
                .font(.app(size: 14, relativeTo: .subheadline)).foregroundStyle(Palette.ink3)
            // The web's "then open the healthOS iPhone app": this is it.
            Text("Or keep using a food app that writes to Apple Health, such as MyFitnessPal, Cronometer, Lose It!, MacroFactor or Yazio, and turn on its Apple Health connection in that app. This iPhone reads it at its next sync, once you allow healthOS to read nutrition when Health asks.")
                .font(.app(size: 14, relativeTo: .subheadline)).foregroundStyle(Palette.ink3)
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
            NutriCardHead(title: "Macro balance") {
                Text("\(Fmt.relativeDay(day.date, today: today)) · \(day.app)").mutedSmall()
            }
            if parts.isEmpty {
                Text("No protein, carbs or fat logged that day.").font(.app(size: 14, relativeTo: .subheadline)).foregroundStyle(Palette.ink3)
            } else {
                let donut = MacroDonut(parts: parts, energy: mode == .all ? day.values["energy_kcal"] : nil).frame(width: 124, height: 124)
                let list = VStack(alignment: .leading, spacing: 10) {
                    ForEach(parts) { p in
                        HStack(spacing: 10) {
                            Circle().fill(MacroColor.of(p.key)).frame(width: 10, height: 10)
                            Text(p.label).font(.app(size: 14, relativeTo: .subheadline)).foregroundStyle(Palette.ink2)
                            Spacer(minLength: 4)
                            Text("\(Fmt.number(p.grams)) g").font(.app(size: 14, weight: .semibold, relativeTo: .subheadline)).foregroundStyle(Palette.ink)
                            Text("\(p.percent)%").font(.app(.caption)).foregroundStyle(Palette.ink3).frame(minWidth: 40, alignment: .trailing)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                // Side by side where they fit (.macro-balance-body wraps), the list under the ring where they don't.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 24) { donut; list.frame(minWidth: 180) }
                    VStack(alignment: .leading, spacing: 16) { donut; list }
                }
            }
            MacroFooter(day: day, caffeine: caffeine)
        }
        .card()
    }
}

struct MacroDonut: View {
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
                    Text(Fmt.number(energy)).font(.app(fixedSize: 22, weight: .semibold)).monospacedDigit().foregroundStyle(Palette.ink)
                    Text("kcal").font(.app(.caption2)).foregroundStyle(Palette.ink3)
                } else {
                    Text("by weight").font(.app(.caption2)).foregroundStyle(Palette.ink3)
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
            Text(label).font(.app(.caption)).foregroundStyle(Palette.ink3)
            Text(value).font(.app(.subheadline, weight: .medium)).monospacedDigit().foregroundStyle(Palette.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct FoodInsightsCard: View {
    let insights: [Pattern]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Insights").font(.app(.headline)).foregroundStyle(Palette.ink)
            if insights.isEmpty {
                Text("Patterns show up here once there are a few weeks of logs to compare: caffeine and that night's sleep, and drinks and the next morning's HRV.")
                    .font(.app(.footnote)).foregroundStyle(Palette.ink3).fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(insights) { p in
                    let (symbol, tone) = HomeInsightsCard.style(p.icon ?? "")
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: symbol)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(tone.ink)
                            .frame(width: 34, height: 34)
                            .background(tone.background, in: Circle())
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.text).font(.app(.subheadline)).foregroundStyle(Palette.ink)
                            Text(((p.detail ?? "") + " Days that go together, not proof that one causes the other.").trimmingCharacters(in: .whitespaces))
                                .font(.app(.caption)).foregroundStyle(Palette.ink3)
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

/// Macros. On the open Duo (Q5) the average day is its lead, beside the intro and the range; the days logged, the
/// nutrients' charts, which need the width, and the app choice are on the trailing side.
struct NutritionMacros: View {
    let data: NutritionData
    var part: NutritionPart = .all

    var body: some View {
        if data.days.isEmpty {
            if part.lead { FoodNothingLoggedCard().id("macros.nothing") }
        } else {
            if part.lead { FoodAverageCard(data: data).id("macros.average") }
            // The days logged go first on the trailing side on the open Duo, so the leading side fits without scrolling.
            if part.rest { FoodLoggedCard(data: data).id("macros.logged") }
            if part.rest { rest }
        }
    }

    /// Each row with the same id in the one column and the open Duo's pane, so a fold hands it over (§4).
    @ViewBuilder private var rest: some View {
        ForEach(FoodMath.order.filter { n in data.days.contains { $0.values[n] != nil } }.map { "macros.chart.\($0)" }, id: \.self) { id in
            let n = String(id.dropFirst("macros.chart.".count))
            let target = n == "energy_kcal" || n == "protein_g" ? data.targets?[n] : nil
            FoodChartCard(title: FoodMath.name(n), points: data.days.compactMap { d in d.values[n].map { Point(date: d.date, value: $0) } },
                          start: data.start, end: data.end, target: target,
                          table: FoodChartTable(columns: ["Date", "\(FoodMath.name(n)) (\(FoodMath.names[n]?.unit ?? ""))"]) { [Fmt.day($0.date, "MMMdyyyy"), Fmt.number($0.value)] },
                          format: { FoodMath.amount(n, $0) })
        }
        if data.apps.count > 1 { FoodAppChoice(data: data).id("macros.apps") }
        Text("Days with nothing logged are left out, not counted as zero. When two apps logged the same day, one is shown and the other isn't added in, because food apps often copy each other's entries through Apple Health.")
            .font(.app(.caption)).foregroundStyle(Palette.ink3).fixedSize(horizontal: false, vertical: true)
            .id("macros.note")
    }
}

/// The latest logged day: each nutrient, and protein, carbs and fat as one split by weight.
struct FoodDayCard: View {
    let day: FoodDay
    let today: String
    let mode: NutritionMode

    var body: some View {
        let shown = FoodMath.order.filter { day.values[$0] != nil }
        let parts = FoodMath.parts(day)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(Fmt.relativeDay(day.date, today: today)).font(.app(.headline)).foregroundStyle(Palette.ink)
                Spacer()
                Text(day.app)
                    .font(.app(.caption, weight: .medium))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Palette.surface2, in: Capsule())
                    .foregroundStyle(Palette.ink2)
            }
            if mode == .none || shown.isEmpty {
                Text("You logged food in \(([day.app] + day.otherApps).joined(separator: ", ")).").font(.app(.footnote)).foregroundStyle(Palette.ink2)
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
                    Text("Also logged in \(day.otherApps.joined(separator: ", ")), not added in.").font(.app(.caption)).foregroundStyle(Palette.ink3)
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
            .font(.app(.caption)).foregroundStyle(Palette.ink2)
        }
        .accessibilityElement()
        .accessibilityLabel("By weight: " + parts.map { "\($0.label.lowercased()) \($0.percent)%" }.joined(separator: ", "))
    }
}

// MARK: - Hydration

/// Hydration. On the open Duo (Q5) the water chart is its lead, beside the intro and the range; the two averages, small
/// cards, go side by side on the trailing side, with the caffeine chart across under them.
struct NutritionHydration: View {
    let data: NutritionData
    let units: Units
    let days: Int
    var part: NutritionPart = .all

    var body: some View {
        if data.water.isEmpty && data.caffeine.isEmpty {
            if part.lead { nothing.id("hydration.nothing") }
        } else {
            let water = { (ml: Double) in "\(FoodMath.glassesText(ml)) \(FoodMath.glasses(ml) == 1 ? "glass" : "glasses") · \(FoodMath.water(ml, units: units))" }
            let waterSummary = HydrationSummaryCard(title: "Water", points: data.water, format: water, target: data.targets?["water_ml"].map { FoodMath.water($0, units: units) }, days: days)
            let caffeineSummary = HydrationSummaryCard(title: "Caffeine", points: data.caffeine, format: { "\(Fmt.number($0)) mg" }, target: nil, days: days)
            // The ids a fold hands over (§4): the pane's pair of averages has the one column's water average's id. The
            // caffeine average is a row only in the one column, so an unfold from it opens the pane at its top.
            switch part {
            case .all:
                waterSummary.id("hydration.averages")
                caffeineSummary.id("hydration.caffeineAverage")
                waterChart.id("hydration.water")
                caffeineChart.id("hydration.caffeine")
            case .lead:
                waterChart.id("hydration.water")
            case .rest:
                DuoPair(spacing: 16, paneSideBySide: true) { waterSummary } second: { caffeineSummary }
                    .id("hydration.averages")
                caffeineChart.id("hydration.caffeine")
            }
        }
    }

    private var nothing: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No water or caffeine logged").font(.app(.headline)).foregroundStyle(Palette.ink)
            Text("Apps that log drinks, like WaterMinder or your food app, write water and caffeine to Apple Health, and they show up here.")
                .font(.app(.footnote)).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true)
        }
        .card()
    }

    private var waterChart: some View {
        FoodChartCard(title: "Water", points: data.water, start: data.start, end: data.end, target: data.targets?["water_ml"],
                      note: "1 glass = \(FoodMath.glassSize(units))", medianNote: false,
                      table: FoodChartTable(columns: ["Date", units == .imperial ? "Water (fl oz)" : "Water (mL)", "Glasses"]) {
                          [Fmt.day($0.date, "MMMdyyyy"), FoodMath.water($0.value, units: units), Fmt.number(FoodMath.glasses($0.value), 1)]
                      },
                      format: { FoodMath.water($0, units: units) },
                      axis: { units == .imperial ? Fmt.number($0 / 29.5735) : Fmt.number($0) })
    }

    private var caffeineChart: some View {
        FoodChartCard(title: "Caffeine", points: data.caffeine, start: data.start, end: data.end, target: nil,
                      note: "daily total", medianNote: false,
                      table: FoodChartTable(columns: ["Date", "Caffeine (mg)"]) { [Fmt.day($0.date, "MMMdyyyy"), Fmt.number($0.value)] },
                      format: { "\(Fmt.number($0)) mg" })
    }
}

// MARK: - Charts

/// One bar per logged day, side by side in even slots as the web's BarChart (src/charts/Charts.tsx) draws them: days
/// with nothing logged are left out, not drawn as zero or as a gap, so a few logged days fill the width instead of
/// sitting apart on the whole window's axis. The median as a faint line, the person's own target as a plain dashed one,
/// and the latest day (or the one picked) in the accent.
struct FoodChartCard: View {
    let title: String
    let points: [Point]
    /// The window asked for; the axis plots only the days logged in it.
    let start: String
    let end: String
    let target: Double?
    var note: String?
    /// Say "median line" in the note (the nutrients' charts; the web's hydration charts don't).
    var medianNote = true
    /// The same days as a table; nil: the date and the formatted value.
    var table: FoodChartTable?
    let format: (Double) -> String
    var axis: (Double) -> String = { Fmt.compact($0) }
    /// The picked day's date (a bar is the day's "yyyy-MM-dd") and the table view: the page's (`foodChartPicks`, above
    /// the open Duo's panes, so a fold keeps them, P4), or this card's own where no page holds them.
    @Environment(\.foodChartPicks) private var picks
    @State private var own = FoodChartPick()
    private var pick: FoodChartPick { picks?.pick(title) ?? own }
    private var selected: String? { pick.selected }
    private var asTable: Bool { pick.asTable }

    var body: some View {
        let pick = pick
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.app(.subheadline, weight: .medium)).foregroundStyle(Palette.ink)
                        .accessibilityAddTraits(.isHeader)
                    Text(([FoodMath.days(points.count) + " logged"] + (medianNote ? ["median line"] : []) + [note].compactMap { $0 }).joined(separator: " · "))
                        .font(.app(.caption)).foregroundStyle(Palette.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if !points.isEmpty { ChartTableToggle(title: title, asTable: Bindable(pick).asTable) }
            }
            if !points.isEmpty {
                if asTable {
                    FoodTableView(table: table ?? FoodChartTable(columns: ["Date", title]) { [Fmt.day($0.date, "MMMdyyyy"), format($0.value)] }, points: points)
                        .padding(.top, 6)
                } else {
                    // 180 on a phone; taller where the band is wider (P9).
                    GeometryReader { geo in chart(width: geo.size.width) }.duoChartHeight(180).padding(.top, 6)
                }
            }
        }
        .card()
    }

    private var median: Double? {
        let v = points.map(\.value).sorted()
        guard !v.isEmpty else { return nil }
        return v.count % 2 == 1 ? v[v.count / 2] : (v[v.count / 2 - 1] + v[v.count / 2]) / 2
    }

    /// The plot's width beside the value axis, roughly: what the bars' slots share.
    private static let valueAxisWidth: CGFloat = 32

    /// A bar's width in its slot, as the web's: the slot less 2 points, at least 1 and at most 24.
    static func barWidth(plotWidth: CGFloat, count: Int) -> CGFloat {
        guard count > 0, plotWidth > 0 else { return 1 }
        return max(1, min(24, plotWidth / CGFloat(count) - 2))
    }

    /// Which days get a date under the axis (xLabels): 2 to 6 of them, one per 90 points, spread evenly from the first
    /// logged day to the last.
    static func labelIndices(count: Int, width: CGFloat) -> [Int] {
        guard count > 0 else { return [] }
        let n = max(2, min(6, Int(width / 90)))
        var out: [Int] = []
        for k in 0..<n {
            let i = Int((Double(k) / Double(n - 1) * Double(count - 1)).rounded())
            if !out.contains(i) { out.append(i) }
        }
        return out
    }

    private func chart(width: CGFloat) -> some View {
        let picked = selected.flatMap { s in points.first { $0.date == s } }
        let bar = Self.barWidth(plotWidth: width - Self.valueAxisWidth, count: points.count)
        let labelled = Self.labelIndices(count: points.count, width: width).map { points[$0].date }
        return Chart {
            ForEach(points) { p in
                BarMark(x: .value("Day", p.date), y: .value(title, p.value), width: .fixed(bar))
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
                        Text("Your target").font(.app(.caption2)).foregroundStyle(Palette.ink2)
                            .padding(.horizontal, 4)
                            .background(Palette.surface.opacity(0.9), in: RoundedRectangle(cornerRadius: 4))
                    }
            }
            if let picked {
                RuleMark(x: .value("Day", picked.date))
                    .foregroundStyle(Palette.ink3.opacity(0.3))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        VStack(spacing: 1) {
                            Text(format(picked.value)).font(.app(.caption, weight: .semibold))
                            Text(Fmt.day(picked.date)).font(.app(.caption2))
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Palette.surface2, in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(Palette.ink)
                    }
            }
        }
        .chartScrub(Bindable(pick).selected)
        .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { v in
            AxisGridLine().foregroundStyle(Palette.grid)
            AxisValueLabel { if let n = v.as(Double.self) { Text(axis(n)) } }.font(.axis).foregroundStyle(Palette.ink3)
        } }
        .chartXAxis { AxisMarks(values: labelled) { v in
            AxisValueLabel { if let d = v.as(String.self) { Text(Fmt.day(d)) } }.font(.axis).foregroundStyle(Palette.ink3)
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

/// One chart's picked day and whether it shows as a table.
@MainActor @Observable
final class FoodChartPick {
    var selected: String?
    var asTable = false
}

/// A range view's charts' picks, by chart title, held by the page above the open Duo's panes (P4), so a fold that swaps
/// them leaves each chart as it was. Each chart watches only its own.
@MainActor @Observable
final class FoodChartPicks {
    @ObservationIgnored private var picks: [String: FoodChartPick] = [:]

    func pick(_ title: String) -> FoodChartPick {
        if let p = picks[title] { return p }
        let p = FoodChartPick()
        picks[title] = p
        return p
    }
}

private struct FoodChartPicksKey: EnvironmentKey {
    static var defaultValue: FoodChartPicks? { nil }
}

extension EnvironmentValues {
    /// The page's chart picks (NutritionRangeTab); nil: each chart keeps its own.
    var foodChartPicks: FoodChartPicks? {
        get { self[FoodChartPicksKey.self] }
        set { self[FoodChartPicksKey.self] = newValue }
    }
}

// MARK: - Tables, averages and the app that counts

/// A chart's days as a table (ChartCard's table view): its columns, and each day's cells, newest first.
struct FoodChartTable {
    let columns: [String]
    let row: (Point) -> [String]
}

/// Chart or table (ChartCard's .seg): two small icon buttons in a soft well, the one shown raised on white.
private struct ChartTableToggle: View {
    let title: String
    @Binding var asTable: Bool

    var body: some View {
        HStack(spacing: 0) {
            option("chart.bar", "Chart", on: !asTable) { asTable = false }
            option("tablecells", "Table", on: asTable) { asTable = true }
        }
        .padding(3)
        .background(Palette.surface2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.border))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title) view")
    }

    private func option(_ symbol: String, _ name: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.caption)
                .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                .foregroundStyle(on ? Palette.ink : Palette.ink2)
                .frame(width: 30, height: 26)
                .background {
                    if on {
                        RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.surface).shadow(color: .black.opacity(0.08), radius: 1, y: 1)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// The table itself, scrolling inside its card past a few dozen days (.table-wrap): a 360 pt window on a phone; on the
/// open Duo the smaller of that and 45% of the scope's height (§2.7).
private struct FoodTableView: View {
    let table: FoodChartTable
    let points: [Point]
    @Environment(\.duoTableWindow) private var window

    var body: some View {
        let rows = points.reversed().map(table.row)
        ScrollView {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 0) {
                GridRow {
                    ForEach(table.columns, id: \.self) { Text($0).font(.app(size: 12, weight: .medium, relativeTo: .caption)).foregroundStyle(Palette.ink3) }
                }
                .padding(.vertical, 6)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, cells in
                    Divider().overlay(Palette.border).gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                            Text(cell).font(.app(size: 13, relativeTo: .footnote)).foregroundStyle(Palette.ink)
                        }
                    }
                    .padding(.vertical, 6)
                    .accessibilityElement(children: .combine)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: window)
    }
}

/// The range's average day (AverageCard): each nutrient's mean over the days it was logged (a day without it doesn't
/// count as zero), and protein, carbs and fat by weight. In place of repeating the latest day, which Trends shows.
struct FoodAverageCard: View {
    let data: NutritionData
    /// In the open Duo's leading pane, which doesn't scroll: the ring over the values, three to a row.
    @Environment(\.duoInPane) private var inPane

    /// Each nutrient's mean over the days it was logged.
    static func averages(_ days: [FoodDay]) -> [String: Double] {
        var out: [String: Double] = [:]
        for n in FoodMath.order {
            let v = days.compactMap { $0.values[n] }
            if !v.isEmpty { out[n] = v.reduce(0, +) / Double(v.count) }
        }
        return out
    }

    var body: some View {
        let avg = Self.averages(data.days)
        let shown = FoodMath.order.filter { avg[$0] != nil }
        let parts = FoodMath.parts(FoodDay(date: data.end, app: "", values: avg, otherApps: []))
        let span = Fmt.daysBetween(data.start, data.end) + 1
        VStack(alignment: .leading, spacing: 14) {
            NutriCardHead(title: "Average day") {
                Text("\(data.days.count) logged \(data.days.count == 1 ? "day" : "days") in the last \(span)").mutedSmall()
            }
            // Three to a row in the open Duo's leading pane (it doesn't scroll), whichever side the bar is on.
            let values = LazyVGrid(columns: [GridItem(.adaptive(minimum: inPane ? 88 : 120), spacing: inPane ? 12 : 16, alignment: .topLeading)], alignment: .leading, spacing: 12) {
                ForEach(shown, id: \.self) { n in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(FoodMath.name(n)).font(.app(.caption)).foregroundStyle(Palette.ink2)
                        Text(FoodMath.amount(n, avg[n]!)).font(.app(size: 22, weight: .medium, relativeTo: .title3)).tracking(-0.44).foregroundStyle(Palette.ink)
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            if parts.count == 3 {
                let donut = MacroDonut(parts: parts, energy: avg["energy_kcal"])
                    .frame(width: 124, height: 124)
                    .accessibilityLabel("Average by weight: " + parts.map { "\($0.label.lowercased()) \($0.percent)%" }.joined(separator: ", "))
                // Side by side where the values have room (.average-day-body wraps), else the ring over them.
                if inPane {
                    VStack(alignment: .leading, spacing: 16) { donut; values }
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .center, spacing: 24) { donut; values.frame(minWidth: 220) }
                        VStack(alignment: .leading, spacing: 16) { donut; values }
                    }
                }
            } else {
                values
            }
            Text("Each average counts only the days that nutrient was logged.").mutedSmall()
        }
        .card()
    }
}

/// On days two apps logged (AppChoice): use one app's totals, or Automatic, which picks whichever logged the most that
/// day. Saved as the person's setting (nutritionApp), then every view reads again.
private struct FoodAppChoice: View {
    let data: NutritionData
    @Environment(Dashboard.self) private var dashboard
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("On days two apps logged").font(.app(.headline, weight: .medium)).foregroundStyle(Palette.ink).accessibilityAddTraits(.isHeader)
                Text("Use one app's totals. Automatic picks whichever logged the most that day.").mutedSmall()
            }
            NutritionFlow(spacing: 0, rowSpacing: 4) {
                ForEach([String?.none] + data.apps.map(Optional.some), id: \.self) { app in
                    let on = data.app == app
                    Button(app ?? "Automatic") { save(app) }
                        .buttonStyle(.plain)
                        .font(.app(size: 13, weight: .medium, relativeTo: .footnote))
                        .foregroundStyle(on ? Palette.ink : Palette.ink2)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .frame(minHeight: 36)
                        .background {
                            if on { RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.surface).shadow(color: .black.opacity(0.08), radius: 1, y: 1) }
                        }
                        .contentShape(Rectangle())
                        .disabled(busy)
                        .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(3)
            .background(Palette.surface2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.border))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("App to use")
            if let error { NoteBad(error, size: 12) }
        }
        .card()
    }

    private func save(_ app: String?) {
        guard app != data.app else { return }
        busy = true
        error = nil
        Task {
            do {
                // The days' totals change with it: everything is read again.
                try await dashboard.save(settings: ["nutritionApp": app.map { $0 as Any } ?? NSNull()], reload: true)
            } catch {
                if !APIClient.isCancellation(error) { self.error = error.localizedDescription }
            }
            busy = false
        }
    }
}

/// A drink's average over the days it was logged in the range, and how many days that was (HydrationSummary).
private struct HydrationSummaryCard: View {
    let title: String
    let points: [Point]
    let format: (Double) -> String
    let target: String?
    let days: Int

    var body: some View {
        let avg = points.isEmpty ? nil : points.map(\.value).reduce(0, +) / Double(points.count)
        VStack(alignment: .leading, spacing: 6) {
            NutriCardHead(title: title) { Text("Last \(days) days").mutedSmall() }
            if let avg {
                Text(format(avg)).font(.app(size: 32, weight: .medium, relativeTo: .title)).tracking(-0.96).foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text("a day on average, over the \(points.count) \(points.count == 1 ? "day" : "days") logged").font(.app(.footnote)).foregroundStyle(Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                if let target { Text("Your target \(target)").mutedSmall() }
            } else {
                Text("Nothing logged in these \(days) days.").mutedSmall()
            }
        }
        .accessibilityElement(children: .combine)
        .card()
    }
}
