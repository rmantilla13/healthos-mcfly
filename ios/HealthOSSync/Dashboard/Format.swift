import Foundation

/// Number, date and unit formatting, matching src/lib.ts so the app and the web read the same.
enum Fmt {
    private static var numberFormatters: [Int: NumberFormatter] = [:]

    static func number(_ value: Double, _ digits: Int = 0) -> String {
        let f = numberFormatters[digits] ?? {
            let f = NumberFormatter()
            f.numberStyle = .decimal
            f.minimumFractionDigits = digits
            f.maximumFractionDigits = digits
            numberFormatters[digits] = f
            return f
        }()
        return f.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// 12,400 -> "12.4K"; 10,000 -> "10K".
    static func compact(_ value: Double) -> String {
        abs(value) >= 1000 ? number(value / 1000, value.truncatingRemainder(dividingBy: 1000) == 0 ? 0 : 1) + "K" : number(value)
    }

    /// 445 minutes -> "7h 25m"; 45 -> "45m".
    static func duration(minutes: Double) -> String {
        let h = Int(minutes / 60)
        let m = Int((minutes.truncatingRemainder(dividingBy: 60)).rounded())
        return h > 0 ? "\(h)h \(String(format: "%02d", m))m" : "\(m)m"
    }

    static func hoursMinutes(_ hours: Double) -> String { duration(minutes: hours * 60) }

    /// "+3", "−3" (true minus sign), "0".
    static func signed(_ value: Double, _ digits: Int = 0) -> String {
        let v = number(abs(value), digits)
        return value > 0 ? "+\(v)" : value < 0 ? "−\(v)" : v
    }

    /// A signed difference in minutes: "+24 min", "−1h 05m", "0 min".
    static func signedMinutes(_ minutes: Double) -> String {
        let m = minutes.rounded()
        let size = abs(m) < 60 ? "\(Int(abs(m))) min" : duration(minutes: abs(m))
        return m > 0 ? "+\(size)" : m < 0 ? "−\(size)" : size
    }

    private static var dateFormatters: [String: DateFormatter] = [:]

    /// Formats a "YYYY-MM-DD" day with a template such as "MMMd" or "EEEEMMMMd".
    static func day(_ day: String, _ template: String = "MMMd") -> String {
        let f = dateFormatters[template] ?? {
            let f = DateFormatter()
            f.timeZone = TimeZone(identifier: "UTC")
            f.setLocalizedDateFormatFromTemplate(template)
            dateFormatters[template] = f
            return f
        }()
        return f.string(from: Day.midnightUTC(day))
    }

    static func relativeDay(_ day: String, today: String) -> String {
        let d = daysBetween(day, today)
        if d == 0 { return "Today" }
        if d == 1 { return "Yesterday" }
        if d > 1 && d < 7 { return "\(d) days ago" }
        return Fmt.day(day)
    }

    static func daysBetween(_ a: String, _ b: String) -> Int {
        Int((Day.midnightUTC(b).timeIntervalSince(Day.midnightUTC(a)) / 86_400).rounded())
    }

    /// Wall-clock time as recorded: the ISO strings carry the wearer's own offset, so slice, don't convert.
    static func clock(_ iso: String) -> String { String(iso.dropFirst(11).prefix(5)) }

    static func minutesOfDay(_ iso: String) -> Int {
        let c = clock(iso).split(separator: ":").compactMap { Int($0) }
        return c.count == 2 ? c[0] * 60 + c[1] : 0
    }

    /// Minutes after midnight as a 24-hour clock, wrapping past midnight: 390 -> "06:30", 1500 -> "01:00".
    static func clock(minutesOfDay minutes: Double) -> String {
        let m = (Int(minutes.rounded()) % 1440 + 1440) % 1440
        return String(format: "%02d:%02d", m / 60, m % 60)
    }

    /// Bedtimes from /api/sleep count minutes after 18:00 so a night doesn't wrap at midnight: 330 -> "23:30", 430 -> "01:10".
    static func eveningClock(minutesAfter18 minutes: Double) -> String { clock(minutesOfDay: 18 * 60 + minutes) }

    /// Plots a "YYYY-MM-DD" day at local noon, so chart axes label it with the right date in any time zone.
    static func chartDate(_ day: String) -> Date {
        let p = day.split(separator: "-").compactMap { Int($0) }
        return Calendar.current.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: 12)) ?? Day.midnightUTC(day)
    }
}

struct Measure {
    let value: Double
    let unit: String
    func text(_ digits: Int) -> String { "\(Fmt.number(value, digits)) \(unit)" }

    /// "+0.4 °C", "−0.7 °F", "0.0 °C": the sign follows the rounded value, so a tiny change reads as no change.
    func signed(_ digits: Int) -> String {
        let scale = pow(10, Double(digits))
        let rounded = (value * scale).rounded() / scale
        return "\(Fmt.signed(rounded == 0 ? 0 : rounded, digits)) \(unit)"
    }
}

enum Units: String {
    case metric, imperial

    func temp(_ celsius: Double) -> Measure { self == .imperial ? Measure(value: celsius * 9 / 5 + 32, unit: "°F") : Measure(value: celsius, unit: "°C") }
    func mass(_ kg: Double) -> Measure { self == .imperial ? Measure(value: kg / 0.45359237, unit: "lb") : Measure(value: kg, unit: "kg") }
    func distance(_ m: Double) -> Measure { self == .imperial ? Measure(value: m / 1609.344, unit: "mi") : Measure(value: m / 1000, unit: "km") }
    /// A temperature difference (deviation from baseline): °F scales by 9/5 with no +32 offset. Show it with `signed`.
    func tempDelta(_ celsius: Double) -> Measure { self == .imperial ? Measure(value: celsius * 9 / 5, unit: "°F") : Measure(value: celsius, unit: "°C") }
}

extension Array where Element == Point {
    var average: Double? { isEmpty ? nil : reduce(0) { $0 + $1.value } / Double(count) }

    /// Over long ranges, daily bars get too thin to read; average them by week (Monday start), like the web.
    func weekly(days: Int) -> [Point] {
        guard days > 90 else { return self }
        var buckets: [(String, [Double])] = []
        for p in self {
            let monday = Point.weekStart(p.date)
            if let i = buckets.firstIndex(where: { $0.0 == monday }) { buckets[i].1.append(p.value) } else { buckets.append((monday, [p.value])) }
        }
        return buckets.map { Point(date: $0.0, value: $0.1.reduce(0, +) / Double($0.1.count)) }
    }

    /// Trailing mean over calendar days: each point becomes the average of the readings in the `days` days ending on
    /// its date (gaps don't stretch the window). One output point per input point, oldest first.
    func rolling(days: Int) -> [Point] {
        let days = Swift.max(1, days)
        let sorted = self.sorted { $0.date < $1.date }
        var out: [Point] = []
        var start = 0
        var sum = 0.0
        for (i, p) in sorted.enumerated() {
            sum += p.value
            while Fmt.daysBetween(sorted[start].date, p.date) >= days {
                sum -= sorted[start].value
                start += 1
            }
            out.append(Point(date: p.date, value: sum / Double(i - start + 1)))
        }
        return out
    }

    /// Sums by Monday-start week for the `weeks` weeks up to and including the week of `ending`, oldest first. Every
    /// week is there, so the axis stays steady; a week with no readings sums to 0. Each point is dated by its Monday.
    func weeklySums(weeks: Int, ending: String) -> [Point] {
        let last = Point.weekStart(ending)
        let mondays = (0..<Swift.max(0, weeks)).reversed().map { Day.add(last, -7 * $0) }
        var sums = Dictionary(uniqueKeysWithValues: mondays.map { ($0, 0.0) })
        for p in self {
            let monday = Point.weekStart(p.date)
            if sums[monday] != nil { sums[monday]! += p.value }
        }
        return mondays.map { Point(date: $0, value: sums[$0] ?? 0) }
    }
}

extension Point {
    static func weekStart(_ day: String) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let weekday = cal.component(.weekday, from: Day.midnightUTC(day)) // 1 = Sunday
        return Day.add(day, -((weekday + 5) % 7))
    }
}

/// "Week so far" sentences from the summary, the same wording as WeekSummaryText in src/pages/Home.tsx.
enum WeekText {
    static func title(_ w: WeekSummary) -> String {
        w.days == 1 ? "Week so far · \(Fmt.day(w.start, "EEEE"))" : "Week so far · \(Fmt.day(w.start, "EEE"))–\(Fmt.day(w.end, "EEE"))"
    }

    static func body(_ w: WeekSummary, stepGoal: Double) -> AttributedString {
        func bold(_ s: String) -> AttributedString {
            var a = AttributedString(s)
            a.inlinePresentationIntent = .stronglyEmphasized
            return a
        }
        func pct(_ a: Double, _ b: Double) -> Int { Int(((a - b) / b * 100).rounded()) }
        var sentences: [AttributedString] = []

        if let avg = w.sleep.avg {
            var s = AttributedString("You're sleeping ") + bold(Fmt.hoursMinutes(avg)) + AttributedString(" a night")
            if let prev = w.sleep.prev {
                let diff = Int(((avg - prev) * 60).rounded())
                s += abs(diff) < 5 ? AttributedString(", about the same as last week") : AttributedString(", ") + bold("\(abs(diff)) min \(diff > 0 ? "more" : "less")") + AttributedString(" than last week")
            }
            sentences.append(s + AttributedString("."))
        }

        var activity: [AttributedString] = []
        if let avg = w.steps.avg {
            var s = AttributedString("Steps average ") + bold(Fmt.number((avg / 10).rounded() * 10)) + AttributedString(" a day")
            if let prev = w.steps.prev, prev != 0 {
                let change = pct(avg, prev)
                if abs(change) >= 5 { s += AttributedString(" (\(change > 0 ? "up" : "down") \(abs(change))%)") }
            }
            s += w.steps.goalDays > 0
                ? AttributedString(", with your goal met on ") + bold("\(w.steps.goalDays) of \(w.steps.daysWithData)") + AttributedString(" days")
                : AttributedString(", under your \(Fmt.compact(stepGoal)) goal")
            activity.append(s)
        }
        let n = w.workouts.count
        activity.append(n > 0
            ? bold("\(n) workout\(n == 1 ? "" : "s")") + AttributedString(" logged (\(Fmt.duration(minutes: w.workouts.minutes)))")
            : AttributedString(activity.isEmpty ? "No workouts logged yet" : "no workouts logged yet"))
        sentences.append(activity.dropFirst().reduce(activity[0]) { $0 + AttributedString("; ") + $1 } + AttributedString("."))

        var heart: [(lead: String, value: String?)] = []
        if let avg = w.restingHr.avg, let prev = w.restingHr.prev {
            let d = avg - prev
            heart.append(abs(d) < 1 ? ("resting heart rate is steady", nil) : ("resting heart rate is ", "\(d < 0 ? "down" : "up") \(Fmt.number(abs(d), 1)) bpm"))
        }
        if let avg = w.hrv.avg, let prev = w.hrv.prev, prev != 0 {
            let c = pct(avg, prev)
            heart.append(abs(c) < 3 ? ("HRV is holding steady", nil) : ("HRV is ", "\(c > 0 ? "up" : "down") \(abs(c))%"))
        }
        if let avg = w.recovery.avg { heart.append(("recovery averages ", "\(Fmt.number(avg))%")) }
        if !heart.isEmpty {
            var s = AttributedString()
            for (i, h) in heart.enumerated() {
                if i > 0 { s += AttributedString(i == heart.count - 1 ? " and " : ", ") }
                s += AttributedString(i == 0 ? h.lead.prefix(1).uppercased() + h.lead.dropFirst() : h.lead)
                if let v = h.value { s += bold(v) }
            }
            sentences.append(s + AttributedString("."))
        }

        if w.sleep.avg == nil && w.steps.avg == nil && n == 0 && heart.isEmpty { return AttributedString("Nothing recorded yet this week.") }
        return sentences.dropFirst().reduce(sentences[0]) { $0 + AttributedString(" ") + $1 }
    }
}
