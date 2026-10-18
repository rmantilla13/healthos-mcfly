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

private enum VitalKey: CaseIterable { case temp, breathing, heart }

struct OrganicPortrait: View {
    let summary: Summary
    let photo: PhotoMeta?
    let units: Units
    let stepGoal: Double
    @Environment(Dashboard.self) private var dashboard
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var image: UIImage?
    @State private var revealStart: Date?
    @State private var revealed = false
    @State private var cells: RevealCells?
    @State private var width: CGFloat = 360
    @State private var liveOpen = false

    private let figureHeight: CGFloat = 340
    private static var played: Set<String> = []

    var body: some View {
        GeometryReader { geo in
            let layout = Layout(width: geo.size.width, figureHeight: figureHeight, aspect: aspect)
            ZStack(alignment: .topLeading) {
                GlowBlob()
                    .fill(Palette.pageGlow)
                    .frame(width: 220, height: 240)
                    .position(x: layout.figure.midX, y: layout.figure.minY + layout.figure.height * 0.36)
                    .accessibilityHidden(true)
                figure(layout)
                    .frame(width: layout.figure.width, height: layout.figure.height)
                    .position(x: layout.figure.midX, y: layout.figure.midY)
                callouts(layout)
                    .opacity(revealed || photo == nil ? 1 : 0)
                    .animation(.easeOut(duration: 0.5), value: revealed)
                shapes(layout)
            }
        }
        // The figure is narrower than tall photos would need on small phones; size the area to the real figure.
        .frame(height: Layout(width: width, figureHeight: figureHeight, aspect: aspect).figure.maxY + 72)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .task(id: "\(photo?.versionKey ?? "none")-\(scheme == .dark)") { await loadPhoto() }
        .sheet(isPresented: $liveOpen) { LiveHeartRateView() }
    }

    private var aspect: CGFloat {
        guard let photo, photo.height > 0 else { return 0.62 }
        return CGFloat(photo.width / photo.height)
    }

    private var dots: [VitalKey: CGPoint] {
        if let d = photo?.dots, let t = d.temp, let b = d.breathing, let h = d.heart, t.count == 2, b.count == 2, h.count == 2 {
            return [.temp: CGPoint(x: t[0], y: t[1]), .breathing: CGPoint(x: b[0], y: b[1]), .heart: CGPoint(x: h[0], y: h[1])]
        }
        // The silhouette's points.
        return [.temp: CGPoint(x: 0.5, y: 0.1), .breathing: CGPoint(x: 0.5, y: 0.42), .heart: CGPoint(x: 0.57, y: 0.56)]
    }

    private var faceCenterX: CGFloat {
        if let f = photo?.face, f.count == 4 { return CGFloat(f[0] + f[2] / 2) }
        return 0.5
    }

    // MARK: Figure

    @ViewBuilder
    private func figure(_ layout: Layout) -> some View {
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

    private func reading(_ key: VitalKey) -> (name: String, value: String?, color: Color, a11y: String) {
        let v = summary.vitals
        switch key {
        case .temp:
            let m = v?.temp?.latest.map { units.temp($0.value) }
            let label = v?.temp?.label ?? "Temperature"
            return ("Temp", m.map { $0.text(1) }, tempColor, "\(label) \(m?.text(1) ?? "no reading")")
        case .breathing:
            let s = v?.breathing?.latest.map { "\(Fmt.number($0.value, 1)) rpm" }
            return ("Breathing", s, Palette.series1, "Breathing rate \(s ?? "no reading")")
        case .heart:
            let s = v?.heart?.latest.map { "\(Fmt.number($0.value)) bpm" }
            return ("Heart", s, Palette.vitalHeart, "Resting heart rate \(s ?? "no reading")")
        }
    }

    private var tempColor: Color {
        switch summary.vitals?.temp?.status {
        case "high": Palette.serious
        case "low": Palette.series1
        default: Palette.vitalTemp
        }
    }

    @ViewBuilder
    private func callouts(_ layout: Layout) -> some View {
        let placed = layout.labels(for: dots, faceCenterX: faceCenterX)
        let bpm = summary.vitals?.heart?.latest?.value ?? 60
        let rpm = summary.vitals?.breathing?.latest?.value ?? 15
        TimelineView(.animation(paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack(alignment: .topLeading) {
                ForEach(VitalKey.allCases, id: \.self) { key in
                    if let p = placed[key] {
                        let r = reading(key)
                        Path { path in
                            path.move(to: p.dot)
                            path.addQuadCurve(to: p.anchor, control: CGPoint(x: (p.dot.x + p.anchor.x) / 2, y: min(p.dot.y, p.anchor.y) - 14))
                        }
                        .stroke(Palette.ink3, style: StrokeStyle(lineWidth: 1, lineCap: .round))
                        VitalDot(color: r.color, pulse: reduceMotion ? 0 : Self.pulse(key, t: t, bpm: bpm, rpm: rpm), key: key)
                            .position(p.dot)
                        VStack(alignment: p.left ? .trailing : .leading, spacing: 1) {
                            HStack(spacing: 3) {
                                Text(r.name).font(.caption2.weight(.medium)).foregroundStyle(Palette.ink2)
                                // The heart reading opens live heart rate.
                                if key == .heart { Image(systemName: "waveform.path.ecg").font(.caption2).foregroundStyle(Palette.vitalHeart) }
                            }
                            Text(r.value ?? "—").font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(Palette.ink)
                        }
                        .frame(width: Layout.labelWidth, alignment: p.left ? .trailing : .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { if key == .heart { liveOpen = true } }
                        .position(p.label)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(r.a11y)
                        .accessibilityAddTraits(key == .heart ? .isButton : [])
                        .accessibilityHint(key == .heart ? "Opens live heart rate" : "")
                    }
                }
            }
        }
    }

    /// 0…1: the heart dot beats every 60/bpm s; the breathing halo swells every 60/rpm s; temperature glows slowly.
    private static func pulse(_ key: VitalKey, t: Double, bpm: Double, rpm: Double) -> Double {
        switch key {
        case .heart:
            let period = 60 / max(30, min(bpm, 200))
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
    private func shapes(_ layout: Layout) -> some View {
        let sleep = summary.sleep?.latest
        let steps = summary.activity?.latest
        let hrv = summary.hrv?.latest
        DataShape(tint: .green, radii: .init(topLeading: 30, bottomLeading: 22, bottomTrailing: 34, topTrailing: 24),
                  title: "Slept", value: sleep.map { Fmt.hoursMinutes($0.value) } ?? "—", a11y: "Slept \(sleep.map { Fmt.hoursMinutes($0.value) } ?? "no data")") {
            dashboard.open(.sleep)
        }
        .position(layout.shapeSlept)
        DataShape(tint: .peach, radii: .init(topLeading: 24, bottomLeading: 34, bottomTrailing: 22, topTrailing: 30),
                  title: "Steps", value: steps.map { Fmt.number($0.value) } ?? "—",
                  progress: steps.map { min(1, $0.value / max(1, stepGoal)) },
                  a11y: "Steps \(steps.map { Fmt.number($0.value) } ?? "no data") of \(Fmt.number(stepGoal)) goal") {
            dashboard.open(.activity)
        }
        .position(layout.shapeSteps)
        DataShape(tint: .pink, radii: .init(topLeading: 34, bottomLeading: 26, bottomTrailing: 30, topTrailing: 22),
                  title: "HRV", value: hrv.map { "\(Fmt.number($0.value)) ms" } ?? "—",
                  a11y: "Heart rate variability \(hrv.map { "\(Fmt.number($0.value)) milliseconds" } ?? "no data")") {
            dashboard.open(.vitals)
        }
        .position(layout.shapeHRV)
    }
}

/// Where the figure, readings and shapes go for a given width.
private struct Layout {
    static let labelWidth: CGFloat = 84
    let width: CGFloat
    let figure: CGRect

    init(width: CGFloat, figureHeight: CGFloat, aspect: CGFloat) {
        self.width = width
        let w = min(figureHeight * aspect, width * 0.6)
        let h = w / max(aspect, 0.01)
        figure = CGRect(x: (width - w) / 2, y: 8, width: w, height: min(h, figureHeight))
    }

    var shapeSlept: CGPoint { CGPoint(x: max(64, figure.minX + 10), y: figure.minY + figure.height * 0.74) }
    var shapeSteps: CGPoint { CGPoint(x: min(width - 64, figure.maxX - 10), y: figure.minY + figure.height * 0.86) }
    var shapeHRV: CGPoint { CGPoint(x: width / 2, y: figure.maxY + 34) }

    struct Placed {
        let dot: CGPoint
        let label: CGPoint
        let anchor: CGPoint
        let left: Bool
    }

    /// Readings go left or right of the face, never over it, spaced at least 44 pt apart on each side.
    func labels(for dots: [VitalKey: CGPoint], faceCenterX: CGFloat) -> [VitalKey: Placed] {
        var out: [VitalKey: Placed] = [:]
        let points = dots.mapValues { CGPoint(x: figure.minX + $0.x * figure.width, y: figure.minY + $0.y * figure.height) }
        for left in [true, false] {
            let side = dots.filter { ($0.value.x < faceCenterX) == left }.sorted { $0.value.y < $1.value.y }
            var lastY = -CGFloat.infinity
            for (key, _) in side {
                let p = points[key]!
                let y = max(p.y, lastY + 44)
                lastY = y
                let cx = left ? Self.labelWidth / 2 + 2 : width - Self.labelWidth / 2 - 2
                let ax = left ? Self.labelWidth + 6 : width - Self.labelWidth - 6
                out[key] = Placed(dot: p, label: CGPoint(x: cx, y: y), anchor: CGPoint(x: ax, y: y), left: left)
            }
        }
        return out
    }
}

private struct VitalDot: View {
    let color: Color
    let pulse: Double
    let key: VitalKey

    var body: some View {
        ZStack {
            Circle().fill(color.opacity(key == .breathing ? 0.16 + 0.18 * pulse : 0.22))
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

/// A dashed path through the day with a pebble per timeline event.
struct TodayPath: View {
    let timeline: Summary.Timeline
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        let events = Array(timeline.events.sorted { $0.start < $1.start }.suffix(5))
        VStack(alignment: .leading, spacing: 8) {
            Text(timeline.date == dashboard.summary?.today ? "Today's path" : "The day's path").font(.headline).foregroundStyle(Palette.ink)
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
                            Button { open(e) } label: {
                                VStack(spacing: 4) {
                                    Circle().fill(TimelineCard.color(e.kind))
                                        .overlay(Circle().stroke(Palette.surface, lineWidth: 2))
                                        .frame(width: 16, height: 16)
                                    Text(e.title).font(.caption2.weight(.semibold)).foregroundStyle(Palette.ink).lineLimit(1)
                                    Text(Fmt.clock(e.start)).font(.caption2).monospacedDigit().foregroundStyle(Palette.ink3)
                                }
                                .frame(width: 72, height: 64)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .position(x: point(i).x, y: point(i).y + 24)
                            .accessibilityLabel("\(e.title), \(Fmt.clock(e.start)) to \(Fmt.clock(e.end))")
                        }
                    }
                }
                .frame(height: 96)
            }
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
