// Body measurements a person adds themselves (body_entries): weight, body fat and lean mass from a scale, a scan or
// their records, stored in kg and %. Every write sets that day's `daily` row for source 'manual' to the day's latest
// entry, or removes it once the day has none, in the same transaction; so charts, sheets, the summary and McFly read
// a typed weigh-in like a scale's, and it wins its day over a device's (query.ts, MANUAL_FIRST).
// Read and written for the signed-in person only. Nothing here logs a value or a note: errors log their kind alone.
import { randomUUID } from 'node:crypto';
import express, { type NextFunction, type Request, type Response } from 'express';
import { BODY_METHODS, BODY_METRICS, type BodyEntries, type BodyEntry, type BodyLatest, type BodyMethod, type BodyMetric, type BodySource, LB_PER_KG } from '../shared/body.ts';
import { currentUser } from './auth.ts';
import { addDays } from './dates.ts';
import { type Db, type Queryable, type Scope, bumpDataVersion, upsertDaily } from './db.ts';
import { loadDaily, requestContext, valueOn } from './query.ts';

type Row = { id: string; metric: BodyMetric; value: number; date: string; time: string | null; method: BodyMethod; note: string; created_at: number };

const METRICS = BODY_METRICS.map((m) => m.metric);
const METHODS: BodyMethod[] = [...BODY_METHODS.map((m) => m.method), 'other'];
const SPEC = Object.fromEntries(BODY_METRICS.map((m) => [m.metric, m])) as Record<BodyMetric, (typeof BODY_METRICS)[number]>;
/** "a weight", "a body fat", "a lean body mass": how the messages name each metric. */
const NAME: Record<BodyMetric, string> = { weight: 'weight', body_fat: 'body fat', lean_mass: 'lean body mass' };
const NOTE_MAX = 200;
/** The window the cards read: long enough to find a weigh-in a month before one that's a few weeks old. */
const LATEST_DAYS = 120;
const DATE = /^\d{4}-\d{2}-\d{2}$/;
const TIME = /^([01]\d|2[0-3]):[0-5]\d$/;

/** A real calendar day as YYYY-MM-DD (Date.parse rolls 2026-02-30 over to March; the round trip catches that). */
function validDate(v: unknown): v is string {
  if (typeof v !== 'string' || !DATE.test(v)) return false;
  const ms = Date.parse(`${v}T00:00:00Z`);
  return !Number.isNaN(ms) && new Date(ms).toISOString().slice(0, 10) === v;
}

const toEntry = (r: Row): BodyEntry => ({
  id: r.id,
  metric: r.metric,
  value: Number(r.value),
  date: r.date,
  time: r.time,
  method: r.method,
  note: r.note,
  createdAt: Number(r.created_at),
});

class BodyInputError extends Error {}
function fail(message: string): never {
  throw new BodyInputError(message);
}

/**
 * An entry as sent, checked and in stored units (kg, %): the metric, its value within the metric's range after a
 * pound value is converted, a date from 1900 to the person's today, an optional HH:MM time, where it's from, and a
 * short note. Messages name the field and its range, never the value sent.
 */
function parseEntry(raw: Record<string, unknown>, today: string) {
  const metric = METRICS.find((m) => m === raw.metric) ?? fail('Choose weight, body fat or lean body mass.');
  const spec = SPEC[metric];
  const unit = raw.unit ?? spec.unit;
  const units = spec.unit === '%' ? ['%'] : ['kg', 'lb'];
  if (typeof unit !== 'string' || !units.includes(unit)) fail(spec.unit === '%' ? 'Body fat is a percentage.' : 'Choose kg or lb.');
  if (typeof raw.value !== 'number' || !Number.isFinite(raw.value)) fail(`Enter your ${NAME[metric]} as a number.`);
  const value = unit === 'lb' ? (raw.value as number) / LB_PER_KG : (raw.value as number);
  if (value < spec.min || value > spec.max) {
    const range = unit === 'lb' ? `${Math.ceil(spec.min * LB_PER_KG)} and ${Math.floor(spec.max * LB_PER_KG)} lb` : unit === '%' ? `${spec.min} and ${spec.max}%` : `${spec.min} and ${spec.max} kg`;
    fail(`Enter a ${NAME[metric]} between ${range}.`);
  }
  if (!validDate(raw.date)) fail('Enter the date as YYYY-MM-DD.');
  const date = raw.date as string;
  if (date > today) fail("That day hasn't happened yet.");
  if (date < '1900-01-01') fail('Enter a date from 1900 on.');
  const time = raw.time === undefined || raw.time === null || raw.time === '' ? null : raw.time;
  if (time !== null && (typeof time !== 'string' || !TIME.test(time))) fail('Enter the time as HH:MM, or leave it empty.');
  const method = raw.method === undefined || raw.method === null ? 'other' : (METHODS.find((m) => m === raw.method) ?? fail('Choose Scale, Scan or Records.'));
  if (raw.note !== undefined && raw.note !== null && typeof raw.note !== 'string') fail('The note should be text.');
  const note = typeof raw.note === 'string' ? raw.note.trim() : '';
  if (note.length > NOTE_MAX) fail(`Keep the note to ${NOTE_MAX} characters.`);
  // To the gram (or a thousandth of a point): enough to give back what was typed in pounds.
  return { metric, value: Math.round(value * 1000) / 1000, date, time: time as string | null, method, note };
}

/**
 * The day's `daily` row for source 'manual': the day's latest entry for the metric, by time and then by when it was
 * added. An entry without a time counts as earlier in the day than one with a time. No entry left, no row.
 */
async function project(q: Queryable, userId: string, date: string, metric: BodyMetric) {
  const [last] = await q.query<{ value: number }>(
    'SELECT value FROM body_entries WHERE user_id = $1 AND date = $2 AND metric = $3 ORDER BY time DESC NULLS LAST, created_at DESC, id DESC LIMIT 1',
    [userId, date, metric],
  );
  if (last) await upsertDaily(q, userId, [{ date, metric, source: 'manual', value: Number(last.value) }]);
  else await q.query("DELETE FROM daily WHERE user_id = $1 AND date = $2 AND metric = $3 AND source = 'manual'", [userId, date, metric]);
}

export function bodyRouter(db: Db, hosted: boolean) {
  const router = express.Router();
  const scopeOf = (res: Response): Scope => ({ db, userId: currentUser(res).id });

  /**
   * While the local owner's demo data is showing, their own rows are hidden (query.ts sourceList), so an entry would
   * vanish as it's saved: writes are refused until the demo is off. Returns the person's today otherwise.
   */
  async function writable(scope: Scope, res: Response): Promise<string | null> {
    const { demo, today } = await requestContext(scope, hosted);
    if (!demo) return today;
    res.status(409).json({ error: 'Turn off demo data in your Profile to add your own measurements.' });
    return null;
  }

  /** Your entries, newest first: one metric or all three, over the last `days` days (a year by default). */
  router.get('/entries', async (req, res) => {
    const scope = scopeOf(res);
    const metric = req.query.metric;
    if (metric !== undefined && !METRICS.some((m) => m === metric)) return void res.status(400).json({ error: 'metric: expected weight, body_fat or lean_mass' });
    const days = Math.min(Math.max(Number(req.query.days) || 365, 1), 36_500);
    const { demo, today } = await requestContext(scope, hosted);
    // The demo hides a person's own rows everywhere else, so the list does too.
    if (demo) return void res.json({ entries: [] } satisfies BodyEntries);
    const rows = await db.query<Row>(
      `SELECT id, metric, value, date, time, method, note, created_at FROM body_entries WHERE user_id = $1 AND date >= $2 ${metric ? 'AND metric = $3' : ''}
       ORDER BY date DESC, time DESC NULLS LAST, created_at DESC, id DESC`,
      metric ? [scope.userId, addDays(today, -(days - 1)), metric] : [scope.userId, addDays(today, -(days - 1))],
    );
    res.json({ entries: rows.map(toEntry) } satisfies BodyEntries);
  });

  /** Each metric's latest value as the charts show it, and which source it came from, for the Body cards' footers. */
  router.get('/latest', async (req, res) => {
    const scope = scopeOf(res);
    const { demo, today } = await requestContext(scope, hosted);
    const asOf = validDate(req.query.date) && req.query.date <= today ? req.query.date : today;
    const daily = await loadDaily(scope, demo, addDays(asOf, -(LATEST_DAYS - 1)), asOf, METRICS);
    const ctx = { daily, demo };
    const latest = Object.fromEntries(
      METRICS.map((metric) => {
        const dates = [...(daily.get(metric)?.values() ?? [])].flatMap((byDate) => [...byDate.keys()]).sort();
        const date = dates.at(-1);
        const v = date ? valueOn(ctx, metric, date) : undefined;
        return [metric, date && v ? { date, value: v.value, source: v.source as BodySource } : null];
      }),
    ) as BodyLatest;
    res.json(latest);
  });

  router.post('/entries', async (req, res) => {
    const scope = scopeOf(res);
    const today = await writable(scope, res);
    if (!today) return;
    const body = req.body as unknown;
    if (typeof body !== 'object' || body === null || Array.isArray(body)) return void res.status(400).json({ error: 'Expected an entry.' });
    const e = parseEntry(body as Record<string, unknown>, today);
    const row: Row = { id: randomUUID(), ...e, created_at: Date.now() };
    await db.tx(async (q) => {
      await q.query(
        'INSERT INTO body_entries (user_id, id, date, time, metric, value, method, note, created_at, updated_at) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $9)',
        [scope.userId, row.id, row.date, row.time, row.metric, row.value, row.method, row.note, row.created_at],
      );
      await project(q, scope.userId, row.date, row.metric);
    });
    await bumpDataVersion(db, scope.userId);
    res.json({ entry: toEntry(row) });
  });

  /** Change one of your entries: the fields sent replace the stored ones, and the whole entry is checked again. */
  router.patch('/entries/:id', async (req, res) => {
    const scope = scopeOf(res);
    const today = await writable(scope, res);
    if (!today) return;
    const [old] = await db.query<Row>('SELECT id, metric, value, date, time, method, note, created_at FROM body_entries WHERE user_id = $1 AND id = $2', [scope.userId, req.params.id]);
    if (!old) return void res.status(404).json({ error: 'No such entry' });
    const patch = req.body as unknown;
    if (typeof patch !== 'object' || patch === null || Array.isArray(patch)) return void res.status(400).json({ error: 'Expected the fields to change.' });
    const p = patch as Record<string, unknown>;
    // The stored value is in kg or %: a unit applies only to a value sent with it.
    const merged = { metric: old.metric, date: old.date, time: old.time, method: old.method, note: old.note, ...p, ...('value' in p ? {} : { value: Number(old.value), unit: undefined }) };
    const e = parseEntry(merged, today);
    await db.tx(async (q) => {
      await q.query('UPDATE body_entries SET metric = $3, value = $4, date = $5, time = $6, method = $7, note = $8, updated_at = $9 WHERE user_id = $1 AND id = $2', [
        scope.userId,
        old.id,
        e.metric,
        e.value,
        e.date,
        e.time,
        e.method,
        e.note,
        Date.now(),
      ]);
      // The day it left as well as the day it's on now, when it moved.
      await project(q, scope.userId, e.date, e.metric);
      if (old.date !== e.date || old.metric !== e.metric) await project(q, scope.userId, old.date, old.metric);
    });
    await bumpDataVersion(db, scope.userId);
    res.json({ entry: toEntry({ ...old, ...e }) });
  });

  router.delete('/entries/:id', async (req, res) => {
    const scope = scopeOf(res);
    if (!(await writable(scope, res))) return;
    const gone = await db.tx(async (q) => {
      const [row] = await q.query<{ date: string; metric: BodyMetric }>('DELETE FROM body_entries WHERE user_id = $1 AND id = $2 RETURNING date, metric', [scope.userId, req.params.id]);
      if (row) await project(q, scope.userId, row.date, row.metric);
      return row;
    });
    if (!gone) return void res.status(404).json({ error: 'No such entry' });
    await bumpDataVersion(db, scope.userId);
    res.json({ deleted: 1 });
  });

  router.use((err: Error & { status?: number }, _req: Request, res: Response, _next: NextFunction) => {
    if (err instanceof BodyInputError) return void res.status(400).json({ error: err.message });
    if (err.status && err.status >= 400 && err.status < 500) return void res.status(err.status).json({ error: 'Bad request' });
    // The kind of failure only: a database error's text can quote the values it was given.
    console.error('body:', err.name);
    res.status(500).json({ error: 'Something went wrong' });
  });

  return router;
}
