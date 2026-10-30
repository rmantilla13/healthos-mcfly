import SwiftUI

// The overview's latest-workout card (WorkoutCard.tsx): that session's own figures, the same sport's recent sessions
// side by side, and a few general recovery suggestions after a recent one. Every figure is the workout's own, as Apple
// Health, WHOOP or a Fitbit export recorded it; pace and speed are its duration divided by its distance.

struct BodyWorkoutCard: View {
    let summary: Summary
    let read: BodyRead<[Workout]>
    /// The suggestions ticked so far, by workout (memory only: the web keeps them in that browser).
    let ticked: (String) -> Set<String>
    let tick: (String, String, Bool) -> Void
    @Environment(Dashboard.self) private var dashboard

    /// The figures under the headline (WorkoutCard.tsx stats), in its order.
    static func stats(_ w: Workout, units: Units) -> [(label: String, value: String)] {
        let minutes = BodyWorkoutMath.num(w.durationMin)
        let kind = BodySportKind.of(w.sport)
        let dist = BodyWorkoutMath.num(w.distanceM).map { BodyWorkoutMath.distance($0, units: units, kind: kind) }
        var out: [(String, String)] = []
        if dist != nil, let minutes { out.append(("Duration", Fmt.duration(minutes: minutes))) }
        if let pace = BodyWorkoutMath.pace(w, units: units) { out.append((pace.isSpeed ? "Avg speed" : "Avg pace", pace.text)) }
        if let avg = BodyWorkoutMath.num(w.avgHr) { out.append(("Avg heart rate", "\(Fmt.number(avg)) bpm")) }
        if let max = BodyWorkoutMath.num(w.maxHr) { out.append(("Max heart rate", "\(Fmt.number(max)) bpm")) }
        if let kcal = BodyWorkoutMath.num(w.energyKcal) { out.append(("Energy", "\(Fmt.number(kcal)) kcal")) }
        if let strain = BodyWorkoutMath.num(w.strain) { out.append(("Strain", "\(Fmt.number(strain, 1)) of 21")) }
        return out.map { (label: $0.0, value: $0.1) }
    }

    /// "No workouts in the 90 days up to today. Workouts come from Apple Health and WHOOP."
    static func none(_ s: Summary) -> String {
        "No workouts in the \(BodyWorkoutMath.days) days up to \(s.date == s.today ? "today" : Fmt.day(s.date, "MMMdyyyy")). Workouts come from Apple Health and WHOOP."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { dashboard.open(.activity) } label: {
                HStack {
                    Text("Latest workout").font(.app(.footnote, weight: .medium)).foregroundStyle(Palette.ink)
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right").font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.ink2).accessibilityHidden(true)
                }
                .frame(minHeight: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Latest workout")
            .accessibilityHint("Opens Activity on Body")
            switch read {
            case .loading: BodyNoData(text: "Loading…")
            case .failed(let words): BodyNoData(text: "Couldn't load your workouts: \(words)")
            case .done(let list):
                if let w = BodyWorkoutMath.latest(list, now: Date()) {
                    latest(w, list: list)
                } else {
                    BodyNoData(text: Self.none(summary))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("body.workout")
    }

    @ViewBuilder private func latest(_ w: Workout, list: [Workout]) -> some View {
        let units = dashboard.units
        let kind = BodySportKind.of(w.sport)
        let minutes = BodyWorkoutMath.num(w.durationMin)
        let dist = BodyWorkoutMath.num(w.distanceM).map { BodyWorkoutMath.distance($0, units: units, kind: kind) }
        let sessions = BodyWorkoutMath.recent(list, w, n: 6)
        HStack(spacing: 12) {
            Image(systemName: WorkoutListRow.symbol(w.sport)).font(.system(size: 15, weight: .medium)).foregroundStyle(Palette.ink2)
                .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                .frame(width: 40, height: 40)
                .background(Palette.surface2, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(w.sport).font(.app(.headline, weight: .medium)).foregroundStyle(Palette.ink)
                Text("\(Fmt.relativeDay(w.date, today: summary.today)) · \(BodyWorkoutMath.wallClock(w.start))").font(.app(.footnote)).foregroundStyle(Palette.ink2)
            }
        }
        .accessibilityElement(children: .combine)
        if let dist {
            BodyValue(value: Fmt.number(dist.value, dist.digits), unit: dist.unit)
        } else if let minutes {
            BodyValue(value: Fmt.duration(minutes: minutes), unit: "duration")
        }
        let stats = Self.stats(w, units: units)
        if !stats.isEmpty {
            BodyColumns(columns: 2, spacing: 12) {
                ForEach(stats, id: \.label) { s in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.label).font(.app(.caption)).foregroundStyle(Palette.ink3)
                        Text(s.value).font(.app(.subheadline, weight: .medium)).foregroundStyle(Palette.ink)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        if sessions.count > 1 {
            BodySessionBars(sessions: sessions, latest: w, units: units, kind: kind)
        } else {
            Text("No other \(w.sport.lowercased()) sessions in the last \(BodyWorkoutMath.days) days to compare with.")
                .font(.app(.caption)).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true)
        }
        if BodyWorkoutMath.suggestionsApply(w, now: Date()) {
            Divider().overlay(Palette.border).padding(.vertical, 4)
            VStack(alignment: .leading, spacing: 8) {
                Text("General suggestions").font(.app(.subheadline, weight: .semibold)).foregroundStyle(Palette.ink).accessibilityAddTraits(.isHeader)
                Text("Common ideas after a session like this, not personal or medical advice.").font(.app(.caption)).foregroundStyle(Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                let on = ticked(w.id)
                ForEach(BodyWorkoutMath.suggestions(w)) { sg in
                    let isOn = on.contains(sg.id)
                    Button { tick(w.id, sg.id, !isOn) } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: isOn ? "checkmark.square.fill" : "square").font(.system(size: 20)).foregroundStyle(isOn ? Palette.accentText : Palette.ink3)
                                .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(sg.text).font(.app(.footnote)).foregroundStyle(Palette.ink).fixedSize(horizontal: false, vertical: true)
                                Text(sg.why).font(.app(.caption)).foregroundStyle(Palette.ink3)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(isOn ? [.isSelected] : [])
                }
            }
        }
        Text(BodyWorkoutMath.from(w.source)).font(.app(.caption)).foregroundStyle(Palette.ink2).padding(.top, 4)
    }
}

/// Equal columns inside a card (the workout's figures), rows as tall as their tallest; one column at the accessibility
/// sizes.
struct BodyColumns<Content: View>: View {
    let columns: Int
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let n = typeSize.isAccessibilitySize ? 1 : columns
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing, alignment: .topLeading), count: n), alignment: .leading, spacing: 8) {
            content
        }
    }
}

/// The sport's recent sessions as bars, oldest to newest, this one in the accent colour, each with its value above and
/// its date below (WorkoutCard.tsx SessionBars).
struct BodySessionBars: View {
    let sessions: [Workout]
    let latest: Workout
    let units: Units
    let kind: BodySportKind

    var body: some View {
        let byDistance = BodyWorkoutMath.barsByDistance(sessions, latest: latest)
        let unit = byDistance ? BodyWorkoutMath.distance(1000, units: units, kind: kind).unit : "min"
        let values: [Double?] = sessions.map { w in
            if !byDistance { return BodyWorkoutMath.num(w.durationMin) }
            return BodyWorkoutMath.num(w.distanceM).map { BodyWorkoutMath.distance($0, units: units, kind: kind).value }
        }
        let text: (Double?) -> String = { v in v.map { byDistance ? Fmt.number($0, $0 >= 100 ? 0 : 1) : Fmt.number($0) } ?? String.emptyValue }
        let top = max(1, values.compactMap { $0 }.max() ?? 1)
        let caption = "\(byDistance ? "Distance (\(unit))" : "Duration (min)"), last \(sessions.count) \(latest.sport.lowercased()) sessions"
        VStack(alignment: .leading, spacing: 6) {
            Text(caption).font(.app(.caption)).foregroundStyle(Palette.ink2)
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(Array(sessions.enumerated()), id: \.element.id) { i, w in
                    let v = values[i]
                    let mine = w.id == latest.id
                    VStack(spacing: 3) {
                        Text(text(v)).font(.axis).foregroundStyle(mine ? Palette.ink : Palette.ink3).fixedSize()
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(mine ? Palette.barAccent : Palette.bar)
                            .frame(width: 18, height: max(v == nil ? 0 : 2, CGFloat((v ?? 0) / top) * 54))
                        Text(Fmt.day(w.date)).font(.axis).foregroundStyle(Palette.ink3).fixedSize()
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 92, alignment: .bottom)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caption)
        .accessibilityValue(sessions.enumerated().map { i, w in
            "\(Fmt.day(w.date, "EEEMMMd")): \(values[i] == nil ? "not recorded" : "\(text(values[i])) \(unit)")\(w.id == latest.id ? " (this workout)" : "")"
        }.joined(separator: ", "))
    }
}
