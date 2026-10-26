import SwiftUI
import XCTest
@testable import HealthOSSync

/// The portrait studio and "Use a photo as is" (Portraits/), against src/components/portraits/PortraitStudio.tsx,
/// src/portraits.ts and src/pages/Profile.tsx: their words, which buttons work when, the order "Use this portrait" runs
/// in and each step's failure, the server's refusals in its own words, and images kept in memory only. A local server
/// has no OpenAI key, so ready, pending and failed portraits come from portraits-studio.json, written by hand from
/// shared/portraits.ts; each request is a stand-in (PortraitService) that records what was asked.
@MainActor
final class PortraitsTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = Bundle(for: Self.self).url(forResource: name, withExtension: "json")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name).json")
        return try XCTUnwrap(try? Data(contentsOf: url), "missing fixture \(name).json")
    }

    private func web(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(path)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { throw XCTSkip("\(path) isn't next to the app") }
        return text
    }

    private func studioList() throws -> PortraitList { try JSONDecoder().decode(PortraitList.self, from: fixture("portraits-studio")) }

    /// A list with no portrait being made, so Make my portrait can be pressed.
    private func settledList(canGenerate: Bool = true) throws -> PortraitList {
        let list = try studioList()
        return PortraitList(portraits: list.portraits.filter { $0.status != "pending" }, chosen: list.chosen, canGenerate: canGenerate)
    }

    /// What the stand-in was asked, in order.
    private final class Log {
        var calls: [String] = []
        var steps: [String] = []
    }

    private func cutout() -> PhotoCutout {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 120), format: format).image { ctx in
            UIColor(white: 0.85, alpha: 1).setFill()
            ctx.fill(CGRect(x: 20, y: 10, width: 40, height: 100))
        }
        return PhotoCutout(cutout: image.cgImage!, avatar: image.cgImage!, meta: [:])
    }

    /// A stand-in for the server and the cut-out: each answers as given, and records its call.
    private func service(_ log: Log, list: @escaping () throws -> PortraitList?, model: @escaping () -> PortraitStudioModel?,
                         image: @escaping (String) throws -> Data = { _ in Data() },
                         cutOut: @escaping () throws -> PhotoCutout = { throw PhotoCutout.Failure(message: "unused") },
                         upload: @escaping () throws -> Void = {}, choose: (() throws -> PortraitList)? = nil,
                         generate: @escaping () throws -> Portrait = { Portrait(id: "new", kind: "generated", status: "pending") },
                         delete: (() throws -> PortraitList)? = nil) -> PortraitService {
        func step() { if let step = model()?.using?.step { log.steps.append(step) } }
        return PortraitService(
            list: { log.calls.append("list"); return try list() },
            addReference: { photo in log.calls.append("add \(photo.width)x\(photo.height)"); return Portrait(id: "r-new", kind: "reference", status: "ready") },
            generate: { id in log.calls.append("generate \(id)"); return try generate() },
            delete: { id in log.calls.append("delete \(id)"); return try (delete ?? { try XCTUnwrap(list()) })() },
            choose: { id in log.calls.append("choose \(id)"); step(); return try (choose ?? { try XCTUnwrap(list()) })() },
            image: { id in log.calls.append("image \(id)"); step(); return try image(id) },
            cutOut: { _ in log.calls.append("cutOut"); step(); return try cutOut() },
            upload: { _ in log.calls.append("upload"); step(); try upload() },
            usePortraitPerspective: { log.calls.append("perspective portrait") },
            photoChanged: { log.calls.append("photoChanged") },
            sleep: { _ in log.calls.append("sleep") })
    }

    private func model(_ log: Log, list: PortraitList?, image: @escaping (String) throws -> Data = { _ in Data() },
                       cutOut: @escaping () throws -> PhotoCutout = { throw PhotoCutout.Failure(message: "unused") },
                       upload: @escaping () throws -> Void = {}, choose: (() throws -> PortraitList)? = nil,
                       generate: @escaping () throws -> Portrait = { Portrait(id: "new", kind: "generated", status: "pending") },
                       delete: (() throws -> PortraitList)? = nil) async -> PortraitStudioModel {
        let m = PortraitStudioModel()
        m.service = service(log, list: { list }, model: { [weak m] in m }, image: image, cutOut: cutOut, upload: upload, choose: choose,
                            generate: generate, delete: delete)
        await m.read()
        log.calls.removeAll()
        return m
    }

    // MARK: Words

    func testTheWordsAreTheStudios() throws {
        let studio = try web("src/components/portraits/PortraitStudio.tsx")
        for words in [PortraitWords.introOwnKey, PortraitWords.introServerKey, PortraitWords.introNoKey, PortraitWords.introEnd, PortraitWords.connectKey,
                      PortraitWords.empty, PortraitWords.notAnImage, PortraitWords.cantOpen, PortraitWords.deleteReference, PortraitWords.deleteChosen,
                      PortraitWords.deletePortrait, PortraitWords.replacePhoto, PortraitWords.pending, PortraitWords.failedDefault, PortraitWords.orphans,
                      PortraitWords.title, PortraitWords.add, PortraitWords.adding, PortraitWords.reference, PortraitWords.makeMine,
                      PortraitWords.makingShort, PortraitWords.oneAtATime, PortraitWords.inUse, PortraitWords.useThis, PortraitWords.usingShort,
                      ServerWords.portraitNeedsKeyNotHere] {
            XCTAssertTrue(studio.contains(words), words)
        }
        XCTAssertTrue(studio.contains("You have {MAX_REFERENCES} reference photos, the most there can be. Delete one to add another."))
        XCTAssertEqual(PortraitWords.full, "You have 5 reference photos, the most there can be. Delete one to add another.")
        XCTAssertTrue(studio.contains("Couldn't load your portrait photos: {loadError.message}"))
        XCTAssertTrue(studio.contains("Added {added(ref.createdAt)} · private to you"))
        XCTAssertTrue(studio.contains("` · ${fromIt.length} ${fromIt.length === 1 ? 'portrait' : 'portraits'}`"))
        for label in ["`Your reference photo from ${added(ref.createdAt)}`", "`Delete the reference photo from ${added(ref.createdAt)}`",
                      "`Your portrait from ${when}`", "`Delete the portrait from ${when}`"] {
            XCTAssertTrue(studio.contains(label), label)
        }
        let flow = try web("src/portraits.ts")
        for words in [PortraitWords.loadingPortrait, PortraitWords.saving, PortraitWords.couldNotLoad, PortraitWords.noFace, PortraitWords.unreachable,
                      PortraitWords.tooLarge, PortraitWords.couldNotSave] {
            XCTAssertTrue(flow.contains(words), words)
        }
        XCTAssertTrue(try web("src/photo/process.ts").contains("'\(PortraitWords.cuttingOut)'"))
        XCTAssertTrue(try web("src/lib.ts").contains("'\(PortraitWords.somethingWrong)'"))
        // The limits the words count with.
        let shared = try web("shared/portraits.ts")
        XCTAssertTrue(shared.contains("export const MAX_REFERENCES = \(PortraitLimits.maxReferences);"))
        XCTAssertTrue(shared.contains("export const PORTRAITS_PER_DAY = \(PortraitLimits.perDay);"))
        XCTAssertTrue(shared.contains("export const MAX_GENERATED = \(PortraitLimits.maxGenerated);"))
    }

    func testTheIntroSaysWhoseKeyAndTheNoteWhyNot() async throws {
        XCTAssertEqual(PortraitWords.intro(canGenerate: true, ownKey: true), PortraitWords.introOwnKey + PortraitWords.introEnd)
        XCTAssertEqual(PortraitWords.intro(canGenerate: true, ownKey: false), PortraitWords.introServerKey + PortraitWords.introEnd)
        XCTAssertEqual(PortraitWords.intro(canGenerate: false, ownKey: true), PortraitWords.introNoKey + PortraitWords.introEnd)

        let log = Log()
        // Before the list is read: no note at all.
        XCTAssertNil(PortraitStudioModel().keyNote(byok: false))
        // A key to make one with: no note.
        let can = await model(log, list: try settledList())
        XCTAssertNil(can.keyNote(byok: false))
        // None: why, in the web's words. Keys can't be stored here (or the server predates GET /api/ai) ...
        let cannot = await model(log, list: try settledList(canGenerate: false))
        XCTAssertEqual(cannot.keyNote(byok: false), "Making a portrait needs an OpenAI key, and storing your own key isn’t available on this server.")
        // ... or they can, and the person hasn't connected one; unknown reads the same, as the web's while /ai loads.
        XCTAssertEqual(cannot.keyNote(byok: true), PortraitWords.connectKey)
        XCTAssertEqual(cannot.keyNote(byok: nil), PortraitWords.connectKey)
        XCTAssertFalse(cannot.canMake, "no key: Make my portrait is off")
        // The local server's own answer: no OpenAI key, keys can be stored.
        let local = try JSONDecoder().decode(PortraitList.self, from: Data(#"{"portraits":[],"chosen":null,"canGenerate":false}"#.utf8))
        XCTAssertEqual(local.canGenerate, false)
    }

    func testDeleteAsksTheWebsQuestions() throws {
        let list = try studioList()
        let byId = Dictionary(uniqueKeysWithValues: list.portraits.map { ($0.id, $0) })
        XCTAssertEqual(PortraitWords.deleteQuestion(try XCTUnwrap(byId["ref-a"]), chosen: list.chosen), PortraitWords.deleteReference)
        XCTAssertEqual(PortraitWords.deleteQuestion(try XCTUnwrap(byId["made-chosen"]), chosen: list.chosen),
                       "Delete this portrait? Your profile photo made from it stays; you can remove that under “Use a photo as is”.")
        XCTAssertEqual(PortraitWords.deleteQuestion(try XCTUnwrap(byId["made-ready"]), chosen: list.chosen), "Delete this portrait? It can’t be undone.")
    }

    // MARK: What can be pressed

    func testOnePortraitAtATimeAndFiveReferencesAtMost() async throws {
        let log = Log()
        let m = await model(log, list: try studioList())
        XCTAssertEqual(m.references.map(\.id), ["ref-a", "ref-b"])
        XCTAssertEqual(m.made(from: m.references[0]).map(\.id), ["made-ready", "made-chosen", "made-failed"])
        XCTAssertEqual(m.orphans.map(\.id), ["made-orphan"], "its reference was deleted")
        XCTAssertEqual(m.chosen, "made-chosen")
        // One is being made: every Make my portrait waits, and the one it comes from says Making….
        XCTAssertTrue(m.making)
        XCTAssertFalse(m.canMake)
        XCTAssertTrue(m.isMaking(from: m.references[1]))
        XCTAssertFalse(m.isMaking(from: m.references[0]))
        await m.make(from: m.references[0])
        XCTAssertEqual(log.calls, [], "nothing is sent while one is being made")
        XCTAssertFalse(m.full)
        XCTAssertEqual(PortraitWords.referenceLine(m.references[0], made: 3), "Added \(PortraitWords.added(m.references[0].createdAt)) · private to you · 3 portraits")
        XCTAssertTrue(PortraitWords.referenceLine(m.references[0], made: 1).hasSuffix(" · private to you · 1 portrait"))
        XCTAssertEqual(PortraitWords.referenceLine(m.references[0], made: 0), "Added \(PortraitWords.added(m.references[0].createdAt)) · private to you")
        XCTAssertEqual(PortraitWords.failure(try XCTUnwrap(m.portraits.first { $0.id == "made-failed" })), "OpenAI is busy right now. Try again in a minute.")
        XCTAssertEqual(PortraitWords.failure(try XCTUnwrap(m.portraits.first { $0.id == "made-failed-quiet" })), PortraitWords.failedDefault)

        let refs = (1...5).map { Portrait(id: "r\($0)", kind: "reference", status: "ready", createdAt: 1_761_300_000_000) }
        let five = await model(log, list: PortraitList(portraits: refs, chosen: nil, canGenerate: true))
        XCTAssertTrue(five.full, "the add pill is off at five")
    }

    func testTheAddedDayIsShortMonthAndDayOnThePhonesOwnDay() throws {
        // The web's `added`: the browser's own language and time zone, short month and day.
        let studio = try web("src/components/portraits/PortraitStudio.tsx")
        XCTAssertTrue(studio.contains("const added = (ms: number) => new Date(ms).toLocaleDateString(undefined, { month: 'short', day: 'numeric' });"))
        let ms = 1_761_300_000_000.0 // 24 October 2025, 10:00 UTC
        let us = Locale(identifier: "en_US")
        XCTAssertEqual(PortraitWords.added(ms, locale: us, timeZone: try XCTUnwrap(TimeZone(identifier: "UTC"))), "Oct 24")
        // Already the 25th at UTC+14, still the 23rd at UTC−11: the day it was where the phone is, not UTC's.
        XCTAssertEqual(PortraitWords.added(ms, locale: us, timeZone: try XCTUnwrap(TimeZone(identifier: "Pacific/Kiritimati"))), "Oct 25")
        XCTAssertEqual(PortraitWords.added(ms, locale: us, timeZone: try XCTUnwrap(TimeZone(identifier: "Pacific/Pago_Pago"))), "Oct 23")
        // In the phone's language, as toLocaleDateString(undefined, …) is in the browser's.
        XCTAssertEqual(PortraitWords.added(ms, locale: Locale(identifier: "en_GB"), timeZone: try XCTUnwrap(TimeZone(identifier: "UTC"))), "24 Oct")
        XCTAssertEqual(PortraitWords.added(nil), "")
    }

    // MARK: The server's refusals, in its words

    func testMakeShowsTheServersRefusalAsItIs() async throws {
        let refusals: [(Int, String)] = [
            (429, "You've made 10 portraits today, the most in a day. Try again tomorrow."),
            (409, "Your portrait is still being made. It can take a minute or two."),
            (409, "You have 20 portraits. Delete one you don't need to make another."),
            (409, "Connect your OpenAI key in your Profile to make a portrait."),
            (404, "That reference photo is gone. Add it again to make a portrait."),
            (500, "Something went wrong. Try again in a moment."),
        ]
        for (code, words) in refusals {
            let log = Log()
            let m = await model(log, list: try settledList(), generate: { throw APIClient.error(status: code, message: words, path: "/portraits/generate") })
            await m.make(from: m.references[0])
            XCTAssertEqual(m.note, words, "\(code): no \"Server answered\"")
            XCTAssertNil(m.busy)
            XCTAssertEqual(log.calls, ["generate ref-a"])
        }
        // Offline: the web's request() words, not the phone's "Can't reach localhost".
        let log = Log()
        let offline = APIClient(base: URL(string: "http://localhost:8805")!).unreachable(URLError(.notConnectedToInternet))
        let m = await model(log, list: try settledList(), generate: { throw offline })
        await m.make(from: m.references[0])
        XCTAssertEqual(m.note, "Couldn't reach healthOS. Check your connection and try again.")
        XCTAssertTrue(try web("src/lib.ts").contains("\"\(PortraitWords.unreachable)\""))
        // The server says the day's limit: the phone keeps no count of its own.
        let server = try web("server/portraits.ts")
        XCTAssertTrue(server.contains("`You've made ${PORTRAITS_PER_DAY} portraits today, the most in a day. Try again tomorrow.`"))
        XCTAssertTrue(server.contains("'Your portrait is still being made. It can take a minute or two.'"))
    }

    func testMakeStartsOneAndReadsTheList() async throws {
        let log = Log()
        let m = await model(log, list: try settledList())
        XCTAssertTrue(m.canMake)
        await m.make(from: m.references[1])
        XCTAssertEqual(log.calls, ["generate ref-b", "list"])
        XCTAssertNil(m.note)
    }

    func testDeletingOneAlreadyGoneSaysSoAndReadsAgain() async throws {
        let log = Log()
        let m = await model(log, list: try settledList(), delete: { throw APIClient.error(status: 404, message: "That photo is already gone.", path: "/portraits/x") })
        await m.delete(m.references[0])
        XCTAssertEqual(m.note, "That photo is already gone.")
        XCTAssertEqual(log.calls, ["delete ref-a", "list"])

        // A delete that goes through answers with the list: nothing else to read.
        let after = try settledList()
        let kept = PortraitList(portraits: after.portraits.filter { $0.id != "made-ready" }, chosen: after.chosen, canGenerate: true)
        let log2 = Log()
        let m2 = await model(log2, list: after, delete: { kept })
        await m2.delete(try XCTUnwrap(m2.portraits.first { $0.id == "made-ready" }))
        XCTAssertEqual(log2.calls, ["delete made-ready"])
        XCTAssertFalse(m2.portraits.contains { $0.id == "made-ready" })
    }

    // MARK: Use this portrait

    func testUseRunsInTheWebsOrder() async throws {
        let log = Log()
        let list = try settledList()
        let chosenNow = PortraitList(portraits: list.portraits, chosen: "made-ready", canGenerate: true)
        let cut = cutout()
        var model: PortraitStudioModel?
        let m = PortraitStudioModel()
        model = m
        m.service = service(log, list: { chosenNow }, model: { model }, image: { _ in Data([1, 2, 3]) }, cutOut: { cut }, choose: { chosenNow })
        await m.use(try XCTUnwrap(list.portraits.first { $0.id == "made-ready" }))
        // Saved as the profile photo first, marked as in use only then, then the perspective; the dashboard read again.
        XCTAssertEqual(log.calls, ["image made-ready", "cutOut", "upload", "choose made-ready", "perspective portrait", "photoChanged", "list"])
        XCTAssertEqual(log.steps, [PortraitWords.loadingPortrait, PortraitWords.cuttingOut, PortraitWords.saving, PortraitWords.saving])
        XCTAssertNil(m.failed)
        XCTAssertNil(m.using)
        XCTAssertEqual(m.successes, 1, "the success haptic")
        XCTAssertEqual(m.chosen, "made-ready")
    }

    func testEachStepOfUseFailsInTheWebsWords() async throws {
        let list = try settledList()
        let ready = try XCTUnwrap(list.portraits.first { $0.id == "made-ready" })
        let cut = cutout()
        let cases: [(String, (Log) async -> PortraitStudioModel, String, [String])] = [
            ("image gone", { log in await self.model(log, list: list, image: { _ in throw APIClient.error(status: 404, message: "Not found", path: "/portraits/x/image") }) },
             PortraitWords.couldNotLoad, ["image made-ready"]),
            ("no face", { log in await self.model(log, list: list, cutOut: { throw PhotoCutout.Failure(message: "No face found. Choose a photo where your face is clearly visible.") }) },
             PortraitWords.noFace, ["image made-ready", "cutOut"]),
            ("other cut-out", { log in await self.model(log, list: list, cutOut: { throw PhotoCutout.Failure(message: "Couldn't separate you from the background.") }) },
             "Couldn't separate you from the background.", ["image made-ready", "cutOut"]),
            // processPhoto's own words for an image it can't read (src/photo/process.ts), as the web shows them here.
            ("unreadable", { log in await self.model(log, list: list, cutOut: { throw PhotoCutout.Failure(message: "Couldn't read that image. Choose a photo.") }) },
             "Couldn't read that image. Use a JPEG or PNG photo.", ["image made-ready", "cutOut"]),
            ("too large here", { log in await self.model(log, list: list, cutOut: { cut }, upload: { throw PhotoCutout.Failure(message: "That photo is too large to upload. Try another one.") }) },
             PortraitWords.tooLarge, ["image made-ready", "cutOut", "upload"]),
            ("too large there", { log in await self.model(log, list: list, cutOut: { cut }, upload: { throw APIClient.error(status: 413, message: "", path: "/profile/photo/upload") }) },
             PortraitWords.tooLarge, ["image made-ready", "cutOut", "upload"]),
            ("unreachable", { log in await self.model(log, list: list, cutOut: { cut }, upload: { throw APIError.network("Can't reach localhost.") }) },
             PortraitWords.unreachable, ["image made-ready", "cutOut", "upload"]),
            ("refused", { log in await self.model(log, list: list, cutOut: { cut }, upload: { throw APIClient.error(status: 400, message: "The photo's size doesn't match.", path: "/profile/photo/upload") }) },
             "The photo's size doesn't match.", ["image made-ready", "cutOut", "upload"]),
            ("no words", { log in await self.model(log, list: list, cutOut: { cut }, upload: { throw APIClient.error(status: 500, message: nil, path: "/profile/photo/upload") }) },
             PortraitWords.couldNotSave, ["image made-ready", "cutOut", "upload"]),
            ("gone at choose", { log in await self.model(log, list: list, cutOut: { cut }, choose: { throw APIClient.error(status: 404, message: "That portrait is gone.", path: "/portraits/x/choose") }) },
             "That portrait is gone.", ["image made-ready", "cutOut", "upload", "choose made-ready"]),
            ("offline at choose", { log in await self.model(log, list: list, cutOut: { cut }, choose: { throw APIError.network("Can't reach localhost. The Internet connection appears to be offline.") }) },
             PortraitWords.unreachable, ["image made-ready", "cutOut", "upload", "choose made-ready"]),
        ]
        for (name, make, words, calls) in cases {
            let log = Log()
            let m = await make(log)
            await m.use(ready)
            XCTAssertEqual(m.failed, PortraitStudioModel.Failed(id: "made-ready", text: words), name)
            XCTAssertEqual(log.calls, calls + ["list"], "\(name): nothing after the step that failed")
            XCTAssertEqual(m.successes, 0, name)
            XCTAssertNil(m.using, name)
        }
    }

    // MARK: Reading, waiting and images

    func testWhileOneIsBeingMadeTheListIsCheckedUntilItsDone() async throws {
        let pending = try studioList()
        let done = try settledList()
        var answers = [pending, pending, done]
        let log = Log()
        let m = PortraitStudioModel()
        m.service = service(log, list: { answers.isEmpty ? done : answers.removeFirst() }, model: { nil })
        await m.read()
        XCTAssertTrue(m.making)
        await m.poll()
        XCTAssertFalse(m.making)
        XCTAssertEqual(log.calls, ["list", "sleep", "list", "sleep", "list"], "every 3.5 s, and no more once it's ready")
        XCTAssertEqual(PortraitStudioModel.pollInterval, .milliseconds(3500))
        // Nothing being made: no checking at all.
        log.calls.removeAll()
        await m.poll()
        XCTAssertEqual(log.calls, [])
    }

    func testAnOlderServerAndAFailedRead() async throws {
        let log = Log()
        let older = await model(log, list: nil)
        XCTAssertTrue(older.missing)
        XCTAssertNil(older.list)

        var fail = true
        let list = try settledList()
        let m = PortraitStudioModel()
        m.service = service(log, list: {
            if fail { throw APIClient.error(status: 500, message: "Something went wrong. Try again in a moment.", path: "/portraits") }
            return list
        }, model: { nil })
        await m.read()
        XCTAssertEqual(m.loadError, "Something went wrong. Try again in a moment.")
        XCTAssertEqual(PortraitWords.loadFailed(try XCTUnwrap(m.loadError)), "Couldn't load your portrait photos: Something went wrong. Try again in a moment.")
        fail = false
        await m.read()
        XCTAssertNil(m.loadError)
        fail = true
        await m.read()
        XCTAssertNil(m.loadError, "a failure after a list keeps the list on screen")
        XCTAssertEqual(m.list, list)
    }

    func testAFirstReadOfflineSaysTheWebsWords() async throws {
        let log = Log()
        let m = PortraitStudioModel()
        let offline = APIClient(base: URL(string: "http://localhost:8805")!).unreachable(URLError(.notConnectedToInternet))
        m.service = service(log, list: { throw offline }, model: { nil })
        await m.read()
        XCTAssertEqual(m.loadError, PortraitWords.unreachable)
    }

    func testAddingShrinksOnThePhoneFirst() async throws {
        let log = Log()
        let m = await model(log, list: try settledList())
        await m.add { PreparedPhoto(jpeg: Data([0xFF, 0xD8]), width: 1200, height: 1600) }
        XCTAssertEqual(log.calls, ["add 1200x1600", "list"])
        XCTAssertEqual(m.successes, 1)
        XCTAssertNil(m.note)
        log.calls.removeAll()
        await m.add { nil }
        XCTAssertEqual(m.note, PortraitWords.cantOpen, "never sent when it can't be read here")
        XCTAssertEqual(log.calls, [])
    }

    func testImagesStayInMemory() async throws {
        let fm = FileManager.default
        func files() -> Set<String> {
            var all = Set<String>()
            for dir in [fm.urls(for: .cachesDirectory, in: .userDomainMask)[0], fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
                        fm.temporaryDirectory] {
                let walk = fm.enumerator(at: dir, includingPropertiesForKeys: nil)
                while let url = walk?.nextObject() as? URL { all.insert(url.path) }
            }
            return all
        }
        let figure = try XCTUnwrap(UIImage(named: "DigitalMan", in: Bundle(for: Dashboard.self), with: nil)?.pngData())
        let log = Log()
        let list = try settledList()
        let m = await model(log, list: list, image: { _ in figure })
        let before = files()
        let ready = try XCTUnwrap(list.portraits.first { $0.id == "made-ready" })
        await m.loadThumbnail(ready, maxPixel: 600)
        let thumb = try XCTUnwrap(m.thumbs["made-ready"])
        XCTAssertLessThanOrEqual(max(thumb.size.width, thumb.size.height) * thumb.scale, 600, "shrunk, not the full image")
        // Read once.
        await m.loadThumbnail(ready, maxPixel: 600)
        XCTAssertEqual(log.calls, ["image made-ready"])
        // A failed or pending one has no image to ask for.
        await m.loadThumbnail(try XCTUnwrap(list.portraits.first { $0.id == "made-failed" }), maxPixel: 600)
        XCTAssertEqual(log.calls, ["image made-ready"])
        XCTAssertEqual(files().subtracting(before), [], "nothing written to Caches, Application Support or tmp")
        // Gone from the list, gone from memory.
        let m2 = await model(log, list: list, image: { _ in figure })
        await m2.loadThumbnail(ready, maxPixel: 600)
        m2.service = service(log, list: { PortraitList(portraits: list.portraits.filter { $0.id != "made-ready" }, chosen: nil, canGenerate: true) }, model: { nil })
        await m2.read()
        XCTAssertNil(m2.thumbs["made-ready"])
    }

    func testAWriteStartedForOnePersonNeverGoesOutAsAnother() async throws {
        let d = Dashboard()
        d.phase = .ready
        d.account = AuthState.User(id: "person-a", email: nil, name: nil, role: nil)
        let a = try XCTUnwrap(d.signedInPerson)
        XCTAssertNoThrow(try SignedInPerson.check(d, is: a))
        let live = PortraitService.live(d)
        let cut = cutout()
        func refused(_ name: String, _ write: () async throws -> Void) async {
            do {
                try await write()
                XCTFail("\(name) went out")
            } catch {
                XCTAssertTrue(error is CancellationError, "\(name): \(error)")
            }
        }
        // Someone else signs in while a portrait is being used: nothing more is sent for the first person.
        d.account = AuthState.User(id: "person-b", email: nil, name: nil, role: nil)
        XCTAssertNotEqual(d.signedInPerson, a)
        await refused("upload") { try await live.upload(cut) }
        await refused("choose") { _ = try await live.choose("p1") }
        await refused("perspective") { try await live.usePortraitPerspective() }
        await refused("photo") { try await PhotoPreview.upload(cut, d, for: a) }
        // Signed out: nobody's writes go.
        d.phase = .signIn
        XCTAssertNil(d.signedInPerson)
        await refused("add") { _ = try await live.addReference(PreparedPhoto(jpeg: Data([0xFF, 0xD8]), width: 10, height: 10)) }
        await refused("make") { _ = try await live.generate("r1") }
        await refused("delete") { _ = try await live.delete("r1") }
        XCTAssertThrowsError(try SignedInPerson.check(d, is: nil), "nobody's is never anybody's")
        // The studio stays quiet about it: no note, no failure on the tile.
        let m = PortraitStudioModel(service: live)
        await m.add { PreparedPhoto(jpeg: Data([0xFF, 0xD8]), width: 10, height: 10) }
        XCTAssertNil(m.note)
        XCTAssertNil(m.busy)
        XCTAssertEqual(m.successes, 0)
    }

    func testAnIdIsOnePathSegment() {
        XCTAssertEqual(APIClient.pathPart("0f8a2c1e-9b7d-4c3a-8e2f-1a2b3c4d5e6f"), "0f8a2c1e-9b7d-4c3a-8e2f-1a2b3c4d5e6f")
        XCTAssertEqual(APIClient.pathPart("a/b c"), "a%2Fb%20c", "as encodeURIComponent")
    }

    // MARK: Use a photo as is

    func testUseAPhotoAsIsInProfilesWords() throws {
        let profile = try web("src/pages/Profile.tsx")
        for words in [PhotoWords.title, PhotoWords.line, PhotoWords.previewLine, PhotoWords.tooLarge, PhotoWords.couldNotSave,
                      "'\(PhotoWords.choose)'", "'\(PhotoWords.chooseAgain)'", "'\(PhotoWords.save)'", "'\(PhotoWords.saving)'",
                      "Remove photo", "Cancel", "alt=\"\(PhotoWords.current)\"", "alt=\"\(PhotoWords.newCutout)\"", "alt=\"\(PhotoWords.newAvatar)\""] {
            XCTAssertTrue(profile.contains(words), words)
        }
        // The hosted sentence, since the iPhone always cuts out on the device.
        XCTAssertTrue(profile.contains("? \"\(PhotoWords.line)\""))
        XCTAssertEqual(PhotoWords.saveFailure(APIClient.error(status: 413, message: "x", path: "/profile/photo/upload")), PhotoWords.tooLarge)
        XCTAssertEqual(PhotoWords.saveFailure(PhotoCutout.Failure(message: "That photo is too large to upload. Try another one.")), PhotoWords.tooLarge)
        XCTAssertEqual(PhotoWords.saveFailure(APIClient.error(status: 404, message: "Not found", path: "/profile/photo/upload")), PhotoWords.notHere,
                       "an older server without the route")
        XCTAssertEqual(PhotoWords.saveFailure(APIClient.error(status: 400, message: "Missing cutout", path: "/profile/photo/upload")), "Missing cutout")
        XCTAssertEqual(PhotoWords.saveFailure(APIClient.error(status: 500, message: nil, path: "/profile/photo/upload")), PhotoWords.couldNotSave)
        // The cut-out's failures in the web's words (src/photo/process.ts).
        let process = try web("src/photo/process.ts")
        XCTAssertTrue(process.contains(PhotoWords.noFace))
        XCTAssertTrue(process.contains(PhotoWords.unreadable))
        XCTAssertEqual(PhotoWords.cutOutFailure(PhotoCutout.Failure(message: "No face found. Choose a photo where your face is clearly visible.")), PhotoWords.noFace)
        XCTAssertEqual(PhotoWords.cutOutFailure(PhotoCutout.Failure(message: "Couldn't read that image. Choose a photo.")), PhotoWords.unreadable)
        XCTAssertEqual(PhotoWords.cutOutFailure(PhotoCutout.Failure(message: "Couldn't separate you from the background.")),
                       "Couldn't separate you from the background.")
        XCTAssertTrue(process.contains("Couldn't separate you from the background."))
    }

    // MARK: Look

    /// The studio in each state, and the photo's preview, draw light and dark, at the default and the largest text size.
    /// With HOS_SNAPSHOTS set, each is saved there to look at.
    func testEachStateDraws() async throws {
        let figure = try XCTUnwrap(UIImage(named: "DigitalMan", in: Bundle(for: Dashboard.self), with: nil)?.pngData())
        let list = try studioList()
        let log = Log()
        let full = await model(log, list: list, image: { _ in figure })
        for p in list.portraits { await full.loadThumbnail(p, maxPixel: 600) }
        let empty = await model(log, list: PortraitList(portraits: [], chosen: nil, canGenerate: false))
        let one = await model(log, list: PortraitList(portraits: [list.portraits[0]], chosen: nil, canGenerate: false), image: { _ in figure })
        await one.loadThumbnail(list.portraits[0], maxPixel: 240)
        let refs = (1...5).map { Portrait(id: "r\($0)", kind: "reference", status: "ready", createdAt: 1_761_300_000_000) }
        let five = await model(log, list: PortraitList(portraits: refs, chosen: nil, canGenerate: true))
        let failedUse = await model(log, list: try settledList(), image: { _ in throw APIError.network("x") })
        await failedUse.use(try XCTUnwrap(list.portraits.first { $0.id == "made-ready" }))
        let refused = await model(log, list: try settledList(), generate: { throw APIClient.error(status: 429, message: "You've made 10 portraits today, the most in a day. Try again tomorrow.", path: "/portraits/generate") })
        await refused.make(from: refused.references[0])
        let states: [(String, PortraitStudioModel, Bool?, Bool)] = [
            ("empty-connect", empty, true, false), ("empty-not-here", empty, false, false), ("one-reference", one, true, false),
            ("tiles", full, true, true), ("five", five, true, false), ("use-failed", failedUse, true, false), ("day-limit", refused, true, false),
        ]
        for (name, model, byok, ownKey) in states {
            for scheme in [ColorScheme.light, .dark] {
                for size in [DynamicTypeSize.large, .accessibility5] {
                    let view = PortraitStudioContent(model: model, byok: byok, ownKey: ownKey)
                        .padding(18).frame(width: 343).background(Palette.page)
                        .environment(\.colorScheme, scheme).dynamicTypeSize(size)
                    let image = try XCTUnwrap(Snapshot.render(view, scale: size == .large ? 3 : 1), name)
                    XCTAssertGreaterThan(image.size.height, 40, name)
                    Snapshot.save(image, "portraits-\(name)-\(scheme == .dark ? "dark" : "light")\(size == .large ? "" : "-ax5")")
                }
            }
        }
        let cut = try XCTUnwrap(UIImage(named: "DigitalMan", in: Bundle(for: Dashboard.self), with: nil)?.cgImage)
        let photo = PhotoCutout(cutout: cut, avatar: cut, meta: [:])
        for scheme in [ColorScheme.light, .dark] {
            let view = PhotoPreviewRow(photo: photo, saving: false, save: {}, cancel: {})
                .padding(18).frame(width: 343).background(Palette.page).environment(\.colorScheme, scheme)
            let image = try XCTUnwrap(Snapshot.render(view))
            Snapshot.save(image, "photo-preview-\(scheme == .dark ? "dark" : "light")")
        }
    }
}
