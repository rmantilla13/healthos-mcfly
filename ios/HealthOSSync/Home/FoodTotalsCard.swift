import SwiftUI

/// Home's optional "Food" card (home.food, src/pages/Nutrition.tsx NutritionCard): the latest logged day's totals, up to
/// five of them, and which of the last 7 days have anything logged. Only while Nutrition is on (Home doesn't place it
/// otherwise), from GET /api/nutrition?days=7, which already leaves out what the person chose not to see. Home reads it
/// (HomeReads) and places the card only once there's a reply, as on the web. Its ↗ opens Nutrition.
struct FoodTotalsCard: View {
    let data: NutritionData
    @Environment(Dashboard.self) private var dashboard

    /// What the card shows from a reply: the latest day, its nutrients (in the web's order, without saturated fat and
    /// sodium, at most five), and each of the window's days, logged or not.
    struct Model: Equatable {
        struct Day: Equatable {
            let date: String
            let logged: Bool
        }

        let latest: FoodDay?
        let shown: [String]
        let days: [Day]
        /// "Yesterday · MyFitnessPal", or "Last 7 days" with nothing logged.
        let note: String

        static func == (a: Model, b: Model) -> Bool { a.latest?.date == b.latest?.date && a.shown == b.shown && a.days == b.days && a.note == b.note }

        init(_ data: NutritionData) {
            let latest = data.days.last
            self.latest = latest
            shown = latest.map { day in Array(FoodMath.order.filter { day.values[$0] != nil && $0 != "sat_fat_g" && $0 != "sodium_mg" }.prefix(5)) } ?? []
            let logged = Set(data.days.map(\.date))
            days = FoodMath.dates(from: data.start, to: data.end).map { Day(date: $0, logged: logged.contains($0)) }
            note = latest.map { "\(Fmt.relativeDay($0.date, today: data.today)) · \($0.app)" } ?? "Last 7 days"
        }
    }

    var body: some View { card(Model(data)) }

    private func card(_ m: Model) -> some View {
        Button { dashboard.open(.nutrition) } label: {
            VStack(alignment: .leading, spacing: 10) {
                CardHead(title: "Food")
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .bottom, spacing: 28) {
                        values(m)
                        Spacer(minLength: 0)
                        side(m, alignment: .trailing)
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        values(m)
                        side(m, alignment: .leading)
                    }
                }
            }
            .card(.peach)
            .contentShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        }
        .buttonStyle(CardPressStyle())
        .accessibilityLabel(spoken(m))
        .accessibilityHint("Opens Nutrition")
        .accessibilityIdentifier("card-home.food")
    }

    @ViewBuilder private func values(_ m: Model) -> some View {
        if let latest = m.latest {
            if m.shown.isEmpty {
                Text("Logged in \(latest.app)").font(.app(.footnote, weight: .medium)).foregroundStyle(Palette.ink)
            } else {
                // Wraps like the web's row of values: as many to a line as fit.
                HomeFlowRow(spacing: 28, lineSpacing: 10) {
                    ForEach(m.shown, id: \.self) { key in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(FoodMath.name(key)).font(.app(.caption)).foregroundStyle(Palette.ink2)
                            Text(FoodMath.amount(key, latest.values[key] ?? 0))
                                .font(.app(size: 22, weight: .medium, relativeTo: .title2)).tracking(-0.44).foregroundStyle(Palette.ink)
                        }
                    }
                }
            }
        } else {
            Text("Nothing logged in the last 7 days.").font(.app(.caption)).foregroundStyle(Palette.ink2)
        }
    }

    private func side(_ m: Model, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 6) {
            HStack(spacing: 4) {
                ForEach(m.days, id: \.date) { day in
                    RoundedRectangle(cornerRadius: 4).fill(day.logged ? Palette.barAccent : Palette.grid).frame(width: 16, height: 16)
                }
            }
            Text(m.note).font(.app(.caption)).foregroundStyle(Palette.ink2)
        }
    }

    private func spoken(_ m: Model) -> String {
        let logged = m.days.filter(\.logged).count
        var parts = ["Food"]
        if let latest = m.latest {
            parts.append(m.shown.isEmpty ? "Logged in \(latest.app)" : m.shown.map { "\(FoodMath.name($0)) \(FoodMath.amount($0, latest.values[$0] ?? 0))" }.joined(separator: ", "))
        } else {
            parts.append("Nothing logged in the last 7 days")
        }
        parts.append("Logged on \(logged) of the last \(m.days.count) days")
        parts.append(m.note)
        return parts.joined(separator: ". ")
    }
}

/// Lays its children out left to right, wrapping onto a new line when the next doesn't fit (CSS flex-wrap). A child wider
/// than the whole line gets a line of its own at the line's width, and as many lines of its own as its words take there.
struct HomeFlowRow: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8
    /// `.trailing`: each line starts from the right (Home's wide header), its children centred on the line; `.leading`
    /// (the default): from the left, each at the line's top.
    var alignment: HorizontalAlignment = .leading

    private func lines(_ subviews: Subviews, width: CGFloat) -> [[(Int, CGSize)]] {
        var lines: [[(Int, CGSize)]] = [[]]
        var x: CGFloat = 0
        for (i, view) in subviews.enumerated() {
            // Where it breaks goes by each child's one-line width, as flex-wrap's does.
            let ideal = view.sizeThatFits(.unspecified)
            let w = min(ideal.width, width)
            // Narrowed to the line, it's measured again there: its words wrap and it grows taller.
            let h = w < ideal.width ? view.sizeThatFits(ProposedViewSize(width: w, height: nil)).height : ideal.height
            if !lines[lines.count - 1].isEmpty, x + spacing + w > width {
                lines.append([])
                x = 0
            }
            x += (lines[lines.count - 1].isEmpty ? 0 : spacing) + w
            lines[lines.count - 1].append((i, CGSize(width: w, height: h)))
        }
        return lines
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = lines(subviews, width: width)
        let height = rows.map { $0.map(\.1.height).max() ?? 0 }.reduce(0, +) + lineSpacing * CGFloat(max(0, rows.count - 1))
        let used = rows.map { row in row.map(\.1.width).reduce(0, +) + spacing * CGFloat(max(0, row.count - 1)) }.max() ?? 0
        return CGSize(width: proposal.width ?? used, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        let trailing = alignment == .trailing
        for row in lines(subviews, width: bounds.width) {
            let used = row.map(\.1.width).reduce(0, +) + spacing * CGFloat(max(0, row.count - 1))
            var x = trailing ? bounds.maxX - used : bounds.minX
            let h = row.map(\.1.height).max() ?? 0
            for (i, size) in row {
                subviews[i].place(at: CGPoint(x: x, y: y + (trailing ? (h - size.height) / 2 : 0)),
                                  proposal: ProposedViewSize(width: size.width, height: size.height))
                x += size.width + spacing
            }
            y += h + lineSpacing
        }
    }
}
