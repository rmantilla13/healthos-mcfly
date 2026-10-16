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
}
