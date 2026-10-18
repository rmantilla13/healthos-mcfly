import fs from 'node:fs';
import { createHash } from 'node:crypto';
import { Readable } from 'node:stream';
import { SaxesParser, type SaxesTagPlain } from 'saxes';
import yauzl from 'yauzl';
import { type DailyRow, type EventRow, type HourlyRow, type Scope, type WorkoutRow, deleteSource, getUserSetting, setUserSetting, upsertDaily, upsertEvents, upsertHourly, upsertWorkouts, bumpDataVersion } from '../db.ts';
import { DAY_ROLLOVER_MS, localDate, localHour, parseAppleDate, toLocalIso, type Stamp, zoneOffsets } from '../dates.ts';
import type { CervicalMucus, Flow, Nutrient, OvulationTest } from '../../shared/types.ts';
import { type CycleKind, type CycleRow, upsertCycle } from '../cycle/index.ts';
import { type NutritionRow, upsertNutrition } from '../nutrition.ts';

export const SOURCE = 'apple';

// sum keeps the best single source per day (iPhone and Watch count the same walk); sumAll adds every source,
// for things logged by hand in different apps (a coffee in one, water in another).
type Agg = 'sum' | 'sumAll' | 'avg' | 'last';
/** byWakeDay: a nightly reading that counts toward the morning the night ends, like sleep (and WHOOP's skin temperature). */
type Quantity = { metric: string; agg: Agg; convert?: (value: number, unit: string) => number; byWakeDay?: boolean };

const toKcal = (v: number, unit: string) => (unit === 'kJ' ? v / 4.184 : v);
const toPercent = (v: number) => (v <= 1.5 ? v * 100 : v);
const toCelsius = (v: number, unit: string) => (unit === 'degF' ? ((v - 32) * 5) / 9 : v);
const toKg = (v: number, unit: string) => (unit === 'lb' ? v * 0.45359237 : unit === 'g' ? v / 1000 : v);
const toKm = (v: number, unit: string) => (unit === 'mi' ? v * 1.609344 : unit === 'm' ? v / 1000 : v);
// mmol/L prints with glucose's molar mass, e.g. "mmol<180.1558800000541>/L".
const toMgDl = (v: number, unit: string) => (unit.startsWith('mmol') ? v * 18.0156 : v);
const toKmh = (v: number, unit: string) => (unit === 'mi/hr' ? v * 1.609344 : unit === 'm/s' ? v * 3.6 : v);
const toMg = (v: number, unit: string) => (unit === 'g' ? v * 1000 : v);
const toMl = (v: number, unit: string) =>
  unit === 'L' ? v * 1000 : unit === 'fl_oz_us' ? v * 29.5735295625 : unit === 'fl_oz_imp' ? v * 28.4130625 : v;
const toGrams = (v: number, unit: string) => (unit === 'mg' ? v / 1000 : unit === 'mcg' ? v / 1e6 : unit === 'kg' ? v * 1000 : unit === 'oz' ? v * 28.349523125 : v);

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
  HKQuantityTypeIdentifierAppleSleepingWristTemperature: { metric: 'wrist_temp', agg: 'avg', convert: toCelsius, byWakeDay: true },
  HKQuantityTypeIdentifierBodyTemperature: { metric: 'body_temp', agg: 'avg', convert: toCelsius },
  HKQuantityTypeIdentifierBodyMass: { metric: 'weight', agg: 'last', convert: toKg },
  HKQuantityTypeIdentifierBodyFatPercentage: { metric: 'body_fat', agg: 'last', convert: toPercent },
  HKQuantityTypeIdentifierLeanBodyMass: { metric: 'lean_mass', agg: 'last', convert: toKg },
  HKQuantityTypeIdentifierVO2Max: { metric: 'vo2max', agg: 'last' },
  HKQuantityTypeIdentifierBloodPressureSystolic: { metric: 'blood_pressure_systolic', agg: 'avg' },
  HKQuantityTypeIdentifierBloodPressureDiastolic: { metric: 'blood_pressure_diastolic', agg: 'avg' },
  HKQuantityTypeIdentifierBloodGlucose: { metric: 'glucose', agg: 'avg', convert: toMgDl },
  HKQuantityTypeIdentifierWalkingSpeed: { metric: 'walking_speed', agg: 'avg', convert: toKmh },
  // About one reading a week, so the latest one is the day's.
  HKQuantityTypeIdentifierAppleWalkingSteadiness: { metric: 'walking_steadiness', agg: 'last', convert: toPercent },
  HKQuantityTypeIdentifierWalkingAsymmetryPercentage: { metric: 'walking_asymmetry', agg: 'avg', convert: toPercent },
  HKQuantityTypeIdentifierTimeInDaylight: { metric: 'daylight_min', agg: 'sum' },
  HKQuantityTypeIdentifierFlightsClimbed: { metric: 'flights', agg: 'sum' },
  HKQuantityTypeIdentifierAppleSleepingBreathingDisturbances: { metric: 'breathing_disturbances', agg: 'avg' },
  HKQuantityTypeIdentifierDietaryCaffeine: { metric: 'caffeine_mg', agg: 'sumAll', convert: toMg },
  HKQuantityTypeIdentifierDietaryWater: { metric: 'water_ml', agg: 'sumAll', convert: toMl },
};

/** An hour the Watch counted as stood (Idle is the other value), by name or as the raw value 0. */
const STAND_HOUR = 'HKCategoryTypeIdentifierAppleStandHour';
const stood = (v: string | undefined) => v === 'HKCategoryValueAppleStandHourStood' || v === '0';

/**
 * What food apps log, as daily totals per app (server/nutrition.ts). Kept apart from the daily metrics, and stored
 * only for people who turned nutrition on. Dated by the sample's start, like the daily quantities.
 */
const NUTRITION_TYPES: Record<string, { nutrient: Nutrient; convert?: (value: number, unit: string) => number }> = {
  HKQuantityTypeIdentifierDietaryEnergyConsumed: { nutrient: 'energy_kcal', convert: toKcal },
  HKQuantityTypeIdentifierDietaryProtein: { nutrient: 'protein_g', convert: toGrams },
  HKQuantityTypeIdentifierDietaryCarbohydrates: { nutrient: 'carbs_g', convert: toGrams },
  HKQuantityTypeIdentifierDietaryFatTotal: { nutrient: 'fat_g', convert: toGrams },
  HKQuantityTypeIdentifierDietaryFiber: { nutrient: 'fiber_g', convert: toGrams },
  HKQuantityTypeIdentifierDietarySugar: { nutrient: 'sugar_g', convert: toGrams },
  HKQuantityTypeIdentifierDietaryFatSaturated: { nutrient: 'sat_fat_g', convert: toGrams },
  HKQuantityTypeIdentifierDietarySodium: { nutrient: 'sodium_mg', convert: toMg },
  HKQuantityTypeIdentifierNumberOfAlcoholicBeverages: { nutrient: 'alcohol_drinks' },
};

/**
 * Types that can also sit inside a <Correlation> (a blood pressure reading, a logged food). The export may write
 * the same sample at the top level too; the parser sees both copies, so the second is dropped (see AppleAggregator.twin).
 */
const CORRELATED = new Set([
  'HKQuantityTypeIdentifierBloodPressureSystolic',
  'HKQuantityTypeIdentifierBloodPressureDiastolic',
  'HKQuantityTypeIdentifierDietaryCaffeine',
  'HKQuantityTypeIdentifierDietaryWater',
  // A food app's meal is a Food correlation holding these; its copy at the top level mustn't count twice.
  ...Object.keys(NUTRITION_TYPES),
]);

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
// Longer than this with nothing recorded, asleep or awake, and it's two sleeps (a night and a nap), not one.
const SLEEP_GAP_MS = 2 * 3_600_000;

type SleepSegment = { start: Stamp; end: Stamp; stage: Stage };
type SleepNight = { light: number; deep: number; rem: number; awake: number; in_bed: number; start?: Stamp; end?: Stamp };

/**
 * The main sleep among one source's segments for a date: segments (asleep or awake) with gaps of up to
 * SLEEP_GAP_MS between them are one sleep, and the one that spans longest asleep wins. It starts and ends
 * at its first and last asleep moment. A nap the same app wrote for the same day is a sleep of its own.
 */
function mainSleep(segments: SleepSegment[]): { start: Stamp; end: Stamp } | undefined {
  type Run = { reach: number; start?: Stamp; end?: Stamp };
  let best: { start: Stamp; end: Stamp } | undefined;
  const keep = (run: Run) => {
    if (run.start && run.end && (!best || run.end.ms - run.start.ms > best.end.ms - best.start.ms)) best = { start: run.start, end: run.end };
  };
  let run: Run | undefined;
  for (const s of [...segments].sort((a, b) => a.start.ms - b.start.ms)) {
    if (run && s.start.ms - run.reach > SLEEP_GAP_MS) {
      keep(run);
      run = undefined;
    }
    run ??= { reach: s.end.ms };
    run.reach = Math.max(run.reach, s.end.ms);
    if (s.stage === 'awake') continue;
    run.start ??= s.start;
    if (!run.end || s.end.ms > run.end.ms) run.end = s.end;
  }
  if (run) keep(run);
  return best;
}

/**
 * Minutes per stage for one source's night, counting overlapping time once. Sleep apps
 * (SleepWatch, Oura, Clock) often write the same night several times or in overlapping pieces.
 * A same-day nap's minutes count too, as WHOOP's do, but the night's start and end are its main sleep's.
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

  const main = mainSleep(segments.filter((s) => s.stage !== 'in_bed'));
  if (main) {
    night.start = main.start;
    night.end = main.end;
  } else {
    for (const s of segments) {
      if (!night.start || s.start.ms < night.start.ms) night.start = s.start;
      if (!night.end || s.end.ms > night.end.ms) night.end = s.end;
    }
  }
  return night;
}

// Cycle tracking records (server/cycle.ts), kept apart from the daily metrics. Apple renamed menstrual flow's
// values in iOS 18 (MenstrualFlow* became VaginalBleeding*), so both spellings are read, and so are raw numbers.
const BASAL_TEMP = 'HKQuantityTypeIdentifierBasalBodyTemperature';
const CYCLE_TYPES: Record<string, CycleKind> = {
  HKCategoryTypeIdentifierMenstrualFlow: 'flow',
  HKCategoryTypeIdentifierIntermenstrualBleeding: 'spotting',
  HKCategoryTypeIdentifierOvulationTestResult: 'ovulation_test',
  HKCategoryTypeIdentifierCervicalMucusQuality: 'mucus',
  HKCategoryTypeIdentifierSexualActivity: 'sexual_activity',
};

/** An Apple category value ("HKCategoryValueVaginalBleedingMedium", or its raw number) as one of ours. */
function appleChoice<T extends string>(value: string | undefined, prefixes: string[], names: Record<string, T>, raw: (T | undefined)[]): T | undefined {
  if (!value) return undefined;
  if (/^\d+$/.test(value)) return raw[Number(value)];
  const prefix = prefixes.find((p) => value.startsWith(p));
  return prefix ? names[value.slice(prefix.length)] : undefined;
}

const appleFlow = (v: string | undefined) =>
  appleChoice<Flow>(v, ['HKCategoryValueVaginalBleeding', 'HKCategoryValueMenstrualFlow'], { Unspecified: 'unspecified', Light: 'light', Medium: 'medium', Heavy: 'heavy', None: 'none' }, [
    undefined,
    'unspecified',
    'light',
    'medium',
    'heavy',
    'none',
  ]);
const appleOvulation = (v: string | undefined) =>
  appleChoice<OvulationTest>(
    v,
    ['HKCategoryValueOvulationTestResult'],
    { Negative: 'negative', LuteinizingHormoneSurge: 'lh_surge', Positive: 'lh_surge', Indeterminate: 'indeterminate', EstrogenSurge: 'estrogen_surge' },
    [undefined, 'negative', 'lh_surge', 'indeterminate', 'estrogen_surge'],
  );
const appleMucus = (v: string | undefined) =>
  appleChoice<CervicalMucus>(v, ['HKCategoryValueCervicalMucusQuality'], { Dry: 'dry', Sticky: 'sticky', Creamy: 'creamy', Watery: 'watery', EggWhite: 'egg_white' }, [
    undefined,
    'dry',
    'sticky',
    'creamy',
    'watery',
    'egg_white',
  ]);
const yes = (v: string | undefined) => v === '1' || v?.toLowerCase() === 'true';
const no = (v: string | undefined) => v === '0' || v?.toLowerCase() === 'false';

/**
 * Apps whose data healthOS reads from their own API. Their copies in Apple Health are skipped,
 * or they would count twice (WHOOP writes sleep, heart rate, SpO2 and workouts into Health).
 */
export function fromDirectSource(sourceName: string | undefined) {
  return /^whoop\b/i.test((sourceName ?? '').trim());
}

/**
 * Except steps. A day's steps keep one device's count, never a sum (see the sums below), so WHOOP's steps in
 * Health compete with the iPhone's and the Watch's instead of adding to them, and their hours follow the
 * device that wins the day. For someone who wears WHOOP more than an Apple Watch, that's usually WHOOP.
 */
const KEPT_FROM_DIRECT = new Set(['HKQuantityTypeIdentifierStepCount']);

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
   * With the person's time zone, local times use the offset the zone had at each instant: hourly buckets,
   * cycle days, and the times and dates of sleep, workouts and mindful sessions. Apple's export prints every
   * timestamp with one fixed offset, so for half the year its own wall clock is an hour off. Daily quantities
   * keep the export's own dates, as before.
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
  // sumAll metrics: date|metric -> total across every source.
  private totals = new Map<string, number>();
  // stand hours: date -> local hours stood, by any source.
  private standHours = new Map<string, Set<number>>();
  // Correlated records still waiting for their other copy, by where they were seen (see twin).
  private twins = { nested: new Map<string, number>(), top: new Map<string, number>() };
  private inCorrelation = false;
  // hourly sums: date|metric -> source -> hour -> total, so each day can keep its best single source, as days do.
  private hourSums = new Map<string, Map<string, Map<number, number>>>();
  // hourly heart rate: date|hour -> running average, low and high.
  private hourHr = new Map<string, { sum: number; n: number; min: number; max: number }>();
  // sleep: wake-date -> source -> segments. The source with the most sleep wins the night.
  private sleep = new Map<string, Map<string, SleepSegment[]>>();
  private mindful: EventRow[] = [];
  private workouts: WorkoutRow[] = [];
  private openWorkout: { attrs: Record<string, string>; stats: Record<string, string>[] } | null = null;
  // A cycle record waits for its closing tag: a period's start and protection used are <MetadataEntry> children.
  private openCycle: { attrs: Record<string, string>; meta: Record<string, string> } | null = null;
  private cycle: CycleRow[] = [];
  // Basal temperature: date -> the day's first reading, the one taken on waking.
  private basalTemp = new Map<string, { ms: number; value: number }>();
  // Food: date|nutrient|app -> total. Each app's total is kept; a day shows one app's (see pickDays).
  private nutrition = new Map<string, number>();

  onOpenTag(tag: SaxesTagPlain) {
    const a = tag.attributes as Record<string, string>;
    if ((tag.name === 'Record' || tag.name === 'Workout') && fromDirectSource(a.sourceName) && !(tag.name === 'Record' && KEPT_FROM_DIRECT.has(a.type))) {
      this.records += tag.name === 'Record' ? 1 : 0;
      this.skipped++;
      return;
    }
    if (tag.name === 'Record') this.record(a);
    else if (tag.name === 'Correlation') this.inCorrelation = true;
    else if (tag.name === 'Workout') this.openWorkout = { attrs: a, stats: [] };
    else if (tag.name === 'WorkoutStatistics' && this.openWorkout) this.openWorkout.stats.push(a);
    else if (tag.name === 'MetadataEntry' && this.openCycle && a.key) this.openCycle.meta[a.key] = a.value;
  }

  onCloseTag(tag: SaxesTagPlain) {
    if (tag.name === 'Correlation') this.inCorrelation = false;
    if (tag.name === 'Record' && this.openCycle) {
      this.cycleRecord(this.openCycle.attrs, this.openCycle.meta);
      this.openCycle = null;
    }
    if (tag.name === 'Workout' && this.openWorkout) {
      const w = buildWorkout(this.openWorkout.attrs, this.openWorkout.stats, (st) => this.zoned(st));
      if (w) this.workouts.push(w);
      this.openWorkout = null;
    }
  }

  private record(a: Record<string, string>) {
    this.records++;
    const type = a.type;
    if (CORRELATED.has(type) && this.twin(a)) return;
    if (type === 'HKCategoryTypeIdentifierSleepAnalysis') return this.sleepRecord(a);
    if (type === 'HKCategoryTypeIdentifierMindfulSession') return this.mindfulRecord(a);
    if (Object.hasOwn(CYCLE_TYPES, type)) {
      this.openCycle = { attrs: a, meta: {} };
      return;
    }
    if (type === BASAL_TEMP) return this.basalTempRecord(a);
    if (type === STAND_HOUR) return this.standRecord(a);
    if (Object.hasOwn(NUTRITION_TYPES, type)) return this.nutritionRecord(a, NUTRITION_TYPES[type]);

    const q = QUANTITIES[type];
    if (!q || !a.startDate || a.value === undefined) return;
    const raw = Number(a.value);
    if (!Number.isFinite(raw)) return;
    const value = q.convert ? q.convert(raw, a.unit ?? '') : raw;
    const start = parseAppleDate(a.startDate);
    const date = q.byWakeDay && a.endDate ? localDate(parseAppleDate(a.endDate), DAY_ROLLOVER_MS) : localDate(start);
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
    } else if (q.agg === 'sumAll') {
      const k = `${date}|${q.metric}`;
      this.totals.set(k, (this.totals.get(k) ?? 0) + value);
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

  /**
   * Whether this is the second copy of a correlated sample: the same record nested in a <Correlation> and at
   * the top level, in either order. Identical records on the same side are separate samples and both count.
   */
  private twin(a: Record<string, string>): boolean {
    const key = [a.type, a.sourceName, a.startDate, a.endDate, a.value].join('|');
    const [mine, other] = this.inCorrelation ? [this.twins.nested, this.twins.top] : [this.twins.top, this.twins.nested];
    const waiting = other.get(key) ?? 0;
    if (waiting > 0) {
      if (waiting === 1) other.delete(key);
      else other.set(key, waiting - 1);
      return true;
    }
    mine.set(key, (mine.get(key) ?? 0) + 1);
    return false;
  }

  private standRecord(a: Record<string, string>) {
    if (!stood(a.value) || !a.startDate) return;
    // Dated by start, like the quantities. Two watches can both log the same hour; it counts once.
    const start = parseAppleDate(a.startDate);
    getOr(this.standHours, localDate(start), () => new Set()).add(localHour(start));
  }

  private sleepRecord(a: Record<string, string>) {
    const stage = SLEEP_STAGE[a.value];
    if (!stage || !a.startDate || !a.endDate) return;
    const start = this.zoned(parseAppleDate(a.startDate));
    const end = this.zoned(parseAppleDate(a.endDate));
    const span = end.ms - start.ms;
    if (span <= 0 || span > MAX_SEGMENT_MS) return;
    getOr(getOr(this.sleep, localDate(end, DAY_ROLLOVER_MS), () => new Map()), a.sourceName ?? 'unknown', () => []).push({ start, end, stage });
  }

  private mindfulRecord(a: Record<string, string>) {
    if (!a.startDate || !a.endDate) return;
    const start = this.zoned(parseAppleDate(a.startDate));
    const end = this.zoned(parseAppleDate(a.endDate));
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

  /**
   * The stamp in the person's own zone, when known: the same instant, with the offset the zone had then.
   * Cycle entries are whole days logged at local midnight, so the export's one fixed offset would put half
   * the year's entries on the day before; a bedtime or a workout's end would read an hour off.
   */
  private zoned(st: Stamp): Stamp {
    return this.offsetAt ? { ms: st.ms, offsetMin: this.offsetAt(st.ms) } : st;
  }

  private cycleRecord(a: Record<string, string>, meta: Record<string, string>) {
    const kind = CYCLE_TYPES[a.type];
    if (!kind || !a.startDate) return;
    const date = localDate(this.zoned(parseAppleDate(a.startDate)));
    const push = (k: CycleKind, value: string | undefined) => value && this.cycle.push({ date, kind: k, source: SOURCE, value });
    if (kind === 'flow') {
      push('flow', appleFlow(a.value));
      if (yes(meta.HKMenstrualCycleStart)) push('period_start', '1');
    } else if (kind === 'spotting') push('spotting', '1');
    else if (kind === 'ovulation_test') push('ovulation_test', appleOvulation(a.value));
    else if (kind === 'mucus') push('mucus', appleMucus(a.value));
    else if (kind === 'sexual_activity') {
      const used = meta.HKSexualActivityProtectionUsed;
      push('sexual_activity', yes(used) ? 'protected' : no(used) ? 'unprotected' : 'unspecified');
    }
  }

  private nutritionRecord(a: Record<string, string>, n: (typeof NUTRITION_TYPES)[string]) {
    const raw = Number(a.value);
    if (!a.startDate || !Number.isFinite(raw) || raw < 0) return;
    const value = n.convert ? n.convert(raw, a.unit ?? '') : raw;
    const k = `${localDate(parseAppleDate(a.startDate))}|${n.nutrient}|${(a.sourceName ?? '').trim() || 'unknown'}`;
    this.nutrition.set(k, (this.nutrition.get(k) ?? 0) + value);
  }

  private basalTempRecord(a: Record<string, string>) {
    const raw = Number(a.value);
    if (!a.startDate || !Number.isFinite(raw)) return;
    const start = parseAppleDate(a.startDate);
    const date = localDate(this.zoned(start));
    const cur = this.basalTemp.get(date);
    if (!cur || start.ms < cur.ms) this.basalTemp.set(date, { ms: start.ms, value: toCelsius(raw, a.unit ?? '') });
  }

  finish(): { daily: DailyRow[]; hourly: HourlyRow[]; workouts: WorkoutRow[]; events: EventRow[]; cycle: CycleRow[]; nutrition: NutritionRow[] } {
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
    for (const [k, total] of this.totals) {
      const [date, metric] = k.split('|');
      push(date, metric, total);
    }
    for (const [date, hours] of this.standHours) push(date, 'stand_hours', hours.size);

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
    const cycle = [...this.cycle];
    for (const [date, { value }] of this.basalTemp) cycle.push({ date, kind: 'bbt', source: SOURCE, value: String(Math.round(value * 100) / 100) });
    const nutrition: NutritionRow[] = [...this.nutrition].map(([k, value]) => {
      const [date, nutrient, ...app] = k.split('|');
      return { date, nutrient: nutrient as Nutrient, source: SOURCE, app: app.join('|'), value };
    });
    return { daily, hourly, workouts: this.workouts, events, cycle, nutrition };
  }
}

function buildWorkout(a: Record<string, string>, stats: Record<string, string>[], zoned: (st: Stamp) => Stamp): WorkoutRow | null {
  if (!a.startDate || !a.endDate) return null;
  const start = zoned(parseAppleDate(a.startDate));
  const end = zoned(parseAppleDate(a.endDate));
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
  const { daily, hourly, workouts, events, cycle, nutrition } = agg.finish();
  const keepNutrition = (await getUserSetting(db, userId, 'nutrition')) === 'on';

  await db.tx(async (q) => {
    // Clears Apple's rows only, cycle entries included; anything logged by hand stays. Food totals are replaced only
    // while nutrition is on: off, healthOS neither reads them nor touches what it kept from before.
    await deleteSource(q, userId, SOURCE, keepNutrition ? [] : ['nutrition_daily']);
    // Stored whether or not cycle tracking is on, and hidden until it is.
    await upsertCycle(q, userId, cycle);
    // Food totals only for people who turned nutrition on; otherwise healthOS keeps none.
    if (keepNutrition) await upsertNutrition(q, userId, nutrition);
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
  await bumpDataVersion(db, userId);
  return result;
}

