import Foundation
import SwiftUI

// GET /api/peers (shared/peers.ts PeerData, server/peers.ts): where the person's own 30-day averages sit among a group
// of people their age who also take part. Only the group's rounded quartiles, its size as a range ("20+") and which
// quarter the person is in ever come back: never anyone's ids, names, exact count or own values, and the person is
// never in their own group. Read fresh each time the card opens, never kept on the phone.

/// One measurement from one source (shared/peers.ts PeerMetric). Read field by field: one the app can't read leaves the
/// others.
struct PeerMetric: Codable, Equatable, Identifiable {
    /// The group, rounded, with its size as a range: "20+" | "50+" | "100+".
    struct Group: Codable, Equatable {
        let size: String
        let median: Double
        let p25: Double
        let p75: Double
    }

    let metric: String
    let source: String
    /// Your 30-day average, rounded as the metric is shown; nil when you have none.
    let you: Double?
    let yourDays: Int
    /// "ready" | "gathering" | "not_enough_days"
    let status: String
    /// Which quarter you sit in (shared/peers.ts PeerBand), from the group's rounded figures. Only when ready.
    @Lossy var band: String?
    @Lossy var group: Group?

    var id: String { "\(metric)|\(source)" }
    /// The quarter, when the server named one the app knows.
    var quarter: Peers.Band? { band.flatMap(Peers.Band.init(rawValue:)) }

    private enum CodingKeys: String, CodingKey { case metric, source, you, yourDays, status, band, group }

    init(metric: String, source: String, you: Double?, yourDays: Int, status: String, band: String? = nil, group: Group? = nil) {
        self.metric = metric
        self.source = source
        self.you = you
        self.yourDays = yourDays
        self.status = status
        self.band = band
        self.group = group
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        metric = try c.decode(String.self, forKey: .metric)
        source = try c.decode(String.self, forKey: .source)
        you = try? c.decodeIfPresent(Double.self, forKey: .you)
        yourDays = (try? c.decodeIfPresent(Int.self, forKey: .yourDays)) ?? 0
        status = (try? c.decodeIfPresent(String.self, forKey: .status)) ?? ""
        _band = try c.decode(Lossy<String>.self, forKey: .band)
        _group = try c.decode(Lossy<Group>.self, forKey: .group)
    }
}

/// GET /api/peers. Not taking part: `reason` "off" (not ticked), "no_age" / "under_age" (it needs an age of 18 or
/// over) or "no_accounts" (a local healthOS without sign-in: there's nobody else). Taking part: the age group, the
/// window the averages cover, and a comparison per measurement the person has. `demo`: the local preview's made-up
/// group, never real people.
struct PeerData: Codable, Equatable {
    struct Window: Codable, Equatable {
        let from: String
        let to: String
    }

    let participating: Bool
    @Lossy var reason: String?
    @Lossy var ageBand: String?
    @Lossy var window: Window?
    @LossyArray var metrics: [PeerMetric]
    @Lossy var demo: Bool?

    init(participating: Bool, reason: String? = nil, ageBand: String? = nil, window: Window? = nil, metrics: [PeerMetric] = [], demo: Bool? = nil) {
        self.participating = participating
        self.reason = reason
        self.ageBand = ageBand
        self.window = window
        self.metrics = metrics
        self.demo = demo
    }

    /// Some measurement is waiting for enough people and none has a result yet: the web's banner above the rows.
    var gathering: Bool { metrics.contains { $0.status == "gathering" } && !metrics.contains { $0.status == "ready" } }
}

extension APIClient {
    /// GET /api/peers; nil from a server older than peer comparisons.
    func peers() async throws -> PeerData? { try await optional("/peers") }
}

extension Dashboard {
    /// The person's age-group comparison, computed by the server as it's asked (so turning it off shows at once); nil
    /// from a server without it. Never cached.
    func peers() async throws -> PeerData? { try await fetch { try await $0.peers() } }
}

/// What the comparison card read last (the web's useApi('/peers')), in memory only and for one person on one server:
/// the card that holds it starts afresh for anyone else. A failure shows in the web's words over what was read; the
/// next answer clears it. A server that answers with its catch-all 404 (`read` gives nil) has no comparison, and the
/// card hides.
@MainActor
@Observable
final class PeerReader {
    private(set) var data: PeerData?
    private(set) var error: String?
    /// The server predates comparisons.
    private(set) var missing = false
    /// Each read's number, so an older answer never replaces a newer one.
    private var reads = 0

    init(data: PeerData? = nil) { self.data = data }

    /// One read: `answer` is GET /api/peers (nil from a server without it).
    func read(_ answer: () async throws -> PeerData?) async {
        reads += 1
        let mine = reads
        do {
            let got = try await answer()
            guard mine == reads else { return }
            if let got {
                data = got
                error = nil
            } else {
                missing = true
            }
        } catch {
            guard mine == reads, !Task.isCancelled, !APIClient.isCancellation(error) else { return }
            self.error = PeerWords.message(error)
        }
    }
}

/// The web's words for the comparison (src/pages/Profile.tsx PeerBody and PeerRow), and its value formatting. Straight
/// apostrophes, as that file has them. PeersTests reads Profile.tsx to keep them in step.
enum PeerWords {
    static let title = "Your age-group comparison"
    static let meta = "Private to you"
    static let loading = "Loading…"
    static let fine = "Your result says which quarter of this healthOS group your average sits in. Sitting higher in the group does not necessarily mean better health."
    static let demo = "Sample group: in this local preview the people you're compared with are made up."
    static let noReadings = "No readings from WHOOP or Apple Health in the last 30 days to compare yet."
    static let gathering = "Not enough people in your age group yet. Results appear once at least \(Peers.minOthers) others have \(Peers.minDays) recorded days."
    static let waiting = "Waiting for enough people in your age group to compare with."

    static func loadFailed(_ message: String) -> String { "Couldn't load your comparison: \(message)" }

    /// A failed read in the words the web shows after "Couldn't load your comparison:" (src/lib.ts): the server's own
    /// message whatever its code, its plain fallback when it sent none, or "Couldn't reach healthOS…" offline.
    static func message(_ error: Error) -> String { PortraitWords.message(error) }

    /// Why the person isn't taking part, as Markdown: "Edit preferences" is a link to the welcome's steps where the
    /// server has them (`editLink`), plain words otherwise. nil for a reason the app doesn't know (the web shows nothing).
    static func notTakingPart(_ reason: String?, editLink: Bool) -> String? {
        let edit = editLink ? "[Edit preferences](healthos://welcome)" : "Edit preferences"
        switch reason {
        case "off": return "You're not taking part. Turn it on in \(edit)."
        case "no_age": return "Add your age in \(edit) to take part."
        case "under_age": return "Peer comparisons are for people aged 18 and over."
        case "no_accounts": return "There's no one to compare with here: this healthOS runs on this Mac without accounts."
        default: return nil
        }
    }

    /// "Ages 30–39 · your averages for Sep 27 – Oct 26" (the dates as the web's fmtDate: UTC, month and day).
    static func window(ageBand: String, from: String, to: String) -> String {
        "Ages \(ageBand) · your averages for \(Fmt.day(from)) – \(Fmt.day(to))"
    }

    /// Where your average sits (BAND_LABEL): a quarter, never a rank.
    static func bandLabel(_ band: Peers.Band) -> String {
        switch band {
        case .belowP25: "Below the group's 25th percentile"
        case .p25Median: "Between the 25th percentile and the median"
        case .medianP75: "Between the median and the 75th percentile"
        case .aboveP75: "Above the 75th percentile"
        }
    }

    /// SOURCE_LABEL; a source the app doesn't know shows as sent.
    static func sourceLabel(_ source: String) -> String {
        switch source {
        case "whoop": "WHOOP"
        case "apple": "Apple Health"
        case "demo": "Sample"
        default: source
        }
    }

    /// "Resting heart rate · WHOOP".
    static func heading(_ m: PeerMetric) -> String {
        "\(Peers.pair(metric: m.metric, source: m.source)?.label ?? m.metric) · \(sourceLabel(m.source))"
    }

    /// A value as the row shows it: sleep as hours and minutes, the rest rounded to the pair's digits with its unit
    /// ("58 bpm", "96.8%", "7,412 steps").
    static func value(_ v: Double, _ m: PeerMetric) -> String {
        if m.metric == "sleep_hours" { return hoursMinutes(v) }
        let pair = Peers.pair(metric: m.metric, source: m.source)
        return Fmt.number(v, pair?.digits ?? 0) + unit(pair)
    }

    /// The group's middle half: "52–64 ms", "6h 30m–7h 24m"; the unit once, at the end.
    static func range(_ lo: Double, _ hi: Double, _ m: PeerMetric) -> String {
        if m.metric == "sleep_hours" { return "\(hoursMinutes(lo))–\(hoursMinutes(hi))" }
        let pair = Peers.pair(metric: m.metric, source: m.source)
        let digits = pair?.digits ?? 0
        return "\(Fmt.number(lo, digits))–\(Fmt.number(hi, digits))\(unit(pair))"
    }

    /// "%" right after the number, any other unit after a space, none without a pair.
    private static func unit(_ pair: Peers.Pair?) -> String {
        guard let unit = pair?.unit, !unit.isEmpty else { return "" }
        return unit == "%" ? "%" : " \(unit)"
    }

    /// "Your average 58 bpm over 21 days"; nil when you have no average.
    static func yours(_ m: PeerMetric) -> String? {
        guard let you = m.you else { return nil }
        return "Your average \(value(you, m)) over \(m.yourDays) \(m.yourDays == 1 ? "day" : "days")"
    }

    /// "Group median 60 bpm · middle half 55–65 bpm · 50+ people".
    static func group(_ g: PeerMetric.Group, _ m: PeerMetric) -> String {
        "Group median \(value(g.median, m)) · middle half \(range(g.p25, g.p75, m)) · \(g.size) people"
    }

    /// "3 of 7 recorded days so far: your result appears after 7."
    static func notEnoughDays(_ m: PeerMetric) -> String {
        "\(m.yourDays) of \(Peers.minDays) recorded days so far: your result appears after \(Peers.minDays)."
    }

    /// A measurement still waiting for its group: your average first, when you have one.
    static func waiting(_ m: PeerMetric) -> String {
        (yours(m).map { "\($0). " } ?? "") + waiting
    }

    /// The web's hoursMinutes (src/lib.ts duration): the minutes rounded first, so 7.999 h reads "8h 00m".
    static func hoursMinutes(_ hours: Double) -> String {
        let t = Int((hours * 60).rounded())
        let h = t / 60, m = t % 60
        return h != 0 ? "\(h)h \(String(format: "%02d", m))m" : "\(m)m"
    }
}

/// The comparison bar's colours (src/styles/profile.css --peer-track, --peer-band, --peer-you): the group's outer
/// quarters, its middle half, and the quarter you're in. They're Profile's own, not the shared tokens in styles.css,
/// so they live here; PeersTests checks them against profile.css.
enum PeerColors {
    static let trackValue = Themed<CSSColor>(0xECEBE6, 0x2C2C2A)
    static let bandValue = Themed<CSSColor>(0xCBE0C0, 0x34503F)
    static let youValue = Themed<CSSColor>(0x3D5A49, 0xB5D1BB)

    static let track = trackValue.color
    static let band = bandValue.color
    static let you = youValue.color

    /// One quarter's colour: yours lit, the middle two the group's middle half, the outer two the track.
    static func quarter(_ q: Peers.Band, yours: Peers.Band) -> Color {
        if q == yours { return you }
        return q == .p25Median || q == .medianP75 ? band : track
    }
}
