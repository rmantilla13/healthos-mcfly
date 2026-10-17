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

enum Keychain {
    static let ingestToken = "healthos.ingest-token"

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
