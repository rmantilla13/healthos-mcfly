// "Export your data": everything one person stored, as a JSON download built only from their own session
// (GET /api/me/export). There's no user id parameter and no admin variant: it's always the signed-in person's.
//
// Every column is listed by name (never SELECT *), so what leaves is what's written here: no password or token
// hashes, session versions, WHOOP tokens, invites, key ciphertext, file or photo bytes, or settings internals
// (sync state, the data version, OAuth state). Demo rows are left out, and so are the nutrition amounts the person's
// Nutrition setting hides. USER_TABLES (server/db.ts) is the list of one person's tables: test/export.test.ts checks
// every one is either exported here or excluded on purpose.
//
// Hourly readings over years run to tens of MB, over Vercel's limit for a response sent in one piece, so the file is
// streamed: each section (and the biggest, a year at a time) is read in full and then written.
import { once } from 'node:events';
import express, { type NextFunction, type Request, type Response } from 'express';
import type { FoodValues, NutritionNumbers } from '../shared/types.ts';
import { currentUser } from './auth.ts';
import { type Db, type Scope, type USER_TABLES, getUserSettings, setUserSetting } from './db.ts';
import { shownValues } from './foodlog.ts';
import { readSettings, requestContext } from './query.ts';

type UserTable = (typeof USER_TABLES)[number];
type Row = Record<string, unknown>;

/** One list of rows from one table, as SELECT cols FROM table WHERE user_id = $1 AND where ORDER BY order. */
type RowList = {
  table: UserTable;
  cols: string;
  where?: string;
  order: string;
  /** Read a year of `date` at a time (the big tables). */
  byYear?: boolean;
  map?: (row: Row) => Row;
};

const NOT_DEMO = "source <> 'demo'";

/** The Nutrition setting hides some amounts: the file leaves them out too, as every other nutrition response does. */
const hides = (numbers: NutritionNumbers | null): numbers is 'no_energy' | 'none' => numbers === 'no_energy' || numbers === 'none';

/**
 * food_log.per is one portion's amounts as JSON text: exported as the object it is, as stored, or with only the amounts the
 * person sees (shownValues, as the food log shows them). Name, portion, time and quantity stay either way.
 */
const perOf =
  (numbers: NutritionNumbers | null) =>
  (row: Row): Row => {
    let per: unknown;
    try {
      per = JSON.parse(String(row.per));
    } catch {
      return hides(numbers) ? { ...row, per: {} } : row;
    }
    if (!hides(numbers)) return { ...row, per };
    const values: FoodValues = {};
    if (typeof per === 'object' && per !== null) {
      for (const [k, v] of Object.entries(per)) if (typeof v === 'number' && Number.isFinite(v)) values[k as keyof FoodValues] = v;
    }
    return { ...row, per: shownValues(values, numbers) };
  };

/**
 * Saved food entries and the food apps' daily totals. nutrition_daily holds nutrients only (water from Health is a reading,
 * in readings.daily), so every row is an amount: none for 'none', and no calories for 'no_energy'.
 */
const nutritionLists = (numbers: NutritionNumbers | null): Record<string, RowList> => ({
  // Saved entries only: a draft is McFly's estimate the person never saved, deleted after a day.
  log: {
    table: 'food_log',
    cols: 'id, date, time, name, portion, quantity, per, method, ref, origin, created_at AS "createdAt", updated_at AS "updatedAt"',
    where: 'NOT draft',
    order: 'date, time, id',
    map: perOf(numbers),
  },
  daily: {
    table: 'nutrition_daily',
    cols: 'date, nutrient, source, app, value',
    where: numbers === 'none' ? 'false' : numbers === 'no_energy' ? `${NOT_DEMO} AND nutrient <> 'energy_kcal'` : NOT_DEMO,
    order: 'date, nutrient, source, app',
  },
});

/** The file's lists, in the order they're written. Nested objects are written as objects of lists. */
const LISTS: Record<string, RowList | Record<string, RowList>> = {
  readings: {
    daily: { table: 'daily', cols: 'date, metric, source, value', where: NOT_DEMO, order: 'date, metric, source', byYear: true },
    hourly: { table: 'hourly', cols: 'date, hour, metric, source, value', where: NOT_DEMO, order: 'date, hour, metric, source', byYear: true },
    // WHOOP counts steps per cycle (sleep to sleep); readings.daily has the day totals made from them.
    whoopCycleSteps: { table: 'whoop_cycle_steps', cols: 'cycle_id::float8 AS "cycleId", start_ms::float8 AS "startMs", date, steps', order: 'start_ms' },
  },
  sleep: {
    events: { table: 'events', cols: 'id, source, kind, title, start, "end", date', where: NOT_DEMO, order: 'start, id' },
    stages: { table: 'sleep_stages', cols: 'date, source, start, "end", stage', where: NOT_DEMO, order: 'date, start, source', byYear: true },
  },
  workouts: {
    table: 'workouts',
    cols: 'id, source, sport, start, "end", date, duration_min AS "durationMin", energy_kcal AS "energyKcal", distance_m AS "distanceM", avg_hr AS "avgHr", max_hr AS "maxHr", strain, effort',
    where: NOT_DEMO,
    order: 'start, id',
  },
  // Replaced per export by the person's own setting (listsFor).
  nutrition: nutritionLists(null),
  cycle: { table: 'cycle', cols: 'date, kind, source, value', where: NOT_DEMO, order: 'date, kind, source' },
  labs: {
    table: 'lab_results',
    cols: `id, collected, biomarker, name, value, value_text AS "valueText", unit, ref_low AS "refLow", ref_high AS "refHigh", ref_text AS "refText",
      lab, panel, source, created_at AS "createdAt"`,
    where: NOT_DEMO,
    order: 'collected, biomarker, id',
  },
  journal: {
    table: 'journal_entries',
    cols: 'id, date, time, mood, text, origin, created_at AS "createdAt", updated_at AS "updatedAt"',
    order: 'date, time, id',
  },
  body: {
    table: 'body_entries',
    cols: 'id, date, time, metric, value, method, note, origin, created_at AS "createdAt", updated_at AS "updatedAt"',
    order: 'date, time, id',
  },
  // What each file is, never the file: lab reports, portrait photos and the profile photo's cut-out and avatar.
  files: {
    labDocuments: { table: 'lab_documents', cols: 'id, name, mime, size, created_at AS "uploadedAt", read_at AS "readAt"', order: 'created_at, id' },
    portraits: { table: 'portraits', cols: 'id, kind, status, mime, bytes AS size, width, height, created_at AS "createdAt"', order: 'created_at, id' },
    profilePhoto: { table: 'profile_assets', cols: 'name, mime, octet_length(data) AS size, updated_at AS "updatedAt"', order: 'name' },
  },
  // Which providers have a key of the person's own, by its last 4 characters: never the key.
  ai: { table: 'ai_keys', cols: 'provider, last4', order: 'provider' },
  usage: {
    table: 'mcfly_usage',
    cols: `day, questions, input_tokens::float8 AS "inputTokens", output_tokens::float8 AS "outputTokens", own_questions AS "ownQuestions",
      own_input_tokens::float8 AS "ownInputTokens", own_output_tokens::float8 AS "ownOutputTokens", voice_notes AS "voiceNotes"`,
    order: 'day',
  },
};

/** The lists for one person's export: the same, in the same order, with nutrition as much as their setting shows. */
const listsFor = (numbers: NutritionNumbers | null): typeof LISTS => ({ ...LISTS, nutrition: nutritionLists(numbers) });

const isList = (x: RowList | Record<string, RowList>): x is RowList => typeof (x as RowList).table === 'string';
const allLists = Object.values(LISTS).flatMap((x) => (isList(x) ? [x] : Object.values(x)));

/** The tables the file is built from: the lists above, plus user_settings (settings and sources, each field by name). */
export const EXPORTED_TABLES: UserTable[] = [...new Set<UserTable>([...allLists.map((l) => l.table), 'user_settings'])];

/** One person's tables that are left out on purpose, and why. */
export const EXCLUDED_TABLES: Partial<Record<UserTable, string>> = {
  tokens: "WHOOP's access and refresh tokens: a key to the account, not health data.",
};

/** One export per person per minute: a second click or a script can't make the server build it again and again. */
const EXPORT_EVERY_MS = 60_000;

/**
 * Claims this person's export slot, or says when it's free. Kept in the database (an atomic upsert) so the limit holds
 * across serverless instances and two requests at once can't both get it.
 */
async function claimSlot(db: Db, userId: string): Promise<number | null> {
  const now = Date.now();
  const claimed = await db.query(
    `INSERT INTO user_settings (user_id, key, value) VALUES ($1, 'export_last', $2)
     ON CONFLICT (user_id, key) DO UPDATE SET value = excluded.value WHERE user_settings.value::float8 <= $3 RETURNING 1`,
    [userId, String(now), now - EXPORT_EVERY_MS],
  );
  if (claimed.length) return null;
  const mine = await getUserSettings(db, userId);
  return Number(mine.get('export_last')) + EXPORT_EVERY_MS;
}

const json = (raw: string | undefined) => {
  try {
    return raw ? JSON.parse(raw) : null;
  } catch {
    return null;
  }
};

/** The header of the file: who, their settings and their sources. Read before anything is sent. */
async function head(scope: Scope, res: Response, hosted: boolean) {
  const { db, userId } = scope;
  const user = currentUser(res);
  const [settings, mine, [account], [whoop], [token]] = await Promise.all([
    readSettings(scope, hosted),
    getUserSettings(db, userId),
    db.query<Row>('SELECT email, name, role, created_at AS "createdAt", last_login_at AS "lastLoginAt" FROM users WHERE id = $1', [userId]),
    db.query<{ connected: boolean }>("SELECT EXISTS (SELECT 1 FROM tokens WHERE user_id = $1 AND provider = 'whoop') AS connected", [userId]),
    db.query<{ has: boolean }>('SELECT ingest_token_hash IS NOT NULL AS has FROM users WHERE id = $1', [userId]),
  ]);
  return {
    // Without sign-in (local) there's no account row: the person is this Mac's owner.
    account: account ?? { email: user.email, name: settings.name, role: user.role, createdAt: null, lastLoginAt: null },
    settings,
    sources: {
      whoop: { connected: Boolean(whoop?.connected), lastSync: mine.get('whoop_last_sync') ?? null },
      apple: { lastImport: json(mine.get('apple_last_import')), lastSync: json(mine.get('apple_last_sync')), iphoneToken: Boolean(token?.has) },
      fitbit: { lastImport: json(mine.get('fitbit_last_import')) },
    },
  };
}

/** A list's rows, a page at a time: the whole list, or a year of it for the big tables. */
async function* pages(scope: Scope, list: RowList): AsyncGenerator<Row[]> {
  const where = list.where ? `AND ${list.where}` : '';
  const select = (extra: string) => `SELECT ${list.cols} FROM ${list.table} WHERE user_id = $1 ${where} ${extra} ORDER BY ${list.order}`;
  if (!list.byYear) {
    yield await scope.db.query<Row>(select(''), [scope.userId]);
    return;
  }
  const [span] = await scope.db.query<{ lo: string | null; hi: string | null }>(`SELECT MIN(date) AS lo, MAX(date) AS hi FROM ${list.table} WHERE user_id = $1 ${where}`, [
    scope.userId,
  ]);
  if (!span?.lo || !span.hi) return;
  for (let year = Number(span.lo.slice(0, 4)); year <= Number(span.hi.slice(0, 4)); year++) {
    yield await scope.db.query<Row>(select('AND date >= $2 AND date < $3'), [scope.userId, `${year}-01-01`, `${year + 1}-01-01`]);
  }
}

/**
 * Writes to the response, waiting when it's full; stops if the person went away. A connection that closes while full
 * never drains, so the wait ends on either (and drops its listeners, or a long export would pile them up).
 */
function writer(res: Response) {
  return async (text: string) => {
    if (res.destroyed) throw new Error('The download was cancelled.');
    if (res.write(text)) return;
    const stop = new AbortController();
    try {
      await Promise.race([once(res, 'drain', { signal: stop.signal }), once(res, 'close', { signal: stop.signal })]);
    } finally {
      stop.abort();
    }
    if (res.destroyed) throw new Error('The download was cancelled.');
  };
}

async function writeList(write: (t: string) => Promise<void>, scope: Scope, list: RowList) {
  await write('[');
  let first = true;
  for await (const rows of pages(scope, list)) {
    if (!rows.length) continue;
    await write((first ? '' : ',') + rows.map((r) => JSON.stringify(list.map ? list.map(r) : r)).join(','));
    first = false;
  }
  await write(']');
}

export function exportRouter(db: Db, hosted: boolean) {
  const router = express.Router();

  router.get('/', async (_req, res) => {
    const userId = currentUser(res).id;
    const scope = { db, userId };
    const retryAt = await claimSlot(db, userId);
    if (retryAt !== null) {
      res.setHeader('Retry-After', String(Math.max(1, Math.ceil((retryAt - Date.now()) / 1000))));
      return void res.status(429).json({ error: 'Your export was just prepared. Try again in a minute.' });
    }
    try {
      const [{ today }, top] = await Promise.all([requestContext(scope, hosted), head(scope, res, hosted)]);
      res.setHeader('Content-Type', 'application/json; charset=utf-8');
      res.setHeader('Content-Disposition', `attachment; filename="healthos-export-${today}.json"`);
      const write = writer(res);
      const intro = {
        format: 'healthos-export',
        version: 1,
        exportedAt: new Date().toISOString(),
        notes: [
          'Personal health records. Not a diagnosis.',
          'Files are listed by name, type, size and date; the files themselves are not included. Keys, passwords and connection tokens are never exported.',
        ],
        ...top,
      };
      await write(JSON.stringify(intro).slice(0, -1));
      for (const [key, part] of Object.entries(listsFor(top.settings.nutritionNumbers))) {
        await write(`,${JSON.stringify(key)}:`);
        if (isList(part)) await writeList(write, scope, part);
        else {
          let first = true;
          for (const [name, list] of Object.entries(part)) {
            await write(`${first ? '{' : ','}${JSON.stringify(name)}:`);
            await writeList(write, scope, list);
            first = false;
          }
          await write('}');
        }
      }
      res.end('}');
    } catch (err) {
      // A failed export doesn't use up the minute.
      await setUserSetting(db, userId, 'export_last', null).catch(() => {});
      // Part of the file is already on its way: break the connection, so it fails as a download instead of ending
      // as a short file that looks complete.
      if (res.headersSent) {
        console.error('export:', (err as Error).name);
        return void res.destroy();
      }
      throw err;
    }
  });

  router.use((err: Error, _req: Request, res: Response, _next: NextFunction) => {
    // The kind of failure only: a database error's text can quote the values it was given.
    console.error('export:', err.name);
    res.status(500).json({ error: "Couldn't prepare your export. Try again in a moment." });
  });

  return router;
}
