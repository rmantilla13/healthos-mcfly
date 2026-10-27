import SwiftUI
import UIKit
import XCTest
@testable import HealthOSSync

/// D10 and P6 in drawn tests: nothing tappable meets a vertical fold, flat or active, at any text size.
@MainActor
enum DuoFoldAssertions {
    /// Hosts `view` in `state` (as DuoSnapshot does: the Duo's safe area and the fold injected) and fails if any element
    /// with the button trait (or a link, an adjustable control or a text field) has an accessibilityFrame that meets
    /// the fold band: the fold's frame ±12 pt (`DuoFold.clearance`). In a horizontal scroll view whose content is wider
    /// than its frame, only what the row shows counts, and a row that itself crosses the fold is exempt: a row that
    /// really scrolls sideways may cross the fold. A state whose
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

    /// What meets the fold band: each element's label and frame. An element in a row that really scrolls sideways counts
    /// only for the part the row shows (its frame clipped to the row's), so a page tab the row cuts off at the leading
    /// side's edge isn't on the fold; and a sideways row that itself crosses the fold is exempt (D10).
    static func offenders(in host: DuoHost) async throws -> [String] {
        guard let band = band(host.box.state) else { return [] }
        let scrollers = host.sidewaysScrollers()
        let elements = try await host.elements()
        return elements.compactMap { element in
            guard tappable(element) else { return nil }
            let frame = element.accessibilityFrame
            guard meets(frame, band) else { return nil }
            var shown = frame
            for scroller in scrollers {
                let part = frame.intersection(scroller)
                guard !part.isNull, part.width > 0.5, part.height > 0.5 else { continue }
                if meets(scroller, band) { return nil }
                shown = part
            }
            guard meets(shown, band) else { return nil }
            return "\(element.accessibilityLabel ?? element.accessibilityIdentifier ?? "?") \(frame)"
        }
    }

    /// A frame with some area that reaches into the band's x.
    private static func meets(_ frame: CGRect, _ band: ClosedRange<CGFloat>) -> Bool {
        frame.width > 0 && frame.height > 0 && frame.maxX > band.lowerBound && frame.minX < band.upperBound
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
