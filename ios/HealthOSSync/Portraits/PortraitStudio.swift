import PhotosUI
import SwiftUI

/// The portrait studio (src/components/portraits/PortraitStudio.tsx), in Profile → Your portrait photos: reference
/// photos of you, and likenesses made from them in the healthOS style on OpenAI, one at a time. A reference stays
/// private: only you can open it, and it goes to OpenAI only when you make a portrait from it. Nothing made here reaches
/// the dashboard until "Use this portrait", which cuts it out on this iPhone and saves it as your profile photo.
struct PortraitStudio: View {
    let model: PortraitStudioModel
    @Environment(Dashboard.self) private var dashboard
    @Environment(\.profileCardsKeep) private var keep
    /// Its dialogs, picker and camera when the page keeps none (`profileCards(_:)`).
    @State private var ownAsks = PortraitAsks()

    var body: some View {
        let asks = keep?.asks ?? ownAsks
        PortraitStudioContent(
            model: model,
            byok: dashboard.availability.byok,
            ownKey: dashboard.availability.ai.value?.key("openai") != nil,
            add: { asks.add(camera: UIImagePickerController.isSourceTypeAvailable(.camera)) },
            make: { ref in Task { await model.make(from: ref) } },
            delete: { asks.deleting = $0 },
            use: { p in
                if dashboard.status?.photo != nil { asks.replacing = p } else { Task { await model.use(p) } }
            },
            asks: asks)
            .task { await dashboard.loadAI() }
            .task(id: model.making) { await model.poll() }
            .sensoryFeedback(.success, trigger: model.successes)
            // What the web's role="alert" and role="status" lines read out: a refusal, a failed Use, Use's steps, one
            // being made.
            .onChange(of: model.spoken) { _, spoken in spoken?.post() }
            // The picker and the camera: here, unless the page presents them from above its panes.
            .modifier(OwnPickers(asks: keep == nil ? ownAsks : nil, model: model))
    }
}

/// The studio's photo picker and camera on the studio itself, for a page without a keep.
private struct OwnPickers: ViewModifier {
    let asks: PortraitAsks?
    let model: PortraitStudioModel

    func body(content: Content) -> some View {
        if let asks {
            content.portraitPickers(asks) { [model] in model }
        } else {
            content
        }
    }
}

/// What the studio shows for its model (no dashboard needed, so tests can draw it): the head, the notes, each
/// reference photo as a row with the portraits made from it as tiles beneath, and those whose reference is gone.
struct PortraitStudioContent: View {
    let model: PortraitStudioModel
    /// Keys can be stored on this server (nil: not known yet).
    let byok: Bool?
    /// The person connected their own OpenAI key.
    let ownKey: Bool
    var add: () -> Void = {}
    var make: (Portrait) -> Void = { _ in }
    var delete: (Portrait) -> Void = { _ in }
    var use: (Portrait) -> Void = { _ in }
    /// The studio's questions, each shown on the button that asked (P10); nil draws without them (tests).
    var asks: PortraitAsks? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            head
            if let keyNote = model.keyNote(byok: byok) {
                Text(keyNote)
                    .font(.app(size: 12.5, relativeTo: .footnote))
                    .foregroundStyle(ColorToken.badgePeachInk.color)
                    .lineSpacing(2)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(ColorToken.badgePeachBg.color, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("portraits.keyNote")
            }
            if model.full { Text(PortraitWords.full).font(.app(size: 12, relativeTo: .caption)).foregroundStyle(Palette.ink3) }
            if let note = model.note { BadNote(text: note) }
            if let error = model.loadError, model.list == nil { BadNote(text: PortraitWords.loadFailed(error), icon: false) }
            if model.list != nil, model.references.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "camera").font(.system(size: 18)).accessibilityHidden(true)
                    Text(PortraitWords.empty).font(.app(size: 12.5, relativeTo: .footnote)).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Palette.ink3)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.surface2, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
            }
            if !model.references.isEmpty {
                VStack(spacing: 0) {
                    ForEach(model.references) { ref in
                        ReferenceRow(model: model, ref: ref, byok: byok, make: make, delete: delete, use: use, asks: asks)
                            .padding(.top, 14)
                            .padding(.bottom, ref.id == model.references.last?.id ? 0 : 14)
                            .overlay(alignment: .top) { Hairline() }
                    }
                }
            }
            if !model.orphans.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Text(PortraitWords.orphans)
                        .font(.app(size: 12.5, weight: .medium, relativeTo: .footnote))
                        .foregroundStyle(Palette.ink3)
                        .accessibilityAddTraits(.isHeader)
                    TileGrid(model: model, portraits: model.orphans, use: use, delete: delete, asks: asks).padding(.top, 14)
                }
                .padding(.top, 14)
                .overlay(alignment: .top) { Hairline() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The title and its line, with the add pill under them (the web's phone layout).
    private var head: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(PortraitWords.title)
                    .font(.app(size: 14, weight: .medium, relativeTo: .subheadline))
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(PortraitWords.intro(canGenerate: model.canGenerate, ownKey: ownKey))
                    .font(.app(size: 12.5, relativeTo: .footnote))
                    .foregroundStyle(Palette.ink3)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(action: add) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: "plus").imageScale(.small).accessibilityHidden(true)
                    PillText(model.busy == "add" ? PortraitWords.adding : PortraitWords.add)
                }
            }
            .buttonStyle(.quietPill(size: .compact))
            .disabled(model.full || model.locked)
            .accessibilityIdentifier("portraits.add")
            .modifier(AddSourceDialog(asks: asks))
        }
    }
}

/// One reference photo: its thumbnail, when it was added and how many portraits came from it, Make my portrait and
/// Delete, then those portraits.
private struct ReferenceRow: View {
    let model: PortraitStudioModel
    let ref: Portrait
    let byok: Bool?
    let make: (Portrait) -> Void
    let delete: (Portrait) -> Void
    let use: (Portrait) -> Void
    let asks: PortraitAsks?
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let fromIt = model.made(from: ref)
        let keyNote = model.keyNote(byok: byok)
        VStack(alignment: .leading, spacing: 0) {
            let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout(spacing: 14))
            layout {
                thumbnail
                VStack(alignment: .leading, spacing: 4) {
                    Text(PortraitWords.reference)
                        .font(.app(size: 14, weight: .medium, relativeTo: .subheadline))
                        .foregroundStyle(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(PortraitWords.referenceLine(ref, made: fromIt.count))
                        .font(.app(size: 12.5, relativeTo: .footnote))
                        .foregroundStyle(Palette.ink3)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
            let actions = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6)) : AnyLayout(HStackLayout(spacing: 6))
            actions {
                Button { make(ref) } label: { PillText(model.isMaking(from: ref) ? PortraitWords.makingShort : PortraitWords.makeMine) }
                    .buttonStyle(.quietPill(size: .compact))
                    .disabled(!model.canMake)
                    .accessibilityHint(keyNote ?? (model.making ? PortraitWords.oneAtATime : ""))
                    .accessibilityIdentifier("portraits.make.\(ref.id)")
                Button(PortraitWords.delete) { delete(ref) }
                    .buttonStyle(QuietTextStyle())
                    .disabled(model.locked)
                    .accessibilityLabel(PortraitWords.deleteReferenceLabel(ref))
                    .accessibilityIdentifier("portraits.delete.\(ref.id)")
                    .modifier(DeleteDialog(asks: asks, model: model, p: ref))
            }
            .padding(.top, 10)
            .padding(.leading, typeSize.isAccessibilitySize ? 0 : 68)
            if !fromIt.isEmpty {
                TileGrid(model: model, portraits: fromIt, use: use, delete: delete, asks: asks).padding(.top, 14)
            }
        }
    }

    private var thumbnail: some View {
        ZStack {
            Palette.surface2
            if let image = model.thumbs[ref.id] {
                Image(uiImage: image).resizable().scaledToFill()
            }
        }
        .frame(width: 54, height: 70)
        .clipShape(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
        .accessibilityElement()
        .accessibilityLabel(PortraitWords.referenceLabel(ref))
        .accessibilityAddTraits(.isImage)
        .task(id: ref.status) { await model.loadThumbnail(ref, maxPixel: 240) }
    }
}

/// Portraits as tiles, two to a row on the phone (one at the largest text sizes), more where the card is wider
/// (PortraitTileColumns); the tiles in a row as tall as each other, their buttons along the bottom, as the web's grid
/// lines them up.
private struct TileGrid: View {
    let model: PortraitStudioModel
    let portraits: [Portrait]
    let use: (Portrait) -> Void
    let delete: (Portrait) -> Void
    let asks: PortraitAsks?
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.duoBand) private var band

    var body: some View {
        let accessibility = typeSize.isAccessibilitySize
        CardColumnsLayout(spacing: PortraitTileColumns.spacing) { [band] width in
            PortraitTileColumns.count(width: width, band: band, accessibility: accessibility)
        } {
            ForEach(portraits) { p in
                PortraitTile(model: model, p: p, use: use, delete: delete, asks: asks).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// One portrait: ready (its image, and Use this portrait unless it's the one in use), being made (a slow sheen), or
/// failed (the server's reason); with what Use is doing, or why it couldn't.
private struct PortraitTile: View {
    let model: PortraitStudioModel
    let p: Portrait
    let use: (Portrait) -> Void
    let delete: (Portrait) -> Void
    let asks: PortraitAsks?

    var body: some View {
        let chosen = p.id == model.chosen
        let using = model.using?.id == p.id ? model.using?.step : nil
        let failed = model.failed?.id == p.id ? model.failed?.text : nil
        VStack(alignment: .leading, spacing: 0) {
            art(chosen: chosen)
            VStack(alignment: .leading, spacing: 8) {
                if p.status == "pending" { state(PortraitWords.pending) }
                if p.status == "failed" { state(PortraitWords.failure(p), bad: true) }
                if let using { state(using) }
                if let failed { state(failed, bad: true) }
                // Its dialogs on the row of buttons (both of its candidates are the one place they show).
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 4) { actions(chosen: chosen, using: using != nil) }
                    VStack(alignment: .leading, spacing: 4) { actions(chosen: chosen, using: using != nil) }
                }
                .modifier(DeleteDialog(asks: asks, model: model, p: p))
                .modifier(ReplaceDialog(asks: asks, model: model, p: p))
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .background(Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(chosen ? Palette.choiceBorder : Palette.border))
    }

    @ViewBuilder
    private func actions(chosen: Bool, using: Bool) -> some View {
        if p.status == "ready", !chosen {
            Button { use(p) } label: { PillText(using ? PortraitWords.usingShort : PortraitWords.useThis, size: TilePillStyle.size) }
                .buttonStyle(TilePillStyle())
                .disabled(model.locked)
                .accessibilityIdentifier("portraits.use.\(p.id)")
        }
        Button(PortraitWords.delete) { delete(p) }
            .buttonStyle(QuietTextStyle(height: 30))
            .disabled(model.locked)
            .accessibilityLabel(PortraitWords.deletePortraitLabel(p))
            .accessibilityIdentifier("portraits.deletePortrait.\(p.id)")
    }

    /// The 2:3 picture: the portrait on the cream wash, the sheen while it's made, or the alert where it failed.
    private func art(chosen: Bool) -> some View {
        Color.clear
            .aspectRatio(2 / 3, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .background {
                ZStack {
                    switch TileArt.wash(p.status) {
                    case .cream: GradientFill(.gradCream)
                    case .failed: Palette.surface2
                    }
                    // .portrait-making: the sheen moves over the tile's own cream.
                    if p.status == "pending" { PortraitSheen() }
                }
            }
            .overlay {
                if p.status == "ready" {
                    Group {
                        if let image = model.thumbs[p.id] { Image(uiImage: image).resizable().scaledToFit() } else { Color.clear }
                    }
                    .accessibilityElement()
                    .accessibilityLabel(PortraitWords.portraitLabel(p))
                    .accessibilityAddTraits(.isImage)
                } else if p.status != "pending" {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 20))
                        .foregroundStyle(ColorToken.badgeBadInk.color)
                        .accessibilityHidden(true)
                }
            }
            .overlay(alignment: .topLeading) {
                if chosen { Badge(PortraitWords.inUse, tone: .sage).padding(8) }
            }
            .clipped()
            // Its full 2:3 first; the words and buttons under it take what's left of the row's height.
            .layoutPriority(1)
            .task(id: p.status) { await model.loadThumbnail(p, maxPixel: 600) }
    }

    private func state(_ text: String, bad: Bool = false) -> some View {
        Text(text)
            .font(.app(size: 12, relativeTo: .caption))
            .foregroundStyle(bad ? ColorToken.badgeBadInk.color : Palette.ink2)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Add's question, on the add pill: choose a photo or take one.
private struct AddSourceDialog: ViewModifier {
    let asks: PortraitAsks?

    func body(content: Content) -> some View {
        if let asks {
            @Bindable var asks = asks
            content.confirmationDialog(PortraitWords.add, isPresented: $asks.askSource, titleVisibility: .hidden) {
                Button("Choose a photo") { asks.pickerShown = true }
                Button("Take a photo") { asks.cameraShown = true }
                Button("Cancel", role: .cancel) {}
            }
        } else {
            content
        }
    }
}

/// Delete's question for one reference or portrait, on its own Delete (P10).
private struct DeleteDialog: ViewModifier {
    let asks: PortraitAsks?
    let model: PortraitStudioModel
    let p: Portrait

    func body(content: Content) -> some View {
        if let asks {
            content.confirmationDialog(PortraitWords.deleteQuestion(p, chosen: model.chosen),
                                       isPresented: Binding(get: { asks.deleting?.id == p.id },
                                                            set: { if !$0, asks.deleting?.id == p.id { asks.deleting = nil } }),
                                       titleVisibility: .visible, presenting: asks.deleting) { p in
                Button(PortraitWords.delete, role: .destructive) { Task { await model.delete(p) } }
                Button("Cancel", role: .cancel) {}
            }
        } else {
            content
        }
    }
}

/// "Replace your photo?" for one portrait, on its Use this portrait.
private struct ReplaceDialog: ViewModifier {
    let asks: PortraitAsks?
    let model: PortraitStudioModel
    let p: Portrait

    func body(content: Content) -> some View {
        if let asks {
            content.confirmationDialog(PortraitWords.replacePhoto,
                                       isPresented: Binding(get: { asks.replacing?.id == p.id },
                                                            set: { if !$0, asks.replacing?.id == p.id { asks.replacing = nil } }),
                                       titleVisibility: .visible, presenting: asks.replacing) { p in
                Button(PortraitWords.useThis) { Task { await model.use(p) } }
                Button("Cancel", role: .cancel) {}
            }
        } else {
            content
        }
    }
}

/// A tile picture's own wash (.portrait-tile-art): the cream, for a portrait ready or being made alike; surface-2 for
/// one that failed (.portrait-tile.is-failed).
enum TileArt: Equatable {
    case cream, failed

    static func wash(_ status: String) -> TileArt { status == "failed" ? .failed : .cream }
}

/// Being made: a slow sheen across the tile's cream (the web's transparent gradient over it); with Reduce Motion, a
/// still wash of surface-hover over the whole picture instead.
private struct PortraitSheen: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var moved = false

    var body: some View {
        GeometryReader { geo in
            if reduceMotion {
                Palette.surfaceHover
            } else {
                LinearGradient(stops: [.init(color: .clear, location: 0.3), .init(color: Palette.surfaceHover, location: 0.5), .init(color: .clear, location: 0.7)],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: geo.size.width * 2.5)
                    .offset(x: moved ? -geo.size.width * 2.5 : geo.size.width)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: false)) { moved = true }
                    }
            }
        }
        .clipped()
        .accessibilityHidden(true)
    }
}

/// .note-bad: an alert in the critical colour.
struct BadNote: View {
    let text: String
    var icon = true

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if icon { Image(systemName: "exclamationmark.triangle").imageScale(.small).accessibilityHidden(true) }
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.app(size: 13, relativeTo: .footnote))
        .foregroundStyle(Palette.critical)
        .accessibilityElement(children: .combine)
    }
}

/// A hairline above a row (border-top: 1px var(--border)).
struct Hairline: View {
    var body: some View { Palette.border.frame(height: 1).accessibilityHidden(true) }
}

/// The web's quiet button (.btn-quiet): ink-3 words on nothing, ink while pressed.
struct QuietTextStyle: ButtonStyle {
    var height: CGFloat = 34
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.dynamicTypeSize) private var typeSize

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.app(size: 13, weight: .medium, relativeTo: .footnote))
            .foregroundStyle(configuration.isPressed ? Palette.ink : Palette.ink3)
            .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
            .padding(.horizontal, 8)
            .frame(minHeight: height)
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.5)
    }
}

/// A tile's primary button (.portrait-tile-actions .btn-primary): the forest pill, a little smaller, so it fits half
/// a phone's width.
private struct TilePillStyle: ButtonStyle {
    /// .portrait-tile-actions .btn: 12.5 px.
    static let size: CGFloat = 12.5
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.app(size: Self.size, weight: .medium, relativeTo: .footnote))
            .foregroundStyle(Palette.accentInk)
            .padding(.horizontal, 12)
            .frame(minHeight: 30)
            .background { GradientFill(configuration.isPressed ? .accentGradHover : .accentGrad).clipShape(Capsule()) }
            .tokenShadow(.pill, in: Capsule())
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.5)
    }
}

/// A pill's words: one line, as the web's, when they fit; else a little smaller (not at the accessibility text sizes,
/// where they stay as large as asked for); else wrapped onto more lines at the spaces between words, the pill growing
/// to fit. Never cut off. `size` is the size the pill's style sets (a compact pill's footnote, a tile's 12.5), for the
/// smaller step.
struct PillText: View {
    let text: String
    var size: CGFloat
    @Environment(\.dynamicTypeSize) private var typeSize

    /// How much smaller the second try is.
    static let smaller: CGFloat = 0.85

    init(_ text: String, size: CGFloat = AppFont.size(.footnote)) {
        self.text = text
        self.size = size
    }

    var body: some View {
        let large = typeSize.isAccessibilitySize
        ViewThatFits(in: .horizontal) {
            line(nil)
            // A stack lays a pill out a fraction of a point narrower than it asked for (rounded to the screen's
            // pixels): the same line again, measured a point narrower each side, so that never makes it shrink or wrap.
            line(nil).padding(.horizontal, -1)
            if !large {
                line(size * Self.smaller)
                line(size * Self.smaller).padding(.horizontal, -1)
            }
            Text(text)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, large ? 0 : 6)
        }
        .multilineTextAlignment(.center)
        .padding(.vertical, large ? 6 : 0)
    }

    /// The words on one line, in the pill's own font or at `smaller` points.
    @ViewBuilder
    private func line(_ smaller: CGFloat?) -> some View {
        if let smaller {
            Text(text).lineLimit(1).font(.app(size: smaller, weight: .medium, relativeTo: .footnote))
        } else {
            Text(text).lineLimit(1)
        }
    }
}
