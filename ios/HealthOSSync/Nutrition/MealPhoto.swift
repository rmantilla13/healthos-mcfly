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

/// Where a meal photo comes from, once "Add a photo" is answered.
enum MealPhotoPick: Equatable {
    case camera, library

    /// This iPhone has a camera; without one (the simulator) there's nothing to choose between, and it's Photos.
    static var hasCamera: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }
}

extension View {
    /// "Add a photo": the camera or Photos, as a phone's browser offers for the web's photo field. Straight to Photos
    /// where there's no camera (the simulator). The photo comes back ready to send, or `failed` when it can't be opened.
    /// The question and what it opens are on this one view (the Log's estimate). Today's conversation puts the question
    /// on its button and what it opens on the page (`mealPhotoChoice` and `mealPhotoPicker`), so a fold that swaps its
    /// panes never closes the camera.
    func mealPhotoSource(isPresented: Binding<Bool>, picked: @escaping (AttachedPhoto) -> Void, failed: @escaping () -> Void) -> some View {
        modifier(MealPhotoSource(asking: isPresented, picked: picked, failed: failed))
    }

    /// "Add a photo"'s question, on the control that asks it (a popover on it at regular width, P10): Take a photo or
    /// Choose from your photos, into `pick`. Straight to Photos where there's no camera.
    func mealPhotoChoice(isPresented: Binding<Bool>, pick: Binding<MealPhotoPick?>) -> some View {
        modifier(MealPhotoChoice(asking: isPresented, pick: pick))
    }

    /// What the question opens, Photos or the camera, presented from here: the page, above anything a fold rebuilds (P4).
    /// The photo comes back ready to send, or `failed` when it can't be opened.
    func mealPhotoPicker(pick: Binding<MealPhotoPick?>, picked: @escaping (AttachedPhoto) -> Void, failed: @escaping () -> Void) -> some View {
        modifier(MealPhotoPicker(pick: pick, picked: picked, failed: failed))
    }
}

private struct MealPhotoSource: ViewModifier {
    @Binding var asking: Bool
    let picked: (AttachedPhoto) -> Void
    let failed: () -> Void
    @State private var pick: MealPhotoPick?

    func body(content: Content) -> some View {
        content
            .mealPhotoChoice(isPresented: $asking, pick: $pick)
            .mealPhotoPicker(pick: $pick, picked: picked, failed: failed)
    }
}

private struct MealPhotoChoice: ViewModifier {
    @Binding var asking: Bool
    @Binding var pick: MealPhotoPick?

    func body(content: Content) -> some View {
        content
            .onChange(of: asking, initial: true) { _, on in
                // Without a camera there's nothing to choose between.
                if on, !MealPhotoPick.hasCamera {
                    asking = false
                    pick = .library
                }
            }
            .confirmationDialog("Add a photo", isPresented: Binding(get: { asking && MealPhotoPick.hasCamera }, set: { asking = $0 }), titleVisibility: .hidden) {
                Button("Take a photo") { pick = .camera }
                Button("Choose from your photos") { pick = .library }
            }
    }
}

private struct MealPhotoPicker: ViewModifier {
    @Binding var pick: MealPhotoPick?
    let picked: (AttachedPhoto) -> Void
    let failed: () -> Void
    @State private var item: PhotosPickerItem?

    func body(content: Content) -> some View {
        content
            .photosPicker(isPresented: Binding(get: { pick == .library }, set: { if !$0, pick == .library { pick = nil } }),
                          selection: $item, matching: .images)
            .onChange(of: item) { _, new in
                guard let new else { return }
                item = nil
                Task {
                    if let data = try? await new.loadTransferable(type: Data.self), let photo = AttachedPhoto(data: data) { picked(photo) } else { failed() }
                }
            }
            .fullScreenCover(isPresented: Binding(get: { pick == .camera }, set: { if !$0, pick == .camera { pick = nil } })) {
                CameraPicker { image in
                    pick = nil
                    guard let image else { return }
                    if let photo = AttachedPhoto(image: image) { picked(photo) } else { failed() }
                }
                .ignoresSafeArea()
            }
    }
}
