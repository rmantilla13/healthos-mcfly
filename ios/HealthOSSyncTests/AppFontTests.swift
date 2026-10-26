import XCTest
import SwiftUI
import UIKit
@testable import HealthOSSync

/// DM Sans: bundled, registered, its weights real points on the wght axis, and its sizes following Dynamic Type.
final class AppFontTests: XCTestCase {
    func testTheFontAndItsLicenceAreBundled() throws {
        let app = Bundle(for: Dashboard.self)
        XCTAssertNotNil(app.url(forResource: "DMSans-Variable", withExtension: "ttf"))
        XCTAssertNotNil(app.url(forResource: "OFL", withExtension: "txt"), "the OFL asks for the licence to ship with the font")
        let fonts = try XCTUnwrap(app.object(forInfoDictionaryKey: "UIAppFonts") as? [String])
        XCTAssertEqual(fonts, ["DMSans-Variable.ttf"])
        XCTAssertEqual(UIFont(name: AppFont.postScriptName, size: 17)?.familyName, AppFont.family)
    }

    func testEachWeightIsAPointOnTheAxis() {
        for (weight, value) in [(Font.Weight.regular, 400.0), (.medium, 500), (.semibold, 600), (.bold, 700)] {
            let font = AppFont.uiFont(size: 17, weight: weight)
            XCTAssertEqual(font.familyName, AppFont.family)
            let variation = CTFontCopyVariation(font as CTFont) as? [NSNumber: NSNumber]
            XCTAssertEqual(variation?[NSNumber(value: AppFont.weightAxis)]?.doubleValue ?? 400, value, "\(weight)")
        }
    }

    func testHeavierWeightsSetWider() {
        // Measured, not just named: each step of the axis draws the same words wider.
        let widths = [Font.Weight.regular, .medium, .semibold, .bold].map { weight in
            ("Resting heart rate 62 bpm" as NSString).size(withAttributes: [.font: AppFont.uiFont(size: 17, weight: weight)]).width
        }
        XCTAssertEqual(widths, widths.sorted())
        XCTAssertEqual(Set(widths).count, 4, "\(widths)")
    }

    func testSizesFollowTheTextSize() {
        let large = AppFont.uiFont(size: 13, relativeTo: .footnote, compatibleWith: UITraitCollection(preferredContentSizeCategory: .large))
        let xxl = AppFont.uiFont(size: 13, relativeTo: .footnote, compatibleWith: UITraitCollection(preferredContentSizeCategory: .extraExtraExtraLarge))
        XCTAssertEqual(large.pointSize, 13, accuracy: 0.01)
        XCTAssertGreaterThan(xxl.pointSize, 15)
        XCTAssertEqual(xxl.familyName, AppFont.family)
        XCTAssertEqual(AppFont.size(.footnote), 13)
        XCTAssertEqual(AppFont.size(.body), 17)
        XCTAssertEqual(AppFont.defaultWeight(.headline), .semibold)
        XCTAssertEqual(AppFont.defaultWeight(.body), .regular)
    }

    func testSwiftUIsInstancesAreTheSameAxisPoints() {
        // Text names the file's instances; each is the point the descriptor path sets, in the same family.
        for weight in [Font.Weight.thin, .ultraLight, .light, .regular, .medium, .semibold, .bold, .heavy, .black] {
            let named = UIFont(name: AppFont.instanceName(weight), size: 17)
            XCTAssertEqual(named?.familyName, AppFont.family, AppFont.instanceName(weight))
            let variation = named.flatMap { CTFontCopyVariation($0 as CTFont) as? [NSNumber: NSNumber] }
            XCTAssertEqual(variation?[NSNumber(value: AppFont.weightAxis)]?.doubleValue ?? 400, AppFont.axisValue(weight), AppFont.instanceName(weight))
        }
    }

    func testDigitsAreProportional() {
        // The web's latin file has no tabular figures, so asking for them changes nothing: "1111" sets narrower than
        // "0000", as on the web. If a font with tnum is bundled, `.monospacedDigit()` starts working and this fails.
        let monospaced = AppFont.uiFont(size: 17).fontDescriptor.addingAttributes([.featureSettings: [[
            UIFontDescriptor.FeatureKey.type: kNumberSpacingType, UIFontDescriptor.FeatureKey.selector: kMonospacedNumbersSelector,
        ]]])
        let font = UIFont(descriptor: monospaced, size: 17)
        func width(_ s: String) -> CGFloat { (s as NSString).size(withAttributes: [.font: font]).width }
        XCTAssertLessThan(width("1111"), width("0000") - 4)
    }

    @MainActor func testTheBarsAreDMSans() throws {
        AppFont.styleBars()
        let bar = UINavigationBar.appearance()
        for attributes in [bar.titleTextAttributes, bar.largeTitleTextAttributes] {
            XCTAssertEqual((attributes?[.font] as? UIFont)?.familyName, AppFont.family)
        }
        // The tab bar ignores UITabBarItem's own appearance: its labels take their font from a tab bar appearance only.
        let tabs = UITabBar.appearance().standardAppearance
        for item in [tabs.stackedLayoutAppearance, tabs.inlineLayoutAppearance, tabs.compactInlineLayoutAppearance] {
            for state in [item.normal, item.selected] {
                let font = try XCTUnwrap(state.titleTextAttributes[.font] as? UIFont)
                XCTAssertEqual(font.familyName, AppFont.family)
                XCTAssertEqual(font.pointSize, 10, "one size, as the system's tab labels are")
            }
        }
        // A segmented picker's height is fixed, so a scaled font would be cut off at the larger text sizes.
        for state in [UIControl.State.normal, .selected] {
            let font = try XCTUnwrap(UISegmentedControl.appearance().titleTextAttributes(for: state)?[.font] as? UIFont)
            XCTAssertEqual(font.familyName, AppFont.family)
            XCTAssertEqual(font.pointSize, 13)
        }
    }

    func testTextTheSystemWouldDrawIsGivenDMSans() throws {
        // Every explicit font is the app's, except on SF Symbols and the lines marked "system face". The system views
        // that set their own fonts, whatever the app's, go through the app's versions: Unavailable for
        // ContentUnavailableView, ChartLegend for a chart's legend, and the app font on each axis label.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("HealthOSSync")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)).compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 30, "the app's sources at \(root.path)")
        let systemFont = /\.(largeTitle|title|title2|title3|headline|subheadline|body|callout|footnote|caption|caption2)\b|\.system\(|Font\.system/
        var problems: [String] = []
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (i, line) in lines.enumerated() where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                let at = "\(file.lastPathComponent):\(i + 1)"
                if line.contains("ContentUnavailableView"), file.lastPathComponent != "Unavailable.swift" { problems.append("\(at): use Unavailable") }
                if line.contains("AxisValueLabel"), !line.contains(".font(.app(") { problems.append("\(at): an axis label without .font(.app(…))") }
                if line.contains(".chartLegend(position:"), !line.contains("ChartLegend(") { problems.append("\(at): use ChartLegend") }
                let around = line + (i > 0 ? lines[i - 1] : "")
                guard !around.contains("Image(systemName"), !around.contains("system face") else { continue }
                for call in line.ranges(of: ".font(") {
                    let argument = String(Self.argument(line[call.upperBound...])).replacing(/\.app\(\.\w+|relativeTo: \.\w+/, with: "")
                    if argument.contains(systemFont) { problems.append("\(at): a system font, \(line.trimmingCharacters(in: .whitespaces))") }
                }
            }
        }
        XCTAssertEqual(problems, [])
    }

    /// What's inside the parentheses a call opened just before `rest`.
    private static func argument(_ rest: Substring) -> Substring {
        var depth = 1
        for index in rest.indices {
            if rest[index] == "(" { depth += 1 }
            if rest[index] == ")" { depth -= 1 }
            if depth == 0 { return rest[..<index] }
        }
        return rest
    }
}
