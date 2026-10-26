import Foundation
import Network

/// A small HTTP server on 127.0.0.1 for slice E's tests (AIKeysTests, McFlyTests), so the app's own requests go out
/// through APIClient and its URLSession as they do against a real server: canned answers by method and path, an answer
/// held back for a while, a stream that stays open, and a log of every request with its body. A path it has no answer
/// for gets a server's catch-all 404 {"error":"Not found"}, as a server older than the route answers. Answers are made
/// up; nothing reaches a real server or provider.
final class AIStubServer: @unchecked Sendable {
    struct Request {
        let method: String
        /// Without its query.
        let path: String
        let headers: [String: String]
        let body: Data
        var text: String { String(decoding: body, as: UTF8.self) }
    }

    struct Answer {
        var status: Int
        var body: String
        var contentType = "application/json"
        /// Seconds before it's sent.
        var delay: TimeInterval = 0
        /// Sent as the start of a stream that stays open (chunked), until the client goes or the server stops.
        var holdOpen = false

        static func json(_ status: Int, _ body: String, delay: TimeInterval = 0) -> Answer { Answer(status: status, body: body, delay: delay) }

        /// Server-sent events, as /api/mcfly/chat writes them: `event: x`, `data: {...}`, then a blank line.
        static func events(_ events: [(String, String)], holdOpen: Bool = false) -> Answer {
            Answer(status: 200, body: events.map { "event: \($0.0)\ndata: \($0.1)\n\n" }.joined(), contentType: "text/event-stream", holdOpen: holdOpen)
        }
    }

    let url: URL
    private let listener: NWListener
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var answers: [String: Answer]
    private var log: [Request] = []
    private var open: [NWConnection] = []

    private init(listener: NWListener, queue: DispatchQueue, port: UInt16, answers: [String: Answer]) {
        self.listener = listener
        self.queue = queue
        self.answers = answers
        url = URL(string: "http://127.0.0.1:\(port)")!
    }

    /// `answers` by "METHOD /api/path", e.g. "POST /api/mcfly/chat".
    static func start(_ answers: [String: Answer]) async throws -> AIStubServer {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: params)
        let queue = DispatchQueue(label: "AIStubServer")
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            listener.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    resumed = true
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { $0.cancel() } // replaced below, once the server exists
            listener.start(queue: queue)
        }
        let server = AIStubServer(listener: listener, queue: queue, port: port, answers: answers)
        listener.newConnectionHandler = { [weak server] connection in
            guard let server else { return connection.cancel() }
            connection.start(queue: queue)
            server.read(connection, Data())
        }
        return server
    }

    func stop() {
        listener.cancel()
        lock.lock()
        let streams = open
        open = []
        lock.unlock()
        streams.forEach { $0.cancel() }
    }

    func set(_ key: String, _ answer: Answer) {
        lock.lock()
        answers[key] = answer
        lock.unlock()
    }

    /// Every request so far, or those to one "METHOD /api/path".
    func requests(_ key: String? = nil) -> [Request] {
        lock.lock()
        defer { lock.unlock() }
        guard let key else { return log }
        return log.filter { "\($0.method) \($0.path)" == key }
    }

    // MARK: HTTP

    private func read(_ connection: NWConnection, _ buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = Self.parse(buffer) {
                self.answer(request, on: connection)
            } else if done || error != nil {
                connection.cancel()
            } else {
                self.read(connection, buffer)
            }
        }
    }

    /// One whole request (its head, and as much body as Content-Length says), or nil while more is to come.
    static func parse(_ buffer: Data) -> Request? {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let lines = String(decoding: buffer[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = headers["content-length"].flatMap { Int($0) } ?? 0
        let body = buffer[end.upperBound...]
        guard body.count >= length else { return nil }
        let path = String(first[1].split(separator: "?", maxSplits: 1)[0])
        return Request(method: String(first[0]), path: path, headers: headers, body: Data(body.prefix(length)))
    }

    private func answer(_ request: Request, on connection: NWConnection) {
        lock.lock()
        log.append(request)
        let answer = answers["\(request.method) \(request.path)"] ?? .json(404, #"{"error":"Not found"}"#)
        if answer.holdOpen { open.append(connection) }
        lock.unlock()

        let body = Data(answer.body.utf8)
        let reason = HTTPURLResponse.localizedString(forStatusCode: answer.status)
        let head = "HTTP/1.1 \(answer.status) \(reason)\r\nContent-Type: \(answer.contentType)\r\nConnection: close\r\n"
        queue.asyncAfter(deadline: .now() + answer.delay) {
            if answer.holdOpen {
                let start = Data((head + "Cache-Control: no-cache\r\nTransfer-Encoding: chunked\r\n\r\n").utf8)
                let chunk = Data("\(String(body.count, radix: 16))\r\n".utf8) + body + Data("\r\n".utf8)
                connection.send(content: start + chunk, completion: .contentProcessed { _ in })
            } else {
                connection.send(content: Data((head + "Content-Length: \(body.count)\r\n\r\n").utf8) + body, contentContext: .finalMessage,
                                isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }

    // MARK: Waiting

    /// Waits until `condition` holds, or `seconds` pass; whether it held.
    @MainActor
    @discardableResult
    static func wait(_ seconds: Double = 5, until condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > end { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }
}
