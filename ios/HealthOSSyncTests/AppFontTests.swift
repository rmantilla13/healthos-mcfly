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
}
