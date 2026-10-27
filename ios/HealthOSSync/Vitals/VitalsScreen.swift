import SwiftUI

/// The Vitals page, a tab (src/pages/Detail.tsx Vitals): your five signals as compact cards (Home's, from the summary
/// Home already loaded), each opening its metric's sheet, then "Your trends": a range of nightly readings, or one day
/// of heart rate by the hour once the server has hourly data. With nothing sent yet, only the cards, empty.
///
/// On the iPhone Duo (duo/design.md §7, decisions.md Q5): one column on a phone, the outer display and Split View; the
/// signals two to a row on the inner display upright, a short last row staying short as the web's plain grid does, and
/// the trends one to a row, as the web's. Opened out sideways, the page's lead stays put on the leading side (the intro
/// and the five signals, two to a row) while "Your trends" scrolls on the trailing side, its charts each across it.
struct VitalsScreen: View {
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        PhaseGate {
            // One person's, on one server: someone else signing in, or another server, starts the page anew, so
            // nothing read for the last person (their day, their trends) is ever on screen for the next.
            VitalsPage().id(identity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.page)
    }

    private var identity: String {
        Self.identity(server: Config.serverURL(), user: dashboard.status?.user?.id ?? dashboard.account?.id)
    }

    /// Whose page this is: the server and the person.
    static func identity(server: URL?, user: String?) -> String { "\(server?.absoluteString ?? "")|\(user ?? "")" }
}

/// The trends read for one range: the web's metrics and the iPhone's own, and temperatures from 30 days earlier for
/// the nightly temperature card.
private struct VitalsTrendsData {
    let trends: Trends
    let tempHistory: Trends?
}

/// The page's rows' ids (a grid is one row).
enum VitalsRows {
    static let intro = "vitals.intro"
    static let signals = "vitals.signals"
    static let trends = "vitals.trends"
    static let day = "vitals.day"
    static let dayNote = "vitals.day.note"
    static let message = "vitals.trends.message"
    /// One trend card's row: the same id in the one column and in the trailing pane, so a fold hands it over.
    static func trend(_ id: String) -> String { "vitals.trend.\(id)" }
}

/// The page. Everything that must outlive a fold lives here, above `DuoPage`: the day picked, what was read, and the
/// loaders and pull to refresh (P4). Opening out sideways swaps the one column for two panes and rebuilds what's in
/// them; nothing is read again for it.
private struct VitalsPage: View {
    @Environment(Dashboard.self) private var dashboard
    @Environment(\.vitalsReads) private var reads
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The day the Day view shows; nil is today.
    @State private var dayDate: String?
    /// GET /day?metrics=heart_rate for that day: nil before it answers, and after an older server or a failure.
    @State private var day: DayData?
    /// The day's read has answered (or failed) at least once, so Day isn't waited for any more.
    @State private var daySettled = false
    @State private var dayLoading = false

    /// The range on screen, kept while another is read (dimmed, as the web's is-refreshing).
    @State private var shown: VitalsTrendsData?
    @State private var trendsLoading = false
    @State private var trendsError: String?

    private var summaryFailure: String? {
        guard dashboard.summary == nil, case .unavailable(let message) = dashboard.phase else { return nil }
        return message
    }

    private var mode: VitalsMode {
        VitalsMode.of(range: dashboard.rangeDays, available: day?.heartRate != nil, settled: daySettled)
    }

    private var charted: Bool { VitalsMode.charted(summary: dashboard.summary, summaryFailed: summaryFailure != nil) }

    var body: some View {
        let days = VitalsMode.days(dashboard.rangeDays)
        // What each read is for, worked out here and handed to its task: a task replaced before it began still runs,
        // and reading the state then would read for the new key as well as the task that replaced it.
        let wantedRange: Int? = charted && mode == .range ? days : nil
        let date = dayDate
        DuoPage { _ in
            // Opened out (Q5): the lead (the intro and the signals) on the leading side, still; "Your trends" on the
            // trailing side, scrolling, each chart across it. Otherwise one column. Each a flat stack of rows by id,
            // so a fold hands over the row at the top (the trends are the anchor).
            DuoPanes(anchor: .secondary) {
                // No foot padding beyond the pane's own: the lead is kept to the pane's height, which stays put.
                VStack(alignment: .leading, spacing: 14) { lead }
                    .padding(.top, 16)
                    .padding(.bottom, 4)
            } secondary: {
                VStack(alignment: .leading, spacing: 14) { trends(days: days) }
                    .scrollTargetLayout()
                    .padding(.vertical, 16)
            } single: {
                VStack(alignment: .leading, spacing: 14) {
                    lead
                    trends(days: days)
                }
                .scrollTargetLayout()
                .padding(.vertical, 16)
            }
        }
        .refreshable { await dashboard.load() }
        // Whether this day has heart rate by the hour decides the Day view; read whatever the range, as the web does.
        .task(id: "\(date ?? "today")|\(dashboard.generation)") {
            guard !Task.isCancelled else { return }
            await loadDay(date)
        }
        .task(id: "\(wantedRange ?? 0)|\(dashboard.generation)") {
            guard let wantedRange, !Task.isCancelled else { return }
            await loadTrends(days: wantedRange)
        }
    }

    /// The page's lead: the intro, then the signals (one grid).
    private var lead: some View {
        VitalsLead(count: dashboard.summary.map(VitalsWords.signalCount), hasSignals: dashboard.summary != nil) { signals }
    }

    /// "Your trends" with its pickers, then the day's heart rate and its footnote, or the trend cards, one row each.
    @ViewBuilder private func trends(days: Int) -> some View {
        if charted {
            trendsHead(days: days)
                .padding(.top, 4)
                .id(VitalsRows.trends)
            switch mode {
            case .day:
                if let d = day, let hr = d.heartRate {
                    VitalsDayCard(series: hr, data: d).dimmed(dayLoading, reduceMotion)
                        .id(VitalsRows.day)
                    Text(VitalsWords.dayFootnote)
                        .font(.app(.footnote))
                        .foregroundStyle(Palette.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                        .dimmed(dayLoading, reduceMotion)
                        .id(VitalsRows.dayNote)
                }
            case .range:
                rangeRows(days: days)
            case .pending:
                EmptyView()
            }
        }
    }

    @ViewBuilder private var signals: some View {
        if let s = dashboard.summary {
            // A plain grid: a short last row stays short, as the web's .vitals-signals does. Two to a row on the inner
            // display upright and in the open Duo's leading pane; one on a phone.
            DuoGrid(VitalsSignals.all(s), id: \.id, paneColumns: 2, loneSpans: false) { signal in
                SignalCard(signal: signal, date: s.date, variant: .compact)
            }
        } else if let failure = summaryFailure {
            message(VitalsWords.summaryFailed(failure))
        } else {
            ProgressView().frame(maxWidth: .infinity, minHeight: 120)
        }
    }

    // MARK: Your trends

    private func trendsHead(days: Int) -> some View {
        let range = Binding(get: { mode == .range ? days : ChartRange.day.days }, set: { dashboard.rangeDays = $0 })
        let ranges = VitalsMode.ranges(dayAvailable: day?.heartRate != nil)
        let dayNav = mode == .day ? day : nil
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 16) {
                heading
                Spacer(minLength: 0)
                tools(range: range, ranges: ranges, dayNav: dayNav)
            }
            VStack(alignment: .leading, spacing: 10) {
                heading
                // With the day picker beside it the tools wrap at the leading edge, as the web's do; the range
                // alone keeps to the trailing side.
                tools(range: range, ranges: ranges, dayNav: dayNav)
                    .frame(maxWidth: .infinity, alignment: dayNav != nil ? .leading : .trailing)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("vitals-trends")
    }

    private var heading: some View {
        Text(VitalsWords.trends)
            .font(.app(size: 17, weight: .medium, relativeTo: .headline))
            .tracking(-0.17)
            .foregroundStyle(Palette.ink)
            .accessibilityAddTraits(.isHeader)
    }

    /// The day picker (in the Day view) and the range picker; the range shows Day as chosen while the Day view is on.
    private func tools(range: Binding<Int>, ranges: [ChartRange], dayNav: DayData?) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                if let d = dayNav { DayNav(today: d.today, date: $dayDate) }
                RangeFilters(days: range, ranges: ranges)
            }
            VStack(alignment: .leading, spacing: 8) {
                if let d = dayNav { DayNav(today: d.today, date: $dayDate) }
                RangeFilters(days: range, ranges: ranges)
            }
        }
    }

    @ViewBuilder private func rangeRows(days: Int) -> some View {
        if let shown {
            let units = dashboard.units
            let end = dashboard.summary?.today ?? Day.today()
            let items = VitalsTrendCards.items(shown.trends, history: shown.tempHistory, days: days, end: end,
                                               status: dashboard.status, units: units)
            // One card to a row everywhere (the web's grid is one column below 1080 pt), each its own row; the
            // iPhone's own cards come after the web's, each only with readings.
            ForEach(items, id: \.id) { item in
                trendCard(item, days: days, end: end).dimmed(trendsLoading, reduceMotion)
                    .id(VitalsRows.trend(item.id))
            }
        } else if let trendsError {
            message(VitalsWords.trendsFailed(trendsError)).id(VitalsRows.message)
        } else {
            ProgressView().frame(maxWidth: .infinity, minHeight: 200).id(VitalsRows.message)
        }
    }

    @ViewBuilder private func trendCard(_ item: VitalsTrendItem, days: Int, end: String) -> some View {
        let t = shown?.trends ?? [:]
        switch item {
        case .trend(let trend):
            VitalsTrendCard(trend: trend)
        case .tempDeviation:
            if let history = shown?.tempHistory {
                TempDeviationCard(trends: history, days: days, end: end, units: dashboard.units).phoneCard(item)
            }
        case .bloodPressure:
            BloodPressureCard(systolic: t["blood_pressure_systolic"] ?? [], diastolic: t["blood_pressure_diastolic"] ?? [])
                .phoneCard(item)
        case .glucose:
            TrendsGlucoseCard(points: t["glucose"] ?? []).phoneCard(item)
        case .breathing:
            BreathingDisturbancesCard(points: t["breathing_disturbances"] ?? []).phoneCard(item)
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.app(.footnote))
            .foregroundStyle(Palette.ink3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 24)
    }

    // MARK: Reads

    /// One day of heart rate by the hour. Its answer is this person's only: one that lands after a sign-out, someone
    /// else's sign-in or another server is dropped (fetchForThisSession).
    private func loadDay(_ date: String?) async {
        dayLoading = true
        defer { dayLoading = false }
        do {
            let answer = try await reads.readDay(dashboard, date)
            guard !Task.isCancelled else { return }
            // nil: an older server without GET /day, so no Day view.
            day = answer
            daySettled = true
        } catch is CancellationError {
            // Another day was picked, a new load started, or the answer is someone else's now.
        } catch {
            guard !Task.isCancelled else { return }
            // Offline or a server error: the ranges, as the web falls back; never "not on this server".
            day = nil
            daySettled = true
        }
    }

    private func loadTrends(days: Int) async {
        trendsLoading = true
        defer { trendsLoading = false }
        let generation = dashboard.generation
        do {
            async let t = reads.readTrends(dashboard, VitalsTrendCards.metrics + VitalsTrendCards.phoneMetrics, days)
            // The nightly temperature card's own read: without it, that card just doesn't show.
            async let h: Trends? = try? await reads.readTrends(dashboard, TempDeviationCard.metrics, days + 30)
            let data = VitalsTrendsData(trends: try await t, tempHistory: await h)
            guard !Task.isCancelled, generation == dashboard.generation else { return }
            shown = data
            trendsError = nil
        } catch is CancellationError {
            // Replaced by a newer read, or the answer is someone else's now: not a failure.
        } catch {
            guard !Task.isCancelled else { return }
            trendsError = error.localizedDescription
            // A failed range shows its failure, not the last range's cards under the new range's name.
            shown = nil
        }
    }
}

private extension View {
    /// One of the iPhone's own trend cards, named as the web's are (vitals-trend-<id>).
    func phoneCard(_ item: VitalsTrendItem) -> some View {
        accessibilityElement(children: .contain).accessibilityIdentifier("vitals-trend-\(item.id)")
    }

    /// Dimmed while what it shows is read again (the web's is-refreshing), without the fade under Reduce Motion.
    func dimmed(_ loading: Bool, _ reduceMotion: Bool) -> some View {
        opacity(loading ? 0.6 : 1).animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: loading)
    }
}

/// The page's lead: its intro (PageIntro: the title, how many signals have a reading, and "Manage sources ↗"), then the
/// signals. In the open Duo's leading pane, which stays put, "Manage sources" moves from under the words into the cell
/// the fifth signal leaves empty beside it, so the lead fits the pane's height; it reads the pane itself, being in it.
private struct VitalsLead<Signals: View>: View {
    let count: Int?
    let hasSignals: Bool
    @ViewBuilder let signals: Signals
    @Environment(\.duoInPane) private var inPane
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // Two to a row in the pane short of the accessibility sizes (DuoGrid's paneColumns), so the fifth's row has room.
        if inPane, hasSignals, !typeSize.isAccessibilitySize {
            PageIntro(VitalsWords.title, sub: VitalsWords.sub(count: count)) { EmptyView() }
                .id(VitalsRows.intro)
            signals
                .overlay(alignment: .bottomTrailing) { ManageSourcesPill().padding(.bottom, 8) }
                .id(VitalsRows.signals)
        } else {
            PageIntro(VitalsWords.title, sub: VitalsWords.sub(count: count)) { ManageSourcesPill() }
                .id(VitalsRows.intro)
            signals.id(VitalsRows.signals)
        }
    }
}

/// "Manage sources ↗" (ManageSources in PageIntro.tsx): a quiet pill to Integrations.
private struct ManageSourcesPill: View {
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        Button { dashboard.open(.integrations) } label: {
            HStack(spacing: 5) {
                Text("Manage sources")
                Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .semibold)).accessibilityHidden(true)
            }
        }
        .buttonStyle(.quietPill)
        .accessibilityHint("Opens Integrations")
        .accessibilityIdentifier("vitals-manage-sources")
    }
}
