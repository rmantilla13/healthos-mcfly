import SwiftUI
import UIKit
import XCTest
@testable import HealthOSSync

// The Family board: what it shows and how it lays out (slice N's FamilyScreen.swift), and the Dashboard's family
// state behind it (the foundation's DashboardModel.swift). Slice N owns this file; a foundation change to the family
// state updates FamilyStateTests here.

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

        // Asked to sign in again: the board goes from memory too, so no page shows from it.
        d.phase = .signIn
        XCTAssertNil(d.familyBoard)
        guard case .noBoard = d.familyPerson("u3") else { return XCTFail("nothing behind a sign-in screen") }

        // Back in, the board read again, then sharing goes off: no one's page either.
        d.phase = .ready
        d.apply(status: try status(sharing: true))
        d.receiveFamily(try board())
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
        // Offline at launch, with a status cached from when it worked but no summary: the tab shows, but nothing will
        // be read until the server can be reached.
        let d = Dashboard()
        d.status = try status(sharing: true)
        d.authMode = "required"
        d.phase = .unavailable("Can't reach health.example.com.")
        XCTAssertTrue(d.familyAvailable)
        XCTAssertEqual(describe(d.familyDisplay), "unavailable: Can't reach health.example.com.")
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
