import XCTest
@testable import HealthOSSync

// The Journal page (slice K, Journal/): its words against the web's own file, the web's rules for the words and times
// a check-in shows, the link that asks for the composer, and the model against counting fake calls: an older server's
// 404 hides the page while a failure never does, late answers are dropped, a failed save keeps the draft, and a change
// in place keeps its words in the model. Every check-in here is made up. Slice K owns this file.

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(json.utf8))
}

/// Three made-up check-ins over two days, and older ones before the 90 days.
let journalFixtureJSON = #"""
{"today":"2026-10-26","older":true,"entries":[
 {"id":"e1","date":"2026-10-26","time":"08:10","mood":4,"text":"Made-up morning line.","createdAt":1,"updatedAt":1},
 {"id":"e2","date":"2026-10-25","time":"21:40","mood":3,"text":"Made-up evening line,\nover two lines.","createdAt":2,"updatedAt":2},
 {"id":"e3","date":"2026-10-25","time":"07:55","mood":null,"text":"Made-up line with no mood.","createdAt":3,"updatedAt":3}
]}
"""#

/// Calls that count themselves and answer what the test says, in place of the server.
@MainActor
final class FakeJournalCalls {
    var reads: [Int] = []
    var added: [(String, Mood?)] = []
    var updated: [(String, String, Mood?)] = []
    var deleted: [String] = []
    var deletedAll = 0
    /// What a read answers for its days (nil: a server without the journal); `readError` throws instead.
    var answer: (Int) throws -> JournalData?
    var readError: Error?
    /// Waits before a read answers (the first read only, when set), so a later read can land first.
    var firstReadDelay: Duration?
    var addError: Error?
    var updateError: Error?
    var deleteError: Error?
    var deleteAllError: Error?

    init(_ json: String = journalFixtureJSON) {
        let data = try? decode(JournalData.self, json)
        answer = { _ in data }
    }

    var calls: JournalModel.Calls {
        JournalModel.Calls(
            read: { days in
                self.reads.append(days)
                // The answer is the one for when it was asked, however long it then takes.
                let first = self.reads.count == 1
                let reply = Result { try self.answer(days) }
                let error = self.readError
                if first, let delay = self.firstReadDelay { try await Task.sleep(for: delay) }
                if let error { throw error }
                return try reply.get()
            },
            add: { text, mood in
                self.added.append((text, mood))
                if let error = self.addError { throw error }
                return try decode(JournalEntry.self, #"{"id":"new","date":"2026-10-26","time":"21:46","text":"x","createdAt":9,"updatedAt":9}"#)
            },
            update: { id, text, mood in
                self.updated.append((id, text, mood))
                if let error = self.updateError { throw error }
                let mood = mood.map { "\($0.rawValue)" } ?? "null"
                let json = #"{"id":"\#(id)","date":"2026-10-26","time":"08:10","mood":\#(mood),"text":"changed","createdAt":1,"updatedAt":50}"#
                return try decode(JournalEntry.self, json)
            },
            delete: { id in
                self.deleted.append(id)
                if let error = self.deleteError { throw error }
            },
            deleteAll: {
                self.deletedAll += 1
                if let error = self.deleteAllError { throw error }
            })
    }
}

@MainActor
final class JournalTests: XCTestCase {
    /// A file of the web app, next to the iPhone app in the repository, its runs of spaces made one.
    private func web(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(path)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { throw XCTSkip("\(path) isn't next to the app") }
        return text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    private let us = Locale(identifier: "en_US")

    // MARK: The web's words and numbers

    func testTheWordsAreTheWebsOwn() throws {
        let page = try web("src/pages/Journal.tsx")
        let words = [
            JournalWords.title, JournalWords.sub, JournalWords.opening, JournalWords.couldNotOpen, JournalWords.newCheckIn,
            JournalWords.moods, JournalWords.box, JournalWords.placeholder, JournalWords.save, JournalWords.saving, JournalWords.saved,
            JournalWords.stillHere, JournalWords.history, JournalWords.empty, "No check-ins in the last ${RECENT_DAYS} days.",
            JournalWords.showEarlier, JournalWords.loading, JournalWords.moreFailed, JournalWords.privacy, JournalWords.deleteAll,
            JournalWords.deleteAllAsk, JournalWords.edit, JournalWords.delete, JournalWords.saveChanges, JournalWords.cancel,
            JournalWords.writeAFew, "Delete the check-in from ${when}? It can’t be undone.", "Edit the check-in from ${when}",
            "Delete the check-in from ${when}", "Mood for the check-in from ${when}", "The check-in from {when}",
            "'character' : 'characters'} left",
        ]
        for w in words { XCTAssertTrue(page.contains(w), "Journal.tsx says \"\(w)\"") }
        XCTAssertEqual(JournalWords.noneRecent(JournalText.recentDays), "No check-ins in the last 90 days.")
        XCTAssertEqual(JournalWords.deleteAsk("today at 8:10 AM"), "Delete the check-in from today at 8:10 AM? It can’t be undone.")
        XCTAssertTrue(page.contains("const COUNT_FROM = \(JournalText.countFrom);"))
        XCTAssertTrue(page.contains("const RECENT_DAYS = \(JournalText.recentDays);"))
        XCTAssertTrue(page.contains("const ALL_DAYS = \(JournalText.allDays);"))
        XCTAssertTrue(page.contains("{ 1: 'badge-peach', 2: 'badge-peach', 3: 'badge-muted', 4: 'badge-sage', 5: 'badge-sage' }"))
        let shared = try web("shared/journal.ts")
        XCTAssertTrue(shared.contains("JOURNAL_MAX_CHARS = \(JournalLimits.maxChars);"))
        for mood in Mood.allCases { XCTAssertTrue(shared.contains("{ value: \(mood.rawValue), label: '\(mood.label)' }"), mood.label) }
    }

    func testMoodTonesAreTheWebsBadges() {
        XCTAssertEqual(JournalText.tone(.rough), .peach)
        XCTAssertEqual(JournalText.tone(.low), .peach)
        XCTAssertEqual(JournalText.tone(.okay), .muted)
        XCTAssertEqual(JournalText.tone(.good), .sage)
        XCTAssertEqual(JournalText.tone(.great), .sage)
    }

    // MARK: Words and times

    func testTheLimitCountsAsTheServerDoes() {
        XCTAssertEqual(JournalText.length("😀"), 2, "JavaScript's .length: UTF-16 units")
        let full = String(repeating: "a", count: JournalLimits.maxChars)
        XCTAssertEqual(JournalText.clamp(full), full)
        XCTAssertEqual(JournalText.clamp(full + "b"), full)
        // An emoji that would end past the limit goes whole, never half.
        let edge = String(repeating: "a", count: JournalLimits.maxChars - 1) + "😀"
        XCTAssertEqual(JournalText.clamp(edge), String(repeating: "a", count: JournalLimits.maxChars - 1))
    }

    func testCharactersLeftShowFrom3500() {
        XCTAssertNil(JournalText.left(String(repeating: "a", count: 3499), locale: us))
        XCTAssertEqual(JournalText.left(String(repeating: "a", count: 3500), locale: us), "500 characters left")
        XCTAssertEqual(JournalText.left(String(repeating: "a", count: 3999), locale: us), "1 character left")
        XCTAssertEqual(JournalText.left(String(repeating: "a", count: 4000), locale: us), "0 characters left")
    }

    func testTimesFollowTheDevicesClock() {
        let plain = { (s: String) in s.replacingOccurrences(of: "\u{202F}", with: " ") }
        XCTAssertEqual(plain(JournalText.clock("21:41", locale: us)), "9:41 PM")
        XCTAssertEqual(plain(JournalText.clock("08:05", locale: us)), "8:05 AM")
        XCTAssertEqual(JournalText.clock("21:41", locale: Locale(identifier: "en_GB")), "21:41")
        XCTAssertEqual(JournalText.clock("odd", locale: us), "odd", "a time that isn't HH:MM shows as kept")
    }

    func testDaysAreTodayYesterdayOrTheDate() {
        XCTAssertEqual(JournalText.day("2026-10-26", today: "2026-10-26", locale: us), "Today")
        XCTAssertEqual(JournalText.day("2026-10-25", today: "2026-10-26", locale: us), "Yesterday")
        XCTAssertEqual(JournalText.day("2026-10-19", today: "2026-10-26", locale: us), "Mon, Oct 19")
        XCTAssertEqual(JournalText.day("2025-12-30", today: "2026-01-02", locale: us), "Tue, Dec 30, 2025", "another year names it")
        XCTAssertEqual(JournalText.when(day: "Today", clock: "8:10 AM"), "today at 8:10 AM")
        XCTAssertEqual(JournalText.when(day: "Mon, Oct 19", clock: "8:10 AM"), "Mon, Oct 19 at 8:10 AM")
    }

    func testTheLineOverTheMoodsIsNowInThePersonsZone() throws {
        let at = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-27T01:46:00Z"))
        XCTAssertEqual(JournalText.now(at, timeZone: "America/New_York", locale: us).replacingOccurrences(of: "\u{202F}", with: " "),
                       "Monday 9:46 PM")
        XCTAssertEqual(JournalText.now(at, timeZone: "Europe/London", locale: Locale(identifier: "en_GB")), "Tuesday 01:46")
        // A zone this iPhone doesn't know: its own, never a crash or a blank.
        XCTAssertFalse(JournalText.now(at, timeZone: "Not/AZone", locale: us).isEmpty)
    }

    func testCheckInsGroupByDayInTheirOrder() throws {
        let data = try decode(JournalData.self, journalFixtureJSON)
        let groups = JournalText.days(data.entries)
        XCTAssertEqual(groups.map(\.date), ["2026-10-26", "2026-10-25"])
        XCTAssertEqual(groups[1].entries.map(\.id), ["e2", "e3"])
    }

    // MARK: The link

    func testALinkAsksForTheComposerOnce() {
        var link = JournalLink()
        let first = RouteRequest(route: AppRoute(.journal, query: ["new": "1"]), id: 3)
        XCTAssertFalse(link.take(first), "nothing is taken before the page shows")
        XCTAssertTrue(link.start(new: true, current: first))
        XCTAssertFalse(link.start(new: true, current: first), "the first showing only")
        XCTAssertFalse(link.take(first), "the request it started with is spent")
        let again = RouteRequest(route: AppRoute(.journal, query: ["new": "1"]), id: 4)
        XCTAssertTrue(link.take(again), "Home's card tapped again while the page is up")
        XCTAssertFalse(link.take(again))
        XCTAssertFalse(link.take(RouteRequest(route: .journal, id: 5)), "Journal from More asks for nothing")
        XCTAssertFalse(link.take(nil))

        var plain = JournalLink()
        XCTAssertFalse(plain.start(new: false, current: first), "opened from More after the last link: not taken again")
        XCTAssertFalse(plain.take(first))
    }

    // MARK: Reading

    func testAnOlderServerHidesTheJournalAndAFailureNeverDoes() async {
        let fake = FakeJournalCalls()
        fake.answer = { _ in nil }
        let model = JournalModel(calls: fake.calls)
        await model.load()
        XCTAssertTrue(model.missing, "an older server's catch-all 404 (optional() → nil)")
        XCTAssertFalse(model.failed)

        for error: Error in [URLError(.notConnectedToInternet), APIError.server(500, "Something went wrong"), APIError.network("offline")] {
            let failing = FakeJournalCalls()
            failing.readError = error
            let model = JournalModel(calls: failing.calls)
            await model.load()
            XCTAssertTrue(model.failed, "\(error)")
            XCTAssertFalse(model.missing, "a failure is never \"not on this server\": \(error)")
            XCTAssertNil(model.data)
            failing.readError = nil
            await model.load()
            XCTAssertFalse(model.failed)
            XCTAssertEqual(model.data?.entries.count, 3)
        }
    }

    func testALateAnswerIsDropped() async throws {
        let fake = FakeJournalCalls()
        let stale = try decode(JournalData.self, #"{"today":"2026-10-26","entries":[]}"#)
        let fresh = try decode(JournalData.self, journalFixtureJSON)
        fake.answer = { _ in fake.reads.count == 1 ? stale : fresh }
        fake.firstReadDelay = .milliseconds(300)
        let model = JournalModel(calls: fake.calls)
        let first = Task { await model.load() }
        try await Task.sleep(for: .milliseconds(50))
        await model.load()
        XCTAssertEqual(model.data?.entries.count, 3)
        await first.value
        XCTAssertEqual(model.data?.entries.count, 3, "the first read's answer landed last, and was dropped")
        XCTAssertFalse(model.loading)
    }

    func testAnAnswerForSomeoneElseIsQuiet() async {
        let fake = FakeJournalCalls()
        fake.readError = CancellationError()
        let model = JournalModel(calls: fake.calls)
        await model.load()
        XCTAssertFalse(model.failed, "fetchForThisSession's CancellationError: another person is here now")
        XCTAssertFalse(model.loading)
        XCTAssertNil(model.data)
    }

    func testShowEarlierReadsTenYearsAndKeepsThe90DaysMeanwhile() async throws {
        let fake = FakeJournalCalls()
        let model = JournalModel(calls: fake.calls)
        await model.load()
        XCTAssertEqual(fake.reads, [90])
        XCTAssertTrue(model.showsMore)
        XCTAssertTrue(model.hasAny)
        XCTAssertEqual(model.emptyLine, "No check-ins in the last 90 days.")

        fake.readError = URLError(.timedOut)
        await model.showEarlier()
        XCTAssertEqual(fake.reads, [90, 3650])
        XCTAssertEqual(model.data?.entries.count, 3, "the 90 days stay on screen")
        XCTAssertTrue(model.awaiting)
        XCTAssertTrue(model.moreFailed)
        XCTAssertTrue(model.showsMore, "the button stays, to try again")

        fake.readError = nil
        let all = try decode(JournalData.self, #"{"today":"2026-10-26","older":false,"entries":[{"id":"old","date":"2019-01-02","time":"10:00","text":"Made-up old line."}]}"#)
        fake.answer = { _ in all }
        await model.showEarlier()
        XCTAssertEqual(fake.reads, [90, 3650, 3650])
        XCTAssertFalse(model.awaiting)
        XCTAssertFalse(model.showsMore)
        XCTAssertEqual(model.groups.map(\.date), ["2019-01-02"])
    }

    func testAnEmptyJournalSaysSoAndHasNothingToDelete() async {
        let fake = FakeJournalCalls(#"{"today":"2026-10-26","entries":[]}"#)
        let model = JournalModel(calls: fake.calls)
        await model.load()
        XCTAssertEqual(model.emptyLine, JournalWords.empty)
        XCTAssertFalse(model.hasAny)
        XCTAssertFalse(model.showsMore, "a server before `older` sends none: no button")
    }

    // MARK: Writing

    func testSavingSendsTheTrimmedWordsAndMoodThenReadsAgain() async {
        let fake = FakeJournalCalls()
        let model = JournalModel(calls: fake.calls)
        await model.load()
        model.setText("   \n")
        XCTAssertFalse(model.canSave, "only spaces: nothing to save")
        model.setText("  Made-up line\nand another.  ")
        model.setMood(.good)
        XCTAssertTrue(model.canSave)
        let saved = await model.save()
        XCTAssertTrue(saved)
        XCTAssertEqual(fake.added.first?.0, "Made-up line\nand another.", "line breaks kept, only the ends trimmed")
        XCTAssertEqual(fake.added.first?.1, .good)
        XCTAssertEqual(model.text, "")
        XCTAssertNil(model.mood)
        XCTAssertTrue(model.saved)
        XCTAssertEqual(fake.reads.count, 2)
        model.setText("m")
        XCTAssertFalse(model.saved, "typing again clears Saved")
    }

    func testAFailedSaveKeepsTheDraftAndSaysSo() async {
        let fake = FakeJournalCalls()
        fake.addError = APIError.server(400, "Write a few words first.")
        let model = JournalModel(calls: fake.calls)
        await model.load()
        model.setText("Made-up words")
        model.setMood(.low)
        let saved = await model.save()
        XCTAssertFalse(saved)
        XCTAssertEqual(model.saveError, "Write a few words first. Your check-in is still here.")
        XCTAssertEqual(model.text, "Made-up words")
        XCTAssertEqual(model.mood, .low)
        XCTAssertFalse(model.saving)

        fake.addError = URLError(.notConnectedToInternet)
        await model.save()
        XCTAssertTrue(model.saveError?.hasSuffix(JournalWords.stillHere) == true)
        XCTAssertFalse(model.saveError?.contains("Made-up words") == true, "never the check-in's words in an error")

        fake.addError = CancellationError()
        model.setText("Made-up words")
        await model.save()
        XCTAssertEqual(model.text, "Made-up words", "an answer for someone else changes nothing")
    }

    func testTheDraftIsCutToTheServersLimit() {
        let model = JournalModel(calls: FakeJournalCalls().calls)
        model.setText(String(repeating: "a", count: JournalLimits.maxChars + 20))
        XCTAssertEqual(JournalText.length(model.text), JournalLimits.maxChars)
    }

    func testTheServersOwnWordsShowAsTheyAre() {
        XCTAssertEqual(JournalModel.message(APIError.server(404, "No such check-in")), "No such check-in")
        XCTAssertEqual(JournalModel.message(APIError.server(400, "A check-in can't be dated in the future.")), "A check-in can't be dated in the future.")
        XCTAssertEqual(JournalModel.message(APIError.server(500, "Something went wrong")), "Server answered 500: Something went wrong")
    }

    // MARK: Changing and deleting

    func testAChangeInPlaceKeepsItsWordsInTheModel() async throws {
        let fake = FakeJournalCalls()
        let model = JournalModel(calls: fake.calls)
        await model.load()
        let entry = try XCTUnwrap(model.data?.entries.first)
        model.startEdit(entry)
        XCTAssertEqual(model.edits[entry.id]?.text, entry.text)
        XCTAssertEqual(model.edits[entry.id]?.mood, .good)
        XCTAssertEqual(model.focusEdit, entry.id, "the box takes the cursor")

        model.setEditText(entry.id, "   ")
        let empty = await model.saveEdit(entry)
        XCTAssertFalse(empty)
        XCTAssertEqual(model.edits[entry.id]?.error, JournalWords.writeAFew)
        XCTAssertTrue(fake.updated.isEmpty, "nothing sent")

        model.setEditText(entry.id, "Made-up change ")
        model.setEditMood(entry.id, nil)
        fake.updateError = APIError.server(404, "No such check-in")
        let refused = await model.saveEdit(entry)
        XCTAssertFalse(refused)
        XCTAssertEqual(model.edits[entry.id]?.error, "No such check-in")
        XCTAssertEqual(model.edits[entry.id]?.text, "Made-up change ", "what was typed stays")

        fake.updateError = nil
        // The read after the change is slow to bring it: what was saved shows meanwhile.
        fake.answer = { _ in try decode(JournalData.self, journalFixtureJSON) }
        let ok = await model.saveEdit(entry)
        XCTAssertTrue(ok)
        XCTAssertEqual(fake.updated.last?.1, "Made-up change")
        XCTAssertNil(fake.updated.last?.2, "the mood cleared")
        XCTAssertNil(model.edits[entry.id])
        XCTAssertEqual(model.refocusEdit, entry.id, "back to its Edit button")
        XCTAssertEqual(model.shown(entry).text, "changed", "the server's answer until a read has it")

        let changed = journalFixtureJSON.replacingOccurrences(of: #""text":"Made-up morning line.","createdAt":1,"updatedAt":1"#,
                                                              with: #""text":"changed","createdAt":1,"updatedAt":50"#)
        fake.answer = { _ in try decode(JournalData.self, changed) }
        await model.load()
        XCTAssertNil(model.justSaved[entry.id], "the read brought it")
    }

    func testCancelClosesAChangeButNotWhileItSaves() async throws {
        let model = JournalModel(calls: FakeJournalCalls().calls)
        await model.load()
        let entry = try XCTUnwrap(model.data?.entries.first)
        model.startEdit(entry)
        model.setEditText(entry.id, "Made-up")
        model.cancelEdit(entry.id)
        XCTAssertNil(model.edits[entry.id])
        XCTAssertEqual(model.shown(entry).text, entry.text, "nothing sent, nothing changed")
    }

    func testAChangeForACheckInThatsGoneGoesWithIt() async throws {
        let fake = FakeJournalCalls()
        let model = JournalModel(calls: fake.calls)
        await model.load()
        let entry = try XCTUnwrap(model.data?.entries.first)
        model.startEdit(entry)
        fake.answer = { _ in try decode(JournalData.self, #"{"today":"2026-10-26","entries":[]}"#) }
        await model.load()
        XCTAssertTrue(model.edits.isEmpty)
    }

    func testDeletingAnAlreadyGoneCheckInCountsAsGone() async throws {
        let fake = FakeJournalCalls()
        let model = JournalModel(calls: fake.calls)
        await model.load()
        let entry = try XCTUnwrap(model.data?.entries.first)
        fake.deleteError = APIError.server(404, "No such check-in")
        let gone = await model.delete(entry)
        XCTAssertTrue(gone)
        XCTAssertNil(model.rowErrors[entry.id])
        XCTAssertEqual(fake.reads.count, 2, "read again")

        fake.deleteError = APIError.server(500, "Something went wrong")
        let failed = await model.delete(entry)
        XCTAssertFalse(failed)
        XCTAssertEqual(model.rowErrors[entry.id], "Server answered 500: Something went wrong")
        XCTAssertEqual(fake.reads.count, 2)
    }

    func testDeleteAllThenReadsAgainOrSaysWhatWentWrong() async {
        let fake = FakeJournalCalls()
        let model = JournalModel(calls: fake.calls)
        await model.load()
        fake.deleteAllError = URLError(.notConnectedToInternet)
        await model.deleteAll()
        XCTAssertNotNil(model.deleteAllError)
        XCTAssertEqual(fake.reads.count, 1)
        fake.deleteAllError = nil
        fake.answer = { _ in try decode(JournalData.self, #"{"today":"2026-10-26","older":false,"entries":[]}"#) }
        await model.deleteAll()
        XCTAssertNil(model.deleteAllError)
        XCTAssertEqual(fake.deletedAll, 2)
        XCTAssertFalse(model.hasAny)
    }

    // MARK: Privacy

    /// Journal text is never logged, kept on disk or put in a report: nothing in Journal/ logs, writes a file or keeps
    /// anything in the defaults or a cache.
    func testTheJournalNeverLogsOrKeepsAnything() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("HealthOSSync/Journal")
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThanOrEqual(files.count, 4)
        let banned = [/\bprint\(/, /os_log/, /Logger\(/, /NSLog/, /UserDefaults/, /FileManager/, /URLCache/, /\.write\(to/,
                      /@AppStorage/, /@SceneStorage/, /debugPrint/, /dump\(/]
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for pattern in banned { XCTAssertNil(source.firstMatch(of: pattern), "\(file.lastPathComponent): \(pattern)") }
        }
    }
}
