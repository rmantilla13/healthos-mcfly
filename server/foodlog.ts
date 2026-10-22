// The food log (/api/nutrition/log): what a person logs in healthOS itself, on the web or the iPhone. The rules
// are nutrition's (server/nutrition.ts): only while Nutrition is on, every response filtered by the person's
// numbers setting, nothing logged, no date or amount in a URL. A day's saved entries count as one more app,
// "healthOS", among the Health apps, never added on top of one: apps that read Health (Lose It!, MacroFactor)
// can copy the entries the iPhone writes there back under their own name, and a sum would count those twice.
import { randomUUID } from 'node:crypto';
import express, { type Response } from 'express';
import type { FoodEntry, FoodLog, FoodMethod, FoodValues, Nutrient, NutritionNumbers } from '../shared/types.ts';
import { HttpError, currentUser } from './auth.ts';
import { addDays } from './dates.ts';
import { type Db, type Queryable, type Scope, bumpDataVersion } from './db.ts';
import { type Food, cachedFood, portionValues } from './foods.ts';
import { NUTRIENTS, NUTRIENT_MAX, shown } from './nutrients.ts';
import { requestContext } from './query.ts';

/** The name healthOS's entries go by among the Health apps, and the iPhone app's name in Apple Health. */
export const HEALTHOS_APP = 'healthOS';

export type FoodKey = Nutrient | 'water_ml';
export const FOOD_KEYS: readonly FoodKey[] = [...NUTRIENTS, 'water_ml'];
/** One entry can't exceed a whole day's ceiling. */
const KEY_MAX: Record<FoodKey, number> = { ...NUTRIENT_MAX, water_ml: 10_000 };
const isFoodKey = (v: string): v is FoodKey => (FOOD_KEYS as readonly string[]).includes(v);

const MAX_QUANTITY = 50;
/** How far back an entry can be dated. */
const MAX_AGE_DAYS = 366;
const DRAFT_TTL_MS = 24 * 3600_000;
const TIME = /^([01]\d|2[0-3]):[0-5]\d$/;
const DATE = /^\d{4}-\d{2}-\d{2}$/;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

type Row = {
  id: string;
  date: string;
  time: string;
  name: string;
  portion: string;
  quantity: number;
  per: string;
  method: FoodMethod;
  ref: string | null;
  origin: 'web' | 'iphone';
  draft: boolean;
  version: number;
};

const COLUMNS = 'id, date, time, name, portion, quantity, per, method, ref, origin, draft, version';

// ---------- amounts ----------

function readPer(raw: string): FoodValues {
  try {
    const parsed: unknown = JSON.parse(raw);
    if (typeof parsed !== 'object' || parsed === null) return {};
    const out: FoodValues = {};
    for (const [k, v] of Object.entries(parsed)) if (isFoodKey(k) && typeof v === 'number' && Number.isFinite(v) && v >= 0) out[k] = v;
    return out;
  } catch {
    return {};
  }
}

export function scaleValues(values: FoodValues, by: number): FoodValues {
  const out: FoodValues = {};
  for (const [k, v] of Object.entries(values) as [FoodKey, number][]) out[k] = v * by;
  return out;
}

/** What a person sees of an entry's amounts: nutrients as `shown` allows, and water unless they see no amounts. */
export function shownValues(values: FoodValues, numbers: NutritionNumbers): FoodValues {
  const out: FoodValues = shown(values, numbers);
  if (numbers !== 'none' && values.water_ml !== undefined) out.water_ml = Math.round(values.water_ml);
  return out;
}

/** Which keys a person may send: the ones they can see. */
const visibleKey = (k: FoodKey, numbers: NutritionNumbers) => numbers === 'all' || (numbers === 'no_energy' && k !== 'energy_kcal');

function toEntry(r: Row, numbers: NutritionNumbers): FoodEntry {
  const quantity = Number(r.quantity);
  return {
    id: r.id,
    date: r.date,
    time: r.time,
    name: r.name,
    portion: r.portion,
    quantity,
    values: shownValues(scaleValues(readPer(r.per), quantity), numbers),
    method: r.method,
    ref: r.ref,
    version: Number(r.version),
    origin: r.origin,
  };
}

// ---------- totals (for server/nutrition.ts) ----------

/** Saved entries' totals by day: nutrients (healthOS's candidate among the apps) and water (added to Hydration). */
export async function loggedTotals(scope: Scope, start: string, end: string) {
  const rows = await scope.db.query<Pick<Row, 'date' | 'quantity' | 'per'>>(
    'SELECT date, quantity, per FROM food_log WHERE user_id = $1 AND NOT draft AND date BETWEEN $2 AND $3',
    [scope.userId, start, end],
  );
  const days = new Map<string, { values: Partial<Record<Nutrient, number>>; water: number }>();
  for (const r of rows) {
    let day = days.get(r.date);
    if (!day) days.set(r.date, (day = { values: {}, water: 0 }));
    for (const [k, v] of Object.entries(scaleValues(readPer(r.per), Number(r.quantity))) as [FoodKey, number][]) {
      if (k === 'water_ml') day.water += v;
      else day.values[k] = (day.values[k] ?? 0) + v;
    }
  }
  return days;
}

// ---------- reading and writing ----------

/** Unsaved estimates older than a day go: nobody confirmed them. */
async function dropStaleDrafts(q: Queryable, userId: string) {
  await q.query('DELETE FROM food_log WHERE user_id = $1 AND draft AND created_at < $2', [userId, Date.now() - DRAFT_TTL_MS]);
}

async function entriesBetween(q: Queryable, userId: string, start: string, end: string) {
  return q.query<Row>(`SELECT ${COLUMNS} FROM food_log WHERE user_id = $1 AND NOT draft AND date BETWEEN $2 AND $3 ORDER BY date, time, created_at`, [userId, start, end]);
}

async function draftsOf(q: Queryable, userId: string) {
  return q.query<Row>(`SELECT ${COLUMNS} FROM food_log WHERE user_id = $1 AND draft ORDER BY created_at, id`, [userId]);
}

async function entryById(q: Queryable, userId: string, id: string) {
  const [row] = await q.query<Row>(`SELECT ${COLUMNS} FROM food_log WHERE user_id = $1 AND id = $2`, [userId, id]);
  return row ?? null;
}

export type NewEntry = Omit<Row, 'draft' | 'version' | 'per'> & { per: FoodValues };

export async function insertEntries(q: Queryable, userId: string, entries: NewEntry[], draft: boolean) {
  const now = Date.now();
  // A millisecond apart, so entries made together (an estimate's items) keep their order.
  for (const [i, e] of entries.entries()) {
    // A retry of the same id (the iPhone resending after a dropped reply) changes nothing.
    await q.query(
      `INSERT INTO food_log (user_id, id, date, time, name, portion, quantity, per, method, ref, origin, draft, version, created_at, updated_at)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, 1, $13, $13) ON CONFLICT (user_id, id) DO NOTHING`,
      [userId, e.id, e.date, e.time, e.name, e.portion, e.quantity, JSON.stringify(e.per), e.method, e.ref, e.origin, draft, now + i],
    );
  }
}

/** Every entry this person made, drafts too (Nutrition's delete and account deletion). */
export async function deleteFoodLog(q: Queryable, userId: string) {
  return (await q.query('DELETE FROM food_log WHERE user_id = $1 RETURNING 1', [userId])).length;
}

// ---------- checking what's sent ----------

const bad = (message: string) => new HttpError(400, message);

/** Local date and time now in the person's zone. */
export function nowIn(timeZone: string | null): { date: string; time: string } {
  const parts = (zone?: string) => Object.fromEntries(
    new Intl.DateTimeFormat('en-CA', { timeZone: zone, hourCycle: 'h23', year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit' })
      .formatToParts(new Date())
      .map((p) => [p.type, p.value]),
  );
  let p: Record<string, string>;
  try {
    p = parts(timeZone ?? undefined);
  } catch {
    p = parts();
  }
  return { date: `${p.year}-${p.month}-${p.day}`, time: `${p.hour}:${p.minute}` };
}

function validDate(v: string) {
  const ms = Date.parse(`${v}T00:00:00Z`);
  return DATE.test(v) && !Number.isNaN(ms) && new Date(ms).toISOString().slice(0, 10) === v;
}

/** A date and time from a body, defaulting to now; never later than today, never more than a year back. */
export function whenFrom(body: Record<string, unknown>, now: { date: string; time: string }) {
  const date = body.date ?? now.date;
  const time = body.time ?? (date === now.date ? now.time : '12:00');
  if (typeof date !== 'string' || !validDate(date)) throw bad('Choose a date.');
  if (date > now.date || date < addDays(now.date, -MAX_AGE_DAYS)) throw bad('Choose a date in the last year.');
  if (typeof time !== 'string' || !TIME.test(time)) throw bad('Choose a time.');
  return { date, time };
}

export function textFrom(v: unknown, what: string, max: number, required: boolean): string {
  if (v === undefined || v === null) {
    if (required) throw bad(`Give it a ${what}.`);
    return '';
  }
  if (typeof v !== 'string') throw bad(`Give it a ${what}.`);
  const s = v.replace(/\s+/g, ' ').trim();
  if (required && !s) throw bad(`Give it a ${what}.`);
  if (s.length > max) throw bad(`Keep the ${what} under ${max} characters.`);
  return s;
}

function quantityFrom(v: unknown): number {
  if (v === undefined) return 1;
  if (typeof v !== 'number' || !Number.isFinite(v) || v <= 0 || v > MAX_QUANTITY) throw bad(`Choose an amount above 0 and up to ${MAX_QUANTITY}.`);
  return Math.round(v * 100) / 100;
}

/** Amounts as typed: known keys, the ones this person can see, each within a day's ceiling. */
export function valuesFrom(v: unknown, numbers: NutritionNumbers): FoodValues {
  if (typeof v !== 'object' || v === null || Array.isArray(v)) throw bad('Amounts should be an object.');
  const out: FoodValues = {};
  for (const [k, raw] of Object.entries(v)) {
    if (!isFoodKey(k)) throw bad('Unknown amount.');
    if (!visibleKey(k, numbers)) throw bad("That amount is hidden by your Nutrition setting, so it can't be set here.");
    if (raw === null) continue;
    if (typeof raw !== 'number' || !Number.isFinite(raw) || raw < 0 || raw > KEY_MAX[k]) throw bad(`Choose an amount from 0 to ${KEY_MAX[k].toLocaleString('en-US')}.`);
    out[k] = raw;
  }
  return out;
}

// ---------- the routes ----------

export type FoodLogDeps = { estimateAvailable: () => Promise<boolean> };

/** The person, their numbers setting and their local now; refuses while Nutrition is off. */
export async function loggingContext(db: Db, hosted: boolean, res: Response) {
  const scope: Scope = { db, userId: currentUser(res).id };
  const rc = await requestContext(scope, hosted);
  const numbers = rc.settings.nutritionNumbers;
  if (!rc.settings.nutrition || !numbers) throw new HttpError(409, 'Turn on Nutrition to log food.');
  return { scope, numbers, today: rc.today, now: nowIn(rc.settings.timeZone), timeZone: rc.settings.timeZone };
}

export function foodLogRouter(db: Db, hosted: boolean, deps: FoodLogDeps) {
  const router = express.Router();

  /** The last `days` days of saved entries (default 7, at most 31) and the estimate waiting for review. */
  router.get('/', async (req, res) => {
    const scope: Scope = { db, userId: currentUser(res).id };
    const rc = await requestContext(scope, hosted);
    const numbers = rc.settings.nutritionNumbers;
    const days = Math.min(Math.max(Math.round(Number(req.query.days)) || 7, 1), 31);
    const start = addDays(rc.today, -(days - 1));
    const can = { estimate: await deps.estimateAvailable(), usda: Boolean(process.env.FDC_API_KEY) };
    if (!rc.settings.nutrition || !numbers) {
      const off: FoodLog = { enabled: false, numbers: null, today: rc.today, start, end: rc.today, entries: [], drafts: [], can };
      return void res.json(off);
    }
    await dropStaleDrafts(db, scope.userId);
    const [entries, drafts] = await Promise.all([entriesBetween(db, scope.userId, start, rc.today), draftsOf(db, scope.userId)]);
    const body: FoodLog = {
      enabled: true,
      numbers,
      today: rc.today,
      start,
      end: rc.today,
      entries: entries.map((r) => toEntry(r, numbers)),
      drafts: drafts.map((r) => toEntry(r, numbers)),
      can,
    };
    res.json(body);
  });

  /**
   * One new entry. A database food is saved by its ref and the index of the portion chosen (portionIndex), and the amounts come
   * from the server's copy, so a person who hides some numbers never receives them. Quick add sends the amounts.
   */
  router.post('/', async (req, res) => {
    const { scope, numbers, now } = await loggingContext(db, hosted, res);
    const b = (req.body ?? {}) as Record<string, unknown>;
    const id = b.id ?? randomUUID();
    if (typeof id !== 'string' || !UUID.test(id)) throw bad('That entry id looks wrong.');
    const method = b.method;
    if (method !== 'quick' && method !== 'search' && method !== 'barcode') throw bad('Choose how it was logged: quick, search or barcode.');
    const origin = b.origin === 'iphone' ? 'iphone' : 'web';
    const { date, time } = whenFrom(b, now);
    const quantity = quantityFrom(b.quantity);
    let name: string;
    let portion: string;
    let per: FoodValues;
    let ref: string | null = null;
    if (method === 'quick') {
      if (numbers === 'none') throw bad('Quick add needs amounts, and your Nutrition setting hides them. Search for the food instead.');
      per = valuesFrom(b.values ?? {}, numbers);
      if (!Object.keys(per).length) throw bad('Enter at least one amount.');
      name = textFrom(b.name, 'name', 100, false) || (Object.keys(per).length === 1 && per.water_ml !== undefined ? 'Water' : 'Quick add');
      portion = textFrom(b.portion, 'portion', 80, false);
    } else {
      if (typeof b.ref !== 'string') throw bad('Choose a food.');
      const food: Food | null = await cachedFood(db, b.ref);
      if (!food) throw bad('That food is no longer available. Search for it again.');
      const index = b.portionIndex ?? 0;
      if (typeof index !== 'number' || !Number.isInteger(index) || index < 0 || index >= food.portions.length) throw bad('Choose a portion.');
      ref = food.ref;
      name = textFrom(b.name, 'name', 100, false) || food.name.slice(0, 100);
      portion = food.portions[index].label;
      per = portionValues(food, index);
    }
    await insertEntries(db, scope.userId, [{ id, date, time, name, portion, quantity, per, method, ref, origin }], false);
    await bumpDataVersion(db, scope.userId);
    const row = await entryById(db, scope.userId, id);
    res.status(201).json(toEntry(row!, numbers));
  });

  /**
   * Change an entry or a draft. Amounts sent are the whole entry's, for the visible keys only; the rest are kept,
   * and a new quantity scales them all, so hidden numbers stay right without ever being sent.
   */
  router.patch('/:id', async (req, res) => {
    const { scope, numbers, now } = await loggingContext(db, hosted, res);
    const row = await entryById(db, scope.userId, String(req.params.id));
    if (!row) throw new HttpError(404, 'That entry is gone.');
    const b = (req.body ?? {}) as Record<string, unknown>;
    const when = b.date !== undefined || b.time !== undefined ? whenFrom({ date: b.date ?? row.date, time: b.time ?? row.time }, now) : { date: row.date, time: row.time };
    const name = b.name !== undefined ? textFrom(b.name, 'name', 100, true) : row.name;
    const portion = b.portion !== undefined ? textFrom(b.portion, 'portion', 80, false) : row.portion;
    const quantity = b.quantity !== undefined ? quantityFrom(b.quantity) : Number(row.quantity);
    const per = readPer(row.per);
    if (b.values !== undefined) {
      if (numbers === 'none') throw bad("Your Nutrition setting hides amounts, so they can't be changed here.");
      const typed = valuesFrom(b.values, numbers);
      for (const k of Object.keys(b.values as object) as FoodKey[]) {
        if (typed[k] === undefined) delete per[k];
        else per[k] = typed[k]! / quantity;
      }
    }
    await db.query(
      `UPDATE food_log SET date = $3, time = $4, name = $5, portion = $6, quantity = $7, per = $8, version = version + 1, updated_at = $9
       WHERE user_id = $1 AND id = $2`,
      [scope.userId, row.id, when.date, when.time, name, portion, quantity, JSON.stringify(per), Date.now()],
    );
    if (!row.draft) await bumpDataVersion(db, scope.userId);
    res.json(toEntry((await entryById(db, scope.userId, row.id))!, numbers));
  });

  router.delete('/:id', async (req, res) => {
    const { scope } = await loggingContext(db, hosted, res);
    const gone = await db.query<{ draft: boolean }>('DELETE FROM food_log WHERE user_id = $1 AND id = $2 RETURNING draft', [scope.userId, String(req.params.id)]);
    if (gone.some((r) => !r.draft)) await bumpDataVersion(db, scope.userId);
    res.json({ deleted: gone.length });
  });

  /** Save drafts (McFly's estimate, as reviewed): from now on they count. Drafts not named are discarded. */
  router.post('/save', async (req, res) => {
    const { scope, numbers } = await loggingContext(db, hosted, res);
    const ids = (req.body as { ids?: unknown } | undefined)?.ids;
    if (!Array.isArray(ids) || ids.length > 50 || ids.some((i) => typeof i !== 'string')) throw bad('Choose what to save.');
    const saved = await db.tx(async (q) => {
      const rows = await q.query<Row>(
        `UPDATE food_log SET draft = false, updated_at = $3 WHERE user_id = $1 AND draft AND id = ANY($2) RETURNING ${COLUMNS}`,
        [scope.userId, ids, Date.now()],
      );
      await q.query('DELETE FROM food_log WHERE user_id = $1 AND draft', [scope.userId]);
      return rows;
    });
    if (saved.length) await bumpDataVersion(db, scope.userId);
    res.json({ entries: saved.map((r) => toEntry(r, numbers)) });
  });

  /** Throw the estimate away. */
  router.post('/discard', async (_req, res) => {
    const { scope } = await loggingContext(db, hosted, res);
    const gone = await db.query('DELETE FROM food_log WHERE user_id = $1 AND draft RETURNING 1', [scope.userId]);
    res.json({ deleted: gone.length });
  });

  return router;
}

export { toEntry as foodEntryOf, draftsOf };
