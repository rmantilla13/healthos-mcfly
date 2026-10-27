import SwiftUI

/// The Vitals page, a tab (src/pages/Detail.tsx Vitals): your five signals as compact cards (Home's, from the summary
/// Home already loaded), each opening its metric's sheet, then "Your trends": a range of nightly readings, or one day
/// of heart rate by the hour once the server has hourly data. With nothing sent yet, only the cards, empty.
///
/// On the iPhone Duo (duo/design.md §7): one column on a phone, the outer display and Split View; the signals two to a
/// row on the inner display upright, a short last row staying short as the web's plain grid does, and the trends one to
/// a row, as the web's. Opened out sideways the whole page splits on the fold, so both sides carry it: the signals and
/// the trend charts two to a row, one each side, twice as many at once; the intro's and the trends' words on the
/// leading side with their controls on the trailing side.
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
    static let trendCards = "vitals.trend-cards"
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
            // One scroll view in every state, so a fold keeps the place and everything read (P14). Opened out sideways
            // it splits on the fold: each row's cards go one each side (the signals and the trends two to a row), the
            // headers' words on the leading side and their controls on the trailing side.
            DuoScroll {
                VStack(alignment: .leading, spacing: 14) {
                    VitalsIntro(count: dashboard.summary.map(VitalsWords.signalCount)).id(VitalsRows.intro)
                    rows(days: days)
                }
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

    /// Everything under the intro, one row each: the signals (one grid), then "Your trends" with its pickers, then the
    /// day's heart rate or the trend cards (one grid).
    @ViewBuilder private func rows(days: Int) -> some View {
        signals.id(VitalsRows.signals)
        if charted {
            trendsHead(days: days)
                .padding(.top, 4)
                .id(VitalsRows.trends)
            switch mode {
            case .day:
                if let d = day {
                    // Opened out: the hours on the leading side, what the other readings need on the trailing side.
                    DuoPair {
                        if let hr = d.heartRate {
                            VitalsDayCard(series: hr, data: d).dimmed(dayLoading, reduceMotion)
                        }
                    } second: {
                        Text(VitalsWords.dayFootnote)
                            .font(.app(.footnote))
                            .foregroundStyle(Palette.ink3)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 4)
                            .dimmed(dayLoading, reduceMotion)
                    }
                    .id(VitalsRows.day)
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
            // display upright and opened out (one each side of the fold); one on a phone.
            DuoGrid(VitalsSignals.all(s), id: \.id, loneSpans: false) { signal in
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
        return VitalsSplitRow {
            // Opened out: the heading (and the day picker) on the leading side, the range on the trailing side.
            VStack(alignment: .leading, spacing: 10) {
                heading
                if let d = dayNav { DayNav(today: d.today, date: $dayDate) }
            }
        } trailing: {
            RangeFilters(days: range, ranges: ranges)
        } whole: {
            ViewThatFits(in: .horizontal) {
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
            // One grid: one card to a row on a phone and upright (the web's), two opened out, one each side of the
            // fold. The iPhone's own cards come after the web's, each only with readings, so no cell is ever empty.
            DuoGrid(items, id: \.id, medium: 1, loneSpans: false) { item in
                trendCard(item, days: days, end: end).dimmed(trendsLoading, reduceMotion)
            }
            .id(VitalsRows.trendCards)
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
                TempDeviationCard(trends: history, days: days, end: end, units: dashboard.units)
            }
        case .bloodPressure:
            BloodPressureCard(systolic: t["blood_pressure_systolic"] ?? [], diastolic: t["blood_pressure_diastolic"] ?? [])
        case .glucose:
            TrendsGlucoseCard(points: t["glucose"] ?? [])
        case .breathing:
            BreathingDisturbancesCard(points: t["breathing_disturbances"] ?? [])
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
    /// Dimmed while what it shows is read again (the web's is-refreshing), without the fade under Reduce Motion.
    func dimmed(_ loading: Bool, _ reduceMotion: Bool) -> some View {
        opacity(loading ? 0.6 : 1).animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: loading)
    }
}

/// The page's intro (PageIntro): the title, how many signals have a reading, and "Manage sources ↗". Split on the fold,
/// the words keep to the leading side and the pill to the trailing side, so neither crosses it.
private struct VitalsIntro: View {
    let count: Int?

    var body: some View {
        VitalsSplitRow {
            PageIntro(VitalsWords.title, sub: VitalsWords.sub(count: count))
        } trailing: {
            ManageSourcesPill()
        } whole: {
            PageIntro(VitalsWords.title, sub: VitalsWords.sub(count: count)) { ManageSourcesPill() }
        }
    }
}

/// A header row: on a page split on the fold, its words on the leading side and its controls at the trailing side's
/// end, each wholly on its side; otherwise as `whole` lays it out. It reads the fold itself, being inside the scroll.
private struct VitalsSplitRow<Leading: View, Trailing: View, Whole: View>: View {
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing
    @ViewBuilder let whole: Whole
    @Environment(\.duoFold) private var fold

    var body: some View {
        if fold.splits {
            DuoPair {
                leading
            } second: {
                trailing.frame(maxWidth: .infinity, alignment: .trailing)
            }
        } else {
            whole
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
