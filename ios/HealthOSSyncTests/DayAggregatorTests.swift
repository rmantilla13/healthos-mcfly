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
