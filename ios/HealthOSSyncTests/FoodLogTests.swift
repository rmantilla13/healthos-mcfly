import HealthKit
import ImageIO
import UIKit
import XCTest
@testable import HealthOSSync

/// Food logged in healthOS (src/pages/FoodLog.tsx, server/foodlog.ts): what the phone sends, how an entry reads, what
/// goes to Apple Health, and that it never comes back from Health to be counted twice.
final class FoodLogTests: XCTestCase {
    private let chicago = TimeZone(identifier: "America/Chicago")!

    private func entry(_ values: [String: Double], id: String = "0b9f3c4e-1a2b-4c3d-8e9f-0a1b2c3d4e5f", version: Int = 1, origin: String = "iphone",
                       date: String = "2026-10-21", time: String = "13:05", name: String = "Lunch") -> FoodEntry {
        FoodEntry(id: id, date: date, time: time, name: name, portion: "1 plate", quantity: 1, values: values, method: "quick", ref: nil,
                  version: version, origin: origin)
    }

    // MARK: Never counted twice

    func testOurOwnSamplesAreRecognisedByTheirSyncIdentifier() {
        XCTAssertTrue(FoodHealth.isOurs([HKMetadataKeySyncIdentifier: "healthos.food.0b9f3c4e"]))
        XCTAssertFalse(FoodHealth.isOurs([HKMetadataKeySyncIdentifier: "healthos-sample-water-2026-10-21-0"]), "the simulator's sample data still counts")
        XCTAssertFalse(FoodHealth.isOurs([HKMetadataKeySyncIdentifier: "e2e-fp-lunch-HKQuantityTypeIdentifierDietaryWater"]))
        XCTAssertFalse(FoodHealth.isOurs([HKMetadataKeyFoodType: "healthos.food.x"]))
        XCTAssertFalse(FoodHealth.isOurs(nil))
        XCTAssertEqual(FoodHealth.syncID("0B9F3C4E-1A2B"), "healthos.food.0b9f3c4e-1a2b")
    }

    // MARK: What goes to Health

    func testAnEntryIsOneFoodCorrelationWithAlcoholOnItsOwn() throws {
        let e = entry(["energy_kcal": 450, "protein_g": 25, "carbs_g": 50, "fat_g": 15, "sodium_mg": 900, "water_ml": 250, "alcohol_drinks": 1, "fiber_g": 0], version: 3)
        let objects = FoodHealth.objects(for: e, in: chicago)
        XCTAssertEqual(objects.count, 2)
        let food = try XCTUnwrap(objects.first as? HKCorrelation)
        XCTAssertEqual(food.correlationType, HKCorrelationType(.food))
        let byType = Dictionary(uniqueKeysWithValues: food.objects.compactMap { $0 as? HKQuantitySample }.map { ($0.quantityType.identifier, $0) })
        XCTAssertEqual(Set(byType.keys), Set([HKQuantityTypeIdentifier.dietaryEnergyConsumed, .dietaryProtein, .dietaryCarbohydrates, .dietaryFatTotal,
                                              .dietarySodium, .dietaryWater].map(\.rawValue)), "a zero amount is left out")
        XCTAssertEqual(byType[HKQuantityTypeIdentifier.dietaryEnergyConsumed.rawValue]?.quantity.doubleValue(for: .kilocalorie()), 450)
        XCTAssertEqual(byType[HKQuantityTypeIdentifier.dietarySodium.rawValue]?.quantity.doubleValue(for: .gramUnit(with: .milli)), 900)
        XCTAssertEqual(byType[HKQuantityTypeIdentifier.dietaryWater.rawValue]?.quantity.doubleValue(for: .literUnit(with: .milli)), 250)
        let alcohol = try XCTUnwrap(objects.last as? HKQuantitySample)
        XCTAssertEqual(alcohol.quantityType, HKQuantityType(.numberOfAlcoholicBeverages))
        XCTAssertEqual(alcohol.quantity.doubleValue(for: .count()), 1)

        // Every object: the entry's name, sync identifier, version and time zone, at its local date and time.
        for object in [food, alcohol] + Array(food.objects) as [HKObject] {
            XCTAssertEqual(object.metadata?[HKMetadataKeySyncIdentifier] as? String, "healthos.food.0b9f3c4e-1a2b-4c3d-8e9f-0a1b2c3d4e5f")
            XCTAssertEqual(object.metadata?[HKMetadataKeySyncVersion] as? Int, 3)
            XCTAssertEqual(object.metadata?[HKMetadataKeyFoodType] as? String, "Lunch")
            XCTAssertEqual(object.metadata?[HKMetadataKeyTimeZone] as? String, "America/Chicago")
            XCTAssertTrue(FoodHealth.isOurs(object.metadata))
        }
        XCTAssertEqual(Stamp(food.startDate, timeZone: chicago).localIso, "2026-10-21T13:05:00-05:00")
    }

    func testOnlyTheAmountsThePhoneWasSentGoToHealth() throws {
        // No calories in "no_energy": the server never sent them, so there's none to write.
        let noEnergy = FoodHealth.objects(for: entry(["protein_g": 25, "fat_g": 15]), in: chicago)
        let samples = try XCTUnwrap(noEnergy.first as? HKCorrelation).objects.compactMap { $0 as? HKQuantitySample }
        XCTAssertFalse(samples.contains { $0.quantityType == HKQuantityType(.dietaryEnergyConsumed) })
        // Nothing at all in "none".
        XCTAssertTrue(FoodHealth.objects(for: entry([:]), in: chicago).isEmpty)
        XCTAssertTrue(FoodHealth.keys(entry([:])).isEmpty)
        // A type the person won't let the app write is left out; drinks alone need no correlation.
        let noWater = FoodHealth.objects(for: entry(["water_ml": 500, "protein_g": 10]), in: chicago) { $0 != HKQuantityType(.dietaryWater) }
        XCTAssertEqual(try XCTUnwrap(noWater.first as? HKCorrelation).objects.count, 1)
        let drinks = FoodHealth.objects(for: entry(["alcohol_drinks": 2]), in: chicago)
        XCTAssertEqual(drinks.count, 1)
        XCTAssertTrue(drinks.first is HKQuantitySample)
        // What the app asks to write: these ten types, nothing else.
        XCTAssertEqual(FoodHealth.shareTypes.count, 10)
        XCTAssertTrue(FoodHealth.shareTypes.contains(HKQuantityType(.dietaryWater)))
    }

    func testReconcileWritesWhatChangedAndRemovesWhatsGoneInsideTheWindowOnly() {
        let w = { (v: Int, d: String, k: [String]) in FoodHealth.Written(version: v, date: d, keys: k) }
        let entries = [
            entry(["protein_g": 20], id: "a", version: 1),                          // written already, unchanged
            entry(["protein_g": 20], id: "b", version: 2),                          // edited on the web
            entry(["protein_g": 20], id: "c", version: 1),                          // new on this phone
            entry(["protein_g": 20], id: "d", version: 1, origin: "web"),           // made on the web: never written here
            entry(["protein_g": 20, "fat_g": 5], id: "e", version: 1),              // amounts shown changed with the setting
            entry([:], id: "f", version: 1),                                        // now "none": nothing to show in Health
        ]
        let written = [
            "a": w(1, "2026-10-21", ["protein_g"]),
            "b": w(1, "2026-10-21", ["protein_g"]),
            "e": w(1, "2026-10-21", ["protein_g"]),
            "f": w(1, "2026-10-20", ["protein_g"]),
            "gone": w(1, "2026-10-19", ["protein_g"]),                              // deleted anywhere
            "old": w(1, "2026-10-01", ["protein_g"]),                               // older than the reply's week: untouched
        ]
        let plan = FoodHealth.plan(entries: entries, written: written, start: "2026-10-15", end: "2026-10-21")
        XCTAssertEqual(plan.write.map(\.id), ["b", "c", "e"])
        XCTAssertEqual(plan.remove, ["f", "gone"])
    }

    // MARK: What the phone sends

    func testBodiesAreWhatTheServerChecks() throws {
        let id = FoodBody.newID()
        XCTAssertEqual(id, id.lowercased(), "the server's UUID check is lowercase only")
        XCTAssertNotNil(UUID(uuidString: id))

        let quick = FoodBody.quick(id: "x", name: "  ", values: ["protein_g": 30], date: "2026-10-21", time: "13:05")
        XCTAssertEqual(quick["method"] as? String, "quick")
        XCTAssertEqual(quick["origin"] as? String, "iphone", "without it the entry is the web's and never reaches Health")
        XCTAssertNil(quick["name"], "a blank name is left for the server to name it")
        XCTAssertEqual(quick["values"] as? [String: Double], ["protein_g": 30])

        let food = FoodBody.food(id: "y", ref: "off:3017620422003", portionIndex: 2, quantity: 1.5, barcode: true, date: "2026-10-21", time: "08:00")
        XCTAssertEqual(food["method"] as? String, "barcode")
        XCTAssertEqual(food["portionIndex"] as? Int, 2)
        XCTAssertNil(food["values"], "a database food's amounts come from the server's copy")

        // 24-hour times, whatever the phone's own setting.
        var c = DateComponents(timeZone: chicago, year: 2026, month: 10, day: 21, hour: 13, minute: 5)
        c.calendar = Calendar(identifier: .gregorian)
        XCTAssertEqual(FoodBody.time(c.date!, in: chicago), "13:05")

        let est = FoodBody.estimate(description: "toast", jpeg: Data([0xFF, 0xD8, 0xFF]), date: "2026-10-21", time: "08:00")
        XCTAssertEqual(est["origin"] as? String, "iphone")
        XCTAssertEqual((est["image"] as? [String: String])?["mediaType"], "image/jpeg")
        XCTAssertEqual((est["image"] as? [String: String])?["data"], "/9j/")
    }

    func testAnEditSendsOnlyWhatChanged() throws {
        let e = FoodEntry(id: "a", date: "2026-10-21", time: "13:05", name: "Lunch", portion: "1 plate", quantity: 2,
                          values: ["energy_kcal": 800, "protein_g": 40, "water_ml": 500], method: "quick", ref: nil, version: 1, origin: "iphone")
        let fields = FoodField.typed(.all)
        let asTyped = Dictionary(uniqueKeysWithValues: fields.map { ($0.key, $0.text(e.values[$0.key], units: .metric)) })
        XCTAssertNil(try FoodBody.patch(e, name: "Lunch", time: "13:05", quantity: 2, typed: asTyped, fields: fields, units: .metric), "nothing changed")
        // How many alone: the server scales every amount, hidden ones too, so unchanged amounts aren't sent back.
        let more = try XCTUnwrap(FoodBody.patch(e, name: "Lunch", time: "13:05", quantity: 3, typed: asTyped, fields: fields, units: .metric))
        XCTAssertEqual(more.keys.sorted(), ["quantity"])
        // A cleared amount goes as null; a changed one as the whole entry's.
        var typed = asTyped
        typed["water_ml"] = ""
        typed["protein_g"] = "45,5"
        let amounts = try XCTUnwrap(FoodBody.patch(e, name: " Late lunch ", time: "14:00", quantity: 2, typed: typed, fields: fields, units: .metric))
        XCTAssertEqual(amounts["name"] as? String, "Late lunch")
        XCTAssertEqual(amounts["time"] as? String, "14:00")
        let values = try XCTUnwrap(amounts["values"] as? [String: Any])
        XCTAssertEqual(values["protein_g"] as? Double, 45.5)
        XCTAssertTrue(values["water_ml"] is NSNull)
        XCTAssertNil(values["energy_kcal"])
        XCTAssertThrowsError(try FoodBody.patch(e, name: " ", time: "13:05", quantity: 2, typed: asTyped, fields: fields, units: .metric))
        XCTAssertThrowsError(try FoodBody.patch(e, name: "Lunch", time: "13:05", quantity: nil, typed: asTyped, fields: fields, units: .metric))
    }

    func testTypedAmountsFollowTheSetting() {
        XCTAssertEqual(FoodField.typed(.all).map(\.key), ["energy_kcal", "protein_g", "carbs_g", "fat_g", "water_ml"])
        XCTAssertEqual(FoodField.typed(.noEnergy).map(\.key), ["protein_g", "carbs_g", "fat_g", "water_ml"])
        XCTAssertTrue(FoodField.typed(.none).isEmpty, "no quick add without amounts")
        let water = FoodField(key: "water_ml", label: "Water")
        XCTAssertEqual(water.unit(.imperial), "fl oz")
        XCTAssertEqual(water.amount("8", units: .imperial)!, 236.588, accuracy: 0.001, "fl oz typed, mL sent")
        XCTAssertEqual(water.text(236.588, units: .imperial), "8")
        XCTAssertNil(water.amount(" ", units: .metric))
        XCTAssertTrue(water.amount("lots", units: .metric)!.isNaN)
        XCTAssertEqual(foodQuantity("1,5"), 1.5)
        XCTAssertNil(foodQuantity("0"))
        XCTAssertNil(foodQuantity("51"))
    }

    // MARK: How it reads

    func testAnEntryReadsLikeTheWeb() {
        let v: [String: Double] = ["energy_kcal": 512.4, "protein_g": 6.4, "carbs_g": 0.5, "fat_g": 12, "alcohol_drinks": 1, "water_ml": 250]
        XCTAssertEqual(FoodText.amounts(v, units: .metric), "512 kcal · 6.4 g protein · 0.5 g carbs · 12 g fat · 1 drink · 250 mL water")
        XCTAssertEqual(FoodText.amounts(["water_ml": 473.176], units: .imperial), "16 fl oz water")
        XCTAssertEqual(FoodText.amounts([:], units: .metric), "", "nothing at all in \"none\"")
        var e = entry([:])
        XCTAssertEqual(FoodText.detail(e), "1 plate")
        e = FoodEntry(id: "x", date: "2026-10-21", time: "08:00", name: "Yogurt", portion: "1 cup (245 g)", quantity: 1.5, values: [:], method: "barcode",
                      ref: "off:3017620422003", version: 1, origin: "iphone")
        XCTAssertEqual(FoodText.detail(e), "1.5 × 1 cup (245 g) · Open Food Facts")
        e = FoodEntry(id: "x", date: "2026-10-21", time: "08:00", name: "Toast", portion: "", quantity: 2, values: [:], method: "estimate", ref: nil,
                      version: 1, origin: "iphone")
        XCTAssertEqual(FoodText.detail(e), "2 × portion · estimated by McFly")
        XCTAssertEqual(FoodText.addUp([entry(["protein_g": 10]), entry(["protein_g": 5, "water_ml": 250])]), ["protein_g": 15, "water_ml": 250])
    }

    // MARK: The photo for an estimate

    func testAPhotoIsShrunkToJPEGWithoutItsLocation() throws {
        let big = UIGraphicsImageRenderer(size: CGSize(width: 4000, height: 3000), format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }())
            .image { ctx in UIColor.orange.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 4000, height: 3000)) }
        let data = try XCTUnwrap(FoodPhoto.jpeg(from: big))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.jpeg")
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        XCTAssertEqual(props[kCGImagePropertyPixelWidth as String] as? Int, 1280)
        XCTAssertEqual(props[kCGImagePropertyPixelHeight as String] as? Int, 960)
        XCTAssertNil(props[kCGImagePropertyGPSDictionary as String])
        XCTAssertLessThan(data.count, 3_000_000, "under the server's 3 MB")

        let small = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 600), format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }())
            .image { ctx in UIColor.green.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 800, height: 600)) }
        let smallProps = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithData(try XCTUnwrap(FoodPhoto.jpeg(from: small)) as CFData, nil)!, 0, nil) as? [String: Any]
        XCTAssertEqual(smallProps?[kCGImagePropertyPixelWidth as String] as? Int, 800, "never enlarged")
    }

    // MARK: Reading the server

    func testDecodesTheLogSearchAndEstimate() throws {
        let log = try JSONDecoder().decode(FoodLog.self, from: Data(#"""
        {"enabled":true,"numbers":"no_energy","today":"2026-10-21","start":"2026-10-08","end":"2026-10-21",
         "entries":[{"id":"a","date":"2026-10-21","time":"08:00","name":"Yogurt","portion":"1 cup (245 g)","quantity":1,"values":{"protein_g":9},"method":"barcode","ref":"off:1","version":1,"origin":"web"},
                    {"id":"bad","date":"2026-10-21"}],
         "drafts":[],"can":{"estimate":false,"usda":false}}
        """#.utf8))
        XCTAssertEqual(log.mode, .noEnergy)
        XCTAssertEqual(log.entries.map(\.id), ["a"], "an entry the app can't read is left out, not the whole log")
        XCTAssertFalse(log.can.estimate)
        XCTAssertEqual(FoodAddMode.available(log), [.search, .scan, .quick], "no estimate without McFly")
        let none = try JSONDecoder().decode(FoodLog.self, from: Data(#"{"enabled":true,"numbers":"none","today":"2026-10-21","start":"2026-10-08","end":"2026-10-21","entries":[],"drafts":[],"can":{"estimate":true,"usda":true}}"#.utf8))
        XCTAssertEqual(FoodAddMode.available(none), [.search, .scan, .estimate], "no quick add without amounts")

        let search = try JSONDecoder().decode(FoodSearch.self, from: Data(#"""
        {"results":[{"ref":"off:3017620422003","name":"Hazelnut spread","brand":"Ferrero","source":"off","portions":[{"label":"15 g","values":{"energy_kcal":81}},{"label":"100 g","values":{"energy_kcal":539}}]}],
         "notes":["USDA FoodData Central didn't answer."]}
        """#.utf8))
        XCTAssertEqual(search.results.first?.portions.map(\.label), ["15 g", "100 g"])
        XCTAssertEqual(search.notes.count, 1)
        let estimate = try JSONDecoder().decode(FoodEstimate.self, from: Data(#"{"drafts":[],"note":"No food in the photo."}"#.utf8))
        XCTAssertTrue(estimate.drafts.isEmpty)
        XCTAssertEqual(estimate.note, "No food in the photo.")
    }

    func testTheServersWordsAreShownAsTheyAre() {
        XCTAssertEqual(APIError.server(409, "Turn on Nutrition to log food.").foodMessage, "Turn on Nutrition to log food.")
        XCTAssertEqual(APIError.misconfigured("McFly isn't set up on this server yet.").foodMessage, "McFly isn't set up on this server yet.")
    }
}
