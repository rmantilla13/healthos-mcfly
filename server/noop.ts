// A WHOOP strap read by NOOP (github.com/ryanbr/noop), from NOOP's CSV export: read in the browser
// (src/import/noop.ts) and sent here in chunks as source 'noop' (shared/noop.ts). Only per-day readings, each night's
// start and end, and workouts arrive. Mounted before the general JSON parser, since a chunk can be a few MB.
//
//   POST /ingest          from the iPhone app, which reads the strap itself (ingest token, not a session; mounted with
//                         the Apple Health ingest): a window of days whose strap rows it replaces
//   POST /import          one chunk of a NOOP export: daily rows, nights and workouts are upserted, so importing a newer
//                         export updates the days it shares with an older one and keeps the rest
//   POST /import/finish   the summary of every NOOP day stored, shown on Integrations (Status.noop.lastImport)
//   POST /clear           every NOOP row and both summaries go; other sources are untouched
import express, { type NextFunction, type Request, type Response } from 'express';
import { NOOP_CHUNK, NOOP_FIRST_DATE, NOOP_INGEST_MAX_DAYS, NOOP_METRICS, NOOP_RANGES, NOOP_STAGES, type NoopMetric, inNoopRange } from '../shared/noop.ts';
import type { NoopImportSummary, NoopSyncSummary } from '../shared/types.ts';
import { ingestAuth } from './apple/ingest.ts';
import { currentUser } from './auth.ts';
import {
  type DailyRow,
  type Db,
  type EventRow,
  type Queryable,
  type SleepStageRow,
  type WorkoutRow,
  bumpDataVersion,
  deleteSource,
  replaceSleepStages,
  setUserSetting,
  upsertDaily,
  upsertEvents,
  upsertWorkouts,
} from './db.ts';

export const NOOP = 'noop';

const MAX_BODY = '4mb';
const MAX_SPAN_MS = 24 * 3_600_000;
const DATE = /^\d{4}-\d{2}-\d{2}$/;
const ISO = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?(?:Z|[+-]\d{2}:\d{2})$/;
const METRICS = new Set<string>(NOOP_METRICS);
const STAGES = new Set<string>(NOOP_STAGES);

class ChunkError extends Error {}

function fail(path: string, message: string): never {
  throw new ChunkError(`${path}: ${message}`);
}

function record(v: unknown, path: string): Record<string, unknown> {
  if (typeof v !== 'object' || v === null || Array.isArray(v)) fail(path, 'expected an object');
  return v as Record<string, unknown>;
}

function list(v: unknown, path: string, max: number): unknown[] {
  if (v === undefined) return [];
  if (!Array.isArray(v)) fail(path, 'expected an array');
  if (v.length > max) fail(path, `at most ${max} per request`);
  return v;
}

/** The latest date a reading can have: tomorrow in UTC covers every time zone's today. */
const latestDate = () => new Date(Date.now() + 86_400_000).toISOString().slice(0, 10);

function date(v: unknown, path: string, latest: string): string {
  const ms = typeof v === 'string' && DATE.test(v) ? Date.parse(v + 'T00:00:00Z') : NaN;
  if (Number.isNaN(ms) || new Date(ms).toISOString().slice(0, 10) !== v) fail(path, 'expected a date as YYYY-MM-DD');
  if (v < NOOP_FIRST_DATE || v > latest) fail(path, `${v} is outside the dates a WHOOP strap reading can have`);
  return v;
}

function iso(v: unknown, path: string): string {
  if (typeof v !== 'string' || !ISO.test(v) || Number.isNaN(Date.parse(v))) fail(path, 'expected an ISO timestamp with offset, e.g. 2026-10-14T06:45:00-07:00');
  return v;
}

/** A start and end within a day of each other, end after start. */
function span(start: unknown, end: unknown, path: string) {
  const s = iso(start, `${path}.start`);
  const e = iso(end, `${path}.end`);
  const ms = Date.parse(e) - Date.parse(s);
  if (ms <= 0 || ms > MAX_SPAN_MS) fail(`${path}.end`, 'expected an end after the start, within a day');
  return { start: s, end: e, ms };
}

/** null, or a number within [lo, hi]. */
function optional(v: unknown, path: string, lo: number, hi: number): number | null {
  if (v === null || v === undefined) return null;
  if (typeof v !== 'number' || !Number.isFinite(v) || v < lo || v > hi) fail(path, `expected null or a number from ${lo} to ${hi}`);
  return v;
}

const slug = (s: string) =>
  s
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-|-$/g, '')
    .slice(0, 40) || 'activity';

/** `stages`: the nights that came with their stages, each replacing that night's strap stages. `dropped`: stretches left out. */
export type ParsedNoopChunk = { daily: DailyRow[]; events: EventRow[]; workouts: WorkoutRow[]; stages: { date: string; segments: SleepStageRow[] }[]; dropped: number };

/**
 * Checks a chunk (a NoopChunk, shared/noop.ts). A wrong shape, an unknown metric, a value no strap could record or a date
 * outside 2015..tomorrow fails the whole chunk: the browser reader applies the same ranges, so one is a bug.
 */
export function parseNoopChunk(body: unknown): ParsedNoopChunk {
  const b = record(body, 'body');
  const latest = latestDate();
  const daily = list(b.daily, 'daily', NOOP_CHUNK.rows).map((raw, i): DailyRow => {
    const p = `daily[${i}]`;
    const r = record(raw, p);
    if (typeof r.metric !== 'string' || !METRICS.has(r.metric)) fail(`${p}.metric`, `unknown metric "${String(r.metric).slice(0, 40)}"`);
    const metric = r.metric as NoopMetric;
    if (typeof r.value !== 'number' || !inNoopRange(metric, r.value)) {
      const [lo, hi] = NOOP_RANGES[metric];
      fail(`${p}.value`, `expected a number from ${lo} to ${hi} for ${metric}`);
    }
    return { date: date(r.date, `${p}.date`, latest), metric, source: NOOP, value: r.value };
  });

  const seen = new Set<string>();
  const stages: ParsedNoopChunk['stages'] = [];
  let dropped = 0;
  const events = list(b.sleep, 'sleep', NOOP_CHUNK.nights).map((raw, i): EventRow => {
    const p = `sleep[${i}]`;
    const n = record(raw, p);
    const d = date(n.date, `${p}.date`, latest);
    if (seen.has(d)) fail(`${p}.date`, `${d} appears twice`);
    seen.add(d);
    const { start, end } = span(n.start, n.end, p);
    if (n.segments !== undefined) {
      // Stages from the strap: one that's merely bad (empty, longer than a night, overlapping the one before) is left
      // out, as the Fitbit import and the iPhone ingest do.
      const segments = list(n.segments, `${p}.segments`, NOOP_CHUNK.stagesPerNight)
        .map((rawSeg, j) => {
          const sp = `${p}.segments[${j}]`;
          const g = record(rawSeg, sp);
          if (typeof g.stage !== 'string' || !STAGES.has(g.stage)) fail(`${sp}.stage`, 'expected awake, rem, light, deep or asleep');
          return { start: iso(g.start, `${sp}.start`), end: iso(g.end, `${sp}.end`), stage: g.stage };
        })
        .sort((x, y) => Date.parse(x.start) - Date.parse(y.start));
      const kept: SleepStageRow[] = [];
      for (const g of segments) {
        const len = Date.parse(g.end) - Date.parse(g.start);
        const prev = kept.at(-1);
        if (len <= 0 || len > MAX_SPAN_MS || (prev && Date.parse(g.start) < Date.parse(prev.end))) dropped++;
        else kept.push(g);
      }
      stages.push({ date: d, segments: kept });
    }
    // One sleep record per night, by its wake date, so importing a newer export replaces it instead of adding one.
    return { id: `noop-sleep-${d}`, source: NOOP, kind: 'sleep', title: 'Sleep', start, end, date: d };
  });

  const workouts = list(b.workouts, 'workouts', NOOP_CHUNK.workouts).map((raw, i): WorkoutRow => {
    const p = `workouts[${i}]`;
    const w = record(raw, p);
    const { start, end, ms } = span(w.start, w.end, p);
    if (typeof w.sport !== 'string' || !w.sport.trim() || w.sport.length > 60) fail(`${p}.sport`, 'expected the activity name, up to 60 characters');
    const sport = w.sport.trim();
    return {
      // By when it started and what it was: NOOP's own key for a workout, so a re-import updates it.
      id: `noop-${Math.round(Date.parse(start) / 1000)}-${slug(sport)}`,
      source: NOOP,
      sport,
      start,
      end,
      date: date(w.date, `${p}.date`, latest),
      duration_min: ms / 60_000,
      energy_kcal: optional(w.energy_kcal, `${p}.energy_kcal`, 0, 20_000),
      distance_m: optional(w.distance_m, `${p}.distance_m`, 0, 1_000_000),
      avg_hr: optional(w.avg_hr, `${p}.avg_hr`, 25, 230),
      max_hr: optional(w.max_hr, `${p}.max_hr`, 25, 230),
      strain: optional(w.strain, `${p}.strain`, 0, 21),
    };
  });

  return { daily, events, workouts, stages, dropped };
}

async function writeChunk(q: Queryable, userId: string, c: ParsedNoopChunk) {
  await upsertDaily(q, userId, c.daily);
  await upsertEvents(q, userId, c.events);
  await upsertWorkouts(q, userId, c.workouts);
  await replaceSleepStages(q, userId, NOOP, c.stages);
}

/** Writes one checked chunk for this person, all or nothing. */
export async function importNoopChunk(db: Db, userId: string, c: ParsedNoopChunk) {
  await db.tx((q) => writeChunk(q, userId, c));
  if (c.daily.length || c.events.length || c.workouts.length) await bumpDataVersion(db, userId);
}

export type ParsedNoopIngest = ParsedNoopChunk & { from: string; to: string };

/** Checks a POST /ingest body (a NoopIngest): a chunk plus the window of local dates it replaces, holding every record. */
export function parseNoopIngest(body: unknown): ParsedNoopIngest {
  const b = record(body, 'body');
  const w = record(b.window, 'window');
  const latest = latestDate();
  const from = date(w.from, 'window.from', latest);
  const to = date(w.to, 'window.to', latest);
  const days = (Date.parse(to) - Date.parse(from)) / 86_400_000 + 1;
  if (days < 1 || days > NOOP_INGEST_MAX_DAYS) fail('window', `expected from..to of 1 to ${NOOP_INGEST_MAX_DAYS} days`);
  const c = parseNoopChunk(b);
  const outside = [...c.daily, ...c.events, ...c.workouts].find((r) => r.date < from || r.date > to);
  if (outside) fail('window', `${outside.date} is outside ${from}..${to}`);
  return { ...c, from, to };
}

/**
 * Replaces this person's strap rows in the window with the ones sent, all or nothing. NOOP rescores recent nights, and
 * a workout's id carries its name, so adding without clearing would leave the old versions behind.
 */
export async function ingestNoop(db: Db, userId: string, p: ParsedNoopIngest): Promise<NoopSyncSummary> {
  await db.tx(async (q) => {
    for (const table of ['daily', 'events', 'workouts', 'sleep_stages']) {
      await q.query(`DELETE FROM ${table} WHERE user_id = $1 AND source = $2 AND date BETWEEN $3 AND $4`, [userId, NOOP, p.from, p.to]);
    }
    await writeChunk(q, userId, p);
  });
  const summary: NoopSyncSummary = {
    syncedAt: new Date().toISOString(),
    from: p.from,
    to: p.to,
    days: new Set(p.daily.map((r) => r.date)).size,
    nights: p.events.length,
    workouts: p.workouts.length,
  };
  await setUserSetting(db, userId, 'noop_last_sync', JSON.stringify(summary));
  await bumpDataVersion(db, userId);
  return summary;
}

/** POST /noop/ingest, authenticated by the person's ingest token like the Apple Health one. Mounted before the session gate. */
export function noopIngestRouter(db: Db, ownerToken: string | undefined) {
  const router = express.Router();
  router.post('/noop/ingest', ingestAuth(db, ownerToken), express.json({ limit: MAX_BODY }), async (req, res) => {
    let parsed: ParsedNoopIngest;
    try {
      parsed = parseNoopIngest(req.body);
    } catch (err) {
      if (err instanceof ChunkError) return void res.status(400).json({ error: err.message });
      throw err;
    }
    const summary = await ingestNoop(db, res.locals.ingestUser as string, parsed);
    res.json({ ok: true, ...summary, dropped: parsed.dropped });
  });
  router.use((err: Error & { status?: number; type?: string }, _req: Request, res: Response, next: NextFunction) => {
    if (err.type === 'entity.too.large') return void res.status(413).json({ error: 'Request too large' });
    if (err.type === 'entity.parse.failed') return void res.status(400).json({ error: 'Body is not JSON' });
    next(err);
  });
  return router;
}

function parseFinish(body: unknown) {
  const b = record(body, 'body');
  const latest = latestDate();
  if (typeof b.days !== 'number' || !Number.isInteger(b.days) || b.days < 0 || b.days > 100_000) fail('days', 'expected a whole number of days');
  const optDate = (v: unknown, p: string) => (v === null || v === undefined ? null : date(v, p, latest));
  optDate(b.firstDate, 'firstDate');
  optDate(b.lastDate, 'lastDate');
  list(b.metrics, 'metrics', NOOP_METRICS.length).forEach((m, i) => {
    if (typeof m !== 'string' || !METRICS.has(m)) fail(`metrics[${i}]`, 'unknown metric');
  });
}

/** This person's NOOP data as stored: distinct dates and metrics of the day rows, and how many nights and workouts. */
export async function storedNoopSummary(db: Db, userId: string): Promise<Omit<NoopImportSummary, 'importedAt'>> {
  const [[spanRow], metrics, [nights], [workouts]] = await Promise.all([
    db.query<{ days: number; first: string | null; last: string | null }>(
      'SELECT COUNT(DISTINCT date)::int AS days, MIN(date) AS first, MAX(date) AS last FROM daily WHERE user_id = $1 AND source = $2',
      [userId, NOOP],
    ),
    db.query<{ metric: string }>('SELECT DISTINCT metric FROM daily WHERE user_id = $1 AND source = $2', [userId, NOOP]),
    db.query<{ n: number }>("SELECT COUNT(*)::int AS n FROM events WHERE user_id = $1 AND source = $2 AND kind = 'sleep'", [userId, NOOP]),
    db.query<{ n: number }>('SELECT COUNT(*)::int AS n FROM workouts WHERE user_id = $1 AND source = $2', [userId, NOOP]),
  ]);
  return {
    days: Number(spanRow?.days) || 0,
    firstDate: spanRow?.first ?? null,
    lastDate: spanRow?.last ?? null,
    metrics: metrics.map((m) => m.metric).sort(),
    nights: Number(nights?.n) || 0,
    workouts: Number(workouts?.n) || 0,
  };
}

export function noopRouter(db: Db) {
  const router = express.Router();
  const json = express.json({ limit: MAX_BODY });
  const userOf = (res: Response) => currentUser(res).id;

  router.post('/import', json, async (req, res) => {
    let chunk: ParsedNoopChunk;
    try {
      chunk = parseNoopChunk(req.body);
    } catch (err) {
      if (err instanceof ChunkError) return void res.status(400).json({ error: err.message });
      throw err;
    }
    await importNoopChunk(db, userOf(res), chunk);
    res.json({ ok: true, daily: chunk.daily.length, nights: chunk.events.length, workouts: chunk.workouts.length, dropped: chunk.dropped });
  });

  router.post('/import/finish', json, async (req, res) => {
    try {
      parseFinish(req.body);
    } catch (err) {
      if (err instanceof ChunkError) return void res.status(400).json({ error: err.message });
      throw err;
    }
    const userId = userOf(res);
    // What's stored, not only what this import sent: an export from a reinstalled NOOP may start later than the last.
    const lastImport: NoopImportSummary = { ...(await storedNoopSummary(db, userId)), importedAt: new Date().toISOString() };
    await setUserSetting(db, userId, 'noop_last_import', JSON.stringify(lastImport));
    await bumpDataVersion(db, userId);
    res.json({ ok: true, lastImport });
  });

  router.post('/clear', async (_req, res) => {
    const userId = userOf(res);
    await db.tx(async (q) => {
      await deleteSource(q, userId, NOOP);
      await setUserSetting(q, userId, 'noop_last_import', null);
      await setUserSetting(q, userId, 'noop_last_sync', null);
    });
    await bumpDataVersion(db, userId);
    res.json({ ok: true });
  });

  router.use((err: Error & { status?: number; type?: string }, _req: Request, res: Response, next: NextFunction) => {
    if (err.type === 'entity.too.large') return void res.status(413).json({ error: 'That part of the import is over 4 MB. Try again; healthOS sends smaller parts.' });
    if (err.type === 'entity.parse.failed') return void res.status(400).json({ error: "That part of the import wasn't readable. Try again." });
    next(err);
  });

  return router;
}
