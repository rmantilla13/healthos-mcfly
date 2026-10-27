import SwiftUI

/// The bottom row a floating control sits in (Ask McFly's pill): trailing, or leading when duoBarEdge == .leading;
/// never centred. Its own scope: it reads the fold and the active occlusions around it, and stays below an active
/// horizontal fold and clear of an active occlusion by the smallest move. It adds no padding of its own: put the
/// control's padding inside it, as AskMcFlyEntry pads its pill.
///
///     .safeAreaInset(edge: .bottom) {
///         DuoFloatingRow { AskMcFlyPill { … } }
///             .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 10)
///     }
struct DuoFloatingRow<Content: View>: View {
    private let content: Content
    @Environment(\.duoDisplayOverride) private var display
    @State private var around = Around()
    @State private var size = CGSize.zero

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    /// What's around the row, in its own coordinates.
    struct Around: Equatable {
        var size = CGSize.zero
        var occlusions: [CGRect] = []
        var fold: CGRect?
        var foldActive = false
    }

    var body: some View {
        DuoBarEdgeReader { systemEdge in
            let barEdge = display != nil ? display?.barEdge : systemEdge
            let edge = Self.edge(barEdge: barEdge)
            content
                .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
                .offset(Self.move(control: Self.place(size, in: around.size, edge: edge), occlusions: around.occlusions,
                                  fold: around.foldActive ? around.fold : nil))
                .frame(maxWidth: .infinity, alignment: edge == .leading ? .leading : .trailing)
                .onGeometryChange(for: Around.self) { proxy in read(proxy, barEdge: barEdge) } action: { around = $0 }
                .environment(\.duoBarEdge, barEdge)
        }
    }

    private func read(_ proxy: GeometryProxy, barEdge: HorizontalEdge?) -> Around {
        if let display {
            let frame = proxy.frame(in: .global)
            return Around(size: proxy.size, occlusions: display.occlusions(in: frame), fold: display.horizontalFold(in: frame),
                          foldActive: display.foldActive)
        }
        let reading = DuoSystemReading.read(proxy, barEdge: barEdge, occlusions: true)
        return Around(size: proxy.size, occlusions: reading.occlusions, fold: reading.horizontalFold, foldActive: reading.horizontalFoldActive)
    }

    /// Trailing, unless the bar is on the leading edge (then leading): never centred (O4).
    static func edge(barEdge: HorizontalEdge?) -> HorizontalEdge { barEdge == .leading ? .leading : .trailing }

    /// The control's frame in a row `row` big, at `edge`.
    static func place(_ size: CGSize, in row: CGSize, edge: HorizontalEdge) -> CGRect {
        CGRect(x: edge == .leading ? 0 : max(0, row.width - size.width), y: max(0, (row.height - size.height) / 2),
               width: size.width, height: size.height)
    }

    /// How far to move the control: below an active horizontal fold it meets, then clear of each active occlusion it
    /// meets by the smallest move up, left or right (never down, off the bottom of the screen).
    static func move(control: CGRect, occlusions: [CGRect], fold: CGRect?) -> CGSize {
        var at = control
        if let fold, at.minY < fold.maxY, at.maxY > fold.minY - DuoFold.clearance {
            at.origin.y = fold.maxY
        }
        for occlusion in occlusions where at.intersects(occlusion) {
            let up = occlusion.minY - at.maxY
            let left = occlusion.minX - at.maxX
            let right = occlusion.maxX - at.minX
            let best = [CGSize(width: 0, height: up), CGSize(width: left, height: 0), CGSize(width: right, height: 0)]
                .min { hypot($0.width, $0.height) < hypot($1.width, $1.height) } ?? .zero
            at = at.offsetBy(dx: best.width, dy: best.height)
        }
        return CGSize(width: at.minX - control.minX, height: at.minY - control.minY)
    }
}
