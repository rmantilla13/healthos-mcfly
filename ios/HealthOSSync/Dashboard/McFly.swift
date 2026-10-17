import SwiftUI

// Ask McFly: the dashboard's health assistant (server/mcfly.ts). The conversation lives in memory only,
// never on disk, like the web.

struct McFlyStatus: Decodable {
    let configured: Bool
    let limit: Int
    let usedToday: Int

    var available: Bool { configured && limit > 0 }
    var left: Int { max(0, limit - usedToday) }
}

enum McFlyEvent {
    case text(String)
    case tool(String)
    case refusal(String)
    case error(String)
    case done
}

extension APIClient {
    func mcflyStatus() async throws -> McFlyStatus { try await getJSON("/mcfly") }

    /// Streams the answer to the last question (text/event-stream: text, tool, refusal, error, done).
    func mcflyChat(_ messages: [McFlyMessage]) -> AsyncThrowingStream<McFlyEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let body = try JSONEncoder().encode(["messages": messages.suffix(40).map { ["role": $0.role.rawValue, "content": $0.content] }])
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
                    var event = ""
                    for try await line in bytes.lines {
                        if line.hasPrefix("event:") {
                            event = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                        } else if line.hasPrefix("data:") {
                            let json = Data(line.dropFirst(5).trimmingCharacters(in: .whitespaces).utf8)
                            let fields = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] ?? [:]
                            switch event {
                            case "text": continuation.yield(.text(fields["text"] as? String ?? ""))
                            case "tool": continuation.yield(.tool(fields["label"] as? String ?? "your data"))
                            case "refusal": continuation.yield(.refusal(fields["error"] as? String ?? "McFly can't answer that."))
                            case "error": continuation.yield(.error(fields["error"] as? String ?? "Something went wrong."))
                            case "done":
                                continuation.yield(.done)
                                continuation.finish()
                                return
                            default: break
                            }
                        }
                    }
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
    let id = UUID()
    var role: Role
    var content: String
    var failed = false
}

@MainActor
@Observable
final class McFlyChat {
    var messages: [McFlyMessage] = []
    var status: McFlyStatus?
    var streaming = false
    var lookingAt: String?

    func refreshStatus() async {
        status = try? await APIClient.current()?.mcflyStatus()
    }

    func newChat() {
        guard !streaming else { return }
        messages = []
        lookingAt = nil
    }

    func ask(_ question: String) async {
        let q = String(question.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4000))
        guard !q.isEmpty, !streaming, let client = APIClient.current() else { return }
        let history = messages.filter { !$0.failed }
        messages.append(McFlyMessage(role: .user, content: q))
        messages.append(McFlyMessage(role: .assistant, content: ""))
        let index = messages.count - 1
        streaming = true
        defer {
            streaming = false
            lookingAt = nil
        }
        do {
            for try await event in client.mcflyChat(history + [McFlyMessage(role: .user, content: q)]) {
                switch event {
                case .text(let t):
                    lookingAt = nil
                    messages[index].content += t
                case .tool(let label): lookingAt = label
                case .refusal(let e), .error(let e):
                    messages[index].content = e
                    messages[index].failed = true
                case .done: break
                }
            }
            if messages[index].content.isEmpty {
                messages[index].content = "No answer came back. Try again."
                messages[index].failed = true
            }
        } catch {
            messages[index].content = error.localizedDescription
            messages[index].failed = true
        }
        await refreshStatus()
    }
}

/// The floating pill at the bottom of Today.
struct AskMcFlyPill: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label("Ask McFly", systemImage: "sparkles")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 18)
                .frame(minHeight: 44)
                .foregroundStyle(Palette.page)
                .background(Palette.ink, in: Capsule())
                .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens a chat about your health data")
    }
}

struct McFlySheet: View {
    @Bindable var chat: McFlyChat
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if chat.messages.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Ask about your health data").font(.headline).foregroundStyle(Palette.ink)
                                Text("For example: How did I sleep this week? Is my resting heart rate trending down?")
                                    .font(.subheadline).foregroundStyle(Palette.ink3)
                            }
                            .padding(.top, 24)
                        }
                        ForEach(chat.messages) { m in
                            Bubble(message: m).id(m.id)
                        }
                        if let label = chat.lookingAt {
                            Label("Looking at \(label)…", systemImage: "magnifyingglass")
                                .font(.caption).foregroundStyle(Palette.ink3)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(16)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: chat.messages.last?.content) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("end", anchor: .bottom) }
                }
            }
            .background(Palette.page)
            .safeAreaInset(edge: .bottom) { composer }
            .navigationTitle("Ask McFly")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("New chat") { chat.newChat() }.disabled(chat.messages.isEmpty || chat.streaming)
                }
            }
            .task { await chat.refreshStatus() }
        }
    }

    private var composer: some View {
        VStack(spacing: 6) {
            if let s = chat.status {
                Text(s.left == 1 ? "1 question left today" : "\(s.left) questions left today")
                    .font(.caption2).foregroundStyle(Palette.ink3)
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

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !chat.streaming && (chat.status?.left ?? 1) > 0
    }

    private func send() {
        guard canSend else { return }
        let q = draft
        draft = ""
        focused = false // the keyboard steps aside while the answer streams
        Task { await chat.ask(q) }
    }
}

private struct Bubble: View {
    let message: McFlyMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 6) {
                if message.role == .assistant, message.content.isEmpty {
                    ProgressView().controlSize(.small)
                } else if message.role == .assistant {
                    LightMarkdown(text: message.content)
                } else {
                    Text(message.content)
                }
            }
            .font(.callout)
            .foregroundStyle(message.role == .user ? Palette.page : (message.failed ? Palette.critical : Palette.ink))
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
