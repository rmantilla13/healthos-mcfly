import UIKit
import XCTest
@testable import HealthOSSync

/// Nutrition's Today (src/pages/NutritionChat.tsx, src/hooks/useVoiceNote.ts, src/styles/nutrition.css): the
/// conversation's rules, an estimate's review, what the setup line says, the day's balance, voice notes and the page's
/// views, each against the web's own words and cases. The server's food log (server/foodlog.ts) is the made-up
/// fixture food-log-day.json.
@MainActor
final class NutritionConversationTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func web(_ path: String) throws -> String {
        guard let text = try? String(contentsOf: Self.root.appendingPathComponent(path), encoding: .utf8) else { throw XCTSkip("\(path) isn't next to the app") }
        return text
    }

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json")))
    }

    private func entry(_ id: String, name: String = "Greek yogurt", portion: String = "1 cup (245 g)", quantity: Double = 1, time: String = "08:10",
                       date: String = "2026-10-23", values: [String: Double] = ["protein_g": 20, "carbs_g": 9]) -> FoodEntry {
        FoodEntry(id: id, date: date, time: time, name: name, portion: portion, quantity: quantity, values: values, method: "estimate", ref: nil,
                  version: 1, origin: "iphone")
    }

    private func day(drafts: [FoodEntry] = [], batch: String? = nil, entries: [FoodEntry] = []) throws -> FoodLogDay {
        let json: [String: Any] = [
            "numbers": "all", "today": "2026-10-24", "date": "2026-10-24", "entries": try entries.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) },
            "drafts": try drafts.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) }, "draftBatch": batch as Any? ?? NSNull(),
            "balance": [:], "countedApp": NSNull(),
        ]
        return try JSONDecoder().decode(FoodLogDay.self, from: JSONSerialization.data(withJSONObject: json))
    }

    // MARK: Look

    func testTheColoursAreNutritionCSS() throws {
        // :root, then the prefers-color-scheme block (the forced-dark block repeats it).
        let css = try web("src/styles/nutrition.css")
        let media = try XCTUnwrap(css.range(of: "@media (prefers-color-scheme: dark)"))
        let forced = try XCTUnwrap(css.range(of: "/* Forced dark"))
        func block(_ text: Substring) -> [String: String] {
            var out: [String: String] = [:]
            for m in text.matches(of: /--([a-z-]+):\s*([^;]+);/) { out[String(m.1)] = String(m.2).trimmingCharacters(in: .whitespaces) }
            return out
        }
        let light = block(css[..<media.lowerBound]), dark = block(css[media.upperBound..<forced.lowerBound])
        for token in NutriColor.allCases {
            XCTAssertEqual(light[token.rawValue], token.value.light.description, token.rawValue)
            XCTAssertEqual(dark[token.rawValue], token.value.dark.description, token.rawValue)
        }
        // The empty ring's loop: conic-gradient(from 210deg, five stops).
        func ring(_ value: String?) -> [String] { (value ?? "").matches(of: /#[0-9a-f]{6}/).map { String($0.0) } }
        XCTAssertTrue(light["nutri-ring"]?.hasPrefix("conic-gradient(from \(Int(NutriColor.ringFrom))deg") == true)
        XCTAssertEqual(ring(light["nutri-ring"]), NutriColor.ring.light.map(\.description))
        XCTAssertEqual(ring(dark["nutri-ring"]), NutriColor.ring.dark.map(\.description))
        // Today's three pastels, never the chart series; Trends' macro balance keeps the series (Nutrition.tsx).
        XCTAssertTrue(try web("src/pages/NutritionChat.tsx").contains("{ key: 'protein_g', label: 'Protein', color: 'var(--nutri-protein)' }"))
        XCTAssertTrue(try web("src/pages/Nutrition.tsx").contains("{ key: 'protein_g', color: 'var(--series-1)' }"))
    }

    // MARK: A correction

    func testACorrectionIsTheWebsWithinTheServersLimit() {
        // Each expected value is the web's corrected() run on the same words.
        XCTAssertEqual(NutritionChat.corrected("", ""), "")
        XCTAssertEqual(NutritionChat.corrected("pasta", ""), "pasta")
        XCTAssertEqual(NutritionChat.corrected("", "it was half"), "it was half")
        XCTAssertEqual(NutritionChat.corrected("a bowl of pasta.", "it was half"), "a bowl of pasta. Correction: it was half")
        XCTAssertEqual(NutritionChat.corrected("rice and beans . . .  ", "no beans"), "rice and beans. Correction: no beans")
        let long = NutritionChat.corrected(String(repeating: "x", count: 1200), "less oil")
        XCTAssertEqual(long.utf16.count, 1000)
        XCTAssertTrue(long.hasSuffix("xxxxxxxx. Correction: less oil"))
        XCTAssertEqual(NutritionChat.corrected(String(repeating: "y", count: 10), String(repeating: "z", count: 990)), String(repeating: "z", count: 990),
                       "a tail of 1,000 or more is the correction alone")
        let tight = NutritionChat.corrected(String(repeating: "y", count: 10), String(repeating: "z", count: 985))
        XCTAssertEqual(tight.utf16.count, 1000)
        XCTAssertTrue(tight.hasPrefix("y. Correction: z"))
        XCTAssertEqual(NutritionChat.corrected("ppppp", String(repeating: "q", count: 1200)), String(repeating: "q", count: 1000))
        // Counted as the web counts (UTF-16), and never splitting a character.
        let emoji = NutritionChat.prefix(String(repeating: "🍝", count: 600), utf16: 1000)
        XCTAssertEqual(emoji.utf16.count, 1000)
        XCTAssertEqual(NutritionChat.prefix("a🍝", utf16: 2), "a")
        // The words as one line, as the web collapses them.
        XCTAssertEqual(NutritionChat.words("  two eggs\n\n and   toast "), "two eggs and toast")
    }

    func testACorrectionBuildsOnWhatTheEstimateWasMadeFrom() {
        let words = EstimateTurn(batch: "b", note: "", asked: "chicken bowl", photo: false, items: ["Chicken (150 g)", "Rice (1 cup)"], date: "2026-10-23", time: "12:30", at: Date())
        XCTAssertEqual(NutritionChat.previous(for: words, resendingPhoto: false), "chicken bowl")
        let photo = EstimateTurn(batch: "b", note: "", asked: "", photo: true, items: ["Chicken (150 g)", "Rice (1 cup)"], date: "2026-10-23", time: "12:30", at: Date())
        XCTAssertEqual(NutritionChat.previous(for: photo, resendingPhoto: false), "From a photo: Chicken (150 g); Rice (1 cup)")
        XCTAssertEqual(NutritionChat.previous(for: photo, resendingPhoto: true), "Chicken (150 g); Rice (1 cup)", "the photo goes again, so its items stand in for words")
        let both = EstimateTurn(batch: "b", note: "", asked: "my lunch", photo: true, items: ["Soup"], date: "2026-10-23", time: "12:30", at: Date())
        XCTAssertEqual(NutritionChat.previous(for: both, resendingPhoto: false), "my lunch. From a photo: Soup")
        XCTAssertEqual(NutritionChat.itemText(entry("a")), "Greek yogurt (1 cup (245 g))")
        XCTAssertEqual(NutritionChat.itemText(entry("a", portion: "")), "Greek yogurt")
    }

    func testAFollowUpCorrectsTheOpenEstimateOnItsDayWithItsPhoto() throws {
        let thread = NutritionThread()
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0x01])
        let first = thread.ask(words: "chicken bowl", jpeg: jpeg, at: FoodMoment(date: "2026-10-22", time: "12:00"), openBatch: nil)
        XCTAssertNil(first.correcting)
        XCTAssertEqual(first.description, "chicken bowl")
        let drafts = [entry("d1", name: "Chicken", portion: "150 g"), entry("d2", name: "Rice", portion: "1 cup")]
        let said = thread.received(FoodEstimate(drafts: drafts, batch: "b1", note: "Assumed a tablespoon of oil."), for: first)
        XCTAssertEqual(said, "McFly's estimate is ready to check: Chicken (150 g), Rice (1 cup).")
        XCTAssertEqual(thread.fresh["b1"], drafts)
        XCTAssertEqual(thread.lastPhoto, NutritionThread.LastPhoto(batch: "b1", jpeg: jpeg))

        // While the server waits on b1, a message corrects it: on its day and time, with its photo sent again.
        let open = try XCTUnwrap(thread.open(batch: "b1"))
        let fix = thread.ask(words: "no rice", jpeg: nil, at: FoodMoment(date: "2026-10-24", time: "18:40"), openBatch: "b1")
        XCTAssertEqual(fix.correcting, open.id)
        XCTAssertEqual(fix.description, "chicken bowl. Correction: no rice")
        XCTAssertEqual(fix.moment, FoodMoment(date: "2026-10-22", time: "12:00"))
        XCTAssertEqual(fix.jpeg, jpeg)
        XCTAssertNil(thread.open(batch: "b2"), "only the estimate the server is waiting on is open")

        thread.received(FoodEstimate(drafts: [drafts[0]], batch: "b2", note: nil), for: fix)
        XCTAssertEqual(thread.turns.compactMap(\.estimate).map(\.state), [.replaced, .open])
        XCTAssertNotNil(thread.open(batch: "b2"))

        // Nothing found: McFly says so, and the one it corrected is gone on the server too.
        let again = thread.ask(words: "actually nothing", jpeg: nil, at: FoodMoment(date: "2026-10-24", time: "19:00"), openBatch: "b2")
        XCTAssertEqual(thread.received(FoodEstimate(drafts: [], batch: nil, note: ""), for: again), "McFly didn't find food or drink to estimate.")
        XCTAssertEqual(thread.turns.compactMap(\.estimate).map(\.state), [.replaced, .discarded])
        XCTAssertEqual(thread.turns.last?.body, .note(text: "McFly didn't find food or drink to estimate.", error: false))
        thread.failed("You've used McFly 30 times today, the daily limit (estimates count too).")
        XCTAssertEqual(thread.turns.last?.body, .note(text: "You've used McFly 30 times today, the daily limit (estimates count too).", error: true))
    }

    func testAnEstimateWaitingOnTheServerJoinsOnceAndClearKeepsIt() throws {
        let thread = NutritionThread()
        let waiting = try day(drafts: [entry("d1", time: "09:15")], batch: "web-batch")
        thread.join(waiting: waiting)
        thread.join(waiting: waiting)
        XCTAssertEqual(thread.turns.count, 1)
        let found = try XCTUnwrap(thread.turns.first?.estimate)
        XCTAssertTrue(found.found)
        XCTAssertEqual([found.date, found.time], ["2026-10-23", "09:15"])
        XCTAssertEqual(found.items, ["Greek yogurt (1 cup (245 g))"])
        thread.join(waiting: try day())
        XCTAssertEqual(thread.turns.count, 1, "no estimate waiting, nothing joins")

        thread.append(ChatTurn(.you(text: "hello", thumbnail: nil)))
        thread.append(ChatTurn(.note(text: "Hi", error: false)))
        thread.clear(keeping: thread.open(batch: "web-batch")?.id)
        XCTAssertEqual(thread.turns.count, 1, "Clear keeps only the estimate still waiting")
        thread.clear(keeping: nil)
        XCTAssertTrue(thread.isEmpty)

        for i in 0..<45 { thread.append(ChatTurn(.you(text: "\(i)", thumbnail: nil))) }
        XCTAssertEqual(thread.turns.count, NutritionChat.maxTurns)
        XCTAssertEqual(thread.turns.first?.body, .you(text: "5", thumbnail: nil), "the oldest go first")
    }

    func testWhatAnEstimatesLineShows() throws {
        let at = Date(timeIntervalSince1970: 1_000)
        let drafts = [entry("d1")]
        var turn = EstimateTurn(batch: "b1", note: "", asked: "yogurt", photo: false, items: ["Greek yogurt (1 cup (245 g))"], date: "2026-10-23", time: "08:10", at: at)
        // The day that knows about it shows its drafts; one read before it arrived, this estimate's own.
        XCTAssertEqual(NutritionChat.shows(turn, day: try day(drafts: drafts, batch: "b1"), dayAskedAt: at.addingTimeInterval(-60), fresh: nil), .review(drafts))
        let fresh = [entry("f1")]
        XCTAssertEqual(NutritionChat.shows(turn, day: try day(), dayAskedAt: at.addingTimeInterval(-60), fresh: fresh), .review(fresh))
        XCTAssertEqual(NutritionChat.shows(turn, day: nil, dayAskedAt: nil, fresh: fresh), .review(fresh))
        // Read since, and not waiting: saved or discarded elsewhere, or a day old.
        let gone = NutritionChat.shows(turn, day: try day(), dayAskedAt: at.addingTimeInterval(60), fresh: fresh)
        XCTAssertEqual(gone.text, "Greek yogurt (1 cup (245 g)). This estimate isn't waiting any more: it was saved or discarded somewhere else, or it went after a day.")
        XCTAssertEqual(NutritionChat.shows(turn, day: nil, dayAskedAt: nil, fresh: nil).text, "Greek yogurt (1 cup (245 g))")
        turn.state = .saved
        turn.saved = 1
        XCTAssertEqual(NutritionChat.shows(turn, day: nil, dayAskedAt: nil, fresh: nil).text, "Saved to your food journal.")
        turn.saved = 3
        XCTAssertEqual(NutritionChat.shows(turn, day: nil, dayAskedAt: nil, fresh: nil).text, "Saved 3 items to your food journal.")
        turn.state = .discarded
        XCTAssertEqual(NutritionChat.shows(turn, day: nil, dayAskedAt: nil, fresh: nil).text, "Discarded. Nothing was saved.")
        turn.state = .replaced
        XCTAssertEqual(NutritionChat.shows(turn, day: nil, dayAskedAt: nil, fresh: nil).text, "Greek yogurt (1 cup (245 g)). Corrected below.")
        // The words are the web's.
        let chat = try web("src/pages/NutritionChat.tsx")
        for words in ["Saved to your food journal.", "Discarded. Nothing was saved.", ". Corrected below.",
                      ". This estimate isn't waiting any more: it was saved or discarded somewhere else, or it went after a day.",
                      "McFly didn't find food or drink to estimate.", "This estimate is waiting for you to check.", "Here's my estimate.",
                      "Check it, then save. Nothing counts until you do.", "Everything is left out. Discard it, or tell me what you had instead.",
                      "Not quite right? Tell me what to change, and I'll redo it. Estimates are rough, so you can fix any amount after saving, too.",
                      "Good food.", "One simple conversation.", "“I had a chicken bowl with rice and avocado.”", "What's on your plate?",
                      "Tell me in your own words. I'll take care of the numbers.", "A conversation about what nourishes you.",
                      "Your day starts with a bite.", "Nothing logged here that day.", "Tell McFly what you ate.",
                      "Tell McFly what you had, and it goes on this day.", "Your meals will appear here.", "McFly is estimating…",
                      "Adds to ", "From a label or another app, for ", "In one tap, for ", ". Any other amount goes in Type amounts.",
                      "Search foods or a barcode", "Type amounts", "Add a photo", "More ways to add food", "Add to your food journal",
                      "Anything to correct?", "I ate…", "A correction to the estimate", "What did you eat?", "Send the correction", "Send to McFly",
                      "Clear this conversation", "Remove the photo", "Your photo, as it will be sent", "That photo couldn't be opened here. Try a JPEG or PNG, or describe it instead."] {
            XCTAssertTrue(chat.contains(words), words)
        }
    }

    func testWhatsAddedGoesOnTheDayViewed() {
        let zone = TimeZone(identifier: "America/Chicago")!
        let now = ISO8601DateFormatter().date(from: "2026-10-24T18:05:00Z")!
        XCTAssertEqual(NutritionChat.when(viewing: "2026-10-24", today: "2026-10-24", now: now, zone: zone), FoodMoment(date: "2026-10-24", time: "13:05"))
        XCTAssertEqual(NutritionChat.when(viewing: "2026-10-20", today: "2026-10-24", now: now, zone: zone), FoodMoment(date: "2026-10-20", time: "12:00"))
        XCTAssertEqual(NutritionChat.dayWords("2026-10-24", today: "2026-10-24"), "today")
        XCTAssertEqual(NutritionChat.dayWords("2026-10-23", today: "2026-10-24"), Fmt.day("2026-10-23", "EEEEMMMMd"))
    }

    // MARK: Under the composer

    func testTheSetupLineSaysWhoReadsAnEstimate() throws {
        let shared = FoodLog.Can(estimate: true, usda: false, estimateProvider: "anthropic", estimateSource: "shared", voice: false)
        XCTAssertNil(NutritionChat.setupLine(can: nil, ai: AiStatus(), mode: .all), "nothing until both are known")
        XCTAssertNil(NutritionChat.setupLine(can: shared, ai: nil, mode: .all))
        XCTAssertEqual(NutritionChat.setupLine(can: shared, ai: AiStatus(), mode: .all),
                       .using("Using healthOS's shared assistant · your words and photos go to Anthropic for each estimate, and healthOS doesn't keep them."))
        let ownOpenAI = FoodLog.Can(estimate: true, estimateProvider: "openai", estimateSource: "own", voice: true)
        XCTAssertEqual(NutritionChat.setupLine(can: ownOpenAI, ai: AiStatus(byok: true, keys: [.init(provider: "openai", last4: "abcd")], voice: true), mode: .all),
                       .using("Using your own OpenAI key · your words and photos go to OpenAI for each estimate, and healthOS doesn't keep them."),
                       "OpenAI is named already: no line about voice notes")
        let ownClaude = FoodLog.Can(estimate: true, estimateProvider: "anthropic", estimateSource: "own", voice: true)
        XCTAssertEqual(NutritionChat.setupLine(can: ownClaude, ai: AiStatus(byok: true, keys: [.init(provider: "anthropic", last4: "wxyz")], voice: true), mode: .all),
                       .using("Using your own Claude key · your words and photos go to Anthropic for each estimate, and healthOS doesn't keep them. Voice notes are transcribed by OpenAI first, on this server's key."))
        let gemini = FoodLog.Can(estimate: true, estimateProvider: "gemini", estimateSource: "own", voice: true)
        XCTAssertEqual(NutritionChat.setupLine(can: gemini, ai: AiStatus(byok: true, keys: [.init(provider: "gemini", last4: "1"), .init(provider: "openai", last4: "2")]), mode: .all),
                       .using("Using your own Gemini key · your words and photos go to Google for each estimate, and healthOS doesn't keep them. Voice notes are transcribed by OpenAI first, on your key."))
        // An older server's can, without who reads it: it had only Claude.
        XCTAssertEqual(NutritionChat.setupLine(can: FoodLog.Can(estimate: true), ai: AiStatus(), mode: .all),
                       .using("Using healthOS's shared assistant · your words and photos go to Anthropic for each estimate, and healthOS doesn't keep them."))
        // Nothing can estimate: connect a key where keys can be stored, else what still works.
        let none = FoodLog.Can(estimate: false)
        XCTAssertEqual(NutritionChat.setupLine(can: none, ai: AiStatus(byok: true), mode: .all), .connectOpenAI)
        XCTAssertEqual(NutritionChat.setupLine(can: none, ai: AiStatus(byok: false), mode: .all),
                       .notHere("Estimates need an AI key, and storing your own isn't available on this server. You can still search foods, type amounts or add water from +."))
        XCTAssertEqual(NutritionChat.setupLine(can: none, ai: AiStatus(byok: false), mode: .none),
                       .notHere("Estimates need an AI key, and storing your own isn't available on this server. You can still search foods from +."))

        let chat = try web("src/pages/NutritionChat.tsx")
        for words in ["Using healthOS's shared assistant", "your words and photos go to ", " for each estimate, and healthOS doesn't keep them.",
                      " Voice notes are transcribed by OpenAI first, on ", "your key", "this server's key", "One-time setup: ", "connect your OpenAI key", "</a> to start.",
                      "You can still search foods from +.", "You can still search foods, type amounts or add water from +.", "#/profile?connect=openai"] {
            XCTAssertTrue(chat.contains(words), words)
        }
        let log = try web("src/pages/FoodLog.tsx")
        XCTAssertTrue(log.contains("anthropic: 'Anthropic', openai: 'OpenAI', gemini: 'Google'"))
        XCTAssertTrue(log.contains("anthropic: 'Claude', openai: 'OpenAI', gemini: 'Gemini'"))
    }

    func testTheLogSaysWhereAPhotoGoes() throws {
        XCTAssertEqual(NutritionChat.estimatePrivacy(FoodLog.Can(estimate: true, estimateProvider: "anthropic", estimateSource: "shared")),
                       "The photo and words go to Anthropic for this one estimate, and healthOS doesn't keep them. It counts as one McFly question.")
        XCTAssertEqual(NutritionChat.estimatePrivacy(FoodLog.Can(estimate: true, estimateProvider: "openai", estimateSource: "own")),
                       "The photo and words go to OpenAI for this one estimate, and healthOS doesn't keep them. It runs on your own OpenAI key.")
        XCTAssertEqual(NutritionChat.estimatePrivacy(FoodLog.Can(estimate: true)),
                       "The photo and words go to Anthropic for this one estimate, and healthOS doesn't keep them. It counts as one McFly question.")
        XCTAssertEqual(NutritionChat.company("mistral"), "mistral", "a provider this build doesn't know is never called another's name")
        let log = try web("src/pages/FoodLog.tsx")
        for words in ["The photo and words go to ", " for this one estimate, and healthOS doesn't keep them.", "It counts as one McFly question.", "It runs on your own "] {
            XCTAssertTrue(log.contains(words), words)
        }
    }

    func testVoiceOffSaysWhy() throws {
        XCTAssertNil(NutritionChat.voiceOff(voice: true, byok: false))
        XCTAssertEqual(NutritionChat.voiceOff(voice: false, byok: false), ServerWords.voiceNeedsKeyNotHere)
        XCTAssertEqual(NutritionChat.voiceOff(voice: false, byok: true), "Connect your OpenAI key for voice notes.")
        XCTAssertEqual(NutritionChat.voiceOff(voice: nil, byok: nil), "Connect your OpenAI key for voice notes.", "the web's line when GET /api/ai isn't known")
        XCTAssertTrue(try web("src/pages/NutritionChat.tsx").contains("'Connect your OpenAI key for voice notes.'"))
    }

    // MARK: The day

    func testTheDailyBalanceInEachMode() throws {
        // The made-up day, no calories: 38 g protein, 54 g carbs and 6.9 g fat over two meals.
        let day = try JSONDecoder().decode(FoodLogDay.self, from: fixture("food-log-day"))
        let b = DailyBalanceMath(day: day, mode: day.mode, units: .metric)
        XCTAssertEqual(b.badge, "2 entries")
        XCTAssertEqual(b.meals, 2)
        XCTAssertEqual(b.label, "By weight: protein 38%, carbs 55%, fat 7%")
        XCTAssertNil(b.center.value, "no calories: the ring says by weight")
        XCTAssertEqual(b.center.caption, "by weight")
        XCTAssertEqual(b.rows.map(\.grams), ["38", "54", "6.9"])
        XCTAssertEqual(b.rows.map(\.percent), ["38%", "55%", "7%"])
        XCTAssertTrue(b.extras.isEmpty)
        XCTAssertEqual(b.foot, "Estimated from your logged meals.")

        let all = try JSONDecoder().decode(FoodLogDay.self, from: Data(#"""
        {"numbers":"all","today":"2026-10-24","date":"2026-10-24",
         "entries":[{"id":"a","date":"2026-10-24","time":"08:00","name":"Oats","portion":"","quantity":1,"values":{},"method":"quick","ref":null,"version":1,"origin":"web"}],
         "drafts":[],"draftBatch":null,"balance":{"energy_kcal":1240,"protein_g":40,"fat_g":0,"fiber_g":6.5,"sugar_g":12,"sodium_mg":1250,"alcohol_drinks":1,"water_ml":750},
         "countedApp":"healthOS","can":{"estimate":false,"usda":false}}
        """#.utf8))
        let a = DailyBalanceMath(day: all, mode: .all, units: .metric)
        XCTAssertEqual(a.badge, "1 entry")
        XCTAssertEqual(a.center.value, "1,240")
        XCTAssertEqual(a.center.caption, "kcal logged")
        XCTAssertEqual(a.parts.map(\.key), ["protein_g"], "fat at 0 isn't a part of the ring")
        XCTAssertEqual(a.rows.map(\.grams), ["40", nil, "0"], "carbs not logged is a dash; fat logged as 0 shows")
        XCTAssertEqual(a.rows.map(\.percent), ["100%", .emptyValue, "0%"])
        XCTAssertEqual(a.extras.map(\.label), ["Fiber", "Sugar", "Sodium", "Alcohol", "Water"])
        XCTAssertEqual(a.extras.map(\.value), ["6.5 g", "12 g", "1,250 mg", "1 drink", "750 mL"])
        XCTAssertEqual(DailyBalanceMath(day: all, mode: .all, units: .imperial).extras.last?.value, "25 fl oz")

        let none = DailyBalanceMath(day: day, mode: .none, units: .metric)
        XCTAssertEqual(none.label, "2 meals logged")
        XCTAssertEqual(none.center.value, "2")
        XCTAssertEqual(none.center.caption, "meals logged")
        XCTAssertEqual(none.foot, "Counted from your food journal.")

        // Nothing logged: dashes, never zeros.
        let empty = DailyBalanceMath(day: nil, mode: .all, units: .metric)
        XCTAssertEqual(empty.center.value, .emptyValue)
        XCTAssertEqual(empty.label, "No protein, carbs or fat logged")
        XCTAssertEqual(empty.rows.map(\.percent), [.emptyValue, .emptyValue, .emptyValue])
        XCTAssertEqual(DailyBalanceMath(day: nil, mode: .none, units: .metric).label, "No meals logged")
        XCTAssertEqual(DailyBalanceMath(day: nil, mode: .none, units: .metric).center.value, .emptyValue)

        let chat = try web("src/pages/NutritionChat.tsx")
        for words in ["Your daily balance", "Your food journal", "kcal logged", "by weight", "meal logged", "meals logged",
                      "You chose to see no amounts, so this counts your meals, not what's in them.", "Counted from your food journal.",
                      "Estimated from your logged meals.", "No protein, carbs or fat logged", "'Fiber'", "'Sugar'", "'Sodium'", "'Alcohol'", "'Water'"] {
            XCTAssertTrue(chat.contains(words), words)
        }
    }

    // MARK: Reviewing an estimate

    private final class Writes {
        var changes: [(String, [String: Any])] = []
        var saved: [(String, [String])] = []
        var discarded: [String] = []
        var fail: Error?

        @MainActor var api: EstimateReview.Writes {
            EstimateReview.Writes(change: { e, body in
                if let fail = self.fail { throw fail }
                self.changes.append((e.id, body))
            }, save: { batch, ids in
                self.saved.append((batch, ids))
                return ids.map { FoodEntry(id: $0, date: "2026-10-24", time: "12:00", name: "x", portion: "", quantity: 1, values: [:], method: "estimate", ref: nil, version: 1, origin: "iphone") }
            }, discard: { self.discarded.append($0) })
        }
    }

    func testAReviewSendsOnlyWhatChangedThenSavesWhatsKept() async throws {
        let drafts = [entry("d1", name: "Chicken", portion: "150 g", quantity: 1, time: "12:30", values: ["energy_kcal": 250, "protein_g": 46]),
                      entry("d2", name: "Rice", portion: "1 cup", quantity: 1, time: "12:30", values: ["energy_kcal": 205, "carbs_g": 45]),
                      entry("d3", name: "Avocado", portion: "half", quantity: 1, time: "12:30", values: ["energy_kcal": 120])]
        let review = EstimateReview(drafts: drafts, batch: "b1")
        XCTAssertEqual(review.saveTitle, "Save 3 items")
        XCTAssertEqual(review.time, "12:30")
        review.binding("d1", \.name).wrappedValue = "  Grilled chicken "
        review.binding("d2", \.quantity).wrappedValue = "1,5"
        review.leaveOut("d3")
        XCTAssertEqual(review.saveTitle, "Save 2 items")
        XCTAssertEqual(review.line(review.kept[1], mode: .all, units: .metric), "308 kcal · 68 g carbs", "at the quantity typed")
        XCTAssertEqual(review.line(review.kept[1], mode: .none, units: .metric), "")
        XCTAssertEqual(review.altogether(mode: .all, units: .metric), "558 kcal · 46 g protein · 68 g carbs")
        review.time = "13:05"

        let writes = Writes()
        let n = await review.save(writes.api)
        XCTAssertEqual(n, 2)
        XCTAssertEqual(writes.changes.map(\.0), ["d1", "d2"])
        XCTAssertEqual(writes.changes[0].1["name"] as? String, "Grilled chicken")
        XCTAssertEqual(writes.changes[0].1["time"] as? String, "13:05")
        XCTAssertNil(writes.changes[0].1["quantity"])
        XCTAssertEqual(writes.changes[1].1["quantity"] as? Double, 1.5)
        XCTAssertNil(writes.changes[1].1["name"])
        XCTAssertEqual(writes.saved.first?.0, "b1")
        XCTAssertEqual(writes.saved.first?.1, ["d1", "d2"], "what's left out isn't named, so the server discards it")
        XCTAssertFalse(review.busy)

        // The server's own words for what it would refuse, before anything is sent.
        let bad = EstimateReview(drafts: drafts, batch: "b1")
        bad.binding("d1", \.name).wrappedValue = " "
        let refused = Writes()
        let unnamed = await bad.save(refused.api)
        XCTAssertNil(unnamed)
        XCTAssertEqual(bad.error, "Give it a name.")
        XCTAssertTrue(refused.saved.isEmpty)
        bad.binding("d1", \.name).wrappedValue = "Chicken"
        bad.binding("d1", \.quantity).wrappedValue = "60"
        let tooMany = await bad.save(refused.api)
        XCTAssertNil(tooMany)
        XCTAssertEqual(bad.error, "Choose an amount above 0 and up to 50.")
        XCTAssertTrue(try web("server/foodlog.ts").contains("Choose an amount above 0 and up to ${MAX_QUANTITY}."))

        // A refusal from the server shows as it is.
        let failing = Writes()
        failing.fail = APIError.server(409, "Turn on Nutrition to log food.")
        let third = EstimateReview(drafts: drafts, batch: "b1")
        third.time = "14:00"
        let refusedByServer = await third.save(failing.api)
        XCTAssertNil(refusedByServer)
        XCTAssertEqual(third.error, "Turn on Nutrition to log food.")

        let discarding = Writes()
        let gone = await EstimateReview(drafts: drafts, batch: "b9").discard(discarding.api)
        XCTAssertTrue(gone)
        XCTAssertEqual(discarding.discarded, ["b9"])
        XCTAssertEqual(EstimateReview(drafts: [drafts[0]], batch: "b").saveTitle, "Save 1 item")
        XCTAssertEqual(EstimateReview(drafts: [drafts[0]], batch: "b").altogether(mode: .all, units: .metric), "", "one item needs no total")
    }

    // MARK: Voice notes

    private final class FakeRecorder: VoiceRecording {
        var problem: VoiceProblem?
        var audio: Data? = Data(repeating: 1, count: 2_000)
        var started = 0
        var stopped = 0
        var cancelled = 0
        /// Holds start() until let go, like a permission question.
        var gate: CheckedContinuation<Void, Never>?
        var waits = false

        func start() async throws {
            started += 1
            if waits { await withCheckedContinuation { gate = $0 } }
            if let problem { throw problem }
        }
        func stop() -> Data? {
            stopped += 1
            return audio
        }
        func cancel() { cancelled += 1 }
    }

    private final class Clock {
        var now = Date(timeIntervalSince1970: 0)
    }

    private func settle(_ voice: VoiceNote) async {
        for _ in 0..<200 where voice.state == .transcribing { try? await Task.sleep(for: .milliseconds(5)) }
    }

    func testAVoiceNoteIsWrittenDownIntoTheComposer() async {
        let recorder = FakeRecorder()
        let clock = Clock()
        var sent: [Data] = []
        let voice = VoiceNote(recorder: recorder, transcribe: { sent.append($0); return "  two eggs and toast " }, now: { clock.now })
        var words: [String] = []
        voice.onText = { words.append($0) }
        XCTAssertEqual(voice.label, "Hold to talk")

        await voice.start(.press)
        XCTAssertEqual(voice.state, .recording)
        XCTAssertEqual(voice.more, " · let go to stop")
        clock.now = clock.now.addingTimeInterval(65)
        voice.release()
        XCTAssertEqual(voice.state, .transcribing)
        XCTAssertEqual(voice.label, "Writing it down…")
        await settle(voice)
        XCTAssertEqual(voice.state, .idle)
        XCTAssertEqual(words, ["two eggs and toast"], "the words fill the composer, trimmed; nothing is sent on its own")
        XCTAssertEqual(sent, [recorder.audio!])
        XCTAssertNil(voice.error)

        // VoiceOver or a keyboard: activate to start, again to stop.
        await voice.start(.toggle)
        XCTAssertEqual(voice.more, " · press again to stop")
        clock.now = clock.now.addingTimeInterval(3)
        voice.toggle()
        await settle(voice)
        XCTAssertEqual(words.count, 2)
    }

    func testAVoiceNoteThatCantBeUsedSaysWhy() async throws {
        let recorder = FakeRecorder()
        let clock = Clock()
        var reply: () throws -> String = { "" }
        let voice = VoiceNote(recorder: recorder, transcribe: { _ in try reply() }, now: { clock.now })

        // A tap, not a note.
        await voice.start(.press)
        clock.now = clock.now.addingTimeInterval(0.3)
        voice.release()
        XCTAssertEqual(voice.state, .idle)
        XCTAssertEqual(voice.error, "Hold the button while you talk, then let go.")
        await voice.start(.toggle)
        clock.now = clock.now.addingTimeInterval(0.2)
        voice.toggle()
        XCTAssertEqual(voice.error, "That was too short to hear anything. Try again.")

        // Over the server's 4 MB.
        recorder.audio = Data(count: VoiceNote.maxBytes + 1)
        await voice.start(.press)
        clock.now = clock.now.addingTimeInterval(30)
        voice.release()
        XCTAssertEqual(voice.error, "That recording is too long. Keep voice notes to about a minute.")
        recorder.audio = Data(repeating: 1, count: 100)

        // Silence, and the server's own words.
        await voice.start(.press)
        clock.now = clock.now.addingTimeInterval(2)
        voice.release()
        await settle(voice)
        XCTAssertEqual(voice.error, "No words came through. Try again a little closer to the microphone.")
        reply = { throw APIError.misconfigured("Voice notes need an OpenAI key. Connect one in your Profile.") }
        await voice.start(.press)
        clock.now = clock.now.addingTimeInterval(2)
        voice.release()
        await settle(voice)
        XCTAssertEqual(voice.error, "Voice notes need an OpenAI key. Connect one in your Profile.")

        // The microphone.
        recorder.problem = .blocked
        await voice.start(.press)
        XCTAssertEqual(voice.state, .idle)
        XCTAssertEqual(voice.error, "The microphone is blocked for healthOS. Allow it in Settings, or type instead.")
        recorder.problem = nil

        // Let go while the microphone was still being asked for: nothing is recorded.
        recorder.waits = true
        let starting = Task { await voice.start(.press) }
        while recorder.gate == nil { await Task.yield() }
        XCTAssertEqual(voice.state, .starting)
        XCTAssertEqual(voice.label, "Starting the microphone…")
        voice.release()
        recorder.gate?.resume()
        await starting.value
        XCTAssertEqual(voice.state, .idle)
        XCTAssertEqual(recorder.cancelled, 1)
        XCTAssertEqual(voice.error, "Hold the button while you talk, then let go.")
        recorder.waits = false

        // Leaving the page mid-recording throws it away.
        await voice.start(.press)
        voice.cancel()
        XCTAssertEqual(voice.state, .idle)
        XCTAssertEqual(recorder.cancelled, 2)

        // A touch taken away at once (the permission question, a scroll), before the start has even begun: the press
        // is already starting, so the release is heard and nothing records. (After leaving the page, the button is
        // ready again for the next note.)
        voice.press()
        XCTAssertEqual(voice.state, .starting)
        voice.release()
        for _ in 0..<200 where voice.state != .idle { await Task.yield() }
        XCTAssertEqual(voice.state, .idle)
        XCTAssertEqual(recorder.cancelled, 3)
        XCTAssertEqual(voice.error, "Hold the button while you talk, then let go.")

        let hook = try web("src/hooks/useVoiceNote.ts")
        for words in ["Hold the button while you talk, then let go.", "That was too short to hear anything. Try again.",
                      "That recording is too long. Keep voice notes to about a minute.", "No words came through. Try again a little closer to the microphone.",
                      "No microphone was found. Type what you had instead.", "The microphone is in use by another app. Try again, or type instead.",
                      "The microphone couldn't start. Type what you had instead.", "Couldn't reach healthOS. Check your connection and try again.",
                      "That recording couldn't be transcribed. Try again, or type it instead.", "MAX_MS = 60_000", "MIN_MS = 500", "MAX_BYTES = 4 * 1024 * 1024"] {
            XCTAssertTrue(hook.contains(words), words)
        }
        XCTAssertEqual(VoiceProblem.noMicrophone.message, "No microphone was found. Type what you had instead.")
        XCTAssertEqual(VoiceWords.unreachable, "Couldn't reach healthOS. Check your connection and try again.")
    }

    /// A transcription that comes back after its note was given up on (the page left and come back to, or the app
    /// sent to the background) and a new note started: it's dropped, and the new recording goes on and stops as usual.
    func testWordsForANoteGivenUpOnNeverTouchTheNextOne() async {
        let recorder = FakeRecorder()
        let clock = Clock()
        var answers: [CheckedContinuation<String, Never>] = []
        var sent = 0
        let voice = VoiceNote(recorder: recorder, transcribe: { _ in
            sent += 1
            return await withCheckedContinuation { answers.append($0) }
        }, now: { clock.now })
        var words: [String] = []
        voice.onText = { words.append($0) }

        await voice.start(.press)
        clock.now = clock.now.addingTimeInterval(3)
        voice.release()
        XCTAssertEqual(voice.state, .transcribing)
        while answers.isEmpty { await Task.yield() }

        // Away and back while it's written down, then a new note.
        voice.cancel()
        XCTAssertEqual(voice.state, .idle)
        await voice.start(.press)
        XCTAssertEqual(voice.state, .recording)

        // The first note's words arrive: nothing of them is used, and the recording isn't ended.
        answers[0].resume(returning: "the first note")
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(voice.state, .recording, "the new recording goes on")
        XCTAssertEqual(words, [])
        XCTAssertNil(voice.error)

        // Let go: the microphone stops (no stop is skipped), and the second note is written down.
        clock.now = clock.now.addingTimeInterval(2)
        voice.release()
        XCTAssertEqual(recorder.stopped, 2)
        XCTAssertEqual(voice.state, .transcribing)
        while answers.count < 2 { await Task.yield() }
        answers[1].resume(returning: "the second note")
        await settle(voice)
        XCTAssertEqual(voice.state, .idle)
        XCTAssertEqual(words, ["the second note"])
        XCTAssertEqual(sent, 2)
        XCTAssertEqual(recorder.cancelled, 0, "neither recording was cancelled: the first had already stopped")
    }

    /// The microphone's permission question makes the app inactive for a moment: a note started from VoiceOver waits
    /// for the answer and records. Given up on meanwhile, it stops its own recording when the answer comes, and no
    /// second start runs over it.
    func testANoteWaitingForTheMicrophoneEndsOnlyItself() async {
        let recorder = FakeRecorder()
        let clock = Clock()
        let voice = VoiceNote(recorder: recorder, transcribe: { _ in "words" }, now: { clock.now })

        recorder.waits = true
        let first = Task { await voice.start(.toggle) }
        while recorder.gate == nil { await Task.yield() }
        XCTAssertEqual(voice.state, .starting)
        recorder.gate?.resume()
        recorder.gate = nil
        await first.value
        XCTAssertEqual(voice.state, .recording, "Allow: it records")
        clock.now = clock.now.addingTimeInterval(2)
        voice.toggle()
        await settle(voice)
        XCTAssertEqual(voice.state, .idle)
        XCTAssertNil(voice.error)

        // Given up on (the background) while the question is up.
        let second = Task { await voice.start(.toggle) }
        while recorder.gate == nil { await Task.yield() }
        voice.cancel()
        XCTAssertEqual(voice.state, .idle)
        XCTAssertEqual(recorder.cancelled, 1)
        // Pressed again while that start still waits: nothing starts over it.
        voice.toggle()
        XCTAssertEqual(voice.state, .idle)
        XCTAssertEqual(recorder.started, 2)
        recorder.gate?.resume()
        await second.value
        XCTAssertEqual(voice.state, .idle, "the answer came for a note given up on")
        XCTAssertEqual(recorder.cancelled, 2, "it stopped its own recording")
        XCTAssertNil(voice.error, "and said nothing: the person had left")

        // The next note works as usual.
        recorder.waits = false
        await voice.start(.toggle)
        XCTAssertEqual(voice.state, .recording)
    }

    func testATranscriptionsRefusalSaysWhy() {
        // An older server without POST /ai/transcribe answers its catch-all; one that can't be reached, nothing.
        XCTAssertEqual(VoiceWords.error(APIError.server(404, "Not found")).localizedDescription, VoiceWords.notTranscribed)
        XCTAssertEqual(VoiceWords.error(APIError.server(404, "")).localizedDescription, VoiceWords.notTranscribed)
        XCTAssertEqual(VoiceWords.error(APIError.network("Can't reach localhost. Could not connect to the server.")).localizedDescription, VoiceWords.unreachable)
        // The server's own words otherwise (server/ai/routes.ts), as the web shows them.
        let limit = "You've used today's 20 voice notes on healthOS's shared key. Type what you had instead."
        XCTAssertEqual(VoiceWords.error(APIClient.error(status: 429, message: limit, path: "/ai/transcribe")).foodMessage, limit)
        let noKey = "Voice notes need an OpenAI key. Connect one in your Profile."
        XCTAssertEqual(VoiceWords.error(APIClient.error(status: 503, message: noKey, path: "/ai/transcribe")).foodMessage, noKey)
        // Signing in again and a cancellation stay what they are.
        guard case .signInRequired? = VoiceWords.error(APIError.signInRequired) as? APIError else { return XCTFail("a 401 drops to sign-in") }
        XCTAssertTrue(APIClient.isCancellation(VoiceWords.error(CancellationError())))
    }

    func testARecordingLeftBehindIsDeleted() throws {
        let leftover = FileManager.default.temporaryDirectory.appendingPathComponent("healthos-voice-test.m4a")
        try Data([1, 2, 3]).write(to: leftover)
        MicrophoneRecorder.removeLeftovers()
        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path))
    }

    func testTheThreadsPhotoIsASmallCopy() throws {
        let photo = UIGraphicsImageRenderer(size: CGSize(width: 1280, height: 960), format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }())
            .image { ctx in UIColor.orange.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 1280, height: 960)) }
        let thumb = try XCTUnwrap(NutritionThread.thumbnail(try XCTUnwrap(photo.jpegData(compressionQuality: 0.8))))
        XCTAssertEqual(thumb.size.width * thumb.scale, 240)
        XCTAssertEqual(thumb.size.height * thumb.scale, 180)
        let attached = try XCTUnwrap(AttachedPhoto(data: try XCTUnwrap(photo.pngData())))
        XCTAssertEqual(attached.preview.size.width * attached.preview.scale, 1280, "a meal photo is sent at 1,280 px on its long edge")
        XCTAssertEqual(Array(attached.jpeg.prefix(3)), [0xFF, 0xD8, 0xFF], "as a JPEG")
    }

    // MARK: The page's views

    func testTheViewsAreTheWebsWithFallbacksForOlderServers() throws {
        XCTAssertEqual(NutritionTab.visible(.all), [.today, .trends, .macros, .hydration, .log])
        XCTAssertEqual(NutritionTab.visible(.noEnergy), [.today, .trends, .macros, .hydration, .log])
        XCTAssertEqual(NutritionTab.visible(.none), [.today, .trends, .log], "no amounts: no Macros or Hydration")
        XCTAssertEqual(NutritionTab.visible(.all).map(\.label), ["Today", "Trends", "Macros", "Hydration", "Log"])
        // Links: ?tab=overview is Trends's old name, and anything else unknown is Today.
        XCTAssertEqual(NutritionTab.of("overview"), .trends)
        XCTAssertEqual(NutritionTab.of("macros"), .macros)
        XCTAssertEqual(NutritionTab.of(nil), .today)
        XCTAssertEqual(NutritionTab.of("soon"), .today)
        XCTAssertEqual(NutritionTab.current(.macros, in: NutritionTab.visible(.none)), .today, "a view this setting hides opens Today")
        // An older server without one day of the log shows the Log in Today's place; one without the log at all, Trends.
        let older = NutritionTab.visible(.all, today: false)
        XCTAssertEqual(older, [.trends, .macros, .hydration, .log])
        XCTAssertEqual(NutritionTab.current(.today, in: older), .log)
        let oldest = NutritionTab.visible(.all, today: true, logging: false)
        XCTAssertEqual(oldest, [.trends, .macros, .hydration])
        XCTAssertEqual(NutritionTab.current(.today, in: oldest), .trends)
        XCTAssertEqual(NutritionTab.current(.log, in: oldest), .trends)
        // Profile's card places link to ?tab=overview, which the page opens as Trends.
        XCTAssertEqual(NutritionTab.of(CardPlace.nutritionOverview.route.query["tab"]), .trends)

        let page = try web("src/pages/Nutrition.tsx")
        XCTAssertTrue(page.contains("{ id: 'today', label: 'Today' },\n  { id: 'trends', label: 'Trends' },\n  { id: 'macros', label: 'Macros' },\n  { id: 'hydration', label: 'Hydration' },\n  { id: 'log', label: 'Log' },"))
        XCTAssertTrue(page.contains("param === 'overview' ? 'trends'"))
        for words in ["What you log here or in your food app. Only you can see it.", "A conversation about what nourishes you. Off until you turn it on.",
                      "Average day", "Each average counts only the days that nutrient was logged.", "On days two apps logged",
                      "Use one app's totals. Automatic picks whichever logged the most that day.", "a day on average, over the",
                      "What it shows", "What stays private", "First, choose what you want to see", "You can change it any time in your Profile."] {
            XCTAssertTrue(page.contains(words), words)
        }
    }

    /// The conversation, its last full photo and the draft live only in the page (memory only, as privacy.html
    /// promises), and the page is made anew for another person or another server: its key names both. Signed out,
    /// PhaseGate shows sign-in instead of the page, so nothing of it stays.
    func testTheConversationIsOnePersonsOnOneServer() throws {
        let one = URL(string: "http://localhost:8807"), other = URL(string: "http://192.168.1.20:8787")
        XCTAssertEqual(NutritionScreen.identity(server: one, user: "u1"), NutritionScreen.identity(server: one, user: "u1"))
        XCTAssertNotEqual(NutritionScreen.identity(server: one, user: "u1"), NutritionScreen.identity(server: one, user: "u2"), "another person")
        XCTAssertNotEqual(NutritionScreen.identity(server: one, user: "u1"), NutritionScreen.identity(server: other, user: "u1"), "another server")
        XCTAssertNotEqual(NutritionScreen.identity(server: one, user: nil), NutritionScreen.identity(server: one, user: "u1"))
        // The web keys its conversation by person too (NutritionChat's key={status.user.id}).
        XCTAssertTrue(try web("src/pages/NutritionChat.tsx").contains("<NutritionChat key={status.user.id}"))
        // Nothing of the conversation, its photos or the draft is ever written or logged: none of the ways to keep or
        // log something appears in the code that holds them.
        for file in ["Nutrition/NutritionChatModel.swift", "Nutrition/NutritionToday.swift", "Nutrition/MealPhoto.swift", "Dashboard/NutritionScreen.swift"] {
            let code = try String(contentsOf: Self.root.appendingPathComponent("ios/HealthOSSync/\(file)"), encoding: .utf8)
            for writer in ["UserDefaults.", "FileManager.", ".write(to:", "SecItem", "URLCache", "SummaryCache.", "print(", "Logger(", "os_log", "NSLog", "@AppStorage", "@SceneStorage"] {
                XCTAssertFalse(code.contains(writer), "\(file): \(writer)")
            }
        }
    }

    // MARK: Links to the page

    func testALinkIsAppliedOnce() throws {
        var link = NutritionLink()
        let macros = RouteRequest(route: AppRoute(.nutrition, query: ["tab": "macros"]), id: 4)
        let first = link.take(macros)
        XCTAssertEqual(first?.tab, .macros)
        XCTAssertEqual(first?.compose, false)
        XCTAssertNil(link.take(macros), "coming back to the tab doesn't open Macros again")
        XCTAssertNil(link.take(nil))
        // Home's orb: Today, with its composer, once.
        let orb = RouteRequest(route: AppRoute(.nutrition, query: ["compose": "1", "tab": "macros"]), id: 5)
        let asked = link.take(orb)
        XCTAssertEqual(asked?.tab, .today)
        XCTAssertEqual(asked?.compose, true)
        XCTAssertNil(link.take(orb))
        // The same link opened again is a new request, and works again.
        XCTAssertEqual(link.take(RouteRequest(route: macros.route, id: 6))?.tab, .macros)
        XCTAssertEqual(link.take(RouteRequest(route: AppRoute(.nutrition, query: [:]), id: 7))?.tab, .today)
        // The web reads compose=1 from the address of Today alone (Nutrition.tsx).
        XCTAssertTrue(try web("src/pages/Nutrition.tsx").contains("compose={params.get('compose') === '1'}"))
    }
}
