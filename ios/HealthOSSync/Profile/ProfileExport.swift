import Observation
import SwiftUI
import UIKit

/// "Export your data" (GET /api/me/export, server/export.ts): everything the person stored, as one JSON file, built only
/// from their own session. The server streams it with no length, so it's downloaded straight into a file in a folder
/// of its own under the app's temporary directory (complete file protection), never in memory as a whole, never in
/// Documents or the ProfileImages cache, and never logged. The share sheet hands it on. The folder is deleted when the
/// sheet has gone, before the next export, at every launch (AppDelegate), and the moment nobody's signed in, the server
/// changes or someone else is signed in (`ProfileExportJob`). Nutrition amounts the person's Nutrition setting hides
/// are already left out by the server; nothing here adds any back.
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
            (file, response) = try await (download ?? { try await live($0) })(request)
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
            throw refusal(body, response, client: client, sent: SessionStore.carried(by: request))
        }
        // A new session cookie, if one came, is kept as for any answer.
        _ = try? client.checked(Data(), response, path: path, sent: SessionStore.carried(by: request))
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
            // Only this export's own folder: another may have started since.
            try? FileManager.default.removeItem(at: dir)
            throw Problem(message: ProfileWords.exportFailed)
        }
    }

    /// A download not handed on: the file, and the folder it was written into when that's one of the export's own.
    static func discard(_ file: URL) {
        try? FileManager.default.removeItem(at: file)
        let parent = file.deletingLastPathComponent()
        if isInFolder(parent) { try? FileManager.default.removeItem(at: parent) }
    }

    private static func isInFolder(_ dir: URL) -> Bool {
        dir.standardizedFileURL.deletingLastPathComponent().path == folder.standardizedFileURL.path
    }

    /// The error for a refused export: signed out, an older server, or the server's words (the web's fallback when
    /// it sent none).
    static func refusal(_ body: Data, _ response: URLResponse, client: APIClient, sent: String?) -> Error {
        do {
            _ = try client.checked(body, response, path: path, sent: sent)
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
        } catch is CancellationError {
            // A 401 for a session that ended since, someone else's now: nothing to say.
            return CancellationError()
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
    /// `session` is the app's own; tests pass one that answers for the server.
    static func live(_ request: URLRequest, session: URLSession = APIClient.session) async throws -> (URL, URLResponse) {
        let dir = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let file = dir.appendingPathComponent("download.part")
        let writer: StreamWriter
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
            guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.protectionKey: FileProtectionType.complete]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            writer = try StreamWriter(file: file)
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw Failure.unreachable
        }
        let task = session.dataTask(with: request)
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

    /// Hands the file to the share sheet (Save to Files, AirDrop, …), over whatever is showing, and returns the sheet;
    /// nil when there was nowhere to show it. `completed` runs each time something was done with the file. `gone` runs
    /// once, when the sheet has really gone: not when an activity in it is cancelled (Save to Files, then Cancel, puts
    /// the sheet back, and its completion is called anyway), but when the sheet is dismissed.
    @MainActor
    static func share(_ file: URL, completed: @escaping () -> Void, gone: @escaping () -> Void) -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let root = scenes.flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController else { return nil }
        var top = root
        while let shown = top.presentedViewController, !shown.isBeingDismissed { top = shown }
        let once = Once(gone)
        let sheet = ProfileExportSheet(activityItems: [file], applicationActivities: nil)
        sheet.onGone = once
        sheet.completionWithItemsHandler = { [weak sheet] _, done, _, _ in
            Task { @MainActor in
                if done { completed() }
                // Dismissed along with what it showed, which can skip its own disappearing: gone once nothing shows it.
                try? await Task.sleep(for: .seconds(1))
                if sheet == nil || (sheet?.presentingViewController == nil && sheet?.viewIfLoaded?.window == nil) { once() }
            }
        }
        // A popover only at regular width (the open iPhone Duo): it points at Download JSON (design §2.7).
        if let popover = sheet.popoverPresentationController {
            ProfileExportAnchor.shared.point(popover, fallback: top.view)
        }
        top.present(sheet, animated: true)
        return sheet
    }

    /// A closing step that runs at most once, however many ways say it's time.
    @MainActor
    final class Once {
        private var action: (() -> Void)?
        init(_ action: @escaping () -> Void) { self.action = action }
        func callAsFunction() {
            let run = action
            action = nil
            run?()
        }
    }
}

/// Where the share sheet points from where it shows as a popover (regular width: the open iPhone Duo): the export row's
/// Download JSON button. A fold can make the row again (from the page's one column into a pane), so the popover that's
/// up moves to the button that's there now, and a change of window size points it at that button too. With no button
/// in a window it points at the middle of what's showing, as before. Every other iPhone shows the share sheet as a
/// sheet, where none of this is used.
@MainActor
final class ProfileExportAnchor: NSObject, UIPopoverPresentationControllerDelegate {
    static let shared = ProfileExportAnchor()

    /// The button's stand-in now in a window, if any.
    private(set) weak var view: UIView?
    /// The share sheet's popover while it's up.
    private weak var popover: UIPopoverPresentationController?

    /// Points `popover` at the button, or at the middle of `fallback` without one, and follows it from now on.
    func point(_ popover: UIPopoverPresentationController, fallback: UIView) {
        if let view, view.window != nil {
            popover.sourceView = view
            popover.sourceRect = view.bounds
        } else {
            popover.sourceView = fallback
            popover.sourceRect = CGRect(x: fallback.bounds.midX, y: fallback.bounds.midY, width: 0, height: 0)
        }
        popover.delegate = self
        self.popover = popover
    }

    /// A button came into a window (Profile showing, or its row made again after a fold): the popover that's up moves to it.
    func arrived(_ view: UIView) {
        self.view = view
        guard let popover, popover.presentedViewController.presentingViewController != nil else { return }
        popover.sourceView = view
        popover.sourceRect = view.bounds
        popover.containerView?.setNeedsLayout()
    }

    /// A button left its window: no longer the one to point at, unless another has come since.
    func left(_ view: UIView) {
        if self.view === view { self.view = nil }
    }

    /// The window changed size (a fold): the popover points at the button that's there now.
    func popoverPresentationController(_ popoverPresentationController: UIPopoverPresentationController,
                                       willRepositionPopoverTo rect: UnsafeMutablePointer<CGRect>,
                                       in view: AutoreleasingUnsafeMutablePointer<UIView>) {
        guard let anchor = self.view, anchor.window != nil else { return }
        view.pointee = anchor
        rect.pointee = anchor.bounds
    }
}

/// Download JSON's stand-in for the share sheet's popover: an empty view behind the button that tells
/// `ProfileExportAnchor` when it's in a window. It draws nothing, takes no touches and isn't read by VoiceOver.
struct ProfileExportAnchorView: UIViewRepresentable {
    func makeUIView(context: Context) -> Stand { Stand() }
    func updateUIView(_ uiView: Stand, context: Context) {}

    final class Stand: UIView {
        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            isAccessibilityElement = false
            backgroundColor = .clear
        }

        required init?(coder: NSCoder) { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { ProfileExportAnchor.shared.arrived(self) } else { ProfileExportAnchor.shared.left(self) }
        }
    }
}

/// The export's share sheet, which says when it has been dismissed: not when something it presented (the Files
/// browser) covers it or goes, only when it goes itself.
final class ProfileExportSheet: UIActivityViewController {
    var onGone: ProfileExport.Once?

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil { onGone?.callAsFunction() }
    }
}

/// "Export your data" while it's on its way and while its file waits in the share sheet. One at a time for the whole
/// app, so it outlives Profile's row: leave Profile while it's preparing and it's still "Preparing…" when you're back,
/// with no second export to throw the first away, and the share sheet still comes, over whatever is showing, as the
/// web's download still lands after leaving its page. It's tied to who asked for it: the moment nobody's signed in,
/// another server is set or someone else is signed in, wherever the app is, the download stops, the share sheet goes,
/// the file is deleted and the line under the row goes.
@MainActor
@Observable
final class ProfileExportJob {
    static let shared = ProfileExportJob()

    /// Who asked: the server, and the account and sign-in mode as far as they're known.
    struct Owner: Equatable {
        var server: URL?
        var user: String?
        var mode: String?

        init(server: URL?, user: String?, mode: String?) {
            self.server = server
            self.user = user
            self.mode = mode
        }

        @MainActor
        init(_ dashboard: Dashboard) {
            self.init(server: APIClient.current()?.base, user: dashboard.status?.user?.id ?? dashboard.account?.id, mode: dashboard.authMode)
        }

        /// Still the one who asked. An account or mode not known yet when they asked (the status came after) doesn't
        /// make them someone else; another server, or another account, does.
        func same(as now: Owner) -> Bool {
            server == now.server && (user == nil || now.user == nil || user == now.user) && (mode == nil || now.mode == nil || mode == now.mode)
        }
    }

    /// The line under the row: "Saved <name>." or what went wrong.
    struct Line: Equatable {
        let ok: Bool
        let text: String
    }

    private(set) var busy = false
    private(set) var result: Line?
    /// The server answered that it has no export: it's older than it.
    private(set) var missing = false

    /// The download, and the share sheet: the app's own; tests pass theirs.
    @ObservationIgnored var perform: @MainActor (Dashboard) async throws -> URL = { dashboard in
        try await dashboard.fetch { try await ProfileExport.run(client: $0) }
    }
    @ObservationIgnored var present: @MainActor (URL, _ completed: @escaping () -> Void, _ gone: @escaping () -> Void) -> UIViewController? = { file, completed, gone in
        ProfileExport.share(file, completed: completed, gone: gone)
    }

    @ObservationIgnored private weak var dashboard: Dashboard?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var owner: Owner?
    @ObservationIgnored private weak var sheet: UIViewController?
    /// Goes up with every export and every drop, so one dropped can't land.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var watching = false

    init() {}

    /// Download JSON: unless one is already on its way, and only while someone's signed in (or the server has no
    /// sign-in).
    func start(_ dashboard: Dashboard) {
        guard !busy, dashboard.phase == .ready else { return }
        self.dashboard = dashboard
        generation += 1
        let generation = generation
        owner = Owner(dashboard)
        busy = true
        result = nil
        missing = false
        watch()
        let perform = perform
        task = Task { [weak self] in
            let outcome: Result<URL, Error>
            do {
                outcome = .success(try await perform(dashboard))
            } catch {
                outcome = .failure(error)
            }
            if let self {
                self.finish(outcome, generation: generation)
            } else if case .success(let file) = outcome {
                ProfileExport.discard(file)
            }
        }
    }

    /// Nobody's signed in, another server, or someone else: the download stops, the share sheet goes with what it
    /// showed, and the file and the line go.
    func drop() {
        generation += 1
        task?.cancel()
        task = nil
        busy = false
        result = nil
        missing = false
        owner = nil
        if let presenter = sheet?.presentingViewController { presenter.dismiss(animated: false) }
        sheet = nil
        ProfileExport.removeAll()
    }

    /// Profile went (Back, another tab; ProfileScreen calls it): the row's line goes with it, as the web's does, unless
    /// an export is still on its way or its share sheet is up.
    func rowGone() {
        guard !busy, sheet == nil else { return }
        result = nil
        missing = false
    }

    private func finish(_ outcome: Result<URL, Error>, generation: Int) {
        guard generation == self.generation else {
            // Dropped while it was on its way: whatever it brought goes, and nothing of a newer one.
            if case .success(let file) = outcome { ProfileExport.discard(file) }
            return
        }
        task = nil
        busy = false
        switch outcome {
        case .failure(let error):
            if error is CancellationError { break }
            if let problem = error as? ProfileExport.Problem {
                missing = problem.routeMissing
                result = Line(ok: false, text: problem.message)
            } else if dashboard?.phase == .ready {
                // Signed out (the sign-in screen takes over), or no server.
                result = Line(ok: false, text: error.localizedDescription)
            }
        case .success(let file):
            // Only to the one who asked, still signed in on the same server.
            guard let dashboard, dashboard.phase == .ready, owner?.same(as: Owner(dashboard)) == true else {
                ProfileExport.discard(file)
                drop()
                return
            }
            let name = file.lastPathComponent
            let shown = present(file, { [weak self] in
                guard let self, generation == self.generation else { return }
                self.result = Line(ok: true, text: ProfileWords.exportSaved(name))
            }, { [weak self] in
                ProfileExport.discard(file)
                guard let self, generation == self.generation else { return }
                self.sheet = nil
            })
            if let shown {
                sheet = shown
            } else {
                ProfileExport.discard(file)
                result = Line(ok: false, text: ProfileWords.exportFailed)
            }
        }
        watch()
    }

    /// Something to protect: an export on its way, its share sheet, or the line it left.
    private var holding: Bool { busy || sheet != nil || result != nil }

    /// Looks at who's signed in again whenever the phase, the account, the sign-in mode or the status changes, wherever
    /// the app is, for as long as there's something to protect.
    private func watch() {
        guard !watching, holding, let dashboard else { return }
        watching = true
        withObservationTracking {
            _ = dashboard.phase
            _ = dashboard.authMode
            _ = dashboard.account
            _ = dashboard.status
        } onChange: { [weak self] in
            // Called as the value is about to change: look once it has.
            Task { @MainActor in self?.check() }
        }
    }

    private func check() {
        watching = false
        guard let dashboard else { return }
        if dashboard.phase != .ready || owner.map({ !$0.same(as: Owner(dashboard)) }) == true { drop() }
        watch()
    }
}

/// Profile's "Export your data" row: Download JSON (Preparing… while the server builds it), then the share sheet.
/// Under the row, "Saved <name>." or what went wrong, read out as it changes. A server that answers it has no export
/// (older than it) gets no button again. On the open iPhone Duo the share sheet is a popover from Download JSON.
struct ProfileExportRow: View {
    var divider = true
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        let job = ProfileExportJob.shared
        ProfileRow("Export your data", divider: divider) {
            Text(ProfileWords.exportLine)
            if let result = job.result {
                Text(result.text).foregroundStyle(result.ok ? Palette.accentText : Palette.critical)
                    .accessibilityIdentifier("exportResult")
            }
        } action: {
            if !job.missing {
                Button(job.busy ? "Preparing…" : "Download JSON") { job.start(dashboard) }
                    .buttonStyle(ProfilePillStyle())
                    .disabled(job.busy)
                    .accessibilityIdentifier("exportData")
                    // Where the share sheet points from as a popover (the open iPhone Duo).
                    .background(ProfileExportAnchorView().accessibilityHidden(true))
            }
        }
        .onChange(of: job.result?.text) { _, text in
            if let text { UIAccessibility.post(notification: .announcement, argument: text) }
        }
        // Its line goes when Profile goes (ProfileScreen), not when a fold only moves this row into a pane.
    }
}
