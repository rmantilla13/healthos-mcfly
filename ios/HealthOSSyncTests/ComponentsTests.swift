import XCTest
import SwiftUI
import UIKit
@testable import HealthOSSync

/// The shared pieces draw what the web draws: washes strongest at the bottom, the orb's dark core, the sheet's footer
/// only when it has one.
@MainActor
final class ComponentsTests: XCTestCase {
    /// The view drawn at 1× in a colour scheme, as RGBA bytes.
    private func pixels<V: View>(_ view: V, width: Int, height: Int, scheme: ColorScheme = .light) throws -> (Int, Int) -> [Int] {
        let renderer = ImageRenderer(content: view.frame(width: CGFloat(width), height: CGFloat(height)).environment(\.colorScheme, scheme))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let ctx = try XCTUnwrap(CGContext(data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return { x, y in
            let i = (y * width + x) * 4
            return (0..<4).map { Int(data[i + $0]) }
        }
    }

    func testAWashIsStrongestNearTheBottom() throws {
        // --grad-green: its ellipse sits on the bottom edge, 30% in.
        let at = try pixels(GradientFill(.gradGreen), width: 200, height: 100)
        let bottom = at(60, 98), top = at(60, 2), farRight = at(196, 2)
        XCTAssertLessThan(bottom[0], top[0] - 25, "green at the bottom: \(bottom) vs \(top)")
        XCTAssertGreaterThan(bottom[1], bottom[0] + 15, "\(bottom)")
        // Far from the ellipse there's only the white sheen.
        XCTAssertGreaterThan(farRight[0], 240, "\(farRight)")
    }

    func testTheSheenAndWashesFollowTheColourScheme() throws {
        let light = try pixels(GradientFill(.sheen), width: 100, height: 60)(50, 30)
        let dark = try pixels(GradientFill(.sheen), width: 100, height: 60, scheme: .dark)(50, 30)
        XCTAssertGreaterThan(light[0], 235, "\(light)")
        XCTAssertLessThan(dark[0], 45, "\(dark)")
        let darkWash = try pixels(GradientFill(.gradPeach), width: 200, height: 100, scheme: .dark)(156, 98)
        XCTAssertGreaterThan(darkWash[0], darkWash[2] + 20, "a warm wash in the dark too: \(darkWash)")
    }

    func testTheAccentButtonIsTheForestGradient() throws {
        let at = try pixels(GradientFill(.accentGrad), width: 40, height: 40)
        // #3b5346 at the top into #294237 at the bottom.
        XCTAssertEqual(at(20, 0)[0], 0x3B, accuracy: 3)
        XCTAssertEqual(at(20, 39)[0], 0x29, accuracy: 3)
    }

    /// A fill taller than one Canvas can draw in a Form or List row (8,192 pixels, about 2,730 points at 3×) is drawn
    /// whole, top to bottom, at any height: such a card showed its shadow where its fill should be. On screen, in a
    /// window, as the row draws it; the row's red background would show through anywhere the fill is missing.
    func testAVeryTallFillIsDrawnWholeInAFormRow() async throws {
        XCTAssertEqual(GradientFill.slabs(height: 640), [0..<640], "one Canvas, as before, for anything shorter")
        XCTAssertEqual(GradientFill.slabs(height: 2888.5), [0..<1000, 1000..<2000, 2000..<2888.5])
        XCTAssertEqual(GradientFill.slabs(height: 0), [])

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        for (height, bottom) in [(2600.0, false), (3200, false), (3200, true), (6000, false), (6000, true)] {
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
            window.rootViewController = UIHostingController(rootView: TallFormRow(height: height, bottom: bottom))
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            try await Task.sleep(for: .milliseconds(1200))
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let cg = try XCTUnwrap(image.cgImage)
            let w = cg.width, h = cg.height
            var data = [UInt8](repeating: 0, count: w * h * 4)
            let ctx = try XCTUnwrap(CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            var sheen = 0, red = 0
            for y in 0..<h {
                let i = (y * w + w / 2) * 4
                if data[i] > 200, data[i + 1] < 120 { red += 1 }
                if data[i] > 235, data[i + 1] > 235, data[i + 2] > 235 { sheen += 1 }
            }
            XCTAssertEqual(red, 0, "\(height) pt, \(bottom ? "at its bottom" : "at its top"): the row shows through")
            XCTAssertGreaterThan(sheen, 300, "\(height) pt, \(bottom ? "at its bottom" : "at its top"): the sheen fills it")
        }
    }

    private struct TallFormRow: View {
        let height: CGFloat
        let bottom: Bool

        var body: some View {
            ScrollViewReader { proxy in
                Form {
                    Section {
                        Color.clear.frame(height: height).frame(maxWidth: .infinity)
                            .background { GradientFill(.sheen) }
                            .listRowBackground(Color.red)
                            .listRowInsets(EdgeInsets())
                    }
                    Section { Text("End").id("end") }
                }
                .task {
                    guard bottom else { return }
                    try? await Task.sleep(for: .milliseconds(300))
                    proxy.scrollTo("end", anchor: .bottom)
                }
            }
        }
    }

    func testTheOrbHasADarkRedCore() throws {
        let at = try pixels(Orb(size: 40), width: 40, height: 40)
        let core = at(20, 18)
        XCTAssertEqual(core[0], 0x7B, accuracy: 12, "\(core)")
        XCTAssertLessThan(core[1], 40, "\(core)")
    }

    /// The quiet pill is the web's one-line pill up to the largest standard size, words cut short when there's no room as
    /// on the web; at the accessibility sizes its words wrap instead, so none is cut off.
    func testTheQuietPillsWordsWrapOnlyAtTheAccessibilitySizes() {
        func size(_ title: String, _ type: DynamicTypeSize, width: CGFloat, _ pill: PillSize = .regular) -> CGSize {
            UIHostingController(rootView: Button(title) {}.buttonStyle(.quietPill(size: pill)).environment(\.dynamicTypeSize, type))
                .sizeThatFits(in: CGSize(width: width, height: 3000))
        }
        let long = "Connect your own key to keep asking"
        for type in [DynamicTypeSize.large, .xxxLarge] {
            XCTAssertEqual(size(long, type, width: 400).height, 44, accuracy: 0.5, "\(type): the pill's own height")
            XCTAssertEqual(size(long, type, width: 160).height, 44, accuracy: 0.5, "\(type): one line however narrow, as the web's")
            XCTAssertEqual(size("Change", type, width: 400, .compact).height, 34, accuracy: 0.5)
        }
        for pill in [PillSize.regular, .compact] {
            let oneLine = size("OK", .accessibility5, width: 300, pill)
            let wrapped = size(long, .accessibility5, width: 300, pill)
            XCTAssertGreaterThan(wrapped.height, oneLine.height * 2.5, "\(pill): every word shown, on several lines")
            XCTAssertLessThanOrEqual(wrapped.width, 300)
        }
    }

    /// The accent pill, as the quiet pill: one line up to the largest standard size; at the accessibility sizes its words
    /// wrap ("Enter my workspace" was cut off on the welcome's last step at AX5).
    func testTheAccentPillsWordsWrapOnlyAtTheAccessibilitySizes() {
        func size(_ title: String, _ type: DynamicTypeSize, width: CGFloat, arrow: Bool = true) -> CGSize {
            UIHostingController(rootView: Button { } label: { WelcomeButtonLabel(title, arrow: arrow) }
                .buttonStyle(.accentPill).environment(\.dynamicTypeSize, type))
                .sizeThatFits(in: CGSize(width: width, height: 3000))
        }
        for type in [DynamicTypeSize.large, .xxxLarge] {
            XCTAssertEqual(size("Enter my workspace", type, width: 340).height, 44, accuracy: 0.5, "\(type): the pill's own height")
        }
        let oneLine = size("OK", .accessibility5, width: 300, arrow: false)
        let wrapped = size("Enter my workspace", .accessibility5, width: 300)
        XCTAssertGreaterThan(wrapped.height, oneLine.height * 1.8, "every word shown, on more than one line")
        XCTAssertLessThanOrEqual(wrapped.width, 300)
    }

    /// The radio mark grows with the card's name: 16 points at the default size, more at the accessibility sizes.
    func testTheRadioMarkGrowsWithTheText() {
        func side(_ type: DynamicTypeSize) -> CGFloat {
            UIHostingController(rootView: RadioMark(isOn: true).environment(\.dynamicTypeSize, type)).sizeThatFits(in: CGSize(width: 400, height: 400)).width
        }
        XCTAssertEqual(side(.large), 16, accuracy: 0.5)
        XCTAssertGreaterThan(side(.accessibility5), 16 * 2.5, "about as much bigger as the words beside it")
    }

    /// The range chips keep one row where they fit; at AX5 they wrap inside the well, so "90 days" isn't cut off at
    /// the edge, and the well stays inside the page.
    func testTheRangeChipsWrapRatherThanRunOffTheEdge() {
        func size(_ type: DynamicTypeSize, width: CGFloat) -> CGSize {
            UIHostingController(rootView: RangeFilters(days: .constant(30), ranges: ChartRange.standard.filter { $0.days <= 90 })
                .environment(\.dynamicTypeSize, type)).sizeThatFits(in: CGSize(width: width, height: 3000))
        }
        let row = size(.large, width: 358)
        XCTAssertLessThan(row.width, 358, "one row, as wide as its chips")
        let wrapped = size(.accessibility5, width: 358)
        XCTAssertLessThanOrEqual(wrapped.width, 358.5)
        XCTAssertGreaterThan(wrapped.height, row.height * 3, "on more than one row")
    }

    /// The Macros, water and caffeine charts as the web's BarChart: an even slot per logged day, a bar the slot less 2
    /// points (1 to 24), and 2 to 6 dates under them, first and last day included.
    func testTheFoodChartsPlotTheLoggedDaysInEvenSlots() {
        XCTAssertEqual(FoodChartCard.barWidth(plotWidth: 300, count: 3), 24, "three days: the widest bar, not a third of the width")
        XCTAssertEqual(FoodChartCard.barWidth(plotWidth: 300, count: 30), 8)
        XCTAssertEqual(FoodChartCard.barWidth(plotWidth: 300, count: 400), 1)
        XCTAssertEqual(FoodChartCard.labelIndices(count: 3, width: 330), [0, 1, 2])
        XCTAssertEqual(FoodChartCard.labelIndices(count: 30, width: 330), [0, 15, 29])
        XCTAssertEqual(FoodChartCard.labelIndices(count: 1, width: 330), [0])
        XCTAssertEqual(FoodChartCard.labelIndices(count: 0, width: 330), [])
    }

    /// A drag on a chart picks points only when it starts sideways; one that starts up or down is the page's scroll.
    func testAChartPicksOnlyOnASidewaysDrag() {
        XCTAssertTrue(ChartScrub.isSideways(CGPoint(x: 300, y: 40)))
        XCTAssertTrue(ChartScrub.isSideways(CGPoint(x: -300, y: 40)))
        XCTAssertFalse(ChartScrub.isSideways(CGPoint(x: 40, y: 300)))
        XCTAssertFalse(ChartScrub.isSideways(CGPoint(x: 10, y: -300)))
        XCTAssertFalse(ChartScrub.isSideways(.zero))
    }

    /// The radio card's mark as the web's radio draws: empty, a grey ring on a grey disc in dark mode (not the card's
    /// own surface); chosen, an accent ring, a white band and an accent dot, in light and dark.
    func testTheRadioMarkIsTheWebsInLightAndDark() throws {
        let offDark = try pixels(RadioMark(isOn: false), width: 16, height: 16, scheme: .dark)(8, 8)
        XCTAssertEqual(offDark[0], 0x3B, accuracy: 3, "\(offDark)")
        XCTAssertEqual(offDark[2], 0x3B, accuracy: 3, "\(offDark)")
        let offLight = try pixels(RadioMark(isOn: false), width: 16, height: 16)(8, 8)
        XCTAssertGreaterThan(offLight[0], 250, "white in light mode, as before: \(offLight)")
        for (scheme, accent) in [(ColorScheme.light, [0x2F, 0x4A, 0x3D]), (.dark, [0x4D, 0x6B, 0x5A])] {
            let at = try pixels(RadioMark(isOn: true), width: 16, height: 16, scheme: scheme)
            let dot = at(8, 8), band = at(2, 8)
            for i in 0..<3 { XCTAssertEqual(dot[i], accent[i], accuracy: 4, "\(scheme) dot: \(dot)") }
            XCTAssertGreaterThan(band[0], 235, "\(scheme) white band: \(band)")
            XCTAssertGreaterThan(band[1], 235, "\(scheme) white band: \(band)")
        }
    }

    func testASheetHasAFooterOnlyWhenGivenOne() {
        XCTAssertFalse(SheetScaffold(title: "Edit widgets") { Text("Body") }.hasFooter)
        XCTAssertTrue(SheetScaffold(title: "Edit widgets") { Text("Body") } footer: { Button("Done") {} }.hasFooter)
    }

    /// The web's .card: 20px at the sides and top, 18px at the bottom (it has no phone override).
    func testACardIsPaddedAsTheWebsCard() {
        let size = UIHostingController(rootView: Color.red.frame(width: 100, height: 50).card().fixedSize())
            .sizeThatFits(in: CGSize(width: 400, height: 400))
        XCTAssertEqual(size.width, 140)
        XCTAssertEqual(size.height, 88)
    }

    /// The initial on pale sage, as the web's .avatar, not white on a brown gradient (no photo: the local server).
    func testAnAvatarWithoutAPhotoIsPaleSage() throws {
        let at = try pixels(Avatar(photo: nil, name: "Ricky", size: 32), width: 36, height: 36)
        let fill = at(9, 18) // inside the circle, left of the initial
        XCTAssertEqual(fill[0], 0xE6, accuracy: 4, "--accent-soft #e6efe3: \(fill)")
        XCTAssertEqual(fill[1], 0xEF, accuracy: 4, "\(fill)")
        let dark = try pixels(Avatar(photo: nil, name: "Ricky", size: 32), width: 36, height: 36, scheme: .dark)(9, 18)
        XCTAssertEqual(dark[0], 0x26, accuracy: 4, "--accent-soft dark #263529: \(dark)")
    }

    /// A row's icon grows with the text up to about xxLarge, then stops, so it never sits over the name beside it.
    func testARowIconStopsGrowing() {
        XCTAssertEqual(RowIcon.width(26), 26)
        XCTAssertEqual(RowIcon.width(26 * 1.24), 26 * 1.24, accuracy: 0.01)
        XCTAssertEqual(RowIcon.width(26 * 3.1), 26 * 1.3, accuracy: 0.01, "the largest text size")
    }

    func testEveryCardTintIsAWash() {
        XCTAssertEqual(Set(CardTint.allCases.map(\.gradient)).count, CardTint.allCases.count)
        XCTAssertEqual(CardTint.plain.gradient, .sheen)
        XCTAssertEqual(String.emptyValue, "—")
    }
}

private func XCTAssertEqual(_ a: Int, _ b: Int, accuracy: Int, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertLessThanOrEqual(abs(a - b), accuracy, "\(a) vs \(b) \(message)", file: file, line: line)
}
