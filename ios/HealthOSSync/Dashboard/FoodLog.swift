import Foundation
import UIKit

// The food log (GET/POST/PATCH/DELETE /api/nutrition/log, server/foodlog.ts): what a person logs in healthOS itself,
// on the web or here. Same rules as the rest of Nutrition: the server has already removed every number the person
// chose not to see, a database food is saved by its ref and portion (so the phone never needs hidden numbers), and
// nothing here judges an amount. Shapes mirror shared/types.ts (FoodEntry, FoodLog, FoodResult, FoodSearch, FoodEstimate).

/// One food or drink logged in healthOS.
struct FoodEntry: Codable, Identifiable, Equatable {
    let id: String
    let date: String
    /// Local time, HH:MM.
    let time: String
    let name: String
    /// What one portion is ("1 cup (245 g)"); quantity is how many.
    let portion: String
    let quantity: Double
    /// The whole entry (one portion × quantity), as the setting allows: never energy in "no_energy", empty in "none".
    let values: [String: Double]
    /// "quick" | "search" | "barcode" | "estimate"
    let method: String
    /// "fdc:<id>" or "off:<barcode>" when it came from a food database.
    let ref: String?
    /// Bumped on every edit, so this phone knows when its copy in Apple Health is out of date.
    let version: Int
    /// "web" | "iphone": the phone writes the ones made here to Apple Health.
    let origin: String
}

/// GET /api/nutrition/log: saved entries over the last few days, and McFly's estimate waiting for review.
struct FoodLog: Codable {
    /// What this person can do here (shared/types.ts FoodLog['can']), read field by field: newer servers add who reads
    /// an estimate and whether voice notes work, older ones send only the first two. The app's Availability keeps
    /// the last one heard.
    struct Can: Codable, Equatable {
        /// McFly estimates: the person's own OpenAI, Claude or Gemini key, else the shared Claude key with a limit above 0.
        var estimate = false
        /// USDA search (the server has its key).
        var usda = false
        /// Who reads an estimate: "anthropic" | "openai" | "gemini"; nil when nobody can, and from older servers.
        var estimateProvider: String?
        /// "own" | "shared"; nil as above.
        var estimateSource: String?
        /// Voice notes can be written down (an OpenAI key); nil from older servers, which have none.
        var voice: Bool?

        private enum CodingKeys: String, CodingKey { case estimate, usda, estimateProvider, estimateSource, voice }

        init(estimate: Bool = false, usda: Bool = false, estimateProvider: String? = nil, estimateSource: String? = nil, voice: Bool? = nil) {
            self.estimate = estimate
            self.usda = usda
            self.estimateProvider = estimateProvider
            self.estimateSource = estimateSource
            self.voice = voice
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            func value<T: Decodable>(_ key: CodingKeys) -> T? { try? c.decodeIfPresent(T.self, forKey: key) }
            self.init(estimate: value(.estimate) ?? false, usda: value(.usda) ?? false, estimateProvider: value(.estimateProvider),
                      estimateSource: value(.estimateSource), voice: value(.voice))
        }
    }

    let enabled: Bool
    let numbers: String?
    let today: String
    let start: String
    let end: String
    @LossyArray var entries: [FoodEntry]
    @LossyArray var drafts: [FoodEntry]
    /// The estimate those drafts came from: saving or discarding names it, so a newer one (another device) is left alone.
    let draftBatch: String?
    let can: Can

    var mode: NutritionMode { NutritionMode(rawValue: numbers ?? "") ?? .none }
}

/// One day of the food log (POST /api/nutrition/log/day {date}, shared/foodday.ts FoodDay): the Nutrition page's Today
/// view, for any day in the last year. Named apart from FoodDay, which is one day of GET /api/nutrition's totals. The
/// date goes in the body, never the address. nil from a server older than it (APIClient.foodLogDay): fall back to the
/// Log tab's GET /api/nutrition/log.
struct FoodLogDay: Codable {
    /// "all" | "no_energy" | "none".
    let numbers: String?
    /// Today in the person's time zone: the latest day that can be viewed.
    let today: String
    /// The day shown.
    let date: String
    /// That day's saved entries, by time, each as the person's setting allows.
    @LossyArray var entries: [FoodEntry]
    /// McFly's estimate waiting for review, whichever day it's for (one waits at a time).
    @LossyArray var drafts: [FoodEntry]
    let draftBatch: String?
    /// The day's saved entries added up, filtered like each entry: never energy in "no_energy", empty in "none".
    @Lossy var balance: [String: Double]?
    /// The app whose totals count for this day ("healthOS" for this log, or a Health app such as MyFitnessPal); nil when
    /// nothing was logged anywhere. Apps are never added together.
    let countedApp: String?
    @Lossy var can: FoodLog.Can?

    var mode: NutritionMode { NutritionMode(rawValue: numbers ?? "") ?? .none }
}

/// A database food from a search or a barcode, with its portions' amounts for one of each (filtered by the setting).
struct FoodResult: Codable, Identifiable, Equatable {
    struct Portion: Codable, Equatable {
        let label: String
        let values: [String: Double]
    }

    let ref: String
    let name: String
    let brand: String?
    /// "usda" | "off"
    let source: String
    let portions: [Portion]
    var id: String { ref }
}

/// POST /api/nutrition/foods/search and /barcode. `notes` say which database couldn't be reached, if any.
struct FoodSearch: Codable {
    @LossyArray var results: [FoodResult]
    @LossyArray var notes: [String]
}

/// POST /api/nutrition/estimate: drafts to review, and McFly's note on what it assumed (not stored).
struct FoodEstimate: Codable {
    @LossyArray var drafts: [FoodEntry]
    let batch: String?
    let note: String?
}

// MARK: - Words and numbers

/// How an entry reads, in the web's words (src/pages/FoodLog.tsx).
enum FoodText {
    static let flOzML = 29.5735

    /// Grams: a decimal only for small amounts that have one (0.5 g, not 6.0 g).
    static func grams(_ v: Double) -> String {
        Fmt.number(v, v < 10 && Int((v * 10).rounded()) % 10 != 0 ? 1 : 0)
    }

    static func water(_ ml: Double, units: Units) -> String {
        units == .imperial ? "\(Fmt.number(ml / flOzML)) fl oz" : "\(Fmt.number(ml)) mL"
    }

    /// An entry's amounts in one line, in the order people read a label. Only what the server sent.
    static func amounts(_ v: [String: Double], units: Units) -> String {
        var parts: [String] = []
        if let e = v["energy_kcal"] { parts.append("\(Fmt.number(e)) kcal") }
        if let p = v["protein_g"] { parts.append("\(grams(p)) g protein") }
        if let c = v["carbs_g"] { parts.append("\(grams(c)) g carbs") }
        if let f = v["fat_g"] { parts.append("\(grams(f)) g fat") }
        if let a = v["alcohol_drinks"], a > 0 {
            let n = (a * 10).rounded() / 10
            parts.append("\(n == n.rounded() ? String(Int(n)) : String(n)) \(a == 1 ? "drink" : "drinks")")
        }
        if let w = v["water_ml"] { parts.append("\(water(w, units: units)) water") }
        return parts.joined(separator: " · ")
    }

    static func addUp(_ entries: [FoodEntry]) -> [String: Double] {
        entries.reduce(into: [:]) { total, e in for (k, v) in e.values { total[k, default: 0] += v } }
    }

    static func scaled(_ v: [String: Double], by: Double) -> [String: Double] { v.mapValues { $0 * by } }

    /// "1 cup (245 g)", or "2 × 1 cup (245 g)".
    static func portion(_ e: FoodEntry) -> String { portion(e.portion, quantity: e.quantity) }

    static func portion(_ label: String, quantity: Double) -> String {
        quantity == 1 ? label : "\(quantityText(quantity)) × \(label.isEmpty ? "portion" : label)"
    }

    /// A typed number, either decimal separator ("1,5" is 1.5); nil when it isn't one.
    static func number(_ raw: String) -> Double? {
        Double(raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
    }

    /// 2 -> "2", 1.5 -> "1.5", 0.33333 -> "0.33".
    static func quantityText(_ q: Double) -> String {
        let r = (q * 100).rounded() / 100
        return r == r.rounded() ? String(Int(r)) : String(r)
    }

    /// The entry's second line: how much, and where it came from.
    static func detail(_ e: FoodEntry) -> String {
        let source: String? = e.ref?.hasPrefix("off:") == true ? "Open Food Facts" : e.ref != nil ? "USDA" : nil
        return [portion(e), e.method == "estimate" ? "estimated by McFly" : nil, source]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// An amount a person can type: never calories in "no_energy", none at all in "none" (typedKeys in FoodLog.tsx).
struct FoodField: Identifiable, Equatable {
    let key: String
    let label: String
    var id: String { key }

    func unit(_ units: Units) -> String {
        switch key {
        case "energy_kcal": "kcal"
        case "water_ml": units == .imperial ? "fl oz" : "mL"
        default: "g"
        }
    }

    static func typed(_ mode: NutritionMode) -> [FoodField] {
        if mode == .none { return [] }
        return (mode == .all ? [FoodField(key: "energy_kcal", label: "Calories")] : []) + [
            FoodField(key: "protein_g", label: "Protein"),
            FoodField(key: "carbs_g", label: "Carbs"),
            FoodField(key: "fat_g", label: "Fat"),
            FoodField(key: "water_ml", label: "Water"),
        ]
    }

    /// Typed text to a stored amount (water from fl oz when imperial): nil for blank, NaN for nonsense.
    func amount(_ raw: String, units: Units) -> Double? {
        let s = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        if s.isEmpty { return nil }
        let n = Double(s) ?? .nan
        return key == "water_ml" && units == .imperial ? n * FoodText.flOzML : n
    }

    /// A stored amount as text in the field's unit, to one decimal.
    func text(_ v: Double?, units: Units) -> String {
        guard let v else { return "" }
        let shown = ((key == "water_ml" && units == .imperial ? v / FoodText.flOzML : v) * 10).rounded() / 10
        return shown == shown.rounded() ? String(Int(shown)) : String(shown)
    }
}

/// A how-many field: decimals with either separator; nil when it isn't a usable amount.
func foodQuantity(_ raw: String) -> Double? {
    let q = Double(raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
    return q.flatMap { $0 > 0 && $0 <= 50 ? $0 : nil }
}

// MARK: - What the phone sends

/// Request bodies, as the server checks them: a lowercase UUID the phone makes (so a retry after a dropped reply changes
/// nothing), 24-hour local times, origin "iphone", and only the keys the person's setting shows.
enum FoodBody {
    /// The server's UUID check is lowercase only.
    static func newID() -> String { UUID().uuidString.lowercased() }

    private static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    /// "13:05" whatever the phone's 12/24-hour setting, in `zone`.
    static func time(_ date: Date, in zone: TimeZone = .current) -> String {
        timeFormat.timeZone = zone
        return timeFormat.string(from: date)
    }

    /// A Date for an "HH:MM" on today's calendar, for a time picker.
    static func date(forTime time: String, in zone: TimeZone = .current) -> Date {
        let p = time.split(separator: ":").compactMap { Int($0) }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let base = cal.startOfDay(for: Date())
        return cal.date(byAdding: .minute, value: (p.first ?? 12) * 60 + (p.count > 1 ? p[1] : 0), to: base) ?? Date()
    }

    static func quick(id: String = newID(), name: String, portion: String? = nil, values: [String: Double], date: String, time: String) -> [String: Any] {
        var b: [String: Any] = ["id": id, "method": "quick", "origin": "iphone", "values": values, "date": date, "time": time]
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { b["name"] = trimmed }
        if let portion { b["portion"] = portion }
        return b
    }

    /// A database food: its ref and the portion's index; the server works out the amounts from its own copy.
    static func food(id: String = newID(), ref: String, portionIndex: Int, quantity: Double, barcode: Bool, date: String, time: String) -> [String: Any] {
        ["id": id, "method": barcode ? "barcode" : "search", "origin": "iphone", "ref": ref, "portionIndex": portionIndex,
         "quantity": quantity, "date": date, "time": time]
    }

    /// Only what changed, as the web does. Typed amounts are for the new quantity; a quantity change alone scales every
    /// amount on the server, hidden ones included, so unchanged amounts are never sent back. nil when nothing changed.
    static func patch(_ e: FoodEntry, name: String, time: String, quantity: Double?, typed: [String: String], fields: [FoodField], units: Units) throws -> [String: Any]? {
        var b: [String: Any] = [:]
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.isEmpty { throw FoodError("Give it a name.") }
        if n != e.name { b["name"] = n }
        if time != e.time { b["time"] = time }
        guard let quantity else { throw FoodError("Choose an amount above 0 and up to 50.") }
        if quantity != e.quantity { b["quantity"] = quantity }
        var values: [String: Any] = [:]
        for f in fields {
            let raw = typed[f.key] ?? ""
            if raw == f.text(e.values[f.key], units: units) { continue }
            if let v = f.amount(raw, units: units) {
                guard v.isFinite, v >= 0 else { throw FoodError("\(f.label) should be a number.") }
                values[f.key] = v
            } else {
                values[f.key] = NSNull()
            }
        }
        if !values.isEmpty { b["values"] = values }
        return b.isEmpty ? nil : b
    }

    /// POST /api/nutrition/estimate. The photo is already a small JPEG (FoodPhoto).
    static func estimate(description: String, jpeg: Data?, date: String, time: String) -> [String: Any] {
        var b: [String: Any] = ["description": description, "origin": "iphone", "date": date, "time": time]
        if let jpeg { b["image"] = ["mediaType": "image/jpeg", "data": jpeg.base64EncodedString()] }
        return b
    }

    /// POST /log/save: those drafts of that estimate count from now on; its others are discarded.
    static func save(batch: String, ids: [String]) -> [String: Any] { ["batch": batch, "ids": ids] }

    /// POST /log/discard: that estimate only.
    static func discard(batch: String) -> [String: Any] { ["batch": batch] }
}

/// Water in one tap, as on the web (WATER in src/pages/FoodLog.tsx): a glass or a bottle in the person's units, logged as
/// a quick entry. Any other amount goes through Quick add.
struct FoodWater: Identifiable, Equatable {
    let label: String
    let portion: String
    let ml: Double
    var id: String { label }

    static func choices(_ units: Units) -> [FoodWater] {
        units == .imperial
            ? [.init(label: "Glass, 8 fl oz", portion: "1 glass (8 fl oz)", ml: 8 * FoodText.flOzML),
               .init(label: "Bottle, 16.9 fl oz", portion: "1 bottle (16.9 fl oz)", ml: 500)]
            : [.init(label: "Glass, 250 mL", portion: "1 glass (250 mL)", ml: 250),
               .init(label: "Bottle, 500 mL", portion: "1 bottle (500 mL)", ml: 500)]
    }

    /// "Added a glass (250 mL)."
    var added: String { "Added \(portion.replacingOccurrences(of: "^1 ", with: "a ", options: .regularExpression))." }

    func body(id: String = FoodBody.newID(), date: String, time: String) -> [String: Any] {
        FoodBody.quick(id: id, name: "Water", portion: portion, values: ["water_ml": ml], date: date, time: time)
    }
}

/// A message written for the person, shown as it is.
struct FoodError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

extension Error {
    /// The server's own words for a refused request ("Turn on Nutrition to log food."), else the usual description.
    var foodMessage: String {
        switch self as? APIError {
        case .server(_, let message)? where !message.isEmpty: message
        case .misconfigured(let message)?: message
        default: localizedDescription
        }
    }
}

// MARK: - Photos

/// A meal photo for McFly: shrunk on the phone to a 1,280 px long edge and re-encoded as JPEG, which leaves out the
/// camera and location data a photo carries, keeps the upload small and the estimate near 1,600 tokens.
enum FoodPhoto {
    static let longEdge: CGFloat = 1280

    /// Drawn upright, as every photo the app sends (PhotoPipeline).
    static func jpeg(from image: UIImage, quality: CGFloat = 0.85) -> Data? {
        PhotoPipeline.prepare(image, longEdge: Int(longEdge), quality: quality)?.jpeg
    }
}
