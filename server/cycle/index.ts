// Cycle tracking (/api/cycle): menstrual flow, spotting, ovulation tests, cervical mucus, basal body temperature,
// symptoms and sexual activity, from Apple Health and from logging by hand, read together with the nightly
// temperatures Apple Watch and WHOOP already record. Estimates of ovulation, the fertile window and the next
// period come from the person's own history (engine.ts). This is reproductive-health data, so:
// - It has its own table, never `daily`: summaries, the admin view and McFly's metric list can't reach it. The
//   cycle code reads `daily` (temperatures, resting heart rate, HRV); nothing flows the other way.
// - Apple Health's records are stored even while tracking is off, hidden. Every read checks the person's
//   cycle_tracking setting first.
// - Nothing here logs values or errors' text, and dates travel in request bodies, never in URLs.
//
// Modules: records.ts (storage and validation), temperature.ts (readings and the rise), engine.ts (periods,
// ovulation, estimates, phase), insights.ts (patterns from past cycles).
import express, { type NextFunction, type Request, type Response } from 'express';
import type { CycleData, CycleDay, CycleLogDay } from '../../shared/types.ts';
import { currentUser } from '../auth.ts';
import { addDays } from '../dates.ts';
import { type Db, type Queryable, type Scope, bumpDataVersion } from '../db.ts';
import { requestContext } from '../query.ts';
import { type CycleAnalysis, analyzeCycle, cyclePhase } from './engine.ts';
import { type VitalRow, cycleInsights } from './insights.ts';
import { type Fail, MANUAL, parseCycleDay, readLogDays, replaceCycleDays } from './records.ts';
import type { TempReading } from './temperature.ts';

export { analyzeCycle, cyclePhase, fitLength, forecastCycle } from './engine.ts';
export { phaseOf } from './insights.ts';
export { type CycleKind, type CycleRow, MANUAL, logDays, parseCycleDay, replaceCycleDays, toRows, upsertCycle } from './records.ts';
export { type TempReading, detectShift, prepareTemperatures } from './temperature.ts';

/** The metrics the engine reads from `daily`, real sources only (never the demo's). */
const VITALS = ['wrist_temp', 'skin_temp', 'resting_hr', 'hrv_rmssd', 'hrv_sdnn'];

export type CycleInputs = { days: CycleLogDay[]; wearable: TempReading[]; vitals: VitalRow[] };

/** Everything the engine needs for one person. The page, the family board and Ask McFly all start here. */
export async function loadCycleInputs(q: Queryable, userId: string): Promise<CycleInputs> {
  const [days, vitals] = await Promise.all([
    readLogDays(q, userId),
    q.query<VitalRow>("SELECT date, metric, source, value FROM daily WHERE user_id = $1 AND metric = ANY($2) AND source IN ('apple', 'whoop') ORDER BY date", [userId, VITALS]),
  ]);
  const sources: Record<string, TempReading['source']> = { wrist_temp: 'wrist', skin_temp: 'skin' };
  const wearable: TempReading[] = vitals.flatMap((v): TempReading[] => (sources[v.metric] ? [{ date: v.date, source: sources[v.metric], value: v.value }] : []));
  return { days, wearable, vitals: vitals.filter((v) => v.metric !== 'wrist_temp' && v.metric !== 'skin_temp') };
}

export function analyzeInputs(inputs: CycleInputs, today: string): CycleAnalysis {
  return analyzeCycle(inputs.days, today, inputs.wearable);
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
  earlyEstimate: null,
  ovulations: [],
  phase: null,
});

/**
 * One person's cycle view: logged days and temperatures in the window (default the last 400 days to `end`), and
 * periods, cycles, estimates and patterns from all their history. Empty unless they have cycle tracking on.
 */
export async function cycleView(scope: Scope, hosted: boolean, opts: { days?: number; end?: string } = {}): Promise<CycleData> {
  const { today, settings } = await requestContext(scope, hosted);
  if (!settings.cycleTracking) return empty(today);
  const inputs = await loadCycleInputs(scope.db, scope.userId);
  const end = opts.end && opts.end < today ? opts.end : today;
  const from = addDays(end, -((opts.days ?? 400) - 1));
  const a = analyzeInputs(inputs, today);
  const inWindow = (d: { date: string }) => d.date >= from && d.date <= end;
  return {
    enabled: true,
    today,
    days: inputs.days.filter(inWindow),
    ...a,
    temperatures: a.temperatures.filter(inWindow),
    phase: cyclePhase(a, inputs.days, today),
    insights: cycleInsights(a, inputs.days, inputs.vitals, today),
  };
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
