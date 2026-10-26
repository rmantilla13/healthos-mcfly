import SwiftUI
import UIKit

/// "Export your data" (GET /api/me/export, server/export.ts): everything the person stored, as one JSON file, built only
/// from their own session. The server streams it with no length, so it's downloaded straight into a file in a folder
/// of its own under the app's temporary directory (complete file protection), never in memory as a whole, never in
/// Documents or the ProfileImages cache, and never logged. The share sheet hands it on; the folder is deleted when
/// the sheet closes, before the next export, and when nobody's signed in. Nutrition amounts the person's Nutrition
/// setting hides are already left out by the server; nothing here adds any back.
enum ProfileExport {
    /// Why a download gave no file.
    enum Failure: Error, Equatable {
        /// No answer came at all (offline, the server down).
        case unreachable
        /// The answer started and broke off: the server stops a failing export rather than end it as a short file
        /// that looks complete.
        case stopped
    }

    /// A refusal or failure, in the words to show: the server's own, or the web's.
    struct Problem: LocalizedError, Equatable {
        let message: String
        /// The server has no such route: it's older than the export (APIError.routeMissing).
        var routeMissing = false
        var errorDescription: String? { message }
    }

    /// One download: the answer's body in a file, and its head. Throws `Failure`, or CancellationError.
    typealias Download = (URLRequest) async throws -> (URL, URLResponse)

    static let path = "/me/export"

    /// Where exports wait to be shared. Everything in it is temporary.
    static var folder: URL { FileManager.default.temporaryDirectory.appendingPathComponent("healthos-export", isDirectory: true) }

    /// Downloads the export and returns its file, named as the server names it, ready to share. A refusal throws a
    /// `Problem` with the server's words (a 429's "Your export was just prepared. Try again in a minute."), a 401
    /// throws APIError.signInRequired (for `dashboard.fetch` to sign out), and any other failure a `Problem` with the
    /// web's words. `download` is the request; tests pass their own.
    static func run(client: APIClient, download: Download? = nil, today: String = Day.today()) async throws -> URL {
        removeAll()
        // The usual 30 s between bytes is plenty; a long history takes a while to build, a year at a time.
        let request = client.urlRequest(path, timeout: 120)
        let file: URL
        let response: URLResponse
        do {
            (file, response) = try await (download ?? live)(request)
        } catch Failure.unreachable {
            throw Problem(message: ProfileWords.exportUnreachable)
        } catch Failure.stopped {
            throw Problem(message: ProfileWords.exportStopped)
        }
        // Whatever isn't handed on goes: a refusal's body, a file that couldn't be named.
        var kept: URL?
        defer { if kept == nil { discard(file) } }
        guard let http = response as? HTTPURLResponse else { throw Problem(message: ProfileWords.exportUnreachable) }
        guard (200..<300).contains(http.statusCode) else {
            // A refusal's body is a line of JSON.
            let body = (try? FileHandle(forReadingFrom: file)).flatMap { handle in
                defer { try? handle.close() }
                return try? handle.read(upToCount: 64 * 1024)
            } ?? Data()
            throw refusal(body, response, client: client)
        }
        // A new session cookie, if one came, is kept as for any answer.
        _ = try? client.checked(Data(), response, path: path)
        let name = fileName(contentDisposition: http.value(forHTTPHeaderField: "Content-Disposition"), today: today)
        // Named in its own folder: the one it was written into, or a new one.
        let parent = file.deletingLastPathComponent()
        let dir = isInFolder(parent) ? parent : folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
            let target = dir.appendingPathComponent(name)
            try FileManager.default.moveItem(at: file, to: target)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: target.path)
            kept = target
            return target
        } catch {
            removeAll()
            throw Problem(message: ProfileWords.exportFailed)
        }
    }

    /// A download not handed on: the file, and the folder it was written into when that's one of the export's own.
    private static func discard(_ file: URL) {
        try? FileManager.default.removeItem(at: file)
        let parent = file.deletingLastPathComponent()
        if isInFolder(parent) { try? FileManager.default.removeItem(at: parent) }
    }

    private static func isInFolder(_ dir: URL) -> Bool {
        dir.standardizedFileURL.deletingLastPathComponent().path == folder.standardizedFileURL.path
    }

    /// The error for a refused export: signed out, an older server, or the server's words (the web's fallback when
    /// it sent none).
    static func refusal(_ body: Data, _ response: URLResponse, client: APIClient) -> Error {
        do {
            _ = try client.checked(body, response, path: path)
            return Problem(message: ProfileWords.exportFailed)
        } catch let error as APIError {
            switch error {
            case .signInRequired: return error
            case .server(_, let message):
                if error.routeMissing { return Problem(message: ProfileWords.exportNotHere, routeMissing: true) }
                return Problem(message: message.isEmpty ? ProfileWords.exportFailed : message)
            case .misconfigured(let message), .network(let message):
                return Problem(message: message.isEmpty ? ProfileWords.exportFailed : message)
            }
        } catch {
            return Problem(message: ProfileWords.exportFailed)
        }
    }

    /// The file's name from Content-Disposition (`attachment; filename="healthos-export-2026-10-26.json"`), as the web
    /// reads it, else the web's own `healthos-export-<today>.json`. Never a path: slashes and the like go.
    static func fileName(contentDisposition: String?, today: String) -> String {
        let fallback = "healthos-export-\(today).json"
        guard let header = contentDisposition, let start = header.range(of: "filename=\"") else { return fallback }
        let rest = header[start.upperBound...]
        guard let end = rest.firstIndex(of: "\""), end > rest.startIndex else { return fallback }
        let unsafe = CharacterSet(charactersIn: "/\\:\0").union(.controlCharacters)
        let cleaned = String(rest[..<end]).unicodeScalars.filter { !unsafe.contains($0) }.map(String.init).joined()
            .trimmingCharacters(in: .whitespaces)
        let name = String(cleaned.drop { $0 == "." })
        return name.isEmpty ? fallback : name
    }

    /// Deletes every export waiting here.
    static func removeAll() {
        try? FileManager.default.removeItem(at: folder)
    }

    /// The download as the app makes it: written straight into a file of its own in `folder` as it arrives (complete
    /// file protection), so tens of MB never sit in memory, and nothing of it is left anywhere else. A system download
    /// task would keep a broken download's part in the app's temporary files to resume it later: this keeps none.
    /// A failure says whether the answer had begun (`stopped`) or never came (`unreachable`), and deletes the part.
    static func live(_ request: URLRequest) async throws -> (URL, URLResponse) {
        let dir = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let file = dir.appendingPathComponent("download.part")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
            guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.protectionKey: FileProtectionType.complete]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw Failure.unreachable
        }
        let writer = try StreamWriter(file: file)
        let task = APIClient.session.dataTask(with: request)
        task.delegate = writer
        do {
            let response = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    writer.start(task, continuation)
                }
            } onCancel: {
                task.cancel()
            }
            return (file, response)
        } catch {
            try? FileManager.default.removeItem(at: dir)
            if Task.isCancelled || APIClient.isCancellation(error) { throw CancellationError() }
            throw writer.answered ? Failure.stopped : Failure.unreachable
        }
    }

    /// Writes one download's body into its file as it comes, and says how it ended.
    private final class StreamWriter: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private let handle: FileHandle
        private var continuation: CheckedContinuation<URLResponse, Error>?
        private var response: URLResponse?
        private var failed: Error?

        init(file: URL) throws { handle = try FileHandle(forWritingTo: file) }

        func start(_ task: URLSessionDataTask, _ continuation: CheckedContinuation<URLResponse, Error>) {
            lock.withLock { self.continuation = continuation }
            task.resume()
        }

        /// The answer's head came: whatever happens next broke off a download that had begun.
        var answered: Bool { lock.withLock { response != nil } }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            lock.withLock { self.response = response }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            do {
                try handle.write(contentsOf: data)
            } catch {
                // The phone is full, or the file went: no use reading on.
                lock.withLock { failed = error }
                dataTask.cancel()
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            try? handle.close()
            let (continuation, response, failed) = lock.withLock { () -> (CheckedContinuation<URLResponse, Error>?, URLResponse?, Error?) in
                defer { self.continuation = nil }
                return (self.continuation, self.response, self.failed)
            }
            if let error = failed ?? error {
                continuation?.resume(throwing: error)
            } else if let response {
                continuation?.resume(returning: response)
            } else {
                continuation?.resume(throwing: URLError(.badServerResponse))
            }
        }
    }

    /// Hands the file to the share sheet (Save to Files, AirDrop, …), over whatever is showing. `done` runs once it
    /// closes, saying whether something was done with the file. False when there was nowhere to show it.
    @MainActor
    static func share(_ file: URL, done: @escaping (Bool) -> Void) -> Bool {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let root = scenes.flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController else { return false }
        var top = root
        while let shown = top.presentedViewController, !shown.isBeingDismissed { top = shown }
        let sheet = UIActivityViewController(activityItems: [file], applicationActivities: nil)
        sheet.completionWithItemsHandler = { _, completed, _, _ in
            Task { @MainActor in done(completed) }
        }
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = top.view
            popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
        }
        top.present(sheet, animated: true)
        return true
    }
}

/// Profile's "Export your data" row: Download JSON (Preparing… while the server builds it), then the share sheet.
/// Under the row, "Saved <name>." or what went wrong, read out as it changes. A server that answers it has no export
/// (older than it) gets no button again.
struct ProfileExportRow: View {
    var divider = true
    @Environment(Dashboard.self) private var dashboard
    @State private var busy = false
    @State private var result: (ok: Bool, text: String)?
    /// The server answered that it has no export: it's older than it.
    @State private var missing = false

    var body: some View {
        ProfileRow("Export your data", divider: divider) {
            Text(ProfileWords.exportLine)
            if let result {
                Text(result.text).foregroundStyle(result.ok ? Palette.accentText : Palette.critical)
                    .accessibilityIdentifier("exportResult")
            }
        } action: {
            if !missing {
                Button(busy ? "Preparing…" : "Download JSON") { Task { await export() } }
                    .buttonStyle(ProfilePillStyle())
                    .disabled(busy)
                    .accessibilityIdentifier("exportData")
            }
        }
        .onChange(of: result?.text) { _, text in
            if let text { UIAccessibility.post(notification: .announcement, argument: text) }
        }
        .onChange(of: dashboard.phase) { _, phase in
            // Nobody's signed in: the last person's line goes, with any file waiting.
            if phase != .ready {
                result = nil
                ProfileExport.removeAll()
            }
        }
    }

    private func export() async {
        busy = true
        result = nil
        defer { busy = false }
        let file: URL
        do {
            file = try await dashboard.fetch { try await ProfileExport.run(client: $0) }
        } catch is CancellationError {
            return
        } catch let problem as ProfileExport.Problem {
            if problem.routeMissing { missing = true }
            result = (false, problem.message)
            return
        } catch {
            // Signed out (the sign-in screen takes over), or no server.
            if dashboard.phase == .ready { result = (false, error.localizedDescription) }
            return
        }
        guard dashboard.phase == .ready else {
            ProfileExport.removeAll()
            return
        }
        let name = file.lastPathComponent
        let shown = ProfileExport.share(file) { completed in
            ProfileExport.removeAll()
            if completed { result = (true, ProfileWords.exportSaved(name)) }
        }
        if !shown {
            ProfileExport.removeAll()
            result = (false, ProfileWords.exportFailed)
        }
    }
}
