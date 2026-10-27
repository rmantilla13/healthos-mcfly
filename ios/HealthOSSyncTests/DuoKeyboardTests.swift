import XCTest
@testable import HealthOSSync

/// The keyboard's Done (Shell/Duo/DuoKeyboard.swift, D0 of the Duo design): a flexible space then Done before iOS
/// 27.1, as it always was; from 27.1, the iPhone Duo's release, where the group hung the app, no Done in the bar at all
/// (the bar centred Done alone on the open Duo's fold), and a Done beside each number field instead.
final class DuoKeyboardTests: XCTestCase {
    private func shape(_ major: Int, _ minor: Int, _ patch: Int = 0) -> DuoKeyboardDone.Shape {
        DuoKeyboardDone.shape(on: OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: patch))
    }

    func testBefore27_1DoneKeepsItsSpacer() {
        XCTAssertEqual(shape(17, 0), .spacerThenDone)
        XCTAssertEqual(shape(18, 6), .spacerThenDone)
        XCTAssertEqual(shape(26, 4), .spacerThenDone)
        XCTAssertEqual(shape(27, 0), .spacerThenDone)
        XCTAssertEqual(shape(27, 0, 9), .spacerThenDone)
    }

    /// From 27.1 the keyboard's bar holds no Done (build 23: the bar centres it, which is where the open Duo's fold is):
    /// the number fields put theirs beside them.
    func testFrom27_1DoneSitsBesideTheField() {
        XCTAssertEqual(shape(27, 1), .besideTheField)
        XCTAssertEqual(shape(27, 1, 2), .besideTheField)
        XCTAssertEqual(shape(27, 2), .besideTheField)
        XCTAssertEqual(shape(28, 0), .besideTheField)
    }

    func testOnlyBesideTheFieldLeavesTheBarEmpty() {
        for shape in DuoKeyboardDone.Shape.allCases {
            XCTAssertEqual(shape.inBar, shape != .besideTheField, "\(shape)")
        }
        XCTAssertTrue(shape(27, 0).inBar)
        XCTAssertFalse(shape(27, 1).inBar)
    }

    func testThisSimulatorGetsItsOwnVersionsShape() {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        XCTAssertEqual(DuoKeyboardDone.current, DuoKeyboardDone.shape(on: version))
    }
}
