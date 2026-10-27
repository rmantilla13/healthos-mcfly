import SwiftUI
import XCTest
@testable import HealthOSSync

/// Body's models on their own (shared/body.ts, AddEntrySheet.tsx, MeasurementCard.tsx, Body.tsx): the entry form's
/// numbers and the body it sends, the cards' change line, what the server's answers decode to, the words for a refusal,
/// the tabs' specs and ranges, and the model's reads (a late answer dropped, another person's data gone).
@MainActor
final class BodyTests: XCTestCase {
    private func point(_ date: String, _ value: Double) -> Point { Point(date: date, value: value) }

    // MARK: The entry form

    func testATypedValueTakesACommaAndRefusesWords() {
        XCTAssertEqual(BodyMath.value("72,4"), 72.4)
        XCTAssertEqual(BodyMath.value(" 81.0 "), 81)
        XCTAssertNil(BodyMath.value("abc"))
        XCTAssertNil(BodyMath.value("  "))
        XCTAssertNil(BodyMath.value("1,2,3"))
    }

    func testTheRangeAndHintFollowTheUnit() {
        XCTAssertEqual(BodyMetric.weight.range(unit: "kg").low, 20)
        XCTAssertEqual(BodyMetric.weight.range(unit: "lb").low, 45, "20 kg is 44.09 lb, up to whole pounds")
        XCTAssertEqual(BodyMetric.weight.range(unit: "lb").high, 881, "400 kg is 881.8 lb, down")
        XCTAssertEqual(BodyMetric.weight.hint(unit: "kg"), "In kg, between 20 and 400.")
        XCTAssertEqual(BodyMetric.bodyFat.hint(unit: "%"), "As a percentage, between 2 and 75.")
        XCTAssertEqual(BodyMetric.bodyFat.unit(.imperial), "%")
        XCTAssertEqual(BodyMetric.leanMass.unit(.imperial), "lb")
        XCTAssertEqual(BodyMetric.weight.unit(.metric), "kg")
    }

    func testTheEntryBodySendsTheUnitTypedAndLeavesOutWhatIsEmpty() throws {
        let body = BodyMath.entryBody(metric: .weight, value: 176.4, unit: "lb", date: "2026-10-21", time: nil, method: nil, note: "  ")
        XCTAssertEqual(body["metric"] as? String, "weight")
        XCTAssertEqual(body["unit"] as? String, "lb", "imperial sends lb; the server stores kg")
        XCTAssertEqual(body["value"] as? Double, 176.4)
        XCTAssertTrue(body["time"] is NSNull)
        XCTAssertNil(body["method"])
        XCTAssertNil(body["note"])
        let full = BodyMath.entryBody(metric: .bodyFat, value: 18, unit: "%", date: "2026-10-21", time: "07:30", method: .scan, note: " after run ")
        XCTAssertEqual(full["time"] as? String, "07:30")
        XCTAssertEqual(full["method"] as? String, "scan")
        XCTAssertEqual(full["note"] as? String, "after run")
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: full))
    }

    func testTheServersWordsAreShownAndA500OrOfflineNeverSaysNotSetUp() {
        XCTAssertEqual(BodyMath.message(APIError.server(400, "Enter a weight between 20 and 400 kg.")), "Enter a weight between 20 and 400 kg.")
        XCTAssertEqual(BodyMath.message(APIError.server(409, "Turn off demo data to add your own entries.")),
                       "Turn off demo data to add your own entries.")
        XCTAssertEqual(BodyMath.message(APIError.server(404, "No such entry")), "No such entry")
        for error: Error in [APIError.server(500, ""), APIError.network("The Internet connection appears to be offline.")] {
            let words = BodyMath.message(error)
            XCTAssertFalse(words.isEmpty)
            XCTAssertFalse(words.localizedCaseInsensitiveContains("set up"), words)
            XCTAssertFalse((BodyModel.words(error) ?? "").localizedCaseInsensitiveContains("set up"))
        }
        XCTAssertNil(BodyModel.words(CancellationError()), "a cancelled read says nothing")
    }

    // MARK: The cards

    func testTheChangeLineIsAgainstAboutAMonthBefore() {
        let pts = [point("2026-09-20", 80.0), point("2026-10-05", 79.6), point("2026-10-21", 79.2)]
        XCTAssertEqual(BodyMath.aboutBefore(pts)?.date, "2026-09-20", "30 days before Oct 21 is Sep 21, within 9 days")
        XCTAssertEqual(BodyMath.change(pts, unit: "kg"), "\(Fmt.signed(-0.8, 1)) kg since \(Fmt.day("2026-09-20"))")
        XCTAssertEqual(BodyMath.change([point("2026-09-21", 18.0), point("2026-10-21", 18.4)], unit: "%"),
                       "+0.4 points since \(Fmt.day("2026-09-21"))")
        XCTAssertEqual(BodyMath.change([point("2026-09-21", 80.0), point("2026-10-21", 80.02)], unit: "kg"),
                       "about the same as \(Fmt.day("2026-09-21"))")
        XCTAssertNil(BodyMath.change([point("2026-10-10", 80.0), point("2026-10-21", 79.0)], unit: "kg"), "nothing about a month before")
        XCTAssertNil(BodyMath.change([], unit: "kg"))
    }

    func testEntriesAndLatestDecodeEachOnTheirOwn() throws {
        let entries = try JSONDecoder().decode(BodyEntries.self, from: Data("""
        {"entries":[{"id":"a","metric":"weight","value":80.1,"date":"2026-10-21"},
                    {"id":"b","metric":"weight","value":"bad","date":"2026-10-20"},
                    {"id":"c","metric":"body_fat","value":18,"date":"2026-10-19","time":"07:30","method":"scan","note":"gym"}]}
        """.utf8))
        XCTAssertEqual(entries.entries.map(\.id), ["a", "c"], "one entry the app can't read leaves out only itself")
        XCTAssertEqual(entries.entries[0].method, "other")
        XCTAssertNil(entries.entries[0].time)
        XCTAssertEqual(BodyMath.detail(entries.entries[1], today: "2026-10-21"), "\(Fmt.day("2026-10-19", "MMMd")), 07:30 · Scan · gym")

        let latest = try JSONDecoder().decode(BodyLatest.self, from: Data("""
        {"weight":{"date":"2026-10-21","value":80,"source":"fitbit"},"body_fat":{"date":1},"lean_mass":null}
        """.utf8))
        XCTAssertEqual(latest[.weight]?.sourceName, "Fitbit")
        XCTAssertNil(latest[.bodyFat])
        XCTAssertNil(latest[.leanMass])
        XCTAssertEqual(BodyLatestValue(date: "x", value: 1, source: "manual").sourceName, "Added by you")
        XCTAssertNil(BodyLatestValue(date: "x", value: 1, source: "new").sourceName)
    }

    func testWorkoutsNameFitbit() {
        XCTAssertEqual(WorkoutListRow.sourceName("fitbit"), "Fitbit")
        XCTAssertEqual(WorkoutListRow.sourceName("apple+whoop"), "Apple Health and WHOOP")
    }

    // MARK: The tabs

    func testTabsAndRanges() {
        XCTAssertEqual(BodyTab.of(["tab": "metabolism"]), .metabolism)
        XCTAssertEqual(BodyTab.of(["tab": "nope"]), .overview)
        XCTAssertEqual(BodyTab.of([:]), .overview)
        XCTAssertEqual(BodyRange.days(ChartRange.day.days), 30, "Day counts as 30 days on a tab without a Day view")
        XCTAssertEqual(BodyRange.days(90), 90)
        XCTAssertEqual(BodyActivityMode.of(rangeDays: 30, available: true, settled: true), .range)
        XCTAssertEqual(BodyActivityMode.of(rangeDays: 1, available: true, settled: true), .day)
        XCTAssertEqual(BodyActivityMode.of(rangeDays: 1, available: false, settled: false), .pending)
        XCTAssertEqual(BodyActivityMode.of(rangeDays: 1, available: false, settled: true), .range)
    }

    func testATabShowsItsAlwaysChartsAndTheOnesWithReadings() {
        let specs = BodyTrendSpec.specs(.cardiovascular)
        XCTAssertEqual(specs.map(\.key), ["resting_hr", "hrv_rmssd", "hrv_sdnn", "spo2", "resp_rate", "vo2max"])
        let shown = BodyTrendSpec.shown(specs, in: ["hrv_rmssd": [point("2026-10-21", 70)], "vo2max": []])
        XCTAssertEqual(shown.map(\.key), ["resting_hr", "hrv_rmssd", "spo2", "resp_rate"], "always, or with a reading")
        XCTAssertEqual(Array(BodyTrendSpec.specs(.metabolism).map(\.key).prefix(2)), ["weight", "body_fat"])
        XCTAssertTrue(BodyTrendSpec.specs(.overview).isEmpty)
    }

    // MARK: The model's reads

    private func reads(trends: @escaping @MainActor ([String], Int) async throws -> Trends,
                       latest: @escaping @MainActor () async throws -> BodyLatest? = { nil }) -> BodyReads {
        BodyReads(summary: { d, _ in try XCTUnwrap(d.summary) }, trends: { _, m, days, _ in try await trends(m, days) },
                  latest: { _ in try await latest() }, entries: { _, _ in nil }, add: { _, _ in }, delete: { _, _ in },
                  day: { _, _ in nil }, workouts: { _, _, _ in [] }, glucose: { _, _ in nil }, labs: { _ in throw APIError.server(500, "") })
    }

    private func signedIn() -> Dashboard {
        let d = Dashboard()
        d.authMode = "required"
        d.signedIn()
        return d
    }

    func testALateAnswerForAnOlderAskIsDropped() async {
        let d = signedIn()
        let model = BodyModel()
        var calls = 0
        let r = reads(trends: { _, _ in
            calls += 1
            if calls == 1 {
                try await Task.sleep(for: .milliseconds(300))
                return ["resting_hr": [Point(date: "2026-10-01", value: 99)]]
            }
            return ["resting_hr": [Point(date: "2026-10-21", value: 52)]]
        })
        let first = Task { await model.loadTab(.recovery, days: 30, d, reads: r) }
        try? await Task.sleep(for: .milliseconds(50))
        await model.loadTab(.recovery, days: 30, d, reads: r)
        await first.value
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(model.tabTrends(.recovery, days: 30).value?["resting_hr"]?.first?.value, 52, "the older ask's answer doesn't land")
    }

    func testAnotherPersonsAnswerNeverLandsAndTheirDataGoes() async {
        let d = signedIn()
        let model = BodyModel()
        await model.loadTab(.recovery, days: 30, d, reads: reads(trends: { _, _ in ["resting_hr": [Point(date: "2026-10-21", value: 52)]] }))
        XCTAssertNotNil(model.tabTrends(.recovery, days: 30).value)
        // Someone else signs in while a read is out: its answer is dropped, and nothing of the last person's stays.
        let late = reads(trends: { _, _ in
            d.signedIn()
            return ["resting_hr": [Point(date: "2026-10-21", value: 99)]]
        })
        await model.loadTab(.strain, days: 30, d, reads: late)
        model.adopt(d.session)
        XCTAssertNil(model.tabTrends(.recovery, days: 30).value, "the last person's tab is gone")
        XCTAssertNil(model.tabTrends(.strain, days: 30).value, "the answer read for them never lands")
    }

    func testAServerWithoutBodyRoutesCannotAdd() async throws {
        let d = signedIn()
        let f = try BodyDuoTests.fixture()
        d.apply(status: f.status)
        d.summary = f.summary
        let model = BodyModel()
        await model.loadOverview(d, reads: reads(trends: { _, _ in [:] }, latest: { nil }))
        XCTAssertFalse(BodyRows(model: model, now: f.summary, tab: .overview, dashboard: d).canAdd, "an older server's 404: no Add entry")
        // A 500 on the sources keeps adding: it isn't a missing route.
        let other = BodyModel()
        await other.loadOverview(d, reads: reads(trends: { _, _ in [:] }, latest: { throw APIError.server(500, "") }))
        XCTAssertTrue(BodyRows(model: other, now: f.summary, tab: .overview, dashboard: d).canAdd)
        XCTAssertNotNil(other.latest.failure)
    }
}
