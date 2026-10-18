import SwiftUI

// Cycle tracking on Today and in Trends (src/pages/Cycle.tsx). The data comes from GET /api/cycle on its own,
// only while cycle tracking is on; nothing here reaches the summary, flags, patterns or the digest.

/// Where today sits in the cycle, on Today. Opens the Cycle section of Trends.
struct CycleCard: View {
    let cycle: CycleData
    let phase: CyclePhase
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        let layout = CycleLayout(cycle: cycle, day: phase.day)
        let next = phase.nextPeriodIn.map { " · " + CycleText.nextPeriod(in: $0) } ?? ""
        Button { dashboard.open(.cycle) } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Cycle").font(.subheadline.weight(.medium)).foregroundStyle(Palette.ink2)
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.caption.weight(.semibold)).foregroundStyle(Palette.ink3)
                }
                HStack(alignment: .center, spacing: 14) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(PhaseStyle.title(phase.name)).font(.title3.weight(.semibold)).foregroundStyle(Palette.ink)
                        Text("Day \(phase.day)\(next)").font(.footnote).foregroundStyle(Palette.ink2)
                        if let fertile = CycleText.fertileLine(cycle) {
                            Text(fertile).font(.caption).foregroundStyle(Palette.ink3)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    PhaseRing(layout: layout, phase: phase.name).frame(width: 84, height: 84)
                }
            }
            .card(.pink)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens Cycle")
    }
}

/// The Cycle section of Trends: this cycle, a five-week calendar, and recent cycle lengths.
struct CycleTrends: View {
    @Environment(Dashboard.self) private var dashboard
    @State private var cycle: CycleData?
    @State private var loaded = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 14) {
            if let cycle {
                CycleNowCard(cycle: cycle)
                CycleCalendarCard(cycle: cycle)
                CycleHistoryCard(cycle: cycle)
            } else if let error {
                ContentUnavailableView("Couldn't load your cycle", systemImage: "circle.dashed", description: Text(error))
            } else if loaded {
                Text("Your cycle shows here once cycle tracking is on and a period is logged, in Apple Health or on the web.")
                    .font(.footnote).foregroundStyle(Palette.ink3)
                    .card()
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            }
        }
        .task(id: "\(dashboard.generation)|\(dashboard.cycleTrackingOn)") {
            do {
                cycle = try await dashboard.cycle()
                error = nil
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
            loaded = true
        }
    }
}

// MARK: - Phase colours and words

private enum PhaseStyle {
    static func title(_ name: String) -> String {
        switch name {
        case "menstrual": "Menstrual phase"
        case "follicular": "Follicular phase"
        case "ovulatory": "Ovulatory phase"
        case "luteal": "Luteal phase"
        default: name.capitalized
        }
    }

    /// A plain line about the phase. Tendencies only: cycles and bodies vary.
    static func blurb(_ name: String) -> String {
        switch name {
        case "menstrual": "Your period. Energy may dip a little; going easier when you need to is fine."
        case "follicular": "After your period. Energy often builds through this part of the cycle."
        case "ovulatory": "Around ovulation, as estimated. Many people feel their most energetic now."
        case "luteal": "After ovulation. Temperature and resting heart rate often run a little higher, and sleep may feel lighter."
        default: ""
        }
    }

    static func color(_ name: String) -> Color {
        switch name {
        case "menstrual": Palette.gaugeFill
        case "follicular": Palette.series3
        case "ovulatory": Palette.series1
        case "luteal": Palette.warning
        default: Palette.ink3
        }
    }
}

private enum CycleText {
    static func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }

    static func range(_ a: String, _ b: String) -> String { a == b ? Fmt.day(a) : "\(Fmt.day(a)) – \(Fmt.day(b))" }

    /// A period that's due reads as "around today", never as late.
    static func nextPeriod(in days: Int) -> String {
        days <= 0 ? "period may start around today" : "next period in \(plural(days, "day"))"
    }

    /// This cycle's estimated fertile window: ahead, under way, or already past.
    static func fertileLine(_ cycle: CycleData) -> String? {
        guard let f = cycle.estimate?.fertile else { return nil }
        if cycle.today > f.end { return "Fertile window was \(range(f.start, f.end)), estimated" }
        return cycle.today >= f.start ? "Fertile window until \(Fmt.day(f.end)), estimated" : "Fertile window \(range(f.start, f.end)), estimated"
    }

    static func bleeding(_ d: CycleDay?) -> Bool { d?.flow != nil && d?.flow != "none" }
}

/// This cycle in cycle days: the period, the fertile window and the expected length, for the ring.
private struct CycleLayout {
    let length: Int
    let period: Int
    let fertile: ClosedRange<Int>
    let day: Int

    init(cycle: CycleData, day: Int) {
        let start = cycle.current?.start
        let cycleDay = { (date: String) in start.map { Fmt.daysBetween($0, date) + 1 } }
        var length = cycle.stats?.cycleDays ?? 28
        if let next = cycle.estimate?.nextPeriod.date, let d = cycleDay(next) { length = d - 1 }
        length = max(length, 15)
        let period = min(max(cycle.stats?.periodDays ?? 5, 1), length)
        var fertile: ClosedRange<Int>
        if let f = cycle.estimate?.fertile, let a = cycleDay(f.start), let b = cycleDay(f.end) {
            fertile = max(a, 1)...max(a, b, 1)
        } else {
            let ovulation = length - 14
            fertile = (ovulation - 5)...(ovulation + 1)
        }
        self.length = max(length, fertile.upperBound)
        self.period = period
        self.fertile = fertile
        self.day = day
    }

    /// Phase segments as fractions of the cycle: menstrual, follicular, ovulatory, luteal.
    var segments: [(name: String, from: Double, to: Double)] {
        let l = Double(length)
        let p = Double(period) / l
        let fs = max(p, Double(fertile.lowerBound - 1) / l)
        let fe = min(1, max(fs, Double(fertile.upperBound) / l))
        return [("menstrual", 0, p), ("follicular", p, fs), ("ovulatory", fs, fe), ("luteal", fe, 1)].filter { $0.2 > $0.1 }
    }

    /// Where today falls on the ring; a long cycle stops at the end rather than wrapping.
    var position: Double { (Double(min(day, length)) - 0.5) / Double(length) }
}

/// A ring of the cycle's phases, today's phase in full colour and a dot at today.
private struct PhaseRing: View {
    let layout: CycleLayout
    let phase: String
    var lineWidth: CGFloat = 8

    var body: some View {
        ZStack {
            Canvas { ctx, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let r = min(size.width, size.height) / 2 - lineWidth / 2 - 3
                let angle = { (f: Double) in Angle.degrees(-90 + 360 * f) }
                for s in layout.segments {
                    let gap = min(1.5, (s.to - s.from) * 360 / 4)
                    var arc = Path()
                    arc.addArc(center: c, radius: r, startAngle: angle(s.from) + .degrees(gap), endAngle: angle(s.to) - .degrees(gap), clockwise: false)
                    let color = PhaseStyle.color(s.name).opacity(s.name == phase ? 1 : 0.3)
                    ctx.stroke(arc, with: .color(color), style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                }
                let a = angle(layout.position).radians
                let p = CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
                let dot = Path(ellipseIn: CGRect(x: p.x - 5.5, y: p.y - 5.5, width: 11, height: 11))
                ctx.fill(dot, with: .color(Palette.ink))
                ctx.stroke(dot, with: .color(Palette.surface), lineWidth: 2)
            }
            VStack(spacing: 0) {
                Text("Day").font(.caption2).foregroundStyle(Palette.ink3)
                Text("\(layout.day)").font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(Palette.ink)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Trends cards

/// This cycle: phase, day, next period and fertile window, or why there's no estimate yet.
private struct CycleNowCard: View {
    let cycle: CycleData

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("This cycle").font(.headline).foregroundStyle(Palette.ink)
                Spacer()
                if cycle.estimate != nil { Chip(text: "Estimate") }
            }
            if let current = cycle.current {
                HStack(alignment: .center, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        if let phase = cycle.phase {
                            Text(PhaseStyle.title(phase.name)).font(.title2.weight(.semibold)).foregroundStyle(Palette.ink)
                        }
                        Text("Day \(current.day)").font(cycle.phase == nil ? .title2.weight(.semibold) : .subheadline.weight(.medium))
                            .foregroundStyle(cycle.phase == nil ? Palette.ink : Palette.ink2)
                        Text("Period started \(Fmt.day(current.start))").font(.caption).foregroundStyle(Palette.ink3)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if let phase = cycle.phase {
                        PhaseRing(layout: CycleLayout(cycle: cycle, day: phase.day), phase: phase.name).frame(width: 76, height: 76)
                    }
                }
                if let phase = cycle.phase {
                    Text(PhaseStyle.blurb(phase.name)).font(.footnote).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true)
                }
                if let est = cycle.estimate {
                    let until = Fmt.daysBetween(cycle.today, est.nextPeriod.date)
                    VStack(alignment: .leading, spacing: 10) {
                        fact("Next period",
                             until > 0 ? "Around \(Fmt.day(est.nextPeriod.date)), in \(CycleText.plural(until, "day"))" : until == 0 ? "May start around today" : "Expected around \(Fmt.day(est.nextPeriod.date))",
                             "Usually \(CycleText.range(est.nextPeriod.earliest, est.nextPeriod.latest))")
                        fact("Fertile window", CycleText.range(est.fertile.start, est.fertile.end), "Ovulation around \(Fmt.day(est.ovulation))")
                    }
                } else {
                    Text(cycle.noEstimate == "stale"
                        ? "Your latest logged period started \(Fmt.day(current.start)). Log your most recent one to see estimates again."
                        : "Estimates appear after two complete cycles: three period starts.")
                        .font(.footnote).foregroundStyle(Palette.ink3).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("No period logged yet. Log the first day of your next one, or add your history in Apple Health.")
                    .font(.footnote).foregroundStyle(Palette.ink3).fixedSize(horizontal: false, vertical: true)
            }
            if let est = cycle.estimate {
                Text("Estimated from \(Self.basis(est)). Cycles vary, so these are estimates, not medical advice and not reliable as contraception.")
                    .font(.caption).foregroundStyle(Palette.ink3).fixedSize(horizontal: false, vertical: true)
            }
        }
        .card(.pink)
    }

    private func fact(_ title: String, _ value: String, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(Palette.ink3)
            Text(value).font(.subheadline.weight(.medium)).foregroundStyle(Palette.ink)
            Text(note).font(.caption).foregroundStyle(Palette.ink3)
        }
        .accessibilityElement(children: .combine)
    }

    private static func basis(_ est: CycleData.Estimate) -> String {
        switch est.basis {
        case "lh_test": "your LH test this cycle"
        case "bbt": "your temperature rise this cycle"
        default: "your last \(CycleText.plural(est.cycles ?? 0, "cycle"))"
        }
    }
}

/// Five weeks around today, Monday first: logged period days, the expected period, the fertile window and ovulation.
private struct CycleCalendarCard: View {
    let cycle: CycleData

    private static let weekdays = ["M", "T", "W", "T", "F", "S", "S"]
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)

    var body: some View {
        let dates = Self.dates(cycle)
        let byDate = Dictionary(cycle.days.map { ($0.date, $0) }, uniquingKeysWith: { _, b in b })
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Calendar").font(.headline).foregroundStyle(Palette.ink)
                Spacer()
                if let first = dates.first, let last = dates.last {
                    Text(CycleText.range(first, last)).font(.caption).foregroundStyle(Palette.ink3)
                }
            }
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(Array(Self.weekdays.enumerated()), id: \.offset) { _, w in
                    Text(w).font(.caption2.weight(.medium)).foregroundStyle(Palette.ink3).accessibilityHidden(true)
                }
                ForEach(dates, id: \.self) { date in
                    cell(date, day: byDate[date])
                }
            }
            legend
        }
        .card()
    }

    private struct Marks {
        var period = false
        var predicted = false
        var fertile = false
        var ovulation = false
        var today = false
        var future = false
    }

    private func marks(_ date: String, day: CycleDay?) -> Marks {
        var m = Marks()
        m.period = CycleText.bleeding(day)
        m.today = date == cycle.today
        m.future = date > cycle.today
        if let est = cycle.estimate {
            let predictedEnd = Day.add(est.nextPeriod.date, (cycle.stats?.periodDays ?? 5) - 1)
            m.predicted = !m.period && date >= cycle.today && date >= est.nextPeriod.date && date <= predictedEnd
            m.fertile = date >= est.fertile.start && date <= est.fertile.end
            m.ovulation = date == est.ovulation
        }
        return m
    }

    private func cell(_ date: String, day: CycleDay?) -> some View {
        let m = marks(date, day: day)
        let number = Text("\(Int(date.suffix(2)) ?? 0)")
            .font(.footnote.weight(m.period || m.today ? .semibold : .regular))
            .monospacedDigit()
            .underline(m.today)
            .foregroundStyle(m.period ? Palette.surface : m.predicted ? Palette.gaugeFill : m.fertile ? Tone.blue.ink : m.future ? Palette.ink3 : Palette.ink)
        let states = [
            m.today ? "today" : nil,
            m.period ? "period" : nil,
            m.predicted ? "expected period" : nil,
            m.fertile ? "fertile window, estimated" : nil,
            m.ovulation ? "estimated ovulation" : nil,
        ].compactMap { $0 }
        return number
            .frame(maxWidth: 40)
            .frame(height: 36)
            .background {
                if m.period {
                    Circle().fill(Palette.gaugeFill)
                } else if m.fertile {
                    Circle().fill(Tone.blue.background)
                }
            }
            .overlay {
                if m.predicted { Circle().strokeBorder(Palette.gaugeFill, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2])) }
                if m.ovulation { Circle().strokeBorder(Tone.blue.ink, lineWidth: 1.5).padding(2) }
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(([Fmt.day(date, "EEEEMMMMd")] + states).joined(separator: ", "))
    }

    private var legend: some View {
        let keys = [
            LegendItem(label: "Period", shape: AnyView(Circle().fill(Palette.gaugeFill))),
            LegendItem(label: "Expected period", shape: AnyView(Circle().strokeBorder(Palette.gaugeFill, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2])))),
            LegendItem(label: "Fertile (estimate)", shape: AnyView(Circle().fill(Tone.blue.background))),
            LegendItem(label: "Ovulation (estimate)", shape: AnyView(Circle().strokeBorder(Tone.blue.ink, lineWidth: 1.5))),
        ]
        // Without an estimate only logged periods can show.
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(cycle.estimate == nil ? Array(keys.prefix(1)) : keys) { key in
                HStack(spacing: 6) {
                    key.shape.frame(width: 12, height: 12)
                    Text(key.label).font(.caption2).foregroundStyle(Palette.ink3)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private struct LegendItem: Identifiable {
        let label: String
        let shape: AnyView
        var id: String { label }
    }

    /// 35 days from the Monday on or before the current period's start, or four weeks back when that's longer ago,
    /// so today is always in view along with as much of this cycle as fits.
    static func dates(_ cycle: CycleData) -> [String] {
        let fourWeeksBack = Day.add(cycle.today, -27)
        let anchor = cycle.current.map { max($0.start, fourWeeksBack) } ?? fourWeeksBack
        let start = Point.weekStart(min(anchor, cycle.today))
        return (0..<35).map { Day.add(start, $0) }
    }
}

/// Typical cycle and period lengths, and the last six cycles as bars (the web's "Your cycles").
private struct CycleHistoryCard: View {
    let cycle: CycleData

    var body: some View {
        let periods = cycle.periods
        // The server's cycles: from one period start to the next.
        let recent = Array(zip(periods, periods.dropFirst()).map { (start: $0.start, days: Fmt.daysBetween($0.start, $1.start)) }.suffix(6))
        let longest = max(35, recent.map(\.days).max() ?? 0)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Your cycles").font(.headline).foregroundStyle(Palette.ink)
                Spacer()
                Text("\(CycleText.plural(periods.count, "period")) logged").font(.caption).foregroundStyle(Palette.ink3)
            }
            HStack(alignment: .top, spacing: 24) {
                stat("Typical cycle", cycle.stats?.cycleDays.map { "\($0) days" } ?? "–", note: range)
                stat("Typical period", cycle.stats?.periodDays.map { CycleText.plural($0, "day") } ?? "–", note: nil)
                Spacer(minLength: 0)
            }
            if recent.isEmpty {
                Text("Cycle lengths appear after two period starts.").font(.footnote).foregroundStyle(Palette.ink3)
            } else {
                VStack(spacing: 8) {
                    ForEach(recent, id: \.start) { c in
                        HStack(spacing: 10) {
                            Text(Fmt.day(c.start)).font(.caption).foregroundStyle(Palette.ink3).frame(width: 52, alignment: .leading)
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Palette.gaugeTrack)
                                    Capsule().fill(Palette.gaugeFill).frame(width: geo.size.width * min(1, Double(c.days) / Double(longest)))
                                }
                            }
                            .frame(height: 8)
                            Text("\(c.days) d").font(.caption.weight(.medium)).monospacedDigit().foregroundStyle(Palette.ink2).frame(width: 40, alignment: .trailing)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Cycle starting \(Fmt.day(c.start, "MMMMd")), \(CycleText.plural(c.days, "day"))")
                    }
                }
            }
        }
        .card()
    }

    private var range: String? {
        guard let lo = cycle.stats?.shortest, let hi = cycle.stats?.longest, lo != hi else { return nil }
        return "\(lo)–\(hi) days"
    }

    private func stat(_ title: String, _ value: String, note: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(Palette.ink3)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit().foregroundStyle(Palette.ink)
            if let note { Text(note).font(.caption).foregroundStyle(Palette.ink3) }
        }
        .accessibilityElement(children: .combine)
    }
}
