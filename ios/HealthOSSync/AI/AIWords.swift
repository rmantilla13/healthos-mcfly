import Foundation

// The words and rules of the two key sheets, ported from src/components/ai/AiSheets.tsx so they can be tested against
// the web's own file: what Ask McFly uses now, where a question goes, what runs while no key is connected, what the
// server last saw of a stored key, and which button the Chatbot sheet offers. No key ever passes through here: only
// a provider, its last four characters and the model the person typed.

/// One of the providers a person can connect a key for (shared/ai.ts AI_PROVIDERS), in the web's order.
enum AIProvider: String, CaseIterable, Identifiable {
    case openai, anthropic, gemini

    var id: String { rawValue }

    /// The name people know it by (LABEL in AiSheets.tsx).
    var label: String {
        switch self {
        case .openai: "OpenAI"
        case .anthropic: "Claude"
        case .gemini: "Gemini"
        }
    }

    /// Who receives the questions (COMPANY in AiSheets.tsx).
    var company: String {
        switch self {
        case .openai: "OpenAI"
        case .anthropic: "Anthropic"
        case .gemini: "Google"
        }
    }

    /// A provider's name for a provider id the server sent; the id as it is for one this app doesn't know.
    static func label(_ id: String?) -> String? {
        guard let id else { return nil }
        return AIProvider(rawValue: id)?.label ?? id
    }
}

/// Who answers Ask McFly, as the Chatbot sheet chooses it (shared/ai.ts ChatChoice): a provider on the person's own
/// key, or "shared", the server's Claude.
enum ChatChoice: Hashable, Identifiable {
    case shared
    case own(AIProvider)

    init?(_ raw: String) {
        if raw == "shared" { self = .shared }
        else if let p = AIProvider(rawValue: raw) { self = .own(p) }
        else { return nil }
    }

    var raw: String {
        switch self {
        case .shared: "shared"
        case .own(let p): p.rawValue
        }
    }

    var id: String { raw }

    var provider: AIProvider? {
        if case .own(let p) = self { return p }
        return nil
    }
}

enum AIWords {
    /// AiSheets.tsx NOT_HERE.
    static let notHere = ServerWords.keysNotHere

    /// What the server last saw of a stored key, by its kind (PROBLEM in AiSheets.tsx). nil for a kind this app
    /// doesn't know: the badge still says it needs attention.
    static func problem(_ kind: String?) -> String? {
        switch kind {
        case "auth": "This key didn't work the last time it was used. Replace it, or check it with the provider."
        case "quota": "Its account was out of credit the last time it was used."
        case "unreadable": "This key can't be read any more, because the server's data key changed. Paste it again."
        default: nil
        }
    }

    /// The line at the top of the Chatbot sheet: what Ask McFly uses right now (usingLine).
    static func using(_ s: AiStatus) -> String {
        guard let chat = s.chat else { return s.byok ? ServerWords.mcflyNeedsKey : ServerWords.mcflyNotOnServer }
        if chat.source == "shared" { return "Using healthOS's shared Claude" }
        let last4 = s.key(chat.provider)?.last4
        return "Using your \(AIProvider.label(chat.provider) ?? chat.provider) key\(last4.map { " ending \($0)" } ?? "")"
    }

    /// Where a question goes on each choice (whereLine).
    static func whereQuestionsGo(_ pick: ChatChoice) -> String {
        switch pick {
        case .shared:
            "Your questions, and the data McFly reads to answer them, go to Anthropic on healthOS's key, within the daily question limit."
        case .own(let p):
            "Your questions, and the data McFly reads to answer them, go to \(p.company) on your key, under your own agreement with them. They don't count toward healthOS's daily limit."
        }
    }

    static let geminiTip = "Use a paid-tier key: Google may use free-tier content to improve its products."

    /// Under the Chatbot sheet's "not here" panel when the shared assistant still answers.
    static let sharedAnswers = "Ask McFly answers with healthOS's shared Claude key, within its daily question limit."

    /// What runs instead while no OpenAI key of the person's own is connected (instead() in OpenAIKeySheet).
    static func instead(_ s: AiStatus) -> String {
        let meals: String
        if s.estimate?.source == "own", s.estimate?.provider == AIProvider.anthropic.rawValue {
            meals = "Until then, meal estimates use your Claude key."
        } else if s.estimate != nil {
            meals = "Until then, meal estimates use healthOS's shared Claude."
        } else if s.byok {
            meals = "Meal estimates need this key, or a Claude key in Chatbot."
        } else {
            meals = ServerWords.estimatesNotHere
        }
        let voice = s.voice ? "Voice notes and portraits use the server's OpenAI key."
            : s.byok ? "Voice notes and portraits need this key." : ServerWords.voiceAndPortraitsNotHere
        return "\(meals) \(voice)"
    }

    /// "Remove your X key from healthOS? …", with what happens to Ask McFly when the chat uses that key (ConfirmRemove).
    static func confirmRemove(_ provider: AIProvider, consequence: String) -> String {
        ["Remove your \(provider.label) key from healthOS?", consequence, "You can connect it again anytime."]
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The Chatbot sheet's consequence of removing a key the chat uses.
    static func chatbotRemoveConsequence(_ s: AiStatus, _ provider: AIProvider) -> String {
        guard s.chatChoice == provider.rawValue else { return "" }
        return s.shared ? "Ask McFly goes back to healthOS's shared Claude." : "Ask McFly stops until you connect a key."
    }

    /// The OpenAI sheet's: the same, "too", since the key is first of all for meals, voice notes and portraits.
    static func openAIRemoveConsequence(_ s: AiStatus) -> String {
        guard s.chatChoice == AIProvider.openai.rawValue else { return "" }
        return s.shared ? "Ask McFly goes back to healthOS's shared Claude too." : "Ask McFly stops too, until you connect a key."
    }

    // MARK: The OpenAI sheet's words

    static let openAILede = "Your own OpenAI API key, for meal photos and descriptions, voice notes and portraits."
    static let openAIConnected = "Connected. Meal photos, descriptions, voice notes and portraits now use your OpenAI key."

    /// The where-panel's first paragraph: before a key is stored the line above says what's used meanwhile; this one
    /// is what the key changes.
    static func openAIWhere(connected: Bool) -> String {
        (connected ? "Meal photos, descriptions and voice notes go" : "Once your key is connected, meal photos, descriptions and voice notes go")
            + " to OpenAI on your key, for that one request, and aren't kept by healthOS. Estimates and voice notes on your key don't count toward healthOS's daily limits."
    }

    static func openAIPortraits(connected: Bool, serverPortraits: Bool) -> String {
        if connected { return "Portrait photos stay in your account, seen only by you, and go to OpenAI on your key only when you make a portrait." }
        if serverPortraits {
            return "Portrait photos stay in your account, seen only by you, and go to OpenAI on this healthOS server's key, only when you make a portrait, until you connect yours."
        }
        return "Portrait photos stay in your account, seen only by you. Making a portrait needs this key."
    }

    static let openAIChatbotNote = "Choose OpenAI in Chatbot to use this same key for Ask McFly."
}

/// The Chatbot sheet's state, as ChatbotSheet keeps it on the web: the choice on screen, the key and model typed,
/// replacing or removing a stored key. Pure, so the web's rules are tested on their own. The key typed lives only in
/// the sheet's memory, and goes when a save succeeds or the sheet closes.
struct ChatbotForm: Equatable {
    var pick: ChatChoice?
    var key = ""
    var model = ""
    var replacing = false
    var removing = false

    /// What the sheet opens on: the person's choice, else the shared assistant, else the first provider (the web's
    /// useEffect on the first status).
    static func opening(_ s: AiStatus) -> ChatChoice {
        let choice = ChatChoice(s.chatChoice) ?? .shared
        return choice != .shared || s.shared || !s.byok ? choice : .own(.openai)
    }

    /// Choosing a card starts over: nothing typed, the stored key's model.
    mutating func choose(_ p: ChatChoice, _ s: AiStatus?) {
        pick = p
        key = ""
        replacing = false
        removing = false
        model = p.provider.flatMap { s?.key($0.rawValue)?.model } ?? ""
    }

    /// After a save or a removal went through.
    mutating func saved() {
        key = ""
        replacing = false
        removing = false
    }

    func stored(_ s: AiStatus) -> AiStatus.Key? { pick?.provider.flatMap { s.key($0.rawValue) } }
    /// A key is typed for this provider: none is stored yet, or it's being replaced.
    func entering(_ s: AiStatus) -> Bool { pick?.provider != nil && (stored(s) == nil || replacing) }
    func modelChanged(_ s: AiStatus) -> Bool {
        guard let info = stored(s) else { return false }
        return Self.trimmed(model) != (info.model ?? "")
    }
    func isCurrent(_ s: AiStatus) -> Bool { pick?.raw == s.chatChoice }
    var keyTyped: Bool { !Self.trimmed(key).isEmpty }

    /// The footer's main button: its words, and whether it can be pressed.
    func primary(_ s: AiStatus, busy: Bool) -> (title: String, enabled: Bool) {
        guard let pick else { return ("", false) }
        switch pick {
        case .shared:
            return (isCurrent(s) ? "In use" : "Use the shared assistant", !busy && !isCurrent(s))
        case .own(let p):
            if entering(s) { return (busy ? "Checking with \(p.label)…" : "Verify & save", !busy && keyTyped) }
            return (isCurrent(s) ? "Save" : "Use \(p.label)", !busy && !(isCurrent(s) && !modelChanged(s)))
        }
    }

    /// One request of a save, in order; the last one answers with the status the sheet shows.
    enum Step: Equatable {
        /// PUT /ai/keys/:provider. `key` nil changes only the stored key's model; `model` nil is the default.
        case putKey(AIProvider, key: String?, model: String?)
        /// PUT /ai/chat.
        case useChat(ChatChoice)
    }

    /// What pressing the main button sends, and the note shown once it went through; nil when there's nothing to send.
    func save(_ s: AiStatus) -> (steps: [Step], done: String)? {
        guard let pick else { return nil }
        guard case .own(let p) = pick else { return ([.useChat(.shared)], "Ask McFly now uses healthOS's shared Claude.") }
        let model = Self.trimmed(self.model).isEmpty ? nil : Self.trimmed(self.model)
        if entering(s) {
            guard keyTyped else { return nil }
            return ([.putKey(p, key: Self.trimmed(key), model: model), .useChat(pick)], "Saved. Ask McFly now uses your \(p.label) key.")
        }
        let steps: [Step] = (modelChanged(s) ? [.putKey(p, key: nil, model: model)] : []) + [.useChat(pick)]
        return (steps, isCurrent(s) ? "Saved." : "Ask McFly now uses your \(p.label) key.")
    }

    static func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
}
