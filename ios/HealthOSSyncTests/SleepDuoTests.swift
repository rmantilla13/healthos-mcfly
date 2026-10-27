import SwiftUI
import XCTest
@testable import HealthOSSync

// The Sleep page drawn at the iPhone Duo's sizes with the fold put in (duo/design.md §8.2), from a local test server's
// made-up demo answers (Fixtures/sleep-*.json): the outer display, the inner display upright, open in landscape (the
// fold flat and active) and in Split View, light and dark, at the default size and AX3. Nothing tappable on the fold,
// and a fold or a band change keeps the tab and reads nothing again. PNGs are written when TEST_RUNNER_DUO_SHOTS is set
// (d-*.png, design §8.3's names). Slice J owns this file.

@MainActor
final class SleepDuoTests: XCTestCase {
    /// The demo's night, with its "today" the morning after (as the web's references were taken), so it's "Last night".
    private func night() throws -> SleepNightDetail {
        let text = String(decoding: try sleepFixture("sleep-night"), as: UTF8.self).replacingOccurrences(of: #""today":"2026-10-27""#, with: #""today":"2026-10-26""#)
        return try JSONDecoder().decode(SleepNightDetail.self, from: Data(text.utf8))
    }

    /// Reads that answer with the fixtures and count themselves.
    private final class Counter {
        var reads = 0
    }

    private func reads(_ counter: Counter, night: SleepNightDetail?, timing: SleepTiming? = nil, patterns: Patterns? = nil) throws -> SleepReads {
        let rhr = try sleepDecode(Trends.self, "sleep-rhr")["resting_hr"] ?? []
        let stages = try sleepDecode(Trends.self, "sleep-stages")
        let trends = try sleepDecode(Trends.self, "sleep-trends")
        let timing = try timing ?? sleepDecode(SleepTiming.self, "sleep-timing")
        let patterns = try patterns ?? sleepDecode(Patterns.self, "patterns")
        return SleepReads(
            night: { _, _ in counter.reads += 1; return night },
            restingHr: { _, _ in counter.reads += 1; return rhr },
            patterns: { _ in counter.reads += 1; return patterns },
            timing: { _ in counter.reads += 1; return timing },
            trends: { _, metrics, _ in counter.reads += 1; return metrics.contains("sleep_awake") ? stages : trends })
    }

    private func dashboard(status: String = sleepDemoStatus, summary: Bool = true) throws -> Dashboard {
        let d = Dashboard()
        d.signedIn()
        d.apply(status: try sleepStatus(status))
        if summary {
            let text = String(decoding: try sleepFixture("sleep-summary"), as: UTF8.self).replacingOccurrences(of: #""today":"2026-10-27""#, with: #""today":"2026-10-26""#)
            d.summary = try JSONDecoder().decode(Summary.self, from: Data(text.utf8))
        }
        return d
    }

    /// The page as the shell shows it under More, without its NavigationStack (drawn tests take the state's insets).
    private func page(_ d: Dashboard, _ reads: SleepReads, model: SleepModel) -> some View {
        SleepPage(linkTab: nil, model: model)
            .background(Palette.page)
            .environment(d)
            .environment(AppModel())
            .environment(\.sleepReads, reads)
    }

    /// The outer display, upright, open in landscape (the bar on either side, the fold flat and active) and Split View.
    private let states: [DuoState] = [.outer, .innerPortrait(), .innerLandscape(), .innerLandscape(bar: .leading),
                                      .innerLandscape(foldActive: true), .innerSplit(bar: .trailing)]

    // MARK: Drawn

    func testTheOverviewInEveryState() async throws {
        try await drawEveryState(.overview, name: "d")
    }

    func testTheStagesInEveryState() async throws {
        try await drawEveryState(.stages, name: "d-stages")
    }

    func testTheTrendsInEveryState() async throws {
        try await drawEveryState(.trends, name: "d-trends")
    }

    func testTheCoachingInEveryState() async throws {
        try await drawEveryState(.coaching, name: "d-coaching")
    }

    /// A tab in every state, light and dark, at the default size and AX3, then the outer display at AX5 (the phone's
    /// widest text: nothing cut off).
    private func drawEveryState(_ tab: SleepTab, name: String) async throws {
        let counter = Counter()
        let d = try dashboard()
        let r = try reads(counter, night: try night())
        for state in states {
            for dark in [false, true] {
                for size: DynamicTypeSize in [.large, .accessibility3] {
                    try await DuoSnapshot.draw(page(d, r, model: SleepModel(tab: tab)), as: state, dark: dark, typeSize: size, name: name)
                }
            }
        }
        for dark in [false, true] {
            try await DuoSnapshot.draw(page(d, r, model: SleepModel(tab: tab)), as: .outer, dark: dark, typeSize: .accessibility5, name: name)
        }
    }

    /// Open in landscape, every tab puts its cards on both sides of the fold (the leading side and the trailing one each
    /// hold some of what VoiceOver reaches below the header), with the bar on either side.
    func testBothSidesOfTheFoldCarryContent() async throws {
        let counter = Counter()
        let d = try dashboard()
        let r = try reads(counter, night: try night())
        for tab in SleepTab.allCases {
            for state in [DuoState.innerLandscape(), .innerLandscape(bar: .leading)] {
                let host = try await DuoHost(page(d, r, model: SleepModel(tab: tab)), as: state)
                defer { host.close() }
                guard let band = DuoFoldAssertions.band(state) else { return XCTFail("no fold at \(state)") }
                let frames = try await host.elements().map(\.accessibilityFrame).filter { $0.minY > 200 && $0.width > 0 }
                XCTAssertTrue(frames.contains { $0.maxX < band.lowerBound }, "\(tab) \(state): nothing on the leading side")
                XCTAssertTrue(frames.contains { $0.minX > band.upperBound }, "\(tab) \(state): nothing on the trailing side")
                XCTAssertFalse(frames.contains { $0.minX < band.lowerBound - 40 && $0.maxX > band.upperBound + 40 && $0.height > 120 },
                               "\(tab) \(state): a card runs across the fold")
            }
        }
    }

    /// No source and no night ever: the three cards, empty, and no tabs or day picker.
    func testTheBarePage() async throws {
        let counter = Counter()
        let d = try dashboard(status: sleepNewStatus, summary: false)
        let bare = try JSONDecoder().decode(SleepNightDetail.self, from: Data(#"{"date":"2026-10-27","today":"2026-10-27","lastNight":null,"segments":[],"insights":[]}"#.utf8))
        let r = try reads(counter, night: bare)
        for state in [DuoState.outer, .innerPortrait(), .innerLandscape()] {
            try await DuoSnapshot.draw(page(d, r, model: SleepModel()), as: state, name: "d-bare")
        }
        let host = try await DuoHost(page(d, r, model: SleepModel()), as: .outer)
        defer { host.close() }
        let labels = try await host.elements().compactMap(\.accessibilityLabel)
        XCTAssertTrue(labels.contains(SleepWords.subNone), "the line asks for a wearable")
        XCTAssertFalse(labels.contains("Previous day"), "no day picker on the bare page")
        XCTAssertFalse(labels.contains { $0.hasPrefix("Sleep stages") }, "no stages card")
    }

    /// Coaching with fewer than seven nights says so in the web's words.
    func testCoachingWaitsForAWeek() async throws {
        let counter = Counter()
        let d = try dashboard()
        let few = try JSONDecoder().decode(SleepTiming.self, from: Data(#"{"nights":[],"stats":{"nights":3,"avgBedMin":null,"avgWakeMin":null,"bedSd":null,"wakeSd":null,"midWeekday":null,"midWeekend":null,"socialJetlag":null,"need":null,"debt":null,"debtNights":0}}"#.utf8))
        let r = try reads(counter, night: try night(), timing: few)
        try await DuoSnapshot.draw(page(d, r, model: SleepModel(tab: .coaching)), as: .outer, name: "d-coaching-waits")
        let host = try await DuoHost(page(d, r, model: SleepModel(tab: .coaching)), as: .outer)
        defer { host.close() }
        let labels = try await host.elements().compactMap(\.accessibilityLabel)
        XCTAssertTrue(labels.contains { $0.contains(SleepWords.needsAWeek(3)) }, "\(labels)")
    }

    // MARK: The fold

    func testNothingTappableOnTheFold() async throws {
        let counter = Counter()
        let d = try dashboard()
        let r = try reads(counter, night: try night())
        for tab in SleepTab.allCases {
            for state in DuoState.folded {
                for size: DynamicTypeSize in [.large, .accessibility3] {
                    try await DuoFoldAssertions.assertNothingTappableOnTheFold(page(d, r, model: SleepModel(tab: tab)), state: state, typeSize: size)
                }
            }
        }
    }

    // MARK: Continuity

    /// A fold, an unfold and a turn keep the tab chosen and read nothing again (P4, P14): the model and the loaders sit
    /// above the DuoPage, and the panes are rebuilt below them.
    func testStateSurvivesBandChangeAndNothingIsReadAgain() async throws {
        let counter = Counter()
        let d = try dashboard()
        let model = SleepModel(tab: .overview)
        let host = try await DuoHost(page(d, try reads(counter, night: try night()), model: model), as: .outer)
        defer { host.close() }
        XCTAssertNotNil(model.night.value)
        model.tab = .trends
        try await host.settle()
        let read = counter.reads
        XCTAssertGreaterThan(read, 0)
        for state in [DuoState.innerLandscape(), .innerPortrait(), .innerLandscape(foldActive: true), .innerSplit(bar: .leading), .outer] {
            try await host.set(state)
            XCTAssertEqual(model.tab, .trends, "\(state)")
            XCTAssertEqual(counter.reads, read, "nothing is read again at \(state)")
        }
        XCTAssertEqual(model.readCount, read)
    }

    /// The same link opened again while the page is up applies its tab again; the link that opened the page doesn't.
    func testALinkOpenedAgainAppliesItsTab() async throws {
        let counter = Counter()
        let d = try dashboard()
        d.open(AppRoute(.sleep, query: ["tab": "stages"]))
        let model = SleepModel(tab: .stages)
        let host = try await DuoHost(page(d, try reads(counter, night: try night()), model: model), as: .outer)
        defer { host.close() }
        XCTAssertEqual(model.tab, .stages)
        model.tab = .trends
        try await host.settle()
        XCTAssertEqual(model.tab, .trends, "the opener isn't applied twice")
        d.open(AppRoute(.sleep, query: ["tab": "stages"]))
        try await host.settle()
        XCTAssertEqual(model.tab, .stages)
        d.open(AppRoute(.sleep, query: ["tab": "coaching"]))
        try await host.settle()
        XCTAssertEqual(model.tab, .coaching)
    }
}
