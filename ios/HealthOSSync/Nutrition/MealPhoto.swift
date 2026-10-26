import PhotosUI
import SwiftUI

/// A meal photo for McFly to estimate, ready to send: turned upright, shrunk on the phone to a 1,280 px long edge and
/// re-encoded as a JPEG, which leaves out where and when it was taken (PhotoPipeline). Kept in memory only, for that
/// estimate (and, in Today's conversation, a correction of it).
struct AttachedPhoto: Equatable {
    let jpeg: Data
    /// The photo as it will be sent, to show.
    let preview: UIImage

    /// The web's quality for a meal photo (shrinkPhoto in src/pages/FoodLog.tsx).
    static let quality: CGFloat = 0.85

    /// From Photos' bytes (a HEIC, a PNG): nil when it isn't an image.
    init?(data: Data) {
        guard let p = PhotoPipeline.prepare(data, longEdge: Int(FoodPhoto.longEdge), quality: Self.quality) else { return nil }
        self.init(jpeg: p.jpeg)
    }

    /// From the camera.
    init?(image: UIImage) {
        guard let p = PhotoPipeline.prepare(image, longEdge: Int(FoodPhoto.longEdge), quality: Self.quality) else { return nil }
        self.init(jpeg: p.jpeg)
    }

    private init?(jpeg: Data) {
        guard let preview = UIImage(data: jpeg) else { return nil }
        self.jpeg = jpeg
        self.preview = preview
    }
}

extension View {
    /// "Add a photo": the camera or Photos, as a phone's browser offers for the web's photo field. Straight to Photos
    /// where there's no camera (the simulator). The photo comes back ready to send, or `failed` when it can't be opened.
    func mealPhotoSource(isPresented: Binding<Bool>, picked: @escaping (AttachedPhoto) -> Void, failed: @escaping () -> Void) -> some View {
        modifier(MealPhotoSource(asking: isPresented, picked: picked, failed: failed))
    }
}

private struct MealPhotoSource: ViewModifier {
    @Binding var asking: Bool
    let picked: (AttachedPhoto) -> Void
    let failed: () -> Void
    @State private var library = false
    @State private var camera = false
    @State private var item: PhotosPickerItem?

    private var hasCamera: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    func body(content: Content) -> some View {
        content
            .onChange(of: asking) { _, on in
                // Without a camera there's nothing to choose between.
                if on, !hasCamera {
                    asking = false
                    library = true
                }
            }
            .confirmationDialog("Add a photo", isPresented: Binding(get: { asking && hasCamera }, set: { asking = $0 }), titleVisibility: .hidden) {
                Button("Take a photo") { camera = true }
                Button("Choose from your photos") { library = true }
            }
            .photosPicker(isPresented: $library, selection: $item, matching: .images)
            .onChange(of: item) { _, new in
                guard let new else { return }
                item = nil
                Task {
                    if let data = try? await new.loadTransferable(type: Data.self), let photo = AttachedPhoto(data: data) { picked(photo) } else { failed() }
                }
            }
            .fullScreenCover(isPresented: $camera) {
                CameraPicker { image in
                    camera = false
                    guard let image else { return }
                    if let photo = AttachedPhoto(image: image) { picked(photo) } else { failed() }
                }
                .ignoresSafeArea()
            }
    }
}
