import SwiftUI
import UIKit

// Home's photo figure (src/components/Figure.tsx PhotoFigure): your own cut-out with the web's fade, revealed through a
// short ASCII sweep once per launch, its callouts pinned to the points Vision found and their labels in the page space
// beside the silhouette, measured from its outline. Then the levels the dots and words share, and Today's timeline.

// MARK: - The photo

/// Where each callout's label goes on a photo (Figure.tsx photoLayout, spo2Dot and placeLabels), all in 0–1 of the
/// cut-out: blood oxygen's dot derived on the shoulder line, each label on its side, as close to its dot's height as the
/// silhouette leaves room for, below the label above it on that side.
enum PhotoLabels {
    struct Slot: Equatable {
        let key: CalloutKey
        let left: Bool
        /// The label may sit over the photo's faded bottom (a wrist reading).
        var overFade = false
    }

    /// A label's box: on the left `x` is its right edge, on the right its left edge.
    struct Placed: Equatable {
        let key: CalloutKey
        let left: Bool
        let x: Double
        let y: Double
        let w: Double
        let h: Double
    }

    /// The photo fades out toward the bottom; from here down it's faint enough to write over.
    static let fadedFrom = 0.8
    /// A label before it's been measured (Figure.tsx's starting sizes), in points.
    static let estimated: [CalloutKey: CGSize] = [.temp: CGSize(width: 110, height: 64), .breathing: CGSize(width: 100, height: 64),
                                                  .heart: CGSize(width: 100, height: 64), .spo2: CGSize(width: 110, height: 64)]

    /// The face box [x, y, w, h], or a centred one for metadata without it.
    static func face(_ photo: PhotoMeta) -> [Double] {
        if let f = photo.face, f.count == 4 { return f }
        return [0.35, 0.05, 0.3, 0.3]
    }

    /// Where the shoulders are. Older servers don't send it: the cut-out tool puts them a tenth of the face's height
    /// below the neck, which is about the face's bottom (server/photo/cutout.swift), so the same from the face box.
    static func shoulderY(_ photo: PhotoMeta) -> Double {
        if let y = photo.shoulderY { return y }
        let f = face(photo)
        return min(1, f[1] + f[3] * 1.1)
    }

    static func point(_ p: [Double]?) -> CGPoint? {
        guard let p, p.count == 2 else { return nil }
        return CGPoint(x: p[0], y: p[1])
    }

    /// Blood oxygen's dot: on the shoulder line (just under shoulderY), on the side opposite the heart dot. Photos carry
    /// no such point, so it's derived: the chest dot mirrored across the throat, then a third of the way on toward the
    /// outline's edge on that row (Figure.tsx spo2Dot).
    static func spo2Dot(_ photo: PhotoMeta) -> CGPoint? {
        guard let b = point(photo.dots?.breathing), let h = point(photo.dots?.heart) else { return nil }
        let y = min(1, shoulderY(photo) + 0.03)
        let mirrored = 2 * b.x - h.x
        let toLeft = mirrored <= b.x
        let row = photo.outline.flatMap { o in o.count == 100 ? o[min(99, max(0, Int((y * 100).rounded(.down))))] : nil }
        let edge = row.flatMap { r in r.count == 2 && r[0] <= r[1] ? (toLeft ? r[0] : r[1]) : nil } ?? mirrored + (toLeft ? -0.15 : 0.15)
        return CGPoint(x: mirrored + (edge - mirrored) * 0.35, y: y)
    }

    /// Each callout's dot; nil when the photo's metadata lacks them (the digital human stands in then).
    static func dots(_ photo: PhotoMeta) -> [CalloutKey: CGPoint]? {
        guard let t = point(photo.dots?.temp), let b = point(photo.dots?.breathing), let h = point(photo.dots?.heart), let s = spo2Dot(photo) else { return nil }
        return [.temp: t, .breathing: b, .heart: h, .spo2: s]
    }

    /// Which side each label goes, top to bottom by their dots, so leader lines never cross. With blood oxygen (Home's
    /// set), its label and heart's go on the left and breathing's on the right, as designed.
    static func slots(_ dots: [CalloutKey: CGPoint], callouts: [CalloutKey]) -> [Slot] {
        let withSpo2 = callouts.contains(.spo2)
        let all = [Slot(key: .temp, left: true), Slot(key: .breathing, left: !withSpo2), Slot(key: .heart, left: withSpo2), Slot(key: .spo2, left: true)]
        return all.filter { callouts.contains($0.key) }.sorted { (dots[$0.key]?.y ?? 0) < (dots[$1.key]?.y ?? 0) }
    }

    /// The silhouette by row, [left, right]; [1, 0] where empty. Older metadata has no outline: the face is the obstacle
    /// above the shoulders and everything below is body.
    static func outline(_ photo: PhotoMeta) -> [[Double]] {
        if let o = photo.outline, o.count == 100, o.allSatisfy({ $0.count == 2 }) { return o }
        let f = face(photo), shoulder = shoulderY(photo)
        return (0..<100).map { i in
            let y = (Double(i) + 0.5) / 100
            if y >= shoulder - 0.04 { return [0, 1] }
            return y >= f[1] - f[3] * 0.15 ? [f[0] - f[2] * 0.1, f[0] + f[2] * 1.1] : [1, 0]
        }
    }

    /// Each label in empty page space beside the silhouette, as close as possible (vertically) to its dot
    /// (Figure.tsx placeLabels). `sizes` are the labels' measured sizes, and the figure's, in points.
    static func place(photo: PhotoMeta, dots: [CalloutKey: CGPoint], slots: [Slot], sizes: [CalloutKey: CGSize], width: Double, height: Double) -> [Placed] {
        let outline = outline(photo)
        func rows(_ top: Double, _ bottom: Double, _ overFade: Bool) -> [[Double]] {
            let from = max(0, Int((top * 100).rounded(.down)))
            let to = min(100, Int((bottom * 100).rounded(.up)))
            guard from < to else { return [] }
            return (from..<to).map { i in overFade && Double(i) / 100 >= fadedFrom ? [1, 0] : outline[i] }
        }
        let gapX = 12 / width, gapY = 10 / height
        var placed: [Placed] = []
        for slot in slots {
            let size = sizes[slot.key] ?? estimated[slot.key] ?? CGSize(width: 100, height: 64)
            let w = Double(size.width) / width, h = Double(size.height) / height
            guard let dot = dots[slot.key] else { continue }
            let (dotX, dotY) = (Double(dot.x), Double(dot.y))
            // Below the label above it on the same side.
            let above = placed.last { $0.left == slot.left }
            let minTop = above.map { $0.y + $0.h + gapY } ?? 0
            var best: Placed?, bestScore = Double.infinity, widest: Placed?
            func room(_ p: Placed) -> Double { p.left ? p.x - p.w : 1 - (p.x + p.w) }
            var top = minTop
            while top + h <= 1 {
                let span = rows(top, top + h, slot.overFade)
                let x: Double, fits: Bool
                if slot.left {
                    x = min((span.map { $0[0] }.min() ?? .infinity) - gapX, dotX - gapX)
                    fits = x - w >= 0
                } else {
                    x = max((span.map { $0[1] }.max() ?? -.infinity) + gapX, dotX + gapX)
                    fits = x + w <= 1
                }
                let candidate = Placed(key: slot.key, left: slot.left, x: x, y: top, w: w, h: h)
                if widest == nil || room(candidate) > room(widest!) { widest = candidate }
                if fits {
                    let score = abs(top + h / 2 - dotY)
                    if score < bestScore {
                        best = candidate
                        bestScore = score
                    }
                }
                top += 0.005
            }
            // Nowhere free: the roomiest spot, with the label kept inside the figure.
            let p = best ?? widest.map { Placed(key: $0.key, left: $0.left, x: $0.left ? max($0.x, w) : min($0.x, 1 - w), y: $0.y, w: w, h: h) }
                ?? Placed(key: slot.key, left: slot.left, x: 0.5, y: 0, w: w, h: h)
            placed.append(p)
        }
        return placed
    }

    /// Where a leader line meets its label: beside its value line, 6pt off the label's edge toward the body.
    static func lineEnd(_ p: Placed, width: Double, height: Double) -> CGPoint {
        CGPoint(x: (p.x + (p.left ? 6 / width : -6 / width)) * width, y: (p.y + 30 / height) * height)
    }
}

/// The person's own cut-out (Figure.tsx PhotoFigure): the photo's fade and tone, the glow behind it, a light leader
/// line from each dot to its label, and the labels beside the silhouette. The callouts wait for the photo, then fade in.
struct PortraitFigure: View {
    let vitals: Summary.Vitals?
    let asOf: String
    let photo: PhotoMeta
    var units: Units = .metric
    var scrub: HeartScrub?
    var callouts: [CalloutKey] = CalloutKey.home
    var onHeart: (() -> Void)?
    /// The photo couldn't be loaded (or its metadata has no dots): the caller shows the digital human instead.
    var onFailed: (() -> Void)?
    /// Home's figure state, which keeps the cut-out once read, so a fold that rebuilds the figure (the open Duo's panes)
    /// draws it again without reading it again; nil: read on every appearance, as before.
    var kept: HomeFigureState?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.homeReads) private var reads
    @State private var image: UIImage?
    @State private var revealStart: Date?
    @State private var revealed = false
    @State private var cells: RevealCells?
    /// The figure's size as last laid out, for the reveal's glyph grid only (it never sets the layout).
    @State private var size = CGSize(width: 343, height: 457)
    @State private var sizes: [CalloutKey: CGSize] = [:]

    /// The figure is at most 440pt wide on a phone (styles.css .figure at 820px and below).
    static let maxWidth: CGFloat = 440
    private static var played: Set<String> = []

    var body: some View {
        Group {
            if let dots = PhotoLabels.dots(photo) {
                // The photo's own shape sets the figure's size from the width it's given; everything is drawn over it.
                Color.clear
                    .aspectRatio(CGFloat(photo.width / max(1, photo.height)), contentMode: .fit)
                    .frame(maxWidth: Self.maxWidth)
                    .overlay {
                        GeometryReader { geo in
                            let width = geo.size.width, height = geo.size.height
                            let slots = PhotoLabels.slots(dots, callouts: callouts)
                            let placed = PhotoLabels.place(photo: photo, dots: dots, slots: slots, sizes: sizes, width: width, height: height)
                            ZStack(alignment: .topLeading) {
                                glow(width: width, height: height)
                                figure(width: width, height: height)
                                callouts(dots: dots, placed: placed, width: width, height: height)
                                    .opacity(revealed ? 1 : 0)
                                    .animation(reduceMotion ? nil : .easeOut(duration: 0.5), value: revealed)
                            }
                            .frame(width: width, height: height, alignment: .topLeading)
                            .onAppear { size = geo.size }
                            .onChange(of: geo.size) { _, new in size = new }
                        }
                    }
            } else {
                Color.clear.frame(height: 0).onAppear { onFailed?() }
            }
        }
        .frame(maxWidth: .infinity)
        .task(id: "\(photo.versionKey)-\(scheme == .dark)") { await loadPhoto() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("figure-photo")
    }

    private func glow(width: CGFloat, height: CGFloat) -> some View {
        // .figure-glow: radial-gradient(60% 45% at 50% 38%), from 4% above the photo.
        EllipticalGradient(colors: [Palette.figureGlow, Palette.figureGlow.opacity(0)], center: .center, startRadiusFraction: 0, endRadiusFraction: 0.5)
            .frame(width: width * 1.2, height: height * 1.04 * 0.9)
            .position(x: width / 2, y: -height * 0.04 + height * 1.04 * 0.38)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func figure(width: CGFloat, height: CGFloat) -> some View {
        if let image {
            TimelineView(.animation(paused: revealed)) { context in
                let elapsed = revealStart.map { context.date.timeIntervalSince($0) } ?? 99
                let edge = RevealMath.edge(elapsed: elapsed)
                ZStack {
                    Image(uiImage: image)
                        .resizable()
                        .mask(FadeMask())
                        .mask(alignment: .top) {
                            VStack(spacing: 0) {
                                Color.clear.frame(height: max(0, height * edge))
                                Color.black
                            }
                        }
                    if !revealed, let cells {
                        AsciiBand(cells: cells, edge: edge, frame: Int(elapsed * 30), dark: scheme == .dark)
                    }
                }
                .frame(width: width, height: height)
                .onChange(of: edge <= -RevealMath.band) { _, done in if done { revealed = true } }
            }
            .accessibilityLabel("Your photo")
        }
    }

    private func callouts(dots: [CalloutKey: CGPoint], placed: [PhotoLabels.Placed], width: CGFloat, height: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            // Over a photo, leader lines cross hair, skin and page: a light line with a soft dark edge reads on all three.
            Canvas { ctx, _ in
                for p in placed {
                    guard let d = dots[p.key] else { continue }
                    var line = Path()
                    line.move(to: CGPoint(x: d.x * width, y: d.y * height))
                    line.addLine(to: PhotoLabels.lineEnd(p, width: width, height: height))
                    ctx.stroke(line, with: .color(.white.opacity(0.9)), lineWidth: 1.25)
                }
            }
            .shadow(color: .black.opacity(0.45), radius: 1)
            .frame(width: width, height: height)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            ForEach(callouts, id: \.self) { key in
                let text = CalloutText.of(key, vitals: vitals, asOf: asOf, units: units, scrub: scrub)
                if let d = dots[key] {
                    CalloutMark(text: text, halo: 13, dot: 5).position(x: d.x * width, y: d.y * height)
                }
                let p = placed.first { $0.key == key }
                label(text)
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { sizes[key] = $0 }
                    .offset(x: p.map { ($0.left ? $0.x - $0.w : $0.x) * width } ?? 0, y: (p?.y ?? 0) * height)
                    .opacity(p == nil || sizes[key] == nil ? 0 : 1)
            }
        }
    }

    @ViewBuilder private func label(_ text: CalloutText) -> some View {
        if text.key == .heart, let onHeart {
            Button(action: onHeart) { CalloutLabel(text: text).contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .accessibilityLabel(text.spoken)
                .accessibilityHint("Opens live heart rate")
                .accessibilityIdentifier("callout-heart")
        } else {
            CalloutLabel(text: text)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(text.spoken)
                .accessibilityIdentifier("callout-\(text.key.rawValue)")
        }
    }

    private func loadPhoto() async {
        let key = photo.versionKey
        let keptKey = "\(key)|\(scheme == .dark)"
        if let cutout = kept?.cutout, cutout.key == keptKey {
            image = cutout.image
            revealed = true
            return
        }
        guard let img = await reads.readCutout(photo, scheme == .dark) else {
            image = nil
            onFailed?()
            return
        }
        kept?.cutout = (keptKey, img)
        if reduceMotion || Self.played.contains(key) {
            image = img
            revealed = true
            return
        }
        let size = size
        cells = await Task.detached(priority: .userInitiated) { RevealCells(image: img, size: size) }.value
        Self.played.insert(key)
        revealed = false
        image = img
        revealStart = Date()
        // Backstop: the band can't stay up if the timeline stops ticking (e.g. the screen goes away).
        try? await Task.sleep(for: .seconds(RevealMath.duration + 0.2))
        revealed = true
    }
}

// MARK: - Levels

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
    /// one shown stays neutral (its date shows instead), so last week's number never alarms today's figure.
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
        // A dot with no level yet: the figure's gold (styles.css --level-none: var(--callout-dot)).
        case .neutral: Palette.calloutDot
        }
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
            // The reveal's characters sit on a monospaced grid, so they stay in the system face.
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

// MARK: - Today's timeline

/// Home's optional timeline card (Home.tsx TimelineCard): a readout of one moment, the day's 24-hour track to scrub
/// through it (TimelineScrub.swift), and the last four events with where each stands. Today runs from 00:00 to now; a
/// past day runs the whole day. While the marker is off live, the figure's heart shows that hour.
struct TodayPath: View {
    let timeline: Summary.Timeline
    /// The marker and the heart at it, shared with the figure through Home.
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

    /// "Today's timeline", or "Timeline · Fri, Oct 23" for another day.
    static func title(date: String, today: String) -> String {
        date == today ? "Today's timeline" : "Timeline · \(Fmt.day(date, "EEEMMMd"))"
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
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(Self.title(date: timeline.date, today: today))
                        .font(.app(size: 15, weight: .medium, relativeTo: .subheadline)).foregroundStyle(Palette.ink)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    // Back to the resting position; hidden while there.
                    Button { withAnimation(TimelineScrub.motion(.easeOut(duration: 0.25), reduceMotion: reduceMotion)) { scrub = nil } } label: {
                        Text(isToday ? "Now" : "End of day")
                    }
                    .buttonStyle(.quietPill(size: .compact))
                    .opacity(live ? 0 : 1)
                    .disabled(live)
                    .accessibilityHidden(live)
                    .accessibilityHint(isToday ? "Moves the timeline marker back to now" : "Moves the timeline marker back to the end of the day")
                    .accessibilityIdentifier("timeline-live")
                }
                .padding(.bottom, 14)
                TimelineScrubber(events: events, date: timeline.date, isToday: isToday, day: hours,
                                 answered: load.answered(timeline.date), failed: load.failed(timeline.date),
                                 upper: upper, moment: moment, scrub: scrubBinding)
                list(timeline.events, current: Set(moment.events.map(\.id)), isToday: isToday, now: HomeTimelineCard.localNow(context.date))
                    .padding(.top, 6)
            }
            .card()
            // The figure's heart follows the marker while it's off live (web Home.tsx onHeart), and again on coming
            // back to Home with a moment still held.
            .onAppear { scrubbed.follow(HeartScrub.from(moment, live: live, date: timeline.date)) }
            .onChange(of: HeartScrub.from(moment, live: live, date: timeline.date)) { _, heart in scrubbed.follow(heart) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("card-home.timeline")
        .task(id: "\(timeline.date)|\(dashboard.generation)") { await fetchDay() }
        // A new day starts live, and the figure goes back to the resting rate with it.
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

    /// The day's last four events (.tl-list): each one's colour, name and times, and Completed, In progress or
    /// Upcoming; the ones at the marker stand out.
    @ViewBuilder
    private func list(_ events: [TimelineEvent], current: Set<String>, isToday: Bool, now: String) -> some View {
        if events.isEmpty {
            Text("Nothing recorded for this day.").font(.app(.footnote)).foregroundStyle(Palette.ink3).padding(.top, 6)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(events.suffix(4)) { e in
                    let state = HomeTimelineCard.state(e, isToday: isToday, now: now)
                    HStack(spacing: 12) {
                        Circle().fill(HomeTimelineCard.color(e.kind)).frame(width: 10, height: 10)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.title).font(.app(.subheadline, weight: .medium)).foregroundStyle(Palette.ink)
                            Text("\(Fmt.clock(e.start)) – \(Fmt.clock(e.end))\(e.detail.map { " · \($0)" } ?? "")")
                                .font(.app(.caption)).foregroundStyle(Palette.ink3)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Text(state)
                            .font(.app(.caption, weight: state == "In progress" ? .medium : .regular))
                            .foregroundStyle(state == "In progress" ? Palette.series1 : Palette.ink3)
                    }
                    .background {
                        if current.contains(e.id) {
                            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.surfaceHover).padding(-6)
                        }
                    }
                    .animation(TimelineScrub.motion(.easeOut(duration: 0.15), reduceMotion: reduceMotion), value: current.contains(e.id))
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(e.title), \(Fmt.clock(e.start)) to \(Fmt.clock(e.end))\(e.detail.map { ", \($0)" } ?? ""), \(state)")
                }
            }
            .padding(.top, 6)
        }
    }
}
