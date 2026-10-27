import SwiftUI
import UIKit
import XCTest
@testable import HealthOSSync

/// D10 and P6 in drawn tests: nothing tappable meets a vertical fold, flat or active, at any text size.
@MainActor
enum DuoFoldAssertions {
    /// Hosts `view` in `state` (as DuoSnapshot does: the Duo's safe area and the fold injected) and fails if any element
    /// with the button trait (or a link, an adjustable control or a text field) has an accessibilityFrame that meets
    /// the fold band: the fold's frame ±12 pt (`DuoFold.clearance`). Elements inside a horizontal scroll view whose
    /// content is wider than its frame are skipped: a row that really scrolls sideways may cross the fold. A state whose
    /// vertical fold isn't inside the window (no fold, a horizontal one, Split View's at the window's edge) passes.
    static func assertNothingTappableOnTheFold(_ view: some View, state: DuoState, typeSize: DynamicTypeSize = .large,
                                               file: StaticString = #filePath, line: UInt = #line) async throws {
        let host = try await DuoHost(view, as: state, typeSize: typeSize)
        defer { host.close() }
        try await assertNothingTappableOnTheFold(in: host, file: file, line: line)
    }

    /// The same, for a view already hosted (after a `set(_:)`, say).
    static func assertNothingTappableOnTheFold(in host: DuoHost, file: StaticString = #filePath, line: UInt = #line) async throws {
        let found = try await offenders(in: host)
        XCTAssert(found.isEmpty, "on the fold in \(host.box.state) at \(host.box.typeSize): \(found.joined(separator: "; "))", file: file, line: line)
    }

    /// The fold band in window points, or nil when the state has no vertical fold inside the window.
    static func band(_ state: DuoState) -> ClosedRange<CGFloat>? {
        let display = state.display
        guard let fold = display.fold, display.foldIsVertical, fold.minX > 0, fold.maxX < state.size.width else { return nil }
        return (fold.minX - DuoFold.clearance)...(fold.maxX + DuoFold.clearance)
    }

    /// What meets the fold band: each element's label and frame.
    static func offenders(in host: DuoHost) async throws -> [String] {
        guard let band = band(host.box.state) else { return [] }
        let scrollers = host.sidewaysScrollers()
        let elements = try await host.elements()
        return elements.compactMap { element in
            guard tappable(element) else { return nil }
            let frame = element.accessibilityFrame
            guard frame.width > 0, frame.height > 0, frame.maxX > band.lowerBound, frame.minX < band.upperBound else { return nil }
            let middle = CGPoint(x: frame.midX, y: frame.midY)
            guard !scrollers.contains(where: { $0.contains(middle) }) else { return nil }
            return "\(element.accessibilityLabel ?? element.accessibilityIdentifier ?? "?") \(frame)"
        }
    }

    private static func tappable(_ element: NSObject) -> Bool {
        let traits = element.accessibilityTraits
        return traits.contains(.button) || traits.contains(.link) || traits.contains(.adjustable)
            || element is UITextField || element is UITextView
    }
}

private extension NSObject {
    var accessibilityIdentifier: String? { (self as? UIAccessibilityIdentification)?.accessibilityIdentifier }
}
