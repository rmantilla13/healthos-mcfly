import SwiftUI

/// The Body page (src/pages/Body.tsx): your figure and the measurements you add first, then, once a device has sent
/// anything, one day of its readings, and a tab for each area over a range. A link's `tab=` opens a tab (Activity was the
/// web's #/activity); each time the link is opened, on the Body tab already or not.
///
/// One column on every iPhone, the outer display and the inner display upright. On the open iPhone Duo in landscape
/// (decisions.md Q5) the figure card, the page's line and its tabs stay on the leading side of the fold, and everything
/// else is in two columns on the trailing side, the wide cards across both. What a fold rebuilds is only the panes'
/// content: the model, the tab, the reads, the sheet and the workout ticks live here, above the panes (P4).
struct BodyScreen: View {
    @Environment(Dashboard.self) private var dashboard
    @Environment(\.bodyReads) private var reads
    @State private var model = BodyModel()
    @State private var tab: BodyTab = .overview
    @State private var adding: BodyMetric?
    /// The workout suggestions ticked, by workout; memory only.
    @State private var ticks: [String: Set<String>] = [:]

    var body: some View {
        PhaseGate {
            DuoPage { _ in
                BodyContent(model: model, tab: $tab, onAdd: { adding = $0 }, ticks: $ticks)
            }
            .background(Palette.page.ignoresSafeArea())
            .refreshable { await dashboard.load() }
        }
        .sheet(item: $adding) { metric in
            if let now = model.now(dashboard) {
                BodyEntrySheet(metric: metric, today: now.today, demo: now.demo == true,
                               changed: { Task { await dashboard.load() } }, close: { adding = nil })
                    .environment(dashboard)
                    .environment(\.bodyReads, reads)
            }
        }
        .task(id: "\(readKey)|\(dashboard.date ?? "")|\(tab == .overview)") {
            guard dashboard.phase == .ready, tab == .overview else { return }
            await model.loadOverview(dashboard, reads: reads)
        }
        .task(id: "\(readKey)|\(tab.rawValue)|\(dashboard.rangeDays)") {
            guard dashboard.phase == .ready, tab != .overview else { return }
            await model.loadTab(tab, days: BodyRange.days(dashboard.rangeDays), dashboard, reads: reads)
        }
        .task(id: "\(readKey)|\(tab == .activity)|\(model.activityDate ?? "")") {
            guard dashboard.phase == .ready, tab == .activity else { return }
            await model.loadActivityDay(dashboard, reads: reads)
        }
        .onChange(of: dashboard.request(for: .body)?.id, initial: true) { _, _ in
            // Each opening of a link applies its tab again, whatever was picked since.
            if let request = dashboard.request(for: .body) { tab = BodyTab.of(request.route.query) }
        }
        // Signed out, someone else, another server: no sheet stays up on the last person's entries.
        .onChange(of: dashboard.session) { _, _ in
            adding = nil
            ticks = [:]
        }
    }

    /// Who and what: a new person, server or load reads again.
    private var readKey: String {
        let s = dashboard.session
        return "\(s.server)|\(s.person ?? "")|\(s.count)|\(dashboard.generation)|\(dashboard.phase == .ready)"
    }
}

/// The ranges as each tab reads them: Day counts as 30 days on a tab without a Day view (useRange's DAY).
enum BodyRange {
    static func days(_ shared: Int) -> Int { shared == ChartRange.day.days ? 30 : shared }
}

/// The page under its DuoPage: a spinner or the reason while there's nothing yet, then the lead and the tab's rows, in
/// one column or two panes.
private struct BodyContent: View {
    let model: BodyModel
    @Binding var tab: BodyTab
    let onAdd: (BodyMetric) -> Void
    @Binding var ticks: [String: Set<String>]
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        if let now = model.now(dashboard) {
            let rows = BodyRows(model: model, now: now, tab: tab, dashboard: dashboard)
            if rows.figure {
                // The Overview with your figure: on the open Duo, the figure stays put on the leading side while the
                // rest scrolls in two columns beside it (Q5).
                DuoPanes(anchor: .secondary) {
                    BodyLeadPane(summary: now) { lead(rows, split: false) }
                } secondary: {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(rows.ids, id: \.self) { id in row(id, rows: rows).id(id) }
                    }
                    .padding(.vertical, 16)
                    .scrollTargetLayout()
                } single: {
                    VStack(alignment: .leading, spacing: 14) {
                        lead(rows, split: false).id("body.lead")
                        BodyFigureCard(summary: now).id("body.figure")
                        ForEach(rows.ids, id: \.self) { id in row(id, rows: rows).id(id) }
                    }
                    .padding(.bottom, 16)
                    .scrollTargetLayout()
                }
            } else {
                // A tab's charts, or the Overview without a figure: one scroll, split on the open Duo's fold, so its
                // cards go one each side of it, twice as many at once.
                DuoScroll {
                    VStack(alignment: .leading, spacing: 14) {
                        lead(rows, split: true).id("body.lead")
                        ForEach(rows.ids, id: \.self) { id in row(id, rows: rows).id(id) }
                    }
                    .padding(.bottom, 16)
                }
            }
        } else if case .unavailable(let message) = dashboard.phase {
            Unavailable("Couldn't load your data", systemImage: "wifi.exclamationmark", description: message) { EmptyView() }
        } else {
            ProgressView()
        }
    }

    // MARK: The lead

    /// The page's lead: as one block (the phone, a pane), or, with `split`, as a header that splits on the fold.
    @ViewBuilder private func lead(_ rows: BodyRows, split: Bool) -> some View {
        let selection = Binding<BodyTab>(get: { tab }, set: { new in
            // The web's tabs are links (#/body?tab=…): opening one keeps the page the sheet names in step.
            tab = new
            dashboard.open(BodyCardLink.tab(new))
        })
        let showsTabs = tab != .overview || rows.devices
        if split {
            BodyHeader(tab: selection, showsTabs: showsTabs) { tools(rows) }
        } else {
            BodyLead(tab: selection, showsTabs: showsTabs) { tools(rows) }
        }
    }

    @ViewBuilder private func tools(_ rows: BodyRows) -> some View {
        @Bindable var model = model
        switch tab {
        case .overview: EmptyView()
        case .activity:
            if rows.activityMode == .day, let day = model.activityDay.value ?? nil {
                DayNav(today: day.today, date: $model.activityDate)
            }
            RangeFilters(days: Binding(get: { rows.activityMode == .range ? BodyRange.days(dashboard.rangeDays) : ChartRange.day.days },
                                       set: { dashboard.rangeDays = $0 }),
                         ranges: model.dayAvailable ? ChartRange.withDay : ChartRange.standard)
        default:
            RangeFilters(days: Binding(get: { BodyRange.days(dashboard.rangeDays) }, set: { dashboard.rangeDays = $0 }))
        }
    }

    // MARK: The rows

    @ViewBuilder private func row(_ id: String, rows: BodyRows) -> some View {
        let s = dashboard.summary ?? rows.now
        let shown = dashboard.cardShown
        switch id {
        case "body.measures":
            DuoGrid(rows.measureCells, id: \.self, medium: 1, paneColumns: 2) { cell in
                if cell == "story" {
                    BodyStoryCard(figure: rows.figure).duoSpans()
                } else if let metric = BodyMetric(rawValue: cell) {
                    BodyMeasurementCard(metric: metric, stored: model.measured.value?[metric.rawValue] ?? [],
                                        latest: model.latest.value.flatMap { $0?[metric] }, asOf: rows.now.date,
                                        onAdd: rows.canAdd ? onAdd : nil)
                }
            }
        case "body.devices.head":
            BodyDevicesHead(summary: s)
        case "body.devices.1":
            let trends = model.devices?.trends.value ?? [:]
            DuoGrid(BodyRows.shown(["body.rhr", "body.hrv", "body.strain", "body.recovery"], shown), id: \.self, paneColumns: 2) { card in
                switch card {
                case "body.rhr": BodyRestingHrCard(summary: s, points: trends["resting_hr"] ?? [])
                case "body.hrv": BodyHrvCard(summary: s)
                case "body.strain": BodyStrainCard(summary: s)
                default: BodyRecoveryCard(summary: s, points: trends["recovery"] ?? [])
                }
            }
        case "body.devices.2":
            let day = model.devices?.day.value ?? nil
            pair(BodyRows.shown(["body.heart", "body.metrics"], shown)) { card in
                if card == "body.heart" { BodyHeartCard(day: day) } else { BodyMetricsCard(summary: s, trends: model.devices?.trends.value ?? [:]) }
            }
        case "body.devices.3":
            let day = model.devices?.day.value ?? nil
            pair(BodyRows.shown(["body.energy", "body.steps"], shown)) { card in
                if card == "body.energy" {
                    BodyEnergyCard(day: day, points: model.devices?.trends.value?["active_energy"] ?? [], date: s.date)
                } else {
                    BodyStepsDayCard(day: day, summary: s, goal: dashboard.stepGoal)
                }
            }
        case "body.devices.4":
            DuoGrid(rows.lastRow, id: \.self, paneColumns: 2) { card in
                switch card {
                case "body.workout":
                    BodyWorkoutCard(summary: s, read: model.devices?.workouts ?? .loading, ticked: { ticks[$0] ?? [] },
                                    tick: { w, sg, on in ticks[w, default: []] = on ? ticks[w, default: []].union([sg]) : ticks[w, default: []].subtracting([sg]) })
                        .duoSpans()
                case "body.glucose": BodyGlucoseCard(summary: s, read: model.devices?.glucose ?? .loading)
                default: BodyBiomarkersCard(read: model.devices?.labs ?? .loading).duoSpans()
                }
            }
        case "body.hidden":
            BodyAllHidden()
        case "trend.loading", "activity.pending":
            ProgressView().frame(maxWidth: .infinity, minHeight: 200)
        case "trend.failed":
            BodyReadFailed(title: "Couldn't load trends", words: rows.tabFailure ?? "")
        case "trend.empty":
            BodyNothingInRange()
        case "trend.grid":
            // The tab's charts: one per row, as the web's grid-2 below 1080; one each side of the open Duo's fold.
            DuoGrid(rows.cells, id: \.self, medium: 1) { cell in chart(cell, rows: rows) }
        default:
            EmptyView()
        }
    }

    /// One of a tab's charts (or the Activity tab's workouts), by its cell.
    @ViewBuilder private func chart(_ cell: String, rows: BodyRows) -> some View {
        switch cell {
        case "activity.day.steps":
            if let day = model.activityDay.value ?? nil, let steps = day.steps {
                BodyDayCard(metric: .steps, series: steps, data: day, goal: dashboard.stepGoal)
            }
        case "activity.day.energy":
            if let day = model.activityDay.value ?? nil, let energy = day.activeEnergy {
                BodyDayCard(metric: .energy, series: energy, data: day)
            }
        case "activity.steps":
            BodyStepsCard(points: model.activity?.trends.value?["steps"] ?? [], days: BodyRange.days(dashboard.rangeDays), goal: dashboard.stepGoal)
                .accessibilityIdentifier("activity.steps")
        case "activity.workouts":
            BodyWorkoutsCard(read: model.activity?.workouts ?? .loading)
        default:
            if let spec = rows.spec(cell) {
                BodySpecCard(spec: spec, points: rows.points(spec.key))
            }
        }
    }

    /// A pair of cards (CardRow pair): stacked, one alone full width when the other is hidden.
    @ViewBuilder private func pair<Card: View>(_ cards: [String], @ViewBuilder card: @escaping (String) -> Card) -> some View {
        if cards.count == 2 {
            DuoPair { card(cards[0]) } second: { card(cards[1]) }
        } else if let only = cards.first {
            card(only)
        }
    }
}

/// "From your devices" and the day picker, which moves the shared date (the figure and your measurements stay today's).
private struct BodyDevicesHead: View {
    let summary: Summary
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        let nav = DayNav(today: summary.today,
                         date: Binding(get: { dashboard.date }, set: { d in Task { await dashboard.show(date: d) } }),
                         label: { Fmt.day($0, "EEEMMMdyyyy") })
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center) {
                title
                Spacer(minLength: 8)
                nav
            }
            VStack(alignment: .leading, spacing: 6) {
                title
                nav
            }
        }
        .padding(.top, 14)
    }

    private var title: some View {
        Text("From your devices").font(.app(size: 17, weight: .medium, relativeTo: .headline)).foregroundStyle(Palette.ink)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Every card on the page is hidden (AllHiddenNote).
private struct BodyAllHidden: View {
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("All the cards on this page are hidden. Choose the ones to show with Edit widgets on Home, or in your Profile.")
                .font(.app(.footnote)).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true)
            Button("Open your Profile") { dashboard.open(.profile) }
                .font(.app(.footnote, weight: .semibold)).foregroundStyle(Palette.accentText).buttonStyle(.plain).frame(minHeight: 44)
        }
        .card()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("body.allHidden")
    }
}

/// What the page shows for a tab, worked out once per draw: the rows (by their ids, the same in one column and in the
/// panes, so a fold keeps the place), the cards that show, and the tab's reads.
struct BodyRows {
    let now: Summary
    let tab: BodyTab
    /// The figure card shows: a perspective with a figure, and the card not hidden.
    let figure: Bool
    /// A device has sent anything (latestDataDate; a weigh-in typed in doesn't count).
    let devices: Bool
    let ids: [String]
    /// A tab's charts, in "trend.grid": the day's, the range's and Activity's workouts by their ids, the trends by key.
    let cells: [String]
    let measureCells: [String]
    let lastRow: [String]
    /// Entries can be added: the server has /body/* (an older one answers its catch-all 404).
    let canAdd: Bool
    let activityMode: BodyActivityMode
    let tabFailure: String?
    private let specs: [BodyTrendSpec]
    private let trends: Trends

    static func shown(_ ids: [String], _ shown: (String) -> Bool) -> [String] { ids.filter(shown) }

    @MainActor init(model: BodyModel, now: Summary, tab: BodyTab, dashboard: Dashboard) {
        let shown = dashboard.cardShown
        self.now = now
        self.tab = tab
        let perspective = Perspective.of(dashboard.status?.settings)
        figure = tab == .overview && perspective != .stats && shown("body.figure")
        devices = now.latestDataDate != nil
        if case .done(nil) = model.latest { canAdd = false } else { canAdd = true }
        var measures = shown("body.composition") ? BodyMetric.allCases.map(\.rawValue) : []
        if shown("body.story") { measures.append("story") }
        measureCells = measures
        // Glucose hides on a server without its sheet.
        var last = Self.shown(["body.workout", "body.glucose", "body.biomarkers"], shown)
        if case .done(nil)? = model.devices?.glucose { last.removeAll { $0 == "body.glucose" } }
        lastRow = last
        activityMode = BodyActivityMode.of(rangeDays: dashboard.rangeDays, available: model.dayAvailable, settled: model.daySettled)

        var ids: [String] = []
        var cells: [String] = []
        var specs: [BodyTrendSpec] = []
        var trends: Trends = [:]
        var failure: String?
        switch tab {
        case .overview:
            if !measures.isEmpty { ids.append("body.measures") }
            if devices, dashboard.summary != nil, BodyOverviewMath.deviceCards.contains(where: shown) {
                ids.append("body.devices.head")
                if !Self.shown(["body.rhr", "body.hrv", "body.strain", "body.recovery"], shown).isEmpty { ids.append("body.devices.1") }
                if !Self.shown(["body.heart", "body.metrics"], shown).isEmpty { ids.append("body.devices.2") }
                if !Self.shown(["body.energy", "body.steps"], shown).isEmpty { ids.append("body.devices.3") }
                if !last.isEmpty { ids.append("body.devices.4") }
            }
            if dashboard.status?.settings != nil, Cards.all.filter({ $0.page == .body }).allSatisfy({ !shown($0.id) }) { ids.append("body.hidden") }
        case .activity:
            switch activityMode {
            case .pending: ids = ["activity.pending"]
            case .day:
                let day = model.activityDay.value ?? nil
                if day?.steps != nil { cells.append("activity.day.steps") }
                if day?.activeEnergy != nil { cells.append("activity.day.energy") }
                if !cells.isEmpty { ids = ["trend.grid"] }
            case .range:
                let read = model.activity?.trends ?? .loading
                switch read {
                case .loading: ids = ["trend.loading"]
                case .failed(let words):
                    ids = ["trend.failed"]
                    failure = words
                case .done(let t):
                    trends = t
                    specs = [BodyTrendSpec.strain, BodyTrendSpec.activeEnergy, BodyTrendSpec.exercise]
                    specs = BodyTrendSpec.shown(specs, in: t)
                    cells = ["activity.steps"] + specs.map(\.key) + ["activity.workouts"]
                    ids = ["trend.grid"]
                }
            }
        default:
            switch model.tabTrends(tab, days: BodyRange.days(dashboard.rangeDays)) {
            case .loading: ids = ["trend.loading"]
            case .failed(let words):
                ids = ["trend.failed"]
                failure = words
            case .done(let t):
                trends = t
                specs = BodyTrendSpec.shown(BodyTrendSpec.specs(tab), in: t)
                cells = specs.map(\.key)
                ids = specs.isEmpty ? ["trend.empty"] : ["trend.grid"]
            }
        }
        self.ids = ids
        self.cells = cells
        self.specs = specs
        self.trends = trends
        tabFailure = failure
    }

    func spec(_ key: String) -> BodyTrendSpec? { specs.first { $0.key == key } }
    func points(_ key: String) -> [Point] { trends[key] ?? [] }
}
