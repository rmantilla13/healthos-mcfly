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
        for type in HealthTypes.sampleTypes where type != HealthTypes.workout {
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
            return IngestClient.Response(daily: payload.daily.count, workouts: 0, events: 0, hourly: 0, cycle: 0, metrics: lists ? metrics.sorted() : nil)
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
        for type in HealthTypes.sampleTypes { state.anchors[type.identifier] = Data([1]) }
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
        for type in HealthTypes.sampleTypes { state.anchors[type.identifier] = Data([1]) }
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
