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
            return "http://localhost:8787" // the simulator shares the Mac's network, so the localhost-only server works
            #else
            return ""
            #endif
        }
        set { defaults.set(newValue, forKey: "serverURL") }
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

    static var healthRequested: Bool {
        get { defaults.bool(forKey: "healthRequested") }
        set { defaults.set(newValue, forKey: "healthRequested") }
    }

    /// "192.168.1.20:8788" -> http://192.168.1.20:8788. Nil if it isn't a usable http(s) URL.
    static func serverURL(_ text: String = serverText) -> URL? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        if !s.contains("://") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s), let scheme = url.scheme, ["http", "https"].contains(scheme), url.host != nil else { return nil }
        return url
    }
}

enum Keychain {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "healthos.ingest-token",
        kSecAttrAccount as String: "default",
    ]

    static func read() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String) {
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var q = query
        q[kSecValueData as String] = Data(value.utf8)
        // Background deliveries can arrive while the phone is locked; the token must stay readable after first unlock.
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }
}
