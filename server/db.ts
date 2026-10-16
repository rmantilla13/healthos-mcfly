// Row types and write helpers over the Postgres store (server/store.ts).
import path from 'node:path';
import { type Db, type Queryable, getStore, insertMany } from './store.ts';

export type { Db, Queryable };
export { getStore };

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

export async function upsertDaily(q: Queryable, rows: DailyRow[]) {
  // One value per (date, metric, source): a later duplicate in the same batch would make Postgres
  // reject the statement ("cannot affect row a second time"), so keep the last one.
  const unique = new Map<string, DailyRow>();
  for (const r of rows) if (Number.isFinite(r.value)) unique.set(`${r.date}|${r.metric}|${r.source}`, r);
  await insertMany(
    q,
    'daily',
    ['date', 'metric', 'source', 'value'],
    [...unique.values()].map((r) => [r.date, r.metric, r.source, r.value]),
    'ON CONFLICT (date, metric, source) DO UPDATE SET value = excluded.value',
  );
}

const WORKOUT_COLS = ['id', 'source', 'sport', 'start', 'end', 'date', 'duration_min', 'energy_kcal', 'distance_m', 'avg_hr', 'max_hr', 'strain'] as const;

export async function upsertWorkouts(q: Queryable, rows: WorkoutRow[]) {
  const unique = new Map(rows.map((w) => [w.id, w]));
  await insertMany(
    q,
    'workouts',
    [...WORKOUT_COLS],
    [...unique.values()].map((w) => WORKOUT_COLS.map((c) => w[c])),
    `ON CONFLICT (id) DO UPDATE SET ${WORKOUT_COLS.filter((c) => c !== 'id')
      .map((c) => `"${c}" = excluded."${c}"`)
      .join(', ')}`,
  );
}

const EVENT_COLS = ['id', 'source', 'kind', 'title', 'start', 'end', 'date'] as const;

export async function upsertEvents(q: Queryable, rows: EventRow[]) {
  const unique = new Map(rows.map((e) => [e.id, e]));
  await insertMany(
    q,
    'events',
    [...EVENT_COLS],
    [...unique.values()].map((e) => EVENT_COLS.map((c) => e[c])),
    `ON CONFLICT (id) DO UPDATE SET ${EVENT_COLS.filter((c) => c !== 'id')
      .map((c) => `"${c}" = excluded."${c}"`)
      .join(', ')}`,
  );
}

export async function deleteSource(q: Queryable, source: string) {
  for (const table of ['daily', 'workouts', 'events']) {
    await q.query(`DELETE FROM ${table} WHERE source = $1`, [source]);
  }
}

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
