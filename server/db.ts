import { DatabaseSync } from 'node:sqlite';
import fs from 'node:fs';
import path from 'node:path';

export type Db = DatabaseSync;

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

const SCHEMA = `
PRAGMA journal_mode = WAL;
CREATE TABLE IF NOT EXISTS daily (
  date   TEXT NOT NULL,
  metric TEXT NOT NULL,
  source TEXT NOT NULL,
  value  REAL NOT NULL,
  PRIMARY KEY (date, metric, source)
);
CREATE INDEX IF NOT EXISTS daily_metric ON daily (metric, source, date);
CREATE TABLE IF NOT EXISTS workouts (
  id TEXT PRIMARY KEY,
  source TEXT NOT NULL,
  sport TEXT NOT NULL,
  start TEXT NOT NULL,
  end TEXT NOT NULL,
  date TEXT NOT NULL,
  duration_min REAL NOT NULL,
  energy_kcal REAL,
  distance_m REAL,
  avg_hr REAL,
  max_hr REAL,
  strain REAL
);
CREATE INDEX IF NOT EXISTS workouts_date ON workouts (date);
CREATE TABLE IF NOT EXISTS events (
  id TEXT PRIMARY KEY,
  source TEXT NOT NULL,
  kind TEXT NOT NULL,
  title TEXT NOT NULL,
  start TEXT NOT NULL,
  end TEXT NOT NULL,
  date TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS events_date ON events (date);
CREATE TABLE IF NOT EXISTS settings (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS tokens (
  provider TEXT PRIMARY KEY,
  access_token TEXT NOT NULL,
  refresh_token TEXT,
  expires_at INTEGER NOT NULL,
  scope TEXT
);
`;

export function openDb(file: string): Db {
  if (file !== ':memory:') fs.mkdirSync(path.dirname(file), { recursive: true });
  const db = new DatabaseSync(file);
  db.exec(SCHEMA);
  return db;
}

export const DATA_DIR = path.resolve(process.env.HEALTHOS_DATA_DIR ?? path.join(import.meta.dirname, '..', 'data'));

let shared: Db | undefined;
export function getDb(): Db {
  shared ??= openDb(path.join(DATA_DIR, 'healthos.db'));
  return shared;
}

export function transaction<T>(db: Db, fn: () => T): T {
  db.exec('BEGIN');
  try {
    const result = fn();
    db.exec('COMMIT');
    return result;
  } catch (err) {
    db.exec('ROLLBACK');
    throw err;
  }
}

export function upsertDaily(db: Db, rows: Iterable<DailyRow>) {
  const stmt = db.prepare(
    'INSERT INTO daily (date, metric, source, value) VALUES (?, ?, ?, ?) ON CONFLICT (date, metric, source) DO UPDATE SET value = excluded.value',
  );
  for (const r of rows) {
    if (Number.isFinite(r.value)) stmt.run(r.date, r.metric, r.source, r.value);
  }
}

export function upsertWorkouts(db: Db, rows: Iterable<WorkoutRow>) {
  const stmt = db.prepare(
    `INSERT OR REPLACE INTO workouts (id, source, sport, start, end, date, duration_min, energy_kcal, distance_m, avg_hr, max_hr, strain)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
  );
  for (const w of rows) {
    stmt.run(w.id, w.source, w.sport, w.start, w.end, w.date, w.duration_min, w.energy_kcal, w.distance_m, w.avg_hr, w.max_hr, w.strain);
  }
}

export function upsertEvents(db: Db, rows: Iterable<EventRow>) {
  const stmt = db.prepare('INSERT OR REPLACE INTO events (id, source, kind, title, start, end, date) VALUES (?, ?, ?, ?, ?, ?, ?)');
  for (const e of rows) stmt.run(e.id, e.source, e.kind, e.title, e.start, e.end, e.date);
}

export function deleteSource(db: Db, source: string) {
  for (const table of ['daily', 'workouts', 'events']) {
    db.prepare(`DELETE FROM ${table} WHERE source = ?`).run(source);
  }
}

export function getSetting(db: Db, key: string): string | undefined {
  const row = db.prepare('SELECT value FROM settings WHERE key = ?').get(key) as { value: string } | undefined;
  return row?.value;
}

export function setSetting(db: Db, key: string, value: string | null) {
  if (value === null) db.prepare('DELETE FROM settings WHERE key = ?').run(key);
  else db.prepare('INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value').run(key, value);
}
