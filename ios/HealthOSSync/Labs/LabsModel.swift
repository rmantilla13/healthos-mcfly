import SwiftUI

// Lab results (shared/labs.ts, GET /api/labs), and their words and bar (src/components/LabRange.tsx), shared by the
// Blood records page (slice L, whose folder this is) and Body's "Key biomarkers" card (slice I). Keep these signatures:
// LabsData and its parts, `LabWords.statusLabel/statusHint/rangeLabel/rangeText/number`, `LabRangeBar(result:compact:)`
// and `dashboard.labs()`. Nothing here judges a result: a status only says where a number sits against a range.

/// Where a result sits against its range. Never a verdict: "below the range", not "low" or "bad".
enum LabStatus: String, Codable {
    case below, within, above
}

/// The range a result is read against (LabRange): the lab's own printed one, or, only when the report printed none, a
/// typical adult range from the catalogue, always labelled as such.
struct LabRange: Codable, Equatable {
    let low: Double?
    let high: Double?
    let text: String
    /// "lab" | "typical"
    let kind: String
    let note: String?
    /// Only for a printed range with more than one band ("Male: 13.0-17.0 Female: 12.0-15.0"): nil when there's one
    /// band, `.some(nil)` when none could be picked, else "female" or "male", picked by the sex in the profile.
    let band: String??

    var typical: Bool { kind == "typical" }

    private enum CodingKeys: String, CodingKey { case low, high, text, kind, note, band }

    init(low: Double?, high: Double?, text: String, kind: String = "lab", note: String? = nil, band: String?? = nil) {
        self.low = low
        self.high = high
        self.text = text
        self.kind = kind
        self.note = note
        self.band = band
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        low = try? c.decodeIfPresent(Double.self, forKey: .low)
        high = try? c.decodeIfPresent(Double.self, forKey: .high)
        text = (try? c.decode(String.self, forKey: .text)) ?? ""
        kind = (try? c.decode(String.self, forKey: .kind)) ?? "lab"
        note = try? c.decodeIfPresent(String.self, forKey: .note)
        band = c.contains(.band) ? .some(try? c.decode(String.self, forKey: .band)) : nil
    }
}

/// One stored result, as printed, with where it sits against its own range (LabResult).
struct LabResult: Codable, Identifiable, Equatable {
    let id: String
    /// The day the sample was collected (YYYY-MM-DD).
    let collected: String
    /// A catalogue key, or "other:<slug>".
    let biomarker: String
    /// The marker's name as printed.
    let name: String
    /// The result as printed: "5.4", "<0.5", "Negative".
    let valueText: String
    let value: Double?
    /// "<" or ">": the true value is somewhere below or above `value`.
    let qualifier: String?
    let unit: String
    @Lossy var range: LabRange?
    @Lossy var status: LabStatus?
    let lab: String
    let panel: String
    /// "manual", "report" or "demo".
    let source: String

    private enum CodingKeys: String, CodingKey {
        case id, collected, biomarker, name, valueText, value, qualifier, unit, range, status, lab, panel, source
    }

    init(id: String = "r", collected: String = "", biomarker: String = "", name: String = "", valueText: String, value: Double?,
         qualifier: String? = nil, unit: String = "", range: LabRange?, status: LabStatus?, lab: String = "", panel: String = "",
         source: String = "manual") {
        self.id = id
        self.collected = collected
        self.biomarker = biomarker
        self.name = name
        self.valueText = valueText
        self.value = value
        self.qualifier = qualifier
        self.unit = unit
        _range = Lossy(wrappedValue: range)
        _status = Lossy(wrappedValue: status)
        self.lab = lab
        self.panel = panel
        self.source = source
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        collected = try c.decode(String.self, forKey: .collected)
        biomarker = (try? c.decode(String.self, forKey: .biomarker)) ?? ""
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        valueText = (try? c.decode(String.self, forKey: .valueText)) ?? ""
        value = try? c.decodeIfPresent(Double.self, forKey: .value)
        qualifier = try? c.decodeIfPresent(String.self, forKey: .qualifier)
        unit = (try? c.decode(String.self, forKey: .unit)) ?? ""
        _range = (try? c.decode(Lossy<LabRange>.self, forKey: .range)) ?? Lossy(wrappedValue: nil)
        _status = (try? c.decode(Lossy<LabStatus>.self, forKey: .status)) ?? Lossy(wrappedValue: nil)
        lab = (try? c.decode(String.self, forKey: .lab)) ?? ""
        panel = (try? c.decode(String.self, forKey: .panel)) ?? ""
        source = (try? c.decode(String.self, forKey: .source)) ?? ""
    }
}

/// One biomarker: its latest result, every result oldest first, and the exact values that can be drawn together
/// (LabMarker).
struct LabMarker: Codable, Identifiable, Equatable {
    struct Point: Codable, Equatable {
        let id: String
        let date: String
        let value: Double
    }

    let key: String
    let name: String
    let group: String
    let latest: LabResult
    @LossyArray var history: [LabResult]
    /// Exact values in the latest result's unit, oldest first.
    @LossyArray var points: [Point]
    /// Results in a unit that can't be put on the same scale as the latest one.
    @Lossy var otherUnits: Int?

    var id: String { key }
}

/// One collection: the results from one day, one lab and one panel (LabPanel).
struct LabPanel: Codable, Equatable {
    let collected: String
    let lab: String
    let panel: String
    @LossyArray var results: [LabResult]
}

/// GET /api/labs (LabsData): every marker and every collection, newest first. A marker or panel that can't be read is
/// left out, not the whole answer.
struct LabsData: Codable, Equatable {
    let today: String
    /// The demo results are showing (a local demo database, before any results of your own).
    @Lossy var demo: Bool?
    @Lossy var count: Int?
    @LossyArray var markers: [LabMarker]
    @LossyArray var panels: [LabPanel]

    /// The latest results, most recently collected first (Body's card shows six): a stable sort keeps the catalogue's
    /// order within a day, as BiomarkersCard.tsx does.
    func latest(_ count: Int) -> [LabMarker] {
        Array(markers.enumerated().sorted { a, b in
            a.element.latest.collected != b.element.latest.collected ? a.element.latest.collected > b.element.latest.collected : a.offset < b.offset
        }.map(\.element).prefix(count))
    }
}

extension APIClient {
    /// GET /api/labs. It's older than this branch, so every server with accounts has it.
    func labs() async throws -> LabsData { try await get("/labs") }
}

extension Dashboard {
    /// Every lab result (the Blood records page, Body's Key biomarkers card).
    func labs() async throws -> LabsData { try await fetch { try await $0.labs() } }
}

/// The web's words for a result against its range (shared/labs.ts). The words carry the meaning; colour and the bar
/// only repeat it.
enum LabWords {
    static let statusWords: [LabStatus: String] = [.below: "Below range", .within: "Within range", .above: "Above range"]

    /// The status in words. A typical range says so, so it's never mistaken for the lab's own (statusLabel).
    static func statusLabel(_ r: LabResult) -> String {
        if let status = r.status {
            let where_ = [LabStatus.below: "Below", .within: "Within", .above: "Above"][status] ?? ""
            return "\(where_) \(r.range?.typical == true ? "typical range" : "range")"
        }
        guard let range = r.range else { return "No range printed" }
        if r.value == nil { return "Compare with range" }
        // A printed range with no numbers in it ("See note"), not several bands.
        if range.low == nil, range.high == nil, range.band == nil { return "Compare with range" }
        return "Can’t be placed"
    }

    /// Why there's no status, or which range a status is against when it isn't simply the printed one (statusHint).
    static func statusHint(_ r: LabResult) -> String? {
        let range = r.range
        if r.status != nil, let range, range.typical {
            return "The report printed no range, so this uses a typical adult range\(range.note.map { " (\($0))" } ?? "")."
        }
        if r.status != nil, let band = range?.band ?? nil {
            return "The report printed more than one range. This uses the one for \(band == "female" ? "women" : "men"), from the sex in your profile."
        }
        if r.status != nil { return nil }
        guard let range else { return "The report printed no range, and there's no typical range to use for this marker." }
        if r.value == nil { return "The result is a word, not a number: compare it with the printed range." }
        if case .some(.none) = range.band {
            return "The printed range has more than one band (by sex, age or category), so this result isn't placed against any one of them. If your profile has no sex chosen and the bands are for women and men, choosing one may place it."
        }
        if range.low == nil, range.high == nil { return "The printed range has no numbers to place this against: compare the result with the range as printed." }
        return "Printed as \(r.valueText), which could fall on either side of the range."
    }

    /// The range text as printed, with a note when it's the typical one or one band of several (rangeLabel).
    static func rangeLabel(_ r: LabResult) -> String {
        guard let range = r.range else { return "—" }
        if range.typical { return "\(range.text) (typical adult\(range.note.map { ", \($0)" } ?? ""))" }
        if let band = range.band ?? nil { return "\(range.text) (\(band) range used)" }
        return range.text
    }

    /// A range written out: "3.5–5.0", "≤ 199", "≥ 40" (rangeText).
    static func rangeText(_ low: Double?, _ high: Double?) -> String {
        switch (low, high) {
        case let (low?, high?): "\(plain(low))–\(plain(high))"
        case let (nil, high?): "≤ \(plain(high))"
        case let (low?, nil): "≥ \(plain(low))"
        default: ""
        }
    }

    /// Up to three significant figures, without trailing zeros: 4.5, 0.45, 1,245 (labNumber).
    static func number(_ v: Double) -> String {
        let a = abs(v)
        let digits = a >= 100 ? 0 : a >= 10 ? 1 : a >= 1 ? 2 : 3
        return v.formatted(.number.precision(.fractionLength(0...digits)))
    }

    /// A number as JavaScript writes it in a template: 5, 4.5.
    private static func plain(_ v: Double) -> String {
        v == v.rounded() && abs(v) < 1e15 ? String(Int(v)) : String(v)
    }
}

/// The web's lab colours (styles.css, "Lab tests"): the shaded range, the result's mark, and the status chips.
enum LabColors {
    static let band: Themed<CSSColor> = Themed(0xCDEBC4, 0x2A5426)
    static let dot: Themed<CSSColor> = Themed(0x0B0B0B, 0xF0EFEC)
    static let out: Themed<CSSColor> = Themed(0xC4521F, 0xF08A5D)
    static let withinBg: Themed<CSSColor> = Themed(0xDFF3D8, 0x1D3A1B)
    static let withinInk: Themed<CSSColor> = Themed(0x1F6B1F, 0x8FDC85)
    static let outBg: Themed<CSSColor> = Themed(0xFFE4D4, 0x432617)
    static let outInk: Themed<CSSColor> = Themed(0x9A3F17, 0xF4A97F)
    static let noneBg: Themed<CSSColor> = Themed(0xEFEFEC, 0x262625)

    /// By the CSS's names, for the test that reads styles.css.
    static let all: [String: Themed<CSSColor>] = [
        "lab-band": band, "lab-dot": dot, "lab-out": out, "lab-within-bg": withinBg, "lab-within-ink": withinInk,
        "lab-out-bg": outBg, "lab-out-ink": outInk, "lab-none-bg": noneBg,
    ]
}

/// A result against its range (LabRangeBar): a track, the range shaded on it, and the result as a dot, hollow when it was
/// printed with "<" or ">", in the out colour outside the range. One-sided ranges ("<200", ">39") shade from zero or to
/// the end; a result far outside sits at the edge. Decorative: the range and status are always written beside it.
/// Without a range it draws nothing, or, `compact` (Body's card, in a row of them), an empty track's space.
struct LabRangeBar: View {
    let result: LabResult
    var compact = false

    /// Where the band and the dot sit along the track, 0 to 1; nil without a range to draw.
    static func layout(_ result: LabResult) -> (bandFrom: Double, bandTo: Double, dot: Double?)? {
        guard let range = result.range, range.low != nil || range.high != nil else { return nil }
        let lo: Double, hi: Double, from: Double, to: Double
        if let low = range.low, let high = range.high {
            let pad = nonZero((high - low) * 0.6) ?? nonZero(abs(high) * 0.2) ?? 1
            lo = max(low >= 0 ? 0 : -.infinity, low - pad)
            hi = high + pad
            (from, to) = (low, high)
        } else if let high = range.high {
            lo = 0
            hi = nonZero(high * 1.6) ?? 1
            (from, to) = (0, high)
        } else {
            let low = range.low ?? 0
            lo = 0
            hi = nonZero(low * 2) ?? 1
            (from, to) = (low, hi)
        }
        func t(_ v: Double) -> Double { min(1, max(0, (v - lo) / (nonZero(hi - lo) ?? 1))) }
        return (t(from), t(to), result.value.map(t))
    }

    private static func nonZero(_ v: Double) -> Double? { v == 0 || v.isNaN ? nil : v }

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let at = Self.layout(result) {
            GeometryReader { geo in
                let w = geo.size.width
                let out = result.status == .below || result.status == .above
                let mark = (out ? LabColors.out : LabColors.dot).color
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.axis).frame(height: 2)
                    Capsule().fill(LabColors.band.color).frame(width: max(0, (at.bandTo - at.bandFrom) * w), height: 6)
                        .offset(x: at.bandFrom * w)
                    if let dot = at.dot {
                        Circle()
                            .fill(result.qualifier != nil ? Palette.surface : mark)
                            .overlay { if result.qualifier != nil { Circle().strokeBorder(mark, lineWidth: 2) } }
                            .frame(width: 10, height: 10)
                            .background(Circle().fill(Palette.surface).padding(-2))
                            .offset(x: dot * w - 5)
                    }
                }
                .frame(height: 10)
            }
            .frame(maxWidth: compact ? .infinity : 170)
            .frame(height: 10)
            .accessibilityHidden(true)
        } else if compact {
            Color.clear.frame(height: 10).accessibilityHidden(true)
        }
    }
}
