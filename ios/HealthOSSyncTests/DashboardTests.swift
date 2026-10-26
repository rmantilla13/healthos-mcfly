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

final class DayCardTitleTests: XCTestCase {
    func testTheCardNamesItsMetric() {
        XCTAssertEqual(DayCard.title("Steps", running: true, isToday: true), "Steps so far today")
        XCTAssertEqual(DayCard.title("Active energy", running: true, isToday: true), "Active energy so far today")
        XCTAssertEqual(DayCard.title("Heart rate", running: false, isToday: true), "Heart rate today")
        XCTAssertEqual(DayCard.title("Steps", running: true, isToday: false), "Steps by hour")
        XCTAssertEqual(DayCard.title("Heart rate", running: false, isToday: false), "Heart rate by hour")
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

// MARK: - Card hiding (shared/cards.ts, Profile → Cards)

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
        // Either flag, or both (nutrition first, as cards.ts writes them).
        let cards = try groups(#"\{ id: '([^']+)', page: '([^']+)', label: (?:'([^']*)'|"([^"]*)")(, nutrition: true)?(, defaultHidden: true)? \}"#)
        XCTAssertEqual(cards.count, 41, "every card in CARDS")
        XCTAssertEqual(Cards.all.count, 41)
        XCTAssertEqual(cards.map { $0[0]! }, Cards.all.map(\.id), "same ids, same order")
        for (c, card) in zip(cards, Cards.all) {
            XCTAssertEqual(c[1], card.page.rawValue, card.id)
            XCTAssertEqual(c[2] ?? c[3], card.label, card.id)
            XCTAssertEqual(c[4] != nil, card.nutrition, card.id)
            XCTAssertEqual(c[5] != nil, card.optional, card.id)
        }
        XCTAssertEqual(Cards.optional, ["home.week", "home.timeline", "home.insights", "home.load", "home.activity", "home.food"])
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

    func testHiddenCardsLeaveTheRestInOrder() throws {
        let hidden: Set<String> = ["home.spo2", "home.load", "sleep.total", "future.card"]
        XCTAssertEqual(Cards.visible(Cards.todayGrid, hidden: hidden), ["home.readiness", "home.hrv", "home.sleep", "home.activity"])
        XCTAssertEqual(Cards.visible(Cards.todayGrid, hidden: []), Cards.todayGrid)
        XCTAssertFalse(Cards.allHidden(in: .home, hidden: hidden))
        XCTAssertTrue(Cards.allHidden(in: .home, hidden: Set(Cards.ids(in: .home))))
        XCTAssertFalse(Cards.allHidden(in: CardPlace(.vitals), hidden: Set(Cards.all.map(\.id))), "nothing to hide there, so no note")

        // The status's list, unknown ids ignored.
        let d = try dashboard(hidden: ["home.hrv", "future.card"])
        XCTAssertTrue(d.cardsAvailable)
        XCTAssertFalse(d.cardShown("home.hrv"))
        XCTAssertTrue(d.cardShown("home.spo2"))
        XCTAssertEqual(Cards.visible(Cards.todayGrid, hidden: d.cardsOff), ["home.readiness", "home.spo2", "home.sleep", "home.load", "home.activity"])
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
        XCTAssertEqual(off.flatMap(\.cards).count, 34)
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
        XCTAssertNil(d.pendingCards)
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
        XCTAssertNil(d.pendingCards)
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
        XCTAssertNil(d.pendingCards)
    }
}

/// The cards review's fixes: the Settings row and Show all count the same cards, and the Nutrition overview's cards
/// per setting (the web's rule, ready for its screen). Home's grid is in HomeFigureTests.
final class CardHidingReviewTests: XCTestCase {
    func testTheRowAndShowAllCountTheSameCards() throws {
        // Hidden on the web with Nutrition on, then Nutrition turned off; plus a newer server's card.
        let notListed: Set<String> = ["nutrition.water", "future.card"]
        XCTAssertEqual(Cards.hiddenOffered(notListed, nutrition: false), [], "All shown, and no Show all with every switch on")
        XCTAssertEqual(Cards.hiddenOffered(notListed, nutrition: true), ["nutrition.water"])
        XCTAssertEqual(Cards.hiddenOffered(["sleep.rhr", "future.card", "home.spo2", "nutrition.water"], nutrition: false),
                       ["home.spo2", "sleep.rhr"], "in the registry's order")
        XCTAssertEqual(Cards.hiddenOffered([], nutrition: true), [])
        // The optional cards are off, not hidden, so they don't count (CardVisibilityTests).
        XCTAssertEqual(Cards.hiddenOffered(Set(Cards.all.map(\.id)), nutrition: true), Cards.all.filter { !$0.optional }.map(\.id))
        XCTAssertEqual(Cards.hiddenOffered(Set(Cards.all.map(\.id)), nutrition: false).count, 29)
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
