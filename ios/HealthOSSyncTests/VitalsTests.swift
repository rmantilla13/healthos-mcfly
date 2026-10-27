import SwiftUI
import UIKit
import XCTest
@testable import HealthOSSync

// The Vitals page (Vitals/, slice H): its words and rules against the web's Detail.tsx, its five signal cards, its
// trend cards, and what it does with each answer its reads get (a day, none from an older server, a failure). The
// drawn tests in the Duo's states are VitalsDuoTests. Made-up numbers only (the Fixtures folder's demo answers).

/// The fixtures and the counting reads both of Vitals' test files use.
@MainActor
final class VitalsFixtures {
    var trends = 0, tempHistory = 0, days: [String?] = []
    var trendsReply: Trends
    var tempReply: Trends?
    /// nil: an older server without GET /day.
    var dayReply: DayData?
    var dayFails = false
    var trendsFail = false

    let summary: Summary
    let status: ServerStatus

    init() throws {
        summary = try JSONDecoder().decode(Summary.self, from: Self.fixture("summary"))
        status = try JSONDecoder().decode(ServerStatus.self, from: Self.fixture("status"))
        trendsReply = try JSONDecoder().decode(Trends.self, from: Self.fixture("trends-vitals"))
        tempReply = trendsReply
        dayReply = try JSONDecoder().decode(DayData.self, from: Self.fixture("day"))
    }

    static func fixture(_ name: String) throws -> Data {
        let url = Bundle(for: VitalsFixtures.self).url(forResource: name, withExtension: "json")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name).json")
        return try XCTUnwrap(try? Data(contentsOf: url), "missing fixture \(name).json")
    }

    /// A file of the web app, next to the iPhone app in the repository.
    static func web(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(path)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { throw XCTSkip("\(path) isn't next to the app") }
        return text
    }

    var reads: VitalsReads {
        VitalsReads(
            readTrends: { _, metrics, _ in
                if metrics == TempDeviationCard.metrics {
                    self.tempHistory += 1
                    guard let reply = self.tempReply else { throw URLError(.notConnectedToInternet) }
                    return reply
                }
                self.trends += 1
                if self.trendsFail { throw APIError.network("The Internet connection appears to be offline.") }
                return self.trendsReply
            },
            readDay: { _, date in
                self.days.append(date)
                if self.dayFails { throw APIError.network("The Internet connection appears to be offline.") }
                return self.dayReply
            })
    }

    /// The iPhone's own metrics added to the trends answer (made-up readings on the same nights as resting heart rate).
    func addPhoneMetrics() {
        let nights = (trendsReply["resting_hr"] ?? []).map(\.date)
        func series(_ base: Double, _ step: Double) -> [Point] {
            nights.enumerated().map { Point(date: $0.element, value: base + Double($0.offset % 5) * step) }
        }
        trendsReply["blood_pressure_systolic"] = series(118, 2)
        trendsReply["blood_pressure_diastolic"] = series(76, 1)
        trendsReply["glucose"] = series(92, 3)
        trendsReply["breathing_disturbances"] = series(3, 1)
        tempReply = trendsReply
    }

    /// A dashboard showing the demo summary and status, signed in on no server.
    func dashboard(range: Int = 30) -> Dashboard {
        let d = Dashboard()
        d.apply(status: status)
        d.summary = summary
        d.rangeDays = range
        return d
    }

    /// The page as the Vitals tab shows it, with these reads in the server's place.
    func page(_ d: Dashboard) -> some View {
        VitalsScreen().environment(d).environment(AppModel()).environment(\.vitalsReads, reads)
    }
}

@MainActor
final class VitalsTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    private func status(whoop: Bool, fitbitMetrics: [String]?) throws -> ServerStatus {
        let fitbit = fitbitMetrics.map { #","fitbit":{"lastImport":{"days":30,"firstDate":"2026-09-01","lastDate":"2026-09-30","metrics":\#(String(decoding: try! JSONSerialization.data(withJSONObject: $0), as: UTF8.self)),"importedAt":"2026-10-01T10:00:00Z"}}"# } ?? ""
        return try decode(ServerStatus.self, #"{"hosted":false,"whoop":{"configured":true,"connected":\#(whoop)}\#(fitbit)}"#)
    }

    private func points(_ values: [Double], from day: String = "2026-10-01") -> [Point] {
        values.enumerated().map { Point(date: Day.add(day, $0.offset), value: $0.element) }
    }

    // MARK: Words

    /// Each trend card's table, as Detail.tsx's Trend gives ChartCard: Date and the card's title, a row a reading, the
    /// date with its year and the value as the card formats it.
    func testATrendCardsTable() {
        let trend = VitalsTrend(metric: "resting_hr", title: "Resting heart rate", points: points([52, 50]),
                                format: { "\(Fmt.number($0)) bpm" })
        let table = VitalsTrendCards.table(trend)
        XCTAssertEqual(table.columns, ["Date", "Resting heart rate"])
        XCTAssertEqual(table.rows.count, 2)
        XCTAssertEqual(table.rows[1][1], "50 bpm")
        XCTAssertEqual(table.rows[0][0], Fmt.day("2026-10-01", "yMMMd"))
        XCTAssertTrue(table.rows[0][0].contains("2026"), "the date with its year")
    }

    func testTheWordsAreTheWebs() throws {
        let detail = try VitalsFixtures.web("src/pages/Detail.tsx")
        for words in [VitalsWords.title, VitalsWords.trends, VitalsWords.dayFootnote, "Overnight readings from your connected sources.",
                      "available measurement${n === 1 ? '' : 's'} from your connected sources.", "Couldn't load your latest readings: ",
                      "Apple Watch, during sleep", "'WHOOP'", "during sleep`", "No data in this range", " · average "] {
            XCTAssertTrue(detail.contains(words), words)
        }
        XCTAssertEqual(VitalsWords.sub(count: nil), "Overnight readings from your connected sources.")
        XCTAssertEqual(VitalsWords.sub(count: 1), "1 available measurement from your connected sources.")
        XCTAssertEqual(VitalsWords.sub(count: 0), "0 available measurements from your connected sources.")
        XCTAssertEqual(VitalsWords.sub(count: 5), "5 available measurements from your connected sources.")
        XCTAssertEqual(VitalsWords.summaryFailed("Server answered 500"), "Couldn't load your latest readings: Server answered 500")
    }

    func testWhoMeasuresHrvAsRmssd() throws {
        XCTAssertEqual(VitalsWords.rmssdNote(nil), "WHOOP, during sleep", "not known yet: WHOOP's, as before")
        XCTAssertEqual(VitalsWords.rmssdNote(try status(whoop: false, fitbitMetrics: nil)), "WHOOP, during sleep")
        XCTAssertEqual(VitalsWords.rmssdNote(try status(whoop: true, fitbitMetrics: nil)), "WHOOP, during sleep")
        XCTAssertEqual(VitalsWords.rmssdNote(try status(whoop: false, fitbitMetrics: ["hrv_rmssd", "steps"])), "Fitbit, during sleep")
        XCTAssertEqual(VitalsWords.rmssdNote(try status(whoop: true, fitbitMetrics: ["hrv_rmssd"])), "WHOOP or Fitbit, during sleep")
        XCTAssertEqual(VitalsWords.rmssdNote(try status(whoop: true, fitbitMetrics: ["steps"])), "WHOOP, during sleep",
                       "a Fitbit export without RMSSD doesn't count")
    }

    // MARK: Signals

    func testTheFiveSignalsAreHomesCompactCardsAndOpenVitals() throws {
        let fixtures = try VitalsFixtures()
        let signals = VitalsSignals.all(fixtures.summary)
        XCTAssertEqual(signals.map(\.id), ["home.rhr", "home.spo2", "home.hrv", "home.readiness", "home.resp"], "the web's order")
        XCTAssertEqual(signals.map(\.metric), [.restingHr, .spo2, .hrv, .recovery, .respRate])
        for signal in signals {
            XCTAssertEqual(signal.page, .vitals, "\(signal.id): its sheet's Open goes to Vitals")
            XCTAssertEqual(signal.chart, Signal.Chart.none, "\(signal.id): compact cards have no chart")
        }
        XCTAssertEqual(signals, [.restingHr(fixtures.summary, variant: .compact), .spo2(fixtures.summary, variant: .compact),
                                 .hrv(fixtures.summary, variant: .compact), .recovery(fixtures.summary, variant: .compact),
                                 .respRate(fixtures.summary, variant: .compact)])
        let web = try VitalsFixtures.web("src/pages/Detail.tsx")
        XCTAssertTrue(web.contains("""
                  <RestingHrCard s={s} variant="compact" />
                  <Spo2Card s={s} variant="compact" />
                  <HrvCard s={s} variant="compact" />
                  <RecoveryCard s={s} variant="compact" />
                  <RespRateCard s={s} variant="compact" />
        """))
    }

    func testSignalCountIsTheWebs() throws {
        let fixtures = try VitalsFixtures()
        XCTAssertEqual(VitalsWords.signalCount(fixtures.summary), 5)
        let empty = try decode(Summary.self, #"""
        {"date":"2026-10-19","today":"2026-10-19","vitals":{"heart":{"label":"Resting heart","latest":null,"status":null}},
         "readiness":{"kind":"vo2max","latest":{"date":"2026-10-19","value":41,"source":"apple"}},
         "spo2":{"latest":null,"series":[],"status":null},"hrv":{"metric":"hrv_sdnn","latest":null,"series":[],"baseline":null,"status":null},
         "sleep":{"latest":null,"series":[],"change":null},"load":null,"activity":{"latest":null,"series":[]},
         "timeline":{"date":"2026-10-19","events":[]},"insights":[]}
        """#)
        XCTAssertEqual(VitalsWords.signalCount(empty), 0, "VO₂ max isn't recovery: Body shows it")
    }

    func testPressingASignalOpensItsSheetForVitals() async throws {
        let fixtures = try VitalsFixtures()
        let d = fixtures.dashboard()
        let expected: [(title: String, key: MetricKey)] = [("Resting heart rate", .restingHr), ("Blood oxygen", .spo2), ("HRV", .hrv),
                                                          ("Recovery", .recovery), ("Respiratory rate", .respRate)]
        try await HostedAccessibility.onScreen(fixtures.page(d)) { elements in
            for (title, key) in expected {
                d.metricSheet = nil
                let card = try XCTUnwrap(elements.first { $0.accessibilityHint == "Opens \(title) details" },
                                         "\(title): a card VoiceOver can press")
                XCTAssertTrue(card.accessibilityActivate(), title)
                try await Task.sleep(for: .milliseconds(100))
                XCTAssertEqual(d.metricSheet?.key, key, title)
                XCTAssertEqual(d.metricSheet?.page, .vitals, title)
                XCTAssertEqual(d.metricSheet?.section, "Your signals", title)
                XCTAssertEqual(d.metricSheet?.date, fixtures.summary.date, title)
            }
        }
    }

    // MARK: Modes

    func testModeIsTheWebsUseDay() {
        for range in [7, 30, 90, 365] {
            for (available, settled) in [(false, false), (false, true), (true, false), (true, true)] {
                XCTAssertEqual(VitalsMode.of(range: range, available: available, settled: settled), .range, "\(range)")
            }
        }
        XCTAssertEqual(VitalsMode.of(range: 1, available: true, settled: true), .day)
        XCTAssertEqual(VitalsMode.of(range: 1, available: true, settled: false), .day)
        XCTAssertEqual(VitalsMode.of(range: 1, available: false, settled: true), .range, "no hourly data: the ranges")
        XCTAssertEqual(VitalsMode.of(range: 1, available: false, settled: false), .pending, "Day picked earlier: wait for the answer")
        XCTAssertEqual(VitalsMode.days(1), 30, "Day that can't be shown is 30 days")
        XCTAssertEqual(VitalsMode.days(90), 90)
        XCTAssertEqual(VitalsMode.ranges(dayAvailable: true).map(\.label), ["Day", "7 days", "30 days", "90 days", "1 year"])
        XCTAssertEqual(VitalsMode.ranges(dayAvailable: false).map(\.label), ["7 days", "30 days", "90 days", "1 year"])
    }

    func testTrendsShowOnceAnythingWasEverSent() throws {
        let fixtures = try VitalsFixtures()
        XCTAssertTrue(VitalsMode.charted(summary: fixtures.summary, summaryFailed: false))
        let none = try decode(Summary.self, #"{"date":"2026-10-19","today":"2026-10-19","insights":[]}"#)
        XCTAssertNil(none.latestDataDate)
        XCTAssertFalse(VitalsMode.charted(summary: none, summaryFailed: false), "nothing sent yet: only the cards")
        XCTAssertTrue(VitalsMode.charted(summary: nil, summaryFailed: true), "no summary: the trends show what they have")
        XCTAssertFalse(VitalsMode.charted(summary: nil, summaryFailed: false), "still reading")
    }

    // MARK: Trend cards

    func testTrendCardsInTheWebsOrder() throws {
        let fixtures = try VitalsFixtures()
        let cards = VitalsTrendCards.cards(fixtures.trendsReply, status: fixtures.status, units: .metric)
        // The fixture: recovery, RMSSD, wrist temperature, no SDNN and no skin or body temperature.
        XCTAssertEqual(cards.map(\.metric), ["recovery", "resting_hr", "hrv_rmssd", "spo2", "resp_rate", "wrist_temp"])
        XCTAssertEqual(cards.map(\.title), ["Recovery", "Resting heart rate", "HRV (RMSSD)", "Blood oxygen", "Respiratory rate", "Wrist temperature"])
        XCTAssertEqual(cards[2].note, "WHOOP, during sleep")
        XCTAssertEqual(cards[5].note, "Apple Watch, during sleep")
        XCTAssertEqual(Set(VitalsTrendCards.metrics + VitalsTrendCards.phoneMetrics).count, 13)
        XCTAssertLessThanOrEqual(VitalsTrendCards.metrics.count + VitalsTrendCards.phoneMetrics.count, 20, "the server takes 20 at most")
        XCTAssertTrue(try VitalsFixtures.web("src/pages/Detail.tsx")
            .contains("/trends?metrics=\(VitalsTrendCards.metrics.joined(separator: ","))&days="))

        let sdnnOnly: Trends = ["hrv_sdnn": points([40, 42]), "resting_hr": points([60])]
        XCTAssertEqual(VitalsTrendCards.cards(sdnnOnly, status: nil, units: .metric).map(\.metric), ["resting_hr", "hrv_sdnn", "spo2", "resp_rate"])
        XCTAssertEqual(VitalsTrendCards.cards(sdnnOnly, status: nil, units: .metric)[1].note, "Apple Watch")
        let both: Trends = ["hrv_sdnn": points([40]), "hrv_rmssd": points([70])]
        XCTAssertEqual(VitalsTrendCards.cards(both, status: nil, units: .metric).map(\.metric), ["resting_hr", "hrv_rmssd", "hrv_sdnn", "spo2", "resp_rate"])
        let nothing = VitalsTrendCards.cards([:], status: nil, units: .metric)
        XCTAssertEqual(nothing.map(\.metric), ["resting_hr", "hrv_rmssd", "spo2", "resp_rate"], "the four always-there cards, empty")
        XCTAssertEqual(nothing.map(VitalsTrendCards.note), Array(repeating: "No data in this range", count: 4))
    }

    /// The trends' grid: the web's cards, then the iPhone's own only where they have readings, so no cell is empty.
    func testTheTrendGridHasNoEmptyCells() throws {
        let fixtures = try VitalsFixtures()
        let end = "2026-10-31"
        let web = VitalsTrendCards.cards(fixtures.trendsReply, status: fixtures.status, units: .metric).map(\.metric)
        let none = VitalsTrendCards.items([:], history: nil, days: 30, end: end, status: nil, units: .metric)
        XCTAssertEqual(none.map(\.id), ["resting_hr", "hrv_rmssd", "spo2", "resp_rate"], "no extras without readings")
        var t: Trends = ["blood_pressure_diastolic": points([80]), "glucose": points([95]), "breathing_disturbances": points([1.2])]
        let extras = VitalsTrendCards.items(t, history: nil, days: 30, end: end, status: nil, units: .metric).map(\.id)
        XCTAssertEqual(Array(extras.suffix(3)), ["blood-pressure", "glucose", "breathing-disturbances"])
        // The nightly temperature needs seven earlier nights before a night in the range.
        let history: Trends = ["wrist_temp": points(Array(repeating: 34.1, count: 40), from: "2026-09-22")]
        t = [:]
        XCTAssertEqual(VitalsTrendCards.items(t, history: history, days: 30, end: end, status: nil, units: .metric).last?.id, "temp-deviation")
        let short: Trends = ["wrist_temp": points([34.1, 34.2], from: "2026-10-20")]
        XCTAssertFalse(VitalsTrendCards.items(t, history: short, days: 30, end: end, status: nil, units: .metric).contains { $0.id == "temp-deviation" })
        let all = VitalsTrendCards.items(fixtures.trendsReply, history: nil, days: 30, end: end, status: fixtures.status, units: .metric)
        XCTAssertEqual(Array(all.map(\.id).prefix(web.count)), web, "the web's first, in its order")
    }

    func testTemperaturesAreInThePersonsUnits() {
        let t: Trends = ["body_temp": points([36.6, 37.0]), "skin_temp": points([33.5])]
        let metric = VitalsTrendCards.cards(t, status: nil, units: .metric)
        let imperial = VitalsTrendCards.cards(t, status: nil, units: .imperial)
        XCTAssertEqual(metric.map(\.metric).suffix(2), ["body_temp", "skin_temp"])
        let body = imperial.first { $0.metric == "body_temp" }!
        XCTAssertEqual(body.points.map(\.value)[0], 36.6 * 9 / 5 + 32, accuracy: 0.0001, "drawn in °F, so the axis reads °F")
        XCTAssertEqual(body.format(body.points[1].value), "98.6 °F")
        XCTAssertEqual(metric.first { $0.metric == "body_temp" }!.format(37), "37.0 °C")
        XCTAssertEqual(imperial.first { $0.metric == "skin_temp" }!.note, "WHOOP")
    }

    func testTheNoteAndTheMedian() {
        let trend = VitalsTrend(metric: "resting_hr", title: "Resting heart rate", points: points([60, 62, 58]), format: { "\(Fmt.number($0)) bpm" },
                                note: "Apple Watch")
        XCTAssertEqual(VitalsTrendCards.note(trend), "\(Fmt.day("2026-10-03")) · average 60 bpm · Apple Watch")
        XCTAssertNil(VitalsTrendCards.median([1, 2, 3, 4]), "four readings: no median line yet")
        XCTAssertEqual(VitalsTrendCards.median([5, 1, 4, 2, 3]), 3)
        XCTAssertEqual(VitalsTrendCards.median([6, 1, 5, 2, 4, 3]), 3.5)
    }

    func testWhosePageItIs() {
        let a = URL(string: "http://localhost:8801")!, b = URL(string: "http://localhost:8804")!
        XCTAssertNotEqual(VitalsScreen.identity(server: a, user: "p1"), VitalsScreen.identity(server: a, user: "p2"))
        XCTAssertNotEqual(VitalsScreen.identity(server: a, user: "p1"), VitalsScreen.identity(server: b, user: "p1"))
        XCTAssertEqual(VitalsScreen.identity(server: a, user: "p1"), VitalsScreen.identity(server: a, user: "p1"))
    }

    // MARK: What each answer does

    /// Waits on the main run loop until `done`, then lets the page draw what came.
    private func wait(_ what: String, timeout: TimeInterval = 10, until done: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !done(), Date() < end { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(done(), what, file: file, line: line)
        try await Task.sleep(for: .milliseconds(300))
    }

    private func labels(_ host: DuoHost) async throws -> [String] {
        try await host.elements().compactMap(\.accessibilityLabel)
    }

    func testADayWithHeartRateOffersTheDayView() async throws {
        let fixtures = try VitalsFixtures()
        let d = fixtures.dashboard(range: 1)
        let host = try await DuoHost(fixtures.page(d), as: .outer)
        defer { host.close() }
        try await wait("the day is read") { fixtures.days.count == 1 }
        let words = try await labels(host)
        XCTAssertTrue(words.contains("Day"), "Day is offered")
        XCTAssertTrue(words.contains("Previous day"), "and the day picker shows")
        XCTAssertTrue(words.contains("Typical (median of the last 30 days)"), "the hourly heart rate, with its key")
        XCTAssertTrue(words.contains(VitalsWords.dayFootnote))
        XCTAssertEqual(fixtures.trends, 0, "no range is read while the Day view is up")
    }

    func testAnOlderServerWithoutTheDayHidesItAndShowsTheRange() async throws {
        let fixtures = try VitalsFixtures()
        fixtures.dayReply = nil
        let d = fixtures.dashboard(range: 1)
        let host = try await DuoHost(fixtures.page(d), as: .outer)
        defer { host.close() }
        try await wait("the range is read once the day says there's none") { fixtures.trends >= 1 }
        XCTAssertEqual(fixtures.trends, 1, "read once")
        let elements = try await host.elements()
        let thirty = try XCTUnwrap(elements.first { $0.accessibilityLabel == "30 days" })
        XCTAssertTrue(thirty.accessibilityTraits.contains(.selected), "the 30 days stand in for Day")
        XCTAssertFalse(elements.contains { $0.accessibilityLabel == "Day" }, "no Day on a server without GET /day")
        XCTAssertEqual(fixtures.days, [nil])
    }

    func testAFailedDayFallsBackToTheRangeWithoutSayingItIsMissing() async throws {
        let fixtures = try VitalsFixtures()
        fixtures.dayFails = true
        let d = fixtures.dashboard(range: 1)
        let host = try await DuoHost(fixtures.page(d), as: .outer)
        defer { host.close() }
        try await wait("the range is read") { fixtures.trends >= 1 }
        XCTAssertEqual(fixtures.trends, 1, "read once")
        let words = try await labels(host).joined(separator: " | ").lowercased()
        XCTAssertFalse(words.contains("not set up") || words.contains("not available") || words.contains("isn't available")
                       || words.contains("this server"), "offline is never 'not on this server'")
        XCTAssertFalse(words.contains("| day |"), "Day isn't offered while it can't be read")
    }

    func testAFailedRangeSaysSoInTheConnectionsWords() async throws {
        let fixtures = try VitalsFixtures()
        fixtures.trendsFail = true
        let d = fixtures.dashboard(range: 30)
        let host = try await DuoHost(fixtures.page(d), as: .outer)
        defer { host.close() }
        try await wait("the range is read") { fixtures.trends == 1 }
        // The message is under the signals: scroll down to it, as a person would.
        for scroll in DuoScrollTests.verticalScrollViews(in: host.window) {
            scroll.setContentOffset(CGPoint(x: 0, y: max(0, scroll.contentSize.height - scroll.bounds.height)), animated: false)
        }
        try await host.settle()
        let words = try await labels(host)
        XCTAssertTrue(words.contains { $0.hasPrefix("Couldn't load your trends: ") && $0.contains("offline") }, "the connection's words")
        XCTAssertFalse(words.contains { $0.lowercased().contains("not set up") })
    }

    func testANewLoadReadsAgainAndAnotherRangeIsReadOnce() async throws {
        let fixtures = try VitalsFixtures()
        let d = fixtures.dashboard(range: 30)
        let host = try await DuoHost(fixtures.page(d), as: .outer)
        defer { host.close() }
        try await wait("the range and its temperatures are read") { fixtures.trends == 1 && fixtures.tempHistory == 1 }
        d.rangeDays = 7
        try await wait("another range is read") { fixtures.trends == 2 }
        d.generation += 1
        try await wait("a new load reads both again") { fixtures.trends == 3 && fixtures.days.count == 2 }
        XCTAssertEqual(fixtures.tempHistory, 3)
    }
}
