import SwiftUI
import XCTest
@testable import HealthOSSync

/// Profile's age-group comparison (Peers/): GET /api/peers read as shared/peers.ts sends it, and shown in
/// src/pages/Profile.tsx's words and formats. peers-ready.json and peers-demo.json are written by hand as server/peers.ts
/// compare() would answer (a group of 20 or more can't exist on a local server): testTheFixturesAreAnswersTheServerCanSend
/// holds them to it. peers-demo.json's group is the server's own sample group (SAMPLE, sampleGroup) for its two
/// measurements. The not-taking-part answers are a local server's.
@MainActor
final class PeersTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = Bundle(for: Self.self).url(forResource: name, withExtension: "json")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name).json")
        return try XCTUnwrap(try? Data(contentsOf: url), "missing fixture \(name).json")
    }

    private func web(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(path)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { throw XCTSkip("\(path) isn't next to the app") }
        return text
    }

    private func decode(_ json: String) throws -> PeerData {
        try JSONDecoder().decode(PeerData.self, from: Data(json.utf8))
    }

    private func metric(_ id: String, in data: PeerData) throws -> PeerMetric {
        try XCTUnwrap(data.metrics.first { $0.id == id }, id)
    }

    // MARK: Reading the answer

    func testNotTakingPartForEachReason() throws {
        for reason in ["off", "no_age", "under_age", "no_accounts"] {
            let data = try decode(#"{"participating":false,"reason":"\#(reason)"}"#)
            XCTAssertFalse(data.participating)
            XCTAssertEqual(data.reason, reason)
            XCTAssertNotNil(PeerWords.notTakingPart(data.reason, editLink: true), reason)
        }
        // A reason a later server adds says nothing (the web's lookup comes back empty), and the fine print stays.
        let later = try decode(#"{"participating":false,"reason":"paused"}"#)
        XCTAssertNil(PeerWords.notTakingPart(later.reason, editLink: true))
    }

    func testALocalServersAnswers() throws {
        // A made-up account on a local server: comparisons off, then on with an age and no readings yet.
        let off = try decode(#"{"participating":false,"reason":"off"}"#)
        XCTAssertEqual(PeerWords.notTakingPart(off.reason, editLink: true), "You're not taking part. Turn it on in [Edit preferences](healthos://welcome).")
        let none = try decode(#"{"participating":true,"ageBand":"30–39","window":{"from":"2026-09-27","to":"2026-10-26"},"metrics":[]}"#)
        XCTAssertTrue(none.participating)
        XCTAssertTrue(none.metrics.isEmpty, "shows the no-readings line")
        XCTAssertFalse(none.gathering)
    }

    func testTakingPartReadsEachMeasurementOnItsOwn() throws {
        let data = try JSONDecoder().decode(PeerData.self, from: fixture("peers-ready"))
        XCTAssertTrue(data.participating)
        XCTAssertEqual(data.ageBand, "30–39")
        XCTAssertEqual(data.window, PeerData.Window(from: "2026-09-27", to: "2026-10-26"))
        XCTAssertNil(data.demo)
        XCTAssertEqual(data.metrics.map(\.id), ["resting_hr|whoop", "sleep_hours|apple", "steps|apple", "spo2|apple", "hrv_rmssd|whoop", "recovery|whoop", "resp_rate|whoop"])
        let rhr = try metric("resting_hr|whoop", in: data)
        XCTAssertEqual(rhr.quarter, .belowP25)
        XCTAssertEqual(rhr.group, PeerMetric.Group(size: "50+", median: 60, p25: 56, p75: 65))
        XCTAssertNil(try metric("hrv_rmssd|whoop", in: data).group, "only a ready one has a group")
        // The fixture's quarters are what shared/peers.ts peerBand says for its rounded figures.
        for m in data.metrics where m.status == "ready" {
            let g = try XCTUnwrap(m.group)
            XCTAssertEqual(Peers.band(you: try XCTUnwrap(m.you), p25: g.p25, median: g.median, p75: g.p75), m.quarter, m.id)
        }
    }

    /// What compare() (server/peers.ts) can answer: every row has your own average, rounded to its pair's digits;
    /// fewer than PEER_MIN_DAYS days of yours is not_enough_days, before the group is looked at; a ready row's
    /// quartiles are rounded to the pair's digits, its quarter is peerBand's for them, and its size is a bucket.
    func testTheFixturesAreAnswersTheServerCanSend() throws {
        let server = try web("server/peers.ts")
        XCTAssertTrue(server.contains("if (own.days < PEER_MIN_DAYS) return { ...base, status: 'not_enough_days' };"))
        XCTAssertTrue(server.contains("const you = round(own.avg, digits);"))
        XCTAssertTrue(server.contains("median: round(quantile(sorted, 0.5), digits), p25: round(quantile(sorted, 0.25), digits), p75: round(quantile(sorted, 0.75), digits)"))
        func rounded(_ v: Double, _ digits: Int) -> Bool {
            let scale = pow(10, Double(digits))
            return abs((v * scale).rounded() / scale - v) < 1e-9
        }
        for name in ["peers-ready", "peers-demo"] {
            let data = try JSONDecoder().decode(PeerData.self, from: fixture(name))
            XCTAssertFalse(data.metrics.isEmpty, name)
            for m in data.metrics {
                let digits = try XCTUnwrap(Peers.pair(metric: m.metric, source: m.source), m.id).digits
                let you = try XCTUnwrap(m.you, "\(name) \(m.id): compare() always sends your average")
                XCTAssertTrue(rounded(you, digits), "\(name) \(m.id)")
                switch m.status {
                case "not_enough_days":
                    XCTAssertLessThan(m.yourDays, Peers.minDays, "\(name) \(m.id)")
                case "gathering":
                    XCTAssertGreaterThanOrEqual(m.yourDays, Peers.minDays, "\(name) \(m.id)")
                    XCTAssertNil(m.group)
                case "ready":
                    XCTAssertGreaterThanOrEqual(m.yourDays, Peers.minDays, "\(name) \(m.id)")
                    let g = try XCTUnwrap(m.group, m.id)
                    for q in [g.p25, g.median, g.p75] { XCTAssertTrue(rounded(q, digits), "\(name) \(m.id) \(q)") }
                    XCTAssertTrue(["20+", "50+", "100+"].contains(g.size), m.id)
                    XCTAssertEqual(Peers.band(you: you, p25: g.p25, median: g.median, p75: g.p75), m.quarter, "\(name) \(m.id)")
                default:
                    XCTFail("\(name) \(m.id): \(m.status)")
                }
            }
        }
        // The sample group is 64 made-up people: 50+.
        XCTAssertTrue(server.contains("const SAMPLE_SIZE = 64;"))
        XCTAssertTrue(server.contains("resting_hr: { center: 60, spread: 7 },"))
        XCTAssertTrue(server.contains("sleep_hours: { center: 7, spread: 0.7 },"))
    }

    func testOddShapesKeepWhatCanBeRead() throws {
        // A row with no metric is dropped on its own; the rest stay.
        let partial = try decode(#"{"participating":true,"ageBand":"30–39","window":{"from":"2026-09-27","to":"2026-10-26"},"metrics":[{"metric":"steps","source":"apple","you":8412,"yourDays":30,"status":"gathering"},{"source":"apple","status":"ready"}]}"#)
        XCTAssertEqual(partial.metrics.map(\.id), ["steps|apple"])
        // shared/peers.ts allows no average of your own (null): the row says so by leaving it out.
        let noAverage = try decode(#"{"participating":true,"ageBand":"30–39","window":{"from":"2026-09-27","to":"2026-10-26"},"metrics":[{"metric":"resp_rate","source":"whoop","you":null,"yourDays":9,"status":"gathering"}]}"#)
        XCTAssertNil(try XCTUnwrap(noAverage.metrics.first).you)
        // A band the app doesn't know, a group it can't read and no day count: the rest of the row stays.
        let data = try decode(#"{"participating":true,"ageBand":"70+","window":{"from":"2026-09-27","to":"2026-10-26"},"metrics":[{"metric":"steps","source":"apple","you":5000,"status":"ready","band":"top_tenth","group":"lots"}],"demo":true}"#)
        let m = try XCTUnwrap(data.metrics.first)
        XCTAssertNil(m.quarter)
        XCTAssertNil(m.group)
        XCTAssertEqual(m.yourDays, 0)
        XCTAssertEqual(data.demo, true)
        // Without `participating` it isn't an answer at all.
        XCTAssertThrowsError(try decode(#"{"reason":"off"}"#))
    }

    func testTheGatheringNoteOnlyWhileNothingIsReady() throws {
        let ready = try JSONDecoder().decode(PeerData.self, from: fixture("peers-ready"))
        XCTAssertFalse(ready.gathering, "one is ready")
        let waiting = PeerData(participating: true, metrics: ready.metrics.filter { $0.status != "ready" })
        XCTAssertTrue(waiting.gathering)
        let notEnough = PeerData(participating: true, metrics: ready.metrics.filter { $0.status == "not_enough_days" })
        XCTAssertFalse(notEnough.gathering, "too few days of your own isn't the group gathering")
        XCTAssertFalse(PeerData(participating: true).gathering)
    }

    // MARK: Words and numbers, as Profile.tsx has them

    func testTheWordsAreProfiles() throws {
        let profile = try web("src/pages/Profile.tsx")
        for words in [PeerWords.fine, PeerWords.demo, PeerWords.noReadings, "Peer comparisons are for people aged 18 and over.",
                      "There's no one to compare with here: this healthOS runs on this Mac without accounts.",
                      "Waiting for enough people in your age group to compare with.",
                      PeerWords.title, PeerWords.meta, "Couldn't load your comparison: {error.message}"] {
            XCTAssertTrue(profile.contains(words), words)
        }
        XCTAssertEqual(PeerWords.loadFailed("Something went wrong"), "Couldn't load your comparison: Something went wrong")
        // The two with a link to Edit preferences.
        XCTAssertTrue(profile.contains("You're not taking part. Turn it on in <a href={href('welcome')}>Edit preferences</a>."))
        XCTAssertTrue(profile.contains("Add your age in <a href={href('welcome')}>Edit preferences</a> to take part."))
        XCTAssertEqual(PeerWords.notTakingPart("off", editLink: true), "You're not taking part. Turn it on in [Edit preferences](healthos://welcome).")
        XCTAssertEqual(PeerWords.notTakingPart("no_age", editLink: false), "Add your age in Edit preferences to take part.",
                       "no link where the server has no welcome steps")
        XCTAssertEqual(AppRoute(url: URL(string: "healthos://welcome")!)?.page, .welcome, "the link opens the welcome's steps")
        // The templates.
        XCTAssertTrue(profile.contains("Not enough people in your age group yet. Results appear once at least {PEER_MIN_OTHERS} others have {PEER_MIN_DAYS} recorded days."))
        XCTAssertEqual(PeerWords.gathering, "Not enough people in your age group yet. Results appear once at least 20 others have 7 recorded days.")
        XCTAssertTrue(profile.contains("Ages {data.ageBand} · your averages for {fmtDate(data.window.from)} – {fmtDate(data.window.to)}"))
        XCTAssertTrue(profile.contains("Group median {show(m.group.median)} · middle half {range(m.group.p25, m.group.p75)} · {m.group.size} people"))
        XCTAssertTrue(profile.contains("{m.yourDays} of {PEER_MIN_DAYS} recorded days so far: your result appears after {PEER_MIN_DAYS}."))
        XCTAssertTrue(profile.contains("`Your average ${show(m.you)} over ${m.yourDays} ${m.yourDays === 1 ? 'day' : 'days'}`"))
        XCTAssertTrue(profile.contains("{yours && `${yours}. `}Waiting for enough people"))
        // The quarters and the sources.
        for band in Peers.Band.allCases {
            XCTAssertTrue(profile.contains("\(band.rawValue): \(band == .belowP25 ? "\"" : "'")\(PeerWords.bandLabel(band))"), band.rawValue)
        }
        XCTAssertTrue(profile.contains("const SOURCE_LABEL: Record<string, string> = { whoop: 'WHOOP', apple: 'Apple Health', demo: 'Sample' };"))
        XCTAssertEqual(["whoop", "apple", "demo", "garmin"].map(PeerWords.sourceLabel), ["WHOOP", "Apple Health", "Sample", "garmin"])
    }

    func testValuesReadAsTheWebsRows() throws {
        let data = try JSONDecoder().decode(PeerData.self, from: fixture("peers-ready"))
        let rhr = try metric("resting_hr|whoop", in: data)
        XCTAssertEqual(PeerWords.heading(rhr), "Resting heart rate · WHOOP")
        XCTAssertEqual(PeerWords.yours(rhr), "Your average 54 bpm over 28 days")
        XCTAssertEqual(PeerWords.group(try XCTUnwrap(rhr.group), rhr), "Group median 60 bpm · middle half 56–65 bpm · 50+ people")
        // Sleep in hours and minutes, the range without a unit.
        let sleep = try metric("sleep_hours|apple", in: data)
        XCTAssertEqual(PeerWords.yours(sleep), "Your average 7h 24m over 21 days")
        XCTAssertEqual(PeerWords.group(try XCTUnwrap(sleep.group), sleep), "Group median 7h 06m · middle half 6h 30m–7h 36m · 100+ people")
        // Steps with the thousands separator, the unit after a space; % right after the number, one day singular.
        let steps = try metric("steps|apple", in: data)
        XCTAssertEqual(PeerWords.value(8412, steps), Fmt.number(8412) + " steps")
        XCTAssertEqual(PeerWords.range(5100, 8100, steps), "\(Fmt.number(5100))–\(Fmt.number(8100)) steps")
        let spo2 = try metric("spo2|apple", in: data)
        XCTAssertEqual(PeerWords.yours(spo2), "Your average \(Fmt.number(96.8, 1))% over 26 days")
        XCTAssertEqual(PeerWords.range(96.1, 97.4, spo2), "\(Fmt.number(96.1, 1))–\(Fmt.number(97.4, 1))%")
        // One day reads singular (a row that isn't ready can have one day of yours).
        let oneDay = PeerMetric(metric: "spo2", source: "apple", you: 96.8, yourDays: 1, status: "not_enough_days")
        XCTAssertEqual(PeerWords.yours(oneDay), "Your average \(Fmt.number(96.8, 1))% over 1 day")
        XCTAssertEqual(PeerWords.notEnoughDays(oneDay), "1 of 7 recorded days so far: your result appears after 7.")
        // Waiting and not enough days.
        XCTAssertEqual(PeerWords.waiting(try metric("hrv_rmssd|whoop", in: data)),
                       "Your average 61 ms over 12 days. Waiting for enough people in your age group to compare with.")
        XCTAssertEqual(PeerWords.waiting(try metric("resp_rate|whoop", in: data)),
                       "Your average \(Fmt.number(15.2, 1)) breaths/min over 9 days. Waiting for enough people in your age group to compare with.")
        // Without an average of your own (the type allows it), only the waiting words.
        let noAverage = PeerMetric(metric: "resp_rate", source: "whoop", you: nil, yourDays: 9, status: "gathering")
        XCTAssertNil(PeerWords.yours(noAverage))
        XCTAssertEqual(PeerWords.waiting(noAverage), "Waiting for enough people in your age group to compare with.")
        XCTAssertEqual(PeerWords.notEnoughDays(try metric("recovery|whoop", in: data)), "3 of 7 recorded days so far: your result appears after 7.")
        // The demo sample uses its metric's first pair; one the app doesn't know shows its id and no unit.
        let demo = PeerMetric(metric: "resp_rate", source: "demo", you: 14.8, yourDays: 30, status: "ready")
        XCTAssertEqual(PeerWords.heading(demo), "Respiratory rate · Sample")
        XCTAssertEqual(PeerWords.value(14.8, demo), "\(Fmt.number(14.8, 1)) breaths/min")
        let unknown = PeerMetric(metric: "vo2max", source: "apple", you: 41.6, yourDays: 9, status: "gathering")
        XCTAssertEqual(PeerWords.heading(unknown), "vo2max · Apple Health")
        XCTAssertEqual(PeerWords.value(41.6, unknown), "42")
    }

    func testHoursAndMinutesRoundTheMinutesFirst() {
        // src/lib.ts duration: Math.round(minutes), then hours and two-digit minutes; under an hour, minutes alone.
        XCTAssertEqual(PeerWords.hoursMinutes(7.5), "7h 30m")
        XCTAssertEqual(PeerWords.hoursMinutes(0.75), "45m")
        XCTAssertEqual(PeerWords.hoursMinutes(7.999), "8h 00m", "never 7h 60m")
        XCTAssertEqual(PeerWords.hoursMinutes(6.05), "6h 03m")
    }

    func testTheWindowsDatesAreTheDaysAsWritten() {
        // fmtDate reads a day as UTC midnight, so the window never moves a day with the phone's time zone.
        XCTAssertEqual(PeerWords.window(ageBand: "30–39", from: "2026-09-27", to: "2026-10-26"),
                       "Ages 30–39 · your averages for \(Fmt.day("2026-09-27")) – \(Fmt.day("2026-10-26"))")
        XCTAssertTrue(Fmt.day("2026-09-27").contains("27"))
    }

    // MARK: Where it shows

    func testOnlySignedInOnAServerThatNamesTheSwitch() throws {
        let withSwitch = try JSONDecoder().decode(ServerStatus.self, from: Data(#"{"settings":{"peerComparison":false,"perspective":"portrait"}}"#.utf8))
        let older = try JSONDecoder().decode(ServerStatus.self, from: fixture("status"))
        XCTAssertNil(older.settings?.peerComparison, "the fixture is from a server before comparisons")
        XCTAssertTrue(PeersSection.shown(phase: .ready, status: withSwitch))
        XCTAssertFalse(PeersSection.shown(phase: .ready, status: older), "an older server: nothing")
        XCTAssertFalse(PeersSection.shown(phase: .signIn, status: withSwitch), "never behind the sign-in screen")
        XCTAssertFalse(PeersSection.shown(phase: .ready, status: nil))
    }

    // MARK: Look

    func testTheBarsColoursAreProfileCss() throws {
        let css = try web("src/styles/profile.css")
        func value(_ name: String, in block: Substring) throws -> String {
            try XCTUnwrap(block.firstMatch(of: try Regex("--\(name): (#[0-9a-f]{6});"))?.output[1].substring.map(String.init), name)
        }
        let light = try XCTUnwrap(css.firstMatch(of: /:root \{[^}]*\}/)).output[...]
        let dark = try XCTUnwrap(css.firstMatch(of: /:root:not\(\[data-theme='light'\]\) \{[^}]*\}/)).output[...]
        for (name, token) in [("peer-track", PeerColors.trackValue), ("peer-band", PeerColors.bandValue), ("peer-you", PeerColors.youValue)] {
            XCTAssertEqual(try value(name, in: light), token.light.description, name)
            XCTAssertEqual(try value(name, in: dark), token.dark.description, name)
        }
    }

    func testYourQuarterIsLitAndTheMiddleHalfShaded() {
        XCTAssertEqual(PeerColors.quarter(.p25Median, yours: .p25Median), PeerColors.you)
        XCTAssertEqual(PeerColors.quarter(.medianP75, yours: .belowP25), PeerColors.band)
        XCTAssertEqual(PeerColors.quarter(.aboveP75, yours: .belowP25), PeerColors.track)
        XCTAssertEqual(PeerColors.quarter(.belowP25, yours: .aboveP75), PeerColors.track)
    }

    /// Each state draws, light and dark, at the default and the largest text size. With HOS_SNAPSHOTS set (xcodebuild's
    /// TEST_RUNNER_HOS_SNAPSHOTS), each is saved there as a PNG to look at; nothing is written otherwise.
    func testEachStateDraws() throws {
        let ready = try JSONDecoder().decode(PeerData.self, from: fixture("peers-ready"))
        let demo = try JSONDecoder().decode(PeerData.self, from: fixture("peers-demo"))
        let states: [(String, PeerData?, String?)] = [
            ("loading", nil, nil),
            ("error", nil, "Something went wrong"),
            ("off", PeerData(participating: false, reason: "off"), nil),
            ("no-age", PeerData(participating: false, reason: "no_age"), nil),
            ("under-age", PeerData(participating: false, reason: "under_age"), nil),
            ("no-accounts", PeerData(participating: false, reason: "no_accounts"), nil),
            ("no-readings", PeerData(participating: true, ageBand: "30–39", window: ready.window), nil),
            ("gathering", PeerData(participating: true, ageBand: "30–39", window: ready.window, metrics: ready.metrics.filter { $0.status != "ready" }), nil),
            ("ready", ready, nil),
            ("demo", demo, nil),
        ]
        for (name, data, error) in states {
            for scheme in [ColorScheme.light, .dark] {
                for size in [DynamicTypeSize.large, .accessibility5] {
                    let view = PeerContent(data: data, error: error)
                        .padding(18)
                        .frame(width: 343)
                        .background(Palette.page)
                        .environment(\.colorScheme, scheme)
                        .dynamicTypeSize(size)
                    let image = try XCTUnwrap(Snapshot.render(view, scale: size == .large ? 3 : 1.5), name)
                    XCTAssertGreaterThan(image.size.height, 20, name)
                    Snapshot.save(image, "peers-\(name)-\(scheme == .dark ? "dark" : "light")\(size == .large ? "" : "-ax5")")
                }
            }
        }
    }
}

/// Drawing a view to look at it: ImageRenderer at the screen's scale, saved only where HOS_SNAPSHOTS names a folder.
@MainActor
enum Snapshot {
    static func render<V: View>(_ view: V, scale: CGFloat = 3) -> UIImage? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        return renderer.uiImage
    }

    static func save(_ image: UIImage, _ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["HOS_SNAPSHOTS"], !dir.isEmpty else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? image.pngData()?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }
}
