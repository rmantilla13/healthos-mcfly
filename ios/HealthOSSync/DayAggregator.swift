import CryptoKit
import Foundation
import HealthKit

// Row shapes of POST /api/apple/ingest (DailyRow, WorkoutRow, EventRow in server/db.ts).

struct DailyRow: Codable, Equatable {
    var date: String
    var metric: String
    var source = "apple"
    var value: Double
}

struct WorkoutRow: Codable, Equatable {
    var id: String
    var source = "apple"
    var sport: String
    var start: String
    var end: String
    var date: String
    var duration_min: Double
    var energy_kcal: Double?
    var distance_m: Double?
    var avg_hr: Double?
    var max_hr: Double?
    var strain: Double?
}

struct EventRow: Codable, Equatable {
    var id: String
    var source = "apple"
    var kind: String
    var title: String
    var start: String
    var end: String
    var date: String
}

/// One clock hour of one metric (POST /api/apple/ingest `hourly`). Days and hours are the phone's local time.
struct HourlyRow: Codable, Equatable {
    var date: String
    var hour: Int
    var metric: String
    var value: Double
}

/// One stretch of a night (POST /api/apple/ingest `sleepStages`): in_bed, awake, asleep, light, rem or deep.
struct SleepStageRow: Codable, Equatable {
    var start: String
    var end: String
    var stage: String
}

/// A night's whole timeline by wake date; the server replaces the night with it, and an empty one clears it.
struct SleepStageNight: Codable, Equatable {
    var date: String
    var segments: [SleepStageRow]
}

struct IngestPayload: Codable {
    var daily: [DailyRow] = []
    /// Every hour with data for each (date, metric) sent: the server replaces that day's hours for the metric.
    var hourly: [HourlyRow]?
    /// Days with cycle records, each that day's complete set.
    var cycle: [CycleDay]?
    var workouts: [WorkoutRow] = []
    var events: [EventRow] = []
    var deleted: Deleted?
    /// The stages through each night sent, for the Sleep page. Only when the window had any sleep at all, so a phone
    /// without access to sleep never clears nights an export import stored.
    var sleepStages: [SleepStageNight]?

    /// Workouts and mindful sessions sent earlier that were since deleted in Health.
    struct Deleted: Codable {
        var workouts: [String]
        var events: [String]
    }

    var rowCount: Int { daily.count + workouts.count + events.count }
}

/// One quantity sample as the aggregation sees it.
struct QuantityPoint {
    let start: Stamp
    let value: Double
    let source: SampleSource
    /// When the sample ended: a `byWakeDay` metric counts toward this morning.
    var end: Stamp? = nil
}

struct SleepSegment {
    let start: Stamp
    let end: Stamp
    let stage: SleepStage
}

/// One sleep sample as the aggregation sees it (kept free of HealthKit so tests can set the source).
struct SleepRecord {
    let start: Stamp
    let end: Stamp
    let stage: SleepStage
    let source: SampleSource
}

/// One Watch stand-hour record as the aggregation sees it.
struct StandRecord {
    let start: Stamp
    let stood: Bool
    let source: SampleSource
}

struct SleepNight {
    var light = 0.0, deep = 0.0, rem = 0.0, awake = 0.0, inBed = 0.0 // minutes
    var start: Stamp?
    var end: Stamp?
    var asleep: Double { light + deep + rem }
}

/// Turns HealthKit samples into complete per-day rows for a set of local dates, using the same
/// rules as AppleAggregator in server/apple/import.ts. Samples outside `dates` are ignored, so the
/// caller can over-fetch a padded window.
final class DayAggregator {
    let dates: Set<String>

    // date -> metric -> source -> total. iPhone and Watch both count the same walk, so a day keeps the best single source.
    private var sums: [String: [String: [String: Double]]] = [:]
    // date -> metric -> source -> hour -> total, for the Day view. A day sends the hours of the source that
    // won its daily total, so the hours add up to the daily row (the export importer does the same).
    private var hourlySums: [String: [String: [String: [Int: Double]]]] = [:]
    private var averages: [String: (sum: Double, n: Int)] = [:] // "date|metric"
    private var hrRange: [String: (min: Double, max: Double)] = [:]
    // "date|hour" -> heart rate that hour, over every non-WHOOP source.
    private var hourlyHR: [String: (sum: Double, n: Int, min: Double, max: Double)] = [:]
    private var lasts: [String: (at: Date, value: Double)] = [:] // "date|metric"
    // "date|metric" -> total over every source: a coffee logged in one app and another in a second app both count.
    private var totals: [String: Double] = [:]
    // date -> local hours stood. Two watches can log the same hour; it counts once.
    private var standHours: [String: Set<Int>] = [:]
    // wake date -> source -> segments. The source with the most sleep wins the night.
    private var sleep: [String: [String: [SleepSegment]]] = [:]
    /// Any sleep sample (not WHOOP's copy) was read for these dates, so a date without one has no night.
    private var sawSleep = false
    private var mindful: [EventRow] = []
    /// WHOOP wrote steps into Health for these days (it does only when Health → Apps → WHOOP → Steps is allowed).
    private(set) var sawWhoopSteps = false
    private var workouts: [WorkoutRow] = []

    /// Hourly metrics the server accepts that come from summing samples.
    static let hourlySumMetrics: Set<String> = ["steps", "active_energy"]

    // Longer than any real night: such records are app bugs, not sleep.
    static let maxSegment: TimeInterval = 20 * 3600
    // Where segments from one source overlap, the most specific stage wins and asleep beats awake.
    static let stagePriority: [SleepStage] = [.deep, .rem, .light, .unspecified, .awake]

    init(dates: Set<String>) {
        self.dates = dates
    }

    func add(_ samples: [HKQuantitySample], as q: QuantityMetric) {
        add(points: samples.map { QuantityPoint(start: $0.startStamp, value: $0.quantity.doubleValue(for: q.unit) * q.scale, source: $0.writtenBy, end: $0.endStamp) }, as: q)
    }

    /// The aggregation itself, kept free of HealthKit so tests can set the source.
    func add(points: [QuantityPoint], as q: QuantityMetric) {
        for p in points where p.source.counts(q.metric) {
            if p.source.isReadDirectly { sawWhoopSteps = true }
            let value = p.value
            guard value.isFinite else { continue }
            let date = q.byWakeDay ? (p.end ?? p.start).localDate(shift: Day.rollover) : p.start.localDate()
            guard dates.contains(date) else { continue }
            let hour = p.start.localHour
            let key = "\(date)|\(q.metric)"
            switch q.aggregation {
            case .sum:
                sums[date, default: [:]][q.metric, default: [:]][p.source.name, default: 0] += value
                if Self.hourlySumMetrics.contains(q.metric) {
                    hourlySums[date, default: [:]][q.metric, default: [:]][p.source.name, default: [:]][hour, default: 0] += value
                }
            case .sumAll:
                totals[key, default: 0] += value
            case .avg:
                averages[key, default: (0, 0)].sum += value
                averages[key, default: (0, 0)].n += 1
                if q.metric == "hr_avg" {
                    let r = hrRange[date] ?? (value, value)
                    hrRange[date] = (Swift.min(r.min, value), Swift.max(r.max, value))
                    let hk = "\(date)|\(hour)"
                    let h = hourlyHR[hk] ?? (0, 0, value, value)
                    hourlyHR[hk] = (h.sum + value, h.n + 1, Swift.min(h.min, value), Swift.max(h.max, value))
                }
            case .last:
                if let cur = lasts[key], p.start.date < cur.at { continue }
                lasts[key] = (p.start.date, value)
            }
        }
    }

    /// The source whose total counts for the day: the largest, ties broken by name so it's stable.
    private static func winner(_ bySource: [String: Double]) -> (source: String, total: Double)? {
        bySource.max { a, b in a.value != b.value ? a.value < b.value : a.key > b.key }.map { ($0.key, $0.value) }
    }

    /// Hour rows for the Day view: steps and active energy from each day's winning source, heart rate over all sources.
    var hourlyRows: [HourlyRow] {
        var rows: [HourlyRow] = []
        for (date, byMetric) in hourlySums {
            for (metric, bySource) in byMetric {
                guard let win = Self.winner(sums[date]?[metric] ?? [:]), let hours = bySource[win.source] else { continue }
                rows += hours.map { HourlyRow(date: date, hour: $0.key, metric: metric, value: $0.value) }
            }
        }
        for (key, h) in hourlyHR {
            let parts = key.split(separator: "|")
            let (date, hour) = (String(parts[0]), Int(parts[1])!)
            rows += [
                HourlyRow(date: date, hour: hour, metric: "hr_avg", value: h.sum / Double(h.n)),
                HourlyRow(date: date, hour: hour, metric: "hr_min", value: h.min),
                HourlyRow(date: date, hour: hour, metric: "hr_max", value: h.max),
            ]
        }
        return rows.sorted { ($0.date, $0.metric, $0.hour) < ($1.date, $1.metric, $1.hour) }
    }

    func add(sleep samples: [HKCategorySample]) {
        add(sleepRecords: samples.compactMap { s in
            SleepStage(s.value).map { SleepRecord(start: s.startStamp, end: s.endStamp, stage: $0, source: s.writtenBy) }
        })
    }

    func add(sleepRecords records: [SleepRecord]) {
        for r in records where !r.source.isReadDirectly {
            let span = r.end.date.timeIntervalSince(r.start.date)
            guard span > 0, span <= Self.maxSegment else { continue }
            let date = r.end.localDate(shift: Day.rollover)
            guard dates.contains(date) else { continue }
            sawSleep = true
            sleep[date, default: [:]][r.source.name, default: []].append(SleepSegment(start: r.start, end: r.end, stage: r.stage))
        }
    }

    func add(mindful samples: [HKCategorySample]) {
        for s in samples where !s.writtenBy.isReadDirectly {
            let start = s.startStamp
            let date = start.localDate()
            guard dates.contains(date) else { continue }
            mindful.append(EventRow(
                id: "hk-" + s.uuid.uuidString.lowercased(),
                kind: "mindful", title: "Mindfulness", start: start.localIso, end: s.endStamp.localIso, date: date))
        }
    }

    func add(standHours samples: [HKCategorySample]) {
        add(standRecords: samples.map {
            StandRecord(start: $0.startStamp, stood: $0.value == HKCategoryValueAppleStandHour.stood.rawValue, source: $0.writtenBy)
        })
    }

    /// Hours stood, dated by start like the quantities (server/apple/import.ts `standRecord`).
    func add(standRecords records: [StandRecord]) {
        for r in records where r.stood && !r.source.isReadDirectly {
            let date = r.start.localDate()
            guard dates.contains(date) else { continue }
            standHours[date, default: []].insert(r.start.localHour)
        }
    }

    func add(workouts list: [HKWorkout]) {
        let distanceTypes: [HKQuantityTypeIdentifier] = [.distanceWalkingRunning, .distanceCycling, .distanceSwimming, .distanceWheelchair, .distanceDownhillSnowSports]
        for w in list where !w.writtenBy.isReadDirectly {
            let start = w.startStamp
            let date = start.localDate()
            guard dates.contains(date) else { continue }
            let name = WorkoutNames.name(w.workoutActivityType)

            var duration = w.duration / 60
            if !(duration > 0) { duration = w.endDate.timeIntervalSince(w.startDate) / 60 }
            let energy = w.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie())
                ?? w.totalEnergyBurned?.doubleValue(for: .kilocalorie())
            let distance = distanceTypes.lazy.compactMap { w.statistics(for: HKQuantityType($0))?.sumQuantity()?.doubleValue(for: .meter()) }.first
                ?? w.totalDistance?.doubleValue(for: .meter())
            let hr = w.statistics(for: HKQuantityType(.heartRate))

            workouts.append(WorkoutRow(
                // Stable across syncs. The server replaces the same workout from an earlier export.zip import.
                id: "hk-" + w.uuid.uuidString.lowercased(),
                sport: WorkoutNames.sport(name),
                start: start.localIso,
                end: w.endStamp.localIso,
                date: date,
                duration_min: duration,
                energy_kcal: energy.flatMap { $0.isFinite && $0 > 0 ? $0 : nil },
                distance_m: distance.flatMap { $0.isFinite && $0 > 0 ? $0 : nil },
                avg_hr: hr?.averageQuantity()?.doubleValue(for: HealthTypes.bpm),
                max_hr: hr?.maximumQuantity()?.doubleValue(for: HealthTypes.bpm),
                strain: nil))
        }
    }

    func finish() -> IngestPayload {
        var p = IngestPayload()
        func push(_ date: String, _ metric: String, _ value: Double) { p.daily.append(DailyRow(date: date, metric: metric, value: value)) }
        func split(_ key: String) -> (String, String) {
            let parts = key.split(separator: "|", maxSplits: 1)
            return (String(parts[0]), String(parts[1]))
        }

        for (date, byMetric) in sums {
            for (metric, bySource) in byMetric { if let win = Self.winner(bySource) { push(date, metric, win.total) } }
        }
        for (key, a) in averages {
            let (date, metric) = split(key)
            push(date, metric, a.sum / Double(a.n))
        }
        for (date, r) in hrRange {
            push(date, "hr_min", r.min)
            push(date, "hr_max", r.max)
        }
        for (key, l) in lasts {
            let (date, metric) = split(key)
            push(date, metric, l.value)
        }
        for (key, total) in totals {
            let (date, metric) = split(key)
            push(date, metric, total)
        }
        for (date, hours) in standHours { push(date, "stand_hours", Double(hours.count)) }

        p.events = mindful
        var stages: [String: [SleepStageRow]] = [:]
        for (date, bySource) in sleep {
            var best: SleepNight?
            var bestSource = ""
            for (source, segments) in bySource.sorted(by: { $0.key < $1.key }) {
                let night = Self.resolveNight(segments)
                if best == nil || night.asleep > best!.asleep {
                    best = night
                    bestSource = source
                }
            }
            guard let night = best else { continue }
            // The night's stages from the same source as its totals, so the chart and the figures agree.
            stages[date] = Self.nightTimeline(bySource[bestSource] ?? []).map {
                SleepStageRow(start: $0.start.localIso, end: $0.end.localIso, stage: $0.stage.name)
            }
            // Older watches and phone-only tracking log only "in bed" or "asleep"; keep whatever exists.
            let hours = (night.asleep > 0 ? night.asleep : night.inBed) / 60
            guard hours > 0 else { continue }
            push(date, "sleep_hours", hours)
            if night.inBed > 0 { push(date, "sleep_in_bed", night.inBed / 60) }
            if night.deep + night.rem > 0 {
                push(date, "sleep_deep", night.deep / 60)
                push(date, "sleep_rem", night.rem / 60)
                push(date, "sleep_light", night.light / 60)
                push(date, "sleep_awake", night.awake / 60)
            }
            if let start = night.start, let end = night.end {
                p.events.append(EventRow(
                    id: hashId("apple", "sleep", bestSource, date),
                    kind: "sleep", title: "Sleep", start: start.localIso, end: end.localIso, date: date))
            }
        }
        if sawSleep {
            p.sleepStages = dates.sorted().map { SleepStageNight(date: $0, segments: stages[$0] ?? []) }
        }
        p.workouts = workouts
        let hourly = hourlyRows
        p.hourly = hourly.isEmpty ? nil : hourly
        return p
    }

    /// Minutes per stage for one source's night, counting overlapping time once. Port of
    /// `resolveNight` in server/apple/import.ts: sleep apps often write the same night several
    /// times or in overlapping pieces.
    static func resolveNight(_ segments: [SleepSegment]) -> SleepNight {
        var night = SleepNight()

        func sweep(_ segs: [SleepSegment], _ onSpan: (Double, [SleepStage: Int]) -> Void) {
            var edges = segs.flatMap { [(t: $0.start.date, stage: $0.stage, d: 1), (t: $0.end.date, stage: $0.stage, d: -1)] }
            edges.sort { $0.t != $1.t ? $0.t < $1.t : $0.d < $1.d }
            var active: [SleepStage: Int] = [:]
            for i in edges.indices {
                let e = edges[i]
                active[e.stage, default: 0] += e.d
                if i + 1 < edges.count, edges[i + 1].t > e.t { onSpan(edges[i + 1].t.timeIntervalSince(e.t) / 60, active) }
            }
        }

        sweep(segments.filter { $0.stage == .inBed }) { minutes, active in
            if (active[.inBed] ?? 0) > 0 { night.inBed += minutes }
        }
        sweep(segments.filter { $0.stage != .inBed }) { minutes, active in
            guard let stage = stagePriority.first(where: { (active[$0] ?? 0) > 0 }) else { return }
            switch stage {
            case .deep: night.deep += minutes
            case .rem: night.rem += minutes
            case .light, .unspecified: night.light += minutes
            case .awake: night.awake += minutes
            case .inBed: break
            }
        }

        // A same-day nap's minutes count, as WHOOP's do, but the night's start and end are its main sleep's.
        if let main = mainSleep(segments.filter { $0.stage != .inBed }) {
            night.start = main.start
            night.end = main.end
        } else {
            for s in segments {
                if night.start == nil || s.start.date < night.start!.date { night.start = s.start }
                if night.end == nil || s.end.date > night.end!.date { night.end = s.end }
            }
        }
        return night
    }

    /// A stretch of the drawn night.
    struct Stretch {
        var start: Stamp
        var end: Stamp
        var stage: SleepStage
    }

    /// Time in bed shows only where nothing else was recorded: the lead-in before falling asleep, and lying awake after.
    static let timelinePriority: [SleepStage] = stagePriority + [.inBed]
    /// Shorter stretches fold into their neighbour: they can't be seen, and rounding leaves them behind.
    static let minStretch: TimeInterval = 60

    /// One source's night as a timeline: one stage at each moment (the priority `resolveNight` counts by), only the
    /// main sleep and the time in bed just before it (a same-day nap is left out, though its minutes count in the
    /// totals), with neighbouring stretches of the same stage joined. Never overlapping. Port of `nightTimeline` in
    /// server/apple/import.ts.
    static func nightTimeline(_ segments: [SleepSegment]) -> [Stretch] {
        var edges = segments.flatMap { [(t: $0.start, stage: $0.stage, d: 1), (t: $0.end, stage: $0.stage, d: -1)] }
        edges.sort { $0.t.date != $1.t.date ? $0.t.date < $1.t.date : $0.d < $1.d }
        var active: [SleepStage: Int] = [:]
        var spans: [Stretch] = []
        for i in edges.indices {
            let e = edges[i]
            active[e.stage, default: 0] += e.d
            guard i + 1 < edges.count, edges[i + 1].t.date > e.t.date,
                  let stage = timelinePriority.first(where: { (active[$0] ?? 0) > 0 }) else { continue }
            let next = edges[i + 1].t
            if let last = spans.last, last.stage == stage, last.end.date == e.t.date {
                spans[spans.count - 1].end = next
            } else {
                spans.append(Stretch(start: e.t, end: next, stage: stage))
            }
        }

        // The main sleep's run: stretches with gaps of up to `sleepGap` between them.
        var runs: [[Stretch]] = []
        for sp in spans {
            if let last = runs.last?.last, sp.start.date.timeIntervalSince(last.end.date) <= sleepGap {
                runs[runs.count - 1].append(sp)
            } else {
                runs.append([sp])
            }
        }
        func asleep(_ run: [Stretch]) -> TimeInterval {
            run.reduce(0) { $0 + ($1.stage == .inBed || $1.stage == .awake ? 0 : $1.end.date.timeIntervalSince($1.start.date)) }
        }
        let main = mainSleep(segments.filter { $0.stage != .inBed })
        let chosen = main.flatMap { m in runs.first { $0.first!.start.date <= m.start.date && m.start.date < $0.last!.end.date } }
            ?? runs.reduce([Stretch]()) { asleep($1) > asleep($0) ? $1 : $0 }

        // Slivers join the stretch before them (the first one, the stretch after), then like stages join up again.
        var out: [Stretch] = []
        for sp in chosen {
            let touching = out.last.map { $0.end.date == sp.start.date } ?? false
            if touching, out.last!.stage == sp.stage || sp.end.date.timeIntervalSince(sp.start.date) < minStretch {
                out[out.count - 1].end = sp.end
            } else if touching, out.last!.end.date.timeIntervalSince(out.last!.start.date) < minStretch {
                // Only a stretch after a gap can still be a sliver here; this one takes it over.
                out[out.count - 1].end = sp.end
                out[out.count - 1].stage = sp.stage
            } else {
                out.append(sp)
            }
        }
        return out.filter { $0.end.date.timeIntervalSince($0.start.date) >= minStretch }
    }

    /// Gaps longer than this split a source's segments into separate sleeps (server SLEEP_GAP_MS).
    static let sleepGap: TimeInterval = 2 * 3600

    /// The longest run of segments with gaps of at most `sleepGap`, from its first asleep moment to its last.
    /// Port of `mainSleep` in server/apple/import.ts.
    static func mainSleep(_ segments: [SleepSegment]) -> (start: Stamp, end: Stamp)? {
        var best: (start: Stamp, end: Stamp)?
        var reach: Date?, start: Stamp?, end: Stamp?
        func keep() {
            if let start, let end, best.map({ end.date.timeIntervalSince(start.date) > $0.end.date.timeIntervalSince($0.start.date) }) ?? true {
                best = (start, end)
            }
        }
        for s in segments.sorted(by: { $0.start.date < $1.start.date }) {
            if let r = reach, s.start.date.timeIntervalSince(r) > sleepGap {
                keep()
                reach = nil; start = nil; end = nil
            }
            reach = max(reach ?? s.end.date, s.end.date)
            if s.stage == .awake { continue }
            if start == nil { start = s.start }
            if end == nil || s.end.date > end!.date { end = s.end }
        }
        keep()
        return best
    }
}

/// sha1 of the parts joined with "|", first 20 hex characters (server `hashId`).
func hashId(_ parts: String...) -> String {
    Insecure.SHA1.hash(data: Data(parts.joined(separator: "|").utf8)).map { String(format: "%02x", $0) }.joined().prefix(20).description
}
