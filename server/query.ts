import os from 'node:os';
import type { Insight, Latest, Point, RangeStatus, Settings, Summary, TimelineEvent, Trends, Vital, WeekSummary, Workout } from '../shared/types.ts';
import { type Queryable, getSettings } from './db.ts';
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

export function settingsFrom(map: Map<string, string>, hosted: boolean): Settings {
  // Hosted, the OS user is the platform's sandbox account, so don't guess a name from it.
  const fallbackName = hosted ? '' : capitalize(os.userInfo().username);
  return {
    name: map.get('name') || map.get('whoop_first_name') || fallbackName,
    stepGoal: Number(map.get('step_goal')) || 10_000,
    units: map.get('units') === 'imperial' ? 'imperial' : 'metric',
    demo: (map.get('demo') as Settings['demo']) || 'auto',
    timeZone: map.get('timezone') ?? null,
  };
}

export async function readSettings(q: Queryable, hosted = false) {
  return settingsFrom(await getSettings(q), hosted);
}

export async function hasRealData(q: Queryable) {
  const [row] = await q.query<{ any: boolean }>("SELECT EXISTS (SELECT 1 FROM daily WHERE source IN ('apple', 'whoop')) AS any");
  return Boolean(row?.any);
}

/** Demo rows only ever exist in a local database, so the hosted app never shows them. */
export async function demoActive(q: Queryable, settings: Settings, hosted: boolean) {
  if (hosted) return false;
  return settings.demo === 'on' || (settings.demo === 'auto' && !(await hasRealData(q)));
}

const sourceList = (demo: boolean) => (demo ? ['demo'] : ['apple', 'whoop']);

function sourcesFor(ctx: { demo: boolean }, metric: string): string[] {
  if (ctx.demo) return ['demo'];
  return APPLE_FIRST.has(metric) ? ['apple', 'whoop'] : ['whoop', 'apple'];
}

async function loadDaily(q: Queryable, demo: boolean, from: string, to: string, metrics?: string[]): Promise<DailyIndex> {
  const sources = sourceList(demo);
  const params: unknown[] = [from, to, sources];
  let filter = '';
  if (metrics) {
    params.push(metrics);
    filter = 'AND metric = ANY($4)';
  }
  const rows = await q.query<{ date: string; metric: string; source: string; value: number }>(
    `SELECT date, metric, source, value FROM daily WHERE date BETWEEN $1 AND $2 AND source = ANY($3) ${filter}`,
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

async function latestDataDate(q: Queryable, demo: boolean, today: string): Promise<string | null> {
  const [row] = await q.query<{ d: string | null }>('SELECT MAX(date) AS d FROM daily WHERE source = ANY($1) AND date <= $2', [sourceList(demo), today]);
  return row?.d ?? null;
}

async function loadWorkouts(q: Queryable, demo: boolean, from: string, to: string): Promise<Workout[]> {
  return q.query<Workout>('SELECT * FROM workouts WHERE date BETWEEN $1 AND $2 AND source = ANY($3) ORDER BY start DESC', [from, to, sourceList(demo)]);
}

export async function requestContext(q: Queryable, hosted: boolean) {
  const settings = await readSettings(q, hosted);
  const demo = await demoActive(q, settings, hosted);
  return { settings, demo, today: todayLocal(settings.timeZone ?? undefined) };
}

// ---------- series over the snapshot ----------

/** Daily values for a metric, one per date, taken from the preferred source that has that day. */
export function series(ctx: Pick<Ctx, 'daily' | 'demo'>, metric: string, from: string, to: string): Point[] {
  const bySource = ctx.daily.get(metric);
  if (!bySource) return [];
  const sources = sourcesFor(ctx, metric);
  const dates = new Set<string>();
  for (const s of sources) for (const d of bySource.get(s)?.keys() ?? []) if (d >= from && d <= to) dates.add(d);
  return [...dates].sort().map((date) => {
    const value = sources.map((s) => bySource.get(s)?.get(date)).find((v) => v !== undefined)!;
    return { date, value };
  });
}

/**
 * The most recent value within the lookback window, from any source. Source preference only breaks
 * ties on the same day, so a stale reading from the preferred source never hides a fresher one
 * (e.g. a WHOOP left in a drawer while the Apple Watch keeps recording).
 */
export function latest(ctx: Pick<Ctx, 'daily' | 'demo'>, metric: string, asOf: string, lookbackDays = 14): Latest | null {
  const bySource = ctx.daily.get(metric);
  if (!bySource) return null;
  const from = addDays(asOf, -lookbackDays);
  let best: Latest | null = null;
  let bestRank = Infinity;
  sourcesFor(ctx, metric).forEach((source, rank) => {
    for (const [date, value] of bySource.get(source) ?? []) {
      if (date < from || date > asOf) continue;
      if (!best || date > best.date || (date === best.date && rank < bestRank)) {
        best = { date, value, source };
        bestRank = rank;
      }
    }
  });
  return best;
}

export async function trends(q: Queryable, hosted: boolean, metrics: string[], days: number, asOfParam?: string): Promise<Trends> {
  const { demo, today } = await requestContext(q, hosted);
  const asOf = asOfParam ?? today;
  const from = addDays(asOf, -(days - 1));
  const daily = await loadDaily(q, demo, from, asOf, metrics);
  return Object.fromEntries(metrics.map((m) => [m, series({ daily, demo }, m, from, asOf)]));
}

export async function workouts(q: Queryable, hosted: boolean, days: number, asOfParam?: string): Promise<Workout[]> {
  const { demo, today } = await requestContext(q, hosted);
  const asOf = asOfParam ?? today;
  return loadWorkouts(q, demo, addDays(asOf, -(days - 1)), asOf);
}

// ---------- helpers ----------

const mean = (xs: number[]) => (xs.length ? xs.reduce((a, b) => a + b, 0) / xs.length : null);

function sd(xs: number[]) {
  const m = mean(xs);
  if (m === null || xs.length < 2) return null;
  return Math.sqrt(xs.reduce((a, x) => a + (x - m) ** 2, 0) / (xs.length - 1));
}

/** Compare a value with the 30 days before it. Needs a week of history to say anything. */
function rangeStatus(ctx: Ctx, metric: string, l: Latest | null, minSpread: number): RangeStatus | null {
  if (!l) return null;
  const history = series(ctx, metric, addDays(l.date, -30), addDays(l.date, -1)).map((p) => p.value);
  const m = mean(history);
  if (m === null || history.length < 7) return null;
  const band = Math.max(sd(history) ?? 0, minSpread);
  if (l.value > m + band) return 'high';
  if (l.value < m - band) return 'low';
  return 'normal';
}

function windowMean(points: Point[], from: string, to: string) {
  return mean(points.filter((p) => p.date >= from && p.date <= to).map((p) => p.value));
}

/** Of several ways to measure the same thing (HRV as RMSSD or SDNN, temperatures), the one measured most recently. */
function pickMetric(ctx: Ctx, candidates: string[], asOf: string, lookback = 30) {
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

export async function summary(q: Queryable, hosted: boolean, asOfParam?: string): Promise<Summary> {
  const { settings, demo, today } = await requestContext(q, hosted);
  const asOf = asOfParam && asOfParam <= today ? asOfParam : today;
  const anchor = await latestDataDate(q, demo, today);
  const insightEnd = anchor && anchor < asOf ? anchor : asOf;
  const from = addDays(insightEnd < asOf ? insightEnd : asOf, -SUMMARY_WINDOW);

  const [daily, recentWorkouts, sleepStarts, tl] = await Promise.all([
    loadDaily(q, demo, from, asOf),
    loadWorkouts(q, demo, addDays(asOf, -14), asOf),
    q.query<{ date: string; start: string }>(
      "SELECT DISTINCT ON (date) date, start FROM events WHERE kind = 'sleep' AND date BETWEEN $1 AND $2 AND source = ANY($3) ORDER BY date, start",
      [addDays(insightEnd, -13), insightEnd, sourceList(demo)],
    ),
    timeline(q, demo, asOf),
  ]);
  const ctx: Ctx = { settings, demo, today, daily, workouts: recentWorkouts, sleepStarts };

  const heart = latest(ctx, 'resting_hr', asOf);
  const breathing = latest(ctx, 'resp_rate', asOf);
  const temp = pickMetric(ctx, ['body_temp', 'wrist_temp', 'skin_temp'], asOf, 14);
  const tempLabel = { body_temp: 'Body temp', wrist_temp: 'Wrist temp', skin_temp: 'Skin temp' }[temp.metric] ?? 'Body temp';

  const vitals: Summary['vitals'] = {
    heart: { label: 'Resting heart', latest: heart, status: rangeStatus(ctx, 'resting_hr', heart, 2) } satisfies Vital,
    breathing: { label: 'Breathing', latest: breathing, status: rangeStatus(ctx, 'resp_rate', breathing, 0.5) },
    temp: { label: tempLabel, latest: temp.latest, status: rangeStatus(ctx, temp.metric, temp.latest, 0.3) },
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
  };
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

async function timeline(q: Queryable, demo: boolean, asOf: string): Promise<Summary['timeline']> {
  const sources = sourceList(demo);
  // Show the chosen day, or the most recent day that has anything on it.
  const [row] = await q.query<{ d: string | null }>(
    `SELECT MAX(date) AS d FROM (SELECT date FROM events WHERE source = ANY($1) AND date <= $2
     UNION ALL SELECT date FROM workouts WHERE source = ANY($1) AND date <= $2) AS days`,
    [sources, asOf],
  );
  const day = row?.d ?? asOf;

  const [events, ws] = await Promise.all([
    q.query<TimelineEvent>('SELECT id, kind, title, start, "end" FROM events WHERE date = $1 AND source = ANY($2)', [day, sources]),
    q.query<{ id: string; sport: string; start: string; end: string; energy_kcal: number | null; strain: number | null }>(
      'SELECT id, sport, start, "end", energy_kcal, strain FROM workouts WHERE date = $1 AND source = ANY($2)',
      [day, sources],
    ),
  ]);

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
