import SwiftUI
import UIKit
import XCTest
@testable import HealthOSSync

// Home as the web's (slice B): the signal cards, the figure's callouts and the digital human, Today's nutrition, the
// health journal card, the optional cards, Edit widgets, the header, the banners and the tagline. Each checks its words
// and numbers against the web's own files (src/pages/Home.tsx, src/components/home/*, Figure.tsx, VitalCard.tsx,
// EditWidgets.tsx, App.tsx, styles.css), so the two can't drift apart. Slice B owns this file.

/// A file of the web app, next to the iPhone app in the repository.
private func web(_ path: String) throws -> String {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
}

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(json.utf8))
}

/// A summary from today's server, with every Home field: made-up numbers.
private let fullSummary = #"""
{"date":"2026-10-19","today":"2026-10-19","latestDataDate":"2026-10-19","name":"Sam","demo":false,"stepGoal":10000,
 "vitals":{"heart":{"label":"Resting heart","latest":{"date":"2026-10-19","value":58,"source":"apple"},"status":"high","level":"off"},
           "breathing":{"label":"Breathing","latest":{"date":"2026-10-17","value":14.6,"source":"apple"},"status":"normal","level":"normal"},
           "temp":{"label":"Wrist temp","latest":{"date":"2026-10-19","value":36.1,"source":"apple"},"status":"normal","level":"normal"},
           "spo2":{"label":"Blood oxygen","latest":{"date":"2026-10-19","value":96.5,"source":"apple"},"status":"low","level":"unusual"}},
 "readiness":{"kind":"recovery","latest":{"date":"2026-10-19","value":72,"source":"whoop"},"average":67,"zone":"green"},
 "spo2":{"latest":{"date":"2026-10-19","value":96.5,"source":"apple"},"series":[{"date":"2026-10-18","value":97},{"date":"2026-10-19","value":96.5}],"status":"low"},
 "hrv":{"metric":"hrv_sdnn","latest":{"date":"2026-10-18","value":48,"source":"apple"},"series":[{"date":"2026-10-17","value":45},{"date":"2026-10-18","value":48}],"baseline":46,"status":"optimal"},
 "sleep":{"latest":{"date":"2026-10-19","value":6.4,"source":"apple"},"series":[{"date":"2026-10-18","value":7.1},{"date":"2026-10-19","value":6.4}],"change":-0.052},
 "load":{"kind":"energy","latest":{"date":"2026-10-19","value":420,"source":"apple"},"average":500,"series":[]},
 "activity":{"latest":{"date":"2026-10-19","value":8200,"source":"apple"},"series":[{"date":"2026-10-19","value":8200}]},
 "restingHr":{"latest":{"date":"2026-10-19","value":58,"source":"apple"},"series":[{"date":"2026-10-18","value":55},{"date":"2026-10-19","value":58}]},
 "respRate":{"latest":{"date":"2026-10-17","value":14.6,"source":"apple"},"series":[{"date":"2026-10-17","value":14.6}]},
 "timeline":{"date":"2026-10-19","events":[]},"insights":[]}
"""#

/// The same day from a server before resting heart rate, respiratory rate and the blood oxygen callout, and an Apple-only
/// person (VO₂ max, not recovery).
private let olderSummary = #"""
{"date":"2026-10-19","today":"2026-10-19","name":null,
 "vitals":{"heart":{"label":"Resting heart","latest":{"date":"2026-10-19","value":61,"source":"apple"},"status":"normal"},
           "breathing":{"label":"Breathing","latest":{"date":"2026-10-19","value":15,"source":"apple"},"status":null}},
 "readiness":{"kind":"vo2max","latest":{"date":"2026-10-12","value":41.2,"source":"apple"},"previous":40.1},
 "spo2":{"latest":null,"series":[],"status":null},
 "hrv":{"metric":"hrv_rmssd","latest":{"date":"2026-10-19","value":62,"source":"whoop"},"series":[],"baseline":null,"status":null},
 "sleep":{"latest":null,"series":[],"change":null},"load":null,"activity":{"latest":null,"series":[]},
 "timeline":{"date":"2026-10-19","events":[]},"insights":[]}
"""#

// MARK: - Signal cards

final class HomeSignalCardTests: XCTestCase {
    func testEachCardIsTheWebsTitleToneUnitAndSheet() throws {
        let s = try decode(Summary.self, fullSummary)
        let signals = Signal.ids.compactMap { Signal.of($0, s) }
        XCTAssertEqual(signals.map(\.id), ["home.rhr", "home.spo2", "home.hrv", "home.sleep", "home.readiness", "home.resp"])
        XCTAssertEqual(signals.map(\.title), ["Resting heart rate", "Blood oxygen", "HRV", "Sleep", "Recovery", "Respiratory rate"])
        XCTAssertEqual(signals.map(\.unit), ["bpm", "%", "ms", "hours", "%", "breaths/min"])
        XCTAssertEqual(signals.map(\.tint), [.green, .peach, .blue, .lavender, .pink, .mint])
        XCTAssertEqual(signals.map(\.metric), [.restingHr, .spo2, .hrv, .sleepHours, .recovery, .respRate])
        // Sleep's sheet says "Open Sleep"; the rest "Open Vitals".
        XCTAssertEqual(signals.map(\.page.page), [.vitals, .vitals, .vitals, .sleep, .vitals, .vitals])

        // Each of those is in Signals.tsx, as the web writes it.
        let tsx = try web("src/components/home/Signals.tsx")
        for signal in signals {
            XCTAssertTrue(tsx.contains("title=\"\(signal.title)\""), signal.title)
            XCTAssertTrue(tsx.contains("unit=\"\(signal.unit)\""), signal.unit)
            XCTAssertTrue(tsx.contains("metric=\"\(signal.metric.rawValue)\""), signal.metric.rawValue)
        }
        for tone in ["green", "peach", "blue", "lavender", "pink", "mint"] { XCTAssertTrue(tsx.contains("tone=\"\(tone)\""), tone) }
    }

    func testTheReadingsTheirWordsChartsAndFeet() throws {
        let s = try decode(Summary.self, fullSummary)
        let rhr = Signal.restingHr(s)
        XCTAssertEqual(rhr.value, "58")
        XCTAssertEqual(rhr.status, SignalStatus(words: "Well above usual", level: .off))
        XCTAssertEqual(rhr.footLeft, "Last 30 days")
        XCTAssertEqual(rhr.spoken, "Resting heart rate, 58 beats per minute, Well above usual")

        let spo2 = Signal.spo2(s)
        XCTAssertEqual(spo2.value, "96.5", "a decimal only when there is one")
        XCTAssertEqual(spo2.status?.words, "Below your range")
        XCTAssertNil(spo2.status?.level)
        XCTAssertEqual(spo2.footLeft, "90")
        XCTAssertEqual(spo2.footRight, "100")
        XCTAssertEqual(spo2.chart, .spo2(s.spo2?.series ?? [], value: 96.5))

        let hrv = Signal.hrv(s)
        XCTAssertEqual(hrv.status, SignalStatus(words: "Optimal", stale: Fmt.day("2026-10-18")), "an older reading keeps its date")
        XCTAssertEqual(hrv.footLeft, "usual · SDNN")
        XCTAssertTrue(hrv.swatch)

        let sleep = Signal.sleep(s)
        XCTAssertEqual(sleep.value, "6.4")
        XCTAssertEqual(sleep.status?.words, "Fair")
        XCTAssertEqual(sleep.footLeft, "Last 14 nights")
        XCTAssertEqual(sleep.footRight, "−5% wk")

        let recovery = Signal.recovery(s)
        XCTAssertEqual(recovery.value, "72")
        XCTAssertEqual(recovery.status, SignalStatus(words: "High", level: .normal, zone: true))
        XCTAssertEqual(recovery.footLeft, "+5 vs 30-day avg")
        XCTAssertEqual(recovery.chart, .recovery(72))

        let resp = Signal.respRate(s)
        XCTAssertEqual(resp.value, "14.6")
        XCTAssertEqual(resp.status, SignalStatus(words: "Normal", level: .normal, stale: Fmt.day("2026-10-17")))
        XCTAssertEqual(resp.chart, .none, "one day isn't a line")
        XCTAssertNil(resp.footLeft)

        // VoiceOver reads the feet that say something of their own, in words; the chart's captions go with the chart.
        XCTAssertEqual(hrv.spoken, "HRV, 48 milliseconds, Optimal, \(Fmt.day("2026-10-18")), Apple Watch measures SDNN")
        XCTAssertEqual(sleep.spoken, "Sleep, 6.4 hours, Fair, This week's average 5% below last week's")
        XCTAssertEqual(recovery.spoken, "Recovery, 72 percent, High, 5 above the 30-day average")
        XCTAssertEqual(spo2.spoken, "Blood oxygen, 96.5 percent, Below your range", "90 and 100 are the chart's")
        XCTAssertEqual(Signal.spokenChange(-0.4), nil, "a change that shows as 0")
        XCTAssertEqual(Signal.spokenChange(3.6, unit: "%"), "4% above")

        let tsx = try web("src/components/home/Signals.tsx")
        for title in ["This week's average vs last week's", "WHOOP and Fitbit measure RMSSD during sleep", "Apple Watch measures SDNN"] {
            XCTAssertTrue(tsx.contains(title), title)
        }
        for words in ["Last 30 days", "Last 14 nights", "Below your range", "Building baseline", "vs 30-day avg", "% wk", "usual · ",
                      "Well above usual", "Well below usual", "Above usual", "Below usual", "Optimal", "Below baseline", "Moderate", "'Good'", "'Fair'", "'Short'"] {
            XCTAssertTrue(tsx.contains(words), words)
        }
    }

    func testAnOlderServerFallsBackToTheVitalsWithNoChartAndRecoveryIsWhoopsOnly() throws {
        let s = try decode(Summary.self, olderSummary)
        let rhr = Signal.restingHr(s)
        XCTAssertEqual(rhr.value, "61", "the resting heart vital, without restingHr")
        XCTAssertEqual(rhr.chart, .none)
        XCTAssertNil(rhr.footLeft)
        XCTAssertEqual(rhr.status, SignalStatus(words: "Normal", level: .normal), "servers before levels: the status says it")
        let resp = Signal.respRate(s)
        XCTAssertEqual(resp.value, "15.0")
        XCTAssertEqual(resp.status, SignalStatus(words: "Building baseline", level: nil))
        // VO₂ max is Body's: an Apple-only person's Recovery is the empty card.
        XCTAssertNil(Signal.recovery(s).value)
        XCTAssertEqual(Signal.recovery(s).spoken, "Recovery, no reading yet")
        XCTAssertNil(Signal.spo2(s).value)
        XCTAssertNil(Signal.sleep(s).value)
        XCTAssertEqual(Signal.hrv(s).footLeft, "usual · RMSSD")
        XCTAssertEqual(Signal.hrv(s).status?.words, "Building baseline")
    }

    func testCompactCardsKeepTheValueAndStatusOnly() throws {
        let s = try decode(Summary.self, fullSummary)
        for id in Signal.ids {
            let compact = try XCTUnwrap(Signal.of(id, s, variant: .compact))
            let home = try XCTUnwrap(Signal.of(id, s))
            XCTAssertEqual(compact.value, home.value, id)
            XCTAssertEqual(compact.status, home.status, id)
            XCTAssertEqual(compact.chart, .none, id)
            XCTAssertNil(compact.footRight, id)
            // HRV still says which it measures, without the band's key.
            XCTAssertEqual(compact.footLeft, id == "home.hrv" ? "SDNN" : nil, id)
            XCTAssertFalse(compact.swatch)
        }
    }

    func testTheEmptyCardsWordsAndSizesAreVitalCards() throws {
        let tsx = try web("src/components/VitalCard.tsx")
        for words in ["Connect a source to get started", "No reading yet", "Awaiting data", "Connect"] { XCTAssertTrue(tsx.contains(words), words) }
        // .vital-home is 1.55:1 at least 210 tall, and 236 with a reading on Home; .vital-compact 3.6:1, at least 176.
        let css = try web("src/styles.css"), home = try web("src/styles/home.css")
        XCTAssertTrue(css.contains("aspect-ratio: 1.55;\n  min-height: 210px;"))
        XCTAssertTrue(css.contains("aspect-ratio: 3.6;\n  min-height: 176px;"))
        XCTAssertTrue(home.contains("min-height: 236px;"))
        XCTAssertEqual(SignalCard.minHeight(.home, empty: true, width: 343), 343 / 1.55, accuracy: 0.001)
        XCTAssertEqual(SignalCard.minHeight(.home, empty: true, width: 300), 210)
        XCTAssertEqual(SignalCard.minHeight(.home, empty: false, width: 343), 236)
        XCTAssertEqual(SignalCard.minHeight(.compact, empty: true, width: 343), 176)
        XCTAssertEqual(SignalCard.minHeight(.compact, empty: false, width: 800), 800 / 3.6, accuracy: 0.001)
    }

    func testTheMiniChartsAreTheWebs() {
        let points = [Point(date: "a", value: 10), Point(date: "b", value: 20), Point(date: "c", value: 15)]
        // 6pt in from every edge; the domain clamps.
        let places = SignalLine.places(points, size: CGSize(width: 112, height: 52), domain: nil)
        XCTAssertEqual(places.map(\.x), [6, 56, 106])
        XCTAssertEqual(places.map(\.y), [46, 6, 26])
        XCTAssertEqual(SignalLine.places([Point(date: "a", value: 88)], size: CGSize(width: 100, height: 44), domain: 90...100), [CGPoint(x: 50, y: 38)])
        // HRV's band: the mean of the nights before the latest (or the baseline), ± their standard deviation.
        let dots = SignalDots.scale(points, baseline: nil)
        XCTAssertEqual(dots?.mean, 15)
        XCTAssertEqual(dots?.sd ?? 0, (50.0).squareRoot(), accuracy: 1e-9)
        XCTAssertEqual(SignalDots.scale(points, baseline: 12)?.mean, 12)
        XCTAssertNil(SignalDots.scale([], baseline: nil))
        XCTAssertEqual(RangeScale.position(95, in: 90...100), 0.5)
        XCTAssertEqual(RangeScale.position(80, in: 90...100), 0)
        // Recovery's rings: 0 at the lower left of the outer ring, 100 at the lower right.
        XCTAssertEqual(SignalRings.dot(0).x, 60 + 56 * cos(.pi * 0.75), accuracy: 1e-9)
        XCTAssertEqual(SignalRings.dot(1).x, 60 + 56 * cos(-.pi * 0.75), accuracy: 1e-9)
        // A monotone line: a flat stretch stays flat.
        let flat = SmoothPath.path([CGPoint(x: 0, y: 10), CGPoint(x: 10, y: 10), CGPoint(x: 20, y: 30)])
        XCTAssertEqual(flat.boundingRect.minY, 10, accuracy: 1e-9)
    }

    @MainActor func testACardWithAMinimumHeightPushesItsFootToTheBottom() {
        let layout = CardMinHeight(min: 200)
        let view = layout { VStack(spacing: 0) { Color.red.frame(height: 20); Spacer(minLength: 0); Color.blue.frame(height: 10) } }
        let size = UIHostingController(rootView: view).sizeThatFits(in: CGSize(width: 300, height: CGFloat.greatestFiniteMagnitude))
        XCTAssertEqual(size.height, 200)
        let tall = UIHostingController(rootView: layout { Color.red.frame(height: 260) }).sizeThatFits(in: CGSize(width: 300, height: CGFloat.greatestFiniteMagnitude))
        XCTAssertEqual(tall.height, 260, "content taller than the minimum grows the card")
    }
}

// MARK: - The figure

final class HomeFigureCalloutTests: XCTestCase {
    private let today = "2026-10-19"

    func testHomesCalloutsAndTheirWords() throws {
        let s = try decode(Summary.self, fullSummary)
        let heart = CalloutText.of(.heart, vitals: s.vitals, asOf: today)
        XCTAssertEqual([heart.name, heart.value, heart.unit, heart.status], ["Heart", "58", "bpm", "Well above usual"])
        XCTAssertEqual(heart.level, .off)
        let breathing = CalloutText.of(.breathing, vitals: s.vitals, asOf: today)
        XCTAssertEqual([breathing.name, breathing.value, breathing.unit], ["Breathing", "14.6", "/min"])
        XCTAssertEqual(breathing.level, .neutral, "an older reading never alarms today's figure")
        XCTAssertNil(breathing.statusLevel)
        XCTAssertEqual(breathing.status, "Normal · \(Fmt.day("2026-10-17"))")
        let spo2 = CalloutText.of(.spo2, vitals: s.vitals, asOf: today)
        XCTAssertEqual([spo2.name, spo2.value, spo2.unit], ["Blood oxygen", "96.5", "%"])
        XCTAssertEqual(spo2.spoken, "Blood oxygen, 96.5 percent, Below usual")
        XCTAssertNil(spo2.rate, "blood oxygen doesn't move")
        XCTAssertEqual(CalloutText.of(.temp, vitals: s.vitals, asOf: today, units: .imperial).unit, "°F")
        // Home's set (Home.tsx): blood oxygen, breathing and heart.
        XCTAssertTrue(try web("src/pages/Home.tsx").contains("callouts={['spo2', 'breathing', 'heart']}"))
        XCTAssertEqual(CalloutKey.home, [.spo2, .breathing, .heart])
    }

    func testAServerBeforeTheBloodOxygenCalloutShowsADashWithItsUnit() throws {
        let s = try decode(Summary.self, olderSummary)
        let spo2 = CalloutText.of(.spo2, vitals: s.vitals, asOf: today)
        XCTAssertEqual(spo2.name, "Blood oxygen")
        XCTAssertNil(spo2.value)
        XCTAssertEqual(spo2.unit, "%")
        XCTAssertNil(spo2.status, "nothing to compare without a reading")
        XCTAssertEqual(spo2.level, .neutral)
        XCTAssertEqual(spo2.spoken, "Blood oxygen, no reading")
        // A breathing reading with no baseline yet.
        XCTAssertEqual(CalloutText.of(.breathing, vitals: s.vitals, asOf: today).status, "Building baseline")
    }

    func testANeutralDotIsTheFiguresGold() throws {
        // styles.css: --level-none: var(--callout-dot).
        XCTAssertTrue(try web("src/styles.css").contains("--level-none: var(--callout-dot);"))
        XCTAssertEqual(VitalLevel.neutral.color, Palette.calloutDot)
        XCTAssertEqual(VitalLevel.normal.color, Palette.good)
        XCTAssertEqual(VitalLevel.unusual.color, Palette.warning)
        XCTAssertEqual(VitalLevel.off.color, Palette.critical)
    }

    func testTheDotsMoveAsTheWebsKeyframes() throws {
        let css = try web("src/styles.css")
        // vital-beat's keyframes.
        for frame in ["10% {\n    transform: scale(1.42);", "20% {\n    transform: scale(1.04);", "29% {\n    transform: scale(1.24);"] {
            XCTAssertTrue(css.contains(frame), frame)
        }
        XCTAssertEqual(CalloutMotion.beat(0), 1)
        XCTAssertEqual(CalloutMotion.beat(0.10), 1.42, accuracy: 1e-9)
        XCTAssertEqual(CalloutMotion.beat(0.20), 1.04, accuracy: 1e-9)
        XCTAssertEqual(CalloutMotion.beat(0.29), 1.24, accuracy: 1e-9)
        XCTAssertEqual(CalloutMotion.beat(0.6), 1)
        // The ring: seen at 8%, gone by 72%, grown to 2.1.
        XCTAssertTrue(css.contains("8% {\n    opacity: 0.75;"))
        XCTAssertEqual(CalloutMotion.ring(0.08).opacity, 0.75, accuracy: 1e-9)
        XCTAssertEqual(CalloutMotion.ring(0.8).opacity, 0)
        XCTAssertEqual(CalloutMotion.ring(0).scale, 0.45, accuracy: 1e-9)
        // Breathing in for 40%: 0.78 to 1.25.
        XCTAssertTrue(css.contains("transform: scale(0.78);") && css.contains("transform: scale(1.25);"))
        XCTAssertEqual(CalloutMotion.breathe(0).scale, 0.78, accuracy: 1e-9)
        XCTAssertEqual(CalloutMotion.breathe(0.4).scale, 1.25, accuracy: 1e-9)
        XCTAssertEqual(CalloutMotion.breathe(0.4).opacity, 1, accuracy: 1e-9)
        // Temperature's 6 s glow.
        XCTAssertTrue(css.contains("animation: vital-warmth 6s ease-in-out infinite;"))
        XCTAssertEqual(CalloutMotion.warmth(0.5).scale, 1.08, accuracy: 1e-9)
        XCTAssertEqual(CalloutMotion.phase(7, period: 6), 1.0 / 6, accuracy: 1e-9)
    }

    func testTheDigitalHumansPlacesAreFigureTsxs() throws {
        let tsx = try web("src/components/Figure.tsx")
        let man = DigitalArt.man
        XCTAssertTrue(tsx.contains("width: 640,\n  height: 600,"))
        XCTAssertEqual(man.width, 640)
        XCTAssertEqual(man.height, 600)
        func row(_ key: String, _ s: DigitalArt.Spot) -> String {
            func p(_ v: CGPoint) -> String { "[\(Self.js(v.x)), \(Self.js(v.y))]" }
            return "\(key): { dot: \(p(s.dot)), label: \(p(s.label)), line: \(p(s.line)), side: '\(s.left ? "left" : "right")' },"
        }
        for (key, spot) in [("spo2", man.spots[.spo2]!), ("breathing", man.spots[.breathing]!), ("heart", man.spots[.heart]!),
                            ("temp", man.spots[.temp]!), ("wrist", man.wrist)] {
            XCTAssertTrue(tsx.contains(row(key, spot)), row(key, spot))
        }
        XCTAssertEqual(man.asset, "DigitalMan")
        XCTAssertNotNil(UIImage(named: "DigitalMan"))
        XCTAssertNotNil(UIImage(named: "JournalGut"))
    }

    /// A number as Figure.tsx writes it: 0.0 is "0.0", others without trailing zeros.
    private static func js(_ v: CGFloat) -> String {
        if v == 0 { return "0.0" }
        var s = String(format: "%.4f", Double(v))
        while s.hasSuffix("0") { s.removeLast() }
        return s
    }

    func testDigitalLabelsMoveDownBelowTheOneAboveAndLeftToStayInside() {
        let man = DigitalArt.man
        let width: CGFloat = 343, height = width * 600 / 640
        let sizes: [CalloutKey: CGSize] = [.spo2: CGSize(width: 80, height: 50), .heart: CGSize(width: 70, height: 50), .breathing: CGSize(width: 76, height: 50)]
        let nudge = man.nudges(CalloutKey.home, sizes: sizes, width: width, wrist: false)
        // Heart's label starts at 28% down; blood oxygen's, at 16.3%, is 50 tall: heart moves to 6pt below it.
        XCTAssertEqual(nudge[.spo2]?.dy, 0)
        XCTAssertEqual(nudge[.heart]?.dy ?? 0, 0.163 * height + 50 + 6 - 0.28 * height, accuracy: 1e-9)
        // Breathing's label starts at 92% across: moved left so its right edge is the figure's.
        XCTAssertEqual(nudge[.breathing]?.dx ?? 0, width - (0.92 * width + 76), accuracy: 1e-9)
        XCTAssertEqual(nudge[.spo2]?.dx, 0)
        // A label not measured yet isn't moved.
        XCTAssertNil(man.nudges(CalloutKey.home, sizes: [:], width: width, wrist: false)[.heart])
        // A watch's temperature goes at the wrist.
        XCTAssertEqual(man.spot(.temp, wrist: true), man.wrist)
        XCTAssertTrue(CalloutText.atWrist(try? decode(Summary.self, fullSummary).vitals))
    }

    func testReduceMotionHoldsEveryDotStill() throws {
        let s = try decode(Summary.self, fullSummary)
        let heart = CalloutText.of(.heart, vitals: s.vitals, asOf: today)
        let breathing = CalloutText.of(.breathing, vitals: s.vitals, asOf: today)
        let temp = CalloutText.of(.temp, vitals: s.vitals, asOf: today)
        let spo2 = CalloutText.of(.spo2, vitals: s.vitals, asOf: today)
        XCTAssertEqual([heart, breathing, temp, spo2].map { CalloutMark.moves($0, reduceMotion: false) }, [true, true, true, false],
                       "the heart beats, breathing breathes, temperature glows; blood oxygen doesn't move")
        XCTAssertEqual([heart, breathing, temp, spo2].map { CalloutMark.moves($0, reduceMotion: true) }, [false, false, false, false])
        let none = CalloutText.of(.heart, vitals: nil, asOf: today)
        XCTAssertFalse(CalloutMark.moves(none, reduceMotion: false), "no reading, nothing to move at")
    }

    func testWhichFigureShows() throws {
        let photo = try decode(PhotoMeta.self, #"{"version":3,"width":900,"height":1200,"face":[0.38,0.06,0.24,0.24],"shoulderY":0.36,"dots":{"temp":[0.5,0.1],"breathing":[0.5,0.3],"heart":[0.56,0.45]}}"#)
        let noDots = try decode(PhotoMeta.self, #"{"version":3,"width":900,"height":1200,"face":[0.38,0.06,0.24,0.24]}"#)
        XCTAssertEqual(HomeFigure.shown(.stats, photo: photo, failed: nil), .none)
        XCTAssertEqual(HomeFigure.shown(.digital, photo: photo, failed: nil), .digital)
        XCTAssertEqual(HomeFigure.shown(.portrait, photo: nil, failed: nil), .digital, "no photo yet")
        XCTAssertEqual(HomeFigure.shown(.portrait, photo: photo, failed: nil), .portrait)
        XCTAssertEqual(HomeFigure.shown(.portrait, photo: noDots, failed: nil), .digital, "metadata without the dots, without trying the image")
        XCTAssertEqual(HomeFigure.shown(.portrait, photo: photo, failed: 3), .digital, "while its cut-out can't be loaded")
        XCTAssertEqual(HomeFigure.shown(.portrait, photo: photo, failed: 2), .portrait, "an older photo's failure says nothing of a new one")
    }

    func testThePerspectiveDecidesTheFigure() throws {
        func settings(_ perspective: String?) throws -> ServerStatus.Settings {
            try decode(ServerStatus.Settings.self, perspective.map { #"{"perspective":"\#($0)"}"# } ?? "{}")
        }
        XCTAssertEqual(Perspective.of(try settings("portrait")), .portrait)
        XCTAssertEqual(Perspective.of(try settings("digital")), .digital)
        XCTAssertEqual(Perspective.of(try settings("stats")), .stats)
        XCTAssertEqual(Perspective.of(try settings(nil)), .portrait, "servers before onboarding read as the portrait")
        XCTAssertEqual(Perspective.of(try settings("hologram")), .portrait)
        XCTAssertEqual(Perspective.of(nil), .portrait)
    }

    func testThePortraitNoteSaysWhatsTrueForThisServer() throws {
        let tsx = try web("src/pages/Home.tsx")
        XCTAssertTrue(tsx.contains(ServerWords.homePortraitNotHere))
        XCTAssertTrue(tsx.contains("Your portrait appears here once it's made."))
        XCTAssertTrue(tsx.contains("'Connect an OpenAI key and add' : 'Add'"))
        XCTAssertTrue(tsx.contains(PortraitNote.link))
        // "Not on this server" only when both are known missing; unknown is the plain invitation.
        XCTAssertEqual(PortraitNote.words(byok: false, portraits: false).text, ServerWords.homePortraitNotHere)
        XCTAssertFalse(PortraitNote.words(byok: false, portraits: false).link)
        XCTAssertEqual(PortraitNote.words(byok: true, portraits: false).text, "Your portrait appears here once it's made. Connect an OpenAI key and add photos in ")
        XCTAssertEqual(PortraitNote.words(byok: nil, portraits: nil).text, "Your portrait appears here once it's made. Add photos in ")
        XCTAssertEqual(PortraitNote.words(byok: true, portraits: true).text, "Your portrait appears here once it's made. Add photos in ")
        XCTAssertTrue(PortraitNote.words(byok: nil, portraits: nil).link)
    }
}

// MARK: - Today's nutrition

final class HomeNutritionCardTests: XCTestCase {
    private typealias N = TodayNutritionCard

    private func entry(_ time: String, _ name: String, date: String = "2026-10-19", kcal: Double? = nil) throws -> FoodEntry {
        let values = kcal.map { #"{"energy_kcal":\#($0),"protein_g":10}"# } ?? "{}"
        return try decode(FoodEntry.self, #"{"id":"\#(time)","date":"\#(date)","time":"\#(time)","name":"\#(name)","portion":"1","quantity":1,"values":\#(values),"method":"quick","ref":null,"version":1,"origin":"web"}"#)
    }

    func testTheTrackIsTheWebs() throws {
        let tsx = try web("src/components/home/TodayNutrition.tsx")
        XCTAssertTrue(tsx.contains("const START = 6 * 60;"))
        XCTAssertTrue(tsx.contains("const SEGMENT = \(N.segment);"))
        XCTAssertTrue(tsx.contains("const SEGMENTS = \(N.segments);"))
        XCTAssertTrue(tsx.contains("const LOG_DAYS = \(N.logDays);"))
        XCTAssertTrue(tsx.contains("const TICKS = [\(N.ticks.map { "'\($0)'" }.joined(separator: ", "))];"))
        XCTAssertEqual(N.start, 360)
        // Before 6:00 counts as the first segment, after 21:00 as the last.
        XCTAssertEqual(N.segment(of: "05:10"), 0)
        XCTAssertEqual(N.segment(of: "07:14"), 0)
        XCTAssertEqual(N.segment(of: "07:15"), 1)
        XCTAssertEqual(N.segment(of: "20:59"), 11)
        XCTAssertEqual(N.segment(of: "23:30"), 11)
        XCTAssertEqual(N.part(of: "10:59"), .morning)
        XCTAssertEqual(N.part(of: "11:00"), .midday)
        XCTAssertEqual(N.part(of: "15:00"), .evening)
        XCTAssertEqual(N.listTimes(["08:10"]), "08:10")
        XCTAssertEqual(N.listTimes(["08:10", "12:30"]), "08:10 and 12:30")
        XCTAssertEqual(N.listTimes(["08:10", "12:30", "19:00"]), "08:10, 12:30 and 19:00")
        // The tints, light and dark (home.css).
        let css = try web("src/styles/home.css")
        for hex in ["#b6d4a4", "#b3c0ee", "#f0c391", "#5f8a52", "#5c69a6", "#a8763f", "rgba(28, 37, 32, 0.07)"] { XCTAssertTrue(css.contains(hex), hex) }
    }

    func testADayWithEntries() throws {
        let entries = [try entry("08:10", "Oatmeal", kcal: 300), try entry("08:40", "Coffee", kcal: 5), try entry("19:05", "Pasta", kcal: 700),
                       try entry("12:00", "Yesterday's", date: "2026-10-18", kcal: 400)]
        let all = N.Model(entries: entries, date: "2026-10-19", today: "2026-10-19", mode: .all)
        XCTAssertEqual(all.title, "Today's nutrition")
        XCTAssertEqual(all.count, 3, "only the day shown")
        XCTAssertEqual(all.kcal, 1005)
        XCTAssertEqual(all.latest, "Latest: Pasta, 19:05")
        XCTAssertNil(all.empty)
        XCTAssertEqual(all.segments[1], .morning, "08:10, in the 7:15–8:30 segment")
        XCTAssertEqual(all.segments[2], .morning, "08:40")
        XCTAssertEqual(all.segments[10], .evening, "19:05")
        XCTAssertEqual(all.segments.compactMap { $0 }.count, 3, "a tint only where something was logged")
        XCTAssertEqual(all.spoken, "3 entries today, at 08:10, 08:40 and 19:05")
        // Energy only for people who chose to see it.
        XCTAssertEqual(N.Model(entries: entries, date: "2026-10-19", today: "2026-10-19", mode: .noEnergy).kcal, 0)
        XCTAssertEqual(N.Model(entries: entries, date: "2026-10-19", today: "2026-10-19", mode: .none).kcal, 0)
        // A past day.
        let past = N.Model(entries: entries, date: "2026-10-18", today: "2026-10-19", mode: .all)
        XCTAssertEqual(past.title, "Nutrition · \(Fmt.day("2026-10-18", "EEEMMMd"))")
        XCTAssertEqual(past.spoken, "1 entry that day, at 12:00")
        let tsx = try web("src/components/home/TodayNutrition.tsx")
        for words in ["Today's nutrition", "Nutrition · ", "Latest: ", "'entry' : 'entries'", " kcal", "'today' : 'that day'"] { XCTAssertTrue(tsx.contains(words), words) }
    }

    func testTheThreeEmptyDays() throws {
        let fresh = N.Model(entries: [], date: "2026-10-19", today: "2026-10-19", mode: .all)
        XCTAssertEqual(fresh.empty?.title, "A fresh start")
        XCTAssertEqual(fresh.empty?.text, "Log your first meal to see your day take shape.")
        XCTAssertEqual(fresh.spoken, "Nothing logged yet today")
        let none = N.Model(entries: [], date: "2026-10-12", today: "2026-10-19", mode: .all)
        XCTAssertEqual(none.empty?.title, "Nothing logged that day")
        XCTAssertEqual(none.empty?.text, "Meals you log appear here at the time you had them.")
        let old = N.Model(entries: [], date: "2026-09-01", today: "2026-10-19", mode: .all)
        XCTAssertEqual(old.empty?.title, "Older than a month")
        XCTAssertEqual(old.empty?.text, "Home shows the last 31 days of your food log.")
        // Nutrition off: today's invitation whatever the day, and nothing asked for.
        let off = N.Model(entries: [], date: "2026-09-01", today: "2026-10-19", mode: nil)
        XCTAssertEqual(off.title, "Today's nutrition")
        XCTAssertEqual(off.empty?.title, "A fresh start")
        XCTAssertEqual(N.daysBack(date: "2026-09-01", today: "2026-10-19", on: false), 0)
        XCTAssertEqual(N.daysBack(date: "2026-10-17", today: "2026-10-19", on: true), 2)
        let tsx = try web("src/components/home/TodayNutrition.tsx")
        for m in [fresh, none, old] {
            XCTAssertTrue(tsx.contains(m.empty!.title), m.empty!.title)
            XCTAssertTrue(tsx.contains(m.empty!.text), m.empty!.text)
        }
        XCTAssertTrue(tsx.contains("'Nothing logged yet today'"))
        XCTAssertTrue(tsx.contains("'#/nutrition?compose=1'"), "the orb opens the composer")
        XCTAssertTrue(tsx.contains("'Log food' : 'Open Nutrition'"))
    }
}

// MARK: - The journal, food totals, the optional cards

final class HomeOtherCardsTests: XCTestCase {
    func testTheJournalCardsWords() throws {
        let tsx = try web("src/components/home/JournalPrompt.tsx")
        for words in ["Your health journal", "How are you feeling today?", "A thought, a feeling, a little context.", "Write a check-in", "Add another",
                      "A check-in at ", "'#/journal?new=1'", "/journal?days=1"] {
            XCTAssertTrue(tsx.contains(words), words)
        }
        let data = try decode(JournalData.self, #"""
        {"today":"2026-10-19","entries":[
          {"id":"b","date":"2026-10-19","time":"18:30","mood":4,"text":"\n  Slept well, long walk.\nMore later","createdAt":2},
          {"id":"a","date":"2026-10-19","time":"08:10","mood":null,"text":"","createdAt":1},
          {"id":"c","date":"2026-10-18","time":"09:00","mood":2,"text":"Yesterday","createdAt":0}]}
        """#)
        let m = JournalPromptCard.Model(data)
        XCTAssertEqual(m.mood, "Good")
        XCTAssertEqual(m.line, "Slept well, long walk.", "the first line with words")
        XCTAssertEqual(m.button, "Add another")
        let quiet = JournalPromptCard.Model(latest: data.entries[1])
        XCTAssertNil(quiet.mood)
        XCTAssertEqual(quiet.line, "A check-in at 08:10")
        let none = JournalPromptCard.Model(nil)
        XCTAssertNil(none.line)
        XCTAssertEqual(none.button, "Write a check-in")
        // Only today's: yesterday's check-in isn't today's.
        XCTAssertEqual(JournalPromptCard.Model(try decode(JournalData.self, #"{"today":"2026-10-19","entries":[{"id":"c","date":"2026-10-18","time":"09:00","mood":2,"text":"Yesterday"}]}"#)).button, "Write a check-in")
    }

    func testFoodTotalsAreTheLatestDaysFirstFive() throws {
        let data = try decode(NutritionData.self, #"""
        {"enabled":true,"numbers":"all","today":"2026-10-19","start":"2026-10-13","end":"2026-10-19","apps":["MyFitnessPal"],"app":null,
         "days":[{"date":"2026-10-15","app":"Cronometer","values":{"energy_kcal":1800}},
                 {"date":"2026-10-18","app":"MyFitnessPal","values":{"energy_kcal":2100,"protein_g":90,"carbs_g":240,"fat_g":70,"fiber_g":30,"sugar_g":40,"sat_fat_g":20,"sodium_mg":2100}}]}
        """#)
        let m = FoodTotalsCard.Model(data)
        XCTAssertEqual(m.latest?.date, "2026-10-18")
        XCTAssertEqual(m.shown, ["energy_kcal", "protein_g", "carbs_g", "fat_g", "fiber_g"], "five, without saturated fat and sodium")
        XCTAssertEqual(m.days.map(\.logged), [false, false, true, false, false, true, false])
        XCTAssertEqual(m.note, "Yesterday · MyFitnessPal")
        let empty = FoodTotalsCard.Model(try decode(NutritionData.self, #"{"enabled":true,"numbers":"none","today":"2026-10-19","start":"2026-10-13","end":"2026-10-19","days":[]}"#))
        XCTAssertNil(empty.latest)
        XCTAssertEqual(empty.note, "Last 7 days")
        let tsx = try web("src/pages/Nutrition.tsx")
        for words in ["Nothing logged in the last 7 days.", "Logged in {latest.app}", "'Last 7 days'", "n !== 'sat_fat_g' && n !== 'sodium_mg').slice(0, 5)", "/nutrition?days=7"] {
            XCTAssertTrue(tsx.contains(words), words)
        }
    }

    func testTheOptionalCardsWords() throws {
        let tsx = try web("src/pages/Home.tsx")
        func load(_ kind: String, _ value: Double, _ average: Double?) throws -> Summary.Load {
            try decode(Summary.Load.self, #"{"kind":"\#(kind)","latest":{"date":"2026-10-19","value":\#(value),"source":"x"},"average":\#(average.map { "\($0)" } ?? "null")}"#)
        }
        XCTAssertEqual(LoadCard.band(try load("strain", 9.9, nil)), "Light")
        XCTAssertEqual(LoadCard.band(try load("strain", 13, nil)), "Moderate")
        XCTAssertEqual(LoadCard.band(try load("strain", 17.9, nil)), "High")
        XCTAssertEqual(LoadCard.band(try load("strain", 18, nil)), "All out")
        XCTAssertEqual(LoadCard.band(try load("energy", 500, 500)), "Above usual")
        XCTAssertEqual(LoadCard.band(try load("energy", 499, 500)), "Below usual")
        for words in ["'Light'", "'Moderate'", "'High'", "'All out'", "'Above usual'", "'Below usual'", "Strain comes from WHOOP; active energy from Apple Health.",
                      "No steps recorded yet.", "Connect data", "% of goal", "Recent insights", "Insights appear after a week or two of data.",
                      "Vitals from your latest night, compared with your own last 30 days.", "Nothing recorded for this day.", "Today's timeline", "Timeline · "] {
            XCTAssertTrue(tsx.contains(words), words)
        }
        XCTAssertEqual(TodayPath.title(date: "2026-10-19", today: "2026-10-19"), "Today's timeline")
        XCTAssertEqual(TodayPath.title(date: "2026-10-18", today: "2026-10-19"), "Timeline · \(Fmt.day("2026-10-18", "EEEMMMd"))")
    }

    func testEachEventSaysWhereItStands() throws {
        let e = try decode(TimelineEvent.self, #"{"id":"w","kind":"workout","title":"Run","start":"2026-10-19T07:00:00-05:00","end":"2026-10-19T07:40:00-05:00","detail":null}"#)
        XCTAssertEqual(TimelineCard.state(e, isToday: true, now: "2026-10-19T06:59"), "Upcoming")
        XCTAssertEqual(TimelineCard.state(e, isToday: true, now: "2026-10-19T07:10"), "In progress")
        XCTAssertEqual(TimelineCard.state(e, isToday: true, now: "2026-10-19T07:40"), "Completed")
        XCTAssertEqual(TimelineCard.state(e, isToday: false, now: "2026-10-19T06:00"), "Completed", "every event of a past day")
        let tsx = try web("src/pages/Home.tsx")
        for words in ["'Completed'", "'In progress'", "'Upcoming'", "timeline.events.slice(-4)"] { XCTAssertTrue(tsx.contains(words), words) }
    }

    func testHomesRowsAreHomeTsxs() throws {
        let tsx = try web("src/pages/Home.tsx")
        // Every card id Home.tsx lays out, in its order.
        let ids = tsx.matches(of: /\['(home\.[a-z0-9]+)'/).map { String($0.output.1) }
        XCTAssertEqual(ids, HomeCards.signals + HomeCards.lower + HomeCards.optionalRow + ["home.timeline", "home.week", "home.insights"])
    }
}

// MARK: - Edit widgets, the header, the banners

final class HomeChromeTests: XCTestCase {
    func testEditWidgetsGroupsHomesCards() throws {
        let tsx = try web("src/components/shell/EditWidgets.tsx"), choices = try web("src/components/CardChoices.tsx")
        XCTAssertTrue(tsx.contains(EditWidgetsSheet.intro))
        for words in ["eyebrow=\"Home\"", "title=\"Edit widgets\"", "Every page's cards", "Done"] { XCTAssertTrue(tsx.contains(words), words) }
        for words in ["On this page", "More you can add"] { XCTAssertTrue(choices.contains(words), words) }

        let with = EditWidgetsSheet.groups(nutrition: true, optionalCards: true)
        XCTAssertEqual(with.onPage.map(\.id), ["home.rhr", "home.spo2", "home.hrv", "home.sleep", "home.readiness", "home.resp", "home.nutrition", "home.journal"])
        XCTAssertEqual(with.more.map(\.id), ["home.week", "home.timeline", "home.insights", "home.load", "home.activity", "home.food"])
        // Food totals only with Nutrition on.
        XCTAssertFalse(EditWidgetsSheet.groups(nutrition: false, optionalCards: true).more.map(\.id).contains("home.food"))
        // A server older than optional cards: only the cards it knows, and none of them optional.
        let older = EditWidgetsSheet.groups(nutrition: false, optionalCards: false)
        XCTAssertTrue(older.more.isEmpty)
        XCTAssertEqual(older.onPage.map(\.id), ["home.spo2", "home.hrv", "home.sleep", "home.readiness", "home.timeline", "home.insights", "home.load", "home.activity"])
    }

    func testTheGreetingAndTheTopBar() throws {
        let shell = try web("src/components/shell/ShellHeader.tsx"), bar = try web("src/components/shell/TopBar.tsx")
        XCTAssertEqual(HomeHeader.subtitle(date: "2026-10-19", today: "2026-10-19"), "Here's your health today.")
        XCTAssertEqual(HomeHeader.subtitle(date: "2026-10-16", today: "2026-10-19"), "Here's your health on \(Fmt.day("2026-10-16", "EEEEMMMMd")).")
        for words in ["Hello,", "Here's your health today.", "Here's your health on ", "weekday: 'long', month: 'long', day: 'numeric'", "|| 'there'"] {
            XCTAssertTrue(shell.contains(words), words)
        }
        XCTAssertEqual(HomeHeader.name(settings: "  Sam ", summary: "Other"), "Sam")
        XCTAssertEqual(HomeHeader.name(settings: " ", summary: nil), "there")
        XCTAssertEqual(HomeHeader.name(settings: nil, summary: "Alex"), "Alex")
        // Next goes back to today (no date) rather than to a date, and never past it.
        XCTAssertEqual(HomeHeader.next(after: "2026-10-16", today: "2026-10-19"), "2026-10-17")
        XCTAssertNil(HomeHeader.next(after: "2026-10-18", today: "2026-10-19"))
        for words in ["Demo data · Connect yours", "Edit widgets", "Refresh", "Previous day", "Next day", "weekday: 'short', month: 'short', day: 'numeric'"] {
            XCTAssertTrue(bar.contains(words), words)
        }
        XCTAssertTrue(try web("src/styles.css").contains("@media (max-width: 420px) {\n  .topbar-widgets span {\n    display: none;"))
    }

    func testTheNoSourcesBannerIsAppTsxs() throws {
        let app = try web("src/App.tsx")
        XCTAssertTrue(app.contains(NoSourcesBanner.text))
        XCTAssertTrue(app.contains("const noSources = (s: Status) => !s.demo && !s.apple.lastImport && !s.apple.lastSync && !s.whoop.connected && !s.fitbit?.lastImport;"))
        func status(_ json: String) throws -> ServerStatus { try decode(ServerStatus.self, json) }
        XCTAssertTrue(NoSourcesBanner.shows(try status(#"{"demo":false,"apple":{},"whoop":{"connected":false}}"#)))
        XCTAssertFalse(NoSourcesBanner.shows(try status(#"{"demo":true,"apple":{},"whoop":{"connected":false}}"#)), "demo data shows")
        XCTAssertFalse(NoSourcesBanner.shows(try status(#"{"demo":false,"apple":{"lastSync":{"syncedAt":"2026-10-19T08:00:00Z"}},"whoop":{"connected":false}}"#)))
        XCTAssertFalse(NoSourcesBanner.shows(try status(#"{"demo":false,"apple":{"lastImport":{"importedAt":"2026-10-19T08:00:00Z"}},"whoop":{}}"#)))
        XCTAssertFalse(NoSourcesBanner.shows(try status(#"{"demo":false,"apple":{},"whoop":{"connected":true}}"#)))
        XCTAssertFalse(NoSourcesBanner.shows(try status(#"{"demo":false,"apple":{},"whoop":{},"fitbit":{"lastImport":{"importedAt":"2026-10-19","metrics":[]}}}"#)))
        XCTAssertFalse(NoSourcesBanner.shows(try status("{}")), "a status that says nothing about sources says nothing")
        XCTAssertFalse(NoSourcesBanner.shows(nil))
        // The family note, once (App.tsx FamilyNotice).
        for words in ["Your family can see your daily status and your last 30 days on the", "board. Change this in", "your Profile", "Got it"] {
            XCTAssertTrue(app.contains(words), words)
        }
    }

    func testTheTaglineIsHomeTsxs() throws {
        let tsx = try web("src/pages/Home.tsx")
        for words in ["A clearer picture.", "A healthier you.", "Your measurements", "href={href('vitals')}"] { XCTAssertTrue(tsx.contains(words), words) }
        // With just the statistics, the compact line after the cards.
        XCTAssertTrue(tsx.contains("{stats && <Tagline compact />}"))
        // The page's last line, without the right-hand one Ask McFly's pill takes on Home.
        let foot = try web("src/components/shell/AppFooter.tsx")
        XCTAssertTrue(foot.contains("<span>\(HomeFooter.text)</span>"))
        XCTAssertTrue(foot.contains("{!home && <span>"))
    }

    func testAllHiddenSaysWhatTheWebSays() throws {
        let row = try web("src/components/CardRow.tsx")
        XCTAssertTrue(row.contains("All the cards on this page are hidden. Choose the ones to show with Edit widgets on Home, or in"))
        XCTAssertTrue(Cards.allHidden(in: .home, hidden: Set(Cards.all.filter { $0.page == .home }.map(\.id))))
        XCTAssertFalse(Cards.allHidden(in: .home, hidden: Set(Cards.optional)), "the default cards still show")
    }
}

// MARK: - Every text size

/// Nothing on Home runs off a phone's screen at any text size: each part fits the width it's given (the content width
/// of a 375pt phone, with the page's 16pt sides).
@MainActor
final class HomeFitsTests: XCTestCase {
    private let width: CGFloat = 343
    private let sizes: [DynamicTypeSize] = [.large, .xxxLarge, .accessibility1, .accessibility3, .accessibility5]

    private func fit(_ view: some View, _ size: DynamicTypeSize, sync: AppModel? = nil) -> CGSize {
        let root = view.environment(Dashboard()).environment(sync ?? AppModel()).environment(\.dynamicTypeSize, size)
        return UIHostingController(rootView: root).sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
    }

    private func assertFits(_ name: String, _ view: some View, file: StaticString = #filePath, line: UInt = #line) {
        for size in sizes {
            XCTAssertLessThanOrEqual(fit(view, size).width, width + 0.5, "\(name) runs off the screen at \(size)", file: file, line: line)
        }
    }

    func testEveryCardFits() throws {
        for json in [fullSummary, olderSummary] {
            let s = try decode(Summary.self, json)
            for id in Signal.ids {
                assertFits(id, SignalCard(signal: try XCTUnwrap(Signal.of(id, s)), date: s.date))
                assertFits("\(id) compact", SignalCard(signal: try XCTUnwrap(Signal.of(id, s, variant: .compact)), date: s.date, variant: .compact))
            }
            assertFits("load", LoadCard(summary: s))
            assertFits("activity", ActivityCard(summary: s, goal: 10_000))
            assertFits("insights", InsightsCard(insights: s.insights ?? [], today: s.today))
            assertFits("week", WeekCard(week: s.week, stepGoal: 10_000))
            assertFits("figure", DigitalFigure(vitals: s.vitals, asOf: s.date))
        }
        assertFits("nutrition", TodayNutritionCard(date: "2026-10-19", today: "2026-10-19"))
        assertFits("journal", JournalPromptCard())
        assertFits("tagline", HomeTagline())
        assertFits("compact tagline", HomeTagline(compact: true))
        assertFits("no sources", NoSourcesBanner())
        assertFits("family notice", FamilyNotice())
        assertFits("footer", HomeFooter())
    }

    /// The figure's size comes from the width it's given, never from one kept from an earlier layout, which would hold
    /// the whole page wider than the screen once it had been (at the largest text sizes it was).
    func testTheFigureTakesTheWidthItsGiven() throws {
        let s = try decode(Summary.self, fullSummary)
        for proposed: CGFloat in [120, 200, 343] {
            let host = UIHostingController(rootView: DigitalFigure(vitals: s.vitals, asOf: s.date).environment(\.dynamicTypeSize, .accessibility5))
            let size = host.sizeThatFits(in: CGSize(width: proposed, height: .greatestFiniteMagnitude))
            XCTAssertEqual(size.width, proposed, accuracy: 0.5)
            XCTAssertEqual(size.height, proposed * 600 / 640, accuracy: 0.5)
        }
        let photo = try decode(PhotoMeta.self, #"{"version":1,"width":900,"height":1200,"face":[0.38,0.06,0.24,0.24],"shoulderY":0.36,"dots":{"temp":[0.5,0.1],"breathing":[0.5,0.3],"heart":[0.56,0.45]}}"#)
        for proposed: CGFloat in [120, 343, 600] {
            let host = UIHostingController(rootView: PortraitFigure(vitals: s.vitals, asOf: s.date, photo: photo).environment(\.dynamicTypeSize, .accessibility5))
            let size = host.sizeThatFits(in: CGSize(width: proposed, height: .greatestFiniteMagnitude))
            XCTAssertEqual(size.height, min(proposed, PortraitFigure.maxWidth) * 4 / 3, accuracy: 0.5, "at most 440 wide, in the photo's shape")
        }
    }

    func testTheHeaderFits() throws {
        let s = try decode(Summary.self, fullSummary)
        assertFits("header", HomeHeader(summary: s, editing: .constant(false)))
        // With the demo note and Edit widgets (a server that hides cards), the parts that wrap at the largest sizes.
        let d = Dashboard()
        d.apply(status: try decode(ServerStatus.self, #"{"demo":true,"settings":{"name":"Sam","hiddenCards":[],"shownCards":[]}}"#))
        XCTAssertTrue(d.cardsAvailable)
        let sync = AppModel()
        sync.sources = SourcesSyncStatus(finishedAt: Date(), apple: .ok, whoop: .skipped("Not connected"), hint: nil)
        for size in sizes {
            let root = HomeHeader(summary: s, editing: .constant(false)).environment(d).environment(sync).environment(\.dynamicTypeSize, size)
            let fitted = UIHostingController(rootView: root).sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
            XCTAssertLessThanOrEqual(fitted.width, width + 0.5, "the header with the demo note runs off the screen at \(size)")
        }
    }

    /// The sync line is in full at every size: each source's state is in it.
    func testTheSyncLineWrapsRatherThanBeingCutOff() {
        let sync = AppModel()
        // Both synced: no notes under the line, so its height is the line's own.
        let status = SourcesSyncStatus(finishedAt: Date(), apple: .ok, whoop: .ok, hint: nil)
        XCTAssertTrue(status.notes.isEmpty)
        sync.sources = status
        let narrow: CGFloat = 160
        for size in [DynamicTypeSize.accessibility3, .accessibility5] {
            let line = UIHostingController(rootView: SyncStatusLine().environment(sync).environment(\.dynamicTypeSize, size))
                .sizeThatFits(in: CGSize(width: narrow, height: .greatestFiniteMagnitude))
            // Its words alone, given the line's whole width (more than they get beside the icon): a lower bound.
            let words = Text("Synced \(status.finishedAt.formatted(.relative(presentation: .named))) · \(status.summary)")
                .font(.app(.caption)).fixedSize(horizontal: false, vertical: true).environment(\.dynamicTypeSize, size)
            let needed = UIHostingController(rootView: words).sizeThatFits(in: CGSize(width: narrow, height: .greatestFiniteMagnitude))
            XCTAssertGreaterThanOrEqual(line.height, needed.height - 0.5, "the sync line is cut off at \(size)")
        }
    }

    /// The quiet buttons (Every page's cards, Got it) wrap their words where they're narrow, never cutting them off.
    func testAQuietButtonWraps() {
        let button = Button("Every page's cards") {}.buttonStyle(HomeQuietButtonStyle()).environment(\.dynamicTypeSize, .accessibility5)
        let wide = UIHostingController(rootView: button).sizeThatFits(in: CGSize(width: 2000, height: CGFloat.greatestFiniteMagnitude))
        let narrow = UIHostingController(rootView: button).sizeThatFits(in: CGSize(width: wide.width / 2, height: .greatestFiniteMagnitude))
        XCTAssertLessThanOrEqual(narrow.width, wide.width / 2 + 0.5)
        XCTAssertGreaterThan(narrow.height, wide.height + 1, "on two lines, not one cut short")
    }

    /// Edit widgets' buttons fit the sheet (18pt sides) at every size: Done goes under Every page's cards when they don't
    /// fit side by side.
    func testEditWidgetsFooterFits() {
        let sheet = width + 32 - 36
        for size in sizes {
            let footer = EditWidgetsSheet.Footer(everyPage: {}, done: {}).environment(\.dynamicTypeSize, size)
            let fitted = UIHostingController(rootView: footer).sizeThatFits(in: CGSize(width: sheet, height: .greatestFiniteMagnitude))
            XCTAssertLessThanOrEqual(fitted.width, sheet + 0.5, "Edit widgets' buttons run off the sheet at \(size)")
        }
        let large = UIHostingController(rootView: EditWidgetsSheet.Footer(everyPage: {}, done: {}).environment(\.dynamicTypeSize, .large))
            .sizeThatFits(in: CGSize(width: sheet, height: .greatestFiniteMagnitude))
        let ax5 = UIHostingController(rootView: EditWidgetsSheet.Footer(everyPage: {}, done: {}).environment(\.dynamicTypeSize, .accessibility5))
            .sizeThatFits(in: CGSize(width: sheet, height: .greatestFiniteMagnitude))
        XCTAssertLessThan(large.height, 60, "side by side at the default size")
        XCTAssertGreaterThan(ax5.height, large.height * 2, "one under the other at the largest")
    }

    /// The journal card with a long check-in: the line wraps inside the card, which grows to hold it, rather than running
    /// over its button.
    func testTheJournalWithALongCheckInGrowsToHoldIt() throws {
        // No mood, so the line is the row's only child and its height is all the row's.
        func entry(_ text: String) throws -> JournalEntry {
            try decode(JournalEntry.self, #"{"id":"a","date":"2026-10-19","time":"08:10","mood":null,"text":"\#(text)","createdAt":1}"#)
        }
        let long = try entry("Made-up: a long first line that needs more than one line of the card to say all of it")
        let short = try entry("Made-up")
        assertFits("journal with a check-in", JournalPromptCard(latest: long))
        for size in [DynamicTypeSize.accessibility3, .accessibility5] {
            let tall = fit(JournalPromptCard(latest: long), size).height, low = fit(JournalPromptCard(latest: short), size).height
            XCTAssertGreaterThan(tall, low + 10, "the long line's second line has room at \(size)")
        }
    }

    func testTheFoodTotalsCardFits() throws {
        let data = try decode(NutritionData.self, #"""
        {"enabled":true,"numbers":"all","today":"2026-10-19","start":"2026-10-13","end":"2026-10-19","apps":["MyFitnessPal"],"app":null,
         "days":[{"date":"2026-10-18","app":"MyFitnessPal","values":{"energy_kcal":2100,"protein_g":90,"carbs_g":240,"fat_g":70,"fiber_g":30}}]}
        """#)
        assertFits("food totals", FoodTotalsCard(data: data))
        XCTAssertGreaterThan(fit(FoodTotalsCard(data: data), .large).height, 100)
    }
}

/// HomeFlowRow (the journal's mood and line, the food card's values) reports the height its children take, a wrapped line's
/// included.
@MainActor
final class HomeFlowRowTests: XCTestCase {
    func testALineWiderThanTheRowWrapsOnALineOfItsOwnAndCountsAllItsHeight() {
        let line = Text("Made-up: felt tired after lunch, maybe the late night again").font(.system(size: 13)).lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
        let badge = Text("Good").font(.system(size: 12)).padding(4)
        for w: CGFloat in [120, 200] {
            func height(_ view: some View) -> CGFloat {
                UIHostingController(rootView: view).sizeThatFits(in: CGSize(width: w, height: .greatestFiniteMagnitude)).height
            }
            let alone = height(line.frame(width: w))
            let one = height(Text("M").font(.system(size: 13)))
            XCTAssertGreaterThan(alone, one * 1.5, "the line takes two lines at \(w)")
            let row = height(HomeFlowRow(spacing: 8, lineSpacing: 6) { badge; line }.frame(width: w))
            XCTAssertEqual(row, height(badge) + 6 + alone, accuracy: 1, "the badge's line, then the wrapped line's two")
        }
        // Children that fit stay on one line.
        let short = UIHostingController(rootView: HomeFlowRow(spacing: 8, lineSpacing: 6) { badge; Text("Ok").font(.system(size: 13)) }.frame(width: 200))
            .sizeThatFits(in: CGSize(width: 200, height: CGFloat.greatestFiniteMagnitude))
        XCTAssertLessThan(short.height, 30)
    }
}
