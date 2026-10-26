import AVFAudio
import Foundation
import Observation

// Hold to talk (src/hooks/useVoiceNote.ts): a voice note recorded on the iPhone, sent once to POST /api/ai/transcribe as
// the raw recording, and its words handed back for the person to check. It never sends anything on its own: the words
// fill the composer, and nothing is estimated until the person sends them. The recording is AAC in an .m4a temp file
// for as long as it records, read into memory and deleted before it's sent; the server forwards it to OpenAI and keeps
// nothing. It's never kept, cached or logged.
// - Touch: press to record, let go to stop, at most a minute (well under the 4 MB upload limit).
// - VoiceOver, Switch Control and a keyboard: activating it starts, and again stops, since holding isn't something
//   everyone can do.

/// Why the microphone couldn't start.
enum VoiceProblem: Error, Equatable {
    case blocked, noMicrophone, inUse, couldNotStart

    /// In plain words (micProblem in useVoiceNote.ts; the iPhone's permission is in Settings, not a browser's).
    var message: String {
        switch self {
        case .blocked: "The microphone is blocked for healthOS. Allow it in Settings, or type instead."
        case .noMicrophone: "No microphone was found. Type what you had instead."
        case .inUse: "The microphone is in use by another app. Try again, or type instead."
        case .couldNotStart: "The microphone couldn't start. Type what you had instead."
        }
    }
}

/// What records a voice note: the microphone, or a stand-in in tests.
@MainActor
protocol VoiceRecording: AnyObject {
    /// Asks for the microphone the first time, then starts recording. Throws a VoiceProblem.
    func start() async throws
    /// Stops, and gives the recording's bytes (nil when there are none). Nothing of it stays on disk.
    func stop() -> Data?
    /// Stops and throws the recording away.
    func cancel()
}

/// A voice note's state and what it says (useVoiceNote).
@MainActor
@Observable
final class VoiceNote {
    enum State: Equatable { case idle, starting, recording, transcribing }
    /// How it was started: held down, or turned on and off (VoiceOver, Switch Control, a keyboard).
    enum Via: Equatable { case press, toggle }

    static let maxSeconds: TimeInterval = 60
    /// Shorter than this is a tap, not a note.
    static let minSeconds: TimeInterval = 0.5
    static let maxBytes = 4 * 1024 * 1024

    private(set) var state: State = .idle
    private(set) var seconds = 0
    private(set) var error: String?
    private(set) var via: Via = .press

    private let recorder: VoiceRecording
    private let transcribe: (Data) async throws -> String
    private let now: () -> Date
    /// The words, never called with nothing.
    var onText: (String) -> Void = { _ in }
    private var startedAt: Date?
    /// Let go before the recorder started (the microphone was still being asked for): don't record after all.
    private var released = false
    /// Which note this is. A new note, and leaving the page, move it on, so what comes back for an earlier note (its
    /// start, its words, its clock) is dropped and never touches the one after it.
    private var note = 0
    /// A start is still waiting for the recorder (the microphone's permission question). Only one at a time, so a
    /// start that comes back for a note given up on can stop its own recording and no other.
    private var waitingForRecorder = false
    private var ticker: Task<Void, Never>?
    private var writing: Task<Void, Never>?

    init(recorder: VoiceRecording, transcribe: @escaping (Data) async throws -> String, now: @escaping () -> Date = Date.init) {
        self.recorder = recorder
        self.transcribe = transcribe
        self.now = now
    }

    var byKey: Bool { via == .toggle }

    /// "Hold to talk", "Recording 0:05", "Writing it down…", "Starting the microphone…". On a phone the web leaves out
    /// the rest of the recording line (`more`), which VoiceOver still reads.
    var label: String {
        switch state {
        case .recording: "Recording \(seconds / 60):\(String(format: "%02d", seconds % 60))"
        case .transcribing: "Writing it down…"
        case .starting: "Starting the microphone…"
        case .idle: "Hold to talk"
        }
    }

    /// " · let go to stop", " · press again to stop" while recording.
    var more: String { state == .recording ? (byKey ? " · press again to stop" : " · let go to stop") : "" }

    func clearError() { error = nil }

    /// A finger down on the button.
    func press() {
        // A press during a recording started from VoiceOver or a keyboard stops it.
        if state == .recording, via == .toggle { return stop() }
        guard let id = prepare(.press) else { return }
        Task { await begin(.press, id) }
    }

    /// The finger lifted, or the touch was taken away (the microphone's permission question, a scroll): stops.
    func release() {
        if via == .press { stop() }
    }

    /// VoiceOver's activate, Switch Control or a keyboard: starts, and again stops.
    func toggle() {
        if state == .recording { stop() } else if let id = prepare(.toggle) { Task { await begin(.toggle, id) } }
    }

    /// Leaving the page (or the app going to the background) mid-note: the microphone stops, the recording is thrown
    /// away, and words still being written down for it are dropped. The button is ready again for the next note.
    func cancel() {
        note += 1
        ticker?.cancel()
        ticker = nil
        writing?.cancel()
        writing = nil
        if state == .starting || state == .recording { recorder.cancel() }
        state = .idle
        seconds = 0
    }

    func start(_ how: Via) async {
        guard let id = prepare(how) else { return }
        await begin(how, id)
    }

    /// Starting, right away: a release that comes before the microphone is ready is heard. The new note's number.
    private func prepare(_ how: Via) -> Int? {
        guard state == .idle, !waitingForRecorder else { return nil }
        note += 1
        error = nil
        via = how
        released = false
        state = .starting
        return note
    }

    private func begin(_ how: Via, _ id: Int) async {
        waitingForRecorder = true
        do {
            try await recorder.start()
        } catch {
            waitingForRecorder = false
            guard id == note else { return }
            state = .idle
            self.error = (error as? VoiceProblem ?? .couldNotStart).message
            return
        }
        waitingForRecorder = false
        if id != note || (how == .press && released) {
            recorder.cancel()
            if id == note {
                state = .idle
                error = "Hold the button while you talk, then let go."
            }
            return
        }
        startedAt = now()
        state = .recording
        seconds = 0
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, !Task.isCancelled, self.note == id, self.state == .recording, let startedAt = self.startedAt else { return }
                let took = self.now().timeIntervalSince(startedAt)
                self.seconds = Int(took)
                if took >= Self.maxSeconds { return self.stop() }
            }
        }
    }

    /// Stops the recording and writes it down.
    func stop() {
        released = true
        guard state == .recording else { return }
        ticker?.cancel()
        ticker = nil
        let took = startedAt.map { now().timeIntervalSince($0) } ?? 0
        let audio = recorder.stop()
        seconds = 0
        guard let audio, !audio.isEmpty, took >= Self.minSeconds else {
            state = .idle
            error = via == .press ? "Hold the button while you talk, then let go." : "That was too short to hear anything. Try again."
            return
        }
        guard audio.count <= Self.maxBytes else {
            state = .idle
            error = "That recording is too long. Keep voice notes to about a minute."
            return
        }
        state = .transcribing
        let id = note
        writing = Task { await written(audio, id) }
    }

    private func written(_ audio: Data, _ id: Int) async {
        // Only this note's own answer ends its "Writing it down…": a note given up on leaves the next one alone.
        defer { if id == note, state == .transcribing { state = .idle; writing = nil } }
        do {
            let words = try await transcribe(audio).trimmingCharacters(in: .whitespacesAndNewlines)
            guard id == note else { return }
            if words.isEmpty { error = "No words came through. Try again a little closer to the microphone." } else { onText(words) }
        } catch {
            guard id == note, !APIClient.isCancellation(error) else { return }
            self.error = error.foodMessage
        }
    }
}

/// The iPhone's microphone: AAC in an .m4a temp file while it records, read into memory and deleted when it stops.
/// The audio session is active only while recording.
@MainActor
final class MicrophoneRecorder: VoiceRecording {
    private static let prefix = "healthos-voice-"
    private var recorder: AVAudioRecorder?
    private var file: URL?

    init() { Self.removeLeftovers() }

    func start() async throws {
        switch AVAudioApplication.shared.recordPermission {
        case .denied: throw VoiceProblem.blocked
        case .undetermined:
            guard await AVAudioApplication.requestRecordPermission() else { throw VoiceProblem.blocked }
        default: break
        }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .default)
            try session.setActive(true)
        } catch {
            throw (error as NSError).code == AVAudioSession.ErrorCode.insufficientPriority.rawValue ? VoiceProblem.inUse : VoiceProblem.couldNotStart
        }
        guard session.isInputAvailable else {
            deactivate()
            throw VoiceProblem.noMicrophone
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(Self.prefix)\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        // One recording at a time: anything left of an earlier one goes first, its file included.
        recorder?.stop()
        recorder = nil
        removeFile()
        do {
            let r = try AVAudioRecorder(url: url, settings: settings)
            file = url
            guard r.record() else { throw VoiceProblem.couldNotStart }
            recorder = r
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        } catch {
            cancel()
            throw VoiceProblem.couldNotStart
        }
    }

    func stop() -> Data? {
        recorder?.stop()
        recorder = nil
        defer {
            removeFile()
            deactivate()
        }
        return file.flatMap { try? Data(contentsOf: $0) }
    }

    func cancel() {
        recorder?.stop()
        recorder = nil
        removeFile()
        deactivate()
    }

    private func removeFile() {
        if let file { try? FileManager.default.removeItem(at: file) }
        file = nil
    }

    private func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// A recording left behind (the app ended mid-note) goes too.
    static func removeLeftovers() {
        let dir = FileManager.default.temporaryDirectory
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }
}

extension APIClient {
    /// POST /api/ai/transcribe: a recording's words. The raw audio, typed by its format (AAC in MP4); the server checks
    /// its first bytes anyway.
    func transcribe(_ audio: Data) async throws -> String {
        struct Transcript: Decodable { let text: String }
        let data = try await request("/ai/transcribe", method: "POST", body: audio, contentType: "audio/mp4", timeout: 75)
        guard let t = try? JSONDecoder().decode(Transcript.self, from: data) else { throw FoodError(VoiceWords.notTranscribed) }
        return t.text
    }
}

enum VoiceWords {
    static let notTranscribed = "That recording couldn't be transcribed. Try again, or type it instead."
    static let unreachable = "Couldn't reach healthOS. Check your connection and try again."

    /// What a refused transcription says: the server's own words (a limit, no key, OpenAI busy); an older server
    /// without the route, or one that can't be reached, in the web's (useVoiceNote.ts transcribe). Signing in again
    /// and a cancellation pass through as they are.
    static func error(_ error: Error) -> Error {
        guard let api = error as? APIError else { return error }
        if api.routeMissing { return FoodError(notTranscribed) }
        if case .network = api { return FoodError(unreachable) }
        return api
    }
}

extension Dashboard {
    /// A voice note's words (a 401 drops to sign-in), with its refusals in `VoiceWords.error`'s words.
    func transcribe(_ audio: Data) async throws -> String {
        do {
            return try await fetch { try await $0.transcribe(audio) }
        } catch {
            throw VoiceWords.error(error)
        }
    }
}
