import SwiftUI
import XCTest
@testable import HealthOSSync

/// The fixtures are real responses from a local server showing demo data (name and time zone scrubbed). day, cycle,
/// sleep, patterns and digest are written by hand from shared/types.ts and the feature contract.
final class DashboardTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        // Fixtures added since the last `xcodegen generate` aren't in the bundle yet; read those next to this file.
        let url = Bundle(for: Self.self).url(forResource: name, withExtension: "json")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name).json")
        return try XCTUnwrap(try? Data(contentsOf: url), "missing fixture \(name).json")
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

    func testReadsSignInStateFromOldAndNewServers() throws {
        let old = try JSONDecoder().decode(AuthState.self, from: Data(#"{"mode":"required","authenticated":false}"#.utf8))
        XCTAssertFalse(old.usesAccounts)
        XCTAssertNil(old.user)

        let new = try JSONDecoder().decode(AuthState.self, from: Data(#"{"mode":"required","authenticated":true,"setup":false,"user":{"id":"u1","email":"sam@example.com","name":"Sam","role":"admin"}}"#.utf8))
        XCTAssertTrue(new.usesAccounts)
        XCTAssertEqual(new.user?.email, "sam@example.com")

        let fresh = try JSONDecoder().decode(AuthState.self, from: Data(#"{"mode":"required","authenticated":false,"setup":true,"user":null}"#.utf8))
        XCTAssertTrue(fresh.usesAccounts)
        XCTAssertNil(fresh.user)
    }

    func testInviteCodesAndLinksBothWork() {
        XCTAssertEqual(APIClient.inviteToken(from: "  ABCD-EFGH \n"), "ABCD-EFGH")
        // Link tokens are case-sensitive base64url: keep case, dashes and underscores.
        XCTAssertEqual(APIClient.inviteToken(from: "https://health.mcfly.bot/#/invite/aB3-x_Yz9Q"), "aB3-x_Yz9Q")
        XCTAssertEqual(APIClient.inviteToken(from: "https://health.mcfly.bot/#/invite/aB3-x_Yz9Q?from=admin"), "aB3-x_Yz9Q")
        XCTAssertEqual(APIClient.inviteToken(from: ""), "")
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

    func testDecodesTheNewerEndpoints() throws {
        let day = try JSONDecoder().decode(DayData.self, from: fixture("day"))
        XCTAssertEqual(day.asOf, 14)
        XCTAssertEqual(day.steps?.hours.count, 24)
        XCTAssertEqual(day.steps?.hours[8], 1180)
        XCTAssertNil(day.steps?.hours[20])
        XCTAssertEqual(day.steps?.total?.source, "apple")
        XCTAssertEqual(day.heartRate?.min?.count, 24)
        XCTAssertEqual(day.heartRate?.max?[8], 156)
        XCTAssertNil(day.activeEnergy?.min)

        let cycle = try JSONDecoder().decode(CycleData.self, from: fixture("cycle"))
        XCTAssertTrue(cycle.enabled)
        XCTAssertEqual(cycle.current?.day, 19)
        XCTAssertEqual(cycle.estimate?.nextPeriod.date, "2026-10-27")
        XCTAssertEqual(cycle.estimate?.fertile.start, "2026-10-08")
        XCTAssertEqual(cycle.stats?.cycleDays, 29)
        XCTAssertEqual(cycle.periods.count, 4)
        XCTAssertEqual(cycle.days.first?.periodStart, true)
        XCTAssertEqual(cycle.days.first(where: { $0.spotting == true })?.date, "2026-10-09")
        XCTAssertEqual(cycle.phase?.name, "luteal")
        XCTAssertEqual(cycle.phase?.nextPeriodIn, 11)
        XCTAssertTrue(cycle.phase?.luteal ?? false)

        let sleep = try JSONDecoder().decode(SleepTiming.self, from: fixture("sleep"))
        XCTAssertEqual(sleep.nights.count, 14)
        XCTAssertEqual(sleep.nights[0].midMin, 592.5)
        XCTAssertTrue(sleep.nights[0].weekend)
        XCTAssertEqual(sleep.stats?.debtNights, 7)
        XCTAssertEqual(sleep.stats?.socialJetlag ?? 0, 63.6, accuracy: 0.01)

        let patterns = try JSONDecoder().decode(Patterns.self, from: fixture("patterns"))
        XCTAssertEqual(patterns.patterns.map(\.id), ["steps_sleep", "late_workout_hrv", "short_sleep_rhr"])
        XCTAssertEqual(patterns.patterns[1].effect, -6.2)
        XCTAssertEqual(patterns.patterns[0].n, 41)

        let digest = try JSONDecoder().decode(DigestReply.self, from: fixture("digest"))
        XCTAssertTrue(digest.configured)
        XCTAssertEqual(digest.digest?.weekEnd, "2026-10-11")
        XCTAssertNil(digest.reason)
        let off = try JSONDecoder().decode(DigestReply.self, from: Data(#"{"configured":false,"digest":null,"reason":"not_configured"}"#.utf8))
        XCTAssertNil(off.digest)
        XCTAssertEqual(off.reason, "not_configured")
    }

    func testOlderOrOddResponsesStillDecode() throws {
        // A short hours array is padded to 24, and a metric the app can't read drops only itself.
        let day = try JSONDecoder().decode(DayData.self, from: Data(#"{"date":"2026-10-16","today":"2026-10-16","asOf":null,"metrics":{"steps":{"hours":[1,2,null],"typical":[]},"flights":{"perHour":true}}}"#.utf8))
        XCTAssertEqual(day.steps?.hours.count, 24)
        XCTAssertEqual(day.steps?.typical.count, 24)
        XCTAssertEqual(day.metrics.keys.sorted(), ["steps"])
        XCTAssertNil(day.asOf)

        // A cycle reply from before `phase`, with cycle tracking off.
        let cycle = try JSONDecoder().decode(CycleData.self, from: Data(#"{"enabled":false,"today":"2026-10-16","days":[],"periods":[],"cycles":[],"stats":{"cycleDays":null,"periodDays":null,"shortest":null,"longest":null},"current":null,"estimate":null,"noEstimate":null,"ovulations":[]}"#.utf8))
        XCTAssertFalse(cycle.enabled)
        XCTAssertNil(cycle.phase)
        XCTAssertNil(cycle.current)

        // Too few nights for any stats.
        let sleep = try JSONDecoder().decode(SleepTiming.self, from: Data(#"{"nights":[],"stats":{"nights":0,"avgBedMin":null,"avgWakeMin":null,"bedSd":null,"wakeSd":null,"midWeekday":null,"midWeekend":null,"socialJetlag":null,"need":null,"debt":null,"debtNights":0}}"#.utf8))
        XCTAssertTrue(sleep.nights.isEmpty)
        XCTAssertNil(sleep.stats?.need)
    }

    func testAMalformedFlagDropsOnlyItself() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture("summary")) as? [String: Any])
        XCTAssertTrue(try JSONDecoder().decode(Summary.self, from: JSONSerialization.data(withJSONObject: json)).flags.isEmpty, "servers before flags")

        json["flags"] = [
            ["id": "rhr_temp", "tone": "caution", "title": "Your body may be under strain", "text": "Resting heart rate has been about 6 bpm above your usual for 2 days and your temperature is up.", "page": "vitals"],
            ["id": "broken", "tone": "caution"], // no title or text
            NSNull(),
            ["id": "rhr_up", "tone": "info", "title": "Resting heart rate is up", "text": "It has been above your usual for 3 days.", "page": "vitals"],
        ] as [Any]
        let s = try JSONDecoder().decode(Summary.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(s.flags.map(\.id), ["rhr_temp", "rhr_up"])
        XCTAssertTrue(s.flags[0].caution)
        XCTAssertFalse(s.flags[1].caution)
        XCTAssertNotNil(s.sleep?.latest)
        XCTAssertFalse(s.insights?.isEmpty ?? true)

        // The offline cache keeps them.
        let again = try JSONDecoder().decode(Summary.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(again.flags.map(\.id), ["rhr_temp", "rhr_up"])

        json["flags"] = "unexpected"
        XCTAssertTrue(try JSONDecoder().decode(Summary.self, from: JSONSerialization.data(withJSONObject: json)).flags.isEmpty)
    }

    func testCycleIsASectionOnlyWhenTracking() {
        XCTAssertEqual(TrendsSection(page: "cycle"), .cycle)
        XCTAssertEqual(TrendsSection.cycle.rawValue, "Cycle")
        XCTAssertEqual(TrendsSection.visible(cycleTracking: false), [.vitals, .sleep, .activity, .body])
        XCTAssertEqual(TrendsSection.visible(cycleTracking: true), [.vitals, .sleep, .activity, .body, .cycle])
    }

    func testRollingMeanCountsCalendarDays() {
        let points = [
            Point(date: "2026-10-01", value: 80),
            Point(date: "2026-10-02", value: 82),
            Point(date: "2026-10-03", value: 84),
            Point(date: "2026-10-10", value: 70), // a week later: the earlier days are out of its 7-day window
            Point(date: "2026-10-11", value: 72),
        ]
        let r = points.rolling(days: 7)
        XCTAssertEqual(r.map(\.date), points.map(\.date))
        XCTAssertEqual(r.map(\.value), [80, 81, 82, 70, 71])
        XCTAssertEqual(points.rolling(days: 30).last?.value ?? 0, 77.6, accuracy: 0.0001)
        XCTAssertEqual(points.reversed().rolling(days: 7).map(\.value), [80, 81, 82, 70, 71], "sorted first")
    }

    func testWeeklySumsStartOnMonday() {
        // Sun 4th, Mon 5th .. Sun 18th, then Wed 21st.
        let points = [Point(date: "2026-10-04", value: 100)]
            + (0..<14).map { Point(date: Day.add("2026-10-05", $0), value: Double($0 + 1)) }
            + [Point(date: "2026-10-21", value: 5)]
        let weeks = points.weeklySums(weeks: 4, ending: "2026-10-22")
        XCTAssertEqual(weeks.map(\.date), ["2026-09-28", "2026-10-05", "2026-10-12", "2026-10-19"])
        XCTAssertEqual(weeks.map(\.value), [100, 28, 77, 5])
        // Weeks with nothing are there, at 0.
        XCTAssertEqual(points.weeklySums(weeks: 2, ending: "2026-11-02").map(\.value), [0, 0])
        XCTAssertEqual(points.weeklySums(weeks: 1, ending: "2026-10-05").map(\.date), ["2026-10-05"])
    }

    func testTemperatureDeltasAndSleepClocks() {
        XCTAssertEqual(Units.metric.tempDelta(0.4).signed(1), "+0.4 °C")
        XCTAssertEqual(Units.imperial.tempDelta(0.5).signed(1), "+0.9 °F") // a delta: ×9/5, no +32
        XCTAssertEqual(Units.imperial.tempDelta(-1).signed(1), "−1.8 °F")
        XCTAssertEqual(Units.metric.tempDelta(0.04).signed(1), "0.0 °C")
        XCTAssertEqual(Units.metric.tempDelta(-0.04).signed(1), "0.0 °C")

        XCTAssertEqual(Fmt.eveningClock(minutesAfter18: 330), "23:30")
        XCTAssertEqual(Fmt.eveningClock(minutesAfter18: 430), "01:10")
        XCTAssertEqual(Fmt.eveningClock(minutesAfter18: 0), "18:00")
        XCTAssertEqual(Fmt.eveningClock(minutesAfter18: -30), "17:30")
        XCTAssertEqual(Fmt.eveningClock(minutesAfter18: 592.5), "03:53")
        XCTAssertEqual(Fmt.clock(minutesOfDay: 405), "06:45")

        XCTAssertEqual(Fmt.signedMinutes(24), "+24 min")
        XCTAssertEqual(Fmt.signedMinutes(-63.6), "−1h 04m")
        XCTAssertEqual(Fmt.signedMinutes(0.3), "0 min")
    }

    func testSleepDebtCountsNightsInTheWeekNotARun() {
        func stats(need: Double?, debt: Double?, nights: Int) -> SleepTiming.Stats {
            .init(nights: 14, avgBedMin: nil, avgWakeMin: nil, bedSd: nil, wakeSd: nil, midWeekday: nil, midWeekend: nil,
                  socialJetlag: nil, need: need, debt: debt, debtNights: nights)
        }
        // The only night this week may have been days ago, so it isn't "last night".
        let one = SleepConsistencyCard.need(stats(need: 8, debt: 1.2, nights: 1))
        XCTAssertEqual(one, "Sleep need about 8h 00m · 1h 12m short over 1 of the last 7 nights")
        XCTAssertFalse(one?.contains("last night") ?? true)
        XCTAssertEqual(SleepConsistencyCard.need(stats(need: 8, debt: 0.1, nights: 3)), "Sleep need about 8h 00m · on track over 3 of the last 7 nights")
        XCTAssertEqual(SleepConsistencyCard.need(stats(need: 7.5, debt: 3.5, nights: 7)), "Sleep need about 7h 30m · 3h 30m short over the last 7 nights")
        XCTAssertEqual(SleepConsistencyCard.need(stats(need: 8, debt: 0, nights: 0)), "Sleep need about 8h 00m")
        XCTAssertEqual(SleepConsistencyCard.need(stats(need: 8, debt: nil, nights: 2)), "Sleep need about 8h 00m")
        XCTAssertNil(SleepConsistencyCard.need(stats(need: nil, debt: nil, nights: 0)))
        XCTAssertNil(SleepConsistencyCard.need(nil))
    }

    func testLongRangesAverageByWeek() {
        let days = (0..<14).map { Point(date: Day.add("2026-10-05", $0), value: Double($0)) } // Mon 5th .. Sun 18th
        let weeks = days.weekly(days: 365)
        XCTAssertEqual(weeks.map(\.date), ["2026-10-05", "2026-10-12"])
        XCTAssertEqual(weeks.map(\.value), [3, 10])
        XCTAssertEqual(days.weekly(days: 30).count, 14)
    }
}

/// The Family board (GET /api/family). family.json is written by hand from shared/types.ts FamilyBoard: Sam (you, WHOOP,
/// off), Ana (Apple Watch, all good, luteal phase shared), Leo (phone only: no status) and Maria (quiet, a day ahead).
final class FamilyBoardTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        // Fixtures added since the last `xcodegen generate` aren't in the bundle yet; read those next to this file.
        let url = Bundle(for: Self.self).url(forResource: name, withExtension: "json")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name).json")
        return try XCTUnwrap(try? Data(contentsOf: url), "missing fixture \(name).json")
    }

    private func board() throws -> FamilyBoard { try JSONDecoder().decode(FamilyBoard.self, from: fixture("family")) }

    private func member(_ json: String) throws -> FamilyMember { try JSONDecoder().decode(FamilyMember.self, from: Data(json.utf8)) }

    func testDecodesTheBoard() throws {
        let b = try board()
        XCTAssertTrue(b.sharing)
        XCTAssertEqual(b.today, "2026-10-17")
        XCTAssertEqual(b.members.map(\.name), ["Sam", "Ana", "Leo", "Maria"])
        let sam = b.members[0]
        XCTAssertEqual(sam.devices, ["whoop", "iphone"])
        XCTAssertEqual(sam.readiness?.kind, "recovery")
        XCTAssertEqual(sam.readiness?.usual, 68)
        XCTAssertEqual(sam.restingHr?.status, "normal")
        XCTAssertEqual(sam.steps?.source, "whoop")
        XCTAssertNil(sam.steps?.asOfHour)
        XCTAssertEqual(sam.avatarKey, "1760700000000", "an integer in the avatar URL, never 1.7607e+12")
        XCTAssertNil(sam.cyclePhase)
        let ana = b.members[1]
        XCTAssertEqual(ana.readiness?.metric, "hrv_sdnn")
        XCTAssertEqual(ana.cyclePhase, "luteal")
        XCTAssertNil(ana.avatarKey)
        let leo = b.members[2]
        XCTAssertNil(leo.status, "phone only: nothing to compare")
        XCTAssertNil(leo.readiness)
        XCTAssertEqual(leo.sleep?.inBed, true)
        XCTAssertEqual(leo.steps?.usualByNow, 7420)
        let maria = b.members[3]
        XCTAssertEqual(maria.status, "quiet")
        XCTAssertEqual(maria.quietSince, "2026-10-13")
        XCTAssertNil(maria.sleep)
        XCTAssertNil(maria.steps)

        let off = try JSONDecoder().decode(FamilyBoard.self, from: Data(#"{"sharing":false}"#.utf8))
        XCTAssertFalse(off.sharing)
        XCTAssertNil(off.today)
        XCTAssertTrue(off.members.isEmpty)
    }

    func testYouComeFirstAndTheGroupLineNamesYou() throws {
        let b = try board()
        XCTAssertEqual(b.members.filter(\.isYou).map(\.id), ["u1"])
        XCTAssertTrue(b.members.first?.isYou ?? false, "the server puts you first")
        XCTAssertEqual(FamilyText.title(b.members[0]), "Sam (you)")
        XCTAssertEqual(FamilyText.title(b.members[1]), "Ana")
        XCTAssertEqual(FamilyText.groupLine(b.members), "Off their usual: you · All good: Ana")

        let check = try member(#"{"id":"u9","name":"Zoe","isYou":false,"today":"2026-10-17","status":"check","reasons":["hrv","sleep"]}"#)
        XCTAssertEqual(FamilyText.groupLine([check] + b.members), "Check in: Zoe · Off their usual: you · All good: Ana")
        XCTAssertNil(FamilyText.groupLine([b.members[2], b.members[3]]), "phone-only and quiet say nothing there")
        XCTAssertEqual(FamilyText.reasons(check), "HRV lower than usual · Short night")
    }

    func testStatusWordingMatchesTheWeb() throws {
        let b = try board()
        XCTAssertEqual(b.members.map(FamilyText.status), ["Off your usual", "All good", nil, "No new data since Tue"])
        XCTAssertEqual(FamilyText.dot("good"), Palette.good)
        XCTAssertEqual(FamilyText.dot("check"), Palette.serious)
        XCTAssertNil(FamilyText.dot("quiet"))

        // Fresh phone data, but nothing from a watch or WHOOP since Monday.
        let phoneOnly = try member(#"{"id":"a","name":"Ana","isYou":false,"today":"2026-10-17","status":"quiet","latestDataDate":"2026-10-17","quietSince":"2026-10-12"}"#)
        XCTAssertEqual(FamilyText.status(phoneOnly), "No watch or WHOOP data since Mon")
        let never = try member(#"{"id":"b","name":"Bo","isYou":false,"today":"2026-10-17","status":"quiet","latestDataDate":null,"quietSince":null}"#)
        XCTAssertEqual(FamilyText.status(never), "No data yet")
        let learningYou = try member(#"{"id":"c","name":"Sam","isYou":true,"today":"2026-10-17","status":"learning"}"#)
        XCTAssertEqual(FamilyText.status(learningYou), "Getting to know your usual")
        let learning = try member(#"{"id":"d","name":"Leo","isYou":false,"today":"2026-10-17","status":"learning"}"#)
        XCTAssertEqual(FamilyText.status(learning), "Getting to know their usual")
        let check = try member(#"{"id":"e","name":"Leo","isYou":false,"today":"2026-10-17","status":"check"}"#)
        XCTAssertEqual(FamilyText.status(check), "Check in")

        XCTAssertEqual(FamilyText.since("2026-10-17", today: "2026-10-17"), "today")
        XCTAssertEqual(FamilyText.since("2026-10-16", today: "2026-10-17"), "yesterday")
        XCTAssertEqual(FamilyText.since("2026-10-01", today: "2026-10-17"), "Oct 1")
    }

    func testAnUnknownStatusOrFieldDoesNotBreakTheBoard() throws {
        let odd = try member(#"""
        {"id":"x","name":"Kai","isYou":false,"today":"2026-10-17","status":"resting","devices":["whoop","ring",3],
         "reasons":["sleep","stress"],"cyclePhase":"ovulation","readiness":{"kind":"readiness_v2","value":3},
         "sleep":"unexpected","avatar":"soon","steps":{"value":1200,"source":"apple","asOfHour":8,"usualByNow":2950},"somethingNew":true}
        """#)
        XCTAssertEqual(odd.status, "resting", "kept as a string")
        XCTAssertNil(FamilyText.status(odd), "no pill for a status the app doesn't know")
        XCTAssertEqual(odd.devices, ["whoop", "ring"])
        XCTAssertEqual(FamilyText.devicesLine(odd, boardToday: "2026-10-17"), "WHOOP")
        XCTAssertEqual(FamilyText.reasons(odd), "Short night")
        XCTAssertNil(FamilyText.phase(odd.cyclePhase), "only period, follicular or luteal, ever")
        XCTAssertNil(odd.sleep)
        XCTAssertNil(odd.avatar)
        XCTAssertNil(FamilyText.readinessValue(odd))
        XCTAssertEqual(FamilyText.readinessLabel(odd), "Recovery")
        XCTAssertEqual(FamilyText.readinessNote(odd), "None in the last few days")
        XCTAssertEqual(FamilyText.stepsNote(odd), "by 09:00 · usually ~3K", "2,950 rounds half up to 3,000, as on the web")

        // A member without an id drops only itself.
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture("family")) as? [String: Any])
        var members = try XCTUnwrap(json["members"] as? [Any])
        members.insert(["name": "No id"], at: 1)
        members.append("unexpected")
        json["members"] = members
        json["somethingNew"] = [1, 2]
        let b = try JSONDecoder().decode(FamilyBoard.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(b.members.map(\.id), ["u1", "u2", "u3", "u4"])
    }

    func testTileNotesReadLikeTheWeb() throws {
        let b = try board()
        let (sam, ana, leo, maria) = (b.members[0], b.members[1], b.members[2], b.members[3])

        XCTAssertEqual(FamilyText.devicesLine(sam, boardToday: "2026-10-17"), "WHOOP + iPhone")
        XCTAssertEqual(FamilyText.devicesLine(maria, boardToday: "2026-10-17"), "Apple Watch · their Sun")
        XCTAssertEqual(FamilyText.devicesLine(try member(#"{"id":"n","name":"New","isYou":false,"today":"2026-10-17","devices":[]}"#), boardToday: "2026-10-17"), "No devices yet")

        XCTAssertEqual(FamilyText.sleepNote(sam), "−1h 06m vs usual")
        XCTAssertEqual(FamilyText.sleepNote(ana), "+12m vs usual")
        XCTAssertEqual(FamilyText.sleepNote(leo), "in bed")
        XCTAssertEqual(FamilyText.sleepNote(maria), "No sleep data for last night")
        let earlier = try member(#"{"id":"s","name":"S","isYou":false,"today":"2026-10-17","sleep":{"hours":7.1,"date":"2026-10-16","usual":7.0,"inBed":false}}"#)
        XCTAssertEqual(FamilyText.sleepNote(earlier), "the night before · about usual")

        XCTAssertEqual(b.members.map(FamilyText.readinessLabel), ["Recovery", "HRV", "HRV", "HRV"])
        XCTAssertEqual(FamilyText.readinessValue(sam), "41%")
        XCTAssertEqual(FamilyText.readinessValue(ana), "48 ms")
        XCTAssertEqual(FamilyText.readinessNote(sam), "usual 68%")
        XCTAssertEqual(FamilyText.readinessNote(ana), "+7% vs usual · SDNN")
        XCTAssertEqual(FamilyText.readinessNote(leo), "Needs a watch or WHOOP")
        XCTAssertEqual(FamilyText.readinessNote(maria), "None in the last few days")
        let newHrv = try member(#"{"id":"h","name":"H","isYou":false,"today":"2026-10-17","devices":["whoop"],"readiness":{"kind":"hrv","metric":"hrv_rmssd","value":60,"date":"2026-10-17","usual":null}}"#)
        XCTAssertEqual(FamilyText.readinessNote(newHrv), "RMSSD")

        XCTAssertEqual(FamilyText.stepsNote(sam), "WHOOP, since waking")
        XCTAssertEqual(FamilyText.stepsNote(ana), "by 16:00")
        XCTAssertEqual(FamilyText.stepsNote(leo), "by 17:00 · usually ~7.4K")
        XCTAssertEqual(FamilyText.stepsNote(maria), "None yet today")
        let noHours = try member(#"{"id":"t","name":"T","isYou":false,"today":"2026-10-17","steps":{"value":300,"source":"apple","asOfHour":null,"usualByNow":null}}"#)
        XCTAssertEqual(FamilyText.stepsNote(noHours), "today")

        XCTAssertEqual(FamilyText.reasons(sam), "Recovery lower than usual")
        XCTAssertNil(FamilyText.reasons(ana))
        XCTAssertEqual(FamilyText.phase(ana.cyclePhase), "Luteal phase")
        XCTAssertEqual(FamilyText.phase("period"), "Period")
        XCTAssertEqual(FamilyText.initial("ana"), "A")
        XCTAssertEqual(FamilyText.initial(""), "·")

        let spoken = FamilyText.accessibilitySummary(maria, boardToday: "2026-10-17")
        XCTAssertEqual(spoken, "Maria. Apple Watch · their Sun. No new data since Tue. Sleep none, No sleep data for last night. HRV none, None in the last few days. Steps none, None yet today")
    }

    func testStatusCarriesTheFamilySettings() throws {
        let old = try JSONDecoder().decode(ServerStatus.self, from: fixture("status"))
        XCTAssertNil(old.settings?.familySharing, "older servers don't name it: unknown, not off")
        let json = #"{"settings":{"name":"Sam","cycleTracking":true,"familySharing":true,"shareCyclePhase":false,"familyNoticeSeen":false}}"#
        let new = try JSONDecoder().decode(ServerStatus.self, from: Data(json.utf8))
        XCTAssertEqual(new.settings?.familySharing, true)
        XCTAssertEqual(new.settings?.shareCyclePhase, false)
        XCTAssertEqual(new.settings?.familyNoticeSeen, false)
    }
}

/// What the Family tab shows as sharing, sessions and the server change. Only the synchronous steps the network calls
/// end in are driven here (`apply(status:)`, `receiveFamily`, `signedIn`), so nothing is sent anywhere.
@MainActor
final class FamilyStateTests: XCTestCase {
    private func board(sharing: Bool = true) throws -> FamilyBoard {
        if !sharing { return try JSONDecoder().decode(FamilyBoard.self, from: Data(#"{"sharing":false}"#.utf8)) }
        let url = Bundle(for: Self.self).url(forResource: "family", withExtension: "json")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/family.json")
        return try JSONDecoder().decode(FamilyBoard.self, from: Data(contentsOf: url))
    }

    /// A status as the server sends it. No cycleTracking, so applying it leaves the app's settings alone.
    private func status(sharing: Bool?, noticeSeen: Bool? = nil) throws -> ServerStatus {
        var settings: [String: Any] = ["name": "Sam"]
        if let sharing { settings["familySharing"] = sharing }
        if let noticeSeen { settings["familyNoticeSeen"] = noticeSeen }
        return try JSONDecoder().decode(ServerStatus.self, from: JSONSerialization.data(withJSONObject: ["settings": settings]))
    }

    /// Signed in on a server with accounts, sharing on, the fixture board on screen and Sam's photo loaded.
    private func sharingDashboard() throws -> Dashboard {
        let d = Dashboard()
        d.authMode = "required"
        d.signedIn()
        d.apply(status: try status(sharing: true, noticeSeen: false))
        d.receiveFamily(try board())
        d.rememberFamilyAvatar(Data([1, 2, 3]), id: "u1", version: "1760700000000")
        XCTAssertEqual(d.familyAvatarCache.count, 1)
        XCTAssertEqual(describe(d.familyDisplay), "board")
        return d
    }

    private func describe(_ display: FamilyDisplay) -> String {
        switch display {
        case .needsAccounts: "needsAccounts"
        case .sharingOff: "sharingOff"
        case .board(let b): b.sharing ? "board" : "board(sharing off)"
        case .missing: "missing"
        case .failed(let e): "failed: \(e)"
        case .unavailable(let m): "unavailable: \(m)"
        case .loading: "loading"
        }
    }

    func testTurningSharingOffShowsNoOneEvenWhenTheReadAfterFails() throws {
        let d = try sharingDashboard()
        // setFamilySharing(false): the PUT answers with the new status, then the board is read again. The status alone
        // must clear the board, since that read may fail (offline) and a failed read keeps what's on screen.
        d.apply(status: try status(sharing: false))
        XCTAssertNil(d.familyBoard, "nobody from the old board")
        XCTAssertTrue(d.familyAvatarCache.isEmpty, "other people's photos go too")
        XCTAssertNil(d.familyReadAt, "the next look reads it again, not 30 seconds later")
        XCTAssertEqual(describe(d.familyDisplay), "sharingOff")
        XCTAssertTrue(d.familyAvailable, "the tab stays, saying sharing is off")

        // A photo that was on its way lands after that: shown to no one and not kept.
        d.rememberFamilyAvatar(Data([1]), id: "u1", version: "1760700000000")
        XCTAssertTrue(d.familyAvatarCache.isEmpty)

        // The read after it fails: still nobody, and no error over the sharing-off screen.
        XCTAssertEqual(describe(FamilyDisplay.resolve(authMode: "required", phase: .ready, sharing: false, board: nil, missing: false, error: "Can't reach the server.")), "sharingOff")
    }

    func testSharingTurnedOffElsewhereHidesACachedBoard() throws {
        // Turned off on the web: a status refresh says so while a board from before is still cached (or a read that
        // started earlier lands late). The setting wins.
        let cached = try board()
        XCTAssertEqual(describe(FamilyDisplay.resolve(authMode: "required", phase: .ready, sharing: false, board: cached, missing: false, error: nil)), "sharingOff")
        XCTAssertEqual(describe(FamilyDisplay.resolve(authMode: "required", phase: .ready, sharing: false, board: cached, missing: false, error: "offline")), "sharingOff")

        let d = try sharingDashboard()
        d.apply(status: try status(sharing: false)) // the next refreshIfChanged(includeStatus:) or load
        XCTAssertNil(d.familyBoard)
        XCTAssertEqual(describe(d.familyDisplay), "sharingOff")
    }

    func testTurningSharingBackOnWaitsForTheBoard() throws {
        let d = try sharingDashboard()
        d.apply(status: try status(sharing: false))
        d.receiveFamily(try board(sharing: false))
        XCTAssertEqual(describe(d.familyDisplay), "sharingOff")
        // Turned on: the "off" board is from before, so it goes; Settings says on, and the tab doesn't say off.
        d.apply(status: try status(sharing: true))
        XCTAssertNil(d.familyBoard)
        XCTAssertEqual(describe(d.familyDisplay), "loading")
        XCTAssertEqual(describe(FamilyDisplay.resolve(authMode: "required", phase: .ready, sharing: true, board: nil, missing: false, error: "offline")), "failed: offline")
        d.receiveFamily(try board())
        XCTAssertEqual(describe(d.familyDisplay), "board")
    }

    func testAnUnchangedOrUnnamedSettingKeepsTheBoard() throws {
        let d = try sharingDashboard()
        let readAt = d.familyReadAt
        d.apply(status: try status(sharing: true))
        XCTAssertNotNil(d.familyBoard)
        XCTAssertEqual(d.familyReadAt, readAt)
        XCTAssertEqual(d.familyAvatarCache.count, 1)
        // A server whose status doesn't name the setting: the board decides.
        d.apply(status: try status(sharing: nil))
        XCTAssertNotNil(d.familyBoard)
        XCTAssertEqual(describe(d.familyDisplay), "board")
        XCTAssertEqual(describe(FamilyDisplay.resolve(authMode: "required", phase: .ready, sharing: nil, board: try board(sharing: false), missing: false, error: nil)), "sharingOff")
    }

    func testANewSessionStartsWithNoneOfTheLastPersonsFamilyState() throws {
        let d = try sharingDashboard()
        d.hideFamilyNotice()
        XCTAssertFalse(d.showsFamilyNotice)
        // The session ends without a sign-out (expired, password reset): a 401 only asks for sign-in again.
        d.phase = .signIn
        // Someone else signs in (signIn and join both end here).
        d.signedIn()
        XCTAssertEqual(d.phase, .ready)
        XCTAssertNil(d.familyBoard, "not the last person's board, with them as \"(you)\"")
        XCTAssertTrue(d.familyAvatarCache.isEmpty)
        XCTAssertNil(d.familyReadAt)
        XCTAssertNil(d.familyError)
        XCTAssertFalse(d.familyMissing)
        // Their status arrives with the load: their own one-time notice shows.
        d.apply(status: try status(sharing: true, noticeSeen: false))
        XCTAssertTrue(d.showsFamilyNotice)
        XCTAssertEqual(describe(d.familyDisplay), "loading")
    }

    func testAnUnavailableServerSaysSoInsteadOfSpinning() throws {
        // Sign-in misconfigured on the server, with a status cached from when it worked: the tab shows, but nothing
        // will be read until the server is fixed.
        let d = Dashboard()
        d.status = try status(sharing: true)
        d.authMode = "misconfigured"
        d.phase = .unavailable("Sign-in isn't set up on health.example.com yet.")
        XCTAssertTrue(d.familyAvailable)
        XCTAssertEqual(describe(d.familyDisplay), "unavailable: Sign-in isn't set up on health.example.com yet.")
        // Still starting: a spinner is right, start() is on its way.
        d.phase = .starting
        XCTAssertEqual(describe(d.familyDisplay), "loading")
        // Without sign-in at all, the board isn't offered.
        d.authMode = "open"
        XCTAssertEqual(describe(d.familyDisplay), "needsAccounts")
    }

    func testTheTileSharesOnlyWhatSettingsDescribes() throws {
        // Settings: "last night's sleep, recovery or HRV, today's steps, and how they compare with your own usual".
        // Resting heart rate shows only as a reason next to Off or Check in, as on the web.
        func member(_ json: String) throws -> FamilyMember { try JSONDecoder().decode(FamilyMember.self, from: Data(json.utf8)) }
        let sam = try board().members[0]
        XCTAssertEqual(sam.restingHr?.status, "normal")
        XCTAssertFalse(FamilyText.accessibilitySummary(sam, boardToday: "2026-10-17").contains("Resting heart rate"))
        let low = try member(#"{"id":"l","name":"L","isYou":false,"today":"2026-10-17","status":"good","reasons":[],"restingHr":{"status":"low","date":"2026-10-17"}}"#)
        XCTAssertFalse(FamilyText.accessibilitySummary(low, boardToday: "2026-10-17").contains("Resting heart rate"))
        let quiet = try member(#"{"id":"q","name":"Q","isYou":false,"today":"2026-10-17","status":"quiet","quietSince":"2026-10-14","reasons":[],"restingHr":{"status":"high","date":"2026-10-15"}}"#)
        XCTAssertFalse(FamilyText.accessibilitySummary(quiet, boardToday: "2026-10-17").contains("Resting heart rate"))
        let up = try member(#"{"id":"r","name":"R","isYou":false,"today":"2026-10-17","status":"off","reasons":["resting_hr"],"restingHr":{"status":"high","date":"2026-10-17"}}"#)
        let spoken = FamilyText.accessibilitySummary(up, boardToday: "2026-10-17")
        XCTAssertEqual(spoken.components(separatedBy: "Resting heart rate above usual").count - 1, 1, "once, as the reason")
    }
}

/// The Family tile at phone width (375pt, the SE and mini) across Dynamic Type sizes. Members have no photo, so no
/// avatar is fetched.
@MainActor
final class FamilyLayoutTests: XCTestCase {
    private func member(phase: Bool = true, demo: Bool = true) throws -> FamilyMember {
        let json = """
        {"id":"u1","name":"Gabriela","isYou":true,"demo":\(demo),"today":"2026-10-17","avatar":null,"devices":["whoop","watch"],
         "latestDataDate":"2026-10-17","quietSince":null,"status":"check","reasons":["hrv","sleep"],
         "sleep":{"hours":5.1,"date":"2026-10-16","usual":7.4,"inBed":false},"readiness":{"kind":"recovery","value":100,"date":"2026-10-17","usual":null},
         "steps":{"value":123456,"source":"apple","asOfHour":23,"usualByNow":18800}\(phase ? #","cyclePhase":"follicular""# : "")}
        """
        return try JSONDecoder().decode(FamilyMember.self, from: Data(json.utf8))
    }

    private let sizes: [DynamicTypeSize] = [.large, .xxxLarge, .accessibility1, .accessibility2]

    private func fit(_ view: some View, width: CGFloat, _ size: DynamicTypeSize) -> CGSize {
        let host = UIHostingController(rootView: view.environment(Dashboard()).environment(\.dynamicTypeSize, size))
        return host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
    }

    func testTheBoardFitsAPhoneAtEveryTextSize() throws {
        let board = FamilyBoard(sharing: true, today: "2026-10-17", members: [try member()])
        for size in sizes + [.accessibility5] {
            let s = fit(FamilyBoardView(board: board).padding(16), width: 375, size)
            XCTAssertLessThanOrEqual(s.width, 375.5, "nothing runs off the screen at \(size)")
        }
    }

    func testThePillsWrapBelowTheNameInsteadOfCuttingIt() throws {
        // A tile at 375pt: 343pt inside the board's padding. "Gabriela (you)", "Follicular phase" and "Demo data" don't
        // fit on one row there, so the pills take a row of their own and the tile grows by it.
        let withPills = fit(FamilyTile(member: try member(), boardToday: "2026-10-17"), width: 343, .large).height
        let nameOnly = fit(FamilyTile(member: try member(phase: false, demo: false), boardToday: "2026-10-17"), width: 343, .large).height
        XCTAssertGreaterThan(withPills, nameOnly + 10)
    }

    func testALongNameWrapsInsteadOfBeingCut() throws {
        // Too long for one line beside the photo at 375pt: the name takes a second line rather than ending in "…".
        func member(_ name: String) throws -> FamilyMember {
            try JSONDecoder().decode(FamilyMember.self, from: Data(#"{"id":"u9","name":"\#(name)","isYou":true,"today":"2026-10-17","devices":["watch"],"status":"check"}"#.utf8))
        }
        let long = try member("Maria Fernanda Gabriela Rodríguez")
        let short = try member("Ana")
        let longHeight = fit(FamilyTileHead(member: long, boardToday: "2026-10-17"), width: 311, .large).height
        let shortHeight = fit(FamilyTileHead(member: short, boardToday: "2026-10-17"), width: 311, .large).height
        let line = fit(Text("A").font(.headline), width: 311, .large).height
        XCTAssertGreaterThanOrEqual(longHeight, shortHeight + line - 1)
    }

    func testTheWrapKeepsEachViewWholeAndStartsANewRowWhenFull() {
        func box(_ w: CGFloat) -> some View { Color.clear.frame(width: w, height: 20) }
        let wrap = FamilyWrap(spacing: 6, rowSpacing: 4) { box(150); box(100); box(100) }
        // 150 + 6 + 100 is more than 237: the second box starts a row, and the third fits beside it.
        XCTAssertEqual(fit(wrap, width: 237, .large), CGSize(width: 206, height: 44))
        XCTAssertEqual(fit(wrap, width: 400, .large), CGSize(width: 362, height: 20))
        // A view wider than a row gets the row to itself and is offered that width.
        let text = FamilyWrap { Text("Maria Fernanda Gabriela Rodríguez (you)").font(.headline).lineLimit(2) }
        let one = fit(Text("A").font(.headline), width: 200, .large).height
        let wrapped = fit(text, width: 200, .large)
        XCTAssertLessThanOrEqual(wrapped.width, 200)
        XCTAssertGreaterThan(wrapped.height, one * 1.5, "two lines")
    }

    func testSlotFiguresGrowWithTheTextAndStayAboveTheirCaption() throws {
        func height(_ view: some View, _ size: DynamicTypeSize, width: CGFloat = 1000) -> CGFloat { fit(view, width: width, size).height }
        let valueFont = FamilySlot.valueFont
        XCTAssertGreaterThan(height(Text("5h 06m").font(valueFont).fixedSize(), .accessibility2), height(Text("5h 06m").font(valueFont).fixedSize(), .large) * 1.3)
        for size in sizes + [.accessibility5] {
            XCTAssertGreaterThan(height(Text("5h 06m").font(valueFont).fixedSize(), size), height(Text("Sleep").font(.caption).fixedSize(), size), "at \(size)")
        }
        // In the slot itself: what's left after its caption row and note is the figure, and it outgrows the caption.
        for size in [DynamicTypeSize.large, .xxxLarge, .accessibility2] {
            let slot = height(FamilySlot(icon: "bed.double", label: "Sleep", value: "5h 06m", note: "last night"), size, width: 200)
            let caption = height(HStack(spacing: 4) { Image(systemName: "bed.double"); Text("Sleep") }.font(.caption).fixedSize(), size)
            let note = height(Text("last night").font(.caption2).fixedSize(), size)
            let figure = slot - caption - note - 2 * 2
            XCTAssertGreaterThan(figure, caption, "at \(size): slot \(slot), caption \(caption), note \(note)")
        }
    }
}

final class CancellationTests: XCTestCase {
    func testADroppedRequestIsNotAnError() {
        XCTAssertTrue(APIClient.isCancellation(CancellationError()))
        XCTAssertTrue(APIClient.isCancellation(URLError(.cancelled)))
        XCTAssertFalse(APIClient.isCancellation(URLError(.notConnectedToInternet)))
        XCTAssertFalse(APIClient.isCancellation(APIError.network("Can't reach the server.")))
    }
}

final class PhotoCutoutTests: XCTestCase {
    func testPhotoWithoutAFaceExplainsWhy() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 600)).image { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 600))
        }
        XCTAssertThrowsError(try PhotoCutout.process(image.pngData()!)) { error in
            XCTAssertTrue(error is PhotoCutout.Failure, "\(error)")
        }
        XCTAssertThrowsError(try PhotoCutout.process(Data("not an image".utf8))) { error in
            XCTAssertEqual(error.localizedDescription, "Couldn't read that image. Choose a photo.")
        }
    }
}
