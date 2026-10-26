import UIKit
import XCTest
@testable import HealthOSSync

/// Answers for the server inside the export's own download (`ProfileExport.live`): the answer's head, its body in
/// pieces, and how it ends: whole, broken off, never answered, or still coming until it's cancelled.
final class ExportStubProtocol: URLProtocol {
    enum End {
        case finish
        case fail(URLError.Code)
        /// Says it has begun (`started`), then waits to be stopped.
        case hang
    }

    struct Script {
        var status: Int?
        var headers: [String: String] = [:]
        var chunks: [String] = []
        var end: End = .finish
    }

    static var script = Script()
    static var started: (() -> Void)?

    /// The head server/export.ts sends. Its JSON type matters: without one, URLSession holds the head back to sniff
    /// the body's type and, when the stream then breaks, reports only the failure, as if no answer had come.
    static let exportHead = ["Content-Type": "application/json; charset=utf-8"]

    static var session: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ExportStubProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let script = Self.script
        if let status = script.status, let url = request.url,
           let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: script.headers) {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        for chunk in script.chunks { client?.urlProtocol(self, didLoad: Data(chunk.utf8)) }
        // A moment later, as a server ends or breaks off a stream: an end in the same breath as the head would be
        // all URLSession reports.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { [self] in
            switch script.end {
            case .finish: client?.urlProtocolDidFinishLoading(self)
            case .fail(let code): client?.urlProtocol(self, didFailWithError: URLError(code))
            case .hang: Self.started?()
            }
        }
    }

    override func stopLoading() {}
}

/// Profile's export (slice D): the download as the app makes it, against a stand-in server, and the job that ties an
/// export to who asked for it.
@MainActor
final class ProfileExportTests: XCTestCase {
    private let base = URL(string: "http://127.0.0.1:9")!

    override func setUp() async throws {
        ProfileExport.removeAll()
        ExportStubProtocol.script = .init()
        ExportStubProtocol.started = nil
    }

    override func tearDown() async throws {
        ProfileExport.removeAll()
        ExportStubProtocol.script = .init()
        ExportStubProtocol.started = nil
    }

    // MARK: The download

    private func liveExport() async throws -> URL {
        let session = ExportStubProtocol.session
        defer { session.invalidateAndCancel() }
        return try await ProfileExport.run(client: APIClient(base: base), download: { try await ProfileExport.live($0, session: session) },
                                           today: "2026-10-26")
    }

    private func liveProblem() async -> Error? {
        do {
            _ = try await liveExport()
            return nil
        } catch {
            return error
        }
    }

    /// Everything under the export's folder, folders included.
    private func leftovers() -> [String] {
        FileManager.default.enumerator(atPath: ProfileExport.folder.path)?.allObjects.compactMap { $0 as? String } ?? []
    }

    /// What's at the top of the app's temporary folder, but the export's own folder: a system download task would
    /// leave a broken download's part here.
    private func temporaryFiles() -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? [])
            .subtracting(["healthos-export"])
    }

    func testAWholeAnswerIsWrittenStraightIntoAFileOfItsOwn() async throws {
        let before = temporaryFiles()
        ExportStubProtocol.script = .init(status: 200, headers: ExportStubProtocol.exportHead.merging(["Content-Disposition": #"attachment; filename="healthos-export-2026-10-25.json""#]) { $1 },
                                          chunks: [#"{"format":"healthos-export","#, #""version":1,"#, #""meals":[]}"#])
        let file = try await liveExport()
        XCTAssertEqual(file.lastPathComponent, "healthos-export-2026-10-25.json")
        XCTAssertEqual(file.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path, ProfileExport.folder.standardizedFileURL.path,
                       "in a folder of its own in the export's folder")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), #"{"format":"healthos-export","version":1,"meals":[]}"#, "every piece, in order")
        XCTAssertEqual(leftovers().filter { $0.hasSuffix(".part") }, [], "the part became the file")
        XCTAssertEqual(temporaryFiles().subtracting(before), [], "nothing anywhere else")
    }

    func testABrokenOffDownloadLeavesNothingOfItself() async throws {
        let before = temporaryFiles()
        ExportStubProtocol.script = .init(status: 200, headers: ExportStubProtocol.exportHead, chunks: [#"{"format":"healthos-export","meals":["#],
                                          end: .fail(.networkConnectionLost))
        let error = await liveProblem()
        XCTAssertEqual(error as? ProfileExport.Problem, ProfileExport.Problem(message: ProfileWords.exportStopped), "it began, then stopped")
        XCTAssertEqual(leftovers(), [], "no part, no folder")
        XCTAssertEqual(temporaryFiles().subtracting(before), [], "and nothing kept to resume it")
    }

    func testNoAnswerIsUnreachableAndLeavesNothing() async throws {
        let before = temporaryFiles()
        ExportStubProtocol.script = .init(status: nil, end: .fail(.cannotConnectToHost))
        let error = await liveProblem()
        XCTAssertEqual(error as? ProfileExport.Problem, ProfileExport.Problem(message: ProfileWords.exportUnreachable))
        XCTAssertEqual(leftovers(), [])
        XCTAssertEqual(temporaryFiles().subtracting(before), [])
    }

    func testARefusalThroughTheDownloadSaysTheServersWords() async throws {
        ExportStubProtocol.script = .init(status: 429, headers: ["Content-Type": "application/json", "Retry-After": "42"],
                                          chunks: [#"{"error":"Your export was just prepared. Try again in a minute."}"#])
        let error = await liveProblem()
        XCTAssertEqual((error as? ProfileExport.Problem)?.message, "Your export was just prepared. Try again in a minute.")
        XCTAssertEqual(leftovers(), [], "a refusal's body isn't kept")
    }

    func testCancellingMidDownloadStopsItAndLeavesNothing() async throws {
        let started = expectation(description: "the body has begun")
        ExportStubProtocol.started = { started.fulfill() }
        ExportStubProtocol.script = .init(status: 200, headers: ExportStubProtocol.exportHead, chunks: [#"{"format":"healthos-export","#], end: .hang)
        let session = ExportStubProtocol.session
        defer { session.invalidateAndCancel() }
        let task = Task {
            try await ProfileExport.run(client: APIClient(base: base), download: { try await ProfileExport.live($0, session: session) })
        }
        await fulfillment(of: [started], timeout: 5)
        task.cancel()
        switch await task.result {
        case .success: XCTFail("a cancelled export is no file")
        case .failure(let error): XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(leftovers(), [])
    }

    // MARK: The job

    private func person(_ id: String) -> AuthState.User {
        AuthState.User(id: id, email: "\(id)@example.test", name: nil, role: nil)
    }

    /// A dashboard with someone signed in on a server with sign-in.
    private func signedIn(_ id: String) -> Dashboard {
        let dashboard = Dashboard()
        dashboard.authMode = "required"
        dashboard.account = person(id)
        dashboard.phase = .ready
        return dashboard
    }

    /// Lets the job's work, and its look at who's signed in, run.
    private func settle() async {
        for _ in 0..<5 { try? await Task.sleep(for: .milliseconds(20)) }
    }

    /// A finished download, waiting in a folder of its own as `run` leaves it.
    private func downloaded() throws -> URL {
        let dir = ProfileExport.folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("healthos-export-2026-10-26.json")
        try Data(#"{"format":"healthos-export"}"#.utf8).write(to: file)
        return file
    }

    /// A download the test lets finish when it likes.
    private final class Gate {
        var waiting: CheckedContinuation<URL, Error>?
        var asked = 0
        func open(_ file: URL) { waiting?.resume(returning: file); waiting = nil }
        func fail(_ error: Error) { waiting?.resume(throwing: error); waiting = nil }
    }

    private func job(_ gate: Gate, shown: @escaping (URL, @escaping () -> Void, @escaping () -> Void) -> UIViewController?) -> ProfileExportJob {
        let job = ProfileExportJob()
        job.perform = { _ in
            gate.asked += 1
            return try await withCheckedThrowingContinuation { gate.waiting = $0 }
        }
        job.present = { file, completed, gone in shown(file, completed, gone) }
        return job
    }

    /// Person A asks for their export, signs out while it's still preparing, and person B signs in before it ends: A's
    /// record never reaches B's share sheet, and its file goes.
    func testAnExportOnItsWayAtSignOutNeverReachesTheNextPerson() async throws {
        let dashboard = signedIn("a")
        let gate = Gate()
        var shared = 0
        let job = job(gate) { _, _, _ in shared += 1; return UIViewController() }
        job.start(dashboard)
        await settle()
        XCTAssertTrue(job.busy)
        dashboard.phase = .signIn
        await settle()
        XCTAssertFalse(job.busy, "the download stops with the sign-out, wherever the app is")
        dashboard.account = person("b")
        dashboard.phase = .ready
        await settle()
        let file = try downloaded()
        // The server had already sent it all.
        gate.open(file)
        await settle()
        XCTAssertEqual(shared, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertNil(job.result)
    }

    /// Someone else signed in without the phase leaving ready (the status says who it is now): the same.
    func testAnotherAccountWhileItsPreparingDropsIt() async throws {
        let dashboard = signedIn("a")
        let gate = Gate()
        var shared = 0
        let job = job(gate) { _, _, _ in shared += 1; return UIViewController() }
        job.start(dashboard)
        await settle()
        dashboard.account = person("b")
        await settle()
        XCTAssertFalse(job.busy)
        let file = try downloaded()
        gate.open(file)
        await settle()
        XCTAssertEqual(shared, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testWhoAskedIsTheServerAndTheAccount() {
        let server = URL(string: "http://127.0.0.1:8804")!
        let asked = ProfileExportJob.Owner(server: server, user: "a", mode: "required")
        XCTAssertTrue(asked.same(as: .init(server: server, user: "a", mode: "required")))
        XCTAssertFalse(asked.same(as: .init(server: server, user: "b", mode: "required")), "someone else")
        XCTAssertFalse(asked.same(as: .init(server: URL(string: "http://127.0.0.1:8805")!, user: "a", mode: "required")), "another server")
        XCTAssertFalse(asked.same(as: .init(server: nil, user: "a", mode: "required")), "no server any more")
        XCTAssertFalse(asked.same(as: .init(server: server, user: "a", mode: "open")))
        // Not known when they asked (the status came after): still them.
        XCTAssertTrue(ProfileExportJob.Owner(server: server, user: nil, mode: nil).same(as: asked))
        XCTAssertTrue(asked.same(as: .init(server: server, user: nil, mode: "required")))
    }

    /// Leaving Profile while it's preparing and coming back: still preparing, and a second tap starts nothing that
    /// would throw the first away. Its share sheet still comes.
    func testOneExportAtATimeOutlivesProfilesRow() async throws {
        let dashboard = signedIn("a")
        let gate = Gate()
        let sheet = UIViewController()
        var shownFile: URL?
        var completed: (() -> Void)?
        var gone: (() -> Void)?
        let job = job(gate) { file, done, closed in
            shownFile = file
            completed = done
            gone = closed
            return sheet
        }
        job.start(dashboard)
        await settle()
        job.rowGone()
        job.start(dashboard)
        await settle()
        XCTAssertTrue(job.busy, "still preparing")
        XCTAssertEqual(gate.asked, 1, "one export, not a second that discards the first")
        let file = try downloaded()
        gate.open(file)
        await settle()
        XCTAssertFalse(job.busy)
        XCTAssertEqual(shownFile, file, "shared with the one who asked")
        XCTAssertNil(job.result, "nothing done with it yet")
        // An activity cancelled with the sheet still up: nothing said, the file still there to try again.
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        completed?()
        XCTAssertEqual(job.result, .init(ok: true, text: "Saved healthos-export-2026-10-26.json."))
        job.rowGone()
        XCTAssertNotNil(job.result, "kept while its sheet is up")
        gone?()
        gone?()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "deleted once the sheet has gone")
        XCTAssertNotNil(job.result, "the line stays while the row shows")
        job.rowGone()
        XCTAssertNil(job.result, "and goes with the row, as the web's")
        _ = sheet
    }

    /// A sign-out (a 401 from a check in the background) while the share sheet is up: the sheet goes with what it
    /// showed, and the file and the line with it.
    func testSigningOutTakesTheShareSheetAndTheFile() async throws {
        final class Presenter: UIViewController {
            var dismissed = false
            override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) { dismissed = true }
        }
        final class Sheet: UIViewController {
            let presenter = Presenter()
            override var presentingViewController: UIViewController? { presenter }
        }
        let dashboard = signedIn("a")
        let gate = Gate()
        let sheet = Sheet()
        var completed: (() -> Void)?
        let job = job(gate) { _, done, _ in completed = done; return sheet }
        job.start(dashboard)
        await settle()
        let file = try downloaded()
        gate.open(file)
        await settle()
        completed?()
        XCTAssertNotNil(job.result)
        dashboard.phase = .signIn
        await settle()
        XCTAssertTrue(sheet.presenter.dismissed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertNil(job.result, "nothing of theirs for whoever signs in next")
        // A completion that comes after it went says nothing.
        completed?()
        XCTAssertNil(job.result)
    }

    func testAFailureSaysSoAndAnOlderServerLosesTheButton() async throws {
        let dashboard = signedIn("a")
        let gate = Gate()
        let job = job(gate) { _, _, _ in XCTFail("nothing to share"); return nil }
        job.start(dashboard)
        await settle()
        gate.fail(ProfileExport.Problem(message: ProfileWords.exportNotHere, routeMissing: true))
        await settle()
        XCTAssertFalse(job.busy)
        XCTAssertTrue(job.missing)
        XCTAssertEqual(job.result, .init(ok: false, text: ProfileWords.exportNotHere))
        // Another server may have it: the next look asks again.
        dashboard.phase = .signIn
        await settle()
        XCTAssertFalse(job.missing)
        XCTAssertNil(job.result)
    }

    func testNowhereToShowItIsAFailureAndNoFile() async throws {
        let dashboard = signedIn("a")
        let gate = Gate()
        let job = job(gate) { _, _, _ in nil }
        job.start(dashboard)
        await settle()
        let file = try downloaded()
        gate.open(file)
        await settle()
        XCTAssertEqual(job.result, .init(ok: false, text: ProfileWords.exportFailed))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testNothingStartsWhileNobodysSignedIn() async {
        let dashboard = signedIn("a")
        dashboard.phase = .signIn
        let gate = Gate()
        let job = job(gate) { _, _, _ in nil }
        job.start(dashboard)
        await settle()
        XCTAssertFalse(job.busy)
        XCTAssertEqual(gate.asked, 0)
    }

    func testAClosingStepRunsOnce() {
        var runs = 0
        let once = ProfileExport.Once { runs += 1 }
        once()
        once()
        XCTAssertEqual(runs, 1)
    }
}

