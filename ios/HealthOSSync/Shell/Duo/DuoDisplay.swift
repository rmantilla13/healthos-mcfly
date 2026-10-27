import SwiftUI

/// A Duo state in window points (unmirrored), for drawn tests on iOS 27.0 and for the Debug log. The app never sets it:
/// on iOS 27.1 each scope reads the system. A scope given an override converts it with its own frame(in: .global).
///
/// The numbers are the measured ones where there are any (duo/api.md §8, design §1 and §2.1). Where the fold is and
/// how wide is G2's to measure, so the fold here is the display's midline and has no width, active or not.
struct DuoDisplay: Equatable, Sendable {
    /// The `.division` region, inactive included.
    var fold: CGRect?
    var foldActive: Bool
    /// toolbarVerticalEdge.
    var barEdge: HorizontalEdge?
    /// The active `.occlusion` regions.
    var occlusions: [CGRect]

    static let none = DuoDisplay(fold: nil, foldActive: false, barEdge: nil, occlusions: [])

    /// The outer display, 466×678: the bar on the trailing edge; the camera at (399.67, 29.33, 37×37) and the status
    /// bar's region (382, 0, 84×170), both inside the bar, both active.
    static let outer = DuoDisplay(fold: nil, foldActive: false, barEdge: .trailing,
                                  occlusions: [CGRect(x: 399.67, y: 29.33, width: 37, height: 37), CGRect(x: 382, y: 0, width: 84, height: 170)])

    /// The inner display in landscape, 951×669: the fold vertical at x ≈ 475.5 (the midline until G2 measures it), the
    /// bar on `bar`'s edge. `.leading` is unmeasured (§2.1): it's where the bar would go with the device turned the other
    /// way. The inner camera's region is active only while it's in use, so there's none.
    static func innerLandscape(foldActive: Bool = false, bar: HorizontalEdge = .trailing) -> DuoDisplay {
        DuoDisplay(fold: CGRect(x: innerLandscapeSize.width / 2 - foldWidth / 2, y: 0, width: foldWidth, height: innerLandscapeSize.height),
                   foldActive: foldActive, barEdge: bar, occlusions: [])
    }

    /// The inner display in portrait, 669×951: the fold horizontal at y ≈ 475.5, and no vertical bar.
    static func innerPortrait(foldActive: Bool = false) -> DuoDisplay {
        DuoDisplay(fold: CGRect(x: 0, y: innerPortraitSize.height / 2 - foldWidth / 2, width: innerPortraitSize.width, height: foldWidth),
                   foldActive: foldActive, barEdge: nil, occlusions: [])
    }

    /// One app of two in Split View on the inner display, ≈471×669: the bar on `bar`'s edge, and the fold at the window's
    /// other edge, between the two apps (assumed until M1 records it), inactive.
    static func innerSplit(bar: HorizontalEdge) -> DuoDisplay {
        let x = bar == .leading ? innerSplitSize.width : 0
        return DuoDisplay(fold: CGRect(x: x, y: 0, width: foldWidth, height: innerSplitSize.height), foldActive: false, barEdge: bar, occlusions: [])
    }

    // The windows these are for.
    static let outerSize = CGSize(width: 466, height: 678)
    static let innerLandscapeSize = CGSize(width: 951, height: 669)
    static let innerPortraitSize = CGSize(width: 669, height: 951)
    static let innerSplitSize = CGSize(width: 471, height: 669)
    /// The fold's width in these presets: none, though G2 has measured it (`measuredInnerLandscapeFold`). The presets
    /// keep 0 until the change is agreed, since every page's drawn tests are written against 443 | 379 (gates.md G2).
    static let foldWidth: CGFloat = 0

    /// G2 (HOS Duo, iOS 27.1, the shell stage): the `.division` region the inner display reports in landscape, in window
    /// points. 40 pt wide, centred on the midline (x 455.5–495.5), inactive while flat and active when partly open (99°
    /// and 147°). With the bar trailing, a page's 847 pt of content splits 423 | 359 around it with the 12 pt clearance,
    /// not the presets' 443 | 379. The live app reads the real region; only drawn tests use the presets.
    static let measuredInnerLandscapeFold = CGRect(x: 455.5, y: 0, width: 40, height: 669)

    /// Whether the fold runs up and down the window (a vertical division) rather than across it.
    var foldIsVertical: Bool { fold.map { $0.height > $0.width } ?? false }

    /// The vertical fold as a scope at `frame` (global, that is window, points) sees it: its x-span from the scope's
    /// leading edge, rounded to 0.5 pt, mirrored for right-to-left as the system's default `.mirrors` is. nil when the
    /// fold is horizontal or doesn't meet the scope, as the system reports only regions that meet the reader's frame.
    func verticalFold(in frame: CGRect, direction: LayoutDirection = .leftToRight) -> ClosedRange<CGFloat>? {
        guard let fold, foldIsVertical, Self.meets(fold, frame) else { return nil }
        let lower = direction == .rightToLeft ? frame.maxX - fold.maxX : fold.minX - frame.minX
        return DuoFold.rounded(lower)...DuoFold.rounded(lower + fold.width)
    }

    /// A horizontal fold in a scope's own coordinates (its frame global), or nil.
    func horizontalFold(in frame: CGRect) -> CGRect? {
        guard let fold, !foldIsVertical, Self.meets(fold, frame) else { return nil }
        return fold.offsetBy(dx: -frame.minX, dy: -frame.minY)
    }

    /// The active occlusions that meet a scope, in its own coordinates.
    func occlusions(in frame: CGRect) -> [CGRect] {
        occlusions.filter { Self.meets($0, frame) }.map { $0.offsetBy(dx: -frame.minX, dy: -frame.minY) }
    }

    /// Two rects meet, counting a zero-width or zero-height one on the edge (CGRect.intersects says a line meets nothing).
    static func meets(_ a: CGRect, _ b: CGRect) -> Bool {
        a.minX <= b.maxX && a.maxX >= b.minX && a.minY <= b.maxY && a.maxY >= b.minY
    }
}
