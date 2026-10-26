import ImageIO
import Observation
import UIKit

// The portrait studio's state and steps (src/components/portraits/PortraitStudio.tsx, src/portraits.ts): the list of
// reference photos and the portraits made from them, what's being done right now, and "Use this portrait". Images are
// fetched into memory and shrunk to thumbnails there; the full image is fetched again for Use and let go after. Nothing
// here is written to disk, cached in ProfileImages or logged.

/// What the studio asks the server and the phone for, so a test can stand in for each (`live` is the app's).
struct PortraitService {
    var list: @MainActor () async throws -> PortraitList?
    var addReference: @MainActor (PreparedPhoto) async throws -> Portrait
    var generate: @MainActor (_ referenceId: String) async throws -> Portrait
    var delete: @MainActor (_ id: String) async throws -> PortraitList
    var choose: @MainActor (_ id: String) async throws -> PortraitList
    var image: @MainActor (_ id: String) async throws -> Data
    /// The on-device cut-out (PhotoCutout, Apple Vision), off the main thread.
    var cutOut: @MainActor (Data) async throws -> PhotoCutout
    /// POST /api/profile/photo/upload.
    var upload: @MainActor (PhotoCutout) async throws -> Void
    /// PUT /api/settings {perspective: "portrait"}: Home and Body show "Your own portrait".
    var usePortraitPerspective: @MainActor () async throws -> Void
    /// The profile photo changed: read the dashboard again, as the web's notifyDataChanged.
    var photoChanged: @MainActor () async -> Void
    /// The wait between checks while a portrait is being made.
    var sleep: @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

    /// The app's, for the person signed in now. Each write first checks that same person is still signed in on the
    /// same server: one started for them (Use this portrait takes a few seconds) never goes out as whoever signs in
    /// next. Otherwise it stops with a CancellationError, which the studio stays quiet about.
    @MainActor static func live(_ dashboard: Dashboard) -> PortraitService {
        let who = dashboard.signedInPerson
        let still = { try SignedInPerson.check(dashboard, is: who) }
        return PortraitService(
            list: { try await dashboard.portraits() },
            addReference: { photo in try still(); return try await dashboard.addReference(photo) },
            generate: { id in try still(); return try await dashboard.generatePortrait(referenceId: id) },
            delete: { id in try still(); return try await dashboard.deletePortrait(id: id) },
            choose: { id in try still(); return try await dashboard.choosePortrait(id: id) },
            image: { try await dashboard.portraitImage(id: $0) },
            cutOut: { data in try await Task.detached(priority: .userInitiated) { try PhotoCutout.process(data) }.value },
            upload: { photo in try still(); try await dashboard.fetch { try await $0.uploadPhoto(photo) } },
            usePortraitPerspective: { try still(); try await dashboard.save(settings: ["perspective": "portrait"]) },
            photoChanged: { if (try? still()) != nil { await dashboard.load() } })
    }
}

/// Who a card's reads and writes are for: the server and the account signed in there. Profile's portrait and
/// comparison cards start afresh when it changes, and a write started for one person checks it's still them first.
enum SignedInPerson {
    /// Stops (CancellationError) unless `person` is still the one signed in, on the same server.
    @MainActor static func check(_ dashboard: Dashboard, is person: String?) throws {
        guard let person, dashboard.signedInPerson == person else { throw CancellationError() }
    }
}

extension Dashboard {
    /// "<server>|<account id>" while someone's signed in (the account id is empty on a server without sign-in); nil
    /// otherwise.
    var signedInPerson: String? {
        guard phase == .ready else { return nil }
        return "\(Config.serverURL()?.absoluteString ?? "")|\(account?.id ?? status?.user?.id ?? "")"
    }
}

@MainActor
@Observable
final class PortraitStudioModel {
    /// "Use this portrait" under way: which one, and the step's words.
    struct Using: Equatable {
        let id: String
        let step: String
    }

    /// Why that portrait couldn't be used.
    struct Failed: Equatable {
        let id: String
        let text: String
    }

    /// How often the list is checked while a portrait is being made (POLL_MS).
    static let pollInterval: Duration = .milliseconds(3500)

    /// The list as last read; nil until the first read, or on a server without portraits (`missing`).
    private(set) var list: PortraitList?
    /// The server predates portraits (GET /api/portraits answered its catch-all 404).
    private(set) var missing = false
    /// The first read failed, in the server's words; a later failure keeps the list on screen.
    private(set) var loadError: String?
    /// "add", "make:<id>" or "delete:<id>" while that's under way.
    private(set) var busy: String?
    /// What went wrong with the last add, make or delete.
    private(set) var note: String?
    private(set) var using: Using?
    private(set) var failed: Failed?
    /// Shrunk images by id, in memory only.
    private(set) var thumbs: [String: UIImage] = [:]
    /// Goes up with each photo added and each portrait put to use, for the success haptic.
    private(set) var successes = 0
    /// Set by the view once it has the dashboard.
    var service: PortraitService?
    /// Each read's number, so an older answer never replaces a newer one.
    private var reads = 0

    init(service: PortraitService? = nil) { self.service = service }

    // MARK: What's shown

    var portraits: [Portrait] { list?.portraits ?? [] }
    var references: [Portrait] { portraits.filter { $0.kind == "reference" } }
    var made: [Portrait] { portraits.filter { $0.kind == "generated" } }
    /// One is being made: one at a time, and the list is checked until it's done.
    var making: Bool { made.contains { $0.status == "pending" } }
    /// Portraits whose reference was deleted.
    var orphans: [Portrait] { made.filter { p in !references.contains { $0.id == p.referenceId } } }
    var canGenerate: Bool { list?.canGenerate ?? false }
    /// Five references: the most there can be.
    var full: Bool { references.count >= PortraitLimits.maxReferences }
    /// Something is under way: every other button waits.
    var locked: Bool { busy != nil || using != nil }
    var chosen: String? { list?.chosen }

    func made(from ref: Portrait) -> [Portrait] { made.filter { $0.referenceId == ref.id } }

    /// Make my portrait can be pressed: a key to make it with, none being made, nothing else under way.
    var canMake: Bool { canGenerate && !making && !locked }

    /// "Making…" while this one's request is out or one made from it is pending.
    func isMaking(from ref: Portrait) -> Bool { busy == "make:\(ref.id)" || made(from: ref).contains { $0.status == "pending" } }

    /// The note under the head on why Make my portrait is off; nil while unknown or when one can be made.
    func keyNote(byok: Bool?) -> String? {
        guard list != nil, !canGenerate else { return nil }
        return PortraitWords.keyNote(byok: byok)
    }

    // MARK: Reading

    /// GET /api/portraits. The list shows as soon as it's read; a failure before any list says so, after one keeps it.
    func read() async {
        guard let service else { return }
        reads += 1
        let mine = reads
        do {
            let answer = try await service.list()
            guard mine == reads else { return }
            if let answer {
                apply(answer)
                missing = false
            } else {
                list = nil
                missing = true
            }
            loadError = nil
        } catch {
            guard mine == reads, !PortraitWords.cancelled(error) else { return }
            if list == nil { loadError = PortraitWords.message(error) }
        }
    }

    /// While a portrait is being made, the list is read every 3.5 s until the server says ready or failed. The view runs
    /// this while the studio is open, and it ends when nothing's pending or the studio goes.
    func poll() async {
        guard let service else { return }
        while making, !Task.isCancelled {
            do { try await service.sleep(Self.pollInterval) } catch { return }
            if Task.isCancelled { return }
            await read()
        }
    }

    private func apply(_ answer: PortraitList) {
        list = answer
        let ids = Set(answer.portraits.map(\.id))
        thumbs = thumbs.filter { ids.contains($0.key) }
    }

    /// A ready photo's image, shrunk to `maxPixel` on its long side, for its tile. Fetched once; one that's gone, or
    /// can't be read, stays without.
    func loadThumbnail(_ p: Portrait, maxPixel: Int) async {
        guard thumbs[p.id] == nil, p.status == "ready", let service else { return }
        guard let data = try? await service.image(p.id) else { return }
        let image = await Task.detached(priority: .utility) { PortraitImages.thumbnail(data, maxPixel: maxPixel) }.value
        guard let image, portraits.contains(where: { $0.id == p.id }) else { return }
        thumbs[p.id] = image
    }

    // MARK: Changes

    private func act(_ what: String, _ work: () async throws -> Void) async {
        busy = what
        note = nil
        defer { busy = nil }
        do {
            try await work()
        } catch {
            if PortraitWords.cancelled(error) { return }
            note = PortraitWords.message(error)
        }
    }

    /// Adds a reference photo: shrunk on the phone as the web does (PhotoPipeline.reference), then kept.
    func add(_ photo: @escaping @Sendable () -> PreparedPhoto?) async {
        guard let service else { return }
        await act("add") {
            guard let prepared = await Task.detached(priority: .userInitiated, operation: photo).value else {
                throw PortraitWords.Failure(PortraitWords.cantOpen)
            }
            _ = try await service.addReference(prepared)
            successes += 1
            await read()
        }
    }

    /// A photo the picker couldn't hand over as an image.
    func notAnImage() { note = PortraitWords.notAnImage }

    /// Make my portrait: the server starts it and answers at once; the list then shows it being made.
    func make(from ref: Portrait) async {
        guard let service, canMake else { return }
        await act("make:\(ref.id)") {
            _ = try await service.generate(ref.id)
            await read()
        }
    }

    /// Deletes a reference photo or a portrait, after its question was answered. One already gone says so, and the
    /// list is read again.
    func delete(_ p: Portrait) async {
        guard let service else { return }
        var gone = false
        await act("delete:\(p.id)") {
            do {
                apply(try await service.delete(p.id))
            } catch APIError.server(404, let said) {
                gone = true
                throw PortraitWords.Failure(said.isEmpty ? PortraitWords.somethingWrong : said)
            }
        }
        if gone { await read() }
    }

    /// Use this portrait, in the web's order: its image, the cut-out made here, saved as the profile photo, marked as
    /// the one in use only then (so it's remembered with the photo it became), and the perspective set to "Your own
    /// portrait". Each step's words show on its tile; a failure says what went wrong there.
    func use(_ p: Portrait) async {
        guard let service, !locked else { return }
        failed = nil
        using = Using(id: p.id, step: PortraitWords.loadingPortrait)
        defer { using = nil }
        do {
            let data: Data
            do { data = try await service.image(p.id) } catch {
                if PortraitWords.cancelled(error) { throw error }
                throw PortraitWords.Failure(PortraitWords.couldNotLoad)
            }
            using = Using(id: p.id, step: PortraitWords.cuttingOut)
            let cut: PhotoCutout
            do { cut = try await service.cutOut(data) } catch {
                if PortraitWords.cancelled(error) { throw error }
                throw PortraitWords.Failure(PortraitWords.cutOutFailure(error))
            }
            using = Using(id: p.id, step: PortraitWords.saving)
            do { try await service.upload(cut) } catch {
                if PortraitWords.cancelled(error) { throw error }
                throw PortraitWords.Failure(PortraitWords.uploadFailure(error))
            }
            apply(try await service.choose(p.id))
            try await service.usePortraitPerspective()
            successes += 1
            await service.photoChanged()
        } catch {
            if PortraitWords.cancelled(error) { return }
            failed = Failed(id: p.id, text: PortraitWords.message(error))
        }
        await read()
    }
}

/// Images from the server, shrunk in memory.
enum PortraitImages {
    /// The image at most `maxPixel` on its long side, decoded as it's shrunk (JPEG, PNG and WebP alike), its
    /// transparency kept. nil when the bytes aren't an image.
    static func thumbnail(_ data: Data, maxPixel: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map { UIImage(cgImage: $0) }
    }
}

/// The studio's words, as PortraitStudio.tsx and src/portraits.ts write them (their curly apostrophes and quotes kept).
/// PortraitsTests reads those files to keep them in step.
enum PortraitWords {
    /// A failure whose message is already the words to show.
    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    static let title = "Portrait studio"
    static let introOwnKey = "Your reference photos are kept in your healthOS account, where only you can open them. One goes to OpenAI, on your own key, only when you make a portrait from it."
    static let introServerKey = "Your reference photos are kept in your healthOS account, where only you can open them. One goes to OpenAI, on this healthOS server’s key, only when you make a portrait from it."
    static let introNoKey = "Your reference photos are kept in your healthOS account, where only you can open them. Making a portrait sends one to OpenAI on your own key."
    static let introEnd = " Nothing you make here appears on your dashboard until you choose it."
    static let connectKey = "Connect your OpenAI key in your Profile (OpenAI · Nutrition & portraits, above) to make a portrait."
    static let full = "You have \(PortraitLimits.maxReferences) reference photos, the most there can be. Delete one to add another."
    static let empty = "Add a clear photo of just you, ideally head to toe and facing the camera. It’s what your portrait is made from."
    static let notAnImage = "Choose an image file (JPEG or PNG)."
    static let cantOpen = "That photo couldn't be opened here. Try a JPEG or PNG."
    static let add = "Add a reference photo"
    static let adding = "Adding…"
    static let reference = "Reference photo"
    static let makeMine = "Make my portrait"
    static let makingShort = "Making…"
    static let oneAtATime = "One portrait at a time."
    static let delete = "Delete"
    static let orphans = "From reference photos you’ve deleted"
    static let inUse = "In use"
    static let pending = "Making your portrait… this can take a minute"
    static let failedDefault = "This portrait couldn’t be made. Try again."
    static let useThis = "Use this portrait"
    static let usingShort = "Using…"
    static let deleteReference = "Delete this reference photo? Portraits already made from it stay until you delete them. It can’t be undone."
    static let deleteChosen = "Delete this portrait? Your profile photo made from it stays; you can remove that under “Use a photo as is”."
    static let deletePortrait = "Delete this portrait? It can’t be undone."
    static let replacePhoto = "Use this portrait as your profile photo? It replaces the photo you have now on Home, Body and your avatar."
    // src/portraits.ts makeProfilePhoto.
    static let loadingPortrait = "Loading your portrait…"
    static let saving = "Saving…"
    static let couldNotLoad = "Couldn't load this portrait. Check your connection and try again."
    static let noFace = "healthOS couldn't find a face in this portrait, so it can't place your vitals on it. Try making another."
    static let unreachable = "Couldn't reach healthOS. Check your connection and try again."
    static let tooLarge = "This portrait came out too large to save. Try making another."
    static let couldNotSave = "Couldn't save your portrait as your photo."
    /// One of the cut-out's own steps (src/photo/process.ts), shown while the iPhone's runs in one go.
    static let cuttingOut = "Cutting you out…"
    /// src/lib.ts, for an answer without the server's words.
    static let somethingWrong = "Something went wrong. Try again in a moment."

    /// The intro, honest about whose OpenAI key a reference goes to.
    static func intro(canGenerate: Bool, ownKey: Bool) -> String {
        (canGenerate ? (ownKey ? introOwnKey : introServerKey) : introNoKey) + introEnd
    }

    /// Why a portrait can't be made here: keys can't be stored on this server (byok false, or a server older than
    /// GET /api/ai), or the person hasn't connected one. Unknown reads as the second, as the web's does while loading.
    static func keyNote(byok: Bool?) -> String { byok == false ? ServerWords.portraitNeedsKeyNotHere : connectKey }

    static func loadFailed(_ message: String) -> String { "Couldn't load your portrait photos: \(message)" }

    /// The question before deleting it.
    static func deleteQuestion(_ p: Portrait, chosen: String?) -> String {
        p.kind == "reference" ? deleteReference : p.id == chosen ? deleteChosen : deletePortrait
    }

    /// "Added Oct 26 · private to you · 2 portraits".
    static func referenceLine(_ ref: Portrait, made: Int) -> String {
        var line = "Added \(added(ref.createdAt)) · private to you"
        if made > 0 { line += " · \(made) \(made == 1 ? "portrait" : "portraits")" }
        return line
    }

    static func referenceLabel(_ ref: Portrait) -> String { "Your reference photo from \(added(ref.createdAt))" }
    static func deleteReferenceLabel(_ ref: Portrait) -> String { "Delete the reference photo from \(added(ref.createdAt))" }
    static func portraitLabel(_ p: Portrait) -> String { "Your portrait from \(added(p.createdAt))" }
    static func deletePortraitLabel(_ p: Portrait) -> String { "Delete the portrait from \(added(p.createdAt))" }

    /// A failed portrait's reason, the server's plain words, or the web's own when it gave none.
    static func failure(_ p: Portrait) -> String {
        if let said = p.error, !said.isEmpty { return said }
        return failedDefault
    }

    private static let addedFormat: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f
    }()

    /// The day it was added, in this phone's time zone (the web's `added`: month and day).
    static func added(_ ms: Double?) -> String {
        guard let ms else { return "" }
        return addedFormat.string(from: Date(timeIntervalSince1970: ms / 1000))
    }

    /// An error in the words the web shows: the server's own message whatever its code (a 404's "That photo is already
    /// gone.", a 429's day limit), or the app's for a failure that never reached it.
    static func message(_ error: Error) -> String {
        if case APIError.server(_, let said) = error { return said.isEmpty ? somethingWrong : said }
        return error.localizedDescription
    }

    /// The cut-out's failure on a portrait: without a face it can't place the vitals, in the web's words.
    static func cutOutFailure(_ error: Error) -> String {
        let said = error.localizedDescription
        return said.hasPrefix("No face found") ? noFace : said
    }

    /// Saving the cut-out failed: too large (here or at the server), unreachable, or the server's words.
    static func uploadFailure(_ error: Error) -> String {
        switch error {
        case let failure as PhotoCutout.Failure:
            return failure.message.contains("too large") ? tooLarge : couldNotSave
        case APIError.server(413, _): return tooLarge
        case APIError.server(_, let said): return said.isEmpty ? couldNotSave : said
        case APIError.network: return unreachable
        default: return error.localizedDescription
        }
    }

    static func cancelled(_ error: Error) -> Bool { APIClient.isCancellation(error) }
}
