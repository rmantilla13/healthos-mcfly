import SwiftUI
import UIKit

// Scrubbing a day on Today's path (src/charts/scrub.ts and the timeline card in src/pages/Home.tsx): drag the
// marker through today (00:00 to now) or a whole past day, and the readout shows what was going on then, from the
// day's events and its hourly readings (GET /api/day). Every figure is a real reading or a running total of them,
// and says which hour it covers; nothing is spread across an hour or guessed between readings.

// MARK: - Logic

enum TimelineScrub {
    static let dayMinutes = 1440
    /// The shortest an event is drawn, in minutes, so a brief session can still be seen and pressed.
    static let minDrawn = 12
    /// A drag or a tap lands on 5-minute marks (or inside a short event it's over).
    static let snap = 5
    /// VoiceOver steps an hour at a time.
    static let voiceOverStep = 60

    /// "07:05"; 1440 is "24:00", the end of the day.
    static func clock(_ minute: Int) -> String { String(format: "%02d:%02d", minute / 60, minute % 60) }
    /// "07:00", the start of an hour (24 is the end of the day).
    static func hourClock(_ hour: Int) -> String { String(format: "%02d:00", hour) }
    /// "07:00–08:00", the hour starting at `hour`.
    static func hourRange(_ hour: Int) -> String { "\(hourClock(hour))–\(hourClock(hour + 1))" }

    /// How far the marker goes: the whole day for a past day; up to now for today, but never short of the last
    /// hour with readings (the phone's clock and the person's saved time zone can disagree).
    static func scrubMax(isToday: Bool, nowMinute: Int, asOf: Int?) -> Int {
        guard isToday else { return dayMinutes }
        return min(dayMinutes, max(nowMinute, (asOf ?? 0) * 60))
    }

    /// The next stop `step` minutes away on a grid of `step` (so 14:32 goes back to 14:00, then 13:00), within 0…upper.
    static func stepMinute(_ minute: Int, step: Int, forward: Bool, upper: Int) -> Int {
        let next = forward ? (minute / step) * step + step : ((minute + step - 1) / step) * step - step
        return min(upper, max(0, next))
    }

    /// The phone's minute of `day` at `date`; 1440 once the phone's date has moved past it (until the summary catches up).
    static func nowMinute(_ date: Date, day: String) -> Int {
        if Day.of(date) > day { return dayMinutes }
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    // MARK: Events

    /// An event's minutes on `date`: as recorded (from–to, clipped to the day, so a night that began the evening
    /// before starts at 0) and as drawn (at least `minDrawn` wide).
    struct Span: Equatable {
        let from: Int
        let to: Int
        let drawnTo: Int
    }

    static func span(_ e: TimelineEvent, date: String) -> Span {
        let from = e.start.prefix(10) < date ? 0 : Fmt.minutesOfDay(e.start)
        let to = e.end.prefix(10) > date ? dayMinutes : Fmt.minutesOfDay(e.end)
        return Span(from: from, to: to, drawnTo: max(to, from + minDrawn))
    }

    /// The minute a press at `raw` minutes picks: inside an event, that exact minute (so a short one isn't rounded
    /// past); on the part of a short event drawn beyond its end, its last real minute (so pressing what you see
    /// shows it); anywhere else, the nearest `snap` minutes.
    static func pressMinute(_ events: [TimelineEvent], date: String, raw: Double, snap: Int) -> Int {
        let m = Int(raw.rounded(.down))
        let spans = events.map { span($0, date: date) }
        if spans.contains(where: { m >= $0.from && m < $0.to }) { return m }
        if let drawn = spans.first(where: { $0.to > $0.from && m >= $0.to && m < $0.drawnTo }) { return drawn.to - 1 }
        return Int((raw / Double(snap)).rounded()) * snap
    }

    /// The events going on at a minute of `date`, by their recorded wall-clock start and end (not as drawn).
    static func events(at minute: Int, in events: [TimelineEvent], date: String) -> [TimelineEvent] {
        let t = "\(date)T\(clock(min(minute, dayMinutes - 1)))"
        return events.filter { $0.start.prefix(16) <= t && t < $0.end.prefix(16) }
    }

    /// What the person was doing at the marker: asleep, napping, or the workout or session's own name.
    static func doing(_ e: TimelineEvent) -> String {
        switch e.kind {
        case "sleep": "Asleep"
        case "nap": "Napping"
        default: e.title
        }
    }

    // MARK: Hours (src/charts/day.ts)

    /// The last hour with readings to count: a past day is complete (23); today stops at the latest synced hour.
    static func drawThrough(date: String, today: String, asOf: Int?) -> Int? {
        guard let asOf else { return nil }
        return date < today ? 23 : min(max(asOf, 0), 23)
    }

    /// Running total by the end of each hour, through `through`. Hours without readings add nothing; later hours are nil.
    static func cumulative(_ hours: [Double?], through: Int?) -> [Double?] {
        var sum = 0.0
        return hours.enumerated().map { h, v in
            guard let through, h <= through else { return nil }
            sum += v ?? 0
            return sum
        }
    }

    /// The latest hour, at or before `through`, with a reading.
    static func lastReading(_ hours: [Double?], through: Int?) -> Int? {
        guard let through, !hours.isEmpty else { return nil }
        for h in stride(from: min(through, hours.count - 1), through: 0, by: -1) where hours[h] != nil { return h }
        return nil
    }

    // MARK: Moment

    /// Heart rate in the hour holding the marker.
    enum Heart: Equatable {
        /// `partial`: today's last synced hour, which may still be filling up.
        case reading(hour: Int, avg: Double, low: Double?, high: Double?, typical: Double?, partial: Bool)
        /// No reading in that hour.
        case missing(hour: Int)
        /// Today, after the last hour the phone has sent.
        case pending(hour: Int)
        /// No reading at all that day (so far, for today).
        case empty
    }

    /// A summed metric (steps, active energy) up to the marker.
    enum Total: Equatable {
        /// The running total over whole hours, by `at`:00 (0–24), against the typical total by then.
        case by(at: Int, value: Double, typical: Double?)
        /// Today, with the marker past every synced reading: the total so far, which may end part-way through an
        /// hour, so there's no typical to compare it with.
        case soFar(Double)
        /// Nothing recorded that day (so far, for today).
        case empty
    }

    struct Moment {
        let minute: Int
        let events: [TimelineEvent]
        /// Each is nil when the person has no hourly data of that kind at all (or no hourly data for the day).
        var heart: Heart?
        var steps: Total?
        var energy: Total?

        var hasFigures: Bool { heart != nil || steps != nil || energy != nil }
    }

    /// What a moment of the day looked like. `live` is the resting position: now for today, when heart rate is the
    /// latest reading and the totals are so far; the end of the day for a past day.
    static func moment(day: DayData?, events: [TimelineEvent], date: String, minute: Int, live: Bool) -> Moment {
        var m = Moment(minute: minute, events: self.events(at: minute, in: events, date: date))
        guard let day, day.date == date else { return m }
        let isToday = day.date == day.today
        let asOf = day.asOf.map { min(max($0, 0), 23) }
        let through = drawThrough(date: day.date, today: day.today, asOf: asOf)
        if let hr = day.heartRate { m.heart = heart(hr, through: through, isToday: isToday, asOf: asOf, minute: minute, live: live) }
        if let s = day.steps { m.steps = total(s, through: through, isToday: isToday, asOf: asOf, minute: minute, live: live) }
        if let e = day.activeEnergy { m.energy = total(e, through: through, isToday: isToday, asOf: asOf, minute: minute, live: live) }
        return m
    }

    private static func heart(_ hr: DaySeries, through: Int?, isToday: Bool, asOf: Int?, minute: Int, live: Bool) -> Heart {
        let latest = lastReading(hr.hours, through: through)
        // No reading at all also covers a day with nothing synced: lastReading is nil without a cut-off.
        guard let through, latest != nil || !live else { return .empty }
        let hour = live ? (latest ?? 0) : min(23, minute / 60)
        if hour > through { return .pending(hour: hour) }
        guard let avg = hr.hours[hour] else { return .missing(hour: hour) }
        return .reading(hour: hour, avg: avg, low: hr.min.flatMap { $0[hour] }, high: hr.max.flatMap { $0[hour] },
                        typical: hr.typical[hour], partial: isToday && hour == asOf)
    }

    private static func total(_ s: DaySeries, through: Int?, isToday: Bool, asOf: Int?, minute: Int, live: Bool) -> Total {
        // A day where this metric has no hours at all says so, rather than counting up zeros.
        guard let through, s.hours[0...through].contains(where: { $0 != nil }) else { return .empty }
        let run = cumulative(s.hours, through: through)
        // Today's last synced hour may still be filling up; the hours before it are whole.
        let whole = isToday ? (asOf ?? 0) - 1 : 23
        // The hour boundary at or before the marker; live means now (so far) or the end of a past day.
        let at = live ? 24 : min(24, minute / 60)
        if at - 1 > whole { return .soFar(run[through] ?? 0) }
        if at == 0 { return .by(at: 0, value: 0, typical: nil) }
        return .by(at: at, value: run[at - 1] ?? 0, typical: s.typical[at - 1])
    }

    // MARK: Words

    /// Which hour a heart figure is the average of, or why there's none. Today's last synced hour may still be
    /// filling up, so it's the average since the hour began.
    static func heartStatus(_ h: Heart, isToday: Bool) -> String {
        switch h {
        case let .reading(hour, _, _, _, _, partial): partial ? "avg since \(hourClock(hour))" : "avg \(hourRange(hour))"
        case .pending: "not synced yet"
        case let .missing(hour): "none \(hourRange(hour))"
        case .empty: isToday ? "none yet today" : "none that day"
        }
    }

    /// The lines under a total's value: when it's counted to, and the typical total by then.
    static func totalLines(_ t: Total, isToday: Bool) -> [String] {
        switch t {
        case .empty: [isToday ? "none yet today" : "none that day"]
        case .soFar: ["so far today"]
        case let .by(at, _, typical): [at == 24 ? "whole day" : "by \(hourClock(at))"] + (typical.map { ["typical \(Fmt.number($0))"] } ?? [])
        }
    }

    /// The spoken value: the moment, what was going on, and every figure the readout shows, as it labels them.
    static func spoken(_ m: Moment, time: String) -> String {
        var parts = [time, m.events.isEmpty ? "nothing logged" : m.events.map(doing).joined(separator: " and ")]
        switch m.heart {
        case let .reading(hour, avg, low, high, _, partial)?:
            let when = partial ? "since \(hourClock(hour))" : "from \(hourClock(hour)) to \(hourClock(hour + 1))"
            let range = low.flatMap { l in high.map { ", range \(Fmt.number(l)) to \(Fmt.number($0))" } } ?? ""
            parts.append("heart \(Fmt.number(avg)) bpm, average \(when)\(range)")
        case let .missing(hour)?: parts.append("no heart reading from \(hourClock(hour)) to \(hourClock(hour + 1))")
        case .pending?: parts.append("heart rate not synced yet")
        case .empty?, nil: break
        }
        for (t, what, unit) in [(m.steps, "steps", ""), (m.energy, "active energy", " kcal")] {
            switch t {
            case let .soFar(v)?: parts.append("\(what) \(Fmt.number(v))\(unit) so far today")
            case let .by(at, v, typical)?:
                let when = at == 24 ? "for the whole day" : "by \(hourClock(at))"
                parts.append("\(what) \(Fmt.number(v))\(unit) \(when)\(typical.map { ", typical \(Fmt.number($0))" } ?? "")")
            case .empty?, nil: break
            }
        }
        return parts.joined(separator: "; ")
    }

    /// The day's step count, as the Activity card shows it, when the hours don't add up to it: a WHOOP count (its
    /// API has no hours), or hours not all sent yet. Small rounding differences don't count.
    static func stepNote(_ day: DayData?) -> String? {
        guard let st = day?.steps, let total = st.total else { return nil }
        let hourSteps = st.hours.reduce(0) { $0 + ($1 ?? 0) }
        guard total.value > hourSteps * 1.01 + 1 else { return nil }
        return total.source == "whoop"
            ? "Steps by the hour are from your iPhone or Apple Watch. WHOOP counted \(Fmt.number(total.value)) for the day."
            : "The hours here add up to \(Fmt.number(hourSteps)) steps; the day's count is \(Fmt.number(total.value))."
    }

    /// Said when the day has no hourly readings to scrub through (or the server has no Day view): events only.
    static func noHoursNote(isToday: Bool) -> String {
        isToday ? "No hourly readings yet today. Heart rate, steps and energy show here after a sync." : "No hourly readings for this day."
    }

    /// Said when asking for the day's hours failed (offline, a server error) and there's nothing of that day to show.
    static let loadFailedNote = "Hourly readings couldn't load just now. Trying again shortly."

    /// The line under the track. "No hourly readings" only once the server has said so for this day; while asking,
    /// nothing; after a failure, that it couldn't load (never that there's nothing).
    static func note(day: DayData?, answered: Bool, failed: Bool, showsSteps: Bool, isToday: Bool) -> String? {
        guard let day, !day.metrics.isEmpty else {
            if answered { return noHoursNote(isToday: isToday) }
            return failed ? loadFailedNote : nil
        }
        return showsSteps ? stepNote(day) : nil
    }

    /// No sliding under Reduce Motion: the marker and its pill jump (web: `transition: none` under
    /// prefers-reduced-motion).
    static func motion(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }
}

/// What's known of the timeline day's hourly readings (GET /api/day).
struct DayLoad {
    /// The server's last answer: a day's readings, or nil for none (or no Day view).
    private(set) var day: DayData?
    /// The day that answer was for.
    private(set) var answeredDate: String?
    /// A day whose latest request failed (offline, a server error).
    private(set) var failedDate: String?

    /// Only that day's readings; another day's never stand in.
    func hours(for date: String) -> DayData? { day?.date == date ? day : nil }
    /// The server has said what `date` has, so an empty answer can be called empty. False on the first frame of a
    /// new day, before it's been asked.
    func answered(_ date: String) -> Bool { answeredDate == date }
    func failed(_ date: String) -> Bool { failedDate == date }

    mutating func received(_ fetched: DayData?, for date: String) {
        day = fetched
        answeredDate = date
        failedDate = nil
    }

    /// Keeps the readings already on screen for the same day (they're real, if not the newest).
    mutating func failed(for date: String) {
        failedDate = date
    }
}

/// While Today's path is moved off live, the portrait's heart shows that hour's average heart rate instead of the
/// resting rate, with its hour as its words (web HeartScrub in src/components/Figure.tsx and figureStatus in
/// src/pages/Home.tsx). It has no level: levels are for resting rates.
struct HeartScrub: Equatable {
    /// The timeline's day; the portrait shows it only when that's the day it shows.
    let date: String
    /// nil: no reading in that hour.
    let bpm: Double?
    /// One short line: "Avg 07:00–08:00", "Avg since 14:00", "Not synced yet", "No reading then", "No readings".
    let label: String
    /// The same for VoiceOver, without the abbreviation.
    let spoken: String

    /// nil while live, or without hourly heart rate that day.
    static func from(_ moment: TimelineScrub.Moment, live: Bool, date: String) -> HeartScrub? {
        guard !live, let heart = moment.heart else { return nil }
        typealias S = TimelineScrub
        switch heart {
        case let .reading(hour, avg, _, _, _, partial):
            return partial
                ? HeartScrub(date: date, bpm: avg, label: "Avg since \(S.hourClock(hour))", spoken: "average since \(S.hourClock(hour))")
                : HeartScrub(date: date, bpm: avg, label: "Avg \(S.hourRange(hour))", spoken: "average from \(S.hourClock(hour)) to \(S.hourClock(hour + 1))")
        case .pending: return HeartScrub(date: date, bpm: nil, label: "Not synced yet", spoken: "not synced yet")
        case .missing: return HeartScrub(date: date, bpm: nil, label: "No reading then", spoken: "no reading then")
        case .empty: return HeartScrub(date: date, bpm: nil, label: "No readings", spoken: "no readings")
        }
    }
}

/// Where Today's path has its marker, and what the heart reads there, shared through Today (web Home.tsx: the
/// timeline card's scrub, and the heartScrub it hands the figure). Today owns it; the path moves the marker and
/// says what the hour's heart rate is, and the portrait shows that, but only on its own day.
@MainActor @Observable
final class TodayScrub {
    /// The minute the marker was moved to, and the day it was moved on; nil is live.
    private var held: (date: String, minute: Int)?
    /// That hour's heart while the marker is off live and the path is on screen; nil otherwise.
    private(set) var heart: HeartScrub?

    /// The marker's minute on `date`; nil (live) when it was moved on another day, so a new day starts live.
    func minute(on date: String) -> Int? {
        guard let held, held.date == date else { return nil }
        return held.minute
    }

    /// Moves the marker on `date`; nil goes back to live.
    func move(to minute: Int?, on date: String) {
        held = minute.map { (date, $0) }
    }

    /// The path now shows `date`. A marker left on another day goes back to live, and the heart with it, so
    /// coming back to that day starts at now again (the web keys its timeline card by day).
    func show(_ date: String) {
        guard let held, held.date != date else { return }
        self.held = nil
        set(nil)
    }

    /// The heart at the path's moment (`HeartScrub.from`): that hour's while off live, nil at live or without
    /// hourly heart rate.
    func follow(_ heart: HeartScrub?) { set(heart) }

    /// The path left the screen (its card hidden, another tab, a pushed page): back to the resting rate. The marker
    /// keeps its place, and `follow` brings the heart back when the path returns.
    func hide() { set(nil) }

    /// What the portrait of `date` shows for the heart: the scrubbed hour only when the path is on that same day.
    func heart(on date: String) -> HeartScrub? {
        guard let heart, heart.date == date else { return nil }
        return heart
    }

    /// Only a real change reaches the portrait, so a drag within one hour doesn't redraw it.
    private func set(_ next: HeartScrub?) {
        if next != heart { heart = next }
    }
}

// MARK: - View

/// The readout and the 24-hour track with its marker. Horizontal drags scrub and spring back to live on release
/// (as a stock chart does); vertical drags scroll the page; a tap holds that moment until "Now", and a double tap
/// goes back to it. VoiceOver adjusts it an hour at a time.
struct TimelineScrubber: View {
    let events: [TimelineEvent]
    let date: String
    let isToday: Bool
    /// The day's hourly readings when they're for `date`; nil otherwise.
    let day: DayData?
    /// The server has answered for `date`, so "no hourly readings" isn't said while they load.
    let answered: Bool
    /// Asking for `date`'s readings failed.
    let failed: Bool
    /// The end of the track, which is also where live sits.
    let upper: Int
    let moment: TimelineScrub.Moment
    /// The minute the marker was moved to; nil is live.
    @Binding var scrub: Int?
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragging = false
    @State private var pillWidth: CGFloat = 40
    @State private var drag = DragState()

    private static let trackTop: CGFloat = 30
    private static let trackHeight: CGFloat = 14
    private static let height: CGFloat = 68

    private var live: Bool { scrub == nil }
    private var liveName: String { isToday ? "Now" : "End of day" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            readout
                .accessibilityHidden(true) // the track speaks all of it, as its value
            track
            if let note = notes { Text(note).font(.app(.caption)).foregroundStyle(Palette.ink3).fixedSize(horizontal: false, vertical: true) }
        }
    }

    private var notes: String? {
        TimelineScrub.note(day: day, answered: answered, failed: failed, showsSteps: moment.steps != nil, isToday: isToday)
    }

    // MARK: Readout

    private var readout: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(live ? liveName : TimelineScrub.clock(moment.minute))
                    .font(.app(.title2, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .fixedSize()
                // One line, so the track below never moves while the marker does.
                HStack(spacing: 10) {
                    if moment.events.isEmpty {
                        Text("Nothing logged").foregroundStyle(Palette.ink3)
                    }
                    ForEach(moment.events) { e in
                        HStack(spacing: 5) {
                            Circle().fill(TimelineCard.color(e.kind)).frame(width: 8, height: 8)
                            Text(TimelineScrub.doing(e)).foregroundStyle(Palette.ink)
                            Text("\(Fmt.clock(e.start))–\(Fmt.clock(e.end))").font(.app(.caption)).monospacedDigit().foregroundStyle(Palette.ink3)
                        }
                    }
                }
                .font(.app(.footnote, weight: .medium))
                .lineLimit(1)
            }
            if moment.hasFigures {
                let tiles = Group {
                    if let h = moment.heart { heartTile(h) }
                    if let s = moment.steps { totalTile("Steps", unit: "", s) }
                    if let e = moment.energy { totalTile("Active energy", unit: "kcal", e) }
                }
                if typeSize >= .xxLarge {
                    VStack(spacing: 8) { tiles }
                } else {
                    HStack(alignment: .top, spacing: 8) { tiles }
                }
            }
        }
    }

    private func heartTile(_ h: TimelineScrub.Heart) -> some View {
        var value: String?
        var lines = [TimelineScrub.heartStatus(h, isToday: isToday)]
        if case let .reading(_, avg, low, high, _, _) = h {
            value = Fmt.number(avg)
            if let low, let high { lines.append("range \(Fmt.number(low))–\(Fmt.number(high))") }
        }
        return ScrubStatTile(name: "Heart rate", value: value, unit: "bpm", lines: lines)
    }

    private func totalTile(_ name: String, unit: String, _ t: TimelineScrub.Total) -> some View {
        let value: String? = switch t {
        case .empty: nil
        case let .soFar(v): Fmt.number(v)
        case let .by(_, v, _): Fmt.number(v)
        }
        return ScrubStatTile(name: name, value: value, unit: unit, lines: TimelineScrub.totalLines(t, isToday: isToday))
    }

    // MARK: Track

    private var track: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width)
            let x = { (m: Int) in CGFloat(m) / CGFloat(TimelineScrub.dayMinutes) * w }
            let minute = moment.minute
            ZStack(alignment: .topLeading) {
                Capsule().fill(Palette.surface2)
                    .overlay(Capsule().strokeBorder(Palette.border))
                    .frame(width: w, height: Self.trackHeight)
                    .offset(y: Self.trackTop)
                ForEach(events) { e in
                    let s = TimelineScrub.span(e, date: date)
                    Capsule().fill(TimelineCard.color(e.kind))
                        .frame(width: max(6, x(s.drawnTo - s.from) - 2), height: Self.trackHeight - 4)
                        .offset(x: x(s.from), y: Self.trackTop + 2)
                }
                // Where now is, while the marker is elsewhere.
                if isToday && !live {
                    Path { p in
                        p.move(to: CGPoint(x: x(upper), y: Self.trackTop - 6))
                        p.addLine(to: CGPoint(x: x(upper), y: Self.trackTop + Self.trackHeight + 2))
                    }
                    .stroke(Palette.ink3, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                Rectangle().fill(Palette.ink)
                    .frame(width: 1.5, height: Self.trackTop + Self.trackHeight - 16)
                    .offset(x: x(minute) - 0.75, y: 18)
                // The pill slides from left-aligned at 00:00 to right-aligned at 24:00, so it never leaves the card.
                Text(TimelineScrub.clock(minute))
                    .font(.app(.caption2, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(Palette.surface)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Palette.ink, in: Capsule())
                    .shadow(color: .black.opacity(live ? 0 : 0.2), radius: 4, y: 2)
                    .fixedSize()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pillWidth = $0 }
                    .offset(x: x(minute) - pillWidth * CGFloat(minute) / CGFloat(TimelineScrub.dayMinutes))
                ticks(w)
                    .offset(y: Self.trackTop + Self.trackHeight + 6)
            }
            .frame(width: w, height: Self.height, alignment: .topLeading)
            .animation(dragging ? nil : TimelineScrub.motion(.easeOut(duration: 0.25), reduceMotion: reduceMotion), value: minute)
            .overlay {
                ScrubSurface(
                    began: { start, now in begin(start: start, x: now, width: w) },
                    moved: { follow($0, width: w) },
                    ended: { end() },
                    tapped: { tap($0, width: w) },
                    doubleTapped: { toLive() }
                )
            }
        }
        .frame(height: Self.height)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isToday ? "Today's timeline" : "The day's timeline")
        .accessibilityValue(TimelineScrub.spoken(moment, time: live ? liveName : TimelineScrub.clock(moment.minute)))
        .accessibilityHint("Swipe up or down to move through the day by the hour.")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: nudge(forward: true)
            case .decrement: nudge(forward: false)
            @unknown default: break
            }
        }
        // Activating does nothing, as clicking the web slider's handle doesn't move it. Without its own action,
        // VoiceOver's double tap would become a real tap at the track's centre and hold the moment there.
        .accessibilityAction(.default) {}
        .accessibilityAction(named: Text(liveName)) { toLive() }
    }

    private func ticks(_ w: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach([0, 6, 12, 18, 24], id: \.self) { h in
                Text(TimelineScrub.hourClock(h))
                    .font(.app(.caption2)).monospacedDigit().foregroundStyle(Palette.ink3)
                    .fixedSize()
                    .frame(width: w, alignment: h == 0 ? .leading : h == 24 ? .trailing : .center)
                    .offset(x: h == 0 || h == 24 ? 0 : w * (CGFloat(h) / 24 - 0.5))
            }
        }
        .frame(width: w, alignment: .leading)
        .accessibilityHidden(true)
    }

    // MARK: Moving the marker

    /// Moving to the end (now, or the end of the day) is going live. Returns where the marker now is.
    @discardableResult
    private func go(_ m: Int) -> Int {
        scrub = m >= upper ? nil : max(0, m)
        return min(upper, max(0, m))
    }

    private func nudge(forward: Bool) {
        go(TimelineScrub.stepMinute(moment.minute, step: TimelineScrub.voiceOverStep, forward: forward, upper: upper))
    }

    private func toLive() {
        withAnimation(TimelineScrub.motion(.easeOut(duration: 0.25), reduceMotion: reduceMotion)) { scrub = nil }
    }

    /// Grabbing the marker's pill moves it from where it is; a drag that starts elsewhere jumps it there.
    private func begin(start: CGFloat, x: CGFloat, width: CGFloat) {
        let marker = CGFloat(moment.minute) / CGFloat(TimelineScrub.dayMinutes) * width
        drag.grab = abs(start - marker) <= 24 ? (start, moment.minute) : nil
        drag.hour = moment.minute / 60
        drag.haptics.prepare()
        dragging = true
        follow(x, width: width)
    }

    private func follow(_ x: CGFloat, width: CGFloat) {
        let perPoint = Double(TimelineScrub.dayMinutes) / Double(width)
        let to: Int
        if let grab = drag.grab {
            let snaps = (Double(x - grab.start) * perPoint / Double(TimelineScrub.snap)).rounded()
            to = go(grab.minute + Int(snaps) * TimelineScrub.snap)
        } else {
            to = go(TimelineScrub.pressMinute(events, date: date, raw: Double(x) * perPoint, snap: TimelineScrub.snap))
        }
        tick(to)
    }

    /// A drag springs back to live on release; what it showed was a look, not a choice.
    private func end() {
        dragging = false
        drag.grab = nil
        withAnimation(TimelineScrub.motion(.spring(duration: 0.35), reduceMotion: reduceMotion)) { scrub = nil }
    }

    /// A tap holds the moment it picks, until "Now". A tap on the marker itself leaves it where it is.
    private func tap(_ x: CGFloat, width: CGFloat) {
        let marker = CGFloat(moment.minute) / CGFloat(TimelineScrub.dayMinutes) * width
        guard abs(x - marker) > 24 else { return }
        drag.hour = moment.minute / 60
        let to = withAnimation(TimelineScrub.motion(.easeOut(duration: 0.25), reduceMotion: reduceMotion)) {
            go(TimelineScrub.pressMinute(events, date: date, raw: Double(x) * Double(TimelineScrub.dayMinutes) / Double(width), snap: TimelineScrub.snap))
        }
        tick(to)
    }

    /// A selection tick each time the marker crosses into another hour.
    private func tick(_ minute: Int) {
        let hour = minute / 60
        guard hour != drag.hour else { return }
        drag.hour = hour
        drag.haptics.selectionChanged()
        drag.haptics.prepare()
    }

    /// The press in progress; a reference, so a drag's bookkeeping doesn't redraw the view.
    private final class DragState {
        /// Where a press on the pill began and the minute the marker was at then.
        var grab: (start: CGFloat, minute: Int)?
        /// The hour the marker was last in, for the haptic tick.
        var hour = 0
        let haptics = UISelectionFeedbackGenerator()
    }
}

/// One figure at the marker: its name, value, and up to two short lines saying what it covers. Always four rows
/// tall, so the readout keeps its height as the marker moves.
private struct ScrubStatTile: View {
    let name: String
    let value: String?
    let unit: String
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(name).font(.app(.caption)).foregroundStyle(Palette.ink2).lineLimit(1).minimumScaleFactor(0.8)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value ?? "—")
                    .font(.app(.headline)).monospacedDigit()
                    .foregroundStyle(value == nil ? Palette.ink3 : Palette.ink)
                if value != nil, !unit.isEmpty {
                    Text(unit).font(.app(.caption2, weight: .medium)).foregroundStyle(Palette.ink3)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.vertical, 1)
            ForEach(0..<2, id: \.self) { i in
                Text(i < lines.count ? lines[i] : " ")
                    .font(.app(.caption2)).monospacedDigit().foregroundStyle(Palette.ink3)
                    .lineLimit(1).minimumScaleFactor(0.75)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface2, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.border))
    }
}

/// The track's touch surface. A UIKit pan that only begins on a sideways move, so a vertical drag that starts on
/// the track still scrolls the page (SwiftUI drag gestures inside a ScrollView behave differently across iOS
/// versions); taps and double taps beside it.
private struct ScrubSurface: UIViewRepresentable {
    /// Where the press began and where it is now, in the surface's points.
    var began: (_ start: CGFloat, _ x: CGFloat) -> Void
    var moved: (CGFloat) -> Void
    var ended: () -> Void
    var tapped: (CGFloat) -> Void
    var doubleTapped: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true
        let c = context.coordinator
        let pan = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.pan(_:)))
        pan.delegate = c
        pan.maximumNumberOfTouches = 1
        let double = UITapGestureRecognizer(target: c, action: #selector(Coordinator.doubleTap(_:)))
        double.numberOfTapsRequired = 2
        let single = UITapGestureRecognizer(target: c, action: #selector(Coordinator.tap(_:)))
        single.require(toFail: double)
        [pan, double, single].forEach(view.addGestureRecognizer)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.surface = self
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var surface: ScrubSurface

        init(_ surface: ScrubSurface) { self.surface = surface }

        @objc func pan(_ g: UIPanGestureRecognizer) {
            guard let view = g.view else { return }
            let x = g.location(in: view).x
            switch g.state {
            case .began: surface.began(x - g.translation(in: view).x, x)
            case .changed: surface.moved(x)
            case .ended, .cancelled, .failed: surface.ended()
            default: break
            }
        }

        /// With VoiceOver on, a tap here can only be one VoiceOver made up for an activation (at the track's centre),
        /// never a choice of moment: the track's own adjustable and named actions move the marker instead.
        @objc func tap(_ g: UITapGestureRecognizer) {
            guard let view = g.view, !UIAccessibility.isVoiceOverRunning else { return }
            surface.tapped(g.location(in: view).x)
        }

        @objc func doubleTap(_ g: UITapGestureRecognizer) {
            guard !UIAccessibility.isVoiceOverRunning else { return }
            surface.doubleTapped()
        }

        /// Sideways scrubs; up and down is the page's scroll. By the time a pan asks, it has moved past its slop, so
        /// the distance says which way (a slow drag can have no velocity yet).
        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard let pan = g as? UIPanGestureRecognizer else { return true }
            let t = pan.translation(in: pan.view)
            if t != .zero { return abs(t.x) > abs(t.y) }
            let v = pan.velocity(in: pan.view)
            return abs(v.x) > abs(v.y)
        }

        /// The page's scroll waits for the scrub pan to decide, so a sideways drag is never taken as a scroll; an
        /// up-or-down one fails the scrub at once and scrolls as usual.
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            g is UIPanGestureRecognizer && other is UIPanGestureRecognizer && other.view is UIScrollView
        }
    }
}
