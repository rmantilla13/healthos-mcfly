import SwiftUI
import UIKit
import XCTest
@testable import HealthOSSync

/// iPhone Duo, layer 1 (duo/design.md §8.1): the blocks' math, without drawing, except where a row says "drawn".
/// The numbers are the Duo's: the outer display's content is 362 wide (382 less 20), inner portrait's 637 (669 less
/// 2 × 16) and inner landscape's 847 (867 less 20), with the fold at window x 475.5, which is content x 455.5 with the bar
/// trailing and 391.5 with it leading. The gap at the fold is the fold's width plus twice the 12 pt clearance (not
/// §2.4's "plus 14", which would put every split card inside the fold band D10 keeps clear), and each side ends on a whole
/// point: 443 | 379 with the bar trailing, 379 | 443 with it leading.
@MainActor
final class DuoLayoutTests: XCTestCase {
    private let foldTrailingBar: ClosedRange<CGFloat> = 455.5...455.5
    private let foldLeadingBar: ClosedRange<CGFloat> = 391.5...391.5

    func testBands() {
        XCTAssertEqual(DuoBand.of(contentWidth: 362, typeSize: .large), .compact)
        XCTAssertEqual(DuoBand.of(contentWidth: 637, typeSize: .large), .medium)
        XCTAssertEqual(DuoBand.of(contentWidth: 847, typeSize: .large), .wide)
        XCTAssertEqual(DuoBand.of(contentWidth: 847, typeSize: .accessibility3), .medium)
        XCTAssertEqual(DuoBand.of(contentWidth: 455, typeSize: .large), .compact)
        // The edges: 528 compact, 529 medium, 799 medium, 800 wide; compact can't go lower.
        XCTAssertEqual(DuoBand.of(contentWidth: 528, typeSize: .large), .compact)
        XCTAssertEqual(DuoBand.of(contentWidth: 529, typeSize: .large), .medium)
        XCTAssertEqual(DuoBand.of(contentWidth: 799, typeSize: .large), .medium)
        XCTAssertEqual(DuoBand.of(contentWidth: 800, typeSize: .large), .wide)
        XCTAssertEqual(DuoBand.of(contentWidth: 362, typeSize: .accessibility5), .compact)
        XCTAssertEqual(DuoBand.of(contentWidth: 637, typeSize: .accessibility1), .compact)
        XCTAssertEqual(DuoBand.of(contentWidth: 637, typeSize: .xxxLarge), .medium, "xxxLarge isn't an accessibility size")
    }

    func testSplitNeedsBothSides() {
        // ≥300 each side splits, and the span is kept as reported (rounded to 0.5 pt).
        XCTAssertEqual(DuoSplit.fold(contentWidth: 847, division: 455.4...455.6, active: false), DuoFold(span: 455.5...455.5, active: false))
        XCTAssertEqual(DuoSplit.fold(contentWidth: 847, division: 446...465, active: true), DuoFold(span: 446...465, active: true))
        // A fold nearer an edge than 300 doesn't: Split View's, at the window's edge.
        XCTAssertEqual(DuoSplit.fold(contentWidth: 847, division: 290...290, active: false), .none)
        XCTAssertEqual(DuoSplit.fold(contentWidth: 847, division: 560...560, active: false), .none)
        XCTAssertEqual(DuoSplit.fold(contentWidth: 367, division: 387...387, active: false), .none)
        // Wide with no fold reported splits at its middle; narrower doesn't.
        XCTAssertEqual(DuoSplit.fold(contentWidth: 847, division: nil, active: false), DuoFold(span: 423.5...423.5, active: false))
        XCTAssertEqual(DuoSplit.fold(contentWidth: 637, division: nil, active: false), .none)
        // A whole scope, Split View: the page at x 84–471 (bar leading), the fold at the window's trailing edge.
        let split = DuoDisplay.innerSplit(bar: .leading)
        let page = CGRect(x: 84, y: 0, width: 387, height: 635)
        let values = DuoScopeValues.resolve(width: 387, margins: .measured(barEdge: .leading), division: split.verticalFold(in: page),
                                            active: false, typeSize: .large)
        XCTAssertNil(values.fold.span)
        XCTAssertEqual(values.band, .compact)
        // A pane or a sheet never splits.
        XCTAssertNil(DuoScopeValues.resolve(width: 867, margins: .measured(barEdge: .trailing), division: 475.5...475.5, active: false,
                                            typeSize: .large, splits: false).fold.span)
    }

    func testColumnsSplitOnTheFold() {
        let layout = DuoColumnsLayout(columns: 2, spacing: 14, fold: foldTrailingBar, loneSpans: true)
        let rows = layout.rows(count: 4, width: 847)
        XCTAssertEqual(rows.count, 2)
        for row in rows {
            XCTAssertLessThanOrEqual(row[0].maxX, foldTrailingBar.lowerBound - DuoFold.clearance, "the leading column ends before the fold band")
            XCTAssertGreaterThanOrEqual(row[1].x, foldTrailingBar.upperBound + DuoFold.clearance, "the trailing one starts after it")
            XCTAssertEqual(row[0].x, 0)
            XCTAssertEqual(row[0].width, 443.5, accuracy: 0.5)
            XCTAssertEqual(row[1].maxX, 847)
            XCTAssertEqual(row[1].width, 379.5, accuracy: 0.5)
        }
        // An active fold with a width: the gap grows to it.
        let wide = DuoColumnsLayout(columns: 2, spacing: 14, fold: 446...465, loneSpans: true).rows(count: 2, width: 847)[0]
        XCTAssertLessThanOrEqual(wide[0].maxX, 434)
        XCTAssertGreaterThanOrEqual(wide[1].x, 477)
    }

    func testColumnsBarLeading() {
        let row = DuoColumnsLayout(columns: 2, spacing: 14, fold: foldLeadingBar, loneSpans: true).rows(count: 2, width: 847)[0]
        XCTAssertLessThanOrEqual(row[0].maxX, foldLeadingBar.lowerBound - DuoFold.clearance)
        XCTAssertGreaterThanOrEqual(row[1].x, foldLeadingBar.upperBound + DuoFold.clearance)
        XCTAssertEqual(row[0].width, 379.5, accuracy: 0.5)
        XCTAssertEqual(row[1].width, 443.5, accuracy: 0.5)
        // From the page: the override's fold at window 475.5, the page at x 84 with no leading margin.
        let page = CGRect(x: 84, y: 0, width: 867, height: 635)
        let values = DuoScopeValues.resolve(width: 867, margins: .measured(barEdge: .leading),
                                            division: DuoDisplay.innerLandscape(bar: .leading).verticalFold(in: page), active: false, typeSize: .large)
        XCTAssertEqual(values.fold.span, foldLeadingBar)
        XCTAssertEqual(values.contentWidth, 847)
    }

    func testMediumKeepsWebCounts() {
        // Sleep's three signals at medium: 3 across.
        let three = DuoGrid<[Int], Int, EmptyView>.columns(count: 3, band: .medium, fold: .none, medium: 3)
        XCTAssertEqual(three, 3)
        XCTAssertEqual(DuoColumnsLayout(columns: three, spacing: 14, fold: nil, loneSpans: true).rows(count: 3, width: 637).map(\.count), [3])
        // Three at medium 2: 2 + one spanning the row, as the web's .fill-row.
        let two = DuoGrid<[Int], Int, EmptyView>.columns(count: 3, band: .medium, fold: .none, medium: 2)
        XCTAssertEqual(two, 2)
        let spanning = DuoColumnsLayout(columns: two, spacing: 14, fold: nil, loneSpans: true).rows(count: 3, width: 637)
        XCTAssertEqual(spanning.map(\.count), [2, 1])
        XCTAssertEqual(spanning[0][0].width, 311.5, accuracy: 0.01)
        XCTAssertEqual(spanning[1][0], DuoColumnsLayout.Slot(x: 0, width: 637))
        // loneSpans: false keeps the short last row short (Vitals).
        let short = DuoColumnsLayout(columns: two, spacing: 14, fold: nil, loneSpans: false).rows(count: 3, width: 637)
        XCTAssertEqual(short[1][0].width, 311.5, accuracy: 0.01)
        // The web's fillColumns: 4 in a row of at most 3 is 2 × 2; 5 in 3 is 3 + 2, the 2 sharing the row.
        XCTAssertEqual(DuoGrid<[Int], Int, EmptyView>.fillColumns(4, max: 3), 2)
        XCTAssertEqual(DuoGrid<[Int], Int, EmptyView>.fillColumns(5, max: 3), 3)
        XCTAssertEqual(DuoGrid<[Int], Int, EmptyView>.fillColumns(1, max: 3), 1)
        let fiveInThree = DuoColumnsLayout(columns: 3, spacing: 14, fold: nil, loneSpans: true).rows(count: 5, width: 637)
        XCTAssertEqual(fiveInThree[1].map(\.width), [311.5, 311.5])
        // Compact: one per row, whatever the web's count.
        XCTAssertEqual(DuoGrid<[Int], Int, EmptyView>.columns(count: 3, band: .compact, fold: .none, medium: 3), 1)
    }

    func testSplitNeverSpans() {
        let rows = DuoColumnsLayout(columns: 2, spacing: 14, fold: foldTrailingBar, loneSpans: true).rows(count: 3, width: 847)
        XCTAssertEqual(rows.map(\.count), [2, 1])
        XCTAssertEqual(rows[1][0], rows[0][0], "the short last row's card is in the leading column, not across the fold")
        // One card alone, too.
        XCTAssertEqual(DuoColumnsLayout(columns: 2, spacing: 14, fold: foldTrailingBar, loneSpans: true).rows(count: 1, width: 847)[0][0].x, 0)
    }

    func testAX3StillSplits() {
        // Inner landscape at AX3: medium by band, but the vertical fold still splits it, two columns.
        let values = DuoScopeValues.resolve(width: 867, margins: .measured(barEdge: .trailing), division: 475.5...475.5, active: false,
                                            typeSize: .accessibility3)
        XCTAssertEqual(values.band, .medium)
        XCTAssertEqual(values.fold.span, foldTrailingBar)
        XCTAssertEqual(DuoGrid<[Int], Int, EmptyView>.columns(count: 5, band: values.band, fold: values.fold, medium: 3), 2)
        // And with no region reported, the middle fallback goes by width, not by the dropped band.
        XCTAssertNotNil(DuoScopeValues.resolve(width: 867, margins: .measured(barEdge: .trailing), division: nil, active: false,
                                               typeSize: .accessibility3).fold.span)
    }

    func testPairSplitsOnTheFold() async throws {
        let probe = DuoProbe()
        let page = DuoPage { _ in
            DuoScroll {
                DuoPair { probe.view("first") } second: { probe.view("second") }
            }
        }
        let host = try await DuoHost(page.environment(probe), as: .innerLandscape())
        defer { host.close() }
        let first = try XCTUnwrap(probe.frames["first"]), second = try XCTUnwrap(probe.frames["second"])
        XCTAssertEqual(first.minY, second.minY, "side by side")
        XCTAssertLessThanOrEqual(first.maxX, 475.5 - DuoFold.clearance)
        XCTAssertGreaterThanOrEqual(second.minX, 475.5 + DuoFold.clearance)
        XCTAssertEqual(first.minX, 20, "the page's leading margin")
        XCTAssertEqual(second.maxX, 867, "to the bar")
        // Stacked where the scope doesn't split.
        try await host.set(.innerPortrait())
        let a = try XCTUnwrap(probe.frames["first"]), b = try XCTUnwrap(probe.frames["second"])
        XCTAssertGreaterThan(b.minY, a.maxY)
        XCTAssertEqual(a.width, 637)
    }

    func testPairHalvesAreCompact() async throws {
        let probe = DuoProbe()
        let page = DuoPage { _ in DuoScroll { DuoPair { probe.view("first") } second: { probe.view("second") } } }
        let host = try await DuoHost(page.environment(probe), as: .innerLandscape())
        defer { host.close() }
        XCTAssertEqual(probe.bands["first"], .compact)
        XCTAssertEqual(probe.bands["second"], .compact)
        XCTAssertEqual(probe.folds["first"], DuoFold.none, "no fold inside a half")
        XCTAssertEqual(DuoPair<EmptyView, EmptyView>.halfBand(split: true, band: .wide), .compact)
        XCTAssertEqual(DuoPair<EmptyView, EmptyView>.halfBand(split: false, band: .medium), .medium)
        try await host.set(.innerPortrait())
        XCTAssertEqual(probe.bands["first"], .medium, "stacked, each half is the page's width")
    }

    func testOneSide() async throws {
        // duoOneSide() width = the fold's start − half the gap (the clearance), down to a whole point.
        XCTAssertEqual(DuoFold(span: foldTrailingBar, active: false).leadingWidth(), 443)
        XCTAssertEqual(DuoFold(span: foldLeadingBar, active: false).leadingWidth(), 379)
        XCTAssertNil(DuoFold.none.leadingWidth())
        let probe = DuoProbe()
        let page = DuoPage { _ in DuoScroll { probe.view("block").duoOneSide() } }
        let host = try await DuoHost(page.environment(probe), as: .innerLandscape())
        defer { host.close() }
        let block = try XCTUnwrap(probe.frames["block"])
        XCTAssertEqual(block.minX, 20)
        XCTAssertEqual(block.width, 443)
        XCTAssertEqual(probe.bands["block"], .compact)
        // Unchanged where the scope doesn't split.
        try await host.set(.innerPortrait())
        XCTAssertEqual(probe.frames["block"]?.width, 637)
    }

    func testLeadingOfFoldMargins() {
        let values = DuoScopeValues.resolve(width: 867, margins: .measured(barEdge: .trailing), division: 475.5...475.5, active: false,
                                            typeSize: .large, side: .leadingOfFold)
        XCTAssertEqual(values.margins.leading, 20)
        XCTAssertEqual(values.margins.trailing, 867 - 20 - 443, "the trailing margin reaches the fold, less the clearance")
        XCTAssertEqual(values.contentWidth, 443)
        XCTAssertEqual(values.band, .compact)
        XCTAssertEqual(values.fold, .none)
        // A cap (sign-in's 520) still keeps to the leading side.
        XCTAssertEqual(DuoScopeValues.resolve(width: 867, margins: .measured(barEdge: .trailing), division: 475.5...475.5, active: false,
                                              typeSize: .large, side: .leadingOfFold, maxWidth: 520).contentWidth, 443)
        // A capped full page that would straddle the fold without splitting keeps to the leading side too.
        XCTAssertEqual(DuoScopeValues.resolve(width: 867, margins: .measured(barEdge: .trailing), division: 475.5...475.5, active: false,
                                              typeSize: .large, maxWidth: 560).contentWidth, 443)
        // Unsplit: the whole width, or the cap.
        XCTAssertEqual(DuoScopeValues.resolve(width: 669, margins: .phone, division: nil, active: false, typeSize: .large,
                                              side: .leadingOfFold).contentWidth, 637)
        XCTAssertEqual(DuoScopeValues.resolve(width: 669, margins: .phone, division: nil, active: false, typeSize: .large,
                                              maxWidth: 560).margins.trailing, 16 + 77)
    }

    func testFloatingEdge() async throws {
        XCTAssertEqual(DuoFloatingRow<EmptyView>.edge(barEdge: nil), .trailing)
        XCTAssertEqual(DuoFloatingRow<EmptyView>.edge(barEdge: .trailing), .trailing)
        XCTAssertEqual(DuoFloatingRow<EmptyView>.edge(barEdge: .leading), .leading)
        // Never centred: the control sits at one end of its row.
        let row = CGSize(width: 382, height: 46)
        XCTAssertEqual(DuoFloatingRow<EmptyView>.place(CGSize(width: 157, height: 46), in: row, edge: .trailing).maxX, 382)
        XCTAssertEqual(DuoFloatingRow<EmptyView>.place(CGSize(width: 157, height: 46), in: row, edge: .leading).minX, 0)
        // Clear of an active occlusion by the smallest move, and below an active horizontal fold it meets.
        let control = CGRect(x: 225, y: 600, width: 157, height: 46)
        XCTAssertEqual(DuoFloatingRow<EmptyView>.move(control: control, occlusions: [CGRect(x: 360, y: 590, width: 40, height: 40)], fold: nil),
                       CGSize(width: -22, height: 0), "left, the smallest move")
        XCTAssertEqual(DuoFloatingRow<EmptyView>.move(control: control, occlusions: [CGRect(x: 0, y: 640, width: 466, height: 40)], fold: nil),
                       CGSize(width: 0, height: -6))
        XCTAssertEqual(DuoFloatingRow<EmptyView>.move(control: control, occlusions: [], fold: CGRect(x: 0, y: 590, width: 669, height: 20)),
                       CGSize(width: 0, height: 10))
        XCTAssertEqual(DuoFloatingRow<EmptyView>.move(control: control, occlusions: [], fold: nil), .zero)
        // Drawn: the pill's row with the bar leading, then trailing, then none.
        let probe = DuoProbe()
        let view = Color.clear.safeAreaInset(edge: .bottom) { DuoFloatingRow { probe.view("pill").frame(width: 120, height: 44) } }
        let host = try await DuoHost(view.environment(probe), as: .innerLandscape(bar: .leading))
        defer { host.close() }
        XCTAssertEqual(probe.frames["pill"]?.minX, 84, "bottom-leading beside a leading bar")
        try await host.set(.innerLandscape())
        XCTAssertEqual(probe.frames["pill"]?.maxX, 867, "bottom-trailing")
        try await host.set(.innerPortrait())
        XCTAssertEqual(probe.frames["pill"]?.maxX, 669, "bottom-trailing with no bar")
    }

    func testTableWindow() {
        XCTAssertEqual(DuoBand.compact.tableWindow(scopeHeight: 600), 360, "every iPhone and the outer display: as today")
        XCTAssertEqual(DuoBand.medium.tableWindow(scopeHeight: 661), 297, "the centred inner sheet: 45% of 661")
        XCTAssertEqual(DuoBand.medium.tableWindow(scopeHeight: 951), 360)
        XCTAssertEqual(DuoBand.wide.tableWindow(scopeHeight: nil), 360, "outside a scope")
        var environment = EnvironmentValues()
        XCTAssertEqual(environment.duoTableWindow, 360)
        environment.duoBand = .medium
        environment.duoScopeHeight = 661
        XCTAssertEqual(environment.duoTableWindow, 297)
    }

    /// SheetScaffold is its own scope: a sheet wider than its SheetSize keeps its column at the web's Sheet width,
    /// centred; every iPhone's sheet is narrower, so it keeps its 18 pt sides. Its band is its own (no split).
    func testSheetSizeCapsTheColumn() async throws {
        let probe = DuoProbe()
        let small = SheetScaffold(title: "Key", size: .sm) { probe.view("sm") }
        let host = try await DuoHost(small.environment(probe), as: .innerPortrait())
        defer { host.close() }
        XCTAssertEqual(probe.frames["sm"]?.minX, 18 + 94.5, "(669 − 480) / 2 more on each side")
        XCTAssertEqual(probe.frames["sm"]?.width, 480 - 36)
        XCTAssertEqual(probe.bands["sm"], .compact)
        XCTAssertNil(probe.folds["sm"]?.span)
        let probe2 = DuoProbe()
        let medium = SheetScaffold(title: "Basics") { probe2.view("md") }
        let wide = try await DuoHost(medium.environment(probe2), as: .innerLandscape())
        defer { wide.close() }
        XCTAssertEqual(probe2.frames["md"]?.width, 650 - 36, "capped at 650")
        XCTAssertEqual(probe2.bands["md"], .medium)
        XCTAssertNil(probe2.folds["md"]?.span, "a sheet never splits")
        // A sheet narrower than .md (every iPhone's, and the outer display's): its 18 pt sides, as before.
        let probe3 = DuoProbe()
        let phone = try await DuoHost(SheetScaffold(title: "Phone") { probe3.view("phone") }.environment(probe3), as: .outer)
        defer { phone.close() }
        XCTAssertEqual(probe3.frames["phone"]?.minX, 18)
        XCTAssertEqual(probe3.frames["phone"]?.width, 382 - 36)
    }

    /// Drawn tests run on iOS 27.0, where a sheet has no NavigationStack, so a bar of its own can't hold Close: with the
    /// outer display's bar edge injected, SheetScaffold keeps its round × (on the Duo, 27.1, Close is in the bar).
    func testDrawnSheetsKeepTheirClose() async throws {
        for state: DuoState in [.outer, .innerPortrait(), .innerLandscape()] {
            let host = try await DuoHost(SheetScaffold(title: "T") { Text("body") }, as: state)
            defer { host.close() }
            let labels = try await host.elements().compactMap(\.accessibilityLabel)
            XCTAssertTrue(labels.contains("Close"), "\(state): \(labels)")
        }
        let atLeast27_1 = ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 27, minorVersion: 1, patchVersion: 0))
        XCTAssertEqual(DuoSheetStack<EmptyView>.stacks, atLeast27_1)
    }

    func testChartHeight() {
        XCTAssertEqual(DuoBand.compact.chartHeight(200), 200)
        XCTAssertEqual(DuoBand.medium.chartHeight(200), 260)
        XCTAssertEqual(DuoBand.wide.chartHeight(200), 260)
    }

    func testMoreSymbol() {
        XCTAssertEqual(AppTab.more.symbol(verticalBar: true), "square.grid.2x2")
        XCTAssertEqual(AppTab.more.symbol(verticalBar: false), "ellipsis")
        XCTAssertEqual(AppTab.settings.symbol(verticalBar: true), "square.grid.2x2")
        for tab in [AppTab.home, .vitals, .body, .nutrition] {
            XCTAssertEqual(tab.symbol(verticalBar: true), tab.symbol)
            XCTAssertEqual(tab.symbol(verticalBar: false), tab.symbol)
        }
    }

    func testFoldFromOverride() async throws {
        // Window points to a scope's x, through its global frame.
        let landscape = DuoDisplay.innerLandscape()
        XCTAssertEqual(landscape.verticalFold(in: CGRect(x: 0, y: 0, width: 867, height: 635)), 475.5...475.5)
        XCTAssertEqual(landscape.verticalFold(in: CGRect(x: 84, y: 0, width: 867, height: 635)), 391.5...391.5)
        XCTAssertEqual(landscape.verticalFold(in: CGRect(x: 0, y: 0, width: 867, height: 635), direction: .rightToLeft), 391.5...391.5,
                       "mirrored, as the system's default .mirrors")
        XCTAssertNil(landscape.verticalFold(in: CGRect(x: 500, y: 0, width: 300, height: 635)), "a fold that doesn't meet the scope")
        XCTAssertNil(DuoDisplay.innerPortrait().verticalFold(in: CGRect(x: 0, y: 0, width: 669, height: 917)), "a horizontal fold")
        XCTAssertEqual(DuoDisplay.innerPortrait().horizontalFold(in: CGRect(x: 0, y: 100, width: 669, height: 817))?.minY, 375.5)
        XCTAssertEqual(DuoDisplay.outer.occlusions(in: CGRect(x: 0, y: 0, width: 382, height: 644)).count, 1, "the status bar's region only touches")
        // Drawn: a page reads it in its content's coordinates.
        let probe = DuoProbe()
        let page = DuoPage { _ in DuoScroll { probe.view("content") } }
        let host = try await DuoHost(page.environment(probe), as: .innerLandscape())
        defer { host.close() }
        XCTAssertEqual(probe.folds["content"], DuoFold(span: foldTrailingBar, active: false))
        XCTAssertEqual(probe.margins["content"], DuoMargins(leading: 20, trailing: 0))
        XCTAssertEqual(probe.edges["content"], .some(.trailing))
        try await host.set(.innerLandscape(foldActive: true, bar: .leading))
        XCTAssertEqual(probe.folds["content"], DuoFold(span: foldLeadingBar, active: true))
        XCTAssertEqual(probe.margins["content"], DuoMargins(leading: 0, trailing: 20))
        try await host.set(.outer)
        XCTAssertEqual(probe.folds["content"], DuoFold.none)
        XCTAssertEqual(probe.bands["content"], .compact)
        XCTAssertEqual(probe.frames["content"]?.width, 362)
    }

    /// Drawn: a page-tabs row and a TextEditor inside DuoScroll start at x 0 of their own frame (the page's margins
    /// don't reach a nested scroll view), and duoBleed's row runs to the page's edges with its first item on the page's.
    func testNestedScrollKeepsItsMargins() async throws {
        let probe = DuoProbe()
        let page = DuoPage { _ in
            DuoScroll {
                VStack(alignment: .leading, spacing: 10) {
                    ScrollView(.horizontal) { HStack { probe.view("tab").frame(width: 80, height: 30) } }
                        .frame(height: 30)
                        .background { probe.view("row") }
                    ScrollView(.horizontal) { HStack { probe.view("bledTab").frame(width: 80, height: 30) } }
                        .frame(height: 30)
                        .background { probe.view("bledRow") }
                        .duoBleed()
                    TextEditor(text: .constant("Words"))
                        .frame(height: 80)
                        .accessibilityIdentifier("nestedEditor")
                }
            }
        }
        let host = try await DuoHost(page.environment(probe), as: .outer)
        defer { host.close() }
        let row = try XCTUnwrap(probe.frames["row"]), tab = try XCTUnwrap(probe.frames["tab"])
        XCTAssertEqual(row.minX, 20, "the row sits on the page's margin")
        XCTAssertEqual(tab.minX, row.minX, "its first item at x 0 of the row: no margin inherited")
        let bledRow = try XCTUnwrap(probe.frames["bledRow"]), bledTab = try XCTUnwrap(probe.frames["bledTab"])
        XCTAssertEqual(bledRow.minX, 0, "duoBleed: to the page's leading edge")
        XCTAssertEqual(bledRow.maxX, 382, "and its trailing one")
        XCTAssertEqual(bledTab.minX, 20, "its first item lined up with the page")
        // The TextEditor's text starts where the same editor's does outside any DuoScroll.
        let inside = try XCTUnwrap(Self.textOffset(in: host.window))
        let plain = try await DuoHost(TextEditor(text: .constant("Words")).frame(width: 362, height: 80), as: .outer)
        defer { plain.close() }
        let outside = try XCTUnwrap(Self.textOffset(in: plain.window))
        XCTAssertEqual(inside, outside, accuracy: 0.5)
    }

    // MARK: - decisions.md Q5: two columns inside a pane

    func testPaneColumnsNeedTheMinimumAndNoAccessibilitySize() {
        XCTAssertEqual(DuoPaneColumns.count(2, width: 379, typeSize: .large), 2, "the trailing pane: 182.5 each")
        XCTAssertEqual(DuoPaneColumns.count(2, width: 443, typeSize: .large), 2, "the leading pane: 214.5 each")
        XCTAssertEqual(DuoPaneColumns.count(2, width: 354, typeSize: .large), 2, "170 each, the minimum")
        XCTAssertEqual(DuoPaneColumns.count(2, width: 353, typeSize: .large), 1, "169.5 each")
        XCTAssertEqual(DuoPaneColumns.count(2, width: 300, typeSize: .large), 1)
        XCTAssertEqual(DuoPaneColumns.count(2, width: 379, typeSize: .xxxLarge), 2, "xxxLarge isn't an accessibility size")
        XCTAssertEqual(DuoPaneColumns.count(2, width: 443, typeSize: .accessibility1), 1)
        XCTAssertEqual(DuoPaneColumns.count(2, width: 443, typeSize: .accessibility3), 1)
        XCTAssertEqual(DuoPaneColumns.count(3, width: 443, typeSize: .large), 2, "three of 138 don't fit, two do")
        XCTAssertEqual(DuoPaneColumns.count(1, width: 443, typeSize: .large), 1)
        XCTAssertEqual(DuoPaneColumns.count(2, width: nil, typeSize: .large), 1, "outside any scope")
    }

    func testASpanningCellTakesARowOnlyWhereSpansCount() {
        let pane = DuoColumnsLayout(columns: 2, spacing: 14, loneSpans: true, honoursSpans: true)
        let rows = pane.rows(spans: [false, false, true, false, false, false], width: 379)
        XCTAssertEqual(rows.map(\.count), [2, 1, 2, 1])
        XCTAssertEqual(rows[0], [.init(x: 0, width: 182.5), .init(x: 196.5, width: 182.5)])
        XCTAssertEqual(rows[1], [.init(x: 0, width: 379)], "the spanning card across the pane")
        XCTAssertEqual(rows[3], [.init(x: 0, width: 379)], "a lone last card spans, as the web's fill-row")
        // A span in the middle of a row ends that row short.
        let middle = pane.rows(spans: [false, true, false, false], width: 379)
        XCTAssertEqual(middle.map(\.count), [1, 1, 2])
        XCTAssertEqual(middle[0], [.init(x: 0, width: 379)])
        // Not honoured (every grid outside a pane): an ordinary cell, the rows as before.
        let page = DuoColumnsLayout(columns: 2, spacing: 14, loneSpans: true)
        XCTAssertEqual(page.rows(spans: [false, true, false], width: 637), page.rows(count: 3, width: 637))
        // Never across a fold, even if asked: the short row stays in the leading column.
        let split = DuoColumnsLayout(columns: 2, spacing: 14, fold: foldTrailingBar, loneSpans: true, honoursSpans: true)
        let splitRows = split.rows(spans: [false, true, false], width: 847)
        XCTAssertEqual(splitRows.map(\.count), [2, 1])
        XCTAssertEqual(splitRows[1], [.init(x: 0, width: 443)])
    }

    /// Drawn: `paneColumns: 2` gives two columns inside the trailing pane (488–867) and a `.duoSpans()` card the pane's
    /// width; one column at AX3. The same grid as the page's single column is exactly as a plain DuoGrid on the outer
    /// display (one column) and upright (the web's 2-up, the span ignored), so no iPhone changes.
    func testPaneColumnsOnlyInsideAPane() async throws {
        let names = ["a", "b", "chart", "c"]
        // First, a plain DuoGrid of the same cards as a page's only column, on the outer display and upright.
        var plain: [String: [String: CGRect]] = [:]
        let plainProbe = DuoProbe()
        let plainPage = DuoPage { _ in DuoScroll { DuoGrid(names, id: \.self) { plainProbe.view($0) } } }
        let plainHost = try await DuoHost(plainPage.environment(plainProbe), as: .outer)
        for state: DuoState in [.outer, .innerPortrait()] {
            try await plainHost.set(state)
            plain["\(state)"] = plainProbe.frames
        }
        plainHost.close()

        let probe = DuoProbe()
        let grid = DuoGrid(names, id: \.self, paneColumns: 2) { name in
            if name == "chart" { probe.view(name).duoSpans() } else { probe.view(name) }
        }
        let page = DuoPage { _ in DuoPanes { probe.view("picture") } secondary: { grid } single: { grid } }
        let host = try await DuoHost(page.environment(probe), as: .innerLandscape())
        defer { host.close() }
        let a = try XCTUnwrap(probe.frames["a"]), b = try XCTUnwrap(probe.frames["b"])
        let chart = try XCTUnwrap(probe.frames["chart"]), c = try XCTUnwrap(probe.frames["c"])
        XCTAssertEqual(a.minX, 488)
        XCTAssertEqual(a.width, 182.5)
        XCTAssertEqual(b.minY, a.minY, "side by side")
        XCTAssertEqual(b.maxX, 867)
        XCTAssertEqual(chart.minX, 488)
        XCTAssertEqual(chart.width, 379, "across the pane")
        XCTAssertGreaterThan(chart.minY, a.maxY)
        XCTAssertEqual(c.width, 379, "a lone last card spans the pane")
        XCTAssertEqual(probe.bands["a"], .compact)
        XCTAssertLessThanOrEqual(try XCTUnwrap(probe.frames["picture"]).maxX, 463, "the picture in the leading pane")
        // The accessibility sizes: one column.
        try await host.set(.innerLandscape(), typeSize: .accessibility3)
        XCTAssertEqual(probe.frames["a"]?.width, 379)
        XCTAssertGreaterThan(try XCTUnwrap(probe.frames["b"]).minY, try XCTUnwrap(probe.frames["a"]).maxY)
        try await host.set(.innerLandscape(), typeSize: .large)
        XCTAssertEqual(probe.frames["a"]?.width, 182.5)
        // The page's single column: exactly the plain grid's.
        for state: DuoState in [.outer, .innerPortrait()] {
            try await host.set(state)
            for name in names {
                XCTAssertEqual(probe.frames[name], plain["\(state)"]?[name], "\(name) in \(state)")
            }
        }
        XCTAssertEqual(probe.frames["chart"]?.width, (637 - 14) / 2, "upright, the span is an ordinary cell")
    }

    func testAPairGoesSideBySideInAPaneOnlyWhenAsked() async throws {
        let probe = DuoProbe()
        let page = DuoPage { _ in
            DuoPanes {
                DuoPair { probe.view("chart1") } second: { probe.view("chart2") }
            } secondary: {
                DuoPair(paneSideBySide: true) { probe.view("small1") } second: { probe.view("small2") }
            } single: {
                DuoPair(paneSideBySide: true) { probe.view("small1") } second: { probe.view("small2") }
            }
        }
        let host = try await DuoHost(page.environment(probe), as: .innerLandscape())
        defer { host.close() }
        let s1 = try XCTUnwrap(probe.frames["small1"]), s2 = try XCTUnwrap(probe.frames["small2"])
        XCTAssertEqual(s1.minY, s2.minY, "side by side in the pane")
        XCTAssertEqual(s1.width, 182.5)
        XCTAssertEqual(s2.maxX, 867)
        XCTAssertEqual(probe.bands["small1"], .compact)
        let c1 = try XCTUnwrap(probe.frames["chart1"]), c2 = try XCTUnwrap(probe.frames["chart2"])
        XCTAssertGreaterThan(c2.minY, c1.maxY, "a plain pair stacks in a pane")
        XCTAssertEqual(c1.width, 443)
        // Stacked at AX3, and in the single column (the outer display).
        try await host.set(.innerLandscape(), typeSize: .accessibility3)
        XCTAssertGreaterThan(try XCTUnwrap(probe.frames["small2"]).minY, try XCTUnwrap(probe.frames["small1"]).maxY)
        try await host.set(.innerLandscape(), typeSize: .large)
        try await host.set(.outer)
        XCTAssertGreaterThan(try XCTUnwrap(probe.frames["small2"]).minY, try XCTUnwrap(probe.frames["small1"]).maxY)
        XCTAssertEqual(probe.frames["small1"]?.width, 362)
    }

    /// Where a text view's first character sits, from the text view's own leading edge, on screen.
    private static func textOffset(in view: UIView) -> CGFloat? {
        if let text = view as? UITextView {
            let caret = text.caretRect(for: text.beginningOfDocument)
            return text.convert(caret, to: nil).minX - text.convert(text.bounds, to: nil).minX
        }
        for sub in view.subviews { if let x = textOffset(in: sub) { return x } }
        return nil
    }
}

/// Records what the blocks give the views inside them: each probe's frame (window points), band, fold, margins and
/// bar edge, by name.
@MainActor @Observable
final class DuoProbe {
    var frames: [String: CGRect] = [:]
    var bands: [String: DuoBand] = [:]
    var folds: [String: DuoFold] = [:]
    var margins: [String: DuoMargins] = [:]
    var edges: [String: HorizontalEdge?] = [:]

    func view(_ name: String) -> some View { DuoProbeView(name: name) }
}

private struct DuoProbeView: View {
    let name: String
    @Environment(DuoProbe.self) private var probe
    @Environment(\.duoBand) private var band
    @Environment(\.duoFold) private var fold
    @Environment(\.duoMargins) private var margins
    @Environment(\.duoBarEdge) private var edge

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity, minHeight: 20)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { probe.frames[name] = $0 }
            .onChange(of: Seen(band: band, fold: fold, margins: margins, edge: edge), initial: true) { _, seen in
                probe.bands[name] = seen.band
                probe.folds[name] = seen.fold
                probe.margins[name] = seen.margins
                probe.edges[name] = .some(seen.edge)
            }
    }

    private struct Seen: Equatable {
        let band: DuoBand
        let fold: DuoFold
        let margins: DuoMargins
        let edge: HorizontalEdge?
    }
}
