import Foundation
import Observation

enum AppTab: Hashable { case today, trends, settings }

enum TrendsSection: String, CaseIterable, Identifiable {
    case vitals = "Vitals", sleep = "Sleep", activity = "Activity", body = "Body"
    var id: String { rawValue }

    /// Web pages an insight can link to.
    init?(page: String) {
        switch page {
        case "vitals": self = .vitals
        case "sleep": self = .sleep
        case "activity": self = .activity
        case "body": self = .body
        default: return nil
        }
    }
}

extension Notification.Name {
    /// Posted when a HealthKit sync sent new data, so the dashboard can reload.
    static let healthOSSynced = Notification.Name("healthOSSynced")
}

/// What the dashboard shows, read from the healthOS server. The server merges Apple Health and
/// WHOOP and computes recovery, insights and the week summary, so the app shows the same
/// numbers as the web dashboard.
@MainActor
@Observable
final class Dashboard {
    enum Phase: Equatable {
        case starting
        case noServer
        case signIn
        case unavailable(String)
        case ready
    }

    var phase: Phase = .starting
    var summary: Summary?
    var status: ServerStatus?
    /// nil means today.
    var date: String?
    var loading = false
    /// Shown above the content, e.g. while offline with a cached summary on screen.
    var error: String?
    var tab: AppTab = .today
    var trendsSection: TrendsSection = .vitals
    /// "open" (no sign-in, e.g. a local server) or "required" (the hosted dashboard).
    var authMode: String?
    /// The server signs in with email and password (per-person accounts), not a password alone.
    var usesAccounts = false
    /// Who's signed in, on servers with accounts.
    var account: AuthState.User?
    /// Goes up after every successful load, so screens holding their own fetched data (trends, workouts) fetch again.
    var generation = 0

    private var server: URL?
    private var trendCache: [String: Trends] = [:]
    private var workoutCache: [Int: [Workout]] = [:]

    var units: Units { Units(rawValue: status?.settings?.units ?? "") ?? .metric }
    var stepGoal: Double { summary?.stepGoal ?? status?.settings?.stepGoal ?? 10_000 }
    var signInRequired: Bool { phase == .signIn }

    /// Connects to the configured server if it changed since the last start.
    func startIfNeeded() async {
        // Also when /auth/me never succeeded (offline at launch): until then the sign-in mode is unknown.
        if server != Config.serverURL() || phase == .starting || authMode == nil { await start() }
    }

    func start() async {
        guard let client = APIClient.current() else {
            phase = .noServer
            return
        }
        if server != client.base {
            server = client.base
            clearData()
            if let cached = SummaryCache.load(for: client.base) {
                summary = cached.summary
                status = cached.status
            }
        }
        do {
            let auth = try await client.authState()
            authMode = auth.mode
            usesAccounts = auth.usesAccounts
            account = auth.user
            switch auth.mode {
            case "open": phase = .ready
            case "required": phase = auth.authenticated ? .ready : .signIn
            default: phase = .unavailable("Sign-in isn't set up on \(client.base.host ?? "the server") yet.")
            }
        } catch {
            // Offline: keep showing the last summary if there is one.
            phase = summary == nil ? .unavailable(error.localizedDescription) : .ready
            self.error = error.localizedDescription
            return
        }
        if phase == .ready { await load() }
    }

    func load() async {
        guard let client = APIClient.current() else { return }
        loading = true
        defer { loading = false }
        do {
            async let s = client.summary(date: date)
            async let st = client.status()
            let (summary, status) = try await (s, st)
            self.summary = summary
            self.status = status
            error = nil
            if case .unavailable = phase { phase = .ready }
            trendCache = [:]
            workoutCache = [:]
            generation += 1
            if date == nil { SummaryCache.save(summary: summary, status: status, for: client.base) }
        } catch APIError.signInRequired {
            phase = .signIn
        } catch {
            self.error = error.localizedDescription
        }
    }


    func signIn(email: String, password: String) async throws {
        guard let client = APIClient.current() else { throw APIError.network("Enter the server address in Settings.") }
        try await client.signIn(email: email, password: password)
        Config.lastEmail = email
        if let auth = try? await client.authState() {
            authMode = auth.mode
            usesAccounts = auth.usesAccounts
            account = auth.user
        }
        phase = .ready
        await load()
    }

    func join(code: String, name: String, email: String, password: String) async throws {
        guard let client = APIClient.current() else { throw APIError.network("Enter the server address in Settings.") }
        try await client.acceptInvite(code: code, email: email, name: name, password: password)
        Config.lastEmail = email
        account = (try? await client.authState())?.user
        phase = .ready
        await load()
    }

    func signOut() async {
        if let client = APIClient.current() {
            await client.signOut()
            SummaryCache.clear(for: client.base)
        }
        clearData()
        account = nil
        phase = .signIn
    }

    func show(date newDate: String?) async {
        date = newDate == summary?.today ? nil : newDate
        await load()
    }

    func open(_ section: TrendsSection) {
        trendsSection = section
        tab = .trends
    }

    func trends(_ metrics: [String], days: Int) async throws -> Trends {
        let key = "\(metrics.joined(separator: ","))|\(days)"
        if let hit = trendCache[key] { return hit }
        guard let client = APIClient.current() else { throw APIError.network("No server configured.") }
        do {
            let t = try await client.trends(metrics, days: days)
            trendCache[key] = t
            return t
        } catch APIError.signInRequired {
            phase = .signIn
            throw APIError.signInRequired
        }
    }

    func workouts(days: Int) async throws -> [Workout] {
        if let hit = workoutCache[days] { return hit }
        guard let client = APIClient.current() else { throw APIError.network("No server configured.") }
        let w = try await client.workouts(days: days)
        workoutCache[days] = w
        return w
    }

    private func clearData() {
        summary = nil
        status = nil
        date = nil
        error = nil
        trendCache = [:]
        workoutCache = [:]
    }
}

/// The last summary from each server, so the app opens with numbers on screen even offline.
/// Health data, so it stays in the app's container with full file protection.
enum SummaryCache {
    private struct Entry: Codable {
        let summary: Summary
        let status: ServerStatus?
    }

    private static func file(for base: URL) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("summary-\(hashId(base.absoluteString)).json")
    }

    static func load(for base: URL) -> (summary: Summary, status: ServerStatus?)? {
        guard let data = try? Data(contentsOf: file(for: base)), let e = try? JSONDecoder().decode(Entry.self, from: data) else { return nil }
        return (e.summary, e.status)
    }

    static func save(summary: Summary, status: ServerStatus?, for base: URL) {
        try? JSONEncoder().encode(Entry(summary: summary, status: status)).write(to: file(for: base), options: [.atomic, .completeFileProtection])
    }

    static func clear(for base: URL) { try? FileManager.default.removeItem(at: file(for: base)) }
}
