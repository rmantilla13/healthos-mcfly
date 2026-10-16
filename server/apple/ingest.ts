// Incremental Apple Health pushes from the iOS companion app (ios/). The app aggregates
// HealthKit samples on the phone into the same per-day rows the export importer writes,
// and posts the days that changed. Unlike an import, a push never clears earlier data.

import { createHash, timingSafeEqual } from 'node:crypto';
import express, { type NextFunction, type Request, type Response } from 'express';
import { type Db, type DailyRow, type EventRow, type WorkoutRow, setSetting, transaction, upsertDaily, upsertEvents, upsertWorkouts } from '../db.ts';
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

export type IngestPayload = { daily: DailyRow[]; workouts: WorkoutRow[]; events: EventRow[] };
export type IngestResult = { daily: number; workouts: number; events: number };

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
  return { daily, workouts, events };
}

/** Upserts a validated push. Each daily row is a complete recomputed day, so it replaces the stored value. */
export function ingestApple(db: Db, p: IngestPayload): IngestResult {
  transaction(db, () => {
    upsertDaily(db, p.daily);
    upsertWorkouts(db, p.workouts);
    // Like the importer, keep one Apple sleep event per night: if another source now wins the night, drop the old one.
    const dropSleep = db.prepare("DELETE FROM events WHERE source = ? AND kind = 'sleep' AND date = ? AND id <> ?");
    for (const e of p.events) if (e.kind === 'sleep') dropSleep.run(SOURCE, e.date, e.id);
    upsertEvents(db, p.events);
  });
  const result = { daily: p.daily.length, workouts: p.workouts.length, events: p.events.length };
  if (result.daily + result.workouts + result.events > 0) {
    setSetting(db, 'apple_last_sync', JSON.stringify({ ...result, syncedAt: new Date().toISOString() }));
  }
  return result;
}

function tokenMatches(given: string, expected: string) {
  // Hash both sides so the comparison is constant-time regardless of length.
  const digest = (s: string) => createHash('sha256').update(s).digest();
  return timingSafeEqual(digest(given), digest(expected));
}

/**
 * POST /apple/ingest. Always requires `Authorization: Bearer <HEALTHOS_INGEST_TOKEN>`;
 * with no token configured the endpoint is off. Mounted on the localhost server and,
 * in LAN mode, on its own listener (see lanIngestApp).
 */
export function ingestRouter(db: Db, token: string | undefined) {
  const router = express.Router();

  const auth = (req: Request, res: Response, next: NextFunction) => {
    if (!token) return void res.status(503).json({ error: 'Ingest is off. Set HEALTHOS_INGEST_TOKEN in .env and restart the server.' });
    const m = /^Bearer (.+)$/.exec(req.headers.authorization ?? '');
    if (!m || !tokenMatches(m[1].trim(), token)) {
      return void res.status(401).set('WWW-Authenticate', 'Bearer').json({ error: 'Missing or wrong ingest token' });
    }
    next();
  };

  // A first sync sends years of history in chunks; each chunk can be well over express.json's 100 kB default.
  router.post('/apple/ingest', auth, express.json({ limit: '25mb' }), (req, res) => {
    let payload: IngestPayload;
    try {
      payload = parseIngest(req.body);
    } catch (err) {
      if (err instanceof IngestError) return void res.status(400).json({ error: err.message });
      throw err;
    }
    res.json({ ok: true, ...ingestApple(db, payload) });
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
