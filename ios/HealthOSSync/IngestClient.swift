import Foundation

struct SyncError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// POST /api/apple/ingest on the healthOS server.
struct IngestClient {
    let base: URL
    let token: String

    struct Response: Decodable {
        let daily: Int
        let workouts: Int
        let events: Int
        /// Only servers that store hours report this; older ones drop the hourly rows silently.
        let hourly: Int?
        /// Only servers that store cycle days report this.
        let cycle: Int?
        /// Nights of sleep stages stored; only servers that store them report this (0 for none).
        let sleepStages: Int?
        /// Every daily metric the server takes. Older servers don't list them (SyncState.legacyMetrics).
        let metrics: [String]?
    }

    /// A reply other than 2xx, with the server's own message.
    struct Rejected: LocalizedError {
        let status: Int
        let detail: String
        var errorDescription: String? { "Server answered \(status): \(detail)" }
        /// The server refused a daily metric by name (`daily[i].metric: unknown metric "x"`), e.g. after it went back to
        /// a version that takes fewer. Hourly rows fail with "unknown hourly metric", which no filter here can fix.
        var unknownMetric: Bool { status == 400 && detail.contains("unknown metric \"") }
    }

    private struct ErrorBody: Decodable { let error: String }

    @discardableResult
    func send(_ payload: IngestPayload) async throws -> Response {
        var request = URLRequest(url: base.appendingPathComponent("api/apple/ingest"))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "X-HealthOS") // required by the localhost server for any write
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(payload)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw SyncError("Can't reach \(base.absoluteString): \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else { throw SyncError("No HTTP response from the server") }
        guard (200..<300).contains(http.statusCode) else {
            let detail = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error
                ?? String(data: data, encoding: .utf8)?.prefix(200).description
                ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw Rejected(status: http.statusCode, detail: detail)
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }
}
