import Foundation
import Observation
import UIKit

/// The charts of the pages not built in the app yet (TrendsPage, src/pages/Detail.tsx): Vitals, Sleep and Cycle show
/// one each, Body shows Body and Activity.
enum TrendsSection: String, CaseIterable, Identifiable {
    case vitals = "Vitals", sleep = "Sleep", activity = "Activity", body = "Body", cycle = "Cycle"
    var id: String { rawValue }
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
        /// The server has sign-in but it isn't set up (its /auth/me says "misconfigured"): the web's Login says sign-in
        /// isn't available right now (PhaseGate shows it).
        case misconfigured
        /// Can't load: offline with nothing kept on the phone.
        case unavailable(String)
        case ready
    }

    var phase: Phase = .starting {
        didSet {
            // Signed out without Sign out (a session that ran out or was ended elsewhere, none at launch): a token
            // nobody can be told the owner of waits for a sign-in; one whose owner is known goes on (IngestTokenOwner).
            if phase == .signIn, oldValue != .signIn {
                ingestSessionEnded()
                // Asked to sign in, however it came (Sign out, a session that ran out or was ended elsewhere, none at
                // launch): nothing of the last person stays in memory for whoever holds the phone, as the web clears
                // what it loaded on a 401. Their summary, settings, Family board, McFly conversation and photo go;
                // the summary kept on disk stays for their next launch (Sign out removes that too).
                clearData()
                forgetPerson()
            }
            // Signed out, or the server can't be reached: no page stays open on what it showed.
            if phase != .ready, oldValue == .ready { dropPages() }
        }
    }
    var summary: Summary?
    var status: ServerStatus?
    /// nil means today.
    var date: String?
    var loading = false
    /// Shown above the content, e.g. while offline with a cached summary on screen.
    var error: String?
    // Navigation (Shell/Navigation.swift).
    /// The tab showing. Asking for `.settings` opens Profile under More, as the web's #/settings does.
    var tab: AppTab = .home {
        didSet {
            if tab == .settings {
                tab = .more
                paths[.more] = [.profile]
            }
        }
    }
    /// The pages each tab has pushed over its own, the top one last.
    var paths: [AppTab: [AppRoute]] = [:]
    /// The last link to each tab's own page, for its query (Body's tab=activity).
    var requests: [AppPage: RouteRequest] = [:]
    var requestCount = 0
    /// A page of the server's website showing over the app, until it's closed.
    var webPage: WebPage?
    /// The account menu ("Your workspace") is up, from any page's avatar (Shell/AccountMenu.swift).
    var accountMenuOpen = false
    /// A metric's detail sheet showing over the app (`showMetric`, Shell/MetricRequest.swift).
    var metricSheet: MetricRequest?
    /// The chart pages' range in days (RangeFilters), shared by Vitals, Body and Sleep as the web shares it in a
    /// session (useRange): 30 to start with; 1 is Day. Memory only.
    var rangeDays = 30
    /// The welcome flow asked for again (#/welcome: Profile's Edit preferences), until it's closed (Shell/Welcome.swift).
    var welcomeEditing = false
    /// A new account's welcome put off for this session: only the stub offers it, until slice A builds the flow.
    var onboardingPutOff = false
    /// Ask McFly's conversation, for the Home pill's sheet and the page under More alike. In memory only, and gone with
    /// a sign-out, another person's sign-in or another server.
    let mcfly: McFlyChat
    /// What this server can do for the person signed in (Shell/Availability.swift): own AI keys, estimates, voice
    /// notes, portraits, reading lab reports, Ask McFly. Gone with them too.
    let availability: Availability
    /// "open" (no sign-in, e.g. a local server) or "required" (the hosted dashboard).
    var authMode: String?
    /// The server signs in with email and password (per-person accounts), not a password alone.
    var usesAccounts = false
    /// Who's signed in, on servers with accounts.
    var account: AuthState.User?
    /// Goes up after every successful load, so screens holding their own fetched data (trends, workouts) fetch again.
    var generation = 0
    /// The server's data version behind what's on screen (nil: unknown, so the next check reloads).
    private(set) var dataVersion: String?
    /// The phone's local date when today's summary was loaded, so the first check after midnight reloads.
    private var loadedOn: String?

    private var server: URL?
    private var trendCache: [String: Trends] = [:]
    private var workoutCache: [Int: [Workout]] = [:]
    // Newer endpoints. A cached nil means the server doesn't have it (404), so it isn't asked again until the next load.
    private var dayCache: [String: DayData?] = [:]
    private var cycleCache: [Int: CycleData?] = [:]
    /// By days, insights and what the person sees, so a reply read in one mode never shows in another. Memory only.
    private var nutritionCache: [String: NutritionData?] = [:]
    private var sleepCache: [Int: SleepTiming?] = [:]
    private var patternsCache: Patterns?? = .none
    private var digestCache: DigestReply?? = .none

    // The Family board lives apart from the caches a load clears: other people's changes don't move your data
    // version, so it's re-read on its own schedule (opening the tab, returning to the app, every few minutes
    // while it's on screen, pull to refresh). Memory only: never written to disk.
    /// The last board read; nil before the first read, or when the server has no Family board (`familyMissing`).
    private(set) var familyBoard: FamilyBoard?
    /// The server answered 404 for GET /api/family: it predates the Family board.
    private(set) var familyMissing = false
    /// The last read failed (offline, server error); what's on screen stays.
    private(set) var familyError: String?
    private(set) var familyLoading = false
    /// When the board on screen was read; nil means the next look reads it again.
    private(set) var familyReadAt: Date?
    /// Avatars by "id|version", only for people on the board; a cached nil means there's none to show.
    private(set) var familyAvatarCache: [String: Data?] = [:]
    /// The one-time Family notice was dismissed here, before the server's status says so.
    private(set) var familyNoticeDismissed = false
    /// Counts board reads, so a slower, older one can't replace a newer one (or land after a sign-out).
    private var familyRequest = 0

    /// Whose account the ingest token sends to, and whether the sync waits for a sign-in, as Profile shows it.
    private(set) var ingestOwner: IngestTokenOwner
    /// Where the token and its owner are kept: the app passes the Keychain's.
    private let tokenStore: IngestTokenStore
    /// The time zone sent this session, so a server that keeps another one isn't sent it on every load.
    private var timeZoneSent: String?

    init(tokenStore: IngestTokenStore = MemoryTokenStore()) {
        self.tokenStore = tokenStore
        ingestOwner = tokenStore.owner
        let chat = McFlyChat()
        mcfly = chat
        availability = Availability(chat: chat)
    }

    var units: Units { Units(rawValue: status?.settings?.units ?? "") ?? .metric }
    var stepGoal: Double { summary?.stepGoal ?? status?.settings?.stepGoal ?? 10_000 }
    /// Cycle tracking is on (set on the web or in Profile): the Cycle card, the Cycle page and GET /api/cycle.
    var cycleTrackingOn: Bool { status?.settings?.cycleTracking == true }
    /// What the person chose to see of their nutrition, or nil while Nutrition is off (or the server has none).
    var nutritionMode: NutritionMode? {
        guard status?.settings?.nutrition == true, let numbers = status?.settings?.nutritionNumbers else { return nil }
        return NutritionMode(rawValue: numbers)
    }
    /// Nutrition is on, with a choice of what to see: the Nutrition tab's screen and GET /api/nutrition.
    var nutritionOn: Bool { nutritionMode != nil }
    var signInRequired: Bool { phase == .signIn }
    /// The server has the Family board: its status names the setting, or the board itself was read.
    var familyAvailable: Bool { status?.settings?.familySharing != nil || familyBoard != nil }
    /// Show the one-time "your family can see your status" note on Today. Not without sign-in: no one else is on
    /// the board there, and Profile has no Family section to change.
    var showsFamilyNotice: Bool {
        status?.settings?.familySharing == true && status?.settings?.familyNoticeSeen == false && !familyNoticeDismissed && authMode != "open"
    }
    /// What the Family tab shows now.
    var familyDisplay: FamilyDisplay {
        FamilyDisplay.resolve(authMode: authMode, phase: phase, sharing: status?.settings?.familySharing, board: familyBoard,
                              missing: familyMissing, error: familyError)
    }

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
            // Another server, not the first connect at launch (which a tapped notification's page may already be
            // waiting for): nothing pushed stays open on what the last one showed.
            if server != nil { dropPages() }
            server = client.base
            clearData()
            if let cached = SummaryCache.load(for: client.base) {
                summary = cached.summary
                status = cached.status
                dataVersion = cached.version
                loadedOn = cached.loadedOn
            }
        }
        do {
            apply(auth: try await client.authState(), host: client.base.host)
        } catch is CancellationError {
            return
        } catch {
            // Offline: keep showing the last summary if there is one.
            phase = summary == nil ? .unavailable(error.localizedDescription) : .ready
            self.error = error.localizedDescription
            return
        }
        if phase == .ready { await refreshIfChanged(includeStatus: true) }
    }

    /// What /auth/me said at the start: the sign-in mode, who's signed in, and so the phase.
    func apply(auth: AuthState, host: String?) {
        authMode = auth.mode
        usesAccounts = auth.usesAccounts
        account = auth.user
        switch auth.mode {
        case "open": phase = .ready
        case "required":
            phase = auth.authenticated ? .ready : .signIn
            // Every time, not only on the way into .signIn: the sign-in screen may be up already from a 401 that came
            // while the sign-in mode wasn't known (offline at launch), when the token's owner wasn't looked at.
            if !auth.authenticated { ingestSessionEnded() }
        default: phase = .misconfigured
        }
        // Signed in at launch (the first launch after an update included): a token with no known owner is theirs.
        checkIngestToken(signedInAs: account)
    }

    /// Reloads only when the server's data changed since what's on screen, or the day rolled over. Runs on open, on
    /// return to the app, after syncs and every minute while the app is open. `includeStatus` also refreshes
    /// settings and the photo, which the data version doesn't cover (not on the minute timer).
    func refreshIfChanged(includeStatus: Bool) async {
        guard phase == .ready, !loading, let client = APIClient.current() else { return }
        guard UIApplication.shared.applicationState == .active else { return }
        let version: String?
        do {
            version = try await client.dataVersion()
        } catch APIError.signInRequired {
            phase = .signIn
            return
        } catch {
            // Offline: keep what's on screen; the next check tries again.
            return
        }
        let rolledOver = date == nil && loadedOn != Day.today()
        // A server without /version can't say whether anything changed: reload on open, return and after syncs,
        // but not every minute.
        if version == nil, !includeStatus, !rolledOver, summary != nil { return }
        if summary == nil || version == nil || version != dataVersion || rolledOver {
            await load(knownVersion: version)
        } else if includeStatus, let status = try? await client.status() {
            apply(status: status)
            if date == nil, let summary { SummaryCache.save(summary: summary, status: status, version: dataVersion, loadedOn: loadedOn, for: client.base) }
            if await statusRead() { await load() }
        }
    }

    /// Downloads the summary and status. Pull to refresh and changing day call it directly.
    func load(knownVersion: String?? = .none) async {
        guard await download(knownVersion: knownVersion) else { return }
        // The server's "today" moved with the time zone sent: read the day again, once (a zone is sent once).
        if await statusRead() { await download(knownVersion: .none) }
    }

    /// One read of the summary and status; true when it came.
    @discardableResult
    private func download(knownVersion: String??) async -> Bool {
        guard let client = APIClient.current() else { return false }
        loading = true
        defer { loading = false }
        do {
            async let s = client.summary(date: date)
            async let st = client.status()
            // Read before (or with) the data, so a change landing mid-load still shows up on the next check.
            let version: String?
            if let knownVersion { version = knownVersion } else { version = try? await client.dataVersion() }
            let (summary, status) = try await (s, st)
            self.summary = summary
            apply(status: status)
            error = nil
            if case .unavailable = phase { phase = .ready }
            clearCaches()
            availability.loadedAgain()
            // Your own tile changed with your data: read the board again next time, keeping it on screen until then.
            familyReadAt = nil
            generation += 1
            dataVersion = version
            if date == nil {
                loadedOn = Day.today()
                SummaryCache.save(summary: summary, status: status, version: version, loadedOn: loadedOn, for: client.base)
            }
            return true
        } catch APIError.signInRequired {
            phase = .signIn
        } catch is CancellationError {
            // Interrupted, not failed: what's on screen stays, and the next check loads it.
        } catch {
            self.error = error.localizedDescription
        }
        return false
    }

    /// After every status read, never a settings change's own answer: who's signed in against the ingest token's
    /// owner, then the time zone. True when the server's "today" moved, so the caller reads the day again.
    private func statusRead() async -> Bool {
        checkIngestToken(signedInAs: status?.user?.id != nil ? status?.user : account)
        return await followTimeZone()
    }


    func signIn(email: String, password: String) async throws {
        guard let client = APIClient.current() else { throw APIError.network("Enter the server address in Profile.") }
        try await client.signIn(email: email, password: password)
        await sessionStarted(email: email)
    }

    func join(code: String, name: String, email: String, password: String) async throws {
        guard let client = APIClient.current() else { throw APIError.network("Enter the server address in Profile.") }
        try await client.acceptInvite(code: code, email: email, name: name, password: password)
        await sessionStarted(email: email, newAccount: true)
    }

    /// The server just sent a session cookie for `email`: a sign-in, a new account from an invite, or a new password
    /// from a reset link (POST /auth/reset, slice A). Who it is and the sign-in mode are read again, the ingest token is
    /// checked against them, and the dashboard loads as theirs.
    func sessionStarted(email: String, newAccount: Bool = false) async {
        let auth = try? await APIClient.current()?.authState()
        if let auth {
            authMode = auth.mode
            usesAccounts = auth.usesAccounts
        }
        // Before the email is replaced: an older build's token not looked at yet (the sign-in screen came up before
        // the sign-in mode was known) is the email signed in with before this one's. A new account never keeps the
        // token here (IngestTokenOwner), so it needs no look.
        if !newAccount { ingestSessionEnded(signingIn: true) }
        tokenStore.lastEmail = email
        // Never the last person's, when the server can't say just now: the first status read says who it is.
        account = auth?.user
        signedIn(newAccount: newAccount)
        await load()
    }

    /// A new session (sign-in or a new account from an invite), maybe as someone else after the last one expired:
    /// nothing of the last person's Family board, photos or dismissed notice carries over, and the ingest token is
    /// checked against who it is. The pages open stay: the last person's went when the sign-in screen came (leaving
    /// .ready), so any open now were opened since, by whoever is signing in (a tapped digest's Insights).
    func signedIn(newAccount: Bool = false) {
        resetFamily()
        forgetPerson()
        timeZoneSent = nil
        phase = .ready
        checkIngestToken(signedInAs: account, newAccount: newAccount)
    }

    func signOut() async {
        ingestSignedOut()
        if let client = APIClient.current() {
            await client.signOut()
            SummaryCache.clear(for: client.base)
        }
        clearData()
        forgetPerson()
        account = nil
        phase = .signIn
        // Back to Home with nothing open, as the web reloads to its sign-in page.
        resetNavigation()
    }

    /// What the app keeps of the person signed in beyond their data: the McFly conversation, what the server can do
    /// for them, the profile photo kept in Caches, and what's open over the app for them (a metric, the welcome).
    private func forgetPerson() {
        mcfly.forget()
        availability.forget()
        ProfileImages.clear()
        metricSheet = nil
        welcomeEditing = false
        onboardingPutOff = false
    }

    func show(date newDate: String?) async {
        date = newDate == summary?.today ? nil : newDate
        await load()
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

    // The accessors below return nil when the server doesn't have the feature (an older server): hide it, no error.
    // They throw only for real failures (offline, server errors).

    /// One day by hour; nil date means today.
    func day(date: String?) async throws -> DayData? {
        let key = date ?? "today"
        if let hit = dayCache[key] { return hit }
        let d = try await fetch { try await $0.day(date: date) }
        dayCache[key] = d
        return d
    }

    /// The cycle view over the last `days` days; nil without asking while cycle tracking is off.
    func cycle(days: Int = 120) async throws -> CycleData? {
        guard cycleTrackingOn else { return nil }
        if let hit = cycleCache[days] { return hit }
        let c = try await fetch { try await $0.cycle(days: days) }
        let shown = c?.enabled == true ? c : nil
        cycleCache[days] = shown
        return shown
    }

    /// Food totals over the last `days` days; nil without asking while Nutrition is off, and nil from a server without it.
    func nutrition(days: Int, insights: Bool = false) async throws -> NutritionData? {
        guard let mode = nutritionMode else { return nil }
        let key = "\(days)|\(insights)|\(mode.rawValue)"
        if let hit = nutritionCache[key] { return hit }
        let n = try await fetch { try await $0.nutrition(days: days, insights: insights) }
        let shown = n?.enabled == true ? n : nil
        nutritionCache[key] = shown
        return shown
    }

    /// The server has Nutrition (its status names the setting), so the Nutrition tab can offer to turn it on.
    var nutritionAvailable: Bool { status?.settings?.nutrition != nil }

    /// The server has the food log (GET /nutrition/log): nil until asked, false when it answered 404 (an older server).
    var foodLogAvailable: Bool?
    /// An entry was saved here before Health was asked about writing food: ask once the sheet closes.
    var foodHealthAskPending = false

    /// The person's time zone (settings.timeZone), where a logged entry's date and time are.
    var timeZone: TimeZone { status?.settings?.timeZone.flatMap(TimeZone.init(identifier:)) ?? .current }

    /// Turns Nutrition on with what the person chose to see (the web's opt-in): the server refuses it without a choice.
    /// The phone starts reading food once a sync hears it's on.
    func turnOnNutrition(_ mode: NutritionMode) async throws {
        try await save(settings: ["nutrition": true, "nutritionNumbers": mode.rawValue])
    }

    /// Sets or clears (nil) one of the person's own targets: "energy_kcal", "protein_g" or "water_ml".
    func setNutritionTarget(_ key: String, _ value: Double?) async throws {
        try await save(settings: ["nutritionTargets": [key: value.map { $0 as Any } ?? NSNull()]])
    }

    func sleepTiming(days: Int) async throws -> SleepTiming? {
        if let hit = sleepCache[days] { return hit }
        let s = try await fetch { try await $0.sleepTiming(days: days) }
        sleepCache[days] = s
        return s
    }

    func patterns() async throws -> Patterns? {
        if let hit = patternsCache { return hit }
        let p = try await fetch { try await $0.patterns() }
        patternsCache = .some(p)
        return p
    }

    /// The weekly digest reply; check `configured` and `digest` before showing it.
    func digest() async throws -> DigestReply? {
        if let hit = digestCache { return hit }
        let d = try await fetch { try await $0.digest() }
        digestCache = .some(d)
        return d
    }

    // MARK: Family

    /// Reads the Family board unless it was read moments ago (`force` always reads). Opening the tab, returning to
    /// the app and the five-minute timer call it; pull to refresh forces it. Failures keep what's on screen.
    func loadFamily(force: Bool = false) async {
        guard phase == .ready else { return }
        if !force {
            if familyLoading { return }
            if let at = familyReadAt, Date().timeIntervalSince(at) < Self.familyFresh { return }
        }
        // A forced read (after a settings change) overtakes one already on its way; only the newest is shown.
        familyRequest += 1
        let request = familyRequest
        familyLoading = true
        defer { if request == familyRequest { familyLoading = false } }
        do {
            let board = try await fetch { try await $0.family() }
            guard request == familyRequest else { return }
            receiveFamily(board)
        } catch is CancellationError {
            // Superseded or the screen went away: not a failure to show.
        } catch {
            guard request == familyRequest else { return }
            if case .signIn = phase { return }
            familyError = error.localizedDescription
        }
    }

    /// Shows a board just read (nil: the server has no Family board).
    func receiveFamily(_ board: FamilyBoard?) {
        familyMissing = board == nil
        familyBoard = board
        familyError = nil
        familyReadAt = Date()
        // Avatars of people no longer on the board (or after sharing went off) go.
        familyAvatarCache = familyAvatarCache.filter { familyShows(avatar: $0.key) }
    }

    /// The board on screen has this person with this photo version ("id|version").
    private func familyShows(avatar key: String) -> Bool {
        guard let board = familyBoard, board.sharing else { return false }
        return board.members.contains { m in m.avatarKey.map { "\(m.id)|\($0)" } == key }
    }

    /// Reads it again shortly: what a look within this many seconds of the last read shows.
    static let familyFresh: TimeInterval = 30
    /// How often an open Family tab reads the board again.
    static let familyRefresh: TimeInterval = 5 * 60

    /// A family member's avatar (PNG), nil when there's none. Cached in memory for this board only.
    func familyAvatar(id: String, version: String) async -> Data? {
        let key = "\(id)|\(version)"
        if let hit = familyAvatarCache[key] { return hit }
        guard let client = APIClient.current() else { return nil }
        do {
            let data = try await client.familyAvatar(id: id, version: version)
            rememberFamilyAvatar(data, id: id, version: version)
            return data
        } catch {
            return nil // offline: the initial shows, and the next look tries again
        }
    }

    /// Keeps a photo only while its person is still on the board: one arriving after sharing went off is shown to no
    /// one and isn't kept.
    func rememberFamilyAvatar(_ data: Data?, id: String, version: String) {
        let key = "\(id)|\(version)"
        if familyShows(avatar: key) { familyAvatarCache[key] = data }
    }

    /// Turns sharing on or off (it's mutual), then reads the board again. Throws so the caller can roll back.
    /// The status the server answers with drops the board from before at once (see `apply(status:)`), so a read
    /// that fails afterwards can't leave everyone on screen.
    func setFamilySharing(_ on: Bool) async throws {
        try await save(settings: ["familySharing": on])
        await loadFamily(force: true)
    }

    /// Shows or hides your cycle phase on your tile; the server keeps it off unless tracking and sharing are on.
    func setShareCyclePhase(_ on: Bool) async throws {
        try await save(settings: ["shareCyclePhase": on])
        if familyBoard?.sharing == true { await loadFamily(force: true) }
    }

    /// The one-time Today note: gone at once, and for good once the server has it.
    func dismissFamilyNotice() async {
        hideFamilyNotice()
        do {
            try await save(settings: ["familyNoticeSeen": true])
        } catch {
            familyNoticeDismissed = false
        }
    }

    func hideFamilyNotice() { familyNoticeDismissed = true }

    // MARK: Time zone

    /// The hosted server runs in UTC: tell it this phone's time zone, so its "today" is the person's (src/App.tsx does it
    /// on every load). After a status read only, and a zone is sent once: a server that took the request and kept its
    /// own zone, or refused it (a 4xx), isn't asked again this session. One that couldn't be reached or failed (a 5xx,
    /// a cold start) is asked on the next read. True when the server now has `zone`. `send` is PUT /api/settings; tests
    /// pass their own.
    func followTimeZone(_ zone: String = TimeZone.current.identifier, send: (@MainActor ([String: Any]) async throws -> ServerStatus)? = nil) async -> Bool {
        guard phase == .ready, let settings = status?.settings, settings.timeZone != zone, timeZoneSent != zone else { return false }
        let send = send ?? { fields in try await self.fetch { try await $0.updateSettings(fields) } }
        timeZoneSent = zone
        do {
            showChanged(try await send(["timeZone": zone]))
        } catch {
            if Self.worthRetrying(error) { timeZoneSent = nil }
            return false
        }
        return status?.settings?.timeZone == zone
    }

    /// The request didn't reach a server that could answer it: offline, cancelled, or a server error (5xx, and the 503
    /// that maps to `misconfigured`). Asking again later may work.
    private static func worthRetrying(_ error: Error) -> Bool {
        if APIClient.isCancellation(error) { return true }
        switch error as? APIError {
        case .network?, .misconfigured?: return true
        case .server(let code, _)?: return code >= 500
        default: return false
        }
    }

    // MARK: Ingest token

    /// The account signed in now, as the token's owner is kept.
    private func ingestAccount(_ user: AuthState.User?) -> IngestTokenOwner.Account? {
        user?.id.map { IngestTokenOwner.Account(server: server?.absoluteString ?? "", id: $0, email: user?.email) }
    }

    /// Who's signed in by what the app knows now: the sign-in's answer, or the last status read's.
    private var signedInUser: AuthState.User? { account?.id != nil ? account : status?.user }

    private func updateIngestOwner(_ change: (inout IngestTokenOwner, Bool) -> Bool) {
        var owner = tokenStore.owner
        let remove = change(&owner, tokenStore.hasToken)
        tokenStore.owner = owner
        if remove { tokenStore.removeToken() }
        ingestOwner = owner
    }

    /// Someone is signed in as `user` (a sign-in, a new account, or a status read): the same account as the token's
    /// resumes the sync, anyone else's removes the token. On a server with accounts and no id yet, nothing changes
    /// until a read says who it is. A server without sign-in doesn't pause, unless the token is another server's.
    func checkIngestToken(signedInAs user: AuthState.User?, newAccount: Bool = false) {
        guard phase == .ready else { return }
        switch authMode {
        case "open":
            let here = server?.absoluteString ?? ""
            updateIngestOwner { owner, _ in
                owner.noSignIn(on: here)
                return false
            }
        case "required":
            if usesAccounts, user?.id == nil, !newAccount { return }
            updateIngestOwner { $0.signedIn(ingestAccount(user), hasToken: $1, newAccount: newAccount) }
        default:
            break
        }
    }

    /// Signing out with the button (offered only while signed in): nothing of this phone's Health data goes up until
    /// someone signs in.
    func ingestSignedOut() {
        guard authMode == "required" else { return }
        let who = ingestAccount(signedInUser)
        let lastEmail = tokenStore.lastEmail
        updateIngestOwner { owner, hasToken in
            owner.signedOut(who, hasToken: hasToken, lastEmail: lastEmail)
            return false
        }
    }

    /// The server with sign-in says there's no session, and Sign out wasn't tapped (IngestTokenOwner.sessionEnded).
    /// `signingIn`: a sign-in just went through, so the server has sign-in even if its mode wasn't known yet.
    func ingestSessionEnded(signingIn: Bool = false) {
        guard authMode == "required" || signingIn else { return }
        let lastEmail = tokenStore.lastEmail
        updateIngestOwner { owner, hasToken in
            owner.sessionEnded(hasToken: hasToken, lastEmail: lastEmail)
            return false
        }
    }

    /// The token was typed, pasted or removed in Profile: it's the signed-in account's, if anyone's.
    func ingestTokenChanged() {
        let who = authMode == "required" && phase == .ready ? ingestAccount(signedInUser) : nil
        updateIngestOwner { owner, hasToken in
            owner.tokenChanged(hasToken: hasToken, signedIn: who)
            return false
        }
    }

    /// The sign-in screen says why this iPhone's Health data isn't going up: the sync waits for a sign-in, with a token.
    var ingestWaitsForSignIn: Bool { ingestOwner.paused && tokenStore.hasToken }

    // MARK: Cards

    /// Both card lists while changes are on their way to the server; nil shows the server's lists.
    private(set) var pendingCards: CardLists?
    /// Card changes sent and not answered yet.
    private var cardChanges = 0
    /// The last card change sent. Each waits for the one before, so they reach the server in the order they were made.
    private var cardQueue: Task<Void, Never>?

    /// The server can hide cards (its status names the list). Older servers can't: every card shows, and Profile
    /// has no Cards section.
    var cardsAvailable: Bool { status?.settings?.hiddenCards != nil }
    /// The cards hidden now (shared/cards.ts ids), changes on their way included. An optional card turned off can be
    /// in it too.
    var hiddenCards: [String] { pendingCards?.hidden ?? status?.settings?.hiddenCards ?? [] }
    /// The optional cards turned on, changes on their way included; nil from a server older than optional cards.
    var shownCards: [String]? { pendingCards.map(\.shown) ?? status?.settings?.shownCards }
    /// The server has optional cards (its status names the list): they're off until turned on. On an older server
    /// they're ordinary cards, on unless hidden.
    var optionalCards: Bool { shownCards != nil }
    /// The cards that don't show now, for the screens to leave out: hidden ones, and optional ones not turned on.
    var cardsOff: Set<String> { Cards.off(hidden: hiddenCards, shown: shownCards) }
    func cardShown(_ id: String) -> Bool { Cards.shows(id, hidden: hiddenCards, shown: shownCards) }

    /// Shows or hides one card (Profile → Cards). Throws when the server refuses, after the switch went back.
    func setCard(_ id: String, shown: Bool) async throws { try await changeCards(.card(id, shown: shown)) }

    /// Every default card back on (the web's Show all). The optional cards stay as they are: the list sent keeps the
    /// ones that are off.
    func showAllCards() async throws { try await changeCards(.list(Cards.afterShowAll(hiddenCards, optionalCards: optionalCards))) }

    /// Shows a change at once, then sends it after any still on their way (the web's useCardEditor). When the last
    /// one is answered the screens follow the server's lists, so a refused change goes back. `send` is PUT
    /// /api/settings; tests pass their own.
    func changeCards(_ change: CardChange, send: (@MainActor ([String: Any]) async throws -> ServerStatus)? = nil) async throws {
        let send = send ?? { fields in try await self.fetch { try await $0.updateSettings(fields) } }
        pendingCards = change.applied(to: CardLists(hidden: hiddenCards, shown: shownCards))
        cardChanges += 1
        defer {
            cardChanges -= 1
            if cardChanges == 0 { pendingCards = nil }
        }
        let previous = cardQueue
        let work = Task { @MainActor in
            await previous?.value
            var status = try await send(change.body)
            // A server from before one-card changes ignored it: the same change again, as the whole list.
            if let retry = change.retry(stored: status.settings?.hiddenCards) { status = try await send(retry.body) }
            showChanged(status)
        }
        cardQueue = Task { _ = try? await work.value }
        try await work.value
    }

    // MARK: Settings

    /// Saves settings the way every page does (PUT /api/settings), e.g. ["perspective": "portrait"] or ["units":
    /// "imperial", "stepGoal": 8000]: the status the server answers with shows at once, and is kept with today's
    /// summary for the next launch. Throws the server's refusal ("Choose what to show before turning nutrition on."),
    /// with nothing saved. An older server ignores keys it doesn't know and still answers with its status, so check the
    /// answer, never that the save went through: a feature shows only where the status names its setting (onboarding
    /// and "Edit preferences" only where settings.perspective is present).
    ///
    /// `reload`: the change moves what the data shows (units, name, step goal, demo data), so the summary is read again.
    /// Card changes go through `changeCards`, which keeps them in order. `send` is the request; tests pass their own.
    @discardableResult
    func save(settings fields: [String: Any], reload: Bool = false,
              send: (@MainActor ([String: Any]) async throws -> ServerStatus)? = nil) async throws -> ServerStatus {
        let send = send ?? { fields in try await self.fetch { try await $0.updateSettings(fields) } }
        let status = try await send(fields)
        showChanged(status)
        if reload { await load() }
        return status
    }

    /// Shows a status the server answered a change with (PUT /api/settings, or another write that answers with the
    /// status), and keeps it with today's summary for the next launch. Not after a plain read: that's `apply(status:)`.
    func showChanged(_ status: ServerStatus) {
        apply(status: status)
        if date == nil, let summary, let client = APIClient.current() {
            SummaryCache.save(summary: summary, status: status, version: dataVersion, loadedOn: loadedOn, for: client.base)
        }
    }

    /// Shows a status from the server: settings, the photo, and whether you share with family.
    func apply(status: ServerStatus) {
        let before = self.status?.settings
        self.status = status
        // What the person sees, or their targets, changed: no reply read before may show again.
        let after = status.settings
        if before?.nutrition != after?.nutrition || before?.nutritionNumbers != after?.nutritionNumbers || before?.nutritionTargets != after?.nutritionTargets {
            nutritionCache = [:]
        }
        // Cycle tracking turned on (on the web): the next Sync asks Health for those types, then sends their history.
        if let on = status.settings?.cycleTracking { Config.cycleTracking = on }
        // Sharing changed (here, on the web or on another phone) since the board was read: that board, and the photos
        // on it, go at once, so turned off nobody stays on screen, offline or not. The next look reads it again.
        if let on = status.settings?.familySharing, let board = familyBoard, board.sharing != on { dropFamilyBoard() }
    }

    func fetch<T>(_ request: (APIClient) async throws -> T) async throws -> T {
        guard let client = APIClient.current() else { throw APIError.network("No server configured.") }
        do {
            return try await request(client)
        } catch APIError.signInRequired {
            phase = .signIn
            throw APIError.signInRequired
        }
    }

    private func clearCaches() {
        trendCache = [:]
        workoutCache = [:]
        dayCache = [:]
        cycleCache = [:]
        nutritionCache = [:]
        sleepCache = [:]
        patternsCache = .none
        digestCache = .none
    }

    private func clearData() {
        summary = nil
        status = nil
        date = nil
        error = nil
        dataVersion = nil
        loadedOn = nil
        foodLogAvailable = nil
        timeZoneSent = nil
        clearCaches()
        resetFamily()
        // Another server's conversation, or nobody's yet: it doesn't carry over, and nor does what it could do.
        mcfly.forget()
        availability.forget()
    }

    /// Forgets the board and its photos; a read already on its way is dropped when it lands.
    private func dropFamilyBoard() {
        familyBoard = nil
        familyError = nil
        familyReadAt = nil
        familyAvatarCache = [:]
        familyRequest += 1
        familyLoading = false
    }

    /// Everything Family for this person, for a sign-out, another server or another person signing in.
    private func resetFamily() {
        dropFamilyBoard()
        familyMissing = false
        familyNoticeDismissed = false
    }
}

/// What the Family tab shows, first match wins.
enum FamilyDisplay {
    /// The server has no sign-in (a local one): the board needs a person per account.
    case needsAccounts
    /// You turned sharing off (here or anywhere else): you see no one, whatever was read before.
    case sharingOff
    case board(FamilyBoard)
    /// The server predates the Family board.
    case missing
    /// The read failed and there's nothing to keep on screen.
    case failed(String)
    /// The dashboard can't load at all (sign-in isn't set up on the server, or it can't be reached): nothing will be
    /// read until that's fixed, so say why instead of spinning.
    case unavailable(String)
    case loading

    static func resolve(authMode: String?, phase: Dashboard.Phase, sharing: Bool?, board: FamilyBoard?, missing: Bool, error: String?) -> FamilyDisplay {
        if authMode == "open" { return .needsAccounts }
        if sharing == false { return .sharingOff }
        if let board { return board.sharing ? .board(board) : .sharingOff }
        if missing { return .missing }
        if let error { return .failed(error) }
        if case .unavailable(let message) = phase { return .unavailable(message) }
        return .loading
    }
}

/// The last summary from each server, so the app opens with numbers on screen even offline.
/// Health data, so it stays in the app's container with full file protection.
enum SummaryCache {
    private struct Entry: Codable {
        let summary: Summary
        var status: ServerStatus?
        var version: String?
        var loadedOn: String?
        /// Which build wrote it (`format`); nil from builds before it was kept.
        var format: Int?
    }

    /// 2: settings.shownCards is kept, so a cached status without it is from a server older than optional cards.
    private static let format = 2

    /// Where one server's is kept; tests write an older build's there.
    static func file(for base: URL) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("summary-\(hashId(base.absoluteString)).json")
    }

    static func load(for base: URL) -> (summary: Summary, status: ServerStatus?, version: String?, loadedOn: String?)? {
        guard let data = try? Data(contentsOf: file(for: base)), var e = try? JSONDecoder().decode(Entry.self, from: data) else { return nil }
        // Cached by a build that never kept shownCards, so it can't say whether the server has optional cards. The
        // hosted one has them: take it that they're off there until the first status read says, or they'd show on the
        // first launch after the update, then go (or stay, offline). Any other server (a Mac or LAN one) may be older
        // than optional cards, so it keeps the older rule, every card on unless hidden, as before the update.
        if e.format == nil, e.status?.hosted == true, e.status?.settings?.hiddenCards != nil, e.status?.settings?.shownCards == nil {
            e.status?.settings?.shownCards = []
        }
        return (e.summary, e.status, e.version, e.loadedOn)
    }

    static func save(summary: Summary, status: ServerStatus?, version: String?, loadedOn: String?, for base: URL) {
        let entry = Entry(summary: summary, status: status, version: version, loadedOn: loadedOn, format: format)
        try? JSONEncoder().encode(entry).write(to: file(for: base), options: [.atomic, .completeFileProtection])
    }

    static func clear(for base: URL) { try? FileManager.default.removeItem(at: file(for: base)) }
}
