// Row types and write helpers over the Postgres store (server/store.ts). Every data row belongs to a user:
// helpers take the user id explicitly, and the schema has no default for it, so a write can't land unowned.
import { randomBytes } from 'node:crypto';
import path from 'node:path';
import { type Db, type Queryable, OWNER_ID, getStore, insertMany } from './store.ts';

export type { Db, Queryable };
export { OWNER_ID, getStore };

/** One person's view of the database. Every query that touches health data goes through a scope. */
export type Scope = { db: Db; userId: string };

export type DailyRow = { date: string; metric: string; source: string; value: number };

export type WorkoutRow = {
  id: string;
  source: string;
  sport: string;
  start: string;
  end: string;
  date: string;
  duration_min: number;
  energy_kcal: number | null;
  distance_m: number | null;
  avg_hr: number | null;
  max_hr: number | null;
  strain: number | null;
};

/** One local hour of one metric: a sum (steps, active_energy) or a reading (hr_avg, hr_min, hr_max). */
export type HourlyRow = { date: string; hour: number; metric: string; source: string; value: number };

/** Hourly metrics and how two buckets for the same hour combine (the repeated hour when clocks go back). */
export const HOURLY_FOLD: Record<string, (a: number, b: number) => number> = {
  steps: (a, b) => a + b,
  active_energy: (a, b) => a + b,
  hr_avg: (a, b) => (a + b) / 2,
  hr_min: Math.min,
  hr_max: Math.max,
};

export type EventRow = {
  id: string;
  source: string;
  kind: 'sleep' | 'nap' | 'mindful';
  title: string;
  start: string;
  end: string;
  date: string;
};

/** Local working files (uploads in progress, the compiled photo tool). Never used by the hosted app. */
export const DATA_DIR = path.resolve(process.env.HEALTHOS_DATA_DIR ?? path.join(import.meta.dirname, '..', 'data'));

export async function upsertDaily(q: Queryable, userId: string, rows: DailyRow[]) {
  // One value per (date, metric, source): a later duplicate in the same batch would make Postgres
  // reject the statement ("cannot affect row a second time"), so keep the last one.
  const unique = new Map<string, DailyRow>();
  for (const r of rows) if (Number.isFinite(r.value)) unique.set(`${r.date}|${r.metric}|${r.source}`, r);
  await insertMany(
    q,
    'daily',
    ['user_id', 'date', 'metric', 'source', 'value'],
    [...unique.values()].map((r) => [userId, r.date, r.metric, r.source, r.value]),
    'ON CONFLICT (user_id, date, metric, source) DO UPDATE SET value = excluded.value',
  );
}

const WORKOUT_COLS = ['id', 'source', 'sport', 'start', 'end', 'date', 'duration_min', 'energy_kcal', 'distance_m', 'avg_hr', 'max_hr', 'strain'] as const;

export async function upsertWorkouts(q: Queryable, userId: string, rows: WorkoutRow[]) {
  const unique = new Map(rows.map((w) => [w.id, w]));
  await insertMany(
    q,
    'workouts',
    ['user_id', ...WORKOUT_COLS],
    [...unique.values()].map((w) => [userId, ...WORKOUT_COLS.map((c) => w[c])]),
    `ON CONFLICT (user_id, id) DO UPDATE SET ${WORKOUT_COLS.filter((c) => c !== 'id')
      .map((c) => `"${c}" = excluded."${c}"`)
      .join(', ')}`,
  );
}

const EVENT_COLS = ['id', 'source', 'kind', 'title', 'start', 'end', 'date'] as const;

export async function upsertEvents(q: Queryable, userId: string, rows: EventRow[]) {
  const unique = new Map(rows.map((e) => [e.id, e]));
  await insertMany(
    q,
    'events',
    ['user_id', ...EVENT_COLS],
    [...unique.values()].map((e) => [userId, ...EVENT_COLS.map((c) => e[c])]),
    `ON CONFLICT (user_id, id) DO UPDATE SET ${EVENT_COLS.filter((c) => c !== 'id')
      .map((c) => `"${c}" = excluded."${c}"`)
      .join(', ')}`,
  );
}

export async function upsertHourly(q: Queryable, userId: string, rows: HourlyRow[]) {
  // One row per (metric, date, hour, source): duplicates in a batch fold together rather than make
  // Postgres reject the statement.
  const unique = new Map<string, HourlyRow>();
  for (const r of rows) {
    if (!Number.isFinite(r.value)) continue;
    const k = `${r.metric}|${r.date}|${r.hour}|${r.source}`;
    const prev = unique.get(k);
    unique.set(k, prev ? { ...r, value: (HOURLY_FOLD[r.metric] ?? ((_a, b) => b))(prev.value, r.value) } : r);
  }
  await insertMany(
    q,
    'hourly',
    ['user_id', 'metric', 'date', 'hour', 'source', 'value'],
    [...unique.values()].map((r) => [userId, r.metric, r.date, r.hour, r.source, r.value]),
    'ON CONFLICT (user_id, metric, date, hour, source) DO UPDATE SET value = excluded.value',
  );
}

/** One night's sleep stages from one device. */
export type SleepStageRow = { start: string; end: string; stage: string };

/**
 * Replaces the stages for each of these nights (wake dates) from this source: a resent night is the device's
 * whole night again, so what it no longer reports goes too.
 */
export async function replaceSleepStages(q: Queryable, userId: string, source: string, nights: { date: string; segments: SleepStageRow[] }[]) {
  if (!nights.length) return;
  await q.query('DELETE FROM sleep_stages WHERE user_id = $1 AND source = $2 AND date = ANY($3)', [userId, source, nights.map((n) => n.date)]);
  const rows = new Map<string, unknown[]>();
  for (const n of nights) for (const g of n.segments) rows.set(`${n.date}|${g.start}`, [userId, n.date, source, g.start, g.end, g.stage]);
  await insertMany(q, 'sleep_stages', ['user_id', 'date', 'source', 'start', 'end', 'stage'], [...rows.values()]);
}

/** One source's rows in every table that has them, except the tables in `keep`. */
export async function deleteSource(q: Queryable, userId: string, source: string, keep: string[] = []) {
  for (const table of ['daily', 'hourly', 'workouts', 'events', 'cycle', 'sleep_stages', 'nutrition_daily'].filter((t) => !keep.includes(t))) {
    await q.query(`DELETE FROM ${table} WHERE user_id = $1 AND source = $2`, [userId, source]);
  }
  if (source === 'whoop') await q.query('DELETE FROM whoop_cycle_steps WHERE user_id = $1', [userId]);
}

// ---------- settings ----------
// Platform-wide settings (sign-in guards, registration, defaults) live in `settings`;
// one person's settings (name, units, time zone, sync state…) live in `user_settings`.

export async function getSetting(q: Queryable, key: string): Promise<string | undefined> {
  const [row] = await q.query<{ value: string }>('SELECT value FROM settings WHERE key = $1', [key]);
  return row?.value;
}

export async function getSettings(q: Queryable): Promise<Map<string, string>> {
  const rows = await q.query<{ key: string; value: string }>('SELECT key, value FROM settings');
  return new Map(rows.map((r) => [r.key, r.value]));
}

export async function setSetting(q: Queryable, key: string, value: string | null) {
  if (value === null) await q.query('DELETE FROM settings WHERE key = $1', [key]);
  else await q.query('INSERT INTO settings (key, value) VALUES ($1, $2) ON CONFLICT (key) DO UPDATE SET value = excluded.value', [key, value]);
}

export async function getUserSetting(q: Queryable, userId: string, key: string): Promise<string | undefined> {
  const [row] = await q.query<{ value: string }>('SELECT value FROM user_settings WHERE user_id = $1 AND key = $2', [userId, key]);
  return row?.value;
}

export async function getUserSettings(q: Queryable, userId: string): Promise<Map<string, string>> {
  const rows = await q.query<{ key: string; value: string }>('SELECT key, value FROM user_settings WHERE user_id = $1', [userId]);
  return new Map(rows.map((r) => [r.key, r.value]));
}

export async function setUserSetting(q: Queryable, userId: string, key: string, value: string | null) {
  if (value === null) await q.query('DELETE FROM user_settings WHERE user_id = $1 AND key = $2', [userId, key]);
  else {
    await q.query(
      'INSERT INTO user_settings (user_id, key, value) VALUES ($1, $2, $3) ON CONFLICT (user_id, key) DO UPDATE SET value = excluded.value',
      [userId, key, value],
    );
  }
}

/**
 * Mark that this person's data changed. Clients poll GET /api/version (one row read) and refetch only when
 * it moves, instead of re-downloading everything on a timer. Opaque: compare it, don't parse it.
 */
export async function bumpDataVersion(q: Queryable, userId: string) {
  await setUserSetting(q, userId, 'data_version', `${Date.now().toString(36)}-${randomBytes(3).toString('hex')}`);
}

/** Everything one person stored, removed together (account deletion). */
export async function deleteUserData(q: Queryable, userId: string) {
  for (const table of ['daily', 'hourly', 'workouts', 'events', 'cycle', 'sleep_stages', 'nutrition_daily', 'food_log', 'whoop_cycle_steps', 'tokens', 'profile_assets', 'user_settings', 'mcfly_usage']) {
    await q.query(`DELETE FROM ${table} WHERE user_id = $1`, [userId]);
  }
}
