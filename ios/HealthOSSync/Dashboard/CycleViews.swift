import Charts
import SwiftUI

// Cycle tracking on Today and in Trends (src/pages/Cycle.tsx). The data comes from GET /api/cycle on its own,
// only while cycle tracking is on; nothing here reaches the summary, flags, patterns or the digest. Every estimate
// is worded as one: no day is ever shown as safe, and nothing is fit to use as contraception.

/// Where today sits in the cycle, on Today. Opens the Cycle section of Trends.
struct CycleCard: View {
    let cycle: CycleData
    let phase: CyclePhase
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        let layout = CycleLayout(cycle: cycle, day: phase.day)
        // Days to the next period come with a full estimate; an early one (typical cycles) still says roughly when.
        let nextIn = phase.nextPeriodIn ?? cycle.shownEstimate.map { max(0, Fmt.daysBetween(cycle.today, $0.nextPeriod.date)) }
        let next = nextIn.map { " · " + CycleText.nextPeriod(in: $0) } ?? ""
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
                    PhaseRing(layout: layout).frame(width: 84, height: 84)
                }
            }
            .card(.pink)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens Cycle")
    }
}

/// The Cycle section of Trends: this cycle, the fertile window, the temperature curve, a calendar, past cycles and
/// patterns.
struct CycleTrends: View {
    @Environment(Dashboard.self) private var dashboard
    @State private var cycle: CycleData?
    @State private var loaded = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 14) {
            if let cycle {
                CycleSections(cycle: cycle, units: dashboard.units)
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

/// The Cycle section's cards for one reply, apart from loading it.
struct CycleSections: View {
    let cycle: CycleData
    let units: Units

    var body: some View {
        CycleNowCard(cycle: cycle)
        if !cycle.fertility.isEmpty { CycleFertilityCard(cycle: cycle) }
        if !cycle.history.isEmpty { CycleTemperatureCard(cycle: cycle, units: units) }
        CycleCalendarCard(cycle: cycle)
        CycleHistoryCard(cycle: cycle, units: units)
        if let insights = cycle.insights, !insights.body.isEmpty || !insights.symptoms.isEmpty || !insights.deviations.isEmpty {
            CyclePatternsCard(insights: insights, units: units)
        }
    }
}

// MARK: - Phase colours and words

private enum PhaseStyle {
    static func title(_ name: String) -> String {
        switch name {
        case "menstrual": "Menstrual phase"
        case "follicular": "Follicular phase"
        case "ovulatory": "Around ovulation"
        case "luteal": "Luteal phase"
        default: name.capitalized
        }
    }

    /// A plain line about the phase. Tendencies only: cycles and bodies vary.
    static func blurb(_ name: String) -> String {
        switch name {
        case "menstrual": "Your period. Energy may dip a little; going easier when you need to is fine."
        case "follicular": "After your period. Energy often builds through this part of the cycle."
        case "ovulatory": "Around ovulation, as estimated. The days just before it are the most fertile."
        case "luteal": "After ovulation. Temperature and resting heart rate often run a little higher, and sleep may feel lighter."
        default: ""
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
        guard let f = cycle.shownEstimate?.fertile else { return nil }
        if cycle.today > f.end { return "Fertile window was \(range(f.start, f.end)), estimated" }
        return cycle.today >= f.start ? "Fertile window until \(Fmt.day(f.end)), estimated" : "Fertile window \(range(f.start, f.end)), estimated"
    }

    static func bleeding(_ d: CycleDay?) -> Bool { d?.flow != nil && d?.flow != "none" }

    static func source(_ s: String) -> String {
        switch s {
        case "wrist": "Apple Watch wrist temperature"
        case "skin": "WHOOP skin temperature"
        default: "thermometer"
        }
    }

    static func sourceShort(_ s: String) -> String {
        switch s {
        case "wrist": "Apple Watch"
        case "skin": "WHOOP"
        default: "Thermometer"
        }
    }

    /// How ovulation stands this cycle: confirmed by a temperature rise, from an LH test, being watched for, or estimated.
    static func ovulationLine(_ cycle: CycleData) -> String? {
        let now = cycle.history.last
        if now?.status == "confirmed", let o = now?.ovulation {
            return "Ovulation confirmed around \(Fmt.day(o.date)) by a sustained rise in your \(source(o.tempSource ?? "bbt"))."
        }
        if now?.status == "lh_test", let o = now?.ovulation { return "Ovulation likely around \(Fmt.day(o.date)), the day after your positive LH test." }
        guard let est = cycle.shownEstimate else { return nil }
        if let t = now?.temperature, cycle.today <= Day.add(est.ovulation, 3) { return "Watching your \(source(t.source)) for the rise that follows ovulation." }
        return "Ovulation estimated around \(Fmt.day(est.ovulation))."
    }

    static func level(_ l: String) -> String {
        switch l {
        case "peak": "Peak"
        case "high": "High"
        default: "Possible"
        }
    }

    static func symptom(_ s: String) -> String {
        switch s {
        case "breast_tenderness": "Breast tenderness"
        case "mood_changes": "Mood changes"
        case "back_pain": "Lower back pain"
        case "appetite_changes": "Appetite changes"
        case "sleep_changes": "Sleep changes"
        case "hot_flashes": "Hot flashes"
        default: s.prefix(1).uppercased() + s.dropFirst()
        }
    }
}

private enum FertileColor {
    static func of(_ level: String) -> Color {
        switch level {
        case "peak": Palette.fertilePeak
        case "high": Palette.fertileHigh
        default: Palette.fertileMedium
        }
    }
}

// MARK: - The ring

/// This cycle day by day, for the ring: the period, each fertile day by its chance, after ovulation, and the rest.
private struct CycleLayout {
    enum Kind: Equatable {
        case period, fertile(String), luteal, plain
    }

    let length: Int
    let expected: Int
    let day: Int
    /// Index 0 is cycle day 1.
    let kinds: [Kind]

    init(cycle: CycleData, day: Int) {
        let est = cycle.shownEstimate
        let start = cycle.current?.start
        let cycleDay = { (date: String) in start.map { Fmt.daysBetween($0, date) + 1 } }
        var expected = cycle.stats?.cycleDays ?? 28
        if let next = est?.nextPeriod.date, let d = cycleDay(next) { expected = d - 1 }
        expected = max(expected, 15)
        let length = max(expected, day)
        let periodDays = cycle.periods.last(where: { $0.start == start })?.days ?? cycle.stats?.periodDays ?? 5
        let period = min(max(periodDays, 1), length)
        var kinds = Array(repeating: Kind.plain, count: length)
        for i in 0..<period { kinds[i] = .period }

        var fertileEnd = period
        let mark = { (d: Int, level: String) in
            guard d > period, d <= length else { return }
            kinds[d - 1] = .fertile(level)
            fertileEnd = max(fertileEnd, d)
        }
        if !cycle.fertility.isEmpty {
            for f in cycle.fertility { if let d = cycleDay(f.date) { mark(d, f.level) } }
        } else if let f = est?.fertile, let a = cycleDay(f.start), let b = cycleDay(f.end), a <= b {
            // A server from before graded days: the window as one block.
            for d in a...b { mark(d, "high") }
        }
        if let o = (cycle.history.last?.ovulation?.date ?? est?.ovulation).flatMap(cycleDay) {
            let from = max(o + 1, fertileEnd + 1)
            if from <= length { for d in from...length { kinds[d - 1] = .luteal } }
        }
        self.length = length
        self.expected = expected
        self.day = day
        self.kinds = kinds
    }

    /// Runs of the same kind, as fractions of the ring.
    var segments: [(kind: Kind, from: Double, to: Double)] {
        var out: [(kind: Kind, from: Double, to: Double)] = []
        let l = Double(length)
        for (i, k) in kinds.enumerated() {
            if let last = out.last, last.kind == k {
                out[out.count - 1].to = Double(i + 1) / l
            } else {
                out.append((k, Double(i) / l, Double(i + 1) / l))
            }
        }
        return out
    }

    /// Where today falls on the ring; a long cycle stops at the end rather than wrapping.
    var position: Double { (Double(min(day, length)) - 0.5) / Double(length) }

    static func color(_ kind: Kind) -> Color {
        switch kind {
        case .period: Palette.gaugeFill
        case .fertile(let level): FertileColor.of(level)
        case .luteal: Palette.cycleLuteal
        case .plain: Palette.grid
        }
    }
}

/// The cycle as a ring, with a dot at today.
private struct PhaseRing: View {
    let layout: CycleLayout
    var lineWidth: CGFloat = 8

    var body: some View {
        ZStack {
            Canvas { ctx, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let r = min(size.width, size.height) / 2 - lineWidth / 2 - 3
                let angle = { (f: Double) in Angle.degrees(-90 + 360 * f) }
                for s in layout.segments {
                    let gap = min(1.2, (s.to - s.from) * 360 / 4)
                    var arc = Path()
                    arc.addArc(center: c, radius: r, startAngle: angle(s.from) + .degrees(gap), endAngle: angle(s.to) - .degrees(gap), clockwise: false)
                    ctx.stroke(arc, with: .color(CycleLayout.color(s.kind)), style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
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

// MARK: - This cycle

/// This cycle: phase, day, next period and fertile window, or why there's no estimate yet.
private struct CycleNowCard: View {
    let cycle: CycleData

    var body: some View {
        let est = cycle.shownEstimate
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("This cycle").font(.headline).foregroundStyle(Palette.ink)
                Spacer()
                if let est { Chip(text: Self.confidence(est)) }
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
                    PhaseRing(layout: CycleLayout(cycle: cycle, day: current.day)).frame(width: 84, height: 84)
                }
                if let phase = cycle.phase {
                    Text(PhaseStyle.blurb(phase.name)).font(.footnote).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true)
                }
                if let est {
                    let until = Fmt.daysBetween(cycle.today, est.nextPeriod.date)
                    VStack(alignment: .leading, spacing: 10) {
                        fact("Next period",
                             until > 0 ? "\(Fmt.day(est.nextPeriod.date)), in \(CycleText.plural(until, "day"))" : until == 0 ? "May start around today" : "Expected around \(Fmt.day(est.nextPeriod.date))",
                             "Likely \(CycleText.range(est.nextPeriod.earliest, est.nextPeriod.latest))")
                        fact("Fertile window", CycleText.range(est.fertile.start, est.fertile.end), CycleText.ovulationLine(cycle) ?? "Ovulation around \(Fmt.day(est.ovulation))")
                    }
                } else {
                    Text(cycle.noEstimate == "stale"
                        ? "Your latest logged period started \(Fmt.day(current.start)). Log your most recent one to see estimates again."
                        : "Estimates appear once a period is logged.")
                        .font(.footnote).foregroundStyle(Palette.ink3).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("No period logged yet. Log the first day of your next one, or add your history in Apple Health.")
                    .font(.footnote).foregroundStyle(Palette.ink3).fixedSize(horizontal: false, vertical: true)
            }
            if let est {
                Text("\(Self.basis(est)) Estimates, not medical advice, and not reliable as contraception.")
                    .font(.caption).foregroundStyle(Palette.ink3).fixedSize(horizontal: false, vertical: true)
            }
        }
        .card(.pink)
    }

    private func fact(_ title: String, _ value: String, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(Palette.ink3)
            Text(value).font(.subheadline.weight(.medium)).foregroundStyle(Palette.ink)
            Text(note).font(.caption).foregroundStyle(Palette.ink3).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private static func confidence(_ est: CycleData.Estimate) -> String {
        switch est.confidence {
        case "high": "Confident"
        case "medium": "Fairly sure"
        case "low": "Early estimate"
        default: "Estimate"
        }
    }

    private static func basis(_ est: CycleData.Estimate) -> String {
        if (est.cycles ?? 0) < 2 { return "Based on typical cycles until you've logged a few of your own." }
        switch est.basis {
        case "lh_test": return "Based on this cycle's LH test and your past cycles."
        case "bbt": return "Based on this cycle's temperature rise and your past cycles."
        default: return "Based on your last \(CycleText.plural(min(est.cycles ?? 0, 12), "cycle"))."
        }
    }
}

// MARK: - Fertile window

/// Each day's estimated chance of conception, relative to the most fertile day, two days either side of the window.
private struct CycleFertilityCard: View {
    let cycle: CycleData

    var body: some View {
        let byDate = Dictionary(cycle.fertility.map { ($0.date, $0) }, uniquingKeysWith: { _, b in b })
        let first = cycle.fertility.first!.date, last = cycle.fertility.last!.date
        let days = (0...(Fmt.daysBetween(first, last) + 4)).map { Day.add(first, $0 - 2) }
        let found = cycle.history.last?.ovulation?.date
        let ovulation = found ?? cycle.shownEstimate?.ovulation
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Fertile window").font(.headline).foregroundStyle(Palette.ink)
                Spacer()
                Chip(text: cycle.fertility.first?.basis == "logged" ? "Your signs" : "Estimate")
            }
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(days, id: \.self) { d in
                    let f = byDate[d]
                    VStack(spacing: 4) {
                        GeometryReader { geo in
                            ZStack(alignment: .bottom) {
                                RoundedRectangle(cornerRadius: 6).fill(Palette.surface2)
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(f.map { FertileColor.of($0.level) } ?? Palette.grid)
                                    .frame(height: geo.size.height * max(0.06, f?.chance ?? 0.04))
                            }
                        }
                        .frame(height: 72)
                        .opacity(d < cycle.today ? 0.55 : 1)
                        Text("\(Int(d.suffix(2)) ?? 0)")
                            .font(.caption2.weight(d == cycle.today ? .bold : .regular)).monospacedDigit()
                            .foregroundStyle(d == cycle.today ? Palette.ink : Palette.ink3)
                        Text(d == ovulation ? (found == nil ? "○" : "●") : " ").font(.system(size: 9)).foregroundStyle(Palette.fertilePeak)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Self.label(d, f, ovulation: d == ovulation, today: d == cycle.today))
                }
            }
            HStack(spacing: 12) {
                ForEach(["medium", "high", "peak"], id: \.self) { l in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 3).fill(FertileColor.of(l)).frame(width: 10, height: 10)
                        Text(CycleText.level(l)).font(.caption2).foregroundStyle(Palette.ink3)
                    }
                }
                Text(found == nil ? "○ Ovulation (estimate)" : "● Ovulation").font(.caption2).foregroundStyle(Palette.ink3)
            }
            .accessibilityHidden(true)
            Text("Each day's chance of conception, relative to the most fertile day: the five days before ovulation and the day itself. Positive LH tests, egg-white or watery mucus and a temperature rise all sharpen it. Never treat a day outside it as safe.")
                .font(.caption).foregroundStyle(Palette.ink3).fixedSize(horizontal: false, vertical: true)
        }
        .card()
    }

    private static func label(_ d: String, _ f: CycleData.Fertility?, ovulation: Bool, today: Bool) -> String {
        var parts = [Fmt.day(d, "EEEEMMMMd"), f.map { "\(CycleText.level($0.level).lowercased()) chance" } ?? "outside the estimated window"]
        if ovulation { parts.append("ovulation") }
        if today { parts.append("today") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Temperature

/// One cycle's temperatures by cycle day, against the person's own level on the device that covered it best: the
/// cover line, the rise after ovulation, the period and positive LH tests. Earlier cycles a swipe of the arrows away.
private struct CycleTemperatureCard: View {
    let cycle: CycleData
    let units: Units
    @State private var index: Int?

    private struct Band: Identifiable {
        let day: Int
        let level: String
        var id: Int { day }
    }

    private struct Reading: Identifiable {
        let day: Int
        let value: Double
        let excluded: Bool
        let date: String
        var id: String { date }
    }

    var body: some View {
        let history = cycle.history
        let i = min(index ?? history.count - 1, history.count - 1)
        let c = history[i]
        let end = c.end ?? cycle.shownEstimate.map { Day.add($0.nextPeriod.date, -1) } ?? cycle.today
        let source = c.temperature?.source
        let cd = { (date: String) in Fmt.daysBetween(c.start, date) + 1 }
        let readings = source.map { s in
            cycle.temperatures.filter { $0.source == s && $0.date >= c.start && $0.date <= (c.end ?? cycle.today) }
                .map { Reading(day: cd($0.date), value: units.tempDelta($0.deviation).value, excluded: $0.excluded != nil, date: $0.date) }
        } ?? []
        let length = max(cd(end), readings.last?.day ?? 0, 14)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Temperature").font(.headline).foregroundStyle(Palette.ink)
                Spacer()
                Button { index = i - 1 } label: { Image(systemName: "chevron.left") }
                    .disabled(i <= 0).accessibilityLabel("Earlier cycle")
                Text(c.end.map { CycleText.range(c.start, $0) } ?? "Since \(Fmt.day(c.start))").font(.caption).foregroundStyle(Palette.ink2).monospacedDigit()
                Button { index = i + 1 } label: { Image(systemName: "chevron.right") }
                    .disabled(i >= history.count - 1).accessibilityLabel("Later cycle")
            }
            .buttonStyle(.borderless)
            Text(status(c, source: source)).font(.caption).foregroundStyle(Palette.ink3).fixedSize(horizontal: false, vertical: true)
            if readings.isEmpty {
                Text("No temperatures in this cycle. Wearing an Apple Watch (Series 8 or later) or WHOOP to sleep records one every night; you can also log a thermometer reading on the web.")
                    .font(.footnote).foregroundStyle(Palette.ink3).fixedSize(horizontal: false, vertical: true)
            } else {
                chart(c, readings: readings, length: length, cd: cd)
                legend
            }
        }
        .card()
    }

    private func status(_ c: CycleData.History, source: String?) -> String {
        let lead = source.map { "\(CycleText.sourceShort($0)), against your own usual level. " } ?? ""
        switch c.status {
        case "confirmed":
            let rise = c.temperature?.rise.map { ", about \(units.tempDelta($0).signed(2)) after it" } ?? ""
            return lead + "Rise found: ovulation around \(c.ovulation.map { Fmt.day($0.date) } ?? "")\(rise)."
        case "lh_test": return lead + "No temperature rise confirmed; ovulation from your LH test around \(c.ovulation.map { Fmt.day($0.date) } ?? "")."
        case "waiting": return lead + "No rise yet this cycle."
        case "not_found": return lead + "No sustained rise in this cycle's temperatures."
        default: return lead + "Too few temperatures in this cycle to look for a rise."
        }
    }

    private func chart(_ c: CycleData.History, readings: [Reading], length: Int, cd: (String) -> Int) -> some View {
        let values = readings.map(\.value) + [c.temperature?.coverline.map { units.tempDelta($0).value }].compactMap { $0 }
        let span = max(0.2, (values.max() ?? 0.1) - (values.min() ?? -0.1))
        let lo = (values.min() ?? -0.1) - span * 0.25
        let hi = (values.max() ?? 0.1) + span * 0.15
        let ov = c.ovulation.map { cd($0.date) }
        let bleeding = cycle.days.filter { CycleText.bleeding($0) && $0.date >= c.start }.map { cd($0.date) }.filter { $0 <= length }
        let lh = cycle.days.filter { $0.ovulationTest == "lh_surge" && $0.date >= c.start }.map { cd($0.date) }.filter { $0 <= length }
        let fertile = c.end == nil ? cycle.fertility.map { Band(day: cd($0.date), level: $0.level) }.filter { $0.day <= length } : []
        let usable = readings.filter { !$0.excluded }
        return Chart {
            ForEach(fertile) { f in
                RectangleMark(xStart: .value("Day", Double(f.day) - 0.5), xEnd: .value("Day", Double(f.day) + 0.5), yStart: .value("Low", lo), yEnd: .value("High", hi))
                    .foregroundStyle(FertileColor.of(f.level).opacity(0.45))
            }
            if let ov, ov < length {
                RectangleMark(xStart: .value("Day", Double(ov) + 0.5), xEnd: .value("Day", Double(length) + 0.5), yStart: .value("Low", lo), yEnd: .value("High", hi))
                    .foregroundStyle(Palette.cycleLuteal.opacity(0.55))
            }
            if let cover = c.temperature?.coverline {
                RuleMark(y: .value("Cover line", units.tempDelta(cover).value))
                    .foregroundStyle(Palette.ink3)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            if let ov {
                RuleMark(x: .value("Ovulation", Double(ov))).foregroundStyle(Palette.fertilePeak).lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            ForEach(usable) { r in
                LineMark(x: .value("Cycle day", Double(r.day)), y: .value("Temperature", r.value))
                    .foregroundStyle(Tone.pink.ink)
                    .interpolationMethod(.linear)
            }
            ForEach(readings) { r in
                PointMark(x: .value("Cycle day", Double(r.day)), y: .value("Temperature", r.value))
                    .symbol {
                        if r.excluded {
                            Circle().strokeBorder(Palette.ink3, lineWidth: 1.5).frame(width: 7, height: 7)
                        } else {
                            Circle().fill(Tone.pink.ink).frame(width: 6, height: 6)
                        }
                    }
                    .accessibilityLabel("\(Fmt.day(r.date)), day \(r.day)")
                    .accessibilityValue("\(Measure(value: r.value, unit: units.tempDelta(0).unit).signed(2))\(r.excluded ? ", left out" : "")")
            }
            ForEach(bleeding, id: \.self) { d in
                RectangleMark(xStart: .value("Day", Double(d) - 0.4), xEnd: .value("Day", Double(d) + 0.4), yStart: .value("Low", lo), yEnd: .value("High", lo + (hi - lo) * 0.04))
                    .foregroundStyle(Palette.gaugeFill)
            }
            ForEach(lh, id: \.self) { d in
                PointMark(x: .value("Positive LH test", Double(d)), y: .value("Top", hi - (hi - lo) * 0.05))
                    .symbol(.triangle).symbolSize(30)
                    .foregroundStyle(Palette.fertilePeak)
            }
        }
        .chartXScale(domain: 0.5...(Double(length) + 0.5))
        .chartYScale(domain: lo...hi)
        .chartXAxis {
            AxisMarks(values: Array(stride(from: 1, through: length, by: length > 30 ? 7 : 5)).map(Double.init)) { v in
                AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d))").foregroundStyle(Palette.ink3) } }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { v in
                AxisGridLine().foregroundStyle(Palette.grid)
                AxisValueLabel { if let d = v.as(Double.self) { Text(Fmt.signed(d, abs(d) < 0.1 && d != 0 ? 2 : 1)).foregroundStyle(Palette.ink3) } }
            }
        }
        .frame(height: 190)
        .accessibilityLabel("Temperature by cycle day, \(units.tempDelta(0).unit) from your usual\(ov.map { ", ovulation on day \($0)" } ?? "")")
    }

    private var legend: some View {
        HStack(spacing: 12) {
            HStack(spacing: 5) { Capsule().fill(Palette.gaugeFill).frame(width: 12, height: 5); Text("Period") }
            HStack(spacing: 5) { Rectangle().fill(Palette.cycleLuteal).frame(width: 10, height: 10); Text("After ovulation") }
            Text("○ Left out")
            Text("▲ LH test")
        }
        .font(.caption2).foregroundStyle(Palette.ink3)
        .accessibilityHidden(true)
    }
}

// MARK: - Calendar

/// Five weeks around today, Monday first: logged period days, the expected period, fertile days by chance and ovulation.
private struct CycleCalendarCard: View {
    let cycle: CycleData

    private static let weekdays = ["M", "T", "W", "T", "F", "S", "S"]

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
            // A plain Grid, not a lazy one: inside the Trends scroll view a lazy grid sizes its rows as they scroll in,
            // and everything below it jumps.
            Grid(horizontalSpacing: 4, verticalSpacing: 6) {
                GridRow {
                    ForEach(Array(Self.weekdays.enumerated()), id: \.offset) { _, w in
                        Text(w).font(.caption2.weight(.medium)).foregroundStyle(Palette.ink3).frame(maxWidth: .infinity).accessibilityHidden(true)
                    }
                }
                ForEach(Array(stride(from: 0, to: dates.count, by: 7)), id: \.self) { row in
                    GridRow {
                        ForEach(dates[row..<min(row + 7, dates.count)], id: \.self) { date in
                            cell(date, day: byDate[date])
                        }
                    }
                }
            }
            legend
        }
        .card()
    }

    private struct Marks {
        var period = false
        var predicted = false
        /// "medium" | "high" | "peak", nil outside the estimated window.
        var fertile: String?
        var ovulation = false
        var ovulationEstimated = false
        var entries = false
        var today = false
        var future = false
    }

    private func marks(_ date: String, day: CycleDay?) -> Marks {
        var m = Marks()
        m.period = CycleText.bleeding(day)
        m.today = date == cycle.today
        m.future = date > cycle.today
        if let d = day {
            let logged: [Bool] = [d.spotting == true, d.ovulationTest != nil, d.mucus != nil, d.bbt != nil, d.sexualActivity != nil, !(d.symptoms ?? []).isEmpty]
            m.entries = logged.contains(true)
        }
        if cycle.history.contains(where: { $0.ovulation?.date == date }) { m.ovulation = true }
        if let est = cycle.shownEstimate {
            let predictedEnd = Day.add(est.nextPeriod.date, (cycle.stats?.periodDays ?? 5) - 1)
            m.predicted = !m.period && date >= cycle.today && date >= est.nextPeriod.date && date <= predictedEnd
            if cycle.fertility.isEmpty {
                if date >= est.fertile.start && date <= est.fertile.end { m.fertile = "high" }
            } else {
                m.fertile = cycle.fertility.first { $0.date == date }?.level
            }
            if !m.ovulation, cycle.history.last?.ovulation == nil, date == est.ovulation { m.ovulationEstimated = true }
        }
        return m
    }

    private func cell(_ date: String, day: CycleDay?) -> some View {
        let m = marks(date, day: day)
        let onPeak = m.fertile == "peak" && !m.period && !m.predicted
        let number = Text("\(Int(date.suffix(2)) ?? 0)")
            .font(.footnote.weight(m.period || m.today ? .semibold : .regular))
            .monospacedDigit()
            .underline(m.today)
            .foregroundStyle(m.period ? Color.white : m.predicted ? Palette.gaugeFill : onPeak ? Palette.surface : m.future ? Palette.ink3 : Palette.ink)
        let states = [
            m.today ? "today" : nil,
            m.period ? "period" : nil,
            m.predicted ? "expected period" : nil,
            m.fertile.map { "\(CycleText.level($0).lowercased()) fertility, estimated" },
            m.ovulation ? "ovulation" : m.ovulationEstimated ? "estimated ovulation" : nil,
            m.entries ? "entries logged" : nil,
        ].compactMap { $0 }
        return number
            .frame(maxWidth: 40)
            .frame(height: 36)
            .background {
                if m.period {
                    Circle().fill(Palette.gaugeFill)
                } else if let level = m.fertile, !m.predicted {
                    Circle().fill(FertileColor.of(level))
                }
            }
            .overlay {
                if m.predicted { Circle().strokeBorder(Palette.gaugeFill, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2])) }
                if m.ovulation { Circle().strokeBorder(Palette.fertilePeak, lineWidth: 1.5).padding(-2) }
                if m.ovulationEstimated { Circle().strokeBorder(Palette.fertilePeak, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2])).padding(-2) }
            }
            .overlay(alignment: .bottom) {
                if m.entries { Circle().fill(day?.symptoms?.isEmpty == false ? Tone.peach.ink : Palette.ink2).frame(width: 4, height: 4).offset(y: -3) }
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(([Fmt.day(date, "EEEEMMMMd")] + states).joined(separator: ", "))
    }

    private var legend: some View {
        let keys = [
            LegendItem(label: "Period", shape: AnyView(Circle().fill(Palette.gaugeFill))),
            LegendItem(label: "Expected period", shape: AnyView(Circle().strokeBorder(Palette.gaugeFill, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2])))),
            LegendItem(label: "Fertile (estimate)", shape: AnyView(Circle().fill(Palette.fertileHigh))),
            LegendItem(label: "Ovulation", shape: AnyView(Circle().strokeBorder(Palette.fertilePeak, lineWidth: 1.5))),
        ]
        // Without an estimate only logged periods can show.
        let shown = cycle.shownEstimate == nil ? Array(keys.prefix(1)) : keys
        return Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
            ForEach(Array(stride(from: 0, to: shown.count, by: 2)), id: \.self) { i in
                GridRow {
                    ForEach(shown[i..<min(i + 2, shown.count)]) { key in
                        HStack(spacing: 6) {
                            key.shape.frame(width: 12, height: 12)
                            Text(key.label).font(.caption2).foregroundStyle(Palette.ink3)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
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

// MARK: - Past cycles

/// Typical lengths, and the last six cycles as bars: the period, before ovulation and after it (the web's "Your cycles").
private struct CycleHistoryCard: View {
    let cycle: CycleData
    let units: Units

    private struct Row: Identifiable {
        let start: String
        let days: Int
        let current: Bool
        let period: Int
        /// Before and after ovulation, once it was found.
        let split: (before: Int, after: Int)?
        let label: String
        var id: String { start }
    }

    var body: some View {
        let rows = Self.rows(cycle, units: units)
        let longest = max(35, rows.map(\.days).max() ?? 0)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Your cycles").font(.headline).foregroundStyle(Palette.ink)
                Spacer()
                Text("\(CycleText.plural(cycle.periods.count, "period")) logged").font(.caption).foregroundStyle(Palette.ink3)
            }
            let stats = statItems
            Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 12) {
                ForEach(Array(stride(from: 0, to: stats.count, by: 2)), id: \.self) { i in
                    GridRow(alignment: .top) {
                        ForEach(stats[i..<min(i + 2, stats.count)], id: \.title) { item in
                            stat(item.title, item.value, note: item.note).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            if rows.isEmpty {
                Text("Cycle lengths appear after two period starts.").font(.footnote).foregroundStyle(Palette.ink3)
            } else {
                VStack(spacing: 8) {
                    ForEach(rows) { r in
                        HStack(spacing: 10) {
                            Text(Fmt.day(r.start)).font(.caption).foregroundStyle(Palette.ink3).frame(width: 52, alignment: .leading)
                            GeometryReader { geo in
                                let w = { (n: Int) in geo.size.width * min(1, Double(n) / Double(longest)) }
                                HStack(spacing: 2) {
                                    Capsule().fill(Palette.gaugeFill).frame(width: w(r.period))
                                    if let split = r.split {
                                        Capsule().fill(Palette.fertileMedium).frame(width: w(split.before))
                                        Capsule().fill(Palette.cycleLuteal).frame(width: w(split.after)).opacity(r.current ? 0.55 : 1)
                                    } else {
                                        Capsule().fill(Palette.gaugeTrack.opacity(0.5)).frame(width: w(max(0, r.days - r.period)))
                                    }
                                }
                            }
                            .frame(height: 8)
                            Text(r.current ? "\(r.days) d…" : "\(r.days) d").font(.caption.weight(.medium)).monospacedDigit().foregroundStyle(Palette.ink2).frame(width: 44, alignment: .trailing)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(r.label)
                    }
                }
                if rows.contains(where: { $0.split != nil }) {
                    HStack(spacing: 12) {
                        HStack(spacing: 5) { Capsule().fill(Palette.gaugeFill).frame(width: 12, height: 6); Text("Period") }
                        HStack(spacing: 5) { Capsule().fill(Palette.fertileMedium).frame(width: 12, height: 6); Text("Before ovulation") }
                        HStack(spacing: 5) { Capsule().fill(Palette.cycleLuteal).frame(width: 12, height: 6); Text("After") }
                    }
                    .font(.caption2).foregroundStyle(Palette.ink3)
                    .accessibilityHidden(true)
                }
            }
        }
        .card()
    }

    /// From the server's per-cycle history, else (an older server) from consecutive period starts.
    private static func rows(_ cycle: CycleData, units: Units) -> [Row] {
        if !cycle.history.isEmpty {
            return cycle.history.suffix(6).map { h -> Row in
                let period = min(h.periodDays ?? 0, h.days)
                let split = h.follicularDays.map { f in (before: max(0, f - period), after: max(0, h.days - f)) }
                let label = [
                    "Cycle starting \(Fmt.day(h.start, "MMMMd")), \(CycleText.plural(h.days, "day"))\(h.end == nil ? " so far" : "")",
                    h.periodDays.map { "period \(CycleText.plural($0, "day"))" },
                    h.follicularDays.map { "ovulation on day \($0)\(h.status == "confirmed" ? " (temperature)" : " (LH test)")" },
                    h.temperature?.rise.map { "rise \(units.tempDelta($0).signed(2))" },
                ].compactMap { $0 }.joined(separator: ", ")
                return Row(start: h.start, days: h.days, current: h.end == nil, period: period, split: split, label: label)
            }
        }
        let periods = cycle.periods
        return zip(periods, periods.dropFirst()).suffix(6).map { a, b -> Row in
            let days = Fmt.daysBetween(a.start, b.start)
            return Row(start: a.start, days: days, current: false, period: min(a.days, days), split: nil, label: "Cycle starting \(Fmt.day(a.start, "MMMMd")), \(CycleText.plural(days, "day"))")
        }
    }

    private var range: String? {
        guard let lo = cycle.stats?.shortest, let hi = cycle.stats?.longest, lo != hi else { return nil }
        return "\(lo)–\(hi) days"
    }

    private struct StatItem {
        let title: String
        let value: String
        let note: String?
    }

    private var statItems: [StatItem] {
        var items = [
            StatItem(title: "Typical cycle", value: cycle.stats?.cycleDays.map { "\($0) days" } ?? "–", note: range),
            StatItem(title: "Period", value: cycle.stats?.periodDays.map { CycleText.plural($0, "day") } ?? "–", note: nil),
        ]
        if let luteal = cycle.stats?.lutealDays { items.append(StatItem(title: "After ovulation", value: CycleText.plural(luteal, "day"), note: nil)) }
        if let regular = cycle.stats?.regular {
            items.append(StatItem(title: "Regularity", value: regular ? "Regular" : "Variable", note: cycle.stats?.variation.map { "Varies by \(CycleText.plural($0, "day"))" }))
        }
        return items
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

// MARK: - Patterns

/// How the person's body changes after ovulation, when their symptoms come, and recent cycles outside the usual ranges.
private struct CyclePatternsCard: View {
    let insights: CycleData.Insights
    let units: Units

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Patterns").font(.headline).foregroundStyle(Palette.ink)
                Spacer()
                Text("From your own cycles").font(.caption).foregroundStyle(Palette.ink3)
            }
            ForEach(insights.body, id: \.metric) { b in
                HStack(alignment: .firstTextBaseline) {
                    Text(Self.metric(b.metric)).font(.subheadline).foregroundStyle(Palette.ink2)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(value(b, b.follicular)) → \(value(b, b.luteal))").font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(Palette.ink)
                        Text("before → after ovulation, \(CycleText.plural(b.cycles, "cycle"))").font(.caption2).foregroundStyle(Palette.ink3)
                    }
                }
                .accessibilityElement(children: .combine)
                Divider()
            }
            if !insights.symptoms.isEmpty {
                let symptoms = Array(insights.symptoms.prefix(6))
                Grid(alignment: .topLeading, horizontalSpacing: 8, verticalSpacing: 8) {
                    ForEach(Array(stride(from: 0, to: symptoms.count, by: 2)), id: \.self) { i in
                        GridRow {
                            ForEach(symptoms[i..<min(i + 2, symptoms.count)], id: \.symptom) { s in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(CycleText.symptom(s.symptom)).font(.footnote.weight(.semibold)).foregroundStyle(Tone.peach.ink)
                                    Text("\(s.phase.map { "mostly \(Self.phase($0))" } ?? "at different points") · \(CycleText.plural(s.cycles, "cycle"))")
                                        .font(.caption2).foregroundStyle(Palette.ink3).fixedSize(horizontal: false, vertical: true)
                                }
                                .padding(.horizontal, 10).padding(.vertical, 8)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                .background(Tone.peach.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }
                }
            }
            if !insights.deviations.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(insights.deviations, id: \.kind) { d in
                        Text(Self.deviation(d)).font(.footnote).foregroundStyle(Palette.ink).fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Outside the usual ranges (FIGO). Often nothing, but worth mentioning to a clinician if it keeps happening.")
                        .font(.caption).foregroundStyle(Palette.ink3).fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Tone.yellow.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .card()
    }

    private func value(_ b: CycleData.Insights.Body, _ v: Double) -> String {
        switch b.metric {
        case "temperature": units.tempDelta(v).signed(2)
        case "resting_hr": "\(Fmt.number(v, 1)) \(b.unit)"
        default: "\(Fmt.number(v, 0)) \(b.unit)"
        }
    }

    private static func metric(_ m: String) -> String {
        switch m {
        case "resting_hr": "Resting heart rate"
        case "hrv": "HRV"
        default: "Temperature"
        }
    }

    private static func phase(_ p: String) -> String {
        switch p {
        case "menstrual": "during your period"
        case "follicular": "before ovulation"
        case "ovulatory": "around ovulation"
        default: "after ovulation"
        }
    }

    private static func deviation(_ d: CycleData.Insights.Deviation) -> String {
        switch d.kind {
        case "frequent": "\(d.count) of your last \(d.of) cycles were shorter than 24 days."
        case "infrequent": "\(d.count) of your last \(d.of) cycles were longer than 38 days."
        case "irregular": "Your last \(d.of) cycles varied by \(d.spread ?? 0) days, more than the 7 to 9 days usually seen."
        case "prolonged": "\(d.count) of your last \(d.of) periods lasted more than 8 days."
        default: "You logged spotting between periods in \(d.count) of your last \(d.of) cycles."
        }
    }
}
