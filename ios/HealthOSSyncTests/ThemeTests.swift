import XCTest
import SwiftUI
import UIKit
@testable import HealthOSSync

/// The app's tokens are the web's: every colour, gradient, shadow and radius in src/styles.css, light and dark, read
/// from the file itself (as testRegistryMatchesSharedCards reads shared/cards.ts), so the two can't drift apart.
final class ThemeTests: XCTestCase {
    /// `--name: value;` in the light :root block and in the prefers-color-scheme dark block (the forced-dark block
    /// after it repeats the dark one).
    private struct Blocks {
        let light: [String: String]
        let dark: [String: String]
    }

    private func blocks() throws -> Blocks {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("src/styles.css")
        guard let css = try? String(contentsOf: url, encoding: .utf8) else { throw XCTSkip("src/styles.css isn't next to the app") }
        let lines = css.components(separatedBy: "\n")
        let media = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("@media (prefers-color-scheme: dark)") })
        let forced = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("/* Forced dark") })
        XCTAssertLessThan(media, forced)
        func decls(_ range: Range<Int>) throws -> [String: String] {
            let regex = try NSRegularExpression(pattern: #"^\s*--([a-z0-9-]+):\s*(.+);\s*$"#)
            var out: [String: String] = [:]
            for line in lines[range] {
                let ns = line as NSString
                guard let m = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
                out[ns.substring(with: m.range(at: 1))] = ns.substring(with: m.range(at: 2))
            }
            return out
        }
        return Blocks(light: try decls(0..<media), dark: try decls(media..<forced))
    }

    // MARK: - Reading CSS values

    /// Splits at commas (or spaces) outside parentheses.
    private func split(_ s: String, on separator: Character) -> [String] {
        var parts: [String] = [], current = "", depth = 0
        for ch in s {
            if ch == "(" { depth += 1 } else if ch == ")" { depth -= 1 }
            if ch == separator, depth == 0 {
                parts.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(ch)
            }
        }
        parts.append(current.trimmingCharacters(in: .whitespaces))
        return parts.filter { !$0.isEmpty }
    }

    private func color(_ s: String) -> CSSColor? {
        if s.hasPrefix("#"), s.count == 7, let hex = UInt32(s.dropFirst(), radix: 16) { return CSSColor(hex) }
        guard s.hasPrefix("rgba("), s.hasSuffix(")") else { return nil }
        let n = s.dropFirst(5).dropLast().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard n.count == 4, let r = UInt8(n[0]), let g = UInt8(n[1]), let b = UInt8(n[2]), let a = Double(n[3]) else { return nil }
        return .rgba(r, g, b, a)
    }

    private func percent(_ s: String) -> Double? {
        s.hasSuffix("%") ? Double(s.dropLast()).map { $0 / 100 } : nil
    }

    private func px(_ s: String) -> Double? {
        s == "0" ? 0 : s.hasSuffix("px") ? Double(s.dropLast(2)) : nil
    }

    /// A gradient value's layers from the top, with `var(--x)` read from the same block.
    private func gradient(_ value: String, in block: [String: String]) throws -> [CSSGradient] {
        try split(value, on: ",").flatMap { layer -> [CSSGradient] in
            if layer.hasPrefix("var(--") {
                let name = String(layer.dropFirst(6).dropLast())
                return try gradient(try XCTUnwrap(block[name], name), in: block)
            }
            let open = try XCTUnwrap(layer.firstIndex(of: "("))
            let kind = layer[..<open]
            let args = split(String(layer[layer.index(after: open)...].dropLast()), on: ",")
            let stops = try args.dropFirst().map { stop -> (CSSColor, Double) in
                let words = split(stop, on: " ")
                return (try XCTUnwrap(color(words[0]), stop), try XCTUnwrap(percent(words[1]), stop))
            }
            switch kind {
            case "linear-gradient":
                let degrees = try XCTUnwrap(Double(args[0].replacingOccurrences(of: "deg", with: "")), args[0])
                return [.linear(degrees, stops)]
            case "radial-gradient":
                let geometry = args[0].split(separator: " ").map(String.init)
                XCTAssertEqual(geometry.count, 5, args[0])
                XCTAssertEqual(geometry[2], "at")
                let f = try [0, 1, 3, 4].map { try XCTUnwrap(percent(geometry[$0]), args[0]) }
                return [.radial(f[0], f[1], at: f[2], f[3], stops)]
            default:
                XCTFail("unknown gradient \(kind)")
                return []
            }
        }
    }

    private func shadow(_ value: String) throws -> [CSSShadow] {
        try split(value, on: ",").map { layer in
            let words = split(layer, on: " ")
            let lengths = try words.dropLast().map { try XCTUnwrap(px($0), layer) }
            let c = try XCTUnwrap(color(try XCTUnwrap(words.last)), layer)
            XCTAssert(lengths.count == 3 || lengths.count == 4, layer)
            return CSSShadow(x: lengths[0], y: lengths[1], blur: lengths[2], spread: lengths.count == 4 ? lengths[3] : 0, color: c)
        }
    }

    // MARK: - Tokens

    func testEveryColourTokenIsTheCSSs() throws {
        let css = try blocks()
        let names = css.light.filter { color($0.value) != nil }.map(\.key)
        XCTAssertEqual(Set(names), Set(ColorToken.allCases.map(\.rawValue)), "every colour in :root, and nothing else")
        XCTAssertGreaterThan(names.count, 90, "the parse found the block")
        for token in ColorToken.allCases {
            let light = try XCTUnwrap(css.light[token.rawValue].flatMap(color), token.rawValue)
            XCTAssertEqual(token.value.light, light, "--\(token.rawValue) light")
            // A token the dark block doesn't name keeps its light value.
            let dark = try css.dark[token.rawValue].map { try XCTUnwrap(color($0), "--\(token.rawValue) dark") } ?? light
            XCTAssertEqual(token.value.dark, dark, "--\(token.rawValue) dark")
        }
        // Nothing in the dark block that light doesn't have.
        for (name, value) in css.dark where color(value) != nil {
            XCTAssertNotNil(ColorToken(rawValue: name), "--\(name) is only in the dark block")
        }
    }

    func testEveryGradientIsTheCSSs() throws {
        let css = try blocks()
        let names = css.light.filter { $0.value.contains("gradient(") }.map(\.key)
        XCTAssertEqual(Set(names), Set(GradientToken.allCases.map(\.rawValue)))
        for token in GradientToken.allCases {
            XCTAssertEqual(token.layers.light, try gradient(try XCTUnwrap(css.light[token.rawValue]), in: css.light), "--\(token.rawValue) light")
            let dark = try XCTUnwrap(css.dark[token.rawValue], "every gradient has a dark value: --\(token.rawValue)")
            XCTAssertEqual(token.layers.dark, try gradient(dark, in: css.dark), "--\(token.rawValue) dark")
        }
        // Each card wash is a radial over the sheen, and each CardTint has one.
        for tint in CardTint.allCases where tint != .plain {
            XCTAssertEqual(tint.gradient.layers.light.count, 2)
            XCTAssertEqual(tint.gradient.layers.light.last, GradientToken.sheen.layers.light.first)
        }
    }

    func testShadowsAreTheCSSs() throws {
        let css = try blocks()
        for token in ShadowToken.allCases {
            XCTAssertEqual(token.layers.light, try shadow(try XCTUnwrap(css.light[token.rawValue])), "--\(token.rawValue) light")
            XCTAssertEqual(token.layers.dark, try shadow(try XCTUnwrap(css.dark[token.rawValue])), "--\(token.rawValue) dark")
        }
    }

    func testRadiiAreTheCSSs() throws {
        let css = try blocks()
        let radii: [String: CGFloat] = ["r-card": Radius.card, "r-sheet": Radius.sheet, "r-menu": Radius.menu, "r-nav": Radius.nav,
                                        "r-tile": Radius.tile, "r-field": Radius.field, "r-pill": Radius.pill]
        XCTAssertEqual(Set(css.light.keys.filter { $0.hasPrefix("r-") }), Set(radii.keys))
        for (name, value) in radii {
            XCTAssertEqual(try XCTUnwrap(css.light[name].flatMap(px)), Double(value), name)
        }
    }

    // MARK: - The colours as drawn

    private func components(_ color: Color, _ style: UIUserInterfaceStyle) -> [Int] {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: style)).getRed(&r, green: &g, blue: &b, alpha: &a)
        return [r, g, b, a].map { Int(($0 * 255).rounded()) }
    }

    func testColoursFollowTheColourScheme() {
        XCTAssertEqual(components(Palette.page, .light), [0xF4, 0xF1, 0xEE, 255])
        XCTAssertEqual(components(Palette.page, .dark), [0x0E, 0x10, 0x0E, 255])
        XCTAssertEqual(components(Palette.ink, .light), [0x24, 0x31, 0x2A, 255])
        XCTAssertEqual(components(Palette.ink, .dark), [0xEE, 0xF0, 0xEC, 255])
        XCTAssertEqual(components(Palette.border, .light), [36, 49, 42, 18])
        XCTAssertEqual(components(Palette.border, .dark), [255, 255, 255, 18])
        XCTAssertEqual(components(Palette.accent, .light), [0x2F, 0x4A, 0x3D, 255])
        XCTAssertEqual(components(Palette.accent, .dark), [0x4D, 0x6B, 0x5A, 255])
        XCTAssertEqual(components(Palette.orbCore, .dark), [0x7B, 0x0D, 0x10, 255], "the orb is the same in dark")
    }

    func testTheTintIsTheForestAccent() {
        XCTAssertEqual(components(Palette.tint, .light), components(Palette.accent, .light))
        // Words in dark mode take the accent's text step, which reads on the dark surface.
        XCTAssertEqual(components(Palette.tint, .dark), components(Palette.accentText, .dark))
    }

    // MARK: - Drawing

    func testAGradientLineReachesTheCorners() {
        // Straight down: from the top edge's middle to the bottom's.
        let down = CSSGradient.line(degrees: 180, in: CGSize(width: 100, height: 40))
        XCTAssertEqual(down.start.x, 50, accuracy: 1e-9)
        XCTAssertEqual(down.start.y, 0, accuracy: 1e-9)
        XCTAssertEqual(down.end.y, 40, accuracy: 1e-9)
        // At an angle, the nearest and farthest corners fall exactly on 0% and 100%.
        for size in [CGSize(width: 340, height: 196), CGSize(width: 116, height: 60)] {
            for degrees in [118.0, 165, 160, 170, 90] {
                let line = CSSGradient.line(degrees: degrees, in: size)
                let dx = line.end.x - line.start.x, dy = line.end.y - line.start.y
                func at(_ p: CGPoint) -> Double { ((p.x - line.start.x) * dx + (p.y - line.start.y) * dy) / (dx * dx + dy * dy) }
                let corners = [CGPoint.zero, CGPoint(x: size.width, y: 0), CGPoint(x: 0, y: size.height), CGPoint(x: size.width, y: size.height)].map(at)
                XCTAssertEqual(corners.min()!, 0, accuracy: 1e-9, "\(degrees)° in \(size)")
                XCTAssertEqual(corners.max()!, 1, accuracy: 1e-9, "\(degrees)° in \(size)")
            }
        }
    }
}
