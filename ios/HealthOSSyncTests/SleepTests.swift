import SwiftUI
import XCTest
@testable import HealthOSSync

// The Sleep page's models (Sleep/): the night's decoding, the clock arithmetic, the cards' rules and words against
// src/pages/Sleep.tsx, the tabs a server has, and the page model's reads: one per date and load, a late one dropped, a
// missing route hiding its feature and a failure never reading as "not set up". Slice J owns this file. The fixtures
// are a local test server's made-up demo answers (Fixtures/sleep-*.json).

func sleepFixture(_ name: String) throws -> Data {
    let url = Bundle(for: SleepTests.self).url(forResource: name, withExtension: "json")
        ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name).json")
    return try Data(contentsOf: url)
}

func sleepDecode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
    try JSONDecoder().decode(T.self, from: try sleepFixture(name))
}

func sleepStatus(_ json: String) throws -> ServerStatus {
    try JSONDecoder().decode(ServerStatus.self, from: Data(json.utf8))
}

/// The demo's status: demo data on, WHOOP connected, every card at its default.
let sleepDemoStatus = #"{"hosted":false,"demo":true,"settings":{"name":"Sam","hiddenCards":[],"shownCards":[],"timeZone":"America/New_York"},"whoop":{"configured":true,"connected":true,"lastSync":null},"apple":{"lastSync":null,"lastImport":null},"fitbit":{"lastImport":null}}"#
/// A new account: no source and no night ever.
let sleepNewStatus = #"{"hosted":false,"demo":false,"settings":{"name":"Sam","hiddenCards":[],"shownCards":[]},"whoop":{"configured":true,"connected":false,"lastSync":null},"apple":{"lastSync":null,"lastImport":null},"fitbit":{"lastImport":null}}"#

@MainActor
final class SleepTests: XCTestCase {
    // MARK: The night

    func testTheDemoNightDecodes() throws {
        let n = try sleepDecode(SleepNightDetail.self, "sleep-night")
        XCTAssertEqual(n.date, "2026-10-26")
        XCTAssertEqual(n.source, "apple")
        XCTAssertGreaterThan(n.segments.count, 10)
        XCTAssertTrue(n.staged)
        XCTAssertNotNil(n.performance)
        XCTAssertNotNil(n.efficiency)
        XCTAssertEqual(n.lastNight, .night("2026-10-26"))
        XCTAssertFalse(n.noNights)
        XCTAssertEqual(n.insights.map(\.id), ["latency", "consistency"])
        let empty = try sleepDecode(SleepNightDetail.self, "sleep-night-empty")
        XCTAssertNil(empty.asleepHours)
        XCTAssertTrue(empty.segments.isEmpty)
        XCTAssertNil(empty.stageTotals)
    }

    /// lastNight missing (an older server) is the full page; null is "no night ever"; one bad stretch is dropped.
    func testOlderAndOddShapes() throws {
        let older = try JSONDecoder().decode(SleepNightDetail.self, from: Data(#"{"date":"2026-10-20","today":"2026-10-27","segments":[],"insights":[]}"#.utf8))
        XCTAssertEqual(older.lastNight, .unknown)
        XCTAssertFalse(older.noNights)
        XCTAssertNil(older.performance, "servers older than the three cards send no performance")
        let none = try JSONDecoder().decode(SleepNightDetail.self, from: Data(#"{"date":"2026-10-27","today":"2026-10-27","lastNight":null,"segments":[],"insights":[]}"#.utf8))
        XCTAssertEqual(none.lastNight, .none)
        XCTAssertTrue(none.noNights)
        let odd = try JSONDecoder().decode(SleepNightDetail.self, from: Data(#"""
        {"date":"2026-10-26","today":"2026-10-27","asleepHours":"seven","stages":{"awake":0.5},
         "segments":[{"start":"2026-10-25T23:00:00-04:00","end":"2026-10-25T23:30:00-04:00","stage":"light"},{"start":3}],
         "insights":[{"id":"a","icon":"moon","text":"One"},{"oops":true}]}
        """#.utf8))
        XCTAssertNil(odd.asleepHours)
        XCTAssertNil(odd.stages, "a stage total it can't read is no totals, not zeros")
        XCTAssertEqual(odd.segments.count, 1)
        XCTAssertEqual(odd.insights.map(\.id), ["a"])
        XCTAssertEqual(odd.stageTotals?.light ?? 0, 0.5, accuracy: 0.001, "a staged night with no totals adds up its stretches")
    }

    // MARK: Clocks

    func testClocksKeepTheNightsOwnOffset() throws {
        XCTAssertEqual(SleepClock.offset("2026-10-25T23:18:00-04:00"), -240)
        XCTAssertEqual(SleepClock.offset("2026-10-25T23:18:00+05:30"), 330)
        XCTAssertEqual(SleepClock.offset("2026-10-25T23:18:00Z"), 0)
        XCTAssertEqual(SleepClock.wall("2026-10-25T23:18:00-04:00"), "23:18")
        let t = try XCTUnwrap(SleepClock.time("2026-10-26T04:00:00.000Z"))
        XCTAssertEqual(SleepClock.local(t, offsetIso: "2026-10-25T23:18:00-04:00"), "00:00")
        // The night the clocks go back: the axis and the facts follow the offset in force at each moment.
        let segs = [SleepNightDetail.Segment(start: "2026-11-01T00:30:00-04:00", end: "2026-11-01T01:30:00-05:00", stage: "light")]
        let after = try XCTUnwrap(SleepClock.time("2026-11-01T01:45:00-05:00"))
        XCTAssertEqual(SleepClock.at(after, segments: segs, fallback: segs[0].start), "01:45")
        let from = try XCTUnwrap(SleepClock.time("2026-10-25T22:52:00-04:00")), to = try XCTUnwrap(SleepClock.time("2026-10-26T06:34:00-04:00"))
        let ticks = SleepClock.hourTicks(from: from, to: to, every: 3, offsetIso: "2026-10-25T22:52:00-04:00") { SleepClock.local($0, offsetIso: "-04:00") }
        XCTAssertEqual(ticks.map(\.label), ["00:00", "03:00", "06:00"], "the hypnogram's hours at phone width, as the web's 375")
    }

    // MARK: The three cards

    func testTheCardsRules() throws {
        let night = try sleepDecode(SleepNightDetail.self, "sleep-night")
        let demo = SleepNightContext(night: night, status: try sleepStatus(sleepDemoStatus))
        XCTAssertFalse(demo.bare)
        XCTAssertTrue(demo.whoop)
        XCTAssertEqual(demo.label, "Night to Mon, Oct 26")
        XCTAssertEqual(demo.source, "Demo data")
        let none = try JSONDecoder().decode(SleepNightDetail.self, from: Data(#"{"date":"2026-10-27","today":"2026-10-27","lastNight":null,"segments":[],"insights":[]}"#.utf8))
        let bare = SleepNightContext(night: none, status: try sleepStatus(sleepNewStatus))
        XCTAssertTrue(bare.bare, "no source and no night ever: the bare page")
        XCTAssertFalse(bare.whoop)
        XCTAssertEqual(bare.label, "Last night")
        XCTAssertFalse(SleepNightContext(night: none, status: try sleepStatus(sleepDemoStatus)).bare, "the demo counts as a source")
        XCTAssertFalse(SleepNightContext(night: night, status: try sleepStatus(sleepNewStatus)).bare, "a night counts")

        XCTAssertEqual(SleepWords.band(85), "Good")
        XCTAssertEqual(SleepWords.band(84.9), "Fair")
        XCTAssertEqual(SleepWords.band(70), "Fair")
        XCTAssertEqual(SleepWords.band(69), "Low")
        XCTAssertEqual(SleepScoreBar.nearest(89), 80)
        XCTAssertEqual(SleepScoreBar.nearest(93), 100)
        XCTAssertEqual(SleepNightCard.score(89), "89")
        XCTAssertEqual(SleepNightCard.score(89.5), "89.5")
        XCTAssertFalse(SleepChangeChip.shows(0.4))
        XCTAssertTrue(SleepChangeChip.shows(-2.1))
        XCTAssertFalse(SleepChangeChip.shows(nil))
    }

    func testStagesNotesBySourceAndAge() {
        XCTAssertEqual(SleepWords.stagesNote(source: "whoop", date: "2026-10-01", today: "2026-10-27"), SleepWords.whoopStages)
        XCTAssertEqual(SleepWords.stagesNote(source: "fitbit", date: "2026-10-01", today: "2026-10-27"), SleepWords.fitbitStages)
        XCTAssertEqual(SleepWords.stagesNote(source: "apple", date: "2026-09-27", today: "2026-10-27"), SleepWords.resentStages, "30 days: the iPhone sends it again")
        XCTAssertEqual(SleepWords.stagesNote(source: "apple", date: "2026-09-26", today: "2026-10-27"), SleepWords.oldStages)
    }

    func testInsightRows() throws {
        let night = try sleepDecode(SleepNightDetail.self, "sleep-night")
        let summary = try sleepDecode(Summary.self, "sleep-summary")
        let rows = SleepInsightRow.rows(night: night, home: summary.insights ?? [], patterns: [])
        // The night's two, and not Home's bedtime one, which says what "consistency" already says.
        XCTAssertEqual(rows.map(\.id), ["latency", "consistency"])
        XCTAssertEqual(rows.map(\.tab), [.stages, .trends])
        let patterns = try JSONDecoder().decode(Patterns.self, from: Data(#"""
        {"start":"2026-04-30","end":"2026-10-26","patterns":[
          {"id":"p1","icon":"steps","text":"On days with 10k+ steps, you tend to sleep 24 min longer that night.","detail":"Based on 41 days.","n":41,"effect":24,"unit":"min","page":"sleep"},
          {"id":"p2","icon":"heart","text":"Elsewhere.","detail":"x","n":9,"effect":1,"unit":"bpm","page":"vitals"},
          {"id":"p3","icon":"spark","text":"Another.","detail":"y","n":9,"effect":1,"unit":"min","page":"sleep"}]}
        """#.utf8))
        let debt = Insight(id: "debt", icon: "moon", text: "Made-up debt line.", date: "2026-10-26", page: "sleep")
        let all = SleepInsightRow.rows(night: night, home: [debt], patterns: patterns.patterns)
        XCTAssertEqual(all.map(\.id), ["latency", "consistency", "home-debt", "p1"], "four at most, the sleep patterns only")
        XCTAssertEqual(all.last?.note, "Based on 41 days.")
        XCTAssertEqual(all.last?.tab, .coaching)
        XCTAssertEqual(SleepInsightRow.style("spark").1, .blue)
    }

    // MARK: Stages, Trends, Coaching

    func testStageNightsAndTheirWeeks() throws {
        let t = try sleepDecode(Trends.self, "sleep-stages")
        let month = SleepStageNights(t, days: 30)
        XCTAssertFalse(month.weekly)
        XCTAssertEqual(month.rows, month.nights)
        XCTAssertGreaterThan(month.nights.count, 20)
        XCTAssertEqual(Double(month.totals.reduce(0) { $0 + $1.share }), 100, accuracy: 2)
        // Past 90 days, one bar a week: each stage's sum over the week's nights, divided by its nights.
        let made: Trends = ["sleep_deep": [Point(date: "2026-10-19", value: 1), Point(date: "2026-10-20", value: 2)],
                            "sleep_rem": [Point(date: "2026-10-20", value: 2)], "sleep_hours": [Point(date: "2026-10-19", value: 7)]]
        let year = SleepStageNights(made, days: 365)
        XCTAssertTrue(year.weekly)
        XCTAssertEqual(year.rows.count, 1)
        XCTAssertEqual(year.rows[0].date, "2026-10-19")
        XCTAssertEqual(year.rows[0].values["sleep_deep"], 1.5)
        XCTAssertEqual(year.rows[0].values["sleep_rem"], 1, "REM's 2 over the week's two nights, as the web divides")
        XCTAssertEqual(year.mean("sleep_rem"), 1)
        XCTAssertEqual(year.average, 7)
        XCTAssertEqual(SleepPage.rangeDays(1), 30, "Day reads as 30 days here, as on the web")
        XCTAssertEqual(SleepPage.rangeDays(90), 90)
    }

    func testTrendsShowWhatTheRangeHas() throws {
        let t = try sleepDecode(Trends.self, "sleep-trends")
        let specs = SleepTrendCards.specs(t)
        XCTAssertEqual(specs.first?.title, "Time asleep")
        XCTAssertEqual(Set(specs.map(\.id)).subtracting(t.filter { !$0.value.isEmpty }.map(\.key)), [])
        XCTAssertEqual(SleepTrendCards.specs([:]).map(\.title), ["Time asleep"], "time asleep always, the rest only with data")
        XCTAssertNil(SleepTrendCard.median([Point(date: "2026-10-01", value: 1)]))
        let five = (1...5).map { Point(date: "2026-10-0\($0)", value: Double($0)) }
        XCTAssertEqual(SleepTrendCard.median(five), 3)
        let gap = [Point(date: "2026-10-01", value: 1), Point(date: "2026-10-04", value: 1), Point(date: "2026-10-08", value: 1)]
        XCTAssertEqual(SleepTrendCard.runs(gap).map(\.count), [2, 1], "the line breaks after more than three days")
    }

    func testCoachingWords() throws {
        XCTAssertEqual(SleepWords.needsAWeek(1), "This needs a week of nights. There is 1 so far.")
        XCTAssertEqual(SleepWords.needsAWeek(3), "This needs a week of nights. There are 3 so far.")
        XCTAssertEqual(SleepWords.fromSix(330), "23:30")
        XCTAssertEqual(SleepWords.fromSix(430), "01:10")
        XCTAssertEqual(SleepWords.ofDay(406.6), "06:47")
        let st = try sleepDecode(SleepTiming.self, "sleep-timing").stats
        let stats = try XCTUnwrap(st)
        XCTAssertGreaterThanOrEqual(stats.nights, 7)
        let foot = SleepWords.usualTimesFoot(stats)
        if let j = stats.socialJetlag, abs(j) >= 30 {
            XCTAssertTrue(foot.hasPrefix("Weekends run "), foot)
        } else {
            XCTAssertEqual(foot, "Over \(stats.nights) nights")
        }
    }

    /// Every sentence the page shows is the web's own.
    func testTheWordsAreSleepTsx() throws {
        let web = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("src/pages/Sleep.tsx"), encoding: .utf8)
        let quoted = [SleepWords.title, SleepWords.sub, SleepWords.subNone, SleepWords.noNight, SleepWords.performanceFoot, SleepWords.efficiencyFoot,
                      SleepWords.whoopOnly, SleepWords.noWhoopNight, SleepWords.sleepChange, SleepWords.noStages, SleepWords.whoopStages,
                      SleepWords.fitbitStages, SleepWords.resentStages, SleepWords.oldStages, SleepWords.insightsEmpty, SleepWords.whoopTimeline,
                      SleepWords.noRestingHr, SleepWords.needNote, SleepWords.needTwoWeeks, SleepWords.debtNote, SleepWords.patternsEmpty,
                      SleepWords.patternsNote, "This needs a week of nights.", "Couldn't load your sleep: ", "Last night", "Night to ",
                      "An average night", "nights with stages", "average time asleep", "Sleep stages, weekly average", "Usual times",
                      "Your sleep need", "Sleep debt, last 7 days", "short of your need", "What goes with your better nights",
                      "Below your usual", "Within your usual", "Above your usual", "Sleep insights", "Sleep timeline", "Fell asleep",
                      "Deepest sleep", "Woke up", "In bed", "WHOOP: sleep vs sleep needed", "Time asleep ÷ time in bed", "Time in bed",
                      "Sleep consistency", "Deep sleep", "REM sleep", "Time asleep"]
            + SleepWords.performanceNoReading + SleepWords.efficiencyNoReading + SleepTab.allCases.map(\.label)
        for words in quoted {
            XCTAssertTrue(web.contains(words), "Sleep.tsx says “\(words)”")
        }
        XCTAssertFalse(SleepWords.couldntLoad("x").localizedCaseInsensitiveContains("set up"), "a failure never says it isn't set up")
        XCTAssertTrue(web.contains("const RESENT_DAYS = \(SleepWords.resentDays)"))
    }

    // MARK: The page's tabs and reads

    func testALinksTab() {
        XCTAssertEqual(SleepTab(query: "stages"), .stages)
        XCTAssertEqual(SleepTab(query: "coaching"), .coaching)
        XCTAssertEqual(SleepTab(query: nil), .overview)
        XCTAssertEqual(SleepTab(query: "nonsense"), .overview)
    }

    /// Answers that count and can wait, in the server's place.
    private final class Reads {
        var nights: [String: SleepNightDetail] = [:]
        var nightAsked: [String] = []
        var hold: String?
        var held: CheckedContinuation<Void, Never>?
        var nightError: Error?
        var nightMissing = false
        var timingMissing = false
        var trendsError: Error?
        var trendsAsked = 0

        @MainActor var reads: SleepReads {
            SleepReads(
                night: { _, date in
                    let key = date ?? "today"
                    self.nightAsked.append(key)
                    if self.hold == key { await withCheckedContinuation { self.held = $0 } }
                    if let e = self.nightError { throw e }
                    if self.nightMissing { return nil }
                    return self.nights[key] ?? SleepNightDetail(date: date ?? "2026-10-27", today: "2026-10-27")
                },
                restingHr: { _, _ in [] },
                patterns: { _ in nil },
                timing: { _ in self.timingMissing ? nil : SleepTiming(nights: [], stats: nil) },
                trends: { _, _, _ in
                    self.trendsAsked += 1
                    if let e = self.trendsError { throw e }
                    return ["sleep_hours": [Point(date: "2026-10-26", value: 7)]]
                })
        }
    }

    func testALateNightIsDropped() async throws {
        let fake = Reads()
        fake.hold = "2026-10-20"
        let model = SleepModel()
        let d = Dashboard()
        let reads = fake.reads
        let older = Task { await model.loadNight(date: "2026-10-20", generation: 1, reads: reads, dashboard: d) }
        while fake.held == nil { try await Task.sleep(for: .milliseconds(10)) }
        await model.loadNight(date: "2026-10-21", generation: 1, reads: reads, dashboard: d)
        XCTAssertEqual(model.night.value?.date, "2026-10-21")
        fake.held?.resume()
        await older.value
        XCTAssertEqual(model.night.value?.date, "2026-10-21", "the answer for the night left behind lands on nobody")
        // The same night and load again: nothing is read.
        let asked = fake.nightAsked.count
        await model.loadNight(date: "2026-10-21", generation: 1, reads: reads, dashboard: d)
        XCTAssertEqual(fake.nightAsked.count, asked)
        // A new load reads it again, keeping the night on screen meanwhile.
        await model.loadNight(date: "2026-10-21", generation: 2, reads: reads, dashboard: d)
        XCTAssertEqual(fake.nightAsked.count, asked + 1)
    }

    func testAnOlderServerHidesWhatItHasntGot() async {
        let fake = Reads()
        fake.nightMissing = true
        fake.timingMissing = true
        let model = SleepModel(tab: .overview)
        let d = Dashboard()
        await model.loadNight(date: nil, generation: 1, reads: fake.reads, dashboard: d)
        await model.loadTiming(generation: 1, reads: fake.reads, dashboard: d)
        XCTAssertEqual(model.tabs, [.stages, .trends], "no night and no bed times: no Overview and no Coaching")
        XCTAssertEqual(model.shownTab, .stages)
    }

    func testAFailureSaysSoAndNeverHides() async {
        let fake = Reads()
        fake.nightError = URLError(.notConnectedToInternet)
        let model = SleepModel()
        let d = Dashboard()
        await model.loadNight(date: nil, generation: 1, reads: fake.reads, dashboard: d)
        guard case .failed(let message) = model.night else { return XCTFail("offline is a failure, not a missing route") }
        XCTAssertFalse(message.isEmpty)
        XCTAssertEqual(model.tabs, SleepTab.allCases, "offline hides nothing")
        // Trends: a failure on a new range leaves the last one on screen.
        await model.loadTrends(stages: false, days: 30, generation: 1, reads: fake.reads, dashboard: d)
        XCTAssertNotNil(model.trendsTrends.value)
        fake.trendsError = URLError(.timedOut)
        await model.loadTrends(stages: false, days: 90, generation: 1, reads: fake.reads, dashboard: d)
        XCTAssertNotNil(model.trendsTrends.value, "what's on screen stays")
    }

    // MARK: The API

    func testTheNightsRoute() async throws {
        let base = try XCTUnwrap(URL(string: "http://sleep.example.test"))
        APIClient.answering(with: [SleepStubProtocol.self])
        defer {
            APIClient.answering(with: [])
            SleepStubProtocol.reply = (200, "{}")
            SleepStubProtocol.asked = []
        }
        SleepStubProtocol.reply = (200, String(decoding: try sleepFixture("sleep-night"), as: UTF8.self))
        let night = try await APIClient(base: base).sleepNight(date: "2026-10-26")
        XCTAssertEqual(night?.date, "2026-10-26")
        XCTAssertEqual(SleepStubProtocol.asked.last, "/api/sleep/night?date=2026-10-26")
        // An older server's catch-all 404: no night view, no error.
        SleepStubProtocol.reply = (404, #"{"error":"Not found"}"#)
        let missing = try await APIClient(base: base).sleepNight(date: nil)
        XCTAssertNil(missing)
        XCTAssertEqual(SleepStubProtocol.asked.last, "/api/sleep/night")
        // A server error is an error: the page says it couldn't load, never that the feature isn't there.
        SleepStubProtocol.reply = (500, #"{"error":"Something broke"}"#)
        do {
            _ = try await APIClient(base: base).sleepNight(date: nil)
            XCTFail("a 500 throws")
        } catch {}
        SleepStubProtocol.reply = (200, String(decoding: try sleepFixture("sleep-rhr"), as: UTF8.self))
        let rhr = try await APIClient(base: base).sleepRestingHr(date: "2026-10-26")
        XCTAssertFalse(rhr.isEmpty)
        XCTAssertEqual(SleepStubProtocol.asked.last, "/api/trends?metrics=resting_hr&days=14&date=2026-10-26")
    }
}

/// Answers every request with `reply`, and notes what was asked.
final class SleepStubProtocol: URLProtocol {
    nonisolated(unsafe) static var reply: (Int, String) = (200, "{}")
    nonisolated(unsafe) static var asked: [String] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let url = request.url { Self.asked.append(url.path + (url.query.map { "?\($0)" } ?? "")) }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: Self.reply.0, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.reply.1.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
