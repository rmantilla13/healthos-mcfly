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
