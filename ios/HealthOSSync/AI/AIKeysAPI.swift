import Foundation

// Your own AI keys (server/ai/routes.ts), as Profile's Chatbot and OpenAI sheets send them. A key goes out once, in
// the body of PUT /api/ai/keys/:provider, for the server to check with its provider and store encrypted; nothing on
// the phone keeps, caches or logs it, and every answer carries only a provider and its last four characters. Each
// write answers with the person's AiStatus, which the sheets show and pass to `availability.heard(ai:)`.
//
// GET /api/ai is the foundation's (`APIClient.aiStatus()`, nil from a server older than own keys). The writes are new
// on this branch too, but they're only offered once GET /api/ai has answered, so an older server never sees one.

extension APIClient {
    /// PUT /api/ai/keys/:provider. `key` nil changes only a stored key's model; `model` nil means the default. The
    /// server checks a new key with the provider first: a 400 "That key wasn't accepted by OpenAI." or a 502
    /// "Couldn't reach OpenAI to check the key…" comes back in its own words.
    func saveAIKey(_ provider: AIProvider, key: String?, model: String?) async throws -> AiStatus {
        try await sendJSON("PUT", Self.keyPath(provider), Self.keyBody(key: key, model: model), timeout: 45)
    }

    static func keyPath(_ provider: AIProvider) -> String { "/ai/keys/\(provider.rawValue)" }

    /// The body of PUT /ai/keys/:provider from the Chatbot sheet: the model always (null for the default, as the web
    /// sends it), the key only when one was typed.
    static func keyBody(key: String?, model: String?) -> [String: Any] {
        var body: [String: Any] = ["model": model ?? NSNull()]
        if let key { body["key"] = key }
        return body
    }

    /// PUT /api/ai/keys/openai with only the key (the OpenAI sheet), which keeps the model already stored.
    func saveOpenAIKey(_ key: String) async throws -> AiStatus {
        try await sendJSON("PUT", Self.keyPath(.openai), ["key": key], timeout: 45)
    }

    /// DELETE /api/ai/keys/:provider. A chat that used it goes back to the shared assistant.
    func removeAIKey(_ provider: AIProvider) async throws -> AiStatus {
        try await sendJSON("DELETE", Self.keyPath(provider))
    }

    /// PUT /api/ai/chat: who answers Ask McFly.
    func chooseChat(_ choice: ChatChoice) async throws -> AiStatus {
        try await sendJSON("PUT", "/ai/chat", ["provider": choice.raw])
    }

    /// One step of the Chatbot sheet's save.
    func run(_ step: ChatbotForm.Step) async throws -> AiStatus {
        switch step {
        case .putKey(let p, let key, let model): try await saveAIKey(p, key: key, model: model)
        case .useChat(let choice): try await chooseChat(choice)
        }
    }
}

extension Error {
    /// What the key sheets and Ask McFly show for a refused request: the server's own words whatever its status (a
    /// 502 "Couldn't reach OpenAI to check the key. Try again in a moment." included), as the web shows them. Never
    /// anything of the key: the server's words never carry it.
    var aiMessage: String {
        switch self as? APIError {
        case .server(_, let message)? where !message.isEmpty: message
        case .misconfigured(let message)?: message
        default: localizedDescription
        }
    }
}
