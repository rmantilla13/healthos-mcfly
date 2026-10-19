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
        // A reply from before the rebuilt engine: none of the newer fields, and nothing breaks.
        XCTAssertTrue(cycle.history.isEmpty)
        XCTAssertTrue(cycle.fertility.isEmpty)
        XCTAssertNil(cycle.earlyEstimate)
        XCTAssertNil(cycle.stats?.regular)
        XCTAssertEqual(cycle.shownEstimate?.ovulation, "2026-10-13")

        // The rebuilt engine (made-up data on a local server): Apple Watch nights, symptoms, graded fertile days.
        let v2 = try JSONDecoder().decode(CycleData.self, from: fixture("cycle-v2"))
        XCTAssertEqual(v2.current?.day, 13)
        XCTAssertEqual(v2.estimate?.confidence, "medium")
        XCTAssertEqual(v2.estimate?.nextPeriod.latest, "2026-11-05")
        XCTAssertEqual(v2.stats?.lutealDays, 13)
        XCTAssertEqual(v2.stats?.regular, true)
        XCTAssertEqual(v2.history.map(\.status), ["confirmed", "confirmed", "confirmed", "confirmed", "waiting"])
        XCTAssertEqual(v2.history.first?.ovulation?.tempSource, "wrist")
        XCTAssertEqual(v2.history.first?.temperature?.source, "wrist")
        XCTAssertNil(v2.history.last?.end)
        XCTAssertEqual(v2.temperatures.count, 41)
        XCTAssertEqual(v2.temperatures.filter { $0.excluded == "disturbed" }.map(\.date), ["2026-09-15", "2026-10-17"])
        XCTAssertEqual(v2.fertility.first?.date, "2026-10-14")
        XCTAssertEqual(v2.fertility.filter { $0.level == "high" }.count, 5)
        XCTAssertEqual(v2.insights?.body.map(\.metric), ["resting_hr", "hrv", "temperature"])
        XCTAssertEqual(v2.insights?.symptoms.first?.phase, "menstrual")
        XCTAssertEqual(v2.days.first { $0.date == "2026-10-17" }?.symptoms, ["headache"])
        XCTAssertEqual(v2.days.first { $0.date == "2026-10-17" }?.tempDisturbed, "sick")

        // Before two complete cycles the estimate leans on typical ones and stays out of `estimate`.
        let early = try JSONDecoder().decode(CycleData.self, from: Data(#"{"enabled":true,"today":"2026-09-10","days":[],"periods":[{"start":"2026-08-26","end":"2026-08-30","days":5}],"cycles":[],"stats":{"cycleDays":null,"periodDays":5,"shortest":null,"longest":null},"current":{"start":"2026-08-26","day":16},"estimate":null,"noEstimate":"cycles","earlyEstimate":{"nextPeriod":{"date":"2026-09-24","earliest":"2026-09-19","latest":"2026-09-30"},"ovulation":"2026-09-11","fertile":{"start":"2026-09-04","end":"2026-09-15"},"basis":"calendar","cycles":0,"confidence":"low"},"ovulations":[],"phase":{"name":"ovulatory","day":16,"nextPeriodIn":null,"basis":"estimate"}}"#.utf8))
        XCTAssertNil(early.estimate)
        XCTAssertEqual(early.shownEstimate?.nextPeriod.date, "2026-09-24")
        XCTAssertEqual(early.shownEstimate?.cycles, 0)
        XCTAssertNil(early.phase?.nextPeriodIn)

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
        XCTAssertEqual(spoken, "Maria. Apple Watch · their Sun. No new data since Tue. Sleep none, No sleep data for last night. HRV none, None in the last few days. Steps none, None yet today. Resting heart rate 59 bpm · Tue")
    }

    // MARK: The last 30 days

    /// The fixture as an older server sends it: no history, and resting heart rate as a verdict only.
    private func olderBoard() throws -> FamilyBoard {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture("family")) as? [String: Any])
        json["members"] = (json["members"] as? [[String: Any]])?.map { m -> [String: Any] in
            var m = m
            m["history"] = nil
            if var r = m["restingHr"] as? [String: Any] {
                r["value"] = nil
                r["usual"] = nil
                m["restingHr"] = r
            }
            return m
        }
        return try JSONDecoder().decode(FamilyBoard.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testDecodesTheirThirtyDays() throws {
        let b = try board()
        let (sam, ana, leo, maria) = (b.members[0], b.members[1], b.members[2], b.members[3])
        let h = try XCTUnwrap(sam.history)
        XCTAssertEqual(h.sleep?.inBed, false)
        XCTAssertEqual(h.sleep?.points.count, 10)
        XCTAssertEqual(h.sleep?.points.first, Point(date: "2026-10-08", value: 7.2), "oldest first")
        XCTAssertEqual(h.readiness?.kind, "recovery")
        XCTAssertEqual(h.readiness?.points.last?.value, 41)
        XCTAssertEqual(h.steps.map(\.value), [8200, 10400, 7600, 5234])
        XCTAssertEqual(h.restingHr.count, 5)
        XCTAssertEqual(h.load?.kind, "strain")
        XCTAssertEqual(sam.restingHr?.value, 57)
        XCTAssertEqual(sam.restingHr?.usual, 55)

        XCTAssertEqual(ana.history?.readiness?.kind, "hrv_sdnn")
        XCTAssertEqual(ana.history?.load?.kind, "energy")
        XCTAssertEqual(leo.history?.sleep?.inBed, true, "phone only: time in bed, marked as such")
        XCTAssertNil(leo.history?.readiness, "null on the wire")
        XCTAssertEqual(leo.history?.restingHr, [])
        XCTAssertNil(maria.history?.load)
        XCTAssertEqual(maria.history?.steps, [])
    }

    func testAnOlderServerKeepsTheTileAsItWas() throws {
        let b = try olderBoard()
        XCTAssertEqual(b.members.map(\.name), ["Sam", "Ana", "Leo", "Maria"])
        for m in b.members {
            XCTAssertNil(m.history)
            for metric in [FamilyChartData.Metric.sleep, .readiness, .steps, .restingHr] {
                XCTAssertNil(FamilyCharts.spark(metric, m), "no small charts without history")
            }
            XCTAssertTrue(FamilyCharts.page(m).isEmpty, "and no page to open")
        }
        let sam = b.members[0]
        XCTAssertEqual(sam.restingHr?.status, "normal")
        XCTAssertNil(sam.restingHr?.value)
        // Wording stays as before: no resting heart rate figure, so VoiceOver doesn't read one either.
        XCTAssertEqual(FamilyText.readinessNote(sam), "usual 68%")
        let spoken = FamilyText.accessibilitySummary(b.members[3], boardToday: "2026-10-17")
        XCTAssertEqual(spoken, "Maria. Apple Watch · their Sun. No new data since Tue. Sleep none, No sleep data for last night. HRV none, None in the last few days. Steps none, None yet today")
    }

    func testOddHistoryDropsOnlyTheOddPart() throws {
        let m = try member(#"""
        {"id":"x","name":"Kai","isYou":false,"today":"2026-10-17","devices":[],
         "history":{"sleep":"unexpected","readiness":{"kind":"readiness_v3","points":[{"date":"2026-10-16","value":5},{"date":"2026-10-17","value":6}]},
                    "steps":[{"date":"2026-10-16","value":"many"},{"date":"2026-10-17","value":4000},{"date":"17 Oct","value":1},{"value":3}],
                    "restingHr":null,"load":{"points":[{"date":"2026-10-17","value":3}]},"somethingNew":[1]}}
        """#)
        let h = try XCTUnwrap(m.history, "one odd part doesn't lose the rest")
        XCTAssertNil(h.sleep)
        XCTAssertEqual(h.readiness?.kind, "readiness_v3", "kept as a string")
        XCTAssertNil(FamilyText.readinessHistory(m), "but not drawn: the app doesn't know that kind")
        XCTAssertEqual(h.steps.map(\.date), ["2026-10-17", "17 Oct"], "unreadable points drop themselves")
        XCTAssertEqual(FamilyCharts.clean(h.steps).map(\.date), ["2026-10-17"], "and a date that isn't a day never reaches a chart")
        XCTAssertEqual(h.restingHr, [])
        XCTAssertNil(h.load, "no kind: nothing to say what it is")
        XCTAssertEqual(FamilyText.readinessLabel(m), "HRV")
        XCTAssertEqual(FamilyCharts.page(m).map(\.id), ["sleep", "readiness", "steps", "restingHr"])

        let noInBed = try member(#"{"id":"y","name":"Y","isYou":false,"today":"2026-10-17","history":{"sleep":{"points":[{"date":"2026-10-17","value":7}]}}}"#)
        XCTAssertEqual(noInBed.history?.sleep?.inBed, false)
        XCTAssertEqual(noInBed.history?.steps, [])
        let notAnObject = try member(#"{"id":"z","name":"Z","isYou":false,"today":"2026-10-17","history":"soon"}"#)
        XCTAssertNil(notAnObject.history)
        // A day that can't be read (lenient decoding allows "") never crashes the date maths.
        let noToday = try member(#"{"id":"w","name":"W","isYou":false,"today":"","history":{"restingHr":[{"date":"2026-10-12","value":60},{"date":"2026-10-13","value":61}]}}"#)
        XCTAssertEqual(FamilyText.restingNote(noToday), "bpm")
        XCTAssertEqual(FamilyCharts.spark(.restingHr, noToday)?.points.count, 2)
        _ = FamilyCharts.window(noToday)
    }

    func testSparksShowTheirLastSevenDays() throws {
        let b = try board()
        let (sam, ana, leo, maria) = (b.members[0], b.members[1], b.members[2], b.members[3])

        let sleep = try XCTUnwrap(FamilyCharts.spark(.sleep, sam))
        XCTAssertEqual(sleep.kind, .bars)
        XCTAssertEqual(sleep.points.map(\.date), ["2026-10-11", "2026-10-12", "2026-10-13", "2026-10-14", "2026-10-15", "2026-10-16", "2026-10-17"])
        XCTAssertEqual(sleep.domain, 0...8.1, "bars from zero")
        let readiness = try XCTUnwrap(FamilyCharts.spark(.readiness, sam))
        XCTAssertEqual(readiness.kind, .line)
        XCTAssertEqual(readiness.points.count, 7)
        XCTAssertEqual(readiness.domain.lowerBound, 41 - 7.75, accuracy: 0.001, "a quarter of the 41–72 span below")
        XCTAssertEqual(readiness.domain.upperBound, 72 + 7.75, accuracy: 0.001)
        XCTAssertEqual(FamilyCharts.spark(.steps, sam)?.points.count, 4)
        XCTAssertEqual(FamilyCharts.spark(.restingHr, sam)?.points.map(\.value), [54, 56, 55, 57], "Oct 10 is eight days back")

        XCTAssertNil(FamilyCharts.spark(.steps, ana), "one day isn't a chart")
        XCTAssertEqual(FamilyCharts.spark(.restingHr, ana)?.domain, 51...54, "a flat-ish run still gets room")
        XCTAssertNil(FamilyCharts.spark(.readiness, leo), "phone only: nothing to draw")
        XCTAssertNil(FamilyCharts.spark(.restingHr, leo))
        XCTAssertEqual(FamilyCharts.spark(.steps, leo)?.points.count, 7)

        // Maria's today is a day ahead of the board's: her week is hers, so Oct 11 is out.
        XCTAssertEqual(FamilyCharts.spark(.sleep, maria)?.points.map(\.date), ["2026-10-12", "2026-10-13"])
        XCTAssertEqual(FamilyCharts.week(maria.history?.sleep?.points ?? [], today: "2026-10-17").map(\.date), ["2026-10-11", "2026-10-12", "2026-10-13"])
        XCTAssertNil(FamilyCharts.spark(.steps, maria))
    }

    func testRestingHeartRateReadsLikeTheWeb() throws {
        let b = try board()
        let (sam, ana, leo, maria) = (b.members[0], b.members[1], b.members[2], b.members[3])
        XCTAssertEqual(FamilyText.restingValue(sam), "57")
        XCTAssertEqual(FamilyText.restingNote(sam), "bpm · about usual")
        XCTAssertEqual(FamilyText.restingNote(ana), "bpm · below usual 56")
        XCTAssertNil(FamilyText.restingValue(leo))
        XCTAssertEqual(FamilyText.restingNote(leo), "None lately")
        XCTAssertEqual(FamilyText.restingValue(maria), "59", "the latest of the 30 days")
        XCTAssertEqual(FamilyText.restingNote(maria), "bpm · Tue", "not recent: say when")

        let high = try member(#"{"id":"h","name":"H","isYou":false,"today":"2026-10-17","restingHr":{"status":"high","date":"2026-10-17","value":64,"usual":55},"history":{}}"#)
        XCTAssertEqual(FamilyText.restingNote(high), "bpm · above usual 55")
        let noUsual = try member(#"{"id":"n","name":"N","isYou":false,"today":"2026-10-17","restingHr":{"status":"normal","date":"2026-10-17","value":60,"usual":null},"history":{}}"#)
        XCTAssertEqual(FamilyText.restingNote(noUsual), "bpm")
        let fresh = try member(#"{"id":"f","name":"F","isYou":false,"today":"2026-10-17","restingHr":null,"history":{"restingHr":[{"date":"2026-10-16","value":58}]}}"#)
        XCTAssertEqual(FamilyText.restingNote(fresh), "bpm · no usual yet", "too new to have a usual")
        XCTAssertEqual(FamilyText.restingValue(fresh), "58")

        XCTAssertEqual(FamilyText.accessibilitySummary(sam, boardToday: "2026-10-17").components(separatedBy: ". ").last, "Resting heart rate 57 bpm · about usual")
        XCTAssertEqual(FamilyText.accessibilitySummary(leo, boardToday: "2026-10-17").components(separatedBy: ". ").last, "Resting heart rate none, None lately")
    }

    func testReadinessLabelFallsBackToTheThirtyDays() throws {
        // No reading today: the 30 days say which it is, before the devices do.
        let whoop = try member(#"{"id":"r","name":"R","isYou":false,"today":"2026-10-17","devices":["watch"],"readiness":null,"history":{"readiness":{"kind":"recovery","points":[]}}}"#)
        XCTAssertEqual(FamilyText.readinessLabel(whoop), "Recovery")
        XCTAssertEqual(FamilyText.readinessFormat(whoop, 63), "63%")
        let hrv = try member(#"{"id":"s","name":"S","isYou":false,"today":"2026-10-17","devices":["whoop"],"readiness":null,"history":{"readiness":{"kind":"hrv_rmssd","points":[]}}}"#)
        XCTAssertEqual(FamilyText.readinessLabel(hrv), "HRV")
        XCTAssertEqual(FamilyText.readinessFormat(hrv, 61.4), "61 ms")
        let neither = try member(#"{"id":"t","name":"T","isYou":false,"today":"2026-10-17","devices":["whoop"],"readiness":null,"history":{"readiness":null}}"#)
        XCTAssertEqual(FamilyText.readinessLabel(neither), "Recovery")
    }

    func testThePersonPageChartsEachAgainstTheirOwnUsual() throws {
        let b = try board()
        let (sam, ana, leo, maria) = (b.members[0], b.members[1], b.members[2], b.members[3])

        let charts = FamilyCharts.page(sam)
        XCTAssertEqual(charts.map(\.id), ["sleep", "readiness", "steps", "restingHr", "load"])
        let (sleep, readiness, steps, resting, load) = (charts[0], charts[1], charts[2], charts[3], charts[4])

        XCTAssertEqual(sleep.title, "Sleep")
        XCTAssertEqual(sleep.value, "6h 24m")
        XCTAssertEqual(sleep.note, "usual 7h 30m")
        XCTAssertEqual(sleep.kind, .bars)
        XCTAssertEqual(sleep.points.count, 10, "all 30 days, not just the week")
        XCTAssertEqual(try XCTUnwrap(sleep.median), 7.3, accuracy: 0.0001, "even count: the mean of the middle two")
        XCTAssertNil(sleep.usual)
        XCTAssertEqual(sleep.label, "Sam's sleep per night, median 7h 18m")
        XCTAssertEqual(sleep.axis(8), "8h")

        XCTAssertEqual(readiness.title, "WHOOP recovery")
        XCTAssertEqual(readiness.value, "41%")
        XCTAssertEqual(readiness.note, "usual 68%")
        XCTAssertEqual(readiness.kind, .line)
        XCTAssertNil(readiness.median, "lines carry the usual, not a median")
        XCTAssertEqual(readiness.usual, 68)
        XCTAssertTrue(readiness.domain.contains(68) && readiness.domain.contains(41), "the usual line is never off the chart")
        XCTAssertEqual(readiness.format(60), "60%")

        XCTAssertEqual(steps.value, "5,234")
        XCTAssertEqual(steps.note, "today so far")
        XCTAssertNil(steps.median, "four days: too few for a typical level")
        XCTAssertEqual(steps.format(8200), "8,200 steps")
        XCTAssertEqual(steps.axis(12_000), "12K")

        XCTAssertEqual(resting.title, "Resting heart rate")
        XCTAssertEqual(resting.value, "57 bpm")
        XCTAssertEqual(resting.note, "usual 55 bpm")
        XCTAssertEqual(resting.usual, 55)
        XCTAssertEqual(FamilyCharts.segments(resting.points), [0, 0, 1, 1, 1], "the line breaks over Oct 12–14")
        XCTAssertEqual(resting.axis(55), "55")
        XCTAssertEqual(resting.axis(55.5), "55.5")

        XCTAssertEqual(load.title, "Day strain")
        XCTAssertEqual(load.value, "6.1")
        XCTAssertEqual(load.note, "WHOOP, 0–21")

        let anaCharts = FamilyCharts.page(ana)
        XCTAssertEqual(anaCharts[1].title, "Heart rate variability")
        XCTAssertEqual(anaCharts[1].value, "48 ms")
        XCTAssertEqual(anaCharts[1].note, "usual 45 ms")
        XCTAssertEqual(anaCharts[0].note, "usual 7h 00m")
        XCTAssertEqual(anaCharts[3].note, "usual 56 bpm")
        XCTAssertEqual(anaCharts[4].title, "Active energy")
        XCTAssertEqual(anaCharts[4].value, "380 kcal")
        XCTAssertEqual(anaCharts[4].note, "Apple Watch or iPhone")

        let leoCharts = FamilyCharts.page(leo)
        XCTAssertEqual(leoCharts[0].title, "Time in bed")
        XCTAssertEqual(leoCharts[0].note, "from the iPhone")
        XCTAssertEqual(leoCharts[1].value, "—")
        XCTAssertNil(leoCharts[1].note)
        XCTAssertTrue(leoCharts[1].points.isEmpty)
        XCTAssertEqual(leoCharts[3].value, "—")
        XCTAssertEqual(leoCharts[2].median, 9100, "seven days: the middle one")

        XCTAssertEqual(FamilyCharts.page(maria).map(\.id), ["sleep", "readiness", "steps", "restingHr"], "no load: no load chart")
        XCTAssertEqual(FamilyCharts.page(maria)[3].value, "59 bpm")

        // Last night came from the phone while the chart holds watch nights: say why it's missing.
        let phoneNight = try member(#"{"id":"p","name":"P","isYou":false,"today":"2026-10-17","sleep":{"hours":8.6,"date":"2026-10-17","usual":null,"inBed":true},"history":{"sleep":{"inBed":false,"points":[]}}}"#)
        XCTAssertEqual(FamilyCharts.page(phoneNight)[0].note, "last night in bed (phone), not in the chart")
        XCTAssertEqual(FamilyCharts.page(phoneNight)[0].title, "Sleep")
    }

    func testThePersonPageWindowIsTheirThirtyDays() throws {
        let b = try board()
        let sam = b.members[0], maria = b.members[3]
        let half: TimeInterval = 12 * 3600
        let window = FamilyCharts.window(sam)
        XCTAssertEqual(window.lowerBound, Fmt.chartDate("2026-09-18").addingTimeInterval(-half))
        XCTAssertEqual(window.upperBound, Fmt.chartDate("2026-10-17").addingTimeInterval(half))
        XCTAssertEqual(FamilyCharts.window(maria).upperBound, Fmt.chartDate("2026-10-18").addingTimeInterval(half), "to her today, not the board's")
        XCTAssertEqual(FamilyCharts.window(maria).lowerBound, Fmt.chartDate("2026-09-19").addingTimeInterval(-half))

        XCTAssertEqual(FamilyText.pageDevicesLine(sam, boardToday: "2026-10-17"), "WHOOP + iPhone · last 30 days")
        XCTAssertEqual(FamilyText.pageDevicesLine(maria, boardToday: "2026-10-17"), "Apple Watch · their Sun · last 30 days")
        XCTAssertEqual(String(FamilyText.pageFoot(sam).characters), "Dashed lines are the median of these 30 days; “usual” lines are your average of the 30 days before the latest reading. Open your full dashboard")
        XCTAssertEqual(String(FamilyText.pageFoot(maria).characters), "Dashed lines are the median of these 30 days; “usual” lines are their average of the 30 days before the latest reading. Only what they share is here.")
    }

    func testMedianAndRunsMatchTheWebCharts() {
        let p = { (d: String, v: Double) in Point(date: d, value: v) }
        XCTAssertNil(FamilyCharts.median([p("2026-10-01", 1), p("2026-10-02", 2), p("2026-10-03", 3), p("2026-10-04", 4)]))
        XCTAssertEqual(FamilyCharts.median([p("2026-10-01", 5), p("2026-10-02", 1), p("2026-10-03", 4), p("2026-10-04", 2), p("2026-10-05", 3)]), 3)
        let runs = [p("2026-10-01", 1), p("2026-10-04", 1), p("2026-10-08", 1), p("2026-10-09", 1), p("2026-10-20", 1)]
        let segments = FamilyCharts.segments(runs)
        XCTAssertEqual(segments, [0, 0, 1, 1, 2], "3 days apart joins; 4 breaks")
        XCTAssertEqual(runs.indices.map { FamilyCharts.isAlone($0, in: segments) }, [false, false, false, false, true])
        XCTAssertEqual(FamilyCharts.padded([], by: 0.15), 0...1)
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

    func testAPersonPageShowsOnlyWhoTheBoardShows() throws {
        let d = try sharingDashboard()
        XCTAssertEqual(d.familyPerson("u2").member?.name, "Ana")
        guard case .shown(_, let boardToday) = d.familyPerson("u4") else { return XCTFail("Maria is on the board") }
        XCTAssertEqual(boardToday, "2026-10-17", "the viewer's today, so her page says \"their Sun\"")

        // Ana stops sharing: the next read leaves her out, and her page says so.
        let url = Bundle(for: Self.self).url(forResource: "family", withExtension: "json")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/family.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json["members"] = (json["members"] as? [[String: Any]])?.filter { $0["id"] as? String != "u2" }
        d.receiveFamily(try JSONDecoder().decode(FamilyBoard.self, from: JSONSerialization.data(withJSONObject: json)))
        guard case .notOnBoard = d.familyPerson("u2") else { return XCTFail("Ana isn't on the board any more") }
        XCTAssertNotNil(d.familyPerson("u3").member)

        // Asked to sign in again: the board is still in memory, but no page shows from it.
        d.phase = .signIn
        XCTAssertNotNil(d.familyBoard)
        guard case .noBoard = d.familyPerson("u3") else { return XCTFail("nothing behind a sign-in screen") }

        // Back in, then sharing goes off: no one's page either.
        d.phase = .ready
        XCTAssertNotNil(d.familyPerson("u3").member)
        d.apply(status: try status(sharing: false))
        guard case .noBoard = d.familyPerson("u3") else { return XCTFail("sharing off shows no one") }
    }

    func testTheNoticeShowsOnceMoreAndStaysDismissed() throws {
        // The server now keeps "seen" as version 2, so everyone who dismissed the old note gets false and sees it again.
        let d = Dashboard()
        d.authMode = "required"
        d.signedIn()
        d.apply(status: try status(sharing: true, noticeSeen: false))
        XCTAssertTrue(d.showsFamilyNotice)

        // "Got it": gone at once, before the PUT answers.
        d.hideFamilyNotice()
        XCTAssertFalse(d.showsFamilyNotice)
        // The PUT's answer says seen.
        d.apply(status: try status(sharing: true, noticeSeen: true))
        XCTAssertFalse(d.showsFamilyNotice)
        // A status read that started before the PUT lands late: still gone.
        d.apply(status: try status(sharing: true, noticeSeen: false))
        XCTAssertFalse(d.showsFamilyNotice)
        // Next launch, with the server saying seen: not shown.
        let next = Dashboard()
        next.authMode = "required"
        next.signedIn()
        next.apply(status: try status(sharing: true, noticeSeen: true))
        XCTAssertFalse(next.showsFamilyNotice)
        // Not while sharing is off.
        next.apply(status: try status(sharing: false, noticeSeen: false))
        XCTAssertFalse(next.showsFamilyNotice)

        // What "Got it" sends: a JSON true, which is what the server stores version 2 for (it checks === true).
        let body = try JSONSerialization.data(withJSONObject: ["familyNoticeSeen": true])
        XCTAssertEqual(String(decoding: body, as: UTF8.self), #"{"familyNoticeSeen":true}"#)
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
        // Settings: "last night's sleep, recovery or HRV, today's steps, resting heart rate and training load, the last
        // 30 days of each". With the 30-day board, resting heart rate is a figure of its own, as on the web.
        func member(_ json: String) throws -> FamilyMember { try JSONDecoder().decode(FamilyMember.self, from: Data(json.utf8)) }
        let sam = try board().members[0]
        XCTAssertEqual(sam.restingHr?.status, "normal")
        XCTAssertTrue(FamilyText.accessibilitySummary(sam, boardToday: "2026-10-17").contains("Resting heart rate 57 bpm"))
        // From an older server (no history, no value): only as a reason next to Off or Check in, as that web did.
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

    func testTheThirtyDayTileFitsAPhoneAtEveryTextSize() throws {
        // Two by two with a small chart under each figure, from a server with the 30-day board.
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(try member())) as? [String: Any])
        let week = (11...17).map { ["date": "2026-10-\($0)", "value": Double($0)] }
        json["history"] = ["sleep": ["inBed": false, "points": week], "readiness": ["kind": "recovery", "points": week], "steps": week, "restingHr": week]
        json["restingHr"] = ["status": "high", "date": "2026-10-17", "value": 64, "usual": 55]
        let rich = try JSONDecoder().decode(FamilyMember.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNotNil(FamilyCharts.spark(.restingHr, rich))
        let board = FamilyBoard(sharing: true, today: "2026-10-17", members: [rich])
        for size in sizes + [.accessibility5] {
            let s = fit(FamilyBoardView(board: board).padding(16), width: 375, size)
            XCTAssertLessThanOrEqual(s.width, 375.5, "nothing runs off the screen at \(size)")
        }
        // The sparks add height, not width: the tile is taller than the same person without history.
        let plain = fit(FamilyTile(member: try member(), boardToday: "2026-10-17"), width: 343, .large).height
        let withCharts = fit(FamilyTile(member: rich, boardToday: "2026-10-17"), width: 343, .large).height
        XCTAssertGreaterThan(withCharts, plain + FamilySpark.height)
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

// MARK: - Card hiding (shared/cards.ts, Settings → Cards)

@MainActor
final class CardHidingTests: XCTestCase {
    /// A status as the server sends it; no hiddenCards is a server from before card hiding.
    private func status(hidden: [String]?) throws -> ServerStatus {
        var settings: [String: Any] = ["name": "Sam"]
        if let hidden { settings["hiddenCards"] = hidden }
        return try JSONDecoder().decode(ServerStatus.self, from: JSONSerialization.data(withJSONObject: ["settings": settings]))
    }

    private func dashboard(hidden: [String]?) throws -> Dashboard {
        let d = Dashboard()
        d.apply(status: try status(hidden: hidden))
        return d
    }

    private func json(_ change: CardChange) throws -> String {
        String(decoding: try APIClient.settingsBody(change.body), as: UTF8.self)
    }

    /// What the server does with a PUT /settings body (server/app.ts): one card's change applied to the stored list,
    /// or the whole list. `oneCard: false` is a server from before one-card changes, which ignores `cardShown`.
    private func serve(_ fields: [String: Any], stored: inout [String], oneCard: Bool = true) {
        if let list = fields["hiddenCards"] as? [String] {
            stored = list
        } else if oneCard, let c = fields["cardShown"] as? [String: Any], let id = c["id"] as? String, let shown = c["shown"] as? Bool {
            stored = Cards.toggled(stored, id: id, shown: shown)
        }
    }

    func testRegistryMatchesSharedCards() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("shared/cards.ts")
        guard let source = try? String(contentsOf: url, encoding: .utf8) else { throw XCTSkip("shared/cards.ts isn't next to the app") }
        let ns = source as NSString
        func groups(_ pattern: String) throws -> [[String?]] {
            try NSRegularExpression(pattern: pattern).matches(in: source, range: NSRange(location: 0, length: ns.length)).map { m in
                (1..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? nil : ns.substring(with: m.range(at: $0)) }
            }
        }
        let cards = try groups(#"\{ id: '([^']+)', page: '([^']+)', label: (?:'([^']*)'|"([^"]*)")(, nutrition: true)? \}"#)
        XCTAssertEqual(cards.count, 29, "every card in CARDS")
        XCTAssertEqual(cards.map { $0[0]! }, Cards.all.map(\.id), "same ids, same order")
        for (c, card) in zip(cards, Cards.all) {
            XCTAssertEqual(c[1], card.page.rawValue, card.id)
            XCTAssertEqual(c[2] ?? c[3], card.label, card.id)
            XCTAssertEqual(c[4] != nil, card.nutrition, card.id)
        }
        let pages = try groups(#"\{ page: '([^']+)', label: '([^']+)' \}"#)
        XCTAssertEqual(pages.map { $0[0]! }, CardPage.allCases.map(\.rawValue))
        XCTAssertEqual(pages.map { $0[1]! }, CardPage.allCases.map(\.label))
    }

    func testNutritionOverviewClosesUpAroundHiddenCards() {
        // Everything shown: energy, protein, water, logged as two rows of two, then macros and insights.
        let all = Cards.nutritionOverview(mode: .all, hidden: [])
        XCTAssertEqual(Cards.rows(all.row, max: 2), [["nutrition.energy", "nutrition.protein"], ["nutrition.water", "nutrition.logged"]])
        // Hiding protein leaves three: the last one takes the whole row, no hole.
        let noProtein = Cards.nutritionOverview(mode: .all, hidden: ["nutrition.protein"])
        XCTAssertEqual(Cards.rows(noProtein.row, max: 2), [["nutrition.energy", "nutrition.water"], ["nutrition.logged"]])
        // Calories hidden by the setting: energy never shows, so it doesn't count toward "all hidden".
        let noEnergy = Cards.nutritionOverview(mode: .noEnergy, hidden: ["nutrition.protein", "nutrition.water", "nutrition.logged", "nutrition.macros", "nutrition.insights"])
        XCTAssertTrue(noEnergy.allHidden)
        XCTAssertFalse(Cards.nutritionOverview(mode: .all, hidden: ["nutrition.protein", "nutrition.water", "nutrition.logged", "nutrition.macros", "nutrition.insights"]).allHidden)
    }

    func testOnlyCardsTheAppShowsAreMapped() {
        XCTAssertEqual(Cards.ids(in: .today), ["home.readiness", "home.spo2", "home.hrv", "home.sleep", "home.load", "home.activity", "home.timeline", "home.insights"])
        XCTAssertEqual(Cards.todayGrid.filter { Cards.card($0)?.place == .today }, Cards.todayGrid, "every grid card is a Today card")
        XCTAssertEqual(Cards.ids(in: .trends(.sleep)), ["sleep.score", "sleep.total", "sleep.stages"])
        XCTAssertEqual(Cards.ids(in: .trends(.nutrition)),
                       ["nutrition.energy", "nutrition.protein", "nutrition.water", "nutrition.logged", "nutrition.macros", "nutrition.insights"])
        // No food card on Today, and nothing of the Body overview in the app.
        XCTAssertNil(Cards.card("home.food")?.place)
        XCTAssertTrue(Cards.all.filter { $0.page == .body }.allSatisfy { $0.place == nil })
        XCTAssertTrue(Cards.ids(in: .trends(.body)).isEmpty)
        XCTAssertNil(Cards.card("future.card"))
    }

    func testHiddenCardsLeaveTheRestInOrder() throws {
        let hidden: Set<String> = ["home.spo2", "home.load", "sleep.total", "future.card"]
        XCTAssertEqual(Cards.visible(Cards.todayGrid, hidden: hidden), ["home.readiness", "home.hrv", "home.sleep", "home.activity"])
        XCTAssertEqual(Cards.visible(Cards.todayGrid, hidden: []), Cards.todayGrid)
        XCTAssertFalse(Cards.allHidden(in: .today, hidden: hidden))
        XCTAssertTrue(Cards.allHidden(in: .today, hidden: Set(Cards.ids(in: .today))))
        XCTAssertFalse(Cards.allHidden(in: .trends(.body), hidden: Set(Cards.all.map(\.id))), "nothing to hide there, so no note")

        // The status's list, unknown ids ignored.
        let d = try dashboard(hidden: ["home.hrv", "future.card"])
        XCTAssertTrue(d.cardsAvailable)
        XCTAssertFalse(d.cardShown("home.hrv"))
        XCTAssertTrue(d.cardShown("home.spo2"))
        XCTAssertEqual(Cards.visible(Cards.todayGrid, hidden: d.hiddenCardSet), ["home.readiness", "home.spo2", "home.sleep", "home.load", "home.activity"])
    }

    func testAnOlderServerShowsEveryCard() throws {
        let d = try dashboard(hidden: nil)
        XCTAssertFalse(d.cardsAvailable, "no Cards section in Settings")
        XCTAssertEqual(d.hiddenCards, [])
        XCTAssertTrue(Cards.all.allSatisfy { d.cardShown($0.id) })
        XCTAssertFalse(Dashboard().cardsAvailable, "nor before the status has loaded")
        XCTAssertTrue(try dashboard(hidden: []).cardsAvailable)
    }

    func testTheGridReflowsWithNoHoles() {
        XCTAssertEqual(Cards.rows([String](), max: 2), [])
        XCTAssertEqual(Cards.rows(["a"], max: 2), [["a"]], "one card takes the whole row")
        XCTAssertEqual(Cards.rows(["a", "b"], max: 2), [["a", "b"]])
        XCTAssertEqual(Cards.rows(["a", "b", "c"], max: 2), [["a", "b"], ["c"]], "an odd last card spans both columns")
        XCTAssertEqual(Cards.rows(["a", "b", "c", "d"], max: 2), [["a", "b"], ["c", "d"]])
        XCTAssertEqual(Cards.rows(["a", "b", "c", "d", "e"], max: 2), [["a", "b"], ["c", "d"], ["e"]])
        XCTAssertEqual(Cards.rows(Cards.todayGrid, max: 2), [["home.readiness", "home.spo2"], ["home.hrv", "home.sleep"], ["home.load", "home.activity"]])
        // Blood oxygen hidden: the cards after it move up and Activity spans the last row.
        XCTAssertEqual(Cards.rows(Cards.visible(Cards.todayGrid, hidden: ["home.spo2"]), max: 2),
                       [["home.readiness", "home.hrv"], ["home.sleep", "home.load"], ["home.activity"]])
        // The web's fillColumns: as few rows as fit, as even as they go.
        XCTAssertEqual(Cards.fillColumns(0, max: 3), 1)
        XCTAssertEqual(Cards.fillColumns(4, max: 3), 2, "2 × 2, not 3 + 1")
        XCTAssertEqual(Cards.fillColumns(5, max: 3), 3)
        XCTAssertEqual(Cards.fillColumns(6, max: 4), 3)
        XCTAssertEqual(Cards.rows(["a", "b", "c", "d"], max: 3), [["a", "b"], ["c", "d"]])
    }

    func testTheSettingsBodies() throws {
        XCTAssertEqual(try json(.card("home.hrv", shown: false)), #"{"cardShown":{"id":"home.hrv","shown":false}}"#)
        XCTAssertEqual(try json(.card("sleep.stages", shown: true)), #"{"cardShown":{"id":"sleep.stages","shown":true}}"#)
        XCTAssertEqual(try json(.list(["home.spo2", "home.hrv"])), #"{"hiddenCards":["home.spo2","home.hrv"]}"#)
        XCTAssertEqual(try json(.list([])), #"{"hiddenCards":[]}"#, "Show all")
    }

    func testOneCardChangesApplyToTheListAsItIs() {
        XCTAssertEqual(Cards.toggled(["home.spo2"], id: "home.hrv", shown: false), ["home.spo2", "home.hrv"])
        XCTAssertEqual(Cards.toggled(["home.spo2", "home.hrv"], id: "home.hrv", shown: false), ["home.spo2", "home.hrv"], "once each")
        XCTAssertEqual(Cards.toggled(["home.spo2", "future.card"], id: "home.spo2", shown: true), ["future.card"], "unknown ids stay")
        XCTAssertEqual(CardChange.list(["a"]).applied(to: ["b"]), ["a"])
    }

    func testTheWholeListGoesOnlyWhenTheServerIgnoredTheChange() {
        let hide = CardChange.card("home.hrv", shown: false)
        XCTAssertNil(hide.retry(stored: ["home.spo2", "home.hrv"]), "it took")
        XCTAssertEqual(hide.retry(stored: ["future.card"]), .list(["future.card", "home.hrv"]), "built on what the server answered")
        let show = CardChange.card("home.hrv", shown: true)
        XCTAssertNil(show.retry(stored: []))
        XCTAssertEqual(show.retry(stored: ["home.hrv", "home.spo2"]), .list(["home.spo2"]))
        XCTAssertNil(hide.retry(stored: nil))
        XCTAssertNil(CardChange.list([]).retry(stored: ["home.hrv"]))
    }

    func testSettingsOffersNutritionCardsOnlyWithNutritionOn() {
        let off = Cards.pages(nutrition: false)
        XCTAssertEqual(off.map(\.page), [.home, .sleep, .body])
        XCTAssertFalse(off.flatMap(\.cards).contains { $0.nutrition })
        XCTAssertEqual(off.flatMap(\.cards).count, 22)
        let on = Cards.pages(nutrition: true)
        XCTAssertEqual(on.map(\.page), [.home, .sleep, .body, .nutrition])
        XCTAssertEqual(on.flatMap(\.cards).map(\.id), Cards.all.map(\.id))
        XCTAssertEqual(on.first?.cards.map(\.id).contains("home.food"), true)
    }

    func testAChangeShowsAtOnceThenFollowsTheServer() async throws {
        let d = try dashboard(hidden: ["home.spo2"])
        var stored = ["home.spo2", "sleep.rhr"] // hidden on the web meanwhile
        var bodies: [String] = []
        try await d.changeCards(.card("home.hrv", shown: false)) { fields in
            bodies.append(String(decoding: try APIClient.settingsBody(fields), as: UTF8.self))
            XCTAssertEqual(d.hiddenCards, ["home.spo2", "home.hrv"], "hidden before the server answers")
            self.serve(fields, stored: &stored)
            return try self.status(hidden: stored)
        }
        XCTAssertEqual(bodies, [#"{"cardShown":{"id":"home.hrv","shown":false}}"#])
        XCTAssertNil(d.pendingHiddenCards)
        XCTAssertEqual(d.hiddenCards, ["home.spo2", "sleep.rhr", "home.hrv"], "the server's list, the web's change kept")
    }

    func testARefusedChangeGoesBack() async throws {
        let d = try dashboard(hidden: ["home.spo2"])
        do {
            try await d.changeCards(.card("home.hrv", shown: false)) { _ in
                XCTAssertFalse(d.cardShown("home.hrv"))
                throw APIError.server(400, "Unknown card, or not a list of cards.")
            }
            XCTFail("the error reaches the caller, to say so")
        } catch APIError.server(400, _) {}
        XCTAssertNil(d.pendingHiddenCards)
        XCTAssertEqual(d.hiddenCards, ["home.spo2"])
        XCTAssertTrue(d.cardShown("home.hrv"))
    }

    func testAServerFromBeforeOneCardChangesGetsTheWholeList() async throws {
        let d = try dashboard(hidden: ["home.spo2"])
        var stored = ["home.spo2", "sleep.rhr"]
        var bodies: [String] = []
        try await d.changeCards(.card("home.hrv", shown: false)) { fields in
            bodies.append(String(decoding: try APIClient.settingsBody(fields), as: UTF8.self))
            self.serve(fields, stored: &stored, oneCard: false)
            return try self.status(hidden: stored)
        }
        XCTAssertEqual(bodies, [#"{"cardShown":{"id":"home.hrv","shown":false}}"#, #"{"hiddenCards":["home.spo2","sleep.rhr","home.hrv"]}"#])
        XCTAssertEqual(d.hiddenCards, ["home.spo2", "sleep.rhr", "home.hrv"])
    }

    func testChangesReachTheServerInTheOrderMade() async throws {
        let d = try dashboard(hidden: [])
        var stored: [String] = []
        var bodies: [String] = []
        var release: CheckedContinuation<Void, Never>?
        let send: @MainActor ([String: Any]) async throws -> ServerStatus = { fields in
            bodies.append(String(decoding: try APIClient.settingsBody(fields), as: UTF8.self))
            // The first one is slow to arrive.
            if bodies.count == 1 { await withCheckedContinuation { release = $0 } }
            self.serve(fields, stored: &stored)
            return try self.status(hidden: stored)
        }
        let hide = Task { try await d.changeCards(.card("home.hrv", shown: false), send: send) }
        for _ in 0..<1000 where release == nil { await Task.yield() }
        XCTAssertEqual(d.hiddenCards, ["home.hrv"])
        let show = Task { try await d.changeCards(.card("home.hrv", shown: true), send: send) }
        for _ in 0..<1000 where d.hiddenCards != [] { await Task.yield() }
        XCTAssertTrue(d.cardShown("home.hrv"), "shown again at once")
        XCTAssertEqual(bodies.count, 1, "the second waits for the first")
        release?.resume()
        try await hide.value
        try await show.value
        XCTAssertEqual(bodies, [#"{"cardShown":{"id":"home.hrv","shown":false}}"#, #"{"cardShown":{"id":"home.hrv","shown":true}}"#])
        XCTAssertEqual(stored, [])
        XCTAssertEqual(d.hiddenCards, [])
        XCTAssertNil(d.pendingHiddenCards)
    }
}

/// The cards review's fixes: an empty Today grid leaves no gap, the Settings row and Show all count the same cards,
/// and the Nutrition overview's cards per setting (the web's rule, ready for its screen).
final class CardHidingReviewTests: XCTestCase {
    private func summary() throws -> Summary {
        let url = Bundle(for: Self.self).url(forResource: "summary", withExtension: "json")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/summary.json")
        return try JSONDecoder().decode(Summary.self, from: XCTUnwrap(try? Data(contentsOf: url), "missing fixture summary.json"))
    }

    @MainActor private func height<V: View>(_ view: V) -> CGFloat {
        UIHostingController(rootView: view).sizeThatFits(in: CGSize(width: 375, height: CGFloat.greatestFiniteMagnitude)).height
    }

    @MainActor func testAGridWithEveryCardHiddenAddsNoGap() throws {
        let s = try summary()
        let bar = Color.red.frame(height: 10)
        let without = height(VStack(spacing: 16) { bar; bar })
        XCTAssertEqual(without, 36)
        // The probe sees the bug: an empty stack still gets spacing on both sides, the old grid's 16pt extra.
        let emptyStack = height(VStack(spacing: 16) { bar; VStack(spacing: 12) { ForEach([String](), id: \.self) { Text($0) } }; bar })
        XCTAssertEqual(emptyStack, without + 16)
        // TodayGrid with all six hidden takes no space and no spacing.
        let grid = height(VStack(spacing: 16) { bar; TodayGrid(summary: s, ids: [], goal: 10_000); bar })
        XCTAssertEqual(grid, without, "no gap where the grid was")
        XCTAssertEqual(Cards.visible(Cards.todayGrid, hidden: Set(Cards.todayGrid)), [], "what Today passes then")
    }

    func testTheRowAndShowAllCountTheSameCards() throws {
        // Hidden on the web with Nutrition on, then Nutrition turned off; plus a newer server's card.
        let notListed: Set<String> = ["nutrition.water", "future.card"]
        XCTAssertEqual(Cards.hiddenOffered(notListed, nutrition: false), [], "All shown, and no Show all with every switch on")
        XCTAssertEqual(Cards.hiddenOffered(notListed, nutrition: true), ["nutrition.water"])
        XCTAssertEqual(Cards.hiddenOffered(["sleep.rhr", "future.card", "home.spo2", "nutrition.water"], nutrition: false),
                       ["home.spo2", "sleep.rhr"], "in the registry's order")
        XCTAssertEqual(Cards.hiddenOffered([], nutrition: true), [])
        XCTAssertEqual(Cards.hiddenOffered(Set(Cards.all.map(\.id)), nutrition: true), Cards.all.map(\.id))
        XCTAssertEqual(Cards.hiddenOffered(Set(Cards.all.map(\.id)), nutrition: false).count, 22)
    }

    func testNutritionOverviewCardsFollowTheSetting() {
        let ids = ["nutrition.energy", "nutrition.protein", "nutrition.water", "nutrition.logged", "nutrition.macros", "nutrition.insights"]
        XCTAssertEqual(Cards.all.filter { $0.page == .nutrition }.map(\.id), ids, "every Nutrition card is on the overview")

        let all = Cards.nutritionOverview(mode: .all, hidden: [])
        XCTAssertEqual(all, .init(row: Array(ids[0..<4]), pair: ["nutrition.macros", "nutrition.insights"], allHidden: false))
        XCTAssertEqual(Cards.nutritionOverview(mode: .noEnergy, hidden: []).row, ["nutrition.protein", "nutrition.water", "nutrition.logged"],
                       "no Energy card while calories are hidden")

        // Everything but Energy hidden: with calories hidden Energy never appears, so the page is all hidden (web 3efedb7).
        let allButEnergy = Set(ids.dropFirst())
        XCTAssertEqual(Cards.nutritionOverview(mode: .noEnergy, hidden: allButEnergy), .init(row: [], pair: [], allHidden: true))
        XCTAssertEqual(Cards.nutritionOverview(mode: .all, hidden: allButEnergy), .init(row: ["nutrition.energy"], pair: [], allHidden: false))
        XCTAssertTrue(Cards.nutritionOverview(mode: .all, hidden: Set(ids)).allHidden)

        // Hiding one leaves the rest in order, and the pair keeps the one left.
        XCTAssertEqual(Cards.nutritionOverview(mode: .all, hidden: ["nutrition.water", "nutrition.insights", "future.card"]),
                       .init(row: ["nutrition.energy", "nutrition.protein", "nutrition.logged"], pair: ["nutrition.macros"], allHidden: false))

        // No amounts: only Days logged can go, and the page keeps its note, so it's never all hidden.
        XCTAssertEqual(Cards.nutritionOverview(mode: .none, hidden: []), .init(row: ["nutrition.logged"], pair: [], allHidden: false))
        XCTAssertEqual(Cards.nutritionOverview(mode: .none, hidden: Set(ids)), .init(row: [], pair: [], allHidden: false))
    }
}
