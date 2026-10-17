// The Family board (GET /api/family): a small daily tile for everyone who shares, seen by everyone who shares.
// Sharing is on unless a person turns it off in Settings, and it's mutual: turned off, they neither see anyone
// nor are seen. This is the only place one person's health data is read for another, and a tile carries only
// what FamilyMember lists: no values over time, no email, nothing about anyone who doesn't share.
import express from 'express';
import type { CycleDay, FamilyBoard, FamilyCyclePhase, FamilyDevice, FamilyMember, FamilyReason, FamilyStatus, Latest, Point, RangeStatus } from '../shared/types.ts';
import { authMode, currentUser } from './auth.ts';
import { type CycleRow, analyzeCycle, logDays } from './cycle.ts';
import { addDays } from './dates.ts';
import { type Db, getUserSetting } from './db.ts';
import { typicalRunning } from './day.ts';
import { photoAsset } from './photo.ts';
import { latest, latestDataDate, loadDaily, requestContext, series, valueOn } from './query.ts';

/** People who share, in order of id. Without sign-in (one local person) that's only the viewer, if they share. */
export async function sharerIds(db: Db, viewerId: string): Promise<string[]> {
  if (authMode() === 'open') return (await getUserSetting(db, viewerId, 'family_sharing')) === 'off' ? [] : [viewerId];
  const rows = await db.query<{ id: string }>(
    `SELECT u.id FROM users u WHERE u.status = 'active'
       AND NOT EXISTS (SELECT 1 FROM user_settings s WHERE s.user_id = u.id AND s.key = 'family_sharing' AND s.value = 'off')
     ORDER BY u.id`,
  );
  return rows.map((r) => r.id);
}

export async function familyBoard(db: Db, hosted: boolean, viewerId: string): Promise<FamilyBoard> {
  const ids = await sharerIds(db, viewerId);
  if (!ids.includes(viewerId)) return { sharing: false };
  const [users, whoop, avatars, phases] = await Promise.all([
    db.query<{ id: string; name: string }>('SELECT id, name FROM users WHERE id = ANY($1)', [ids]),
    db.query<{ user_id: string }>("SELECT user_id FROM tokens WHERE provider = 'whoop' AND user_id = ANY($1)", [ids]),
    db.query<{ user_id: string; updated_at: number }>("SELECT user_id, updated_at FROM profile_assets WHERE name = 'avatar.png' AND user_id = ANY($1)", [ids]),
    db.query<{ user_id: string }>("SELECT user_id FROM user_settings WHERE key = 'family_cycle_phase' AND value = 'on' AND user_id = ANY($1)", [ids]),
  ]);
  const has = (rows: { user_id: string }[], id: string) => rows.some((r) => r.user_id === id);
  const members = await Promise.all(
    ids.map((id) =>
      memberTile(db, hosted, id, {
        isYou: id === viewerId,
        accountName: users.find((u) => u.id === id)?.name ?? '',
        whoop: has(whoop, id),
        avatar: Number(avatars.find((a) => a.user_id === id)?.updated_at) || null,
        sharesPhase: has(phases, id),
      }),
    ),
  );
  members.sort((a, b) => Number(b.isYou) - Number(a.isYou) || a.name.localeCompare(b.name));
  return { sharing: true, today: members.find((m) => m.isYou)!.today, members };
}

const WINDOW_DAYS = 45;
const METRICS = ['steps', 'sleep_hours', 'sleep_in_bed', 'recovery', 'hrv_rmssd', 'hrv_sdnn', 'resting_hr'];
/** Stricter than Home's ranges: the board flags only clear departures from someone's usual. */
const BAND = 1.5;
const MIN_HISTORY = 7;

const mean = (xs: number[]) => (xs.length ? xs.reduce((a, b) => a + b, 0) / xs.length : null);
function sd(xs: number[]) {
  const m = mean(xs);
  return m === null || xs.length < 2 ? null : Math.sqrt(xs.reduce((a, x) => a + (x - m) ** 2, 0) / (xs.length - 1));
}
/** The mean of the history, once there's a week of it. */
const usualOf = (history: Point[]) => (history.length >= MIN_HISTORY ? mean(history.map((p) => p.value)) : null);
/** Above or below the band around the usual; null without a week of history. */
function against(history: Point[], value: number, minSpread: number): RangeStatus | null {
  const m = usualOf(history);
  if (m === null) return null;
  const band = BAND * Math.max(sd(history.map((p) => p.value)) ?? 0, minSpread);
  return value > m + band ? 'high' : value < m - band ? 'low' : 'normal';
}

type TileOpts = { isYou: boolean; accountName: string; whoop: boolean; avatar: number | null; sharesPhase: boolean };

async function memberTile(db: Db, hosted: boolean, userId: string, o: TileOpts): Promise<FamilyMember> {
  const scope = { db, userId };
  const { settings, demo, today } = await requestContext(scope, hosted);
  const from = addDays(today, -WINDOW_DAYS);
  const [daily, newest, hourly, phase] = await Promise.all([
    loadDaily(scope, demo, from, today, METRICS),
    latestDataDate(scope, demo, today),
    db.query<{ date: string; hour: number; value: number }>(
      "SELECT date, hour, value FROM hourly WHERE user_id = $1 AND metric = 'steps' AND source = $2 AND date BETWEEN $3 AND $4",
      [userId, demo ? 'demo' : 'apple', addDays(today, -30), today],
    ),
    o.sharesPhase && settings.cycleTracking ? cyclePhaseOf(db, userId, today) : null,
  ]);
  const ctx = { daily, demo };
  const yesterday = addDays(today, -1);
  const window = (metric: string) => series(ctx, metric, from, today);
  // Phone-only sleep is time in bed (the importer keeps it when nothing else exists): shown, never judged.
  const inBedOnly = (date: string, hours: number) => {
    const bed = valueOn(ctx, 'sleep_in_bed', date)?.value;
    return bed !== undefined && Math.abs(bed - hours) * 60 <= 1;
  };

  // Sleep: last night, against the 28 nights before it.
  const night = latest(ctx, 'sleep_hours', today, 1);
  const sleep = night
    ? {
        hours: round(night.value, 2),
        date: night.date,
        usual: nullableRound(usualOf(series(ctx, 'sleep_hours', addDays(night.date, -28), addDays(night.date, -1))), 2),
        inBed: inBedOnly(night.date, night.value),
      }
    : null;

  // Readiness: WHOOP recovery, else HRV (Apple Watch's SDNN or WHOOP's RMSSD), each against its 30 days before.
  let readiness: FamilyMember['readiness'] = null;
  let readinessLow: FamilyReason | null = null;
  const prior = (metric: string, l: Latest) => series(ctx, metric, addDays(l.date, -30), addDays(l.date, -1));
  const recovery = latest(ctx, 'recovery', today, 1);
  if (recovery) {
    const usual = usualOf(prior('recovery', recovery));
    readiness = { kind: 'recovery', value: Math.round(recovery.value), date: recovery.date, usual: nullableRound(usual, 0) };
    if (usual !== null && recovery.value <= usual - 25) readinessLow = 'recovery';
  } else {
    const hrv = (['hrv_rmssd', 'hrv_sdnn'] as const)
      .map((metric) => ({ metric, l: latest(ctx, metric, today, 3) }))
      .filter((x): x is { metric: 'hrv_rmssd' | 'hrv_sdnn'; l: Latest } => x.l !== null)
      .sort((a, b) => b.l.date.localeCompare(a.l.date))[0];
    if (hrv) {
      const history = prior(hrv.metric, hrv.l);
      const usual = usualOf(history);
      readiness = { kind: 'hrv', metric: hrv.metric, value: Math.round(hrv.l.value), date: hrv.l.date, usual: nullableRound(usual, 0) };
      if (usual !== null && against(history, hrv.l.value, usual * 0.05) === 'low') readinessLow = 'hrv';
    }
  }

  const rhr = latest(ctx, 'resting_hr', today, 3);
  const rhrStatus = rhr ? against(prior('resting_hr', rhr), rhr.value, 2) : null;
  const restingHr = rhr && rhrStatus ? { status: rhrStatus, date: rhr.date } : null;

  // Today's steps by the same rule as everywhere else; how far along the day is only from the phone's hours.
  const counted = valueOn(ctx, 'steps', today);
  let steps: FamilyMember['steps'] = null;
  if (counted) {
    const fromWhoop = counted.source === 'whoop';
    const pace = fromWhoop ? null : stepsPace(hourly, today);
    steps = { value: Math.round(counted.value), source: fromWhoop ? 'whoop' : 'apple', asOfHour: pace?.asOfHour ?? null, usualByNow: pace?.usualByNow ?? null };
  }

  // What the board compares at all: something a watch or WHOOP measures (phone-only sleep doesn't count).
  const stagedSleep = window('sleep_hours').filter((p) => !inBedOnly(p.date, p.value));
  const wearable = [window('recovery'), window('hrv_rmssd'), window('hrv_sdnn'), window('resting_hr'), stagedSleep].flat();
  const signals: FamilyReason[] = [];
  if (readinessLow) signals.push(readinessLow);
  if (restingHr?.status === 'high') signals.push('resting_hr');
  if (sleep && !sleep.inBed && sleep.usual !== null && sleep.hours <= sleep.usual - 1.5) signals.push('sleep');
  const { status, quietSince } = familyStatus({
    today,
    newest,
    wearableNewest: wearable.reduce<string | null>((d, p) => (d === null || p.date > d ? p.date : d), null),
    fresh: readiness !== null || restingHr !== null || (sleep !== null && !sleep.inBed),
    baselines: (sleep !== null && !sleep.inBed && sleep.usual !== null) || (readiness?.usual ?? null) !== null || restingHr !== null,
    signals,
  });

  const devices: FamilyDevice[] = [];
  if (o.whoop) devices.push('whoop');
  const apple = (metric: string) => (daily.get(metric)?.get('apple')?.size ?? 0) > 0;
  if (apple('resting_hr') || apple('hrv_sdnn')) devices.push('watch');
  else if (METRICS.some(apple)) devices.push('iphone');

  return {
    id: userId,
    name: settings.name || o.accountName || 'Family member',
    isYou: o.isYou,
    demo,
    today,
    avatar: o.avatar,
    devices,
    latestDataDate: newest,
    quietSince,
    status,
    reasons: signals.slice(0, 2),
    sleep,
    readiness,
    restingHr,
    steps,
    ...(phase ? { cyclePhase: phase } : {}),
  };
}

const round = (v: number, places: number) => Math.round(v * 10 ** places) / 10 ** places;
const nullableRound = (v: number | null, places: number) => (v === null ? null : round(v, places));

/**
 * The status, first match wins: no recent data at all; nothing a watch or WHOOP measures (phone only: no
 * status); nothing fresh from one; no usual yet; else how many clear departures from their usual there are.
 */
export function familyStatus(i: {
  today: string;
  newest: string | null;
  wearableNewest: string | null;
  fresh: boolean;
  baselines: boolean;
  signals: FamilyReason[];
}): { status: FamilyStatus | null; quietSince: string | null } {
  if (i.newest === null || i.newest < addDays(i.today, -1)) return { status: 'quiet', quietSince: i.newest };
  if (i.wearableNewest === null) return { status: null, quietSince: null };
  if (!i.fresh) return { status: 'quiet', quietSince: i.wearableNewest };
  if (!i.baselines) return { status: 'learning', quietSince: null };
  return { status: i.signals.length >= 2 ? 'check' : i.signals.length === 1 ? 'off' : 'good', quietSince: null };
}

/** Today's steps so far by the latest synced hour, and the usual running total by then (median of 30 days). */
export function stepsPace(rows: { date: string; hour: number; value: number }[], today: string): { asOfHour: number | null; usualByNow: number | null } {
  const days = new Map<string, (number | null)[]>();
  for (const r of rows) {
    let hours = days.get(r.date);
    if (!hours) days.set(r.date, (hours = Array.from({ length: 24 }, () => null)));
    hours[Number(r.hour)] = (hours[Number(r.hour)] ?? 0) + Number(r.value);
  }
  const todays = days.get(today);
  let asOfHour: number | null = null;
  todays?.forEach((v, h) => {
    if (v !== null) asOfHour = h;
  });
  if (asOfHour === null) return { asOfHour: null, usualByNow: null };
  const before = [...days].filter(([d]) => d < today && d >= addDays(today, -30)).map(([, h]) => h);
  const typical = typicalRunning(before)[asOfHour];
  return { asOfHour, usualByNow: typical === null || typical === undefined ? null : Math.round(typical) };
}

async function cyclePhaseOf(db: Db, userId: string, today: string): Promise<FamilyCyclePhase | null> {
  const rows = await db.query<CycleRow>("SELECT date, kind, source, value FROM cycle WHERE user_id = $1 AND source IN ('apple', 'manual') ORDER BY date", [userId]);
  const days = logDays(rows);
  return familyPhase(analyzeCycle(days, today), days, today);
}

/**
 * One word for a shared phase. A period needs only logged bleeding (today or yesterday, early in the cycle);
 * the rest needs an estimate, and nothing shows from the earliest the next period could come, so the word
 * can't hint that it's late. Never "ovulation" or "fertile".
 */
export function familyPhase(a: ReturnType<typeof analyzeCycle>, days: CycleDay[], today: string): FamilyCyclePhase | null {
  if (!a.current) return null;
  const yesterday = addDays(today, -1);
  const bleeding = days.some((d) => (d.date === today || d.date === yesterday) && d.flow !== undefined && d.flow !== 'none');
  if (bleeding && a.current.day <= (a.stats.periodDays ?? 5) + 2) return 'period';
  if (!a.estimate || today >= a.estimate.nextPeriod.earliest) return null;
  return today <= a.estimate.ovulation ? 'follicular' : 'luteal';
}

export function familyRouter(db: Db, hosted: boolean) {
  const r = express.Router();
  r.get('/', async (_req, res) => {
    res.json(await familyBoard(db, hosted, currentUser(res).id));
  });
  // Only the small avatar, and only between two people who both share. Cached briefly, so turning sharing
  // off takes effect within minutes even in a browser that already loaded it.
  r.get('/:id/avatar.png', async (req, res) => {
    const viewer = currentUser(res).id;
    const ids = await sharerIds(db, viewer);
    if (!ids.includes(viewer) || !ids.includes(req.params.id)) return void res.status(404).json({ error: 'Not found' });
    const data = await photoAsset({ db, userId: req.params.id }, 'avatar.png');
    if (!data) return void res.status(404).json({ error: 'Not found' });
    res.setHeader('Cache-Control', 'private, max-age=300');
    res.type('png').send(data);
  });
  return r;
}
