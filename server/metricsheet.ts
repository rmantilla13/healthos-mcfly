// One metric for a detail sheet (GET /api/metric/:key?range=day|week|month|year&date=YYYY-MM-DD): its history over a
// rolling window, three figures, the change from the window before, and one plain sentence about it.
// - Values come from the dashboard's own helpers: loadDaily + series over the window, exactly as GET /api/trends
//   reads them, and dayView for the Day range, as GET /api/day. Same device rules, same blended values.
// - A status is the dashboard's own: read off the summary computed for the same date (the one Home and Body show),
//   so the sheet's pill and sentence can't disagree with the card it was opened from.
// - The sentence is put together from those numbers, never by a model, and says nothing a number doesn't.
// - Only the signed-in person's data, a fixed list of metrics, and nothing here logs a value.
import express, { type NextFunction, type Request, type Response } from 'express';
import { type MetricChange, type MetricFigure, type MetricKey, type MetricRange, type MetricSheet, type MetricStatus, METRIC_INFO, RANGE_DAYS, RANGE_WINDOW, isMetricKey, isMetricRange } from '../shared/metrics.ts';
import type { DayData, DayMetric, Latest, Point, Settings, Summary } from '../shared/types.ts';
import { currentUser } from './auth.ts';
import { addDays } from './dates.ts';
import type { Db, Scope } from './db.ts';
import { DAY_METRICS, dayView } from './day.ts';
import { type Ctx, MIN_AWAKE_HOURS, latest, loadDaily, mean, rangeStatus, requestContext, series, sourceList, summary, valueOn, withDerivedEfficiency } from './query.ts';

const DATE = /^\d{4}-\d{2}-\d{2}$/;
const KG_PER_LB = 0.45359237;

type Spec = {
  /** The stored daily metric. HRV takes the one the summary picked (RMSSD or SDNN); heart rate has only hours. */
  metric: string | null;
  /** The sentence's opening, given the average with its unit: "Your resting heart rate averaged 54 bpm". */
  lead: (value: string) => string;
  /** The words for a change up and down. */
  words?: [up: string, down: string];
  /** A day's running total (steps, energy, strain): today's isn't over, so it's left out of the figures. */
  summed?: boolean;
  /** Stored in kg, shown in the person's units. */
  mass?: boolean;
  /** What one day's value is when it isn't a reading (glucose's is the mean of the day's readings), for the figures and the sentence. */
  perDay?: string;
  /** A change smaller than this (in stored units, kg for mass, or as a fraction of the period before with `steadyPct`) is "about the same". */
  steady: number;
  steadyPct?: boolean;
  /** Read now and then rather than daily (a weigh-in, a meter), so a period needs fewer days to compare. */
  sparse?: boolean;
  /** Its hours, for the Day range. */
  day?: DayMetric;
};

const SPECS: Record<MetricKey, Spec> = {
  resting_hr: { metric: 'resting_hr', lead: (v) => `Your resting heart rate averaged ${v}`, steady: 1 },
  hrv: { metric: null, lead: (v) => `Your HRV averaged ${v}`, steady: 0.03, steadyPct: true },
  sleep_hours: { metric: 'sleep_hours', lead: (v) => `You slept ${v} a night on average`, words: ['more', 'less'], steady: 5 / 60 },
  recovery: { metric: 'recovery', lead: (v) => `Your recovery averaged ${v}`, steady: 3 },
  strain: { metric: 'strain', lead: (v) => `Your day strain averaged ${v}`, summed: true, steady: 0.5 },
  steps: { metric: 'steps', lead: (v) => `You averaged ${v} a day`, words: ['more', 'fewer'], summed: true, steady: 0.05, steadyPct: true, day: 'steps' },
  active_energy: { metric: 'active_energy', lead: (v) => `Your active energy averaged ${v} a day`, summed: true, steady: 0.05, steadyPct: true, day: 'active_energy' },
  spo2: { metric: 'spo2', lead: (v) => `Your blood oxygen averaged ${v}`, steady: 0.3 },
  resp_rate: { metric: 'resp_rate', lead: (v) => `Your respiratory rate averaged ${v}`, steady: 0.3 },
  glucose: { metric: 'glucose', lead: (v) => `Your daily glucose averaged ${v}`, perDay: 'daily average', steady: 2, sparse: true },
  weight: { metric: 'weight', lead: (v) => `Your weight averaged ${v}`, mass: true, steady: 0.2, sparse: true },
  body_fat: { metric: 'body_fat', lead: (v) => `Your body fat averaged ${v}`, steady: 0.3, sparse: true },
  lean_mass: { metric: 'lean_mass', lead: (v) => `Your lean body mass averaged ${v}`, mass: true, steady: 0.2, sparse: true },
  vo2max: { metric: 'vo2max', lead: (v) => `Your cardio fitness averaged ${v}`, steady: 0.5, sparse: true },
  heart_rate: { metric: null, lead: (v) => `Your heart rate averaged ${v}`, steady: 2, day: 'heart_rate' },
  sleep_performance: { metric: 'sleep_performance', lead: (v) => `Your sleep performance averaged ${v}`, steady: 2 },
  sleep_efficiency: { metric: 'sleep_efficiency', lead: (v) => `Your sleep efficiency averaged ${v}`, steady: 1 },
};

/**
 * Days with data each period needs before the two are compared: a third of the days for daily readings, and for
 * ones taken now and then about a reading a fortnight (a month for the year), so a single weigh-in isn't a trend.
 */
const MIN_DAYS: Record<'dense' | 'sparse', Record<Exclude<MetricRange, 'day'>, number>> = {
  dense: { week: 3, month: 10, year: 120 },
  sparse: { week: 1, month: 2, year: 12 },
};

/** The usual band's least width for glucose: a daily average moves a few mg/dL with meals, which isn't a change. */
const GLUCOSE_MIN_SPREAD = 5;
/** How far back the glucose card's latest reading may be: meters and CGMs come and go. */
const GLUCOSE_LOOKBACK = 90;

// ---------- formatting, for the sentence (the dashboard formats the figures itself) ----------

const number = (v: number, digits: number) => v.toLocaleString('en-US', { minimumFractionDigits: digits, maximumFractionDigits: digits });
const hm = (hours: number) => {
  const total = Math.round(hours * 60);
  const h = Math.floor(total / 60);
  const m = total % 60;
  return h ? `${h}h ${String(m).padStart(2, '0')}m` : `${m}m`;
};
const shortDate = new Intl.DateTimeFormat('en-US', { month: 'short', day: 'numeric', timeZone: 'UTC' });
const dayName = (date: string, today: string) => (date === today ? 'today' : date === addDays(today, -1) ? 'yesterday' : `on ${shortDate.format(new Date(`${date}T00:00:00Z`))}`);
const hourFmt = new Intl.DateTimeFormat('en-US', { hour: 'numeric', timeZone: 'UTC' });
const hourLabel = (h: number) => hourFmt.format(Date.UTC(2000, 0, 1, h % 24));

/** A value with its unit as the sentence says it: "54 bpm", "96.5%", "7h 12m", "8,400 steps". */
export function withUnit(key: MetricKey, value: number, unit: string) {
  const info = METRIC_INFO[key];
  if (info.duration) return hm(value);
  const v = number(value, info.digits);
  if (!unit) return v;
  return unit === '%' ? `${v}%` : `${v} ${unit}`;
}

/**
 * A change's size as the sentence says it: sleep in minutes, percentages in points (recovery 55% to 42% is 13
 * points, not "13%", which would read as a relative change), everything else in its own unit.
 */
function sizeOf(key: MetricKey, delta: number, unit: string) {
  if (METRIC_INFO[key].duration) return `${Math.round(Math.abs(delta) * 60)} min`;
  if (unit === '%') {
    const v = number(Math.abs(delta), METRIC_INFO[key].digits);
    return `${v} ${v === '1' ? 'point' : 'points'}`;
  }
  return withUnit(key, Math.abs(delta), unit);
}

// ---------- the sentence ----------

export type SentenceParts = {
  key: MetricKey;
  range: Exclude<MetricRange, 'day'>;
  unit: string;
  average: number;
  /** Days with data in the window, and how many there could have been (one fewer when today isn't counted). */
  days: number;
  possible: number;
  /** The window's average less the previous one's, when both had enough days. */
  delta: number | null;
  previous: number | null;
  /** The card's status for the latest reading, as a phrase ("within your usual range"), with that reading. */
  status: { phrase: string; latest: Latest } | null;
  today: string;
};

const PERIOD: Record<Exclude<MetricRange, 'day'>, [now: string, before: string]> = {
  week: [RANGE_WINDOW.week, 'the 7 days before'],
  month: [RANGE_WINDOW.month, 'the 30 days before'],
  year: [RANGE_WINDOW.year, 'the 12 months before'],
};

/**
 * Whether a change is too small to call one: under the metric's threshold, or zero once rounded as shown. A mass's
 * threshold is in kg, so a change in pounds is weighed in kg first: the same change is steady in either unit.
 */
export function isSteady(key: MetricKey, delta: number, previous: number, unit: string) {
  const s = SPECS[key];
  const stored = s.mass && unit === 'lb' ? delta * KG_PER_LB : delta;
  const small = s.steadyPct ? previous !== 0 && Math.abs(delta / previous) < s.steady : Math.abs(stored) < s.steady;
  return small || /^0(\.0+)?( |%|m|$)/.test(sizeOf(key, delta, unit));
}

/**
 * One plain sentence from the figures: the window's average, how it compares with the window before (only when
 * both had enough days), and the status the card shows for the latest reading, in the card's own terms. Nothing
 * else: no "better", "improving" or "good", so it can't say more than the numbers do.
 */
export function sentence(p: SentenceParts): string {
  const spec = SPECS[p.key];
  const [now, before] = PERIOD[p.range];
  const coverage = p.days < p.possible ? ` (${p.days} ${p.days === 1 ? 'day' : 'days'} with data)` : '';
  let text = `${spec.lead(withUnit(p.key, p.average, p.unit))} over ${now}${coverage}`;
  if (p.delta !== null && p.previous !== null) {
    const [up, down] = spec.words ?? ['higher', 'lower'];
    text += isSteady(p.key, p.delta, p.previous, p.unit)
      ? `, about the same as ${before}`
      : `, ${sizeOf(p.key, p.delta, p.unit)} ${p.delta > 0 ? up : down} than ${before}`;
  }
  const latestWord = spec.perDay ? `your latest ${spec.perDay}` : 'your latest';
  if (p.status) text += `; ${latestWord}, ${withUnit(p.key, p.status.latest.value, p.unit)} ${dayName(p.status.latest.date, p.today)}, ${p.status.phrase}`;
  return `${text}.`;
}

// ---------- statuses, as the cards show them ----------

const USUAL: Record<'low' | 'normal' | 'high', [MetricStatus, string]> = {
  low: [{ text: 'Below your usual', position: 'below' }, 'is below your usual range'],
  normal: [{ text: 'Within your usual', position: 'within' }, 'is within your usual range'],
  high: [{ text: 'Above your usual', position: 'above' }, 'is above your usual range'],
};
/** Above the usual band, for a card that calls anything not below it "Normal" (blood oxygen). */
const AT_OR_ABOVE: [MetricStatus, string] = [{ text: 'At or above your usual', position: 'at_or_above' }, 'is at or above your usual range'];
/**
 * The summary's HRV status. 'optimal' is any night at or above the mean of the 30 days before it (Body's words, not
 * Home's "Optimal"): it isn't a band, so the sentence says the average, not the range. The other two are band-based.
 */
const HRV: Record<'optimal' | 'normal' | 'low', [MetricStatus, string]> = {
  optimal: [AT_OR_ABOVE[0], 'is at or above the average of the 30 days before it'],
  normal: USUAL.normal,
  low: USUAL.low,
};
/** WHOOP's recovery zones, as Body's card names them. */
const ZONE = { green: ['High', '67–100'], yellow: ['Moderate', '34–66'], red: ['Low', '0–33'] } as const;
/** WHOOP's strain bands, as the strain card names them. */
const strainBand = (v: number) => (v < 10 ? ['Light', 'under 10'] : v < 14 ? ['Moderate', '10–14'] : v < 18 ? ['High', '14–18'] : ['All out', '18–21']);

type Found = { status: MetricStatus; phrase: string; latest: Latest };

/** The status a card on Home or Body shows for this metric, from the same summary those cards read. */
function cardStatus(key: MetricKey, s: Summary, stepGoal: number): Found | null {
  const usual = (l: Latest | null, st: 'low' | 'normal' | 'high' | null) => (l && st ? { status: USUAL[st][0], phrase: USUAL[st][1], latest: l } : null);
  switch (key) {
    case 'resting_hr':
      return usual(s.vitals.heart.latest, s.vitals.heart.status);
    case 'resp_rate':
      return usual(s.vitals.breathing.latest, s.vitals.breathing.status);
    case 'spo2': {
      // The cards call anything not below the usual range "Normal": a high reading isn't singled out, so here it's
      // "at or above" rather than "above", which the card's word can't seem to contradict.
      const l = s.spo2.latest;
      const st = s.spo2.status;
      if (!l || !st) return null;
      return st === 'high' ? { status: AT_OR_ABOVE[0], phrase: AT_OR_ABOVE[1], latest: l } : usual(l, st);
    }
    case 'hrv':
      return s.hrv.latest && s.hrv.status ? { status: HRV[s.hrv.status][0], phrase: HRV[s.hrv.status][1], latest: s.hrv.latest } : null;
    case 'recovery': {
      const r = s.readiness;
      if (r?.kind !== 'recovery') return null;
      const [word, range] = ZONE[r.zone];
      return { status: { text: `${word} zone, ${range}`, position: 'band' }, phrase: `is in the ${word.toLowerCase()} zone (${range})`, latest: r.latest };
    }
    case 'strain': {
      const l = s.load;
      if (l?.kind !== 'strain') return null;
      const [word, range] = strainBand(l.latest.value);
      return { status: { text: word, position: 'band' }, phrase: `is ${word.toLowerCase()} (${range} of 21)`, latest: l.latest };
    }
    case 'active_energy': {
      // Only where the card shows it: the Load card's energy view (no WHOOP strain), against the 7 days before.
      const l = s.load;
      if (l?.kind !== 'energy' || l.average === null) return null;
      const above = l.latest.value >= l.average;
      return {
        status: { text: above ? 'Above usual' : 'Below usual', position: 'band' },
        phrase: above ? 'is at or above the average of the 7 days before it' : 'is below the average of the 7 days before it',
        latest: l.latest,
      };
    }
    case 'steps': {
      const l = s.activity.latest;
      if (!l) return null;
      const pct = Math.round((l.value / stepGoal) * 100);
      return { status: { text: `${pct}% of goal`, position: 'band' }, phrase: `is ${pct}% of your ${number(stepGoal, 0)}-step goal`, latest: l };
    }
    default:
      return null;
  }
}

const SUMMARY_KEYS = new Set<MetricKey>(['resting_hr', 'hrv', 'spo2', 'resp_rate', 'recovery', 'strain', 'active_energy', 'steps']);

// ---------- the sheet ----------

export class SheetError extends Error {
  readonly status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

type Snapshot = { daily: Ctx['daily']; demo: boolean };

/** Monday of a date's week, so a year's weeks line up with the Activity page's weekly bars. */
const monday = (date: string) => {
  const d = new Date(`${date}T00:00:00Z`);
  return addDays(date, -((d.getUTCDay() + 6) % 7));
};

/** Weekly averages of daily values, each dated its Monday. */
export function weeklyMeans(points: Point[]): Point[] {
  const weeks = new Map<string, number[]>();
  for (const p of points) {
    const k = monday(p.date);
    const list = weeks.get(k);
    if (list) list.push(p.value);
    else weeks.set(k, [p.value]);
  }
  return [...weeks].map(([date, vs]) => ({ date, value: mean(vs)! }));
}

const lowest = (ps: Point[]) => ps.reduce<Point | null>((a, p) => (!a || p.value < a.value ? p : a), null);
const highest = (ps: Point[]) => ps.reduce<Point | null>((a, p) => (!a || p.value > a.value ? p : a), null);

function sourcesIn(snap: Snapshot, metric: string, points: Point[]) {
  const set = new Set<string>();
  for (const p of points) for (const s of (valueOn(snap, metric, p.date)?.source ?? '').split('+')) if (s) set.add(s);
  return [...set].sort();
}

// Efficiency where a device sent none of its own lives in query.ts, so the Sleep page's card picks the same night's
// value as this sheet; exported here as before.
export { withDerivedEfficiency };

/**
 * Whether the person has ever had a reading of this metric, on any day, from the sources the sheet reads: one EXISTS
 * per kind of row. HRV counts either measure; the Day metrics count their hours too (heart rate has only hours).
 */
async function everMeasured(scope: Scope, demo: boolean, key: MetricKey): Promise<boolean> {
  const spec = SPECS[key];
  const daily = key === 'hrv' ? ['hrv_rmssd', 'hrv_sdnn'] : spec.metric ? [spec.metric] : [];
  // Every parameter is used by a check (Postgres can't type one that isn't).
  const params: unknown[] = [scope.userId];
  const checks: string[] = [];
  if (daily.length) {
    params.push(sourceList(demo), daily);
    const [sources, metrics] = [params.length - 1, params.length];
    checks.push(`EXISTS (SELECT 1 FROM daily WHERE user_id = $1 AND source = ANY($${sources}) AND metric = ANY($${metrics}))`);
    if (key === 'sleep_efficiency') {
      checks.push(
        `EXISTS (SELECT 1 FROM daily h JOIN daily b ON b.user_id = h.user_id AND b.date = h.date AND b.source = h.source AND b.metric = 'sleep_in_bed'
          WHERE h.user_id = $1 AND h.source = ANY($${sources}) AND h.metric = 'sleep_hours' AND b.value - h.value > ${MIN_AWAKE_HOURS})`,
      );
    }
  }
  if (spec.day) {
    params.push(demo ? ['demo', ...sourceList(false)] : sourceList(false), HOURLY_BASE[spec.day]);
    checks.push(`EXISTS (SELECT 1 FROM hourly WHERE user_id = $1 AND source = ANY($${params.length - 1}) AND metric = $${params.length})`);
  }
  const [row] = await scope.db.query<{ has: boolean }>(`SELECT ${checks.join(' OR ')} AS has`, params);
  return Boolean(row?.has);
}

export async function metricSheet(scope: Scope, hosted: boolean, key: MetricKey, range: MetricRange, dateParam?: string): Promise<MetricSheet> {
  const info = METRIC_INFO[key];
  const spec = SPECS[key];
  if (!info.ranges.includes(range)) throw new SheetError(400, range === 'day' ? 'Only steps, active energy and heart rate have a Day view.' : `${info.label} has a Day view only.`);
  const { settings, demo, today } = await requestContext(scope, hosted);
  const asOf = dateParam && dateParam <= today ? dateParam : today;
  const ever = everMeasured(scope, demo, key);
  // Awaited below; this only keeps a failure that comes while something else is awaited from going unhandled.
  ever.catch(() => {});
  if (range === 'day') return { ...(await daySheet(scope, hosted, key, asOf, settings, demo)), everMeasured: await ever };

  const n = RANGE_DAYS[range];
  const from = addDays(asOf, -(n - 1));
  const prevFrom = addDays(from, -n);
  const s = SUMMARY_KEYS.has(key) ? await summary(scope, hosted, asOf) : null;
  // HRV is whichever of RMSSD (WHOOP) and SDNN (Apple Watch) the dashboard shows: the two are never mixed.
  const metric = key === 'hrv' ? s!.hrv.metric : spec.metric!;
  // The glucose status looks back further than a week, at its own 30 days before the latest reading.
  const loadFrom = key === 'glucose' ? addDays(asOf, -(GLUCOSE_LOOKBACK + 31)) : prevFrom;
  const efficiency = key === 'sleep_efficiency';
  const loaded = await loadDaily(scope, demo, loadFrom < prevFrom ? loadFrom : prevFrom, asOf, efficiency ? [metric, 'sleep_hours', 'sleep_in_bed'] : [metric]);
  const daily = efficiency ? withDerivedEfficiency(loaded) : loaded;
  const snap: Snapshot = { daily, demo };

  const units = settings.units;
  const conv = (v: number) => (spec.mass && units === 'imperial' ? v / KG_PER_LB : v);
  const convPts = (ps: Point[]) => ps.map((p) => ({ date: p.date, value: conv(p.value) }));
  const unit = spec.mass ? (units === 'imperial' ? 'lb' : 'kg') : info.unit;

  // The window, as GET /api/trends reads it for the same days and date.
  const inWindow = series(snap, metric, from, asOf);
  const shown = convPts(inWindow);
  const partialToday = !!spec.summed && inWindow.at(-1)?.date === today;
  const counted = partialToday ? shown.slice(0, -1) : shown;
  const before = convPts(series(snap, metric, prevFrom, addDays(from, -1)));
  const average = mean(counted.map((p) => p.value));
  const previous = mean(before.map((p) => p.value));
  const need = MIN_DAYS[spec.sparse ? 'sparse' : 'dense'][range];

  let change: MetricChange | null = null;
  if (average !== null && previous !== null && counted.length >= need && before.length >= need) {
    change = { previous, delta: average - previous, pct: previous ? (average - previous) / previous : null, against: PERIOD[range][1], from: prevFrom, to: addDays(from, -1), days: before.length };
  }

  let found = s ? cardStatus(key, s, settings.stepGoal) : null;
  if (key === 'glucose') {
    const ctx: Ctx = { settings, demo, today, daily, workouts: [], sleepStarts: [] };
    const l = latest(ctx, 'glucose', asOf, GLUCOSE_LOOKBACK);
    const st = rangeStatus(ctx, 'glucose', l, GLUCOSE_MIN_SPREAD);
    if (l && st) found = { status: USUAL[st][0], phrase: USUAL[st][1], latest: l };
  }
  if (found && spec.mass) found = { ...found, latest: { ...found.latest, value: conv(found.latest.value) } };

  const possible = n - (partialToday ? 1 : 0);
  const last = shown.at(-1) ?? null;
  const per = spec.perDay ? ` ${spec.perDay}` : '';
  const tiles: MetricFigure[] = [
    { label: spec.summed ? 'Lowest day' : `Lowest${per}`, value: lowest(counted)?.value ?? null, unit, date: lowest(counted)?.date },
    { label: spec.summed ? 'Highest day' : `Highest${per}`, value: highest(counted)?.value ?? null, unit, date: highest(counted)?.date },
    { label: `Latest${per}`, value: last?.value ?? null, unit, date: last?.date, ...(partialToday ? { note: 'so far today' } : {}) },
  ];
  const headline: MetricFigure = {
    label: spec.summed ? 'Daily average' : info.duration ? 'Average a night' : 'Average',
    value: average,
    unit,
    note: `${counted.length} of ${possible} days with data${partialToday ? "; today isn't counted until it's over" : ''}`,
  };

  return {
    key,
    metric,
    label: info.label,
    unit,
    digits: info.digits,
    range,
    ranges: await rangesOf(scope, demo, key),
    from,
    to: asOf,
    today,
    resolution: range === 'year' ? 'week' : 'day',
    // A year's weeks average whole days: today's unfinished total would pull its week down.
    points: range === 'year' ? weeklyMeans(counted) : shown,
    day: null,
    sources: sourcesIn(snap, metric, inWindow),
    days: counted.length,
    partialToday,
    headline,
    tiles,
    change,
    latest: found ? { date: found.latest.date, value: found.latest.value } : last,
    status: found?.status ?? null,
    goal: key === 'steps' ? settings.stepGoal : null,
    narrative:
      average === null
        ? null
        : sentence({ key, range, unit, average, days: counted.length, possible, delta: change?.delta ?? null, previous: change?.previous ?? null, status: found ? { phrase: found.phrase, latest: found.latest } : null, today }),
    everMeasured: await ever,
  };
}

/** The stored hourly metric that says whether a Day metric has hours at all (as in server/day.ts). */
const HOURLY_BASE: Record<DayMetric, string> = { steps: 'steps', active_energy: 'active_energy', heart_rate: 'hr_avg' };

/** The metric's ranges; Day only once the person has hours for it (the iPhone app or an export sent them). */
async function rangesOf(scope: Scope, demo: boolean, key: MetricKey): Promise<MetricRange[]> {
  const info = METRIC_INFO[key];
  const dm = SPECS[key].day;
  if (!dm || !info.ranges.includes('day')) return info.ranges;
  const sources = demo ? ['demo', ...sourceList(false)] : sourceList(false);
  const [row] = await scope.db.query<{ has: boolean }>('SELECT EXISTS (SELECT 1 FROM hourly WHERE user_id = $1 AND metric = $2 AND source = ANY($3)) AS has', [
    scope.userId,
    HOURLY_BASE[dm],
    sources,
  ]);
  return row?.has ? info.ranges : info.ranges.filter((r) => r !== 'day');
}

/** One day, hour by hour, as the Day view shows it: a running total for steps and energy, hourly averages for heart rate. */
async function daySheet(scope: Scope, hosted: boolean, key: MetricKey, asOf: string, settings: Settings, demo: boolean): Promise<MetricSheet> {
  const info = METRIC_INFO[key];
  const dm = SPECS[key].day!;
  // All three Day metrics, as Body asks GET /api/day for them, so "now" is the cards' hour: the latest synced of any
  // of them. A metric's own last hour can be earlier (heart rate synced at 2 PM, steps at 11 AM), and comparing at
  // it would set the sheet's "typical by now" against an earlier hour than the card's. A metric with no hours of its
  // own that day has no hour at all, as before.
  const all = await dayView(scope, hosted, DAY_METRICS, asOf);
  const ser = all.metrics[dm];
  const own = !!ser && [ser.hours, ser.min, ser.max].some((l) => l?.some((v) => v !== null));
  const data: DayData = { ...all, asOf: own ? all.asOf : null, metrics: ser ? { [dm]: ser } : {} };
  // The device behind the day's hours: Apple's when there are any (as dayView picks), else demo hours.
  const rows = ser
    ? await scope.db.query<{ source: string }>('SELECT DISTINCT source FROM hourly WHERE user_id = $1 AND metric = $2 AND date = $3 AND source = ANY($4)', [
        scope.userId,
        HOURLY_BASE[dm],
        data.date,
        demo ? ['demo', ...sourceList(false)] : sourceList(false),
      ])
    : [];
  const hourSources = rows.some((r) => r.source === 'apple') ? ['apple'] : rows.map((r) => r.source).sort().slice(0, 1);
  const isToday = data.date === data.today;
  const through = data.asOf === null ? null : data.date < data.today ? 23 : data.asOf;
  const base = {
    key,
    metric: null,
    label: info.label,
    unit: info.unit,
    digits: info.digits,
    range: 'day' as const,
    ranges: info.ranges,
    from: data.date,
    to: data.date,
    today: data.today,
    resolution: 'hour' as const,
    points: [],
    day: data,
    sources: hourSources,
    days: through === null ? 0 : 1,
    partialToday: false,
    latest: null,
    status: null,
    goal: key === 'steps' ? settings.stepGoal : null,
  };
  const empty = { ...base, headline: { label: isToday ? 'Today' : 'That day', value: null, unit: info.unit }, tiles: [], change: null, narrative: null };
  // No hours for this metric on any day: the sheet offers the other ranges instead (heart rate has none).
  const noDay = info.ranges.filter((r) => r !== 'day');
  if (!ser) return { ...empty, ranges: noDay.length ? noDay : info.ranges };
  const when = isToday ? 'so far today' : dayName(data.date, data.today);
  const span = (h: number) => `${hourLabel(h)}–${hourLabel(h + 1)}`;

  if (dm === 'heart_rate') {
    let h: number | null = null;
    if (through !== null) for (let i = through; i >= 0; i--) if (ser.hours[i] !== null) { h = i; break; }
    if (h === null) return empty;
    const upTo = (l?: (number | null)[]) => (l ?? []).slice(0, through! + 1).filter((v): v is number => v !== null);
    const lows = upTo(ser.min).length ? upTo(ser.min) : upTo(ser.hours);
    const highs = upTo(ser.max).length ? upTo(ser.max) : upTo(ser.hours);
    const value = ser.hours[h]!;
    const typical = ser.typical[h];
    const change: MetricChange | null = typical !== null ? { previous: typical, delta: value - typical, pct: typical ? (value - typical) / typical : null, against: `your typical ${span(h)}` } : null;
    const lo = Math.min(...lows);
    const hi = Math.max(...highs);
    const unit = info.unit;
    // Today's last synced hour may still be filling up, so it's the average since the hour began (as on Home).
    const partial = isToday && h === data.asOf;
    const hourText = partial ? `since ${hourLabel(h)}` : `from ${hourLabel(h)} to ${hourLabel(h + 1)}`;
    let text = `Your heart rate averaged ${withUnit(key, value, unit)} ${hourText}`;
    if (change) text += isSteady(key, change.delta, change.previous, unit) ? ', about the same as your typical hour then' : `, ${withUnit(key, Math.abs(change.delta), unit)} ${change.delta > 0 ? 'higher' : 'lower'} than your typical hour then`;
    text += `; it ranged from ${number(lo, 0)} to ${withUnit(key, hi, unit)} ${isToday ? 'so far today' : 'that day'}.`;
    return {
      ...base,
      headline: { label: isToday ? 'Latest hour' : 'Last hour with a reading', value, unit, note: partial ? `average since ${hourLabel(h)}` : `${span(h)} average` },
      tiles: [
        { label: 'Lowest', value: lo, unit, note: isToday ? 'so far today' : 'that day' },
        { label: 'Highest', value: hi, unit, note: isToday ? 'so far today' : 'that day' },
        { label: 'Typical then', value: typical, unit, note: 'median of the last 30 days' },
      ],
      change,
      narrative: text,
    };
  }

  // Steps and energy: the running total through the last hour drawn, as the Day view's cards show it.
  let run = 0;
  let busiest: { h: number; v: number } | null = null;
  let recorded = 0;
  if (through !== null)
    for (let h = 0; h <= through; h++) {
      const v = ser.hours[h];
      if (v === null) continue;
      run += v;
      if (v > 0) recorded++;
      if (!busiest || v > busiest.v) busiest = { h, v };
    }
  // The day's count as the cards show it (steps only; GET /api/day gives it as `total`): when it's ahead of the
  // hours (WHOOP's count, or the phone's before all its hours have synced), it's the day's figure, as on the Activity
  // card. The hours are then only part of the day, so there's no like-for-like comparison with a typical day.
  const ahead = ser.total && (through === null || ser.total.value > run) ? ser.total : null;
  const whoop = ahead?.source === 'whoop';
  const value = ahead ? ahead.value : through !== null ? run : null;
  if (value === null) return empty;
  const unit = info.unit;
  const typical = through !== null ? ser.typical[through] : null;
  const byWhen = isToday && through !== null ? `your typical day by ${hourLabel(through + 1)}` : 'your typical day';
  const change: MetricChange | null = !ahead && through !== null && typical !== null ? { previous: typical, delta: run - typical, pct: typical ? (run - typical) / typical : null, against: byWhen } : null;
  const verb = key === 'steps' ? (isToday ? "You've taken" : 'You took') : isToday ? "You've burned" : 'You burned';
  let text = `${verb} ${withUnit(key, value, unit)}${key === 'active_energy' ? ' of active energy' : ''} ${when}`;
  if (change) {
    const [up, down] = SPECS[key].words ?? ['more', 'less'];
    text += isSteady(key, change.delta, change.previous, unit) ? `, about the same as ${byWhen}` : `, ${withUnit(key, Math.abs(change.delta), unit)} ${change.delta > 0 ? up : down} than ${byWhen}`;
  }
  const hoursSoFar = `${withUnit(key, run, unit)} in the hours ${isToday ? 'synced so far' : 'recorded'}`;
  if (through === null) text += whoop ? ", WHOOP's count, with no hourly readings" : ', with no hourly readings';
  else if (whoop) text += `; that count is WHOOP's, and your iPhone or Apple Watch counted ${hoursSoFar}`;
  else if (ahead) text += `, the day's count; ${hoursSoFar}`;
  const headNote =
    through === null
      ? whoop
        ? "WHOOP's count; no hourly readings"
        : 'no hourly readings'
      : whoop
        ? `WHOOP's count; ${hoursSoFar}, from your iPhone or Apple Watch`
        : ahead
          ? `the day's count; ${hoursSoFar}`
          : undefined;
  const tiles: MetricFigure[] = [
    { label: isToday ? 'Typical by now' : 'Typical day', value: typical, unit, note: 'median of the last 30 days' },
    { label: 'Busiest hour', value: busiest?.v ?? null, unit, note: busiest ? span(busiest.h) : undefined },
    key === 'steps'
      ? { label: 'Goal', value: settings.stepGoal, unit, note: `${Math.round((value / settings.stepGoal) * 100)}% reached` }
      : { label: 'Hours with activity', value: recorded, unit: recorded === 1 ? 'hour' : 'hours' },
  ];
  return {
    ...base,
    sources: whoop ? [...new Set([...hourSources, 'whoop'])].sort() : base.sources,
    headline: { label: isToday ? 'So far today' : 'Whole day', value, unit, note: headNote },
    tiles,
    change,
    narrative: `${text}.`,
  };
}

// ---------- the router ----------

export function metricRouter(db: Db, hosted: boolean) {
  const router = express.Router();
  const scopeOf = (res: Response): Scope => ({ db, userId: currentUser(res).id });

  router.get('/:key', async (req, res) => {
    const key = req.params.key;
    // Named from a fixed list: anything else is unknown, and isn't repeated back.
    if (!isMetricKey(key)) return void res.status(404).json({ error: 'Unknown metric' });
    const range = req.query.range === undefined ? METRIC_INFO[key].initial : req.query.range;
    if (!isMetricRange(range)) return void res.status(400).json({ error: 'range must be day, week, month or year' });
    const date = req.query.date === undefined ? undefined : String(req.query.date);
    if (date !== undefined && !DATE.test(date)) return void res.status(400).json({ error: 'date must be YYYY-MM-DD' });
    try {
      res.json(await metricSheet(scopeOf(res), hosted, key, range, date));
    } catch (err) {
      if (err instanceof SheetError) return void res.status(err.status).json({ error: err.message });
      throw err;
    }
  });

  router.use((err: Error & { status?: number }, _req: Request, res: Response, _next: NextFunction) => {
    if (err.status && err.status >= 400 && err.status < 500) return void res.status(err.status).json({ error: 'Bad request' });
    // The kind of failure only: a database error's text can quote the values it was given.
    console.error('metric sheet:', err.name);
    res.status(500).json({ error: 'Something went wrong' });
  });

  return router;
}

