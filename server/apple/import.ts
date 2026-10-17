import fs from 'node:fs';
import { createHash } from 'node:crypto';
import { Readable } from 'node:stream';
import { SaxesParser, type SaxesTagPlain } from 'saxes';
import yauzl from 'yauzl';
import { type DailyRow, type EventRow, type HourlyRow, type Scope, type WorkoutRow, deleteSource, getUserSetting, setUserSetting, upsertDaily, upsertEvents, upsertHourly, upsertWorkouts } from '../db.ts';
import { DAY_ROLLOVER_MS, localDate, localHour, parseAppleDate, toLocalIso, type Stamp, zoneOffsets } from '../dates.ts';

export const SOURCE = 'apple';

type Agg = 'sum' | 'avg' | 'last';
type Quantity = { metric: string; agg: Agg; convert?: (value: number, unit: string) => number };

const toKcal = (v: number, unit: string) => (unit === 'kJ' ? v / 4.184 : v);
const toPercent = (v: number) => (v <= 1.5 ? v * 100 : v);
const toCelsius = (v: number, unit: string) => (unit === 'degF' ? ((v - 32) * 5) / 9 : v);
const toKg = (v: number, unit: string) => (unit === 'lb' ? v * 0.45359237 : unit === 'g' ? v / 1000 : v);
const toKm = (v: number, unit: string) => (unit === 'mi' ? v * 1.609344 : unit === 'm' ? v / 1000 : v);

const QUANTITIES: Record<string, Quantity> = {
  HKQuantityTypeIdentifierStepCount: { metric: 'steps', agg: 'sum' },
  HKQuantityTypeIdentifierActiveEnergyBurned: { metric: 'active_energy', agg: 'sum', convert: toKcal },
  HKQuantityTypeIdentifierAppleExerciseTime: { metric: 'exercise_min', agg: 'sum' },
  HKQuantityTypeIdentifierDistanceWalkingRunning: { metric: 'distance_km', agg: 'sum', convert: toKm },
  HKQuantityTypeIdentifierHeartRate: { metric: 'hr_avg', agg: 'avg' },
  HKQuantityTypeIdentifierRestingHeartRate: { metric: 'resting_hr', agg: 'avg' },
  HKQuantityTypeIdentifierHeartRateVariabilitySDNN: { metric: 'hrv_sdnn', agg: 'avg' },
  // Newer Apple Watch software also records RMSSD. Kept apart from WHOOP's nightly RMSSD: the Watch's
  // short-window readings run far lower (about 6 ms vs 14 ms on the same day), so they don't share a line.
  HKQuantityTypeIdentifierHeartRateVariabilityRMSSD: { metric: 'hrv_rmssd_watch', agg: 'avg' },
  HKQuantityTypeIdentifierOxygenSaturation: { metric: 'spo2', agg: 'avg', convert: toPercent },
  HKQuantityTypeIdentifierRespiratoryRate: { metric: 'resp_rate', agg: 'avg' },
  HKQuantityTypeIdentifierAppleSleepingWristTemperature: { metric: 'wrist_temp', agg: 'avg', convert: toCelsius },
  HKQuantityTypeIdentifierBodyTemperature: { metric: 'body_temp', agg: 'avg', convert: toCelsius },
  HKQuantityTypeIdentifierBodyMass: { metric: 'weight', agg: 'last', convert: toKg },
  HKQuantityTypeIdentifierBodyFatPercentage: { metric: 'body_fat', agg: 'last', convert: toPercent },
  HKQuantityTypeIdentifierLeanBodyMass: { metric: 'lean_mass', agg: 'last', convert: toKg },
  HKQuantityTypeIdentifierVO2Max: { metric: 'vo2max', agg: 'last' },
};

type Stage = 'in_bed' | 'awake' | 'unspecified' | 'light' | 'rem' | 'deep';

const SLEEP_STAGE: Record<string, Stage> = {
  HKCategoryValueSleepAnalysisInBed: 'in_bed',
  HKCategoryValueSleepAnalysisAsleep: 'unspecified',
  HKCategoryValueSleepAnalysisAsleepUnspecified: 'unspecified',
  HKCategoryValueSleepAnalysisAsleepCore: 'light',
  HKCategoryValueSleepAnalysisAsleepDeep: 'deep',
  HKCategoryValueSleepAnalysisAsleepREM: 'rem',
  HKCategoryValueSleepAnalysisAwake: 'awake',
};

// Where segments from one source overlap, the most specific stage wins and asleep beats awake.
const STAGE_PRIORITY: Stage[] = ['deep', 'rem', 'light', 'unspecified', 'awake'];
// Longer than any real night: such records are app bugs, not sleep.
const MAX_SEGMENT_MS = 20 * 3_600_000;

type SleepSegment = { start: Stamp; end: Stamp; stage: Stage };
type SleepNight = { light: number; deep: number; rem: number; awake: number; in_bed: number; start?: Stamp; end?: Stamp };

/**
 * Minutes per stage for one source's night, counting overlapping time once. Sleep apps
 * (SleepWatch, Oura, Clock) often write the same night several times or in overlapping pieces.
 */
export function resolveNight(segments: SleepSegment[]): SleepNight {
  const night: SleepNight = { light: 0, deep: 0, rem: 0, awake: 0, in_bed: 0 };
  const sweep = (segs: SleepSegment[], onSpan: (minutes: number, active: Map<Stage, number>) => void) => {
    const edges = segs.flatMap((s) => [
      { t: s.start.ms, stage: s.stage, d: 1 },
      { t: s.end.ms, stage: s.stage, d: -1 },
    ]);
    edges.sort((a, b) => a.t - b.t || a.d - b.d);
    const active = new Map<Stage, number>();
    for (let i = 0; i < edges.length; i++) {
      const e = edges[i];
      active.set(e.stage, (active.get(e.stage) ?? 0) + e.d);
      const next = edges[i + 1];
      if (next && next.t > e.t) onSpan((next.t - e.t) / 60_000, active);
    }
  };

  sweep(
    segments.filter((s) => s.stage === 'in_bed'),
    (min, active) => {
      if ((active.get('in_bed') ?? 0) > 0) night.in_bed += min;
    },
  );
  sweep(
    segments.filter((s) => s.stage !== 'in_bed'),
    (min, active) => {
      const stage = STAGE_PRIORITY.find((st) => (active.get(st) ?? 0) > 0);
      if (!stage) return;
      night[stage === 'unspecified' ? 'light' : stage] += min;
    },
  );

  for (const s of segments) {
    if (s.stage === 'awake' || s.stage === 'in_bed') continue;
    if (!night.start || s.start.ms < night.start.ms) night.start = s.start;
    if (!night.end || s.end.ms > night.end.ms) night.end = s.end;
  }
  if (!night.start) {
    for (const s of segments) {
      if (!night.start || s.start.ms < night.start.ms) night.start = s.start;
      if (!night.end || s.end.ms > night.end.ms) night.end = s.end;
    }
  }
  return night;
}

/**
 * Apps whose data healthOS reads from their own API. Their copies in Apple Health are skipped,
 * or they would count twice (WHOOP writes sleep, heart rate, SpO2 and workouts into Health).
 */
export function fromDirectSource(sourceName: string | undefined) {
  return /^whoop\b/i.test((sourceName ?? '').trim());
}

export type ImportProgress = { bytesRead: number; totalBytes: number; records: number };
export type ImportResult = {
  records: number;
  /** Records skipped as another app's copy of data read directly (WHOOP). */
  skipped: number;
  days: number;
  workouts: number;
  firstDate: string | null;
  lastDate: string | null;
};

/** Metrics also kept hour by hour, for the Day view. */
const HOURLY_SUMS = new Set(['steps', 'active_energy']);

/** Accumulates Apple Health records into per-day values. Kept separate from I/O so tests can drive it. */
export class AppleAggregator {
  /**
   * With the person's time zone, hourly buckets use the local hour the zone had at each instant. Apple's
   * export prints every timestamp with one fixed offset, so for half the year its own wall clock is an
   * hour off. Days keep the export's own dates, as before.
   */
  constructor(opts: { timeZone?: string | null } = {}) {
    if (opts.timeZone) {
      try {
        this.offsetAt = zoneOffsets(opts.timeZone);
      } catch {
        // Unknown zone name: use the export's own offsets.
      }
    }
  }
  private offsetAt?: (ms: number) => number;
  records = 0;
  /** Records skipped because they're another app's copy of data read directly (see fromDirectSource). */
  skipped = 0;
  // sum metrics: date -> metric -> source -> total. Different devices (iPhone and
  // Watch) both log steps for the same walk, so per day we keep the best single source.
  private sums = new Map<string, Map<string, Map<string, number>>>();
  private avgs = new Map<string, { sum: number; n: number }>();
  private hrRange = new Map<string, { min: number; max: number }>();
  private lasts = new Map<string, { ms: number; value: number }>();
  // hourly sums: date|metric -> source -> hour -> total, so each day can keep its best single source, as days do.
  private hourSums = new Map<string, Map<string, Map<number, number>>>();
  // hourly heart rate: date|hour -> running average, low and high.
  private hourHr = new Map<string, { sum: number; n: number; min: number; max: number }>();
  // sleep: wake-date -> source -> segments. The source with the most sleep wins the night.
  private sleep = new Map<string, Map<string, SleepSegment[]>>();
  private mindful: EventRow[] = [];
  private workouts: WorkoutRow[] = [];
  private openWorkout: { attrs: Record<string, string>; stats: Record<string, string>[] } | null = null;

  onOpenTag(tag: SaxesTagPlain) {
    const a = tag.attributes as Record<string, string>;
    if ((tag.name === 'Record' || tag.name === 'Workout') && fromDirectSource(a.sourceName)) {
      this.records += tag.name === 'Record' ? 1 : 0;
      this.skipped++;
      return;
    }
    if (tag.name === 'Record') this.record(a);
    else if (tag.name === 'Workout') this.openWorkout = { attrs: a, stats: [] };
    else if (tag.name === 'WorkoutStatistics' && this.openWorkout) this.openWorkout.stats.push(a);
  }

  onCloseTag(tag: SaxesTagPlain) {
    if (tag.name === 'Workout' && this.openWorkout) {
      const w = buildWorkout(this.openWorkout.attrs, this.openWorkout.stats);
      if (w) this.workouts.push(w);
      this.openWorkout = null;
    }
  }

  private record(a: Record<string, string>) {
    this.records++;
    const type = a.type;
    if (type === 'HKCategoryTypeIdentifierSleepAnalysis') return this.sleepRecord(a);
    if (type === 'HKCategoryTypeIdentifierMindfulSession') return this.mindfulRecord(a);

    const q = QUANTITIES[type];
    if (!q || !a.startDate || a.value === undefined) return;
    const raw = Number(a.value);
    if (!Number.isFinite(raw)) return;
    const value = q.convert ? q.convert(raw, a.unit ?? '') : raw;
    const start = parseAppleDate(a.startDate);
    const date = localDate(start);
    const source = a.sourceName ?? 'unknown';

    if (HOURLY_SUMS.has(q.metric) || q.metric === 'hr_avg') {
      const local = this.offsetAt ? { ms: start.ms, offsetMin: this.offsetAt(start.ms) } : start;
      const hDate = localDate(local);
      const hour = localHour(local);
      if (q.metric === 'hr_avg') {
        const k = `${hDate}|${hour}`;
        const cur = this.hourHr.get(k);
        if (cur) {
          cur.sum += value;
          cur.n++;
          cur.min = Math.min(cur.min, value);
          cur.max = Math.max(cur.max, value);
        } else this.hourHr.set(k, { sum: value, n: 1, min: value, max: value });
      } else {
        const bySource = getOr(this.hourSums, `${hDate}|${q.metric}`, () => new Map());
        const byHour = getOr(bySource, source, () => new Map());
        byHour.set(hour, (byHour.get(hour) ?? 0) + value);
      }
    }

    if (q.agg === 'sum') {
      const byMetric = getOr(this.sums, date, () => new Map());
      const bySource = getOr(byMetric, q.metric, () => new Map());
      bySource.set(source, (bySource.get(source) ?? 0) + value);
    } else if (q.agg === 'avg') {
      const k = `${date}|${q.metric}`;
      const cur = getOr(this.avgs, k, () => ({ sum: 0, n: 0 }));
      cur.sum += value;
      cur.n++;
      if (q.metric === 'hr_avg') {
        const r = getOr(this.hrRange, date, () => ({ min: value, max: value }));
        r.min = Math.min(r.min, value);
        r.max = Math.max(r.max, value);
      }
    } else {
      const k = `${date}|${q.metric}`;
      const cur = this.lasts.get(k);
      if (!cur || start.ms >= cur.ms) this.lasts.set(k, { ms: start.ms, value });
    }
  }

  private sleepRecord(a: Record<string, string>) {
    const stage = SLEEP_STAGE[a.value];
    if (!stage || !a.startDate || !a.endDate) return;
    const start = parseAppleDate(a.startDate);
    const end = parseAppleDate(a.endDate);
    const span = end.ms - start.ms;
    if (span <= 0 || span > MAX_SEGMENT_MS) return;
    getOr(getOr(this.sleep, localDate(end, DAY_ROLLOVER_MS), () => new Map()), a.sourceName ?? 'unknown', () => []).push({ start, end, stage });
  }

  private mindfulRecord(a: Record<string, string>) {
    if (!a.startDate || !a.endDate) return;
    const start = parseAppleDate(a.startDate);
    const end = parseAppleDate(a.endDate);
    this.mindful.push({
      id: hashId(SOURCE, 'mindful', a.sourceName ?? '', a.startDate),
      source: SOURCE,
      kind: 'mindful',
      title: 'Mindfulness',
      start: toLocalIso(start),
      end: toLocalIso(end),
      date: localDate(start),
    });
  }

  finish(): { daily: DailyRow[]; hourly: HourlyRow[]; workouts: WorkoutRow[]; events: EventRow[] } {
    const daily: DailyRow[] = [];
    const push = (date: string, metric: string, value: number) => daily.push({ date, metric, source: SOURCE, value });

    for (const [date, byMetric] of this.sums) {
      for (const [metric, bySource] of byMetric) push(date, metric, Math.max(...bySource.values()));
    }
    for (const [k, { sum, n }] of this.avgs) {
      const [date, metric] = k.split('|');
      push(date, metric, sum / n);
    }
    for (const [date, r] of this.hrRange) {
      push(date, 'hr_min', r.min);
      push(date, 'hr_max', r.max);
    }
    for (const [k, { value }] of this.lasts) {
      const [date, metric] = k.split('|');
      push(date, metric, value);
    }

    const hourly: HourlyRow[] = [];
    for (const [k, bySource] of this.hourSums) {
      const [date, metric] = k.split('|');
      // iPhone and Watch both log the same walk: keep the source with the most for the day, as days do.
      let best: Map<number, number> | undefined;
      let bestTotal = -Infinity;
      for (const byHour of bySource.values()) {
        const total = [...byHour.values()].reduce((a, b) => a + b, 0);
        if (total > bestTotal) [best, bestTotal] = [byHour, total];
      }
      for (const [hour, value] of best ?? []) hourly.push({ date, hour, metric, source: SOURCE, value });
    }
    for (const [k, { sum, n, min, max }] of this.hourHr) {
      const [date, h] = k.split('|');
      const hour = Number(h);
      hourly.push(
        { date, hour, metric: 'hr_avg', source: SOURCE, value: sum / n },
        { date, hour, metric: 'hr_min', source: SOURCE, value: min },
        { date, hour, metric: 'hr_max', source: SOURCE, value: max },
      );
    }

    const events: EventRow[] = [...this.mindful];
    for (const [date, bySource] of this.sleep) {
      let best: SleepNight | undefined;
      let bestSource = '';
      for (const [source, segments] of bySource) {
        const night = resolveNight(segments);
        const asleep = night.light + night.deep + night.rem;
        if (!best || asleep > best.light + best.deep + best.rem) {
          best = night;
          bestSource = source;
        }
      }
      if (!best) continue;
      const asleep = best.light + best.deep + best.rem;
      // Older watches and phone-only tracking log only "in bed" or "asleep"; keep whatever exists.
      const hours = (asleep || best.in_bed) / 60;
      if (hours <= 0) continue;
      push(date, 'sleep_hours', hours);
      if (best.in_bed) push(date, 'sleep_in_bed', best.in_bed / 60);
      const staged = best.deep + best.rem > 0;
      if (staged) {
        push(date, 'sleep_deep', best.deep / 60);
        push(date, 'sleep_rem', best.rem / 60);
        push(date, 'sleep_light', best.light / 60);
        push(date, 'sleep_awake', best.awake / 60);
      }
      if (best.start && best.end) {
        events.push({
          id: hashId(SOURCE, 'sleep', bestSource, date),
          source: SOURCE,
          kind: 'sleep',
          title: 'Sleep',
          start: toLocalIso(best.start),
          end: toLocalIso(best.end),
          date,
        });
      }
    }
    return { daily, hourly, workouts: this.workouts, events };
  }
}

function buildWorkout(a: Record<string, string>, stats: Record<string, string>[]): WorkoutRow | null {
  if (!a.startDate || !a.endDate) return null;
  const start = parseAppleDate(a.startDate);
  const end = parseAppleDate(a.endDate);
  const stat = (suffix: string) => stats.find((s) => s.type?.endsWith(suffix));

  let durationMin = Number(a.duration);
  if (a.durationUnit === 'sec' || a.durationUnit === 's') durationMin /= 60;
  if (a.durationUnit === 'hr' || a.durationUnit === 'h') durationMin *= 60;
  if (!Number.isFinite(durationMin) || durationMin <= 0) durationMin = (end.ms - start.ms) / 60_000;

  const energyStat = stat('ActiveEnergyBurned');
  let energy: number | null = null;
  if (energyStat?.sum) energy = toKcal(Number(energyStat.sum), energyStat.unit ?? '');
  else if (a.totalEnergyBurned) energy = toKcal(Number(a.totalEnergyBurned), a.totalEnergyBurnedUnit ?? '');

  const distStat = stats.find((s) => s.type?.includes('Distance') && s.sum);
  let distanceM: number | null = null;
  if (distStat) distanceM = toKm(Number(distStat.sum), distStat.unit ?? '') * 1000;
  else if (a.totalDistance) distanceM = toKm(Number(a.totalDistance), a.totalDistanceUnit ?? '') * 1000;

  const hr = stat('HeartRate');
  return {
    id: hashId(SOURCE, 'workout', a.sourceName ?? '', a.startDate, a.workoutActivityType ?? ''),
    source: SOURCE,
    sport: sportName(a.workoutActivityType ?? ''),
    start: toLocalIso(start),
    end: toLocalIso(end),
    date: localDate(start),
    duration_min: durationMin,
    energy_kcal: energy && Number.isFinite(energy) ? energy : null,
    distance_m: distanceM && Number.isFinite(distanceM) && distanceM > 0 ? distanceM : null,
    avg_hr: hr?.average ? Number(hr.average) : null,
    max_hr: hr?.maximum ? Number(hr.maximum) : null,
    strain: null,
  };
}

export function sportName(type: string): string {
  const name = type.replace(/^HKWorkoutActivityType/, '');
  if (!name) return 'Workout';
  return name.replace(/([a-z])([A-Z])/g, '$1 $2').replace(/([A-Z]+)([A-Z][a-z])/g, '$1 $2');
}

function hashId(...parts: string[]) {
  return createHash('sha1').update(parts.join('|')).digest('hex').slice(0, 20);
}

function getOr<K, V>(map: Map<K, V>, key: K, make: () => V): V {
  let v = map.get(key);
  if (v === undefined) {
    v = make();
    map.set(key, v);
  }
  return v;
}

/** Stream-parse export.xml text. Never loads the whole file: real exports run to several GB. */
export async function parseStream(
  stream: Readable,
  onChunk?: (bytes: number, records: number) => void,
  opts: { timeZone?: string | null } = {},
): Promise<AppleAggregator> {
  const agg = new AppleAggregator(opts);
  const parser = new SaxesParser({ xmlns: false });
  parser.on('opentag', (t) => agg.onOpenTag(t as SaxesTagPlain));
  parser.on('closetag', (t) => agg.onCloseTag(t as SaxesTagPlain));
  let parseError: Error | undefined;
  parser.on('error', (e) => {
    parseError ??= e;
  });

  for await (const chunk of stream) {
    const buf = chunk as Buffer;
    parser.write(buf.toString('utf8'));
    if (parseError) throw parseError;
    onChunk?.(buf.length, agg.records);
  }
  parser.close();
  if (parseError) throw parseError;
  return agg;
}

/** Splits a byte stream into utf8 text without breaking multi-byte characters at chunk edges. */
async function* utf8Safe(stream: Readable): AsyncGenerator<Buffer> {
  let carry: Buffer = Buffer.alloc(0);
  for await (const chunk of stream) {
    let buf = carry.length ? Buffer.concat([carry, chunk as Buffer]) : (chunk as Buffer);
    let cut = buf.length;
    // Walk back over a trailing partial UTF-8 sequence.
    let i = buf.length - 1;
    let back = 0;
    while (i >= 0 && back < 4 && (buf[i] & 0xc0) === 0x80) {
      i--;
      back++;
    }
    if (i >= 0) {
      const lead = buf[i];
      const need = lead >= 0xf0 ? 4 : lead >= 0xe0 ? 3 : lead >= 0xc0 ? 2 : 1;
      if (need > back + 1) cut = i;
    }
    carry = buf.subarray(cut);
    buf = buf.subarray(0, cut);
    if (buf.length) yield buf;
  }
  if (carry.length) yield carry;
}

async function openExportXml(file: string): Promise<{ stream: Readable; totalBytes: number }> {
  const fd = await fs.promises.open(file, 'r');
  const magic = Buffer.alloc(2);
  await fd.read(magic, 0, 2, 0);
  await fd.close();
  if (magic.toString() !== 'PK') {
    return { stream: fs.createReadStream(file, { highWaterMark: 1 << 20 }), totalBytes: (await fs.promises.stat(file)).size };
  }

  return new Promise((resolve, reject) => {
    yauzl.open(file, { lazyEntries: true }, (err, zip) => {
      if (err || !zip) return reject(err ?? new Error('Could not open zip'));
      zip.on('entry', (entry: yauzl.Entry) => {
        // The archive also holds export_cda.xml (a clinical copy) and workout routes; only export.xml is wanted.
        if (/(^|\/)export\.xml$/.test(entry.fileName)) {
          zip.openReadStream(entry, (e, stream) => {
            if (e || !stream) return reject(e ?? new Error('Could not read export.xml'));
            resolve({ stream, totalBytes: entry.uncompressedSize });
          });
        } else zip.readEntry();
      });
      zip.on('end', () => reject(new Error('No export.xml found in this zip. Is it the file from Health → Export All Health Data?')));
      zip.readEntry();
    });
  });
}

/** Import an Apple Health export.zip or export.xml, replacing any earlier Apple Health import. */
export async function importAppleHealth(scope: Scope, file: string, onProgress?: (p: ImportProgress) => void): Promise<ImportResult> {
  const { db, userId } = scope;
  const { stream, totalBytes } = await openExportXml(file);
  // The zone the dashboard reported for this person, for historical local hours (see AppleAggregator).
  const timeZone = await getUserSetting(db, userId, 'timezone');
  let bytesRead = 0;
  const agg = await parseStream(
    Readable.from(utf8Safe(stream)),
    (bytes, records) => {
      bytesRead += bytes;
      onProgress?.({ bytesRead, totalBytes, records });
    },
    { timeZone },
  );
  const { daily, hourly, workouts, events } = agg.finish();

  await db.tx(async (q) => {
    await deleteSource(q, userId, SOURCE);
    await upsertDaily(q, userId, daily);
    await upsertHourly(q, userId, hourly);
    await upsertWorkouts(q, userId, workouts);
    await upsertEvents(q, userId, events);
  });

  const dates = [...new Set(daily.map((d) => d.date))].sort();
  const result: ImportResult = {
    records: agg.records,
    skipped: agg.skipped,
    days: dates.length,
    workouts: workouts.length,
    firstDate: dates[0] ?? null,
    lastDate: dates.at(-1) ?? null,
  };
  await setUserSetting(db, userId, 'apple_last_import', JSON.stringify({ ...result, importedAt: new Date().toISOString() }));
  return result;
}

