// Incremental Apple Health pushes from the iOS companion app (ios/). The app aggregates
// HealthKit samples on the phone into the same per-day rows the export importer writes,
// and posts the days that changed. Unlike an import, a push never clears earlier data.

import { createHash, timingSafeEqual } from 'node:crypto';
import express, { type NextFunction, type Request, type Response } from 'express';
import { type DailyRow, type Db, type EventRow, OWNER_ID, type Scope, type WorkoutRow, setUserSetting, upsertDaily, upsertEvents, upsertWorkouts } from '../db.ts';
import { SOURCE } from './import.ts';

/** Daily metrics the importer produces (server/apple/import.ts). Anything else is a client bug. */
export const APPLE_METRICS = new Set([
  'steps',
  'active_energy',
  'exercise_min',
  'distance_km',
  'hr_avg',
  'hr_min',
  'hr_max',
  'resting_hr',
  'hrv_sdnn',
  'hrv_rmssd_watch',
  'spo2',
  'resp_rate',
  'wrist_temp',
  'body_temp',
  'weight',
  'body_fat',
  'lean_mass',
  'vo2max',
  'sleep_hours',
  'sleep_in_bed',
  'sleep_deep',
  'sleep_rem',
  'sleep_light',
  'sleep_awake',
]);

const MAX_ROWS = 100_000;
const DATE = /^\d{4}-\d{2}-\d{2}$/;
const ISO = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?(?:Z|[+-]\d{2}:\d{2})$/;
const EVENT_KINDS = new Set(['sleep', 'nap', 'mindful']);

export type IngestPayload = {
  daily: DailyRow[];
  workouts: WorkoutRow[];
  events: EventRow[];
  /** Ids of workouts and mindful sessions the app sent earlier that were since deleted in Health. */
  deleted: { workouts: string[]; events: string[] };
};
export type IngestResult = { daily: number; workouts: number; events: number; deleted: number };

export class IngestError extends Error {}

function fail(path: string, message: string): never {
  throw new IngestError(`${path}: ${message}`);
}

function record(v: unknown, path: string): Record<string, unknown> {
  if (typeof v !== 'object' || v === null || Array.isArray(v)) fail(path, 'expected an object');
  return v as Record<string, unknown>;
}

function list(body: Record<string, unknown>, key: string): unknown[] {
  const v = body[key];
  if (v === undefined) return [];
  if (!Array.isArray(v)) fail(key, 'expected an array');
  if (v.length > MAX_ROWS) fail(key, `at most ${MAX_ROWS} rows per request`);
  return v;
}

function text(v: unknown, path: string, max = 100): string {
  if (typeof v !== 'string' || v.length === 0 || v.length > max) fail(path, `expected a string of 1-${max} characters`);
  return v;
}

function date(v: unknown, path: string): string {
  const ms = typeof v === 'string' && DATE.test(v) ? Date.parse(v + 'T00:00:00Z') : NaN;
  // Date.parse rolls 2026-02-30 over to March; the round trip catches that.
  if (Number.isNaN(ms) || new Date(ms).toISOString().slice(0, 10) !== v) fail(path, 'expected a date as YYYY-MM-DD');
  return v as string;
}

function iso(v: unknown, path: string): string {
  if (typeof v !== 'string' || !ISO.test(v) || Number.isNaN(Date.parse(v))) fail(path, 'expected an ISO timestamp with offset, e.g. 2026-10-14T06:45:00-07:00');
  return v;
}

function num(v: unknown, path: string): number {
  if (typeof v !== 'number' || !Number.isFinite(v)) fail(path, 'expected a finite number');
  return v;
}

function optNum(v: unknown, path: string): number | null {
  return v === undefined || v === null ? null : num(v, path);
}

/** Validates a request body. Rows are re-tagged with source 'apple' whatever the client sent. */
export function parseIngest(body: unknown): IngestPayload {
  const b = record(body, 'body');
  const daily = list(b, 'daily').map((raw, i): DailyRow => {
    const p = `daily[${i}]`;
    const r = record(raw, p);
    const metric = text(r.metric, `${p}.metric`, 40);
    if (!APPLE_METRICS.has(metric)) fail(`${p}.metric`, `unknown metric "${metric}"`);
    return { date: date(r.date, `${p}.date`), metric, source: SOURCE, value: num(r.value, `${p}.value`) };
  });
  const workouts = list(b, 'workouts').map((raw, i): WorkoutRow => {
    const p = `workouts[${i}]`;
    const r = record(raw, p);
    const duration = num(r.duration_min, `${p}.duration_min`);
    if (duration < 0) fail(`${p}.duration_min`, 'must not be negative');
    return {
      id: text(r.id, `${p}.id`),
      source: SOURCE,
      sport: text(r.sport, `${p}.sport`),
      start: iso(r.start, `${p}.start`),
      end: iso(r.end, `${p}.end`),
      date: date(r.date, `${p}.date`),
      duration_min: duration,
      energy_kcal: optNum(r.energy_kcal, `${p}.energy_kcal`),
      distance_m: optNum(r.distance_m, `${p}.distance_m`),
      avg_hr: optNum(r.avg_hr, `${p}.avg_hr`),
      max_hr: optNum(r.max_hr, `${p}.max_hr`),
      strain: optNum(r.strain, `${p}.strain`),
    };
  });
  const events = list(b, 'events').map((raw, i): EventRow => {
    const p = `events[${i}]`;
    const r = record(raw, p);
    if (typeof r.kind !== 'string' || !EVENT_KINDS.has(r.kind)) fail(`${p}.kind`, 'expected sleep, nap or mindful');
    return {
      id: text(r.id, `${p}.id`),
      source: SOURCE,
      kind: r.kind as EventRow['kind'],
      title: text(r.title, `${p}.title`),
      start: iso(r.start, `${p}.start`),
      end: iso(r.end, `${p}.end`),
      date: date(r.date, `${p}.date`),
    };
  });
  const gone = b.deleted === undefined ? {} : record(b.deleted, 'deleted');
  const deletedIds = (key: 'workouts' | 'events') =>
    list(gone, key).map((raw, i) => {
      const id = text(raw, `deleted.${key}[${i}]`);
      // The app can only remove what it sent itself, never imported or WHOOP rows.
      if (!id.startsWith('hk-')) fail(`deleted.${key}[${i}]`, 'only ids starting with hk- can be deleted');
      return id;
    });
  return { daily, workouts, events, deleted: { workouts: deletedIds('workouts'), events: deletedIds('events') } };
}

/** Upserts a validated push. Each daily row is a complete recomputed day, so it replaces the stored value. */
export async function ingestApple(scope: Scope, p: IngestPayload): Promise<IngestResult> {
  const { db, userId } = scope;
  // The app ids workouts and mindful sessions by HealthKit UUID ("hk-..."). The same record from an
  // earlier export.zip import has a hashed id instead, so match it by start instant and replace it.
  // Compare instants, not text: the export writes every date with one fixed UTC offset.
  const sameInstant = 'abs(extract(epoch from (start::timestamptz - $3::timestamptz))) < 1';

  let deleted = 0;
  await db.tx(async (q) => {
    for (const id of p.deleted.workouts) {
      deleted += (await q.query('DELETE FROM workouts WHERE user_id = $1 AND source = $2 AND id = $3 RETURNING 1', [userId, SOURCE, id])).length;
    }
    for (const id of p.deleted.events) {
      deleted += (await q.query('DELETE FROM events WHERE user_id = $1 AND source = $2 AND id = $3 RETURNING 1', [userId, SOURCE, id])).length;
    }
    await upsertDaily(q, userId, p.daily);
    for (const w of p.workouts) {
      if (w.id.startsWith('hk-')) {
        await q.query(
          `DELETE FROM workouts WHERE user_id = $1 AND source = $2 AND id NOT LIKE 'hk-%' AND sport = $4 AND ${sameInstant}`,
          [userId, SOURCE, w.start, w.sport],
        );
      }
    }
    await upsertWorkouts(q, userId, p.workouts);
    for (const e of p.events) {
      // Like the importer, keep one Apple sleep event per night: if another source now wins the night, drop the old one.
      if (e.kind === 'sleep') {
        await q.query("DELETE FROM events WHERE user_id = $1 AND source = $2 AND kind = 'sleep' AND date = $3 AND id <> $4", [userId, SOURCE, e.date, e.id]);
      } else if (e.kind === 'mindful' && e.id.startsWith('hk-')) {
        await q.query(`DELETE FROM events WHERE user_id = $1 AND source = $2 AND kind = 'mindful' AND id NOT LIKE 'hk-%' AND ${sameInstant}`, [userId, SOURCE, e.start]);
      }
    }
    await upsertEvents(q, userId, p.events);
  });
  const result = { daily: p.daily.length, workouts: p.workouts.length, events: p.events.length, deleted };
  if (result.daily + result.workouts + result.events + deleted > 0) {
    await setUserSetting(db, userId, 'apple_last_sync', JSON.stringify({ ...result, syncedAt: new Date().toISOString() }));
  }
  return result;
}

function tokenMatches(given: string, expected: string) {
  // Hash both sides so the comparison is constant-time regardless of length.
  const digest = (s: string) => createHash('sha256').update(s).digest();
  return timingSafeEqual(digest(given), digest(expected));
}

/**
 * Which account an ingest token belongs to. Each person creates their own token in Settings (only its
 * hash is stored); the server-wide HEALTHOS_INGEST_TOKEN, from before healthOS was multi-user, is the owner's.
 */
async function tokenUser(db: Db, given: string, ownerToken: string | undefined): Promise<string | null> {
  if (ownerToken && tokenMatches(given, ownerToken)) return OWNER_ID;
  const [row] = await db.query<{ id: string }>("SELECT id FROM users WHERE ingest_token_hash = $1 AND status = 'active'", [
    createHash('sha256').update(given).digest('hex'),
  ]);
  return row?.id ?? null;
}

/**
 * POST /apple/ingest. Always requires `Authorization: Bearer <token>`: a person's own token from Settings,
 * or the server-wide HEALTHOS_INGEST_TOKEN for the owner. Mounted on the server and, in LAN mode, on its
 * own listener (see lanIngestApp).
 */
export function ingestRouter(db: Db, ownerToken: string | undefined) {
  const router = express.Router();

  const auth = async (req: Request, res: Response, next: NextFunction) => {
    try {
      const m = /^Bearer (.+)$/.exec(req.headers.authorization ?? '');
      const userId = m ? await tokenUser(db, m[1].trim(), ownerToken) : null;
      if (!userId) {
        return void res.status(401).set('WWW-Authenticate', 'Bearer').json({ error: 'Missing or wrong ingest token' });
      }
      res.locals.ingestUser = userId;
      next();
    } catch (err) {
      next(err);
    }
  };

  // A first sync sends years of history in chunks; each chunk can be well over express.json's 100 kB default.
  router.post('/apple/ingest', auth, express.json({ limit: '25mb' }), async (req, res) => {
    let payload: IngestPayload;
    try {
      payload = parseIngest(req.body);
    } catch (err) {
      if (err instanceof IngestError) return void res.status(400).json({ error: err.message });
      throw err;
    }
    res.json({ ok: true, ...(await ingestApple({ db, userId: res.locals.ingestUser as string }, payload)) });
  });

  router.use((err: Error & { status?: number }, _req: Request, res: Response, _next: NextFunction) => {
    const status = err.status && err.status >= 400 && err.status < 500 ? err.status : 500;
    if (status === 500) console.error(err);
    res.status(status).json({ error: status === 413 ? 'Request too large' : err.message });
  });

  return router;
}

/** The LAN listener: only the ingest endpoint, nothing that reads health data. */
export function lanIngestApp(db: Db, token: string) {
  const app = express();
  app.disable('x-powered-by');
  app.use('/api', ingestRouter(db, token));
  app.use((_req, res) => void res.status(404).json({ error: 'Not found' }));
  return app;
}
