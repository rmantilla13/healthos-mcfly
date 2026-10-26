import XCTest
@testable import HealthOSSync

/// Profile and its sheets (slice D): the words against the web's own files, the rows' lines, what closing Units &
/// daily goal sends, the password form's rule and its answer, the ?connect= links, and the export's download, names
/// and failures.
@MainActor
final class ProfileTests: XCTestCase {
    /// A file of the web app, next to the iPhone app in the repository, with its runs of spaces and line breaks made
    /// one space, so JSX text that wraps reads as the sentence it is.
    private func web(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(path)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { throw XCTSkip("\(path) isn't next to the app") }
        return text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    private func settings(_ json: String) throws -> ServerStatus.Settings {
        try XCTUnwrap(try JSONDecoder().decode(ServerStatus.self, from: Data(#"{"settings":\#(json)}"#.utf8)).settings)
    }

    // MARK: Words

    func testProfileWordsAreTheWebsOwn() throws {
        let profile = try web("src/pages/Profile.tsx")
        let words = [
            "Your profile & perspective", "Edit preferences", "Peer comparisons enabled.", "Peer comparisons off.",
            "Change your image, age or participation anytime.", "Just the statistics", "Your portrait", "no age given",
            ProfileWords.chatbot(byok: false), ProfileWords.chatbot(byok: true), "Manage chatbot AI", "Ask McFly uses your own",
            try XCTUnwrap(ProfileWords.account(mode: "open", email: nil, role: nil)), "' · admin'", "Signed in", "Change password",
            ProfileWords.openAI(byok: false), ProfileWords.openAI(byok: true), ProfileWords.openAIConnected(last4: ""), "Manage AI key", "Connect AI key",
            "Connected sources", "Manage sources", "Manage what comes into your health profile.",
            "Export your data", "Download JSON", "Preparing…", ProfileWords.exportLine, ProfileWords.exportUnreachable, ProfileWords.exportFailed,
            ProfileWords.exportStopped, "Saved ${name}.", "healthos-export-${localToday()}.json",
            "Privacy & data use", "Read details", "Understand how files, food descriptions and recordings are handled.",
            "End your session", "Sign out on this device.",
            "Units & daily goal", ProfileWords.metric, ProfileWords.imperial, "steps a day", "Choose cards", "Choose the cards you see on Home, Sleep",
            "', Body and Nutrition'", "' and Body'", ProfileWords.cardsNote, "Show all", "Done",
            ProfileWords.family(sharing: true), ProfileWords.family(sharing: false), "Family board", "Cycle tracking",
            "Sex for health calculations: ", "'prefer not to say'", "'not set'",
            "calories and nutrients", "nutrients without calories", "what you logged, no amounts",
            "Name", "Daily step goal", ProfileWords.stepGoalHint, "Saved",
            "Current password", "New password", "Confirm new password", ProfileWords.passwordHint, ProfileWords.passwordsDiffer,
            "Changing…", ProfileWords.passwordChanged,
        ]
        for w in words { XCTAssertTrue(profile.contains(w), "Profile.tsx says \"\(w)\"") }
        XCTAssertTrue(profile.contains("maxLength={\(ProfileWords.nameLimit)}"))
        XCTAssertTrue(profile.contains("next.length >= \(ProfileWords.passwordMinimum)"))
    }

    func testSettingsSheetWordsAreTheWebsOwn() throws {
        let cycle = try web("src/pages/Cycle.tsx")
        for w in [
            "Health profile", ProfileWords.healthProfile, "Sex for health calculations", "Track my cycle", ProfileWords.trackCycle, ProfileWords.trackWhenever,
            "Show my cycle phase to family", ProfileWords.sharePhase, ProfileWords.cycleOff, "Delete cycle data", ProfileWords.deleteCycle,
            "Delete all cycle data", "\(ProfileWords.deleteCycleAsk) \(ProfileWords.deleteCycleWarning)", "There was nothing to delete.", "'entry' : 'entries'",
        ] { XCTAssertTrue(cycle.contains(w), "Cycle.tsx says \"\(w)\"") }
        for (_, title) in ProfileWords.sexChoices { XCTAssertTrue(cycle.contains("'\(title)'"), title) }
        XCTAssertTrue(cycle.contains("(['female', 'male', 'unspecified'] as const)"), "the same three, in the same order")

        let family = try web("src/pages/Family.tsx")
        for w in [ProfileWords.familyTile, ProfileWords.familyShare, "Share with family", " Sharing with: ${others.join(', ')}."] {
            XCTAssertTrue(family.contains(w), "Family.tsx says \"\(w)\"")
        }

        let nutrition = try web("src/pages/Nutrition.tsx")
        for w in [
            ProfileWords.nutritionAbout, ProfileWords.chooseFirst, "What you see", ProfileWords.targetsTitle, ProfileWords.targetsNote,
            ProfileWords.nutritionOff, "Delete nutrition data", ProfileWords.deleteNutrition, "Delete all nutrition data",
            "\(ProfileWords.deleteNutritionAsk) \(ProfileWords.deleteNutritionWarning)", "'Deleted.'", "There was nothing to delete.",
        ] { XCTAssertTrue(nutrition.contains(w), "Nutrition.tsx says \"\(w)\"") }
        for c in ProfileWords.numbersChoices {
            XCTAssertTrue(nutrition.contains("{ value: '\(c.value)', title: '\(c.title)', text: '\(c.text)' }"), c.title)
        }
        // The web's own copy names "the healthOS iPhone app": on the iPhone, that's "this iPhone".
        XCTAssertTrue(nutrition.contains("Your food log comes in from the healthOS iPhone app"))
        XCTAssertTrue(nutrition.contains("History comes in with your next Health export import, or from the healthOS iPhone app at its next sync."))
    }

    func testProvidersAndRangesAreTheServers() throws {
        let ai = try web("shared/ai.ts")
        for p in ProfileWords.providers { XCTAssertTrue(ai.contains("{ provider: '\(p.provider)', label: '\(p.label)' }"), p.label) }
        let query = try web("server/query.ts")
        XCTAssertTrue(query.contains("energy_kcal: [500, 10_000], protein_g: [10, 500], water_ml: [250, 8_000]"))
        XCTAssertEqual(NutritionTargetField.all.map(\.range), [500...10_000, 10...500, 250...8_000])
        let app = try web("server/app.ts")
        XCTAssertTrue(app.contains("if (goal >= \(ProfileWords.stepGoalRange.lowerBound) && goal <= 100_000)"), "the goal the server keeps")
        XCTAssertEqual(ProfileWords.stepGoalRange.upperBound, 100_000)
        XCTAssertTrue(app.contains("body.name.trim().slice(0, \(ProfileWords.nameLimit))"))
        let auth = try web("server/auth.ts")
        XCTAssertTrue(auth.contains("export const MIN_PASSWORD = \(ProfileWords.passwordMinimum);"))
    }

    // MARK: Rows

    func testRowLines() throws {
        let s = try settings(#"{"name":"Ada","units":"imperial","stepGoal":8500,"perspective":"digital","age":33,"peerComparison":true,"sex":"female","cycleTracking":true,"nutrition":true,"nutritionNumbers":"no_energy","familySharing":true}"#)
        XCTAssertEqual(ProfileWords.perspective(s, drawn: .man), "Digital man · 33 years")
        XCTAssertEqual(ProfileWords.peers(s), "Peer comparisons enabled. Change your image, age or participation anytime.")
        XCTAssertEqual(ProfileWords.units(s), "Ada · Imperial (lb, °F, mi) · \(Fmt.number(8500)) steps a day")
        XCTAssertEqual(ProfileWords.cycle(s), "On · Sex for health calculations: female")
        XCTAssertEqual(ProfileWords.nutrition(s), "On · nutrients without calories")
        XCTAssertEqual(ProfileWords.family(sharing: true), "Sharing on. Members who share see your tile and its last 30 days.")

        let bare = try settings(#"{"name":"","units":"metric","stepGoal":10000,"perspective":"stats","nutrition":false,"nutritionNumbers":"all"}"#)
        XCTAssertEqual(ProfileWords.perspective(bare, drawn: .man), "Just the statistics · no age given")
        XCTAssertEqual(ProfileWords.peers(bare), "Peer comparisons off. Change your image, age or participation anytime.")
        XCTAssertEqual(ProfileWords.units(bare), "Metric (kg, °C, km) · \(Fmt.number(10_000)) steps a day", "no name, no dot before it")
        XCTAssertEqual(ProfileWords.cycle(bare), "Off · Sex for health calculations: not set")
        XCTAssertEqual(ProfileWords.nutrition(bare), "Off")
        XCTAssertEqual(ProfileWords.perspective(try settings(#"{"perspective":"portrait","age":40}"#), drawn: .woman), "Your portrait · 40 years")
        XCTAssertEqual(ProfileWords.cycle(try settings(#"{"sex":"unspecified","cycleTracking":false}"#)), "Off · Sex for health calculations: prefer not to say")
        XCTAssertEqual(ProfileWords.nutrition(try settings(#"{"nutrition":true,"nutritionNumbers":"none"}"#)), "On · what you logged, no amounts")
        XCTAssertEqual(ProfileWords.nutrition(try settings(#"{"nutrition":true}"#)), "On · calories and nutrients", "as the web reads a missing choice")
        XCTAssertEqual(ProfileWords.cardPages(nutrition: false), "Choose the cards you see on Home, Sleep and Body.")
        XCTAssertEqual(ProfileWords.cardPages(nutrition: true), "Choose the cards you see on Home, Sleep, Body and Nutrition.")
    }

    func testAccountAndAILines() throws {
        XCTAssertEqual(ProfileWords.account(mode: "required", email: "ada@example.test", role: "admin"), "ada@example.test · admin")
        XCTAssertEqual(ProfileWords.account(mode: "required", email: "ada@example.test", role: "member"), "ada@example.test")
        XCTAssertEqual(ProfileWords.account(mode: "open", email: "", role: "admin"), "This Mac, no sign-in")
        XCTAssertEqual(ProfileWords.account(mode: "open", email: "ada@example.test", role: nil), "This Mac, no sign-in", "a server without sign-in")
        // Offline at launch the sign-in mode isn't known: never "no sign-in" for an account that signs in. The email
        // kept from the last status, or nothing.
        XCTAssertEqual(ProfileWords.account(mode: nil, email: "ada@example.test", role: "admin"), "ada@example.test · admin")
        XCTAssertNil(ProfileWords.account(mode: nil, email: nil, role: nil))
        XCTAssertNil(ProfileWords.account(mode: nil, email: "", role: nil))
        // Unknown says nothing of the server: the ordinary line, never "not set up".
        XCTAssertEqual(ProfileWords.chatbot(byok: nil), ProfileWords.chatbot(byok: true))
        XCTAssertTrue(ProfileWords.chatbot(byok: false).hasSuffix("but storing your own AI keys isn't set up on this server."))
        XCTAssertEqual(ProfileWords.openAI(byok: nil), ProfileWords.openAI(byok: true))
        let own = try JSONDecoder().decode(AiStatus.self, from: Data(#"{"byok":true,"keys":[{"provider":"anthropic","last4":"wxyz"}],"chat":{"provider":"anthropic","source":"own"}}"#.utf8))
        XCTAssertEqual(ProfileWords.ownChat(own), "Ask McFly uses your own Claude key.")
        let shared = try JSONDecoder().decode(AiStatus.self, from: Data(#"{"byok":true,"chat":{"provider":"anthropic","source":"shared"}}"#.utf8))
        XCTAssertNil(ProfileWords.ownChat(shared))
        XCTAssertEqual(ProfileWords.openAIConnected(last4: "1a2b"), "Connected · key ending ••••1a2b")
    }

    func testConnectLinksWaitForTheServersAnswerAboutKeys() throws {
        let link = ["connect": "openai"]
        let known = Availability.Read<AiStatus>.known(try JSONDecoder().decode(AiStatus.self, from: Data(#"{"byok":true}"#.utf8)))
        XCTAssertEqual(ProfileSheet.link([:], ready: true, settings: true, ai: known, asked: false), ProfileSheet.Link.none)
        // Not yet: nobody's signed in, or the status (with the settings) lands after the phase is ready.
        XCTAssertEqual(ProfileSheet.link(link, ready: false, settings: true, ai: known, asked: true), .wait)
        XCTAssertEqual(ProfileSheet.link(link, ready: true, settings: false, ai: known, asked: true), .wait)
        // GET /api/ai hasn't answered: asked first, so an older server's 404 can still keep the sheet shut.
        XCTAssertEqual(ProfileSheet.link(link, ready: true, settings: true, ai: .unknown, asked: false), .wait)
        XCTAssertEqual(ProfileSheet.link(link, ready: true, settings: true, ai: .missing, asked: true), .drop, "a server older than own keys")
        XCTAssertEqual(ProfileSheet.link(link, ready: true, settings: true, ai: known, asked: false), .open(.openai))
        // Asked and the read failed (offline): unknown isn't "not there", so the sheet opens and says what it can.
        XCTAssertEqual(ProfileSheet.link(["connect": "chatbot"], ready: true, settings: true, ai: .unknown, asked: true), .open(.chatbot))
        // What the task that decides waits on changes with each of these.
        XCTAssertEqual(Set([ProfileSheet.aiKnown(.unknown), ProfileSheet.aiKnown(.missing), ProfileSheet.aiKnown(known)]).count, 3)
    }

    func testConnectLinksOpenTheKeySheets() {
        XCTAssertEqual(ProfileSheet.linked(["connect": "openai"]), .openai)
        XCTAssertEqual(ProfileSheet.linked(["connect": "chatbot"]), .chatbot)
        XCTAssertNil(ProfileSheet.linked(["connect": "nutrition"]))
        XCTAssertNil(ProfileSheet.linked([:]))
        // The links the app's own text and routes make.
        XCTAssertEqual(AppRoute(url: URL(string: "healthos://profile?connect=openai")!).flatMap { ProfileSheet.linked($0.query) }, .openai)
        XCTAssertEqual(AppRoute(page: "settings", query: ["connect": "chatbot"]).flatMap { ProfileSheet.linked($0.query) }, .chatbot)
    }

    func testCardNotesSayOnlyWhatTheGroupDoesnt() throws {
        // A card this iPhone shows on the page its group names: nothing to add.
        XCTAssertNil(ProfileCardsSheet.note(try XCTUnwrap(Cards.card("home.hrv")), in: .home))
        // A card no page of this iPhone shows: the web dashboard only. (Made up, so it stays unplaced once every page
        // places all of its cards.)
        let unplaced = DashboardCard(id: "test.unplaced", page: .sleep, label: "Not on this iPhone")
        XCTAssertNil(unplaced.place)
        XCTAssertEqual(ProfileCardsSheet.note(unplaced, in: .sleep), "Only on the web dashboard")
        // Every note is one of those two or names another tab of the page.
        for card in Cards.all {
            guard let note = ProfileCardsSheet.note(card, in: card.page), note != "Only on the web dashboard" else { continue }
            XCTAssertEqual(note, "On this iPhone: \(try XCTUnwrap(card.place).label)")
            XCTAssertNotNil(card.place?.tab)
        }
    }

    /// "Use a photo as is" (PhotoSection) shows once on Profile: on its own card until the portrait photos card shows it
    /// itself (slice F), then only there. Both compile, so this is what says to delete Profile's own card at that merge.
    func testThePhotoPickerShowsOnce() throws {
        let portraits = try web("ios/HealthOSSync/Portraits/PortraitPhotosSection.swift")
        let profile = try web("ios/HealthOSSync/SettingsScreen.swift")
        let inPortraits = portraits.range(of: #"\bPhotoSection\(\)"#, options: .regularExpression) != nil
        let ownCard = profile.contains("ProfilePhotoCard()")
        XCTAssertTrue(inPortraits || ownCard, "Profile shows \"Use a photo as is\" somewhere")
        XCTAssertFalse(inPortraits && ownCard,
                       "PortraitPhotosSection shows PhotoSection now: delete ProfilePhotoCard() and its struct from SettingsScreen.swift")
    }

    // MARK: Units & daily goal

    func testClosingSendsOnlyWhatChanged() throws {
        let s = try settings(#"{"name":"Ada","stepGoal":10000}"#)
        XCTAssertFalse(ProfileBasicsSheet.patch(name: "Ada", goal: "10000", settings: s).changed)
        XCTAssertFalse(ProfileBasicsSheet.patch(name: "  Ada ", goal: "10000", settings: s).changed, "trimmed, as the web compares it")
        XCTAssertFalse(ProfileBasicsSheet.patch(name: "Ada", goal: "", settings: s).changed, "an empty goal isn't sent")
        XCTAssertEqual(ProfileBasicsSheet.patch(name: "Ada L", goal: "10000", settings: s).fields, ["name": "Ada L"])
        let goal = ProfileBasicsSheet.patch(name: "Ada", goal: "8000", settings: s)
        XCTAssertEqual(goal.goal, 8000)
        XCTAssertTrue(goal.fields.isEmpty)
        // The server ignores these without saying: the phone says so and sends nothing.
        for typed in ["499", "100001"] {
            let p = ProfileBasicsSheet.patch(name: "Ada", goal: typed, settings: s)
            XCTAssertTrue(p.goalOutOfRange, typed)
            XCTAssertNil(p.goal)
        }
        // Too long for a number at all: refused too, never closed as if nothing changed.
        let huge = ProfileBasicsSheet.patch(name: "Ada", goal: "12345678901234567890", settings: s)
        XCTAssertTrue(huge.goalOutOfRange)
        XCTAssertTrue(huge.changed, "the sheet stays up to say so")
        XCTAssertNil(huge.goal)
        XCTAssertEqual(ProfileBasicsSheet.patch(name: "Ada", goal: "500", settings: s).goal, 500)
        XCTAssertEqual(ProfileBasicsSheet.patch(name: "Ada", goal: "100000", settings: s).goal, 100_000)
        // No name yet on the server: a blank one is no change.
        XCTAssertFalse(ProfileBasicsSheet.patch(name: "", goal: "10000", settings: try settings(#"{"stepGoal":10000}"#)).changed)
    }

    func testTargetsTheServerWouldIgnoreAreRefusedHere() {
        let protein = NutritionTargetField.all[1]
        XCTAssertNil(protein.problem(nil), "blank clears it")
        XCTAssertNil(protein.problem(120))
        XCTAssertEqual(protein.problem(5), "Protein: between 10 and 500 g, or blank for none.")
    }

    // MARK: Password

    func testPasswordFormRule() {
        XCTAssertFalse(ProfileWords.passwordReady(current: "", next: "0123456789", confirm: "0123456789"), "needs the current one")
        XCTAssertFalse(ProfileWords.passwordReady(current: "old", next: "012345678", confirm: "012345678"), "9 is too short")
        XCTAssertFalse(ProfileWords.passwordReady(current: "old", next: "0123456789", confirm: "0123456788"), "typed the same twice")
        XCTAssertTrue(ProfileWords.passwordReady(current: "old", next: "0123456789", confirm: "0123456789"))
    }

    func testPasswordRefusalsAreTheServersWords() {
        XCTAssertEqual(APIClient.error(status: 403, message: "Your current password is wrong.", path: "/auth/password").localizedDescription,
                       "Your current password is wrong.")
        XCTAssertEqual(APIClient.error(status: 400, message: "Use a password of at least 10 characters.", path: "/auth/password").localizedDescription,
                       "Use a password of at least 10 characters.")
        // A session already gone: the sign-in screen, not a wrong password.
        guard case .signInRequired = APIClient.error(status: 401, message: "Sign in required", path: "/auth/password") else {
            return XCTFail("a 401 from a password change is a session that ended")
        }
    }

    /// The server moves the session version on and answers with a new cookie for this phone: it's kept, so the phone
    /// stays signed in while every other device is signed out.
    func testThePasswordChangesNewSessionIsKept() throws {
        let saved = Keychain.read(service: "healthos.session")
        defer { Keychain.write(saved ?? "", service: "healthos.session") }
        let base = URL(string: "http://127.0.0.1:9")!
        let client = APIClient(base: base)
        SessionStore.update(from: "hos_session=v2.u1.1.111.old; Path=/; HttpOnly; Max-Age=600", url: base, base: base)
        XCTAssertEqual(SessionStore.cookie(for: base), "v2.u1.1.111.old")
        let answer = HTTPURLResponse(url: base.appendingPathComponent("api/auth/password"), statusCode: 200, httpVersion: "HTTP/1.1",
                                     headerFields: ["Set-Cookie": "hos_session=v2.u1.2.222.new; Path=/; HttpOnly; SameSite=Lax; Max-Age=2592000"])!
        _ = try client.checked(Data(#"{"ok":true}"#.utf8), answer, path: "/auth/password")
        XCTAssertEqual(SessionStore.cookie(for: base), "v2.u1.2.222.new")
    }

    // MARK: Export

    private let base = URL(string: "http://127.0.0.1:9")!

    private func answer(_ status: Int, _ body: String, headers: [String: String] = [:]) throws -> (URL, URLResponse) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("test-download-\(UUID().uuidString).tmp")
        try Data(body.utf8).write(to: file)
        return (file, HTTPURLResponse(url: base.appendingPathComponent("api/me/export"), statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
    }

    private func problem(_ download: @escaping ProfileExport.Download) async -> Error? {
        do {
            _ = try await ProfileExport.run(client: APIClient(base: base), download: download, today: "2026-10-26")
            return nil
        } catch {
            return error
        }
    }

    override func tearDown() async throws { ProfileExport.removeAll() }

    func testTheExportIsAFileOfItsOwnNamedAsTheServerNamesIt() async throws {
        var asked: URLRequest?
        var downloaded: URL?
        let body = #"{"format":"healthos-export","version":1}"#
        let file = try await ProfileExport.run(client: APIClient(base: base), download: { request in
            asked = request
            let a = try self.answer(200, body, headers: ["Content-Disposition": #"attachment; filename="healthos-export-2026-10-25.json""#])
            downloaded = a.0
            return a
        }, today: "2026-10-26")
        XCTAssertEqual(asked?.url?.path, "/api/me/export")
        XCTAssertEqual(asked?.httpMethod, "GET")
        XCTAssertEqual(asked?.timeoutInterval, 120)
        XCTAssertEqual(file.lastPathComponent, "healthos-export-2026-10-25.json")
        XCTAssertTrue(file.path.hasPrefix(ProfileExport.folder.path), "in the temporary folder, not Documents or a cache")
        XCTAssertFalse(file.path.contains("/Documents/"))
        XCTAssertFalse(file.path.contains("/Caches/"))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), body)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(downloaded).path), "moved, not copied")
        ProfileExport.removeAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: ProfileExport.folder.path), "gone once shared")
    }

    func testTheExportsName() {
        XCTAssertEqual(ProfileExport.fileName(contentDisposition: #"attachment; filename="healthos-export-2026-10-25.json""#, today: "2026-10-26"),
                       "healthos-export-2026-10-25.json")
        XCTAssertEqual(ProfileExport.fileName(contentDisposition: nil, today: "2026-10-26"), "healthos-export-2026-10-26.json", "the web's own")
        XCTAssertEqual(ProfileExport.fileName(contentDisposition: "attachment", today: "2026-10-26"), "healthos-export-2026-10-26.json")
        XCTAssertEqual(ProfileExport.fileName(contentDisposition: #"attachment; filename="""#, today: "2026-10-26"), "healthos-export-2026-10-26.json")
        let odd = ProfileExport.fileName(contentDisposition: #"attachment; filename="../../x/export.json""#, today: "2026-10-26")
        XCTAssertFalse(odd.contains("/"), "never a path")
        XCTAssertFalse(odd.hasPrefix("."))
        XCTAssertTrue(odd.hasSuffix("export.json"))
    }

    func testARefusalSaysWhatTheServerSays() async throws {
        let busy = await problem { _ in
            try self.answer(429, #"{"error":"Your export was just prepared. Try again in a minute."}"#, headers: ["Retry-After": "42"])
        }
        XCTAssertEqual((busy as? ProfileExport.Problem)?.message, "Your export was just prepared. Try again in a minute.")
        let failed = await problem { _ in try self.answer(500, #"{"error":"Couldn't prepare your export. Try again in a moment."}"#) }
        XCTAssertEqual((failed as? ProfileExport.Problem)?.message, "Couldn't prepare your export. Try again in a moment.", "as sent, not 'Server answered 500'")
        let silent = await problem { _ in try self.answer(502, "") }
        XCTAssertEqual((silent as? ProfileExport.Problem)?.message, ProfileWords.exportFailed, "the web's words when the server sent none")
        XCTAssertFalse(FileManager.default.fileExists(atPath: ProfileExport.folder.path), "nothing kept from a refusal")
    }

    func testARefusalsBodyIsNotKept() async throws {
        var body: URL?
        _ = await problem { _ in
            let a = try self.answer(429, #"{"error":"Your export was just prepared. Try again in a minute."}"#)
            body = a.0
            return a
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(body).path))
    }

    func testAnOlderServerHasNoExport() async throws {
        let missing = await problem { _ in try self.answer(404, #"{"error":"Not found"}"#) } as? ProfileExport.Problem
        XCTAssertEqual(missing?.routeMissing, true)
        XCTAssertEqual(missing?.message, ProfileWords.exportNotHere)
    }

    func testSignedOutDropsToSignIn() async throws {
        let saved = Keychain.read(service: "healthos.session")
        defer { Keychain.write(saved ?? "", service: "healthos.session") }
        let error = await problem { _ in try self.answer(401, #"{"error":"Sign in required","signIn":true}"#) }
        guard case .signInRequired? = error as? APIError else { return XCTFail("a 401 is for dashboard.fetch to sign out: \(String(describing: error))") }
    }

    func testNoAnswerAndABrokenStreamAreNotAFile() async throws {
        let unreachable = await problem { _ in throw ProfileExport.Failure.unreachable }
        XCTAssertEqual((unreachable as? ProfileExport.Problem)?.message, "Couldn't reach healthOS. Check your connection and try again.")
        // The server breaks the connection rather than end a failing export as a short file: a failure, never a file.
        let stopped = await problem { _ in throw ProfileExport.Failure.stopped }
        XCTAssertEqual((stopped as? ProfileExport.Problem)?.message, "The download stopped before it finished. Try again in a minute.")
        let cancelled = await problem { _ in throw CancellationError() }
        XCTAssertTrue(cancelled is CancellationError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ProfileExport.folder.path))
    }

    func testANewExportClearsTheLastOne() async throws {
        let first = try await ProfileExport.run(client: APIClient(base: base), download: { _ in try self.answer(200, "{}") }, today: "2026-10-26")
        let second = try await ProfileExport.run(client: APIClient(base: base), download: { _ in try self.answer(200, "{}") }, today: "2026-10-26")
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }
}
