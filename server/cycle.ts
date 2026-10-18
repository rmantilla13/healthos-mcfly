// Cycle tracking (/api/cycle): menstrual flow, spotting, ovulation tests, cervical mucus, basal body
// temperature and sexual activity, from Apple Health and from logging by hand, with estimates of the next
// period and fertile window from the person's own history. This is reproductive-health data, so:
// - It has its own table, never `daily`: summaries, the admin view and McFly's metric list can't reach it.
// - Apple Health's records are stored even while tracking is off, hidden. Every read checks the person's
//   cycle_tracking setting first.
// - Nothing here logs values or errors' text, and dates travel in request bodies, never in URLs.
import express, { type NextFunction, type Request, type Response } from 'express';
import type { CervicalMucus, CycleData, CycleDay, CycleEstimate, CycleFields, CycleLogDay, CyclePhase, Flow, OvulationTest, SexualActivity } from '../shared/types.ts';
import { currentUser } from './auth.ts';
import { addDays } from './dates.ts';
import { type Db, type Queryable, type Scope, bumpDataVersion } from './db.ts';
import { requestContext } from './query.ts';
import { insertMany } from './store.ts';

export type CycleKind = 'flow' | 'period_start' | 'spotting' | 'ovulation_test' | 'mucus' | 'bbt' | 'sexual_activity';

/** One stored value: a choice from the lists below, '1' for period_start and spotting, °C for bbt. */
export type CycleRow = { date: string; kind: CycleKind; source: string; value: string };

/** Manual entries; Apple Health's are 'apple'. */
export const MANUAL = 'manual';

// Each list runs from least to most: when one day has two records of the same kind (two flow logs, two
// tests), the later in the list wins.
export const FLOWS: readonly Flow[] = ['none', 'unspecified', 'light', 'medium', 'heavy'];
export const OVULATION_TESTS: readonly OvulationTest[] = ['negative', 'indeterminate', 'estrogen_surge', 'lh_surge'];
export const MUCUS: readonly CervicalMucus[] = ['dry', 'sticky', 'creamy', 'watery', 'egg_white'];
export const SEXUAL_ACTIVITY: readonly SexualActivity[] = ['protected', 'unspecified', 'unprotected'];

const RANKED: Partial<Record<CycleKind, readonly string[]>> = { flow: FLOWS, ovulation_test: OVULATION_TESTS, mucus: MUCUS, sexual_activity: SEXUAL_ACTIVITY };

/** Plausible basal body temperatures, °C. */
const BBT_RANGE = [34, 40] as const;

// ---------- rows and days ----------

export function toRows(day: CycleDay, source: string): CycleRow[] {
  const rows: CycleRow[] = [];
  const add = (kind: CycleKind, value: string) => rows.push({ date: day.date, kind, source, value });
  if (day.flow) add('flow', day.flow);
  if (day.periodStart) add('period_start', '1');
  if (day.spotting) add('spotting', '1');
  if (day.ovulationTest) add('ovulation_test', day.ovulationTest);
  if (day.mucus) add('mucus', day.mucus);
  if (day.bbt !== undefined) add('bbt', String(Math.round(day.bbt * 100) / 100));
  if (day.sexualActivity) add('sexual_activity', day.sexualActivity);
  return rows;
}

function setField(f: CycleFields, kind: string, value: string) {
  const pick = <T extends string>(list: readonly T[]) => (list.includes(value as T) ? (value as T) : undefined);
  if (kind === 'flow') f.flow = pick(FLOWS);
  else if (kind === 'period_start') f.periodStart = true;
  else if (kind === 'spotting') f.spotting = true;
  else if (kind === 'ovulation_test') f.ovulationTest = pick(OVULATION_TESTS);
  else if (kind === 'mucus') f.mucus = pick(MUCUS);
  else if (kind === 'sexual_activity') f.sexualActivity = pick(SEXUAL_ACTIVITY);
  else if (kind === 'bbt' && Number.isFinite(Number(value))) f.bbt = Number(value);
}

function fold(kind: CycleKind, a: string, b: string) {
  const rank = RANKED[kind];
  if (rank) return rank.indexOf(b) > rank.indexOf(a) ? b : a;
  return b;
}

export async function upsertCycle(q: Queryable, userId: string, rows: CycleRow[]) {
  // One value per (date, kind, source); two in one batch fold together rather than make Postgres reject it.
  const unique = new Map<string, CycleRow>();
  for (const r of rows) {
    const k = `${r.date}|${r.kind}|${r.source}`;
    const prev = unique.get(k);
    unique.set(k, prev ? { ...r, value: fold(r.kind, prev.value, r.value) } : r);
  }
  await insertMany(
    q,
    'cycle',
    ['user_id', 'date', 'kind', 'source', 'value'],
    [...unique.values()].map((r) => [userId, r.date, r.kind, r.source, r.value]),
    'ON CONFLICT (user_id, date, kind, source) DO UPDATE SET value = excluded.value',
  );
}

/** Each day given is that source's complete record for its date: cleared, then written. A day with no fields clears it. */
export async function replaceCycleDays(q: Queryable, userId: string, source: string, days: CycleDay[]) {
  const dates = [...new Set(days.map((d) => d.date))];
  if (!dates.length) return;
  await q.query('DELETE FROM cycle WHERE user_id = $1 AND source = $2 AND date = ANY($3)', [userId, source, dates]);
  await upsertCycle(
    q,
    userId,
    days.flatMap((d) => toRows(d, source)),
  );
}

/** Stored rows as days: a field logged by hand overrides Apple Health's for the same day. */
export function logDays(rows: Pick<CycleRow, 'date' | 'kind' | 'source' | 'value'>[]): CycleLogDay[] {
  const byDate = new Map<string, { apple?: CycleFields; manual?: CycleFields }>();
  for (const r of rows) {
    let d = byDate.get(r.date);
    if (!d) byDate.set(r.date, (d = {}));
    setField((d[r.source === MANUAL ? 'manual' : 'apple'] ??= {}), r.kind, r.value);
  }
  const clean = (f: CycleFields | undefined) => (f ? (Object.fromEntries(Object.entries(f).filter(([, v]) => v !== undefined)) as CycleFields) : undefined);
  return [...byDate]
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([date, s]) => {
      const apple = clean(s.apple);
      const manual = clean(s.manual);
      return { date, ...apple, ...manual, ...(apple && { apple }), ...(manual && { manual }) };
    });
}

// ---------- validation (manual entries and the iPhone app) ----------

type Fail = (path: string, message: string) => never;

function validDate(v: unknown): v is string {
  if (typeof v !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(v)) return false;
  const ms = Date.parse(`${v}T00:00:00Z`);
  // Date.parse rolls 2026-02-30 over to March; the round trip catches that.
  return !Number.isNaN(ms) && new Date(ms).toISOString().slice(0, 10) === v;
}

/** One day's entries. Messages name the field and what it accepts, never the value sent. */
export function parseCycleDay(raw: unknown, path: string, fail: Fail): CycleDay {
  if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) fail(path, 'expected an object');
  const r = raw as Record<string, unknown>;
  if (!validDate(r.date)) fail(`${path}.date`, 'expected a date as YYYY-MM-DD');
  const day: CycleDay = { date: r.date };
  const given = (key: string) => r[key] !== undefined && r[key] !== null;
  const oneOf = <T extends string>(key: string, list: readonly T[]): T | undefined => {
    if (!given(key)) return undefined;
    if (typeof r[key] !== 'string' || !list.includes(r[key] as T)) fail(`${path}.${key}`, `expected one of ${list.join(', ')}`);
    return r[key] as T;
  };
  const flag = (key: string) => {
    if (!given(key)) return undefined;
    if (typeof r[key] !== 'boolean') fail(`${path}.${key}`, 'expected true or false');
    return r[key] ? true : undefined;
  };
  const flow = oneOf('flow', FLOWS);
  const periodStart = flag('periodStart');
  const spotting = flag('spotting');
  const ovulationTest = oneOf('ovulationTest', OVULATION_TESTS);
  const mucus = oneOf('mucus', MUCUS);
  const sexualActivity = oneOf('sexualActivity', SEXUAL_ACTIVITY);
  let bbt: number | undefined;
  if (given('bbt')) {
    const v = r.bbt;
    if (typeof v !== 'number' || !Number.isFinite(v) || v < BBT_RANGE[0] || v > BBT_RANGE[1]) fail(`${path}.bbt`, `expected °C from ${BBT_RANGE[0]} to ${BBT_RANGE[1]}`);
    bbt = v;
  }
  return Object.assign(
    day,
    Object.fromEntries(Object.entries({ flow, periodStart, spotting, ovulationTest, mucus, bbt, sexualActivity }).filter(([, v]) => v !== undefined)),
  );
}

// ---------- history and estimates ----------

const between = (a: string, b: string) => Math.round((Date.parse(`${b}T00:00:00Z`) - Date.parse(`${a}T00:00:00Z`)) / 86_400_000);

function median(xs: number[]): number | null {
  if (!xs.length) return null;
  const s = [...xs].sort((a, b) => a - b);
  const m = s.length >> 1;
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
}

const clamp = (v: number, lo: number, hi: number) => Math.min(Math.max(v, lo), hi);

/** Bleeding after this many days without any starts a new period. */
const QUIET_DAYS = 7;
/** Two period starts closer than this are the same period. */
const MIN_GAP = 10;
/** Cycles outside this range are more likely a missed or stray log than a real cycle; estimates skip them. */
const PLAUSIBLE_CYCLE = [15, 90] as const;
const PLAUSIBLE_LUTEAL = [9, 18] as const;
/** Estimates use this many of the most recent cycles. */
const RECENT = 6;
/** Days from ovulation to the next period, when this person's own cycles don't show it. */
const LUTEAL_DAYS = 14;
/** No ovulation is inferred in the first days of a cycle (a stray test or reading). */
const EARLIEST_OVULATION = 6;

const isBleeding = (d: CycleFields) => d.flow !== undefined && d.flow !== 'none';

/**
 * The day before a sustained basal temperature rise: the first of three readings above the highest of the six
 * before them, the third at least 0.2 °C higher (the "three over six" rule). Readings are taken as logged.
 */
export function temperatureShift(days: CycleDay[]): string | null {
  const temps = days.filter((d): d is CycleDay & { bbt: number } => d.bbt !== undefined);
  for (let i = 6; i + 2 < temps.length; i++) {
    const cover = Math.max(...temps.slice(i - 6, i).map((t) => t.bbt));
    const [a, b, c] = temps.slice(i, i + 3);
    if (a.bbt > cover && b.bbt > cover && c.bbt >= cover + 0.2) return addDays(a.date, -1);
  }
  return null;
}

/** Periods, cycles and estimates from a person's days (any order). Pure, so tests can drive it. */
export function analyzeCycle(days: CycleDay[], today: string): Omit<CycleData, 'enabled' | 'today' | 'days'> {
  const sorted = [...days].filter((d) => d.date <= today).sort((a, b) => a.date.localeCompare(b.date));
  const bleeding = sorted.filter(isBleeding).map((d) => d.date);
  const bleedingSet = new Set(bleeding);

  // A start someone marked wins over one inferred from bleeding nearby (spotting logged as flow the day before).
  const spaced = (dates: string[]) => dates.reduce<string[]>((out, d) => (out.length && between(out[out.length - 1], d) < MIN_GAP ? out : [...out, d]), []);
  const marked = spaced(sorted.filter((d) => d.periodStart).map((d) => d.date));
  const inferred = bleeding.filter((d) => {
    for (let i = 1; i <= QUIET_DAYS; i++) if (bleedingSet.has(addDays(d, -i))) return false;
    return marked.every((m) => Math.abs(between(m, d)) >= MIN_GAP);
  });
  const starts = spaced([...marked, ...inferred].sort());

  const periods = starts.map((start, i) => {
    const next = starts[i + 1];
    let end = start;
    for (const b of bleeding) {
      if (b <= start) continue;
      if ((next && b >= next) || between(end, b) > 2) break;
      end = b;
    }
    return { start, end, days: between(start, end) + 1 };
  });
  const cycles = starts.slice(1).map((s, i) => ({ start: starts[i], days: between(starts[i], s) }));
  const recent = cycles.filter((c) => c.days >= PLAUSIBLE_CYCLE[0] && c.days <= PLAUSIBLE_CYCLE[1]).slice(-RECENT).map((c) => c.days);

  // Ovulation, after the fact, per cycle: a temperature rise if there is one, else the day after an LH surge.
  const ovulations: CycleData['ovulations'] = [];
  const luteals: number[] = [];
  let currentOvulation: CycleData['ovulations'][number] | undefined;
  starts.forEach((from, i) => {
    const next = starts[i + 1];
    const inCycle = sorted.filter((d) => d.date >= from && (!next || d.date < next));
    const cycleDay = (date: string) => between(from, date) + 1;
    const shift = temperatureShift(inCycle);
    const surge = inCycle.find((d) => d.ovulationTest === 'lh_surge' && cycleDay(d.date) + 1 >= EARLIEST_OVULATION);
    const found =
      shift && cycleDay(shift) >= EARLIEST_OVULATION
        ? { date: shift, basis: 'bbt' as const }
        : surge
          ? { date: addDays(surge.date, 1), basis: 'lh_test' as const }
          : undefined;
    if (!found || found.date > today) return;
    ovulations.push(found);
    if (next) {
      const luteal = between(found.date, next);
      if (luteal >= PLAUSIBLE_LUTEAL[0] && luteal <= PLAUSIBLE_LUTEAL[1]) luteals.push(luteal);
    } else currentOvulation = found;
  });

  const last = starts.at(-1);
  const cycleDays = median(recent);
  const stats = {
    cycleDays: cycleDays === null ? null : Math.round(cycleDays),
    periodDays: median(periods.slice(-RECENT).map((p) => p.days)),
    shortest: recent.length ? Math.min(...recent) : null,
    longest: recent.length ? Math.max(...recent) : null,
  };
  if (stats.periodDays !== null) stats.periodDays = Math.round(stats.periodDays);
  const current = last ? { start: last, day: between(last, today) + 1 } : null;

  let estimate: CycleEstimate | null = null;
  let noEstimate: CycleData['noEstimate'] = null;
  if (!last || cycleDays === null || recent.length < 2) noEstimate = 'cycles';
  else if (between(last, today) > 2 * cycleDays) noEstimate = 'stale';
  else {
    const m = Math.round(cycleDays);
    const luteal = Math.round(median(luteals) ?? LUTEAL_DAYS);
    let nextPeriod: CycleEstimate['nextPeriod'];
    let ovulation: string;
    let basis: CycleEstimate['basis'] = 'calendar';
    if (currentOvulation) {
      // This cycle's own ovulation sign beats the calendar: the next period follows it by the luteal phase.
      ovulation = currentOvulation.date;
      basis = currentOvulation.basis;
      const date = addDays(ovulation, luteal);
      nextPeriod = { date, earliest: addDays(date, -2), latest: addDays(date, 2) };
    } else {
      const lo = Math.min(...recent);
      const hi = Math.max(...recent);
      nextPeriod = {
        date: addDays(last, m),
        earliest: addDays(last, clamp(Math.min(lo, m - 2), m - 7, m)),
        latest: addDays(last, clamp(Math.max(hi, m + 2), m, m + 7)),
      };
      ovulation = addDays(nextPeriod.date, -luteal);
    }
    estimate = { nextPeriod, ovulation, fertile: { start: addDays(ovulation, -5), end: addDays(ovulation, 1) }, basis, cycles: recent.length };
  }
  return { periods, cycles, stats, current, estimate, noEstimate, ovulations };
}

/** A period this many days long when the person's own history doesn't say. */
const PERIOD_DAYS = 5;

/**
 * Where today falls in the current cycle, from analyzeCycle's output and the days it was given. Menstrual while
 * today is in the period's logged bleeding run, or within the usual period length once bleeding was logged in
 * it; ovulatory in the fertile window; luteal after this cycle's ovulation (detected, else estimated); otherwise
 * follicular. null with no current cycle, or one so long past that it isn't really current.
 */
export function cyclePhase(a: ReturnType<typeof analyzeCycle>, days: CycleDay[], today: string): CyclePhase | null {
  const { current, estimate } = a;
  if (!current || a.noEstimate === 'stale' || current.day > PLAUSIBLE_CYCLE[1]) return null;
  // A period that's late reads as due today rather than a negative count.
  const nextPeriodIn = estimate ? Math.max(0, between(today, estimate.nextPeriod.date)) : null;
  const phase = (name: CyclePhase['name'], basis: CyclePhase['basis']): CyclePhase => ({ name, day: current.day, nextPeriodIn, basis });

  const period = a.periods.find((p) => p.start === current.start);
  const bled = days.some((d) => d.date >= current.start && d.date <= today && isBleeding(d));
  if (bled && ((period && today <= period.end) || current.day <= (a.stats.periodDays ?? PERIOD_DAYS))) return phase('menstrual', 'logged');

  // This cycle's own ovulation sign wins over the calendar (the estimate already follows it when there is one).
  const detected = a.ovulations.filter((o) => o.date >= current.start).at(-1);
  const ovulation = detected?.date ?? estimate?.ovulation;
  const fertile = detected ? { start: addDays(detected.date, -5), end: addDays(detected.date, 1) } : estimate?.fertile;
  const basis = detected ? 'logged' : 'estimate';
  if (fertile && today >= fertile.start && today <= fertile.end) return phase('ovulatory', basis);
  if (ovulation && today > ovulation) return phase('luteal', basis);
  return phase('follicular', basis);
}

// ---------- reading ----------

const empty = (today: string): CycleData => ({
  enabled: false,
  today,
  days: [],
  periods: [],
  cycles: [],
  stats: { cycleDays: null, periodDays: null, shortest: null, longest: null },
  current: null,
  estimate: null,
  noEstimate: null,
  ovulations: [],
  phase: null,
});

/**
 * One person's cycle view: logged days in the window (default the last 400 days to `end`), and periods,
 * cycles and estimates from all their history. Empty unless they have cycle tracking on.
 */
export async function cycleView(scope: Scope, hosted: boolean, opts: { days?: number; end?: string } = {}): Promise<CycleData> {
  const { today, settings } = await requestContext(scope, hosted);
  if (!settings.cycleTracking) return empty(today);
  const rows = await scope.db.query<CycleRow>("SELECT date, kind, source, value FROM cycle WHERE user_id = $1 AND source IN ('apple', 'manual') ORDER BY date", [
    scope.userId,
  ]);
  const all = logDays(rows);
  const end = opts.end && opts.end < today ? opts.end : today;
  const from = addDays(end, -((opts.days ?? 400) - 1));
  const analysis = analyzeCycle(all, today);
  return { enabled: true, today, days: all.filter((d) => d.date >= from && d.date <= end), ...analysis, phase: cyclePhase(analysis, all, today) };
}

// ---------- the router ----------

class CycleInputError extends Error {}
const failInput: Fail = (path, message) => {
  throw new CycleInputError(`${path}: ${message}`);
};

export function cycleRouter(db: Db, hosted: boolean) {
  const router = express.Router();
  const scopeOf = (res: Response): Scope => ({ db, userId: currentUser(res).id });

  router.get('/', async (req, res) => {
    const days = Math.min(Math.max(Number(req.query.days) || 400, 1), 3650);
    res.json(await cycleView(scopeOf(res), hosted, { days }));
  });

  /** Log one day by hand: the body is that day's complete manual entry ({ date } alone clears it). */
  router.post('/day', async (req, res) => {
    const scope = scopeOf(res);
    const { today, settings } = await requestContext(scope, hosted);
    if (!settings.cycleTracking) return void res.status(403).json({ error: 'Turn on cycle tracking in Settings first.' });
    let day: CycleDay;
    try {
      day = parseCycleDay(req.body, 'body', failInput);
    } catch (err) {
      if (err instanceof CycleInputError) return void res.status(400).json({ error: err.message });
      throw err;
    }
    if (day.date > today) return void res.status(400).json({ error: "That day hasn't happened yet." });
    await db.tx((q) => replaceCycleDays(q, scope.userId, MANUAL, [day]));
    await bumpDataVersion(db, scope.userId);
    res.json({ ok: true });
  });

  /** Everything cycle-related this person stored, from every source. Works whether tracking is on or off. */
  router.post('/delete', async (_req, res) => {
    const deleted = await db.query('DELETE FROM cycle WHERE user_id = $1 RETURNING 1', [scopeOf(res).userId]);
    await bumpDataVersion(db, scopeOf(res).userId);
    res.json({ deleted: deleted.length });
  });

  router.use((err: Error & { status?: number }, _req: Request, res: Response, _next: NextFunction) => {
    if (err.status && err.status >= 400 && err.status < 500) return void res.status(err.status).json({ error: 'Bad request' });
    // The kind of failure only: a database error's text can quote the values it was given.
    console.error('cycle:', err.name);
    res.status(500).json({ error: 'Something went wrong' });
  });

  return router;
}
