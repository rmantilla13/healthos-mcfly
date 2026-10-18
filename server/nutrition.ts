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
import { currentUser } from './auth.ts';
import { addDays } from './dates.ts';
import { type Db, type Queryable, type Scope, bumpDataVersion } from './db.ts';
import { requestContext } from './query.ts';
import { insertMany } from './store.ts';

/** In the order they're shown. Daily totals: energy in kcal, masses in g except sodium (mg), alcohol in drinks. */
export const NUTRIENTS: readonly Nutrient[] = ['energy_kcal', 'protein_g', 'carbs_g', 'fat_g', 'fiber_g', 'sugar_g', 'sat_fat_g', 'sodium_mg', 'alcohol_drinks'];

/** Above any real day's total: a bigger number is a unit mix-up, not a meal. */
const MAX: Record<Nutrient, number> = {
  energy_kcal: 30_000,
  protein_g: 2_000,
  carbs_g: 3_000,
  fat_g: 2_000,
  fiber_g: 500,
  sugar_g: 2_000,
  sat_fat_g: 1_000,
  sodium_mg: 50_000,
  alcohol_drinks: 100,
};

/** One stored total: a day, a nutrient, where it came from ('apple'), and the app that logged it in Health. */
export type NutritionRow = { date: string; nutrient: Nutrient; source: string; app: string; value: number };

export const isNutrient = (v: unknown): v is Nutrient => typeof v === 'string' && (NUTRIENTS as readonly string[]).includes(v);

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
    days.flatMap((d) => d.apps.flatMap((a) => Object.entries(a.values).map(([nutrient, value]) => ({ date: d.date, nutrient: nutrient as Nutrient, source, app: a.app, value: value! })))),
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
      if (typeof v !== 'number' || !Number.isFinite(v) || v < 0 || v > MAX[key]) fail(`${p}.values.${key}`, `expected a number from 0 to ${MAX[key]}`);
      values[key] = v;
    }
    return { app: a.app.trim(), values };
  });
  return { date: r.date, apps };
}

// ---------- reading ----------

/** What a person sees of one day's values: the setting decides, here, before anything leaves the server. */
export function shown(values: Partial<Record<Nutrient, number>>, numbers: NutritionNumbers): Partial<Record<Nutrient, number>> {
  if (numbers === 'none') return {};
  const out: Partial<Record<Nutrient, number>> = {};
  for (const n of NUTRIENTS) {
    if (numbers === 'no_energy' && n === 'energy_kcal') continue;
    const v = values[n];
    if (v !== undefined) out[n] = Math.round(v * 10) / 10;
  }
  return out;
}

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

const empty = (today: string): NutritionData => ({ enabled: false, numbers: null, today, start: today, end: today, apps: [], app: null, days: [] });

/**
 * One person's nutrition over the last `days` days to `end` (default today), one app per day, filtered by their
 * number setting. Empty unless they have nutrition on and have chosen what to see.
 */
export async function nutritionView(scope: Scope, hosted: boolean, opts: { days?: number; end?: string } = {}): Promise<NutritionData> {
  const { today, settings } = await requestContext(scope, hosted);
  const numbers = settings.nutritionNumbers;
  if (!settings.nutrition || !numbers) return empty(today);
  const end = opts.end && opts.end < today ? opts.end : today;
  const start = addDays(end, -((opts.days ?? 30) - 1));
  const rows = await scope.db.query<NutritionRow>(
    'SELECT date, nutrient, source, app, value FROM nutrition_daily WHERE user_id = $1 AND date BETWEEN $2 AND $3 ORDER BY date',
    [scope.userId, start, end],
  );
  const picked = pickDays(
    rows.filter((r) => isNutrient(r.nutrient)),
    settings.nutritionApp,
  );
  const daysByApp = new Map<string, number>();
  for (const d of picked) for (const a of [d.app, ...d.otherApps]) daysByApp.set(a, (daysByApp.get(a) ?? 0) + 1);
  const days: NutritionDay[] = picked.map((d) => ({ ...d, values: shown(d.values, numbers) }));
  return {
    enabled: true,
    numbers,
    today,
    start,
    end,
    apps: [...daysByApp].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0])).map(([app]) => app),
    app: settings.nutritionApp,
    days,
  };
}

// ---------- the router ----------

export function nutritionRouter(db: Db, hosted: boolean) {
  const router = express.Router();
  const scopeOf = (res: Response): Scope => ({ db, userId: currentUser(res).id });

  router.get('/', async (req, res) => {
    const days = Math.min(Math.max(Number(req.query.days) || 30, 1), 366);
    res.json(await nutritionView(scopeOf(res), hosted, { days }));
  });

  /** Everything nutrition-related this person stored, from every source. Works whether nutrition is on or off. */
  router.post('/delete', async (_req, res) => {
    const { userId } = scopeOf(res);
    const deleted = await db.query('DELETE FROM nutrition_daily WHERE user_id = $1 RETURNING 1', [userId]);
    await bumpDataVersion(db, userId);
    res.json({ deleted: deleted.length });
  });

  router.use((err: Error & { status?: number }, _req: Request, res: Response, _next: NextFunction) => {
    if (err.status && err.status >= 400 && err.status < 500) return void res.status(err.status).json({ error: 'Bad request' });
    // The kind of failure only: a database error's text can quote the values it was given.
    console.error('nutrition:', err.name);
    res.status(500).json({ error: 'Something went wrong' });
  });

  return router;
}
