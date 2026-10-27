import XCTest
@testable import HealthOSSync

/// The keyboard's Done (Shell/Duo/DuoKeyboard.swift, D0 of the Duo design): a flexible space then Done before iOS
/// 27.1, as it always was; Done alone from 27.1, the iPhone Duo's release, where the group hung the app.
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

    func testFrom27_1DoneStandsAlone() {
        XCTAssertEqual(shape(27, 1), .doneAlone)
        XCTAssertEqual(shape(27, 1, 2), .doneAlone)
        XCTAssertEqual(shape(27, 2), .doneAlone)
        XCTAssertEqual(shape(28, 0), .doneAlone)
    }

    func testThisSimulatorGetsItsOwnVersionsShape() {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        XCTAssertEqual(DuoKeyboardDone.current, DuoKeyboardDone.shape(on: version))
    }
}
