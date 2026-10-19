import os from 'node:os';
import type { Flag, Insight, Latest, Point, RangeStatus, Settings, Summary, TimelineEvent, Trends, Vital, WeekSummary, Workout } from '../shared/types.ts';
import { OWNER_ID, type Scope, getSettings, getUserSettings } from './db.ts';
import { addDays, todayLocal } from './dates.ts';

// Which source wins when more than one has a value for the same day.
// WHOOP is worn overnight so it leads on recovery-type metrics; the iPhone and Watch lead on movement and body.
const APPLE_FIRST = new Set(['steps', 'active_energy', 'exercise_min', 'distance_km', 'weight', 'body_fat', 'lean_mass', 'vo2max', 'hr_avg', 'hr_min', 'hr_max']);

// ---------- loading ----------
// A request loads what it needs in a few queries up front (the hosted database is a network hop away);
// the calculations below then run synchronously over that snapshot.

type DailyIndex = Map<string, Map<string, Map<string, number>>>; // metric -> source -> date -> value

export type Ctx = {
  settings: Settings;
  demo: boolean;
  today: string;
  daily: DailyIndex;
  workouts: Workout[];
  sleepStarts: { date: string; start: string }[];
};

const SEXES = ['female', 'male', 'unspecified'] as const;

/** One person's settings, falling back to the platform defaults an admin sets. */
export function settingsFrom(mine: Map<string, string>, platform: Map<string, string>, opts: { hosted: boolean; userId: string }): Settings {
  // Hosted, the OS user is the platform's sandbox account, so don't guess a name from it.
  const fallbackName = !opts.hosted && opts.userId === OWNER_ID ? capitalize(os.userInfo().username) : '';
  const units = mine.get('units') ?? platform.get('default_units');
  return {
    name: mine.get('name') || mine.get('whoop_first_name') || fallbackName,
    stepGoal: Number(mine.get('step_goal')) || Number(platform.get('default_step_goal')) || 10_000,
    units: units === 'imperial' ? 'imperial' : 'metric',
    demo: (mine.get('demo') as Settings['demo']) || 'auto',
    timeZone: mine.get('timezone') ?? null,
    sex: SEXES.find((x) => x === mine.get('sex')) ?? null,
    cycleTracking: mine.get('cycle_tracking') === 'on',
    familySharing: mine.get('family_sharing') !== 'off',
    shareCyclePhase: mine.get('family_cycle_phase') === 'on',
    // Version 2: the board now also shows the last 30 days, so everyone hears about it again.
    familyNoticeSeen: mine.get('family_notice_seen') === '2',
  };
}

export async function readSettings(scope: Scope, hosted = false) {
  const [mine, platform] = await Promise.all([getUserSettings(scope.db, scope.userId), getSettings(scope.db)]);
  return settingsFrom(mine, platform, { hosted, userId: scope.userId });
}

export async function hasRealData(scope: Scope) {
  const [row] = await scope.db.query<{ any: boolean }>(
    "SELECT EXISTS (SELECT 1 FROM daily WHERE user_id = $1 AND source IN ('apple', 'whoop')) AS any",
    [scope.userId],
  );
  return Boolean(row?.any);
}

/** Demo rows only ever exist in a local database, seeded for the owner, so nobody else (and nothing hosted) sees them. */
export async function demoActive(scope: Scope, settings: Settings, hosted: boolean) {
  if (hosted || scope.userId !== OWNER_ID) return false;
  return settings.demo === 'on' || (settings.demo === 'auto' && !(await hasRealData(scope)));
}

export const sourceList = (demo: boolean) => (demo ? ['demo'] : ['apple', 'whoop']);

function sourcesFor(ctx: { demo: boolean }, metric: string): string[] {
  if (ctx.demo) return ['demo'];
  return APPLE_FIRST.has(metric) ? ['apple', 'whoop'] : ['whoop', 'apple'];
}

export async function loadDaily(scope: Scope, demo: boolean, from: string, to: string, metrics?: string[]): Promise<DailyIndex> {
  const params: unknown[] = [scope.userId, from, to, sourceList(demo)];
  let filter = '';
  if (metrics) {
    params.push(metrics);
    filter = 'AND metric = ANY($5)';
  }
  const rows = await scope.db.query<{ date: string; metric: string; source: string; value: number }>(
    `SELECT date, metric, source, value FROM daily WHERE user_id = $1 AND date BETWEEN $2 AND $3 AND source = ANY($4) ${filter}`,
    params,
  );
  const index: DailyIndex = new Map();
  for (const r of rows) {
    let bySource = index.get(r.metric);
    if (!bySource) index.set(r.metric, (bySource = new Map()));
    let byDate = bySource.get(r.source);
    if (!byDate) bySource.set(r.source, (byDate = new Map()));
    byDate.set(r.date, Number(r.value));
  }
  return index;
}

export async function latestDataDate(scope: Scope, demo: boolean, today: string): Promise<string | null> {
  const [row] = await scope.db.query<{ d: string | null }>(
    'SELECT MAX(date) AS d FROM daily WHERE user_id = $1 AND source = ANY($2) AND date <= $3',
    [scope.userId, sourceList(demo), today],
  );
  return row?.d ?? null;
}

const WORKOUT_FIELDS = 'id, source, sport, start, "end", date, duration_min, energy_kcal, distance_m, avg_hr, max_hr, strain';

export async function loadWorkouts(scope: Scope, demo: boolean, from: string, to: string): Promise<Workout[]> {
  return scope.db.query<Workout>(
    `SELECT ${WORKOUT_FIELDS} FROM workouts WHERE user_id = $1 AND date BETWEEN $2 AND $3 AND source = ANY($4) ORDER BY start DESC`,
    [scope.userId, from, to, sourceList(demo)],
  );
}

export async function requestContext(scope: Scope, hosted: boolean) {
  const settings = await readSettings(scope, hosted);
  const demo = await demoActive(scope, settings, hosted);
  return { settings, demo, today: todayLocal(settings.timeZone ?? undefined) };
}

// ---------- series over the snapshot ----------

/**
 * Metrics that Apple Watch and WHOOP each measure themselves. (WHOOP's own copies in Apple Health are
 * skipped at import, so the two are independent.) On a day both have, the dashboard shows their mean
 * when they agree within the tolerance, and otherwise the source trusted for that metric, so one
 * device that slipped off mid-night can't drag the number.
 */
type Blend = { agree: (a: number, b: number) => boolean; trust: string };
const within = (pct: number) => (a: number, b: number) => Math.abs(a - b) <= pct * Math.max(Math.abs(a), Math.abs(b));
const withinAbs = (d: number) => (a: number, b: number) => Math.abs(a - b) <= d;
// Chosen from the user's own overlap: SpO2 agrees within 2.5 points every day, and sleep differs mainly
// on nights one device wasn't worn. Resting heart rate is deliberately not blended: WHOOP measures it
// asleep and Apple during the day, ~7 bpm apart, so an average would add a third level that shifts with
// whichever device was worn. It takes WHOOP's sleeping measure when there is one, as the source order says.
const BLEND: Record<string, Blend> = {
  // WHOOP is worn overnight, so it's the steadier reading when the two disagree.
  spo2: { agree: withinAbs(2.5), trust: 'whoop' },
  resp_rate: { agree: within(0.1), trust: 'whoop' },
  sleep_hours: { agree: within(0.2), trust: 'whoop' },
};
/**
 * Steps. Apple's count is a calendar day from whichever device saw the most of it: iPhone, Watch, or WHOOP's
 * own copy in Health. WHOOP's API count runs from one sleep to the next, so the two days' edges differ and
 * they're never added. Apple's calendar day is used unless WHOOP's is clearly larger (Apple missed most of
 * the day: the phone sat on a desk while the strap was worn), then WHOOP's. Close counts are the same
 * walking measured over slightly different windows, and the calendar one is right and has hours.
 */
const WHOOP_STEPS_RATIO = 1.2;
const WHOOP_STEPS_MARGIN = 1000;

export function pickSteps<T extends { source: string; value: number }>(apple: T | undefined, whoop: T | undefined): T | undefined {
  if (!apple || !whoop) return apple ?? whoop;
  return whoop.value >= apple.value * WHOOP_STEPS_RATIO && whoop.value - apple.value >= WHOOP_STEPS_MARGIN ? whoop : apple;
}

/** A night's stages and time in bed follow that night's sleep_hours decision, so the parts stay consistent. */
const FOLLOWS: Record<string, string> = {
  sleep_deep: 'sleep_hours',
  sleep_rem: 'sleep_hours',
  sleep_light: 'sleep_hours',
  sleep_awake: 'sleep_hours',
  sleep_in_bed: 'sleep_hours',
};

type Snapshot = Pick<Ctx, 'daily' | 'demo'>;

/** How to combine the sources for a blended metric on a date: average them, or take one. */
function decide(ctx: Snapshot, metric: string, date: string): 'mean' | string | null {
  const rule = BLEND[metric];
  const bySource = ctx.daily.get(metric);
  if (!rule || !bySource) return null;
  const a = bySource.get('apple')?.get(date);
  const w = bySource.get('whoop')?.get(date);
  if (a === undefined || w === undefined) return null;
  return rule.agree(a, w) ? 'mean' : rule.trust;
}

/** The dashboard's value for a metric on one date, and where it came from. */
export function valueOn(ctx: Snapshot, metric: string, date: string): { value: number; source: string } | undefined {
  const bySource = ctx.daily.get(metric);
  if (!bySource) return undefined;
  const present = sourcesFor(ctx, metric)
    .map((source) => ({ source, value: bySource.get(source)?.get(date) }))
    .filter((p): p is { source: string; value: number } => p.value !== undefined);
  if (present.length <= 1) return present[0];
  if (metric === 'steps') {
    const pick = pickSteps(present.find((p) => p.source === 'apple'), present.find((p) => p.source === 'whoop'));
    if (pick) return pick;
  }
  const how = decide(ctx, FOLLOWS[metric] ?? metric, date);
  if (how === 'mean') return { value: present.reduce((t, p) => t + p.value, 0) / present.length, source: 'apple+whoop' };
  return present.find((p) => p.source === how) ?? present[0];
}

/** Daily values for a metric over a date range, combining sources as described above. */
export function series(ctx: Snapshot, metric: string, from: string, to: string): Point[] {
  const bySource = ctx.daily.get(metric);
  if (!bySource) return [];
  const dates = new Set<string>();
  for (const byDate of bySource.values()) for (const d of byDate.keys()) if (d >= from && d <= to) dates.add(d);
  return [...dates].sort().map((date) => ({ date, value: valueOn(ctx, metric, date)!.value }));
}

/**
 * Metrics whose two sources measure different things, so a reading is judged against the same device's own
 * history. The daily resting heart rate falls back from WHOOP's sleeping measure to the Watch's daytime one,
 * ~7 bpm higher, and a few days without the strap would otherwise read as a heart rate that went up.
 */
const OWN_BASELINE = new Set(['resting_hr']);

/** The snapshot narrowed to one source's values of a metric. */
function fromSource(ctx: Snapshot, metric: string, source: string): Snapshot {
  const byDate = ctx.daily.get(metric)?.get(source);
  return { demo: ctx.demo, daily: new Map(byDate ? [[metric, new Map([[source, byDate]])]] : []) };
}

/**
 * The most recent value within the lookback window, from any source, so a stale reading from one
 * device never hides a fresher one (e.g. a WHOOP left in a drawer while the Apple Watch keeps recording).
 */
export function latest(ctx: Snapshot, metric: string, asOf: string, lookbackDays = 14): Latest | null {
  const bySource = ctx.daily.get(metric);
  if (!bySource) return null;
  const from = addDays(asOf, -lookbackDays);
  let newest: string | undefined;
  for (const byDate of bySource.values()) for (const d of byDate.keys()) if (d >= from && d <= asOf && (!newest || d > newest)) newest = d;
  if (!newest) return null;
  const v = valueOn(ctx, metric, newest)!;
  return { date: newest, value: v.value, source: v.source };
}

/**
 * The same session recorded by both devices becomes one: Apple's type, duration, calories and distance
 * (what you chose and what the Watch measured), plus WHOOP's strain.
 */
export function mergeWorkouts(list: Workout[]): Workout[] {
  const whoop = list.filter((w) => w.source === 'whoop');
  const used = new Set<string>();
  const overlaps = (a: Workout, b: Workout) => {
    const [as, ae, bs, be] = [Date.parse(a.start), Date.parse(a.end), Date.parse(b.start), Date.parse(b.end)];
    const overlap = Math.min(ae, be) - Math.max(as, bs);
    return Math.abs(as - bs) < 15 * 60_000 || overlap > 0.5 * Math.min(ae - as, be - bs);
  };
  const out: Workout[] = [];
  for (const w of list) {
    if (w.source === 'whoop') continue;
    const twin = w.source === 'apple' ? whoop.find((x) => !used.has(x.id) && overlaps(w, x)) : undefined;
    if (!twin) {
      out.push(w);
      continue;
    }
    used.add(twin.id);
    out.push({
      ...w,
      source: 'apple+whoop',
      sport: /^other$/i.test(w.sport) ? twin.sport : w.sport,
      energy_kcal: w.energy_kcal ?? twin.energy_kcal,
      distance_m: w.distance_m ?? twin.distance_m,
      avg_hr: w.avg_hr ?? twin.avg_hr,
      max_hr: Math.max(Number(w.max_hr ?? 0), Number(twin.max_hr ?? 0)) || null,
      strain: twin.strain,
    });
  }
  for (const x of whoop) if (!used.has(x.id)) out.push(x);
  return out.sort((a, b) => Date.parse(b.start) - Date.parse(a.start));
}

export async function trends(scope: Scope, hosted: boolean, metrics: string[], days: number, asOfParam?: string): Promise<Trends> {
  const { demo, today } = await requestContext(scope, hosted);
  const asOf = asOfParam ?? today;
  const from = addDays(asOf, -(days - 1));
  // A night's stages follow its sleep_hours decision (FOLLOWS), so that's read too even when not asked for:
  // without it, deep sleep alone would come from one device where the dashboard averages the two.
  const load = [...new Set([...metrics, ...metrics.flatMap((m) => (FOLLOWS[m] ? [FOLLOWS[m]] : []))])];
  const daily = await loadDaily(scope, demo, from, asOf, load);
  return Object.fromEntries(metrics.map((m) => [m, series({ daily, demo }, m, from, asOf)]));
}

export async function workouts(scope: Scope, hosted: boolean, days: number, asOfParam?: string): Promise<Workout[]> {
  const { demo, today } = await requestContext(scope, hosted);
  const asOf = asOfParam ?? today;
  return mergeWorkouts(await loadWorkouts(scope, demo, addDays(asOf, -(days - 1)), asOf));
}

// ---------- helpers ----------

export const mean = (xs: number[]) => (xs.length ? xs.reduce((a, b) => a + b, 0) / xs.length : null);

export function sd(xs: number[]) {
  const m = mean(xs);
  if (m === null || xs.length < 2) return null;
  return Math.sqrt(xs.reduce((a, x) => a + (x - m) ** 2, 0) / (xs.length - 1));
}

/**
 * The person's usual for a reading: the mean of the 30 days before it (from its own device, for OWN_BASELINE
 * metrics) and the band around it, one standard deviation but at least `minSpread`. Needs a week of history.
 */
function usualBand(ctx: Ctx, metric: string, l: Latest, minSpread: number) {
  const own = OWN_BASELINE.has(metric) ? fromSource(ctx, metric, l.source) : ctx;
  const history = series(own, metric, addDays(l.date, -30), addDays(l.date, -1)).map((p) => p.value);
  const m = mean(history);
  if (m === null || history.length < 7) return null;
  return { mean: m, band: Math.max(sd(history) ?? 0, minSpread) };
}

/** Compare a value with the 30 days before it (from its own device, for OWN_BASELINE metrics). Needs a week of history to say anything. */
export function rangeStatus(ctx: Ctx, metric: string, l: Latest | null, minSpread: number): RangeStatus | null {
  const u = l && usualBand(ctx, metric, l, minSpread);
  if (!l || !u) return null;
  if (l.value > u.mean + u.band) return 'high';
  if (l.value < u.mean - u.band) return 'low';
  return 'normal';
}

/** Status and level of a vital: normal inside the usual band (as the status), unusual beyond it, off beyond twice it. */
export function vitalRange(ctx: Ctx, metric: string, l: Latest | null, minSpread: number): Pick<Vital, 'status' | 'level'> {
  const u = l && usualBand(ctx, metric, l, minSpread);
  if (!l || !u) return { status: null, level: null };
  const status = l.value > u.mean + u.band ? 'high' : l.value < u.mean - u.band ? 'low' : 'normal';
  // From the status, so the colour and the words can't disagree at the edge of the band.
  const level = status === 'normal' ? 'normal' : Math.abs(l.value - u.mean) <= 2 * u.band ? 'unusual' : 'off';
  return { status, level };
}

function windowMean(points: Point[], from: string, to: string) {
  return mean(points.filter((p) => p.date >= from && p.date <= to).map((p) => p.value));
}

/** Of several ways to measure the same thing (HRV as RMSSD or SDNN, temperatures), the one measured most recently. */
export function pickMetric(ctx: Ctx, candidates: string[], asOf: string, lookback = 30) {
  let pick: { metric: string; latest: Latest | null } = { metric: candidates[0], latest: null };
  for (const m of candidates) {
    const l = latest(ctx, m, asOf, lookback);
    if (l && (!pick.latest || l.date > pick.latest.date)) pick = { metric: m, latest: l };
  }
  return pick;
}

function capitalize(s: string) {
  return s ? s[0].toUpperCase() + s.slice(1) : s;
}

// ---------- home summary ----------

/** Days of history the summary may look at: VO2 max reaches back 120 days, plus the month before it. */
const SUMMARY_WINDOW = 200;

export async function summary(scope: Scope, hosted: boolean, asOfParam?: string): Promise<Summary> {
  const { settings, demo, today } = await requestContext(scope, hosted);
  const asOf = asOfParam && asOfParam <= today ? asOfParam : today;
  const anchor = await latestDataDate(scope, demo, today);
  const insightEnd = anchor && anchor < asOf ? anchor : asOf;
  const from = addDays(insightEnd < asOf ? insightEnd : asOf, -SUMMARY_WINDOW);

  const [daily, recentWorkouts, sleepStarts, tl] = await Promise.all([
    loadDaily(scope, demo, from, asOf),
    loadWorkouts(scope, demo, addDays(asOf, -14), asOf),
    scope.db.query<{ date: string; start: string }>(
      "SELECT DISTINCT ON (date) date, start FROM events WHERE user_id = $1 AND kind = 'sleep' AND date BETWEEN $2 AND $3 AND source = ANY($4) ORDER BY date, start",
      [scope.userId, addDays(insightEnd, -13), insightEnd, sourceList(demo)],
    ),
    timeline(scope, demo, asOf),
  ]);
  const ctx: Ctx = { settings, demo, today, daily, workouts: mergeWorkouts(recentWorkouts), sleepStarts };

  const heart = latest(ctx, 'resting_hr', asOf);
  const breathing = latest(ctx, 'resp_rate', asOf);
  const temp = pickMetric(ctx, ['body_temp', 'wrist_temp', 'skin_temp'], asOf, 14);
  const tempLabel = { body_temp: 'Body temp', wrist_temp: 'Wrist temp', skin_temp: 'Skin temp' }[temp.metric] ?? 'Body temp';

  const vitals: Summary['vitals'] = {
    heart: { label: 'Resting heart', latest: heart, ...vitalRange(ctx, 'resting_hr', heart, 2) } satisfies Vital,
    breathing: { label: 'Breathing', latest: breathing, ...vitalRange(ctx, 'resp_rate', breathing, 0.5) },
    temp: { label: tempLabel, latest: temp.latest, ...vitalRange(ctx, temp.metric, temp.latest, 0.3) },
  };

  // Readiness: WHOOP recovery when there is one, else Apple's cardio fitness (VO2 max).
  let readiness: Summary['readiness'] = null;
  const rec = latest(ctx, 'recovery', asOf, 7);
  if (rec) {
    const avg = mean(series(ctx, 'recovery', addDays(rec.date, -30), addDays(rec.date, -1)).map((p) => p.value));
    readiness = { kind: 'recovery', latest: rec, average: avg, zone: rec.value >= 67 ? 'green' : rec.value >= 34 ? 'yellow' : 'red' };
  } else {
    const vo2 = latest(ctx, 'vo2max', asOf, 120);
    if (vo2) {
      const prev = latest(ctx, 'vo2max', addDays(vo2.date, -31), SUMMARY_WINDOW);
      readiness = { kind: 'vo2max', latest: vo2, previous: prev?.value ?? null };
    }
  }

  const spo2Latest = latest(ctx, 'spo2', asOf);
  const spo2 = { latest: spo2Latest, series: series(ctx, 'spo2', addDays(asOf, -29), asOf), status: rangeStatus(ctx, 'spo2', spo2Latest, 1) };

  const hrvPick = pickMetric(ctx, ['hrv_rmssd', 'hrv_sdnn'], asOf);
  const hrvSeries = series(ctx, hrvPick.metric, addDays(asOf, -20), asOf);
  const hrvHistory = hrvPick.latest ? series(ctx, hrvPick.metric, addDays(hrvPick.latest.date, -30), addDays(hrvPick.latest.date, -1)).map((p) => p.value) : [];
  const hrvBaseline = hrvPick.latest ? mean(hrvHistory) : null;
  const hrvSd = hrvPick.latest ? sd(hrvHistory) : null;
  let hrvStatus: Summary['hrv']['status'] = null;
  if (hrvPick.latest && hrvBaseline !== null) {
    const band = Math.max(hrvSd ?? 0, hrvBaseline * 0.05);
    hrvStatus = hrvPick.latest.value >= hrvBaseline ? 'optimal' : hrvPick.latest.value >= hrvBaseline - band ? 'normal' : 'low';
  }

  const sleepSeries = series(ctx, 'sleep_hours', addDays(asOf, -27), asOf);
  const sleepLatest = latest(ctx, 'sleep_hours', asOf, 7);
  const thisWeek = windowMean(sleepSeries, addDays(asOf, -6), asOf);
  const lastWeek = windowMean(sleepSeries, addDays(asOf, -13), addDays(asOf, -7));

  let load: Summary['load'] = null;
  const strain = latest(ctx, 'strain', asOf, 3);
  if (strain) {
    const s = series(ctx, 'strain', addDays(asOf, -13), asOf);
    load = { kind: 'strain', latest: strain, average: windowMean(s, addDays(strain.date, -7), addDays(strain.date, -1)), series: s };
  } else {
    const energy = latest(ctx, 'active_energy', asOf, 3);
    if (energy) {
      const s = series(ctx, 'active_energy', addDays(asOf, -13), asOf);
      load = { kind: 'energy', latest: energy, average: windowMean(s, addDays(energy.date, -7), addDays(energy.date, -1)), series: s };
    }
  }

  const heads = flags(ctx, asOf);

  return {
    date: asOf,
    today,
    latestDataDate: anchor,
    name: settings.name,
    demo,
    stepGoal: settings.stepGoal,
    vitals,
    readiness,
    spo2,
    hrv: { metric: hrvPick.metric as Summary['hrv']['metric'], latest: hrvPick.latest, series: hrvSeries, baseline: hrvBaseline, status: hrvStatus },
    sleep: { latest: sleepLatest, series: sleepSeries.slice(-14), change: thisWeek && lastWeek ? (thisWeek - lastWeek) / lastWeek : null },
    load,
    activity: { latest: latest(ctx, 'steps', asOf, 2), series: series(ctx, 'steps', addDays(asOf, -6), asOf) },
    timeline: tl,
    insights: anchor ? insights(ctx, insightEnd) : [],
    week: weekSummary(ctx, asOf),
    ...(heads.length ? { flags: heads } : {}),
  };
}

/** How far above the month before it a resting heart rate reading has to be to count as up. */
const RHR_UP_BPM = 5;
const TEMPS = ['body_temp', 'wrist_temp', 'skin_temp'];

/**
 * Resting heart rate well above the person's usual for days running, with or without a raised temperature.
 * "Readings" are days that have one, newest first, from the device behind the latest reading, and the baseline
 * is that device's too (see OWN_BASELINE). Nothing here looks at cycle data: Summary stays cycle-free.
 */
function flags(ctx: Ctx, asOf: string): Flag[] {
  const newest = latest(ctx, 'resting_hr', asOf, 4);
  if (!newest) return [];
  const own = fromSource(ctx, 'resting_hr', newest.source);
  const readings = series(own, 'resting_hr', addDays(asOf, -4), asOf).reverse();
  // The last `count` readings, the oldest of them on or after `since`, each 5 bpm or more over the mean of the
  // 30 days before the oldest (at least 14 values). Returns how far over they are on average, or null.
  const elevated = (count: number, since: string) => {
    const last = readings.slice(0, count);
    if (last.length < count || last[count - 1].date < since) return null;
    const first = last[count - 1].date;
    const history = series(own, 'resting_hr', addDays(first, -30), addDays(first, -1)).map((p) => p.value);
    const baseline = mean(history);
    if (baseline === null || history.length < 14 || last.some((p) => p.value < baseline + RHR_UP_BPM)) return null;
    return Math.round(mean(last.map((p) => p.value))! - baseline);
  };

  const temp = pickMetric(ctx, TEMPS, asOf, 2);
  const tempHigh = rangeStatus(ctx, temp.metric, temp.latest, 0.3) === 'high';
  const two = readings[0] && readings[0].date >= addDays(asOf, -2) ? elevated(2, addDays(asOf, -3)) : null;
  if (two !== null && tempHigh) {
    return [
      {
        id: 'rhr_temp',
        tone: 'caution',
        title: 'Your body may be under strain',
        text: `Resting heart rate has been about ${two} bpm above your usual for 2 days and your temperature is up. Your body may be fighting something or recovering from strain, so an easier day could help.`,
        page: 'vitals',
      },
    ];
  }
  const three = elevated(3, addDays(asOf, -4));
  if (three !== null) {
    return [
      {
        id: 'rhr_up',
        tone: 'info',
        title: 'Resting heart rate is up',
        text: `Resting heart rate has been about ${three} bpm above your usual for 3 days. Hard training, short sleep, stress or alcohol can all nudge it up, so an easier day may help.`,
        page: 'vitals',
      },
    ];
  }
  return [];
}

function weekSummary(ctx: Ctx, asOf: string): WeekSummary {
  const dow = (new Date(`${asOf}T00:00:00Z`).getUTCDay() + 6) % 7; // Monday = 0
  const start = addDays(asOf, -dow);
  const prevStart = addDays(start, -7);
  const prevEnd = addDays(asOf, -7);
  const pair = (metric: string) => {
    const s = series(ctx, metric, prevStart, asOf);
    return { avg: windowMean(s, start, asOf), prev: windowMean(s, prevStart, prevEnd) };
  };

  const steps = series(ctx, 'steps', prevStart, asOf);
  const thisWeekSteps = steps.filter((p) => p.date >= start);

  // Apple Health and WHOOP often log the same session; count one when two start within 10 minutes.
  const sessions = ctx.workouts.filter((w) => w.date >= start && w.date <= asOf).sort((a, b) => Date.parse(a.start) - Date.parse(b.start));
  const counted: Workout[] = [];
  for (const w of sessions) {
    if (!counted.some((c) => Math.abs(Date.parse(c.start) - Date.parse(w.start)) < 10 * 60_000)) counted.push(w);
  }

  return {
    start,
    end: asOf,
    days: dow + 1,
    sleep: pair('sleep_hours'),
    steps: {
      avg: windowMean(steps, start, asOf),
      prev: windowMean(steps, prevStart, prevEnd),
      goalDays: thisWeekSteps.filter((p) => p.value >= ctx.settings.stepGoal).length,
      daysWithData: thisWeekSteps.length,
    },
    workouts: { count: counted.length, minutes: counted.reduce((a, w) => a + Number(w.duration_min), 0) },
    hrv: pair(pickMetric(ctx, ['hrv_rmssd', 'hrv_sdnn'], asOf).metric),
    restingHr: pair('resting_hr'),
    recovery: pair('recovery'),
  };
}

async function timeline(scope: Scope, demo: boolean, asOf: string): Promise<Summary['timeline']> {
  const sources = sourceList(demo);
  const { db, userId } = scope;
  // Show the chosen day, or the most recent day that has anything on it.
  const [row] = await db.query<{ d: string | null }>(
    `SELECT MAX(date) AS d FROM (SELECT date FROM events WHERE user_id = $1 AND source = ANY($2) AND date <= $3
     UNION ALL SELECT date FROM workouts WHERE user_id = $1 AND source = ANY($2) AND date <= $3) AS days`,
    [userId, sources, asOf],
  );
  const day = row?.d ?? asOf;

  const [events, rawWorkouts] = await Promise.all([
    db.query<TimelineEvent>('SELECT id, kind, title, start, "end" FROM events WHERE user_id = $1 AND date = $2 AND source = ANY($3)', [userId, day, sources]),
    db.query<Workout>(`SELECT ${WORKOUT_FIELDS} FROM workouts WHERE user_id = $1 AND date = $2 AND source = ANY($3)`, [userId, day, sources]),
  ]);
  const ws = mergeWorkouts(rawWorkouts);

  // Apple and WHOOP often both record the same session; keep one when two start within 10 minutes.
  const merged: TimelineEvent[] = [];
  for (const e of [
    ...events.map((e) => ({ ...e })),
    ...ws.map((w) => ({
      id: w.id,
      kind: 'workout' as const,
      title: w.sport,
      start: w.start,
      end: w.end,
      detail: w.strain ? `Strain ${Number(w.strain).toFixed(1)}` : w.energy_kcal ? `${Math.round(Number(w.energy_kcal))} kcal` : undefined,
    })),
  ].sort((a, b) => Date.parse(a.start) - Date.parse(b.start))) {
    const dup = merged.find((m) => m.kind === e.kind && Math.abs(Date.parse(m.start) - Date.parse(e.start)) < 10 * 60_000);
    if (!dup) merged.push(e);
  }
  return { date: day, events: merged };
}

function insights(ctx: Ctx, end: string): Insight[] {
  const out: (Insight & { weight: number })[] = [];
  const weekly = (metric: string) => {
    const s = series(ctx, metric, addDays(end, -13), end);
    const a = windowMean(s, addDays(end, -6), end);
    const b = windowMean(s, addDays(end, -13), addDays(end, -7));
    return a !== null && b !== null ? { now: a, before: b } : null;
  };

  const hrvMetric = pickMetric(ctx, ['hrv_rmssd', 'hrv_sdnn'], end).metric;
  const hrv = weekly(hrvMetric);
  if (hrv) {
    const pct = (hrv.now - hrv.before) / hrv.before;
    if (Math.abs(pct) >= 0.04) {
      out.push({
        id: 'hrv',
        icon: pct > 0 ? 'trend-up' : 'trend-down',
        text: pct > 0 ? `HRV is up ${Math.round(pct * 100)}% in the last 7 days` : `HRV is down ${Math.round(-pct * 100)}% in the last 7 days`,
        date: end,
        page: 'vitals',
        weight: Math.abs(pct) * 3,
      });
    }
  }

  const sleep = weekly('sleep_hours');
  if (sleep) {
    const diffMin = Math.round((sleep.now - sleep.before) * 60);
    if (Math.abs(diffMin) >= 10) {
      out.push({
        id: 'sleep',
        icon: 'moon',
        text: diffMin > 0 ? `${diffMin} min more sleep a night in the last 7 days` : `${-diffMin} min less sleep a night in the last 7 days`,
        date: end,
        page: 'sleep',
        weight: Math.abs(diffMin) / 60,
      });
    }
  }

  const rhr = weekly('resting_hr');
  if (rhr) {
    const diff = rhr.now - rhr.before;
    if (Math.abs(diff) >= 1) {
      out.push({
        id: 'rhr',
        icon: diff < 0 ? 'heart' : 'shield',
        text: diff < 0 ? `Resting heart rate down ${Math.abs(diff).toFixed(1)} bpm in the last 7 days` : `Resting heart rate up ${diff.toFixed(1)} bpm in the last 7 days`,
        date: end,
        page: 'vitals',
        weight: Math.abs(diff) / 3,
      });
    } else {
      out.push({ id: 'rhr', icon: 'shield', text: 'Resting heart rate is holding steady', date: end, page: 'vitals', weight: 0.15 });
    }
  }

  if (ctx.sleepStarts.length >= 7) {
    // Minutes after 18:00 local, so 23:30 and 00:30 sit next to each other.
    const mins = ctx.sleepStarts.map(({ start }) => {
      const [h, m] = start.slice(11, 16).split(':').map(Number);
      return ((h - 18 + 24) % 24) * 60 + m;
    });
    const spread = sd(mins) ?? 0;
    const avg = mean(mins)!;
    const avgClock = (Math.round(avg) + 18 * 60) % (24 * 60);
    const clock = `${String(Math.floor(avgClock / 60)).padStart(2, '0')}:${String(avgClock % 60).padStart(2, '0')}`;
    out.push(
      spread > 40
        ? { id: 'bedtime', icon: 'sun', text: `Bedtime varies by ±${Math.round(spread)} min; try a steadier ${clock}`, date: end, page: 'sleep', weight: spread / 90 }
        : { id: 'bedtime', icon: 'moon', text: `Consistent bedtime around ${clock}`, date: end, page: 'sleep', weight: 0.2 },
    );
  }

  const steps = series(ctx, 'steps', addDays(end, -6), end);
  if (steps.length >= 4) {
    const hit = steps.filter((p) => p.value >= ctx.settings.stepGoal).length;
    const avgSteps = Math.round(mean(steps.map((p) => p.value))! / 100) * 100;
    out.push({
      id: 'steps',
      icon: 'steps',
      text: hit > 0 ? `Step goal reached ${hit} of the last ${steps.length} days` : `Averaging ${avgSteps.toLocaleString('en-US')} steps a day over the last 7 days`,
      date: end,
      page: 'activity',
      weight: 0.3,
    });
  }

  const rec = series(ctx, 'recovery', addDays(end, -6), end);
  if (rec.length >= 4) {
    const green = rec.filter((p) => p.value >= 67).length;
    if (green >= 3) out.push({ id: 'recovery', icon: 'shield', text: `${green} green recoveries in the last ${rec.length} days`, date: end, page: 'vitals', weight: green / 7 });
  }

  return out
    .sort((a, b) => b.weight - a.weight)
    .slice(0, 4)
    .map(({ weight: _w, ...i }) => i);
}
