import SwiftUI

// The two key sheets (src/components/ai/AiSheets.tsx), opened from Profile's Chatbot and "OpenAI · Nutrition &
// portraits" rows, by #/profile?connect=chatbot or ?connect=openai (Nutrition's setup line), and from Ask McFly's
// "Connect your own key". Profile (slice D) presents them; `onClose` is the web's: the presenter's own close, or the
// sheet's dismiss.
//
// A key is sent once, to be checked with its provider and stored encrypted by the server; nothing here keeps it after
// a save, and the server only ever sends back its last four characters. Each sheet reads GET /api/ai as it opens and
// shows the status each write answers with. Signed out, either sheet closes: nothing of the person stays on screen.

/// Who answers Ask McFly, and your own key for it ("Manage chatbot AI"): OpenAI, Claude or Gemini, or the server's
/// shared Claude.
struct ChatbotSheet: View {
    var onClose: (() -> Void)?

    init(onClose: (() -> Void)? = nil) { self.onClose = onClose }

    @Environment(Dashboard.self) private var dashboard
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var model = AIKeysModel()
    @State private var form = ChatbotForm()
    @FocusState private var keyFocused: Bool

    var body: some View {
        SheetScaffold(eyebrow: "Chatbot", title: "Manage chatbot AI", onClose: close) {
            if let status = model.status, form.pick != nil {
                AIStatusLine(status: status)
                if !status.byok {
                    AINotHere(detail: status.shared ? AIWords.sharedAnswers : nil)
                } else {
                    choices(status)
                    details(status)
                }
            } else if model.missing {
                AINotHere()
            } else {
                AILoading(error: model.loadError)
            }
        } footer: {
            footer
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chatbotSheet")
        .task {
            guard dashboard.phase == .ready else { return close() }
            await model.load(dashboard)
            if let s = model.status, form.pick == nil { form.choose(ChatbotForm.opening(s), s) }
        }
        .onChange(of: dashboard.phase) { _, phase in if phase != .ready { signedOut() } }
        .onChange(of: model.note) { _, note in if let note { AccessibilityNotification.Announcement(note.text).post() } }
    }

    @ViewBuilder
    private var footer: some View {
        if let status = model.status, form.pick != nil, status.byok {
            let primary = form.primary(status, busy: model.busy)
            AIFooterButtons {
                Button("Close", action: close).buttonStyle(AITextButtonStyle())
            } primary: {
                Button { save(status) } label: { AIButtonLabel(primary.title) }
                    .buttonStyle(.accentPill)
                    .disabled(!primary.enabled)
                    .accessibilityIdentifier("chatbotPrimary")
            }
        } else {
            Button("Done", action: close).buttonStyle(.accentPill)
        }
    }

    /// The providers as choice cards, two by two (one column at the largest text sizes).
    private func choices(_ status: AiStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Who answers Ask McFly")
                .font(.app(size: 12.5, weight: .medium, relativeTo: .footnote))
                .foregroundStyle(Palette.ink2)
                .accessibilityAddTraits(.isHeader)
            let columns = typeSize.isAccessibilitySize ? [GridItem(.flexible())] : [GridItem(.flexible(), spacing: 10), GridItem(.flexible())]
            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                ForEach(AIProvider.allCases) { p in
                    ChoiceCard(p.label, isOn: form.pick == .own(p), action: { pick(.own(p), status) }) {
                        if status.key(p.rawValue) != nil {
                            Badge("Key added", tone: .sage).padding(.top, 2)
                        }
                    }
                    .accessibilityIdentifier("choice-\(p.rawValue)")
                }
                if status.shared {
                    ChoiceCard("healthOS shared", subtitle: "Claude", isOn: form.pick == .shared, action: { pick(.shared, status) })
                        .accessibilityIdentifier("choice-shared")
                }
            }
            .disabled(model.busy)
        }
    }

    @ViewBuilder
    private func details(_ status: AiStatus) -> some View {
        let info = form.stored(status)
        if let p = form.pick?.provider, let info {
            if form.removing {
                AIConfirmRemove(text: AIWords.confirmRemove(p, consequence: AIWords.chatbotRemoveConsequence(status, p)), provider: p, busy: model.busy,
                                onRemove: { remove(p) }, onKeep: { form.removing = false })
            } else if !form.replacing {
                AIConnectedKey(info: info, busy: model.busy, onReplace: replace, onRemove: { form.removing = true })
            }
        }
        if let p = form.pick?.provider, form.entering(status) {
            AIKeyField(provider: p, key: $form.key, focused: $keyFocused)
                .disabled(model.busy)
                .onSubmit { save(status) }
        }
        if form.pick?.provider != nil, !form.removing {
            AIModelField(model: $form.model).disabled(model.busy)
        }
        if let pick = form.pick {
            AIWherePanel {
                Text(AIWords.whereQuestionsGo(pick))
                if pick == .own(.gemini) { Text(AIWords.geminiTip).foregroundStyle(ColorToken.badgePeachInk.color) }
            }
        }
        AIFeedback(note: model.note)
    }

    private func pick(_ p: ChatChoice, _ status: AiStatus) {
        form.choose(p, status)
        model.note = nil
    }

    private func replace() {
        form.replacing = true
        // The field appears, focused, as the web's autoFocus does.
        Task { @MainActor in keyFocused = true }
    }

    private func save(_ status: AiStatus) {
        guard !model.busy, form.primary(status, busy: false).enabled, let plan = form.save(status) else { return }
        keyFocused = false
        Task {
            let ok = await model.run(dashboard, done: plan.done) { client in
                var last = status
                for step in plan.steps { last = try await client.run(step) }
                return last
            }
            if ok { form.saved() }
        }
    }

    private func remove(_ p: AIProvider) {
        Task {
            if await model.run(dashboard, done: "Your \(p.label) key is removed.", { try await $0.removeAIKey(p) }) { form.saved() }
        }
    }

    /// Close, Done or the X: the typed key goes; the rest stays on screen while the sheet slides away (its state goes
    /// with it), so it never flashes "Loading…".
    private func close() {
        form.key = ""
        if let onClose { onClose() } else { dismiss() }
    }

    /// Signed out underneath: nothing of the person stays, not even while the sheet slides away.
    private func signedOut() {
        form = ChatbotForm()
        model = AIKeysModel()
        if let onClose { onClose() } else { dismiss() }
    }
}

/// Your own OpenAI key, for meal photos and descriptions, voice notes and portraits ("Connect AI key").
struct OpenAIKeySheet: View {
    var onClose: (() -> Void)?

    init(onClose: (() -> Void)? = nil) { self.onClose = onClose }

    @Environment(Dashboard.self) private var dashboard
    @Environment(\.dismiss) private var dismiss
    @State private var model = AIKeysModel()
    @State private var key = ""
    @State private var replacing = false
    @State private var removing = false
    @FocusState private var keyFocused: Bool

    var body: some View {
        SheetScaffold(eyebrow: "OpenAI · Nutrition & portraits", title: "Connect AI key", onClose: close) {
            if let status = model.status {
                if !status.byok {
                    AINotHere(detail: AIWords.instead(status))
                } else {
                    form(status)
                }
            } else if model.missing {
                AINotHere()
            } else {
                AILoading(error: model.loadError)
            }
        } footer: {
            footer
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("openAIKeySheet")
        .task {
            guard dashboard.phase == .ready else { return close() }
            await model.load(dashboard)
        }
        .onChange(of: dashboard.phase) { _, phase in if phase != .ready { signedOut() } }
        .onChange(of: model.note) { _, note in if let note { AccessibilityNotification.Announcement(note.text).post() } }
    }

    private var info: AiStatus.Key? { model.status?.key(AIProvider.openai.rawValue) }
    private var entering: Bool { info == nil || replacing }
    private var keyTyped: Bool { !ChatbotForm.trimmed(key).isEmpty }

    @ViewBuilder
    private var footer: some View {
        if model.status?.byok == true, entering {
            AIFooterButtons {
                Button(replacing ? "Cancel" : "Close") { if replacing { replacing = false; key = "" } else { close() } }
                    .buttonStyle(AITextButtonStyle())
            } primary: {
                Button(action: save) { AIButtonLabel(model.busy ? "Checking with OpenAI…" : "Verify & save") }
                    .buttonStyle(.accentPill)
                    .disabled(model.busy || !keyTyped)
                    .accessibilityIdentifier("openAIPrimary")
            }
        } else {
            Button("Done", action: close).buttonStyle(.accentPill)
        }
    }

    @ViewBuilder
    private func form(_ status: AiStatus) -> some View {
        Text(AIWords.openAILede)
            .font(.app(size: 14, relativeTo: .subheadline))
            .foregroundStyle(Palette.ink2)
            .fixedSize(horizontal: false, vertical: true)
        if let info {
            if removing {
                AIConfirmRemove(text: AIWords.confirmRemove(.openai, consequence: AIWords.openAIRemoveConsequence(status)), provider: .openai,
                                busy: model.busy, onRemove: remove, onKeep: { removing = false })
            } else if !replacing {
                AIConnectedKey(info: info, busy: model.busy, onReplace: {
                    replacing = true
                    Task { @MainActor in keyFocused = true }
                }, onRemove: { removing = true })
            }
        }
        if entering {
            AIKeyField(provider: .openai, key: $key, focused: $keyFocused)
                .disabled(model.busy)
                .onSubmit(save)
        }
        if info == nil {
            Text(AIWords.instead(status))
                .font(.app(size: 12, relativeTo: .caption))
                .foregroundStyle(Palette.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        AIWherePanel {
            Text(AIWords.openAIWhere(connected: info != nil))
            Text(AIWords.openAIPortraits(connected: info != nil, serverPortraits: status.portraits))
            Text(AIWords.openAIChatbotNote).foregroundStyle(Palette.ink3)
        }
        AIFeedback(note: model.note)
    }

    private func save() {
        guard !model.busy, keyTyped, model.status?.byok == true, entering else { return }
        let typed = ChatbotForm.trimmed(key)
        keyFocused = false
        Task {
            if await model.run(dashboard, done: AIWords.openAIConnected, { try await $0.saveOpenAIKey(typed) }) {
                key = ""
                replacing = false
                removing = false
            }
        }
    }

    private func remove() {
        Task {
            if await model.run(dashboard, done: "Your OpenAI key is removed.", { try await $0.removeAIKey(.openai) }) {
                key = ""
                replacing = false
                removing = false
            }
        }
    }

    private func close() {
        key = ""
        if let onClose { onClose() } else { dismiss() }
    }

    /// Signed out underneath: nothing of the person stays, not even while the sheet slides away.
    private func signedOut() {
        key = ""
        replacing = false
        removing = false
        model = AIKeysModel()
        if let onClose { onClose() } else { dismiss() }
    }
}

#if targetEnvironment(simulator)
/// Scripted runs in the Simulator only: `-aiSheet chatbot` or `-aiSheet openai` opens that sheet over Home once
/// signed in, so the sheets can be seen before Profile (another slice) offers their rows. Never in a device build.
struct AISheetLaunchHook: ViewModifier {
    @Environment(Dashboard.self) private var dashboard
    @State private var sheet: String?
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .onChange(of: dashboard.phase == .ready, initial: true) { _, ready in
                guard ready, !shown, let asked = UserDefaults.standard.string(forKey: "aiSheet") else { return }
                shown = true
                sheet = asked
            }
            .sheet(item: Binding(get: { sheet.map(HookSheet.init) }, set: { sheet = $0?.id })) { s in
                if s.id == "openai" { OpenAIKeySheet { sheet = nil } } else { ChatbotSheet { sheet = nil } }
            }
    }

    private struct HookSheet: Identifiable { let id: String }
}
#endif
