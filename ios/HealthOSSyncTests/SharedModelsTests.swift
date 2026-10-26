import SwiftUI
import XCTest
@testable import HealthOSSync

/// What more than one slice reads from the server, decoded once in the foundation, and the constants copied from the
/// web's shared/ files, checked against them so they can't drift.
@MainActor
final class SharedModelsTests: XCTestCase {
    /// A file of the web app, next to the iPhone app in the repository.
    private func web(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(path)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { throw XCTSkip("\(path) isn't next to the app") }
        return text
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    // MARK: Cycle

    /// GET /api/cycle's days carry each source's part (CycleLogDay), for the log sheet: what was typed in, and what
    /// came from Apple Health. The day as shown reads as before.
    func testACycleDayCarriesEachSourcesPart() throws {
        let data = try decode(CycleData.self, """
        {"enabled":true,"today":"2026-10-20","periods":[],"days":[
          {"date":"2026-10-14","flow":"medium","bbt":36.4,"apple":{"flow":"light","bbt":36.4},"manual":{"flow":"medium"}},
          {"date":"2026-10-15","spotting":true},
          {"date":"2026-10-16","flow":"light","apple":{"flow":7}},
          {"flow":"heavy"}
        ]}
        """)
        XCTAssertEqual(data.days.map(\.date), ["2026-10-14", "2026-10-15", "2026-10-16"], "a day without its date is left out")
        let first = data.days[0]
        XCTAssertEqual(first.flow, "medium", "as shown: the hand-made entry wins")
        XCTAssertEqual(first.bbt, 36.4)
        XCTAssertEqual(first.manual?.flow, "medium")
        XCTAssertEqual(first.apple?.flow, "light")
        XCTAssertNil(data.days[1].apple)
        XCTAssertNil(data.days[1].manual)
        XCTAssertEqual(data.days[1].spotting, true)
        XCTAssertNil(data.days[2].apple, "a part that can't be read is nil, not the day")
        XCTAssertEqual(data.days[2].flow, "light")
        // The old fixtures, from before the parts, still read.
        let url = Bundle(for: Self.self).url(forResource: "cycle-v2", withExtension: "json")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/cycle-v2.json")
        XCTAssertFalse(try JSONDecoder().decode(CycleData.self, from: Data(contentsOf: url)).days.isEmpty)
    }

    // MARK: Journal

    func testTheJournalReadsFieldByField() throws {
        let data = try decode(JournalData.self, """
        {"today":"2026-10-26","older":true,"entries":[
          {"id":"a","date":"2026-10-26","time":"21:10","mood":4,"text":"\\n  Slept well.\\nLong walk.","createdAt":1,"updatedAt":2},
          {"id":"b","date":"2026-10-26","time":"08:00","mood":9,"text":"Odd mood"},
          {"id":"c","date":"2026-10-25","time":"07:30","mood":null,"text":""},
          {"date":"2026-10-24","text":"no id"}
        ]}
        """)
        XCTAssertEqual(data.entries.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(data.older, true)
        XCTAssertEqual(data.entries[0].mood, .good)
        XCTAssertEqual(data.entries[0].mood?.label, "Good")
        XCTAssertEqual(data.entries[0].firstLine, "Slept well.")
        XCTAssertNil(data.entries[1].mood, "a mood the app doesn't know is no mood, not no entry")
        XCTAssertNil(data.entries[2].firstLine)
        XCTAssertEqual(data.todays.map(\.id), ["a", "b"])
        // An older server's answer, without `older`.
        XCTAssertNil(try decode(JournalData.self, #"{"today":"2026-10-26","entries":[]}"#).older)

        // The moods and the limit are the web's (shared/journal.ts).
        let journal = try web("shared/journal.ts")
        let moods = journal.matches(of: /\{ value: (\d), label: '(\w+)' \}/).map { (Int($0.1)!, String($0.2)) }
        XCTAssertEqual(moods.map(\.0), Mood.allCases.map(\.rawValue))
        XCTAssertEqual(moods.map(\.1), Mood.allCases.map(\.label))
        XCTAssertTrue(journal.contains("export const JOURNAL_MAX_CHARS = \(JournalLimits.maxChars);"))
    }

    // MARK: Labs

    private func result(value: Double?, text: String? = nil, qualifier: String? = nil, range: LabRange?, status: LabStatus?) -> LabResult {
        LabResult(valueText: text ?? value.map { String($0) } ?? "Negative", value: value, qualifier: qualifier, unit: "mmol/L", range: range, status: status)
    }

    func testLabsDecodeAndTheLatestComeFirst() throws {
        let data = try decode(LabsData.self, """
        {"today":"2026-10-26","demo":true,"count":3,"markers":[
          {"key":"ldl","name":"LDL cholesterol","group":"Lipids","otherUnits":0,"points":[{"id":"1","date":"2026-01-02","value":3.1}],
           "latest":{"id":"1","collected":"2026-01-02","biomarker":"ldl","name":"LDL","valueText":"3.1","value":3.1,"qualifier":null,"unit":"mmol/L",
                     "range":{"low":null,"high":3.4,"text":"<3.4","kind":"lab"},"status":"within","lab":"Lab","panel":"Lipids","source":"demo"},
           "history":[]},
          {"key":"tsh","name":"TSH","group":"Thyroid","otherUnits":0,"points":[],
           "latest":{"id":"2","collected":"2026-03-04","biomarker":"tsh","name":"TSH","valueText":"5.9","value":5.9,"qualifier":null,"unit":"mIU/L",
                     "range":{"low":0.4,"high":4,"text":"0.4-4.0","kind":"typical","note":"adults"},"status":"above","lab":"Lab","panel":"","source":"demo"},
           "history":[]},
          {"key":"odd","name":"Odd"}
        ],"panels":[]}
        """)
        XCTAssertEqual(data.markers.map(\.key), ["ldl", "tsh"], "one that can't be read is left out")
        XCTAssertEqual(data.demo, true)
        XCTAssertEqual(data.latest(6).map(\.key), ["tsh", "ldl"], "the most recently collected first")
        XCTAssertEqual(LabWords.statusLabel(data.markers[1].latest), "Above typical range")
        XCTAssertEqual(LabWords.rangeLabel(data.markers[1].latest), "0.4-4.0 (typical adult, adults)")
    }

    /// shared/labs.ts statusLabel, statusHint and rangeLabel, case by case.
    func testLabWordsAreTheWebs() {
        let printed = LabRange(low: 3.5, high: 5, text: "3.5-5.0")
        XCTAssertEqual(LabWords.statusLabel(result(value: 4, range: printed, status: .within)), "Within range")
        XCTAssertEqual(LabWords.statusLabel(result(value: 3, range: printed, status: .below)), "Below range")
        XCTAssertNil(LabWords.statusHint(result(value: 4, range: printed, status: .within)))
        XCTAssertEqual(LabWords.statusLabel(result(value: 4, range: nil, status: nil)), "No range printed")
        XCTAssertEqual(LabWords.statusHint(result(value: 4, range: nil, status: nil)), "The report printed no range, and there's no typical range to use for this marker.")
        XCTAssertEqual(LabWords.statusLabel(result(value: nil, range: printed, status: nil)), "Compare with range")
        let words = LabRange(low: nil, high: nil, text: "See note")
        XCTAssertEqual(LabWords.statusLabel(result(value: 2, range: words, status: nil)), "Compare with range")
        XCTAssertEqual(LabWords.statusHint(result(value: 2, range: words, status: nil)), "The printed range has no numbers to place this against: compare the result with the range as printed.")
        let bands = LabRange(low: nil, high: nil, text: "Male: 13-17 Female: 12-15", band: .some(nil))
        XCTAssertEqual(LabWords.statusLabel(result(value: 14, range: bands, status: nil)), "Can’t be placed")
        XCTAssertTrue(LabWords.statusHint(result(value: 14, range: bands, status: nil))?.hasPrefix("The printed range has more than one band") == true)
        let picked = LabRange(low: 12, high: 15, text: "Male: 13-17 Female: 12-15", band: .some("female"))
        XCTAssertEqual(LabWords.statusHint(result(value: 14, range: picked, status: .within)), "The report printed more than one range. This uses the one for women, from the sex in your profile.")
        XCTAssertEqual(LabWords.rangeLabel(result(value: 14, range: picked, status: .within)), "Male: 13-17 Female: 12-15 (female range used)")
        XCTAssertEqual(LabWords.statusHint(result(value: 0.5, text: "<0.5", qualifier: "<", range: printed, status: nil)), "Printed as <0.5, which could fall on either side of the range.")
        XCTAssertEqual(LabWords.rangeLabel(result(value: 1, range: nil, status: nil)), "—")
        XCTAssertEqual(LabWords.rangeText(3.5, 5), "3.5–5")
        XCTAssertEqual(LabWords.rangeText(nil, 199), "≤ 199")
        XCTAssertEqual(LabWords.rangeText(40, nil), "≥ 40")
        XCTAssertEqual(LabWords.number(4.5), 4.5.formatted(.number.precision(.fractionLength(0...2))))
        XCTAssertEqual(LabWords.number(0.4567), 0.457.formatted(.number.precision(.fractionLength(0...3))))
        XCTAssertEqual(LabWords.number(1245.6), 1246.0.formatted(.number.precision(.fractionLength(0))))
        // The web's own words, so the copies can't drift.
        if let labs = try? web("shared/labs.ts") {
            for line in ["return `${where} ${r.range?.kind === 'typical' ? 'typical range' : 'range'}`;", "return 'No range printed';",
                         "return 'Compare with range';", "return 'Can’t be placed';",
                         "This uses the one for ${range.band === 'female' ? 'women' : 'men'}, from the sex in your profile.",
                         "return `Printed as ${r.valueText}, which could fall on either side of the range.`;"] {
                XCTAssertTrue(labs.contains(line), line)
            }
        }
    }

    /// The bar (LabRangeBar.tsx): the band padded on both sides, one-sided ranges from zero, a far result at the edge.
    func testTheLabBarPlacesTheResultAsTheWebDoes() throws {
        let both = try XCTUnwrap(LabRangeBar.layout(result(value: 5, range: LabRange(low: 4, high: 6, text: ""), status: .within)))
        // pad = 2 × 0.6 = 1.2: from 2.8 to 7.2.
        XCTAssertEqual(both.bandFrom, (4 - 2.8) / 4.4, accuracy: 0.001)
        XCTAssertEqual(both.bandTo, (6 - 2.8) / 4.4, accuracy: 0.001)
        XCTAssertEqual(both.dot ?? -1, 0.5, accuracy: 0.001)
        let below = try XCTUnwrap(LabRangeBar.layout(result(value: 100, range: LabRange(low: nil, high: 200, text: "<200"), status: .within)))
        XCTAssertEqual(below.bandFrom, 0)
        XCTAssertEqual(below.bandTo, 200 / 320, accuracy: 0.001)
        let far = try XCTUnwrap(LabRangeBar.layout(result(value: 900, range: LabRange(low: 40, high: nil, text: ">40"), status: .above)))
        XCTAssertEqual(far.bandTo, 1)
        XCTAssertEqual(far.dot, 1, "a result far outside sits at the edge")
        XCTAssertNil(LabRangeBar.layout(result(value: 1, range: nil, status: nil)))
    }

    /// The lab colours are the web's, light and dark (styles.css's "Lab tests" block, which the theme test doesn't read).
    func testTheLabColoursAreTheWebs() throws {
        let css = try web("src/styles.css")
        let block = try XCTUnwrap(css.range(of: "/* ---------- Lab tests").map { String(css[$0.lowerBound...].prefix(1400)) })
        let parts = block.components(separatedBy: "@media (prefers-color-scheme: dark)")
        XCTAssertEqual(parts.count, 2)
        func values(_ text: String) -> [String: String] {
            Dictionary(text.matches(of: /--(lab-[a-z-]+): (#[0-9a-f]{6});/).map { (String($0.1), String($0.2)) }) { a, _ in a }
        }
        let light = values(parts[0]), dark = values(parts[1])
        XCTAssertEqual(Set(light.keys), Set(LabColors.all.keys))
        for (name, token) in LabColors.all {
            XCTAssertEqual(token.light.description, light[name], name)
            XCTAssertEqual(token.dark.description, dark[name], name)
        }
    }

    // MARK: Peers

    /// shared/peers.ts: the minimums, the age groups, the pairs and the quarter a value sits in.
    func testPeerConstantsAreTheWebs() throws {
        let peers = try web("shared/peers.ts")
        XCTAssertTrue(peers.contains("export const PEER_MIN_OTHERS = \(Peers.minOthers);"))
        XCTAssertTrue(peers.contains("export const PEER_MIN_DAYS = \(Peers.minDays);"))
        XCTAssertTrue(peers.contains("export const PEER_WINDOW_DAYS = \(Peers.windowDays);"))
        XCTAssertTrue(peers.contains("export const PEER_MIN_AGE = \(Peers.minAge);"))
        let bands = peers.matches(of: /\{ label: '([^']+)', min: (\d+), max: (\d+) \}/).map { "\($0.1) \($0.2)-\($0.3)" }
        XCTAssertEqual(bands, Peers.ageBands.map { "\($0.label) \($0.min)-\($0.max)" })
        let pairs = peers.matches(of: /\{ metric: '(\w+)', source: '(\w+)', label: '([^']+)', unit: '([^']+)', digits: (\d) \}/)
            .map { Peers.Pair(metric: String($0.1), source: String($0.2), label: String($0.3), unit: String($0.4), digits: Int($0.5)!) }
        XCTAssertEqual(pairs, Peers.pairs)
        let bandIds = try XCTUnwrap(peers.firstMatch(of: /export const PEER_BANDS: PeerBand\[\] = \[([^\]]+)\]/)).1
            .matches(of: /'(\w+)'/).map { String($0.1) }
        XCTAssertEqual(bandIds, Peers.Band.allCases.map(\.rawValue))

        XCTAssertNil(Peers.ageBand(nil))
        XCTAssertNil(Peers.ageBand(17))
        XCTAssertEqual(Peers.ageBand(18), "18–29")
        XCTAssertEqual(Peers.ageBand(70), "70+")
        XCTAssertEqual(Peers.pair(metric: "resting_hr", source: "demo")?.source, "whoop", "the demo sample uses the first pair")
        XCTAssertEqual(Peers.band(you: 50, p25: 50, median: 55, p75: 60), .p25Median, "equal to a quartile is inside the middle half")
        XCTAssertEqual(Peers.band(you: 55, p25: 50, median: 55, p75: 60), .p25Median)
        XCTAssertEqual(Peers.band(you: 60, p25: 50, median: 55, p75: 60), .medianP75)
        XCTAssertEqual(Peers.band(you: 49, p25: 50, median: 55, p75: 60), .belowP25)
        XCTAssertEqual(Peers.band(you: 61, p25: 50, median: 55, p75: 60), .aboveP75)
    }

    // MARK: Figure, WHOOP, the app's permissions

    func testTheDigitalHumanFollowsTheChoiceThenGender() throws {
        func settings(_ json: String) throws -> ServerStatus.Settings { try decode(ServerStatus.Settings.self, json) }
        XCTAssertEqual(FigureVariant.of(nil), .man)
        XCTAssertEqual(FigureVariant.of(try settings(#"{"gender":"woman"}"#)), .woman)
        XCTAssertEqual(FigureVariant.of(try settings(#"{"gender":"nonbinary"}"#)), .man)
        XCTAssertEqual(FigureVariant.of(try settings(#"{"gender":"woman","figure":"man"}"#)), .man, "the one chosen")
        XCTAssertEqual(FigureVariant.of(try settings(#"{"figure":"woman"}"#)), .woman)
        // Only the man's artwork exists, so a woman chosen is drawn, and named, as the man.
        XCTAssertEqual(FigureVariant.woman.drawn, .man)
        XCTAssertNotNil(UIImage(named: FigureVariant.man.assetName))
        XCTAssertNotNil(UIImage(named: "JournalGut"))
        XCTAssertTrue(try web("src/components/Figure.tsx").contains("export const figureVariant = (s: Pick<Settings, 'figure' | 'gender'> | undefined): FigureVariant => s?.figure ?? (s?.gender === 'woman' ? 'woman' : 'man');"))
    }

    func testWhoopSaysWhereToSendPeopleBack() throws {
        let status = try decode(ServerStatus.self, #"{"whoop":{"configured":false,"connected":false,"redirectUri":"http://localhost:8787/api/whoop/callback"}}"#)
        XCTAssertEqual(status.whoop?.redirectUri, "http://localhost:8787/api/whoop/callback")
        XCTAssertNil(try decode(ServerStatus.self, #"{"whoop":{"configured":true}}"#).whoop?.redirectUri)
        XCTAssertEqual(try decode(ServerStatus.self, #"{"whoop":{"configured":true,"redirectUri":7}}"#).whoop?.configured, true, "an odd one leaves the rest")
    }

    /// Voice notes need the microphone's purpose, or iOS ends the app on the first request; the camera's covers every
    /// use and names no provider.
    func testThePermissionsSayWhatTheyreFor() throws {
        let info = try XCTUnwrap(Bundle(for: Dashboard.self).infoDictionary)
        let microphone = try XCTUnwrap(info["NSMicrophoneUsageDescription"] as? String)
        XCTAssertTrue(microphone.contains("voice note"))
        let camera = try XCTUnwrap(info["NSCameraUsageDescription"] as? String)
        for use in ["barcodes", "meal", "reference photo", "lab report"] { XCTAssertTrue(camera.contains(use), use) }
        XCTAssertFalse(camera.contains("Anthropic"))
    }

    /// The chart pages' ranges are the web's (RANGES and DAY_RANGE in Detail.tsx).
    func testTheChartRangesAreTheWebs() throws {
        let detail = try web("src/pages/Detail.tsx")
        let block = try XCTUnwrap(detail.range(of: "export const RANGES = [").map { String(detail[$0.upperBound...].prefix { $0 != ";" }) })
        let ranges = block.matches(of: /\{ days: (\d+), label: '([^']+)' \}/).map { ChartRange(days: Int($0.1)!, label: String($0.2)) }
        XCTAssertEqual(ranges, ChartRange.standard)
        XCTAssertTrue(detail.contains("export const DAY_RANGE = { days: DAY, label: '\(ChartRange.day.label)' };"))
        XCTAssertTrue(detail.contains("export const DAY = \(ChartRange.day.days);"))
        XCTAssertEqual(Dashboard().rangeDays, 30, "useRange's first range")
    }
}
