import SwiftUI

/// Home's "Today's nutrition" (src/components/home/TodayNutrition.tsx): the day from 6:00 to 21:00 as 12 segments,
/// each tinted where something was logged (the food log's own entries, GET /api/nutrition/log, by their time), and
/// McFly's orb to log the next one. Only with Nutrition on, and only what the person chose to see: energy only in
/// 'all', amounts never in 'none' (the server leaves them out anyway). Off, it's the same empty card, nothing is asked
/// for, and the orb opens Nutrition, which explains it and offers to turn it on. Empty segments stay plain: a tint
/// always means something was logged then. The entries stay in memory, never on disk.
struct TodayNutritionCard: View {
    /// The day Home shows, and the person's today.
    let date: String
    let today: String
    @Environment(Dashboard.self) private var dashboard
    @State private var entries: [FoodEntry] = []

    // MARK: The web's numbers

    static let start = 6 * 60
    static let segment = 75
    static let segments = 12
    static let ticks = ["6:00", "9:00", "12:00", "15:00", "18:00", "21:00"]
    /// The food log keeps this many days (GET /api/nutrition/log?days=, at most 31).
    static let logDays = 31

    /// Morning, midday or later: the tint a logged segment takes, by its first entry's time.
    enum Part: String, Equatable {
        case morning, midday, evening

        /// home.css --home-meal-*, light and dark.
        var color: Color {
            switch self {
            case .morning: Palette.dynamic(0xB6D4A4, 0x5F8A52)
            case .midday: Palette.dynamic(0xB3C0EE, 0x5C69A6)
            case .evening: Palette.dynamic(0xF0C391, 0xA8763F)
            }
        }
    }

    /// home.css --home-meal-empty.
    static let emptySegment = Themed(.rgba(28, 37, 32, 0.07), .rgba(255, 255, 255, 0.08)).color

    static func minutes(_ time: String) -> Int {
        let parts = time.split(separator: ":")
        guard parts.count >= 2, let h = Int(parts[0]), let m = Int(parts[1].prefix(2)) else { return 0 }
        return h * 60 + m
    }

    /// The segment a time falls in; before 6:00 counts as the first, after 21:00 as the last.
    static func segment(of time: String) -> Int { min(segments - 1, max(0, Int((Double(minutes(time) - start) / Double(segment)).rounded(.down)))) }

    static func part(of time: String) -> Part { minutes(time) < 11 * 60 ? .morning : minutes(time) < 15 * 60 ? .midday : .evening }

    /// "08:10", "08:10 and 12:30", "08:10, 12:30 and 19:00".
    static func listTimes(_ times: [String]) -> String {
        times.count < 2 ? times.joined() : "\(times.dropLast().joined(separator: ", ")) and \(times.last!)"
    }

    /// How many days back the day is (never a date in the address), within what the log keeps. While Nutrition is off
    /// there's nothing for any day, so it's today's invitation.
    static func daysBack(date: String, today: String, on: Bool) -> Int { on ? max(0, Fmt.daysBetween(date, today)) : 0 }

    /// What the card says about one day's entries.
    struct Model: Equatable {
        let title: String
        /// Each segment's tint, nil where nothing was logged.
        let segments: [Part?]
        let count: Int
        /// The day's energy, only for people who chose to see it.
        let kcal: Double
        /// "Latest: Oatmeal, 08:10".
        let latest: String?
        /// With nothing logged: the title and line of the empty state.
        let empty: (title: String, text: String)?
        /// The track's words for VoiceOver.
        let spoken: String

        static func == (a: Model, b: Model) -> Bool {
            a.title == b.title && a.segments == b.segments && a.count == b.count && a.kcal == b.kcal && a.latest == b.latest
                && a.empty?.title == b.empty?.title && a.empty?.text == b.empty?.text && a.spoken == b.spoken
        }

        init(entries all: [FoodEntry], date: String, today: String, mode: NutritionMode?) {
            let back = TodayNutritionCard.daysBack(date: date, today: today, on: mode != nil)
            let kept = back + 1 <= TodayNutritionCard.logDays
            let isToday = back == 0
            let entries = all.filter { $0.date == date }
            title = isToday ? "Today's nutrition" : "Nutrition · \(Fmt.day(date, "EEEMMMd"))"
            var parts = [Part?](repeating: nil, count: TodayNutritionCard.segments)
            var firstTime: [Int: String] = [:]
            for e in entries {
                let i = TodayNutritionCard.segment(of: e.time)
                // The tint follows the segment's first entry, as the web's map keeps its first.
                if firstTime[i] == nil { firstTime[i] = e.time }
            }
            for (i, time) in firstTime { parts[i] = TodayNutritionCard.part(of: time) }
            segments = parts
            count = entries.count
            kcal = mode == .all ? entries.reduce(0) { $0 + ($1.values["energy_kcal"] ?? 0) } : 0
            let newest = entries.max { $0.time < $1.time }
            latest = newest.map { "Latest: \($0.name), \($0.time)" }
            let times = entries.map(\.time).sorted()
            spoken = entries.isEmpty ? (isToday ? "Nothing logged yet today" : "Nothing logged that day")
                : "\(entries.count) \(entries.count == 1 ? "entry" : "entries") \(isToday ? "today" : "that day"), at \(TodayNutritionCard.listTimes(times))"
            if !entries.isEmpty {
                empty = nil
            } else if mode != nil && !kept {
                empty = ("Older than a month", "Home shows the last 31 days of your food log.")
            } else if isToday {
                empty = ("A fresh start", "Log your first meal to see your day take shape.")
            } else {
                empty = ("Nothing logged that day", "Meals you log appear here at the time you had them.")
            }
        }
    }

    var body: some View {
        let mode = dashboard.nutritionMode
        let on = mode != nil
        let back = Self.daysBack(date: date, today: today, on: on)
        let m = Model(entries: entries, date: date, today: today, mode: mode)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text(m.title).font(.app(.footnote, weight: .medium)).foregroundStyle(Palette.ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                // Nutrition's Today composer with Nutrition on (compose=1), Nutrition's own page while it's off.
                Button { dashboard.open(on ? AppRoute(.nutrition, query: ["compose": "1"]) : .nutrition) } label: {
                    Orb(size: 22).frame(width: 44, height: 44).contentShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(-10)
                .accessibilityLabel(on ? "Log food" : "Open Nutrition")
                .accessibilityIdentifier("logFood")
            }
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    ForEach(0..<Self.segments, id: \.self) { i in
                        Capsule().fill(m.segments[i]?.color ?? Self.emptySegment).frame(height: 6)
                    }
                }
                .padding(.top, 10)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(m.spoken)
                HStack {
                    ForEach(Array(Self.ticks.enumerated()), id: \.offset) { i, t in
                        Text(t)
                        if i < Self.ticks.count - 1 { Spacer(minLength: 0) }
                    }
                }
                .font(.app(size: 10.5, relativeTo: .caption2))
                .foregroundStyle(Palette.ink3)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                // Six times across one card: beyond this they'd no longer fit side by side. VoiceOver reads the
                // track's times in full.
                .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                .accessibilityHidden(true)
            }
            if let empty = m.empty {
                VStack(spacing: 6) {
                    Text(empty.title).font(.app(size: 14, weight: .medium, relativeTo: .subheadline)).foregroundStyle(Palette.ink)
                    Text(empty.text).font(.app(.caption)).foregroundStyle(Palette.ink2)
                }
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 260)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(m.count) \(m.count == 1 ? "entry" : "entries")\(m.kcal > 0 ? " · \(Fmt.number(m.kcal)) kcal" : "")")
                        .font(.app(size: 22, weight: .medium, relativeTo: .title2)).tracking(-0.44).foregroundStyle(Palette.ink)
                    if let latest = m.latest {
                        Text(latest).font(.app(.caption)).foregroundStyle(Palette.ink2).lineLimit(1).truncationMode(.tail)
                    }
                }
            }
        }
        .modifier(LowerCard(tint: .cream))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("card-home.nutrition")
        // Only with Nutrition on, and only within the 31 days the log keeps: nothing is asked for otherwise.
        .task(id: "\(date)|\(back)|\(mode?.rawValue ?? "off")|\(dashboard.generation)") {
            guard on, back + 1 <= Self.logDays else {
                entries = []
                return
            }
            if let log = try? await dashboard.loadFoodLog(days: back + 1) {
                entries = log.enabled ? log.entries.filter { $0.date == date } : []
            } else {
                // A server without the food log, or a read that failed: nothing logged to show.
                entries = []
            }
        }
    }
}

/// The lower pair's card (home.css .home-lower > .card): as tall as a signal card, at least, in its wash.
struct LowerCard: ViewModifier {
    let tint: CardTint

    func body(content: Content) -> some View {
        CardMinHeight(min: 236 - 38) { content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading) }
            .card(tint)
    }
}
