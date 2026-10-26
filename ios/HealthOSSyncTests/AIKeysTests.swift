import XCTest
@testable import HealthOSSync

/// Profile's two key sheets (AI/), against the web's own src/components/ai/AiSheets.tsx and server/ai/routes.ts:
/// their words, which choice and button the Chatbot sheet offers in each state, what each save sends, the server's
/// own words when a key is refused, and that a key is never kept: not after a save, not in what the app stores, not
/// for whoever signs in next. ai.json is a local server's answer (no keys can be stored); ai-own-key.json a person
/// with their own keys. No test reaches a provider or uses a real key.
@MainActor
final class AIKeysTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = Bundle(for: Self.self).url(forResource: name, withExtension: "json")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name).json")
        return try Data(contentsOf: url)
    }

    private func status(_ name: String) throws -> AiStatus { try JSONDecoder().decode(AiStatus.self, from: fixture(name)) }
    private func status(json: String) throws -> AiStatus { try JSONDecoder().decode(AiStatus.self, from: Data(json.utf8)) }

    private func web(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard let text = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) else { throw XCTSkip("\(path) isn't next to the app") }
        return text
    }

    /// The parts of `words` around each filled-in value are in the web's file: a template's fixed text.
    private func assertTemplate(_ words: String, filling values: [String], in source: String, file: StaticString = #filePath, line: UInt = #line) {
        var parts = [words]
        for v in values { parts = parts.flatMap { $0.components(separatedBy: v) } }
        for part in parts where !part.trimmingCharacters(in: .whitespaces).isEmpty {
            XCTAssertTrue(source.contains(part), "“\(part)” isn't in the web's file", file: file, line: line)
        }
    }

    /// A key the providers would never accept, made up for these tests.
    private let madeUpKey = "sk-test-not-a-real-key-0000000000wxyz"

    // MARK: The web's words

    func testEveryFixedLineIsTheWebs() throws {
        let sheets = try web("src/components/ai/AiSheets.tsx")
        for words in [
            AIWords.notHere, AIWords.geminiTip, AIWords.sharedAnswers, AIWords.openAILede, AIWords.openAIConnected, AIWords.openAIChatbotNote,
            AIWords.whereQuestionsGo(.shared), "Using healthOS's shared Claude",
            AIWords.problem("auth")!, AIWords.problem("quota")!, AIWords.problem("unreadable")!,
            AIWords.chatbotRemoveConsequence(AiStatus(shared: true, chatChoice: "openai"), .openai),
            AIWords.chatbotRemoveConsequence(AiStatus(shared: false, chatChoice: "openai"), .openai),
            AIWords.openAIRemoveConsequence(AiStatus(shared: true, chatChoice: "openai")),
            AIWords.openAIRemoveConsequence(AiStatus(shared: false, chatChoice: "openai")),
            AIWords.openAIPortraits(connected: true, serverPortraits: false), AIWords.openAIPortraits(connected: false, serverPortraits: true),
            AIWords.openAIPortraits(connected: false, serverPortraits: false),
            "Until then, meal estimates use your Claude key.", "Until then, meal estimates use healthOS's shared Claude.",
            "Meal estimates need this key, or a Claude key in Chatbot.", "Voice notes and portraits use the server's OpenAI key.",
            "Voice notes and portraits need this key.",
            // The sheets' own words: eyebrows, titles, buttons, fields.
            "Manage chatbot AI", "Chatbot", "OpenAI · Nutrition & portraits", "Connect AI key", "Who answers Ask McFly", "Key added",
            "healthOS shared", "Verify & save", "In use", "Use the shared assistant", "Replace", "Remove key", "Keep it", "Removing…",
            "Needs attention", "Paste your key", "The default model", "(optional)", "Loading…", "Ask McFly now uses healthOS's shared Claude.",
            "Your OpenAI key is removed.", "Checking with OpenAI…", "Close", "Cancel", "Done",
        ] {
            XCTAssertTrue(sheets.contains(words), "“\(words)” isn't in AiSheets.tsx")
        }
        // Lines the web writes as templates: their fixed text, around each value.
        for p in AIProvider.allCases {
            assertTemplate(AIWords.whereQuestionsGo(.own(p)), filling: [p.company], in: sheets)
            assertTemplate(AIWords.confirmRemove(p, consequence: ""), filling: [p.label], in: sheets.replacingOccurrences(of: "{LABEL[provider]}", with: "").replacingOccurrences(of: "{consequence} ", with: ""))
        }
        // The where-panel's first line is two halves either side of a choice.
        XCTAssertTrue(sheets.contains("'Meal photos, descriptions and voice notes go'"))
        XCTAssertTrue(sheets.contains("'Once your key is connected, meal photos, descriptions and voice notes go'"))
        XCTAssertTrue(AIWords.openAIWhere(connected: true).hasSuffix(" to OpenAI on your key, for that one request, and aren't kept by healthOS. Estimates and voice notes on your key don't count toward healthOS's daily limits."))
        XCTAssertTrue(sheets.replacingOccurrences(of: "\n                ", with: " ").contains("to OpenAI on your key, for that one request, and aren't kept by healthOS. Estimates and voice notes on your key don't count toward healthOS's daily limits."))
    }

    func testTheProvidersAreTheWebsInItsOrderWithItsNames() throws {
        let shared = try web("shared/ai.ts")
        XCTAssertTrue(shared.contains("{ provider: 'openai', label: 'OpenAI' },\n  { provider: 'anthropic', label: 'Claude' },\n  { provider: 'gemini', label: 'Gemini' },"))
        XCTAssertEqual(AIProvider.allCases.map(\.rawValue), ["openai", "anthropic", "gemini"])
        XCTAssertEqual(AIProvider.allCases.map(\.label), ["OpenAI", "Claude", "Gemini"])
        let sheets = try web("src/components/ai/AiSheets.tsx")
        XCTAssertTrue(sheets.contains("const COMPANY: Record<AiProvider, string> = { openai: 'OpenAI', anthropic: 'Anthropic', gemini: 'Google' };"))
        XCTAssertEqual(AIProvider.allCases.map(\.company), ["OpenAI", "Anthropic", "Google"])
        XCTAssertEqual(AIProvider.label("anthropic"), "Claude")
        XCTAssertEqual(AIProvider.label("mistral"), "mistral", "a provider from a newer server keeps its id")
        // The server's own words when a key is refused: the routes' (shown as they are, see below).
        let routes = try web("server/ai/routes.ts")
        XCTAssertTrue(routes.contains("That key wasn't accepted by ${label}."))
        XCTAssertTrue(routes.contains("Couldn't reach ${label} to check the key. Try again in a moment."))
    }

    // MARK: What the sheets say

    func testTheLineAtTheTopSaysWhatAskMcFlyUsesNow() throws {
        XCTAssertEqual(AIWords.using(try status("ai")), ServerWords.mcflyNotOnServer, "nothing set up and no keys here")
        XCTAssertEqual(AIWords.using(AiStatus(byok: true)), ServerWords.mcflyNeedsKey)
        XCTAssertEqual(AIWords.using(try status("ai-own-key")), "Using your OpenAI key ending Q7xa")
        XCTAssertEqual(AIWords.using(AiStatus(byok: true, shared: true, chat: .init(provider: "anthropic", source: "shared", model: "claude-x"))), "Using healthOS's shared Claude")
        XCTAssertEqual(AIWords.using(AiStatus(byok: true, chat: .init(provider: "gemini", source: "own"))), "Using your Gemini key", "no last 4 known: none shown")
    }

    func testWhatRunsUntilAnOpenAIKeyIsConnected() throws {
        // A local server: no keys can be stored, nothing estimates, no voice notes.
        XCTAssertEqual(AIWords.instead(try status("ai")), "\(ServerWords.estimatesNotHere) \(ServerWords.voiceAndPortraitsNotHere)")
        // Production as the plan describes it: the shared Claude estimates, no OpenAI key, no data key.
        XCTAssertEqual(AIWords.instead(AiStatus(shared: true, estimate: .init(provider: "anthropic", source: "shared"))),
                       "Until then, meal estimates use healthOS's shared Claude. \(ServerWords.voiceAndPortraitsNotHere)")
        XCTAssertEqual(AIWords.instead(AiStatus(byok: true, estimate: .init(provider: "anthropic", source: "own"), voice: true, portraits: true)),
                       "Until then, meal estimates use your Claude key. Voice notes and portraits use the server's OpenAI key.")
        XCTAssertEqual(AIWords.instead(AiStatus(byok: true)), "Meal estimates need this key, or a Claude key in Chatbot. Voice notes and portraits need this key.")
    }

    func testRemovingAKeySaysWhatHappensToAskMcFlyWithNoDoubleSpaces() {
        let usesOpenAI = AiStatus(byok: true, shared: true, chatChoice: "openai")
        XCTAssertEqual(AIWords.confirmRemove(.openai, consequence: AIWords.chatbotRemoveConsequence(usesOpenAI, .openai)),
                       "Remove your OpenAI key from healthOS? Ask McFly goes back to healthOS's shared Claude. You can connect it again anytime.")
        XCTAssertEqual(AIWords.confirmRemove(.gemini, consequence: AIWords.chatbotRemoveConsequence(usesOpenAI, .gemini)),
                       "Remove your Gemini key from healthOS? You can connect it again anytime.", "a key the chat doesn't use changes nothing for it")
        XCTAssertEqual(AIWords.openAIRemoveConsequence(AiStatus(byok: true, chatChoice: "openai")), "Ask McFly stops too, until you connect a key.")
        XCTAssertEqual(AIWords.openAIRemoveConsequence(AiStatus(byok: true, chatChoice: "anthropic")), "")
    }

    func testAStoredKeysTroubleIsAKindNeverTheProvidersText() throws {
        XCTAssertNotNil(AIWords.problem("auth"))
        XCTAssertNil(AIWords.problem(nil))
        // A kind this app doesn't know: the badge still says it needs attention, with no line under it.
        let own = try status("ai-own-key")
        XCTAssertNotNil(own.key("anthropic")?.lastError)
        XCTAssertNil(AIWords.problem(own.key("anthropic")?.lastError))
        // The server only ever writes these kinds (keys.ts noteKeyUse).
        let keys = try web("server/ai/keys.ts")
        XCTAssertTrue(keys.contains("error: 'auth' | 'quota' | 'unreadable' | null"))
    }

    // MARK: The Chatbot sheet's choices and buttons

    func testTheSheetOpensOnWhatTheChatUsesElseTheSharedAssistantElseOpenAI() throws {
        XCTAssertEqual(ChatbotForm.opening(try status("ai")), .shared, "keys can't be stored here: the shared line only")
        XCTAssertEqual(ChatbotForm.opening(try status("ai-own-key")), .own(.openai))
        XCTAssertEqual(ChatbotForm.opening(AiStatus(byok: true, shared: true)), .shared)
        XCTAssertEqual(ChatbotForm.opening(AiStatus(byok: true, shared: false)), .own(.openai), "no shared assistant: the first provider")
        XCTAssertEqual(ChatbotForm.opening(AiStatus(byok: true, chatChoice: "gemini")), .own(.gemini))
    }

    func testChoosingACardStartsOverWithThatKeysModel() throws {
        let s = try status("ai-own-key")
        var form = ChatbotForm()
        form.choose(.own(.openai), s)
        form.key = madeUpKey
        form.replacing = true
        form.choose(.own(.anthropic), s)
        XCTAssertEqual(form, ChatbotForm(pick: .own(.anthropic), key: "", model: "claude-sonnet-4-5"), "nothing typed carries over to another provider")
        form.choose(.shared, s)
        XCTAssertEqual(form.model, "")
    }

    func testTheMainButtonInEachStateAsTheWebOffersIt() throws {
        let s = try status("ai-own-key") // chat on OpenAI; OpenAI and Claude keys stored; shared on
        var form = ChatbotForm()

        form.choose(.shared, s)
        XCTAssertTrue(form.primary(s, busy: false) == ("Use the shared assistant", true))
        form.choose(.own(.openai), s)
        XCTAssertFalse(form.entering(s), "a stored key isn't typed again unless it's replaced")
        XCTAssertTrue(form.primary(s, busy: false) == ("Save", false), "nothing changed")
        form.model = " gpt-5.1-mini "
        XCTAssertTrue(form.primary(s, busy: false) == ("Save", true))
        form.choose(.own(.anthropic), s)
        XCTAssertTrue(form.primary(s, busy: false) == ("Use Claude", true))
        form.choose(.own(.gemini), s)
        XCTAssertTrue(form.entering(s))
        XCTAssertTrue(form.primary(s, busy: false) == ("Verify & save", false), "no key typed yet")
        form.key = "   "
        XCTAssertTrue(form.primary(s, busy: false) == ("Verify & save", false), "spaces aren't a key")
        form.key = madeUpKey
        XCTAssertTrue(form.primary(s, busy: false) == ("Verify & save", true))
        XCTAssertTrue(form.primary(s, busy: true) == ("Checking with Gemini…", false))

        form.choose(.own(.openai), s)
        form.replacing = true
        XCTAssertTrue(form.entering(s))
        XCTAssertTrue(form.primary(s, busy: false) == ("Verify & save", false))

        let sharedNow = AiStatus(byok: true, shared: true)
        form.choose(.shared, sharedNow)
        XCTAssertTrue(form.primary(sharedNow, busy: false) == ("In use", false))
    }

    func testWhatEachSaveSendsAndSays() throws {
        let s = try status("ai-own-key")
        var form = ChatbotForm()

        form.choose(.shared, s)
        XCTAssertEqual(form.save(s)?.steps, [.useChat(.shared)])
        XCTAssertEqual(form.save(s)?.done, "Ask McFly now uses healthOS's shared Claude.")

        // A new key: checked and stored with its model, then chosen.
        form.choose(.own(.gemini), s)
        XCTAssertNil(form.save(s), "nothing to send without a key")
        form.key = "  \(madeUpKey)\n"
        form.model = " gemini-2.5-pro "
        XCTAssertEqual(form.save(s)?.steps, [.putKey(.gemini, key: madeUpKey, model: "gemini-2.5-pro"), .useChat(.own(.gemini))])
        XCTAssertEqual(form.save(s)?.done, "Saved. Ask McFly now uses your Gemini key.")
        form.model = ""
        XCTAssertEqual(form.save(s)?.steps.first, .putKey(.gemini, key: madeUpKey, model: nil), "an empty model is the default")

        // A stored key the chat doesn't use: only chosen, unless its model changed.
        form.choose(.own(.anthropic), s)
        XCTAssertEqual(form.save(s)?.steps, [.useChat(.own(.anthropic))])
        XCTAssertEqual(form.save(s)?.done, "Ask McFly now uses your Claude key.")
        form.model = "claude-opus-4"
        XCTAssertEqual(form.save(s)?.steps, [.putKey(.anthropic, key: nil, model: "claude-opus-4"), .useChat(.own(.anthropic))])
        form.model = ""
        XCTAssertEqual(form.save(s)?.steps.first, .putKey(.anthropic, key: nil, model: nil), "clearing the model goes back to the default")

        // The key in use, a new model.
        form.choose(.own(.openai), s)
        form.model = "gpt-5.1-mini"
        XCTAssertEqual(form.save(s)?.steps, [.putKey(.openai, key: nil, model: "gpt-5.1-mini"), .useChat(.own(.openai))])
        XCTAssertEqual(form.save(s)?.done, "Saved.")

        // After it went through, nothing typed is left.
        form.key = madeUpKey
        form.replacing = true
        form.saved()
        XCTAssertEqual(form.key, "")
        XCTAssertFalse(form.replacing)
    }

    func testTheRequestsAreTheWebs() throws {
        XCTAssertEqual(APIClient.keyPath(.anthropic), "/ai/keys/anthropic")
        let body = try JSONSerialization.data(withJSONObject: APIClient.keyBody(key: madeUpKey, model: nil), options: .sortedKeys)
        XCTAssertEqual(String(decoding: body, as: UTF8.self), #"{"key":"\#(madeUpKey)","model":null}"#)
        let modelOnly = try JSONSerialization.data(withJSONObject: APIClient.keyBody(key: nil, model: "gpt-5.1"), options: .sortedKeys)
        XCTAssertEqual(String(decoding: modelOnly, as: UTF8.self), #"{"model":"gpt-5.1"}"#, "no key: the stored one keeps, its model changes")
        XCTAssertEqual(ChatChoice("shared"), .shared)
        XCTAssertEqual(ChatChoice("gemini"), .own(.gemini))
        XCTAssertNil(ChatChoice("mistral"))
        XCTAssertEqual(ChatChoice.own(.anthropic).raw, "anthropic")
        // The web sends the same shapes.
        let sheets = try web("src/components/ai/AiSheets.tsx")
        XCTAssertTrue(sheets.contains("{ key: key.trim(), model: model.trim() || null }"))
        XCTAssertTrue(sheets.contains("sendJson('PUT', `/ai/keys/${p}`, { model: model.trim() || null })"))
        XCTAssertTrue(sheets.contains("sendJson<AiStatus>('PUT', '/ai/keys/openai', { key: key.trim() })"))
        XCTAssertTrue(sheets.contains("sendJson<AiStatus>('PUT', '/ai/chat', { provider: p })"))
    }

    // MARK: Refusals in the server's words

    func testARefusedKeyShowsTheServersWordsWhateverItsStatus() {
        let path = APIClient.keyPath(.openai)
        XCTAssertEqual(APIClient.error(status: 400, message: "That key wasn't accepted by OpenAI.", path: path).aiMessage, "That key wasn't accepted by OpenAI.")
        XCTAssertEqual(APIClient.error(status: 502, message: "Couldn't reach OpenAI to check the key. Try again in a moment.", path: path).aiMessage,
                       "Couldn't reach OpenAI to check the key. Try again in a moment.", "never “Server answered 502: …”")
        XCTAssertEqual(APIClient.error(status: 503, message: "Connecting your own key isn't set up on this server.", path: path).aiMessage,
                       "Connecting your own key isn't set up on this server.")
        XCTAssertEqual(APIClient.error(status: 500, message: nil, path: path).aiMessage, "Server answered 500: internal server error")
    }

    // MARK: The sheets' requests, and nothing kept

    private var savedServer: String?
    private let base = URL(string: "http://127.0.0.1:9")!

    override func setUp() async throws {
        savedServer = UserDefaults.standard.string(forKey: "serverURL")
        Config.serverText = base.absoluteString
    }

    override func tearDown() async throws {
        if let savedServer { UserDefaults.standard.set(savedServer, forKey: "serverURL") } else { UserDefaults.standard.removeObject(forKey: "serverURL") }
    }

    private func signedIn(_ id: String = "u1") throws -> Dashboard {
        let d = Dashboard()
        d.phase = .ready
        d.apply(status: try JSONDecoder().decode(ServerStatus.self, from: Data(#"{"hosted":false,"settings":{},"user":{"id":"\#(id)","role":"member"}}"#.utf8)))
        return d
    }

    func testASaveShowsItsAnswerAndTheAppHearsIt() async throws {
        let d = try signedIn()
        let model = AIKeysModel()
        let answer = try status("ai-own-key")
        let ok = await model.run(d, done: AIWords.openAIConnected) { _ in answer }
        XCTAssertTrue(ok)
        XCTAssertEqual(model.status, answer)
        XCTAssertEqual(model.note, AINote(ok: true, text: AIWords.openAIConnected))
        XCTAssertFalse(model.busy)
        XCTAssertEqual(d.availability.ai, .known(answer), "Nutrition, portraits and Ask McFly read it at once")
        XCTAssertEqual(d.availability.byok, true)
    }

    func testARefusalSaysSoAndChangesNothing() async throws {
        let d = try signedIn()
        let model = AIKeysModel()
        let before = try status("ai")
        model.status = before
        d.availability.heard(ai: before)
        let ok = await model.run(d, done: "Saved.") { _ in
            throw APIClient.error(status: 400, message: "That key wasn't accepted by Gemini.", path: "/ai/keys/gemini")
        }
        XCTAssertFalse(ok)
        XCTAssertEqual(model.note, AINote(ok: false, text: "That key wasn't accepted by Gemini."))
        XCTAssertEqual(model.status, before)
        XCTAssertEqual(d.availability.ai, .known(before))
    }

    func testAnAnswerThatLandsAfterSignOutOrSomeoneElsesSignInIsDropped() async throws {
        let d = try signedIn("u1")
        let model = AIKeysModel()
        let answer = try status("ai-own-key")
        // Signed out while it was on its way.
        var ok = await model.run(d, done: "Saved.") { _ in
            d.phase = .signIn
            return answer
        }
        XCTAssertFalse(ok)
        XCTAssertNil(model.status)
        XCTAssertNil(model.note)
        XCTAssertEqual(d.availability.ai, .unknown, "nothing of the last person's keys stays")

        // Someone else signed in meanwhile.
        let e = try signedIn("u1")
        ok = await model.run(e, done: "Saved.") { _ in
            e.apply(status: try JSONDecoder().decode(ServerStatus.self, from: Data(#"{"hosted":false,"settings":{},"user":{"id":"u2"}}"#.utf8)))
            return answer
        }
        XCTAssertFalse(ok)
        XCTAssertEqual(e.availability.ai, .unknown)

        // Signed out to begin with: nothing is sent.
        let f = Dashboard()
        f.phase = .signIn
        var sent = false
        ok = await model.run(f, done: "Saved.") { _ in
            sent = true
            return answer
        }
        XCTAssertFalse(ok)
        XCTAssertFalse(sent)
    }

    func testAKeyIsNeverStoredOnThePhone() async throws {
        let d = try signedIn()
        let model = AIKeysModel()
        var form = ChatbotForm()
        let s = try status("ai-own-key")
        form.choose(.own(.gemini), s)
        form.key = madeUpKey
        let plan = try XCTUnwrap(form.save(s))
        var sentKey: String?
        let ok = await model.run(d, done: plan.done) { _ in
            if case .putKey(_, let key, _)? = plan.steps.first { sentKey = key }
            return s
        }
        if ok { form.saved() }
        XCTAssertEqual(sentKey, madeUpKey, "sent once, in the request")
        XCTAssertEqual(form.key, "", "and gone from the sheet once saved")

        // Not in the settings the app keeps, nor in any file it writes.
        let defaults = UserDefaults.standard.dictionaryRepresentation().values.map { "\($0)" }.joined(separator: "\n")
        XCTAssertFalse(defaults.contains(madeUpKey))
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let needle = Data(madeUpKey.utf8)
        for root in [library, documents] {
            let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
            while let url = files?.nextObject() as? URL {
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values?.isRegularFile == true, (values?.fileSize ?? 0) < 8_000_000, let data = try? Data(contentsOf: url) else { continue }
                XCTAssertNil(data.range(of: needle), "the key is in \(url.lastPathComponent)")
            }
        }
    }
}
