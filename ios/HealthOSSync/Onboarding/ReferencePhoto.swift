import Observation
import UIKit

/// The portrait's reference photo chosen on step 1 (useReferencePhoto in Onboarding.tsx). It lives with the welcome, not
/// the step, so leaving step 1 while it uploads doesn't lose it, and nothing waits for it: Continue works whether it
/// saved, failed or is still going. It's shrunk and turned upright on the phone (PhotoPipeline.reference) and kept with
/// POST /api/portraits/reference, as the portrait studio does; the answer names its id.
///
/// The photo is in memory only: never written to disk or logged. Its thumbnail goes with the welcome.
@MainActor
@Observable
final class ReferencePhoto {
    enum State: Equatable { case saving, saved, failed }

    struct Chosen {
        let preview: UIImage
        var state: State
        /// The kept photo's id, once saved.
        var id: String?
    }

    /// The web's words for each thing that can go wrong.
    static let notSaved = "Your photo couldn't be saved just now. You can add it later in your Profile."
    static let notOpened = "That photo couldn't be opened here. Try a JPEG or PNG."
    static let notRemoved = "Your photo couldn't be removed just now. Try again, or remove it later in your Profile."

    private(set) var photo: Chosen?
    private(set) var note: String?
    /// References kept before (here or in the portrait studio): "A photo you added earlier is saved…".
    private(set) var earlier = 0
    /// The server keeps portraits: nil until its list has been read (show the row meanwhile), false when it predates
    /// them (no row).
    private(set) var available: Bool?

    /// A photo picked and on its way in: read from Photos and shrunk, before its thumbnail shows.
    private(set) var preparing = false
    /// Remove is deleting the kept photo.
    private(set) var removing = false
    var saving: Bool { photo?.state == .saving }
    /// A photo is on its way (from the moment it's picked until it's kept or turned down) or going. Choose, Change and
    /// Remove wait meanwhile: a second photo started now would read the first as not kept yet, and the first would stay
    /// on the server, out of sight, counting toward the five references it keeps.
    var busy: Bool { preparing || saving || removing }

    @ObservationIgnored private let add: (PreparedPhoto) async throws -> Portrait
    @ObservationIgnored private let delete: (String) async throws -> Void
    @ObservationIgnored private let list: () async throws -> PortraitList?
    @ObservationIgnored private var work: Task<Void, Never>?
    /// Which choice is current: a sign-out, or a newer choice, leaves an older one nothing to change when it lands.
    @ObservationIgnored private var current = 0

    init(add: @escaping (PreparedPhoto) async throws -> Portrait, delete: @escaping (String) async throws -> Void,
         list: @escaping () async throws -> PortraitList?) {
        self.add = add
        self.delete = delete
        self.list = list
    }

    /// How many references are kept already, and whether the server keeps them at all. A failed read says nothing.
    func load() async {
        do {
            let portraits = try await list()
            available = portraits != nil
            earlier = portraits?.references.count ?? 0
        } catch {}
    }

    /// A photo picked from Photos (read from the library and shrunk, a HEIC included) or taken with the camera, all off
    /// the main thread: `prepare` does both. The row is busy from this moment, and a pick while it's busy is turned
    /// down. Change keeps the new one first and only then deletes the one chosen a moment ago, rather than keeping both.
    func choose(_ prepare: @escaping @Sendable () async -> PreparedPhoto?) {
        guard !busy else { return }
        current += 1
        let choice = current
        preparing = true
        note = nil
        work = Task { await self.run(prepare, choice: choice) }
    }

    /// Waits for the photo on its way (tests).
    func settle() async { await work?.value }

    private func run(_ prepare: @escaping @Sendable () async -> PreparedPhoto?, choice: Int) async {
        let prepared = await Task.detached(priority: .userInitiated, operation: prepare).value
        guard choice == current else { return }
        preparing = false
        guard let prepared, let preview = UIImage(data: prepared.jpeg) else {
            note = Self.notOpened
            return
        }
        let replacing = photo?.state == .saved ? photo?.id : nil
        photo = Chosen(preview: preview, state: .saving)
        let kept: Portrait
        do {
            kept = try await add(prepared)
        } catch {
            guard choice == current else { return }
            photo = Chosen(preview: preview, state: .failed)
            note = Self.notSaved
            return
        }
        guard choice == current else { return }
        photo = Chosen(preview: preview, state: .saved, id: kept.id)
        if let replacing { try? await delete(replacing) }
    }

    /// Remove: a saved photo is deleted first; one that failed or never saved just goes.
    func remove() async {
        // Not while one is on its way: it would come back once kept.
        guard !busy else { return }
        removing = true
        defer { removing = false }
        note = nil
        if let photo, photo.state == .saved, let id = photo.id {
            do {
                try await delete(id)
            } catch {
                note = Self.notRemoved
                return
            }
        }
        photo = nil
    }

    /// Signed out: the upload stops and nothing of the photo stays.
    func forget() {
        work?.cancel()
        current += 1
        preparing = false
        photo = nil
        note = nil
    }
}
