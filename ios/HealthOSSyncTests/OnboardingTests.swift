import UniformTypeIdentifiers
import XCTest
@testable import HealthOSSync

/// The welcome, "Make this space yours" (Onboarding/): its rules against the web's own (src/pages/onboardingFlow.ts,
/// through test/onboarding-ui.test.ts and a fixture made by running that file), the page's moves (Onboarding.tsx go():
/// what each step and each tab saves, the age it stops for, a refusal), the reference photo on step 1, and its words
/// and colours against the web's files.
@MainActor
final class OnboardingTests: XCTestCase {
    // MARK: Helpers

    /// A file of the web app, next to the iPhone app in the repository.
    private func web(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(path)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { throw XCTSkip("\(path) isn't next to the app") }
        return text
    }

    private func fixture(_ name: String, _ ext: String = "json") throws -> Data {
        let url = Bundle(for: Self.self).url(forResource: name, withExtension: ext)
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name).\(ext)")
        return try Data(contentsOf: url)
    }

    private func settings(_ json: String) throws -> ServerStatus.Settings? {
        try JSONDecoder().decode(ServerStatus.self, from: Data(#"{"settings":\#(json)}"#.utf8)).settings
    }

    private func answers(_ perspective: OnboardingPerspective = .portrait, gender: Gender? = nil, figure: FigureVariant? = nil, age: String = "", peer: Bool = false) -> OnboardingAnswers {
        OnboardingAnswers(perspective: perspective, gender: gender, figure: figure, age: age, peer: peer)
    }

    /// A body as JSON with sorted keys, as PUT /api/settings sends it (nulls included).
    private func json(_ body: [String: Any]) throws -> String {
        String(decoding: try APIClient.settingsBody(body), as: UTF8.self)
    }

    private func step(_ n: Any?) -> OnboardingStep? { (n as? Int).flatMap(OnboardingStep.init(rawValue:)) }

    private func mode(_ s: Any?) -> OnboardingMode { (s as? String) == "edit" ? .edit : .new }

    private func answers(fromWeb a: [String: Any]) -> OnboardingAnswers {
        OnboardingAnswers(perspective: OnboardingPerspective(rawValue: a["perspective"] as? String ?? "") ?? .portrait,
                          gender: (a["gender"] as? String).flatMap(Gender.init(rawValue:)),
                          figure: (a["figure"] as? String).flatMap(FigureVariant.init(rawValue:)),
                          age: a["age"] as? String ?? "", peer: a["peer"] as? Bool ?? false)
    }

    // MARK: test/onboarding-ui.test.ts, assertion for assertion

    func testANewAccountResumesAtItsStepAndEditingStartsAtTheFirst() {
        XCTAssertEqual(OnboardingFlow.startStep(onboarding: 2, mode: .new), .about)
        XCTAssertEqual(OnboardingFlow.startStep(onboarding: 3, mode: .new), .community)
        XCTAssertEqual(OnboardingFlow.startStep(onboarding: nil, mode: .new), .perspective)
        XCTAssertEqual(OnboardingFlow.startStep(onboarding: 3, mode: .edit), .perspective)
    }

    func testTheStepsStartFromTheSettingsAsTheyAre() throws {
        let a = OnboardingFlow.answers(from: try settings(#"{"perspective":"stats","gender":"nonbinary","figure":"woman","age":33,"peerComparison":true}"#))
        XCTAssertEqual(a, answers(.stats, gender: .nonbinary, figure: .woman, age: "33", peer: true))
        // An older server without the fields: the defaults.
        XCTAssertEqual(OnboardingFlow.answers(from: try settings("{}")), answers())
        XCTAssertEqual(OnboardingFlow.answers(from: nil), answers())
    }

    func testAnAgeIsAWholeNumberOfYearsFrom1To120() {
        XCTAssertEqual(OnboardingFlow.parseAge("33"), 33)
        XCTAssertEqual(OnboardingFlow.parseAge(" 7 "), 7)
        for bad in ["", "0", "121", "33.5", "3x", "-4", "1000"] { XCTAssertNil(OnboardingFlow.parseAge(bad), bad) }
        // JavaScript's \d is ASCII only: other digits aren't an age there either.
        XCTAssertNil(OnboardingFlow.parseAge("٣٣"))
        XCTAssertFalse(OnboardingFlow.canJoinPeers(17))
        XCTAssertTrue(OnboardingFlow.canJoinPeers(18))
        XCTAssertFalse(OnboardingFlow.canJoinPeers(nil))
    }

    func testEachStepSavesItsOwnAnswersAndForANewAccountTheNextStep() throws {
        XCTAssertEqual(try json(OnboardingFlow.stepSave(.perspective, answers(.digital), mode: .new, to: .about)), #"{"onboarding":2,"perspective":"digital"}"#)
        XCTAssertEqual(try json(OnboardingFlow.stepSave(.about, answers(gender: .woman, figure: .man, age: "40"), mode: .new, to: .community)),
                       #"{"age":40,"figure":null,"gender":"woman","onboarding":3}"#)
        XCTAssertEqual(try json(OnboardingFlow.stepSave(.about, answers(gender: .unsaid, figure: .woman, age: "40"), mode: .new, to: .community)),
                       #"{"age":40,"figure":"woman","gender":"unsaid","onboarding":3}"#)
        // No gender chosen: neither it nor the figure is sent. An unreadable age is never sent as null (which deletes).
        XCTAssertEqual(try json(OnboardingFlow.stepSave(.about, answers(figure: .woman, age: "x"), mode: .new, to: .community)), #"{"onboarding":3}"#)
        XCTAssertEqual(try json(OnboardingFlow.stepSave(.community, answers(age: "40", peer: true), mode: .new, to: nil)),
                       #"{"onboarding":null,"peerComparison":true}"#)
    }

    func testEditingFromProfileNeverTouchesTheOnboardingMarker() {
        for step in OnboardingStep.allCases {
            XCTAssertNil(OnboardingFlow.stepSave(step, answers(age: "40"), mode: .edit, to: nil)["onboarding"], "step \(step.rawValue)")
        }
    }

    func testAStepTabThatJumpsAheadSavesEveryStepItPassesInOneRequest() throws {
        // Step 2 edited, Back to step 1 (nothing saved), then the 03 tab: the gender and age go with step 1's view.
        let a = answers(.digital, gender: .man, age: "40", peer: true)
        XCTAssertEqual(OnboardingFlow.stepsLeft(from: .perspective, to: .community), [.perspective, .about])
        XCTAssertEqual(try json(OnboardingFlow.forwardSave(from: .perspective, a, mode: .edit, to: .community)),
                       #"{"age":40,"figure":null,"gender":"man","perspective":"digital"}"#)
        XCTAssertEqual(try json(OnboardingFlow.forwardSave(from: .perspective, a, mode: .new, to: .community)),
                       #"{"age":40,"figure":null,"gender":"man","onboarding":3,"perspective":"digital"}"#)
        // Continue saves only the step it leaves, and finishing from step 3 only step 3.
        XCTAssertEqual(OnboardingFlow.stepsLeft(from: .perspective, to: .about), [.perspective])
        XCTAssertEqual(try json(OnboardingFlow.forwardSave(from: .perspective, a, mode: .edit, to: .about)), #"{"perspective":"digital"}"#)
        XCTAssertEqual(OnboardingFlow.stepsLeft(from: .community, to: nil), [.community])
        XCTAssertEqual(try json(OnboardingFlow.forwardSave(from: .community, a, mode: .edit, to: nil)), #"{"peerComparison":true}"#)
        // From step 2 to finish: steps 2 and 3, the age before the switch.
        XCTAssertEqual(try json(OnboardingFlow.forwardSave(from: .about, a, mode: .new, to: nil)),
                       #"{"age":40,"figure":null,"gender":"man","onboarding":null,"peerComparison":true}"#)
        XCTAssertTrue(OnboardingFlow.stepsLeft(from: .perspective, to: .community).contains(.about))
        XCTAssertFalse(OnboardingFlow.stepsLeft(from: .perspective, to: .about).contains(.about))
    }

    func testTakingPartIsOnlyEverSentOnWithAnAdultAge() {
        XCTAssertEqual(OnboardingFlow.stepSave(.community, answers(age: "16", peer: true), mode: .new, to: nil)["peerComparison"] as? Bool, false)
        XCTAssertEqual(OnboardingFlow.stepSave(.community, answers(age: "", peer: true), mode: .edit, to: nil)["peerComparison"] as? Bool, false)
        XCTAssertEqual(OnboardingFlow.stepSave(.community, answers(age: "18", peer: false), mode: .edit, to: nil)["peerComparison"] as? Bool, false)
    }

    func testTheDigitalHumanFollowsWomanAndManAndIsChosenForAnyOtherAnswer() {
        XCTAssertEqual(OnboardingFlow.figureOf(gender: .woman, figure: .man), .woman)
        XCTAssertEqual(OnboardingFlow.figureOf(gender: .man, figure: nil), .man)
        XCTAssertEqual(OnboardingFlow.figureOf(gender: .nonbinary, figure: .woman), .woman)
        XCTAssertEqual(OnboardingFlow.figureOf(gender: .unsaid, figure: nil), .man)
        XCTAssertEqual(OnboardingFlow.figureOf(gender: nil, figure: nil), .man)
    }

    func testThePreviewCardSaysWhatHomeWillShowNamingTheFigureActuallyDrawn() {
        XCTAssertEqual(OnboardingFlow.preview(answers(.digital, gender: .woman), hasPhoto: false, drawn: .woman).title, "Digital woman")
        // The woman's artwork isn't there yet, so the man's is drawn, and that's what it's called.
        XCTAssertEqual(OnboardingFlow.preview(answers(.digital, gender: .woman), hasPhoto: false, drawn: .man).title, "Digital man")
        XCTAssertTrue(OnboardingFlow.preview(answers(gender: .nonbinary, figure: .woman), hasPhoto: false, drawn: .man).text
            .contains(/Until your portrait is made.*digital man/))
        XCTAssertEqual(OnboardingFlow.preview(answers(.digital), hasPhoto: false, drawn: .man).eyebrow, "Your digital human")
        XCTAssertEqual(OnboardingFlow.preview(answers(.stats), hasPhoto: true, drawn: .man).title, "Just the statistics")
        XCTAssertTrue(OnboardingFlow.preview(answers(gender: .man), hasPhoto: false, drawn: .man).text.contains(/Until your portrait is made.*digital man/))
        XCTAssertFalse(OnboardingFlow.preview(answers(), hasPhoto: true, drawn: .man).text.contains("Until"))
        // What the app draws: the man, until the woman's artwork is in the app (FigureVariant.drawn).
        XCTAssertEqual(FigureVariant.woman.drawn, UIImage(named: "DigitalWoman") == nil ? .man : .woman)
    }

    func testStep1sPortraitLineSaysWhereAPortraitIsMadeOnThisServerAndNothingUntilItKnows() {
        let key = AiStatus.Key(provider: "openai", last4: "1234")
        XCTAssertNil(OnboardingFlow.portraitNext(nil, hasPhoto: false))
        XCTAssertTrue(OnboardingFlow.portraitNext(AiStatus(byok: true, keys: [key], portraits: true), hasPhoto: false)?.hasSuffix("on your OpenAI key.") == true)
        XCTAssertTrue(OnboardingFlow.portraitNext(AiStatus(byok: true), hasPhoto: false)?.contains("connect your own there") == true)
        // The server's key, and no way to store one's own: no connect clause.
        let shared = OnboardingFlow.portraitNext(AiStatus(portraits: true), hasPhoto: false) ?? ""
        XCTAssertTrue(shared.contains("this healthOS server's OpenAI key"))
        XCTAssertFalse(shared.contains("connect"))
        // Neither: no promise of a portrait studio that can't make one.
        let none = OnboardingFlow.portraitNext(AiStatus(), hasPhoto: false) ?? ""
        XCTAssertTrue(none.contains(/aren't available on this server yet.*the digital human meanwhile/))
        XCTAssertFalse(none.contains("OpenAI") || none.contains("connect"))
        XCTAssertTrue(OnboardingFlow.portraitNext(AiStatus(), hasPhoto: true)?.contains("your cut-out photo meanwhile") == true)
    }

    /// The servers' own answers (Fixtures/ai.json, a server with no keys at all, as the local ones are; ai-own-key.json,
    /// someone's own OpenAI key) read as the portrait line says them.
    func testThePortraitLineFollowsTheServersAiAnswer() async throws {
        let none = try JSONDecoder().decode(AiStatus.self, from: fixture("ai"))
        XCTAssertEqual(OnboardingFlow.portraitNext(none, hasPhoto: false),
                       "Portraits aren't available on this server yet, so your Home and Body pages show the digital human meanwhile.")
        let own = try JSONDecoder().decode(AiStatus.self, from: fixture("ai-own-key"))
        XCTAssertEqual(OnboardingFlow.portraitNext(own, hasPhoto: true),
                       "After saving, open the portrait studio in your Profile to generate and review your likeness on your OpenAI key.")
        // Unknown says nothing; a server without GET /api/ai (Availability's .missing) has no value either.
        let availability = Availability(chat: McFlyChat())
        XCTAssertNil(OnboardingFlow.portraitNext(availability.ai.value, hasPhoto: false))
        await availability.loadAI { nil }
        XCTAssertTrue(availability.aiMissing)
        XCTAssertNil(OnboardingFlow.portraitNext(availability.ai.value, hasPhoto: false))
    }

    // MARK: The web's own answers (Fixtures/onboarding-flow.json, from onboarding-flow.gen.mjs)

    func testThePortGivesTheWebsAnswersForEveryCaseInTheFixture() throws {
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture("onboarding-flow")) as? [String: Any])
        let all = try XCTUnwrap(root["answers"] as? [[String: Any]]).map(answers(fromWeb:))
        func rows(_ key: String) throws -> [[String: Any]] { try XCTUnwrap(root[key] as? [[String: Any]], key) }

        for row in try rows("startStep") {
            XCTAssertEqual(OnboardingFlow.startStep(onboarding: row["onboarding"] as? Int, mode: mode(row["mode"])).rawValue, row["step"] as? Int, "\(row)")
        }
        for row in try rows("answersFrom") {
            let s = try JSONDecoder().decode(ServerStatus.Settings.self, from: JSONSerialization.data(withJSONObject: row["settings"] as Any))
            XCTAssertEqual(OnboardingFlow.answers(from: s), answers(fromWeb: try XCTUnwrap(row["answers"] as? [String: Any])), "\(row)")
        }
        for row in try rows("parseAge") {
            XCTAssertEqual(OnboardingFlow.parseAge(row["text"] as? String ?? ""), row["age"] as? Int, "\(row)")
        }
        for row in try rows("figureOf") {
            let v = OnboardingFlow.figureOf(gender: (row["gender"] as? String).flatMap(Gender.init(rawValue:)), figure: (row["figure"] as? String).flatMap(FigureVariant.init(rawValue:)))
            XCTAssertEqual(v.rawValue, row["variant"] as? String, "\(row)")
        }
        for row in try rows("stepSave") {
            let a = all[try XCTUnwrap(row["a"] as? Int)]
            let body = OnboardingFlow.stepSave(try XCTUnwrap(step(row["step"])), a, mode: mode(row["mode"]), to: step(row["to"]))
            XCTAssertEqual(try json(body), try json(try XCTUnwrap(row["body"] as? [String: Any])), "\(row)")
        }
        for row in try rows("forwardSave") {
            let a = all[try XCTUnwrap(row["a"] as? Int)]
            let from = try XCTUnwrap(step(row["from"]))
            XCTAssertEqual(OnboardingFlow.stepsLeft(from: from, to: step(row["to"])).map(\.rawValue), row["left"] as? [Int], "\(row)")
            let body = OnboardingFlow.forwardSave(from: from, a, mode: mode(row["mode"]), to: step(row["to"]))
            XCTAssertEqual(try json(body), try json(try XCTUnwrap(row["body"] as? [String: Any])), "\(row)")
        }
        for row in try rows("preview") {
            let a = answers(fromWeb: try XCTUnwrap(row["answers"] as? [String: Any]))
            let card = OnboardingFlow.preview(a, hasPhoto: row["hasPhoto"] as? Bool ?? false, drawn: FigureVariant(rawValue: row["drawn"] as? String ?? "") ?? .man)
            let web = try XCTUnwrap(row["card"] as? [String: String])
            XCTAssertEqual([card.eyebrow, card.title, card.text], [web["eyebrow"], web["title"], web["text"]], "\(row)")
        }
        for row in try rows("portraitNext") {
            let ai = try (row["ai"] as? [String: Any]).map { try JSONDecoder().decode(AiStatus.self, from: JSONSerialization.data(withJSONObject: $0)) }
            XCTAssertEqual(OnboardingFlow.portraitNext(ai, hasPhoto: row["hasPhoto"] as? Bool ?? false), row["line"] as? String, "\(row)")
        }
    }

    // MARK: The page's moves (Onboarding.tsx go())

    private final class Sent {
        var bodies: [String] = []
        var finishing: [Bool] = []
        var finished = 0
        var refuse: String?
    }

    private func model(_ mode: OnboardingMode, _ settingsJSON: String) throws -> (OnboardingModel, Sent) {
        let sent = Sent()
        let model = OnboardingModel(mode: mode, settings: try settings(settingsJSON), save: { body, finishing in
            if let refuse = sent.refuse { throw APIError.network(refuse) }
            sent.bodies.append(String(decoding: try APIClient.settingsBody(body), as: UTF8.self))
            sent.finishing.append(finishing)
        }, finish: { sent.finished += 1 })
        return (model, sent)
    }

    func testANewAccountResumesAtTheStepItReachedAndEditingHasEveryTabOpen() throws {
        let (resumed, _) = try model(.new, #"{"perspective":"portrait","onboarding":2,"age":40}"#)
        XCTAssertEqual(resumed.step, .about)
        XCTAssertEqual(resumed.furthest, .about)
        XCTAssertEqual(resumed.nextTitle, "Continue")
        let (edit, _) = try model(.edit, #"{"perspective":"stats","onboarding":null,"age":40}"#)
        XCTAssertEqual(edit.step, .perspective)
        XCTAssertEqual(edit.furthest, .community)
        XCTAssertEqual(edit.answers.perspective, .stats)
    }

    func testContinueSavesTheStepItLeavesAndBackSavesNothing() async throws {
        let (m, sent) = try model(.new, #"{"perspective":"portrait","onboarding":1}"#)
        m.answers.perspective = .digital
        await m.next()
        XCTAssertEqual(sent.bodies, [#"{"onboarding":2,"perspective":"digital"}"#])
        XCTAssertEqual(m.step, .about)
        XCTAssertEqual(m.furthest, .about)
        await m.go(.perspective)
        XCTAssertEqual(m.step, .perspective)
        XCTAssertEqual(sent.bodies.count, 1, "Back saves nothing")
        XCTAssertEqual(m.furthest, .about, "a step reached stays open")
    }

    func testAnEmptyAgeStopsYouOnStep2() async throws {
        let (m, sent) = try model(.new, #"{"perspective":"portrait","onboarding":2}"#)
        m.answers.gender = .woman
        await m.next()
        XCTAssertEqual(sent.bodies, [], "nothing is sent without an age")
        XCTAssertEqual(m.step, .about)
        XCTAssertTrue(m.ageError)
        XCTAssertTrue(m.focusAge, "the age field takes the focus")
        m.setAge("4a2")
        XCTAssertEqual(m.answers.age, "42", "digits only")
        XCTAssertFalse(m.ageError, "a whole number of years clears it")
        await m.next()
        XCTAssertEqual(sent.bodies, [#"{"age":42,"figure":null,"gender":"woman","onboarding":3}"#])
        XCTAssertEqual(m.step, .community)
    }

    /// Onboarding.tsx's step effect: every new step starts at its top with the heading focused, unless that very move
    /// sent the person to step 2 for its age (focusAge, set only when the step changes). The age error itself stays
    /// after Back, as on the web, and mustn't count.
    func testAnAgeErrorLeftFromBeforeDoesntStopStep2OpeningAtItsHeading() async throws {
        let (m, sent) = try model(.new, #"{"perspective":"portrait","onboarding":2}"#)
        await m.next()
        XCTAssertTrue(m.ageError)
        XCTAssertFalse(m.takeSentForAge(), "already on step 2: the field takes the focus and no step opens")
        await m.go(.perspective)
        XCTAssertFalse(m.takeSentForAge())
        await m.next()
        XCTAssertEqual(sent.bodies, [#"{"onboarding":2,"perspective":"portrait"}"#], "only step 1 is left behind")
        XCTAssertEqual(m.step, .about)
        XCTAssertTrue(m.ageError, "the error still shows, as on the web")
        XCTAssertFalse(m.takeSentForAge(), "a plain move forward: step 2 opens at its top, VoiceOver on its heading")
    }

    func testATabThatJumpsPastStep2WithNoAgeOpensItForTheAgeOnce() async throws {
        let (m, _) = try model(.new, #"{"perspective":"portrait","onboarding":3}"#)
        await m.go(.perspective)
        await m.go(.community)
        XCTAssertEqual(m.step, .about, "sent to step 2 for its age")
        XCTAssertTrue(m.focusAge)
        XCTAssertTrue(m.takeSentForAge(), "the field takes the focus, not the heading")
        XCTAssertFalse(m.takeSentForAge(), "once only")
    }

    /// A status left from the person signed out before (a step's save that answered after their Sign out) names them,
    /// not who signs in next: the welcome shows nothing on it, and is built again from the signed-in person's own.
    func testTheWelcomeReadsOnlyTheSignedInPersonsOwnStatus() throws {
        let stale = try JSONDecoder().decode(ServerStatus.self, from: Data(
            #"{"user":{"id":"u-sam","email":"sam@example.test","role":"member"},"settings":{"perspective":"digital","onboarding":2,"age":44,"gender":"man"}}"#.utf8))
        XCTAssertEqual(stale.user?.id, "u-sam")
        XCTAssertFalse(OnboardingFlow.statusIsTheirs(statusUser: stale.user?.id, signedIn: "u-alex"), "Sam's answers never show on Alex's welcome")
        XCTAssertTrue(OnboardingFlow.statusIsTheirs(statusUser: stale.user?.id, signedIn: "u-sam"))
        XCTAssertTrue(OnboardingFlow.statusIsTheirs(statusUser: nil, signedIn: "u-alex"), "an older server's status names nobody")
        XCTAssertTrue(OnboardingFlow.statusIsTheirs(statusUser: "u-sam", signedIn: nil), "the server couldn't say who signed in")
        XCTAssertTrue(OnboardingFlow.personChanged(from: "u-sam", to: "u-alex"), "built again from Alex's own")
        XCTAssertFalse(OnboardingFlow.personChanged(from: "u-alex", to: "u-alex"), "a step's save keeps the steps where they are")
        XCTAssertFalse(OnboardingFlow.personChanged(from: nil, to: "u-alex"))
        XCTAssertFalse(OnboardingFlow.personChanged(from: "u-alex", to: nil))
    }

    func testATabThatJumpsPastStep2AsksForItsAgeFirstThenSavesBothStepsAtOnce() async throws {
        let (m, sent) = try model(.edit, #"{"perspective":"portrait","onboarding":null}"#)
        // Editing: every tab is open, and step 2 has no age yet.
        await m.go(.community)
        XCTAssertEqual(sent.bodies, [])
        XCTAssertEqual(m.step, .about, "sent to step 2 for its age")
        XCTAssertTrue(m.ageError)
        m.setAge("40")
        m.answers.gender = .man
        await m.go(.perspective)
        m.answers.perspective = .stats
        await m.go(.community)
        XCTAssertEqual(sent.bodies, [#"{"age":40,"figure":null,"gender":"man","perspective":"stats"}"#], "one request, no onboarding key")
        XCTAssertEqual(m.step, .community)
    }

    func testARefusalKeepsTheStepAndSaysWhy() async throws {
        let (m, sent) = try model(.new, #"{"perspective":"portrait","onboarding":3,"age":16}"#)
        sent.refuse = "Peer comparisons are for people aged 18 and over."
        await m.next()
        XCTAssertEqual(m.step, .community)
        XCTAssertEqual(m.error, "Peer comparisons are for people aged 18 and over.")
        XCTAssertFalse(m.busy, "Continue works again")
        XCTAssertEqual(sent.finished, 0)
        sent.refuse = nil
        await m.next()
        XCTAssertNil(m.error)
        XCTAssertEqual(sent.finished, 1)
    }

    func testANewAccountFinishesWithOnboardingNullAndAnEditNeverSendsIt() async throws {
        let (new, sentNew) = try model(.new, #"{"perspective":"portrait","onboarding":3,"age":30}"#)
        XCTAssertEqual(new.nextTitle, "Enter my workspace")
        new.answers.peer = true
        await new.next()
        XCTAssertEqual(sentNew.bodies, [#"{"onboarding":null,"peerComparison":true}"#])
        XCTAssertEqual(sentNew.finishing, [true], "the last save reads the dashboard again")
        XCTAssertEqual(sentNew.finished, 1)
        XCTAssertTrue(new.busy, "busy until the welcome has gone")

        let (edit, sentEdit) = try model(.edit, #"{"perspective":"portrait","age":30,"peerComparison":true}"#)
        await edit.go(.community)
        XCTAssertEqual(edit.nextTitle, "Save preferences")
        await edit.next()
        XCTAssertEqual(sentEdit.bodies.last, #"{"peerComparison":true}"#)
        XCTAssertFalse(sentEdit.bodies.contains { $0.contains("onboarding") })
        XCTAssertEqual(sentEdit.finished, 1)
    }

    func testAnAgeUnder18TurnsTakingPartOff() throws {
        let (m, _) = try model(.edit, #"{"perspective":"portrait","age":40,"peerComparison":true}"#)
        XCTAssertTrue(m.answers.peer)
        m.setAge("16")
        XCTAssertFalse(m.answers.peer)
        m.setAge("1234")
        XCTAssertEqual(m.answers.age, "123", "three digits at most")
    }

    // MARK: Step 1's reference photo (useReferencePhoto)

    private final class Portraits {
        var added: [Int] = []
        var deleted: [String] = []
        var failAdd = false
        var failDelete = false
        var next = 0
        var events: [String] = []
    }

    private func photo(_ width: Int = 10) -> PreparedPhoto { PreparedPhoto(jpeg: tinyJPEG(width), width: width, height: width) }

    private func tinyJPEG(_ width: Int) -> Data {
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: width)).image { ctx in
            UIColor.gray.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: width))
        }
        return image.jpegData(compressionQuality: 0.8)!
    }

    private func reference(_ store: Portraits, list: PortraitList? = nil) -> ReferencePhoto {
        ReferencePhoto(add: { photo in
            if store.failAdd { throw APIError.server(500, "") }
            store.next += 1
            store.added.append(photo.width)
            store.events.append("add r\(store.next)")
            return Portrait(id: "r\(store.next)", kind: "reference", status: "ready")
        }, delete: { id in
            if store.failDelete { throw APIError.server(500, "") }
            store.deleted.append(id)
            store.events.append("delete \(id)")
        }, list: { list })
    }

    func testAPhotoIsKeptThenChangeKeepsTheNewOneBeforeDeletingTheOld() async throws {
        let store = Portraits()
        let ref = reference(store)
        ref.choose { [photo = photo(10)] in photo }
        await ref.settle()
        XCTAssertEqual(ref.photo?.state, .saved)
        XCTAssertEqual(ref.photo?.id, "r1")
        XCTAssertNil(ref.note)
        ref.choose { [photo = photo(20)] in photo }
        await ref.settle()
        XCTAssertEqual(store.events, ["add r1", "add r2", "delete r1"], "the new one is kept first, then the old one goes")
        XCTAssertEqual(ref.photo?.id, "r2")
    }

    func testAPhotoThatCouldntBeSavedSaysSoAndContinueDoesntWaitForIt() async throws {
        let store = Portraits()
        store.failAdd = true
        let ref = reference(store)
        ref.choose { [photo = photo()] in photo }
        await ref.settle()
        XCTAssertEqual(ref.photo?.state, .failed)
        XCTAssertEqual(ref.note, "Your photo couldn't be saved just now. You can add it later in your Profile.")
        XCTAssertEqual(store.deleted, [])
        // Remove: one that never saved just goes.
        await ref.remove()
        XCTAssertNil(ref.photo)
        XCTAssertEqual(store.deleted, [])
    }

    func testAPhotoThatCantBeOpenedLeavesTheOneBefore() async throws {
        let store = Portraits()
        let ref = reference(store)
        ref.choose { [photo = photo()] in photo }
        await ref.settle()
        ref.choose { nil }
        await ref.settle()
        XCTAssertEqual(ref.note, "That photo couldn't be opened here. Try a JPEG or PNG.")
        XCTAssertEqual(ref.photo?.id, "r1", "the one before stays")
        XCTAssertEqual(store.added.count, 1)
        XCTAssertFalse(ref.busy, "another can be chosen")
    }

    func testRemoveDeletesASavedPhotoAndKeepsItWhenTheDeleteFails() async throws {
        let store = Portraits()
        let ref = reference(store)
        ref.choose { [photo = photo()] in photo }
        await ref.settle()
        store.failDelete = true
        await ref.remove()
        XCTAssertEqual(ref.note, "Your photo couldn't be removed just now. Try again, or remove it later in your Profile.")
        XCTAssertNotNil(ref.photo)
        store.failDelete = false
        await ref.remove()
        XCTAssertEqual(store.deleted, ["r1"])
        XCTAssertNil(ref.photo)
        XCTAssertNil(ref.note)
    }

    /// Fixtures/portraits.json: one reference kept before. A server without portraits (nil) has no row; one not read yet
    /// shows it.
    func testPhotosKeptBeforeAndServersWithoutPortraits() async throws {
        let list = try JSONDecoder().decode(PortraitList.self, from: fixture("portraits"))
        let ref = reference(Portraits(), list: list)
        XCTAssertNil(ref.available, "unknown until read")
        await ref.load()
        XCTAssertEqual(ref.available, true)
        XCTAssertEqual(ref.earlier, 1)
        let older = reference(Portraits(), list: nil)
        await older.load()
        XCTAssertEqual(older.available, false)
    }

    func testSigningOutStopsThePhotoAndForgetsIt() async throws {
        let store = Portraits()
        let ref = reference(store)
        ref.choose { [photo = photo()] in photo }
        ref.forget()
        await ref.settle()
        XCTAssertNil(ref.photo)
    }

    /// Holds a photo "on its way" (being read from Photos and shrunk) until the test lets it go.
    private actor Gate {
        private var opened = false
        private var waiting: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiting.append($0) }
        }
        func open() {
            opened = true
            waiting.forEach { $0.resume() }
            waiting = []
        }
    }

    /// A second pick while the first is still being read and shrunk would read the first as not kept yet, so its
    /// replacement would never delete it: an orphan on the server, counting toward its five references. The row is busy
    /// from the pick, and a pick meanwhile is turned down.
    func testAPhotoOnItsWayTurnsDownAnotherSoNoneIsLeftOnTheServer() async throws {
        let store = Portraits()
        let ref = reference(store)
        ref.choose { [photo = photo(10)] in photo }
        await ref.settle()
        XCTAssertFalse(ref.busy)
        let gate = Gate()
        ref.choose { [photo = photo(20)] in
            await gate.wait()
            return photo
        }
        XCTAssertTrue(ref.busy, "busy as soon as it's picked, before it's read and shrunk")
        XCTAssertTrue(ref.preparing)
        XCTAssertEqual(ref.photo?.state, .saved, "the one before still shows meanwhile")
        ref.choose { [photo = photo(30)] in photo }
        await ref.remove()
        await gate.open()
        await ref.settle()
        XCTAssertEqual(store.events, ["add r1", "add r2", "delete r1"], "the pick and Remove meanwhile did nothing")
        XCTAssertEqual(store.added, [10, 20])
        XCTAssertEqual(ref.photo?.id, "r2")
        XCTAssertFalse(ref.busy)
    }

    /// Remove waits for the server; a photo chosen meanwhile would be wiped from the row when the delete lands, and
    /// stay on the server unseen.
    func testAPhotoPickedWhileRemoveIsDeletingIsTurnedDown() async throws {
        let gate = Gate()
        var added = 0
        let ref = ReferencePhoto(add: { _ in
            added += 1
            return Portrait(id: "r\(added)", kind: "reference", status: "ready")
        }, delete: { _ in await gate.wait() }, list: { nil })
        ref.choose { [photo = photo()] in photo }
        await ref.settle()
        let removing = Task { await ref.remove() }
        while !ref.removing { await Task.yield() }
        XCTAssertTrue(ref.busy)
        ref.choose { [photo = photo(20)] in photo }
        await gate.open()
        await removing.value
        await ref.settle()
        XCTAssertEqual(added, 1, "the pick during Remove was never sent")
        XCTAssertNil(ref.photo)
        XCTAssertFalse(ref.busy)
    }

    func testSigningOutWhileAPhotoIsReadLeavesNothingWhenItArrives() async throws {
        let store = Portraits()
        let ref = reference(store)
        let gate = Gate()
        ref.choose { [photo = photo()] in
            await gate.wait()
            return photo
        }
        ref.forget()
        XCTAssertFalse(ref.busy, "a new sign-in can choose at once")
        await gate.open()
        await ref.settle()
        XCTAssertNil(ref.photo)
        XCTAssertEqual(store.added, [], "never sent")
        XCTAssertFalse(ref.busy)
    }

    /// A camera photo as a phone keeps it: stored on its side (2400×1800, left half red, right half blue) with EXIF
    /// orientation 6, so it shows upright as 1800×2400, red on top; plus where and when it was taken, and the camera.
    private func cameraJPEG() throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let stored = UIGraphicsImageRenderer(size: CGSize(width: 2400, height: 1800), format: format).image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 1200, height: 1800))
            UIColor.blue.setFill()
            ctx.fill(CGRect(x: 1200, y: 0, width: 1200, height: 1800))
        }
        let out = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil))
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFOrientation: 6, kCGImagePropertyTIFFMake: "MadeUpCam"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:10:26 04:00:00", kCGImagePropertyExifUserComment: "made-up"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 51.5, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 0.12, kCGImagePropertyGPSLongitudeRef: "W"],
        ]
        CGImageDestinationAddImage(dest, try XCTUnwrap(stored.cgImage), properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return out as Data
    }

    private func properties(_ jpeg: Data) throws -> [CFString: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }

    /// One pixel's red and blue, from the top left.
    private func redAndBlue(_ image: CGImage, x: Int, y: Int) throws -> (red: UInt8, blue: UInt8) {
        var pixel = [UInt8](repeating: 0, count: 4)
        let ctx = try XCTUnwrap(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (pixel[0], pixel[2])
    }

    /// The real shrink, from a camera photo's bytes: turned upright on the phone (the server never rotates), with
    /// nothing of where, when or with what it was taken, within the server's limits.
    func testAChosenPhotoGoesThroughThePhotoPipeline() async throws {
        var kept: PreparedPhoto?
        let ref = ReferencePhoto(add: { photo in
            kept = photo
            return Portrait(id: "r1", kind: "reference", status: "ready")
        }, delete: { _ in }, list: { nil })
        let data = try cameraJPEG()
        // The photo as picked does carry it all.
        let before = try properties(data)
        XCTAssertEqual(before[kCGImagePropertyOrientation] as? Int, 6)
        XCTAssertNotNil(before[kCGImagePropertyGPSDictionary])

        ref.choose { PhotoPipeline.reference(data) }
        await ref.settle()
        let photo = try XCTUnwrap(kept)
        XCTAssertEqual(max(photo.width, photo.height), PortraitLimits.maxReferenceEdge)
        XCTAssertLessThanOrEqual(photo.base64Count, PortraitLimits.maxReferenceBase64)

        // Upright: taller than wide, red on top and blue below, with no orientation left to apply.
        XCTAssertLessThan(photo.width, photo.height)
        let after = try properties(photo.jpeg)
        XCTAssertEqual(after[kCGImagePropertyPixelWidth] as? Int, photo.width)
        XCTAssertEqual(after[kCGImagePropertyPixelHeight] as? Int, photo.height)
        XCTAssertEqual((after[kCGImagePropertyOrientation] as? Int) ?? 1, 1)
        let image = try XCTUnwrap(UIImage(data: photo.jpeg)?.cgImage)
        let top = try redAndBlue(image, x: image.width / 2, y: image.height / 8)
        let bottom = try redAndBlue(image, x: image.width / 2, y: image.height * 7 / 8)
        XCTAssertGreaterThan(top.red, 200)
        XCTAssertLessThan(top.blue, 60)
        XCTAssertGreaterThan(bottom.blue, 200)
        XCTAssertLessThan(bottom.red, 60)

        // No metadata: no place, no time taken, no camera, no comment.
        XCTAssertNil(after[kCGImagePropertyGPSDictionary], "where it was taken")
        let exif = after[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        XCTAssertNil(exif[kCGImagePropertyExifDateTimeOriginal], "when")
        XCTAssertNil(exif[kCGImagePropertyExifUserComment])
        let tiff = after[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        XCTAssertNil(tiff[kCGImagePropertyTIFFMake], "with what")
        XCTAssertEqual((tiff[kCGImagePropertyTIFFOrientation] as? Int) ?? 1, 1)
    }

    // MARK: Words and look against the web's files

    func testTheStepsWordsAreTheWebs() throws {
        let page = try web("src/pages/Onboarding.tsx")
        for step in OnboardingStep.allCases {
            for words in [step.label, step.title, step.lede, step.hint] { XCTAssertTrue(page.contains("'\(words)'"), words) }
        }
        for view in PerspectiveStep.views {
            XCTAssertTrue(page.contains("{ id: '\(view.id.rawValue)', title: '\(view.title)', text: '\(view.text)' }"), view.title)
        }
        for gender in Gender.allCases { XCTAssertTrue(page.contains("{ id: '\(gender.rawValue)', label: '\(gender.label)' }"), gender.label) }
        for words in [ReferencePhoto.notSaved] { XCTAssertTrue(page.contains("\"\(words)\""), words) }
        for words in [ReferencePhoto.notOpened, ReferencePhoto.notRemoved] { XCTAssertTrue(page.contains("\"\(words)\""), words) }
        let quoted: [String] = [
            OnboardingWords.eyebrow, OnboardingWords.backToProfile, OnboardingWords.savePreferences, OnboardingWords.enterWorkspace,
            OnboardingWords.referenceTitle, OnboardingWords.referenceText, OnboardingWords.referenceSaving, OnboardingWords.referenceSaved,
            OnboardingWords.referenceEarlier, OnboardingWords.choosePhoto, OnboardingWords.referenceAfter, OnboardingWords.referenceAlt,
            OnboardingWords.genderQuestion, OnboardingWords.genderNote, OnboardingWords.ageLabel, OnboardingWords.ageError,
            OnboardingWords.showMeAs, OnboardingWords.peersTitle, OnboardingWords.consentTitle, OnboardingWords.consentNeedsAge,
            OnboardingWords.peersNote, OnboardingWords.defaultBadge,
        ]
        // JSX text runs over several lines on the web: compare with its whitespace folded.
        let folded = page.replacing(/\s+/, with: " ")
        for words in quoted { XCTAssertTrue(folded.contains(words), words) }
        // The lines built from the peer constants, with the web's ${…} put back.
        let templated: [(String, String)] = [
            (OnboardingWords.ageNote, "Your age is kept private. Peer comparisons are for people aged {PEER_MIN_AGE} and over."),
            (OnboardingWords.peersText, "Compare {PEER_WINDOW_DAYS}-day averages within your age group, using the same measurement and source. In comparisons, your name, photo and individual readings are never shown to anyone else: others see only group figures."),
            (OnboardingWords.consentText, "Your {PEER_WINDOW_DAYS}-day averages count toward the group's median and quartiles. Results need at least {PEER_MIN_OTHERS} other participating people and {PEER_MIN_DAYS} recorded days per person. You can leave anytime in Profile."),
            (OnboardingWords.consentAdults, "Peer comparisons are for people aged ${PEER_MIN_AGE} and over."),
        ]
        for (ours, theirs) in templated {
            XCTAssertTrue(folded.contains(theirs), theirs)
            let filled = theirs.replacing("${PEER_MIN_AGE}", with: "\(Peers.minAge)").replacing("{PEER_MIN_AGE}", with: "\(Peers.minAge)")
                .replacing("{PEER_WINDOW_DAYS}", with: "\(Peers.windowDays)").replacing("{PEER_MIN_OTHERS}", with: "\(Peers.minOthers)")
                .replacing("{PEER_MIN_DAYS}", with: "\(Peers.minDays)")
            XCTAssertEqual(ours, filled)
        }
        XCTAssertTrue(try web("src/components/WelcomeShell.tsx").contains(WelcomeLook.tagline))
    }

    /// onboarding.css's tokens, light (its :root block) and dark (its dark block), as WelcomeLook has them.
    func testTheWelcomesColoursAreOnboardingCss() throws {
        let sheet = try web("src/styles/onboarding.css")
        let lightBlock = try XCTUnwrap(sheet.firstMatch(of: /:root \{([^}]*)\}/)?.output.1)
        let darkBlock = try XCTUnwrap(sheet.firstMatch(of: /:root:not\(\[data-theme='light'\]\) \{([^}]*)\}/)?.output.1)
        func value(_ name: String, in block: Substring) throws -> String {
            let regex = try Regex("--\(name):([^;]*);")
            return String(try XCTUnwrap(block.firstMatch(of: regex)?.output[1].substring, name)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Each colour as one spelling: hex in lower case, rgba's numbers as %g (0.0 and 0 alike).
        func normal(_ color: String) -> String {
            guard color.hasPrefix("rgba(") else { return color.lowercased() }
            let numbers = color.dropFirst(5).dropLast().split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            return "rgba(" + numbers.map { String(format: "%g", $0) }.joined(separator: ",") + ")"
        }
        func colors(_ text: String) -> [String] {
            text.matches(of: /#[0-9a-fA-F]{6}|rgba\([^)]*\)|var\(--page-glow\)/).map { normal(String($0.output)) }
        }
        func css(_ c: CSSColor) -> String { normal(c.description) }
        let plain: [(String, Themed<CSSColor>)] = [
            ("onb-step-off", WelcomeLook.stepOff), ("onb-field", WelcomeLook.field), ("onb-field-border", WelcomeLook.fieldBorder),
            ("onb-chip-on", WelcomeLook.chipOn), ("onb-card-bg", WelcomeLook.cardBg), ("onb-art-shade", WelcomeLook.artShade),
            ("onb-bust-light", WelcomeLook.bustLight), ("onb-bust-dark", WelcomeLook.bustDark), ("onb-bar-top", WelcomeLook.barTop),
            ("onb-bar-bottom", WelcomeLook.barBottom), ("onb-you-top", WelcomeLook.youTop), ("onb-you-bottom", WelcomeLook.youBottom),
            ("onb-consent-border", WelcomeLook.consentBorder),
        ]
        for (name, themed) in plain {
            XCTAssertEqual(colors(try value(name, in: lightBlock)), [css(themed.light)], name)
            XCTAssertEqual(colors(try value(name, in: darkBlock)), [css(themed.dark)], "\(name) dark")
        }
        let gradients: [(String, Themed<[CSSGradient]>)] = [("onb-peach", WelcomeLook.peach), ("onb-consent-bg", WelcomeLook.consentBg), ("onb-bg", WelcomeLook.background)]
        let glow = (light: css(ColorToken.pageGlow.value.light), dark: css(ColorToken.pageGlow.value.dark))
        for (name, themed) in gradients {
            let light = colors(try value(name, in: lightBlock)).map { $0 == "var(--page-glow)" ? glow.light : $0 }
            let dark = colors(try value(name, in: darkBlock)).map { $0 == "var(--page-glow)" ? glow.dark : $0 }
            XCTAssertEqual(light, themed.light.flatMap(\.stops).map { css($0.color) }, name)
            XCTAssertEqual(dark, themed.dark.flatMap(\.stops).map { css($0.color) }, "\(name) dark")
        }
        // The forced-dark block repeats the dark one (change both together, onboarding.css says).
        let forced = try XCTUnwrap(sheet.firstMatch(of: /:root\[data-theme='dark'\] \{([^}]*)\}/)?.output.1)
        XCTAssertEqual(forced.replacing(/\s+/, with: " ").trimmingCharacters(in: .whitespaces), darkBlock.replacing(/\s+/, with: " ").trimmingCharacters(in: .whitespaces))
    }

    /// Step 2's chips are the welcome's own, smaller than the shared ChipToggle: .onb .onb-chip's size, padding and
    /// height (no phone-width rule changes them).
    func testStep2sChipsAreSizedAsOnboardingCssSizesThem() throws {
        let sheet = try web("src/styles/onboarding.css")
        let rules = sheet.matches(of: /\.onb \.onb-chip \{([^}]*)\}/).map { String($0.output.1) }
        XCTAssertEqual(rules.count, 1, "one rule sizes the chips, at every width")
        let rule = try XCTUnwrap(rules.first)
        XCTAssertTrue(rule.contains("font-size: \(Int(WelcomeLook.chipFont))px;"), rule)
        XCTAssertTrue(rule.contains("padding: 0 \(Int(WelcomeLook.chipPadding))px;"), rule)
        XCTAssertTrue(rule.contains("min-height: \(Int(WelcomeLook.chipHeight))px;"), rule)
    }
}
