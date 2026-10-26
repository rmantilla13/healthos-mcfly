import PhotosUI
import SwiftUI

/// "Use a photo as is" (src/pages/Profile.tsx PhotoSettings), under the portrait studio in Profile → Your portrait
/// photos: a photo from the library, cut out here on the iPhone with Apple Vision (PhotoCutout), shown before it's
/// saved, then uploaded (POST /api/profile/photo/upload) as the figure on Home and the avatar. "Remove photo" takes it
/// away (POST /api/profile/photo/clear). Only while signed in, and only that person's: what it shows goes when they
/// sign out or someone else signs in.
struct PhotoSection: View {
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        if dashboard.phase == .ready {
            PhotoAsIs().id("\(Config.serverURL()?.absoluteString ?? "")|\(dashboard.account?.id ?? dashboard.status?.user?.id ?? "")")
        }
    }
}

enum PhotoWords {
    static let title = "Use a photo as is"
    /// The web's hosted line: on the iPhone the photo is always cut out on the device, whatever the server.
    static let line = "Used for the figure on Home and your avatar. It's cut out on this device; only the cut-out, avatar and the points for your vitals are saved."
    static let choose = "Upload a photo"
    static let chooseAgain = "Choose a new photo"
    static let previewLine = "Here's how it came out. Save it to use it on Home and as your avatar."
    static let save = "Save photo"
    static let saving = "Saving…"
    static let cancel = "Cancel"
    static let remove = "Remove photo"
    static let tooLarge = "That photo came out too large to save. Try a smaller or tighter photo."
    static let couldNotSave = "Couldn't save the photo."
    /// A server older than photos from the app (its catch-all 404 for the upload).
    static let notHere = "This server can't take photos from the app yet. Update healthOS, or use the website."
    static let couldNotLoad = "Couldn't load that photo."
    static let current = "Your cut-out photo"
    static let newCutout = "Your new cut-out"
    static let newAvatar = "Your new avatar"
    // src/photo/process.ts, where the iPhone's cut-out (PhotoCutout) words the same failure its own way.
    static let noFace = "No face found. Use a photo where your face is clearly visible."
    static let unreadable = "Couldn't read that image. Use a JPEG or PNG photo."

    /// Cutting out failed: in the web's words where they differ from the cut-out's own.
    static func cutOutFailure(_ error: Error) -> String {
        let said = error.localizedDescription
        if said.hasPrefix("No face found") { return noFace }
        if said.hasPrefix("Couldn't read that image") { return unreadable }
        return said
    }

    /// Saving failed: too large (here or at the server), a server without the route, or the server's words.
    static func saveFailure(_ error: Error) -> String {
        switch error {
        case let failure as PhotoCutout.Failure: return failure.message.contains("too large") ? tooLarge : failure.message
        case APIError.server(413, _): return tooLarge
        case let api as APIError where api.routeMissing: return notHere
        case APIError.server(_, let said): return said.isEmpty ? couldNotSave : said
        default: return error.localizedDescription
        }
    }
}

extension APIClient {
    /// Removes the profile photo (POST /api/profile/photo/clear); the answer is the status, now without one. Home, Body,
    /// the avatar and the Family board go back to no photo.
    func clearPhoto() async throws -> ServerStatus {
        try await sendJSON("POST", "/profile/photo/clear", [:])
    }
}

private struct PhotoAsIs: View {
    @Environment(Dashboard.self) private var dashboard
    @State private var item: PhotosPickerItem?
    /// Cutting out, saving or removing.
    @State private var busy = false
    @State private var step: String?
    @State private var preview: PhotoCutout?
    @State private var error: String?
    /// The cut-out saved now, as the server keeps it (not the dashboard's grade), in memory only.
    @State private var current: UIImage?

    var body: some View {
        let photo = dashboard.status?.photo
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(PhotoWords.title)
                    .font(.app(size: 14, weight: .medium, relativeTo: .subheadline))
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(PhotoWords.line)
                    .font(.app(size: 12, relativeTo: .caption))
                    .foregroundStyle(Palette.ink3)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let preview {
                PhotoPreviewRow(photo: preview, saving: busy, save: { Task { await save(preview) } }, cancel: { self.preview = nil })
            } else {
                HStack(alignment: .top, spacing: 16) {
                    if photo != nil { CutoutFrame(image: current, label: PhotoWords.current) }
                    dropzone(hasPhoto: photo != nil)
                }
            }
            if let error { BadNote(text: error) }
            if photo != nil, !busy, preview == nil {
                Button(PhotoWords.remove) { Task { await remove() } }
                    .buttonStyle(QuietTextStyle())
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("photo.remove")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: item) { _, picked in
            guard let picked else { return }
            Task { await process(picked) }
        }
        .task(id: photo?.versionKey) { await loadCurrent(photo) }
    }

    /// .dropzone: a dashed box with the choose pill, or the step while it works.
    private func dropzone(hasPhoto: Bool) -> some View {
        VStack(spacing: 10) {
            if busy {
                Text(step ?? "Working…").font(.app(.footnote)).foregroundStyle(Palette.ink2).multilineTextAlignment(.center)
            } else {
                Image(systemName: "square.and.arrow.up").font(.system(size: 20)).foregroundStyle(Palette.ink2).accessibilityHidden(true)
                PhotosPicker(selection: $item, matching: .images, photoLibrary: .shared()) {
                    PillText(hasPhoto ? PhotoWords.chooseAgain : PhotoWords.choose)
                }
                .buttonStyle(.quietPill(size: .compact))
                .accessibilityIdentifier("photo.choose")
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 150)
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Palette.axis, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
    }

    private func loadCurrent(_ photo: PhotoMeta?) async {
        current = nil
        guard let photo else { return }
        let data = try? await dashboard.fetch { try await $0.profileImage("cutout.png", version: photo.versionKey) }
        guard let data else { return }
        current = await Task.detached(priority: .utility) { PortraitImages.thumbnail(data, maxPixel: 480) }.value
    }

    private func process(_ picked: PhotosPickerItem) async {
        error = nil
        busy = true
        step = PortraitWords.cuttingOut
        defer {
            busy = false
            step = nil
            item = nil
        }
        do {
            guard let data = try await picked.loadTransferable(type: Data.self) else { throw PhotoCutout.Failure(message: PhotoWords.couldNotLoad) }
            preview = try await Task.detached(priority: .userInitiated) { try PhotoCutout.process(data) }.value
        } catch {
            if !APIClient.isCancellation(error) { self.error = PhotoWords.cutOutFailure(error) }
        }
    }

    private func save(_ photo: PhotoCutout) async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            try await PhotoPreview.upload(photo, dashboard)
            preview = nil
            await dashboard.load()
        } catch {
            if !APIClient.isCancellation(error) { self.error = PhotoWords.saveFailure(error) }
        }
    }

    /// The photo goes from Home, Body, the avatar and the Family board; the copies kept on this phone go with it.
    private func remove() async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            let status = try await dashboard.fetch { try await $0.clearPhoto() }
            dashboard.showChanged(status)
            ProfileImages.clear()
            current = nil
        } catch {
            if !APIClient.isCancellation(error) { self.error = PortraitWords.message(error) }
        }
    }
}

/// The cut-out, whole, in its rounded frame (.photo-preview: 120 × 150 on the surface).
private struct CutoutFrame: View {
    let image: UIImage?
    let label: String

    var body: some View {
        ZStack {
            Palette.surface2
            if let image { Image(uiImage: image).resizable().scaledToFit() }
        }
        .frame(width: 120, height: 150)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isImage)
    }
}

/// How the cut-out came out, before it's saved: the cut-out and the avatar, with Save photo and Cancel.
struct PhotoPreviewRow: View {
    let photo: PhotoCutout
    let saving: Bool
    let save: () -> Void
    let cancel: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16)) : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
        layout {
            CutoutFrame(image: UIImage(cgImage: photo.cutout), label: PhotoWords.newCutout)
            VStack(alignment: .leading, spacing: 10) {
                Image(uiImage: UIImage(cgImage: photo.avatar))
                    .resizable()
                    .scaledToFill()
                    .frame(width: 64, height: 64)
                    .clipShape(Circle())
                    .padding(3)
                    .background(Circle().fill(Palette.surface))
                    .overlay(Circle().strokeBorder(Palette.border))
                    .accessibilityLabel(PhotoWords.newAvatar)
                Text(PhotoWords.previewLine)
                    .font(.app(size: 12, relativeTo: .caption))
                    .foregroundStyle(Palette.ink3)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { buttons }
                    VStack(alignment: .leading, spacing: 8) { buttons }
                }
            }
            .frame(maxWidth: 260, alignment: .leading)
        }
    }

    @ViewBuilder
    private var buttons: some View {
        Button(action: save) { PillText(saving ? PhotoWords.saving : PhotoWords.save) }
            .buttonStyle(.accentPill(size: .compact))
            .disabled(saving)
            .accessibilityIdentifier("photo.save")
        Button(PhotoWords.cancel, action: cancel)
            .buttonStyle(QuietTextStyle())
            .disabled(saving)
    }
}

/// The processed photo before it's saved, as a sheet of its own: Save photo uploads it, Cancel drops it. `saved` runs
/// once it's uploaded, before the sheet closes.
struct PhotoPreview: View {
    let photo: PhotoCutout
    let saved: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(Dashboard.self) private var dashboard
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    PhotoPreviewRow(photo: photo, saving: saving, save: { Task { await save() } }, cancel: { dismiss() })
                    if let error { BadNote(text: error) }
                }
                .padding(20)
            }
            .background(Palette.page)
            .navigationTitle("New photo")
            .navigationBarTitleDisplayMode(.inline)
        }
        .font(.app(.body))
        .tint(Palette.tint)
        .interactiveDismissDisabled(saving)
    }

    private func save() async {
        saving = true
        error = nil
        defer { saving = false }
        do {
            try await Self.upload(photo, dashboard)
            await saved()
            dismiss()
        } catch {
            if !APIClient.isCancellation(error) { self.error = PhotoWords.saveFailure(error) }
        }
    }

    /// Uploads a cut-out as the profile photo; a 401 drops to sign-in, as every request does.
    @MainActor static func upload(_ photo: PhotoCutout, _ dashboard: Dashboard) async throws {
        try await dashboard.fetch { try await $0.uploadPhoto(photo) }
    }
}
