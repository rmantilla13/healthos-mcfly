import { randomBytes } from 'node:crypto';
import { type DailyRow, type Db, type EventRow, OWNER_ID, type Scope, type WorkoutRow, getUserSetting, setUserSetting, upsertDaily, upsertEvents, upsertWorkouts } from './db.ts';
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
  const res = await fetch(TOKEN_URL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ ...body, client_id: clientId, client_secret: clientSecret }),
  });
  if (!res.ok) throw new Error(`WHOOP token request failed (${res.status}): ${await res.text()}`);
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
  const t = await tokenRequest({ grant_type: 'authorization_code', code, redirect_uri: whoopConfig().redirectUri });
  await saveTokens(scope.db, scope.userId, t);
}

async function accessToken(scope: Scope, force = false): Promise<string> {
  const { db, userId } = scope;
  const [row] = await db.query<TokenRow>("SELECT access_token, refresh_token, expires_at FROM tokens WHERE user_id = $1 AND provider = 'whoop'", [userId]);
  if (!row) throw new Error('WHOOP is not connected');
  if (!force && Number(row.expires_at) - 120_000 > Date.now()) return row.access_token;
  // WHOOP rotates refresh tokens and rejects concurrent refreshes, and the cron and a manual sync can run
  // on different instances at once. Lock the token row, then re-read it: if someone else refreshed while
  // we waited, use their token instead of spending the (now invalid) old refresh token.
  return db.tx(async (q) => {
    const [locked] = await q.query<TokenRow>(
      "SELECT access_token, refresh_token, expires_at FROM tokens WHERE user_id = $1 AND provider = 'whoop' FOR UPDATE",
      [userId],
    );
    if (!locked) throw new Error('WHOOP is not connected');
    if (locked.access_token !== row.access_token && Number(locked.expires_at) - 120_000 > Date.now()) return locked.access_token;
    if (!locked.refresh_token) throw new Error('WHOOP session expired. Reconnect WHOOP.');
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
    throw new Error(`WHOOP ${path} failed (${res.status}): ${await res.text()}`);
  }
  throw new Error(`WHOOP ${path} kept failing; try again later.`);
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

export function mapWhoop(data: { cycles: WhoopCycle[]; sleeps: WhoopSleep[]; recoveries: WhoopRecovery[]; workouts: WhoopWorkout[] }) {
  const daily = new Map<string, DailyRow>();
  const add = (date: string, metric: string, value: number | undefined, mode: 'set' | 'sum' = 'set') => {
    if (value === undefined || !Number.isFinite(value)) return;
    const k = `${date}|${metric}`;
    const prev = daily.get(k);
    daily.set(k, { date, metric, source: SOURCE, value: mode === 'sum' && prev ? prev.value + value : value });
  };
  const events: EventRow[] = [];
  const workouts: WorkoutRow[] = [];

  const cycleDay = new Map<number, string>();
  for (const c of data.cycles) {
    // A cycle starts when you fall asleep, so it belongs to the day you wake into.
    const day = localDate(stampFromIso(c.start, c.timezone_offset), DAY_ROLLOVER_MS);
    cycleDay.set(c.id, day);
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

  return { daily: [...daily.values()], events, workouts };
}

function titleCase(s: string) {
  return s.replace(/[-_]+/g, ' ').replace(/\b\w/g, (c) => c.toUpperCase());
}

// ---------- Sync ----------
// Sync status is kept in the database so every instance (and the dashboard) sees the same thing.

export type SyncState = { running: boolean; startedAt?: string; lastSync?: string; lastError?: string; lastCounts?: Record<string, number> };
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

/** Fetch and store everything WHOOP has between start and end (ISO). Returns record counts. */
async function syncRange(scope: Scope, start: string, end?: string) {
  const cycles = await collect<WhoopCycle>(scope, '/cycle', start, end);
  const sleeps = await collect<WhoopSleep>(scope, '/activity/sleep', start, end);
  const recoveries = await collect<WhoopRecovery>(scope, '/recovery', start, end);
  const workouts = await collect<WhoopWorkout>(scope, '/activity/workout', start, end);
  const mapped = mapWhoop({ cycles, sleeps, recoveries, workouts });
  await scope.db.tx(async (q) => {
    await upsertDaily(q, scope.userId, mapped.daily);
    await upsertEvents(q, scope.userId, mapped.events);
    await upsertWorkouts(q, scope.userId, mapped.workouts);
  });
  return { cycles: cycles.length, sleeps: sleeps.length, recoveries: recoveries.length, workouts: workouts.length };
}

/**
 * Recent data first (re-reading the last few days, which WHOOP rescores), then older history in windows
 * until the deadline, resuming from where the previous sync stopped.
 */
export async function syncWhoop(scope: Scope, opts: { full?: boolean; deadline?: number; backfill?: boolean } = {}) {
  const prev = await syncState(scope);
  if (prev.running) return;
  const deadline = opts.deadline ?? Date.now() + SYNC_BUDGET_MS;
  await saveSyncState(scope, { ...prev, running: true, startedAt: new Date().toISOString(), lastError: undefined });
  try {
    const last = await getUserSetting(scope.db, scope.userId, 'whoop_last_sync');
    const since = !last || opts.full ? Date.now() - BACKFILL_DAYS * DAY_MS : Date.parse(last) - 4 * DAY_MS;

    const [profile, body] = await Promise.all([
      api<{ first_name?: string }>(scope, '/user/profile/basic').catch(() => null),
      api<{ max_heart_rate?: number }>(scope, '/user/measurement/body').catch(() => null),
    ]);
    const counts = await syncRange(scope, new Date(since).toISOString());
    if (profile?.first_name) await setUserSetting(scope.db, scope.userId, 'whoop_first_name', profile.first_name);
    // WHOOP's weight is whatever is typed into the profile, not a weigh-in, so it isn't stored as a measurement.
    if (body?.max_heart_rate) await setUserSetting(scope.db, scope.userId, 'whoop_max_hr', String(body.max_heart_rate));

    const lastSync = new Date().toISOString();
    await setUserSetting(scope.db, scope.userId, 'whoop_last_sync', lastSync);

    const saved = Number(await getUserSetting(scope.db, scope.userId, 'whoop_backfill_before'));
    let before = Number.isFinite(saved) && saved > 0 ? saved : Math.min(since, Date.now() - BACKFILL_DAYS * DAY_MS);
    while (opts.backfill !== false && before > HISTORY_START && Date.now() < deadline) {
      const after = Math.max(HISTORY_START, before - WINDOW_DAYS * DAY_MS);
      const got = await syncRange(scope, new Date(after).toISOString(), new Date(before).toISOString());
      for (const k of Object.keys(counts) as (keyof typeof counts)[]) counts[k] += got[k];
      before = after;
      await setUserSetting(scope.db, scope.userId, 'whoop_backfill_before', String(before));
    }

    await saveSyncState(scope, { running: false, lastSync, lastCounts: { ...counts, historyComplete: before <= HISTORY_START ? 1 : 0 } });
  } catch (err) {
    await saveSyncState(scope, { ...prev, running: false, lastError: err instanceof Error ? err.message : String(err) });
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

/**
 * The cron: everyone with WHOOP connected. Recent data for all of them first, then history backfill with
 * whatever time is left. One person's failure (an expired connection) doesn't stop the others.
 */
export async function syncAllWhoop(db: Db) {
  const deadline = Date.now() + SYNC_BUDGET_MS;
  const users = await whoopSyncTargets(db);
  const results: Record<string, string> = {};
  for (const pass of ['recent', 'history'] as const) {
    for (const { user_id } of users) {
      if (Date.now() > deadline) break;
      try {
        await syncWhoop({ db, userId: user_id }, { deadline, backfill: pass === 'history' });
        results[user_id] = 'ok';
      } catch (err) {
        results[user_id] = err instanceof Error ? err.message.slice(0, 120) : 'failed';
      }
    }
  }
  return { users: users.length, results };
}
