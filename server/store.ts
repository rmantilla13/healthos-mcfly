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

/** The account that owned all data before healthOS became multi-user; its users row is made at first sign-in. */
export const OWNER_ID = 'owner';

/** Settings that belong to one person (moved out of the platform-wide settings table in migration 2). */
export const USER_SETTING_KEYS = [
  'name',
  'step_goal',
  'units',
  'demo',
  'timezone',
  'photo_meta',
  'apple_last_import',
  'apple_last_sync',
  'whoop_last_sync',
  'whoop_first_name',
  'whoop_max_hr',
  'whoop_sync',
  'whoop_oauth_state',
  'whoop_backfill_before',
];

/**
 * Numbered schema steps, applied once each, in order, inside one transaction holding an advisory lock
 * (two cold starts can't race). Each step is a list of single statements (one per query).
 */
export const MIGRATIONS: { id: number; name: string; statements: string[] }[] = [
  {
    id: 1,
    name: 'single-user tables',
    statements: [
      `CREATE TABLE IF NOT EXISTS daily (
        date TEXT NOT NULL, metric TEXT NOT NULL, source TEXT NOT NULL, value DOUBLE PRECISION NOT NULL,
        PRIMARY KEY (date, metric, source))`,
      'CREATE INDEX IF NOT EXISTS daily_metric ON daily (metric, source, date)',
      `CREATE TABLE IF NOT EXISTS workouts (
        id TEXT PRIMARY KEY, source TEXT NOT NULL, sport TEXT NOT NULL, start TEXT NOT NULL, "end" TEXT NOT NULL,
        date TEXT NOT NULL, duration_min DOUBLE PRECISION NOT NULL, energy_kcal DOUBLE PRECISION, distance_m DOUBLE PRECISION,
        avg_hr DOUBLE PRECISION, max_hr DOUBLE PRECISION, strain DOUBLE PRECISION)`,
      'CREATE INDEX IF NOT EXISTS workouts_date ON workouts (date)',
      `CREATE TABLE IF NOT EXISTS events (
        id TEXT PRIMARY KEY, source TEXT NOT NULL, kind TEXT NOT NULL, title TEXT NOT NULL,
        start TEXT NOT NULL, "end" TEXT NOT NULL, date TEXT NOT NULL)`,
      'CREATE INDEX IF NOT EXISTS events_date ON events (date)',
      'CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
      `CREATE TABLE IF NOT EXISTS tokens (
        provider TEXT PRIMARY KEY, access_token TEXT NOT NULL, refresh_token TEXT,
        expires_at DOUBLE PRECISION NOT NULL, scope TEXT)`,
      `CREATE TABLE IF NOT EXISTS profile_assets (
        name TEXT PRIMARY KEY, mime TEXT NOT NULL, data BYTEA NOT NULL, updated_at DOUBLE PRECISION NOT NULL)`,
    ],
  },
  {
    id: 2,
    name: 'multi-user: accounts, invites, per-user data',
    statements: [
      `CREATE TABLE users (
        id TEXT PRIMARY KEY,
        email TEXT NOT NULL UNIQUE,
        name TEXT NOT NULL DEFAULT '',
        password_hash TEXT NOT NULL,
        role TEXT NOT NULL CHECK (role IN ('admin', 'user')),
        status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'disabled')),
        session_version INTEGER NOT NULL DEFAULT 1,
        ingest_token_hash TEXT UNIQUE,
        created_at DOUBLE PRECISION NOT NULL,
        last_login_at DOUBLE PRECISION)`,
      `CREATE TABLE invites (
        id TEXT PRIMARY KEY,
        kind TEXT NOT NULL CHECK (kind IN ('invite', 'reset')),
        token_hash TEXT NOT NULL UNIQUE,
        email TEXT,
        role TEXT NOT NULL DEFAULT 'user' CHECK (role IN ('admin', 'user')),
        user_id TEXT,
        created_by TEXT NOT NULL,
        created_at DOUBLE PRECISION NOT NULL,
        expires_at DOUBLE PRECISION NOT NULL,
        used_at DOUBLE PRECISION,
        used_by TEXT,
        revoked_at DOUBLE PRECISION)`,
      'CREATE TABLE user_settings (user_id TEXT NOT NULL, key TEXT NOT NULL, value TEXT NOT NULL, PRIMARY KEY (user_id, key))',
      // Every existing row belongs to the original owner. No default afterwards: a write that forgets
      // whose data it is must fail, not land in someone else's account.
      ...(
        [
          ['daily', 'user_id, date, metric, source'],
          ['workouts', 'user_id, id'],
          ['events', 'user_id, id'],
          ['tokens', 'user_id, provider'],
          ['profile_assets', 'user_id, name'],
        ] as const
      ).flatMap(([table, key]) => [
        `ALTER TABLE ${table} ADD COLUMN user_id TEXT`,
        `UPDATE ${table} SET user_id = '${OWNER_ID}'`,
        `ALTER TABLE ${table} ALTER COLUMN user_id SET NOT NULL`,
        `ALTER TABLE ${table} DROP CONSTRAINT ${table}_pkey`,
        `ALTER TABLE ${table} ADD PRIMARY KEY (${key})`,
      ]),
      'DROP INDEX IF EXISTS daily_metric',
      'CREATE INDEX daily_user_metric ON daily (user_id, metric, date)',
      'DROP INDEX IF EXISTS workouts_date',
      'CREATE INDEX workouts_user_date ON workouts (user_id, date)',
      'DROP INDEX IF EXISTS events_date',
      'CREATE INDEX events_user_date ON events (user_id, date)',
      `INSERT INTO user_settings (user_id, key, value)
        SELECT '${OWNER_ID}', key, value FROM settings WHERE key IN (${USER_SETTING_KEYS.map((k) => `'${k}'`).join(', ')})`,
      `DELETE FROM settings WHERE key IN (${USER_SETTING_KEYS.map((k) => `'${k}'`).join(', ')})`,
    ],
  },
  {
    id: 3,
    name: 'Ask McFly: questions and tokens per person per day',
    statements: [
      `CREATE TABLE mcfly_usage (
        user_id TEXT NOT NULL, day TEXT NOT NULL, questions INTEGER NOT NULL DEFAULT 0,
        input_tokens BIGINT NOT NULL DEFAULT 0, output_tokens BIGINT NOT NULL DEFAULT 0,
        PRIMARY KEY (user_id, day))`,
    ],
  },
  {
    id: 4,
    name: 'Day view: hourly values per person',
    statements: [
      // One value per local hour: a sum (steps, active_energy) or a reading (hr_avg, hr_min, hr_max).
      // Keyed metric-first so a person's run of days for one metric is one index range.
      `CREATE TABLE hourly (
        user_id TEXT NOT NULL, metric TEXT NOT NULL, date TEXT NOT NULL,
        hour SMALLINT NOT NULL CHECK (hour BETWEEN 0 AND 23), source TEXT NOT NULL, value DOUBLE PRECISION NOT NULL,
        PRIMARY KEY (user_id, metric, date, hour, source))`,
    ],
  },
  {
    id: 5,
    name: 'Cycle tracking: per-person cycle log',
    statements: [
      // Reproductive-health entries, kept apart from `daily` so nothing that reads daily (summaries, the
      // admin view, McFly's metric list) can reach them. One value per day, kind and source ('apple' or
      // 'manual'); see server/cycle.ts for the kinds and their values.
      `CREATE TABLE cycle (
        user_id TEXT NOT NULL, date TEXT NOT NULL, kind TEXT NOT NULL, source TEXT NOT NULL, value TEXT NOT NULL,
        PRIMARY KEY (user_id, date, kind, source))`,
    ],
  },
];

async function migrate(db: Db) {
  await db.exec('CREATE TABLE IF NOT EXISTS schema_migrations (id INTEGER PRIMARY KEY, name TEXT NOT NULL, applied_at DOUBLE PRECISION NOT NULL)');
  await db.tx(async (q) => {
    await q.query("SELECT pg_advisory_xact_lock(hashtext('healthos-migrations'))");
    const done = new Set((await q.query<{ id: number }>('SELECT id FROM schema_migrations')).map((r) => Number(r.id)));
    for (const m of MIGRATIONS) {
      if (done.has(m.id)) continue;
      for (const statement of m.statements) await q.query(statement);
      await q.query('INSERT INTO schema_migrations (id, name, applied_at) VALUES ($1, $2, $3)', [m.id, m.name, Date.now()]);
    }
  });
}

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
  await migrate(db);
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
