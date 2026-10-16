// Postgres storage. Neon in the cloud (DATABASE_URL set, e.g. by the Vercel Neon integration);
// PGlite (Postgres compiled to WASM, stored in data/pglite) locally and in tests. Same SQL everywhere.
import path from 'node:path';

export type Row = Record<string, unknown>;

export interface Queryable {
  query<T = Row>(text: string, params?: unknown[]): Promise<T[]>;
}

export interface Db extends Queryable {
  readonly kind: 'neon' | 'pglite';
  /** Several statements, no parameters (schema). */
  exec(text: string): Promise<void>;
  /** Run fn in one transaction; rolls back if it throws. */
  tx<T>(fn: (q: Queryable) => Promise<T>): Promise<T>;
  close(): Promise<void>;
}

export const SCHEMA = `
CREATE TABLE IF NOT EXISTS daily (
  date   TEXT NOT NULL,
  metric TEXT NOT NULL,
  source TEXT NOT NULL,
  value  DOUBLE PRECISION NOT NULL,
  PRIMARY KEY (date, metric, source)
);
CREATE INDEX IF NOT EXISTS daily_metric ON daily (metric, source, date);
CREATE TABLE IF NOT EXISTS workouts (
  id TEXT PRIMARY KEY,
  source TEXT NOT NULL,
  sport TEXT NOT NULL,
  start TEXT NOT NULL,
  "end" TEXT NOT NULL,
  date TEXT NOT NULL,
  duration_min DOUBLE PRECISION NOT NULL,
  energy_kcal DOUBLE PRECISION,
  distance_m DOUBLE PRECISION,
  avg_hr DOUBLE PRECISION,
  max_hr DOUBLE PRECISION,
  strain DOUBLE PRECISION
);
CREATE INDEX IF NOT EXISTS workouts_date ON workouts (date);
CREATE TABLE IF NOT EXISTS events (
  id TEXT PRIMARY KEY,
  source TEXT NOT NULL,
  kind TEXT NOT NULL,
  title TEXT NOT NULL,
  start TEXT NOT NULL,
  "end" TEXT NOT NULL,
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
  expires_at DOUBLE PRECISION NOT NULL,
  scope TEXT
);
CREATE TABLE IF NOT EXISTS profile_assets (
  name TEXT PRIMARY KEY,
  mime TEXT NOT NULL,
  data BYTEA NOT NULL,
  updated_at DOUBLE PRECISION NOT NULL
);
`;

async function openNeon(url: string): Promise<Db> {
  const { neon, Pool } = await import('@neondatabase/serverless');
  const sql = neon(url);
  // Plain queries go over HTTP (no connection to keep alive between invocations);
  // transactions and schema use a short-lived WebSocket pool.
  const withClient = async <T>(fn: (c: { query: (t: string, p?: unknown[]) => Promise<{ rows: Row[] }> }) => Promise<T>) => {
    const pool = new Pool({ connectionString: url });
    const client = await pool.connect();
    try {
      return await fn(client);
    } finally {
      client.release();
      await pool.end();
    }
  };
  return {
    kind: 'neon',
    async query<T>(text: string, params: unknown[] = []) {
      return (await sql.query(text, params)) as T[];
    },
    async exec(text) {
      await withClient((c) => c.query(text));
    },
    tx(fn) {
      return withClient(async (c) => {
        await c.query('BEGIN');
        try {
          const result = await fn({ query: async <T>(t: string, p: unknown[] = []) => (await c.query(t, p)).rows as T[] });
          await c.query('COMMIT');
          return result;
        } catch (err) {
          await c.query('ROLLBACK');
          throw err;
        }
      });
    },
    async close() {},
  };
}

async function openPglite(dir: string | undefined): Promise<Db> {
  const { PGlite } = await import('@electric-sql/pglite');
  const pg = await PGlite.create(dir);
  return {
    kind: 'pglite',
    async query<T>(text: string, params: unknown[] = []) {
      return (await pg.query(text, params)).rows as T[];
    },
    async exec(text) {
      await pg.exec(text);
    },
    tx(fn) {
      return pg.transaction((t) => fn({ query: async <T>(text: string, params: unknown[] = []) => (await t.query(text, params)).rows as T[] }));
    },
    close: () => pg.close(),
  };
}

/** Open a database and make sure the schema exists. `dir` undefined = in-memory PGlite (tests). */
export async function openStore(opts: { url?: string; dir?: string } = {}): Promise<Db> {
  const db = opts.url ? await openNeon(opts.url) : await openPglite(opts.dir);
  await db.exec(SCHEMA);
  return db;
}

let shared: Promise<Db> | undefined;

/** The app's database: Neon when DATABASE_URL is set, otherwise PGlite under data/. */
export function getStore(): Promise<Db> {
  shared ??= openStore(
    process.env.DATABASE_URL
      ? { url: process.env.DATABASE_URL }
      : { dir: path.join(process.env.HEALTHOS_DATA_DIR ?? path.join(import.meta.dirname, '..', 'data'), 'pglite') },
  );
  return shared;
}

/**
 * Insert many rows in chunks with one multi-row statement each, rather than a round trip per row
 * (which over the network would turn a 60k-row import into many minutes).
 */
export async function insertMany(q: Queryable, table: string, columns: string[], rows: unknown[][], conflict = '') {
  const perChunk = Math.max(1, Math.floor(30_000 / columns.length));
  const cols = columns.map((c) => `"${c}"`).join(', ');
  for (let i = 0; i < rows.length; i += perChunk) {
    const chunk = rows.slice(i, i + perChunk);
    const params: unknown[] = [];
    const tuples = chunk.map((r) => `(${r.map((v) => (params.push(v), `$${params.length}`)).join(', ')})`);
    await q.query(`INSERT INTO ${table} (${cols}) VALUES ${tuples.join(', ')} ${conflict}`, params);
  }
}
