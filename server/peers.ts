// Anonymous peer comparisons (shared/peers.ts): the second place, after the Family board (server/family.ts), where one
// person's readings are read for another, and only ever as aggregates of a large enough group. Like the board it's
// mutual: only someone taking part (their own switch on, an age of 18 or over, an active account) sees results, and
// only people taking part are counted. Everything is computed on read, so turning it off takes effect at once.
//
// For each measurement and source the viewer has in their last 30 days, the group is everyone else taking part in the
// viewer's age band with at least 7 days of that same measurement from that same source in the same window. Results
// need at least 20 of them, and the answer carries only the group's rounded quartiles and size bucket, and which quarter
// the viewer sits in by those rounded figures: never ids, names, counts or anyone else's own value. The viewer is never
// in their own group, so nothing they change in their own readings moves the group's figures.
import express from 'express';
import { PEER_MIN_AGE, PEER_MIN_DAYS, PEER_MIN_OTHERS, PEER_PAIRS, PEER_WINDOW_DAYS, type PeerData, type PeerMetric, ageBand, peerBand } from '../shared/peers.ts';
import { authMode, currentUser } from './auth.ts';
import { addDays } from './dates.ts';
import type { Db } from './db.ts';
import { currentAge, requestContext } from './query.ts';

type Avg = { avg: number; days: number };

// Phone-only sleep is time in bed, not sleep (the importer keeps it when nothing else measured the night): it isn't
// the same measurement, so those nights don't count, as on the Family board.
const notInBedOnly = (alias: string) =>
  `NOT EXISTS (SELECT 1 FROM daily b WHERE b.user_id = ${alias}.user_id AND b.date = ${alias}.date AND b.source = ${alias}.source
     AND b.metric = 'sleep_in_bed' AND abs(b.value - ${alias}.value) * 60 <= 1)`;

/** Everyone else taking part in this age band, read fresh on every request (no cache), so opting out is immediate. */
async function participantIds(db: Db, viewerId: string, band: string, today: string): Promise<string[]> {
  const rows = await db.query<{ id: string; age: string }>(
    `SELECT u.id, a.value AS age FROM users u
       JOIN user_settings p ON p.user_id = u.id AND p.key = 'peer_comparison' AND p.value = 'on'
       JOIN user_settings a ON a.user_id = u.id AND a.key = 'age'
     WHERE u.status = 'active' AND u.id <> $1`,
    [viewerId],
  );
  const inBand = (raw: string) => {
    const age = currentAge(raw, today);
    return age !== null && age >= PEER_MIN_AGE && ageBand(age) === band;
  };
  return rows.filter((r) => inBand(r.age)).map((r) => r.id);
}

/** The viewer's own averages over the window, per metric and source. */
async function ownAverages(db: Db, viewerId: string, from: string, to: string): Promise<Map<string, Avg>> {
  const metrics = [...new Set(PEER_PAIRS.map((p) => p.metric))];
  const rows = await db.query<{ metric: string; source: string; avg: number; days: number }>(
    `SELECT d.metric, d.source, AVG(d.value)::float8 AS avg, COUNT(*)::int AS days FROM daily d
     WHERE d.user_id = $1 AND d.metric = ANY($2) AND d.date BETWEEN $3 AND $4 AND (d.metric <> 'sleep_hours' OR ${notInBedOnly('d')})
     GROUP BY d.metric, d.source`,
    [viewerId, metrics, from, to],
  );
  return new Map(rows.map((r) => [`${r.metric}|${r.source}`, { avg: Number(r.avg), days: Number(r.days) }]));
}

/** The others' averages for one pair: one row per person with enough days, and nothing else leaves the query. */
async function groupAverages(db: Db, ids: string[], metric: string, source: string, from: string, to: string): Promise<number[]> {
  if (!ids.length) return [];
  const rows = await db.query<{ avg: number }>(
    `SELECT AVG(d.value)::float8 AS avg FROM daily d
     WHERE d.metric = $1 AND d.source = $2 AND d.date BETWEEN $3 AND $4 AND d.user_id = ANY($5) ${metric === 'sleep_hours' ? `AND ${notInBedOnly('d')}` : ''}
     GROUP BY d.user_id HAVING COUNT(*) >= $6`,
    [metric, source, from, to, ids, PEER_MIN_DAYS],
  );
  return rows.map((r) => Number(r.avg));
}

const round = (v: number, digits: number) => Math.round(v * 10 ** digits) / 10 ** digits;

/** Linear interpolation between the closest ranks (sorted ascending). */
function quantile(sorted: number[], p: number) {
  const h = (sorted.length - 1) * p;
  const lo = Math.floor(h);
  const hi = Math.min(lo + 1, sorted.length - 1);
  return sorted[lo] + (h - lo) * (sorted[hi] - sorted[lo]);
}

const sizeBucket = (n: number) => (n >= 100 ? '100+' : n >= 50 ? '50+' : '20+') as '20+' | '50+' | '100+';

/**
 * One measurement's comparison, from the viewer's own average and the others' (unrounded) averages. The viewer's place
 * is a quarter, worked out from the rounded figures alone: a finer rank against everyone's exact averages would let
 * someone who sets their own readings search out each other person's value, and the group's size, one step at a time.
 */
export function compare(metric: string, source: string, digits: number, own: Avg, group: number[]): PeerMetric {
  const you = round(own.avg, digits);
  const base = { metric, source, you, yourDays: own.days };
  if (own.days < PEER_MIN_DAYS) return { ...base, status: 'not_enough_days' };
  if (group.length < PEER_MIN_OTHERS) return { ...base, status: 'gathering' };
  const sorted = [...group].sort((a, b) => a - b);
  const quartiles = { median: round(quantile(sorted, 0.5), digits), p25: round(quantile(sorted, 0.25), digits), p75: round(quantile(sorted, 0.75), digits) };
  return { ...base, status: 'ready', band: peerBand(you, quartiles), group: { size: sizeBucket(sorted.length), ...quartiles } };
}

// ---------- the local preview's sample group ----------
// The demo owner (local only, no real data) has nobody to compare with, so the preview shows a made-up group around
// typical adult values: the same every time, flagged demo, never anyone's readings.

const SAMPLE: Record<string, { center: number; spread: number }> = {
  resting_hr: { center: 60, spread: 7 },
  hrv_rmssd: { center: 55, spread: 16 },
  sleep_hours: { center: 7, spread: 0.7 },
  steps: { center: 7_500, spread: 2_600 },
  spo2: { center: 96.8, spread: 0.9 },
  resp_rate: { center: 14.8, spread: 1.2 },
  recovery: { center: 58, spread: 12 },
};
const SAMPLE_SIZE = 64;

/** Evenly spaced quantiles of a bell curve (the logistic, close enough for a sample). */
const sampleGroup = ({ center, spread }: { center: number; spread: number }) =>
  Array.from({ length: SAMPLE_SIZE }, (_, i) => {
    const p = (i + 0.5) / SAMPLE_SIZE;
    return center + spread * (Math.log(p / (1 - p)) * Math.sqrt(3)) / Math.PI;
  });

async function demoComparison(db: Db, viewerId: string, band: string, from: string, to: string): Promise<PeerData> {
  const own = await ownAverages(db, viewerId, from, to);
  const metrics: PeerMetric[] = [];
  for (const [metric, shape] of Object.entries(SAMPLE)) {
    const mine = own.get(`${metric}|demo`);
    const pair = PEER_PAIRS.find((p) => p.metric === metric);
    if (mine && pair) metrics.push(compare(metric, 'demo', pair.digits, mine, sampleGroup(shape)));
  }
  return { participating: true, ageBand: band, window: { from, to }, metrics, demo: true };
}

// ---------- GET /api/peers ----------

export async function peerComparison(db: Db, hosted: boolean, viewerId: string): Promise<PeerData> {
  const { settings, demo, today } = await requestContext({ db, userId: viewerId }, hosted);
  // Without sign-in there's one person on this Mac: nobody to compare with (the demo owner gets the sample group).
  if (!demo && authMode() === 'open') return { participating: false, reason: 'no_accounts' };
  if (!settings.peerComparison) return { participating: false, reason: 'off' };
  const age = settings.age ?? null;
  if (age === null) return { participating: false, reason: 'no_age' };
  const band = ageBand(age);
  if (age < PEER_MIN_AGE || !band) return { participating: false, reason: 'under_age' };
  const from = addDays(today, -(PEER_WINDOW_DAYS - 1));
  if (demo) return demoComparison(db, viewerId, band, from, today);

  const [own, ids] = await Promise.all([ownAverages(db, viewerId, from, today), participantIds(db, viewerId, band, today)]);
  // Only what the viewer has: a group for a device they don't wear says nothing about them.
  const pairs = PEER_PAIRS.filter((p) => own.has(`${p.metric}|${p.source}`));
  const metrics = await Promise.all(
    pairs.map(async (p) => compare(p.metric, p.source, p.digits, own.get(`${p.metric}|${p.source}`)!, await groupAverages(db, ids, p.metric, p.source, from, today))),
  );
  return { participating: true, ageBand: band, window: { from, to: today }, metrics };
}

export function peersRouter(db: Db, hosted: boolean) {
  const router = express.Router();
  router.get('/', async (_req, res) => {
    res.json(await peerComparison(db, hosted, currentUser(res).id));
  });
  router.use((err: Error, _req: express.Request, res: express.Response, _next: express.NextFunction) => {
    // The kind of failure only: a database error's text can quote the values it was given.
    console.error('peers:', err.name);
    res.status(500).json({ error: 'Something went wrong' });
  });
  return router;
}
