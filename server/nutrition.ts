// Nutrition (/api/nutrition): daily totals from the apps people log food in (MyFitnessPal, Cronometer, Lose It!,
// MacroFactor, Yazio…), read through Apple Health. Food and eating data is sensitive, so, like cycle tracking:
// - It has its own table, never `daily`: summaries, patterns, the weekly digest, the admin view, the Family board
//   and McFly's metric list can't reach it.
// - It's off until the person turns it on, and nothing is stored while it's off: unlike cycle history, there's no
//   reason to keep food logs nobody asked healthOS to read. Turning it off hides what's stored; delete removes it.
// - The person chooses how much they see (everything, no calories, or no amounts), and every response is filtered
//   here, McFly's included, so a hidden number never leaves the server.
// - Nothing here logs values, and no URL carries a date or an amount.
import express, { type NextFunction, type Request, type Response } from 'express';
import type { Nutrient, NutritionData, NutritionDay, NutritionDayIn, NutritionNumbers } from '../shared/types.ts';
import { aiStatus } from './ai/resolve.ts';
import { HttpError, currentUser } from './auth.ts';
import { addDays } from './dates.ts';
import { type Db, type Queryable, type Scope, bumpDataVersion } from './db.ts';
import { foodPatterns } from './insights.ts';
import type { McflyClient } from './mcfly.ts';
import { NUTRIENTS, NUTRIENT_MAX, isNutrient, shown } from './nutrients.ts';
import { HEALTHOS_APP, deleteFoodLog, foodLogRouter, loggedTotals, loggingContext, shownValues } from './foodlog.ts';
import { type FetchFn, foodsRouter } from './foods.ts';
import { requestContext, trends } from './query.ts';
import { insertMany } from './store.ts';

/** One stored total: a day, a nutrient, where it came from ('apple'), and the app that logged it in Health. */
export type NutritionRow = { date: string; nutrient: Nutrient; source: string; app: string; value: number };

export { NUTRIENTS, NUTRIENT_MAX, isNutrient, shown };

// ---------- storage ----------

export async function upsertNutrition(q: Queryable, userId: string, rows: NutritionRow[]) {
  // One value per key; a later duplicate in the batch would make Postgres reject the statement.
  const unique = new Map<string, NutritionRow>();
  for (const r of rows) if (Number.isFinite(r.value) && r.value >= 0) unique.set(`${r.date}|${r.nutrient}|${r.source}|${r.app}`, r);
  await insertMany(
    q,
    'nutrition_daily',
    ['user_id', 'date', 'nutrient', 'source', 'app', 'value'],
    [...unique.values()].map((r) => [userId, r.date, r.nutrient, r.source, r.app, r.value]),
    'ON CONFLICT (user_id, date, nutrient, source, app) DO UPDATE SET value = excluded.value',
  );
}

/** Each day sent is that day's complete set from Health: its earlier rows from this source go, then these are written. */
export async function replaceNutritionDays(q: Queryable, userId: string, source: string, days: NutritionDayIn[]) {
  const dates = [...new Set(days.map((d) => d.date))];
  if (!dates.length) return;
  await q.query('DELETE FROM nutrition_daily WHERE user_id = $1 AND source = $2 AND date = ANY($3)', [userId, source, dates]);
  await upsertNutrition(
    q,
    userId,
    // healthOS's own entries coming back from Health are already in the food log.
    days.flatMap((d) => d.apps.filter((a) => a.app !== HEALTHOS_APP).flatMap((a) => Object.entries(a.values).map(([nutrient, value]) => ({ date: d.date, nutrient: nutrient as Nutrient, source, app: a.app, value: value! })))),
  );
}

// ---------- validation (the iPhone app's days) ----------

export type Fail = (path: string, message: string) => never;

function validDate(v: unknown): v is string {
  if (typeof v !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(v)) return false;
  const ms = Date.parse(`${v}T00:00:00Z`);
  return !Number.isNaN(ms) && new Date(ms).toISOString().slice(0, 10) === v;
}

/** One day's totals by app. Messages name the field and what it accepts, never the value sent. */
export function parseNutritionDay(raw: unknown, path: string, fail: Fail): NutritionDayIn {
  if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) fail(path, 'expected an object');
  const r = raw as Record<string, unknown>;
  if (!validDate(r.date)) fail(`${path}.date`, 'expected a date as YYYY-MM-DD');
  if (!Array.isArray(r.apps)) fail(`${path}.apps`, 'expected an array');
  if (r.apps.length > 20) fail(`${path}.apps`, 'at most 20 apps a day');
  const apps = r.apps.map((rawApp, i) => {
    const p = `${path}.apps[${i}]`;
    if (typeof rawApp !== 'object' || rawApp === null || Array.isArray(rawApp)) fail(p, 'expected an object');
    const a = rawApp as Record<string, unknown>;
    if (typeof a.app !== 'string' || !a.app.trim() || a.app.length > 100) fail(`${p}.app`, 'expected a string of 1-100 characters');
    if (typeof a.values !== 'object' || a.values === null || Array.isArray(a.values)) fail(`${p}.values`, 'expected an object');
    const values: Partial<Record<Nutrient, number>> = {};
    for (const [key, v] of Object.entries(a.values)) {
      if (!isNutrient(key)) fail(`${p}.values`, `unknown nutrient; expected ${NUTRIENTS.join(', ')}`);
      if (typeof v !== 'number' || !Number.isFinite(v) || v < 0 || v > NUTRIENT_MAX[key]) fail(`${p}.values.${key}`, `expected a number from 0 to ${NUTRIENT_MAX[key]}`);
      values[key] = v;
    }
    return { app: a.app.trim(), values };
  });
  return { date: r.date, apps };
}

// ---------- reading ----------

/**
 * One app per day, never a sum: apps copy each other's logs through Health (Lose It! and MacroFactor read others'
 * energy into their own), so adding them would count the same meal twice. The person's chosen app when it logged
 * that day, else the app with the most energy (then the most nutrients, then by name, so it's stable).
 */
export function pickDays(rows: Pick<NutritionRow, 'date' | 'nutrient' | 'app' | 'value'>[], preferred: string | null): { date: string; app: string; values: Partial<Record<Nutrient, number>>; otherApps: string[] }[] {
  const byDate = new Map<string, Map<string, Partial<Record<Nutrient, number>>>>();
  for (const r of rows) {
    let apps = byDate.get(r.date);
    if (!apps) byDate.set(r.date, (apps = new Map()));
    let values = apps.get(r.app);
    if (!values) apps.set(r.app, (values = {}));
    values[r.nutrient] = (values[r.nutrient] ?? 0) + r.value;
  }
  const rank = (app: string, v: Partial<Record<Nutrient, number>>) => [app === preferred ? 1 : 0, v.energy_kcal ?? 0, Object.keys(v).length];
  return [...byDate]
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([date, apps]) => {
      const sorted = [...apps].sort(([an, av], [bn, bv]) => {
        const [ra, rb] = [rank(an, av), rank(bn, bv)];
        for (let i = 0; i < ra.length; i++) if (ra[i] !== rb[i]) return rb[i] - ra[i];
        return an.localeCompare(bn);
      });
      const [[app, values], ...rest] = sorted;
      return { date, app, values, otherApps: rest.map(([name]) => name) };
    });
}

const empty = (today: string): NutritionData => ({
  enabled: false,
  numbers: null,
  today,
  start: today,
  end: today,
  apps: [],
  app: null,
  days: [],
  targets: {},
  hydration: { water: [], caffeine: [] },
  insights: [],
});

/**
 * The days' candidates, one per app: the Health apps' totals, and healthOS's own log as one more. Health rows
 * under healthOS's name are its own entries coming back from Apple Health (the iPhone writes them there), so
 * they go: the log itself is the copy that counts. Also returns the log's water by day, for Hydration.
 */
async function candidatesBetween(scope: Scope, start: string, end: string) {
  const [rows, logged] = await Promise.all([
    scope.db.query<NutritionRow>(
      'SELECT date, nutrient, source, app, value FROM nutrition_daily WHERE user_id = $1 AND date BETWEEN $2 AND $3 ORDER BY date',
      [scope.userId, start, end],
    ),
    loggedTotals(scope, start, end),
  ]);
  const candidates: Pick<NutritionRow, 'date' | 'nutrient' | 'app' | 'value'>[] = rows.filter((r) => isNutrient(r.nutrient) && r.app !== HEALTHOS_APP);
  const water = new Map<string, number>();
  for (const [date, day] of logged) {
    for (const [nutrient, value] of Object.entries(day.values) as [Nutrient, number][]) candidates.push({ date, nutrient, app: HEALTHOS_APP, value });
    if (day.water > 0) water.set(date, day.water);
  }
  return { candidates, water };
}

async function pickedBetween(scope: Scope, preferred: string | null, start: string, end: string) {
  return pickDays((await candidatesBetween(scope, start, end)).candidates, preferred);
}

/** A day's water: the Health apps' (summed, as people log water in small separate apps) plus healthOS's log. */
function withLoggedWater(points: { date: string; value: number }[], logged: Map<string, number>) {
  const byDate = new Map(points.map((p) => [p.date, p.value]));
  for (const [date, ml] of logged) byDate.set(date, (byDate.get(date) ?? 0) + ml);
  return [...byDate].sort(([a], [b]) => a.localeCompare(b)).map(([date, value]) => ({ date, value: Math.round(value) }));
}

/**
 * One person's nutrition over the last `days` days to `end` (default today), one app per day, filtered by their
 * number setting, with their own targets, water and caffeine, and (when asked) food patterns. Empty unless they
 * have nutrition on and have chosen what to see.
 */
export async function nutritionView(scope: Scope, hosted: boolean, opts: { days?: number; end?: string; insights?: boolean } = {}): Promise<NutritionData> {
  const { today, settings } = await requestContext(scope, hosted);
  const numbers = settings.nutritionNumbers;
  if (!settings.nutrition || !numbers) return empty(today);
  const end = opts.end && opts.end < today ? opts.end : today;
  const days = opts.days ?? 30;
  const start = addDays(end, -(days - 1));
  const amounts = numbers !== 'none';
  const [{ candidates, water }, hydration, insights] = await Promise.all([
    candidatesBetween(scope, start, end),
    amounts ? trends(scope, hosted, ['water_ml', 'caffeine_mg'], days, end) : null,
    // The texts quote amounts ("200+ mg", "2 or more drinks"), so not in 'none'.
    amounts && opts.insights
      ? foodPatterns(scope, hosted, async (from, to) => new Map((await pickedBetween(scope, settings.nutritionApp, from, to)).map((d) => [d.date, d.values.alcohol_drinks ?? 0])))
      : [],
  ]);
  const picked = pickDays(candidates, settings.nutritionApp);
  const t = settings.nutritionTargets;
  const targets: NutritionData['targets'] = {};
  if (amounts) {
    if (numbers === 'all' && t.energy_kcal !== null) targets.energy_kcal = t.energy_kcal;
    if (t.protein_g !== null) targets.protein_g = t.protein_g;
    if (t.water_ml !== null) targets.water_ml = t.water_ml;
  }
  const daysByApp = new Map<string, number>();
  for (const d of picked) for (const a of [d.app, ...d.otherApps]) daysByApp.set(a, (daysByApp.get(a) ?? 0) + 1);
  const shownDays: NutritionDay[] = picked.map((d) => ({ ...d, values: shown(d.values, numbers) }));
  return {
    enabled: true,
    numbers,
    today,
    start,
    end,
    apps: [...daysByApp].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0])).map(([app]) => app),
    app: settings.nutritionApp,
    days: shownDays,
    targets,
    hydration: { water: hydration ? withLoggedWater(hydration.water_ml ?? [], water) : [], caffeine: hydration?.caffeine_mg ?? [] },
    insights,
  };
}

// ---------- the router ----------

/** Nutrition's errors: messages written for the person (HttpError) as they are, anything else without detail. */
export function nutritionErrors(err: Error & { status?: number; type?: string }, _req: Request, res: Response, _next: NextFunction) {
  if (err instanceof HttpError) return void res.status(err.status).json({ error: err.message });
  if (err.type === 'entity.too.large') return void res.status(413).json({ error: 'That photo is too large. Try a smaller one.' });
  if (err.status && err.status >= 400 && err.status < 500) return void res.status(err.status).json({ error: 'Bad request' });
  // The kind of failure only: a database error's text can quote the values it was given.
  console.error('nutrition:', err.name);
  res.status(500).json({ error: 'Something went wrong' });
}

export type NutritionDeps = {
  /** Food database calls (tests pass a fake). */
  fetchFn?: FetchFn;
  /** The shared Claude key, for McFly's food estimates when a person has no key of their own (tests pass a fake). */
  client: () => McflyClient | null;
};

export function nutritionRouter(db: Db, hosted: boolean, { fetchFn = fetch, client }: NutritionDeps) {
  const router = express.Router();
  const scopeOf = (res: Response): Scope => ({ db, userId: currentUser(res).id });

  router.get('/', async (req, res) => {
    const days = Math.min(Math.max(Number(req.query.days) || 30, 1), 366);
    res.json(await nutritionView(scopeOf(res), hosted, { days, insights: req.query.insights === '1' }));
  });

  router.use(
    '/log',
    foodLogRouter(db, hosted, {
      ai: (userId) => aiStatus(db, userId, client),
      countedApp: async (scope, date, preferred) => (await pickedBetween(scope, preferred, date, date))[0]?.app ?? null,
    }),
  );
  router.use(
    '/foods',
    foodsRouter(db, { fetchFn, shownValues, numbersOf: async (res) => (await loggingContext(db, hosted, res)).numbers }),
  );

  /** Everything nutrition-related this person stored, from every source, their food log too. Works whether nutrition is on or off. */
  router.post('/delete', async (_req, res) => {
    const { userId } = scopeOf(res);
    const deleted = await db.tx(async (q) => {
      const totals = await q.query('DELETE FROM nutrition_daily WHERE user_id = $1 RETURNING 1', [userId]);
      return totals.length + (await deleteFoodLog(q, userId));
    });
    await bumpDataVersion(db, userId);
    res.json({ deleted });
  });

  router.use(nutritionErrors);

  return router;
}
