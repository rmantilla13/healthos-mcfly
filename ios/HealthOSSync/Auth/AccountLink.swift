import Foundation

// Invite codes and reset links (server/auth.ts, src/pages/Login.tsx, src/lib.ts readAccountLink). An invite is a short
// code someone types (ABCD-EFGH), or the same code as a link (…/#/invite/ABCDEFGH); a reset is always a long link
// (…/#/reset/<token>). The web opens those links in the browser; on the iPhone they're typed or pasted on the sign-in
// screen, the whole link or the code alone.
//
// Every failed link check counts toward the same per-address lockout as a wrong password (8 failures lock sign-in for
// 15 minutes), and a family on one home network shares that address. So what can't be a code or a link is turned
// down here, on the phone, and never sent.

/// What a link is for: joining (an invite) or choosing a new password (a reset).
enum AccountLinkKind: String, Equatable, Decodable {
    case invite, reset
}

/// What someone pasted or typed: the kind its link says (nil for a bare code or token) and the token in it.
struct PastedLink: Equatable {
    var kind: AccountLinkKind?
    var token: String
}

enum AccountLink {
    /// The letters a code is made of (server/auth.ts CODE_ALPHABET): no 0/O or 1/I/L look-alikes.
    static let codeAlphabet = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
    static let codeLength = 8
    /// The shortest long token taken for a link. The server makes them from 24 random bytes (32 base64url characters);
    /// anything near a code's length is a mistyped code, not a link.
    static let minLinkToken = 20

    /// The server's words for a code or link it doesn't know (checkLink), shown as they are when the phone can tell
    /// without asking.
    static let invalid = "This code or link is invalid, expired or already used."
    /// The web's words for a link of the other kind (AccountLinkPage).
    static let wrongKind = "This link is invalid, expired or already used."

    /// The fewest characters in a new password (Login.tsx and server/auth.ts MIN_PASSWORD).
    static let minPassword = 10
    /// The longest name the server keeps from an invite (acceptInvite's slice(0, 60)); the web's field stops there.
    static let maxName = 60

    /// A code as the server keeps it: 8 letters from the alphabet, in capitals.
    static func isCode(_ text: String) -> Bool {
        text.count == codeLength && text.allSatisfy { codeAlphabet.contains($0) }
    }

    /// A link's long token: base64url characters only (the web's readAccountLink), and long enough to be one.
    static func isLinkToken(_ text: String) -> Bool {
        text.count >= minLinkToken && text.unicodeScalars.allSatisfy { base64url.contains($0) }
    }

    private static let base64url = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")

    /// What was pasted: a whole invite or reset link (everything up to `#/invite/` or `#/reset/` goes, and whatever
    /// follows the token: `?…`, `&…`, a slash), or a bare code or token. A code comes back as the server keeps it
    /// (normalizeToken: spaces and dashes out, in capitals); anything else as given, since link tokens are
    /// case-sensitive.
    static func parse(_ raw: String) -> PastedLink {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var kind: AccountLinkKind?
        for candidate in [AccountLinkKind.invite, .reset] {
            guard let range = text.range(of: "#/\(candidate.rawValue)/") else { continue }
            kind = candidate
            text = String(text[range.upperBound...])
            if let end = text.firstIndex(where: { "?&/#".contains($0) || $0.isWhitespace }) { text = String(text[..<end]) }
            break
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let compact = String(text.filter { $0 != "-" && !$0.isWhitespace }).uppercased()
        return PastedLink(kind: kind, token: isCode(compact) ? compact : text)
    }

    /// Could this be a real code or link of that kind? An invite is a code or a link's token; a reset is only ever a
    /// link's token. Anything else would only count as a failure on the server.
    static func plausible(_ token: String, as kind: AccountLinkKind) -> Bool {
        switch kind {
        case .invite: isCode(token) || isLinkToken(token)
        case .reset: isLinkToken(token)
        }
    }

    /// Something to try (the web's Continue: anything but blank).
    static func filled(_ raw: String) -> Bool { !parse(raw).token.isEmpty }

    /// The code step's answer: which page to open (the kind a pasted link names wins over the step's own), or the
    /// server's words for a code or link that can't be one, without asking it.
    static func entered(_ raw: String, on step: AccountLinkKind) -> Result<(AccountLinkKind, String), LinkShapeError> {
        let pasted = parse(raw)
        let kind = pasted.kind ?? step
        guard plausible(pasted.token, as: kind) else { return .failure(LinkShapeError()) }
        return .success((kind, pasted.token))
    }

    /// The invite page's lede names its code as it's read aloud (ABCD-EFGH); a long link's token is only "accepted".
    static func codeLabel(_ token: String) -> String {
        guard token.count == codeLength else { return "accepted" }
        return "\(token.prefix(4))-\(token.suffix(4))"
    }

    /// The invite page's lede (AccountLinkPage), with the Family board's disclosure.
    static func inviteLede(_ token: String) -> String {
        "Invite code \(codeLabel(token)). Your full dashboard is private to you. Members who share, the admin included, see your daily tile and your last 30 days of sleep, recovery or HRV, steps, resting heart rate and training load on the Family board; you can turn that off in your Profile."
    }
}

/// A code or link that can't be one: never sent, so it never counts toward the lockout.
struct LinkShapeError: LocalizedError, Equatable {
    var errorDescription: String? { AccountLink.invalid }
}

/// POST /api/auth/link: what a code or link is for, and the email an invite is locked to (nil when it isn't).
struct LinkCheck: Decodable, Equatable {
    let kind: AccountLinkKind
    let email: String?

    private enum CodingKeys: String, CodingKey { case kind, email }

    init(kind: AccountLinkKind, email: String?) {
        self.kind = kind
        self.email = email
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(AccountLinkKind.self, forKey: .kind)
        let email = (try? c.decodeIfPresent(String.self, forKey: .email)) ?? nil
        self.email = email?.isEmpty == false ? email : nil
    }
}

/// How a link's check came out.
enum LinkCheckResult: Equatable {
    case ok(email: String?)
    /// The server's words, or the web's for a link of the other kind.
    case bad(String)
    /// A server older than the check, asked while signed out (its session gate answers 401 for a route it doesn't
    /// have): on to the form unchecked, as the iPhone did before.
    case unchecked
}

extension AccountLink {
    /// The check a link's page opens with (AccountLinkPage's effect): it must be the kind asked for.
    static func check(_ token: String, kind: AccountLinkKind, ask: (String) async throws -> LinkCheck) async -> LinkCheckResult {
        do {
            let link = try await ask(token)
            return link.kind == kind ? .ok(email: link.email) : .bad(wrongKind)
        } catch APIError.signInRequired {
            return .unchecked
        } catch {
            return .bad(error.localizedDescription)
        }
    }
}

extension APIClient {
    /// POST /api/auth/link. Its 4xx come back in the server's own words (`.network`), a 404 included; a 401 is an older
    /// server's session gate (`.signInRequired`). Never through `dashboard.fetch`: nobody is signed in to lose.
    func checkLink(_ token: String) async throws -> LinkCheck {
        try await sendJSON("POST", "/auth/link", ["token": token])
    }

    /// POST /api/auth/reset: a new password from a reset link. Every other session ends, and this one starts.
    func resetPassword(token: String, password: String) async throws {
        _ = try await request("/auth/reset", method: "POST", body: try JSONSerialization.data(withJSONObject: ["token": token, "password": password]))
        guard SessionStore.cookie(for: base) != nil else { throw APIError.network("Your password is set, but the server sent no session. Sign in.") }
    }
}

extension Dashboard {
    /// A new password from a reset link: the session it starts is set up as a sign-in's, for the email the server now
    /// says is signed in (a reset link carries none).
    func resetPassword(token: String, password: String) async throws {
        guard let client = APIClient.current() else { throw APIError.network("Enter the server address in Profile.") }
        try await client.resetPassword(token: token, password: password)
        // Never "": the email kept says whose an older build's ingest token is (IngestTokenOwner). Should the server not
        // answer just then, the one kept stays as it was; the status read after says who it is.
        let me = try? await client.authState()
        await sessionStarted(email: me?.user?.email ?? Config.lastEmail)
    }
}
