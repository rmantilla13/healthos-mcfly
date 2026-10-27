import SwiftUI
import XCTest
@testable import HealthOSSync

/// The shell on iPhone Duo (design §1 O3, §7's More and account menu rows; the shell stage of the foundation): More's
/// symbol, the keyboard's Done asked for around a sheet, the keyboard shapes the Debug flag can put up, and More kept to
/// the leading side of the fold.
@MainActor
final class DuoShellTests: XCTestCase {
    private func dashboard() -> Dashboard { Dashboard(tokenStore: MemoryTokenStore()) }

    /// O3: in a vertical bar More is a grid (the ellipsis is the system's overflow menu there); every other tab, and More
    /// everywhere else, keeps its symbol.
    func testMoreSymbol() {
        XCTAssertEqual(AppTab.more.symbol(verticalBar: true), "square.grid.2x2")
        XCTAssertEqual(AppTab.more.symbol(verticalBar: false), "ellipsis")
        XCTAssertEqual(AppTab.settings.symbol(verticalBar: true), "square.grid.2x2")
        for tab in [AppTab.home, .vitals, .body, .nutrition] {
            XCTAssertEqual(tab.symbol(verticalBar: true), tab.symbol)
            XCTAssertEqual(tab.symbol(verticalBar: false), tab.symbol)
        }
        XCTAssertEqual(AppTab.more.symbol(verticalBar: false), AppTab.more.symbol, "the phone's More is unchanged")
    }

    /// keyboardDismissal() on a sheet's view tells what's under it (the sheet's SheetScaffold) that it asked for Done; a
    /// view without it hasn't asked.
    func testKeyboardDismissalAsksForDone() async throws {
        let seen = Seen()
        let asked = DuoAskReader(seen: seen, name: "asked").keyboardDismissal()
        let plain = DuoAskReader(seen: seen, name: "plain")
        let host = try await DuoHost(VStack { asked; plain }, as: .outer)
        defer { host.close() }
        XCTAssertEqual(seen.values["asked"], true)
        XCTAssertEqual(seen.values["plain"], false)
    }

    /// Before iOS 27.1 (every simulator these tests run on but the Duo) a sheet has no stack of its own, so it adds no Done:
    /// the one keyboardDismissal() puts up outside it is the only one, as before.
    func testASheetAddsNoDoneBefore27_1() async throws {
        guard !DuoSheetStack<EmptyView>.stacks else { throw XCTSkip("iOS 27.1: the sheet's stack holds the Done (checked live, G0)") }
        let seen = Seen()
        let sheet = SheetScaffold(title: "Sheet") { DuoInSheetReader(seen: seen) }.keyboardDismissal()
        let host = try await DuoHost(sheet, as: .outer)
        defer { host.close() }
        XCTAssertEqual(seen.values["inSheet"], false, "no Done inside the sheet before 27.1")
    }

    /// The shapes `-duoKeyboardShape` can put up are named by their raw values, and only Debug builds read the flag.
    func testKeyboardShapesHaveNames() {
        XCTAssertEqual(Set(DuoKeyboardDone.Shape.allCases.map(\.rawValue)).count, DuoKeyboardDone.Shape.allCases.count)
        XCTAssertEqual(DuoKeyboardDone.Shape(rawValue: "doneAlone"), .doneAlone)
        XCTAssertEqual(DuoKeyboardDone.Shape(rawValue: "spacerThenDone"), .spacerThenDone)
        XCTAssertNil(DuoKeyboardDone.Shape(rawValue: "nonsense"))
    }

    /// §7: More keeps to the leading side of the fold, so none of its rows meets it, flat or active, at default text and
    /// AX3; upright and on the outer display it's the phone's one column.
    func testMoreKeepsOffTheFold() async throws {
        let d = dashboard()
        let more = MoreScreen().environment(d)
        for state in DuoState.folded {
            for size: DynamicTypeSize in [.large, .accessibility3] {
                try await DuoFoldAssertions.assertNothingTappableOnTheFold(more, state: state, typeSize: size)
            }
        }
        try await DuoSnapshot.drawAll(more, name: "more")
    }

    /// The account menu draws in every state (its sheet's size is the system's; the menu is the same rows).
    func testTheAccountMenuDraws() async throws {
        let d = dashboard()
        try await DuoSnapshot.draw(AccountMenuSheet { _ in }.environment(d), as: .outer, name: "account-menu")
        try await DuoSnapshot.draw(AccountMenuSheet { _ in }.environment(d), as: .innerLandscape(), name: "account-menu")
    }
}

/// What a probe view saw, by name.
@MainActor final class Seen {
    var values: [String: Bool] = [:]
}

private struct DuoAskReader: View {
    let seen: Seen
    let name: String
    @Environment(\.duoKeyboardDoneAsked) private var asked

    var body: some View {
        Color.clear.frame(width: 10, height: 10).onAppear { seen.values[name] = asked }
    }
}

private struct DuoInSheetReader: View {
    let seen: Seen
    @Environment(\.duoKeyboardDoneInSheet) private var inSheet

    var body: some View {
        Color.clear.frame(width: 10, height: 10).onAppear { seen.values["inSheet"] = inSheet }
    }
}

/// The foundation's own pages (design §7's Day view, Insights and Live heart rate, the shell stage's F5), drawn in the
/// Duo's states from the fixtures, with the fold checked in the folded states at default text and AX3. On the open Duo
/// held sideways Day and Insights follow decisions.md Q5: their lead in the leading pane, the rest in the trailing one.
@MainActor
final class DuoFoundationPagesTests: XCTestCase {
    private func fixture<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
        let url = Bundle(for: Self.self).url(forResource: name, withExtension: "json")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name).json")
        return try JSONDecoder().decode(T.self, from: try Data(contentsOf: url))
    }

    private func day() throws -> some View {
        let data = try fixture("day", as: DayData.self)
        return DayPage(current: data.date, today: data.today, data: data, loaded: true, error: nil, goal: 10_000) { _ in }
            .background(Palette.page)
    }

    private func insights() throws -> some View {
        let digest = try fixture("digest", as: DigestReply.self)
        let patterns = try fixture("patterns", as: Patterns.self)
        let trends = try fixture("trends-vitals", as: Trends.self)
        return InsightsPage(digest: digest, patterns: patterns, trends: trends, trendsError: nil, end: patterns.end, stepGoal: 10_000)
            .environment(Dashboard(tokenStore: MemoryTokenStore()))
            .background(Palette.page)
    }

    func testDayDrawsInEveryState() async throws {
        try await DuoSnapshot.drawAll(try day(), name: "day")
        try await DuoSnapshot.draw(try day(), as: .innerLandscape(), typeSize: .accessibility3, name: "day")
    }

    func testInsightsDrawsInEveryState() async throws {
        try await DuoSnapshot.drawAll(try insights(), name: "insights")
        try await DuoSnapshot.draw(try insights(), as: .innerLandscape(), typeSize: .accessibility3, name: "insights")
    }

    func testLiveHeartRateDraws() async throws {
        for state: DuoState in [.outer, .innerPortrait(), .innerLandscape()] {
            _ = try await DuoSnapshot.draw(LiveHeartRateView(), as: state, name: "live-heart-rate")
        }
    }

    func testNothingTappableOnTheFold() async throws {
        for state in DuoState.folded {
            for size: DynamicTypeSize in [.large, .accessibility3] {
                try await DuoFoldAssertions.assertNothingTappableOnTheFold(try day(), state: state, typeSize: size)
                try await DuoFoldAssertions.assertNothingTappableOnTheFold(try insights(), state: state, typeSize: size)
            }
        }
    }

    /// Q5 on the open Duo: Day's previous and next sit in the leading pane, left of the fold; its charts in the trailing
    /// pane, right of it. On the outer display both are in the one column.
    func testDaysLeadIsOnTheLeadingSide() async throws {
        let host = try await DuoHost(try day(), as: .innerLandscape())
        defer { host.close() }
        let elements = try await host.elements()
        let fold = try XCTUnwrap(DuoFoldAssertions.band(.innerLandscape()))
        let previous = try XCTUnwrap(elements.first { $0.accessibilityLabel == "Previous day" })
        XCTAssertLessThan(previous.accessibilityFrame.maxX, fold.lowerBound, "previous day on the leading side")
        // The charts' cards (their titles and legends) are all on the trailing side.
        let trailing = elements.filter { $0.accessibilityFrame.minX > fold.upperBound }
        XCTAssertFalse(trailing.isEmpty, "the charts on the trailing side")
        XCTAssertTrue(trailing.contains { ($0.accessibilityLabel ?? "").contains("Typical") }, "a chart's legend on the trailing side")
    }

    /// The same hosted page through a band change and back (P14): nothing it shows depends on being rebuilt.
    func testDayAndInsightsSurviveABandChange() async throws {
        for page in [AnyView(try day()), AnyView(try insights())] {
            let host = try await DuoHost(page, as: .outer)
            defer { host.close() }
            for state: DuoState in [.innerLandscape(), .innerPortrait(), .outer] {
                try await host.set(state)
                let elements = try await host.elements()
                XCTAssertFalse(elements.isEmpty, "\(state)")
            }
        }
    }
}
