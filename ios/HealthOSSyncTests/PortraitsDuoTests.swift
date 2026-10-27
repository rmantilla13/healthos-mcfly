import SwiftUI
import XCTest
@testable import HealthOSSync

/// Profile's two open-in-place cards on iPhone Duo (duo/design.md §9c, slice F; decisions.md Q5): the portrait studio's
/// tiles keep their own grid (two to a row on the phone, one at the accessibility sizes, as many 156 pt tiles as fit
/// where wider, rounded down to an even count), the comparison goes two to a row in a pane of the open Duo, the studio's
/// dialogs sit on the buttons that ask, and what the cards hold survives a fold.
///
/// The drawn states host the cards the way Q5 places them on Profile: the chosen portrait in the leading pane, and the
/// comparison and the studio, open, in the trailing one (one column everywhere else). PNGs go to TEST_RUNNER_DUO_SHOTS
/// (`d-<state>-<light|dark>[-<size>].png`).
@MainActor
final class PortraitsDuoTests: XCTestCase {
    // MARK: Fixtures

    private func fixture(_ name: String) throws -> Data {
        let url = Bundle(for: Self.self).url(forResource: name, withExtension: "json")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name).json")
        return try XCTUnwrap(try? Data(contentsOf: url), "missing fixture \(name).json")
    }

    private func figure() throws -> Data {
        try XCTUnwrap(UIImage(named: "DigitalMan", in: Bundle(for: Dashboard.self), with: nil)?.pngData())
    }

    /// Counts the list reads; every other call is a stand-in that does nothing.
    private final class Reads { var list = 0 }

    private func service(_ reads: Reads, list: PortraitList?, image: Data) -> PortraitService {
        PortraitService(
            list: { reads.list += 1; return list },
            addReference: { _ in Portrait(id: "r-new", kind: "reference", status: "ready") },
            generate: { _ in Portrait(id: "new", kind: "generated", status: "pending") },
            delete: { _ in try XCTUnwrap(list) },
            choose: { _ in try XCTUnwrap(list) },
            image: { _ in image },
            cutOut: { _ in throw PhotoCutout.Failure(message: "unused") },
            upload: { _ in },
            usePortraitPerspective: {},
            photoChanged: {},
            sleep: { _ in throw CancellationError() })
    }

    /// The studio with portrait-studio.json's references and portraits (none being made, so nothing polls), each
    /// picture the digital man.
    private func studio(_ reads: Reads = Reads()) async throws -> PortraitStudioModel {
        let full = try JSONDecoder().decode(PortraitList.self, from: fixture("portraits-studio"))
        let list = PortraitList(portraits: full.portraits.filter { $0.status != "pending" }, chosen: full.chosen, canGenerate: true)
        let model = PortraitStudioModel(service: service(reads, list: list, image: try figure()))
        await model.read()
        for p in model.portraits { await model.loadThumbnail(p, maxPixel: p.kind == "reference" ? 240 : 600) }
        return model
    }

    private func peers() throws -> PeerData { try JSONDecoder().decode(PeerData.self, from: fixture("peers-ready")) }

    // MARK: The page as Q5 lays it out

    /// Profile's frame on the open Duo, with only these cards: the chosen portrait leading, the cards trailing.
    private struct CardsPage: View {
        let studio: PortraitStudioModel
        let peers: PeerData
        let asks: PortraitAsks
        /// The studio above the comparison, so a first screen shows its tiles (the `d-2-` pictures).
        var studioFirst = false

        var body: some View {
            DuoPage { _ in
                DuoPanes(anchor: .secondary) {
                    chosen.padding(.vertical, 16)
                } secondary: {
                    cards
                } single: {
                    cards
                }
            }
            .background(Palette.page.ignoresSafeArea())
        }

        /// The picture Profile's leading pane holds (D's): here the chosen portrait.
        private var chosen: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text("Your portrait").font(.app(.headline)).foregroundStyle(Palette.ink)
                if let id = studio.chosen, let image = studio.thumbs[id] {
                    Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: 260)
                        .background(GradientFill(.gradCream))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .accessibilityLabel("The portrait in use")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        private var cards: some View {
            VStack(alignment: .leading, spacing: 18) {
                if !studioFirst { comparison }
                Collapsible("Your portrait photos", meta: "\(studio.portraits.count) files", systemImage: "camera", startsOpen: true) {
                    PortraitStudioContent(model: studio, byok: true, ownKey: true, asks: asks)
                }
                if studioFirst { comparison }
            }
            .padding(.vertical, 16)
        }

        private var comparison: some View {
            Collapsible(PeerWords.title, meta: PeerWords.meta, systemImage: "chart.bar", startsOpen: true) {
                PeerContent(data: peers, error: nil)
            }
        }
    }

    private func page(studioFirst: Bool = false) async throws -> CardsPage {
        CardsPage(studio: try await studio(), peers: try peers(), asks: PortraitAsks(), studioFirst: studioFirst)
    }

    // MARK: The math

    /// Two on every iPhone and in every Duo state (one at the accessibility sizes); where four 156 pt tiles fit, four.
    /// The widths are the grid's: a card's 18 pt sides off the content, then the web's 68 pt indent where it applies.
    func testTileColumns() {
        let phone: [CGFloat] = [334, 307, 372, 326]   // 18 Pro, SE, Pro Max, the outer display
        for w in phone {
            XCTAssertEqual(PortraitTileColumns.count(width: w, band: .compact, accessibility: false), 2, "\(w)")
            XCTAssertEqual(PortraitTileColumns.count(width: w, band: .compact, accessibility: true), 1, "\(w)")
        }
        XCTAssertEqual(PortraitTileColumns.count(width: 601, band: .medium, accessibility: false), 2, "upright: 3 fit, rounded down to 2")
        XCTAssertEqual(PortraitTileColumns.count(width: 343, band: .compact, accessibility: false), 2, "a pane, bar trailing")
        XCTAssertEqual(PortraitTileColumns.count(width: 407, band: .compact, accessibility: false), 2, "a pane, bar leading")
        XCTAssertEqual(PortraitTileColumns.count(width: 654, band: .wide, accessibility: false), 4)
        XCTAssertEqual(PortraitTileColumns.count(width: 653, band: .wide, accessibility: false), 2)
        XCTAssertEqual(PortraitTileColumns.count(width: 998, band: .wide, accessibility: false), 6)
        XCTAssertEqual(PortraitTileColumns.count(width: 900, band: .medium, accessibility: true), 1)
        XCTAssertEqual(PortraitTileColumns.count(width: 120, band: .medium, accessibility: false), 2, "never fewer than two")
    }

    /// One to a row everywhere but a pane (the web's 300 pt rows need a 610 pt card); two in a pane while each is 156.
    func testPeerColumns() {
        for w: CGFloat in [307, 334, 372, 326, 601] {
            XCTAssertEqual(PeerColumns.count(width: w, inPane: false, typeSize: .large), 1, "\(w)")
        }
        XCTAssertEqual(PeerColumns.count(width: 610, inPane: false, typeSize: .large), 2, "the web's auto-fill")
        XCTAssertEqual(PeerColumns.count(width: 343, inPane: true, typeSize: .large), 2, "a pane, bar trailing: 166.5 each")
        XCTAssertEqual(PeerColumns.count(width: 407, inPane: true, typeSize: .large), 2)
        XCTAssertEqual(PeerColumns.count(width: 320, inPane: true, typeSize: .large), 1, "155 a column is under a tile")
        XCTAssertEqual(PeerColumns.count(width: 407, inPane: true, typeSize: .accessibility3), 1)
    }

    func testCardColumnsLayout() {
        let two = CardColumnsLayout(spacing: 10) { _ in 2 }
        XCTAssertEqual(two.rows(count: 3, width: 330).map { $0.map(\.x) }, [[0, 170], [0]], "a short last row keeps its column")
        XCTAssertEqual(two.rows(count: 3, width: 330).flatMap { $0.map(\.width) }, [160, 160, 160])
        let one = CardColumnsLayout(spacing: 10) { _ in 1 }
        XCTAssertEqual(one.rows(count: 2, width: 330).flatMap { $0 }, [.init(x: 0, width: 330), .init(x: 0, width: 330)])
    }

    // MARK: Drawn (d), with the fold

    func testOuter() async throws { try await drawn(.outer) }
    func testInnerPortrait() async throws { try await drawn(.innerPortrait()) }
    func testInnerLandscape() async throws { try await drawn(.innerLandscape()) }
    func testInnerLandscapeFoldActive() async throws { try await drawn(.innerLandscape(foldActive: true)) }
    func testInnerLandscapeBarLeading() async throws { try await drawn(.innerLandscape(bar: .leading)) }
    func testInnerSplitView() async throws {
        try await drawn(.innerSplit(bar: .leading))
        try await drawn(.innerSplit(bar: .trailing))
    }

    /// `d-…`: the comparison first; `d-2-…`: the studio first, so a first screen shows its tiles.
    private func drawn(_ state: DuoState) async throws {
        for (name, studioFirst) in [("d", false), ("d-2", true)] {
            let view = try await page(studioFirst: studioFirst)
            for dark in [false, true] {
                for size: DynamicTypeSize in [.large, .accessibility3] {
                    try await DuoSnapshot.draw(view, as: state, dark: dark, typeSize: size, name: name)
                }
            }
        }
    }

    /// Nothing tappable on the fold (D10, P6), flat and active, bar trailing and leading, at the default size and AX3.
    func testNothingTappableOnTheFold() async throws {
        let view = try await page()
        for state in DuoState.folded {
            for size: DynamicTypeSize in [.large, .accessibility3] {
                try await DuoFoldAssertions.assertNothingTappableOnTheFold(view, state: state, typeSize: size)
            }
        }
    }

    /// Q5's frame as drawn: the cards in the trailing pane, the tiles two to a row there and the comparison's rows two
    /// to a row; the outer display keeps one comparison row to a line.
    func testTheTrailingPaneHoldsTwoColumns() async throws {
        let view = try await page()
        let host = try await DuoHost(view, as: .innerLandscape())
        defer { host.close() }
        let elements = try await host.elements()
        func frames(_ prefix: String) -> [CGRect] {
            elements.filter { ($0.accessibilityLabel ?? "").hasPrefix(prefix) }.map(\.accessibilityFrame)
        }
        let tiles = frames("Delete the portrait")
        XCTAssertFalse(tiles.isEmpty)
        // A measurement's row reads as one, starting with its heading ("Resting heart rate · Apple Health").
        let sources = ["WHOOP", "Apple Health", "Sample"].map { " · \($0)" }
        let peerRows = elements.filter { e in sources.contains { (e.accessibilityLabel ?? "").contains($0) } && e.accessibilityFrame.height > 40 }
            .map(\.accessibilityFrame)
        XCTAssertGreaterThanOrEqual(peerRows.count, 2)
        // The bar's trailing: the pane runs from 488 to 867.
        for f in tiles + peerRows { XCTAssertGreaterThanOrEqual(f.minX, 487, "\(f)"); XCTAssertLessThanOrEqual(f.maxX, 868, "\(f)") }
        XCTAssertEqual(Set(peerRows.map { $0.minX.rounded() }).count, 2, "two columns of measurements: \(peerRows)")
        XCTAssertEqual(Set(tiles.map { $0.minX.rounded() }).count, 2, "two columns of tiles: \(tiles)")
    }

    // MARK: Dialogs on their buttons (P10)

    /// Each Delete and each Use asks on its own button: the question for one is shown only by that one.
    func testEachQuestionBelongsToItsButton() async throws {
        let model = try await studio()
        let asks = PortraitAsks()
        asks.deleting = model.references[0]
        XCTAssertEqual(asks.deleting?.id, model.references[0].id)
        asks.clear()
        XCTAssertNil(asks.deleting)
        XCTAssertNil(asks.replacing)
        XCTAssertFalse(asks.askSource)
        asks.add(camera: false)
        XCTAssertTrue(asks.pickerShown, "no camera: straight to Photos")
        asks.add(camera: true)
        XCTAssertTrue(asks.askSource, "a camera: ask which")
        // The studio's file no longer hangs its dialogs on the whole studio.
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("HealthOSSync/Portraits/PortraitStudio.swift"), encoding: .utf8)
        let studioBody = try XCTUnwrap(source.components(separatedBy: "struct PortraitStudioContent").first)
        XCTAssertFalse(studioBody.contains(".confirmationDialog("), "PortraitStudio itself presents no dialog")
        XCTAssertTrue(source.contains(".modifier(AddSourceDialog(asks: asks))"))
        XCTAssertEqual(source.components(separatedBy: ".modifier(DeleteDialog(").count - 1, 2, "the reference row's Delete and each tile's")
        XCTAssertTrue(source.contains(".modifier(ReplaceDialog("))
    }

    // MARK: State across a fold (P4, P14)

    private final class NoServer: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"error":"Not found"}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    override func setUp() async throws { APIClient.answering(with: [NoServer.self]) }
    override func tearDown() async throws { APIClient.answering(with: []) }

    /// The real card, signed in, on a page that keeps it above its panes: the fold's swap (one column ↔ two panes)
    /// finds the same model again and reads nothing more.
    func testPaneSwapKeepsTheCardAndDoesNotReadAgain() async throws {
        let dashboard = Dashboard()
        dashboard.signedIn()
        let person = try XCTUnwrap(dashboard.signedInPerson)
        let keep = ProfileCardsKeep()
        let reads = Reads()
        let model = keep.studio(for: person)
        model.service = service(reads, list: PortraitList(portraits: [], chosen: nil, canGenerate: false), image: Data())
        let page = DuoPage { _ in
            DuoPanes(anchor: .secondary) { Text("Lead") } secondary: { PortraitPhotosSection() } single: { PortraitPhotosSection() }
        }
        .profileCards(keep)
        .environment(dashboard)
        let host = try await DuoHost(page, as: .outer)
        defer { host.close() }
        XCTAssertEqual(reads.list, 1, "read once on showing")
        for state: DuoState in [.innerLandscape(), .outer, .innerLandscape(bar: .leading), .innerPortrait()] {
            try await host.set(state)
            XCTAssertEqual(reads.list, 1, "no second read after \(state)")
            XCTAssertTrue(keep.currentStudio(for: person) === model, "the same model after \(state)")
        }
        // Someone else signing in (or a sign-out) takes it all away.
        keep.retain(only: nil)
        XCTAssertNil(keep.currentStudio(for: person))
        XCTAssertFalse(keep.peers(for: "other") === keep.peers(for: "other|x"))
    }

    /// The band changes under a plain page (no panes, P14): the open card stays open, its tiles stay, nothing is read
    /// again, and the studio's question on its button is still asked.
    func testStateSurvivesBandChange() async throws {
        let reads = Reads()
        let model = try await studio(reads)
        let readsBefore = reads.list
        let asks = PortraitAsks()
        let view = DuoPage { _ in
            DuoScroll {
                Collapsible("Your portrait photos", systemImage: "camera") {
                    PortraitStudioContent(model: model, byok: true, ownKey: true, asks: asks)
                }
                .padding(.vertical, 16)
            }
        }
        let host = try await DuoHost(view, as: .outer)
        defer { host.close() }
        let found = try await host.elements()
        let header = try XCTUnwrap(found.first { ($0.accessibilityLabel ?? "").contains("Your portrait photos") })
        XCTAssertTrue(header.accessibilityActivate(), "the card opens")
        try await host.settle()
        func addShown() async throws -> Bool {
            try await host.elements().contains { $0.accessibilityLabel == PortraitWords.add }
        }
        let opened = try await addShown()
        XCTAssertTrue(opened, "the studio shows once the card is open")
        for state: DuoState in [.innerLandscape(), .innerPortrait(), .innerSplit(bar: .trailing), .outer] {
            try await host.set(state)
            let still = try await addShown()
            XCTAssertTrue(still, "still open after \(state)")
            XCTAssertEqual(reads.list, readsBefore, "no read after \(state)")
        }
    }

    /// The same, the other way round: the band change itself never reads (P14's testBandChangeDoesNotReload), with the
    /// real card on a plain page.
    func testBandChangeDoesNotReload() async throws {
        let dashboard = Dashboard()
        dashboard.signedIn()
        let person = try XCTUnwrap(dashboard.signedInPerson)
        let keep = ProfileCardsKeep()
        let reads = Reads()
        keep.studio(for: person).service = service(reads, list: PortraitList(portraits: [], chosen: nil, canGenerate: false), image: Data())
        let page = DuoPage { _ in DuoScroll { PortraitPhotosSection().padding(.vertical, 16) } }
            .profileCards(keep)
            .environment(dashboard)
        let host = try await DuoHost(page, as: .outer)
        defer { host.close() }
        XCTAssertEqual(reads.list, 1)
        for state: DuoState in [.innerPortrait(), .innerLandscape(), .outer] {
            try await host.set(state)
            XCTAssertEqual(reads.list, 1, "\(state)")
        }
    }
}
