// One-time move from the original local SQLite file (data/healthos.db) into the current database:
// PGlite under data/pglite, or the hosted Neon database when DATABASE_URL is set.
// Copies settings, WHOOP tokens, daily values, workouts and events (demo rows excluded), then the photo.
//   npm run migrate:sqlite
import fs from 'node:fs';
import path from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { DATA_DIR, getStore } from '../db.ts';
import { PHOTO_DIR, storePhoto } from '../photo.ts';
import { insertMany } from '../store.ts';

const file = path.join(DATA_DIR, 'healthos.db');
if (!fs.existsSync(file)) {
  console.error(`Nothing to migrate: ${file} doesn't exist.`);
  process.exit(1);
}
const old = new DatabaseSync(file, { readOnly: true });
const db = await getStore();
console.log(`Copying ${file} into the ${db.kind === 'neon' ? 'hosted (Neon)' : 'local (PGlite)'} database…`);

const tables: { name: string; cols: string[]; key: string; where?: string }[] = [
  { name: 'settings', cols: ['key', 'value'], key: 'key' },
  { name: 'tokens', cols: ['provider', 'access_token', 'refresh_token', 'expires_at', 'scope'], key: 'provider' },
  { name: 'daily', cols: ['date', 'metric', 'source', 'value'], key: 'date, metric, source', where: "source <> 'demo'" },
  {
    name: 'workouts',
    cols: ['id', 'source', 'sport', 'start', 'end', 'date', 'duration_min', 'energy_kcal', 'distance_m', 'avg_hr', 'max_hr', 'strain'],
    key: 'id',
    where: "source <> 'demo'",
  },
  { name: 'events', cols: ['id', 'source', 'kind', 'title', 'start', 'end', 'date'], key: 'id', where: "source <> 'demo'" },
];

await db.tx(async (q) => {
  for (const t of tables) {
    const rows = old.prepare(`SELECT ${t.cols.map((c) => `"${c}"`).join(', ')} FROM ${t.name}${t.where ? ` WHERE ${t.where}` : ''}`).all() as Record<string, unknown>[];
    const update = t.cols.filter((c) => !t.key.split(', ').includes(c)).map((c) => `"${c}" = excluded."${c}"`).join(', ');
    await insertMany(q, t.name, t.cols, rows.map((r) => t.cols.map((c) => r[c])), `ON CONFLICT (${t.key}) DO ${update ? `UPDATE SET ${update}` : 'NOTHING'}`);
    console.log(`  ${t.name}: ${rows.length.toLocaleString()} rows`);
  }
});
if (fs.existsSync(path.join(PHOTO_DIR, 'meta.json'))) {
  await storePhoto(db);
  console.log('  profile photo: stored');
}
await db.close();
console.log('Done.');
