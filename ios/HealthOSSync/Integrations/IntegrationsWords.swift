import Foundation

/// Integrations' words and the rules for what each card shows, from src/pages/Integrations.tsx. IntegrationsTests checks
/// the web's own words against that file. Where the iPhone says something the web doesn't (it *is* the iPhone app, and
/// Safari is where WHOOP is connected), the line is marked "the iPhone's".
enum IntegrationsWords {
    static let title = "Bring your health together."
    static let sub = "Your account. Your measurements. Your choice."

    // The ?whoop= banners (the web's redirect back from WHOOP).
    static let whoopConnected = "WHOOP connected. Your last year is syncing now."
    static let whoopFailedMember = "WHOOP didn't connect. Try connecting again."
    static func whoopFailed(_ message: String) -> String { "WHOOP connection failed: \(message)" }
    static let whoopNotConfiguredLocal = "Add your WHOOP client ID and secret to .env first (the steps are on the WHOOP card)."
    static let whoopNotConfiguredAdmin = "WHOOP isn't set up yet. Add WHOOP_CLIENT_ID and WHOOP_CLIENT_SECRET to the Vercel project, then redeploy."
    static let whoopNotConfiguredMember = "WHOOP isn't available here yet."

    // WHOOP.
    static let whoopBody = "Recovery, sleep, resting heart rate, HRV, blood oxygen and respiratory rate. Includes skin temperature, sleep stages, efficiency and consistency. Imports your last year right away, then the rest of your history."
    static let whoopAway = "You'll sign in on WHOOP's site and come straight back."
    /// The iPhone's: where Connect WHOOP goes. The connection needs the web's session, which only Safari has.
    static let whoopInSafari = "Connect opens healthOS in Safari: sign in there if it asks, then connect WHOOP and come back here."
    static let whoopAdminSetup = "Add WHOOP_CLIENT_ID and WHOOP_CLIENT_SECRET to the Vercel project, then redeploy."
    static let whoopMemberOff = "WHOOP isn't turned on here yet. Ask the admin if you'd like to use it."
    static let whoopDeveloperApp = "Set up a WHOOP developer app"
    static let whoopStepSignIn = "with your WHOOP account and create an app."
    static let whoopStepRedirect = "Add this redirect URL to the app:"
    static let whoopStepScopes = "Select every read scope (recovery, cycles, sleep, workout, profile, body measurement)."
    static let whoopStepEnv = "Copy .env.example to .env, paste the client ID and secret, then restart npm run dev."
    static func whoopLastError(_ error: String) -> String { "Last sync failed: \(error)" }

    // Fitbit / Google Health.
    static let fitbitTitle = "Fitbit / Google Health"
    static let fitbitBody = "Import recorded heart rate, sleep, HRV, weight and body-fat measurements from your data export."
    static let fitbitFoot = "Automatic sync needs an approved Google Health app."
    static let fitbitRemoveAsk = "Remove all imported Fitbit data from healthOS? Your Fitbit account and the export file are not affected."

    // Apple Watch / Health.
    static let appleTitle = "Apple Watch / Health"
    static let appleBody = "Heart rate, HRV, oxygen, breathing and scale measurements arrive from your iPhone through the healthOS iPhone app, which syncs on its own."
    static let appleExportOnMac = "Importing an export file works from healthOS on your Mac."
    static let appleAdminImport = "To import a full export.zip into your own account, run healthOS on your Mac against this database (vercel env pull .env.local, then npm run import:apple -- ~/Downloads/export.zip)."
    static let appleRemoveAsk = "Remove all imported Apple Health data from healthOS? Your iPhone is not affected."
    /// The iPhone's: removing resets this iPhone's sync, so its history goes up again (the next sync is when the app
    /// opens or comes back, so almost at once).
    static let appleRemoveResends = "This iPhone then sends its Apple Health history again from the start, the next time it syncs."
    static let appleUploading = "Uploading your export…"
    static func appleReading(_ records: String) -> String { "Reading records… \(records)" }
    /// The web's stale line says to open the app; here it is the app.
    static let appleStale = "Nothing has come from this iPhone in the last day. Sync now in Profile sends it."
    /// The iPhone's, for the web's "Automatic sync needs an iPhone companion app.": this is that app.
    static let appleNotSetUp = "Automatic sync starts once this iPhone is set up."
    static func appleSynced(_ ago: String) -> String { "Synced from iPhone \(ago)" }

    // The iPhone app token (IphoneToken).
    static let setUpPhone = "Set up this iPhone"
    static let tokenSet = "Token set. The app can send your Apple Health data here."
    static let noToken = "No token yet."
    static let tokenScope = "The token lets the app write to your account only. It can't read anything back or sign in to the dashboard."
    static let tokenShownOnce = "The token is shown only now."
    /// The iPhone's: what Set up this iPhone did.
    static let tokenSavedHere = "Saved on this iPhone, which now sends your Apple Health data here. For another device, use these:"
    static let thisPhoneSetUp = "This iPhone sends your Apple Health data to your account."
    static let newTokenAsk = "Create a new token? The iPhone app stops syncing until you paste the new one."
    static let revokeAsk = "Revoke the iPhone app token? The app stops syncing until you create a new one."

    // The note and the demo card.
    static let noteTitle = "Measured. Always clear."
    static let note = "Every reading keeps its source and date. Disconnecting stops access; previously imported measurements stay in your records. Nutrition logs do not measure glucose, inflammation or water retention."
    static let demoTitle = "Demo data"
    static let demoAuto = "On automatic, the demo turns off once your own readings arrive."
    static func demoLine(showing demo: Bool) -> String { (demo ? "Showing synthetic data. " : "Showing your data. ") + demoAuto }
    static let demoModes: [(value: String, title: String)] = [("auto", "Automatic"), ("on", "Always"), ("off", "Off")]

    // MARK: Times and dates, as the web writes them

    /// ago(): "just now", "12 min ago", "5 h ago", else the day ("Oct 23, 2026").
    static func ago(_ iso: String, now: Date = Date()) -> String? {
        guard let date = Self.instant(iso) else { return nil }
        let mins = Int((now.timeIntervalSince(date) / 60).rounded())
        if mins < 1 { return "just now" }
        if mins < 60 { return "\(mins) min ago" }
        if mins < 48 * 60 { return "\(Int((Double(mins) / 60).rounded())) h ago" }
        return day(String(iso.prefix(10)), template: "MMMdy")
    }

    /// shortDay(): an import's moment as "Oct 23", in this iPhone's own calendar and zone.
    static func shortDay(_ iso: String) -> String? {
        guard let date = Self.instant(iso) else { return nil }
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f.string(from: date)
    }

    /// span(): "Mar 2021 – Oct 2026", or nothing without both ends.
    static func span(_ first: String?, _ last: String?) -> String? {
        guard let first, let last, let a = day(first, template: "MMMy"), let b = day(last, template: "MMMy") else { return nil }
        return "\(a) – \(b)"
    }

    /// "1 day", "1,204 days".
    static func days(_ n: Double) -> String {
        let count = Int(n.rounded())
        return "\(count.formatted()) \(count == 1 ? "day" : "days")"
    }

    /// A date-only string (YYYY-MM-DD) as the web's fmtDate writes it: in UTC, so the day never moves with the zone.
    private static func day(_ ymd: String, template: String) -> String? {
        let parse = DateFormatter()
        parse.locale = Locale(identifier: "en_US_POSIX")
        parse.timeZone = TimeZone(identifier: "UTC")
        parse.dateFormat = "yyyy-MM-dd"
        guard let date = parse.date(from: String(ymd.prefix(10))) else { return nil }
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.setLocalizedDateFormatFromTemplate(template)
        return f.string(from: date)
    }

    private static func instant(_ iso: String) -> Date? { ISO8601DateFormatter.lenient(iso) }
}

/// What each source card shows, from the status alone. A part the status doesn't have (an older server, or a read that
/// failed) shows nothing: never "not set up" because something couldn't be read.
enum IntegrationsRules {
    struct Chip: Equatable {
        let text: String
        let tone: Badge.Tone
    }

    // MARK: WHOOP

    static func whoopChip(_ w: ServerStatus.Whoop, hosted: Bool, admin: Bool) -> Chip {
        if let error = w.lastError, !error.isEmpty { return Chip(text: "Needs attention", tone: .bad) }
        if w.connected == true { return w.syncing == true ? Chip(text: "Syncing…", tone: .muted) : Chip(text: "Connected", tone: .sage) }
        if w.configured == true { return Chip(text: "Ready to connect", tone: .peach) }
        if hosted, !admin { return Chip(text: "Not available yet", tone: .muted) }
        return Chip(text: "Needs a developer app", tone: .peach)
    }

    /// "Synced 5 min ago · syncs every hour" (with " while healthOS is running" off the hosted server).
    static func whoopState(_ w: ServerStatus.Whoop, hosted: Bool, now: Date = Date()) -> String? {
        guard w.connected == true else { return nil }
        let head = w.syncing == true ? "Syncing now…" : w.lastSync.flatMap { IntegrationsWords.ago($0, now: now) }.map { "Synced \($0)" } ?? "Not synced yet"
        return head + " · syncs every hour" + (hosted ? "" : " while healthOS is running")
    }

    /// The web's Connect WHOOP goes to /api/whoop/connect with the browser's session. The app's session isn't Safari's,
    /// so it opens the web's Integrations page there, where the person signs in (if Safari isn't already) and connects.
    static func connectURL(server: URL) -> URL? {
        URL(string: server.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/#/integrations")
    }

    /// The ?whoop= banner: its words and whether it's good news.
    static func banner(query: [String: String], hosted: Bool, admin: Bool) -> (text: String, good: Bool)? {
        switch query["whoop"] {
        case "connected": (IntegrationsWords.whoopConnected, true)
        // The reason can be WHOOP's own technical wording, so only admins (and a local server) see it.
        case "error": (admin || !hosted ? IntegrationsWords.whoopFailed(query["message"] ?? "") : IntegrationsWords.whoopFailedMember, false)
        case "not-configured":
            (!hosted ? IntegrationsWords.whoopNotConfiguredLocal : admin ? IntegrationsWords.whoopNotConfiguredAdmin : IntegrationsWords.whoopNotConfiguredMember, false)
        default: nil
        }
    }

    // MARK: Fitbit

    static func fitbitChip(_ f: ServerStatus.Fitbit) -> Chip {
        if let last = f.lastImport, let day = IntegrationsWords.shortDay(last.importedAt) { return Chip(text: "Imported \(day)", tone: .sage) }
        return Chip(text: "File import available", tone: .sage)
    }

    /// "1,204 days · Mar 2021 – Oct 2026".
    static func fitbitState(_ f: ServerStatus.Fitbit) -> String? {
        guard let last = f.lastImport, let days = last.days else { return nil }
        return IntegrationsWords.days(days) + (IntegrationsWords.span(last.firstDate, last.lastDate).map { " · \($0)" } ?? "")
    }

    // MARK: Apple Health

    /// The Mac's export import is running (it can't be cleared meanwhile).
    static func appleBusy(_ a: ServerStatus.Apple?) -> Bool { ["uploading", "parsing"].contains(a?.job?.state ?? "") }

    /// The iPhone app is how this account syncs: it has a token, or the phone has sent something.
    static func phone(_ a: ServerStatus.Apple?) -> Bool { a?.iphoneToken == true || a?.lastSync != nil }

    static func appleChip(_ a: ServerStatus.Apple?) -> Chip {
        if phone(a) { return Chip(text: "Syncing from iPhone", tone: .sage) }
        if appleBusy(a) { return Chip(text: "Importing…", tone: .muted) }
        if let last = a?.lastImport, let day = IntegrationsWords.shortDay(last.importedAt) { return Chip(text: "Imported \(day)", tone: .sage) }
        // The iPhone's, on every server: the web's local "File import available" offers its export import, which runs
        // on the Mac (the card says so), so here, as on the hosted server, this iPhone app is how Apple Health gets there.
        return Chip(text: "Ready to connect", tone: .peach)
    }

    /// "Imported 2 h ago · 12,345 records · Mar 2021 – Oct 2026", as the web's line; an older server's import without
    /// its records or days says only what it sent.
    static func appleImportState(_ a: ServerStatus.Apple?, now: Date = Date()) -> String? {
        guard let last = a?.lastImport, let ago = IntegrationsWords.ago(last.importedAt, now: now) else { return nil }
        var line = "Imported \(ago)"
        if let records = last.records { line += " · \(Int(records.rounded()).formatted()) records" }
        if let span = IntegrationsWords.span(last.firstDate, last.lastDate) { line += " · \(span)" }
        return line
    }

    /// Hosted, an account that syncs from its iPhone and hasn't sent anything in a day.
    static func appleStale(_ a: ServerStatus.Apple?, hosted: Bool, now: Date = Date()) -> Bool {
        guard hosted, phone(a) else { return false }
        guard let synced = a?.lastSync?.syncedAt, let date = ISO8601DateFormatter.lenient(synced) else { return true }
        return now.timeIntervalSince(date) > 86_400
    }

    /// "Remove Apple Health data" shows while the server holds Apple Health data for this account: an export's import,
    /// or (unlike the web, whose card shows it only after an export) the iPhone's own sync, which on the hosted server
    /// is how it all arrives. Not while an export import runs, which the server refuses with a 409.
    static func showsRemoveApple(_ a: ServerStatus.Apple?) -> Bool {
        guard let a else { return false }
        return (a.lastImport != nil || a.lastSync != nil) && !appleBusy(a)
    }

    /// After the server removed this account's Apple Health data, this iPhone's sync starts again from the beginning
    /// (`SyncEngine.reset()`), or its anchors would send only what's new and the account would stay short of its history.
    /// Only when the token here is this account's (or has no owner: the next token is) and it's the one there was when
    /// Remove was tapped: another account's sync, or one set up since, is left alone.
    static func resetsSync(tokenOwner: IngestTokenOwner.Account?, signedIn: IngestTokenOwner.Account?, tokenBefore: String, tokenNow: String) -> Bool {
        guard tokenBefore == tokenNow else { return false }
        guard let tokenOwner else { return true }
        guard let signedIn else { return false }
        return tokenOwner.isSame(as: signedIn)
    }

    // MARK: The iPhone app token

    /// "Set up this iPhone" shows only signed in on a server with accounts: one without has no account row to hold a
    /// token (it answers 400) and uses HEALTHOS_INGEST_TOKEN instead. Not while the sign-in mode isn't known.
    static func showsPhoneSetup(authMode: String?, phase: Dashboard.Phase) -> Bool { authMode == "required" && phase == .ready }

    /// The token on this iPhone is the signed-in account's.
    static func phoneIsThisAccounts(hasToken: Bool, tokenOwner: IngestTokenOwner.Account?, signedIn: IngestTokenOwner.Account?) -> Bool {
        guard hasToken, let tokenOwner, let signedIn else { return false }
        return tokenOwner.isSame(as: signedIn)
    }

    // MARK: The demo card

    /// Demo rows are seeded only in a local database, for the owner.
    static func showsDemo(_ status: ServerStatus) -> Bool { status.hosted == false && status.user?.id == "owner" }
}

extension ISO8601DateFormatter {
    /// An ISO 8601 instant with or without fractional seconds.
    static func lenient(_ iso: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: iso) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)
    }
}
