import SwiftUI

/// A chart's key in DM Sans: Swift Charts draws its own legend in the system face, whatever the app's font. A dot in
/// each series' colour and its name, in a row, or one under another when the row doesn't fit (the large text sizes).
///
///     .chartLegend(position: .bottom, alignment: .leading) {
///         ChartLegend(SleepTrends.stages.map { ($0.label, $0.color) })
///     }
struct ChartLegend: View {
    let items: [(label: String, color: Color)]

    init(_ items: [(label: String, color: Color)]) { self.items = items }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { entries }
            VStack(alignment: .leading, spacing: 4) { entries }
        }
        .font(.app(.caption))
        .foregroundStyle(Palette.ink3)
    }

    private var entries: some View {
        ForEach(items, id: \.label) { item in
            HStack(spacing: 5) {
                Circle().fill(item.color).frame(width: 7, height: 7)
                Text(item.label)
            }
        }
    }
}
