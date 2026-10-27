import SwiftUI

// Ask McFly as a page (src/pages/McFly.tsx), under More and from Home's pill: the page's line and New chat, then the
// conversation, which scrolls inside the page with few messages sitting just above the composer, like a chat, and the
// composer at the bottom with whose key answers or the questions left today, and Ask or Stop. Where McFly can't
// answer here, a card says why in the web's words, with "Connect your own key" where keys can be stored. The
// conversation is McFlyChat's (Dashboard.mcfly), in memory only.
//
// On the open iPhone Duo in landscape (duo/decisions.md Q5) the page is two screens, one each side of the fold: the
// conversation on the leading side with its composer pinned under it, and what the conversation showed (McFly's charts,
// or the questions to start with) on the trailing side, in two columns that scroll on their own. Everywhere else, every
// iPhone included, it's the one column it always was.

/// More → Ask McFly. Signed out it asks for sign-in (PhaseGate), never showing a conversation.
struct McFlyPage: View {
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        PhaseGate {
            switch dashboard.phase {
            case .ready: McFlyScreen(chat: dashboard.mcfly)
            case .unavailable(let message):
                Unavailable("Can't load Ask McFly", systemImage: "wifi.exclamationmark", description: message)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Palette.page)
            default: ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.page)
            }
        }
    }
}

private let threadSpace = "mcfly-thread"

/// The page while signed in. Its loaders, its sheet and the announcement of each answer sit here, above the Duo's page
/// block, so a fold or a turn, which lays the page out again, never reads anything again or closes the sheet (P4, P14).
struct McFlyScreen: View {
    @Bindable var chat: McFlyChat
    @Environment(Dashboard.self) private var dashboard
    /// What's typed and not sent yet. Here, above the Duo's page block, so a fold or a turn keeps it; leaving the page
    /// empties it, as on the web.
    @State private var draft = ""
    @State private var chatbot = false

    var body: some View {
        DuoPage { _ in
            McFlyLayout(chat: chat, draft: $draft) { chatbot = true }
        }
        .background(Palette.page)
        .sheet(isPresented: $chatbot, onDismiss: {
            Task {
                await chat.refreshStatus()
                await dashboard.loadAI(force: true)
            }
        }) {
            ChatbotSheet { chatbot = false }
        }
        .task {
            chat.attach(to: dashboard)
            await chat.refreshStatus()
            await dashboard.loadAI()
        }
        .onChange(of: chat.streaming) { was, now in
            // The answer is in: VoiceOver reads it, as the web's live thread does.
            guard was, !now, let last = chat.messages.last, last.role == .assistant else { return }
            let words = last.error ?? last.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !words.isEmpty { AccessibilityNotification.Announcement(words).post() }
        }
    }

    /// One character was typed and it was a line break: Return. (A vertical text field takes Return as a new line.)
    static func returnPressed(old: String, new: String) -> Bool {
        guard new.count == old.count + 1 else { return false }
        let at = zip(old, new).prefix { $0 == $1 }.count
        let i = new.index(new.startIndex, offsetBy: at)
        return new[i] == "\n" && new[new.index(after: i)...] == old[old.index(old.startIndex, offsetBy: at)...]
    }
}

/// The page inside the Duo's page block, where the fold and the margins are known (blocks.md: read them inside the
/// block). The conversation is always its first view, with the same modifiers, so a fold or a turn only changes its
/// width and margins and never makes it again: what's typed, the focus and the keyboard, the follow and the scroll all
/// stay. When the page splits on a vertical fold, the conversation keeps to the leading side, and what it showed
/// scrolls on the trailing side. The two sides are DuoPanes' own (`DuoPanes.paneSpans`: 20–463 | 488–867 at 847 pt with
/// the bar trailing), drawn here because DuoPanes scrolls each pane itself and has no place for a composer pinned under
/// a pane that scrolls on its own. Nothing shows beside a conversation McFly can't have here.
private struct McFlyLayout: View {
    @Bindable var chat: McFlyChat
    @Binding var draft: String
    let connect: () -> Void
    @Environment(Dashboard.self) private var dashboard
    @Environment(\.duoFold) private var fold
    @Environment(\.duoMargins) private var margins
    @Environment(\.duoBand) private var band
    @Environment(\.duoContentWidth) private var contentWidth
    @State private var follow = McFlyFollow()
    @FocusState private var focused: Bool

    var body: some View {
        let spans = fold.span.map { DuoPanes<EmptyView, EmptyView, EmptyView>.paneSpans(margins: margins, fold: $0) }
        let beside = spans != nil && chat.status?.unavailable == nil
        HStack(alignment: .top, spacing: 0) {
            McFlyConversation(chat: chat, draft: $draft, follow: follow, focused: $focused, beside: beside, ask: ask, connect: connect)
                // The leading side keeps the fold's clearance on its trailing edge, as a pane does.
                .environment(\.duoMargins, spans == nil ? margins : DuoMargins(leading: margins.leading, trailing: DuoFold.clearance))
                .environment(\.duoBand, spans == nil ? band : .compact)
                .environment(\.duoFold, .none)
                .frame(width: spans?.primaryWidth)
            if let spans, beside {
                Color.clear
                    .frame(width: spans.gap)
                    .accessibilityHidden(true)
                McFlyShown(chat: chat, ask: ask)
                    .environment(\.duoMargins, DuoMargins(leading: DuoFold.clearance, trailing: margins.trailing))
                    .environment(\.duoBand, .compact)
                    .environment(\.duoFold, .none)
                    // Two columns as in one of DuoPanes' panes: DuoGrid(paneColumns:) reads these.
                    .environment(\.duoInPane, true)
                    .environment(\.duoContentWidth, trailingWidth)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // On its own (nothing beside it), the leading side stays at the leading edge rather than centred on the fold.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The trailing side's content: from half the gap after the fold to the page's trailing margin.
    private var trailingWidth: CGFloat? {
        guard let width = contentWidth, let sides = fold.sides(width: width, spacing: 0) else { return nil }
        return sides.trailing.upperBound - sides.trailing.lowerBound
    }

    /// A typed question or a suggestion: the box empties either way, as the web's ask() does.
    private func ask(_ q: String) {
        guard !chat.streaming, chat.status?.questionsLeft != 0 else { return }
        draft = ""
        // On a phone, the keyboard steps aside while the answer comes in.
        focused = false
        follow.sent()
        chat.attach(to: dashboard)
        chat.send(q)
    }
}

/// The conversation: the page's line and New chat, the thread, and the composer pinned under it; or, where McFly can't
/// answer here, why not. On every iPhone it's the whole page. Beside what it showed (`beside`, the open Duo in
/// landscape), its answers' charts are on the other side, so the thread names each one where it was.
private struct McFlyConversation: View {
    @Bindable var chat: McFlyChat
    @Binding var draft: String
    let follow: McFlyFollow
    let focused: FocusState<Bool>.Binding
    let beside: Bool
    let ask: (String) -> Void
    let connect: () -> Void
    @Environment(Dashboard.self) private var dashboard
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The thread is scrolled away from its top: its first lines fade under the page's line.
    @State private var scrolled = false
    @State private var viewport = CGSize.zero

    /// At the accessibility text sizes the page's line scrolls with the conversation, so the thread keeps its room.
    private var bigText: Bool { typeSize.isAccessibilitySize }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let why = chat.status?.unavailable {
                DuoScroll {
                    VStack(alignment: .leading, spacing: 12) {
                        intro
                        unavailable(why)
                    }
                    .padding(.vertical, 8)
                }
            } else {
                if !bigText { intro.duoPagePadding().padding(.top, 8) }
                thread
                composer.duoPagePadding().padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .coordinateSpace(.named(threadSpace))
    }

    // MARK: Intro

    private var intro: some View {
        PageIntro(sub: McFlyWords.sub) {
            if !chat.messages.isEmpty {
                Button {
                    chat.newChat()
                    focused.wrappedValue = true
                } label: {
                    Label("New chat", systemImage: "plus")
                }
                .buttonStyle(.quietPill)
                .disabled(chat.streaming)
                .accessibilityIdentifier("mcflyNewChat")
            }
        }
    }

    // MARK: Unavailable

    private func unavailable(_ why: McFlyUnavailable) -> some View {
        let byok = dashboard.availability.byok == true
        let admin = dashboard.status?.user?.role == "admin"
        return VStack(alignment: .leading, spacing: 10) {
            Text(McFlyWords.title(why))
                .font(.app(size: 15, weight: .medium, relativeTo: .headline))
                .foregroundStyle(Palette.ink)
                .accessibilityAddTraits(.isHeader)
            Text(McFlyWords.text(why, admin: admin, byok: byok))
                .font(.app(size: 14, relativeTo: .subheadline))
                .foregroundStyle(Palette.ink3)
                .fixedSize(horizontal: false, vertical: true)
            if byok {
                Button(action: connect) { AIButtonLabel(McFlyWords.connect) }
                    .buttonStyle(.accentPill)
                    .accessibilityIdentifier("mcflyConnectKey")
            }
        }
        .card()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mcflyUnavailable")
    }

    // MARK: Thread

    private var thread: some View {
        ScrollViewReader { proxy in
            DuoScroll {
                VStack(alignment: .leading, spacing: 0) {
                    if bigText { intro.padding(.bottom, 16) }
                    Spacer(minLength: 0)
                    LazyVStack(alignment: .leading, spacing: 18) {
                        // Beside the conversation, the questions to start with are on the other side.
                        if chat.messages.isEmpty, !beside { empty }
                        ForEach(chat.messages) { m in
                            Group {
                                if m.role == .user { McFlyQuestion(text: m.content) } else { McFlyAnswerRow(message: m, beside: beside) }
                            }
                            .id(m.id)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(threadSpace)) } action: { [follow] frame in
                        follow.contentMoved(top: frame.minY, bottom: frame.maxY)
                    }
                }
                .frame(minHeight: max(viewport.height - 16, 0), alignment: .bottom)
                .padding(.vertical, 8)
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named("mcfly-scroll")).minY } action: { top in
                    let now = top < -4
                    if now != scrolled { scrolled = now }
                }
            }
            .coordinateSpace(.named("mcfly-scroll"))
            .scrollDismissesKeyboard(.interactively)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(threadSpace)) } action: { [follow] frame in
                // A new width (a fold, a turn) flows the words again: that's not the reader scrolling.
                if McFlyFollow.reflows(from: viewport, to: frame.size) { follow.resized() }
                viewport = frame.size
                follow.viewportBottom = frame.maxY
            }
            // Where text scrolls out at the top it fades under the page's line (.mcfly-fade).
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.black.opacity(0), .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: scrolled ? 56 : 0)
                    Color.black
                }
            }
            .environment(\.mcflyChartTouched, { [follow] in follow.chartTouched() })
            // Opening on a conversation: its newest words, as the web's thread opens at its bottom.
            .onAppear {
                guard !chat.messages.isEmpty else { return }
                Task { @MainActor in proxy.scrollTo("end", anchor: .bottom) }
            }
            .onChange(of: followKey) { _, _ in
                // Only while the reader is at the bottom: an earlier paragraph or chart stays put to be read.
                guard follow.following else { return }
                // A short glide down to the new words; with Reduce Motion it jumps there, as the web's thread does.
                if reduceMotion {
                    proxy.scrollTo("end", anchor: .bottom)
                } else {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("end", anchor: .bottom) }
                }
            }
            // Wider or narrower (the open Duo, a fold), the words flow again: a reader at the newest words stays there.
            .onChange(of: viewport.width) { old, _ in
                guard old > 0, follow.following, !chat.messages.isEmpty else { return }
                Task { @MainActor in proxy.scrollTo("end", anchor: .bottom) }
            }
        }
    }

    /// No messages yet: McFly's mark, and questions to start with.
    private var empty: some View {
        VStack(alignment: .leading, spacing: 12) {
            McFlyMark(size: 30, icon: 18)
            Text(McFlyWords.tryThese).font(.app(size: 14, relativeTo: .subheadline)).foregroundStyle(Palette.ink3)
            McFlyFlow(spacing: 8) {
                ForEach(McFlyWords.suggestions, id: \.self) { s in
                    Button(s) { ask(s) }
                        .buttonStyle(McFlyChipStyle())
                        .disabled(chat.streaming || chat.status?.questionsLeft == 0)
                }
            }
        }
        .padding(.vertical, 8)
    }

    /// Changes whenever something new lands at the bottom of the thread.
    private var followKey: [String] {
        guard let m = chat.messages.last else { return [] }
        return [m.id.uuidString, "\(m.content.count)", "\(m.parts.count)", "\(m.steps.count)", m.error ?? "", m.pending ? "1" : "0"]
    }

    // MARK: Composer

    private var left: Int? { chat.status?.questionsLeft }
    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !chat.streaming && left != 0 }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("", text: $draft, prompt: Text(McFlyWords.placeholder(chat.status)).foregroundStyle(Palette.ink3), axis: .vertical)
                .font(.app(size: 14, relativeTo: .body))
                .foregroundStyle(Palette.ink)
                .lineLimit(2...8)
                .focused(focused)
                .submitLabel(.send)
                .onSubmit(send)
                .disabled(left == 0)
                .onChange(of: draft) { old, value in
                    // Return sends, as the web's Enter does; the field keeps lines pasted into it.
                    if McFlyScreen.returnPressed(old: old, new: value) {
                        draft = old
                        send()
                    } else if value.count > 4000 {
                        draft = String(value.prefix(4000))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(minHeight: 48, alignment: .topLeading)
                .background(Palette.surface2, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous).strokeBorder(Palette.border))
                .accessibilityLabel("Your question")
                .accessibilityIdentifier("mcflyQuestion")
            // At the accessibility text sizes the line goes above the button, so neither is squeezed.
            let row = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .trailing, spacing: 8)) : AnyLayout(HStackLayout(spacing: 12))
            row {
                Text(McFlyWords.composerLine(chat.status))
                    .font(.app(size: 12, relativeTo: .caption))
                    .foregroundStyle(Palette.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: typeSize.isAccessibilitySize ? .infinity : nil, alignment: .leading)
                    .accessibilityIdentifier("mcflyComposerLine")
                if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
                if chat.streaming {
                    Button("Stop") { chat.stop() }
                        .buttonStyle(.quietPill)
                        .accessibilityHint("Stops McFly's answer")
                        .accessibilityIdentifier("mcflyStop")
                } else {
                    Button("Ask", action: send)
                        .buttonStyle(.accentPill)
                        .disabled(!canSend)
                        .accessibilityIdentifier("mcflyAsk")
                }
            }
        }
        .padding(12)
        .background { CardSurface(shape: RoundedRectangle(cornerRadius: Radius.card, style: .continuous)) }
    }

    private func send() {
        guard canSend else { return }
        let q = draft
        draft = ""
        ask(q)
    }
}

// MARK: - Beside the conversation

/// What the conversation showed, on the trailing side of the open iPhone Duo (decisions.md Q5): McFly's charts, the
/// newest answer's first, each answer's under the question it answered, two to a row where they're small and across
/// both columns where they need the width (`McFlyVisual.wide`). Before there's any chart, the questions to start with,
/// two to a row. It scrolls on its own, and only when it's taller than the screen. A finger on a chart here never stops
/// the conversation following new words.
private struct McFlyShown: View {
    let chat: McFlyChat
    let ask: (String) -> Void

    var body: some View {
        DuoScroll {
            VStack(alignment: .leading, spacing: 24) {
                let answers = McFlyShownAnswer.all(chat.messages)
                if answers.isEmpty {
                    suggestions
                } else {
                    ForEach(answers) { answer in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(answer.question)
                                .font(.app(size: 12, weight: .medium, relativeTo: .caption))
                                .foregroundStyle(Palette.ink3)
                                .lineLimit(2)
                                .accessibilityAddTraits(.isHeader)
                            DuoGrid(Array(answer.visuals.enumerated()), id: \.offset, paneColumns: 2) { item in
                                // Each card at its own height for its column's width: a row offers its cells the row's
                                // height, and a comparison's rows (label, value and bar) laid out to that came out taller
                                // than measured, over the row below.
                                if item.element.wide {
                                    McFlyVisualView(visual: item.element).fixedSize(horizontal: false, vertical: true).duoSpans()
                                } else {
                                    McFlyVisualView(visual: item.element).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .vertical)
        .accessibilityIdentifier("mcflyShown")
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 12) {
            McFlyMark(size: 30, icon: 18)
            Text(McFlyWords.tryThese).font(.app(size: 14, relativeTo: .subheadline)).foregroundStyle(Palette.ink3)
            DuoGrid(McFlyWords.suggestions, id: \.self, paneColumns: 2, spacing: 8) { s in
                Button(s) { ask(s) }
                    .buttonStyle(McFlyChipStyle(fills: true))
                    .disabled(chat.streaming || chat.status?.questionsLeft == 0)
            }
        }
        .padding(.vertical, 8)
    }
}

/// One answer's charts, for the trailing side: the question it answered, and its charts in the order they came.
struct McFlyShownAnswer: Identifiable, Equatable {
    let id: UUID
    let question: String
    let visuals: [McFlyVisual]

    /// Every answer with a chart, the newest first, so what McFly just drew is at the top.
    static func all(_ messages: [McFlyMessage]) -> [McFlyShownAnswer] {
        let found = messages.indices.compactMap { i -> McFlyShownAnswer? in
            let m = messages[i]
            guard m.role == .assistant else { return nil }
            let visuals = m.parts.compactMap { part -> McFlyVisual? in
                if case .visual(let v) = part { v } else { nil }
            }
            guard !visuals.isEmpty else { return nil }
            let question = i > 0 && messages[i - 1].role == .user ? messages[i - 1].content : ""
            return McFlyShownAnswer(id: m.id, question: question, visuals: visuals)
        }
        return Array(found.reversed())
    }
}

/// In the conversation beside what it showed: where a chart was, its title, and that it's on the other side.
private struct McFlyShownBeside: View {
    let title: String

    var body: some View {
        // The symbols take the words' font, so they grow with the text size.
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "chart.bar.xaxis").imageScale(.small).accessibilityHidden(true)
            Text(title).fixedSize(horizontal: false, vertical: true)
            Image(systemName: "arrow.right").imageScale(.small).accessibilityHidden(true)
        }
        .font(.app(size: 13, weight: .medium, relativeTo: .footnote))
        .foregroundStyle(Palette.ink2)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Palette.surface2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.border))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Chart: \(title), beside the conversation")
    }
}

// MARK: - Messages

/// McFly's mark beside its answers (.mcfly-mark): the spark in a small dark tile.
struct McFlyMark: View {
    var size: CGFloat = 30
    var icon: CGFloat = 16

    var body: some View {
        Image(systemName: "sparkles")
            .font(.system(size: icon * 0.82, weight: .medium))
            .foregroundStyle(Palette.surface)
            .frame(width: size, height: size)
            .background(Palette.ink, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Your question, on the right (.mcfly-q).
private struct McFlyQuestion: View {
    let text: String

    var body: some View {
        HStack {
            Spacer(minLength: 48)
            Text(text)
                .font(.app(size: 14, relativeTo: .body))
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Palette.surface2, in: shape)
                .overlay(shape.strokeBorder(Palette.border))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("You asked: \(text)")
    }

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 16, bottomTrailingRadius: 4, topTrailingRadius: 16, style: .continuous)
    }
}

/// McFly's answer (.mcfly-a): its mark, then each piece of data it read, the answer's words and charts in the order
/// they came, "McFly is thinking…" while nothing has, and what went wrong under it.
private struct McFlyAnswerRow: View {
    let message: McFlyMessage
    /// Its charts are beside the conversation (the open Duo in landscape): each is named where it was.
    var beside = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            McFlyMark()
            VStack(alignment: .leading, spacing: 8) {
                if !message.steps.isEmpty { steps }
                if message.parts.isEmpty {
                    if !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { McFlyAnswer(text: message.content) }
                } else {
                    ForEach(Array(message.parts.enumerated()), id: \.offset) { _, part in
                        switch part {
                        case .text(let t):
                            if !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { McFlyAnswer(text: t) }
                        case .visual(let v):
                            if beside { McFlyShownBeside(title: v.title) } else { McFlyVisualView(visual: v) }
                        }
                    }
                }
                if message.thinking {
                    ShinyText(McFlyWords.thinking).font(.app(size: 14, weight: .medium, relativeTo: .subheadline))
                }
                if let error = message.error {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle").accessibilityHidden(true)
                        Text(error).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.app(size: 13, relativeTo: .footnote))
                    .foregroundStyle(Palette.critical)
                }
            }
            .padding(.top, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// What McFly looked at: a check by each finished step, a turning ring by the one it's on.
    private var steps: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(message.steps.enumerated()), id: \.offset) { j, step in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if message.workingStep == j {
                        StepRing()
                        ShinyText(step)
                    } else {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .semibold)).frame(width: 12).accessibilityHidden(true)
                        Text(step)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.app(size: 12, relativeTo: .caption))
        .foregroundStyle(Palette.ink3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(McFlyWords.steps)
        .accessibilityValue(message.steps.joined(separator: ", "))
    }
}

/// McFly's answers use a little Markdown, as the web reads it (Answer in McFly.tsx): paragraphs, "- " and "1. " lists,
/// and **bold**. Drawn as text only: no links, no other formatting.
struct McFlyAnswer: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let lines):
                    Text(lines.map(Self.inline).reduce(AttributedString()) { $0.characters.isEmpty ? $1 : $0 + AttributedString("\n") + $1 })
                case .bullets(let items):
                    list(items.enumerated().map { ("•", $0.element) })
                case .numbered(let items):
                    list(items.enumerated().map { ("\($0.offset + 1).", $0.element) })
                }
            }
        }
        .font(.app(size: 14, relativeTo: .body))
        .lineSpacing(4)
        .foregroundStyle(Palette.ink)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
    }

    private func list(_ items: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(item.0).monospacedDigit().frame(minWidth: 14, alignment: .trailing).accessibilityHidden(item.0 == "•")
                    Text(Self.inline(item.1))
                }
            }
        }
    }

    enum Block: Equatable {
        case paragraph([String])
        case bullets([String])
        case numbered([String])
    }

    /// The answer's blocks: split at blank lines; a block whose every line starts "- ", "* " or "• " is a list, one
    /// whose every line starts "1. " or "1) " a numbered list, and any other a paragraph, its lines kept, a heading's
    /// "#"s dropped.
    static func blocks(_ text: String) -> [Block] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return trimmed.split(separator: #/\n{2,}/#).map(String.init).map { block in
            let lines = block.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            if !lines.isEmpty, lines.allSatisfy({ $0.contains(#/^\s*[-*•]\s+/#) }) {
                return .bullets(lines.map { $0.replacing(#/^\s*[-*•]\s+/#, with: "") })
            }
            if !lines.isEmpty, lines.allSatisfy({ $0.contains(#/^\s*\d+[.)]\s+/#) }) {
                return .numbered(lines.map { $0.replacing(#/^\s*\d+[.)]\s+/#, with: "") })
            }
            return .paragraph(lines.map { $0.replacing(#/^#+\s+/#, with: "") })
        }
    }

    /// "**bold**" is bold; everything else is plain text, asterisks and all.
    static func inline(_ s: String) -> AttributedString {
        var out = AttributedString()
        var rest = Substring(s)
        while let match = rest.firstMatch(of: #/\*\*([^*]+)\*\*/#) {
            out += AttributedString(String(rest[..<match.range.lowerBound]))
            var bold = AttributedString(String(match.output.1))
            bold.inlinePresentationIntent = .stronglyEmphasized
            out += bold
            rest = rest[match.range.upperBound...]
        }
        out += AttributedString(String(rest))
        return out
    }
}

// MARK: - Small pieces

/// A suggestion (.chip-btn): a soft white chip with a hairline edge, its words left-aligned. `fills`: as wide and as
/// tall as its cell, for the two columns beside the conversation on the open Duo.
private struct McFlyChipStyle: ButtonStyle {
    var fills = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.app(size: 13, relativeTo: .subheadline))
            .foregroundStyle(Palette.ink)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: fills ? .infinity : nil, maxHeight: fills ? .infinity : nil, alignment: .topLeading)
            .frame(minHeight: 36)
            .background(configuration.isPressed ? Palette.surfaceHover : Palette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.border))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .opacity(isEnabled ? 1 : 0.5)
    }
}

/// Chips in rows, wrapping (flex-wrap).
private struct McFlyFlow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews)
        let width = rows.flatMap { $0 }.map { $0.frame.maxX }.max() ?? 0
        let height = rows.last.flatMap { $0.map(\.frame.maxY).max() } ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for item in arrange(width: bounds.width, subviews).flatMap({ $0 }) {
            subviews[item.index].place(at: CGPoint(x: bounds.minX + item.frame.minX, y: bounds.minY + item.frame.minY),
                                       proposal: ProposedViewSize(width: item.frame.width, height: item.frame.height))
        }
    }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> [[(index: Int, frame: CGRect)]] {
        var rows: [[(index: Int, frame: CGRect)]] = [[]]
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for (i, view) in subviews.enumerated() {
            let size = view.sizeThatFits(ProposedViewSize(width: width, height: nil))
            let w = min(size.width, width)
            if x > 0, x + w > width {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
                rows.append([])
            }
            rows[rows.count - 1].append((i, CGRect(x: x, y: y, width: w, height: size.height)))
            x += w + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return rows
    }
}

/// The step McFly is on: a small ring turning (.mcfly-step-ring); a whole ring, still, with Reduce Motion.
private struct StepRing: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9
            Circle()
                .trim(from: 0, to: reduceMotion ? 1 : 0.75)
                .stroke(Palette.ink3, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .rotationEffect(.degrees(reduceMotion ? 0 : turn * 360))
        }
        .frame(width: 10, height: 10)
        .padding(1)
        .accessibilityHidden(true)
    }
}

/// Words with a soft band of light sweeping across them on a loop (ShinyText.tsx): McFly thinking, and the step it's
/// on. The resting colour is the muted ink and the band the full ink; Reduce Motion leaves plain muted words.
struct ShinyText: View {
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ text: String) { self.text = text }

    /// Seconds per sweep, and the pause between sweeps (the web's speed and delay).
    private static let speed = 1.6
    private static let pause = 0.2

    var body: some View {
        if reduceMotion {
            Text(text).foregroundStyle(Palette.ink3)
        } else {
            TimelineView(.animation) { context in
                let cycle = Self.speed + Self.pause
                let t = min(1, context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle) / Self.speed)
                let eased = 0.5 - cos(.pi * t) / 2
                Text(text)
                    .foregroundStyle(Palette.ink3)
                    .overlay {
                        GeometryReader { geo in
                            let band = geo.size.width * 0.34
                            LinearGradient(colors: [Palette.ink.opacity(0), Palette.ink, Palette.ink.opacity(0)], startPoint: .leading, endPoint: .trailing)
                                .frame(width: band)
                                .offset(x: -band + (geo.size.width + 2 * band) * eased - band / 2 + band / 2)
                        }
                        .mask(Text(text))
                        .allowsHitTesting(false)
                    }
            }
        }
    }
}

#if targetEnvironment(simulator)
/// Scripted runs in the Simulator only, to see the conversation's states where no assistant can answer (a local server
/// has no AI key): `-mcflyPreview <state>` puts a made-up conversation and status in memory once signed in, and keeps
/// the server's status from replacing it. States: thread, streaming, own, ownlimit, limit, off, and charts (the thread
/// and a second answer with a comparison, a list of sports and two tiles, for the open Duo's two columns). Never in a
/// device build.
struct McFlyLaunchHook: ViewModifier {
    @Environment(Dashboard.self) private var dashboard
    @State private var done = false

    func body(content: Content) -> some View {
        content.onChange(of: dashboard.phase == .ready, initial: true) { _, ready in
            guard ready, !done, let state = UserDefaults.standard.string(forKey: "mcflyPreview") else { return }
            done = true
            McFlyPreview.apply(state, to: dashboard.mcfly)
            if UserDefaults.standard.bool(forKey: "mcflyOpen") { dashboard.open(.mcfly) }
        }
    }
}

enum McFlyPreview {
    @MainActor static func apply(_ state: String, to chat: McFlyChat) {
        let status: McFlyStatus
        switch state {
        case "own": status = McFlyStatus(configured: true, limit: 200, usedToday: 3, provider: "openai", source: "own", limited: false)
        case "ownlimit": status = McFlyStatus(configured: true, limit: 200, usedToday: 200, provider: "anthropic", source: "own", limited: false)
        case "limit": status = McFlyStatus(configured: true, limit: 30, usedToday: 30, provider: "anthropic", source: "shared", limited: true)
        case "off": status = McFlyStatus(configured: true, limit: 0, usedToday: 0, provider: "anthropic", source: "shared", limited: true)
        default: status = McFlyStatus(configured: true, limit: 30, usedToday: 4, provider: "anthropic", source: "shared", limited: true)
        }
        chat.preview = status
        chat.status = status
        guard ["thread", "streaming", "own", "charts"].contains(state) else { return }
        var answer = McFlyMessage(role: .assistant, content: "")
        answer.apply(.tool("Looking at your sleep"))
        answer.apply(.tool("Comparing with the week before"))
        answer.apply(.text("You slept about **7 h 10 min** a night this week, 20 minutes more than the week before.\n\n- Five nights were over 7 hours\n- Two short nights midweek"))
        let points = ["2026-10-19": 7.4, "2026-10-20": 6.2, "2026-10-21": 6.4, "2026-10-22": 7.5, "2026-10-23": 7.3, "2026-10-24": 7.8, "2026-10-25": 7.6]
        let json = #"{"visual":{"kind":"bars","title":"Sleep this week","unit":"h","resolution":"day","points":["#
            + points.sorted { $0.key < $1.key }.map { #"{"date":"\#($0.key)","value":\#($0.value)}"# }.joined(separator: ",") + #"],"mean":7.2}}"#
        func visual(_ json: String, into answer: inout McFlyMessage) {
            var lines = McFlySSELineSplitter()
            var parser = McFlySSEParser()
            for byte in Array("event: visual\ndata: \(json)\n\n".utf8) {
                if let line = lines.push(byte), let event = parser.feed(line) { answer.apply(event) }
            }
        }
        visual(json, into: &answer)
        answer.apply(.text("\n\nKeeping a steady bedtime would likely help most."))
        answer.finishAnswer()
        chat.messages = [McFlyMessage(role: .user, content: McFlyWords.suggestions[0]), answer]
        if state == "charts" {
            var more = McFlyMessage(role: .assistant, content: "")
            more.apply(.tool("Looking at your activity"))
            more.apply(.text("This month you averaged about **8,400 steps** a day, a little more than last month."))
            visual(#"{"visual":{"kind":"compare","title":"Steps a day","unit":"steps","periods":[{"label":"This month","from":"2026-10-01","to":"2026-10-25","mean":8412,"days":25},{"label":"Last month","from":"2026-09-01","to":"2026-09-30","mean":7930,"days":30}]}}"#, into: &more)
            visual(#"{"visual":{"kind":"sports","title":"Workouts this month","items":[{"sport":"Running","count":6,"minutes":214},{"sport":"Cycling","count":3,"minutes":160},{"sport":"Yoga","count":4,"minutes":120}]}}"#, into: &more)
            visual(#"{"visual":{"kind":"stats","title":"Your heart this week","items":[{"label":"Resting heart rate","value":58,"unit":"bpm","note":"average of 7 days"},{"label":"Heart rate variability","value":46,"unit":"ms","note":"average of 7 days"}]}}"#, into: &more)
            more.apply(.text("\n\nThe runs did most of it."))
            more.finishAnswer()
            chat.messages += [McFlyMessage(role: .user, content: McFlyWords.suggestions[3]), more]
        }
        if state == "streaming" {
            var pending = McFlyMessage(role: .assistant, content: "", pending: true)
            pending.apply(.tool("Looking at your heart rate"))
            chat.messages += [McFlyMessage(role: .user, content: "And my resting heart rate?"), pending]
            chat.streaming = true
        }
    }
}
#endif
