import PhotosUI
import SwiftUI

/// The portrait studio (src/components/portraits/PortraitStudio.tsx), in Profile → Your portrait photos: reference
/// photos of you, and likenesses made from them in the healthOS style on OpenAI, one at a time. A reference stays
/// private: only you can open it, and it goes to OpenAI only when you make a portrait from it. Nothing made here reaches
/// the dashboard until "Use this portrait", which cuts it out on this iPhone and saves it as your profile photo.
struct PortraitStudio: View {
    let model: PortraitStudioModel
    @Environment(Dashboard.self) private var dashboard
    @State private var askSource = false
    @State private var pickerShown = false
    @State private var picked: PhotosPickerItem?
    @State private var cameraShown = false
    @State private var deleting: Portrait?
    @State private var replacing: Portrait?

    var body: some View {
        PortraitStudioContent(
            model: model,
            byok: dashboard.availability.byok,
            ownKey: dashboard.availability.ai.value?.key("openai") != nil,
            add: addPhoto,
            make: { ref in Task { await model.make(from: ref) } },
            delete: { deleting = $0 },
            use: { p in
                if dashboard.status?.photo != nil { replacing = p } else { Task { await model.use(p) } }
            })
            .task { await dashboard.loadAI() }
            .task(id: model.making) { await model.poll() }
            .sensoryFeedback(.success, trigger: model.successes)
            .confirmationDialog(PortraitWords.add, isPresented: $askSource, titleVisibility: .hidden) {
                Button("Choose a photo") { pickerShown = true }
                Button("Take a photo") { cameraShown = true }
                Button("Cancel", role: .cancel) {}
            }
            .photosPicker(isPresented: $pickerShown, selection: $picked, matching: .images, photoLibrary: .shared())
            .onChange(of: picked) { _, item in
                guard let item else { return }
                picked = nil
                Task { await addPicked(item) }
            }
            .fullScreenCover(isPresented: $cameraShown) {
                CameraPicker { image in
                    cameraShown = false
                    guard let image else { return }
                    Task { await model.add { PhotoPipeline.reference(image) } }
                }
                .ignoresSafeArea()
            }
            .confirmationDialog(deleting.map { PortraitWords.deleteQuestion($0, chosen: model.chosen) } ?? "",
                                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible, presenting: deleting) { p in
                Button(PortraitWords.delete, role: .destructive) { Task { await model.delete(p) } }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog(PortraitWords.replacePhoto,
                                isPresented: Binding(get: { replacing != nil }, set: { if !$0 { replacing = nil } }),
                                titleVisibility: .visible, presenting: replacing) { p in
                Button(PortraitWords.useThis) { Task { await model.use(p) } }
                Button("Cancel", role: .cancel) {}
            }
    }

    /// The camera, where there is one, or straight to Photos.
    private func addPhoto() {
        if UIImagePickerController.isSourceTypeAvailable(.camera) { askSource = true } else { pickerShown = true }
    }

    private func addPicked(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return model.notAnImage() }
        await model.add { PhotoPipeline.reference(data) }
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
                        ReferenceRow(model: model, ref: ref, byok: byok, make: make, delete: delete, use: use)
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
                    TileGrid(model: model, portraits: model.orphans, use: use, delete: delete).padding(.top, 14)
                }
                .padding(.top, 14)
                .overlay(alignment: .top) { Hairline() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("portraits.studio")
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
                HStack(spacing: 7) {
                    Image(systemName: "plus").imageScale(.small).accessibilityHidden(true)
                    PillText(model.busy == "add" ? PortraitWords.adding : PortraitWords.add)
                }
            }
            .buttonStyle(.quietPill(size: .compact))
            .disabled(model.full || model.locked)
            .accessibilityIdentifier("portraits.add")
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
            }
            .padding(.top, 10)
            .padding(.leading, typeSize.isAccessibilitySize ? 0 : 68)
            if !fromIt.isEmpty {
                TileGrid(model: model, portraits: fromIt, use: use, delete: delete).padding(.top, 14)
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

/// Portraits as tiles, two to a row (one at the largest text sizes); the tiles in a row as tall as each other, their
/// buttons along the bottom, as the web's grid lines them up.
private struct TileGrid: View {
    let model: PortraitStudioModel
    let portraits: [Portrait]
    let use: (Portrait) -> Void
    let delete: (Portrait) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let perRow = typeSize.isAccessibilitySize ? 1 : 2
        let rows = stride(from: 0, to: portraits.count, by: perRow).map { Array(portraits[$0..<min($0 + perRow, portraits.count)]) }
        VStack(spacing: 10) {
            ForEach(rows, id: \.first?.id) { row in
                HStack(alignment: .top, spacing: 10) {
                    ForEach(row) { p in
                        PortraitTile(model: model, p: p, use: use, delete: delete).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    if row.count < perRow { Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
                }
                .fixedSize(horizontal: false, vertical: true)
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
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 4) { actions(chosen: chosen, using: using != nil) }
                    VStack(alignment: .leading, spacing: 4) { actions(chosen: chosen, using: using != nil) }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .background(Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(chosen ? Palette.choiceBorder : Palette.border))
        .accessibilityIdentifier("portraits.tile.\(p.id)")
    }

    @ViewBuilder
    private func actions(chosen: Bool, using: Bool) -> some View {
        if p.status == "ready", !chosen {
            Button { use(p) } label: { PillText(using ? PortraitWords.usingShort : PortraitWords.useThis) }
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
                switch p.status {
                case "ready": GradientFill(.gradCream)
                case "pending": PortraitSheen()
                default: Palette.surface2
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

/// Being made: a slow sheen across the tile, still with Reduce Motion.
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
        .background(Palette.surface)
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
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.app(size: 12.5, weight: .medium, relativeTo: .footnote))
            .foregroundStyle(Palette.accentInk)
            .padding(.horizontal, 12)
            .frame(minHeight: 30)
            .background { GradientFill(configuration.isPressed ? .accentGradHover : .accentGrad).clipShape(Capsule()) }
            .tokenShadow(.pill, in: Capsule())
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.5)
    }
}


/// A pill's words: one line, as the web's, shrinking a little before they'd be cut off; wrapped at the accessibility
/// text sizes, so the whole label stays readable (the pill grows to fit).
struct PillText: View {
    let text: String
    @Environment(\.dynamicTypeSize) private var typeSize

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
            .minimumScaleFactor(typeSize.isAccessibilitySize ? 1 : 0.85)
            .multilineTextAlignment(.center)
            .padding(.vertical, typeSize.isAccessibilitySize ? 6 : 0)
    }
}
