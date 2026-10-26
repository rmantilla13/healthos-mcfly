import PhotosUI
import SwiftUI

/// Change the profile photo from the phone: pick one, process it here with Vision, preview, then upload (the web's
/// "Use a photo as is"). Profile shows it for now; the portrait photos (PortraitPhotosSection) take it in.
struct PhotoSection: View {
    @Environment(Dashboard.self) private var dashboard
    @State private var item: PhotosPickerItem?
    @State private var processing = false
    @State private var result: PhotoCutout?
    @State private var error: String?

    var body: some View {
        let label = dashboard.status?.photo == nil ? "Add photo" : "Change photo"
        Section {
            HStack(spacing: 14) {
                Avatar(photo: dashboard.status?.photo, name: dashboard.summary?.name, size: 48)
                PhotosPicker(selection: $item, matching: .images, photoLibrary: .shared()) {
                    Text(label)
                }
                .disabled(processing)
                Spacer()
                if processing { ProgressView() }
            }
            if let error { Text(error).font(.app(.footnote)).foregroundStyle(.red) }
        } header: {
            Text("Profile photo")
        } footer: {
            Text("A portrait with your face and shoulders works best. It's cut out on this iPhone; only the result is uploaded.")
        }
        .onChange(of: item) { _, picked in
            guard let picked else { return }
            Task { await process(picked) }
        }
        .sheet(item: Binding(get: { result.map(PreviewItem.init) }, set: { if $0 == nil { result = nil } })) { preview in
            PhotoPreview(photo: preview.photo) {
                result = nil
                await dashboard.load()
            }
        }
    }

    private func process(_ picked: PhotosPickerItem) async {
        processing = true
        error = nil
        defer {
            processing = false
            item = nil
        }
        do {
            guard let data = try await picked.loadTransferable(type: Data.self) else { throw PhotoCutout.Failure(message: "Couldn't load that photo.") }
            result = try await Task.detached(priority: .userInitiated) { try PhotoCutout.process(data) }.value
        } catch {
            self.error = error.localizedDescription
        }
    }

    private struct PreviewItem: Identifiable {
        let photo: PhotoCutout
        let id = UUID()
    }
}

/// The processed photo before it's saved, as on the web: Save uploads it, Cancel drops it. `saved` runs once it's
/// uploaded, before the sheet closes.
struct PhotoPreview: View {
    let photo: PhotoCutout
    let saved: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(uiImage: UIImage(cgImage: photo.cutout))
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 420)
                    .accessibilityLabel("Your cut-out photo")
                Image(uiImage: UIImage(cgImage: photo.avatar))
                    .resizable()
                    .frame(width: 72, height: 72)
                    .clipShape(Circle())
                    .accessibilityLabel("Your avatar")
                if let error { Text(error).font(.app(.footnote)).foregroundStyle(.red).multilineTextAlignment(.center) }
                Spacer()
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.page)
            .navigationTitle("New photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() } else { Button("Save") { Task { await save() } }.bold() }
                }
            }
            .interactiveDismissDisabled(saving)
        }
    }

    private func save() async {
        guard let client = APIClient.current() else { return }
        saving = true
        defer { saving = false }
        do {
            try await client.uploadPhoto(photo)
            await saved()
            dismiss()
        } catch APIError.server(404, _) {
            error = "This server can't take photos from the app yet. Update healthOS, or use the website."
        } catch APIError.server(413, _) {
            error = "That photo is too large to upload. Try another one."
        } catch {
            self.error = error.localizedDescription
        }
    }
}
