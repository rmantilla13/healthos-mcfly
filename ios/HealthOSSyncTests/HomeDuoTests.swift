import SwiftUI
import UIKit
import XCTest
@testable import HealthOSSync

// Home on the iPhone Duo (duo/design.md §7 and §8.2, decisions.md Q5), drawn at the Duo's sizes with the fold put in: the
// outer display and the inner one upright keep one column (the phone's, and the web's counts at 669), and the open Duo
// in landscape has the greeting and the figure on the leading side of the fold, staying put, and every card in two
// scrolling columns on the trailing side. The data is the local demo server's made-up day (Fixtures/summary.json and
// status.json), and nothing here reaches a server: every request is answered here ("not on this server"), and Home's
// own reads are counted stand-ins. Set TEST_RUNNER_DUO_SHOTS to a folder to keep the pictures. Slice B owns this file.

/// Answers every request the page makes as a server without that route does, and counts them.
final class HomeDuoStub: URLProtocol {
    nonisolated(unsafe) static var asked: [String] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.asked.append(request.url?.path ?? "")
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"error":"Not found"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Home's reads, counted, with made-up answers.
@MainActor
final class HomeDuoReads {
    var food = 0, journal = 0, cutout = 0
    var cutoutImage: UIImage?

    var reads: HomeReads {
        HomeReads(
            readFood: { _ in self.food += 1; return nil },
            readJournal: { _ in
                self.journal += 1
                return try JSONDecoder().decode(JournalData.self, from: Data(#"{"today":"2026-10-16","entries":[]}"#.utf8))
            },
            readCutout: { _, _ in self.cutout += 1; return self.cutoutImage })
    }
}

/// The demo day as the fixtures have it, and its Home.
@MainActor
enum HomeDuoFixture {
    static func data(_ name: String) throws -> Data {
        let url = Bundle(for: HomeDuoStub.self).url(forResource: name, withExtension: "json")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name).json")
        return try Data(contentsOf: url)
    }

    static func summary() throws -> Summary { try JSONDecoder().decode(Summary.self, from: data("summary")) }

    /// The demo status, with the optional cards the web's wide Home shows turned on, and the family note not yet seen.
    static func status(perspective: String? = nil, photo: Bool = false) throws -> ServerStatus {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data("status")) as? [String: Any])
        var settings = try XCTUnwrap(json["settings"] as? [String: Any])
        settings["hiddenCards"] = [String]()
        settings["shownCards"] = ["home.load", "home.activity", "home.timeline", "home.week", "home.insights"]
        settings["familySharing"] = true
        settings["familyNoticeSeen"] = false
        if let perspective { settings["perspective"] = perspective }
        json["settings"] = settings
        if photo {
            json["photo"] = ["version": 7, "width": 900, "height": 1200, "face": [0.38, 0.06, 0.24, 0.24], "shoulderY": 0.36,
                             "dots": ["temp": [0.5, 0.1], "breathing": [0.5, 0.3], "heart": [0.56, 0.45]]] as [String: Any]
        }
        return try JSONDecoder().decode(ServerStatus.self, from: JSONSerialization.data(withJSONObject: json))
    }

    static func dashboard(perspective: String? = nil, photo: Bool = false) throws -> Dashboard {
        let d = Dashboard()
        d.apply(status: try status(perspective: perspective, photo: photo))
        return d
    }

    /// Home as TodayScreen shows it: on the page's colour.
    static func page(_ dashboard: Dashboard, reads: HomeDuoReads) throws -> some View {
        TodayContent(summary: try summary())
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.page)
            .environment(dashboard)
            .environment(AppModel())
            .environment(\.homeReads, reads.reads)
    }

    /// A made-up cut-out: a grey figure-shaped block.
    static var cutout: UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 90, height: 120)).image { ctx in
            UIColor.gray.setFill()
            ctx.fill(CGRect(x: 25, y: 5, width: 40, height: 115))
        }
    }
}

@MainActor
final class HomeDuoTests: XCTestCase {
    override func setUp() async throws {
        HomeDuoStub.asked = []
        APIClient.answering(with: [HomeDuoStub.self])
    }

    override func tearDown() async throws {
        APIClient.answering(with: [])
    }

    private func page(perspective: String? = nil, photo: Bool = false, reads: HomeDuoReads? = nil) throws -> some View {
        try HomeDuoFixture.page(try HomeDuoFixture.dashboard(perspective: perspective, photo: photo), reads: reads ?? HomeDuoReads())
    }

    /// The first pictures the user asked for: the open Duo in landscape, light and dark, at the default text size.
    func testEarlyLandscape() async throws {
        for dark in [false, true] {
            try await DuoSnapshot.draw(try page(), as: .innerLandscape(), dark: dark, name: "r")
        }
    }
}
