import SwiftUI

// iPhone Duo: the plain values every scope works out and every page reads (duo/design.md §2.3, §2.4, §3 and §6).
// Pages read `duoBand` and `duoFold` from the environment and never look at size classes, orientation, the screen or
// any iOS 27.x API (rule P1). Each scope (a page, a pane, a sheet, the floating row) measures itself and sets these for
// what's inside it (Shell/Duo/DuoScope.swift). Nothing here stores an iOS 27.1 type: the system's readings are copied
// into these values.

/// The vertical fold as one scope's content sees it: x only, rounded to 0.5 pt (horizontal folds never move scroll
/// content). `span` is nil when this scope doesn't split (§2.3: a vertical division with ≥300 pt each side, inactive
/// included, or the scope's middle in the wide band when no division is reported).
struct DuoFold: Equatable, Sendable {
    /// From the content's leading edge (inside the margins), in points.
    var span: ClosedRange<CGFloat>?
    var active: Bool

    static let none = DuoFold(span: nil, active: false)

    /// How far anything tappable keeps from the fold, on each side (D10: nothing tappable meets the fold's frame
    /// ±12 pt). The gap at the fold is the fold's width plus twice this, so a split row, pair, pane or one-side block
    /// never reaches the fold band that `assertNothingTappableOnTheFold` checks.
    static let clearance: CGFloat = 12

    /// This scope splits on the fold.
    var splits: Bool { span != nil }

    /// Half the gap at the fold for a row with `spacing` between its cells: the clearance, or half the spacing if
    /// that's more.
    static func halfGap(spacing: CGFloat) -> CGFloat { max(spacing / 2, clearance) }

    /// The leading side's width (from the content's leading edge to the fold, less half the gap, down to a whole
    /// point); nil when this scope doesn't split. `duoOneSide()` keeps a block this wide.
    func leadingWidth(spacing: CGFloat = 14) -> CGFloat? {
        span.map { max(0, ($0.lowerBound - Self.halfGap(spacing: spacing)).rounded(.down)) }
    }

    /// The two sides of a row `width` wide (from the content's leading edge): the leading one ends half the gap before
    /// the fold and the trailing one starts half the gap after it, each on a whole point away from the fold (so a
    /// screen's pixel rounding never brings an edge into the fold band). nil when this scope doesn't split.
    func sides(width: CGFloat, spacing: CGFloat = 14) -> (leading: ClosedRange<CGFloat>, trailing: ClosedRange<CGFloat>)? {
        guard let span else { return nil }
        let half = Self.halfGap(spacing: spacing)
        let lead = max(0, (span.lowerBound - half).rounded(.down))
        let trail = min(width, (span.upperBound + half).rounded(.up))
        return (0...lead, trail...max(trail, width))
    }

    /// The widest a control may be and still sit wholly on either side of the fold, wherever its row puts it (the range
    /// picker, the day picker): the narrower side. nil when this scope doesn't split.
    func narrowerSide(width: CGFloat) -> CGFloat? {
        sides(width: width).map { min($0.leading.upperBound - $0.leading.lowerBound, $0.trailing.upperBound - $0.trailing.lowerBound) }
    }

    /// A length rounded to 0.5 pt, as the fold is kept.
    static func rounded(_ x: CGFloat) -> CGFloat { (x * 2).rounded() / 2 }
}

/// The page's horizontal margins: the container guide where a vertical bar is in use (iOS 27.1), else 16 / 16.
struct DuoMargins: Equatable, Sendable {
    var leading: CGFloat
    var trailing: CGFloat

    /// The web's phone padding, and every iPhone's without a vertical bar.
    static let phone = DuoMargins(leading: 16, trailing: 16)

    /// What drawn tests use for the system's container margins (measured on the outer display: 20 on the open side,
    /// 0 beside the bar), and 16 / 16 with no bar.
    static func measured(barEdge: HorizontalEdge?) -> DuoMargins {
        switch barEdge {
        case .trailing: DuoMargins(leading: 20, trailing: 0)
        case .leading: DuoMargins(leading: 0, trailing: 20)
        case nil: .phone
        }
    }

    var insets: EdgeInsets { EdgeInsets(top: 0, leading: leading, bottom: 0, trailing: trailing) }
    var total: CGFloat { leading + trailing }
}

/// How much goes in a row, from the scope's content width (D7). Splitting is the fold's business, not the band's.
enum DuoBand: Int, Comparable, Sendable {
    case compact, medium, wide

    /// The web's 560 px window less its 16 px padding.
    static let compactMax: CGFloat = 528
    /// The web's 1080 px window less its 200 px sidebar and 40 px padding.
    static let wideMin: CGFloat = 800

    /// ≤528 compact, 529–799 medium, ≥800 wide; one step lower at the accessibility text sizes.
    static func of(contentWidth: CGFloat, typeSize: DynamicTypeSize) -> DuoBand {
        let band: DuoBand = contentWidth <= compactMax ? .compact : contentWidth < wideMin ? .medium : .wide
        guard typeSize.isAccessibilitySize, let lower = DuoBand(rawValue: band.rawValue - 1) else { return band }
        return lower
    }

    static func < (a: DuoBand, b: DuoBand) -> Bool { a.rawValue < b.rawValue }

    /// A chart `base` tall in compact is 1.3 times that in medium and wide (`duoChartHeight`).
    func chartHeight(_ base: CGFloat) -> CGFloat { self == .compact ? base : base * 1.3 }

    /// A long table's scrolling window (§2.7: the metric sheet's and the food card's): `base` in compact, as today; the
    /// smaller of `base` and 45% of the scope's height in medium and wide.
    func tableWindow(scopeHeight: CGFloat?, base: CGFloat = 360) -> CGFloat {
        guard self != .compact, let scopeHeight, scopeHeight > 0 else { return base }
        return min(base, (scopeHeight * 0.45).rounded())
    }
}

/// Where a scope splits (§2.3), as pure math so DuoLayoutTests check it without drawing.
enum DuoSplit {
    /// Each side of a vertical division needs at least this much of the content for the scope to split.
    static let minSide: CGFloat = 300

    /// The fold for content `contentWidth` wide, given the x-span of a vertical `.division` region in the content's
    /// coordinates (nil when none is reported). A division with ≥300 pt each side splits; one nearer an edge (Split
    /// View) doesn't. With none reported, content at least `DuoBand.wideMin` wide splits at its middle, whatever the text
    /// size, so nothing jumps from a three-up row to two-up when the device half-folds.
    static func fold(contentWidth: CGFloat, division: ClosedRange<CGFloat>?, active: Bool) -> DuoFold {
        if let division {
            let span = DuoFold.rounded(division.lowerBound)...DuoFold.rounded(max(division.lowerBound, division.upperBound))
            guard span.lowerBound >= minSide, contentWidth - span.upperBound >= minSide else { return .none }
            return DuoFold(span: span, active: active)
        }
        guard contentWidth >= DuoBand.wideMin else { return .none }
        let middle = DuoFold.rounded(contentWidth / 2)
        return DuoFold(span: middle...middle, active: false)
    }
}

/// Which part of a split scope a page keeps to (DuoPage).
enum DuoSide: Sendable {
    /// The whole width, split on the fold by DuoGrid, DuoPair and DuoPanes.
    case full
    /// The leading side only, when the scope splits: the page the web keeps in one column (§2.5).
    case leadingOfFold
}

/// What one scope works out from its size, its margins and the fold, before any band is read (pure, for the tests).
struct DuoScopeValues: Equatable {
    var margins: DuoMargins
    var band: DuoBand
    var fold: DuoFold
    var contentWidth: CGFloat
    var barEdge: HorizontalEdge?

    /// A scope `width` wide with `margins`, given the division's x-span in the scope's own coordinates (from its leading
    /// edge). `splits` is false for a pane or a sheet, which never split. A `.leadingOfFold` page keeps left of the fold
    /// when the scope splits: its trailing margin grows to the fold, less the clearance, and its band is that side's.
    /// `maxWidth` caps the content through the trailing margin the same way; a capped page that would then straddle the
    /// fold without splitting keeps to the leading side too.
    static func resolve(width: CGFloat, margins: DuoMargins, division: ClosedRange<CGFloat>?, active: Bool, typeSize: DynamicTypeSize,
                        splits: Bool = true, side: DuoSide = .full, maxWidth: CGFloat? = nil, barEdge: HorizontalEdge? = nil) -> DuoScopeValues {
        var m = margins
        let content = max(0, width - m.total)
        let inContent = division.map { ($0.lowerBound - m.leading)...($0.upperBound - m.leading) }
        let fold = splits ? DuoSplit.fold(contentWidth: content, division: inContent, active: active) : .none
        let capped = min(content, maxWidth ?? .infinity)
        var shown = capped
        var kept = DuoFold.none
        if let span = fold.span {
            if side == .leadingOfFold || capped - span.upperBound < DuoSplit.minSide {
                shown = min(capped, fold.leadingWidth(spacing: 0) ?? capped)
            } else {
                kept = fold
            }
        }
        m.trailing += content - shown
        return DuoScopeValues(margins: m, band: DuoBand.of(contentWidth: shown, typeSize: typeSize), fold: kept, contentWidth: shown,
                              barEdge: barEdge)
    }
}

// MARK: - The environment

private struct DuoBandKey: EnvironmentKey { static let defaultValue = DuoBand.compact }
private struct DuoFoldKey: EnvironmentKey { static let defaultValue = DuoFold.none }
private struct DuoMarginsKey: EnvironmentKey { static let defaultValue = DuoMargins.phone }
private struct DuoBarEdgeKey: EnvironmentKey { static let defaultValue: HorizontalEdge? = nil }
private struct DuoDisplayOverrideKey: EnvironmentKey { static let defaultValue: DuoDisplay? = nil }
private struct DuoContentWidthKey: EnvironmentKey { static let defaultValue: CGFloat? = nil }
private struct DuoScopeHeightKey: EnvironmentKey { static let defaultValue: CGFloat? = nil }

extension EnvironmentValues {
    /// Set by each scope; default .compact.
    var duoBand: DuoBand {
        get { self[DuoBandKey.self] }
        set { self[DuoBandKey.self] = newValue }
    }

    /// Set by each scope; default .none. Blocks inside a page's scroll content use the page's (P5).
    var duoFold: DuoFold {
        get { self[DuoFoldKey.self] }
        set { self[DuoFoldKey.self] = newValue }
    }

    /// Set by DuoPage, each pane and SheetScaffold; default 16 / 16. DuoScroll insets its content by them.
    var duoMargins: DuoMargins {
        get { self[DuoMarginsKey.self] }
        set { self[DuoMarginsKey.self] = newValue }
    }

    /// The edge the system would put a vertical bar on, read by each scope in its own context (and inside each
    /// SheetScaffold, from the sheet itself); default nil: no vertical bar.
    var duoBarEdge: HorizontalEdge? {
        get { self[DuoBarEdgeKey.self] }
        set { self[DuoBarEdgeKey.self] = newValue }
    }

    /// Drawn tests only; nil in the app. A scope given one converts it with its own frame(in: .global).
    var duoDisplayOverride: DuoDisplay? {
        get { self[DuoDisplayOverrideKey.self] }
        set { self[DuoDisplayOverrideKey.self] = newValue }
    }

    /// The scope's content width (inside its margins), for controls that size themselves to one side of the fold;
    /// nil outside any scope.
    var duoContentWidth: CGFloat? {
        get { self[DuoContentWidthKey.self] }
        set { self[DuoContentWidthKey.self] = newValue }
    }

    /// The scope's height (a page's, a pane's or a sheet's), for what's sized from it; nil outside any scope.
    var duoScopeHeight: CGFloat? {
        get { self[DuoScopeHeightKey.self] }
        set { self[DuoScopeHeightKey.self] = newValue }
    }

    /// A long table's window height here: 360 in compact (every iPhone, the outer display), the smaller of 360 and 45%
    /// of the scope's height in medium and wide (§2.7). Read it with `@Environment(\.duoTableWindow)`.
    var duoTableWindow: CGFloat { duoBand.tableWindow(scopeHeight: duoScopeHeight) }
}
