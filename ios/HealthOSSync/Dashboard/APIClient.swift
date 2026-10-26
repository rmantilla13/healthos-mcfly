import Foundation

enum APIError: LocalizedError {
    case signInRequired
    case misconfigured(String)
    /// The status code and the server's own message, "" when it sent none.
    case server(Int, String)
    case network(String)

    /// Answers whose message the server writes for people (a bad entry, a wrong password, a clash, a photo or file too
    /// large, too many tries): shown as they are, as the web shows them.
    static let plainWords: Set<Int> = [400, 403, 409, 413, 429]

    var errorDescription: String? {
        switch self {
        case .signInRequired: "Sign in to see your dashboard."
        case .misconfigured(let message): message
        case .server(let code, let message):
            if message.isEmpty { "Server answered \(code): \(HTTPURLResponse.localizedString(forStatusCode: code))" }
            else if Self.plainWords.contains(code) { message }
            else { "Server answered \(code): \(message)" }
        case .network(let message): message
        }
    }

    /// The server has no such route: it's older than the feature ("Change server" can point the phone at an older Mac
    /// or LAN server). Its catch-all answers 404 {error: "Not found"}, and one older still answers 404 with no JSON at
    /// all. A route's own 404s ("No such entry", "Unknown metric", "This code or link is invalid…") aren't this. Only
    /// for routes that answer a list or a state (GET /ai, /portraits, /peers, /journal, /labs/documents, /labs/reader,
    /// POST /nutrition/log/day): an image or a file by id (/portraits/:id/image, /family/:id/avatar.png) answers the
    /// same "Not found" when that one is gone.
    var routeMissing: Bool {
        guard case .server(404, let message) = self else { return false }
        return message.isEmpty || message == "Not found"
    }

    /// The server's own words when a feature isn't set up there (a 503: "Connecting your own key isn't set up on this
    /// server.", "Voice notes need an OpenAI key. Connect one in your Profile."), for that feature to show as they
    /// are. nil for any other failure.
    var notSetUpHere: String? {
        if case .misconfigured(let message) = self { return message }
        return nil
    }
}

/// Read access to the healthOS API (the same endpoints the web dashboard uses). The hosted server
/// signs in with the dashboard password and a session cookie; the cookie lives in the Keychain,
/// not in a cookie jar on disk, and goes out as a header from a session that stores no cookies.
///
/// Each page adds its own endpoints in its own file, as an extension (`McFly.swift`, `Portraits/PortraitsAPI.swift`),
/// through `request`, `sendJSON` and `optional` here. An upload that reports progress, or a download read as it
/// arrives, builds its request with `urlRequest` and checks the answer with `checked`, on `session`.
struct APIClient {
    let base: URL

    static func current() -> APIClient? { Config.serverURL().map { APIClient(base: $0) } }

    /// The one session every request goes out on: ephemeral, keeping no cookies of its own.
    private(set) static var session = makeSession()

    private static func makeSession(protocols: [AnyClass] = []) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 30
        if !protocols.isEmpty { config.protocolClasses = protocols + (config.protocolClasses ?? []) }
        return URLSession(configuration: config)
    }

    /// Tests only: every request asks these URLProtocol classes first (a stub answering in the server's place), on a
    /// session otherwise the same, until it's called again with none. The app never calls it.
    ///
    ///     APIClient.answering(with: [StubProtocol.self])
    ///     defer { APIClient.answering(with: []) }
    static func answering(with protocols: [AnyClass]) { session = makeSession(protocols: protocols) }

    private struct ErrorBody: Decodable {
        let error: String?
    }

    /// A request to /api`path` with what every one carries: the session cookie, and on a write X-HealthOS (the server
    /// requires it) and the body's type, JSON unless said otherwise (a recording, a report: "audio/mp4",
    /// "application/pdf"). `headers` adds others, such as X-Filename.
    func urlRequest(_ path: String, query: [URLQueryItem] = [], method: String = "GET", contentType: String = "application/json",
                    headers: [String: String] = [:], timeout: TimeInterval? = nil) -> URLRequest {
        var components = URLComponents(url: base.appendingPathComponent("api" + path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var req = URLRequest(url: components.url!)
        req.httpMethod = method
        if let timeout { req.timeoutInterval = timeout }
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if method != "GET" {
            req.setValue("1", forHTTPHeaderField: "X-HealthOS") // the server requires it on every write
            req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        for (name, value) in headers { req.setValue(value, forHTTPHeaderField: name) }
        if let cookie = SessionStore.cookie(for: base) { req.setValue("\(SessionStore.name)=\(cookie)", forHTTPHeaderField: "Cookie") }
        return req
    }

    /// The body of an answer to `path`, once it's known to be a yes: a new session cookie is kept, and a refusal is
    /// thrown as the error for it (`error(status:message:path:)`), a 401 also dropping the session.
    func checked(_ data: Data, _ response: URLResponse, path: String) throws -> Data {
        guard let http = response as? HTTPURLResponse else { throw APIError.network("No response from the server.") }
        if let setCookie = http.value(forHTTPHeaderField: "Set-Cookie") {
            SessionStore.update(from: setCookie, url: http.url ?? base, base: base)
        }
        if (200..<300).contains(http.statusCode) { return data }

        let error = Self.error(status: http.statusCode, message: (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error, path: path)
        if case .signInRequired = error { SessionStore.clear() }
        throw error
    }

    /// "Can't reach <host>" for a request that never got an answer; a cancelled one stays a cancellation.
    func unreachable(_ error: Error) -> Error {
        if Self.isCancellation(error) { return CancellationError() }
        return APIError.network("Can't reach \(base.host ?? base.absoluteString). \(error.localizedDescription)")
    }

    /// One request and its answer's body. `body` is JSON unless `contentType` says otherwise.
    func request(_ path: String, query: [URLQueryItem] = [], method: String = "GET", body: Data? = nil, contentType: String = "application/json",
                 headers: [String: String] = [:], timeout: TimeInterval? = nil) async throws -> Data {
        var req = urlRequest(path, query: query, method: method, contentType: contentType, headers: headers, timeout: timeout)
        if method != "GET" { req.httpBody = body }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: req)
        } catch {
            throw unreachable(error)
        }
        return try checked(data, response, path: path)
    }

    /// The error for a refused request to `path`, from its status and the server's message (nil when it sent none).
    static func error(status: Int, message serverMessage: String?, path: String) -> APIError {
        let said = serverMessage ?? ""
        let message = said.isEmpty ? HTTPURLResponse.localizedString(forStatusCode: status) : said
        // A 401 from the sign-in itself is a wrong password. Anywhere else the session is gone, changing the password
        // included: that route needs a session.
        let signInForm = path == "/auth/login" || path == "/auth/invite"
        if status == 401, !signInForm { return .signInRequired }
        if status == 503 { return .misconfigured(message) }
        // Account forms' errors (wrong password, too many attempts, a link that's used up) are written for people;
        // show them as they are. A link's check and a reset answer 404 for a code that's invalid or used.
        let accountForm = signInForm || path == "/auth/password" || path == "/auth/link" || path == "/auth/reset"
        if accountForm, (400..<500).contains(status) { return .network(message) }
        return .server(status, said)
    }

    func getJSON<T: Decodable>(_ path: String) async throws -> T { try await get(path) }

    /// A request dropped because its task ended (pull to refresh let go, a sheet covered the screen): nothing went
    /// wrong, so callers stay quiet instead of saying the server can't be reached.
    static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    /// A POST whose response is read as it arrives (server-sent events). Status handling is left to the caller.
    func stream(_ path: String, body: Data) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        var req = urlRequest(path, method: "POST", headers: ["Accept": "text/event-stream"], timeout: 120)
        req.httpBody = body
        do {
            let (bytes, response) = try await Self.session.bytes(for: req)
            guard let http = response as? HTTPURLResponse else { throw APIError.network("No response from the server.") }
            if http.statusCode == 401 { SessionStore.clear() }
            return (bytes, http)
        } catch let e as APIError {
            throw e
        } catch {
            throw unreachable(error)
        }
    }

    func post(_ path: String, body: Data) async throws -> Data { try await request(path, method: "POST", body: body) }

    func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await request(path, query: query))
    }

    func authState() async throws -> AuthState { try await get("/auth/me") }

    /// Servers with accounts read both fields; older ones read only the password, so sending both works with either.
    func signIn(email: String, password: String) async throws {
        var body = ["password": password]
        if !email.isEmpty { body["email"] = email }
        _ = try await request("/auth/login", method: "POST", body: try JSONEncoder().encode(body))
        guard SessionStore.cookie(for: base) != nil else { throw APIError.network("The server accepted the password but sent no session.") }
    }

    /// Creates an account from an invite and signs in (POST /api/auth/invite, same as the web's invite page).
    func acceptInvite(code: String, email: String, name: String, password: String) async throws {
        let body = ["token": Self.inviteToken(from: code), "email": email, "name": name, "password": password]
        _ = try await request("/auth/invite", method: "POST", body: try JSONEncoder().encode(body))
        guard SessionStore.cookie(for: base) != nil else { throw APIError.network("The account was created, but the server sent no session. Sign in.") }
    }

    /// The code from what someone pasted: a bare code, or a whole invite link (…#/invite/<code>).
    /// Case and dashes are kept, since link tokens are case-sensitive; the server normalizes short codes.
    static func inviteToken(from input: String) -> String {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = s.range(of: "#/invite/") { s = String(s[r.upperBound...]) }
        if let end = s.firstIndex(where: { $0 == "?" || $0 == "&" || $0 == "/" }) { s = String(s[..<end]) }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func signOut() async {
        _ = try? await request("/auth/logout", method: "POST", body: Data("{}".utf8))
        SessionStore.clear()
    }

    func summary(date: String?) async throws -> Summary {
        try await get("/summary", query: date.map { [URLQueryItem(name: "date", value: $0)] } ?? [])
    }

    func trends(_ metrics: [String], days: Int) async throws -> Trends {
        try await get("/trends", query: [URLQueryItem(name: "metrics", value: metrics.joined(separator: ",")), URLQueryItem(name: "days", value: String(days))])
    }

    func workouts(days: Int) async throws -> [Workout] {
        try await get("/workouts", query: [URLQueryItem(name: "days", value: String(days))])
    }

    func status() async throws -> ServerStatus { try await get("/status") }

    /// A GET for an endpoint newer servers have: nil when the server has no such route (it predates it), so the
    /// feature hides or falls back. Any other failure, the route's own 404s included, is thrown.
    func optional<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T? {
        do {
            return try await get(path, query: query) as T
        } catch let error as APIError where error.routeMissing {
            return nil
        }
    }

    /// The same for a write (POST /nutrition/log/day, which takes its date in the body): nil when the server has no
    /// such route.
    func optional<T: Decodable>(_ method: String, _ path: String, _ body: [String: Any], timeout: TimeInterval? = nil) async throws -> T? {
        do {
            return try await sendJSON(method, path, body, timeout: timeout) as T
        } catch let error as APIError where error.routeMissing {
            return nil
        }
    }

    /// One day by hour (GET /day); nil date means today. Without metrics the server sends all it has.
    func day(date: String?, metrics: [String]? = nil) async throws -> DayData? {
        var query: [URLQueryItem] = []
        if let date { query.append(URLQueryItem(name: "date", value: date)) }
        if let metrics { query.append(URLQueryItem(name: "metrics", value: metrics.joined(separator: ","))) }
        return try await optional("/day", query: query)
    }

    func cycle(days: Int) async throws -> CycleData? {
        try await optional("/cycle", query: [URLQueryItem(name: "days", value: String(days))])
    }

    /// Bed and wake times (GET /sleep); the server clamps days to 7–365.
    func sleepTiming(days: Int) async throws -> SleepTiming? {
        try await optional("/sleep", query: [URLQueryItem(name: "days", value: String(days))])
    }

    func patterns() async throws -> Patterns? { try await optional("/patterns") }

    // MARK: Food log (server/foodlog.ts, foods.ts, estimate.ts)

    /// The last `days` days of entries (1 to 31) and McFly's estimate waiting for review; nil from a server without logging.
    func foodLog(days: Int) async throws -> FoodLog? {
        try await optional("/nutrition/log", query: [URLQueryItem(name: "days", value: String(days))])
    }

    /// A write with a JSON body, and its JSON answer.
    func sendJSON<T: Decodable>(_ method: String, _ path: String, _ body: [String: Any]? = nil, timeout: TimeInterval? = nil) async throws -> T {
        let data = try await request(path, method: method, body: try JSONSerialization.data(withJSONObject: body ?? [:]), timeout: timeout)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// One day of the log, any day in the last year (POST /nutrition/log/day, the date in the body). nil from a server
    /// older than it: fall back to `foodLog(days:)`.
    func foodLogDay(date: String?) async throws -> FoodLogDay? {
        try await optional("POST", "/nutrition/log/day", date.map { ["date": $0] } ?? [:])
    }

    func addFood(_ body: [String: Any]) async throws -> FoodEntry { try await sendJSON("POST", "/nutrition/log", body) }

    func changeFood(id: String, _ body: [String: Any]) async throws -> FoodEntry { try await sendJSON("PATCH", "/nutrition/log/\(id)", body) }

    func deleteFood(id: String) async throws {
        _ = try await request("/nutrition/log/\(id)", method: "DELETE", body: Data("{}".utf8))
    }

    private struct Saved: Decodable { @LossyArray var entries: [FoodEntry] }

    /// Saves those drafts of that estimate (they count from now on) and discards its others.
    func saveDrafts(batch: String, ids: [String]) async throws -> [FoodEntry] {
        let saved: Saved = try await sendJSON("POST", "/nutrition/log/save", FoodBody.save(batch: batch, ids: ids))
        return saved.entries
    }

    func discardDrafts(batch: String) async throws {
        _ = try await request("/nutrition/log/discard", method: "POST", body: try JSONSerialization.data(withJSONObject: FoodBody.discard(batch: batch)))
    }

    /// Foods for words, or a typed barcode (8 to 14 digits). Search on submit, not as the person types.
    func searchFoods(_ query: String) async throws -> FoodSearch { try await sendJSON("POST", "/nutrition/foods/search", ["query": query]) }

    /// Open Food Facts, then USDA's branded foods. No results means not found: offer quick add from the label.
    func barcode(_ code: String) async throws -> FoodSearch { try await sendJSON("POST", "/nutrition/foods/barcode", ["code": code]) }

    /// McFly's estimate from a photo or words: drafts to review. Counts as one McFly question.
    func estimateFood(_ body: [String: Any]) async throws -> FoodEstimate {
        // McFly reads a photo for a while; the usual 30 s would cut it off.
        try await sendJSON("POST", "/nutrition/estimate", body, timeout: 90)
    }

    /// Food totals by day (GET /nutrition); nil from a server without Nutrition. `insights` adds the food patterns.
    func nutrition(days: Int, insights: Bool = false) async throws -> NutritionData? {
        var query = [URLQueryItem(name: "days", value: String(days))]
        if insights { query.append(URLQueryItem(name: "insights", value: "1")) }
        return try await optional("/nutrition", query: query)
    }

    func digest() async throws -> DigestReply? { try await optional("/mcfly/digest") }

    /// The Family board (GET /family); nil when the server predates it (404).
    func family() async throws -> FamilyBoard? { try await optional("/family") }

    /// A family member's small avatar for this photo version; nil when there's none, or either person stopped sharing.
    func familyAvatar(id: String, version: String) async throws -> Data? {
        do {
            return try await request("/family/\(id)/avatar.png", query: [URLQueryItem(name: "v", value: version)])
        } catch APIError.server(404, _) {
            return nil
        }
    }

    /// Changes settings (PUT /settings), e.g. ["familySharing": false] or a CardChange's body; the server answers
    /// with the new status.
    func updateSettings(_ fields: [String: Any]) async throws -> ServerStatus {
        let data = try await request("/settings", method: "PUT", body: try Self.settingsBody(fields))
        // Every server so far answers with the status; read it again if this one didn't.
        if let status = try? JSONDecoder().decode(ServerStatus.self, from: data), status.settings != nil { return status }
        return try await self.status()
    }

    /// The JSON a PUT /settings sends, keys sorted so the same change always reads the same.
    static func settingsBody(_ fields: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
    }

    /// An opaque version of the signed-in person's data; it changes whenever any of their data changes.
    /// nil when unknown: the server has no /version yet (404) or answered null. Either way, refetch.
    func dataVersion() async throws -> String? {
        struct Reply: Decodable { let version: String? }
        do {
            let reply: Reply = try await get("/version")
            return reply.version
        } catch APIError.server(404, _) {
            return nil
        }
    }

    /// Asks the server to refresh WHOOP now (POST /api/sync). Returns the status JSON with `whoopStarted`.
    /// Servers before /api/sync have POST /api/whoop/sync, which answers 400 when WHOOP isn't connected.
    func syncSources() async throws -> ServerStatus {
        let empty = Data("{}".utf8)
        do {
            return try JSONDecoder().decode(ServerStatus.self, from: try await request("/sync", method: "POST", body: empty))
        } catch APIError.server(404, _) {
            do {
                return try JSONDecoder().decode(ServerStatus.self, from: try await request("/whoop/sync", method: "POST", body: empty))
            } catch APIError.server(400, _) {
                return try await status()
            }
        }
    }

    /// A profile image (avatar.png or cutout.png) for this photo version; nil when there's no photo.
    func profileImage(_ name: String, version: String) async throws -> Data? {
        do {
            return try await request("/profile/\(name)", query: [URLQueryItem(name: "v", value: version)])
        } catch APIError.server(404, _) {
            return nil
        }
    }
}

/// The hosted dashboard's session cookie, kept in the Keychain and tied to the server it came from.
enum SessionStore {
    static let name = "hos_session"
    private static let service = "healthos.session"

    private struct Stored: Codable {
        let server: String
        let value: String
        let expires: Date?
    }

    static func cookie(for base: URL) -> String? {
        guard let raw = Keychain.read(service: service), let s = try? JSONDecoder().decode(Stored.self, from: Data(raw.utf8)) else { return nil }
        guard s.server == base.absoluteString, (s.expires ?? .distantFuture) > Date() else { return nil }
        return s.value
    }

    static func update(from setCookie: String, url: URL, base: URL) {
        guard let c = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": setCookie], for: url).first(where: { $0.name == name }) else { return }
        if c.value.isEmpty || (c.expiresDate.map { $0 <= Date() } ?? false) { return clear() } // sign-out sends an expired, empty cookie
        let stored = Stored(server: base.absoluteString, value: c.value, expires: c.expiresDate)
        if let data = try? JSONEncoder().encode(stored) { Keychain.write(String(decoding: data, as: UTF8.self), service: service) }
    }

    static func clear() { Keychain.write("", service: service) }
}
