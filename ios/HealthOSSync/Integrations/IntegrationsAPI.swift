import Foundation

/// Integrations' requests (src/pages/Integrations.tsx). Every one of these routes is older than this branch except
/// `/fitbit/*`, whose card shows only where the status names `fitbit` (an older server's status doesn't).
extension APIClient {
    /// POST /api/whoop/sync {full: true}: "Re-sync full year". Answers with the status (the sync runs on the server).
    func whoopFullSync() async throws -> ServerStatus { try await sendJSON("POST", "/whoop/sync", ["full": true]) }

    /// POST /api/whoop/disconnect. Answers with the status.
    func whoopDisconnect() async throws -> ServerStatus { try await sendJSON("POST", "/whoop/disconnect") }

    /// POST /api/apple/clear: every Apple Health row of the person signed in goes, the export's and the iPhone's alike,
    /// with the last import and the last sync. Answers with the status; 409 while an export import is running.
    func clearAppleHealth() async throws -> ServerStatus { try await sendJSON("POST", "/apple/clear") }

    /// POST /api/fitbit/clear: every Fitbit row goes, other sources stay. Answers {ok: true}, not the status.
    func clearFitbit() async throws {
        _ = try await request("/fitbit/clear", method: "POST", body: Data("{}".utf8))
    }

    private struct MintedToken: Decodable { let token: String }

    /// POST /api/me/ingest-token: a new token for the iPhone app, which replaces the account's last one. Shown once; the
    /// server keeps only its hash. 400 on a server without accounts (it has no account row to hold one).
    func mintIngestToken() async throws -> String {
        let minted: MintedToken = try await sendJSON("POST", "/me/ingest-token")
        return minted.token
    }

    /// DELETE /api/me/ingest-token: the account's token stops working. Answers with the status.
    func revokeIngestToken() async throws -> ServerStatus { try await sendJSON("DELETE", "/me/ingest-token") }
}
