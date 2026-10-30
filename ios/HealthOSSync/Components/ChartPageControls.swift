import Charts
import SwiftUI
import UIKit

// What the web's chart pages (Vitals, Body, Sleep) share from Detail.tsx: the day picker, the range picker and the
// page's tabs. Here once, so slices H, I and J build their pages from the same pieces. A page keeps its own selection;
// its first one comes from its route's query (`dashboard.request(for:)` on a tab, the `query` its init gets under More).
// On a page split on the iPhone Duo's fold each keeps to one side (D10): the tabs to the leading side, the range and day
// pickers no wider than the narrower side. They read the page's fold, so put them in the page's content, full width
// (the tabs) or in a full-width header row (the pickers).

/// A chart page's range (RANGES in Detail.tsx): 7 days to a year, and Day once the page has hourly data (DAY_RANGE).
struct ChartRange: Hashable, Identifiable {
    let days: Int
    let label: String
    var id: Int { days }

    /// 7 days, 30 days, 90 days, 1 year.
    static let standard = [ChartRange(days: 7, label: "7 days"), ChartRange(days: 30, label: "30 days"),
                           ChartRange(days: 90, label: "90 days"), ChartRange(days: 365, label: "1 year")]
    /// One day by the hour: its value in the shared range (DAY); a page without a Day view reads it as 30 days.
    static let day = ChartRange(days: 1, label: "Day")
    /// Day first, then the standard ranges.
    static let withDay = [day] + standard
}

/// The range picker (RangeFilters): the ranges in a soft well, the chosen one raised on white. One row where they fit;
/// at the largest text sizes they wrap onto more rows inside the well, never breaking a label or hiding one off the
/// edge. Bind it to `dashboard.rangeDays` so the range follows the person from page to page, as the web's does in a
/// session.
struct RangeFilters: View {
    @Binding var days: Int
    var ranges: [ChartRange] = ChartRange.standard
    @Environment(\.duoFold) private var fold
    @Environment(\.duoContentWidth) private var contentWidth

    var body: some View {
        ViewThatFits(in: .horizontal) {
            well(HStack(spacing: 0) { chips }).fixedSize()
            well(WrapLayout(spacing: 0, lineSpacing: 0) { chips }).fixedSize(horizontal: false, vertical: true)
        }
        // On a page split on the fold (the iPhone Duo open), never wider than the narrower side, so wherever its row
        // puts it (trailing, after the page's line, or under it) it sits wholly on one side. Elsewhere this changes
        // nothing.
        .frame(maxWidth: contentWidth.flatMap { fold.narrowerSide(width: $0) })
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Date range")
    }

    private var chips: some View {
        ForEach(ranges) { range in
            let on = range.days == days
            Button(range.label) { days = range.days }
                .buttonStyle(.plain)
                .font(.app(size: 13, weight: .medium, relativeTo: .footnote))
                .foregroundStyle(on ? Palette.ink : Palette.ink2)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background {
                    if on {
                        RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.surface)
                            .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
                    }
                }
                .accessibilityAddTraits(on ? .isSelected : [])
        }
    }

    private func well(_ chips: some View) -> some View {
        chips
            .padding(3)
            .background(Palette.surface2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.border))
    }
}

/// One of a page's tabs (Overview, Stages, Trends…): its id is the route's `tab` query (#/sleep?tab=stages).
struct PageTab: Hashable, Identifiable {
    let id: String
    let label: String
}

/// A page's tabs (Tabs in Detail.tsx): pills, the chosen one in ink with white words. Scrolls sideways when they don't
/// fit, never wrapping a label.
struct PageTabs: View {
    let tabs: [PageTab]
    @Binding var selection: String
    /// What the tabs are, for VoiceOver ("Sleep sections").
    let label: String

    @Environment(\.duoFold) private var fold

    var body: some View {
        Group {
            if fold.splits {
                // On a page split on the fold, the tabs keep to the leading side (`duoOneSide`): one row where they
                // fit, and at the largest text sizes more rows there, so no tab is hidden past the fold or cut off at it.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 4) { pills }.fixedSize()
                    WrapLayout(spacing: 4, lineSpacing: 4) { pills }.fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                // Elsewhere they're as they were: one row that scrolls sideways when it doesn't fit.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) { pills }
                }
            }
        }
        .duoOneSide()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    private var pills: some View {
        ForEach(tabs) { tab in
            let on = tab.id == selection
            Button(tab.label) { selection = tab.id }
                .buttonStyle(.plain)
                .font(.app(size: 13, weight: .medium, relativeTo: .footnote))
                .foregroundStyle(on ? Palette.surface : Palette.ink2)
                .lineLimit(1)
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background(on ? Palette.ink : .clear, in: Capsule())
                .accessibilityAddTraits(on ? .isSelected : [])
        }
    }
}

/// The previous and next day (DayNav): the day in words ("Today", "Yesterday", "3 days ago", a date), then ‹ and ›.
/// `date` nil is today; the next day never passes today.
struct DayNav: View {
    let today: String
    @Binding var date: String?
    /// The day in words; Today, Yesterday, a few days ago or the date when nil.
    var label: ((String) -> String)?
    @Environment(\.duoFold) private var fold
    @Environment(\.duoContentWidth) private var contentWidth

    var body: some View {
        let current = date ?? today
        HStack(spacing: 6) {
            Text(label?(current) ?? Fmt.relativeDay(current, today: today))
                .font(.app(size: 13, relativeTo: .footnote))
                .foregroundStyle(Palette.ink2)
                .padding(.trailing, 6)
            step("chevron.left", "Previous day") { date = Day.add(current, -1) }
            step("chevron.right", "Next day") {
                let next = Day.add(current, 1)
                date = next >= today ? nil : next
            }
            .disabled(current >= today)
        }
        // On a page split on the fold, never wider than the narrower side (put it in the header's trailing group, or as
        // its own leading and trailing groups); elsewhere this changes nothing.
        .frame(maxWidth: contentWidth.flatMap { fold.narrowerSide(width: $0) })
    }

    private func step(_ symbol: String, _ name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.footnote.weight(.semibold))
                .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                .foregroundStyle(Palette.ink2)
                .frame(width: 30, height: 30)
                .background(Palette.surface, in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
    }
}

// MARK: - Picking a point without stopping the page's scroll

extension View {
    /// Picks a Swift Charts chart's point under a tap, or under a finger moved sideways along the chart, as the web's
    /// charts do on a phone (touch-action: pan-y): a drag that starts up or down scrolls the page instead of picking.
    /// Swift Charts' own `chartXSelection` takes every drag that starts on the chart, so a page couldn't be scrolled from
    /// one. The pick stays when the finger lifts; a tap on another bar moves it.
    func chartScrub<Value: Plottable>(_ selection: Binding<Value?>) -> some View {
        chartOverlay { proxy in
            GeometryReader { geo in
                let plot = proxy.plotFrame.map { geo[$0] } ?? CGRect(origin: .zero, size: geo.size)
                let pick: (CGPoint) -> Void = { point in
                    if let value = proxy.value(atX: point.x - plot.minX, as: Value.self) { selection.wrappedValue = value }
                }
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .gesture(SpatialTapGesture().onEnded { pick($0.location) })
                    .modifier(SidewaysScrub(moved: pick))
            }
        }
    }
}

/// When a drag on a chart picks points rather than scrolling the page: when it starts more sideways than up or down.
enum ChartScrub {
    static func isSideways(_ velocity: CGPoint) -> Bool { abs(velocity.x) > abs(velocity.y) }
}

/// A sideways drag that picks as it goes (iOS 18 and later, where UIKit's pan can decline a drag that goes up or down
/// and leave it to the scroll view); on iOS 17, a tap picks.
private struct SidewaysScrub: ViewModifier {
    let moved: (CGPoint) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.gesture(SidewaysPan(moved: moved))
        } else {
            content
        }
    }
}

@available(iOS 18.0, *)
private struct SidewaysPan: UIGestureRecognizerRepresentable {
    let moved: (CGPoint) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        switch recognizer.state {
        case .began, .changed: moved(context.converter.localLocation)
        default: break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        /// Up or down: the pan steps aside, and the page scrolls.
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return true }
            return ChartScrub.isSideways(pan.velocity(in: pan.view))
        }
    }
}
