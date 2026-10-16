import { randomBytes } from 'node:crypto';
import { type Db, type EventRow, type Queryable, type WorkoutRow, type DailyRow, getSetting, setSetting, upsertDaily, upsertEvents, upsertWorkouts } from './db.ts';
import { DAY_MS, DAY_ROLLOVER_MS, localDate, stampFromIso, toLocalIso, todayLocal } from './dates.ts';

export const SOURCE = 'whoop';

const AUTH_URL = 'https://api.prod.whoop.com/oauth/oauth2/auth';
const TOKEN_URL = 'https://api.prod.whoop.com/oauth/oauth2/token';
const API = 'https://api.prod.whoop.com/developer/v2';
// `offline` is what makes WHOOP return a refresh token.
const SCOPES = ['offline', 'read:profile', 'read:body_measurement', 'read:cycles', 'read:recovery', 'read:sleep', 'read:workout'];
const BACKFILL_DAYS = 365;

export function whoopConfig() {
  const port = process.env.PORT ?? '8787';
  return {
    clientId: process.env.WHOOP_CLIENT_ID ?? '',
    clientSecret: process.env.WHOOP_CLIENT_SECRET ?? '',
    redirectUri: process.env.WHOOP_REDIRECT_URI || `http://localhost:${port}/api/whoop/callback`,
  };
}

export const isConfigured = () => Boolean(whoopConfig().clientId && whoopConfig().clientSecret);

export async function isConnected(q: Queryable) {
  const [row] = await q.query<{ any: boolean }>("SELECT EXISTS (SELECT 1 FROM tokens WHERE provider = 'whoop') AS any");
  return Boolean(row?.any);
}

// ---------- OAuth ----------
// The connect and callback requests can land on different serverless instances, so the pending
// state lives in the database rather than in memory.

export async function authorizeUrl(q: Queryable): Promise<string> {
  const { clientId, redirectUri } = whoopConfig();
  // WHOOP requires an 8-character state.
  const state = randomBytes(6).toString('base64url').slice(0, 8);
  await setSetting(q, 'whoop_oauth_state', JSON.stringify({ state, expires: Date.now() + 10 * 60_000 }));
  const params = new URLSearchParams({ response_type: 'code', client_id: clientId, redirect_uri: redirectUri, scope: SCOPES.join(' '), state });
  return `${AUTH_URL}?${params}`;
}

export async function consumeState(q: Queryable, state: string | undefined): Promise<boolean> {
  const raw = await getSetting(q, 'whoop_oauth_state');
  await setSetting(q, 'whoop_oauth_state', null);
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

async function saveTokens(q: Queryable, t: TokenResponse, previousRefresh?: string | null) {
  await q.query(
    `INSERT INTO tokens (provider, access_token, refresh_token, expires_at, scope) VALUES ('whoop', $1, $2, $3, $4)
     ON CONFLICT (provider) DO UPDATE SET access_token = excluded.access_token, refresh_token = excluded.refresh_token,
     expires_at = excluded.expires_at, scope = excluded.scope`,
    [t.access_token, t.refresh_token ?? previousRefresh ?? null, Date.now() + t.expires_in * 1000, t.scope ?? null],
  );
}

export async function exchangeCode(q: Queryable, code: string) {
  const t = await tokenRequest({ grant_type: 'authorization_code', code, redirect_uri: whoopConfig().redirectUri });
  await saveTokens(q, t);
}

async function accessToken(db: Db, force = false): Promise<string> {
  const [row] = await db.query<TokenRow>("SELECT access_token, refresh_token, expires_at FROM tokens WHERE provider = 'whoop'");
  if (!row) throw new Error('WHOOP is not connected');
  if (!force && Number(row.expires_at) - 120_000 > Date.now()) return row.access_token;
  // WHOOP rotates refresh tokens and rejects concurrent refreshes, and the cron and a manual sync can run
  // on different instances at once. Lock the token row, then re-read it: if someone else refreshed while
  // we waited, use their token instead of spending the (now invalid) old refresh token.
  return db.tx(async (q) => {
    const [locked] = await q.query<TokenRow>("SELECT access_token, refresh_token, expires_at FROM tokens WHERE provider = 'whoop' FOR UPDATE");
    if (!locked) throw new Error('WHOOP is not connected');
    if (locked.access_token !== row.access_token && Number(locked.expires_at) - 120_000 > Date.now()) return locked.access_token;
    if (!locked.refresh_token) throw new Error('WHOOP session expired. Reconnect WHOOP.');
    const t = await tokenRequest({ grant_type: 'refresh_token', refresh_token: locked.refresh_token, scope: 'offline' });
    await saveTokens(q, t, locked.refresh_token);
    return t.access_token;
  });
}

export async function disconnect(db: Db) {
  try {
    const token = await accessToken(db);
    await fetch(`${API}/user/access`, { method: 'DELETE', headers: { Authorization: `Bearer ${token}` } });
  } catch {
    // Revoking is best effort; local tokens are removed either way.
  }
  await db.query("DELETE FROM tokens WHERE provider = 'whoop'");
}

async function api<T>(db: Db, path: string, params: Record<string, string> = {}): Promise<T> {
  const url = `${API}${path}${Object.keys(params).length ? `?${new URLSearchParams(params)}` : ''}`;
  let refreshed = false;
  let forceRefresh = false;
  for (let attempt = 0; attempt < 5; attempt++) {
    const res = await fetch(url, { headers: { Authorization: `Bearer ${await accessToken(db, forceRefresh)}` } });
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

async function collect<T>(db: Db, path: string, start: string): Promise<T[]> {
  const out: T[] = [];
  let nextToken: string | undefined;
  do {
    const page = await api<{ records: T[]; next_token?: string | null }>(db, path, {
      limit: '25',
      start,
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

export async function syncState(q: Queryable): Promise<SyncState> {
  const raw = await getSetting(q, 'whoop_sync');
  const s: SyncState = raw ? JSON.parse(raw) : { running: false };
  // A run whose function was cut off never clears its flag; treat it as finished after a while.
  if (s.running && (!s.startedAt || Date.now() - Date.parse(s.startedAt) > STALE_RUN_MS)) s.running = false;
  return s;
}

async function saveSyncState(q: Queryable, s: SyncState) {
  await setSetting(q, 'whoop_sync', JSON.stringify(s));
}

export async function syncWhoop(db: Db, opts: { full?: boolean; timeZone?: string } = {}) {
  const prev = await syncState(db);
  if (prev.running) return;
  await saveSyncState(db, { ...prev, running: true, startedAt: new Date().toISOString(), lastError: undefined });
  try {
    const last = await getSetting(db, 'whoop_last_sync');
    // Re-read a few days on each sync: WHOOP rescores recent sleep and recovery after the fact.
    const since = !last || opts.full ? Date.now() - BACKFILL_DAYS * DAY_MS : Date.parse(last) - 4 * DAY_MS;
    const start = new Date(since).toISOString();

    const [profile, body] = await Promise.all([
      api<{ first_name?: string }>(db, '/user/profile/basic').catch(() => null),
      api<{ weight_kilogram?: number; max_heart_rate?: number }>(db, '/user/measurement/body').catch(() => null),
    ]);
    const cycles = await collect<WhoopCycle>(db, '/cycle', start);
    const sleeps = await collect<WhoopSleep>(db, '/activity/sleep', start);
    const recoveries = await collect<WhoopRecovery>(db, '/recovery', start);
    const workouts = await collect<WhoopWorkout>(db, '/activity/workout', start);

    const mapped = mapWhoop({ cycles, sleeps, recoveries, workouts });
    await db.tx(async (q) => {
      await upsertDaily(q, mapped.daily);
      if (body?.weight_kilogram) {
        await upsertDaily(q, [{ date: todayLocal(opts.timeZone), metric: 'weight', source: SOURCE, value: body.weight_kilogram }]);
      }
      await upsertEvents(q, mapped.events);
      await upsertWorkouts(q, mapped.workouts);
    });
    if (profile?.first_name) await setSetting(db, 'whoop_first_name', profile.first_name);
    if (body?.max_heart_rate) await setSetting(db, 'whoop_max_hr', String(body.max_heart_rate));

    const lastSync = new Date().toISOString();
    await setSetting(db, 'whoop_last_sync', lastSync);
    await saveSyncState(db, {
      running: false,
      lastSync,
      lastCounts: { cycles: cycles.length, sleeps: sleeps.length, recoveries: recoveries.length, workouts: workouts.length },
    });
  } catch (err) {
    await saveSyncState(db, { ...prev, running: false, lastError: err instanceof Error ? err.message : String(err) });
    throw err;
  }
}
