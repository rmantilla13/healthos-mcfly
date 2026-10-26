import SwiftUI

/// A metric's detail sheet (src/components/MetricSheet.tsx, GET /api/metric/:key), shown over the app by the shell for
/// `dashboard.showMetric(_:section:page:range:date:)`: the metric over a day, week, month or year, the window's average,
/// three figures and one plain sentence the server builds from them, then "What this means" (a plain explainer and a
/// source to read on). The card's own page is one link away ("Open Vitals").
///
/// Opened on a window with nothing in it, it moves to its longest range and says so, since the card may show an older
/// reading; a metric never measured at all says "No measurement yet" instead, with no ranges to try. A server without
/// the sheet (an older Mac or LAN server) gets the same sheet built on the phone from its trends (MetricSheetFallback).
///
/// What it loads lives only here, in memory, and goes with the sheet: a sign-out closes it.
struct MetricSheetView: View {
    let request: MetricRequest
    @Environment(Dashboard.self) private var dashboard
    @State private var ranges: SheetRanges
    /// The last sheet that arrived, of any range: it stays up while another range loads (when `shows` says so).
    @State private var data: MetricSheetData?
    /// `data` is the answer for the range on screen as it is now, not a copy kept from before.
    @State private var current = false
    @State private var loading = false
    @State private var error: String?
    /// This sheet's answers by range, so going back to a range shows it at once; read again after a sync.
    @State private var answers: [MetricRange: MetricSheetData] = [:]
    @State private var answersFor = -1
    /// The server has no sheet for this metric: built on the phone from its trends from then on.
    @State private var onPhone = false
    @State private var source: WebPage?

    init(request: MetricRequest) {
        self.request = request
        _ranges = State(initialValue: SheetRanges(key: request.key, asked: request.range))
    }

    var body: some View {
        SheetScaffold(eyebrow: request.section, title: request.key.info.label) {
            MetricSheetContent(
                key: request.key, range: ranges.range, sheet: data, picked: ranges.picked, note: ranges.note(shown: shownSheet),
                loading: loading, error: error, openPage: openPage,
                pick: { ranges.pick($0) },
                manageConnections: { leave(for: .integrations) },
                open: { leave(for: request.page) },
                readMore: { source = WebPage(url: $0) })
        }
        .sheet(item: $source) { SafariView(url: $0.url).ignoresSafeArea() }
        .task(id: "\(ranges.range.rawValue)|\(dashboard.generation)") { await load(ranges.range) }
    }

    private var shownSheet: MetricSheetData? {
        guard let data, data.key == request.key, data.shows(asked: ranges.range, picked: ranges.picked) else { return nil }
        return data
    }

    /// "Open Vitals" names the card's page; not offered when that's the page under the sheet, where closing goes.
    private var openPage: String? {
        let name = SheetPage.name(request.page)
        return dashboard.pageOnScreen.map(SheetPage.name) == name ? nil : name
    }

    private func leave(for route: AppRoute) {
        dashboard.metricSheet = nil
        dashboard.open(route)
    }

    private func load(_ range: MetricRange) async {
        if answersFor != dashboard.generation {
            // New data since: every range is read again, and what's on screen stays up until it is.
            answers = [:]
            answersFor = dashboard.generation
        } else if let hit = answers[range] {
            data = hit
            current = true
            error = nil
            loading = false
            ranges.heard(hit, current: true)
            return
        }
        current = false
        loading = true
        error = nil
        do {
            let sheet = try await fetch(range)
            guard !Task.isCancelled, range == ranges.range else { return }
            answers[range] = sheet
            data = sheet
            current = true
            loading = false
            ranges.heard(sheet, current: true)
        } catch {
            guard !Task.isCancelled, !APIClient.isCancellation(error), range == ranges.range else { return }
            self.error = Self.message(error)
            loading = false
        }
    }

    private func fetch(_ range: MetricRange) async throws -> MetricSheetData {
        if !onPhone {
            let key = request.key, date = request.date
            if let sheet = try await dashboard.fetch({ try await $0.metricSheet(key, range: range, date: date) }) { return sheet }
            onPhone = true
        }
        return try await MetricSheetFallback.load(request.key, range: range, date: request.date, dashboard: dashboard)
    }

    /// The server's own words, as the web shows them after "Couldn't load this: ".
    static func message(_ error: Error) -> String {
        switch error as? APIError {
        case .server(_, let message)?: message.isEmpty ? SheetWords.somethingWrong : message
        case .misconfigured(let message)?, .network(let message)?: message
        case .signInRequired?: APIError.signInRequired.localizedDescription
        case nil: error is DecodingError ? SheetWords.somethingWrong : error.localizedDescription
        }
    }
}

/// The sheet's body for a state: its range buttons, the figures and chart (or why there are none), "What this means"
/// and the link to the card's page. Drawn from what it's given, so every state can be shown without a server.
struct MetricSheetContent: View {
    let key: MetricKey
    let range: MetricRange
    /// The last sheet that arrived, of any range.
    let sheet: MetricSheetData?
    let picked: Bool
    /// Why a range the person didn't press is the pressed one.
    let note: String?
    let loading: Bool
    let error: String?
    /// "Vitals", "Recovery on Body"; nil when the card's page is the one under the sheet.
    let openPage: String?
    var pick: (MetricRange) -> Void = { _ in }
    var manageConnections: () -> Void = {}
    var open: () -> Void = {}
    var readMore: (URL) -> Void = { _ in }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var own: MetricSheetData? { sheet?.key == key ? sheet : nil }
    private var shown: MetricSheetData? { own.flatMap { $0.shows(asked: range, picked: picked) ? $0 : nil } }
    /// Until the first answer it isn't known, so the ranges wait for it rather than showing and then going.
    private var never: Bool { own?.neverMeasured == true }
    private var measured: Bool { own != nil && !never }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if measured, let offered = own?.ranges, offered.count > 1 {
                SheetRangeButtons(ranges: offered, range: range, pick: pick)
                    .padding(.top, -6)
            }
            Group {
                if never {
                    NeverMeasured(key: key, manageConnections: manageConnections)
                } else if let shown {
                    SheetBody(sheet: shown, note: note)
                } else {
                    Text(error.map { SheetWords.couldNotLoad + $0 } ?? SheetWords.loading)
                        .font(.app(size: 14, relativeTo: .subheadline))
                        .foregroundStyle(Palette.ink2)
                        .padding(.vertical, 28)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .opacity(loading && shown != nil ? 0.6 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: loading)
            AboutMetric(info: key.info, readMore: readMore)
            // Only once there's something there.
            if measured, let openPage {
                Button(action: open) {
                    HStack(spacing: 4) {
                        Text("Open \(openPage)")
                        Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).accessibilityHidden(true)
                    }
                    .font(.app(size: 14, weight: .semibold, relativeTo: .subheadline))
                    .foregroundStyle(Palette.ink)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, -6)
            }
        }
        .padding(.top, -2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The range buttons (.filters.msheet-ranges): the ranges in a soft pill-shaped well, the chosen one raised on white.
/// At the largest text sizes they scroll sideways rather than break a label.
private struct SheetRangeButtons: View {
    let ranges: [MetricRange]
    let range: MetricRange
    let pick: (MetricRange) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row
            ScrollView(.horizontal, showsIndicators: false) { row }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Range")
    }

    private var row: some View {
        HStack(spacing: 0) {
            ForEach(ranges, id: \.self) { r in
                let on = r == range
                Button(r.label) { if !on { pick(r) } }
                    .buttonStyle(.plain)
                    .font(.app(size: 13, weight: .medium, relativeTo: .footnote))
                    .foregroundStyle(on ? Palette.ink : Palette.ink2)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background { if on { Capsule().fill(Palette.surface).tokenShadow(.pill, in: Capsule()) } }
                    .contentShape(Capsule())
                    .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Palette.surface2, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.border))
        .fixedSize()
    }
}

/// "No measurement yet.": never measured, so no ranges, source or chart.
private struct NeverMeasured: View {
    let key: MetricKey
    let manageConnections: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            Text(SheetWords.neverTitle).font(.app(size: 14, weight: .semibold, relativeTo: .subheadline))
            Text(SheetWords.neverText).font(.app(size: 13, relativeTo: .footnote))
            if SheetWords.ownEntries.contains(key) {
                Text(SheetWords.ownEntry).font(.app(size: 12, relativeTo: .caption)).foregroundStyle(Palette.ink3)
            }
            Button(action: manageConnections) {
                HStack(spacing: 7) {
                    Text(SheetWords.manageConnections)
                    Image(systemName: "arrow.up.right").imageScale(.small).accessibilityHidden(true)
                }
            }
            .buttonStyle(.quietPill(size: .compact))
            .padding(.top, 16)
        }
        .multilineTextAlignment(.center)
        .foregroundStyle(Palette.ink2)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
        .padding(.top, 34)
        .padding(.horizontal, 8)
        .padding(.bottom, 28)
    }
}

/// The window's figures and chart (SheetBody), or why there are none, then the server's sentence.
private struct SheetBody: View {
    let sheet: MetricSheetData
    let note: String?
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let format = SheetFormat(sheet)
        VStack(alignment: .leading, spacing: 14) {
            if let note {
                Text(note).font(.app(size: 13, relativeTo: .footnote)).foregroundStyle(Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .onAppear { AccessibilityNotification.Announcement(note).post() }
            }
            let line = sheet.sourceLine
            if !line.isEmpty {
                Text(line).font(.app(size: 12, relativeTo: .caption)).foregroundStyle(Palette.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if sheet.nothingToShow {
                Text(sheet.emptyMessage)
                    .font(.app(size: 14, relativeTo: .subheadline))
                    .foregroundStyle(Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 28)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 10) {
                        Headline(sheet: sheet, format: format)
                        Spacer(minLength: 0)
                        if let status = sheet.status { StatusPill(status: status) }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Headline(sheet: sheet, format: format)
                        if let status = sheet.status { StatusPill(status: status) }
                    }
                }
                SheetChart(sheet: sheet)
                if !sheet.tiles.isEmpty { Tiles(sheet: sheet, format: format, oneColumn: typeSize.isAccessibilitySize) }
            }
            if let narrative = sheet.narrative {
                SheetInsight(text: narrative)
            }
        }
    }
}

/// The big number with its label over it and its note under it (.msheet-figure-main); glucose in mmol/L too.
private struct Headline: View {
    let sheet: MetricSheetData
    let format: SheetFormat

    var body: some View {
        let h = sheet.headline
        let big = format.big(h)
        VStack(alignment: .leading, spacing: 4) {
            Text(h.label).font(.app(size: 12, weight: .medium, relativeTo: .caption)).foregroundStyle(Palette.ink2)
            HStack(alignment: .firstTextBaseline, spacing: big.unit == "%" ? 0 : 4) {
                Text(big.value)
                    .font(.app(size: 40, weight: .medium, relativeTo: .largeTitle))
                    .tracking(-1.2)
                    .foregroundStyle(h.value == nil ? Palette.ink3 : Palette.ink)
                if let unit = big.unit {
                    Text(unit).font(.app(size: 15, relativeTo: .subheadline)).foregroundStyle(Palette.ink2)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            if sheet.key == .glucose, let v = h.value {
                Text("\(SheetFormat.number(Glucose.mmol(fromMgDl: v), 1)) mmol/L").font(.app(size: 12, relativeTo: .caption)).foregroundStyle(Palette.ink2)
            }
            if let note = h.note {
                Text(note).font(.app(size: 12, relativeTo: .caption)).foregroundStyle(Palette.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(h.label)
        .accessibilityValue([h.value.map { _ in format.tile(h) } ?? "No data",
                             sheet.key == .glucose ? h.value.map { "\(SheetFormat.number(Glucose.mmol(fromMgDl: $0), 1)) mmol/L" } : nil,
                             h.note].compactMap { $0 }.joined(separator: ", "))
    }
}

/// The sheet's soft white chip (--chip on .msheet-panel), solid with Reduce Transparency.
private struct ChipFill: ShapeStyle {
    /// White in light mode, the raised surface in dark.
    static let solid = Themed(ColorToken.surface.value.light, ColorToken.surfaceHover.value.dark).color

    func resolve(in environment: EnvironmentValues) -> Color {
        environment.accessibilityReduceTransparency ? Self.solid : Palette.chip
    }
}

/// Where the latest reading sits, in the card's words (.pill.msheet-status).
private struct StatusPill: View {
    let status: MetricStatus

    var body: some View {
        // One line, as the web's; at the largest text sizes it wraps rather than cut its words.
        Text(status.text)
            .font(.app(size: 13, weight: .medium, relativeTo: .footnote))
            .foregroundStyle(Palette.ink)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .frame(minHeight: 34)
            .background(ChipFill(), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            .tokenShadow(.pill, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            .accessibilityLabel(status.text + SheetWords.latestReading)
    }
}

/// Lowest, highest and latest (.msheet-tiles): three across, one under another at the largest text sizes.
private struct Tiles: View {
    let sheet: MetricSheetData
    let format: SheetFormat
    let oneColumn: Bool

    var body: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 6, alignment: .top), count: oneColumn ? 1 : 3)
        LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(Array(sheet.tiles.enumerated()), id: \.offset) { _, tile in
                let small = [tile.date.map { Fmt.day($0, sheet.range == .year ? "MMMdyyyy" : "MMMd") }, tile.note].compactMap { $0 }.joined(separator: " · ")
                VStack(alignment: .leading, spacing: 3) {
                    Text(tile.label).font(.app(size: 12, relativeTo: .caption)).foregroundStyle(Palette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(format.tile(tile))
                        .font(.app(size: 15, weight: .semibold, relativeTo: .subheadline))
                        .foregroundStyle(tile.value == nil ? Palette.ink3 : Palette.ink)
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)
                    // A space keeps the tiles one height when one has no date.
                    Text(small.isEmpty ? " " : small).font(.app(size: 11, relativeTo: .caption2)).foregroundStyle(Palette.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, 9)
                .padding(.vertical, 8)
                .background(ChipFill(), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(tile.label)
                .accessibilityValue([tile.value == nil ? "No data" : format.tile(tile), small.isEmpty ? nil : small].compactMap { $0 }.joined(separator: ", "))
            }
        }
    }
}

/// The server's sentence about the figures (.msheet-insight), beside the spark.
private struct SheetInsight: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Palette.ink2)
                .frame(width: 28, height: 28)
                .background(Palette.surface, in: Circle())
                .accessibilityHidden(true)
            Text(text)
                .font(.app(size: 14, relativeTo: .subheadline))
                .lineSpacing(3)
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(ChipFill(), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.cardEdge))
        .accessibilityElement(children: .combine)
    }
}

/// "What this means" (About), under a hairline: the metric in one plain sentence, what to keep in mind about it, and a
/// reputable page to read on, opened in the app's browser.
private struct AboutMetric: View {
    let info: MetricInfo
    let readMore: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Eyebrow(SheetWords.understandYour + info.label)
            Text(SheetWords.whatThisMeans)
                .font(.app(size: 20, weight: .medium, relativeTo: .title3))
                .tracking(-0.2)
                .foregroundStyle(Palette.ink)
                .padding(.vertical, 4)
                .accessibilityAddTraits(.isHeader)
            Text(info.about.what).font(.app(size: 14, relativeTo: .subheadline)).foregroundStyle(Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Text(info.about.caveat).font(.app(size: 12, relativeTo: .caption)).foregroundStyle(Palette.ink3)
                .fixedSize(horizontal: false, vertical: true)
            Button { readMore(info.about.sourceURL) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(info.about.sourceLabel).underline().multilineTextAlignment(.leading)
                    Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold)).accessibilityHidden(true)
                }
                .font(.app(size: 12, relativeTo: .caption))
                .foregroundStyle(Palette.accentText)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
            .accessibilityHint("Opens the page in a browser")
        }
        .padding(.top, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(Palette.border).frame(height: 1) }
    }
}
