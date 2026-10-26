import SwiftUI

// What the web's chart pages (Vitals, Body, Sleep) share from Detail.tsx: the day picker, the range picker and the
// page's tabs. Here once, so slices H, I and J build their pages from the same pieces. A page keeps its own selection;
// its first one comes from its route's query (`dashboard.request(for:)` on a tab, the `query` its init gets under More).

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

    var body: some View {
        ViewThatFits(in: .horizontal) {
            well(HStack(spacing: 0) { chips }).fixedSize()
            well(WrapLayout(spacing: 0, lineSpacing: 0) { chips }).fixedSize(horizontal: false, vertical: true)
        }
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

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

/// The previous and next day (DayNav): the day in words ("Today", "Yesterday", "3 days ago", a date), then ‹ and ›.
/// `date` nil is today; the next day never passes today.
struct DayNav: View {
    let today: String
    @Binding var date: String?
    /// The day in words; Today, Yesterday, a few days ago or the date when nil.
    var label: ((String) -> String)?

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
