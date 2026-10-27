import SwiftUI

// The Sleep page's small charts, after the web's (src/charts/Neka.tsx and Mini.tsx): the score bar, the night stage by
// stage (hypnogram), the night as bars of depth, the stage totals as one bar, the night as one line coloured by stage,
// and the week-on-week chip. Each draws only what it's given, in the shared colours, so dark mode needs nothing of its
// own. VoiceOver reads each as one image with its words; the numbers are in the cards' text too.

/// A stage's colour on the night's charts (Neka.tsx STAGE_COLOR): awake is the hypnogram's pink here, not the Stages
/// tab's pale blue.
enum SleepStageColor {
    static func of(_ stage: String) -> Color {
        switch stage {
        case "awake": Palette.hypAwake
        case "in_bed": Palette.hypInbed
        case "rem": Palette.stageRem
        case "deep": Palette.stageDeep
        default: Palette.stageLight
        }
    }
}

// MARK: - Score bar

/// A 0–100 score on a gradient track, with the scale under it, the nearest tick in bold (Neka.tsx ScoreBar). The
/// gradient spans the whole track, so a colour always means the same score.
struct SleepScoreBar: View {
    let value: Double
    /// What VoiceOver reads ("Sleep performance 89%, good").
    let label: String

    static let ticks: [Double] = [0, 20, 40, 60, 80, 100]

    /// The tick nearest the value, drawn bold.
    static func nearest(_ value: Double) -> Double {
        let v = min(100, max(0, value))
        return ticks.reduce(0) { abs($1 - v) < abs($0 - v) ? $1 : $0 }
    }

    var body: some View {
        let pct = min(100, max(0, value)) / 100
        let near = Self.nearest(value)
        VStack(spacing: 10) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.surface2).overlay(Capsule().strokeBorder(Palette.border))
                    if pct > 0 {
                        LinearGradient(stops: [.init(color: Palette.scoreFrom, location: 0), .init(color: Palette.scoreMid, location: 0.62),
                                               .init(color: Palette.scoreTo, location: 1)], startPoint: .leading, endPoint: .trailing)
                            .frame(width: w)
                            .mask(alignment: .leading) { Capsule().frame(width: w * pct) }
                    }
                    Circle().fill(Palette.scoreTo)
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(Palette.surface).padding(-3))
                        .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                        .offset(x: w * pct - 8)
                }
            }
            .frame(height: 8)
            GeometryReader { geo in
                ForEach(Self.ticks, id: \.self) { t in
                    let tick = Text(Fmt.number(t))
                        .font(t == near ? Font.app(fixedSize: 11, weight: .semibold) : Font.axis)
                        .foregroundStyle(t == near ? Palette.ink : Palette.ink3)
                        .fixedSize()
                    // The first and last ticks sit inside the track's ends, the others centred on their place.
                    if t == 0 {
                        tick.frame(maxWidth: .infinity, alignment: .leading)
                    } else if t == 100 {
                        tick.frame(maxWidth: .infinity, alignment: .trailing)
                    } else {
                        tick.position(x: geo.size.width * t / 100, y: 7)
                    }
                }
            }
            .frame(height: 14)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isImage)
    }
}

/// Good, Fair or Low as a small pill (.score-pill): blue, yellow or peach.
struct SleepScorePill: View {
    let band: String

    var body: some View {
        let tone: Tone = band == "Good" ? .blue : band == "Fair" ? .yellow : .peach
        Text(band)
            .font(.app(size: 12, weight: .medium, relativeTo: .caption))
            .foregroundStyle(tone.ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 2)
            .background(tone.background, in: Capsule())
    }
}

/// This week against last week as a small chip (Neka.tsx Change): green only where the direction is plainly the better
/// one, else quiet. Nothing under 1% either way.
struct SleepChangeChip: View {
    let pct: Double
    /// Which way is better: "up" (more sleep) or "down" (a lower resting heart rate).
    let better: String
    /// The web's title, read by VoiceOver.
    var title = "This week against last week"

    /// Shown only for a change of 1% or more, rounded.
    static func shows(_ pct: Double?) -> Bool { pct.map { $0.isFinite && abs($0).rounded() >= 1 } ?? false }

    var body: some View {
        let up = pct > 0
        let good = better == (up ? "up" : "down")
        HStack(spacing: 4) {
            Image(systemName: up ? "arrow.up.right" : "arrow.down.right")
                .font(.system(size: 10, weight: .semibold))
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            Text("\(Fmt.number(abs(pct).rounded()))%")
        }
        .font(.app(size: 12, weight: .medium, relativeTo: .caption))
        .foregroundStyle(good ? Palette.ink : Palette.ink2)
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(good ? Palette.chipGreen : Palette.chip, in: Capsule())
        .overlay { if !good { Capsule().strokeBorder(Palette.border) } }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(up ? "up" : "down") \(Fmt.number(abs(pct).rounded())) percent")
    }
}

// MARK: - The night

/// The night stage by stage (Neka.tsx Hypnogram): a row per stage, a block for each stretch, a thin line where it
/// changes, and the hours under it. Stages without a row of their own sit on the nearest one (in bed with awake,
/// asleep with light).
struct SleepHypnogram: View {
    let segments: [SleepNightDetail.Segment]
    var height: CGFloat = 170

    static let rows: [(label: String, stages: [String])] = [
        ("Awake", ["awake", "in_bed"]), ("REM", ["rem"]), ("Light", ["light", "asleep"]), ("Deep", ["deep"]),
    ]

    static func row(_ stage: String) -> Int { rows.firstIndex { $0.stages.contains(stage) } ?? 2 }

    var body: some View {
        Canvas { ctx, size in
            guard let first = segments.first, let last = segments.last,
                  let from = SleepClock.time(first.start), let to = SleepClock.time(last.end) else { return }
            let left: CGFloat = 48, bottom: CGFloat = 22
            let rowH = (size.height - bottom) / CGFloat(Self.rows.count)
            let x = { (t: TimeInterval) -> CGFloat in left + CGFloat((t - from) / max(1, to - from)) * (size.width - left - 4) }
            for (i, r) in Self.rows.enumerated() {
                var grid = Path()
                grid.move(to: CGPoint(x: left, y: CGFloat(i + 1) * rowH))
                grid.addLine(to: CGPoint(x: size.width, y: CGFloat(i + 1) * rowH))
                ctx.stroke(grid, with: .color(Palette.grid), lineWidth: 1)
                ctx.draw(Text(r.label).font(.axis).foregroundStyle(Palette.ink3), at: CGPoint(x: 0, y: CGFloat(i) * rowH + rowH / 2), anchor: .leading)
            }
            let pad = rowH * 0.18
            for (i, s) in segments.enumerated() {
                guard let a = SleepClock.time(s.start), let b = SleepClock.time(s.end) else { continue }
                let row = Self.row(s.stage)
                let x0 = x(a)
                if i > 0 {
                    let prev = Self.row(segments[i - 1].stage)
                    if prev != row {
                        var step = Path()
                        step.move(to: CGPoint(x: x0, y: CGFloat(min(prev, row)) * rowH + pad))
                        step.addLine(to: CGPoint(x: x0, y: CGFloat(max(prev, row) + 1) * rowH - pad))
                        ctx.stroke(step, with: .color(Palette.axis), lineWidth: 1)
                    }
                }
                let block = CGRect(x: x0, y: CGFloat(row) * rowH + pad, width: max(1.5, x(b) - x0), height: rowH - pad * 2)
                ctx.fill(Path(roundedRect: block, cornerRadius: 3), with: .color(SleepStageColor.of(s.stage)))
            }
            let every = size.width < 420 ? 3 : 2
            for tick in SleepClock.hourTicks(from: from, to: to, every: every, offsetIso: first.start,
                                             label: { SleepClock.at($0, segments: segments, fallback: first.start) }) {
                ctx.draw(Text(tick.label).font(.axis).foregroundStyle(Palette.ink3), at: CGPoint(x: x(tick.at), y: size.height - 4), anchor: .bottom)
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        .accessibilityAddTraits(.isImage)
    }

    private var spoken: String {
        guard let first = segments.first, let last = segments.last else { return "Sleep stages" }
        return "Sleep stages from \(SleepClock.wall(first.start)) to \(SleepClock.wall(last.end))"
    }
}

/// How deep each part of the night was, as bars from bedtime to waking (Neka.tsx NightBars): deeper sleep, a taller and
/// stronger bar; the bedtime and waking times under them.
struct SleepNightBars: View {
    let segments: [SleepNightDetail.Segment]
    var height: CGFloat = 48

    static let depth: [String: Double] = ["deep": 1, "light": 0.55, "asleep": 0.5, "rem": 0.4, "awake": 0.08, "in_bed": 0.04]

    /// The night in up to 32 bins of about 15 minutes, each its share of depth (0…1).
    static func bins(_ segments: [SleepNightDetail.Segment]) -> [Double] {
        guard let first = segments.first, let last = segments.last,
              let from = SleepClock.time(first.start), let to = SleepClock.time(last.end), to > from else { return [] }
        let n = max(1, min(32, Int(((to - from) / (15 * 60)).rounded())))
        let bin = (to - from) / Double(n)
        let spans = segments.compactMap { s -> (TimeInterval, TimeInterval, Double)? in
            guard let a = SleepClock.time(s.start), let b = SleepClock.time(s.end) else { return nil }
            return (a, b, depth[s.stage] ?? 0)
        }
        return (0..<n).map { i in
            let a = from + Double(i) * bin, b = a + bin
            return spans.reduce(0) { sum, s in sum + max(0, min(b, s.1) - max(a, s.0)) * s.2 } / bin
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            Canvas { ctx, size in
                let depth = Self.bins(segments)
                guard !depth.isEmpty else { return }
                let slot = size.width / CGFloat(depth.count)
                let w = max(2, min(6, slot - 3))
                for (i, d) in depth.enumerated() {
                    let h = max(2, CGFloat(d) * size.height)
                    let r = min(3, w / 2)
                    let bar = Path(roundedRect: CGRect(x: CGFloat(i) * slot + (slot - w) / 2, y: size.height - h, width: w, height: h),
                                   cornerRadii: RectangleCornerRadii(topLeading: r, topTrailing: r))
                    ctx.fill(bar, with: .color(Palette.stageRem.opacity(0.35 + d * 0.65)))
                }
            }
            .frame(height: height)
            HStack {
                Text(segments.first.map { SleepClock.wall($0.start) } ?? "")
                Spacer(minLength: 8)
                Text(segments.last.map { SleepClock.wall($0.end) } ?? "")
            }
            .font(.axis)
            .foregroundStyle(Palette.ink3)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(segments.first.map { f in "Sleep depth through the night, \(SleepClock.wall(f.start)) to \(SleepClock.wall(segments.last?.end ?? f.end))" } ?? "")
        .accessibilityAddTraits(.isImage)
    }
}

/// A bar a night (Mini.tsx MiniBars, blue): the last 14 nights, the latest in the accent.
struct SleepMiniBars: View {
    let points: [Point]
    var height: CGFloat = 44

    var body: some View {
        Canvas { ctx, size in
            let n = points.count
            guard n > 0 else { return }
            let top = max(points.map(\.value).max() ?? 1, 1)
            let slot = size.width / CGFloat(n)
            let w = max(3, min(5, slot - 2))
            for (i, p) in points.enumerated() {
                let y = size.height - CGFloat(p.value / top) * (size.height - 4)
                let h = size.height - y
                guard h > 0 else { continue }
                let r = min(4, w / 2, h)
                let bar = Path(roundedRect: CGRect(x: CGFloat(i) * slot + slot / 2 - w / 2, y: y, width: w, height: h),
                               cornerRadii: RectangleCornerRadii(topLeading: r, topTrailing: r))
                ctx.fill(bar, with: .color(i == n - 1 ? Palette.barAccent : Palette.bar))
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Time asleep, last 14 nights")
        .accessibilityAddTraits(.isImage)
    }
}

/// A night's stage totals as one bar (Neka.tsx StageBar), for nights without the stages through them (WHOOP, a Fitbit
/// export, older syncs).
struct SleepStageBar: View {
    let stages: SleepNightDetail.Stages

    static let order: [(key: String, label: String)] = [("deep", "Deep"), ("light", "Light"), ("rem", "REM"), ("awake", "Awake")]

    var body: some View {
        let total = stages.total == 0 ? 1 : stages.total
        GeometryReader { geo in
            let parts = Self.order.filter { stages.hours($0.key) > 0 }
            let gaps = CGFloat(max(0, parts.count - 1)) * 2
            HStack(spacing: 2) {
                ForEach(parts, id: \.key) { p in
                    SleepStageColor.of(p.key).frame(width: max(2, (geo.size.width - gaps) * stages.hours(p.key) / total))
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 14)
        .padding(.top, 12)
        .padding(.bottom, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.order.map { "\($0.label) \(Int((stages.hours($0.key) / total * 100).rounded()))%" }.joined(separator: ", "))
        .accessibilityAddTraits(.isImage)
    }
}

/// The night as one bar from bed to waking, coloured by stage (one colour without stages), with a marker on the deepest
/// sleep reading its time and stage, and the hours under it (Neka.tsx StageTimeline).
struct SleepStageTimeline: View {
    let segments: [SleepNightDetail.Segment]
    let start: String
    let end: String
    var marker: String?
    /// The narrow layout (≤560 on the web): every other hour's label is left out.
    var narrow: Bool

    var body: some View {
        let from = SleepClock.time(start) ?? 0
        let to = SleepClock.time(end) ?? from + 1
        let span = max(1, to - from)
        let at = marker.flatMap(SleepClock.time)
        let stageAt = at.flatMap { t in segments.first { (SleepClock.time($0.start) ?? .infinity) <= t && t < (SleepClock.time($0.end) ?? 0) }?.stage }
        let ticks = SleepClock.hourTicks(from: from, to: to, every: to - from > 11 * 3600 ? 2 : 1, offsetIso: start,
                                         label: { SleepClock.at($0, segments: segments, fallback: start) })
        let shownTicks = narrow ? ticks.enumerated().filter { $0.offset % 2 == 0 }.map(\.element) : ticks
        let pos = { (t: TimeInterval) -> CGFloat in CGFloat(min(1, max(0, (t - from) / span))) }
        VStack(alignment: .leading, spacing: 12) {
            GeometryReader { geo in
                let w = geo.size.width
                Capsule().fill(Palette.surface2).overlay(Capsule().strokeBorder(Palette.border))
                    .overlay(alignment: .leading) {
                        ZStack(alignment: .leading) {
                            if segments.isEmpty {
                                Palette.stageLight
                            } else {
                                ForEach(segments) { s in
                                    let a = pos(SleepClock.time(s.start) ?? from), b = pos(SleepClock.time(s.end) ?? from)
                                    SleepStageColor.of(s.stage)
                                        .frame(width: max(0, (b - a) * (w - 6)))
                                        .offset(x: a * (w - 6))
                                }
                            }
                        }
                        .frame(width: max(0, w - 6), height: 12, alignment: .leading)
                        .clipShape(Capsule())
                        .padding(.leading, 3)
                    }
                    // The marker and its pill hang over the track without taking room of their own.
                    .overlay(alignment: .topLeading) {
                        if let at {
                            let x = pos(at) * w
                            Rectangle().fill(Palette.ink).frame(width: 1, height: 36)
                                .alignmentGuide(.leading) { _ in -x }
                                .alignmentGuide(.top) { _ in 8 }
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        if let at {
                            let x = pos(at) * w
                            Text(SleepClock.at(at, segments: segments, fallback: start) + (stageAt.map { " · \(SleepClock.label($0))" } ?? ""))
                                .font(.app(size: 11, weight: .semibold, relativeTo: .caption2))
                                .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                                .foregroundStyle(Palette.surface)
                                .lineLimit(1)
                                .fixedSize()
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Palette.ink, in: Capsule())
                                // Centred on the marker, kept inside the track; its foot just above the marker's top.
                                .alignmentGuide(.leading) { d in -min(max(0, x - d.width / 2), max(0, w - d.width)) }
                                .alignmentGuide(.top) { d in d.height + 11 }
                        }
                    }
            }
            .frame(height: 18)
            .padding(.top, 26)
            GeometryReader { geo in
                ForEach(shownTicks, id: \.at) { tick in
                    Text(tick.label).font(.axis).foregroundStyle(Palette.ink3).fixedSize()
                        .position(x: pos(tick.at) * geo.size.width, y: 7)
                }
            }
            .frame(height: 14)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("The night from \(SleepClock.wall(start)) to \(SleepClock.wall(end))"
            + (at.map { ", deepest sleep at \(SleepClock.at($0, segments: segments, fallback: start))" } ?? ""))
        .accessibilityAddTraits(.isImage)
    }
}

// MARK: - Figures in a grid

/// Label, value and a small note in columns (the stage totals, the night's facts): four across where there's room, two
/// on a phone, one at the accessibility text sizes, so no figure is ever cut off.
struct SleepFigureGrid<Item: Identifiable, Cell: View>: View {
    let items: [Item]
    @ViewBuilder let cell: (Item) -> Cell
    @Environment(\.duoBand) private var band
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let columns = typeSize.isAccessibilitySize ? 1 : band == .compact ? 2 : 4
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .topLeading), count: columns),
                  alignment: .leading, spacing: 12) {
            ForEach(items) { cell($0) }
        }
    }
}

/// One stage's total: its dot and name, the time, and its share (.stage-totals).
struct SleepStageFigure: View {
    let label: String
    let color: Color
    let hours: Double
    let share: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 10, height: 10)
                Text(label).font(.app(size: 12, relativeTo: .caption)).foregroundStyle(Palette.ink2)
            }
            Text(Fmt.hoursMinutes(hours)).font(.app(size: 18, weight: .medium, relativeTo: .title3)).tracking(-0.18).foregroundStyle(Palette.ink)
            Text("\(share)%").font(.app(size: 11, relativeTo: .caption2)).foregroundStyle(Palette.ink3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
