import Foundation
import Security

/// How far back the first sync (or a re-upload) reaches.
enum History: String, CaseIterable, Identifiable, Codable {
    case month, year, all
    var id: String { rawValue }

    var label: String {
        switch self {
        case .month: "30 days"
        case .year: "1 year"
        case .all: "Everything"
        }
    }

    func start(from now: Date) -> Date? {
        switch self {
        case .month: Calendar.current.date(byAdding: .day, value: -30, to: Calendar.current.startOfDay(for: now))
        case .year: Calendar.current.date(byAdding: .year, value: -1, to: Calendar.current.startOfDay(for: now))
        case .all: nil
        }
    }
}

/// User settings. The token lives in the Keychain; the rest in UserDefaults.
enum Config {
    private static let defaults = UserDefaults.standard

    static var serverText: String {
        get {
            if let saved = defaults.string(forKey: "serverURL") { return saved }
            #if targetEnvironment(simulator)
            // No default: simulator builds can fill Health with fake sample data, and any server the app syncs
            // with receives it. Even localhost:8787 writes to the hosted database when .env.local has DATABASE_URL.
            return ""
            #else
            return "https://health.mcfly.bot"
            #endif
        }
        set { defaults.set(newValue, forKey: "serverURL") }
    }

    /// WHOOP has written steps into Health at least once, so its hours can reach the Day view.
    static var sawWhoopSteps: Bool {
        get { defaults.bool(forKey: "sawWhoopSteps") }
        set { defaults.set(newValue, forKey: "sawWhoopSteps") }
    }

    static var token: String {
        get { Keychain.read() ?? "" }
        set { Keychain.write(newValue) }
    }

    /// Whose account the token sends to, and whether the sync waits for a sign-in (IngestTokenOwner). Read by
    /// background wakes too, so it's kept here rather than with the dashboard. In the Keychain beside the token, not
    /// in UserDefaults: deleting the app keeps Keychain items, so the two outlive a reinstall together, and a pause
    /// can't be lost while the token stays.
    static var ingestOwner: IngestTokenOwner {
        get {
            Keychain.read(service: Keychain.ingestTokenOwner)
                .flatMap { try? JSONDecoder().decode(IngestTokenOwner.self, from: Data($0.utf8)) } ?? IngestTokenOwner()
        }
        set {
            let json = (try? JSONEncoder().encode(newValue)).map { String(decoding: $0, as: UTF8.self) } ?? ""
            Keychain.write(json, service: Keychain.ingestTokenOwner)
        }
    }

    static var history: History {
        get { defaults.string(forKey: "history").flatMap(History.init(rawValue:)) ?? .all }
        set { defaults.set(newValue.rawValue, forKey: "history") }
    }

    static var backgroundSync: Bool {
        get { defaults.object(forKey: "backgroundSync") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "backgroundSync") }
    }

    /// Pre-fills the sign-in form. Not a secret; the password is never stored.
    static var lastEmail: String {
        get { defaults.string(forKey: "lastEmail") ?? "" }
        set { defaults.set(newValue, forKey: "lastEmail") }
    }

    /// The person's cycle-tracking setting on the server (status.settings.cycleTracking).
    static var cycleTracking: Bool {
        get { defaults.bool(forKey: "cycleTracking") }
        set { defaults.set(newValue, forKey: "cycleTracking") }
    }

    /// The server answered an ingest with a `cycle` count, so it stores cycle days.
    static var serverStoresCycle: Bool {
        get { defaults.bool(forKey: "serverStoresCycle") }
        set { defaults.set(newValue, forKey: "serverStoresCycle") }
    }

    /// The daily metrics the server listed in its last ingest reply (nil: an older server that doesn't list them).
    /// Kept with the sync state, which starts over when the server changes.
    static var serverMetrics: [String]? { SyncState.load().acceptedMetrics }

    /// Health was asked about writing the food logged here (the first entry saved on this phone). From then on every
    /// Health request includes those types.
    static var foodHealthAsked: Bool {
        get { defaults.bool(forKey: "foodHealthAsked") }
        set { defaults.set(newValue, forKey: "foodHealthAsked") }
    }

    static var healthRequested: Bool {
        get { defaults.bool(forKey: "healthRequested") }
        set { defaults.set(newValue, forKey: "healthRequested") }
    }

    /// "health.mcfly.bot" -> https://health.mcfly.bot; "192.168.1.20:8788" -> http://192.168.1.20:8788.
    /// Nil if it isn't a usable http(s) URL.
    static func serverURL(_ text: String = serverText) -> URL? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        if !s.contains("://") {
            // Without a scheme, assume TLS, except for local addresses, which a dev server serves over plain HTTP.
            let local = s.hasPrefix("localhost") || s.contains(".local") || s.range(of: #"^\d+\.\d+\.\d+\.\d+"#, options: .regularExpression) != nil
            s = (local ? "http://" : "https://") + s
        }
        while s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s), let scheme = url.scheme, ["http", "https"].contains(scheme), url.host != nil else { return nil }
        return url
    }
}

/// The ingest token belongs to one account on the server, whoever is signed in here: Health data sent with it lands in
/// that account. So a phone that changes hands would keep sending the new person's Health data to the last person.
/// To stop that, being signed out pauses the sync, in the app and in the background: after Sign out, a session that
/// ran out or was ended elsewhere, or no session at launch. The same account signing back in resumes it; anyone else
/// signing in removes the token, and Settings asks to set this iPhone up again. A token nobody can be told the owner of
/// is never handed to whoever signs in next. A server without sign-in (authMode "open") has one person, so nothing
/// pauses there.
struct IngestTokenOwner: Codable, Equatable {
    /// An account on one server: ids repeat across servers ("owner" is the first account on each).
    struct Account: Codable, Equatable {
        let server: String
        let id: String
    }

    /// Who may take a token whose owner isn't known (`account` nil).
    enum Claim: String, Codable {
        /// Here before owners were kept (an older build's): the account signed in when it's first seen. First seen
        /// while nobody is signed in, it becomes `nobody`'s.
        case firstSeen
        /// Typed or pasted while nobody was signed in: whoever signs in next.
        case nextSignIn
        /// First seen while nobody was signed in, so it can't be told whose: the next sign-in removes it.
        case nobody
    }

    /// Who the token was set under, or first seen with while signed in; nil when not known, or there's no token.
    var account: Account?
    var claim = Claim.firstSeen
    /// Nobody is signed in on a server with sign-in: no Health data goes up until someone signs in.
    var paused = false
    /// The token was removed because it may be someone else's: Settings asks to set this iPhone up again.
    var setUpAgain = false

    /// The token was typed, pasted or removed while `signedIn` (nil: signed out, or a server without accounts).
    mutating func tokenChanged(hasToken: Bool, signedIn: Account?) {
        account = hasToken ? signedIn : nil
        claim = hasToken && signedIn == nil ? .nextSignIn : .firstSeen
        if hasToken { setUpAgain = false }
    }

    /// Someone is signed in: a sign-in, a new account from an invite, or any status read while signed in. `who` is nil
    /// on an older server with one password and no accounts: one person, so the token is theirs. A token whose owner
    /// isn't known yet is taken as this account's (a token from before owners were kept, or one pasted while signed
    /// out), except one nobody can be told the owner of, and except after an invite: an account made a moment ago
    /// can't have made a token, so the one here is someone else's. Returns true when the token has to go.
    mutating func signedIn(_ who: Account?, hasToken: Bool, newAccount: Bool = false) -> Bool {
        paused = false
        guard hasToken else {
            account = nil
            claim = .firstSeen
            return false
        }
        if !newAccount {
            guard let who else { return false }
            if account == nil, claim != .nobody { account = who }
            if account == who { return false }
        }
        account = nil
        claim = .firstSeen
        setUpAgain = true
        return true
    }

    /// Nobody is signed in now: `who` signed out with the button, or (nil) the session ended or there was none at
    /// launch. Nothing goes up until someone signs in. A token whose owner isn't known yet is the one signing out's;
    /// one from before owners were kept, first seen now, can't be told whose.
    mutating func signedOut(_ who: Account?, hasToken: Bool) {
        if hasToken, account == nil, claim != .nobody {
            if let who { account = who } else if claim == .firstSeen { claim = .nobody }
        }
        paused = true
    }

    /// A server without sign-in, `server`: one person, so nothing waits. Except for a token that's an account's on
    /// another server, or nobody's: going back to a server with sign-in, a new background wake mustn't find the pause
    /// gone before that server says who's signed in.
    mutating func noSignIn(on server: String) {
        if let account, account.server != server { return }
        if account == nil, claim == .nobody { return }
        paused = false
    }
}

extension IngestTokenOwner {
    private enum CodingKeys: String, CodingKey { case account, claim, paused, setUpAgain }

    /// Field by field, each with its default when missing or unreadable.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(account: try? c.decodeIfPresent(Account.self, forKey: .account),
                  claim: (try? c.decodeIfPresent(Claim.self, forKey: .claim)) ?? .firstSeen,
                  paused: (try? c.decodeIfPresent(Bool.self, forKey: .paused)) ?? false,
                  setUpAgain: (try? c.decodeIfPresent(Bool.self, forKey: .setUpAgain)) ?? false)
    }
}

/// Where the ingest token and its owner are kept.
protocol IngestTokenStore: AnyObject {
    var hasToken: Bool { get }
    var owner: IngestTokenOwner { get set }
    /// Removes the token because it may be someone else's.
    func removeToken()
}

/// The app's: the token and its owner in the Keychain, where background syncs read them.
final class KeychainTokenStore: IngestTokenStore {
    var hasToken: Bool { !Config.token.isEmpty }

    var owner: IngestTokenOwner {
        get { Config.ingestOwner }
        set { Config.ingestOwner = newValue }
    }

    func removeToken() {
        Config.token = ""
        // The next token is another person's: their history goes up from the start, not from where the last one's stopped.
        Task { await SyncEngine.shared.reset() }
        NotificationCenter.default.post(name: .healthOSTokenRemoved, object: nil)
    }
}

/// Kept in memory only: a dashboard made without the app's store (tests, previews) never touches the real token.
final class MemoryTokenStore: IngestTokenStore {
    var token: String
    var owner: IngestTokenOwner

    init(token: String = "", owner: IngestTokenOwner = IngestTokenOwner()) {
        self.token = token
        self.owner = owner
    }

    var hasToken: Bool { !token.isEmpty }
    func removeToken() { token = "" }
}

extension Notification.Name {
    /// Posted when the ingest token was removed because it may be someone else's, so Settings' field follows.
    static let healthOSTokenRemoved = Notification.Name("healthOSTokenRemoved")
}

enum Keychain {
    static let ingestToken = "healthos.ingest-token"
    /// The token's IngestTokenOwner, as JSON.
    static let ingestTokenOwner = "healthos.ingest-token-owner"

    private static func query(_ service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "default"]
    }

    static func read(service: String = ingestToken) -> String? {
        var q = query(service)
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// An empty value deletes the item.
    static func write(_ value: String, service: String = ingestToken) {
        SecItemDelete(query(service) as CFDictionary)
        guard !value.isEmpty else { return }
        var q = query(service)
        q[kSecValueData as String] = Data(value.utf8)
        // Background deliveries can arrive while the phone is locked; the token must stay readable after first unlock.
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }
}
