import { randomBytes } from 'node:crypto';
import { type DailyRow, type Db, type EventRow, OWNER_ID, type Queryable, type Scope, type WorkoutRow, bumpDataVersion, getUserSetting, setUserSetting, upsertDaily, upsertEvents, upsertWorkouts } from './db.ts';
import { insertMany } from './store.ts';
import { DAY_MS, DAY_ROLLOVER_MS, localDate, stampFromIso, toLocalIso } from './dates.ts';

// Every function works on one person's scope: their tokens, sync state and data. The cron (syncAllWhoop)
// loops over everyone who has connected WHOOP.

export const SOURCE = 'whoop';

const AUTH_URL = 'https://api.prod.whoop.com/oauth/oauth2/auth';
const TOKEN_URL = 'https://api.prod.whoop.com/oauth/oauth2/token';
const API = 'https://api.prod.whoop.com/developer/v2';
// `offline` is what makes WHOOP return a refresh token.
const SCOPES = ['offline', 'read:profile', 'read:body_measurement', 'read:cycles', 'read:recovery', 'read:sleep', 'read:workout'];
const BACKFILL_DAYS = 365;
// Older history is fetched backwards in windows, a few per sync, until this date (before any WHOOP data).
const HISTORY_START = Date.parse('2015-01-01T00:00:00Z');
const WINDOW_DAYS = 120;
// Leave headroom under the function's 300s limit.
const SYNC_BUDGET_MS = 230_000;

export function whoopConfig() {
  const port = process.env.PORT ?? '8787';
  return {
    clientId: process.env.WHOOP_CLIENT_ID ?? '',
    clientSecret: process.env.WHOOP_CLIENT_SECRET ?? '',
    redirectUri: process.env.WHOOP_REDIRECT_URI || `http://localhost:${port}/api/whoop/callback`,
  };
}

export const isConfigured = () => Boolean(whoopConfig().clientId && whoopConfig().clientSecret);

/**
 * A WHOOP failure in words for the person whose data it is: it's shown on Integrations and in the iPhone app.
 * `detail` keeps the technical cause (status codes, WHOOP's reply) for the server logs and the admin screen.
 */
export class WhoopError extends Error {
  readonly detail: string;
  constructor(message: string, detail: string = message) {
    super(message);
    this.detail = detail;
  }
}

export const errorDetail = (err: unknown) => (err instanceof WhoopError ? err.detail : err instanceof Error ? err.message : String(err));

const RETRY_LATER = "WHOOP isn't responding right now. healthOS will try again within the hour.";
const SYNC_FAILED = "The WHOOP sync didn't finish. healthOS will try again within the hour.";
// Also shown in the iPhone app, which has no Disconnect button: point to the website.
const RECONNECT = 'Your WHOOP connection has expired. On the healthOS website, disconnect WHOOP and connect it again.';

export async function isConnected(scope: Scope) {
  const [row] = await scope.db.query<{ any: boolean }>("SELECT EXISTS (SELECT 1 FROM tokens WHERE user_id = $1 AND provider = 'whoop') AS any", [scope.userId]);
  return Boolean(row?.any);
}

// ---------- OAuth ----------
// The connect and callback requests can land on different serverless instances, so the pending state is
// stored in the database, against the person who started connecting: the callback only accepts it from them.

export async function authorizeUrl(scope: Scope): Promise<string> {
  const { clientId, redirectUri } = whoopConfig();
  // WHOOP requires an 8-character state.
  const state = randomBytes(6).toString('base64url').slice(0, 8);
  await setUserSetting(scope.db, scope.userId, 'whoop_oauth_state', JSON.stringify({ state, expires: Date.now() + 10 * 60_000 }));
  const params = new URLSearchParams({ response_type: 'code', client_id: clientId, redirect_uri: redirectUri, scope: SCOPES.join(' '), state });
  return `${AUTH_URL}?${params}`;
}

export async function consumeState(scope: Scope, state: string | undefined): Promise<boolean> {
  const raw = await getUserSetting(scope.db, scope.userId, 'whoop_oauth_state');
  await setUserSetting(scope.db, scope.userId, 'whoop_oauth_state', null);
  if (!raw || !state) return false;
  const pending = JSON.parse(raw) as { state: string; expires: number };
  return pending.state === state && pending.expires > Date.now();
}

type TokenResponse = { access_token: string; refresh_token?: string; expires_in: number; scope?: string };
type TokenRow = { access_token: string; refresh_token: string | null; expires_at: number };

async function tokenRequest(body: Record<string, string>): Promise<TokenResponse> {
  const { clientId, clientSecret } = whoopConfig();
  const connecting = body.grant_type === 'authorization_code';
  const unavailable = connecting ? "WHOOP isn't responding right now. Try connecting again in a little while." : RETRY_LATER;
  const res = await fetch(TOKEN_URL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ ...body, client_id: clientId, client_secret: clientSecret }),
  }).catch((err: Error) => {
    throw new WhoopError(unavailable, `WHOOP token request failed: ${err.message}`);
  });
  if (!res.ok) {
    const detail = `WHOOP token request failed (${res.status}): ${await res.text()}`;
    // 400/401: WHOOP turned the code or refresh token down (revoked, expired or already used).
    if (res.status !== 400 && res.status !== 401) throw new WhoopError(unavailable, detail);
    throw new WhoopError(connecting ? "WHOOP didn't accept the sign-in. Try connecting again." : RECONNECT, detail);
  }
  return (await res.json()) as TokenResponse;
}

async function saveTokens(q: Scope['db'] | { query: Scope['db']['query'] }, userId: string, t: TokenResponse, previousRefresh?: string | null) {
  await q.query(
    `INSERT INTO tokens (user_id, provider, access_token, refresh_token, expires_at, scope) VALUES ($1, 'whoop', $2, $3, $4, $5)
     ON CONFLICT (user_id, provider) DO UPDATE SET access_token = excluded.access_token, refresh_token = excluded.refresh_token,
     expires_at = excluded.expires_at, scope = excluded.scope`,
    [userId, t.access_token, t.refresh_token ?? previousRefresh ?? null, Date.now() + t.expires_in * 1000, t.scope ?? null],
  );
}

export async function exchangeCode(scope: Scope, code: string) {
  try {
    const t = await tokenRequest({ grant_type: 'authorization_code', code, redirect_uri: whoopConfig().redirectUri });
    await saveTokens(scope.db, scope.userId, t);
  } catch (err) {
    // The person sees the plain message on Integrations; the cause goes to the logs.
    console.error(`[whoop] connect failed for ${scope.userId}:`, errorDetail(err));
    throw err instanceof WhoopError ? err : new WhoopError("Couldn't finish connecting WHOOP. Try connecting again.", errorDetail(err));
  }
}

async function accessToken(scope: Scope, force = false): Promise<string> {
  const { db, userId } = scope;
  const [row] = await db.query<TokenRow>("SELECT access_token, refresh_token, expires_at FROM tokens WHERE user_id = $1 AND provider = 'whoop'", [userId]);
  if (!row) throw new WhoopError('WHOOP is not connected.');
  if (!force && Number(row.expires_at) - 120_000 > Date.now()) return row.access_token;
  // WHOOP rotates refresh tokens and rejects concurrent refreshes, and the cron and a manual sync can run
  // on different instances at once. Lock the token row, then re-read it: if someone else refreshed while
  // we waited, use their token instead of spending the (now invalid) old refresh token.
  return db.tx(async (q) => {
    const [locked] = await q.query<TokenRow>(
      "SELECT access_token, refresh_token, expires_at FROM tokens WHERE user_id = $1 AND provider = 'whoop' FOR UPDATE",
      [userId],
    );
    if (!locked) throw new WhoopError('WHOOP is not connected.');
    if (locked.access_token !== row.access_token && Number(locked.expires_at) - 120_000 > Date.now()) return locked.access_token;
    if (!locked.refresh_token) throw new WhoopError(RECONNECT, 'No refresh token stored');
    const t = await tokenRequest({ grant_type: 'refresh_token', refresh_token: locked.refresh_token, scope: 'offline' });
    await saveTokens(q, userId, t, locked.refresh_token);
    return t.access_token;
  });
}

export async function disconnect(scope: Scope) {
  try {
    const token = await accessToken(scope);
    await fetch(`${API}/user/access`, { method: 'DELETE', headers: { Authorization: `Bearer ${token}` } });
  } catch {
    // Revoking is best effort; stored tokens are removed either way.
  }
  await scope.db.query("DELETE FROM tokens WHERE user_id = $1 AND provider = 'whoop'", [scope.userId]);
}

async function api<T>(scope: Scope, path: string, params: Record<string, string> = {}): Promise<T> {
  const url = `${API}${path}${Object.keys(params).length ? `?${new URLSearchParams(params)}` : ''}`;
  let refreshed = false;
  let forceRefresh = false;
  for (let attempt = 0; attempt < 5; attempt++) {
    const res = await fetch(url, { headers: { Authorization: `Bearer ${await accessToken(scope, forceRefresh)}` } });
    forceRefresh = false;
    if (res.ok) return (await res.json()) as T;
    if (res.status === 401 && !refreshed) {
      refreshed = forceRefresh = true;
      continue;
    }
    if (res.status === 429 || res.status >= 500) {
      const wait = Number(res.headers.get('retry-after')) * 1000 || 2000 * (attempt + 1);
      await new Promise((r) => setTimeout(r, wait));
      continue;
    }
    const detail = `WHOOP ${path} failed (${res.status}): ${await res.text()}`;
    // 401 here means it was refused even with a fresh token.
    if (res.status === 401) throw new WhoopError(RECONNECT, detail);
    if (res.status === 403) throw new WhoopError("WHOOP didn't allow access to your data. On the healthOS website, disconnect WHOOP and connect it again, allowing every permission.", detail);
    throw new WhoopError(SYNC_FAILED, detail);
  }
  throw new WhoopError(RETRY_LATER, `WHOOP ${path} kept failing (rate limited or server errors)`);
}

async function collect<T>(scope: Scope, path: string, start: string, end?: string): Promise<T[]> {
  const out: T[] = [];
  let nextToken: string | undefined;
  do {
    const page = await api<{ records: T[]; next_token?: string | null }>(scope, path, {
      limit: '25',
      start,
      ...(end ? { end } : {}),
      ...(nextToken ? { nextToken } : {}),
    });
    out.push(...page.records);
    nextToken = page.next_token ?? undefined;
  } while (nextToken);
  return out;
}

// ---------- Mapping (pure, tested) ----------

export type WhoopCycle = {
  id: number;
  start: string;
  end?: string | null;
  timezone_offset: string;
  score_state: string;
  score?: { strain: number; kilojoule: number; average_heart_rate: number; max_heart_rate: number };
  /** Steps over the cycle (waking to sleep, not midnight to midnight); null when the strap wasn't worn. Since 2026-09-23. */
  step_count?: number | null;
};

export type WhoopSleep = {
  id: string;
  cycle_id?: number;
  start: string;
  end: string;
  timezone_offset: string;
  nap: boolean;
  score_state: string;
  score?: {
    stage_summary: {
      total_in_bed_time_milli: number;
      total_awake_time_milli: number;
      total_light_sleep_time_milli: number;
      total_slow_wave_sleep_time_milli: number;
      total_rem_sleep_time_milli: number;
    };
    respiratory_rate?: number;
    sleep_performance_percentage?: number;
    sleep_efficiency_percentage?: number;
    sleep_consistency_percentage?: number;
  };
};

export type WhoopRecovery = {
  cycle_id: number;
  sleep_id: string;
  created_at: string;
  score_state: string;
  score?: {
    user_calibrating: boolean;
    recovery_score: number;
    resting_heart_rate: number;
    hrv_rmssd_milli: number;
    spo2_percentage?: number;
    skin_temp_celsius?: number;
  };
};

export type WhoopWorkout = {
  id: string;
  start: string;
  end: string;
  timezone_offset: string;
  sport_name?: string;
  score_state: string;
  score?: { strain: number; average_heart_rate: number; max_heart_rate: number; kilojoule: number; distance_meter?: number };
};

const H = 3_600_000;

/**
 * A finished cycle longer than this covers two waking days (the strap was off overnight, so no sleep ended
 * it): its steps can't be split. A late night out is shorter; a missed night is about 40 hours or more.
 */
const MAX_STEP_CYCLE_MS = 36 * H;
/**
 * WHOOP keeps a cycle open until it has processed the next sleep, after you wake. Past this, an open cycle's
 * count may already include the next morning's walking (if no sleep is found), so what's stored is kept.
 */
const OPEN_STEP_CYCLE_MS = 28 * H;

/**
 * One cycle's steps and the day they belong to. `woke` says the date comes from the wake-up (otherwise it's
 * worked out from the start: this batch has the cycle but not its sleep). steps is null when the count can't
 * be used; `hold` means the stored count, if any, stays as it is for now.
 */
export type CycleSteps = { cycleId: number; start: number; date: string; woke: boolean; steps: number | null; hold?: boolean };

export function mapWhoop(
  data: { cycles: WhoopCycle[]; sleeps: WhoopSleep[]; recoveries: WhoopRecovery[]; workouts: WhoopWorkout[] },
  now = Date.now(),
) {
  const daily = new Map<string, DailyRow>();
  const add = (date: string, metric: string, value: number | undefined, mode: 'set' | 'sum' = 'set') => {
    if (value === undefined || !Number.isFinite(value)) return;
    const k = `${date}|${metric}`;
    const prev = daily.get(k);
    daily.set(k, { date, metric, source: SOURCE, value: mode === 'sum' && prev ? prev.value + value : value });
  };
  const events: EventRow[] = [];
  const workouts: WorkoutRow[] = [];

  // When you woke from each cycle's main sleep: a cycle's steps are walked after that, on that day.
  const wokeOn = new Map<number, string>();
  for (const s of data.sleeps) if (!s.nap && s.cycle_id !== undefined) wokeOn.set(s.cycle_id, localDate(stampFromIso(s.end, s.timezone_offset)));

  const cycleDay = new Map<number, string>();
  const cycleSteps: CycleSteps[] = [];
  for (const c of data.cycles) {
    // A cycle starts when you fall asleep, so it belongs to the day you wake into.
    const day = localDate(stampFromIso(c.start, c.timezone_offset), DAY_ROLLOVER_MS);
    cycleDay.set(c.id, day);
    // Steps (also on the current, unscored cycle: steps so far) are dated by the wake-up when it's known,
    // which handles an early bedtime; a finished cycle that spans two waking days is left out.
    const start = Date.parse(c.start);
    const woke = wokeOn.get(c.id);
    const counted = typeof c.step_count === 'number' && c.step_count >= 0;
    const usable = counted && (!c.end || Date.parse(c.end) - start <= MAX_STEP_CYCLE_MS);
    const hold = !c.end && now - start > OPEN_STEP_CYCLE_MS;
    cycleSteps.push({ cycleId: c.id, start, date: woke ?? day, woke: woke !== undefined, steps: usable ? (c.step_count as number) : null, ...(hold ? { hold } : {}) });
    if (c.score_state !== 'SCORED' || !c.score) continue;
    add(day, 'strain', c.score.strain);
    add(day, 'whoop_kcal', c.score.kilojoule / 4.184);
    add(day, 'hr_avg', c.score.average_heart_rate);
  }

  const sleepDay = new Map<string, string>();
  for (const s of data.sleeps) {
    const start = stampFromIso(s.start, s.timezone_offset);
    const end = stampFromIso(s.end, s.timezone_offset);
    const day = localDate(end, DAY_ROLLOVER_MS);
    sleepDay.set(s.id, day);
    events.push({ id: `whoop-sleep-${s.id}`, source: SOURCE, kind: s.nap ? 'nap' : 'sleep', title: s.nap ? 'Nap' : 'Sleep', start: toLocalIso(start), end: toLocalIso(end), date: day });
    if (s.score_state !== 'SCORED' || !s.score) continue;
    const st = s.score.stage_summary;
    const asleep = st.total_light_sleep_time_milli + st.total_slow_wave_sleep_time_milli + st.total_rem_sleep_time_milli;
    // Naps add to the day's total sleep; stage and quality numbers come from the main sleep only.
    add(day, 'sleep_hours', asleep / H, 'sum');
    if (s.nap) continue;
    add(day, 'sleep_in_bed', st.total_in_bed_time_milli / H, 'sum');
    add(day, 'sleep_deep', st.total_slow_wave_sleep_time_milli / H, 'sum');
    add(day, 'sleep_rem', st.total_rem_sleep_time_milli / H, 'sum');
    add(day, 'sleep_light', st.total_light_sleep_time_milli / H, 'sum');
    add(day, 'sleep_awake', st.total_awake_time_milli / H, 'sum');
    add(day, 'resp_rate', s.score.respiratory_rate);
    add(day, 'sleep_performance', s.score.sleep_performance_percentage);
    add(day, 'sleep_efficiency', s.score.sleep_efficiency_percentage);
    add(day, 'sleep_consistency', s.score.sleep_consistency_percentage);
  }

  for (const r of data.recoveries) {
    if (r.score_state !== 'SCORED' || !r.score) continue;
    const day = sleepDay.get(r.sleep_id) ?? cycleDay.get(r.cycle_id) ?? r.created_at.slice(0, 10);
    add(day, 'recovery', r.score.recovery_score);
    add(day, 'resting_hr', r.score.resting_heart_rate);
    add(day, 'hrv_rmssd', r.score.hrv_rmssd_milli);
    add(day, 'spo2', r.score.spo2_percentage);
    add(day, 'skin_temp', r.score.skin_temp_celsius);
  }

  for (const w of data.workouts) {
    const start = stampFromIso(w.start, w.timezone_offset);
    const end = stampFromIso(w.end, w.timezone_offset);
    const scored = w.score_state === 'SCORED' && w.score;
    workouts.push({
      id: `whoop-${w.id}`,
      source: SOURCE,
      sport: titleCase(w.sport_name ?? 'Activity'),
      start: toLocalIso(start),
      end: toLocalIso(end),
      date: localDate(start),
      duration_min: (end.ms - start.ms) / 60_000,
      energy_kcal: scored ? w.score!.kilojoule / 4.184 : null,
      distance_m: scored && w.score!.distance_meter ? w.score!.distance_meter : null,
      avg_hr: scored ? w.score!.average_heart_rate : null,
      max_hr: scored ? w.score!.max_heart_rate : null,
      strain: scored ? w.score!.strain : null,
    });
  }

  return { daily: [...daily.values()], events, workouts, cycleSteps };
}

function titleCase(s: string) {
  return s.replace(/[-_]+/g, ' ').replace(/\b\w/g, (c) => c.toUpperCase());
}

// ---------- Sync ----------
// Sync status is kept in the database so every instance (and the dashboard) sees the same thing.

/** `lastError` is in plain words for the person; `lastErrorDetail` is the technical cause, for the admin screen. */
export type SyncState = {
  running: boolean;
  startedAt?: string;
  lastSync?: string;
  lastError?: string;
  lastErrorDetail?: string;
  lastCounts?: Record<string, number>;
};
const STALE_RUN_MS = 10 * 60_000;

export async function syncState(scope: Scope): Promise<SyncState> {
  const raw = await getUserSetting(scope.db, scope.userId, 'whoop_sync');
  const s: SyncState = raw ? JSON.parse(raw) : { running: false };
  // A run whose function was cut off never clears its flag; treat it as finished after a while.
  if (s.running && (!s.startedAt || Date.now() - Date.parse(s.startedAt) > STALE_RUN_MS)) s.running = false;
  return s;
}

async function saveSyncState(scope: Scope, s: SyncState) {
  await setUserSetting(scope.db, scope.userId, 'whoop_sync', JSON.stringify(s));
}

/**
 * Keep each cycle's steps, then rebuild the WHOOP step count of every day those cycles touch (now or before
 * a re-date) from all of that day's stored cycles. A batch that holds only some of a day's cycles (the
 * sync window slides forward) therefore never replaces the day's total with part of it.
 *
 * `range` is the window the batch was read for (ms; no end means up to now). WHOOP returns every cycle that
 * overlaps it, so a stored cycle that began inside it and wasn't returned is gone (a sleep was deleted and
 * its cycle merged into the one before) and is removed. Not when nothing came back at all, so an empty
 * answer can't wipe a window.
 */
export async function storeCycleSteps(q: Queryable, userId: string, cycles: CycleSteps[], range?: { start: number; end?: number }) {
  if (!cycles.length) return;
  const ids = cycles.map((c) => c.cycleId);
  const gone = range
    ? await q.query<{ cycle_id: string | number; date: string }>(
        `SELECT cycle_id, date FROM whoop_cycle_steps WHERE user_id = $1 AND NOT (cycle_id = ANY($2)) AND start_ms >= $3${range.end === undefined ? '' : ' AND start_ms < $4'}`,
        [userId, ids, range.start, ...(range.end === undefined ? [] : [range.end])],
      )
    : [];
  const stored = new Map(
    (await q.query<{ cycle_id: string | number; date: string }>('SELECT cycle_id, date FROM whoop_cycle_steps WHERE user_id = $1 AND cycle_id = ANY($2)', [userId, ids])).map(
      (r) => [Number(r.cycle_id), r.date],
    ),
  );
  // A held cycle (open past the limit) keeps its stored count. A date worked out from the start never
  // replaces one that came from the wake-up: the window moved past the sleep, not the cycle.
  const write = cycles.filter((c) => !c.hold).map((c) => (!c.woke && stored.has(c.cycleId) ? { ...c, date: stored.get(c.cycleId)! } : c));
  // Every date a cycle here is or was on (a held cycle's too: rebuilding from what's stored changes nothing
  // unless that day's total was cleared).
  const dates = new Set([...gone.map((r) => r.date), ...write.map((c) => c.date), ...cycles.flatMap((c) => (stored.has(c.cycleId) ? [stored.get(c.cycleId)!] : []))]);
  await q.query('DELETE FROM whoop_cycle_steps WHERE user_id = $1 AND cycle_id = ANY($2)', [userId, [...gone.map((r) => Number(r.cycle_id)), ...write.map((c) => c.cycleId)]]);
  const keep = write.filter((c) => c.steps !== null);
  await insertMany(q, 'whoop_cycle_steps', ['user_id', 'cycle_id', 'start_ms', 'date', 'steps'], keep.map((c) => [userId, c.cycleId, c.start, c.date, c.steps]));
  await rebuildWhoopSteps(q, userId, [...dates]);
}

export async function rebuildWhoopSteps(q: Queryable, userId: string, dates: string[]) {
  if (!dates.length) return;
  await q.query("DELETE FROM daily WHERE user_id = $1 AND metric = 'steps' AND source = 'whoop' AND date = ANY($2)", [userId, dates]);
  await q.query(
    `INSERT INTO daily (user_id, date, metric, source, value)
     SELECT user_id, date, 'steps', 'whoop', SUM(steps) FROM whoop_cycle_steps WHERE user_id = $1 AND date = ANY($2) GROUP BY user_id, date`,
    [userId, dates],
  );
}

/**
 * Fetch and store everything WHOOP has between start and end (ISO). Returns record counts. `first` runs in
 * the same transaction, before anything is written.
 */
async function syncRange(scope: Scope, start: string, end?: string, first?: (q: Queryable) => Promise<unknown>) {
  const cycles = await collect<WhoopCycle>(scope, '/cycle', start, end);
  const sleeps = await collect<WhoopSleep>(scope, '/activity/sleep', start, end);
  const recoveries = await collect<WhoopRecovery>(scope, '/recovery', start, end);
  const workouts = await collect<WhoopWorkout>(scope, '/activity/workout', start, end);
  const mapped = mapWhoop({ cycles, sleeps, recoveries, workouts });
  await scope.db.tx(async (q) => {
    await first?.(q);
    await upsertDaily(q, scope.userId, mapped.daily);
    await upsertEvents(q, scope.userId, mapped.events);
    await upsertWorkouts(q, scope.userId, mapped.workouts);
    await storeCycleSteps(q, scope.userId, mapped.cycleSteps, { start: Date.parse(start), ...(end ? { end: Date.parse(end) } : {}) });
  });
  return { cycles: cycles.length, sleeps: sleeps.length, recoveries: recoveries.length, workouts: workouts.length };
}

/**
 * Recent data first (re-reading the last few days, which WHOOP rescores), then older history in windows
 * until the deadline, resuming from where the previous sync stopped.
 */
/** WHOOP added step_count to cycles on 2026-09-23; a few days earlier covers cycles that began before it. */
const WHOOP_STEPS_FROM = '2026-09-20T00:00:00.000Z';

export async function syncWhoop(scope: Scope, opts: { full?: boolean; deadline?: number; backfill?: boolean } = {}) {
  const prev = await syncState(scope);
  if (prev.running) return;
  const deadline = opts.deadline ?? Date.now() + SYNC_BUDGET_MS;
  await saveSyncState(scope, { ...prev, running: true, startedAt: new Date().toISOString(), lastError: undefined, lastErrorDetail: undefined });
  try {
    const last = await getUserSetting(scope.db, scope.userId, 'whoop_last_sync');
    const since = !last || opts.full ? Date.now() - BACKFILL_DAYS * DAY_MS : Date.parse(last) - 4 * DAY_MS;

    const [profile, body] = await Promise.all([
      api<{ first_name?: string }>(scope, '/user/profile/basic').catch(() => null),
      api<{ max_heart_rate?: number }>(scope, '/user/measurement/body').catch(() => null),
    ]);
    const counts = await syncRange(scope, new Date(since).toISOString());
    // Once per person: re-read the weeks since WHOOP started reporting steps on cycles. Version 2 also clears
    // the day totals the first version wrote (summed per batch and dated by when you fell asleep) before
    // the cycles rebuild them, in one transaction. (Recent days are re-read on every sync anyway.)
    if (!(await getUserSetting(scope.db, scope.userId, 'whoop_steps_v2'))) {
      await syncRange(scope, WHOOP_STEPS_FROM, undefined, (q) =>
        q.query("DELETE FROM daily WHERE user_id = $1 AND metric = 'steps' AND source = 'whoop' AND date >= $2", [scope.userId, WHOOP_STEPS_FROM.slice(0, 10)]),
      );
      await setUserSetting(scope.db, scope.userId, 'whoop_steps_v2', WHOOP_STEPS_FROM);
    }
    if (profile?.first_name) await setUserSetting(scope.db, scope.userId, 'whoop_first_name', profile.first_name);
    // WHOOP's weight is whatever is typed into the profile, not a weigh-in, so it isn't stored as a measurement.
    if (body?.max_heart_rate) await setUserSetting(scope.db, scope.userId, 'whoop_max_hr', String(body.max_heart_rate));

    const lastSync = new Date().toISOString();
    await setUserSetting(scope.db, scope.userId, 'whoop_last_sync', lastSync);
    // Recent days are in: let clients refetch now rather than after the history backfill below.
    await bumpDataVersion(scope.db, scope.userId);

    const saved = Number(await getUserSetting(scope.db, scope.userId, 'whoop_backfill_before'));
    let before = Number.isFinite(saved) && saved > 0 ? saved : Math.min(since, Date.now() - BACKFILL_DAYS * DAY_MS);
    while (opts.backfill !== false && before > HISTORY_START && Date.now() < deadline) {
      const after = Math.max(HISTORY_START, before - WINDOW_DAYS * DAY_MS);
      const got = await syncRange(scope, new Date(after).toISOString(), new Date(before).toISOString());
      for (const k of Object.keys(counts) as (keyof typeof counts)[]) counts[k] += got[k];
      before = after;
      await setUserSetting(scope.db, scope.userId, 'whoop_backfill_before', String(before));
    }

    if (before < (Number.isFinite(saved) && saved > 0 ? saved : Infinity)) await bumpDataVersion(scope.db, scope.userId);
    await saveSyncState(scope, { running: false, lastSync, lastCounts: { ...counts, historyComplete: before <= HISTORY_START ? 1 : 0 } });
  } catch (err) {
    const detail = errorDetail(err);
    console.error(`[whoop] sync failed for ${scope.userId}:`, detail);
    // Anything that isn't a WhoopError (a database error, a network failure) is described the same way.
    const lastError = err instanceof WhoopError ? err.message : SYNC_FAILED;
    await saveSyncState(scope, { ...prev, running: false, lastError, lastErrorDetail: detail.slice(0, 500) });
    throw err;
  }
}

/**
 * Active accounts with WHOOP connected. The owner's data predates accounts: until their first sign-in creates
 * the users row (or locally, with sign-in off), there's no row for them, and their sync must keep running.
 */
export function whoopSyncTargets(db: Db) {
  return db.query<{ user_id: string }>(
    `SELECT t.user_id FROM tokens t LEFT JOIN users u ON u.id = t.user_id
     WHERE t.provider = 'whoop' AND (u.status = 'active' OR (u.id IS NULL AND t.user_id = $1)) ORDER BY t.user_id`,
    [OWNER_ID],
  );
}

/** Whether the backfill has reached HISTORY_START, so there's no older history left to fetch. */
async function historyComplete(scope: Scope) {
  const before = Number(await getUserSetting(scope.db, scope.userId, 'whoop_backfill_before'));
  return before > 0 && before <= HISTORY_START;
}

/**
 * The cron: everyone with WHOOP connected. Recent data for all of them first, then history backfill with
 * whatever time is left. One person's failure (an expired connection) doesn't stop the others.
 *
 * The history pass re-reads recent days as well, so it only runs for people with history still to fetch:
 * once that's done, each hourly run makes one sync per person rather than two. Someone whose recent sync
 * just failed waits for the next run instead of failing again (and the failure stays on show).
 */
export async function syncAllWhoop(db: Db) {
  const deadline = Date.now() + SYNC_BUDGET_MS;
  const users = await whoopSyncTargets(db);
  const results: Record<string, string> = {};
  const sync = async (userId: string, backfill: boolean) => {
    try {
      await syncWhoop({ db, userId }, { deadline, backfill });
      results[userId] = 'ok';
    } catch (err) {
      results[userId] = errorDetail(err).slice(0, 120);
    }
  };
  for (const { user_id } of users) {
    if (Date.now() > deadline) break;
    await sync(user_id, false);
  }
  for (const { user_id } of users) {
    if (Date.now() > deadline) break;
    if (results[user_id] !== 'ok' || (await historyComplete({ db, userId: user_id }))) continue;
    await sync(user_id, true);
  }
  return { users: users.length, results };
}
