import HealthKit
import XCTest
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

    private func point(_ hour: Int, _ minute: Int, _ value: Double, _ source: SampleSource) -> QuantityPoint {
        QuantityPoint(start: at("15 \(String(format: "%02d:%02d", hour, minute))"), value: value, source: source)
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

    func testPendingDaysAreUploadedAWeekAtATime() {
        let days = ["2026-10-01", "2026-10-02", "2026-10-07", "2026-10-08", "2026-10-20"]
        XCTAssertEqual(SyncEngine.windows(days), [["2026-10-01", "2026-10-02", "2026-10-07"], ["2026-10-08"], ["2026-10-20"]])
    }
}
