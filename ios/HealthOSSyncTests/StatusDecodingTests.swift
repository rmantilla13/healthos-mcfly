import XCTest
@testable import HealthOSSync

/// The settings, status and summary fields newer servers send (shared/types.ts), read field by field: one the app
/// can't read is nil, and the rest stay.
final class StatusDecodingTests: XCTestCase {
    private func status(_ json: [String: Any]) throws -> ServerStatus {
        try JSONDecoder().decode(ServerStatus.self, from: JSONSerialization.data(withJSONObject: json))
    }

    /// A status as this branch's server sends it (made-up values).
    private let current: [String: Any] = [
        "hosted": true,
        "demo": false,
        "user": ["id": "u1", "email": "sam@example.com", "name": "Sam", "role": "user"],
        "settings": [
            "name": "Sam", "stepGoal": 9000, "units": "imperial", "demo": "auto", "timeZone": "Europe/Paris", "sex": NSNull(),
            "cycleTracking": false, "familySharing": true, "shareCyclePhase": false, "familyNoticeSeen": true, "nutrition": true,
            "nutritionNumbers": "all", "nutritionApp": "Cronometer", "nutritionTargets": ["energy_kcal": 2200, "protein_g": NSNull(), "water_ml": NSNull()],
            "hiddenCards": ["home.hrv"], "shownCards": ["home.week"], "perspective": "digital", "gender": "woman", "figure": NSNull(),
            "age": 41, "peerComparison": true, "onboarding": 2,
        ] as [String: Any],
        "photo": ["version": 1_700_000_000_000, "width": 800, "height": 1200, "face": [0.3, 0.1, 0.4, 0.3], "shoulderY": 0.42,
                  "outline": [[1, 0], [0.4, 0.6]], "dots": ["temp": [0.5, 0.2], "breathing": [0.5, 0.5], "heart": [0.55, 0.6]]] as [String: Any],
        "apple": ["lastImport": NSNull(), "lastSync": ["daily": 3, "workouts": 0, "events": 1, "syncedAt": "2026-10-24T08:00:00Z"],
                  "job": ["state": "parsing", "bytesRead": 10, "totalBytes": 100, "records": 4], "iphoneToken": true] as [String: Any],
        "whoop": ["configured": true, "connected": false, "redirectUri": "https://example.com/cb", "syncing": false, "lastSync": NSNull(), "lastError": NSNull()],
        "fitbit": ["lastImport": ["days": 30, "firstDate": "2026-09-01", "lastDate": "2026-09-30", "metrics": ["steps", "resting_hr"], "importedAt": "2026-10-01T10:00:00Z"]],
    ]

    func testReadsTheNewFields() throws {
        let s = try status(current)
        XCTAssertEqual(s.user?.id, "u1")
        let settings = try XCTUnwrap(s.settings)
        XCTAssertEqual(settings.demo, "auto")
        XCTAssertEqual(settings.nutritionApp, "Cronometer")
        XCTAssertEqual(settings.nutritionTargets?.energy_kcal, 2200)
        XCTAssertEqual(settings.hiddenCards, ["home.hrv"])
        XCTAssertEqual(settings.shownCards, ["home.week"])
        XCTAssertEqual(settings.perspective, "digital")
        XCTAssertEqual(settings.gender, "woman")
        XCTAssertNil(settings.figure)
        XCTAssertEqual(settings.age, 41)
        XCTAssertEqual(settings.peerComparison, true)
        XCTAssertEqual(settings.onboarding, 2)
        XCTAssertEqual(s.apple?.iphoneToken, true)
        XCTAssertEqual(s.apple?.job?.state, "parsing")
        XCTAssertEqual(s.apple?.lastSync?.syncedAt, "2026-10-24T08:00:00Z")
        XCTAssertEqual(s.fitbit?.lastImport?.metrics, ["steps", "resting_hr"])
        XCTAssertEqual(s.photo?.shoulderY, 0.42)
        XCTAssertEqual(s.photo?.outline?.count, 2)
    }

    func testOneBadSettingDropsOnlyItself() throws {
        var json = current
        var settings = try XCTUnwrap(json["settings"] as? [String: Any])
        settings["familySharing"] = "yes"
        settings["units"] = 7
        settings["onboarding"] = "two"
        settings["nutritionTargets"] = "lots"
        settings["hiddenCards"] = ["home.hrv", 3, "home.spo2"]
        settings["somethingNew"] = ["a": 1]
        json["settings"] = settings
        let s = try XCTUnwrap(try status(json).settings)
        XCTAssertNil(s.familySharing)
        XCTAssertNil(s.units)
        XCTAssertNil(s.onboarding)
        XCTAssertNil(s.nutritionTargets)
        XCTAssertEqual(s.hiddenCards, ["home.hrv", "home.spo2"], "the ids it can read")
        XCTAssertEqual(s.name, "Sam")
        XCTAssertEqual(s.nutrition, true, "Nutrition stays on")
        XCTAssertEqual(s.shownCards, ["home.week"])
        XCTAssertEqual(s.timeZone, "Europe/Paris")
    }

    func testOneBadStatusPartLeavesTheRest() throws {
        var json = current
        json["hosted"] = "yes"
        json["user"] = "sam"
        json["fitbit"] = ["lastImport": 5]
        var apple = try XCTUnwrap(json["apple"] as? [String: Any])
        apple["iphoneToken"] = "maybe"
        apple["job"] = ["bytesRead": 1] // no state
        json["apple"] = apple
        let s = try status(json)
        XCTAssertNil(s.hosted)
        XCTAssertNil(s.user)
        XCTAssertNil(s.fitbit?.lastImport)
        XCTAssertNil(s.apple?.iphoneToken)
        XCTAssertNil(s.apple?.job)
        XCTAssertNotNil(s.apple?.lastSync, "the rest of apple stays")
        XCTAssertEqual(s.settings?.familySharing, true, "and so do the settings")
        XCTAssertEqual(s.demo, false)
    }

    func testAnOlderServerLeavesTheNewFieldsNil() throws {
        let s = try status(["settings": ["name": "Sam", "units": "metric", "hiddenCards": []]])
        XCTAssertEqual(s.settings?.hiddenCards, [])
        XCTAssertNil(s.settings?.shownCards, "nil, not empty: every card shows there")
        XCTAssertNil(s.settings?.perspective)
        XCTAssertNil(s.settings?.onboarding)
        XCTAssertNil(s.user)
        XCTAssertNil(s.apple)
        XCTAssertNil(s.fitbit)
    }

    func testTheCacheKeepsTheNewSettings() throws {
        let s = try status(current)
        let again = try JSONDecoder().decode(ServerStatus.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(again.settings?.shownCards, ["home.week"])
        XCTAssertEqual(again.settings?.perspective, "digital")
        XCTAssertEqual(again.settings?.onboarding, 2)
        XCTAssertEqual(again.settings?.nutritionTargets?.energy_kcal, 2200)
        XCTAssertEqual(again.user?.id, "u1")
        XCTAssertEqual(again.apple?.iphoneToken, true)
        XCTAssertEqual(again.photo?.shoulderY, 0.42)

        // An empty shown list stays empty, and a missing one stays missing: they mean different things.
        let empty = try status(["settings": ["hiddenCards": [], "shownCards": []]])
        XCTAssertEqual(try JSONDecoder().decode(ServerStatus.self, from: JSONEncoder().encode(empty)).settings?.shownCards, [])
        let none = try status(["settings": ["hiddenCards": []]])
        XCTAssertNil(try JSONDecoder().decode(ServerStatus.self, from: JSONEncoder().encode(none)).settings?.shownCards)
    }

    func testACacheFromAnOlderBuildStillReads() throws {
        // What builds before these fields wrote: settings with the old keys only.
        let old = #"{"hosted":true,"settings":{"name":"Sam","stepGoal":10000,"units":"metric","timeZone":"UTC","nutrition":false,"hiddenCards":["home.hrv"],"nutritionTargets":null},"apple":{"lastSync":null,"lastImport":null}}"#
        let s = try JSONDecoder().decode(ServerStatus.self, from: Data(old.utf8))
        XCTAssertEqual(s.settings?.hiddenCards, ["home.hrv"])
        XCTAssertNil(s.settings?.shownCards)
        XCTAssertNil(s.settings?.nutritionTargets)
        XCTAssertEqual(s.settings?.timeZone, "UTC")
    }

    func testTheSummaryReadsItsNewReadings() throws {
        let url = Bundle(for: Self.self).url(forResource: "summary", withExtension: "json")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/summary.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json["restingHr"] = ["latest": ["date": "2026-10-24", "value": 52, "source": "whoop"], "series": [["date": "2026-10-23", "value": 54], ["date": "2026-10-24", "value": 52]]]
        json["respRate"] = ["latest": NSNull(), "series": []]
        var vitals = try XCTUnwrap(json["vitals"] as? [String: Any])
        vitals["spo2"] = ["label": "Blood oxygen", "latest": ["date": "2026-10-24", "value": 97, "source": "apple"], "status": "normal"]
        json["vitals"] = vitals
        let s = try JSONDecoder().decode(Summary.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(s.restingHr?.latest?.value, 52)
        XCTAssertEqual(s.restingHr?.series.count, 2)
        XCTAssertNotNil(s.respRate)
        XCTAssertNil(s.respRate?.latest)
        XCTAssertEqual(s.vitals?.spo2?.latest?.value, 97)
        XCTAssertNotNil(s.vitals?.heart?.latest)

        // A blood oxygen the app can't read leaves the other vitals.
        vitals["spo2"] = "high"
        json["vitals"] = vitals
        json["restingHr"] = 52
        let odd = try JSONDecoder().decode(Summary.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(odd.vitals?.spo2)
        XCTAssertNotNil(odd.vitals?.heart?.latest)
        XCTAssertNil(odd.restingHr)
        XCTAssertNotNil(odd.sleep?.latest)
    }
}
