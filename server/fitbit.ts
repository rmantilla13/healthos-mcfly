// A Fitbit export (Google Takeout), read in the browser (src/import/fitbit.ts) and sent here in chunks as source
// 'fitbit' (shared/fitbit.ts). Only per-day readings and each night's sleep stretches arrive: the files themselves never
// leave the person's device. Mounted before the general JSON parser, since a chunk is a few MB.
//
//   POST /import          one chunk of whole days: daily rows are upserted (so the parts of a split export can arrive
//                         on different days); each night's stretches and sleep record replace the night's Fitbit ones.
//                         Merges, so a failure halfway loses nothing.
//   POST /import/finish   the summary of every Fitbit day stored, shown on Integrations (Status.fitbit.lastImport)
//   POST /clear           every Fitbit row and the summary go; other sources are untouched
import express, { type NextFunction, type Request, type Response } from 'express';
import { FITBIT_METRICS, type FitbitFinish, type FitbitMetric } from '../shared/fitbit.ts';
import { FITBIT_CHUNK, FITBIT_FIRST_DATE, FITBIT_RANGES, inFitbitRange } from '../shared/fitbitRanges.ts';
import type { FitbitImportSummary } from '../shared/types.ts';
import { currentUser } from './auth.ts';
import { type DailyRow, type Db, type EventRow, type SleepStageRow, bumpDataVersion, deleteSource, replaceSleepStages, setUserSetting, upsertDaily, upsertEvents } from './db.ts';

export const FITBIT = 'fitbit';

/** Under Vercel's 4.5 MB request limit; the browser sends chunks of at most 3.5 MB (FITBIT_CHUNK). */
const MAX_BODY = '4mb';
const MAX_NIGHT_MS = 24 * 3_600_000;
const DATE = /^\d{4}-\d{2}-\d{2}$/;
const ISO = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?(?:Z|[+-]\d{2}:\d{2})$/;
const METRICS = new Set<string>(FITBIT_METRICS);
const STAGES = new Set(['awake', 'rem', 'light', 'deep', 'asleep']);

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
  // Date.parse rolls 2026-02-30 over to March; the round trip catches that.
  if (Number.isNaN(ms) || new Date(ms).toISOString().slice(0, 10) !== v) fail(path, 'expected a date as YYYY-MM-DD');
  if (v < FITBIT_FIRST_DATE || v > latest) fail(path, `${v} is outside the dates a Fitbit reading can have`);
  return v;
}

function iso(v: unknown, path: string): string {
  if (typeof v !== 'string' || !ISO.test(v) || Number.isNaN(Date.parse(v))) fail(path, 'expected an ISO timestamp with offset, e.g. 2026-10-14T06:45:00-07:00');
  return v;
}

export type ParsedChunk = { daily: DailyRow[]; nights: { date: string; start: string; end: string; segments: SleepStageRow[] }[]; dropped: number };

/**
 * Checks a chunk (a FitbitChunk, shared/fitbit.ts). A wrong shape, an unknown metric, a value no Fitbit could record or a date outside 2008..tomorrow
 * fails the whole chunk (the browser reader applies the same ranges, so one is a bug). A sleep stretch that's merely
 * bad (empty, longer than a night, overlapping the one before) is left out, as the iPhone ingest does.
 */
export function parseFitbitChunk(body: unknown): ParsedChunk {
  const b = record(body, 'body');
  const latest = latestDate();
  const daily = list(b.daily, 'daily', FITBIT_CHUNK.rows).map((raw, i): DailyRow => {
    const p = `daily[${i}]`;
    const r = record(raw, p);
    if (typeof r.metric !== 'string' || !METRICS.has(r.metric)) fail(`${p}.metric`, `unknown metric "${String(r.metric).slice(0, 40)}"`);
    const metric = r.metric as FitbitMetric;
    if (typeof r.value !== 'number' || !inFitbitRange(metric, r.value)) {
      const [lo, hi] = FITBIT_RANGES[metric];
      fail(`${p}.value`, `expected a number from ${lo} to ${hi} for ${metric}`);
    }
    return { date: date(r.date, `${p}.date`, latest), metric, source: FITBIT, value: r.value };
  });
  let dropped = 0;
  const seen = new Set<string>();
  const nights = list(b.sleep, 'sleep', FITBIT_CHUNK.nights).map((raw, i) => {
    const p = `sleep[${i}]`;
    const n = record(raw, p);
    const d = date(n.date, `${p}.date`, latest);
    if (seen.has(d)) fail(`${p}.date`, `${d} appears twice`);
    seen.add(d);
    const start = iso(n.start, `${p}.start`);
    const end = iso(n.end, `${p}.end`);
    const span = Date.parse(end) - Date.parse(start);
    if (span <= 0 || span > MAX_NIGHT_MS) fail(`${p}.end`, 'a night ends after it starts, within a day');
    const segments = list(n.segments, `${p}.segments`, FITBIT_CHUNK.stagesPerNight)
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
      if (len <= 0 || len > MAX_NIGHT_MS || (prev && Date.parse(g.start) < Date.parse(prev.end))) dropped++;
      else kept.push(g);
    }
    return { date: d, start, end, segments: kept };
  });
  return { daily, nights, dropped };
}

/** Writes one checked chunk for this person, all or nothing. */
export async function importFitbitChunk(db: Db, userId: string, c: ParsedChunk) {
  // One sleep record per night, by its wake date, so importing the same export again replaces it instead of adding one.
  const events: EventRow[] = c.nights.map((n) => ({ id: `fitbit-sleep-${n.date}`, source: FITBIT, kind: 'sleep', title: 'Sleep', start: n.start, end: n.end, date: n.date }));
  await db.tx(async (q) => {
    // Upserted, not replaced by day: a large Takeout comes in several .zip files, which may be imported one at a time,
    // and one part's heart rate for a day mustn't go when another part brings that day's sleep.
    await upsertDaily(q, userId, c.daily);
    await upsertEvents(q, userId, events);
    await replaceSleepStages(q, userId, FITBIT, c.nights.map(({ date, segments }) => ({ date, segments })));
  });
  if (c.daily.length || c.nights.length) await bumpDataVersion(db, userId);
}

function parseFinish(body: unknown): FitbitFinish {
  const b = record(body, 'body');
  const latest = latestDate();
  if (typeof b.days !== 'number' || !Number.isInteger(b.days) || b.days < 0 || b.days > 100_000) fail('days', 'expected a whole number of days');
  const optDate = (v: unknown, p: string) => (v === null || v === undefined ? null : date(v, p, latest));
  const metrics = list(b.metrics, 'metrics', FITBIT_METRICS.length).map((m, i) => {
    if (typeof m !== 'string' || !METRICS.has(m)) fail(`metrics[${i}]`, 'unknown metric');
    return m;
  });
  return { days: b.days, firstDate: optDate(b.firstDate, 'firstDate'), lastDate: optDate(b.lastDate, 'lastDate'), metrics: [...new Set(metrics)] };
}

/** This person's Fitbit days as stored, in fitbitFinish's terms (src/import/fitbit.ts): distinct dates and metrics of the day rows. */
async function storedSummary(db: Db, userId: string): Promise<FitbitFinish> {
  const [[span], metrics] = await Promise.all([
    db.query<{ days: number; first: string | null; last: string | null }>(
      'SELECT COUNT(DISTINCT date)::int AS days, MIN(date) AS first, MAX(date) AS last FROM daily WHERE user_id = $1 AND source = $2',
      [userId, FITBIT],
    ),
    db.query<{ metric: string }>('SELECT DISTINCT metric FROM daily WHERE user_id = $1 AND source = $2', [userId, FITBIT]),
  ]);
  return { days: Number(span?.days) || 0, firstDate: span?.first ?? null, lastDate: span?.last ?? null, metrics: metrics.map((m) => m.metric).sort() };
}

export function fitbitRouter(db: Db, _hosted: boolean) {
  const router = express.Router();
  const json = express.json({ limit: MAX_BODY });
  const userOf = (res: Response) => currentUser(res).id;

  router.post('/import', json, async (req, res) => {
    let chunk: ParsedChunk;
    try {
      chunk = parseFitbitChunk(req.body);
    } catch (err) {
      if (err instanceof ChunkError) return void res.status(400).json({ error: err.message });
      throw err;
    }
    await importFitbitChunk(db, userOf(res), chunk);
    res.json({ ok: true, daily: chunk.daily.length, nights: chunk.nights.length, dropped: chunk.dropped });
  });

  router.post('/import/finish', json, async (req, res) => {
    // The browser's own summary is still checked, so a body that isn't one is refused as before, but it isn't kept.
    try {
      parseFinish(req.body);
    } catch (err) {
      if (err instanceof ChunkError) return void res.status(400).json({ error: err.message });
      throw err;
    }
    const userId = userOf(res);
    // The browser's summary covers only the parts sent this time, so a split export imported one .zip at a time would
    // replace the last part's with this one's. Kept is what's stored: every part so far, counted as fitbitFinish does.
    const lastImport: FitbitImportSummary = { ...(await storedSummary(db, userId)), importedAt: new Date().toISOString() };
    await setUserSetting(db, userId, 'fitbit_last_import', JSON.stringify(lastImport));
    await bumpDataVersion(db, userId);
    res.json({ ok: true, lastImport });
  });

  router.post('/clear', async (_req, res) => {
    const userId = userOf(res);
    await db.tx(async (q) => {
      await deleteSource(q, userId, FITBIT);
      await setUserSetting(q, userId, 'fitbit_last_import', null);
    });
    await bumpDataVersion(db, userId);
    res.json({ ok: true });
  });

  router.use((err: Error & { status?: number; type?: string }, _req: Request, res: Response, next: NextFunction) => {
    // Body errors get plain words; anything else goes on to the app's handler (a real failure, logged there).
    if (err.type === 'entity.too.large') return void res.status(413).json({ error: 'That part of the import is over 4 MB. Try again; healthOS sends smaller parts.' });
    if (err.type === 'entity.parse.failed') return void res.status(400).json({ error: "That part of the import wasn't readable. Try again." });
    next(err);
  });

  return router;
}
