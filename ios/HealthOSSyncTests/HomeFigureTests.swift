import SwiftUI
import UIKit
import XCTest
@testable import HealthOSSync

// Home's figure and Today's path (slice B's TimelineScrub.swift, OrganicHome.swift and TodayCards.swift): scrubbing,
// the vital levels and the portrait's layout. Slice B owns this file.

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

/// Home's grid of metric cards (TodayGrid): with every card hidden it leaves no gap.
final class HomeGridTests: XCTestCase {
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
}
