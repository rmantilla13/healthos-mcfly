import XCTest
@testable import HealthOSSync

/// The Bluetooth Heart Rate Measurement format (what a WHOOP strap sends with Heart Rate Broadcast on), and
/// how the live screen keeps its last few minutes.
final class HeartRateMeasurementTests: XCTestCase {
    private func parse(_ bytes: [UInt8]) -> HeartRateMeasurement? { HeartRateMeasurement.parse(Data(bytes)) }

    func testEightBitHeartRate() {
        XCTAssertEqual(parse([0x00, 72]), HeartRateMeasurement(bpm: 72, contact: .unsupported, energyExpended: nil, rrIntervals: []))
    }

    func testSixteenBitHeartRateIsLittleEndian() {
        // 0x012C = 300: a value only the 16-bit format can hold.
        XCTAssertEqual(parse([0x01, 0x2C, 0x01])?.bpm, 300)
        XCTAssertEqual(parse([0x01, 0x48, 0x00])?.bpm, 72)
    }

    func testSkinContact() {
        XCTAssertEqual(parse([0x06, 64])?.contact, .detected)
        XCTAssertEqual(parse([0x04, 0])?.contact, .notDetected)
        XCTAssertEqual(parse([0x02, 64])?.contact, .unsupported, "the detected bit means nothing unless contact is supported")
    }

    func testEnergyExpendedComesBeforeTheIntervals() {
        // Flags: energy + RR. 70 bpm, 0x0123 kJ, then RR 1024 (1 s) and 512 (0.5 s).
        let m = parse([0x18, 70, 0x23, 0x01, 0x00, 0x04, 0x00, 0x02])
        XCTAssertEqual(m?.bpm, 70)
        XCTAssertEqual(m?.energyExpended, 0x0123)
        XCTAssertEqual(m?.rrIntervals, [1.0, 0.5])
    }

    func testIntervalsWithSixteenBitHeartRateAndAStrayByte() {
        let m = parse([0x11, 0x50, 0x00, 0x33, 0x03, 0x99])
        XCTAssertEqual(m?.bpm, 80)
        XCTAssertEqual(m?.rrIntervals, [Double(0x0333) / 1024], "the odd trailing byte is ignored")
        XCTAssertNil(m?.energyExpended)
    }

    func testShortOrEmptyDataIsRejected() {
        XCTAssertNil(parse([]))
        XCTAssertNil(parse([0x00]), "no heart rate byte")
        XCTAssertNil(parse([0x01, 0x48]), "16-bit format with one byte")
        XCTAssertNil(parse([0x08, 70, 0x23]), "energy announced but cut short")
    }

    private func reading(_ bpm: Int, _ contact: HeartRateMeasurement.Contact) -> HeartRateMeasurement {
        HeartRateMeasurement(bpm: bpm, contact: contact, energyExpended: nil, rrIntervals: [])
    }

    func testTheLiveViewKeepsFiveMinutes() {
        let live = LiveHeartRate()
        let start = Date(timeIntervalSince1970: 1_000_000)
        live.record(reading(60, .detected), at: start)
        live.record(reading(75, .unsupported), at: start.addingTimeInterval(301))
        XCTAssertFalse(live.noContact)
        XCTAssertEqual(live.beats.map(\.bpm), [75], "older than five minutes is dropped")
        XCTAssertEqual(live.latest?.bpm, 75)
    }

    func testAStrapOffTheSkinIsNotCharted() {
        let live = LiveHeartRate()
        let start = Date(timeIntervalSince1970: 1_000_000)
        live.record(reading(60, .detected), at: start)
        // A slipped optical strap still sends a plausible number; the contact flag is what says it's wrong.
        live.record(reading(72, .notDetected), at: start.addingTimeInterval(1))
        XCTAssertTrue(live.noContact)
        live.record(reading(0, .unsupported), at: start.addingTimeInterval(2))
        XCTAssertTrue(live.noContact, "zero means no reading, whatever the flags say")
        XCTAssertEqual(live.beats.map(\.bpm), [60])
        XCTAssertEqual(parse([0x04, 64]), HeartRateMeasurement(bpm: 64, contact: .notDetected, energyExpended: nil, rrIntervals: []))
        // Back on the skin: the warning clears and readings are charted again.
        live.record(reading(80, .detected), at: start.addingTimeInterval(3))
        XCTAssertFalse(live.noContact)
        XCTAssertEqual(live.beats.map(\.bpm), [60, 80])
    }

    func testStrapsStayInTheOrderTheyWereHeard() {
        let a = LiveHeartRate.Strap(id: UUID(), name: "WHOOP 4C1234", rssi: -80)
        let b = LiveHeartRate.Strap(id: UUID(), name: "Polar H10", rssi: -50)
        var list = LiveHeartRate.merge([], a)
        list = LiveHeartRate.merge(list, b)
        // Heard again, closer: only its signal changes, so the rows don't move under a finger.
        list = LiveHeartRate.merge(list, LiveHeartRate.Strap(id: a.id, name: a.name, rssi: -40))
        XCTAssertEqual(list.map(\.name), ["WHOOP 4C1234", "Polar H10"])
        XCTAssertEqual(list.first?.rssi, -40)
        // A connected strap reports no signal: the last known one is kept.
        list = LiveHeartRate.merge(list, LiveHeartRate.Strap(id: b.id, name: b.name, rssi: nil, connected: true))
        XCTAssertEqual(list.last?.rssi, -50)
        XCTAssertEqual(list.last?.connected, true)
        XCTAssertEqual(list.first?.connected, false, "an unknown signal isn't 'connected to this iPhone'")
    }

    func testGapsSplitTheLine() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let beats = [0, 1, 2, 30, 31].map { LiveHeartRate.Beat(at: start.addingTimeInterval(Double($0)), bpm: 70) }
        XCTAssertEqual(LiveHeartRate.runs(beats).map { $0.beats.count }, [3, 2])
        XCTAssertEqual(LiveHeartRate.runs([]), [])
    }

    func testTheWatchCardReadsOnlyAppleWatchHeartRate() {
        XCTAssertTrue(LiveHeartRate.isFromWatch(productType: "Watch7,3"))
        XCTAssertFalse(LiveHeartRate.isFromWatch(productType: "iPhone17,1"), "WHOOP's or another app's copy, written from the phone")
        XCTAssertFalse(LiveHeartRate.isFromWatch(productType: nil))
        XCTAssertTrue(LiveHeartRate.isFromWatch(productType: "Watch7,3", deviceModel: "Watch"))
        XCTAssertFalse(LiveHeartRate.isFromWatch(productType: "Watch7,3", deviceModel: "Polar H10"), "a chest strap paired to the Watch")
    }
}

/// Ask McFly's charts: the SSE `visual` event (server/mcfly.ts), answers kept as ordered parts, and the history sent
/// back with each chart as one line, like spoken() in src/pages/McFly.tsx.
final class McFlyVisualTests: XCTestCase {
    /// Feeds raw SSE bytes through the app's own line splitter and the parser, as the server writes them.
    private func events(_ sse: String) -> [McFlyEvent] {
        var lines = McFlySSELineSplitter()
        var parser = McFlySSEParser()
        return Array(sse.utf8).compactMap { lines.push($0) }.compactMap { parser.feed($0) }
    }

    private func frame(_ event: String, _ data: String) -> String { "event: \(event)\ndata: \(data)\n\n" }

    private let barsJSON = #"{"visual":{"kind":"bars","title":"Steps this week","unit":"steps","resolution":"day","points":[{"date":"2026-10-17","value":9100},{"date":"2026-10-18","value":11250},{"date":"2026-10-19","value":3200}],"mean":10175,"days":2,"partialToday":true,"goal":10000}}"#

    private func visual(_ json: String) -> McFlyVisual? {
        guard case .visual(let v)? = events(frame("visual", json)).first else { return nil }
        return v
    }

    func testAVisualArrivesBetweenTextEvents() {
        let sse = frame("tool", #"{"label":"Looking at steps over 3 days"}"#)
            + frame("text", #"{"text":"Here's your week."}"#)
            + frame("visual", barsJSON)
            + frame("text", #"{"text":"\n\nTwo of the days were over your goal."}"#)
            + frame("done", "{}")
        let got = events(sse)
        XCTAssertEqual(got.count, 5)
        XCTAssertEqual(got[0], .tool("Looking at steps over 3 days"))
        XCTAssertEqual(got[1], .text("Here's your week."))
        XCTAssertEqual(got[3], .text("\n\nTwo of the days were over your goal."))
        XCTAssertEqual(got[4], .done)
        guard case .visual(.series(let s)) = got[2] else { return XCTFail("expected a bar chart, got \(got[2])") }
        XCTAssertEqual(s.style, .bars)
        XCTAssertEqual(s.title, "Steps this week")
        XCTAssertEqual(s.unit, "steps")
        XCTAssertEqual(s.points.map(\.date), ["2026-10-17", "2026-10-18", "2026-10-19"])
        XCTAssertEqual(s.points.map(\.value), [9100, 11250, 3200])
        XCTAssertEqual(s.mean, 10175)
        XCTAssertEqual(s.days, 2)
        XCTAssertTrue(s.partialToday)
        XCTAssertEqual(s.goal, 10000)
        XCTAssertFalse(s.weekly)
        XCTAssertEqual(s.note, "average of 2 days · today isn't counted until it's over", "the web's words")
    }

    func testAnUnknownOrBrokenVisualIsSkippedAndTheStreamCarriesOn() {
        let sse = frame("text", #"{"text":"Before."}"#)
            + frame("visual", #"{"visual":{"kind":"heatmap","title":"From a newer server","cells":[[1,2],[3,4]]}}"#)
            + frame("visual", #"{"visual":{"kind":"trend","title":"No points","unit":"bpm","resolution":"day","points":[],"mean":null}}"#)
            + frame("visual", #"{"visual":{"kind":"trend","title":"Bad dates","unit":"bpm","points":[{"date":"yesterday","value":60},{"date":"2026-02-30","value":61}]}}"#)
            + frame("visual", #"{"visual":"#)
            + frame("visual", #"{"nothing":true}"#)
            + frame("sparkle", #"{"text":"an event this app doesn't know"}"#)
            + frame("text", #"{"text":" After."}"#)
            + frame("done", "{}")
        XCTAssertEqual(events(sse), [.text("Before."), .text(" After."), .done])
    }

    func testOneBadPointIsLeftOutOnItsOwn() {
        let json = #"{"visual":{"kind":"trend","title":"Resting heart rate","unit":"bpm","resolution":"week","points":[{"date":"2026-01-05","value":58},{"date":"2026-01-12","value":null},{"date":"Jan 19","value":57},{"date":"2026-01-26","value":56.5}],"mean":57.2,"days":24,"future":"ignored"}}"#
        guard case .series(let s)? = visual(json) else { return XCTFail("expected a trend") }
        XCTAssertEqual(s.style, .trend)
        XCTAssertEqual(s.points.map(\.date), ["2026-01-05", "2026-01-26"])
        XCTAssertTrue(s.weekly)
        XCTAssertFalse(s.partialToday, "absent means a whole day")
        XCTAssertNil(s.goal)
        XCTAssertEqual(s.note, "daily average over 24 days · shown as weekly averages")
    }

    func testEveryKindDecodes() {
        let compare = visual(#"{"visual":{"kind":"compare","title":"Sleep: this week vs last","unit":"h","periods":[{"label":"This week","from":"2026-10-13","to":"2026-10-19","mean":7.5,"days":7,"partialToday":false},{"label":"Last week","from":"2026-10-06","to":"2026-10-12","mean":6.25,"days":6}]}}"#)
        guard case .compare(let c)? = compare else { return XCTFail("compare") }
        XCTAssertEqual(c.periods.map(\.label), ["This week", "Last week"])
        XCTAssertEqual(c.change ?? 0, 20, accuracy: 0.001)
        XCTAssertEqual(c.periods[1].caption, "Oct 6 – Oct 12 · 6 days with data")

        let stats = visual(#"{"visual":{"kind":"stats","title":"Your numbers","items":[{"label":"HRV","value":48,"unit":"ms","note":"average of 7 days","from":"2026-10-13","to":"2026-10-19"},{"label":"Weight","value":72.4,"unit":"kg","note":"2026-10-18"},{"label":"VO2 max","value":null,"unit":"mL/kg/min","note":"No data"}]}}"#)
        guard case .stats(let st)? = stats else { return XCTFail("stats") }
        XCTAssertEqual(st.items.count, 3)
        XCTAssertNil(st.items[2].value)
        XCTAssertEqual(st.items[0].caption, "average of 7 days, Oct 13 – Oct 19")
        XCTAssertEqual(st.items[1].caption, "Sun, Oct 18", "a latest reading's note is its day")
        XCTAssertEqual(st.items[2].caption, "No data")

        let stages = visual(#"{"visual":{"kind":"stages","title":"Sleep stages","rows":[{"date":"2026-10-18","values":{"sleep_deep":1.2,"sleep_light":4,"sleep_rem":1.5,"sleep_awake":0.4}},{"date":"2026-10-19","values":{"sleep_deep":0.9,"sleep_rem":1.8}}]}}"#)
        guard case .stages(let sg)? = stages else { return XCTFail("stages") }
        XCTAssertEqual(sg.rows.map(\.date), ["2026-10-18", "2026-10-19"])
        XCTAssertEqual(sg.rows[1].values, ["sleep_deep": 0.9, "sleep_rem": 1.8])

        let sports = visual(#"{"visual":{"kind":"sports","title":"Workouts by type","items":[{"sport":"Running","count":5,"minutes":210},{"sport":"Other (3 types)","count":4,"minutes":95}]}}"#)
        guard case .sports(let sp)? = sports else { return XCTFail("sports") }
        XCTAssertEqual(sp.items, [.init(sport: "Running", count: 5, minutes: 210), .init(sport: "Other (3 types)", count: 4, minutes: 95)])

        let monthly = visual(#"{"visual":{"kind":"trend","title":"Weight","unit":"kg","resolution":"month","points":[{"date":"2026-01-01","value":73}],"mean":null}}"#)
        guard case .series(let m)? = monthly else { return XCTFail("a monthly trend still decodes") }
        XCTAssertTrue(m.weekly)
        XCTAssertNil(m.mean)
    }

    func testAnAnswerKeepsItsPartsInArrivalOrder() {
        var m = McFlyMessage(role: .assistant, content: "")
        let chart = visual(barsJSON)!
        m.apply(.tool("Looking at steps"))
        m.apply(.text("Here's "))
        m.apply(.text("your week."))
        m.apply(.visual(chart))
        m.apply(.text("\n\n"))
        m.apply(.text("Nice work."))
        m.apply(.visual(chart))
        m.apply(.done)
        XCTAssertEqual(m.parts, [.text("Here's your week."), .visual(chart), .text("\n\nNice work."), .visual(chart)])
        XCTAssertEqual(m.content, "Here's your week.\n\nNice work.", "content stays the words alone")
        XCTAssertTrue(m.hasVisual)
        m.finishAnswer()
        XCTAssertFalse(m.failed)
    }

    func testAChartOnlyAnswerIsAnAnswerAndARefusalDropsTheRest() {
        let chart = visual(barsJSON)!
        var only = McFlyMessage(role: .assistant, content: "")
        only.apply(.visual(chart))
        only.finishAnswer()
        XCTAssertFalse(only.failed)
        XCTAssertEqual(only.spoken, "[Showed a chart: Steps this week]")

        var empty = McFlyMessage(role: .assistant, content: "")
        empty.apply(.text("\n\n"))
        empty.finishAnswer()
        XCTAssertTrue(empty.failed)
        XCTAssertEqual(empty.error, "McFly had no answer. Try asking another way.")

        var refused = McFlyMessage(role: .assistant, content: "")
        refused.apply(.text("Partly"))
        refused.apply(.visual(chart))
        refused.apply(.refusal("McFly can't help with that one. Try asking another way."))
        XCTAssertTrue(refused.failed)
        XCTAssertEqual(refused.parts, [])
        XCTAssertEqual(refused.content, "")
        XCTAssertEqual(refused.error, "McFly can't help with that one. Try asking another way.")
    }

    func testSpokenReplacesEachChartWithOneLine() {
        let chart = visual(barsJSON)!
        var m = McFlyMessage(role: .assistant, content: "")
        m.apply(.text("Here's the trend.\n"))
        m.apply(.visual(chart))
        m.apply(.text("\n\nYou're above your goal most days.\n\n\n"))
        XCTAssertEqual(m.spoken, "Here's the trend.\n\n[Showed a chart: Steps this week]\n\nYou're above your goal most days.")
        // An answer from an older server has no parts: its content is what goes back.
        XCTAssertEqual(McFlyMessage(role: .assistant, content: "Plain answer").spoken, "Plain answer")
    }

    func testHistoryCarriesTheChartPlaceholderAndSkipsFailedAnswers() throws {
        let chart = visual(barsJSON)!
        var answer = McFlyMessage(role: .assistant, content: "")
        answer.apply(.text("Your steps:"))
        answer.apply(.visual(chart))
        var failed = McFlyMessage(role: .assistant, content: "")
        failed.apply(.error("McFly is busy right now. Try again in a minute."))
        let messages = [
            McFlyMessage(role: .user, content: "How many steps this week?"),
            answer,
            McFlyMessage(role: .user, content: "And yesterday?"),
            failed,
            McFlyMessage(role: .user, content: "How did I sleep?"),
            McFlyMessage(role: .assistant, content: "About 7 hours a night."),
        ]
        let turns = McFlyMessage.history(messages, question: "Is that enough?")
        XCTAssertEqual(turns, [
            McFlyTurn(role: "user", content: "How many steps this week?"),
            McFlyTurn(role: "assistant", content: "Your steps:\n\n[Showed a chart: Steps this week]"),
            McFlyTurn(role: "user", content: "How did I sleep?"),
            McFlyTurn(role: "assistant", content: "About 7 hours a night."),
            McFlyTurn(role: "user", content: "Is that enough?"),
        ], "the failed pair goes, so roles still alternate as the server requires")

        let body = try JSONEncoder().encode(["messages": turns])
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: [[String: String]]])
        XCTAssertEqual(decoded["messages"]?[1], ["role": "assistant", "content": "Your steps:\n\n[Showed a chart: Steps this week]"])
    }

    func testValuesReadLikeTheWeb() {
        XCTAssertEqual(McFlyFormat(unit: "h", values: [7.4]).value(7.4), "7h 24m")
        XCTAssertEqual(McFlyFormat(unit: "h", values: [6.9999]).value(6.9999), "7h 00m", "rounded to the minute before splitting")
        XCTAssertEqual(McFlyFormat(unit: "%", values: [85]).value(85), "85%")
        XCTAssertEqual(McFlyFormat(unit: "°F", values: [100.4]).value(100.4), "100.4 °F")
        XCTAssertEqual(McFlyFormat(unit: "steps", values: [8000.4]).value(8000.4), "8,000 steps")
        XCTAssertEqual(McFlyFormat(unit: "", values: [12.5]).value(12.5), "12.5")
        XCTAssertEqual(McFlyFormat(unit: "steps", values: [4000, 12_000]).tick(12_000), "12K")
        XCTAssertEqual(McFlyVisual.Series.runs([Point(date: "2026-10-01", value: 1), Point(date: "2026-10-03", value: 2), Point(date: "2026-10-09", value: 3)], gapDays: 3).map(\.count), [2, 1])
    }
}

/// Ask McFly's review fixes: the stream is cut into lines at "\n" only (so U+2028, U+2029 and U+0085 inside a data
/// line survive), a failed answer keeps the words and charts that already arrived, and the thread follows new words
/// only while the reader is at the bottom (the `following` ref in src/pages/McFly.tsx).
final class McFlyStreamFixTests: XCTestCase {
    private func stream(_ bytes: [UInt8]) -> AsyncStream<UInt8> {
        AsyncStream { c in
            bytes.forEach { c.yield($0) }
            c.finish()
        }
    }

    /// The same reading code mcflyChat runs on the response body.
    private func read(_ sse: String) async throws -> [McFlyEvent] {
        var got: [McFlyEvent] = []
        try await McFlySSEParser.read(stream(Array(sse.utf8))) { got.append($0) }
        return got
    }

    private func contains(_ hay: [UInt8], _ needle: [UInt8]) -> Bool {
        hay.indices.contains { hay[$0...].starts(with: needle) }
    }

    private let chart = McFlyVisual.series(.init(style: .bars, title: "Steps this week", unit: "steps", resolution: "day",
                                                 points: [Point(date: "2026-10-18", value: 11250)], mean: 11250, days: 1,
                                                 partialToday: false, goal: nil))

    func testLineAndParagraphSeparatorsStayInsideTheirDataLine() async throws {
        // JSON.stringify leaves these three unescaped, so they reach the app as raw bytes inside one data line.
        let sse = "event: text\ndata: " + #"{"text":"Rest\#u{2028}then\#u{2029}move\#u{0085}gently"}"# + "\n\n"
            + "event: visual\ndata: " + #"{"visual":{"kind":"bars","title":"Steps\#u{2028}this\#u{2029}week\#u{0085}so far","unit":"steps","resolution":"day","points":[{"date":"2026-10-18","value":11250}],"mean":11250,"days":1}}"# + "\n\n"
            + "event: text\ndata: " + #"{"text":" After."}"# + "\n\n"
            + "event: done\ndata: {}\n\n"
        let raw = Array(sse.utf8)
        XCTAssertTrue(contains(raw, [0xE2, 0x80, 0xA8]), "U+2028 is in the bytes, unescaped")
        XCTAssertTrue(contains(raw, [0xE2, 0x80, 0xA9]), "U+2029 is in the bytes, unescaped")
        XCTAssertTrue(contains(raw, [0xC2, 0x85]), "U+0085 is in the bytes, unescaped")

        let got = try await read(sse)
        XCTAssertEqual(got.count, 4, "\(got)")
        guard got.count == 4 else { return }
        XCTAssertEqual(got[0], .text("Rest\u{2028}then\u{2029}move\u{0085}gently"), "the words aren't lost")
        guard case .visual(.series(let s)) = got[1] else { return XCTFail("the chart isn't lost: \(got[1])") }
        XCTAssertEqual(s.title, "Steps\u{2028}this\u{2029}week\u{0085}so far")
        XCTAssertEqual(s.points.map(\.value), [11250])
        XCTAssertEqual(got[2], .text(" After."))
        XCTAssertEqual(got[3], .done)
    }

    func testBreaksAreLFCRLFOrCRAndMultibyteCharactersSurvive() async throws {
        var splitter = McFlySSELineSplitter()
        let input = "event: text\r\ndata: {\"text\":\"Å … 🫀 心\"}\r\n\r\nevent: done\rdata: {}\n\nevent: tool"
        let lines = Array(input.utf8).compactMap { splitter.push($0) }
        XCTAssertEqual(lines, ["event: text", "data: {\"text\":\"Å … 🫀 心\"}", "", "event: done", "data: {}", ""], "a \"\\r\\n\" is one break, not two")
        XCTAssertEqual(splitter.finish(), "event: tool", "a last line with no break after it still counts")
        XCTAssertNil(splitter.finish())

        let got = try await read(input)
        XCTAssertEqual(got, [.text("Å … 🫀 心"), .done], "reading stops at done")
    }

    func testAnErrorPartwayKeepsTheWordsAndChartsThatArrived() {
        var m = McFlyMessage(role: .assistant, content: "")
        m.apply(.text("Your steps:"))
        m.apply(.visual(chart))
        m.apply(.text("\n\nMostly over"))
        m.apply(.error("McFly took too many steps on this one. Try a narrower question."))
        m.finishAnswer() // ask() still finishes the answer after an error event ends the stream
        XCTAssertTrue(m.failed)
        XCTAssertEqual(m.content, "Your steps:\n\nMostly over")
        XCTAssertEqual(m.parts, [.text("Your steps:"), .visual(chart), .text("\n\nMostly over")])
        XCTAssertEqual(m.error, "McFly took too many steps on this one. Try a narrower question.")
        XCTAssertEqual(m.spoken, "Your steps:\n\n[Showed a chart: Steps this week]\n\nMostly over")
    }

    func testADroppedConnectionKeepsTheWordsAndChartsThatArrived() {
        // The catch in ask(): a transport failure or the stream's idle timeout.
        var m = McFlyMessage(role: .assistant, content: "")
        m.apply(.text("So far"))
        m.apply(.visual(chart))
        m.fail("The request timed out.")
        XCTAssertTrue(m.failed)
        XCTAssertEqual(m.content, "So far")
        XCTAssertEqual(m.parts, [.text("So far"), .visual(chart)])
        XCTAssertEqual(m.error, "The request timed out.")
        m.fail("Can't reach the server.")
        XCTAssertEqual(m.error, "The request timed out.", "the first error is the one shown")

        // Both kinds of failed answer still stay out of what McFly reads back.
        var errored = McFlyMessage(role: .assistant, content: "")
        errored.apply(.text("Partly"))
        errored.apply(.error("Something went wrong."))
        let turns = McFlyMessage.history([
            McFlyMessage(role: .user, content: "Steps this week?"), m,
            McFlyMessage(role: .user, content: "And sleep?"), errored,
        ], question: "Try again?")
        XCTAssertEqual(turns, [McFlyTurn(role: "user", content: "Try again?")])

        // A refusal is still the one that clears what came before it.
        var refused = McFlyMessage(role: .assistant, content: "")
        refused.apply(.text("Partly"))
        refused.apply(.visual(chart))
        refused.apply(.refusal("McFly can't help with that one."))
        XCTAssertEqual(refused.parts, [])
        XCTAssertEqual(refused.content, "")
        XCTAssertEqual(refused.error, "McFly can't help with that one.")
    }

    func testTheThreadFollowsOnlyWhileTheReaderIsAtTheBottom() {
        let f = McFlyFollow()
        f.viewportBottom = 700
        f.contentMoved(top: -1000, bottom: 700)
        XCTAssertTrue(f.following)
        // Words, then a ~250pt chart, land below the fold: the content grows, but nobody scrolled.
        f.contentMoved(top: -1000, bottom: 720)
        f.contentMoved(top: -1000, bottom: 970)
        XCTAssertTrue(f.following, "growth alone never lets go")
        // The thread's own animated scroll down to the newest words, frame by frame.
        f.contentMoved(top: -1100, bottom: 870)
        f.contentMoved(top: -1200, bottom: 770)
        f.contentMoved(top: -1270, bottom: 700)
        XCTAssertTrue(f.following, "moving toward the bottom, even from 270pt away, doesn't let go")
        // The reader scrolls up toward the chart.
        f.contentMoved(top: -1230, bottom: 740)
        XCTAssertTrue(f.following, "within 80pt of the bottom still follows, like the web")
        f.contentMoved(top: -1150, bottom: 820)
        XCTAssertFalse(f.following, "past 80pt lets go")
        // More words arrive while they read the chart.
        f.contentMoved(top: -1150, bottom: 900)
        XCTAssertFalse(f.following)
        // The keyboard comes up: the visible bottom moves, nobody scrolled.
        f.viewportBottom = 400
        f.contentMoved(top: -1150, bottom: 900)
        f.viewportBottom = 700
        XCTAssertFalse(f.following)
        // Heading back down, not there yet.
        f.contentMoved(top: -1200, bottom: 850)
        XCTAssertFalse(f.following)
        // Back within 80pt.
        f.contentMoved(top: -1290, bottom: 760)
        XCTAssertTrue(f.following)
    }

    func testTouchingAChartLetsGoUntilTheReaderScrollsBackOrAsksAgain() {
        let f = McFlyFollow()
        f.viewportBottom = 700
        f.contentMoved(top: -500, bottom: 700)
        f.chartTouched()
        XCTAssertFalse(f.following)
        // Words keep arriving under the chart while a finger is on it, right at the bottom.
        f.contentMoved(top: -500, bottom: 730)
        f.contentMoved(top: -500, bottom: 760)
        XCTAssertFalse(f.following, "the answer growing doesn't pull the chart away")
        // A small scroll at the bottom takes hold again.
        f.contentMoved(top: -560, bottom: 700)
        XCTAssertTrue(f.following)
        f.chartTouched()
        f.sent()
        XCTAssertTrue(f.following, "asking again follows the new answer")

        // Up the thread when a refusal clears the partial answer: the thread settles at its new bottom and follows.
        let g = McFlyFollow()
        g.viewportBottom = 700
        g.contentMoved(top: -1000, bottom: 700)
        g.contentMoved(top: -800, bottom: 900)
        XCTAssertFalse(g.following)
        g.contentMoved(top: -500, bottom: 700)
        XCTAssertTrue(g.following)
    }
}
