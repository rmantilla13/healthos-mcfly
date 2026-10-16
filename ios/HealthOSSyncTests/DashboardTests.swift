import XCTest
@testable import HealthOSSync

/// The fixtures are real responses from a local server showing demo data (name and time zone scrubbed).
final class DashboardTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"), "missing fixture \(name).json")
        return try Data(contentsOf: url)
    }

    func testDecodesTheServerResponses() throws {
        let s = try JSONDecoder().decode(Summary.self, from: fixture("summary"))
        XCTAssertEqual(s.name, "Sam")
        XCTAssertEqual(s.readiness?.kind, "recovery")
        XCTAssertNotNil(s.readiness?.zone)
        XCTAssertEqual(s.load?.kind, "strain")
        XCTAssertEqual(s.hrv?.metric, "hrv_rmssd")
        XCTAssertFalse(s.timeline?.events.isEmpty ?? true)
        XCTAssertFalse(s.insights?.isEmpty ?? true)
        XCTAssertNotNil(s.week)
        XCTAssertNotNil(s.vitals?.heart?.latest)

        let vitals = try JSONDecoder().decode(Trends.self, from: fixture("trends-vitals"))
        XCTAssertFalse(vitals["resting_hr"]?.isEmpty ?? true)
        let sleep = try JSONDecoder().decode(Trends.self, from: fixture("trends-sleep"))
        XCTAssertFalse(sleep["sleep_deep"]?.isEmpty ?? true)
        let workouts = try JSONDecoder().decode([Workout].self, from: fixture("workouts"))
        XCTAssertGreaterThan(workouts.first?.durationMin ?? 0, 0)
        let status = try JSONDecoder().decode(ServerStatus.self, from: fixture("status"))
        XCTAssertEqual(status.settings?.units, "metric")
    }

    func testANewOrBrokenSectionOnlyHidesThatCard() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture("summary")) as? [String: Any])
        json["readiness"] = ["kind": "readiness_v2", "score": "high"] // no `latest`: can't be read
        json["load"] = "unexpected"
        json["week"] = nil
        json["somethingNew"] = [1, 2, 3]
        let s = try JSONDecoder().decode(Summary.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(s.readiness)
        XCTAssertNil(s.load)
        XCTAssertNil(s.week)
        XCTAssertNotNil(s.sleep?.latest)
        XCTAssertNotNil(s.activity?.latest)
    }

    func testTheCachedSummaryRoundTrips() throws {
        let s = try JSONDecoder().decode(Summary.self, from: fixture("summary"))
        let again = try JSONDecoder().decode(Summary.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(again.readiness?.latest.value, s.readiness?.latest.value)
        XCTAssertEqual(again.timeline?.events.count, s.timeline?.events.count)
    }

    func testWeekSummaryReadsLikeTheWeb() {
        let w = WeekSummary(
            start: "2026-10-12", end: "2026-10-16", days: 5,
            sleep: .init(avg: 7.4, prev: 7.0),
            steps: .init(avg: 10_067.8, prev: 8_377.2, goalDays: 3, daysWithData: 5),
            workouts: .init(count: 6, minutes: 340),
            hrv: .init(avg: 72.5, prev: 71.2),
            restingHr: .init(avg: 51.6, prev: 53.6),
            recovery: .init(avg: 64.26, prev: 66.8))
        XCTAssertEqual(
            String(WeekText.body(w, stepGoal: 10_000).characters),
            "You're sleeping 7h 24m a night, 24 min more than last week. Steps average 10,070 a day (up 20%), with your goal met on 3 of 5 days; 6 workouts logged (5h 40m). Resting heart rate is down 2.0 bpm, HRV is holding steady and recovery averages 64%.")
        XCTAssertEqual(WeekText.title(w), "Week so far · Mon–Fri")
    }

    func testFormattingMatchesTheWeb() {
        XCTAssertEqual(Fmt.hoursMinutes(7.4), "7h 24m")
        XCTAssertEqual(Fmt.duration(minutes: 45), "45m")
        XCTAssertEqual(Fmt.compact(10_000), "10K")
        XCTAssertEqual(Fmt.compact(12_400), "12.4K")
        XCTAssertEqual(Fmt.signed(-3.2, 1), "−3.2")
        XCTAssertEqual(Fmt.clock("2026-10-15T22:20:00-05:00"), "22:20")
        XCTAssertEqual(Fmt.minutesOfDay("2026-10-16T06:28:00-05:00"), 388)
        XCTAssertEqual(Fmt.relativeDay("2026-10-15", today: "2026-10-16"), "Yesterday")
        XCTAssertEqual(Units.imperial.mass(80).text(1), "176.4 lb")
    }

    func testLongRangesAverageByWeek() {
        let days = (0..<14).map { Point(date: Day.add("2026-10-05", $0), value: Double($0)) } // Mon 5th .. Sun 18th
        let weeks = days.weekly(days: 365)
        XCTAssertEqual(weeks.map(\.date), ["2026-10-05", "2026-10-12"])
        XCTAssertEqual(weeks.map(\.value), [3, 10])
        XCTAssertEqual(days.weekly(days: 30).count, 14)
    }
}
