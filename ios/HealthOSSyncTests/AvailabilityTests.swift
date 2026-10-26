import XCTest
@testable import HealthOSSync

/// What the server can do for the person (Shell/Availability.swift), read from its own answers: GET /api/ai, McFly's
/// status, the food log's `can`, the portrait list and the lab reader; and an older server's missing routes.
/// ai.json, labs-reader.json and mcfly.json are a local server's answers (demo data, no keys); ai-own-key.json,
/// portraits.json and food-log-day.json are written by hand from shared/ai.ts, shared/portraits.ts and shared/foodday.ts.
@MainActor
final class AvailabilityTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = Bundle(for: Self.self).url(forResource: name, withExtension: "json")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name).json")
        return try XCTUnwrap(try? Data(contentsOf: url), "missing fixture \(name).json")
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    // MARK: An older server's missing routes

    func testOnlyTheCatchAllsNotFoundIsAMissingRoute() {
        // This branch's catch-all, and an older server with no JSON at all.
        XCTAssertTrue(APIClient.error(status: 404, message: "Not found", path: "/journal").routeMissing)
        XCTAssertTrue(APIClient.error(status: 404, message: nil, path: "/ai").routeMissing)
        XCTAssertTrue(APIClient.error(status: 404, message: "", path: "/peers").routeMissing)
        // A route's own 404s mean the route is there.
        XCTAssertFalse(APIClient.error(status: 404, message: "No such entry", path: "/body/entries/x").routeMissing)
        XCTAssertFalse(APIClient.error(status: 404, message: "Unknown metric", path: "/metric/nope").routeMissing)
        // Other answers aren't either.
        XCTAssertFalse(APIClient.error(status: 400, message: "Not found", path: "/journal").routeMissing)
        XCTAssertFalse(APIClient.error(status: 401, message: "Sign in required", path: "/journal").routeMissing)
        XCTAssertFalse(APIError.network("Can't reach the server.").routeMissing)
    }

    func testAFeaturesNotSetUpKeepsTheServersWords() {
        let keys = APIClient.error(status: 503, message: "Connecting your own key isn't set up on this server.", path: "/ai/keys/openai")
        XCTAssertEqual(keys.notSetUpHere, "Connecting your own key isn't set up on this server.")
        XCTAssertEqual(keys.errorDescription, "Connecting your own key isn't set up on this server.", "no 'Server answered 503'")
        XCTAssertNil(APIClient.error(status: 500, message: "Something went wrong", path: "/ai").notSetUpHere)
    }

    func testTheServersOwnWordsForLinksAndLargePhotos() {
        // A link that's used up (404) and a reset's refusal are written for people.
        XCTAssertEqual(APIClient.error(status: 404, message: "This code or link is invalid, expired or already used.", path: "/auth/link").errorDescription,
                       "This code or link is invalid, expired or already used.")
        XCTAssertEqual(APIClient.error(status: 404, message: "This reset link is invalid, expired or already used.", path: "/auth/reset").errorDescription,
                       "This reset link is invalid, expired or already used.")
        // A photo too large: the server's own sentence.
        XCTAssertEqual(APIClient.error(status: 413, message: "That photo is too large to save. Choose it again: healthOS shrinks it on your device.",
                                       path: "/portraits/reference").errorDescription,
                       "That photo is too large to save. Choose it again: healthOS shrinks it on your device.")
        guard case .server(413, _) = APIClient.error(status: 413, message: "x", path: "/profile/photo/upload") else { return XCTFail("callers still see the code") }
    }

    // MARK: Reading the flags

    func testDecodesWhatTheServerSays() throws {
        let local = try JSONDecoder().decode(AiStatus.self, from: fixture("ai"))
        XCTAssertEqual(local, AiStatus(), "a local server without keys: everything off")

        let own = try JSONDecoder().decode(AiStatus.self, from: fixture("ai-own-key"))
        XCTAssertTrue(own.byok)
        XCTAssertEqual(own.keys.map(\.provider), ["openai", "anthropic"], "a key the app can't read is left out")
        XCTAssertEqual(own.key("openai")?.last4, "Q7xa")
        XCTAssertEqual(own.key("anthropic")?.lastError, "That key wasn't accepted by Claude.")
        XCTAssertEqual(own.chat, AiStatus.Use(provider: "openai", source: "own", model: "gpt-5.1"))
        XCTAssertEqual(own.estimate?.source, "own")
        XCTAssertTrue(own.voice && own.portraits)

        // One odd field leaves the rest.
        let odd = try decode(AiStatus.self, #"{"byok":"yes","keys":7,"voice":true,"chat":{"provider":1}}"#)
        XCTAssertEqual(odd, AiStatus(voice: true))

        let reader = try JSONDecoder().decode(LabReader.self, from: fixture("labs-reader"))
        XCTAssertEqual(reader, LabReader(source: nil, reason: "none", limit: 0, usedToday: 0))

        let list = try JSONDecoder().decode(PortraitList.self, from: fixture("portraits"))
        XCTAssertEqual(list.portraits.map(\.id), ["r1", "g1", "g2"])
        XCTAssertEqual(list.references.map(\.id), ["r1"])
        XCTAssertEqual(list.chosen, "g2")
        XCTAssertEqual(list.canGenerate, true)
        XCTAssertEqual(try decode(PortraitList.self, #"{"portraits":[],"chosen":null,"canGenerate":false}"#).canGenerate, false)
    }

    func testMcFlysStatusReadsTheNewFieldsAndTheOldShape() throws {
        // A local server with no assistant, from before provider and source.
        let local = try JSONDecoder().decode(McFlyStatus.self, from: fixture("mcfly"))
        XCTAssertFalse(local.configured)
        XCTAssertNil(local.source)
        XCTAssertEqual(McFlyState(local), .notSetUp)

        // On a person's own key: 200 is its anti-abuse cap, not the shared limit, so it's never "off".
        let own = try decode(McFlyStatus.self, #"{"configured":true,"limit":200,"usedToday":3,"provider":"openai","source":"own","limited":false}"#)
        XCTAssertEqual(own.provider, "openai")
        XCTAssertEqual(own.limited, false)
        XCTAssertEqual(McFlyState(own), .available)
        XCTAssertEqual(McFlyState(try decode(McFlyStatus.self, #"{"configured":true,"limit":0,"usedToday":0,"source":"own"}"#)), .available)

        // The shared key with the admin's limit at 0: turned off.
        XCTAssertEqual(McFlyState(try decode(McFlyStatus.self, #"{"configured":true,"limit":0,"usedToday":0,"source":"shared","limited":true}"#)), .off)
        XCTAssertEqual(McFlyState(try decode(McFlyStatus.self, #"{"configured":true,"limit":30,"usedToday":30}"#)), .available, "out of questions is still on")
        XCTAssertEqual(McFlyState(nil), .unknown)
        // Odd counts don't lose the status.
        XCTAssertEqual(try decode(McFlyStatus.self, #"{"configured":true,"limit":30.0,"usedToday":"2"}"#).limit, 30)
    }

    func testTheFoodLogsCanReadsOlderAndNewerServers() throws {
        let old = try decode(FoodLog.Can.self, #"{"estimate":true,"usda":false}"#)
        XCTAssertEqual(old, FoodLog.Can(estimate: true, usda: false))
        XCTAssertNil(old.voice, "an older server says nothing about voice notes")
        let new = try decode(FoodLog.Can.self, #"{"estimate":true,"usda":true,"estimateProvider":"openai","estimateSource":"own","voice":true}"#)
        XCTAssertEqual(new.estimateProvider, "openai")
        XCTAssertEqual(new.voice, true)

        let day = try JSONDecoder().decode(FoodLogDay.self, from: fixture("food-log-day"))
        XCTAssertEqual(day.mode, .noEnergy)
        XCTAssertEqual(day.date, "2026-10-23")
        XCTAssertEqual(day.entries.map(\.id), ["e1", "e2"], "an entry the app can't read is left out, not the day")
        XCTAssertEqual(day.balance?["protein_g"], 38)
        XCTAssertNil(day.balance?["energy_kcal"], "never energy in no_energy")
        XCTAssertEqual(day.countedApp, "healthOS")
        XCTAssertEqual(day.can?.estimateSource, "shared")
    }

    // MARK: The model

    private func model() -> (Availability, McFlyChat) {
        let chat = McFlyChat()
        return (Availability(chat: chat), chat)
    }

    func testNothingIsSaidUntilTheServerSaysIt() async {
        let (a, _) = model()
        XCTAssertEqual(a.ai, .unknown)
        XCTAssertNil(a.byok)
        XCTAssertNil(a.portraits)
        XCTAssertNil(a.voice)
        XCTAssertNil(a.estimate)
        XCTAssertNil(a.labReading)
        XCTAssertEqual(a.mcflyState, .unknown)

        // A read that fails (offline) leaves it unknown, rather than "not on this server".
        await a.loadAI { throw APIError.network("Can't reach the server.") }
        XCTAssertEqual(a.ai, .unknown)
        XCTAssertNil(a.byok)
    }

    func testTheFlagsFollowTheServer() async {
        let (a, chat) = model()
        // A server without keys (production today has neither OPENAI_API_KEY nor HEALTHOS_DATA_KEY): every flag off.
        await a.loadAI { AiStatus(shared: true, estimate: AiStatus.Use(provider: "anthropic", source: "shared")) }
        XCTAssertEqual(a.byok, false)
        XCTAssertEqual(a.portraits, false)
        XCTAssertEqual(a.voice, false)
        XCTAssertEqual(a.estimate, true)
        XCTAssertEqual(a.estimateProvider, "anthropic")

        // Keys added since: the next load's read says so. Nothing is assumed about any server.
        a.loadedAgain()
        await a.loadAI { AiStatus(byok: true, voice: true, portraits: true) }
        XCTAssertEqual(a.byok, true)
        XCTAssertEqual(a.portraits, true)
        XCTAssertEqual(a.voice, true)
        XCTAssertEqual(a.estimate, false)

        // The pages' own answers come first: the food log's can, the portrait list's canGenerate.
        a.heard(foodCan: FoodLog.Can(estimate: true, estimateProvider: "openai", voice: false))
        a.heard(foodCan: nil)
        XCTAssertEqual(a.voice, false, "a read without a can keeps the last one")
        XCTAssertEqual(a.estimate, true)
        XCTAssertEqual(a.estimateProvider, "openai")
        a.heard(canGeneratePortraits: false)
        XCTAssertEqual(a.portraits, false)

        // McFly's status is the conversation's, seen here.
        chat.status = McFlyStatus(configured: true, limit: 0, usedToday: 0, source: "shared")
        XCTAssertEqual(a.mcflyState, .off)
        XCTAssertEqual(a.mcfly?.limit, 0)

        a.heard(labReader: LabReader(source: "shared", limit: 30))
        XCTAssertEqual(a.labReading, true)
        a.heard(labReader: LabReader(reason: "off"))
        XCTAssertEqual(a.labReading, false)
    }

    /// A key connected or removed changes what reads a meal and whether voice notes work at once, on Nutrition too: the
    /// server works the food log's flags out from the same AiStatus (server/foodlog.ts canFor), so a newer one
    /// replaces what the last log read said, keeping its USDA flag.
    func testAKeyChangeReachesTheFoodLogsFlagsAtOnce() async throws {
        let (a, _) = model()
        let shared = FoodLog.Can(estimate: true, usda: true, estimateProvider: "anthropic", estimateSource: "shared", voice: false)
        a.heard(foodCan: shared)
        XCTAssertEqual(a.estimateProvider, "anthropic")

        // An OpenAI key saved in the Chatbot sheet: its answer says OpenAI reads meals now, on the person's key.
        let own = AiStatus(byok: true, keys: [AiStatus.Key(provider: "openai", last4: "Q7xa")],
                           estimate: AiStatus.Use(provider: "openai", source: "own"), voice: true, portraits: true)
        a.heard(ai: own)
        XCTAssertEqual(a.estimate, true)
        XCTAssertEqual(a.estimateProvider, "openai")
        XCTAssertEqual(a.voice, true)
        XCTAssertEqual(a.foodCan, FoodLog.Can(estimate: true, usda: true, estimateProvider: "openai", estimateSource: "own", voice: true))
        guard case .using(let line)? = NutritionChat.setupLine(can: a.foodCan, ai: a.ai.value, mode: .all) else {
            return XCTFail("Nutrition's line says who reads a meal")
        }
        XCTAssertTrue(line.hasPrefix("Using your own OpenAI key"), line)

        // Removed, on a server with no shared key left: nothing reads a meal, and no voice notes.
        a.heard(ai: AiStatus(byok: true))
        XCTAssertEqual(a.estimate, false)
        XCTAssertNil(a.estimateProvider)
        XCTAssertEqual(a.voice, false)
        XCTAssertEqual(a.foodCan, FoodLog.Can(estimate: false, usda: true, voice: false))
        XCTAssertEqual(NutritionChat.setupLine(can: a.foodCan, ai: a.ai.value, mode: .all), .connectOpenAI)

        // The next load's GET /api/ai, after a key was added elsewhere, is as new.
        a.loadedAgain()
        await a.loadAI { AiStatus(byok: true, estimate: AiStatus.Use(provider: "gemini", source: "own")) }
        XCTAssertEqual(a.estimateProvider, "gemini")
        XCTAssertEqual(a.foodCan?.estimateSource, "own")
        XCTAssertEqual(a.foodCan?.usda, true)

        // Before any log is read there's nothing to update: the flags read the AiStatus.
        let (fresh, _) = model()
        fresh.heard(ai: own)
        XCTAssertNil(fresh.foodCan)
        XCTAssertEqual(fresh.estimateProvider, "openai")
    }

    func testAnOlderServerHidesWhatItDoesntHave() async {
        let (a, _) = model()
        // GET /api/ai answered 404: no keys, portraits or voice notes there.
        await a.loadAI { nil }
        XCTAssertEqual(a.ai, .missing)
        XCTAssertTrue(a.aiMissing)
        XCTAssertEqual(a.byok, false)
        XCTAssertEqual(a.portraits, false)
        XCTAssertEqual(a.voice, false)
        // Estimates still work from the food log's own flag, unknown until it's read.
        XCTAssertNil(a.estimate)
        a.heard(foodCan: FoodLog.Can(estimate: true, usda: true))
        XCTAssertEqual(a.estimate, true)
        XCTAssertEqual(a.voice, false, "an older food log says nothing of voice notes, and /api/ai isn't there")

        await a.loadLabReader { nil }
        XCTAssertEqual(a.labReader, .missing)
        XCTAssertEqual(a.labReading, false)
    }

    func testReadOncePerLoad() async {
        let (a, _) = model()
        var reads = 0
        await a.loadAI { reads += 1; return AiStatus() }
        await a.loadAI { reads += 1; return AiStatus(byok: true) }
        XCTAssertEqual(reads, 1, "a page asking again before the next load reads nothing")
        XCTAssertEqual(a.byok, false)
        await a.loadAI(force: true) { reads += 1; return AiStatus(byok: true) }
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(a.byok, true)
        a.loadedAgain()
        await a.loadAI { reads += 1; throw APIError.network("offline") }
        XCTAssertEqual(reads, 3)
        XCTAssertEqual(a.byok, true, "a failed read keeps what was known")

        // A key saved: its answer is the status, so nothing is read again.
        a.loadedAgain()
        a.heard(ai: AiStatus(byok: true, keys: [AiStatus.Key(provider: "openai", last4: "Q7xa")]))
        await a.loadAI { reads += 1; return AiStatus() }
        XCTAssertEqual(reads, 3)
        XCTAssertEqual(a.ai.value?.key("openai")?.last4, "Q7xa")
    }

    func testForgottenWithThePersonAndNothingLandsAfter() async {
        let (a, _) = model()
        a.heard(ai: AiStatus(byok: true))
        a.heard(foodCan: FoodLog.Can(estimate: true))
        a.heard(canGeneratePortraits: true)
        a.heard(labReader: LabReader(source: "own"))
        a.forget()
        XCTAssertEqual(a.ai, .unknown)
        XCTAssertNil(a.foodCan)
        XCTAssertNil(a.canGeneratePortraits)
        XCTAssertEqual(a.labReader, .unknown)

        // A read on its way when the person signed out lands on no one.
        var release: CheckedContinuation<Void, Never>?
        let reading = Task { @MainActor in
            await a.loadAI {
                await withCheckedContinuation { release = $0 }
                return AiStatus(byok: true)
            }
        }
        while release == nil { await Task.yield() }
        a.forget()
        release?.resume()
        await reading.value
        XCTAssertEqual(a.ai, .unknown)
    }

    func testTheDashboardForgetsItOnSignInAndSignOut() async {
        let saved = UserDefaults.standard.string(forKey: "serverURL")
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: "serverURL") } else { UserDefaults.standard.removeObject(forKey: "serverURL") }
        }
        // No server: Sign out doesn't call one.
        Config.serverText = ""
        let d = Dashboard()
        d.availability.heard(ai: AiStatus(byok: true))
        d.signedIn()
        XCTAssertEqual(d.availability.ai, .unknown, "someone else may have signed in")

        d.availability.heard(ai: AiStatus(byok: true))
        d.mcfly.status = McFlyStatus(configured: true, limit: 30, usedToday: 1)
        XCTAssertEqual(d.availability.mcflyState, .available, "the conversation's status, seen through the dashboard's")
        await d.signOut()
        XCTAssertEqual(d.availability.ai, .unknown)
        XCTAssertEqual(d.availability.mcflyState, .unknown)
    }

    func testTheWebsWordsAreQuotedAsTheyAre() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func web(_ path: String) throws -> String {
            guard let text = try? String(contentsOf: url.appendingPathComponent(path), encoding: .utf8) else { throw XCTSkip("\(path) isn't next to the app") }
            return text
        }
        let sheets = try web("src/components/ai/AiSheets.tsx")
        for words in [ServerWords.keysNotHere, ServerWords.mcflyNotOnServer, ServerWords.mcflyNeedsKey, ServerWords.estimatesNotHere, ServerWords.voiceAndPortraitsNotHere] {
            XCTAssertTrue(sheets.contains(words), words)
        }
        let chat = try web("src/pages/NutritionChat.tsx")
        XCTAssertTrue(chat.contains(ServerWords.voiceNeedsKeyNotHere))
        XCTAssertTrue(chat.contains(ServerWords.estimatesNeedKeyNotHere))
        XCTAssertTrue(try web("src/components/portraits/PortraitStudio.tsx").contains(ServerWords.portraitNeedsKeyNotHere))
        XCTAssertTrue(try web("src/pages/Home.tsx").contains(ServerWords.homePortraitNotHere))
        XCTAssertTrue(try web("src/pages/Labs.tsx").contains(ServerWords.labReadingNotHere))
        let mcfly = try web("src/pages/McFly.tsx")
        XCTAssertTrue(mcfly.contains(ServerWords.mcflyNotSetUp))
        XCTAssertTrue(mcfly.contains(ServerWords.mcflyOff))
    }
}
