import HealthKit
import XCTest
import SwiftUI
@testable import HealthOSSync

/// The on-device aggregation must match server/apple/import.ts. These mirror the server's own
/// tests in test/apple-import.test.ts, with the expected values computed there.
final class DayAggregatorTests: XCTestCase {
    private let pdt = TimeZone(secondsFromGMT: -7 * 3600)!

    /// "15 03:30" -> 2026-10-15 03:30 at -07:00, like the server tests' sleepXml helper.
    private func at(_ s: String) -> Stamp {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm Z"
        return Stamp(f.date(from: "2026-10-\(s) -0700")!, timeZone: pdt)
    }

    private func night(_ segments: [(SleepStage, String, String)]) -> SleepNight {
        DayAggregator.resolveNight(segments.map { SleepSegment(start: at($0.1), end: at($0.2), stage: $0.0) })
    }

    private func hours(_ minutes: Double) -> Double { (minutes / 60 * 100).rounded() / 100 }

    func testANapTheSameAppWroteCountsButTheNightKeepsItsOwnStartAndEnd() {
        // Mirrors test/apple-import.test.ts: the nap's hour counts toward sleep, but bed and wake are the night's.
        let n = night([(.unspecified, "14 22:30", "15 06:00"), (.unspecified, "15 14:00", "15 15:00")])
        XCTAssertEqual(hours(n.asleep), 8.5)
        XCTAssertEqual(n.start?.date, at("14 22:30").date)
        XCTAssertEqual(n.end?.date, at("15 06:00").date)
        // A long wake in the night (under 2 h with nothing recorded) is still one night.
        let broken = night([(.light, "14 23:00", "15 02:00"), (.light, "15 03:30", "15 07:00")])
        XCTAssertEqual(broken.start?.date, at("14 23:00").date)
        XCTAssertEqual(broken.end?.date, at("15 07:00").date)
    }

    func testTheSameNightWrittenManyTimesCountsOnce() {
        let n = night(Array(repeating: (.unspecified, "14 23:00", "15 07:00"), count: 16))
        XCTAssertEqual(hours(n.asleep), 8)
    }

    func testOverlappingStagesFromOneSourceAreMergedDeeperStageWins() {
        let n = night([
            (.light, "14 23:30", "15 03:30"),
            (.deep, "15 02:30", "15 04:00"),
            (.awake, "15 03:00", "15 03:15"),
            (.rem, "15 04:00", "15 05:00"),
            (.unspecified, "14 23:30", "15 05:00"),
            (.awake, "15 05:00", "15 05:20"),
        ])
        XCTAssertEqual(hours(n.asleep), 5.5)
        XCTAssertEqual(hours(n.light), 3)
        XCTAssertEqual(hours(n.deep), 1.5)
        XCTAssertEqual(hours(n.rem), 1)
        XCTAssertEqual(n.awake, 20)
        XCTAssertEqual(n.start?.localIso, "2026-10-14T23:30:00-07:00")
        XCTAssertEqual(n.end?.localIso, "2026-10-15T05:00:00-07:00")
    }

    func testOverlappingInBedRecordsCountAsTheirUnion() {
        let n = night([(.inBed, "14 23:00", "15 07:00"), (.inBed, "14 23:00", "15 07:00"), (.inBed, "15 00:00", "15 06:00")])
        XCTAssertEqual(hours(n.inBed), 8)
        XCTAssertEqual(n.asleep, 0)
    }

    func testANightBelongsToTheDayYouWakeUp() {
        XCTAssertEqual(at("14 06:45").localDate(shift: Day.rollover), "2026-10-14")
        XCTAssertEqual(at("14 23:59").localDate(shift: Day.rollover), "2026-10-15") // a nap ending late counts toward tomorrow
        XCTAssertEqual(at("14 17:59").localDate(shift: Day.rollover), "2026-10-14")
        XCTAssertEqual(at("14 06:45").localIso, "2026-10-14T06:45:00-07:00")
    }

    func testRecordsLongerThanAnyNightAreIgnored() {
        let type = HKCategoryType(.sleepAnalysis)
        let core = HKCategoryValueSleepAnalysis.asleepCore.rawValue
        let agg = DayAggregator(dates: ["2026-10-15"])
        agg.add(sleep: [
            HKCategorySample(type: type, value: core, start: at("12 23:00").date, end: at("15 07:00").date), // 56h: an app bug
            HKCategorySample(type: type, value: core, start: at("14 23:00").date, end: at("15 06:00").date),
        ])
        let rows = agg.finish()
        XCTAssertEqual(rows.daily.first { $0.metric == "sleep_hours" }?.value, 7)
        XCTAssertEqual(rows.events.map(\.kind), ["sleep"])
    }

    func testWhoopsCopyOfANightIsIgnored() {
        // WHOOP writes its sleep into Health too; healthOS reads WHOOP directly, so this copy must not
        // count, even though it has more sleep and would otherwise win the night.
        let whoop = SampleSource(name: "WHOOP", bundleIdentifier: "com.whoop.iphone")
        let watch = SampleSource(name: "Sam's Apple Watch", bundleIdentifier: "com.apple.health.81A5D1E0")
        let agg = DayAggregator(dates: ["2026-10-15"])
        agg.add(sleepRecords: [
            SleepRecord(start: at("14 22:00"), end: at("15 07:00"), stage: .unspecified, source: whoop),
            SleepRecord(start: at("14 23:00"), end: at("15 06:00"), stage: .light, source: watch),
        ])
        let rows = agg.finish()
        XCTAssertEqual(rows.daily.first { $0.metric == "sleep_hours" }?.value, 7)
        XCTAssertEqual(rows.events.first?.id, hashId("apple", "sleep", watch.name, "2026-10-15"))

        let whoopOnly = DayAggregator(dates: ["2026-10-15"])
        whoopOnly.add(sleepRecords: [SleepRecord(start: at("14 22:00"), end: at("15 07:00"), stage: .unspecified, source: whoop)])
        XCTAssertTrue(whoopOnly.finish().daily.isEmpty)
    }

    // MARK: sleep stages through the night (mirrors test/sleep-stages.test.ts)

    private func timeline(_ segments: [(SleepStage, String, String)]) -> [String] {
        DayAggregator.nightTimeline(segments.map { SleepSegment(start: at($0.1), end: at($0.2), stage: $0.0) }).map {
            "\($0.start.localIso.dropFirst(11).prefix(5))-\($0.end.localIso.dropFirst(11).prefix(5)) \($0.stage.name)"
        }
    }

    func testANightsTimelineHasOneStageAtATimeAndAddsUpToTheTotals() {
        let watch = SampleSource(name: "Sam's Apple Watch", bundleIdentifier: "com.apple.health.81A5D1E0")
        let records: [(SleepStage, String, String)] = [
            (.inBed, "14 22:00", "15 06:30"),
            (.light, "14 22:20", "15 00:00"),
            (.deep, "15 00:00", "15 01:00"),
            (.deep, "15 00:30", "15 01:00"),
            (.light, "15 01:00", "15 03:00"),
            (.awake, "15 03:00", "15 03:10"),
            (.rem, "15 03:10", "15 04:00"),
            (.light, "15 04:00", "15 05:00"),
            (.light, "15 05:00", "15 06:00"),
        ]
        XCTAssertEqual(timeline(records), [
            "22:00-22:20 in_bed", "22:20-00:00 light", "00:00-01:00 deep", "01:00-03:00 light",
            "03:00-03:10 awake", "03:10-04:00 rem", "04:00-06:00 light", "06:00-06:30 in_bed",
        ])

        let agg = DayAggregator(dates: ["2026-10-15"])
        agg.add(sleepRecords: records.map { SleepRecord(start: at($0.1), end: at($0.2), stage: $0.0, source: watch) })
        let p = agg.finish()
        let night = p.sleepStages?.first
        XCTAssertEqual(night?.date, "2026-10-15")
        let segs = night?.segments ?? []
        for (a, b) in zip(segs, segs.dropFirst()) { XCTAssertLessThanOrEqual(a.end, b.start) }
        func minutes(_ stage: String) -> Double {
            segs.filter { $0.stage == stage }.reduce(0) { total, g in
                let f = ISO8601DateFormatter()
                return total + f.date(from: g.end)!.timeIntervalSince(f.date(from: g.start)!) / 60
            }
        }
        for (stage, metric) in [("deep", "sleep_deep"), ("rem", "sleep_rem"), ("light", "sleep_light"), ("awake", "sleep_awake")] {
            XCTAssertEqual(minutes(stage), (p.daily.first { $0.metric == metric }!.value * 60).rounded(), stage)
        }
    }

    func testASameDayNapCountsInTheTotalsButIsntDrawn() {
        let segs = timeline([(.light, "14 23:00", "15 03:00"), (.deep, "15 03:00", "15 04:00"), (.light, "15 04:00", "15 07:00"), (.light, "15 14:00", "15 14:40")])
        XCTAssertEqual(segs, ["23:00-03:00 light", "03:00-04:00 deep", "04:00-07:00 light"])
    }

    func testSliversFoldInAndUnspecifiedSleepIsAsleep() {
        XCTAssertEqual(timeline([(.light, "14 23:00", "15 06:00")]).count, 1)
        let sliver = DayAggregator.nightTimeline([
            SleepSegment(start: at("14 23:00"), end: at("15 06:00"), stage: .light),
            SleepSegment(start: at("15 01:00"), end: Stamp(at("15 01:00").date.addingTimeInterval(30), timeZone: pdt), stage: .deep),
        ])
        XCTAssertEqual(sliver.map(\.stage), [.light])
        XCTAssertEqual(timeline([(.unspecified, "14 23:00", "15 06:00")]), ["23:00-06:00 asleep"])
    }

    func testStagesGoUpOnlyWhenTheWindowHadSleepAndClearNightsWithout() {
        let watch = SampleSource(name: "Sam's Apple Watch", bundleIdentifier: "com.apple.health.81A5D1E0")
        let none = DayAggregator(dates: ["2026-10-14", "2026-10-15"])
        XCTAssertNil(none.finish().sleepStages, "no sleep read at all (no access): nothing sent, nothing cleared")

        let one = DayAggregator(dates: ["2026-10-14", "2026-10-15"])
        one.add(sleepRecords: [SleepRecord(start: at("14 23:00"), end: at("15 06:00"), stage: .light, source: watch)])
        XCTAssertEqual(one.finish().sleepStages?.map(\.date), ["2026-10-14", "2026-10-15"])
        XCTAssertEqual(one.finish().sleepStages?.first?.segments, [], "a night with no sleep is cleared")
    }

    func testOlderStateFilesDecodeWithTheStageResendStillToDo() throws {
        let old = try JSONDecoder().decode(SyncState.self, from: Data(#"{"server":"https://health.mcfly.bot","whoopStepsResent":true}"#.utf8))
        XCTAssertFalse(old.sleepStagesResent)
        var state = old
        state.sleepStagesResent = true
        let round = try JSONDecoder().decode(SyncState.self, from: JSONEncoder().encode(state))
        XCTAssertTrue(round.sleepStagesResent)
    }

    private func point(_ hour: Int, _ minute: Int, _ value: Double, _ source: SampleSource) -> QuantityPoint {
        QuantityPoint(start: at("15 \(String(format: "%02d:%02d", hour, minute))"), value: value, source: source)
    }

    func testWhoopStepsCompeteForTheDayButOtherWhoopRecordsStaySkipped() {
        // Someone who wears WHOOP more than a Watch: the iPhone saw 1,000 steps, WHOOP 7,300. WHOOP wins the day,
        // never the sum (both count the same walking), and the hours are WHOOP's.
        let phone = SampleSource(name: "Sami's iPhone", bundleIdentifier: "com.apple.health.phone")
        let whoop = SampleSource(name: "WHOOP", bundleIdentifier: "com.whoop.iphone")
        let steps = HealthTypes.quantities.first { $0.metric == "steps" }!
        let resting = HealthTypes.quantities.first { $0.metric == "resting_hr" }!
        let agg = DayAggregator(dates: ["2026-10-15"])
        agg.add(points: [point(9, 0, 600, phone), point(17, 0, 400, phone),
                         point(9, 5, 3000, whoop), point(13, 0, 2300, whoop), point(17, 10, 2000, whoop)], as: steps)
        agg.add(points: [point(6, 0, 48, whoop)], as: resting)
        let p = agg.finish()
        XCTAssertEqual(p.daily.first { $0.metric == "steps" }?.value, 7300)
        let hours = (p.hourly ?? []).filter { $0.metric == "steps" }
        XCTAssertEqual(hours.map(\.hour), [9, 13, 17])
        XCTAssertEqual(hours.map(\.value), [3000, 2300, 2000])
        XCTAssertNil(p.daily.first { $0.metric == "resting_hr" })
        XCTAssertTrue(agg.sawWhoopSteps)
        XCTAssertTrue(whoop.counts("steps"))
        XCTAssertFalse(whoop.counts("resting_hr"))
    }

    func testHourlyStepsComeFromTheSourceThatWinsTheDay() {
        // iPhone and Watch both count the same walks; the day keeps the Watch (more steps), so its hours are sent
        // and they add up to the daily row.
        let phone = SampleSource(name: "Sam's iPhone", bundleIdentifier: "com.apple.health.phone")
        let watch = SampleSource(name: "Sam's Apple Watch", bundleIdentifier: "com.apple.health.watch")
        let steps = HealthTypes.quantities.first { $0.metric == "steps" }!
        let agg = DayAggregator(dates: ["2026-10-15"])
        agg.add(points: [
            point(8, 10, 900, phone), point(8, 40, 400, phone), point(12, 5, 1500, phone),
            point(8, 15, 1400, watch), point(12, 0, 1700, watch), point(18, 30, 2000, watch),
        ], as: steps)
        let p = agg.finish()
        let daily = p.daily.first { $0.metric == "steps" }!.value
        let hours = (p.hourly ?? []).filter { $0.metric == "steps" }
        XCTAssertEqual(daily, 5100)
        XCTAssertEqual(hours.map(\.hour), [8, 12, 18])
        XCTAssertEqual(hours.map(\.value), [1400, 1700, 2000])
        XCTAssertEqual(hours.reduce(0) { $0 + $1.value }, daily)
    }

    func testHeartRateIsBucketedByHourOverEverySourceButWhoop() {
        let watch = SampleSource(name: "Sam's Apple Watch", bundleIdentifier: "com.apple.health.watch")
        let other = SampleSource(name: "Oura", bundleIdentifier: "com.ouraring.oura")
        let whoop = SampleSource(name: "WHOOP", bundleIdentifier: "com.whoop.iphone")
        let hr = HealthTypes.quantities.first { $0.metric == "hr_avg" }!
        let agg = DayAggregator(dates: ["2026-10-15"])
        agg.add(points: [point(7, 10, 60, watch), point(7, 40, 80, other), point(7, 50, 150, whoop), point(23, 59, 55, watch)], as: hr)
        let rows = (agg.finish().hourly ?? []).map { "\($0.hour) \($0.metric) \(Int($0.value))" }
        XCTAssertEqual(rows, [
            "7 hr_avg 70", "23 hr_avg 55",
            "7 hr_max 80", "23 hr_max 55",
            "7 hr_min 60", "23 hr_min 55",
        ])
    }

    func testHourlyHistoryIsBackfilledOnceTheServerStoresHours() {
        var state = SyncState(server: "https://health.mcfly.bot")
        state.anchors = ["steps": Data([1])]
        state.startHourlyBackfill(serverStoresHours: false) // an older server: nothing changes
        XCTAssertFalse(state.hourlyBackfillStarted)
        XCTAssertEqual(state.anchors.count, 1)

        state.startHourlyBackfill(serverStoresHours: true) // first reply with an hourly count
        XCTAssertTrue(state.hourlyBackfillStarted)
        XCTAssertTrue(state.anchors.isEmpty, "all history is read again")

        state.pending = ["2026-10-15"]
        state.finishHourlyBackfill(serverStoredHours: true)
        XCTAssertFalse(state.hourlyBackfillDone, "days still to send")
        state.pending = []
        state.finishHourlyBackfill(serverStoredHours: false)
        XCTAssertFalse(state.hourlyBackfillDone, "no confirmation from the server yet")
        state.finishHourlyBackfill(serverStoredHours: true)
        XCTAssertTrue(state.hourlyBackfillDone)

        state.anchors = ["steps": Data([2])]
        state.startHourlyBackfill(serverStoresHours: true) // never twice
        XCTAssertEqual(state.anchors.count, 1)
    }

    func testCycleRecordsFoldLikeTheImporter() {
        let t0 = at("15 07:00").date, t1 = at("15 22:00").date
        let days = CycleFolder.fold([
            CycleRecord(date: "2026-10-15", at: t0, kind: .flow("light", periodStart: true)),
            CycleRecord(date: "2026-10-15", at: t1, kind: .flow("heavy", periodStart: false)),
            CycleRecord(date: "2026-10-15", at: t0, kind: .ovulation("negative")),
            CycleRecord(date: "2026-10-15", at: t1, kind: .ovulation("lh_surge")),
            CycleRecord(date: "2026-10-15", at: t1, kind: .bbt(36.9)),
            CycleRecord(date: "2026-10-15", at: t0, kind: .bbt(36.4)), // the first reading wins
            CycleRecord(date: "2026-10-15", at: t0, kind: .sexual("protected")),
            CycleRecord(date: "2026-10-15", at: t1, kind: .sexual("unprotected")),
            CycleRecord(date: "2026-10-16", at: t1, kind: .mucus("egg_white")),
            CycleRecord(date: "2026-10-14", at: t1, kind: .spotting), // not a day being sent
        ], dates: ["2026-10-15", "2026-10-16"])
        XCTAssertEqual(days, [
            CycleDay(date: "2026-10-15", flow: "heavy", periodStart: true, ovulationTest: "lh_surge", bbt: 36.4, sexualActivity: "unprotected"),
            CycleDay(date: "2026-10-16", mucus: "egg_white"),
        ])
    }

    func testHealthSymptomsJoinTheDayOnceEach() {
        let t0 = at("15 07:00").date, t1 = at("15 22:00").date
        let days = CycleFolder.fold([
            CycleRecord(date: "2026-10-15", at: t0, kind: .symptom("headache")),
            CycleRecord(date: "2026-10-15", at: t0, kind: .symptom("cramps")),
            CycleRecord(date: "2026-10-15", at: t1, kind: .symptom("cramps")),
            CycleRecord(date: "2026-10-15", at: t1, kind: .flow("medium", periodStart: false)),
        ], dates: ["2026-10-15"])
        XCTAssertEqual(days, [CycleDay(date: "2026-10-15", flow: "medium", symptoms: ["cramps", "headache"])])

        // Health's own records: severity "not present" (1) is a logged absence, not a symptom.
        let pacific: [String: Any] = [HKMetadataKeyTimeZone: "America/Los_Angeles"]
        let sample = { (type: HKCategoryType, value: Int) in HKCategorySample(type: type, value: value, start: self.at("15 08:00").date, end: self.at("15 08:00").date, metadata: pacific) }
        let records = CycleFolder.records(category: [
            sample(HKCategoryType(.abdominalCramps), HKCategoryValueSeverity.moderate.rawValue),
            sample(HKCategoryType(.headache), HKCategoryValueSeverity.notPresent.rawValue),
            sample(HKCategoryType(.moodChanges), HKCategoryValuePresence.present.rawValue),
            sample(HKCategoryType(.appetiteChanges), HKCategoryValueAppetiteChanges.noChange.rawValue),
        ])
        let folded = CycleFolder.fold(records, dates: ["2026-10-15"])
        XCTAssertEqual(folded.first?.symptoms, ["cramps", "mood_changes"])
        XCTAssertEqual(CycleTypes.symptoms.count, 12)
        XCTAssertTrue(CycleTypes.all.contains(HKCategoryType(.hotFlashes)))
    }

    func testWhoopIsRecognizedByNameOrBundle() {
        // Same rule as fromDirectSource in server/apple/import.ts (/^whoop\b/i on the name), plus the bundle ID.
        XCTAssertTrue(SampleSource(name: "WHOOP", bundleIdentifier: "").isReadDirectly)
        XCTAssertTrue(SampleSource(name: " whoop 4.0", bundleIdentifier: "").isReadDirectly)
        XCTAssertTrue(SampleSource(name: "My Band", bundleIdentifier: "com.Whoop.iphone").isReadDirectly)
        XCTAssertFalse(SampleSource(name: "Whoopsie Sleep", bundleIdentifier: "com.example.sleep").isReadDirectly)
        XCTAssertFalse(SampleSource(name: "Sam's Apple Watch", bundleIdentifier: "com.apple.health.81A5D1E0").isReadDirectly)
    }

    func testIdsAndSportNamesMatchTheExportImporter() {
        // Expected values from server/apple/import.ts (hashId, sportName).
        XCTAssertEqual(hashId("apple", "sleep", "Watch", "2026-10-14"), "6b3a960ff96b21d5f3d6")
        XCTAssertEqual(WorkoutNames.sport(WorkoutNames.name(.highIntensityIntervalTraining)), "High Intensity Interval Training")
        XCTAssertEqual(WorkoutNames.sport(WorkoutNames.name(.traditionalStrengthTraining)), "Traditional Strength Training")
        XCTAssertEqual(WorkoutNames.sport(WorkoutNames.name(.yoga)), "Yoga")
    }

    func testServerAddressesWithoutASchemeUseTLSUnlessLocal() {
        XCTAssertEqual(Config.serverURL("health.mcfly.bot")?.absoluteString, "https://health.mcfly.bot")
        XCTAssertEqual(Config.serverURL(" https://health.mcfly.bot/ ")?.absoluteString, "https://health.mcfly.bot")
        XCTAssertEqual(Config.serverURL("192.168.1.20:8788")?.absoluteString, "http://192.168.1.20:8788")
        XCTAssertEqual(Config.serverURL("localhost:8787")?.absoluteString, "http://localhost:8787")
        XCTAssertEqual(Config.serverURL("macbook.local:8788")?.absoluteString, "http://macbook.local:8788")
        XCTAssertNil(Config.serverURL("ftp://example.com"))
        XCTAssertNil(Config.serverURL(""))
    }

    func testPendingDaysAreUploadedAWeekAtATimeNewestFirst() {
        let days = ["2026-10-01", "2026-10-02", "2026-10-07", "2026-10-08", "2026-10-20"]
        // Newest window first; each window oldest first, because Health.payload reads from its first day to its last.
        XCTAssertEqual(SyncEngine.windows(days), [["2026-10-20"], ["2026-10-02", "2026-10-07", "2026-10-08"], ["2026-10-01"]])
        XCTAssertEqual(SyncEngine.windows(["2026-10-08", "2026-10-02", "2026-10-08"]), [["2026-10-02", "2026-10-08"]])
        for window in SyncEngine.windows(days) { XCTAssertEqual(window, window.sorted()) }
    }

    func testDeletedCycleEntryClearsItsDay() {
        var state = SyncState()
        XCTAssertEqual(state.noteCycle(added: ["A": "2026-03-02", "B": "2026-03-03"], deleted: [], today: "2026-10-17"), [])
        // Deleting A: its day is rechecked and, with nothing left, sent as {date}.
        XCTAssertEqual(state.noteCycle(added: [:], deleted: ["A"], today: "2026-10-17"), ["2026-03-02"])
        XCTAssertEqual(state.cycleClear, ["2026-03-02"])
        XCTAssertNil(state.cycleSampleDays["A"])
        // A deletion with no known day rechecks the last 60 days.
        XCTAssertEqual(state.noteCycle(added: [:], deleted: ["Z"], today: "2026-10-17").count, 61)

        let at = Date()
        let kept = CycleRecord(date: "2026-03-03", at: at, kind: .spotting)
        let days = CycleFolder.fold([kept], dates: ["2026-03-01", "2026-03-02", "2026-03-03"], clearing: ["2026-03-02", "2026-03-03"])
        XCTAssertEqual(days, [CycleDay(date: "2026-03-02"), CycleDay(date: "2026-03-03", spotting: true)])
        // An empty day nobody deleted from stays out, so an export import's rows there survive.
        XCTAssertFalse(days.contains { $0.date == "2026-03-01" })
        let json = String(data: try! JSONEncoder().encode(CycleDay(date: "2026-03-02")), encoding: .utf8)
        XCTAssertEqual(json, #"{"date":"2026-03-02"}"#)
    }

    /// An older build part-way through sending all of history oldest first (it had reached 2019-10-24).
    func testUpgradeMidBackfillSendsRecentMonthFirstThenHistoryNewestFirst() throws {
        let today = "2026-10-17"
        var pending: [String] = []
        var d = "2019-10-25"
        while d <= "2026-10-16" { pending.append(d); d = Day.add(d, 1) }
        let json = try JSONSerialization.data(withJSONObject: ["server": "https://health.mcfly.bot", "pending": pending, "hourlyBackfillStarted": true])
        var state = try JSONDecoder().decode(SyncState.self, from: json)
        XCTAssertTrue(state.hourlyBackfillStarted)

        state.pending = Set(state.pending).union([today]).sorted()
        state.splitOld(today: today)
        XCTAssertEqual(state.pending.first, "2026-09-17")
        XCTAssertEqual(state.pending.last, today)
        XCTAssertEqual(state.pending.count, 31)
        let recent = SyncEngine.windows(state.pending)
        XCTAssertEqual(recent.first?.last, today)
        XCTAssertEqual(recent.first?.first, "2026-10-11")

        // History: newest first, nothing from before 2019-10-25 (already on the server), nothing recent twice.
        let history = SyncEngine.windows(state.backfill)
        XCTAssertEqual(history.first, ["2026-09-10", "2026-09-11", "2026-09-12", "2026-09-13", "2026-09-14", "2026-09-15", "2026-09-16"])
        XCTAssertEqual(history.last?.first, "2019-10-25")
        XCTAssertTrue(Set(state.backfill).isDisjoint(with: state.pending))

        // Not done until the backfill queue is empty too.
        state.pending = []
        state.finishHourlyBackfill(serverStoredHours: true)
        XCTAssertFalse(state.hourlyBackfillDone)
        state.backfill = []
        state.finishHourlyBackfill(serverStoredHours: true)
        XCTAssertTrue(state.hourlyBackfillDone)
    }

    // MARK: New daily metrics (iOS 1.1)

    /// The daily metrics this batch adds (CONTRACT section 1); the server lists them with the legacy 24.
    private let newMetrics = [
        "blood_pressure_systolic", "blood_pressure_diastolic", "glucose", "walking_speed", "walking_steadiness",
        "walking_asymmetry", "daylight_min", "flights", "stand_hours", "breathing_disturbances", "caffeine_mg", "water_ml",
    ]
    private var serverMetrics: [String] { (SyncState.legacyMetrics.union(newMetrics)).sorted() }

    private func metric(_ name: String) -> QuantityMetric { HealthTypes.quantities.first { $0.metric == name }! }

    /// A HealthKit sample recorded at `time` in Pacific time (so the day doesn't depend on the simulator's zone).
    private func sample(_ name: String, _ value: Double, _ unit: HKUnit, _ time: String) -> HKQuantitySample {
        HKQuantitySample(type: metric(name).type, quantity: HKQuantity(unit: unit, doubleValue: value), start: at(time).date, end: at(time).date,
                         metadata: [HKMetadataKeyTimeZone: "America/Los_Angeles"])
    }

    private func daily(_ p: IngestPayload, _ metric: String) -> Double? { p.daily.first { $0.metric == metric }?.value }

    func testEveryQuantityIsReadInAUnitItsTypeUses() {
        // A wrong HKUnit raises at runtime, and the point-based tests never touch units.
        for q in HealthTypes.quantities { XCTAssertTrue(q.type.is(compatibleWith: q.unit), q.metric) }
        let read = Set(HealthTypes.quantities.map(\.metric))
        for name in newMetrics where name != "stand_hours" {
            if name == "breathing_disturbances", #unavailable(iOS 18.0) { continue }
            XCTAssertTrue(read.contains(name), name)
        }
        XCTAssertTrue(HealthTypes.sampleTypes.contains(HealthTypes.standHour))
    }

    func testNewQuantitiesConvertToTheServersUnits() {
        let agg = DayAggregator(dates: ["2026-10-15"])
        let mmolPerL = HKUnit.moleUnit(with: .milli, molarMass: HKUnitMolarMassBloodGlucose).unitDivided(by: .liter())
        let mps = HKUnit.meter().unitDivided(by: .second())
        let samples: [(String, [HKQuantitySample])] = [
            ("blood_pressure_systolic", [sample("blood_pressure_systolic", 118, .millimeterOfMercury(), "15 07:30"),
                                         sample("blood_pressure_systolic", 124, .millimeterOfMercury(), "15 19:30")]),
            ("blood_pressure_diastolic", [sample("blood_pressure_diastolic", 76, .millimeterOfMercury(), "15 07:30")]),
            ("glucose", [sample("glucose", 5.5, mmolPerL, "15 07:00"), sample("glucose", 101, HKUnit(from: "mg/dL"), "15 13:00")]),
            ("walking_speed", [sample("walking_speed", 1.25, mps, "15 09:00"), sample("walking_speed", 1.35, mps, "15 17:00")]),
            ("walking_steadiness", [sample("walking_steadiness", 0.71, .percent(), "15 06:00"), sample("walking_steadiness", 0.82, .percent(), "15 08:00")]),
            ("walking_asymmetry", [sample("walking_asymmetry", 0.02, .percent(), "15 09:00"), sample("walking_asymmetry", 0.04, .percent(), "15 17:00")]),
            ("daylight_min", [sample("daylight_min", 1_200, .second(), "15 12:00"), sample("daylight_min", 15, .minute(), "15 16:00")]),
            ("flights", [sample("flights", 3, .count(), "15 08:00"), sample("flights", 4, .count(), "15 18:00")]),
            ("caffeine_mg", [sample("caffeine_mg", 0.095, .gram(), "15 08:00"), sample("caffeine_mg", 64, .gramUnit(with: .milli), "15 14:30")]),
            ("water_ml", [sample("water_ml", 0.5, .liter(), "15 09:00"), sample("water_ml", 250, .literUnit(with: .milli), "15 13:00")]),
        ]
        for (name, list) in samples { agg.add(list, as: metric(name)) }
        let p = agg.finish()
        XCTAssertEqual(daily(p, "blood_pressure_systolic"), 121)
        XCTAssertEqual(daily(p, "blood_pressure_diastolic"), 76)
        XCTAssertEqual(daily(p, "glucose")!, (99.0857 + 101) / 2, accuracy: 0.01) // mmol/L becomes mg/dL
        XCTAssertEqual(daily(p, "walking_speed")!, 4.68, accuracy: 0.0001) // m/s becomes km/h
        XCTAssertEqual(daily(p, "walking_steadiness")!, 82, accuracy: 0.0001) // the latest reading, as a percent
        XCTAssertEqual(daily(p, "walking_asymmetry")!, 3, accuracy: 0.0001)
        XCTAssertEqual(daily(p, "daylight_min")!, 35, accuracy: 0.0001)
        XCTAssertEqual(daily(p, "flights"), 7)
        XCTAssertEqual(daily(p, "caffeine_mg")!, 159, accuracy: 0.0001)
        XCTAssertEqual(daily(p, "water_ml")!, 750, accuracy: 0.0001)
        XCTAssertNil(p.hourly, "none of these has hours for the Day view")

        if #available(iOS 18.0, *) {
            let nights = DayAggregator(dates: ["2026-10-15"])
            nights.add([sample("breathing_disturbances", 2, .count(), "15 00:30"), sample("breathing_disturbances", 5, .count(), "15 04:00")],
                       as: metric("breathing_disturbances"))
            XCTAssertEqual(daily(nights.finish(), "breathing_disturbances"), 3.5)
        }
    }

    func testCaffeineAndWaterAddUpAcrossAppsWhileFlightsAndDaylightKeepTheBestSource() {
        // A coffee logged in one app and a second in another are two coffees; the iPhone and Watch counting the
        // same stairs are one set of stairs.
        let phone = SampleSource(name: "Sam's iPhone", bundleIdentifier: "com.apple.health.phone")
        let watch = SampleSource(name: "Sam's Apple Watch", bundleIdentifier: "com.apple.health.watch")
        let coffeeApp = SampleSource(name: "Caffeine Log", bundleIdentifier: "com.example.caffeine")
        let waterApp = SampleSource(name: "WaterMinder", bundleIdentifier: "com.example.water")
        let agg = DayAggregator(dates: ["2026-10-15"])
        agg.add(points: [point(8, 0, 95, coffeeApp), point(14, 0, 64, phone), point(16, 0, 30, coffeeApp)], as: metric("caffeine_mg"))
        agg.add(points: [point(9, 0, 250, waterApp), point(12, 0, 500, phone), point(18, 0, 250, waterApp)], as: metric("water_ml"))
        agg.add(points: [point(8, 0, 3, phone), point(12, 0, 2, phone), point(8, 5, 4, watch)], as: metric("flights"))
        agg.add(points: [point(12, 0, 20, watch), point(16, 0, 15, watch), point(12, 0, 10, phone)], as: metric("daylight_min"))
        let p = agg.finish()
        XCTAssertEqual(daily(p, "caffeine_mg"), 189)
        XCTAssertEqual(daily(p, "water_ml"), 1000)
        XCTAssertEqual(daily(p, "flights"), 5)
        XCTAssertEqual(daily(p, "daylight_min"), 35)
        XCTAssertEqual(p.daily.filter { $0.metric == "caffeine_mg" }.count, 1)
        XCTAssertNil(p.hourly)
    }

    func testStandHoursCountEachLocalHourStoodOnce() {
        let watch = SampleSource(name: "Sam's Apple Watch", bundleIdentifier: "com.apple.health.watch")
        let oldWatch = SampleSource(name: "Sam's old Apple Watch", bundleIdentifier: "com.apple.health.watch2")
        let whoop = SampleSource(name: "WHOOP", bundleIdentifier: "com.whoop.iphone")
        let agg = DayAggregator(dates: ["2026-10-15", "2026-10-16"])
        agg.add(standRecords: [
            StandRecord(start: at("15 09:00"), stood: true, source: watch),
            StandRecord(start: at("15 10:00"), stood: true, source: watch),
            StandRecord(start: at("15 11:00"), stood: false, source: watch), // idle
            StandRecord(start: at("15 09:00"), stood: true, source: oldWatch), // the same hour from a second watch
            StandRecord(start: at("15 13:00"), stood: true, source: oldWatch),
            StandRecord(start: at("15 15:00"), stood: true, source: watch),
            StandRecord(start: at("15 15:30"), stood: true, source: oldWatch), // same clock hour
            StandRecord(start: at("15 17:00"), stood: true, source: whoop), // never counts
            StandRecord(start: at("14 18:00"), stood: true, source: watch), // not a day being sent
            StandRecord(start: at("16 08:00"), stood: false, source: watch), // a day with only idle hours
        ])
        let p = agg.finish()
        XCTAssertEqual(p.daily.filter { $0.metric == "stand_hours" }, [DailyRow(date: "2026-10-15", metric: "stand_hours", value: 4)])

        // HealthKit's own record: value 0 is "stood", 1 is "idle".
        let hk = DayAggregator(dates: ["2026-10-15"])
        let pacific: [String: Any] = [HKMetadataKeyTimeZone: "America/Los_Angeles"]
        hk.add(standHours: [
            HKCategorySample(type: HealthTypes.standHour, value: HKCategoryValueAppleStandHour.stood.rawValue, start: at("15 09:00").date, end: at("15 10:00").date, metadata: pacific),
            HKCategorySample(type: HealthTypes.standHour, value: HKCategoryValueAppleStandHour.idle.rawValue, start: at("15 10:00").date, end: at("15 11:00").date, metadata: pacific),
            HKCategorySample(type: HealthTypes.standHour, value: HKCategoryValueAppleStandHour.stood.rawValue, start: at("15 23:00").date, end: at("16 00:00").date, metadata: pacific),
        ])
        XCTAssertEqual(daily(hk.finish(), "stand_hours"), 2)

        // Change detection marks the hour's start day dirty, not a rolled-over wake day like sleep.
        let late = HKCategorySample(type: HealthTypes.standHour, value: 0, start: at("15 23:30").date, end: at("16 00:00").date, metadata: pacific)
        XCTAssertEqual(Health.day(of: late), "2026-10-15")
    }

    func testSleepingWristTemperatureCountsTowardTheWakeDay() {
        // Mirrors test/apple-import.test.ts: asleep before midnight or after it, the night belongs to the day it ends.
        let wrist = HealthTypes.quantities.first { $0.metric == "wrist_temp" }!
        XCTAssertTrue(wrist.byWakeDay)
        let watch = SampleSource(name: "Sam's Apple Watch", bundleIdentifier: "com.apple.health.81A5D1E0")
        let agg = DayAggregator(dates: ["2026-10-14", "2026-10-15", "2026-10-16"])
        agg.add(points: [
            QuantityPoint(start: at("14 23:30"), value: 34.6, source: watch, end: at("15 06:30")),
            QuantityPoint(start: at("16 00:40"), value: 34.9, source: watch, end: at("16 07:10")),
        ], as: wrist)
        XCTAssertEqual(agg.finish().daily.filter { $0.metric == "wrist_temp" }.map(\.date).sorted(), ["2026-10-15", "2026-10-16"])

        // A new night marks its wake day and the evening it began, where older builds dated it.
        let pacific: [String: Any] = [HKMetadataKeyTimeZone: "America/Los_Angeles"]
        let night = HKQuantitySample(type: HealthTypes.wristTemp, quantity: HKQuantity(unit: .degreeCelsius(), doubleValue: 34.6), start: at("14 23:30").date, end: at("15 06:30").date, metadata: pacific)
        XCTAssertEqual(Health.day(of: night), "2026-10-15")
        XCTAssertEqual(Health.days(of: night), ["2026-10-14", "2026-10-15"])
    }

    func testWhoopsCopiesOfTheNewTypesAreSkipped() {
        let whoop = SampleSource(name: "WHOOP", bundleIdentifier: "com.whoop.iphone")
        let agg = DayAggregator(dates: ["2026-10-15"])
        for q in HealthTypes.quantities where newMetrics.contains(q.metric) {
            XCTAssertFalse(whoop.counts(q.metric), q.metric)
            agg.add(points: [point(9, 0, 1, whoop), point(15, 0, 2, whoop)], as: q)
        }
        agg.add(standRecords: [StandRecord(start: at("15 09:00"), stood: true, source: whoop)])
        let p = agg.finish()
        XCTAssertTrue(p.daily.isEmpty, p.daily.map(\.metric).joined(separator: ", "))
        XCTAssertFalse(agg.sawWhoopSteps)
    }

    func testEveryTypeHasItsOwnNameAndFrequentOnesWakeHourly() {
        XCTAssertEqual(HealthTypes.label(HealthTypes.standHour), "stand hours")
        XCTAssertEqual(HealthTypes.label(metric("daylight_min").type), "time in daylight")
        XCTAssertEqual(HealthTypes.label(metric("caffeine_mg").type), "caffeine")
        XCTAssertEqual(HealthTypes.label(metric("walking_speed").type), "walking speed")
        XCTAssertEqual(HealthTypes.label(HealthTypes.workout), "workouts")
        for type in HealthTypes.sampleTypes(food: NutritionTypes.all) where type != HealthTypes.workout {
            XCTAssertNotEqual(HealthTypes.label(type), "workouts", type.identifier)
        }
        let walking = ["daylight_min", "flights", "walking_speed", "walking_steadiness", "walking_asymmetry"]
        let hourly: [HKSampleType] = [HealthTypes.standHour] + walking.map { metric($0).type as HKSampleType }
        for type in hourly { XCTAssertEqual(Health.deliveryFrequency(type), .hourly, type.identifier) }
        for name in ["glucose", "blood_pressure_systolic", "caffeine_mg", "water_ml"] {
            XCTAssertEqual(Health.deliveryFrequency(metric(name).type), .immediate, name)
        }
    }

    #if targetEnvironment(simulator)
    func testSampleDataOnlyAsksToWriteTypesAppsCanWrite() {
        // Asking to share a type apps can't write fails the authorization request.
        let share = Set(SampleData.shareTypes.map(\.identifier))
        for name in ["walking_speed", "walking_steadiness", "walking_asymmetry", "daylight_min", "breathing_disturbances"] {
            guard let q = HealthTypes.quantities.first(where: { $0.metric == name }) else { continue }
            XCTAssertFalse(share.contains(q.type.identifier), name)
        }
        XCTAssertFalse(share.contains(HealthTypes.standHour.identifier))
        XCTAssertFalse(share.contains("HKQuantityTypeIdentifierAppleSleepingBreathingDisturbances"))
        for name in ["blood_pressure_systolic", "blood_pressure_diastolic", "glucose", "caffeine_mg", "water_ml", "flights"] {
            XCTAssertTrue(share.contains(metric(name).type.identifier), name)
        }
    }
    #endif

    // MARK: Capability probe

    func testRowsTheServerWouldRejectAreLeftOut() throws {
        var payload = IngestPayload()
        payload.daily = [
            DailyRow(date: "2026-10-15", metric: "steps", value: 9000),
            DailyRow(date: "2026-10-15", metric: "glucose", value: 95),
            DailyRow(date: "2026-10-15", metric: "stand_hours", value: 11),
        ]
        payload.hourly = [HourlyRow(date: "2026-10-15", hour: 9, metric: "steps", value: 900)]
        payload.events = [EventRow(id: "hk-1", kind: "mindful", title: "Mindfulness", start: "2026-10-15T12:00:00-07:00", end: "2026-10-15T12:10:00-07:00", date: "2026-10-15")]

        // A server that doesn't list its metrics takes the 24 it always did.
        var state = SyncState(server: "https://health.mcfly.bot")
        XCTAssertEqual(SyncState.legacyMetrics.count, 24)
        XCTAssertEqual(state.filtered(payload).daily.map(\.metric), ["steps"])
        XCTAssertEqual(state.filtered(payload).hourly, payload.hourly)
        XCTAssertEqual(state.filtered(payload).events, payload.events)
        XCTAssertEqual(state.filtered(payload).rowCount, 2)

        state.noteAccepted(serverMetrics)
        XCTAssertEqual(state.filtered(payload).daily.map(\.metric), ["steps", "glucose", "stand_hours"])
        state.noteAccepted(["steps", "glucose"])
        XCTAssertEqual(state.filtered(payload).daily.map(\.metric), ["steps", "glucose"])
        // A reply without the list (an older server; how a rollback gets here: testAServerThatWentBackStillTakesTheRest).
        state.noteAccepted(nil)
        XCTAssertNil(state.acceptedMetrics)
        XCTAssertEqual(state.filtered(payload).daily.map(\.metric), ["steps"])

        // Saved with the rest of the sync state; files from older builds have no list.
        state.noteAccepted(serverMetrics)
        let decoded = try JSONDecoder().decode(SyncState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded.acceptedMetrics, serverMetrics)
        let old = try JSONDecoder().decode(SyncState.self, from: Data(#"{"server":"https://health.mcfly.bot","pending":[]}"#.utf8))
        XCTAssertNil(old.acceptedMetrics)
    }

    /// An ingest endpoint that takes only `metrics`, refusing the whole request otherwise like server/apple/ingest.ts,
    /// and lists them in its replies when `lists` is set (older servers don't).
    private final class FakeServer {
        let metrics: Set<String>
        let lists: Bool
        /// What it really takes, when that differs from the list.
        var takes: Set<String>?
        var refuse: IngestClient.Rejected?
        var sent: [[String]] = []

        init(metrics: Set<String>, lists: Bool) {
            self.metrics = metrics
            self.lists = lists
        }

        func send(_ payload: IngestPayload) throws -> IngestClient.Response {
            sent.append(payload.daily.map(\.metric))
            if let refuse { throw refuse }
            let takes = takes ?? metrics
            if let i = payload.daily.firstIndex(where: { !takes.contains($0.metric) }) {
                throw IngestClient.Rejected(status: 400, detail: "daily[\(i)].metric: unknown metric \"\(payload.daily[i].metric)\"")
            }
            return IngestClient.Response(daily: payload.daily.count, workouts: 0, events: 0, hourly: 0, cycle: 0, sleepStages: 0, metrics: lists ? metrics.sorted() : nil)
        }
    }

    private var todayPayload: IngestPayload {
        var payload = IngestPayload()
        payload.daily = [
            DailyRow(date: "2026-10-17", metric: "steps", value: 9000),
            DailyRow(date: "2026-10-17", metric: "stand_hours", value: 11),
            DailyRow(date: "2026-10-17", metric: "flights", value: 7),
        ]
        return payload
    }

    func testAServerThatWentBackStillTakesTheRest() async throws {
        // This build learned the full list, then the server at the same URL went back to the build without it.
        var state = SyncState(server: "https://health.mcfly.bot")
        state.noteAccepted(serverMetrics)
        // Without food types, whatever Nutrition setting this simulator's app last synced with.
        for type in HealthTypes.sampleTypes(food: []) { state.anchors[type.identifier] = Data([1]) }
        let anchors = state.anchors
        let old = FakeServer(metrics: SyncState.legacyMetrics, lists: false)

        // Refused, asked again with an empty push, and sent once more without the rows it doesn't take.
        let (reply, rows) = try await state.push(todayPayload) { try old.send($0) }
        XCTAssertEqual(old.sent, [["steps", "stand_hours", "flights"], [], ["steps"]])
        XCTAssertEqual(rows, 1)
        XCTAssertEqual(reply.daily, 1)
        XCTAssertNil(state.acceptedMetrics)
        XCTAssertEqual(state.anchors, anchors, "a server that takes less: nothing to read again")

        // Saved like any other reply, so the syncs after go straight up with the legacy set.
        state = try JSONDecoder().decode(SyncState.self, from: JSONEncoder().encode(state))
        old.sent = []
        try await state.push(todayPayload) { try old.send($0) }
        XCTAssertEqual(old.sent, [["steps"]])

        // The newer server is back: the rows left out meanwhile go up again through their types' history.
        let new = FakeServer(metrics: Set(serverMetrics), lists: true)
        try await state.push(todayPayload) { try new.send($0) }
        XCTAssertEqual(new.sent, [["steps"]])
        XCTAssertEqual(state.acceptedMetrics, serverMetrics)
        XCTAssertNil(state.anchors[HealthTypes.standHour.identifier])
        XCTAssertNil(state.anchors[HKQuantityType(.flightsClimbed).identifier])
        XCTAssertNotNil(state.anchors[HKQuantityType(.stepCount).identifier])

        // A server that went back to a shorter list is taken at its word too.
        var listed = SyncState()
        listed.noteAccepted(serverMetrics)
        let shorter = FakeServer(metrics: SyncState.legacyMetrics.union(["flights"]), lists: true)
        let (_, sent) = try await listed.push(todayPayload) { try shorter.send($0) }
        XCTAssertEqual(shorter.sent, [["steps", "stand_hours", "flights"], [], ["steps", "flights"]])
        XCTAssertEqual(sent, 2)
        XCTAssertEqual(listed.acceptedMetrics, shorter.metrics.sorted())
    }

    func testOnlyAnUnknownMetricIsRetriedAndOnlyOnce() async {
        let unknownHourly = IngestClient.Rejected(status: 400, detail: #"hourly[0].metric: unknown hourly metric "x""#)
        let badDate = IngestClient.Rejected(status: 400, detail: "daily[0].date: expected a date as YYYY-MM-DD")
        XCTAssertEqual(badDate.localizedDescription, "Server answered 400: daily[0].date: expected a date as YYYY-MM-DD")
        XCTAssertTrue(IngestClient.Rejected(status: 400, detail: #"daily[3].metric: unknown metric "stand_hours""#).unknownMetric)
        XCTAssertFalse(IngestClient.Rejected(status: 500, detail: #"daily[3].metric: unknown metric "stand_hours""#).unknownMetric)
        XCTAssertFalse(unknownHourly.unknownMetric)

        // Any other refusal fails the push as before, without asking again.
        for refusal in [badDate, unknownHourly, IngestClient.Rejected(status: 401, detail: "Unauthorized")] {
            var state = SyncState()
            state.noteAccepted(serverMetrics)
            let server = FakeServer(metrics: Set(serverMetrics), lists: true)
            server.refuse = refusal
            do {
                try await state.push(todayPayload) { try server.send($0) }
                XCTFail(refusal.detail)
            } catch {
                XCTAssertEqual(error.localizedDescription, refusal.localizedDescription)
            }
            XCTAssertEqual(server.sent.count, 1, refusal.detail)
            XCTAssertEqual(state.acceptedMetrics, serverMetrics)
        }

        // A server whose list says it takes the refused metric: the same rows aren't sent again.
        var state = SyncState()
        state.noteAccepted(serverMetrics)
        let confused = FakeServer(metrics: Set(serverMetrics), lists: true)
        confused.takes = SyncState.legacyMetrics
        do {
            try await state.push(todayPayload) { try confused.send($0) }
            XCTFail("sent")
        } catch {
            XCTAssertEqual(error.localizedDescription, #"Server answered 400: daily[1].metric: unknown metric "stand_hours""#)
        }
        XCTAssertEqual(confused.sent, [["steps", "stand_hours", "flights"], []])
        XCTAssertEqual(state.acceptedMetrics, serverMetrics)

        // Still refused after the retry: one retry only, and what the probe taught is kept for the next sync.
        var stuck = SyncState()
        stuck.noteAccepted(serverMetrics)
        let older = FakeServer(metrics: SyncState.legacyMetrics.subtracting(["steps"]), lists: false)
        do {
            try await stuck.push(todayPayload) { try older.send($0) }
            XCTFail("sent")
        } catch {
            XCTAssertTrue((error as? IngestClient.Rejected)?.unknownMetric == true)
        }
        XCTAssertEqual(older.sent, [["steps", "stand_hours", "flights"], [], ["steps"]])
        XCTAssertNil(stuck.acceptedMetrics)
    }

    func testEveryMetricTheServerTakesComesFromAType() {
        for name in serverMetrics {
            if name == "breathing_disturbances", #unavailable(iOS 18.0) { continue }
            XCTAssertNotNil(HealthTypes.type(producing: name), name)
        }
        XCTAssertEqual(HealthTypes.type(producing: "hr_max"), HKQuantityType(.heartRate))
        XCTAssertEqual(HealthTypes.type(producing: "sleep_rem"), HealthTypes.sleep)
        XCTAssertEqual(HealthTypes.type(producing: "stand_hours"), HealthTypes.standHour)
        XCTAssertEqual(HealthTypes.type(producing: "caffeine_mg"), HKQuantityType(.dietaryCaffeine))
        XCTAssertNil(HealthTypes.type(producing: "strain"))
    }

    func testNewlyAcceptedMetricsClearTheirTypesAnchorsOnce() {
        // This build synced with an older server first: every type has an anchor, but the new metrics' rows were left out.
        var state = SyncState(server: "https://health.mcfly.bot")
        // Without food types, whatever Nutrition setting this simulator's app last synced with.
        for type in HealthTypes.sampleTypes(food: []) { state.anchors[type.identifier] = Data([1]) }
        let all = Set(state.anchors.keys)

        XCTAssertEqual(state.noteAccepted(nil), [], "an older server: nothing to resend")
        XCTAssertEqual(Set(state.anchors.keys), all)

        // The server now lists the new metrics: exactly their types read history again.
        let newTypes = Set(newMetrics.compactMap { HealthTypes.type(producing: $0)?.identifier })
        XCTAssertEqual(newTypes.count, HealthTypes.quantities.filter { newMetrics.contains($0.metric) }.count + 1) // + stand hour
        XCTAssertEqual(state.noteAccepted(serverMetrics), newTypes)
        XCTAssertEqual(Set(state.anchors.keys), all.subtracting(newTypes))
        let untouched: [HKSampleType] = [HKQuantityType(.stepCount), HKQuantityType(.heartRate), HealthTypes.sleep, HealthTypes.workout]
        for kept in untouched {
            XCTAssertNotNil(state.anchors[kept.identifier], kept.identifier)
        }
        XCTAssertEqual(state.acceptedMetrics, serverMetrics)

        // The sync that follows reads them again and saves new anchors; the same reply never clears them twice.
        for id in newTypes { state.anchors[id] = Data([2]) }
        XCTAssertEqual(state.noteAccepted(serverMetrics), [])
        XCTAssertEqual(state.noteAccepted(Array(serverMetrics.reversed())), [])
        XCTAssertEqual(Set(state.anchors.keys), all)

        // A metric added later clears only its own type.
        var later = SyncState()
        later.acceptedMetrics = SyncState.legacyMetrics.union(["glucose"]).sorted()
        later.anchors = [HKQuantityType(.bloodGlucose).identifier: Data([1]), HKQuantityType(.dietaryWater).identifier: Data([1])]
        XCTAssertEqual(later.noteAccepted(later.acceptedMetrics! + ["water_ml"]), [HKQuantityType(.dietaryWater).identifier])
        XCTAssertEqual(Array(later.anchors.keys), [HKQuantityType(.bloodGlucose).identifier])
    }
}

// MARK: - Timeline scrubbing and vital levels

/// Scrubbing Today's path (TimelineScrub.swift) mirrors src/charts/scrub.ts; these port test/scrub.test.ts case by
/// case. The vital levels mirror levelOf and statusText in src/components/Figure.tsx.
final class TimelineScrubTests: XCTestCase {
    private typealias S = TimelineScrub
    private let today = "2026-10-19"
    private let past = "2026-10-18"

    private func hours(_ values: [Int: Double]) -> [Double?] { (0..<24).map { values[$0] } }

    /// Steps 1000 at 7, 500 at 8 and 200 at 14; heart rate at 3, 7 and 14 (none at 8); typical totals rising 100 an hour.
    private func dayOf(_ date: String, asOf: Int?) -> DayData {
        DayData(date: date, today: today, asOf: asOf, metrics: [
            "steps": DaySeries(hours: hours([7: 1000, 8: 500, 14: 200]), typical: (0..<24).map { Double(($0 + 1) * 100) as Double? }),
            "active_energy": DaySeries(hours: hours([:]), typical: hours([:])),
            "heart_rate": DaySeries(hours: hours([3: 52, 7: 131.4, 14: 74]), typical: hours([7: 80]),
                                    min: hours([3: 48, 7: 96, 14: 66]), max: hours([3: 57, 7: 162, 14: 90])),
        ])
    }

    private var run: TimelineEvent {
        TimelineEvent(id: "w", kind: "workout", title: "Running", start: "\(today)T07:05:00-05:00", end: "\(today)T07:08:00-05:00", detail: nil)
    }

    private var sleep: TimelineEvent {
        TimelineEvent(id: "s", kind: "sleep", title: "Sleep", start: "\(past)T23:10:00-05:00", end: "\(today)T06:40:00-05:00", detail: nil)
    }

    private func at(_ minute: Int, _ day: DayData?, events: [TimelineEvent] = [], date: String? = nil, live: Bool = false) -> S.Moment {
        S.moment(day: day, events: events, date: date ?? today, minute: minute, live: live)
    }

    func testClockLabelsRunFrom0000To2400() {
        XCTAssertEqual([S.clock(0), S.clock(425), S.clock(1440)], ["00:00", "07:05", "24:00"])
        XCTAssertEqual(S.hourRange(7), "07:00–08:00")
    }

    func testMarkerReachesNowOnTodayAndTheWholeDayOtherwise() {
        XCTAssertEqual(S.scrubMax(isToday: true, nowMinute: 872, asOf: 14), 872)
        // The phone's clock reads 13:10 but hour 14 has synced in the person's own time zone.
        XCTAssertEqual(S.scrubMax(isToday: true, nowMinute: 790, asOf: 14), 840)
        XCTAssertEqual(S.scrubMax(isToday: true, nowMinute: 30, asOf: nil), 30)
        XCTAssertEqual(S.scrubMax(isToday: false, nowMinute: 872, asOf: 14), 1440)
    }

    func testStepsLandOnTheGridAndStayInsideTheRange() {
        XCTAssertEqual(S.stepMinute(872, step: 15, forward: false, upper: 900), 870)
        XCTAssertEqual(S.stepMinute(870, step: 15, forward: false, upper: 900), 855)
        XCTAssertEqual(S.stepMinute(872, step: 15, forward: true, upper: 900), 885)
        XCTAssertEqual(S.stepMinute(895, step: 15, forward: true, upper: 900), 900)
        XCTAssertEqual(S.stepMinute(5, step: 60, forward: false, upper: 900), 0)
        // VoiceOver's hour steps: from 14:32 back to 14:00, then 13:00; forward past now stops at now (live).
        XCTAssertEqual(S.stepMinute(872, step: 60, forward: false, upper: 872), 840)
        XCTAssertEqual(S.stepMinute(840, step: 60, forward: false, upper: 872), 780)
        XCTAssertEqual(S.stepMinute(840, step: 60, forward: true, upper: 872), 872)
    }

    func testEventsAreMatchedByTheirRealTimesNotAsDrawn() {
        XCTAssertEqual(S.events(at: 426, in: [run, sleep], date: today).map(\.id), ["w"])
        XCTAssertEqual(S.events(at: 430, in: [run, sleep], date: today).map(\.id), [])
        // A night that began the evening before covers the small hours; it has ended by 06:40.
        XCTAssertEqual(S.events(at: 120, in: [run, sleep], date: today).map(\.id), ["s"])
        XCTAssertEqual(S.events(at: 400, in: [run, sleep], date: today).map(\.id), [])
        // 24:00 looks at the day's last minute.
        XCTAssertEqual(S.events(at: 1440, in: [sleep], date: past).map(\.id), ["s"])
    }

    func testAPressOnAShortSessionLandsInsideItElsewhereItSnapsTo5Minutes() {
        // The run lasted 07:05–07:08 but is drawn 07:05–07:17.
        XCTAssertEqual(S.span(run, date: today), S.Span(from: 425, to: 428, drawnTo: 437))
        XCTAssertEqual(S.pressMinute([run, sleep], date: today, raw: 426.6, snap: 5), 426, "inside: the exact minute")
        XCTAssertEqual(S.pressMinute([run, sleep], date: today, raw: 433.2, snap: 5), 427, "on the drawn tail: its last real minute")
        XCTAssertEqual(S.events(at: S.pressMinute([run], date: today, raw: 433.2, snap: 5), in: [run], date: today).count, 1)
        XCTAssertEqual(S.pressMinute([run, sleep], date: today, raw: 452.4, snap: 5), 450)
        // The night from the evening before is drawn from 00:00.
        XCTAssertEqual(S.span(sleep, date: today), S.Span(from: 0, to: 400, drawnTo: 400))
    }

    func testHeartRateIsTheHoursOwnAverageAndRange() {
        let day = dayOf(today, asOf: 14)
        XCTAssertEqual(at(7 * 60 + 20, day).heart, .reading(hour: 7, avg: 131.4, low: 96, high: 162, typical: 80, partial: false))
        XCTAssertEqual(at(8 * 60 + 5, day).heart, .missing(hour: 8))
        // Today's last synced hour may still be filling up.
        guard case let .reading(_, _, _, _, _, partial)? = at(14 * 60 + 40, day).heart else { return XCTFail("a reading") }
        XCTAssertTrue(partial)
    }

    func testTodaysHoursAfterTheLastSyncArePendingNotEmpty() {
        let m = at(15 * 60 + 10, dayOf(today, asOf: 14))
        XCTAssertEqual(m.heart, .pending(hour: 15))
        // The totals after the last sync are today's so far, with no typical to compare a part hour with.
        XCTAssertEqual(m.steps, .soFar(1700))
    }

    func testStepsAndEnergyCountWholeHoursAgainstTheTypicalTotalByThen() {
        let day = dayOf(today, asOf: 14)
        // At 08:40 the total is by 08:00: the 1000 of 07:00–08:00, not the 500 still to come in 08:00–09:00.
        XCTAssertEqual(at(8 * 60 + 40, day).steps, .by(at: 8, value: 1000, typical: 800))
        XCTAssertEqual(at(20, day).steps, .by(at: 0, value: 0, typical: nil))
        // A metric with no hours that day says so rather than counting zeros.
        XCTAssertEqual(at(8 * 60 + 40, day).energy, .empty)
        XCTAssertEqual(at(13 * 60 + 59, day).steps, .by(at: 13, value: 1500, typical: 1300))
        // Inside today's last synced hour the total stays at the whole hours; past every synced reading it's so far.
        XCTAssertEqual(at(14 * 60 + 50, day).steps, .by(at: 14, value: 1500, typical: 1400))
        XCTAssertEqual(at(15 * 60, day).steps, .soFar(1700))
    }

    func testLiveTodayIsTheLatestHeartRateAndTheTotalsSoFar() {
        let m = at(16 * 60 + 2, dayOf(today, asOf: 14), events: [run], live: true)
        XCTAssertEqual(m.heart, .reading(hour: 14, avg: 74, low: 66, high: 90, typical: nil, partial: true))
        XCTAssertEqual(m.steps, .soFar(1700))
        XCTAssertEqual(m.events.map(\.id), [])
    }

    func testAPastDayRunsTo2400WhereTheTotalsAreTheWholeDay() {
        let day = dayOf(past, asOf: 14)
        let m = at(1440, day, date: past, live: true)
        XCTAssertEqual(m.heart, .reading(hour: 14, avg: 74, low: 66, high: 90, typical: nil, partial: false))
        XCTAssertEqual(m.steps, .by(at: 24, value: 1700, typical: 2400))
        // Late hours of a past day without readings are "missing", never "pending".
        XCTAssertEqual(at(22 * 60, day, date: past).heart, .missing(hour: 22))
    }

    func testNoHourlyDataAnotherDaysDataOrNothingSyncedYetShowOnlyWhatIsKnown() {
        let none = at(426, nil, events: [run])
        XCTAssertEqual(none.events.map(\.id), ["w"])
        XCTAssertNil(none.heart)
        XCTAssertNil(none.steps)
        XCTAssertFalse(none.hasFigures)
        let empty = at(600, DayData(date: today, today: today, asOf: nil, metrics: [:]))
        XCTAssertFalse(empty.hasFigures)
        XCTAssertEqual(empty.events.map(\.id), [])
        XCTAssertFalse(at(600, dayOf(past, asOf: 14)).hasFigures, "another day's readings never show on this one")
        let unsynced = at(30, dayOf(today, asOf: nil), live: true)
        XCTAssertEqual(unsynced.heart, .empty)
        XCTAssertEqual(unsynced.steps, .empty)
    }

    func testTheSpokenValueHasEveryFigureTheReadoutShows() {
        let day = dayOf(today, asOf: 14)
        XCTAssertEqual(S.spoken(at(7 * 60 + 6, day, events: [run]), time: "07:06"),
                       "07:06; Running; heart 131 bpm, average from 07:00 to 08:00, range 96 to 162; steps 0 by 07:00, typical 700")
        XCTAssertEqual(S.spoken(at(16 * 60, day, events: [sleep], live: true), time: "Now"),
                       "Now; nothing logged; heart 74 bpm, average since 14:00, range 66 to 90; steps \(Fmt.number(1700)) so far today")
        XCTAssertEqual(S.spoken(at(8 * 60 + 40, day), time: "08:40"),
                       "08:40; nothing logged; no heart reading from 08:00 to 09:00; steps \(Fmt.number(1000)) by 08:00, typical 800")
        XCTAssertEqual(S.spoken(at(120, nil, events: [sleep]), time: "02:00"), "02:00; Asleep")
        XCTAssertEqual(S.spoken(at(15 * 60 + 10, day), time: "15:10"),
                       "15:10; nothing logged; heart rate not synced yet; steps \(Fmt.number(1700)) so far today")
    }

    func testFigureLinesSayWhichHourTheyCover() {
        XCTAssertEqual(S.heartStatus(.reading(hour: 7, avg: 1, low: nil, high: nil, typical: nil, partial: false), isToday: true), "avg 07:00–08:00")
        XCTAssertEqual(S.heartStatus(.reading(hour: 14, avg: 1, low: nil, high: nil, typical: nil, partial: true), isToday: true), "avg since 14:00")
        XCTAssertEqual(S.heartStatus(.missing(hour: 8), isToday: true), "none 08:00–09:00")
        XCTAssertEqual(S.heartStatus(.pending(hour: 15), isToday: true), "not synced yet")
        XCTAssertEqual(S.heartStatus(.empty, isToday: true), "none yet today")
        XCTAssertEqual(S.heartStatus(.empty, isToday: false), "none that day")
        XCTAssertEqual(S.totalLines(.by(at: 8, value: 1, typical: 800), isToday: true), ["by 08:00", "typical 800"])
        XCTAssertEqual(S.totalLines(.by(at: 24, value: 1, typical: nil), isToday: false), ["whole day"])
        XCTAssertEqual(S.totalLines(.soFar(5), isToday: true), ["so far today"])
        XCTAssertEqual(S.totalLines(.empty, isToday: false), ["none that day"])
        XCTAssertEqual(S.doing(sleep), "Asleep")
        XCTAssertEqual(S.doing(run), "Running")
    }

    func testTheStepNoteShowsOnlyWhenTheHoursFallShortOfTheDaysCount() {
        func day(_ total: DaySeries.Total?) -> DayData {
            DayData(date: today, today: today, asOf: 14, metrics: ["steps": DaySeries(hours: hours([7: 1000, 8: 500]), typical: [], total: total)])
        }
        XCTAssertEqual(S.stepNote(day(.init(value: 9000, source: "whoop"))),
                       "Steps by the hour are from your iPhone or Apple Watch. WHOOP counted \(Fmt.number(9000)) for the day.")
        XCTAssertEqual(S.stepNote(day(.init(value: 2000, source: "apple"))),
                       "The hours here add up to \(Fmt.number(1500)) steps; the day's count is \(Fmt.number(2000)).")
        XCTAssertNil(S.stepNote(day(.init(value: 1510, source: "apple"))), "within rounding")
        XCTAssertNil(S.stepNote(day(nil)))
        XCTAssertNil(S.stepNote(nil))
    }

    func testNowIsThePhonesMinuteUntilTheDayIsOver() {
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 14, minute: 32))!
        XCTAssertEqual(S.nowMinute(date, day: "2026-10-19"), 14 * 60 + 32)
        XCTAssertEqual(S.nowMinute(date, day: "2026-10-18"), 1440, "past midnight, the shown day is over")
    }

    // MARK: Vital levels

    private func vital(_ status: String?, _ level: String?, date: String = "2026-10-19", reading: Bool = true) -> Vital {
        Vital(label: "Resting HR", latest: reading ? Latest(date: date, value: 62, source: "apple") : nil, status: status, level: level)
    }

    func testEachDotIsColouredByHowFarTheReadingIsFromUsual() {
        XCTAssertEqual(VitalLevel.of(vital("normal", "normal"), asOf: today), .normal)
        XCTAssertEqual(VitalLevel.of(vital("high", "unusual"), asOf: today), .unusual)
        XCTAssertEqual(VitalLevel.of(vital("low", "off"), asOf: today), .off)
        // Servers before levels: the status alone says normal or not.
        XCTAssertEqual(VitalLevel.of(vital("normal", nil), asOf: today), .normal)
        XCTAssertEqual(VitalLevel.of(vital("high", nil), asOf: today), .unusual)
        // Neutral: an older reading, no baseline, no reading, nothing at all, or a value this app doesn't know.
        XCTAssertEqual(VitalLevel.of(vital("high", "off", date: past), asOf: today), .neutral)
        XCTAssertEqual(VitalLevel.of(vital(nil, nil), asOf: today), .neutral)
        XCTAssertEqual(VitalLevel.of(vital(nil, nil, reading: false), asOf: today), .neutral)
        XCTAssertEqual(VitalLevel.of(nil, asOf: today), .neutral)
        XCTAssertEqual(VitalLevel.of(vital("high", "extreme"), asOf: today), .neutral)
        XCTAssertEqual(VitalLevel.of(vital("elevated", "unusual"), asOf: today), .neutral)
    }

    func testTheWordsGoWithTheColourAndTheDirectionComesFromTheStatus() {
        XCTAssertEqual(VitalLevel.statusText(vital("normal", "normal")), "Normal")
        XCTAssertEqual(VitalLevel.statusText(vital("high", "unusual")), "Above usual")
        XCTAssertEqual(VitalLevel.statusText(vital("low", "unusual")), "Below usual")
        XCTAssertEqual(VitalLevel.statusText(vital("high", "off")), "Well above usual")
        XCTAssertEqual(VitalLevel.statusText(vital("low", "off")), "Well below usual")
        XCTAssertEqual(VitalLevel.statusText(vital("high", nil)), "Above usual")
        XCTAssertEqual(VitalLevel.statusText(vital(nil, nil)), "Building baseline")
        XCTAssertEqual(VitalLevel.statusText(vital(nil, nil, reading: false)), "No data")
        XCTAssertEqual(VitalLevel.statusText(nil), "No data")
        XCTAssertNil(VitalLevel.statusText(vital("elevated", nil)))
        // An older reading says when it's from.
        XCTAssertEqual(VitalLevel.statusLine(vital("normal", "normal", date: "2026-10-17"), asOf: today), "Normal · \(Fmt.day("2026-10-17"))")
        XCTAssertEqual(VitalLevel.statusLine(vital("high", "off"), asOf: today), "Well above usual")
    }

    func testLevelDecodesAndIsOptional() throws {
        let decode = { (json: String) in try JSONDecoder().decode(Vital.self, from: Data(json.utf8)) }
        let latest = #""latest":{"date":"2026-10-19","value":62,"source":"apple"}"#
        XCTAssertEqual(try decode(#"{"label":"Resting HR",\#(latest),"status":"high","level":"off"}"#).level, "off")
        XCTAssertNil(try decode(#"{"label":"Resting HR",\#(latest),"status":"normal"}"#).level)
        XCTAssertNil(try decode(#"{"label":"Resting HR","latest":null,"status":null,"level":null}"#).level)
    }
}

// MARK: - Scrub-vitals review fixes

/// The review fixes for scrubbing Today's path: the portrait's readings laid out by their measured heights, the
/// portrait's heart following the marker, a failed GET /api/day never read as "no readings", and no marker
/// animation under Reduce Motion. (VoiceOver's activation isn't covered here: SwiftUI builds no accessibility tree
/// in a unit test unless accessibility is running.)
final class ScrubVitalsFixTests: XCTestCase {
    private typealias S = TimelineScrub
    private let today = "2026-10-19"
    private let past = "2026-10-18"

    // MARK: Portrait layout

    /// A 375pt phone's content width, with the silhouette (no photo).
    private let layout = PortraitLayout(width: 343, figureHeight: 340, aspect: 0.62)
    private let dots = PortraitLayout.silhouetteDots

    private func heights(_ h: CGFloat) -> [VitalKey: CGFloat] { [.temp: h, .breathing: h, .heart: h] }

    /// Every pair of readings on one side is at least `gap` apart, top to bottom.
    private func assertSpaced(_ placed: [VitalKey: PortraitLayout.Placed], file: StaticString = #filePath, line: UInt = #line) {
        for left in [true, false] {
            let side = placed.values.filter { $0.left == left }.map(\.frame).sorted { $0.minY < $1.minY }
            for (a, b) in zip(side, side.dropFirst()) {
                XCTAssertGreaterThanOrEqual(b.minY - a.maxY, PortraitLayout.gap - 0.001, "readings \(a) and \(b) overlap", file: file, line: line)
            }
            for f in side { XCTAssertGreaterThanOrEqual(f.minY, 0, file: file, line: line) }
        }
    }

    /// No reading or shape touches another, and the area is tall enough for all of them.
    private func assertClear(_ plan: PortraitLayout.Plan, file: StaticString = #filePath, line: UInt = #line) {
        let boxes = plan.labels.values.map(\.frame) + plan.shapes.values.map { $0 }
        for (i, a) in boxes.enumerated() {
            XCTAssertLessThanOrEqual(a.maxY, plan.height, "\(a) is below the portrait's area", file: file, line: line)
            for b in boxes[(i + 1)...] {
                XCTAssertFalse(a.intersects(b), "\(a) and \(b) overlap", file: file, line: line)
            }
        }
    }

    func testWrappedReadingsOnTheSilhouetteSitBelowEachOtherNotAFixedDistanceApart() {
        // On the silhouette every dot is right of the face's centre, so all three readings share the right side, and
        // breathing (y≈147) and heart (y≈194) are under 50pt apart. Labels with wrapped status words are about 60pt
        // tall at the default size, 72pt at xLarge and 80pt at xxLarge: the old fixed 58pt between centres overlapped.
        for h: CGFloat in [47, 60, 72, 80] {
            let placed = layout.labels(for: dots, faceCenterX: 0.5, heights: heights(h))
            XCTAssertEqual(placed.count, 3)
            XCTAssertTrue(placed.values.allSatisfy { !$0.left })
            assertSpaced(placed)
        }
        // Mixed: one wrapped status between two single-line ones.
        assertSpaced(layout.labels(for: dots, faceCenterX: 0.5, heights: [.temp: 47, .breathing: 60, .heart: 47]))
        // Before they're measured, the estimate keeps them apart too.
        assertSpaced(layout.labels(for: dots, faceCenterX: 0.5, heights: [:]))
    }

    func testAReadingIsCentredOnItsDotWhenThereIsRoomAndNeverStartsAboveTheTop() {
        let placed = layout.labels(for: dots, faceCenterX: 0.5, heights: heights(47))
        let temp = placed[.temp]!, breathing = placed[.breathing]!
        XCTAssertEqual(temp.frame.midY, temp.dot.y, accuracy: 0.001)
        XCTAssertEqual(breathing.frame.midY, breathing.dot.y, accuracy: 0.001)
        XCTAssertEqual(breathing.anchor.y, breathing.frame.midY, accuracy: 0.001, "the leader line meets the reading's middle")
        // A tall reading by a dot near the top is moved down rather than cut off above the portrait.
        let tall = layout.labels(for: dots, faceCenterX: 0.5, heights: heights(110))
        XCTAssertEqual(tall[.temp]!.frame.minY, 0, accuracy: 0.001)
        assertSpaced(tall)
    }

    func testPhotoDotsOnBothSidesAreSpacedPerSide() {
        let photoDots: [VitalKey: CGPoint] = [.temp: CGPoint(x: 0.4, y: 0.12), .breathing: CGPoint(x: 0.45, y: 0.2), .heart: CGPoint(x: 0.62, y: 0.5)]
        let placed = layout.labels(for: photoDots, faceCenterX: 0.5, heights: heights(80))
        XCTAssertTrue(placed[.temp]!.left)
        XCTAssertTrue(placed[.breathing]!.left)
        XCTAssertFalse(placed[.heart]!.left)
        assertSpaced(placed)
    }

    func testAtTheDefaultSizeTheShapesStayWhereTheyWere() {
        let plan = layout.plan(dots: dots, faceCenterX: 0.5, labelHeights: heights(47), shapeHeights: [:])
        let f = layout.figure
        XCTAssertEqual(plan.shapes[.slept]!.midY, f.minY + f.height * 0.74, accuracy: 0.001)
        XCTAssertEqual(plan.shapes[.steps]!.midY, f.minY + f.height * 0.86, accuracy: 0.001)
        XCTAssertEqual(plan.shapes[.hrv]!.midY, f.maxY + 34, accuracy: 0.001)
        XCTAssertEqual(plan.height, f.maxY + 72, accuracy: 0.001)
        assertClear(plan)
    }

    func testLargeTextPushesTheShapesBelowTheReadingsAndTheAreaGrowsToHoldThem() {
        // xxLarge: wrapped readings about 80pt tall and taller shapes. The heart reading reaches the Steps shape's place.
        let big = layout.plan(dots: dots, faceCenterX: 0.5, labelHeights: heights(80), shapeHeights: [.slept: 74, .steps: 82, .hrv: 74])
        assertClear(big)
        XCTAssertGreaterThan(big.shapes[.steps]!.minY, big.labels[.heart]!.frame.maxY)
        // A photo with the heart low on the right, right where the Steps shape sits.
        let low: [VitalKey: CGPoint] = [.temp: CGPoint(x: 0.55, y: 0.1), .breathing: CGPoint(x: 0.4, y: 0.45), .heart: CGPoint(x: 0.7, y: 0.84)]
        let photo = PortraitLayout(width: 343, figureHeight: 340, aspect: 0.7)
        for h: CGFloat in [47, 60, 80] {
            assertClear(photo.plan(dots: low, faceCenterX: 0.5, labelHeights: heights(h), shapeHeights: [:]))
        }
    }

    // MARK: The portrait's heart while scrubbing

    private func hours(_ values: [Int: Double]) -> [Double?] { (0..<24).map { values[$0] } }

    /// Heart rate at 3, 7 and 14 (none at 8), synced through 14:00.
    private func dayOf(_ date: String, asOf: Int?) -> DayData {
        DayData(date: date, today: today, asOf: asOf, metrics: [
            "steps": DaySeries(hours: hours([7: 1000]), typical: hours([:])),
            "heart_rate": DaySeries(hours: hours([3: 52, 7: 131.4, 14: 74]), typical: hours([:]),
                                    min: hours([7: 96]), max: hours([7: 162])),
        ])
    }

    private func scrubbed(_ minute: Int, _ day: DayData?, date: String? = nil, live: Bool = false) -> HeartScrub? {
        let date = date ?? today
        return HeartScrub.from(S.moment(day: day, events: [], date: date, minute: minute, live: live), live: live, date: date)
    }

    func testTheHeartFollowsTheMarkerWithTheWebsWords() {
        let day = dayOf(today, asOf: 14)
        XCTAssertEqual(scrubbed(7 * 60 + 20, day),
                       HeartScrub(date: today, bpm: 131.4, label: "Avg 07:00–08:00", spoken: "average from 07:00 to 08:00"))
        XCTAssertEqual(scrubbed(14 * 60 + 40, day),
                       HeartScrub(date: today, bpm: 74, label: "Avg since 14:00", spoken: "average since 14:00"))
        XCTAssertEqual(scrubbed(8 * 60 + 5, day)?.label, "No reading then")
        XCTAssertNil(scrubbed(8 * 60 + 5, day)?.bpm)
        XCTAssertEqual(scrubbed(15 * 60 + 10, day)?.label, "Not synced yet")
        XCTAssertEqual(scrubbed(30, dayOf(today, asOf: nil))?.label, "No readings")
        XCTAssertEqual(scrubbed(22 * 60, dayOf(past, asOf: 14), date: past)?.date, past, "tagged with its day, for the portrait's same-day check")
    }

    func testLiveOrWithoutHourlyHeartRateThePortraitKeepsTheRestingRate() {
        XCTAssertNil(scrubbed(16 * 60, dayOf(today, asOf: 14), live: true))
        XCTAssertNil(scrubbed(7 * 60, nil))
        XCTAssertNil(scrubbed(7 * 60, DayData(date: today, today: today, asOf: 14, metrics: ["steps": DaySeries(hours: hours([7: 1]), typical: hours([:]))])))
    }

    func testTheScrubbedHeartCalloutSaysTheHourWithNoLevel() {
        let resting = Vital(label: "Resting HR", latest: Latest(date: today, value: 62, source: "apple"), status: "normal", level: "normal")
        let plain = OrganicPortrait.heartReading(resting, asOf: today, scrub: nil)
        XCTAssertEqual(plain.level, .normal)
        XCTAssertEqual(plain.value, "62 bpm")
        XCTAssertEqual(plain.status, "Normal")
        XCTAssertEqual(plain.a11y, "Resting heart rate 62 bpm, Normal")
        XCTAssertFalse(plain.scrubbed)

        let hour = OrganicPortrait.heartReading(resting, asOf: today, scrub: scrubbed(7 * 60 + 20, dayOf(today, asOf: 14)))
        XCTAssertEqual(hour.level, .neutral, "levels are for resting rates")
        XCTAssertEqual(hour.value, "131 bpm")
        XCTAssertEqual(hour.status, "Avg 07:00–08:00")
        XCTAssertEqual(hour.a11y, "Heart rate 131 bpm, average from 07:00 to 08:00")
        XCTAssertTrue(hour.scrubbed)

        let none = OrganicPortrait.heartReading(resting, asOf: today, scrub: scrubbed(8 * 60 + 5, dayOf(today, asOf: 14)))
        XCTAssertNil(none.value)
        XCTAssertEqual(none.level, .neutral)
        XCTAssertEqual(none.a11y, "Heart rate, no reading then")

        let partial = OrganicPortrait.heartReading(resting, asOf: today, scrub: scrubbed(14 * 60 + 40, dayOf(today, asOf: 14)))
        XCTAssertEqual(partial.a11y, "Heart rate 74 bpm, average since 14:00")
    }

    // MARK: Sharing the marker through Today

    @MainActor func testThePortraitFollowsTheMarkerAndGoesBackToTheRestingRateAtNow() {
        let scrub = TodayScrub()
        let day = dayOf(today, asOf: 14)
        XCTAssertNil(scrub.minute(on: today), "starts live")
        XCTAssertNil(scrub.heart(on: today))

        // A tap holds 07:20, and the path says what the heart reads there.
        scrub.move(to: 7 * 60 + 20, on: today)
        XCTAssertEqual(scrub.minute(on: today), 440)
        scrub.follow(scrubbed(440, day))
        XCTAssertEqual(scrub.heart(on: today)?.bpm, 131.4)
        XCTAssertEqual(scrub.heart(on: today)?.label, "Avg 07:00–08:00")

        // "Now": live again, and the portrait shows the resting rate.
        scrub.move(to: nil, on: today)
        XCTAssertNil(scrub.minute(on: today))
        scrub.follow(scrubbed(16 * 60, day, live: true))
        XCTAssertNil(scrub.heart(on: today))
    }

    @MainActor func testAHeartFromAnotherDayNeverShowsOnThePortrait() {
        // The path fell back to yesterday (nothing on today yet), so today's portrait keeps its resting rate.
        let scrub = TodayScrub()
        scrub.move(to: 440, on: past)
        scrub.follow(scrubbed(440, dayOf(past, asOf: 14), date: past))
        XCTAssertEqual(scrub.heart(on: past)?.label, "Avg 07:00–08:00")
        XCTAssertNil(scrub.heart(on: today))
    }

    @MainActor func testANewDayStartsLiveAndComingBackDoesNotBringTheOldMomentBack() {
        let scrub = TodayScrub()
        scrub.move(to: 440, on: today)
        scrub.follow(scrubbed(440, dayOf(today, asOf: 14)))
        // The previous day is live at once, before the path has redrawn, and the heart is the resting rate.
        XCTAssertNil(scrub.minute(on: past), "a marker held on another day never applies")
        scrub.show(past)
        XCTAssertNil(scrub.heart(on: today))
        XCTAssertNil(scrub.heart(on: past))
        // Back on today it's live again (the web keys its timeline card by day).
        scrub.show(today)
        XCTAssertNil(scrub.minute(on: today))
    }

    @MainActor func testShowingTheSameDayAgainKeepsTheHeldMoment() {
        // A refresh redraws the same day's path; the moment stays held.
        let scrub = TodayScrub()
        scrub.move(to: 440, on: today)
        scrub.follow(scrubbed(440, dayOf(today, asOf: 14)))
        scrub.show(today)
        XCTAssertEqual(scrub.minute(on: today), 440)
        XCTAssertEqual(scrub.heart(on: today)?.bpm, 131.4)
    }

    @MainActor func testThePathLeavingTheScreenRestsTheHeartButKeepsTheMarker() {
        // A hidden card, another tab or a pushed page: the resting rate. Back on Today, the held hour again.
        let scrub = TodayScrub()
        let day = dayOf(today, asOf: 14)
        scrub.move(to: 440, on: today)
        scrub.follow(scrubbed(440, day))
        scrub.hide()
        XCTAssertNil(scrub.heart(on: today))
        XCTAssertEqual(scrub.minute(on: today), 440)
        scrub.follow(scrubbed(440, day))
        XCTAssertEqual(scrub.heart(on: today)?.label, "Avg 07:00–08:00")
    }

    @MainActor func testTheHeartBeatsAtTheScrubbedHoursRateAndStaysStillUnderReduceMotion() {
        let resting = Vital(label: "Resting HR", latest: Latest(date: today, value: 62, source: "apple"), status: "normal", level: "normal")
        let day = dayOf(today, asOf: 14)
        XCTAssertEqual(OrganicPortrait.beatRate(resting: resting, scrub: nil), 62)
        XCTAssertEqual(OrganicPortrait.beatRate(resting: nil, scrub: nil), 60)
        XCTAssertEqual(OrganicPortrait.beatRate(resting: resting, scrub: scrubbed(440, day)), 131.4)
        XCTAssertNil(OrganicPortrait.beatRate(resting: resting, scrub: scrubbed(8 * 60 + 5, day)), "an hour with no reading has nothing to beat at")

        // A beat peaks 9% into its period: every 60/131.4 s at the scrubbed hour, not every 60/62 s.
        func peak(_ bpm: Double) -> Double { 60 / bpm * 0.09 }
        XCTAssertEqual(OrganicPortrait.pulse(.heart, t: peak(131.4), bpm: 131.4, rpm: 15, reduceMotion: false), 1, accuracy: 1e-9)
        XCTAssertEqual(OrganicPortrait.pulse(.heart, t: peak(62), bpm: 131.4, rpm: 15, reduceMotion: false), 0)
        XCTAssertEqual(OrganicPortrait.pulse(.heart, t: peak(131.4), bpm: nil, rpm: 15, reduceMotion: false), 0)
        for key in VitalKey.allCases {
            XCTAssertEqual(OrganicPortrait.pulse(key, t: peak(131.4), bpm: 131.4, rpm: 15, reduceMotion: true), 0, "\(key)")
        }
    }

    // MARK: Loading the day's hours

    private func note(_ load: DayLoad, _ date: String, showsSteps: Bool = false) -> String? {
        S.note(day: load.hours(for: date), answered: load.answered(date), failed: load.failed(date), showsSteps: showsSteps, isToday: date == today)
    }

    func testAFailedRequestNeverSaysThereAreNoHourlyReadings() {
        var load = DayLoad()
        XCTAssertNil(note(load, today), "nothing while asking")
        load.failed(for: today)
        XCTAssertEqual(note(load, today), S.loadFailedNote)
        XCTAssertNotEqual(note(load, today), S.noHoursNote(isToday: true))
        // The retry succeeds.
        load.received(dayOf(today, asOf: 14), for: today)
        XCTAssertFalse(load.failed(today))
        XCTAssertNil(note(load, today))
    }

    func testAFailedRefreshKeepsTheFiguresAlreadyOnScreen() {
        var load = DayLoad()
        load.received(dayOf(today, asOf: 14), for: today)
        // New data on the server: the refetch times out.
        load.failed(for: today)
        XCTAssertEqual(load.hours(for: today)?.asOf, 14, "the heart, steps and energy stay")
        XCTAssertTrue(S.moment(day: load.hours(for: today), events: [], date: today, minute: 900, live: true).hasFigures)
        XCTAssertNil(note(load, today))
    }

    func testANewDayIsNotCalledEmptyBeforeItHasBeenAsked() {
        var load = DayLoad()
        load.received(DayData(date: past, today: today, asOf: nil, metrics: [:]), for: past)
        XCTAssertEqual(note(load, past), S.noHoursNote(isToday: false))
        // The first frame after moving to today: yesterday's answer says nothing about it.
        XCTAssertNil(load.hours(for: today))
        XCTAssertFalse(load.answered(today))
        XCTAssertNil(note(load, today))
        // A failure for one day isn't another day's.
        load.failed(for: today)
        XCTAssertFalse(load.failed(past))
    }

    func testAServerWithoutTheDayViewOrWithNoHoursSaysSo() {
        var load = DayLoad()
        load.received(nil, for: today)
        XCTAssertEqual(note(load, today), S.noHoursNote(isToday: true))
        load.received(DayData(date: today, today: today, asOf: nil, metrics: [:]), for: today)
        XCTAssertEqual(note(load, today), S.noHoursNote(isToday: true))
    }

    // MARK: Reduce Motion

    func testReduceMotionDropsTheMarkersAnimation() {
        XCTAssertNil(S.motion(.easeOut(duration: 0.25), reduceMotion: true))
        XCTAssertNotNil(S.motion(.spring(duration: 0.35), reduceMotion: false))
    }
}
