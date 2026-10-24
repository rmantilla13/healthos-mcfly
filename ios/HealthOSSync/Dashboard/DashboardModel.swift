import Foundation
import Observation
import UIKit

/// The tab bar's tabs. `settings` isn't one: asking for it opens Settings as a sheet over the tab showing (the gear on
/// each tab, Today's avatar, every "Open Settings").
enum AppTab: Hashable { case today, family, trends, nutrition, insights, settings }

enum TrendsSection: String, CaseIterable, Identifiable {
    case vitals = "Vitals", sleep = "Sleep", activity = "Activity", body = "Body", cycle = "Cycle"
    var id: String { rawValue }

    /// Web pages an insight can link to.
    init?(page: String) {
        switch page {
        case "vitals": self = .vitals
        case "sleep": self = .sleep
        case "activity": self = .activity
        case "body": self = .body
        case "cycle": self = .cycle
        default: return nil
        }
    }

    /// The sections to offer: Cycle only while cycle tracking is on.
    static func visible(cycleTracking: Bool) -> [TrendsSection] {
        cycleTracking ? allCases : allCases.filter { $0 != .cycle }
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
    var tab: AppTab = .today {
        didSet {
            // Settings opens over the tab that asked for it, which stays selected underneath.
            if tab == .settings {
                tab = oldValue == .settings ? .today : oldValue
                showingSettings = true
            }
        }
    }
    /// The Settings sheet is up.
    var showingSettings = false
    var trendsSection: TrendsSection = .vitals
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

    /// Whose account the ingest token sends to, and whether the sync waits for a sign-in, as Settings shows it.
    private(set) var ingestOwner: IngestTokenOwner
    /// Where the token and its owner are kept: the app passes the Keychain's.
    private let tokenStore: IngestTokenStore
    /// The time zone sent this session, so a server that keeps another one isn't sent it on every load.
    private var timeZoneSent: String?

    init(tokenStore: IngestTokenStore = MemoryTokenStore()) {
        self.tokenStore = tokenStore
        ingestOwner = tokenStore.owner
    }

    var units: Units { Units(rawValue: status?.settings?.units ?? "") ?? .metric }
    var stepGoal: Double { summary?.stepGoal ?? status?.settings?.stepGoal ?? 10_000 }
    /// Cycle tracking is on (set on the web or in Settings): the Cycle card, the Cycle trends section and GET /api/cycle.
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
    /// the board there, and Settings has no Family section to change.
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
            let auth = try await client.authState()
            authMode = auth.mode
            usesAccounts = auth.usesAccounts
            account = auth.user
            switch auth.mode {
            case "open": phase = .ready
            case "required": phase = auth.authenticated ? .ready : .signIn
            default: phase = .unavailable("Sign-in isn't set up on \(client.base.host ?? "the server") yet.")
            }
            // Signed in at launch (the first launch after an update included): a token with no known owner is theirs.
            checkIngestToken(signedInAs: account?.id)
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
        checkIngestToken(signedInAs: status?.user?.id ?? account?.id)
        return await followTimeZone()
    }


    func signIn(email: String, password: String) async throws {
        guard let client = APIClient.current() else { throw APIError.network("Enter the server address in Settings.") }
        try await client.signIn(email: email, password: password)
        Config.lastEmail = email
        let auth = try? await client.authState()
        if let auth {
            authMode = auth.mode
            usesAccounts = auth.usesAccounts
        }
        // Never the last person's, when the server can't say just now: the first status read says who it is.
        account = auth?.user
        signedIn()
        await load()
    }

    func join(code: String, name: String, email: String, password: String) async throws {
        guard let client = APIClient.current() else { throw APIError.network("Enter the server address in Settings.") }
        try await client.acceptInvite(code: code, email: email, name: name, password: password)
        Config.lastEmail = email
        account = (try? await client.authState())?.user
        signedIn(newAccount: true)
        await load()
    }

    /// A new session (sign-in or a new account from an invite), maybe as someone else after the last one expired:
    /// nothing of the last person's Family board, photos or dismissed notice carries over, and the ingest token is
    /// checked against who it is.
    func signedIn(newAccount: Bool = false) {
        resetFamily()
        timeZoneSent = nil
        phase = .ready
        checkIngestToken(signedInAs: account?.id, newAccount: newAccount)
    }

    func signOut() async {
        ingestSignedOut()
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
        trendsSection = section == .cycle && !cycleTrackingOn ? .vitals : section
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
        try await updateSettings(["nutrition": true, "nutritionNumbers": mode.rawValue])
    }

    /// Sets or clears (nil) one of the person's own targets: "energy_kcal", "protein_g" or "water_ml".
    func setNutritionTarget(_ key: String, _ value: Double?) async throws {
        try await updateSettings(["nutritionTargets": [key: value.map { $0 as Any } ?? NSNull()]])
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
        try await updateSettings(["familySharing": on])
        await loadFamily(force: true)
    }

    /// Shows or hides your cycle phase on your tile; the server keeps it off unless tracking and sharing are on.
    func setShareCyclePhase(_ on: Bool) async throws {
        try await updateSettings(["shareCyclePhase": on])
        if familyBoard?.sharing == true { await loadFamily(force: true) }
    }

    /// The one-time Today note: gone at once, and for good once the server has it.
    func dismissFamilyNotice() async {
        hideFamilyNotice()
        do {
            try await updateSettings(["familyNoticeSeen": true])
        } catch {
            familyNoticeDismissed = false
        }
    }

    func hideFamilyNotice() { familyNoticeDismissed = true }

    // MARK: Time zone

    /// The hosted server runs in UTC: tell it this phone's time zone, so its "today" is the person's (src/App.tsx does it
    /// on every load). After a status read only, and a zone is sent once: a server that answered and kept its own zone
    /// isn't asked again this session. One that couldn't be reached is asked on the next read. True when the server
    /// now has `zone`. `send` is PUT /api/settings; tests pass their own.
    func followTimeZone(_ zone: String = TimeZone.current.identifier, send: (@MainActor ([String: Any]) async throws -> ServerStatus)? = nil) async -> Bool {
        guard phase == .ready, let settings = status?.settings, settings.timeZone != zone, timeZoneSent != zone else { return false }
        let send = send ?? { fields in try await self.fetch { try await $0.updateSettings(fields) } }
        timeZoneSent = zone
        do {
            show(settings: try await send(["timeZone": zone]))
        } catch {
            if APIClient.isCancellation(error) { timeZoneSent = nil }
            if case .network? = error as? APIError { timeZoneSent = nil }
            return false
        }
        return status?.settings?.timeZone == zone
    }

    // MARK: Ingest token

    /// The account signed in now, as the token's owner is kept.
    private func ingestAccount(_ id: String?) -> IngestTokenOwner.Account? {
        id.map { IngestTokenOwner.Account(server: server?.absoluteString ?? "", id: $0) }
    }

    private func updateIngestOwner(_ change: (inout IngestTokenOwner, Bool) -> Bool) {
        var owner = tokenStore.owner
        let remove = change(&owner, tokenStore.hasToken)
        tokenStore.owner = owner
        if remove { tokenStore.removeToken() }
        ingestOwner = owner
    }

    /// Someone is signed in as `id` (a sign-in, a new account, or a status read): the same account as the token's
    /// resumes the sync, anyone else's removes the token. On a server with accounts and no id yet, nothing changes
    /// until a read says who it is. A server without sign-in never pauses.
    func checkIngestToken(signedInAs id: String?, newAccount: Bool = false) {
        guard phase == .ready else { return }
        switch authMode {
        case "open":
            updateIngestOwner { owner, _ in
                owner.noSignIn()
                return false
            }
        case "required":
            if usesAccounts, id == nil, !newAccount { return }
            updateIngestOwner { $0.signedIn(ingestAccount(id), hasToken: $1, newAccount: newAccount) }
        default:
            break
        }
    }

    /// Signing out: nothing of this phone's Health data goes up until someone signs in.
    func ingestSignedOut() {
        guard authMode == "required" else { return }
        let who = ingestAccount(account?.id ?? status?.user?.id)
        updateIngestOwner { owner, hasToken in
            owner.signedOut(who, hasToken: hasToken)
            return false
        }
    }

    /// The token was typed, pasted or removed in Settings: it's the signed-in account's, if anyone's.
    func ingestTokenChanged() {
        let who = authMode == "required" && phase == .ready ? ingestAccount(account?.id ?? status?.user?.id) : nil
        updateIngestOwner { owner, hasToken in
            owner.tokenChanged(hasToken: hasToken, signedIn: who)
            return false
        }
    }

    // MARK: Cards

    /// Both card lists while changes are on their way to the server; nil shows the server's lists.
    private(set) var pendingCards: CardLists?
    /// Card changes sent and not answered yet.
    private var cardChanges = 0
    /// The last card change sent. Each waits for the one before, so they reach the server in the order they were made.
    private var cardQueue: Task<Void, Never>?

    /// The server can hide cards (its status names the list). Older servers can't: every card shows, and Settings
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

    /// Shows or hides one card (Settings → Cards). Throws when the server refuses, after the switch went back.
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
            show(settings: status)
        }
        cardQueue = Task { _ = try? await work.value }
        try await work.value
    }

    /// PUT /api/settings, then shows the status it answers with.
    private func updateSettings(_ fields: [String: Any]) async throws {
        show(settings: try await fetch { try await $0.updateSettings(fields) })
    }

    /// Shows the status a settings change answered with, and keeps it with today's summary for the next launch.
    private func show(settings status: ServerStatus) {
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
        if !cycleTrackingOn, trendsSection == .cycle { trendsSection = .vitals }
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
        let status: ServerStatus?
        var version: String?
        var loadedOn: String?
    }

    private static func file(for base: URL) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("summary-\(hashId(base.absoluteString)).json")
    }

    static func load(for base: URL) -> (summary: Summary, status: ServerStatus?, version: String?, loadedOn: String?)? {
        guard let data = try? Data(contentsOf: file(for: base)), let e = try? JSONDecoder().decode(Entry.self, from: data) else { return nil }
        return (e.summary, e.status, e.version, e.loadedOn)
    }

    static func save(summary: Summary, status: ServerStatus?, version: String?, loadedOn: String?, for base: URL) {
        try? JSONEncoder().encode(Entry(summary: summary, status: status, version: version, loadedOn: loadedOn)).write(to: file(for: base), options: [.atomic, .completeFileProtection])
    }

    static func clear(for base: URL) { try? FileManager.default.removeItem(at: file(for: base)) }
}
