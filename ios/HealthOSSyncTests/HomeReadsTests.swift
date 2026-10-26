import SwiftUI
import UIKit
import XCTest
@testable import HealthOSSync

// What Home reads beside its summary (Home/HomeReads.swift): the food totals, today's check-in, and a cut-out that
// couldn't be loaded, each read from a view that is always on screen. These host Home in a window, with counting reads
// in place of the server, so a read hung on a view that isn't drawn (a `.task` on an empty Group never runs) fails here.
// Slice B owns this file.

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(json.utf8))
}

/// One day with made-up numbers.
private let summaryJSON = #"""
{"date":"2026-10-19","today":"2026-10-19","name":"Sam",
 "vitals":{"heart":{"label":"Resting heart","latest":{"date":"2026-10-19","value":61,"source":"apple"},"status":"normal"},
           "breathing":{"label":"Breathing","latest":{"date":"2026-10-19","value":15,"source":"apple"},"status":null}},
 "readiness":null,"spo2":{"latest":null,"series":[],"status":null},
 "hrv":{"metric":"hrv_rmssd","latest":null,"series":[],"baseline":null,"status":null},
 "sleep":{"latest":null,"series":[],"change":null},"load":null,"activity":{"latest":null,"series":[]},
 "timeline":{"date":"2026-10-19","events":[]},"insights":[]}
"""#

private let foodJSON = #"""
{"enabled":true,"numbers":"all","today":"2026-10-19","start":"2026-10-13","end":"2026-10-19","apps":["MyFitnessPal"],"app":null,
 "days":[{"date":"2026-10-18","app":"MyFitnessPal","values":{"energy_kcal":2100,"protein_g":90}}]}
"""#

private let journalJSON = #"{"today":"2026-10-19","entries":[{"id":"a","date":"2026-10-19","time":"08:10","mood":4,"text":"Made-up line","createdAt":1}]}"#

/// Reads that count themselves and answer what the test says.
@MainActor
private final class FakeReads {
    var food = 0, journal = 0, cutout = 0
    var foodReply: NutritionData?
    /// nil: a server without the journal.
    var journalReply: JournalData?
    var journalFails = false
    var cutoutReply: UIImage?

    var reads: HomeReads {
        HomeReads(
            readFood: { _ in self.food += 1; return self.foodReply },
            readJournal: { _ in
                self.journal += 1
                if self.journalFails { throw URLError(.notConnectedToInternet) }
                return self.journalReply
            },
            readCutout: { _, _ in self.cutout += 1; return self.cutoutReply })
    }
}

@MainActor
final class HomeReadsTests: XCTestCase {
    private var window: UIWindow?

    override func tearDown() {
        window?.isHidden = true
        window = nil
        super.tearDown()
    }

    private func status(_ settings: String, photo: String? = nil) throws -> ServerStatus {
        try decode(ServerStatus.self, #"{"hosted":false,"settings":\#(settings)\#(photo.map { #","photo":\#($0)"# } ?? "")}"#)
    }

    /// Puts the view on screen, as Home is, so its tasks run.
    private func show(_ view: some View, _ dashboard: Dashboard, _ fake: FakeReads) throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let w = UIWindow(windowScene: scene)
        w.frame = CGRect(x: 0, y: 0, width: 375, height: 812)
        w.rootViewController = UIHostingController(rootView: view.environment(dashboard).environment(AppModel()).environment(\.homeReads, fake.reads))
        w.makeKeyAndVisible()
        window = w
    }

    private func wait(_ what: String, timeout: TimeInterval = 10, until done: () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let end = Date().addingTimeInterval(timeout)
        while !done(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertTrue(done(), what, file: file, line: line)
    }

    private func settle(_ seconds: TimeInterval = 0.5) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func testFoodTotalsAreReadWhileTheCardHasNothingToShowYetAndAgainAfterEveryLoad() throws {
        let d = Dashboard()
        d.apply(status: try status(#"{"nutrition":true,"nutritionNumbers":"all","hiddenCards":[],"shownCards":["home.food"]}"#))
        let fake = FakeReads()
        fake.foodReply = try decode(NutritionData.self, foodJSON)
        try show(TodayContent(summary: try decode(Summary.self, summaryJSON)), d, fake)
        wait("the food totals are read with no card on screen yet") { fake.food == 1 }
        d.generation += 1
        wait("and read again after the next load") { fake.food == 2 }
    }

    func testFoodTotalsAreNotAskedForWhileTheCardIsOff() throws {
        for settings in [#"{"nutrition":false,"nutritionNumbers":"all","hiddenCards":[],"shownCards":["home.food"]}"#,
                         #"{"nutrition":true,"nutritionNumbers":"all","hiddenCards":[],"shownCards":[]}"#] {
            let d = Dashboard()
            d.apply(status: try status(settings))
            let fake = FakeReads()
            try show(TodayContent(summary: try decode(Summary.self, summaryJSON)), d, fake)
            // The journal's read runs beside it: once it has, the food's would have too.
            wait("the journal is read") { fake.journal == 1 }
            settle()
            XCTAssertEqual(fake.food, 0, settings)
            window?.isHidden = true
        }
    }

    func testAJournalCardHiddenByAServerWithoutTheJournalComesBackOnceItHasOne() throws {
        let d = Dashboard()
        d.apply(status: try status(#"{"hiddenCards":[],"shownCards":[]}"#))
        let fake = FakeReads()
        fake.journalReply = nil
        try show(TodayContent(summary: try decode(Summary.self, summaryJSON)), d, fake)
        wait("the journal is read") { fake.journal == 1 }
        // The server is updated while the app stays open: the next load reads the journal again, card or no card.
        fake.journalReply = try decode(JournalData.self, journalJSON)
        d.generation += 1
        wait("read again after the next load, though its card is gone") { fake.journal == 2 }
    }

    func testTheJournalIsNotAskedForWhileItsCardIsHidden() throws {
        let d = Dashboard()
        d.apply(status: try status(#"{"hiddenCards":["home.journal"],"shownCards":[]}"#))
        let fake = FakeReads()
        try show(TodayContent(summary: try decode(Summary.self, summaryJSON)), d, fake)
        settle(1)
        XCTAssertEqual(fake.journal, 0)
    }

    func testACutOutThatCouldntBeLoadedIsTriedAgainAfterTheNextLoadAndThePortraitComesBack() throws {
        let photo = #"{"version":7,"width":900,"height":1200,"face":[0.38,0.06,0.24,0.24],"shoulderY":0.36,"dots":{"temp":[0.5,0.1],"breathing":[0.5,0.3],"heart":[0.56,0.45]}}"#
        let d = Dashboard()
        d.apply(status: try status(#"{"perspective":"portrait"}"#, photo: photo))
        let fake = FakeReads()
        fake.cutoutReply = nil
        try show(HomeFigure(summary: try decode(Summary.self, summaryJSON), scrub: nil), d, fake)
        wait("the portrait reads its cut-out, which fails") { fake.cutout == 1 }
        settle()
        XCTAssertEqual(fake.cutout, 1, "no read again until the next load: the digital human stands in")
        // Back online: the next load tries it again behind the digital human, and once it reads, the portrait draws
        // and loads it itself.
        fake.cutoutReply = UIGraphicsImageRenderer(size: CGSize(width: 9, height: 12)).image { ctx in
            UIColor.gray.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 9, height: 12))
        }
        d.generation += 1
        wait("tried again, and the portrait comes back") { fake.cutout >= 3 }
    }
}

/// The reads' own rules, without a screen.
@MainActor
final class HomeReadRulesTests: XCTestCase {
    func testNothingIsAskedForWhileACardIsOffAndAFailedJournalReadKeepsTheCard() async throws {
        let fake = FakeReads()
        let d = Dashboard()
        let none = await fake.reads.food(wanted: false, dashboard: d)
        XCTAssertNil(none)
        XCTAssertEqual(fake.food, 0)
        fake.foodReply = try decode(NutritionData.self, foodJSON)
        let read = await fake.reads.food(wanted: true, dashboard: d)
        XCTAssertEqual(read?.days.count, 1)

        let entry = try decode(JournalData.self, journalJSON).todays.first
        let kept = await fake.reads.journal(wanted: false, current: .read(entry), dashboard: d)
        XCTAssertEqual(kept.latest?.id, "a")
        XCTAssertEqual(fake.journal, 0, "a hidden card isn't read")

        fake.journalReply = nil
        let missing = await fake.reads.journal(wanted: true, current: .reading, dashboard: d)
        XCTAssertFalse(missing.shows, "a server without the journal: no card")

        fake.journalFails = true
        let offline = await fake.reads.journal(wanted: true, current: .read(entry), dashboard: d)
        XCTAssertEqual(offline.latest?.id, "a", "offline, what's on the card stays")
        XCTAssertTrue(offline.shows)
        let stillMissing = await fake.reads.journal(wanted: true, current: .missing, dashboard: d)
        XCTAssertFalse(stillMissing.shows)

        fake.journalFails = false
        fake.journalReply = try decode(JournalData.self, journalJSON)
        let back = await fake.reads.journal(wanted: true, current: .missing, dashboard: d)
        XCTAssertTrue(back.shows)
        XCTAssertEqual(back.latest?.id, "a")
        XCTAssertTrue(HomeJournalRead.reading.shows, "the invitation shows while it reads")
        XCTAssertNil(HomeJournalRead.reading.latest)
    }
}
