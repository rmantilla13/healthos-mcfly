import SwiftUI
import XCTest
@testable import HealthOSSync

/// A metric's detail sheet (MetricSheet/): the bundled metric table and words against the web's own files
/// (shared/metrics.ts, src/components/MetricSheet.tsx, server/metricsheet.ts), the web's rules for an empty window
/// (test/metricsheet.test.ts, case for case), the range it shows, decoding a local demo server's answers
/// (Fixtures/metric-*.json) and an older server's, and the sheet built on the phone for a server without one.
@MainActor
final class MetricSheetTests: XCTestCase {
    /// A file of the web app, next to the iPhone app in the repository.
    private func web(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(path)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { throw XCTSkip("\(path) isn't next to the app") }
        return text
    }

    private func fixture(_ name: String) throws -> MetricSheetData {
        let url = Bundle(for: Self.self).url(forResource: name, withExtension: "json")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name).json")
        let data = try XCTUnwrap(try? Data(contentsOf: url), "missing fixture \(name).json")
        return try JSONDecoder().decode(MetricSheetData.self, from: data)
    }

    private func decode(_ json: String) throws -> MetricSheetData {
        try JSONDecoder().decode(MetricSheetData.self, from: Data(json.utf8))
    }

    private func sheet(_ key: MetricKey = .weight, range: MetricRange, ranges: [MetricRange] = [.week, .month, .year], value: Double? = nil,
                       points: [Point] = [], partialToday: Bool = false, to: String = "2026-10-22", latest: Point? = nil,
                       everMeasured: Bool? = nil) -> MetricSheetData {
        MetricSheetData(key: key, range: range, ranges: ranges, from: to, to: to, points: points, partialToday: partialToday,
                        headline: MetricFigure(label: "Average", value: value, unit: "kg"), latest: latest, everMeasured: everMeasured)
    }

    // MARK: - The web's files

    /// A JavaScript string literal at the start of `text` ('…', "…" or `…` with ${NAME} filled in from `constants`).
    private func literal(_ text: Substring, constants: [String: String]) -> String? {
        guard let quote = text.first, "'\"`".contains(quote) else { return nil }
        var out = ""
        var i = text.index(after: text.startIndex)
        while i < text.endIndex {
            let c = text[i]
            if c == "\\" {
                i = text.index(after: i)
                if i < text.endIndex { out.append(text[i]) }
            } else if c == quote {
                return out
            } else if quote == "`", c == "$", text[text.index(after: i)...].hasPrefix("{") {
                let start = text.index(i, offsetBy: 2)
                guard let end = text[start...].firstIndex(of: "}") else { return nil }
                guard let value = constants[String(text[start..<end])] else { return nil }
                out += value
                i = end
            } else {
                out.append(c)
            }
            i = text.index(after: i)
        }
        return nil
    }

    /// The literal after `field:` in a block of TypeScript.
    private func field(_ name: String, in block: Substring, constants: [String: String] = [:]) -> String? {
        guard let r = block.range(of: "\(name): ") else { return nil }
        return literal(block[r.upperBound...], constants: constants)
    }

    /// The text of `const NAME = …` or `export const NAME… = {` through its closing `};` at the line's start.
    private func block(_ start: String, in text: String) throws -> Substring {
        let from = try XCTUnwrap(text.range(of: start), "\(start) not found")
        let end = try XCTUnwrap(text.range(of: "\n};", range: from.upperBound..<text.endIndex), "\(start) has no end")
        return text[from.upperBound..<end.lowerBound]
    }

    /// Each two-space-indented `key: {` block of an object.
    private func entries(_ object: Substring) -> [(key: String, body: Substring)] {
        let lines = object.components(separatedBy: "\n")
        var out: [(String, [String])] = []
        for line in lines {
            if line.hasPrefix("  "), !line.hasPrefix("   "), let colon = line.firstIndex(of: ":") {
                out.append((String(line[line.index(line.startIndex, offsetBy: 2)..<colon]), [line]))
            } else if !out.isEmpty {
                out[out.count - 1].1.append(line)
            }
        }
        return out.map { ($0.0, Substring($0.1.joined(separator: "\n"))) }
    }

    func testTheBundledMetricsAreTheWebsOwn() throws {
        let ts = try web("shared/metrics.ts")
        // The constants the table is written with.
        var constants: [String: String] = [:]
        for name in ["WEARABLE", "SCORE"] {
            let r = try XCTUnwrap(ts.range(of: "const \(name) = "))
            constants[name] = try XCTUnwrap(literal(ts[r.upperBound...], constants: [:]))
        }
        var sources: [String: (label: String, href: String)] = [:]
        for name in ["CLEVELAND_HR", "MUSCLE_FAT"] {
            let r = try XCTUnwrap(ts.range(of: "const \(name) = "))
            let line = ts[r.upperBound...].prefix { $0 != "\n" }
            sources[name] = (try XCTUnwrap(field("label", in: line)), try XCTUnwrap(field("href", in: line)))
        }
        let ranges: [String: [MetricRange]] = ["ALL": [.week, .month, .year], "WITH_DAY": [.day, .week, .month, .year], "['day']": [.day]]

        let table = entries(try block("export const METRIC_INFO: Record<MetricKey, MetricInfo> = {", in: ts))
        XCTAssertEqual(table.map(\.key), MetricKey.allCases.map(\.rawValue), "every metric, in the web's order (METRIC_KEYS)")
        for (name, body) in table {
            let key = try XCTUnwrap(MetricKey(rawValue: name), name)
            let info = key.info
            XCTAssertEqual(info.label, field("label", in: body), name)
            XCTAssertEqual(info.unit, field("unit", in: body), name)
            XCTAssertTrue(body.contains("digits: \(info.digits),"), "\(name) digits")
            XCTAssertEqual(info.duration, body.contains("duration: true"), "\(name) duration")
            XCTAssertEqual(info.chart.rawValue, field("chart", in: body), name)
            XCTAssertEqual(info.initial.rawValue, field("initial", in: body), name)
            let r = try XCTUnwrap(body.range(of: "ranges: "))
            let after = body[r.upperBound...]
            let written = after.hasPrefix("['day']") ? "['day']" : String(after.prefix { $0 != "," && $0 != "\n" })
            XCTAssertEqual(info.ranges, try XCTUnwrap(ranges[written], "\(name) ranges: \(written)"), "\(name) ranges")
            let about = try XCTUnwrap(body.range(of: "about: {")).upperBound
            XCTAssertEqual(info.about.what, field("what", in: body[about...], constants: constants), "\(name) what")
            XCTAssertEqual(info.about.caveat, field("caveat", in: body[about...], constants: constants), "\(name) caveat")
            let source = try XCTUnwrap(body[about...].range(of: "source: "))
            let rest = body[source.upperBound...]
            if let named = sources.first(where: { rest.hasPrefix($0.key) }) {
                XCTAssertEqual(info.about.sourceLabel, named.value.label, name)
                XCTAssertEqual(info.about.sourceURL.absoluteString, named.value.href, name)
            } else {
                XCTAssertEqual(info.about.sourceLabel, field("label", in: rest), name)
                XCTAssertEqual(info.about.sourceURL.absoluteString, field("href", in: rest), name)
            }
        }
        // The union type names the same metrics.
        let union = ts[try XCTUnwrap(ts.range(of: "export type MetricKey =")).upperBound...].prefix { $0 != ";" }
        XCTAssertEqual(Set(union.components(separatedBy: "'").enumerated().filter { $0.offset % 2 == 1 }.map(\.element)), Set(MetricKey.allCases.map(\.rawValue)))
        XCTAssertTrue(ts.contains("export const MG_DL_PER_MMOL_L = \(Glucose.mgDlPerMmolL);"))
    }

    func testTheRangesAreTheWebsOwn() throws {
        let ts = try web("shared/metrics.ts")
        for r in MetricRange.allCases {
            XCTAssertTrue(ts.contains("\(r.rawValue): '\(r.label)'"), "RANGE_LABEL \(r)")
            if let days = r.days { XCTAssertTrue(ts.contains("\(r.rawValue): \(days)"), "RANGE_DAYS \(r)") }
            if let window = r.window { XCTAssertTrue(ts.contains("\(r.rawValue): '\(window)'"), "RANGE_WINDOW \(r)") }
        }
        XCTAssertTrue(ts.contains("export type MetricRange = 'day' | 'week' | 'month' | 'year';"))
    }

    func testTheSheetsWordsAreTheWebsOwn() throws {
        let tsx = try web("src/components/MetricSheet.tsx")
        // SOURCE, DAY_NOTE, EMPTY and OWN_ENTRIES, entry by entry.
        let source = try XCTUnwrap(tsx.range(of: "const SOURCE: Record<string, string> = { "))
        let pairs = tsx[source.upperBound...].prefix { $0 != "}" }.components(separatedBy: ", ")
        var parsed: [String: String] = [:]
        for pair in pairs {
            let parts = pair.components(separatedBy: ": ")
            parsed[parts[0]] = literal(Substring(parts[1]), constants: [:])
        }
        XCTAssertEqual(parsed, SheetWords.sources)
        let ownEntry = try XCTUnwrap(literal(tsx[try XCTUnwrap(tsx.range(of: "const OWN_ENTRY = ")).upperBound...], constants: [:]))
        XCTAssertEqual(ownEntry, SheetWords.ownEntry)
        for (name, words) in [("const DAY_NOTE: Partial<Record<MetricKey, string>> = {", SheetWords.dayNotes),
                              ("const EMPTY: Partial<Record<MetricKey, string>> = {", SheetWords.empty)] {
            var found: [MetricKey: String] = [:]
            for (key, body) in entries(try block(name, in: tsx)) {
                let value = body.drop { $0 != ":" }.dropFirst(2)
                found[try XCTUnwrap(MetricKey(rawValue: key), key)] = value.hasPrefix("OWN_ENTRY") ? ownEntry : literal(value, constants: [:])
            }
            XCTAssertEqual(found, words, name)
        }
        let own = tsx[try XCTUnwrap(tsx.range(of: "const OWN_ENTRIES = new Set<MetricKey>([")).upperBound...].prefix { $0 != "]" }
        XCTAssertEqual(Set(own.components(separatedBy: "'").enumerated().filter { $0.offset % 2 == 1 }.compactMap { MetricKey(rawValue: $0.element) }), SheetWords.ownEntries)
        // The sheet's sentences, as it writes them.
        let charts = try web("src/charts/Charts.tsx")
        for words in [SheetWords.neverTitle, SheetWords.neverText, SheetWords.manageConnections, SheetWords.noHours, SheetWords.nothingRecorded,
                      SheetWords.loading, SheetWords.couldNotLoad, SheetWords.whatThisMeans, SheetWords.understandYour, SheetWords.byTheHourRunning,
                      "'\(SheetWords.byTheHour)'", SheetWords.typicalNote, SheetWords.weekly, SheetWords.eachNight, SheetWords.eachDay,
                      SheetWords.todaySoFar, SheetWords.latestReading, "SDNN, from Apple Watch", "RMSSD, measured during sleep",
                      ", and added by you", "Week of ", "', weekly averages'", "Open {pageName(to)}", "Median", "Goal "] {
            XCTAssertTrue(tsx.contains(words) || charts.contains(words), words)
        }
        XCTAssertTrue(try web("src/lib.ts").contains(SheetWords.somethingWrong))
        // The figures the phone builds for a server without the sheet are labelled as the server labels them.
        let server = try web("server/metricsheet.ts")
        for words in ["'Lowest day'", "'Highest day'", "'Daily average'", "'Average a night'", "'Average'", "perDay: 'daily average'",
                      "days with data", "; today isn't counted until it's over", "'so far today'", "'So far today'", "'Whole day'",
                      "'Latest hour'", "'Last hour with a reading'", "'Today'", "'That day'"] {
            XCTAssertTrue(server.contains(words), words)
        }
        XCTAssertTrue(server.contains("error: 'Unknown metric'"), "an older server's 404 for a metric it has no sheet for")
    }

    // MARK: - The web's rules (test/metricsheet.test.ts)

    func testAnEmptyWindowMovesToTheLongestRangeOnceAndSaysSo() {
        let ranges: [MetricRange] = [.week, .month, .year]
        XCTAssertEqual(sheet(range: .month).widerRange, .year)
        XCTAssertEqual(sheet(range: .week).widerRange, .year)
        XCTAssertNil(sheet(range: .year).widerRange, "already the longest")
        XCTAssertNil(sheet(range: .month, value: 72).widerRange, "a window with data stays")
        XCTAssertNil(sheet(range: .day, ranges: [.day] + ranges).widerRange, "a Day says why it is empty")
        // Only today's unfinished total: drawn, not counted, so the window isn't empty and isn't called so.
        let today = [Point(date: "2026-10-22", value: 1200)]
        XCTAssertNil(sheet(range: .week, points: today).widerRange)
        XCTAssertNil(sheet(range: .week, points: today).emptyWindowText)
        XCTAssertEqual(sheet(range: .month).emptyWindowText, "Nothing in the last 30 days. Year shows the last 12 months.")
        XCTAssertNil(sheet(range: .year).emptyWindowText)
        XCTAssertNil(sheet(range: .day, ranges: [.day] + ranges).emptyWindowText)
        XCTAssertEqual(MetricSheetData.widenedNote(from: .month, to: .year), "Nothing in the last 30 days, so this shows the last 12 months.")
        XCTAssertNil(MetricSheetData.widenedNote(from: .day, to: .week))
        // Never measured: it says so at once, on its own range.
        XCTAssertNil(sheet(range: .month, everMeasured: false).widerRange)
        XCTAssertTrue(sheet(range: .month, everMeasured: false).shows(asked: .month, picked: false))
    }

    func testTheNoteThatASheetMovedHoldsOnlyWhileTheLongerRangeBearsItOut() {
        // A month ending Oct 22 starts on Sep 23.
        let year = { (date: String?) in self.sheet(range: .year, latest: date.map { Point(date: $0, value: 72) }) }
        XCTAssertTrue(year("2026-08-01").stillEmpty(from: .month), "the latest is two months old")
        XCTAssertTrue(year(nil).stillEmpty(from: .month), "nothing at all")
        XCTAssertTrue(year("2026-09-22").stillEmpty(from: .month), "the day before the month")
        XCTAssertFalse(year("2026-09-23").stillEmpty(from: .month), "the month's first day")
        XCTAssertFalse(year("2026-10-22").stillEmpty(from: .month), "a weigh-in synced today")
        XCTAssertTrue(year("2026-10-15").stillEmpty(from: .week))
        XCTAssertFalse(year("2026-10-16").stillEmpty(from: .week))
    }

    func testAWindowHoldingOnlyTodaysUnfinishedTotalIsntEmpty() {
        XCTAssertTrue(sheet(range: .week).nothingToShow)
        XCTAssertFalse(sheet(range: .week, partialToday: true).nothingToShow, "today's bar and its Latest · so far today")
        XCTAssertFalse(sheet(range: .week, value: 8000).nothingToShow)
    }

    func testASheetAboutToMoveOrAnotherRangesEmptyOneIsNeverOnScreen() {
        let empty = sheet(range: .month)
        let full = sheet(range: .month, value: 72, points: [Point(date: "2026-10-22", value: 72)])
        XCTAssertFalse(empty.shows(asked: .month, picked: false), "it would say \"Nothing in the last 30 days\" for a moment, then move")
        XCTAssertTrue(empty.shows(asked: .month, picked: true), "a range the person pressed is shown, empty or not")
        XCTAssertTrue(sheet(range: .year).shows(asked: .year, picked: false), "the longest says why it is empty")
        XCTAssertTrue(full.shows(asked: .month, picked: false))
        // While another range loads: the last one stays up, unless it's empty.
        XCTAssertTrue(full.shows(asked: .year, picked: false))
        XCTAssertFalse(empty.shows(asked: .year, picked: true))
        let todayOnly = sheet(range: .week, points: [Point(date: "2026-10-22", value: 1200)], partialToday: true)
        XCTAssertTrue(todayOnly.shows(asked: .week, picked: false))
        XCTAssertTrue(todayOnly.shows(asked: .month, picked: true))
    }

    // MARK: - The range shown

    func testItOpensOnTheRangeAskedForWhenTheMetricHasIt() {
        XCTAssertEqual(SheetRanges(key: .steps, asked: .day).range, .day)
        XCTAssertEqual(SheetRanges(key: .hrv, asked: .week).range, .week)
        XCTAssertEqual(SheetRanges(key: .hrv, asked: .day).range, .month, "HRV has no Day: its own default")
        XCTAssertEqual(SheetRanges(key: .heartRate, asked: .week).range, .day, "heart rate has only a Day")
        XCTAssertEqual(SheetRanges(key: .sleepHours, asked: nil).range, .week)
        XCTAssertEqual(SheetRanges(key: .weight, asked: nil).range, .month)
    }

    func testAnEmptyWindowMovesOnceOnCurrentDataAndThePersonsChoiceStays() {
        var r = SheetRanges(key: .vo2max, asked: nil)
        // An older copy, or another range's answer, moves nothing.
        r.heard(sheet(.vo2max, range: .month), current: false)
        XCTAssertEqual(r.range, .month)
        r.heard(sheet(.vo2max, range: .week), current: true)
        XCTAssertEqual(r.range, .month)
        r.heard(sheet(.weight, range: .month), current: true)
        XCTAssertEqual(r.range, .month, "another metric's answer")
        // The month is empty: on to the year, and why.
        r.heard(sheet(.vo2max, range: .month), current: true)
        XCTAssertEqual(r.range, .year)
        XCTAssertEqual(r.widened, .month)
        let year = sheet(.vo2max, range: .year, value: 42.5, points: [Point(date: "2026-09-02", value: 42.5)], latest: Point(date: "2026-09-02", value: 42.5))
        r.heard(year, current: true)
        XCTAssertEqual(r.range, .year, "the longest stays")
        XCTAssertEqual(r.note(shown: year), "Nothing in the last 30 days, so this shows the last 12 months.")
        XCTAssertNil(r.note(shown: sheet(.vo2max, range: .month)), "only over the range it moved to")
        // A reading synced into the month since: the note goes.
        let synced = sheet(.vo2max, range: .year, value: 42.8, points: [Point(date: "2026-10-22", value: 43.1)], latest: Point(date: "2026-10-22", value: 43.1))
        XCTAssertNil(r.note(shown: synced))
        // Pressed: the person's range, empty or not, and no note.
        r.pick(.month)
        XCTAssertEqual(r.range, .month)
        r.heard(sheet(.vo2max, range: .month), current: true)
        XCTAssertEqual(r.range, .month)
        XCTAssertNil(r.note(shown: year))
    }

    func testARangeThePersonDoesntHaveFallsBackToTheirFirst() {
        // Day, before the phone has sent any hours: the server offers the week first.
        var r = SheetRanges(key: .steps, asked: .day)
        r.heard(sheet(.steps, range: .day, ranges: [.week, .month, .year]), current: true)
        XCTAssertEqual(r.range, .week)
        XCTAssertNil(r.widened)
        XCTAssertFalse(r.picked)
        // A metric never measured stays where it opened.
        var never = SheetRanges(key: .glucose, asked: nil)
        never.heard(sheet(.glucose, range: .month, everMeasured: false), current: true)
        XCTAssertEqual(never.range, .month)
    }

    // MARK: - Loading (MetricSheetModel)

    /// A server answering from a table of sheets by range, counting what it's asked.
    private final class FakeServer {
        var sheets: [MetricRange: MetricSheetData] = [:]
        /// It has no sheet for the metric (an older server).
        var missing = false
        var failure: Error?
        var asked: [MetricRange] = []
        var whileAsked: ((MetricRange) -> Void)?

        func answer(_ range: MetricRange) async throws -> MetricSheetData? {
            asked.append(range)
            whileAsked?(range)
            if let failure { throw failure }
            return missing ? nil : sheets[range]
        }
    }

    private func load(_ model: MetricSheetModel, _ server: FakeServer, generation: Int = 1, phone: FakeServer? = nil) async {
        await model.load(generation: generation, fromServer: { try await server.answer($0) }, onPhone: { range in
            guard let sheet = try await phone?.answer(range) else { throw APIError.network("No phone sheet") }
            return sheet
        })
    }

    func testItLoadsTheRangeItOpensOn() async throws {
        let server = FakeServer()
        server.sheets[.month] = try fixture("metric-hrv-month")
        let model = MetricSheetModel(key: .hrv, range: nil)
        XCTAssertNil(model.shown, "nothing until the first answer")
        await load(model, server)
        XCTAssertEqual(server.asked, [.month])
        XCTAssertEqual(model.shown?.range, .month)
        XCTAssertFalse(model.loading)
        XCTAssertTrue(model.current)
        XCTAssertNil(model.error)
        XCTAssertNil(model.note)
    }

    func testAnEmptyMonthMovesToTheYearWithoutShowingItself() async {
        let server = FakeServer()
        server.sheets[.month] = MetricSheetFallback.windowSheet(.vo2max, range: .month, metric: "vo2max", points: [], to: "2026-10-22",
                                                               today: "2026-10-22", units: .metric, goal: nil)
        server.sheets[.year] = sheet(.vo2max, range: .year, value: 42.5, points: [Point(date: "2026-09-02", value: 42.5)],
                                     latest: Point(date: "2026-09-02", value: 42.5))
        let model = MetricSheetModel(key: .vo2max, range: nil)
        await load(model, server)
        XCTAssertEqual(model.range, .year, "moved on its own")
        XCTAssertNil(model.shown, "the empty month never flashes \"Nothing in the last 30 days\"")
        await load(model, server)
        XCTAssertEqual(model.shown?.range, .year)
        XCTAssertEqual(model.note, "Nothing in the last 30 days, so this shows the last 12 months.")
        XCTAssertEqual(server.asked, [.month, .year])
    }

    func testAnotherRangeStaysUpWhileThePressedOneLoads() async throws {
        let server = FakeServer()
        server.sheets[.month] = try fixture("metric-hrv-month")
        var week = try fixture("metric-hrv-month")
        week.range = .week
        server.sheets[.week] = week
        let model = MetricSheetModel(key: .hrv, range: nil)
        await load(model, server)
        model.pick(.week)
        XCTAssertEqual(model.shown?.range, .month, "the month stays up while the week loads")
        var dimmed = false
        server.whileAsked = { _ in dimmed = model.loading && model.shown?.range == .month }
        await load(model, server)
        XCTAssertTrue(dimmed, "dimmed while it loads")
        XCTAssertEqual(model.shown?.range, .week)
        // Back to the month: answered from this sheet's memory, not asked again.
        model.pick(.month)
        await load(model, server)
        XCTAssertEqual(model.shown?.range, .month)
        XCTAssertEqual(server.asked, [.month, .week])
    }

    func testNewDataReadsEveryRangeAgainAndKeepsWhatsOnScreenMeanwhile() async throws {
        let server = FakeServer()
        server.sheets[.month] = try fixture("metric-hrv-month")
        let model = MetricSheetModel(key: .hrv, range: nil)
        await load(model, server, generation: 1)
        var keptUp = false
        server.whileAsked = { _ in keptUp = model.shown != nil && !model.current }
        await load(model, server, generation: 2)
        XCTAssertTrue(keptUp, "the old copy stays up, known not to be current")
        XCTAssertTrue(model.current)
        XCTAssertEqual(server.asked, [.month, .month])
    }

    func testAServerWithoutTheSheetHandsOverToThePhoneForGood() async {
        let server = FakeServer()
        server.missing = true
        let phone = FakeServer()
        phone.sheets[.month] = sheet(.weight, range: .month, value: 70, points: [Point(date: "2026-10-20", value: 70)])
        phone.sheets[.week] = sheet(.weight, range: .week, value: 70, points: [Point(date: "2026-10-20", value: 70)])
        let model = MetricSheetModel(key: .weight, range: nil)
        await load(model, server, phone: phone)
        XCTAssertTrue(model.onPhone)
        XCTAssertEqual(model.shown?.range, .month)
        model.pick(.week)
        await load(model, server, phone: phone)
        XCTAssertEqual(model.shown?.range, .week)
        XCTAssertEqual(server.asked, [.month], "not asked again")
        XCTAssertEqual(phone.asked, [.month, .week])
    }

    func testAFailureIsSaidUnlessAnotherRangeIsUp() async throws {
        let server = FakeServer()
        server.failure = APIClient.error(status: 500, message: "Something went wrong", path: "/metric/hrv")
        let model = MetricSheetModel(key: .hrv, range: nil)
        await load(model, server)
        XCTAssertNil(model.shown)
        XCTAssertEqual(model.error, "Something went wrong")
        XCTAssertFalse(model.loading)
        // With the month up, a failed week leaves the month on screen, as the web's does.
        server.failure = nil
        server.sheets[.month] = try fixture("metric-hrv-month")
        await load(model, server)
        model.pick(.week)
        server.failure = APIError.network("Can't reach localhost.")
        await load(model, server)
        XCTAssertEqual(model.shown?.range, .month)
        // A load cut short (the sheet closed, the range changed) isn't a failure.
        server.failure = CancellationError()
        model.pick(.year)
        await load(model, server)
        XCTAssertNil(model.error)
    }

    func testAnAnswerForARangeThePersonLeftIsDropped() async throws {
        let server = FakeServer()
        server.sheets[.month] = try fixture("metric-hrv-month")
        let model = MetricSheetModel(key: .hrv, range: nil)
        server.whileAsked = { _ in model.pick(.week) }
        await load(model, server)
        XCTAssertNil(model.data, "the month came back after the week was pressed")
        XCTAssertEqual(model.range, .week)
    }

    // MARK: - Words and numbers

    func testTheSourceLine() {
        var s = sheet(.weight, range: .month, value: 70)
        s.from = "2026-09-23"
        s.sources = ["apple", "manual"]
        XCTAssertEqual(s.sourceLine, "From Apple Health, and added by you · each day is that day's last weigh-in · Sep 23 – Oct 22, 2026")
        s.sources = ["manual"]
        XCTAssertTrue(s.sourceLine.hasPrefix("Added by you · "))
        s.sources = ["apple", "whoop"]
        XCTAssertTrue(s.sourceLine.hasPrefix("From Apple Health and WHOOP · "))
        s.sources = ["oura"]
        XCTAssertTrue(s.sourceLine.hasPrefix("From oura · "), "a device the sheet doesn't know is named as sent")
        // A year across two calendar years names both; a Day is its one day.
        var year = sheet(.restingHr, range: .year, value: 52)
        year.from = "2025-10-23"
        year.sources = []
        XCTAssertEqual(year.sourceLine, "Oct 23, 2025 – Oct 22, 2026")
        var day = sheet(.steps, range: .day, value: 4000)
        day.from = "2026-10-26"
        day.to = "2026-10-26"
        XCTAssertEqual(day.sourceLine, "Mon, Oct 26, 2026")
        // HRV says how it was measured.
        var hrv = sheet(.hrv, range: .month, value: 52)
        hrv.metric = "hrv_sdnn"
        XCTAssertEqual(hrv.sourceLine, "SDNN, from Apple Watch · Thu, Oct 22, 2026")
        hrv.metric = "hrv_rmssd"
        XCTAssertEqual(hrv.sourceLine, "RMSSD, measured during sleep · Thu, Oct 22, 2026")
        // Nothing to say about a window with no days, rather than a crash.
        var bad = sheet(range: .month)
        bad.to = ""
        XCTAssertEqual(bad.sourceLine, "each day is that day's last weigh-in")
        XCTAssertTrue(bad.stillEmpty(from: .month))
    }

    func testWhatAnEmptyWindowSays() {
        XCTAssertEqual(sheet(.weight, range: .month).emptyMessage, "Nothing in the last 30 days. Year shows the last 12 months.")
        XCTAssertEqual(sheet(.weight, range: .year).emptyMessage, SheetWords.ownEntry)
        XCTAssertEqual(sheet(.recovery, range: .year).emptyMessage, "Recovery comes from WHOOP.")
        XCTAssertEqual(sheet(.restingHr, range: .year).emptyMessage, "Nothing recorded in this range.")
        XCTAssertEqual(sheet(.steps, range: .day, ranges: [.day, .week, .month, .year]).emptyMessage, SheetWords.noHours)
    }

    func testTheCardsPageIsNamed() {
        XCTAssertEqual(SheetPage.name(.vitals), "Vitals")
        XCTAssertEqual(SheetPage.name(.home), "Home")
        XCTAssertEqual(SheetPage.name(AppRoute(.body, query: ["tab": "recovery"])), "Recovery on Body")
        XCTAssertEqual(SheetPage.name(AppRoute(.sleep, query: ["tab": "trends"])), "Trends on Sleep")
        XCTAssertEqual(SheetPage.name(AppRoute(.body, query: ["tab": "recovery"]), over: .home), "Recovery on Body", "only Activity has two addresses")
    }

    /// Body's Activity tab has two addresses on the web, named apart: Home's cards link #/activity, "Open Activity", and
    /// Body's own card #/body?tab=activity, "Open Activity on Body". Both are `.activity` here, told apart by the page under the sheet.
    func testActivityIsNamedAsTheWebsCardsLinkIt() throws {
        let home = try web("src/pages/Home.tsx"), body = try web("src/pages/Body.tsx")
        for card in ["title=\"Strain\" to={href('activity')} metric=\"strain\"", "metric={strain ? 'strain' : 'active_energy'}",
                     "title=\"Activity\" to={href('activity')} metric=\"steps\""] {
            XCTAssertTrue(home.contains(card), card)
        }
        XCTAssertTrue(home.contains("title={strain ? 'Strain' : 'Active energy'} to={href('activity')}"))
        XCTAssertTrue(body.contains("metric=\"steps\" title=\"activity level\" date={s.date} section=\"Body\" to={bodyHref('activity')}"))
        XCTAssertTrue(try web("src/components/MetricSheet.tsx").contains("return tab ? `${tab[0].toUpperCase()}${tab.slice(1)} on ${page}` : page;"))

        XCTAssertEqual(SheetPage.name(.activity, over: .home), "Activity", "Home's cards: #/activity")
        XCTAssertEqual(SheetPage.name(.activity, over: .body), "Activity on Body", "Body's card: #/body?tab=activity")
        XCTAssertEqual(SheetPage.name(.activity, over: AppRoute(.body, query: ["tab": "activity"])), "Activity on Body")
        XCTAssertEqual(SheetPage.name(.activity), "Activity on Body", "under no page")
        // The same-page check names the page under the sheet over itself: Body's Activity tab hides Body's card's link.
        let under = AppRoute.activity
        XCTAssertEqual(SheetPage.name(under, over: under), SheetPage.name(.activity, over: under))
        XCTAssertNotEqual(SheetPage.name(.home, over: .home), SheetPage.name(.activity, over: .home))
    }

    func testThePageUnderTheSheet() {
        let d = Dashboard()
        XCTAssertEqual(d.pageOnScreen, .home)
        d.open(AppRoute(.body, query: ["tab": "recovery"]))
        XCTAssertEqual(d.pageOnScreen.map { SheetPage.name($0) }, "Recovery on Body")
        d.open(.sleep)
        XCTAssertEqual(d.pageOnScreen, .sleep, "pushed under More")
        d.paths[.more] = []
        XCTAssertNil(d.pageOnScreen, "More's own list is no page")
    }

    func testValuesAreWrittenAsTheCardsWriteThem() {
        XCTAssertEqual(SheetFormat(key: .restingHr, unit: "bpm", digits: 0).value(54.4), "54 bpm")
        XCTAssertEqual(SheetFormat(key: .spo2, unit: "%", digits: 1).value(96.54), "96.5%")
        XCTAssertEqual(SheetFormat(key: .strain, unit: "", digits: 1).value(12.36), "12.4")
        XCTAssertEqual(SheetFormat(key: .steps, unit: "steps", digits: 0).value(8400), "8,400 steps")
        XCTAssertEqual(SheetFormat(key: .sleepHours, unit: "h", digits: 1).value(7.42), "7h 25m")
        XCTAssertEqual(SheetFormat.hoursMinutes(59.6 / 60), "1h 00m", "rounded to the minute first")
        XCTAssertEqual(SheetFormat.hoursMinutes(0.75), "45m")
        XCTAssertEqual(SheetFormat(key: .weight, unit: "lb", digits: 1).value(154.33), "154.3 lb", "the sheet's own unit")
        // The big number: its unit set apart, none for sleep, a dash for nothing.
        let weight = SheetFormat(key: .weight, unit: "kg", digits: 1)
        XCTAssertEqual(weight.big(MetricFigure(label: "Average", value: 70.04, unit: "kg")).value, "70.0")
        XCTAssertEqual(weight.big(MetricFigure(label: "Average", value: 70.04, unit: "kg")).unit, "kg")
        XCTAssertEqual(SheetFormat(key: .recovery, unit: "%", digits: 0).big(MetricFigure(label: "Average", value: 55, unit: "%")).unit, "%")
        XCTAssertNil(SheetFormat(key: .sleepHours, unit: "h", digits: 1).big(MetricFigure(label: "Average a night", value: 7, unit: "h")).unit)
        XCTAssertEqual(weight.big(MetricFigure(label: "Average", value: nil, unit: "kg")).value, "—")
        // A tile in another unit is written in its own ("5 hours").
        let energy = SheetFormat(key: .activeEnergy, unit: "kcal", digits: 0)
        XCTAssertEqual(energy.tile(MetricFigure(label: "Hours with activity", value: 5, unit: "hours")), "5 hours")
        XCTAssertEqual(energy.tile(MetricFigure(label: "Busiest hour", value: 120, unit: "kcal")), "120 kcal")
        XCTAssertEqual(energy.tile(MetricFigure(label: "Typical by now", value: nil, unit: "kcal")), "—")
    }

    func testAxisLabelsTakeTheirStepsDecimals() {
        XCTAssertEqual(SheetFormat.stepDigits(0.5), 1)
        XCTAssertEqual(SheetFormat.stepDigits(0.25), 2)
        XCTAssertEqual(SheetFormat.stepDigits(5), 0)
        XCTAssertEqual(SheetFormat.stepDigits(nil), 0)
        let spo2 = SheetFormat(key: .spo2, unit: "%", digits: 1)
        XCTAssertEqual(spo2.tick(96.5, step: 0.5), "96.5")
        XCTAssertEqual(spo2.tick(97, step: 0.5), "97.0")
        XCTAssertEqual(spo2.tick(96.25, step: 0.25), "96.25")
        XCTAssertEqual(spo2.tick(96, step: 1), "96.0", "a metric with decimals keeps one under 100")
        XCTAssertEqual(SheetFormat(key: .weight, unit: "lb", digits: 1).tick(150, step: 5), "150")
        XCTAssertEqual(SheetFormat(key: .restingHr, unit: "bpm", digits: 0).tick(55, step: 5), "55")
        XCTAssertEqual(SheetFormat(key: .steps, unit: "steps", digits: 0).tick(12_500, step: 2500), "12.5K")
        XCTAssertEqual(SheetFormat(key: .sleepHours, unit: "h", digits: 1).tick(8, step: 1), "8h")
        XCTAssertEqual(SheetFormat(key: .sleepHours, unit: "h", digits: 1).tick(7.5, step: 0.5), "7.5h", "never 8h twice")
        // A half rounds away from zero, as the server's sentence does.
        XCTAssertEqual(SheetFormat(key: .hrv, unit: "ms", digits: 0).value(68.5), "69 ms")
        XCTAssertEqual(SheetFormat(key: .spo2, unit: "%", digits: 1).value(96.25), "96.3%")
        // niceTicks, as src/charts/core.tsx draws them.
        XCTAssertEqual(SheetMath.niceTicks(0, 10_000), [0, 2500, 5000, 7500, 10_000])
        XCTAssertEqual(SheetMath.niceTicks(48, 61), [45, 50, 55, 60, 65])
        XCTAssertEqual(SheetMath.niceTicks(96.1, 97.9), [96, 96.5, 97, 97.5, 98])
        XCTAssertEqual(SheetMath.niceTicks(5, 5), [4, 4.5, 5, 5.5, 6])
        XCTAssertEqual(SheetMath.niceTicks(.nan, 1), [])
        XCTAssertEqual(SheetMath.median([3, 1, 2]), 2)
        XCTAssertEqual(SheetMath.median([4, 1, 2, 3]), 2.5)
        XCTAssertNil(SheetMath.median([]))
    }

    func testTheDatesUnderTheChart() {
        let month = (0..<30).map { Day.add("2026-09-23", $0) }
        let labels = SheetMath.xLabels(month, width: 366)
        XCTAssertEqual(labels.map(\.index), [0, 10, 19, 29], "one per 90 points of width, spread by index")
        XCTAssertEqual(labels.first?.text, "Sep 23")
        XCTAssertEqual(SheetMath.xLabels(month, width: 0).map(\.index), [0, 29], "two at the least")
        let year = (0..<53).map { Day.add("2025-10-27", 7 * $0) }
        XCTAssertEqual(SheetMath.xLabels(year, width: 600).first?.text, "Oct 25", "a year by month and year")
        XCTAssertEqual(SheetMath.runs([Point(date: "2026-10-01", value: 1), Point(date: "2026-10-04", value: 1), Point(date: "2026-10-08", value: 1)], gapDays: 3),
                       [0, 0, 1], "more than three days apart breaks the line")
    }

    // MARK: - Decoding

    func testAMeasuredMonthFromTheServer() throws {
        let s = try fixture("metric-hrv-month")
        XCTAssertEqual(s.key, .hrv)
        XCTAssertEqual(s.range, .month)
        XCTAssertEqual(s.ranges, [.week, .month, .year])
        XCTAssertEqual(s.resolution, .day)
        XCTAssertEqual(s.points.count, 30)
        XCTAssertEqual(s.metric, "hrv_rmssd")
        XCTAssertEqual(s.everMeasured, true)
        XCTAssertEqual(s.status?.position, "at_or_above")
        XCTAssertEqual(s.tiles.map(\.label), ["Lowest", "Highest", "Latest"])
        XCTAssertNotNil(s.headline.value)
        XCTAssertNotNil(s.narrative)
        XCTAssertNotNil(s.latest)
        XCTAssertEqual(s.sourceLine, "From Demo data · RMSSD, measured during sleep · Sep 27 – Oct 26, 2026")
        XCTAssertNil(s.widerRange)
        XCTAssertTrue(s.shows(asked: .month, picked: false))
    }

    func testAWeekOfStepsWithTodaySoFar() throws {
        let s = try fixture("metric-steps-week")
        XCTAssertEqual(s.ranges, [.day, .week, .month, .year])
        XCTAssertTrue(s.partialToday)
        XCTAssertEqual(s.points.last?.date, s.today, "today's bar is drawn")
        XCTAssertEqual(s.tiles.last?.note, "so far today")
        XCTAssertEqual(s.goal, 10_000)
        XCTAssertEqual(s.headline.label, "Daily average")
        XCTAssertEqual(s.status?.position, "band")
    }

    func testAYearIsWeeklyAverages() throws {
        let s = try fixture("metric-sleep-year")
        XCTAssertEqual(s.resolution, .week)
        XCTAssertTrue(s.points.allSatisfy { Point.weekStart($0.date) == $0.date }, "each dated its Monday")
        XCTAssertEqual(s.headline.label, "Average a night")
    }

    func testADayByTheHour() throws {
        let steps = try fixture("metric-steps-day")
        XCTAssertEqual(steps.range, .day)
        XCTAssertEqual(steps.resolution, .hour)
        XCTAssertTrue(steps.points.isEmpty)
        XCTAssertNotNil(steps.day?.metrics["steps"])
        XCTAssertEqual(steps.tiles.map(\.label), ["Typical by now", "Busiest hour", "Goal"])
        XCTAssertNil(steps.widerRange, "a Day never moves")
        let heart = try fixture("metric-heart-rate-day")
        XCTAssertEqual(heart.ranges, [.day])
        XCTAssertNotNil(heart.day?.metrics["heart_rate"]?.min)
        XCTAssertEqual(heart.tiles.map(\.label), ["Lowest", "Highest", "Typical then"])
        XCTAssertEqual(heart.headline.label, "Latest hour")
    }

    func testNeverMeasured() throws {
        let s = try fixture("metric-glucose-never")
        XCTAssertTrue(s.neverMeasured)
        XCTAssertTrue(s.points.isEmpty)
        XCTAssertNil(s.widerRange, "it doesn't move to Year looking for something")
        XCTAssertTrue(s.shows(asked: .month, picked: false))
    }

    func testAnOlderServersSheetCountsAsMeasured() throws {
        // From before everMeasured, with its other later fields left out, and one it can't read.
        let s = try decode("""
        {"key":"weight","label":"Weight","unit":"lb","digits":1,"range":"month","ranges":["week","month","year","decade"],
         "from":"2026-09-23","to":"2026-10-22","today":"2026-10-22","points":[{"date":"2026-10-01","value":154.2},{"date":"bad","value":1},{"value":3}],
         "headline":{"label":"Average","value":154.2,"unit":"lb","note":"1 of 30 days with data"},
         "tiles":[{"label":"Lowest","value":154.2,"unit":"lb","date":"2026-10-01"},"junk"],"status":"high","narrative":"Your weight averaged 154.2 lb over the last 30 days."}
        """)
        XCTAssertNil(s.everMeasured)
        XCTAssertFalse(s.neverMeasured)
        XCTAssertEqual(s.ranges, [.week, .month, .year], "a range it doesn't know is dropped")
        XCTAssertEqual(s.points, [Point(date: "2026-10-01", value: 154.2)])
        XCTAssertEqual(s.tiles.count, 1)
        XCTAssertNil(s.status)
        XCTAssertFalse(s.partialToday)
        XCTAssertNil(s.latest)
        XCTAssertEqual(s.unit, "lb", "the server's unit, in the person's units")
        XCTAssertEqual(s.resolution, .day)
        // The least a sheet can be.
        let least = try decode(#"{"key":"steps","range":"week","headline":{"label":"Daily average","value":null}}"#)
        XCTAssertEqual(least.ranges, MetricKey.steps.info.ranges)
        XCTAssertEqual(least.unit, "steps")
        XCTAssertTrue(least.nothingToShow)
        XCTAssertEqual(least.sourceLine, "")
        // Not a sheet: an unknown metric or range is refused, never shown as another.
        XCTAssertThrowsError(try decode(#"{"key":"secret","range":"week","headline":{"label":"x"}}"#))
        XCTAssertThrowsError(try decode(#"{"key":"steps","range":"decade","headline":{"label":"x"}}"#))
    }

    // MARK: - Older servers

    func testAServerWithoutTheSheetFallsBack() {
        // No /api/metric at all: the catch-all, which `optional` reads as nil.
        XCTAssertTrue(APIClient.error(status: 404, message: "Not found", path: "/metric/hrv").routeMissing)
        // A server from before sleep performance and efficiency had sheets.
        XCTAssertTrue(MetricSheetFallback.unknownMetric(APIClient.error(status: 404, message: "Unknown metric", path: "/metric/sleep_efficiency")))
        XCTAssertFalse(MetricSheetFallback.unknownMetric(APIClient.error(status: 400, message: "range must be day, week, month or year", path: "/metric/hrv")))
        XCTAssertFalse(MetricSheetFallback.unknownMetric(APIClient.error(status: 500, message: "Something went wrong", path: "/metric/hrv")))
        // Errors read as the web reads them after "Couldn't load this: ".
        XCTAssertEqual(MetricSheetModel.message(APIClient.error(status: 500, message: "Something went wrong", path: "/metric/hrv")), "Something went wrong")
        XCTAssertEqual(MetricSheetModel.message(APIClient.error(status: 502, message: nil, path: "/metric/hrv")), SheetWords.somethingWrong)
        XCTAssertEqual(MetricSheetModel.message(APIError.network("Can't reach localhost.")), "Can't reach localhost.")
    }

    func testTheWindowBuiltOnThePhoneFollowsTheServersRules() {
        // A week of steps with today's total so far: drawn, not counted.
        let steps = (0..<8).map { Point(date: Day.add("2026-10-19", $0), value: Double(6000 + 500 * $0)) }
        let s = MetricSheetFallback.windowSheet(.steps, range: .week, metric: "steps", points: steps, to: "2026-10-26", today: "2026-10-26",
                                                units: .metric, goal: 10_000)
        XCTAssertEqual(s.from, "2026-10-20")
        XCTAssertEqual(s.points.count, 7, "the day before the window is left out")
        XCTAssertTrue(s.partialToday)
        XCTAssertEqual(s.headline.label, "Daily average")
        XCTAssertEqual(s.headline.value, (6500 + 7000 + 7500 + 8000 + 8500 + 9000) / 6)
        XCTAssertEqual(s.headline.note, "6 of 6 days with data; today isn't counted until it's over")
        XCTAssertEqual(s.tiles.map(\.label), ["Lowest day", "Highest day", "Latest"])
        XCTAssertEqual(s.tiles.map(\.value), [6500, 9000, 9500])
        XCTAssertEqual(s.tiles.last?.note, "so far today")
        XCTAssertEqual(s.goal, 10_000)
        XCTAssertNil(s.narrative, "the server's sentence isn't guessed")
        XCTAssertNil(s.status)
        XCTAssertNil(s.everMeasured)
        // Weight in pounds, its own words for a day's value, and ties keep the first day.
        let weight = [Point(date: "2026-10-01", value: 70), Point(date: "2026-10-10", value: 70), Point(date: "2026-10-20", value: 71)]
        let w = MetricSheetFallback.windowSheet(.weight, range: .month, metric: "weight", points: weight, to: "2026-10-22", today: "2026-10-26",
                                                units: .imperial, goal: nil)
        XCTAssertEqual(w.unit, "lb")
        XCTAssertEqual(w.tiles[0].date, "2026-10-01")
        XCTAssertEqual(w.tiles[0].value!, 70 / 0.45359237, accuracy: 1e-9)
        XCTAssertFalse(w.partialToday)
        XCTAssertEqual(w.headline.note, "3 of 30 days with data")
        XCTAssertTrue(w.sourceLine.hasSuffix("Sep 23 – Oct 22, 2026"))
        // Glucose's figures say what a day is.
        let g = MetricSheetFallback.windowSheet(.glucose, range: .week, metric: "glucose", points: [], to: "2026-10-26", today: "2026-10-26",
                                                units: .metric, goal: nil)
        XCTAssertEqual(g.tiles.map(\.label), ["Lowest daily average", "Highest daily average", "Latest daily average"])
        XCTAssertEqual(g.widerRange, .year, "an empty window moves on here too")
        // A year is weekly averages, each dated its Monday.
        let nights = [Point(date: "2026-10-19", value: 7), Point(date: "2026-10-21", value: 8), Point(date: "2026-10-26", value: 6)]
        let y = MetricSheetFallback.windowSheet(.sleepHours, range: .year, metric: "sleep_hours", points: nights, to: "2026-10-26", today: "2026-10-26",
                                                units: .metric, goal: nil)
        XCTAssertEqual(y.points, [Point(date: "2026-10-19", value: 7.5), Point(date: "2026-10-26", value: 6)])
        XCTAssertEqual(y.resolution, .week)
        XCTAssertEqual(y.headline.label, "Average a night")
    }

    func testADayBuiltOnThePhone() {
        let hours: [Double?] = [0, 0, 0, 0, 0, 0, 0, 200, 800, 400] + Array(repeating: nil, count: 14)
        let day = DayData(date: "2026-10-26", today: "2026-10-26", asOf: 9,
                          metrics: ["steps": DaySeries(hours: hours, typical: Array(repeating: nil, count: 24)),
                                    "heart_rate": DaySeries(hours: Array(repeating: 70, count: 10) + Array(repeating: nil, count: 14), typical: [])])
        let s = MetricSheetFallback.daySheet(.steps, day: day, date: "2026-10-26", today: "2026-10-26", goal: 10_000)
        XCTAssertEqual(s.range, .day)
        XCTAssertEqual(s.headline.label, "So far today")
        XCTAssertEqual(s.headline.value, 1400)
        XCTAssertEqual(s.day?.metrics.keys.sorted(), ["steps"], "only its own metric")
        XCTAssertFalse(s.nothingToShow)
        let none = MetricSheetFallback.daySheet(.activeEnergy, day: day, date: "2026-10-26", today: "2026-10-26", goal: nil)
        XCTAssertTrue(none.nothingToShow)
        XCTAssertEqual(none.emptyMessage, SheetWords.noHours)
        let older = MetricSheetFallback.daySheet(.heartRate, day: nil, date: "2026-10-20", today: "2026-10-26", goal: nil)
        XCTAssertEqual(older.headline.label, "That day")
        XCTAssertEqual(older.emptyMessage, SheetWords.noHours)
    }

    // MARK: - Pressing and reading it, at every text size

    /// The sheet's content width on a 402-point phone (18 points of margin each side).
    private let sheetWidth: CGFloat = 366

    /// A view's size at a text size, offered `width` across.
    private func measure(_ view: some View, _ type: DynamicTypeSize, width: CGFloat? = nil) -> CGSize {
        let host = UIHostingController(rootView: AnyView(view.environment(\.dynamicTypeSize, type)))
        return host.sizeThatFits(in: CGSize(width: width ?? sheetWidth, height: .greatestFiniteMagnitude))
    }

    /// SwiftUI only builds its accessibility elements while the simulator's accessibility automation is on, and that is a
    /// setting of the simulator, left on or off by whatever drove its UI last. So a test that reads them turns it on for
    /// itself, through the simulator's own libAccessibility, and puts back what it found when it's done.
    private func withAccessibilityAutomation(_ body: () async throws -> Void) async throws {
        let root = ProcessInfo.processInfo.environment["IPHONE_SIMULATOR_ROOT"] ?? ""
        guard let lib = dlopen(root + "/usr/lib/libAccessibility.dylib", RTLD_LOCAL) ?? dlopen("/usr/lib/libAccessibility.dylib", RTLD_LOCAL),
              let get = dlsym(lib, "_AXSAutomationEnabled"), let set = dlsym(lib, "_AXSSetAutomationEnabled") else {
            XCTFail("the simulator's libAccessibility can't be loaded, so what VoiceOver reaches can't be read")
            return
        }
        let enabled = unsafeBitCast(get, to: (@convention(c) () -> Int32).self)
        let setEnabled = unsafeBitCast(set, to: (@convention(c) (Int32) -> Void).self)
        let before = enabled()
        setEnabled(1)
        defer { setEnabled(before) }
        try await body()
    }

    /// Shows a view in a window, as on screen, and hands back its accessibility elements (what VoiceOver reaches), in order.
    private func onScreen(_ view: some View, run: ([NSObject]) async throws -> Void) async throws {
        try await withAccessibilityAutomation {
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let host = UIHostingController(rootView: view)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            func walk(_ o: NSObject, into out: inout [NSObject]) {
                if o.isAccessibilityElement { out.append(o) }
                let n = o.accessibilityElementCount()
                if n != NSNotFound, n > 0 {
                    for i in 0..<n { if let e = o.accessibilityElement(at: i) as? NSObject { walk(e, into: &out) } }
                }
                for sub in (o as? UIView)?.subviews ?? [] { walk(sub, into: &out) }
            }
            // Wait for the elements to be built and to settle (the same number twice running), up to three seconds,
            // rather than for a fixed time.
            var elements: [NSObject] = [], last = -1
            for _ in 0..<60 {
                try await Task.sleep(for: .milliseconds(50))
                elements = []
                walk(host.view, into: &elements)
                if !elements.isEmpty, elements.count == last { break }
                last = elements.count
            }
            try await run(elements)
        }
    }

    /// The Day's table from a sheet's hours, as the sheet draws it.
    private func dayTable(_ sheet: MetricSheetData) throws -> SheetTable {
        let day = try XCTUnwrap(sheet.day), series = try XCTUnwrap(day.metrics[sheet.key.rawValue]), hour = try XCTUnwrap(sheet.key.hourMetric)
        return SheetChart.dayTable(series: series, reading: DayReading(metric: hour, series: series, data: day), running: hour.kind == .running,
                                   format: SheetFormat(sheet))
    }

    /// Made-up steps by the hour until 6 AM, with a typical day, so the running table has every column filled.
    private func stepsDay() -> MetricSheetData {
        let hours: [Double?] = [0, 0, 0, 0, 0, 420, 1260] + Array(repeating: nil, count: 17)
        let typical: [Double?] = [0, 0, 0, 0, 30, 380, 1850] + Array(repeating: nil, count: 17)
        let day = DayData(date: "2026-10-26", today: "2026-10-26", asOf: 6, metrics: ["steps": DaySeries(hours: hours, typical: typical)])
        return MetricSheetFallback.daySheet(.steps, day: day, date: "2026-10-26", today: "2026-10-26", goal: 10_000)
    }

    /// The web's onClick is `setPicked(true); setRange(r)` for every range button, the one already chosen too: pressing the
    /// range the sheet moved to by itself keeps it, drops "Nothing in the last 30 days, so…" and stops it moving again.
    func testPressingTheChosenRangeIsAPick() async throws {
        XCTAssertTrue(try web("src/components/MetricSheet.tsx").contains("""
                        onClick={() => {
                          setPicked(true);
                          setRange(r);
                        }}
        """), "the web's range button picks whatever it is")

        var picked: [MetricRange] = []
        try await onScreen(SheetRangeButtons(ranges: [.week, .month, .year], range: .year, pick: { picked.append($0) })) { elements in
            let year = try XCTUnwrap(elements.first { $0.accessibilityLabel == "Year" })
            XCTAssertTrue(year.accessibilityTraits.contains(.selected))
            XCTAssertTrue(year.accessibilityActivate())
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(picked, [.year], "the chosen range, pressed, is a pick")
            _ = elements.first { $0.accessibilityLabel == "Month" }?.accessibilityActivate()
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(picked, [.year, .month])
        }

        // What that pick does: the sheet moved from an empty month to the year and said so.
        var r = SheetRanges(key: .vo2max, asked: nil)
        r.heard(sheet(.vo2max, range: .month), current: true)
        let year = sheet(.vo2max, range: .year, value: 42.5, points: [Point(date: "2026-09-02", value: 42.5)], latest: Point(date: "2026-09-02", value: 42.5))
        XCTAssertNotNil(r.note(shown: year))
        r.pick(.year)
        XCTAssertEqual(r.range, .year)
        XCTAssertTrue(r.picked)
        XCTAssertNil(r.note(shown: year), "the note goes")
        r.heard(sheet(.vo2max, range: .year), current: true)
        XCTAssertEqual(r.range, .year, "and the sheet doesn't move on its own again")
    }

    /// Never measured, "Manage connections" is the one thing to press, so it grows with the text at every size: one line
    /// up to xxxLarge, and at the accessibility sizes its words wrap inside the sheet rather than stopping at xxxLarge's size.
    func testManageConnectionsGrowsWithTheText() {
        let button = ManageConnectionsButton(action: {})
        let sizes: [DynamicTypeSize] = [.large, .xxxLarge, .accessibility1, .accessibility3, .accessibility5]
        let measured = sizes.map { measure(button, $0) }
        XCTAssertGreaterThan(measured[1].width, measured[0].width, "one line, wider at xxxLarge")
        for i in 1..<sizes.count {
            XCTAssertGreaterThan(measured[i].height, measured[i - 1].height + (i == 1 ? -1 : 0), "\(sizes[i]) doesn't stop at \(sizes[i - 1])'s size")
        }
        for (type, size) in zip(sizes, measured) {
            XCTAssertLessThanOrEqual(size.width, sheetWidth + 0.5, "\(type): inside the sheet")
        }
        let line = measure(Text("Manage").font(PillSize.compact.font).fixedSize(), .accessibility5, width: .greatestFiniteMagnitude).height
        XCTAssertGreaterThan(measure(button, .accessibility5).height, line * 2, "its words on two lines or more at the largest size")
    }

    /// Every cell keeps to one line, as the web's td (white-space: nowrap) does, so no word or value is ever broken: a table
    /// too wide for the sheet scrolls sideways (.table-wrap's overflow) and stays inside the sheet. Its height is then
    /// exactly the names' line and one line per row, with the web's padding and a hairline under each. At the
    /// accessibility sizes the rows stack instead (testAtTheAccessibilitySizesEachTableRowStacks).
    func testTheTablesKeepEachCellToOneLineAtEveryTextSize() throws {
        let css = try web("src/styles.css")
        XCTAssertTrue(css.contains("  font-variant-numeric: tabular-nums;\n  white-space: nowrap;\n}"), "td keeps to one line")
        XCTAssertTrue(css.contains(".table-wrap {\n  max-height: 360px;\n  overflow: auto;\n}"))

        let heart = try dayTable(try fixture("metric-heart-rate-day"))
        let steps = try dayTable(stepsDay())
        let week = try fixture("metric-steps-week")
        let weekTable = SheetTable(columns: ["Date", "Steps"], rows: week.points.map { [Fmt.day($0.date, "MMMdyyyy"), SheetFormat(week).value($0.value)] })
        XCTAssertEqual(heart.columns, ["Hour", "Average", "Low", "High", "Typical"])
        XCTAssertEqual(steps.columns, ["Hour", "This hour", "So far", "Typical by then"])
        XCTAssertEqual(steps.rows.count, 7)
        for table in [heart, steps, weekTable] {
            XCTAssertLessThanOrEqual(table.rows.count, 9, "a short table is shown whole")
            for type: DynamicTypeSize in [.large, .xLarge, .xxxLarge] {
                let name = measure(Text("Hour").font(.app(size: 12, weight: .medium, relativeTo: .caption)).fixedSize(), type, width: .greatestFiniteMagnitude).height
                let line = measure(Text("57 bpm").font(.app(size: 13, relativeTo: .footnote)).fixedSize(), type, width: .greatestFiniteMagnitude).height
                let size = measure(SheetTableView(table: table), type)
                let rows = CGFloat(table.rows.count)
                XCTAssertEqual(size.height, name + 16 + 1 + rows * (line + 16 + 1), accuracy: 1.5, "\(table.columns) at \(type): a cell wrapped")
                XCTAssertLessThanOrEqual(size.width, sheetWidth + 0.5, "\(table.columns) at \(type): inside the sheet")
            }
        }
    }

    /// At the accessibility sizes, where a value would sit off the sheet's edge (the walk saw "55 bp" cut off at AX5),
    /// each row stacks: its date or hour, then each value on a line of its own (named when there are several), every one
    /// inside the sheet and none cut off, with no inner scrolling.
    func testAtTheAccessibilitySizesEachTableRowStacks() throws {
        XCTAssertEqual(SheetTableView.stackedValues(["Week of", "Heart rate"], ["Aug 10, 2026", "54 bpm"]), ["54 bpm"])
        XCTAssertEqual(SheetTableView.stackedValues(["Hour", "Average", "Low"], ["2 AM–3 AM", "57 bpm", "52 bpm"]),
                       ["Average: 57 bpm", "Low: 52 bpm"])
        let year = SheetTable(columns: ["Week of", "Heart rate"], rows: (0..<52).map { ["Aug \($0 % 28 + 1), 2026", "\(50 + $0 % 9) bpm"] })
        let heart = try dayTable(try fixture("metric-heart-rate-day"))
        for table in [year, heart] {
            for type: DynamicTypeSize in [.accessibility1, .accessibility3, .accessibility5] {
                let line = measure(Text("57 bpm").font(.app(size: 13, relativeTo: .footnote)).fixedSize(), type, width: .greatestFiniteMagnitude).height
                let size = measure(SheetTableView(table: table), type)
                XCTAssertLessThanOrEqual(size.width, sheetWidth + 0.5, "\(table.columns) at \(type): inside the sheet")
                let lines = CGFloat(table.rows.count * table.columns.count)
                XCTAssertGreaterThanOrEqual(size.height, lines * line, "\(table.columns) at \(type): every row whole, none in an inner window")
            }
        }
    }

    /// VoiceOver reads the table a row at a time, newest first, each row once, with its columns' names.
    func testVoiceOverReadsEachTableRowOnce() async throws {
        let table = try dayTable(try fixture("metric-heart-rate-day"))
        try await onScreen(SheetTableView(table: table)) { elements in
            let read = elements.compactMap(\.accessibilityLabel)
            XCTAssertEqual(read, table.rows.reversed().map { SheetTableView.spoken(table.columns, $0) })
            XCTAssertEqual(read.first, "Hour: \(table.rows.last![0]), Average: \(table.rows.last![1]), Low: \(table.rows.last![2]), High: \(table.rows.last![3]), Typical: \(table.rows.last![4])")
        }
    }

    /// The chart and table switch is drawn as the web's .seg (a 15-point icon in 5 by 8 points of padding, in a 3-point
    /// well) at the standard size, grows with the text, and each of its buttons, and each range button, takes a tap
    /// anywhere in 44 by 44 points, the two segments growing away from each other.
    func testTheSwitchGrowsWithTheTextAndItsTargetsAre44Points() {
        let large = measure(ViewSwitch(asTable: .constant(false), title: "Each day").fixedSize(), .large, width: .greatestFiniteMagnitude)
        XCTAssertEqual(large.width, 2 * 32 + 6, accuracy: 0.5)
        XCTAssertEqual(large.height, 26 + 6, accuracy: 0.5)
        var last = large
        for type: DynamicTypeSize in [.xxxLarge, .accessibility3, .accessibility5] {
            let size = measure(ViewSwitch(asTable: .constant(false), title: "Each day").fixedSize(), type, width: .greatestFiniteMagnitude)
            XCTAssertGreaterThan(size.width, last.width, "\(type)")
            XCTAssertGreaterThan(size.height, last.height, "\(type)")
            last = size
        }

        let chart = CGRect(x: 3, y: 3, width: 32, height: 26), table = CGRect(x: 35, y: 3, width: 32, height: 26)
        let chartArea = SheetTapArea.area(of: chart, outward: .leading), tableArea = SheetTapArea.area(of: table, outward: .trailing)
        for (drawn, area) in [(chart, chartArea), (table, tableArea)] {
            XCTAssertEqual(area.size, CGSize(width: 44, height: 44))
            XCTAssertTrue(area.contains(drawn), "the whole drawn button")
            XCTAssertEqual(area.midY, drawn.midY, accuracy: 0.01)
        }
        XCTAssertFalse(chartArea.intersects(tableArea), "neither takes the other's taps")
        XCTAssertEqual(chartArea.maxX, chart.maxX)
        XCTAssertEqual(tableArea.minX, table.minX)
        // A range button is wider than 44 already: only taller, so its neighbours keep theirs.
        let day = CGRect(x: 3, y: 3, width: 49, height: 29)
        XCTAssertEqual(SheetTapArea.area(of: day, outward: nil), CGRect(x: 3, y: 3 - 7.5, width: 49, height: 44))
        // Already big enough at the largest sizes: left as drawn.
        let big = CGRect(x: 0, y: 0, width: 60, height: 50)
        XCTAssertEqual(SheetTapArea.area(of: big, outward: .leading), big)
    }
}
