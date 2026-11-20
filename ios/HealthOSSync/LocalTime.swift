import Foundation
import HealthKit

/// A moment plus the UTC offset it was recorded in. Mirrors `Stamp` in server/dates.ts, so a
/// day is always the wearer's local calendar day, wherever they were at the time.
struct Stamp {
    let date: Date
    let offsetSeconds: Int

    init(_ date: Date, timeZone: TimeZone) {
        self.date = date
        offsetSeconds = timeZone.secondsFromGMT(for: date)
    }

    private func wall(shift: TimeInterval = 0) -> DateComponents {
        // Whole seconds, like the server's toISOString().slice(0, 19).
        let seconds = floor(date.timeIntervalSince1970) + TimeInterval(offsetSeconds) + shift
        return Stamp.utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date(timeIntervalSince1970: seconds))
    }

    /// Wall-clock hour (0–23) where it was recorded.
    var localHour: Int { wall().hour! }

    /// Local calendar date (YYYY-MM-DD). Sleep passes `Day.rollover` so a night counts toward the wake day.
    func localDate(shift: TimeInterval = 0) -> String {
        let c = wall(shift: shift)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    /// ISO string carrying the local offset, e.g. 2024-01-15T07:30:00-08:00 (server `toLocalIso`).
    var localIso: String {
        let c = wall()
        let abs = Swift.abs(offsetSeconds) / 60
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
            + (offsetSeconds < 0 ? "-" : "+") + String(format: "%02d:%02d", abs / 60, abs % 60)
    }

    static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
}

enum Day {
    /// Sleep that ends up to 6h before midnight belongs to the next day (server DAY_ROLLOVER_MS).
    static let rollover: TimeInterval = 6 * 3600

    private static let parser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func midnightUTC(_ day: String) -> Date { parser.date(from: day)! }
    static func add(_ day: String, _ days: Int) -> String { parser.string(from: midnightUTC(day).addingTimeInterval(TimeInterval(days) * 86_400)) }
    static func today() -> String { Stamp(Date(), timeZone: .current).localDate() }
    static func of(_ date: Date) -> String { Stamp(date, timeZone: .current).localDate() }
    /// Midnight that starts this calendar day in the phone's time zone.
    static func localMidnight(_ day: String) -> Date? {
        let p = day.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
    }
}

extension HKSample {
    /// The time zone the sample was recorded in, when the writer saved it; otherwise the device's.
    var recordedTimeZone: TimeZone {
        if let id = metadata?[HKMetadataKeyTimeZone] as? String, let tz = TimeZone(identifier: id) { return tz }
        return .current
    }

    var startStamp: Stamp { Stamp(startDate, timeZone: recordedTimeZone) }
    var endStamp: Stamp { Stamp(endDate, timeZone: recordedTimeZone) }
    var sourceName: String { sourceRevision.source.name }
    var writtenBy: SampleSource { SampleSource(name: sourceRevision.source.name, bundleIdentifier: sourceRevision.source.bundleIdentifier) }
}

/// The app or device that wrote a sample.
struct SampleSource: Equatable {
    let name: String
    let bundleIdentifier: String

    /// A source healthOS reads directly, not through Apple Health: WHOOP (its API) or NOOP (its export, or the strap).
    /// Both write their readings into Apple Health too, and counting those copies as well would double them.
    var isReadDirectly: Bool { isWhoop || isNoop }

    /// WHOOP's own app. Same rule as fromDirectSource in server/apple/import.ts (/^whoop\b/i on the name), plus the
    /// bundle ID.
    var isWhoop: Bool {
        bundleIdentifier.lowercased().contains("whoop")
            || name.trimmingCharacters(in: .whitespaces).range(of: #"^whoop\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// NOOP's iPhone app (github.com/ryanbr/noop), which reads a WHOOP strap over Bluetooth and writes heart rate, HRV
    /// (its RMSSD, into the SDNN type), resting heart rate, SpO2, respiratory rate, sleep and workouts into Health.
    /// Its bundle ID is `<prefix>.noop` under whichever team built it (com.noopapp.noop for NOOP's own builds), matched
    /// as a whole last part; or, as sideloading tools add their team ID after it, any app named exactly "NOOP".
    /// Except NOOP's watch app, also named "NOOP" (`<prefix>.noop.watch`): what it records comes from the Apple Watch's
    /// own sensor, not the strap. The export importer has only the name to go on (fromDirectSource).
    var isNoop: Bool {
        let id = bundleIdentifier.lowercased()
        if id.hasSuffix(".noop") { return true }
        let named = name.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("NOOP") == .orderedSame
        return named && !id.split(separator: ".").contains("watch")
    }

    /// Whether this source's records of `metric` count. WHOOP's and NOOP's are skipped (healthOS reads them directly),
    /// except steps: WHOOP's step count competes with the iPhone and Watch for a day's best single source, like the
    /// importer. NOOP doesn't write steps.
    func counts(_ metric: String) -> Bool { !isReadDirectly || metric == "steps" }
}
