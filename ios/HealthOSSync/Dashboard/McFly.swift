import SwiftUI

// Ask McFly: the dashboard's health assistant (server/mcfly.ts). The conversation lives in memory only, never on
// disk, and goes with a sign-out, another person's sign-in or another server. Home's pill (AskMcFlyEntry, below) opens
// its page under More (AI/McFlyPage.swift), as the web's AskPill links to #/mcfly.

/// GET /api/mcfly (shared/types.ts McflyStatus). On the shared key, limit and usedToday are the admin's daily limit; on
/// the person's own key they're its anti-abuse cap, and `limited` is false. provider, source and limited are missing
/// from older servers, and while nothing is set up. Read field by field: one the app can't read is the web's default.
struct McFlyStatus: Decodable, Equatable {
    let configured: Bool
    let limit: Int
    let usedToday: Int
    /// "anthropic" | "openai" | "gemini": whose model answers.
    var provider: String?
    /// "own" (the person's own key) | "shared" (the server's).
    var source: String?
    /// The shared daily limit applies ("N questions left today").
    var limited: Bool?

    /// Answers can be asked for: set up, and on the person's own key or under a shared limit above 0 (src/pages/McFly.tsx).
    var available: Bool { configured && (source == "own" || limit > 0) }
    var left: Int { max(0, limit - usedToday) }

    /// On the person's own key.
    var own: Bool { source == "own" }

    /// The web's `left`: the shared key's questions left today; on the person's own key only 0, once its cap is
    /// reached (its 200 isn't a quota to count down); nil when there's no count to show.
    var questionsLeft: Int? {
        if own { return usedToday >= limit ? 0 : nil }
        return limit > 0 ? max(limit - usedToday, 0) : nil
    }

    /// Why nothing can be asked (the web's `unavailable`), or nil.
    var unavailable: McFlyUnavailable? {
        if !configured { return .notSetUp }
        if !own, limit <= 0 { return .off }
        return nil
    }
}

extension McFlyStatus {
    private enum CodingKeys: String, CodingKey { case configured, limit, usedToday, provider, source, limited }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys) -> T? { try? c.decodeIfPresent(T.self, forKey: key) }
        // Counts can come as 3.0 from some servers' JSON.
        func count(_ key: CodingKeys) -> Int { value(key) ?? (value(key) as Double?).map { Int($0) } ?? 0 }
        self.init(configured: value(.configured) ?? false, limit: count(.limit), usedToday: count(.usedToday),
                  provider: value(.provider), source: value(.source), limited: value(.limited))
    }
}

/// Why Ask McFly can't answer (src/pages/McFly.tsx `unavailable`).
enum McFlyUnavailable: Equatable {
    /// No assistant on this server: no shared Claude key, and no key of the person's own chosen.
    case notSetUp
    /// The admin set the shared daily limit to 0.
    case off
}

/// Ask McFly's words, quoted from src/pages/McFly.tsx (a test checks them against it).
enum McFlyWords {
    static let sub = "Questions about your own sleep, recovery, heart and activity. McFly reads your data to answer. It isn't a doctor."
    static let suggestions = [
        "How did I sleep this week compared with last week?",
        "Is my resting heart rate trending up or down?",
        "What does my HRV say about my recovery lately?",
        "How active was I this month?",
        "When do I usually go to bed and wake up?",
    ]
    static let tryThese = "Try one of these, or ask your own."
    static let thinking = "McFly is thinking…"
    static let steps = "What McFly looked at"
    static let stopped = "Stopped."
    static let noAnswer = "McFly had no answer. Try asking another way."
    static let couldNotAnswer = "McFly could not answer right now."
    static let connect = "Connect your own key"

    static func title(_ why: McFlyUnavailable) -> String { why == .off ? ServerWords.mcflyOff : ServerWords.mcflyNotSetUp }

    /// What to do about it: for the admin, how to turn it on; for everyone else, whether a key of their own would do.
    static func text(_ why: McFlyUnavailable, admin: Bool, byok: Bool) -> String {
        let first: String
        if admin {
            first = why == .off ? "Set a daily question limit above 0 in Admin → Settings."
                : "Add ANTHROPIC_API_KEY (from the Claude Console) to the Vercel project, then redeploy."
        } else if byok {
            first = why == .off ? "The shared assistant is off right now." : "There's no shared assistant on this server."
        } else {
            first = "Ask the admin to turn it on."
        }
        return byok ? first + " You can connect your own AI key in Profile → Chatbot: OpenAI, Claude or Gemini." : first
    }

    /// The line beside Ask: whose key answers, or the questions left today. Empty while there's nothing to say.
    static func composerLine(_ s: McFlyStatus?) -> String {
        guard let s else { return "" }
        let left = s.questionsLeft
        if s.own, left != 0 {
            return AIProvider.label(s.provider).map { "On your \($0) key" } ?? "On your key"
        }
        guard let left else { return "" }
        if s.own { return "You've reached today's limit on your own key." }
        return "\(left) question\(left == 1 ? "" : "s") left today"
    }

    static func placeholder(_ s: McFlyStatus?) -> String {
        s?.questionsLeft == 0 ? "You've reached today's question limit." : "Ask about your health data…"
    }
}

enum McFlyEvent: Equatable {
    case text(String)
    case tool(String)
    /// A chart or a few tiles, between the answer's text (McFlyCharts.swift).
    case visual(McFlyVisual)
    case refusal(String)
    case error(String)
    case done
}

/// Reads /api/mcfly/chat's server-sent events a line at a time (the server writes `event: x`, `data: {...}`, then a
/// blank line). Unknown events, and charts of a kind this app doesn't draw, yield nothing: the answer carries on.
struct McFlySSEParser {
    private var event = ""

    private struct VisualEnvelope: Decodable { let visual: McFlyVisual }

    mutating func feed(_ line: String) -> McFlyEvent? {
        if line.isEmpty {
            event = ""
            return nil
        }
        if line.hasPrefix("event:") {
            event = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
            return nil
        }
        guard line.hasPrefix("data:") else { return nil }
        let json = Data(line.dropFirst(5).trimmingCharacters(in: .whitespaces).utf8)
        if event == "visual" {
            return (try? JSONDecoder().decode(VisualEnvelope.self, from: json)).map { .visual($0.visual) }
        }
        let fields = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] ?? [:]
        switch event {
        case "text": return .text(fields["text"] as? String ?? "")
        case "tool": return .tool(fields["label"] as? String ?? "your data")
        case "refusal": return .refusal(fields["error"] as? String ?? "McFly can't answer that.")
        case "error": return .error(fields["error"] as? String ?? "Something went wrong.")
        case "done": return .done
        default: return nil
        }
    }

    /// Reads a whole response body, handing over each event until `done`.
    static func read<Bytes: AsyncSequence>(_ bytes: Bytes, _ handle: (McFlyEvent) -> Void) async throws where Bytes.Element == UInt8 {
        var lines = McFlySSELineSplitter()
        var parser = McFlySSEParser()
        for try await byte in bytes {
            guard let line = lines.push(byte), let event = parser.feed(line) else { continue }
            handle(event)
            if event == .done { return }
        }
        if let line = lines.finish(), let event = parser.feed(line) { handle(event) }
    }
}

/// Cuts a byte stream into lines at "\n" ("\r\n" or a lone "\r" counts as one break), as server-sent events define
/// them. Foundation's `AsyncBytes.lines` also breaks at U+0085, U+2028 and U+2029, which JSON.stringify leaves
/// unescaped inside a data line, so a sentence or chart title holding one was cut in two and lost.
struct McFlySSELineSplitter {
    private var line: [UInt8] = []
    private var afterCR = false

    mutating func push(_ byte: UInt8) -> String? {
        switch byte {
        case 0x0A:
            if afterCR {
                afterCR = false // the "\n" of a "\r\n": that break was already counted
                return nil
            }
            return take()
        case 0x0D:
            afterCR = true
            return take()
        default:
            afterCR = false
            line.append(byte)
            return nil
        }
    }

    /// The last line, when the stream ends without a break after it.
    mutating func finish() -> String? { line.isEmpty ? nil : take() }

    private mutating func take() -> String {
        defer { line.removeAll(keepingCapacity: true) }
        return String(decoding: line, as: UTF8.self)
    }
}

/// One turn of the conversation as the server reads it (McflyTurn in shared/types.ts).
struct McFlyTurn: Encodable, Equatable {
    let role: String
    let content: String
}

extension APIClient {
    func mcflyStatus() async throws -> McFlyStatus { try await getJSON("/mcfly") }

    /// Streams the answer to the last question (text/event-stream: text, tool, visual, refusal, error, done). A
    /// refusal before the stream starts (403 turned off, 429 over the limit, 503 not set up) comes in the server's
    /// own words.
    func mcflyChat(_ turns: [McFlyTurn]) -> AsyncThrowingStream<McFlyEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let body = try JSONEncoder().encode(["messages": Array(turns.suffix(40))])
                    let (bytes, http) = try await stream("/mcfly/chat", body: body)
                    guard (200..<300).contains(http.statusCode) else {
                        var data = Data()
                        for try await b in bytes { data.append(b) }
                        let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
                        switch http.statusCode {
                        case 401: throw APIError.signInRequired
                        default: throw APIError.network(message ?? McFlyWords.couldNotAnswer)
                        }
                    }
                    try await McFlySSEParser.read(bytes) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

struct McFlyMessage: Identifiable, Equatable {
    enum Role: String { case user, assistant }
    /// An answer in the order it arrived: runs of text, and the charts McFly drew between them.
    enum Part: Equatable {
        case text(String)
        case visual(McFlyVisual)
    }
    let id = UUID()
    var role: Role
    /// All of the answer's text.
    var content: String
    var parts: [Part] = []
    /// Each piece of data McFly read for this answer, in order ("Looking at your sleep").
    var steps: [String] = []
    /// The answer is still coming in.
    var pending = false
    /// What went wrong, shown under whatever of the answer had already arrived.
    var error: String?

    /// A failed answer stays on screen but is left out of the history.
    var failed: Bool { error != nil }
    var hasVisual: Bool { parts.contains { if case .visual = $0 { true } else { false } } }
    private var hasWords: Bool { !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// The step McFly is on: the last one, until its answer starts (the web's shimmering step). nil once it's working
    /// on words or a chart, or done.
    var workingStep: Int? {
        pending && content.isEmpty && !hasVisual && !steps.isEmpty ? steps.count - 1 : nil
    }

    /// "McFly is thinking…": waiting, with nothing read or said yet.
    var thinking: Bool { pending && content.isEmpty && steps.isEmpty }

    /// Folds one streamed event into the answer.
    mutating func apply(_ event: McFlyEvent) {
        switch event {
        case .text(let t):
            content += t
            if case .text(let run)? = parts.last { parts[parts.count - 1] = .text(run + t) } else { parts.append(.text(t)) }
        case .visual(let v):
            parts.append(.visual(v))
        case .tool(let label):
            steps.append(label)
        case .refusal(let e):
            // A refusal can arrive after some text: the partial answer and its charts go, like the web.
            content = ""
            parts = []
            error = e
        case .error(let e):
            fail(e)
        case .done:
            break
        }
    }

    /// Something broke partway (an error event, a dropped connection): the words and charts that already arrived
    /// stay, with the error under them, like the web. The first error is the one kept.
    mutating func fail(_ message: String) {
        if error == nil { error = message }
    }

    /// Stop was pressed: what arrived stays as the answer; with nothing yet, it says so.
    mutating func stop() {
        if content.isEmpty, !hasVisual { fail(McFlyWords.stopped) }
    }

    /// After the stream ends: an answer with neither words nor charts says so.
    mutating func finishAnswer() {
        pending = false
        if error == nil, !hasWords, !hasVisual { error = McFlyWords.noAnswer }
    }

    /// What McFly reads back next time: its words, with a one-line note where each chart was (spoken() on the web).
    var spoken: String {
        guard !parts.isEmpty else { return content }
        let joined = parts.map { part -> String in
            switch part {
            case .text(let t): t
            case .visual(let v): "\n\n\(v.note)\n\n"
            }
        }.joined()
        return joined.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The history the server needs: question and answer pairs that completed, then the new question. A failed
    /// answer's question is left out with it, since the server wants turns that alternate.
    static func history(_ messages: [McFlyMessage], question: String) -> [McFlyTurn] {
        var out: [McFlyTurn] = []
        var i = 0
        while i < messages.count {
            let m = messages[i]
            if m.role == .user, i + 1 < messages.count, messages[i + 1].role == .assistant, !messages[i + 1].failed {
                let answer = messages[i + 1].spoken
                if !answer.isEmpty, !m.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    out += [McFlyTurn(role: Role.user.rawValue, content: m.content), McFlyTurn(role: Role.assistant.rawValue, content: answer)]
                }
                i += 2
            } else {
                i += 1
            }
        }
        return out + [McFlyTurn(role: Role.user.rawValue, content: question)]
    }
}

/// The conversation, for the page under More (and the app's one holder of it, on Dashboard). In memory only.
@MainActor
@Observable
final class McFlyChat {
    var messages: [McFlyMessage] = []
    /// GET /api/mcfly, read after every load and every answer. Availability sees it (`mcflyState`).
    var status: McFlyStatus?
    var streaming = false
    /// Goes up when the conversation is forgotten, so an answer still streaming stops writing into it.
    private var thread = 0
    /// The answer streaming now, for Stop.
    private var task: Task<Void, Never>?
    private var stopping = false
    #if targetEnvironment(simulator)
    /// A made-up status for scripted runs in the Simulator (McFlyLaunchHook), which the server's doesn't replace.
    var preview: McFlyStatus?
    #endif

    /// Reads McFly's status. A read that fails (offline) keeps what was known.
    func refreshStatus() async {
        #if targetEnvironment(simulator)
        if let preview {
            status = preview
            return
        }
        #endif
        let thread = thread
        guard let client = APIClient.current(), let status = try? await client.mcflyStatus() else { return }
        #if targetEnvironment(simulator)
        if let preview { return self.status = preview }
        #endif
        if thread == self.thread { self.status = status }
    }

    /// Signed out, someone else signed in, or another server: the conversation and the status go, an answer on its way
    /// included (its request is cancelled).
    func forget() {
        thread += 1
        task?.cancel()
        task = nil
        messages = []
        status = nil
        streaming = false
        stopping = false
        #if targetEnvironment(simulator)
        preview = nil
        #endif
    }

    func newChat() {
        guard !streaming else { return }
        messages = []
    }

    /// Asks, in a task Stop can end. It's streaming from this moment, so a second tap can't send twice and Stop
    /// shows at once.
    func send(_ question: String) {
        guard !streaming, let q = Self.question(question) else { return }
        streaming = true
        stopping = false
        let thread = thread
        task = Task { await answer(q, thread: thread) }
    }

    /// Ends the answer coming in: what arrived stays, and with nothing yet it says "Stopped." (the web's abort).
    func stop() {
        guard streaming, let task else { return }
        stopping = true
        task.cancel()
    }

    /// Asks and waits for the whole answer.
    func ask(_ question: String) async {
        guard !streaming, let q = Self.question(question) else { return }
        streaming = true
        stopping = false
        await answer(q, thread: thread)
    }

    /// What's sent of a question: trimmed, at most the web's 4,000 characters; nil when there's nothing.
    private static func question(_ text: String) -> String? {
        let q = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4000))
        return q.isEmpty ? nil : q
    }

    /// `thread` is the conversation it was asked in: forgotten before it starts, it never lands in the next one.
    private func answer(_ q: String, thread: Int) async {
        defer {
            if thread == self.thread {
                streaming = false
                stopping = false
                task = nil
            }
        }
        guard thread == self.thread, let client = APIClient.current() else { return }
        let turns = McFlyMessage.history(messages, question: q)
        messages.append(McFlyMessage(role: .user, content: q))
        messages.append(McFlyMessage(role: .assistant, content: "", pending: true))
        let index = messages.count - 1
        do {
            for try await event in client.mcflyChat(turns) {
                // Forgotten while it streamed: leaving the loop ends the request.
                guard thread == self.thread else { return }
                messages[index].apply(event)
            }
            guard thread == self.thread else { return }
            if stopping || Task.isCancelled { messages[index].stop() }
        } catch {
            guard thread == self.thread else { return }
            if stopping || Task.isCancelled || APIClient.isCancellation(error) { messages[index].stop() }
            else { messages[index].fail(error.localizedDescription) }
        }
        messages[index].finishAnswer()
        await refreshStatus()
    }
}

/// Whether the thread keeps the newest words in view while an answer streams (the `following` ref in
/// src/pages/McFly.tsx). Scrolling up to reread, or touching a chart, lets go; scrolling back to within 80pt of
/// the bottom, or sending a question, takes hold again. The answer growing on its own never changes it, and neither
/// does the thread's own scroll down to the newest words.
///
/// A plain class on purpose: it hears about every frame of scrolling, and nothing on screen depends on it, so
/// changing it mustn't redraw the thread.
final class McFlyFollow {
    static let nearBottom: CGFloat = 80

    private(set) var following = true
    /// Where the visible thread ends (the top of the composer), in the same space as the content's edges.
    var viewportBottom: CGFloat = .infinity
    private var top: CGFloat?

    /// The thread's content moved or changed size; `top` and `bottom` are its edges.
    func contentMoved(top newTop: CGFloat, bottom: CGFloat) {
        defer { top = newTop }
        // Only the top edge moving means someone scrolled; words arriving at the bottom leave it where it is.
        guard let old = top, abs(newTop - old) > 0.5 else { return }
        if bottom - viewportBottom < Self.nearBottom {
            following = true
        } else if newTop > old {
            following = false // toward earlier messages
        }
    }

    /// A finger is on a chart: it stays put under the finger until the reader scrolls back down or asks again.
    func chartTouched() { following = false }

    func sent() { following = true }
}

/// Ask McFly over Home (the web's AskPill, src/components/shell/AskPill.tsx). The shell mounts it at the bottom of Home
/// in every phase. Like the web's, it shows on Home whenever someone is signed in, whether or not McFly can answer
/// here: the page it opens (More → Ask McFly) says why not, and how to connect a key of your own.
struct AskMcFlyEntry: View {
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        Group {
            if dashboard.phase == .ready {
                HStack {
                    Spacer(minLength: 0)
                    AskMcFlyPill { dashboard.open(.mcfly) }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 10)
            }
        }
        #if targetEnvironment(simulator)
        .modifier(AISheetLaunchHook())
        .modifier(McFlyLaunchHook())
        #endif
    }
}

/// The pill at the bottom right of Home (.ask-pill at phone width): McFly's orb, "Ask McFly" over "A little more
/// clarity", on a white pill with the pop shadow, a light tap when pressed. Its message icon hides on a phone, as the
/// web's does.
struct AskMcFlyPill: View {
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var taps = 0

    var body: some View {
        Button {
            taps += 1
            action()
        } label: {
            HStack(spacing: 10) {
                Orb(size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Ask McFly")
                        .font(.app(size: 13, weight: .medium, relativeTo: .subheadline))
                        .foregroundStyle(Palette.ink)
                    Text("A little more clarity")
                        .font(.app(size: 11, relativeTo: .caption2))
                        .foregroundStyle(Palette.ink3)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 10)
            .padding(.trailing, 16)
            .padding(.vertical, 7)
            .frame(minHeight: 44)
            .background(Palette.surface, in: Capsule())
            .tokenShadow(.pop, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(PillPress(animate: !reduceMotion))
        // It floats over Home: past the largest standard size it stops growing, and a long press shows it large, as
        // the tab bar does.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityShowsLargeContentViewer {
            Label("Ask McFly", systemImage: "text.bubble")
        }
        .sensoryFeedback(.impact(weight: .light), trigger: taps)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Ask McFly")
        .accessibilityValue("A little more clarity")
        .accessibilityHint("Opens a chat about your health data")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("askMcFly")
    }
}

/// Shrinks a touch while pressed (none with Reduce Motion).
private struct PillPress: ButtonStyle {
    let animate: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && animate ? 0.97 : 1)
            .brightness(configuration.isPressed ? -0.03 : 0)
            .animation(animate ? .easeOut(duration: 0.15) : nil, value: configuration.isPressed)
    }
}

/// Paragraphs, "- " and "1. " lists, and **bold**. Insights' digest uses it; McFly's answers use McFlyAnswer, the web's
/// own rules.
struct LightMarkdown: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                if let marker = block.marker {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(marker).monospacedDigit()
                        Text(Self.inline(block.text))
                    }
                } else {
                    Text(Self.inline(block.text))
                }
            }
        }
    }

    private var blocks: [(marker: String?, text: String)] {
        text.components(separatedBy: "\n").compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { return nil }
            if line.hasPrefix("- ") || line.hasPrefix("* ") { return ("•", String(line.dropFirst(2))) }
            if let r = line.range(of: #"^\d+\.\s"#, options: .regularExpression) { return (String(line[r]).trimmingCharacters(in: .whitespaces), String(line[r.upperBound...])) }
            return (nil, line)
        }
    }

    static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}
