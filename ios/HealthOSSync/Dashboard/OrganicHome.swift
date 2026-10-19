import SwiftUI
import UIKit

// The organic Today: header, the portrait on a soft glow with live vital readings, data shapes floating
// around the lower half, and a path through the day. Colours are the existing Palette only.

// MARK: - Header

struct OrganicHeader: View {
    let summary: Summary
    let name: String?
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        let isToday = summary.date == summary.today
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 2) {
                Text(Fmt.day(summary.date, "EEEEMMMd")).font(.subheadline.weight(.medium)).foregroundStyle(Palette.ink2)
                Spacer()
                Button { Task { await dashboard.show(date: Day.add(summary.date, -1)) } } label: {
                    Image(systemName: "chevron.left").frame(width: 44, height: 44)
                }
                .accessibilityLabel("Previous day")
                Button { Task { await dashboard.show(date: Day.add(summary.date, 1)) } } label: {
                    Image(systemName: "chevron.right").frame(width: 44, height: 44)
                }
                .disabled(isToday)
                .accessibilityLabel("Next day")
                // Today hides its navigation bar, so Settings' gear sits here, top right like on the other tabs.
                Button { dashboard.tab = .settings } label: {
                    Image(systemName: "gearshape").frame(width: 44, height: 44)
                }
                .accessibilityLabel("Settings")
                .accessibilityIdentifier("settingsGear")
            }
            .foregroundStyle(Palette.ink2)
            .buttonStyle(.plain)
            Text("Hello, \(name ?? "there").").font(.title2.weight(.medium)).foregroundStyle(Palette.ink)
            if !isToday {
                Button("Back to today") { Task { await dashboard.show(date: nil) } }.font(.footnote)
            }
            SyncStatusLine()
        }
    }
}

// MARK: - Portrait

enum VitalKey: Int, CaseIterable { case temp, breathing, heart }

struct OrganicPortrait: View {
    let summary: Summary
    let photo: PhotoMeta?
    let units: Units
    let stepGoal: Double
    /// Today's path's marker, shared through Today: while it's moved, the heart shows that hour.
    let scrubbed: TodayScrub
    @Environment(Dashboard.self) private var dashboard
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var image: UIImage?
    @State private var revealStart: Date?
    @State private var revealed = false
    @State private var cells: RevealCells?
    @State private var width: CGFloat = 360
    @State private var liveOpen = false
    /// The readings' and shapes' real heights (they grow with the text size and when status words wrap), so each
    /// is placed below the one above it instead of a fixed distance apart.
    @State private var labelHeights: [VitalKey: CGFloat] = [:]
    @State private var shapeHeights: [PortraitShape: CGFloat] = [:]

    private let figureHeight: CGFloat = 340
    private static var played: Set<String> = []

    var body: some View {
        let scrub = heartScrub
        GeometryReader { geo in
            let layout = PortraitLayout(width: geo.size.width, figureHeight: figureHeight, aspect: aspect)
            let plan = layout.plan(dots: dots, faceCenterX: faceCenterX, labelHeights: labelHeights, shapeHeights: shapeHeights)
            ZStack(alignment: .topLeading) {
                GlowBlob()
                    .fill(Palette.pageGlow)
                    .frame(width: 220, height: 240)
                    .position(x: layout.figure.midX, y: layout.figure.minY + layout.figure.height * 0.36)
                    .accessibilityHidden(true)
                figure(layout)
                    .frame(width: layout.figure.width, height: layout.figure.height)
                    .position(x: layout.figure.midX, y: layout.figure.midY)
                callouts(plan, scrub: scrub)
                    .opacity(revealed || photo == nil ? 1 : 0)
                    .animation(.easeOut(duration: 0.5), value: revealed)
                shapes(plan)
            }
        }
        // The figure is narrower than tall photos would need on small phones; size the area to the real figure, and
        // to readings and shapes pushed below it by large text.
        .frame(height: PortraitLayout(width: width, figureHeight: figureHeight, aspect: aspect)
            .plan(dots: dots, faceCenterX: faceCenterX, labelHeights: labelHeights, shapeHeights: shapeHeights).height)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .task(id: "\(photo?.versionKey ?? "none")-\(scheme == .dark)") { await loadPhoto() }
        .sheet(isPresented: $liveOpen) { LiveHeartRateView() }
    }

    /// While Today's path is moved off live on this same day, the heart shows that hour (web Home.tsx heartScrub).
    private var heartScrub: HeartScrub? { scrubbed.heart(on: summary.date) }

    private var aspect: CGFloat {
        guard let photo, photo.height > 0 else { return 0.62 }
        return CGFloat(photo.width / photo.height)
    }

    private var dots: [VitalKey: CGPoint] {
        if let d = photo?.dots, let t = d.temp, let b = d.breathing, let h = d.heart, t.count == 2, b.count == 2, h.count == 2 {
            return [.temp: CGPoint(x: t[0], y: t[1]), .breathing: CGPoint(x: b[0], y: b[1]), .heart: CGPoint(x: h[0], y: h[1])]
        }
        return PortraitLayout.silhouetteDots
    }

    private var faceCenterX: CGFloat {
        if let f = photo?.face, f.count == 4 { return CGFloat(f[0] + f[2] / 2) }
        return 0.5
    }

    // MARK: Figure

    @ViewBuilder
    private func figure(_ layout: PortraitLayout) -> some View {
        if let photo, let image {
            let elapsed: () -> Double = { revealStart.map { Date().timeIntervalSince($0) } ?? 99 }
            TimelineView(.animation(paused: revealed)) { context in
                let edge = RevealMath.edge(elapsed: revealStart.map { context.date.timeIntervalSince($0) } ?? 99)
                ZStack {
                    Image(uiImage: image)
                        .resizable()
                        .mask(FadeMask())
                        .mask(alignment: .top) {
                            VStack(spacing: 0) {
                                Color.clear.frame(height: max(0, layout.figure.height * edge))
                                Color.black
                            }
                        }
                    if !revealed, let cells {
                        AsciiBand(cells: cells, edge: edge, frame: Int((revealStart.map { context.date.timeIntervalSince($0) } ?? 0) * 30), dark: scheme == .dark)
                    }
                }
                .onChange(of: edge <= -RevealMath.band) { _, done in if done { revealed = true } }
            }
            .accessibilityLabel("Your photo")
            .onAppear { _ = elapsed; _ = photo }
        } else {
            Silhouette()
                .fill(LinearGradient(colors: [Palette.surface2, Palette.ink3.opacity(0.35)], startPoint: .top, endPoint: .bottom))
                .mask(FadeMask())
                .accessibilityHidden(true)
        }
    }

    private func loadPhoto() async {
        guard let photo else {
            image = nil
            revealed = true
            return
        }
        let key = photo.versionKey
        guard let img = await ProfileImages.image(.cutout, version: key, dark: scheme == .dark) else {
            image = nil
            revealed = true // the silhouette shows; nothing stays hidden
            return
        }
        if reduceMotion || Self.played.contains(key) {
            image = img
            revealed = true
            return
        }
        let size = CGSize(width: figureHeight * CGFloat(photo.width / photo.height), height: figureHeight)
        cells = await Task.detached(priority: .userInitiated) { RevealCells(image: img, size: size) }.value
        Self.played.insert(key)
        revealed = false
        image = img
        revealStart = Date()
        // Backstop: the band can't stay up if the timeline stops ticking (e.g. the screen goes away).
        try? await Task.sleep(for: .seconds(RevealMath.duration + 0.2))
        revealed = true
    }

    // MARK: Callouts

    private func reading(_ key: VitalKey, scrub: HeartScrub?) -> CalloutReading {
        let v = summary.vitals
        let vital: Vital?
        let name: String, value: String?, spokenName: String
        switch key {
        case .temp:
            vital = v?.temp
            let m = vital?.latest.map { units.temp($0.value) }
            (name, value, spokenName) = ("Temp", m.map { $0.text(1) }, vital?.label ?? "Temperature")
        case .breathing:
            vital = v?.breathing
            (name, value, spokenName) = ("Breathing", vital?.latest.map { "\(Fmt.number($0.value, 1)) rpm" }, "Breathing rate")
        case .heart:
            return Self.heartReading(v?.heart, asOf: summary.date, scrub: scrub)
        }
        let status = VitalLevel.statusLine(vital, asOf: summary.date)
        let a11y = "\(spokenName) \(value ?? "no reading")" + (status.map { ", \($0)" } ?? "")
        return CalloutReading(name: name, value: value, level: VitalLevel.of(vital, asOf: summary.date), status: status, a11y: a11y)
    }

    /// The heart callout: the resting rate with its level, or, while Today's path is scrubbed, that hour's average
    /// with its hour as the words and no level (levels are for resting rates; web Figure.tsx CalloutLabel).
    static func heartReading(_ vital: Vital?, asOf: String, scrub: HeartScrub?) -> CalloutReading {
        if let scrub {
            let value = scrub.bpm.map { "\(Fmt.number($0)) bpm" }
            return CalloutReading(name: "Heart", value: value, level: .neutral, status: scrub.label,
                                  a11y: value.map { "Heart rate \($0), \(scrub.spoken)" } ?? "Heart rate, \(scrub.spoken)", scrubbed: true)
        }
        let value = vital?.latest.map { "\(Fmt.number($0.value)) bpm" }
        let status = VitalLevel.statusLine(vital, asOf: asOf)
        return CalloutReading(name: "Heart", value: value, level: VitalLevel.of(vital, asOf: asOf), status: status,
                              a11y: "Resting heart rate \(value ?? "no reading")" + (status.map { ", \($0)" } ?? ""))
    }

    @ViewBuilder
    private func callouts(_ plan: PortraitLayout.Plan, scrub: HeartScrub?) -> some View {
        let placed = plan.labels
        let bpm = Self.beatRate(resting: summary.vitals?.heart, scrub: scrub)
        let rpm = summary.vitals?.breathing?.latest?.value ?? 15
        TimelineView(.animation(paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack(alignment: .topLeading) {
                ForEach(VitalKey.allCases, id: \.self) { key in
                    if let p = placed[key] {
                        let r = reading(key, scrub: scrub)
                        Path { path in
                            path.move(to: p.dot)
                            path.addQuadCurve(to: p.anchor, control: CGPoint(x: (p.dot.x + p.anchor.x) / 2, y: min(p.dot.y, p.anchor.y) - 14))
                        }
                        .stroke(Palette.ink3, style: StrokeStyle(lineWidth: 1, lineCap: .round))
                        VitalDot(level: r.level, pulse: Self.pulse(key, t: t, bpm: bpm, rpm: rpm, reduceMotion: reduceMotion), key: key)
                            .position(p.dot)
                        VStack(alignment: p.left ? .trailing : .leading, spacing: 1) {
                            HStack(spacing: 3) {
                                Text(r.name).font(.caption2.weight(.medium)).foregroundStyle(Palette.ink2)
                                // The heart reading opens live heart rate.
                                if key == .heart { Image(systemName: "waveform.path.ecg").font(.caption2).foregroundStyle(Palette.vitalHeart) }
                            }
                            Text(r.value ?? "—").font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(Palette.ink)
                            // The words with the colour, so it never rests on colour alone.
                            if let status = r.status {
                                HStack(alignment: .firstTextBaseline, spacing: 4) {
                                    if r.level != .neutral {
                                        Circle().fill(r.level.color).frame(width: 7, height: 7)
                                    }
                                    Text(status)
                                        .font(.caption2).foregroundStyle(Palette.ink3)
                                        .multilineTextAlignment(p.left ? .trailing : .leading)
                                        // A scrubbed hour stays on one line, so the label keeps its height as the marker moves.
                                        .lineLimit(r.scrubbed ? 1 : 2)
                                        .minimumScaleFactor(r.scrubbed ? 0.5 : 0.85)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .frame(width: PortraitLayout.labelWidth, alignment: p.left ? .trailing : .leading)
                        // Beyond this the words no longer fit beside the figure; VoiceOver and the Vitals screen have them in full.
                        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                        // A scrubbed heart keeps the room it had at rest (its one-line hour can be shorter than wrapped
                        // status words), so nothing below moves while the marker does or springs back.
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
                            labelHeights[key] = r.scrubbed ? max(labelHeights[key] ?? 0, h) : h
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { if key == .heart { liveOpen = true } }
                        .position(x: p.frame.midX, y: p.frame.midY)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(r.a11y)
                        .accessibilityAddTraits(key == .heart ? .isButton : [])
                        .accessibilityHint(key == .heart ? "Opens live heart rate" : "")
                    }
                }
            }
        }
    }

    /// The rate the heart dot beats at: the scrubbed hour's average while Today's path is moved (nil, so still, when
    /// that hour has no reading), otherwise the resting rate, or 60 without one.
    static func beatRate(resting: Vital?, scrub: HeartScrub?) -> Double? {
        if let scrub { return scrub.bpm }
        return resting?.latest?.value ?? 60
    }

    /// 0…1: the heart dot beats every 60/bpm s (still without a bpm); the breathing halo swells every 60/rpm s;
    /// temperature glows slowly. Everything is still under Reduce Motion. The clamps (web Figure.tsx liveVars)
    /// only catch impossible data, so a bad row can't freeze or strobe a dot.
    static func pulse(_ key: VitalKey, t: Double, bpm: Double?, rpm: Double, reduceMotion: Bool) -> Double {
        guard !reduceMotion else { return 0 }
        switch key {
        case .heart:
            guard let bpm else { return 0 }
            let period = 60 / max(30, min(bpm, 220))
            let phase = t.truncatingRemainder(dividingBy: period) / period
            return phase < 0.18 ? sin(phase / 0.18 * .pi) : 0
        case .breathing:
            let period = 60 / max(4, min(rpm, 40))
            return (1 - cos(t.truncatingRemainder(dividingBy: period) / period * 2 * .pi)) / 2
        case .temp:
            return (1 - cos(t.truncatingRemainder(dividingBy: 6) / 6 * 2 * .pi)) / 2
        }
    }

    // MARK: Data shapes

    @ViewBuilder
    private func shapes(_ plan: PortraitLayout.Plan) -> some View {
        let sleep = summary.sleep?.latest
        let steps = summary.activity?.latest
        let hrv = summary.hrv?.latest
        DataShape(tint: .green, radii: .init(topLeading: 30, bottomLeading: 22, bottomTrailing: 34, topTrailing: 24),
                  title: "Slept", value: sleep.map { Fmt.hoursMinutes($0.value) } ?? "—", a11y: "Slept \(sleep.map { Fmt.hoursMinutes($0.value) } ?? "no data")") {
            dashboard.open(.sleep)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { shapeHeights[.slept] = $0 }
        .position(x: plan.shapes[.slept]!.midX, y: plan.shapes[.slept]!.midY)
        DataShape(tint: .peach, radii: .init(topLeading: 24, bottomLeading: 34, bottomTrailing: 22, topTrailing: 30),
                  title: "Steps", value: steps.map { Fmt.number($0.value) } ?? "—",
                  progress: steps.map { min(1, $0.value / max(1, stepGoal)) },
                  a11y: "Steps \(steps.map { Fmt.number($0.value) } ?? "no data") of \(Fmt.number(stepGoal)) goal") {
            dashboard.open(.activity)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { shapeHeights[.steps] = $0 }
        .position(x: plan.shapes[.steps]!.midX, y: plan.shapes[.steps]!.midY)
        DataShape(tint: .pink, radii: .init(topLeading: 34, bottomLeading: 26, bottomTrailing: 30, topTrailing: 22),
                  title: "HRV", value: hrv.map { "\(Fmt.number($0.value)) ms" } ?? "—",
                  a11y: "Heart rate variability \(hrv.map { "\(Fmt.number($0.value)) milliseconds" } ?? "no data")") {
            dashboard.open(.vitals)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { shapeHeights[.hrv] = $0 }
        .position(x: plan.shapes[.hrv]!.midX, y: plan.shapes[.hrv]!.midY)
    }
}

/// A reading beside the portrait: its name, value, level and words, and what VoiceOver says.
struct CalloutReading: Equatable {
    let name: String
    let value: String?
    let level: VitalLevel
    let status: String?
    let a11y: String
    /// The heart while Today's path is scrubbed: that hour's average rather than the resting rate.
    var scrubbed = false
}

/// The data shapes floating around the lower half of the portrait.
enum PortraitShape: CaseIterable { case slept, steps, hrv }

/// Where the figure, readings and shapes go for a given width (web src/components/Figure.tsx placeLabels): each
/// reading sits beside its dot when there's room, otherwise just below the reading above it on that side, by the
/// readings' measured heights; the shapes keep clear of the readings, and the area grows to hold everything.
struct PortraitLayout {
    static let labelWidth: CGFloat = 84
    /// Between two readings on one side, and between a reading and a shape (web: 10px).
    static let gap: CGFloat = 8
    /// A reading before it's been measured: name, value and two lines of status words at the default text size.
    static let estimatedLabelHeight: CGFloat = 60
    static let shapeWidth: CGFloat = 116
    /// A shape before it's been measured (its minimum height).
    static let estimatedShapeHeight: CGFloat = 60
    /// The silhouette's points, when there's no photo (fractions of the figure).
    static let silhouetteDots: [VitalKey: CGPoint] = [.temp: CGPoint(x: 0.5, y: 0.1), .breathing: CGPoint(x: 0.5, y: 0.42), .heart: CGPoint(x: 0.57, y: 0.56)]

    let width: CGFloat
    let figure: CGRect

    init(width: CGFloat, figureHeight: CGFloat, aspect: CGFloat) {
        self.width = width
        let w = min(figureHeight * aspect, width * 0.6)
        let h = w / max(aspect, 0.01)
        figure = CGRect(x: (width - w) / 2, y: 8, width: w, height: min(h, figureHeight))
    }

    struct Placed {
        let dot: CGPoint
        /// The reading's own box.
        let frame: CGRect
        /// Where the leader line from the dot meets it.
        let anchor: CGPoint
        let left: Bool
    }

    struct Plan {
        let labels: [VitalKey: Placed]
        let shapes: [PortraitShape: CGRect]
        /// The whole area's height: the figure with room below it, or further down to the lowest reading or shape.
        let height: CGFloat
    }

    func plan(dots: [VitalKey: CGPoint], faceCenterX: CGFloat, labelHeights: [VitalKey: CGFloat], shapeHeights: [PortraitShape: CGFloat]) -> Plan {
        let labels = labels(for: dots, faceCenterX: faceCenterX, heights: labelHeights)
        let shapes = shapes(avoiding: labels.values.map(\.frame), heights: shapeHeights)
        let lowest = (labels.values.map(\.frame.maxY) + shapes.values.map(\.maxY)).max() ?? 0
        return Plan(labels: labels, shapes: shapes, height: max(figure.maxY + 72, lowest + 8))
    }

    /// Readings go left or right of the face, never over it. Each is centred on its dot's height when there's room,
    /// and otherwise starts `gap` below the bottom of the reading above it on the same side (never above the top).
    func labels(for dots: [VitalKey: CGPoint], faceCenterX: CGFloat, heights: [VitalKey: CGFloat]) -> [VitalKey: Placed] {
        var out: [VitalKey: Placed] = [:]
        let points = dots.mapValues { CGPoint(x: figure.minX + $0.x * figure.width, y: figure.minY + $0.y * figure.height) }
        for left in [true, false] {
            let side = dots.filter { ($0.value.x < faceCenterX) == left }
                .sorted { $0.value.y != $1.value.y ? $0.value.y < $1.value.y : $0.key.rawValue < $1.key.rawValue }
            var minTop: CGFloat = 0
            for (key, _) in side {
                let p = points[key]!
                let h = heights[key] ?? Self.estimatedLabelHeight
                let top = max(p.y - h / 2, minTop)
                minTop = top + h + Self.gap
                let frame = CGRect(x: left ? 2 : width - Self.labelWidth - 2, y: top, width: Self.labelWidth, height: h)
                let ax = left ? Self.labelWidth + 6 : width - Self.labelWidth - 6
                out[key] = Placed(dot: p, frame: frame, anchor: CGPoint(x: ax, y: frame.midY), left: left)
            }
        }
        return out
    }

    /// Each shape at its own place around the figure, moved down below any reading (or shape placed before it) it
    /// would touch.
    func shapes(avoiding labels: [CGRect], heights: [PortraitShape: CGFloat]) -> [PortraitShape: CGRect] {
        let centres: [(PortraitShape, CGPoint)] = [
            (.slept, CGPoint(x: max(64, figure.minX + 10), y: figure.minY + figure.height * 0.74)),
            (.steps, CGPoint(x: min(width - 64, figure.maxX - 10), y: figure.minY + figure.height * 0.86)),
            (.hrv, CGPoint(x: width / 2, y: figure.maxY + 34)),
        ]
        var obstacles = labels
        var out: [PortraitShape: CGRect] = [:]
        for (shape, c) in centres {
            let h = heights[shape] ?? Self.estimatedShapeHeight
            var r = CGRect(x: c.x - Self.shapeWidth / 2, y: c.y - h / 2, width: Self.shapeWidth, height: h)
            // Only ever moves down, past one obstacle at a time, so it settles.
            var moved = true
            while moved {
                moved = false
                for o in obstacles where Self.touches(r, o) {
                    r.origin.y = o.maxY + Self.gap
                    moved = true
                }
            }
            out[shape] = r
            obstacles.append(r)
        }
        return out
    }

    /// Overlapping sideways, and closer than `gap` up and down.
    static func touches(_ a: CGRect, _ b: CGRect) -> Bool {
        a.minX < b.maxX && b.minX < a.maxX && a.minY < b.maxY + gap && b.minY < a.maxY + gap
    }
}

/// A vital's dot on the portrait, green, amber or red by how far the reading is from the person's usual (neutral
/// without a level or for an older reading), animated by its own number: the heart beats, breathing swells, and
/// temperature glows.
private struct VitalDot: View {
    let level: VitalLevel
    let pulse: Double
    let key: VitalKey

    var body: some View {
        let color = level.color
        ZStack {
            Circle().fill(color.opacity(key == .breathing ? 0.16 + 0.18 * pulse : 0.22))
                // The halo takes a ring of the level, so the colour reads at a glance even where the dot is small.
                .overlay(Circle().stroke(color.opacity(level == .neutral ? 0 : 0.5), lineWidth: 1))
                .frame(width: 22 + (key == .breathing ? 10 * pulse : key == .temp ? 4 * pulse : 0))
            Circle().fill(color)
                .overlay(Circle().stroke(Palette.surface, lineWidth: 1.5))
                .frame(width: 9, height: 9)
                .scaleEffect(key == .heart ? 1 + 0.45 * pulse : 1)
        }
        .frame(width: 44, height: 44)
        .accessibilityHidden(true)
    }
}

/// How a vital's dot is coloured and what its words say (src/components/Figure.tsx, levelOf and statusText).
enum VitalLevel: Equatable {
    /// Within the person's usual.
    case normal
    /// Beyond it.
    case unusual
    /// Well beyond it (more than twice the usual band).
    case off
    /// No baseline yet, no reading, a reading older than the day shown, or a level this app doesn't know.
    case neutral

    /// Green within the person's usual, amber beyond it, red well beyond it. A reading from another day than the
    /// one shown stays neutral (its date shows instead), so last week's number never alarms today's portrait.
    static func of(_ v: Vital?, asOf: String) -> VitalLevel {
        guard let v, let latest = v.latest, latest.date == asOf, let status = v.status, ["low", "normal", "high"].contains(status) else {
            return .neutral
        }
        switch v.level {
        // Servers before levels: the status alone says normal or not.
        case nil: return status == "normal" ? .normal : .unusual
        case "normal": return .normal
        case "unusual": return .unusual
        case "off": return .off
        default: return .neutral
        }
    }

    /// The words with the colour: "Normal", "Above usual", "Well below usual"…; nil for a status this app doesn't know.
    static func statusText(_ v: Vital?) -> String? {
        guard let status = v?.status else { return v?.latest == nil ? "No data" : "Building baseline" }
        switch status {
        case "normal": return "Normal"
        case "high", "low":
            let up = status == "high"
            if v?.level == "off" { return up ? "Well above usual" : "Well below usual" }
            return up ? "Above usual" : "Below usual"
        default: return nil
        }
    }

    /// The status words, with the reading's date when it's from another day than the one shown.
    static func statusLine(_ v: Vital?, asOf: String) -> String? {
        let text = statusText(v)
        guard let latest = v?.latest, latest.date != asOf else { return text }
        let date = Fmt.day(latest.date)
        return text.map { "\($0) · \(date)" } ?? date
    }

    var color: Color {
        switch self {
        case .normal: Palette.good
        case .unusual: Palette.warning
        case .off: Palette.critical
        // web --level-none
        case .neutral: Palette.dynamic(0xCFCCC4, 0x77746D)
        }
    }
}

private struct DataShape: View {
    let tint: CardTint
    let radii: RectangleCornerRadii
    let title: String
    let value: String
    var progress: Double?
    let a11y: String
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.caption.weight(.medium)).foregroundStyle(Palette.ink2)
                Text(value).font(.headline).monospacedDigit().foregroundStyle(Palette.ink).lineLimit(1).minimumScaleFactor(0.7)
                if let progress {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Palette.ink.opacity(0.08))
                            Capsule().fill(Palette.series2).frame(width: g.size.width * progress)
                        }
                    }
                    .frame(height: 4)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(width: 116, alignment: .leading)
            .frame(minHeight: 60)
            .background(tint.background(scheme), in: UnevenRoundedRectangle(cornerRadii: radii, style: .continuous))
            .overlay(UnevenRoundedRectangle(cornerRadii: radii, style: .continuous).strokeBorder(Palette.border))
            .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.05), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(a11y)
        .accessibilityHint("Opens trends")
    }
}

/// The photo's own vertical fade: opaque to 42%, 55% at 66%, gone by 92% (web .figure-photo mask).
struct FadeMask: View {
    var body: some View {
        LinearGradient(stops: [
            .init(color: .black, location: 0), .init(color: .black, location: 0.42),
            .init(color: .black.opacity(0.55), location: 0.66), .init(color: .clear, location: 0.92),
        ], startPoint: .top, endPoint: .bottom)
    }

    static func alpha(_ y: Double) -> Double {
        if y <= 0.42 { return 1 }
        if y <= 0.66 { return 1 - 0.45 * (y - 0.42) / 0.24 }
        if y <= 0.92 { return 0.55 * (1 - (y - 0.66) / 0.26) }
        return 0
    }
}

/// An irregular rounded blob for the glow behind the portrait.
struct GlowBlob: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * r.width, y: r.minY + y * r.height) }
        p.move(to: pt(0.52, 0.0))
        p.addCurve(to: pt(1.0, 0.42), control1: pt(0.82, 0.0), control2: pt(1.02, 0.18))
        p.addCurve(to: pt(0.58, 1.0), control1: pt(0.98, 0.70), control2: pt(0.84, 0.98))
        p.addCurve(to: pt(0.02, 0.62), control1: pt(0.28, 1.02), control2: pt(0.0, 0.88))
        p.addCurve(to: pt(0.52, 0.0), control1: pt(0.04, 0.30), control2: pt(0.22, 0.0))
        p.closeSubpath()
        return p
    }
}

/// Head and shoulders, shown when there's no profile photo.
struct Silhouette: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let w = r.width, h = r.height
        p.addEllipse(in: CGRect(x: r.minX + w * 0.33, y: r.minY + h * 0.02, width: w * 0.34, height: h * 0.27))
        p.move(to: CGPoint(x: r.minX + w * 0.02, y: r.minY + h))
        p.addCurve(to: CGPoint(x: r.minX + w * 0.5, y: r.minY + h * 0.33),
                   control1: CGPoint(x: r.minX + w * 0.02, y: r.minY + h * 0.45), control2: CGPoint(x: r.minX + w * 0.22, y: r.minY + h * 0.33))
        p.addCurve(to: CGPoint(x: r.minX + w * 0.98, y: r.minY + h),
                   control1: CGPoint(x: r.minX + w * 0.78, y: r.minY + h * 0.33), control2: CGPoint(x: r.minX + w * 0.98, y: r.minY + h * 0.45))
        p.closeSubpath()
        return p
    }
}

// MARK: - ASCII reveal

/// Timing from src/components/PhotoReveal.tsx: 2.16 s, ease-out quadratic; the edge starts at 88% of the
/// height and travels past the top by the band (20%).
enum RevealMath {
    static let duration = 2.16
    static let band = 0.2
    static let start = 0.88

    static func edge(elapsed: Double) -> Double {
        let t = min(1, max(0, elapsed / duration))
        let p = 1 - (1 - t) * (1 - t)
        return start - p * (start + band)
    }
}

/// The cut-out downsampled to one value per glyph cell.
struct RevealCells: Sendable {
    let cols: Int
    let rows: Int
    let cellW: CGFloat
    let cellH: CGFloat
    let lum: [Float]
    let alpha: [Float]

    init(image: UIImage, size: CGSize) {
        cellH = max(7, size.height / 70)
        cellW = cellH * 0.6
        cols = max(1, Int(size.width / cellW))
        rows = max(1, Int(size.height / cellH))
        var px = [UInt8](repeating: 0, count: cols * rows * 4)
        if let cg = image.cgImage, let ctx = CGContext(data: &px, width: cols, height: rows, bitsPerComponent: 8, bytesPerRow: cols * 4,
                                                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cols, height: rows))
        }
        var l = [Float](repeating: 0, count: cols * rows), a = l
        for row in 0..<rows {
            for col in 0..<cols {
                // CoreGraphics rows run bottom-up; cells are stored top-down.
                let i = ((rows - 1 - row) * cols + col) * 4
                let al = Float(px[i + 3]) / 255
                let k = row * cols + col
                a[k] = al
                l[k] = al > 0 ? (0.2126 * Float(px[i]) + 0.7152 * Float(px[i + 1]) + 0.0722 * Float(px[i + 2])) / 255 / al : 0
            }
        }
        lum = l
        alpha = a
    }
}

private struct AsciiBand: View {
    let cells: RevealCells
    let edge: Double
    let frame: Int
    let dark: Bool

    private static let ramp = Array(" .:-=+*#%@")

    var body: some View {
        Canvas { ctx, size in
            let glyphs = Self.ramp.map { ctx.resolve(Text(String($0)).font(.system(size: cells.cellH, design: .monospaced)).foregroundStyle(Palette.ink)) }
            let sx = size.width / CGFloat(cells.cols), sy = size.height / CGFloat(cells.rows)
            let top = edge - RevealMath.band, below = edge + 0.02
            let r0 = max(0, Int(top * Double(cells.rows))), r1 = min(cells.rows - 1, Int(below * Double(cells.rows)) + 1)
            guard r0 <= r1 else { return }
            for row in r0...r1 {
                let y = (Double(row) + 0.5) / Double(cells.rows)
                guard y >= top, y <= below else { continue }
                let d = y < edge ? (edge - y) / RevealMath.band : 0
                for col in 0..<cells.cols {
                    let k = row * cells.cols + col
                    guard cells.alpha[k] >= 0.35 else { continue }
                    let h = Self.hash(k, frame)
                    if y < edge, Double(h & 0xFFFF) / 65535 < 0.85 * d { continue }
                    let l = Double(cells.lum[k])
                    var idx = Int(((dark ? l : 1 - l) * 9).rounded())
                    if (h >> 16) % 100 < 30 { idx += ((h >> 24) & 1) == 0 ? -1 : 1 }
                    idx = min(9, max(1, idx)) // never a space inside the cut-out
                    var c = ctx
                    c.opacity = FadeMask.alpha(y) * (y < edge ? 1 - 0.8 * d : 0.5)
                    c.draw(glyphs[idx], at: CGPoint(x: (CGFloat(col) + 0.5) * sx, y: (CGFloat(row) + 0.5) * sy))
                }
            }
        }
        .allowsHitTesting(false)
    }

    private static func hash(_ k: Int, _ frame: Int) -> UInt64 {
        var x = UInt64(truncatingIfNeeded: k) &* 0x9E3779B97F4A7C15 ^ UInt64(truncatingIfNeeded: frame) &* 0xC2B2AE3D27D4EB4F
        x ^= x >> 31
        x &*= 0xBF58476D1CE4E5B9
        x ^= x >> 27
        return x
    }
}

// MARK: - Today path

/// The day's path: a readout of one moment, a 24-hour track to scrub through it (TimelineScrub.swift), and a
/// dashed path with a pebble per recent event. Today runs from 00:00 to now; a past day runs the whole day.
struct TodayPath: View {
    let timeline: Summary.Timeline
    /// The marker and the heart at it, shared with the portrait through Today.
    let scrubbed: TodayScrub
    @Environment(Dashboard.self) private var dashboard
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The timeline day's hourly readings (GET /api/day), which day the server last answered for, and whether
    /// asking failed; a failure never reads as "no readings".
    @State private var load = DayLoad()

    /// The minute the marker was moved to on this day; nil is live (now, or the end of a past day).
    private var scrub: Int? {
        get { scrubbed.minute(on: timeline.date) }
        nonmutating set { scrubbed.move(to: newValue, on: timeline.date) }
    }

    private var scrubBinding: Binding<Int?> {
        Binding(get: { scrub }, set: { scrub = $0 })
    }

    var body: some View {
        // The timeline's own day, which can be earlier than the summary's when nothing is on the chosen day.
        let today = dashboard.summary?.today ?? Day.today()
        let isToday = timeline.date == today
        let events = timeline.events.sorted { $0.start < $1.start }
        let hours = load.hours(for: timeline.date)
        let held = scrub
        TimelineView(.everyMinute) { context in
            let upper = TimelineScrub.scrubMax(isToday: isToday, nowMinute: TimelineScrub.nowMinute(context.date, day: today), asOf: hours?.asOf)
            let live = held == nil
            let minute = live ? upper : min(held ?? upper, upper)
            let moment = TimelineScrub.moment(day: hours, events: events, date: timeline.date, minute: minute, live: live)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(isToday ? "Today's path" : "The day's path").font(.headline).foregroundStyle(Palette.ink)
                    Spacer()
                    // Back to the resting position; hidden while there.
                    Button { withAnimation(TimelineScrub.motion(.easeOut(duration: 0.25), reduceMotion: reduceMotion)) { scrub = nil } } label: {
                        Text(isToday ? "Now" : "End of day")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Palette.ink)
                            .padding(.horizontal, 12).padding(.vertical, 5)
                            .background(Palette.surface2, in: Capsule())
                            .overlay(Capsule().strokeBorder(Palette.border))
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .opacity(live ? 0 : 1)
                    .disabled(live)
                    .accessibilityHidden(live)
                    .accessibilityHint(isToday ? "Moves the timeline marker back to now" : "Moves the timeline marker back to the end of the day")
                }
                TimelineScrubber(events: events, date: timeline.date, isToday: isToday, day: hours,
                                 answered: load.answered(timeline.date), failed: load.failed(timeline.date),
                                 upper: upper, moment: moment, scrub: scrubBinding)
                pebbles(Array(events.suffix(5)), current: Set(moment.events.map(\.id)))
            }
            // The portrait's heart follows the marker while it's off live (web Home.tsx onHeart), and again on coming
            // back to Today with a moment still held.
            .onAppear { scrubbed.follow(HeartScrub.from(moment, live: live, date: timeline.date)) }
            .onChange(of: HeartScrub.from(moment, live: live, date: timeline.date)) { _, heart in scrubbed.follow(heart) }
        }
        .task(id: "\(timeline.date)|\(dashboard.generation)") { await fetchDay() }
        // A new day starts live, and the portrait goes back to the resting rate with it.
        .onChange(of: timeline.date, initial: true) { scrubbed.show(timeline.date) }
        .onDisappear { scrubbed.hide() }
    }

    /// Asks for the timeline day's hours. A 404 (a server without the Day view) is an answer: no hours. A real
    /// failure (offline, a server error) keeps what's on screen for this day and tries again, less often each time,
    /// while the card is on screen.
    private func fetchDay() async {
        let date = timeline.date
        var wait = Duration.seconds(15)
        while !Task.isCancelled {
            do {
                let fetched = try await dashboard.day(date: isTodayDate ? nil : date)
                guard !Task.isCancelled else { return }
                load.received(fetched, for: date)
                return
            } catch {
                guard !Task.isCancelled else { return }
                load.failed(for: date)
            }
            try? await Task.sleep(for: wait)
            wait = min(wait * 2, .seconds(300))
        }
    }

    private var isTodayDate: Bool { timeline.date == (dashboard.summary?.today ?? Day.today()) }

    @ViewBuilder
    private func pebbles(_ events: [TimelineEvent], current: Set<String>) -> some View {
        if events.isEmpty {
            Text("Nothing recorded for this day yet.").font(.footnote).foregroundStyle(Palette.ink3)
        } else {
            GeometryReader { geo in
                let w = geo.size.width
                let point: (Int) -> CGPoint = { i in
                    let x = events.count == 1 ? w / 2 : 36 + (w - 72) * CGFloat(i) / CGFloat(events.count - 1)
                    return CGPoint(x: x, y: 30 + 14 * sin(x / w * .pi * 2))
                }
                ZStack(alignment: .topLeading) {
                    Path { p in
                        p.move(to: CGPoint(x: 8, y: 30 + 14 * sin(8 / w * .pi * 2)))
                        var x: CGFloat = 8
                        while x < w - 8 {
                            x += 4
                            p.addLine(to: CGPoint(x: x, y: 30 + 14 * sin(x / w * .pi * 2)))
                        }
                    }
                    .stroke(Palette.ink3.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [4, 6]))
                    ForEach(Array(events.enumerated()), id: \.element.id) { i, e in
                        // The events at the marker stand out.
                        let now = current.contains(e.id)
                        Button { open(e) } label: {
                            VStack(spacing: 4) {
                                Circle().fill(TimelineCard.color(e.kind))
                                    .overlay(Circle().stroke(now ? Palette.ink : Palette.surface, lineWidth: 2))
                                    .frame(width: now ? 20 : 16, height: now ? 20 : 16)
                                    .frame(width: 20, height: 20)
                                Text(e.title).font(.caption2.weight(.semibold)).foregroundStyle(Palette.ink).lineLimit(1)
                                Text(Fmt.clock(e.start)).font(.caption2).monospacedDigit().foregroundStyle(Palette.ink3)
                            }
                            .frame(width: 72, height: 64)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .position(x: point(i).x, y: point(i).y + 24)
                        .animation(TimelineScrub.motion(.easeOut(duration: 0.2), reduceMotion: reduceMotion), value: now)
                        .accessibilityLabel("\(e.title), \(Fmt.clock(e.start)) to \(Fmt.clock(e.end))")
                        .accessibilityHint("Opens trends")
                    }
                }
            }
            .frame(height: 96)
        }
    }

    private func open(_ e: TimelineEvent) {
        switch e.kind {
        case "sleep", "nap": dashboard.open(.sleep)
        case "workout": dashboard.open(.activity)
        default: dashboard.open(.vitals)
        }
    }
}
