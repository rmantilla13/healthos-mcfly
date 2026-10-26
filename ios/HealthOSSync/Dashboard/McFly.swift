import SwiftUI

// Ask McFly: the dashboard's health assistant (server/mcfly.ts). The conversation lives in memory only,
// never on disk, like the web.

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

    /// Streams the answer to the last question (text/event-stream: text, tool, visual, refusal, error, done).
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
                        default: throw APIError.network(message ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
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
    /// What went wrong, shown under whatever of the answer had already arrived.
    var error: String?

    /// A failed answer stays on screen but is left out of the history.
    var failed: Bool { error != nil }
    var hasVisual: Bool { parts.contains { if case .visual = $0 { true } else { false } } }

    /// Folds one streamed event into the answer.
    mutating func apply(_ event: McFlyEvent) {
        switch event {
        case .text(let t):
            content += t
            if case .text(let run)? = parts.last { parts[parts.count - 1] = .text(run + t) } else { parts.append(.text(t)) }
        case .visual(let v):
            parts.append(.visual(v))
        case .refusal(let e):
            // A refusal can arrive after some text: the partial answer and its charts go, like the web.
            content = ""
            parts = []
            error = e
        case .error(let e):
            fail(e)
        case .tool, .done:
            break
        }
    }

    /// Something broke partway (an error event, a dropped connection): the words and charts that already arrived
    /// stay, with the error under them, like the web. The first error is the one kept.
    mutating func fail(_ message: String) {
        if error == nil { error = message }
    }

    /// After the stream ends: an answer with neither words nor charts says so.
    mutating func finishAnswer() {
        if error == nil, content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !hasVisual {
            error = "No answer came back. Try again."
        }
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

@MainActor
@Observable
final class McFlyChat {
    var messages: [McFlyMessage] = []
    var status: McFlyStatus?
    var streaming = false
    var lookingAt: String?
    /// Goes up when the conversation is forgotten, so an answer still streaming stops writing into it.
    private var thread = 0

    func refreshStatus() async {
        let thread = thread
        let status = try? await APIClient.current()?.mcflyStatus()
        if thread == self.thread { self.status = status }
    }

    /// Signed out, someone else signed in, or another server: the conversation and the status go, an answer on its way
    /// included.
    func forget() {
        thread += 1
        messages = []
        status = nil
        streaming = false
        lookingAt = nil
    }

    func newChat() {
        guard !streaming else { return }
        messages = []
        lookingAt = nil
    }

    func ask(_ question: String) async {
        let q = String(question.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4000))
        guard !q.isEmpty, !streaming, let client = APIClient.current() else { return }
        let turns = McFlyMessage.history(messages, question: q)
        messages.append(McFlyMessage(role: .user, content: q))
        messages.append(McFlyMessage(role: .assistant, content: ""))
        let index = messages.count - 1
        let thread = thread
        streaming = true
        defer {
            if thread == self.thread {
                streaming = false
                lookingAt = nil
            }
        }
        do {
            for try await event in client.mcflyChat(turns) {
                // Forgotten while it streamed: leaving the loop ends the request.
                guard thread == self.thread else { return }
                switch event {
                case .tool(let label): lookingAt = label
                case .text, .visual: lookingAt = nil
                case .refusal, .error, .done: break
                }
                messages[index].apply(event)
            }
            guard thread == self.thread else { return }
            messages[index].finishAnswer()
        } catch {
            guard thread == self.thread else { return }
            messages[index].fail(error.localizedDescription)
        }
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

private let threadSpace = "mcfly-thread"

/// The floating pill at the bottom of Today: a glassy indigo capsule with a softly pulsing sparkle and a slow shimmer,
/// a spring and a light tap when pressed. Reduce Motion stills it; Reduce Transparency drops the glass highlight.
/// White text on the gradient stays above 7:1 in light mode and 5:1 in dark.
struct AskMcFlyPill: View {
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var taps = 0

    static let deep = Palette.dynamic(0x1E2552, 0x2E3A8C)
    static let bright = Palette.dynamic(0x3C3FA8, 0x5B4FD0)
    static let glow = Palette.dynamic(0x4B4FD6, 0x7A6CF0)

    var body: some View {
        Button {
            taps += 1
            action()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.subheadline.weight(.bold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.white, Color(UIColor(hex: 0xFFD98A)))
                    .modifier(SparklePulse(active: !reduceMotion))
                    .symbolEffect(.bounce, value: taps)
                Text("Ask McFly")
                    .font(.app(.subheadline, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 20)
            .frame(minHeight: 46)
            .background {
                Capsule()
                    .fill(LinearGradient(colors: [Self.deep, Self.bright], startPoint: .leading, endPoint: .trailing))
                    .overlay {
                        if !reduceTransparency {
                            // Glass: a soft light along the top edge.
                            Capsule().fill(LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0)], startPoint: .top, endPoint: .center))
                        }
                    }
                    .overlay { if !reduceMotion { Shimmer().clipShape(Capsule()) } }
                    .overlay(Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 1))
            }
            .shadow(color: Self.glow.opacity(0.45), radius: 14, y: 6)
            .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
            .contentShape(Capsule())
        }
        .buttonStyle(PillPress(animate: !reduceMotion))
        .sensoryFeedback(.impact(weight: .light), trigger: taps)
        .accessibilityLabel("Ask McFly")
        .accessibilityHint("Opens a chat about your health data")
    }
}

/// A gentle repeating pulse on the sparkle, or none.
private struct SparklePulse: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        if active {
            content.symbolEffect(.pulse.byLayer, options: .repeating.speed(0.5))
        } else {
            content
        }
    }
}

/// A slow band of light across the pill every few seconds.
private struct Shimmer: View {
    @State private var phase: CGFloat = -1
    var body: some View {
        GeometryReader { geo in
            LinearGradient(colors: [.white.opacity(0), .white.opacity(0.22), .white.opacity(0)], startPoint: .leading, endPoint: .trailing)
                .frame(width: geo.size.width * 0.45)
                .offset(x: phase * geo.size.width * 1.5)
                .blendMode(.plusLighter)
        }
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.6).delay(2.4).repeatForever(autoreverses: false)) { phase = 1 }
        }
    }
}

/// Shrinks a touch with a spring while pressed.
private struct PillPress: ButtonStyle {
    let animate: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .brightness(configuration.isPressed ? -0.04 : 0)
            .animation(animate ? .spring(response: 0.28, dampingFraction: 0.6) : nil, value: configuration.isPressed)
    }
}

/// Ask McFly over Home, from the pill: the conversation in a sheet, with Done.
struct McFlySheet: View {
    @Bindable var chat: McFlyChat
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            McFlyThread(chat: chat)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                }
        }
    }
}

/// Ask McFly as a page (More → Ask McFly, the web's #/mcfly): the same conversation as the pill's sheet. Unlike the
/// pill, it's always listed, so on a server with McFly off it says so in the web's words instead of a composer.
/// Signed out it asks for sign-in, never showing a conversation.
struct McFlyPage: View {
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        if dashboard.signInRequired {
            SignInView()
        } else if dashboard.phase == .noServer {
            Unavailable("No server yet", systemImage: "server.rack", description: "Add your healthOS address in Profile.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Palette.page)
        } else if let status = dashboard.mcfly.status, !status.available {
            let admin = dashboard.status?.user?.role == "admin"
            Unavailable(status.configured ? "Ask McFly is turned off" : "Ask McFly isn't set up yet", systemImage: AppPage.mcfly.symbol,
                        description: !admin ? "Ask the admin to turn it on."
                            : status.configured ? "Set a daily question limit above 0 in Admin → Settings."
                            : "Add ANTHROPIC_API_KEY (from the Claude Console) to the Vercel project, then redeploy.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Palette.page)
                .task { await dashboard.mcfly.refreshStatus() }
        } else {
            McFlyThread(chat: dashboard.mcfly)
        }
    }
}

/// The conversation and its composer, for the sheet and the page. Its NavigationStack is theirs.
struct McFlyThread: View {
    @Bindable var chat: McFlyChat
    @State private var draft = ""
    @State private var follow = McFlyFollow()
    @FocusState private var focused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if chat.messages.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Ask about your health data").font(.app(.headline)).foregroundStyle(Palette.ink)
                            Text("For example: How did I sleep this week? Is my resting heart rate trending down?")
                                .font(.app(.subheadline)).foregroundStyle(Palette.ink3)
                        }
                        .padding(.top, 24)
                    }
                    ForEach(chat.messages) { m in
                        Bubble(message: m).id(m.id)
                    }
                    if let label = chat.lookingAt {
                        Label("Looking at \(label)…", systemImage: "magnifyingglass")
                            .font(.app(.caption)).foregroundStyle(Palette.ink3)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(16)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(threadSpace)) } action: { [follow] frame in
                    follow.contentMoved(top: frame.minY, bottom: frame.maxY)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .environment(\.mcflyChartTouched, { [follow] in follow.chartTouched() })
            .onChange(of: followKey) { _, _ in
                // Only while the reader is at the bottom: an earlier paragraph or chart stays put to be read.
                guard follow.following else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
        .background(Palette.page)
        .safeAreaInset(edge: .bottom) {
            composer.onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(threadSpace)).minY } action: { [follow] y in
                follow.viewportBottom = y
            }
        }
        .coordinateSpace(.named(threadSpace))
        .navigationTitle("Ask McFly")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("New chat") { chat.newChat() }.disabled(chat.messages.isEmpty || chat.streaming)
            }
        }
        .task { await chat.refreshStatus() }
    }

    private var composer: some View {
        VStack(spacing: 6) {
            if let s = chat.status {
                Text(s.left == 1 ? "1 question left today" : "\(s.left) questions left today")
                    .font(.app(.caption2)).foregroundStyle(Palette.ink3)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask a question", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($focused)
                    .submitLabel(.send)
                    .onSubmit(send)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Palette.border))
                Button(action: send) {
                    Image(systemName: "arrow.up").font(.body.weight(.bold))
                        .frame(width: 44, height: 44)
                        .foregroundStyle(Palette.page)
                        .background(canSend ? Palette.ink : Palette.ink3, in: Circle())
                }
                .disabled(!canSend)
                .accessibilityLabel("Send")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(.bar)
    }

    /// Changes whenever something new lands at the bottom of the thread.
    private var followKey: [String] {
        guard let m = chat.messages.last else { return [] }
        return [m.id.uuidString, "\(m.content.count)", "\(m.parts.count)", m.error ?? "", chat.lookingAt ?? ""]
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !chat.streaming && (chat.status?.left ?? 1) > 0
    }

    private func send() {
        guard canSend else { return }
        let q = draft
        draft = ""
        focused = false // the keyboard steps aside while the answer streams
        follow.sent()
        Task { await chat.ask(q) }
    }
}

private struct Bubble: View {
    let message: McFlyMessage

    var body: some View {
        if message.role == .assistant, message.hasVisual {
            // Charts sit full width between the answer's paragraphs, in the order they arrived; anything that went
            // wrong afterwards goes under them.
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(message.parts.enumerated()), id: \.offset) { _, part in
                    switch part {
                    case .text(let t):
                        if !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { shell(LightMarkdown(text: t)) }
                    case .visual(let v):
                        McFlyVisualView(visual: v)
                    }
                }
                if let error = message.error { shell(ErrorLine(text: error)) }
            }
        } else {
            shell(content)
        }
    }

    @ViewBuilder
    private var content: some View {
        if message.role == .user {
            Text(message.content)
        } else {
            let words = !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if words { LightMarkdown(text: message.content) }
            if let error = message.error {
                ErrorLine(text: error)
            } else if !words {
                ProgressView().controlSize(.small)
            }
        }
    }

    private func shell(_ inner: some View) -> some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 6) {
                inner
            }
            .font(.app(.callout))
            .foregroundStyle(message.role == .user ? Palette.page : Palette.ink)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(message.role == .user ? Palette.ink : Palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                if message.role == .assistant { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Palette.border) }
            }
            .textSelection(.enabled)
            if message.role == .assistant { Spacer(minLength: 24) }
        }
    }
}

/// What went wrong with an answer, under the part of it that arrived (note-bad on the web).
private struct ErrorLine: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.circle").accessibilityHidden(true)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Palette.critical)
    }
}

/// Paragraphs, "- " and "1. " lists, and **bold**.
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
