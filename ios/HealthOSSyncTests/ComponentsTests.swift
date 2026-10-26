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

    func testASheetHasAFooterOnlyWhenGivenOne() {
        XCTAssertFalse(SheetScaffold(title: "Edit widgets") { Text("Body") }.hasFooter)
        XCTAssertTrue(SheetScaffold(title: "Edit widgets") { Text("Body") } footer: { Button("Done") {} }.hasFooter)
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
