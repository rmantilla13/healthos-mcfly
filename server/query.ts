import os from 'node:os';
import type { Insight, Latest, Point, RangeStatus, Settings, Summary, TimelineEvent, Trends, Vital, Workout } from '../shared/types.ts';
import { type Db, getSetting } from './db.ts';
import { addDays, todayLocal } from './dates.ts';

// Which source wins when more than one has a value for the same day.
// WHOOP is worn overnight so it leads on recovery-type metrics; the iPhone and Watch lead on movement and body.
const APPLE_FIRST = new Set(['steps', 'active_energy', 'exercise_min', 'distance_km', 'weight', 'body_fat', 'lean_mass', 'vo2max', 'hr_avg', 'hr_min', 'hr_max']);

export function readSettings(db: Db): Settings {
  const name = getSetting(db, 'name') || getSetting(db, 'whoop_first_name') || capitalize(os.userInfo().username);
  return {
    name,
    stepGoal: Number(getSetting(db, 'step_goal')) || 10_000,
    units: getSetting(db, 'units') === 'imperial' ? 'imperial' : 'metric',
    demo: (getSetting(db, 'demo') as Settings['demo']) || 'auto',
  };
}

export function hasRealData(db: Db) {
  return Boolean(db.prepare("SELECT 1 FROM daily WHERE source IN ('apple', 'whoop') LIMIT 1").get());
}

export function demoActive(db: Db) {
  const mode = readSettings(db).demo;
  return mode === 'on' || (mode === 'auto' && !hasRealData(db));
}

function sourcesFor(db: Db, metric: string): string[] {
  if (demoActive(db)) return ['demo'];
  return APPLE_FIRST.has(metric) ? ['apple', 'whoop'] : ['whoop', 'apple'];
}

/** Daily values for a metric, one per date, taken from the preferred source that has that day. */
export function series(db: Db, metric: string, from: string, to: string): Point[] {
  const sources = sourcesFor(db, metric);
  const rows = db
    .prepare(
      `SELECT date, source, value FROM daily WHERE metric = ? AND date BETWEEN ? AND ? AND source IN (${sources.map(() => '?').join(',')}) ORDER BY date`,
    )
    .all(metric, from, to, ...sources) as { date: string; source: string; value: number }[];
  const best = new Map<string, { rank: number; value: number }>();
  for (const r of rows) {
    const rank = sources.indexOf(r.source);
    const cur = best.get(r.date);
    if (!cur || rank < cur.rank) best.set(r.date, { rank, value: r.value });
  }
  return [...best].map(([date, { value }]) => ({ date, value }));
}

export function latest(db: Db, metric: string, asOf: string, lookbackDays = 14): Latest | null {
  const sources = sourcesFor(db, metric);
  for (const source of sources) {
    const row = db
      .prepare('SELECT date, value FROM daily WHERE metric = ? AND source = ? AND date BETWEEN ? AND ? ORDER BY date DESC LIMIT 1')
      .get(metric, source, addDays(asOf, -lookbackDays), asOf) as { date: string; value: number } | undefined;
    if (row) return { ...row, source };
  }
  return null;
}

export function trends(db: Db, metrics: string[], days: number, asOf: string): Trends {
  const from = addDays(asOf, -(days - 1));
  return Object.fromEntries(metrics.map((m) => [m, series(db, m, from, asOf)]));
}

export function workouts(db: Db, days: number, asOf: string): Workout[] {
  const sources = demoActive(db) ? ['demo'] : ['apple', 'whoop'];
  return db
    .prepare(`SELECT * FROM workouts WHERE date BETWEEN ? AND ? AND source IN (${sources.map(() => '?').join(',')}) ORDER BY start DESC`)
    .all(addDays(asOf, -(days - 1)), asOf, ...sources) as Workout[];
}

export function latestDataDate(db: Db): string | null {
  const sources = demoActive(db) ? ['demo'] : ['apple', 'whoop'];
  const row = db
    .prepare(`SELECT MAX(date) d FROM daily WHERE source IN (${sources.map(() => '?').join(',')}) AND date <= ?`)
    .get(...sources, todayLocal()) as { d: string | null };
  return row.d;
}

// ---------- helpers ----------

const mean = (xs: number[]) => (xs.length ? xs.reduce((a, b) => a + b, 0) / xs.length : null);

function sd(xs: number[]) {
  const m = mean(xs);
  if (m === null || xs.length < 2) return null;
  return Math.sqrt(xs.reduce((a, x) => a + (x - m) ** 2, 0) / (xs.length - 1));
}

/** Compare a value with the 30 days before it. Needs a week of history to say anything. */
function rangeStatus(db: Db, metric: string, l: Latest | null, minSpread: number): RangeStatus | null {
  if (!l) return null;
  const history = series(db, metric, addDays(l.date, -30), addDays(l.date, -1)).map((p) => p.value);
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

function pickMetric(db: Db, candidates: string[], asOf: string, lookback = 30) {
  for (const m of candidates) {
    const l = latest(db, m, asOf, lookback);
    if (l) return { metric: m, latest: l };
  }
  return { metric: candidates[0], latest: null };
}

function capitalize(s: string) {
  return s ? s[0].toUpperCase() + s.slice(1) : s;
}

// ---------- home summary ----------

export function summary(db: Db, asOfParam?: string): Summary {
  const today = todayLocal();
  const settings = readSettings(db);
  const asOf = asOfParam && asOfParam <= today ? asOfParam : today;

  const heart = latest(db, 'resting_hr', asOf);
  const breathing = latest(db, 'resp_rate', asOf);
  const temp = pickMetric(db, ['body_temp', 'wrist_temp', 'skin_temp'], asOf, 14);
  const tempLabel = { body_temp: 'Body temp', wrist_temp: 'Wrist temp', skin_temp: 'Skin temp' }[temp.metric] ?? 'Body temp';

  const vitals: Summary['vitals'] = {
    heart: { label: 'Resting heart', latest: heart, status: rangeStatus(db, 'resting_hr', heart, 2) } satisfies Vital,
    breathing: { label: 'Breathing', latest: breathing, status: rangeStatus(db, 'resp_rate', breathing, 0.5) },
    temp: { label: tempLabel, latest: temp.latest, status: rangeStatus(db, temp.metric, temp.latest, 0.3) },
  };

  // Readiness: WHOOP recovery when there is one, else Apple's cardio fitness (VO2 max).
  let readiness: Summary['readiness'] = null;
  const rec = latest(db, 'recovery', asOf, 7);
  if (rec) {
    const avg = mean(series(db, 'recovery', addDays(rec.date, -30), addDays(rec.date, -1)).map((p) => p.value));
    readiness = { kind: 'recovery', latest: rec, average: avg, zone: rec.value >= 67 ? 'green' : rec.value >= 34 ? 'yellow' : 'red' };
  } else {
    const vo2 = latest(db, 'vo2max', asOf, 120);
    if (vo2) {
      const prev = db
        .prepare(`SELECT value FROM daily WHERE metric = 'vo2max' AND source = ? AND date < ? ORDER BY date DESC LIMIT 1`)
        .get(vo2.source, addDays(vo2.date, -30)) as { value: number } | undefined;
      readiness = { kind: 'vo2max', latest: vo2, previous: prev?.value ?? null };
    }
  }

  const spo2Latest = latest(db, 'spo2', asOf);
  const spo2 = { latest: spo2Latest, series: series(db, 'spo2', addDays(asOf, -29), asOf), status: rangeStatus(db, 'spo2', spo2Latest, 1) };

  const hrvPick = pickMetric(db, ['hrv_rmssd', 'hrv_sdnn'], asOf);
  const hrvSeries = series(db, hrvPick.metric, addDays(asOf, -20), asOf);
  const hrvBaseline = hrvPick.latest ? mean(series(db, hrvPick.metric, addDays(hrvPick.latest.date, -30), addDays(hrvPick.latest.date, -1)).map((p) => p.value)) : null;
  const hrvSd = hrvPick.latest ? sd(series(db, hrvPick.metric, addDays(hrvPick.latest.date, -30), addDays(hrvPick.latest.date, -1)).map((p) => p.value)) : null;
  let hrvStatus: Summary['hrv']['status'] = null;
  if (hrvPick.latest && hrvBaseline !== null) {
    const band = Math.max(hrvSd ?? 0, hrvBaseline * 0.05);
    hrvStatus = hrvPick.latest.value >= hrvBaseline ? 'optimal' : hrvPick.latest.value >= hrvBaseline - band ? 'normal' : 'low';
  }

  const sleepSeries = series(db, 'sleep_hours', addDays(asOf, -27), asOf);
  const sleepLatest = latest(db, 'sleep_hours', asOf, 7);
  const thisWeek = windowMean(sleepSeries, addDays(asOf, -6), asOf);
  const lastWeek = windowMean(sleepSeries, addDays(asOf, -13), addDays(asOf, -7));

  let load: Summary['load'] = null;
  const strain = latest(db, 'strain', asOf, 3);
  if (strain) {
    const s = series(db, 'strain', addDays(asOf, -13), asOf);
    load = { kind: 'strain', latest: strain, average: windowMean(s, addDays(strain.date, -7), addDays(strain.date, -1)), series: s };
  } else {
    const energy = latest(db, 'active_energy', asOf, 3);
    if (energy) {
      const s = series(db, 'active_energy', addDays(asOf, -13), asOf);
      load = { kind: 'energy', latest: energy, average: windowMean(s, addDays(energy.date, -7), addDays(energy.date, -1)), series: s };
    }
  }

  return {
    date: asOf,
    today,
    latestDataDate: latestDataDate(db),
    name: settings.name,
    demo: demoActive(db),
    stepGoal: settings.stepGoal,
    vitals,
    readiness,
    spo2,
    hrv: { metric: hrvPick.metric as Summary['hrv']['metric'], latest: hrvPick.latest, series: hrvSeries, baseline: hrvBaseline, status: hrvStatus },
    sleep: { latest: sleepLatest, series: sleepSeries.slice(-14), change: thisWeek && lastWeek ? (thisWeek - lastWeek) / lastWeek : null },
    load,
    activity: { latest: latest(db, 'steps', asOf, 2), series: series(db, 'steps', addDays(asOf, -6), asOf) },
    timeline: timeline(db, asOf),
    insights: insights(db, asOf, settings),
  };
}

function timeline(db: Db, asOf: string): Summary['timeline'] {
  const sources = demoActive(db) ? ['demo'] : ['apple', 'whoop'];
  const inList = sources.map(() => '?').join(',');
  // Show the chosen day, or the most recent day that has anything on it.
  const day =
    (
      db
        .prepare(
          `SELECT MAX(date) d FROM (SELECT date FROM events WHERE source IN (${inList}) AND date <= ?
           UNION ALL SELECT date FROM workouts WHERE source IN (${inList}) AND date <= ?)`,
        )
        .get(...sources, asOf, ...sources, asOf) as { d: string | null }
    ).d ?? asOf;

  const events = db.prepare(`SELECT id, kind, title, start, end FROM events WHERE date = ? AND source IN (${inList})`).all(day, ...sources) as TimelineEvent[];
  const ws = db
    .prepare(`SELECT id, sport, start, end, energy_kcal, strain FROM workouts WHERE date = ? AND source IN (${inList})`)
    .all(day, ...sources) as { id: string; sport: string; start: string; end: string; energy_kcal: number | null; strain: number | null }[];

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
      detail: w.strain ? `Strain ${w.strain.toFixed(1)}` : w.energy_kcal ? `${Math.round(w.energy_kcal)} kcal` : undefined,
    })),
  ].sort((a, b) => Date.parse(a.start) - Date.parse(b.start))) {
    const dup = merged.find((m) => m.kind === e.kind && Math.abs(Date.parse(m.start) - Date.parse(e.start)) < 10 * 60_000);
    if (!dup) merged.push(e);
  }
  return { date: day, events: merged };
}

function insights(db: Db, asOf: string, settings: Settings): Insight[] {
  const anchor = latestDataDate(db);
  if (!anchor) return [];
  const end = anchor < asOf ? anchor : asOf;
  const out: (Insight & { weight: number })[] = [];
  const weekly = (metric: string) => {
    const s = series(db, metric, addDays(end, -13), end);
    const a = windowMean(s, addDays(end, -6), end);
    const b = windowMean(s, addDays(end, -13), addDays(end, -7));
    return a !== null && b !== null ? { now: a, before: b } : null;
  };

  const hrvMetric = pickMetric(db, ['hrv_rmssd', 'hrv_sdnn'], end).metric;
  const hrv = weekly(hrvMetric);
  if (hrv) {
    const pct = (hrv.now - hrv.before) / hrv.before;
    if (Math.abs(pct) >= 0.04) {
      out.push({
        id: 'hrv',
        icon: pct > 0 ? 'trend-up' : 'trend-down',
        text: pct > 0 ? `Your HRV has improved by ${Math.round(pct * 100)}%` : `Your HRV is down ${Math.round(-pct * 100)}% this week`,
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
        text: diffMin > 0 ? `You slept ${diffMin} min more per night this week` : `You slept ${-diffMin} min less per night this week`,
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
        text: diff < 0 ? `Resting heart rate is down ${Math.abs(diff).toFixed(1)} bpm` : `Resting heart rate is up ${diff.toFixed(1)} bpm this week`,
        date: end,
        page: 'vitals',
        weight: Math.abs(diff) / 3,
      });
    } else {
      out.push({ id: 'rhr', icon: 'shield', text: 'Resting heart rate is holding steady', date: end, page: 'vitals', weight: 0.15 });
    }
  }

  const sleepEvents = db
    .prepare(
      `SELECT start FROM events WHERE kind = 'sleep' AND date BETWEEN ? AND ? AND source IN (${demoActive(db) ? "'demo'" : "'apple','whoop'"}) GROUP BY date`,
    )
    .all(addDays(end, -13), end) as { start: string }[];
  if (sleepEvents.length >= 7) {
    // Minutes after 18:00 local, so 23:30 and 00:30 sit next to each other.
    const mins = sleepEvents.map(({ start }) => {
      const [h, m] = start.slice(11, 16).split(':').map(Number);
      return (((h - 18 + 24) % 24) * 60 + m);
    });
    const spread = sd(mins) ?? 0;
    const avg = mean(mins)!;
    const avgClock = ((Math.round(avg) + 18 * 60) % (24 * 60));
    const clock = `${String(Math.floor(avgClock / 60)).padStart(2, '0')}:${String(avgClock % 60).padStart(2, '0')}`;
    out.push(
      spread > 40
        ? { id: 'bedtime', icon: 'sun', text: `Bedtime varies by ±${Math.round(spread)} min; try a steadier ${clock}`, date: end, page: 'sleep', weight: spread / 90 }
        : { id: 'bedtime', icon: 'moon', text: `Consistent bedtime around ${clock}`, date: end, page: 'sleep', weight: 0.2 },
    );
  }

  const steps = series(db, 'steps', addDays(end, -6), end);
  if (steps.length >= 4) {
    const hit = steps.filter((p) => p.value >= settings.stepGoal).length;
    const avgSteps = Math.round(mean(steps.map((p) => p.value))! / 100) * 100;
    out.push({
      id: 'steps',
      icon: 'steps',
      text: hit > 0 ? `Step goal reached ${hit} of the last ${steps.length} days` : `Averaging ${avgSteps.toLocaleString('en-US')} steps a day this week`,
      date: end,
      page: 'activity',
      weight: 0.3,
    });
  }

  const rec = series(db, 'recovery', addDays(end, -6), end);
  if (rec.length >= 4) {
    const green = rec.filter((p) => p.value >= 67).length;
    if (green >= 3) out.push({ id: 'recovery', icon: 'shield', text: `${green} green recoveries in the last ${rec.length} days`, date: end, page: 'vitals', weight: green / 7 });
  }

  return out
    .sort((a, b) => b.weight - a.weight)
    .slice(0, 4)
    .map(({ weight: _w, ...i }) => i);
}
