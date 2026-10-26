import Foundation
import Observation

// What this server can do for the person signed in, read from its own answers (the web's "not available on this
// server" states). Every AI or optional feature reads its flag here, never an assumption about a server: keys are
// added and removed, and "Change server" can point the phone at an older Mac or LAN server.
//
// - GET /api/ai: whether keys can be stored here (byok), what reads an estimate, voice notes, portraits.
// - McFly's status (GET /api/mcfly), read by McFlyChat for its pill, sheet and page, and seen here.
// - The food log's `can` (GET /api/nutrition/log, POST /api/nutrition/log/day), as each read hears it.
// - PortraitList.canGenerate (GET /api/portraits), as each read hears it.
// - The lab reader (GET /api/labs/reader).
//
// A route the server answers 404 for is `missing`: the server predates the feature, so it hides or falls back. A read
// that failed (offline) leaves what was known, and nothing known says nothing: never "not on this server" until the
// server said so. A 503 for a feature carries the server's own words (`APIError.notSetUpHere`), shown as they are.

/// GET /api/ai (shared/ai.ts AiStatus): what this person's AI requests use. It never holds a key: the server only
/// ever sends a key's provider and last four characters. Memory only, never in SummaryCache. PUT and DELETE
/// /api/ai/keys/:provider and PUT /api/ai/chat answer with it too (`Availability.heard(ai:)`). Read field by field.
struct AiStatus: Decodable, Equatable {
    /// One of the person's own keys, as the server describes it (shared/ai.ts AiKeyInfo).
    struct Key: Codable, Equatable, Identifiable {
        /// "anthropic" | "openai" | "gemini"
        let provider: String
        let last4: String
        /// The model chosen for it; nil is the provider's default.
        var model: String?
        var addedAt: Double?
        var lastUsedAt: Double?
        /// Why its last use failed, in the server's words.
        var lastError: String?
        var id: String { provider }
    }

    /// Who answers something now: a provider, and whose key (shared/ai.ts AiSource: "own" | "shared").
    struct Use: Decodable, Equatable {
        let provider: String
        let source: String
        var model: String?
    }

    /// Keys can be stored here (the server has HEALTHOS_DATA_KEY).
    var byok = false
    /// The server's shared Claude key is set and the admin allows it.
    var shared = false
    var keys: [Key] = []
    /// What Ask McFly uses now; nil when nothing is available.
    var chat: Use?
    /// What the person chose for the chat: "shared" (the default) or a provider.
    var chatChoice = "shared"
    /// What reads a meal photo or description now; nil when nothing can.
    var estimate: Use?
    /// Voice notes can be written down (an OpenAI key, the person's or the server's).
    var voice = false
    /// Portraits can be made (an OpenAI key, the person's or the server's).
    var portraits = false

    /// The person's own key for this provider, if they connected one.
    func key(_ provider: String) -> Key? { keys.first { $0.provider == provider } }

    private enum CodingKeys: String, CodingKey { case byok, shared, keys, chat, chatChoice, estimate, voice, portraits }

    init(byok: Bool = false, shared: Bool = false, keys: [Key] = [], chat: Use? = nil, chatChoice: String = "shared", estimate: Use? = nil,
         voice: Bool = false, portraits: Bool = false) {
        self.byok = byok
        self.shared = shared
        self.keys = keys
        self.chat = chat
        self.chatChoice = chatChoice
        self.estimate = estimate
        self.voice = voice
        self.portraits = portraits
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys) -> T? { try? c.decodeIfPresent(T.self, forKey: key) }
        self.init(byok: value(.byok) ?? false, shared: value(.shared) ?? false, keys: (value(.keys) as LossyArray<Key>?)?.wrappedValue ?? [],
                  chat: value(.chat), chatChoice: value(.chatChoice) ?? "shared", estimate: value(.estimate),
                  voice: value(.voice) ?? false, portraits: value(.portraits) ?? false)
    }
}

/// GET /api/labs/reader (shared/labs.ts LabReader): what reading a report would use right now, so the page says so
/// before anything is sent. `source` "own" is the person's own Claude key, "shared" one of their Ask McFly questions;
/// nil when reading isn't available, with `reason` "none" (not set up on this server) or "off" (the admin turned it off).
struct LabReader: Decodable, Equatable {
    var source: String?
    var reason: String?
    var limit = 0
    var usedToday = 0

    private enum CodingKeys: String, CodingKey { case source, reason, limit, usedToday }

    init(source: String? = nil, reason: String? = nil, limit: Int = 0, usedToday: Int = 0) {
        self.source = source
        self.reason = reason
        self.limit = limit
        self.usedToday = usedToday
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys) -> T? { try? c.decodeIfPresent(T.self, forKey: key) }
        self.init(source: value(.source), reason: value(.reason), limit: value(.limit) ?? 0, usedToday: value(.usedToday) ?? 0)
    }
}

/// Where Ask McFly stands for this person (src/pages/McFly.tsx).
enum McFlyState: Equatable {
    /// Not read yet: show nothing about it.
    case unknown
    case available
    /// The server has no assistant (ServerWords.mcflyNotSetUp).
    case notSetUp
    /// The admin set the shared daily limit to 0, and the person has no key of their own (ServerWords.mcflyOff).
    case off

    init(_ status: McFlyStatus?) {
        guard let status else {
            self = .unknown
            return
        }
        if !status.configured { self = .notSetUp }
        else if status.available { self = .available }
        else { self = .off }
    }
}

/// What this server can do for the person signed in. One for the app, on Dashboard (`dashboard.availability`); it's
/// forgotten with a sign-out, another person's sign-in or another server.
@MainActor
@Observable
final class Availability {
    /// One source's answer.
    enum Read<Value: Equatable>: Equatable {
        /// Not asked yet, or the read failed before anything was known: say nothing about the feature.
        case unknown
        /// The server predates the route (it answered 404): hide the feature, or fall back.
        case missing
        case known(Value)

        var value: Value? {
            if case .known(let value) = self { return value }
            return nil
        }
    }

    /// GET /api/ai.
    private(set) var ai: Read<AiStatus> = .unknown
    /// GET /api/labs/reader.
    private(set) var labReader: Read<LabReader> = .unknown
    /// The food log's `can`, from the last log or day read.
    private(set) var foodCan: FoodLog.Can?
    /// PortraitList.canGenerate, from the last list read.
    private(set) var canGeneratePortraits: Bool?

    /// McFly's status belongs to its conversation (McFlyChat reads it after every load and every answer): seen
    /// here, not read twice.
    private let chat: McFlyChat
    /// Goes up when everything is forgotten, so a read still on its way can't land on the next person's.
    private var generation = 0
    /// Read since the last load; false: the next ask reads again.
    private var aiFresh = false
    private var readerFresh = false

    init(chat: McFlyChat) { self.chat = chat }

    // MARK: Flags. nil: not known yet, so say nothing. false on a server that predates the route.

    /// The server is older than GET /api/ai: no own keys, portraits or voice notes there. McFly and estimates still
    /// work, from their own flags (`mcflyState`, `estimate`).
    var aiMissing: Bool { ai == .missing }
    /// Keys can be stored on this server (AiStatus.byok).
    var byok: Bool? { aiMissing ? false : ai.value?.byok }
    /// Portraits can be made: the portrait list's own answer first, else GET /api/ai's.
    var portraits: Bool? { canGeneratePortraits ?? (aiMissing ? false : ai.value?.portraits) }
    /// Voice notes can be written down: the food log's answer first, else GET /api/ai's.
    var voice: Bool? { foodCan?.voice ?? (aiMissing ? false : ai.value?.voice) }
    /// McFly can estimate a meal: the food log's answer first (older servers have only that), else GET /api/ai's.
    var estimate: Bool? { foodCan?.estimate ?? ai.value.map { $0.estimate != nil } }
    /// Who reads an estimate ("anthropic" | "openai" | "gemini"); nil when nobody can or it isn't known.
    var estimateProvider: String? { foodCan?.estimateProvider ?? ai.value?.estimate?.provider }
    /// McFly's last status (McFlyChat's).
    var mcfly: McFlyStatus? { chat.status }
    var mcflyState: McFlyState { McFlyState(chat.status) }
    /// A report can be read with Claude now; false where it isn't set up, is off, or the server predates it.
    var labReading: Bool? {
        switch labReader {
        case .unknown: nil
        case .missing: false
        case .known(let reader): reader.source != nil
        }
    }

    // MARK: Reading

    /// GET /api/ai, unless it was answered since the last load (`force` always reads). `read` is the request, nil
    /// when the server answers 404. A failure keeps what was known.
    func loadAI(force: Bool = false, read: () async throws -> AiStatus?) async {
        guard force || !aiFresh else { return }
        let generation = generation
        do {
            let status = try await read()
            guard generation == self.generation else { return }
            ai = status.map { .known($0) } ?? .missing
            aiFresh = true
        } catch {
            // Offline, signed out, cancelled: what's known stays, and the next ask reads again.
        }
    }

    /// GET /api/labs/reader, as `loadAI`.
    func loadLabReader(force: Bool = false, read: () async throws -> LabReader?) async {
        guard force || !readerFresh else { return }
        let generation = generation
        do {
            let reader = try await read()
            guard generation == self.generation else { return }
            labReader = reader.map { .known($0) } ?? .missing
            readerFresh = true
        } catch {}
    }

    /// An AiStatus another request answered with (saving or removing a key, choosing the chat's provider).
    func heard(ai status: AiStatus) {
        ai = .known(status)
        aiFresh = true
    }

    /// The `can` of a food log or day just read.
    func heard(foodCan can: FoodLog.Can?) {
        if let can { foodCan = can }
    }

    /// A portrait list just read.
    func heard(canGeneratePortraits can: Bool) { canGeneratePortraits = can }

    /// A lab reader just read (after reading a report, say, which uses one of the day's).
    func heard(labReader reader: LabReader) {
        labReader = .known(reader)
        readerFresh = true
    }

    /// A load just landed: what's known stays on screen, and the next ask reads it again.
    func loadedAgain() {
        aiFresh = false
        readerFresh = false
    }

    /// Signed out, someone else signed in, or another server: nothing known carries over, and a read on its way is
    /// dropped when it lands.
    func forget() {
        generation += 1
        ai = .unknown
        labReader = .unknown
        foodCan = nil
        canGeneratePortraits = nil
        aiFresh = false
        readerFresh = false
    }
}

extension APIClient {
    /// GET /api/ai; nil from a server older than own keys.
    func aiStatus() async throws -> AiStatus? { try await optional("/ai") }

    /// GET /api/labs/reader; nil from a server older than reading reports.
    func labReader() async throws -> LabReader? { try await optional("/labs/reader") }
}

extension Dashboard {
    /// What this person's AI requests use (GET /api/ai). The shell reads it after every load while signed in; a page
    /// that needs it sooner asks here, and it's read once until the next load (`force` reads again).
    func loadAI(force: Bool = false) async {
        guard phase == .ready else { return }
        await availability.loadAI(force: force) { try await self.fetch { try await $0.aiStatus() } }
    }

    /// What reading a lab report would use now (GET /api/labs/reader), as `loadAI`.
    func loadLabReader(force: Bool = false) async {
        guard phase == .ready else { return }
        await availability.loadLabReader(force: force) { try await self.fetch { try await $0.labReader() } }
    }
}

/// The web's own words where a feature isn't available on a server, so every page says it the same way. Each is
/// quoted from the web file named; keep them in step.
enum ServerWords {
    /// src/components/ai/AiSheets.tsx NOT_HERE.
    static let keysNotHere = "Storing your own AI keys isn't set up on this server."
    /// AiSheets.tsx usingLine, when nothing can answer and keys can't be stored.
    static let mcflyNotOnServer = "Ask McFly isn't set up on this server yet."
    /// AiSheets.tsx usingLine, when nothing can answer yet but a key can be connected.
    static let mcflyNeedsKey = "Ask McFly isn't available yet. Connect a key below to use it."
    /// AiSheets.tsx, the OpenAI sheet's line on meals.
    static let estimatesNotHere = "Meal estimates aren't set up on this server."
    /// AiSheets.tsx, the OpenAI sheet's line on voice notes and portraits.
    static let voiceAndPortraitsNotHere = "Voice notes and portraits aren't set up on this server."
    /// src/pages/NutritionChat.tsx voiceOff.
    static let voiceNeedsKeyNotHere = "Voice notes need an OpenAI key, and storing your own key isn't available on this server."
    /// NutritionChat.tsx SetupLine, before its "You can still …".
    static let estimatesNeedKeyNotHere = "Estimates need an AI key, and storing your own isn't available on this server."
    /// src/components/portraits/PortraitStudio.tsx keyNote (the web's curly apostrophe kept).
    static let portraitNeedsKeyNotHere = "Making a portrait needs an OpenAI key, and storing your own key isn’t available on this server."
    /// src/pages/Home.tsx PortraitNote.
    static let homePortraitNotHere = "Portraits aren't available on this server yet, so the digital human stands in."
    /// src/pages/Labs.tsx NOT_SET_UP.
    static let labReadingNotHere = "Reading reports isn't set up on this server yet. You can still type results in."
    /// src/pages/McFly.tsx, the unavailable card's titles.
    static let mcflyNotSetUp = "Ask McFly isn't set up yet"
    static let mcflyOff = "Ask McFly is turned off"
}
