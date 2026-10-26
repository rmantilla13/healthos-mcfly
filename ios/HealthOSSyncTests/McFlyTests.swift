import XCTest
@testable import HealthOSSync

/// Ask McFly's page and pill (Dashboard/McFly.swift, AI/McFlyPage.swift) against the web's src/pages/McFly.tsx and
/// src/components/shell/AskPill.tsx: its words, whose key answers or how many questions are left, why it can't answer
/// here and what to do about it, every step it read, Stop, and its answers' little Markdown.
@MainActor
final class McFlyTests: XCTestCase {
    private func web(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard let text = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) else { throw XCTSkip("\(path) isn't next to the app") }
        return text
    }

    private func status(_ json: String) throws -> McFlyStatus { try JSONDecoder().decode(McFlyStatus.self, from: Data(json.utf8)) }

    // MARK: Words

    func testThePagesWordsAreTheWebs() throws {
        let page = try web("src/pages/McFly.tsx")
        var words = [McFlyWords.sub, McFlyWords.tryThese, McFlyWords.thinking, McFlyWords.steps, McFlyWords.stopped, McFlyWords.noAnswer,
                     McFlyWords.couldNotAnswer, McFlyWords.connect, "New chat", "Stop", "Ask", "Your question",
                     "You've reached today's question limit.", "Ask about your health data…", "You've reached today's limit on your own key.",
                     "Set a daily question limit above 0 in Admin → Settings.",
                     "Add ANTHROPIC_API_KEY (from the Claude Console) to the Vercel project, then redeploy.",
                     "The shared assistant is off right now.", "There's no shared assistant on this server.", "Ask the admin to turn it on.",
                     " You can connect your own AI key in Profile → Chatbot: OpenAI, Claude or Gemini.",
                     McFlyWords.title(.off), McFlyWords.title(.notSetUp)]
        words += McFlyWords.suggestions
        for w in words { XCTAssertTrue(page.contains(w), "“\(w)” isn't in McFly.tsx") }
        XCTAssertEqual(McFlyWords.suggestions.count, 5)
        XCTAssertTrue(page.contains("const PROVIDER = { anthropic: 'Claude', openai: 'OpenAI', gemini: 'Gemini' } as const;"))

        let pill = try web("src/components/shell/AskPill.tsx")
        XCTAssertTrue(pill.contains("<b>Ask McFly</b>"))
        XCTAssertTrue(pill.contains("<small>A little more clarity</small>"))
        // The web shows the pill on Home always; nothing hides it when McFly can't answer.
        XCTAssertTrue(try web("src/App.tsx").contains("{page === 'home' && <AskPill />}"))
    }

    func testWhatToDoWhenMcFlyCantAnswerHere() {
        XCTAssertEqual(McFlyWords.text(.notSetUp, admin: true, byok: false), "Add ANTHROPIC_API_KEY (from the Claude Console) to the Vercel project, then redeploy.")
        XCTAssertEqual(McFlyWords.text(.off, admin: true, byok: false), "Set a daily question limit above 0 in Admin → Settings.")
        XCTAssertEqual(McFlyWords.text(.off, admin: false, byok: false), "Ask the admin to turn it on.")
        XCTAssertEqual(McFlyWords.text(.notSetUp, admin: false, byok: true),
                       "There's no shared assistant on this server. You can connect your own AI key in Profile → Chatbot: OpenAI, Claude or Gemini.")
        XCTAssertEqual(McFlyWords.text(.off, admin: false, byok: true),
                       "The shared assistant is off right now. You can connect your own AI key in Profile → Chatbot: OpenAI, Claude or Gemini.")
        // The local servers: no Claude key, keys can be stored, the owner is the admin.
        XCTAssertEqual(McFlyWords.text(.notSetUp, admin: true, byok: true),
                       "Add ANTHROPIC_API_KEY (from the Claude Console) to the Vercel project, then redeploy. You can connect your own AI key in Profile → Chatbot: OpenAI, Claude or Gemini.")
        XCTAssertEqual(McFlyWords.title(.notSetUp), "Ask McFly isn't set up yet")
        XCTAssertEqual(McFlyWords.title(.off), "Ask McFly is turned off")
    }

    // MARK: Status

    func testWhyItCantAnswerFollowsTheServersStatus() throws {
        let fixture = try JSONDecoder().decode(McFlyStatus.self, from: Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/mcfly.json")))
        XCTAssertEqual(fixture.unavailable, .notSetUp, "a local server with no assistant")
        XCTAssertEqual(try status(#"{"configured":true,"limit":0,"usedToday":0,"provider":"anthropic","source":"shared","limited":true}"#).unavailable, .off)
        XCTAssertNil(try status(#"{"configured":true,"limit":200,"usedToday":0,"provider":"gemini","source":"own","limited":false}"#).unavailable)
        XCTAssertNil(try status(#"{"configured":true,"limit":30,"usedToday":30}"#).unavailable, "out of questions is still on")
        // The same as Availability's McFlyState, which other pages read.
        for json in [#"{"configured":false,"limit":50,"usedToday":0}"#, #"{"configured":true,"limit":0,"usedToday":0,"source":"shared"}"#,
                     #"{"configured":true,"limit":0,"usedToday":0,"source":"own"}"#, #"{"configured":true,"limit":5,"usedToday":1}"#] {
            let s = try status(json)
            switch McFlyState(s) {
            case .available: XCTAssertNil(s.unavailable, json)
            case .off: XCTAssertEqual(s.unavailable, .off, json)
            case .notSetUp: XCTAssertEqual(s.unavailable, .notSetUp, json)
            case .unknown: XCTFail(json)
            }
        }
    }

    func testAnOwnKeyNamesItsProviderNeverTheCapAsQuestionsLeft() throws {
        let own = try status(#"{"configured":true,"limit":200,"usedToday":3,"provider":"openai","source":"own","limited":false}"#)
        XCTAssertEqual(McFlyWords.composerLine(own), "On your OpenAI key")
        XCTAssertNil(own.questionsLeft)
        XCTAssertEqual(McFlyWords.composerLine(try status(#"{"configured":true,"limit":200,"usedToday":0,"provider":"anthropic","source":"own"}"#)), "On your Claude key")
        XCTAssertEqual(McFlyWords.composerLine(try status(#"{"configured":true,"limit":200,"usedToday":0,"source":"own"}"#)), "On your key")
        let capped = try status(#"{"configured":true,"limit":200,"usedToday":200,"provider":"gemini","source":"own","limited":false}"#)
        XCTAssertEqual(capped.questionsLeft, 0)
        XCTAssertEqual(McFlyWords.composerLine(capped), "You've reached today's limit on your own key.")
        XCTAssertEqual(McFlyWords.placeholder(capped), "You've reached today's question limit.")
        XCTAssertFalse(McFlyWords.composerLine(own).contains("question"), "never “197 questions left today”")
    }

    func testTheSharedKeyCountsDownTodaysQuestions() throws {
        let s = try status(#"{"configured":true,"limit":30,"usedToday":4,"provider":"anthropic","source":"shared","limited":true}"#)
        XCTAssertEqual(McFlyWords.composerLine(s), "26 questions left today")
        XCTAssertEqual(McFlyWords.composerLine(try status(#"{"configured":true,"limit":30,"usedToday":29}"#)), "1 question left today")
        let out = try status(#"{"configured":true,"limit":30,"usedToday":31}"#)
        XCTAssertEqual(out.questionsLeft, 0)
        XCTAssertEqual(McFlyWords.composerLine(out), "0 questions left today")
        XCTAssertEqual(McFlyWords.placeholder(out), "You've reached today's question limit.")
        XCTAssertEqual(McFlyWords.placeholder(s), "Ask about your health data…")
        XCTAssertEqual(McFlyWords.composerLine(nil), "", "nothing said until the server says")
        XCTAssertNil(try status(#"{"configured":true,"limit":0,"usedToday":0}"#).questionsLeft)
    }

    // MARK: An answer

    func testEveryStepIsListedAndTheOneMcFlyIsOnShows() {
        var m = McFlyMessage(role: .assistant, content: "", pending: true)
        XCTAssertTrue(m.thinking, "nothing read or said yet: thinking")
        m.apply(.tool("Looking at your sleep"))
        XCTAssertFalse(m.thinking)
        XCTAssertEqual(m.workingStep, 0)
        m.apply(.tool("Comparing with the week before"))
        XCTAssertEqual(m.steps, ["Looking at your sleep", "Comparing with the week before"])
        XCTAssertEqual(m.workingStep, 1, "the last step shimmers")
        m.apply(.text("You slept"))
        XCTAssertNil(m.workingStep, "once words come, every step is done")
        m.finishAnswer()
        XCTAssertFalse(m.pending)
        XCTAssertNil(m.error)
    }

    func testStopKeepsWhatArrivedOrSaysStopped() {
        var nothing = McFlyMessage(role: .assistant, content: "", pending: true)
        nothing.apply(.tool("Looking at your steps"))
        nothing.stop()
        nothing.finishAnswer()
        XCTAssertEqual(nothing.error, "Stopped.")

        var partly = McFlyMessage(role: .assistant, content: "", pending: true)
        partly.apply(.text("Your steps were up"))
        partly.stop()
        partly.finishAnswer()
        XCTAssertNil(partly.error, "what arrived stands as the answer")
        let turns = McFlyMessage.history([McFlyMessage(role: .user, content: "Steps?"), partly], question: "And sleep?")
        XCTAssertEqual(turns.map(\.content), ["Steps?", "Your steps were up", "And sleep?"], "and McFly reads it back, as the web's does")

        var blank = McFlyMessage(role: .assistant, content: "", pending: true)
        blank.apply(.text("\n\n"))
        blank.stop()
        blank.finishAnswer()
        XCTAssertEqual(blank.error, "McFly had no answer. Try asking another way.")
    }

    func testStopEndsTheRequestAndTheConversationCarriesOn() async throws {
        let saved = UserDefaults.standard.string(forKey: "serverURL")
        defer { if let saved { UserDefaults.standard.set(saved, forKey: "serverURL") } else { UserDefaults.standard.removeObject(forKey: "serverURL") } }
        Config.serverText = "http://127.0.0.1:9" // nothing listens here
        let chat = McFlyChat()
        chat.send("How did I sleep?")
        XCTAssertTrue(chat.streaming, "streaming from the tap, so Stop shows at once")
        chat.send("Again?")
        chat.stop()
        for _ in 0..<200 where chat.streaming { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(chat.streaming)
        XCTAssertEqual(chat.messages.map(\.content), ["How did I sleep?", ""], "a second tap while it streams sends nothing")
        XCTAssertEqual(chat.messages.last?.error, "Stopped.")
        XCTAssertEqual(chat.messages.last?.pending, false)

        // Not stopped: a server that can't be reached says so under the question.
        chat.send("And my steps?")
        for _ in 0..<500 where chat.streaming { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(chat.streaming)
        XCTAssertEqual(chat.messages.count, 4)
        XCTAssertTrue(chat.messages.last?.error?.hasPrefix("Can't reach 127.0.0.1") == true, chat.messages.last?.error ?? "")

        // Forgotten (signed out) while asking: the request ends and nothing is left.
        chat.send("One more?")
        chat.forget()
        XCTAssertFalse(chat.streaming)
        XCTAssertTrue(chat.messages.isEmpty)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(chat.messages.isEmpty, "an answer on its way never lands in the next person's conversation")
        chat.stop() // nothing streaming: nothing happens
        XCTAssertFalse(chat.streaming)
    }

    func testAFailedStatusReadKeepsWhatWasKnown() async {
        let saved = UserDefaults.standard.string(forKey: "serverURL")
        defer { if let saved { UserDefaults.standard.set(saved, forKey: "serverURL") } else { UserDefaults.standard.removeObject(forKey: "serverURL") } }
        Config.serverText = "http://127.0.0.1:9"
        let chat = McFlyChat()
        let known = McFlyStatus(configured: true, limit: 30, usedToday: 2, provider: "anthropic", source: "shared", limited: true)
        chat.status = known
        await chat.refreshStatus()
        XCTAssertEqual(chat.status, known, "offline isn't “not set up”")
        chat.forget()
        XCTAssertNil(chat.status)
    }

    // MARK: Answers' Markdown

    func testAnswersReadTheWebsLittleMarkdown() {
        XCTAssertEqual(McFlyAnswer.blocks("Hello\nthere\n\n- one\n* two\n• three\n\n1. first\n2) second\n\n## Sleep\nok\n\n\n"), [
            .paragraph(["Hello", "there"]),
            .bullets(["one", "two", "three"]),
            .numbered(["first", "second"]),
            .paragraph(["Sleep", "ok"]),
        ])
        XCTAssertEqual(McFlyAnswer.blocks("- one\nnot a list"), [.paragraph(["- one", "not a list"])], "a list only when every line is one")
        XCTAssertEqual(McFlyAnswer.blocks("  \n "), [])
    }

    func testOnlyBoldIsDrawnNeverALink() {
        let s = McFlyAnswer.inline("Your **resting heart rate** fell. See [this](https://example.com) and *that*.")
        XCTAssertEqual(String(s.characters), "Your resting heart rate fell. See [this](https://example.com) and *that*.")
        let bold = s.runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }.map { String(s[$0.range].characters) }
        XCTAssertEqual(bold, ["resting heart rate"])
        XCTAssertTrue(s.runs.allSatisfy { $0.link == nil }, "an answer's text never becomes a link")
    }
}
