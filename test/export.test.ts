// "Export your data" (GET /api/me/export): one person's records as a JSON download, from their own session only,
// with every one of their tables either exported or left out on purpose, and no secret ever in the file.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { AddressInfo } from 'node:net';
import { createApp } from '../server/app.ts';
import { hashPassword } from '../server/auth.ts';
import { OWNER_ID, USER_TABLES, setUserSetting } from '../server/db.ts';
import { EXCLUDED_TABLES, EXPORTED_TABLES } from '../server/export.ts';
import { openStore } from '../server/store.ts';

process.env.SESSION_SECRET = 'export-test-secret-'.padEnd(64, 'x');
process.env.HEALTHOS_PASSWORD_HASH = await hashPassword('owner password 123');

const db = await openStore();
const server = createApp({ db, hosted: false }).listen(0, '127.0.0.1');
await new Promise((r) => server.once('listening', r));
const base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
test.after(() => {
  server.close();
});

let cookie = '';
async function call(method: string, path: string, body?: unknown) {
  const res = await fetch(base + path, {
    method,
    headers: { 'X-HealthOS': '1', 'Content-Type': 'application/json', ...(cookie ? { Cookie: cookie } : {}) },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const set = res.headers.get('set-cookie');
  if (set) cookie = set.split(';')[0];
  return { status: res.status, headers: res.headers, text: await res.text() };
}

// Secrets planted where they live, so a column added to the export by mistake shows up here.
const SECRETS = {
  whoopAccess: 'whoop-access-token-PLANTED-1',
  whoopRefresh: 'whoop-refresh-token-PLANTED-2',
  aiKey: 'sk-PLANTED-openai-key-3',
  oauthState: 'oauth-state-PLANTED-4',
  syncState: 'whoop-sync-PLANTED-5',
  documentBytes: 'PDF-BYTES-PLANTED-6',
  portraitBytes: 'PORTRAIT-BYTES-PLANTED-7',
  photoBytes: 'PHOTO-BYTES-PLANTED-8',
};
const bytes = (s: string) => Buffer.from(s);
let ingestToken = '';

test('every table holding one person’s rows is exported or left out on purpose', () => {
  const excluded = Object.keys(EXCLUDED_TABLES);
  assert.deepEqual([...new Set([...EXPORTED_TABLES, ...excluded])].sort(), [...USER_TABLES].sort());
  assert.equal(
    EXPORTED_TABLES.some((t) => excluded.includes(t)),
    false,
  );
});

test('setup: the owner, a row in every table, the secrets, and someone else', async () => {
  assert.equal((await call('POST', '/api/auth/login', { email: 'owner@example.com', password: 'owner password 123' })).status, 200);
  ingestToken = JSON.parse((await call('POST', '/api/me/ingest-token')).text).token;
  const o = OWNER_ID;
  const q = (sql: string, params: unknown[]) => db.query(sql, params);
  await q("INSERT INTO daily (user_id, date, metric, source, value) VALUES ($1, '2024-03-01', 'resting_hr', 'apple', 61), ($1, '2026-10-01', 'resting_hr', 'whoop', 57.25)", [o]);
  await q("INSERT INTO daily (user_id, date, metric, source, value) VALUES ($1, '2026-10-02', 'resting_hr', 'demo', 99.125)", [o]);
  await q("INSERT INTO hourly (user_id, metric, date, hour, source, value) VALUES ($1, 'steps', '2026-10-01', 9, 'apple', 812)", [o]);
  await q("INSERT INTO whoop_cycle_steps (user_id, cycle_id, start_ms, date, steps) VALUES ($1, 9001, 1790000000000, '2026-10-01', 4321)", [o]);
  await q(`INSERT INTO events (user_id, id, source, kind, title, start, "end", date) VALUES ($1, 'ev1', 'apple', 'sleep', 'Sleep', '2026-09-30T23:00:00-07:00', '2026-10-01T07:00:00-07:00', '2026-10-01')`, [o]);
  await q(`INSERT INTO sleep_stages (user_id, date, source, start, "end", stage) VALUES ($1, '2026-10-01', 'apple', '2026-10-01T01:00:00-07:00', '2026-10-01T02:00:00-07:00', 'deep')`, [o]);
  await q(
    `INSERT INTO workouts (user_id, id, source, sport, start, "end", date, duration_min, energy_kcal, distance_m, avg_hr, max_hr, strain)
     VALUES ($1, 'w1', 'apple', 'running', '2026-10-01T07:30:00-07:00', '2026-10-01T08:10:00-07:00', '2026-10-01', 40, 410, 7100, 151, 172, null)`,
    [o],
  );
  const per = JSON.stringify({ energy_kcal: 210, protein_g: 12 });
  await q(
    `INSERT INTO food_log (user_id, id, date, time, name, portion, quantity, per, method, origin, draft, created_at, updated_at)
     VALUES ($1, 'f1', '2026-10-01', '08:30', 'Porridge', '1 bowl', 1, $2, 'quick', 'web', false, 1, 1),
            ($1, 'f2', '2026-10-01', '12:30', 'Unsaved estimate', '', 1, $2, 'estimate', 'web', true, 1, 1)`,
    [o, per],
  );
  await q("INSERT INTO nutrition_daily (user_id, date, nutrient, source, app, value) VALUES ($1, '2026-10-01', 'energy_kcal', 'apple', 'Cronometer', 1980)", [o]);
  await q("INSERT INTO cycle (user_id, date, kind, source, value) VALUES ($1, '2026-10-01', 'flow', 'manual', 'light')", [o]);
  await q(
    `INSERT INTO lab_results (user_id, id, collected, biomarker, name, value, value_text, unit, ref_low, ref_high, source, created_at)
     VALUES ($1, 'l1', '2026-09-15', 'ldl', 'LDL cholesterol', 112, '112', 'mg/dL', 0, 130, 'manual', 1)`,
    [o],
  );
  await q("INSERT INTO journal_entries (user_id, id, date, time, mood, text, origin, created_at, updated_at) VALUES ($1, 'j1', '2026-10-01', '21:00', 4, 'Felt rested today.', 'web', 1, 1)", [o]);
  await q("INSERT INTO body_entries (user_id, id, date, time, metric, value, created_at, updated_at) VALUES ($1, 'b1', '2026-10-01', '07:00', 'weight', 72.4, 1, 1)", [o]);
  await q(
    "INSERT INTO lab_documents (user_id, id, name, mime, size, sha256, data, created_at) VALUES ($1, 'd1', 'report.pdf', 'application/pdf', 19, 'abc123sha', $2, 1)",
    [o, bytes(SECRETS.documentBytes)],
  );
  await q("INSERT INTO portraits (user_id, id, kind, status, mime, data, width, height, bytes, created_at) VALUES ($1, 'p1', 'reference', 'ready', 'image/jpeg', $2, 800, 1000, 24, 1)", [
    o,
    bytes(SECRETS.portraitBytes),
  ]);
  await q("INSERT INTO profile_assets (user_id, name, mime, data, updated_at) VALUES ($1, 'avatar.png', 'image/png', $2, 1)", [o, bytes(SECRETS.photoBytes)]);
  await q("INSERT INTO ai_keys (user_id, provider, ciphertext, iv, tag, last4, created_at, updated_at) VALUES ($1, 'openai', $2, $3, $4, 'ABCD', 1, 1)", [
    o,
    bytes(SECRETS.aiKey),
    bytes('iv-PLANTED'),
    bytes('tag-PLANTED'),
  ]);
  await q("INSERT INTO mcfly_usage (user_id, day, questions, input_tokens, output_tokens) VALUES ($1, '2026-10-01', 3, 12000, 900)", [o]);
  await q("INSERT INTO tokens (user_id, provider, access_token, refresh_token, expires_at, scope) VALUES ($1, 'whoop', $2, $3, 0, 'read:recovery')", [
    o,
    SECRETS.whoopAccess,
    SECRETS.whoopRefresh,
  ]);
  await setUserSetting(db, o, 'whoop_oauth_state', SECRETS.oauthState);
  await setUserSetting(db, o, 'whoop_sync', JSON.stringify({ running: false, lastError: SECRETS.syncState }));
  await setUserSetting(db, o, 'whoop_last_sync', '2026-10-01T08:00:00.000Z');
  // Someone else, whose rows must never appear.
  await q("INSERT INTO users (id, email, name, password_hash, role, created_at) VALUES ('bob', 'bob@example.com', 'Bob', 'x', 'user', 1)", []);
  await q("INSERT INTO daily (user_id, date, metric, source, value) VALUES ('bob', '2026-10-01', 'resting_hr', 'apple', 77.777)", []);
  await q("INSERT INTO journal_entries (user_id, id, date, time, text, origin, created_at, updated_at) VALUES ('bob', 'jb', '2026-10-01', '09:00', 'BOB-PRIVATE-NOTE', 'web', 1, 1)", []);
});

let file: any;
let text = '';

test('the download is the signed-in person’s, as an attachment, and the file parses', async () => {
  // A user id in the address is ignored: there's no way to ask for someone else's.
  const res = await call('GET', '/api/me/export?userId=bob');
  assert.equal(res.status, 200);
  assert.match(res.headers.get('content-disposition') ?? '', /^attachment; filename="healthos-export-\d{4}-\d{2}-\d{2}\.json"$/);
  assert.match(res.headers.get('content-type') ?? '', /^application\/json/);
  assert.equal(res.headers.get('cache-control'), 'private, no-store');
  text = res.text;
  file = JSON.parse(text);
  assert.equal(file.format, 'healthos-export');
  assert.equal(file.version, 1);
  assert.deepEqual(file.notes[0], 'Personal health records. Not a diagnosis.');
  assert.equal(file.account.email, 'owner@example.com');
  assert.equal(file.account.role, 'admin');
  assert.equal(file.settings.units, 'metric');
  assert.deepEqual(file.sources.whoop, { connected: true, lastSync: '2026-10-01T08:00:00.000Z' });
  assert.equal(file.sources.apple.iphoneToken, true);
});

test('a row from every exported table is there, demo rows and drafts are not', () => {
  assert.deepEqual(
    file.readings.daily.map((r: any) => [r.date, r.source, r.value]),
    [
      ['2024-03-01', 'apple', 61],
      ['2026-10-01', 'whoop', 57.25],
    ],
    'a year at a time, every year, no demo',
  );
  assert.deepEqual(file.readings.hourly, [{ date: '2026-10-01', hour: 9, metric: 'steps', source: 'apple', value: 812 }]);
  assert.deepEqual(file.readings.whoopCycleSteps, [{ cycleId: 9001, startMs: 1790000000000, date: '2026-10-01', steps: 4321 }]);
  assert.equal(file.sleep.events[0].id, 'ev1');
  assert.equal(file.sleep.stages[0].stage, 'deep');
  assert.equal(file.workouts[0].durationMin, 40);
  assert.deepEqual(
    file.nutrition.log.map((e: any) => e.name),
    ['Porridge'],
  );
  assert.deepEqual(file.nutrition.log[0].per, { energy_kcal: 210, protein_g: 12 });
  assert.equal(file.nutrition.daily[0].app, 'Cronometer');
  assert.equal(file.cycle[0].value, 'light');
  assert.equal(file.labs[0].refHigh, 130);
  assert.equal(file.journal[0].text, 'Felt rested today.');
  assert.equal(file.body[0].value, 72.4);
  assert.deepEqual(file.files.labDocuments, [{ id: 'd1', name: 'report.pdf', mime: 'application/pdf', size: 19, uploadedAt: 1, readAt: null }]);
  assert.deepEqual(file.files.portraits, [{ id: 'p1', kind: 'reference', status: 'ready', mime: 'image/jpeg', size: 24, width: 800, height: 1000, createdAt: 1 }]);
  assert.deepEqual(file.files.profilePhoto, [{ name: 'avatar.png', mime: 'image/png', size: SECRETS.photoBytes.length, updatedAt: 1 }]);
  assert.deepEqual(file.ai, [{ provider: 'openai', last4: 'ABCD' }]);
  assert.equal(file.usage[0].questions, 3);
  assert.equal(file.usage[0].inputTokens, 12000);
});

test('no secret, file bytes or anyone else’s data is in the file', async () => {
  for (const [what, secret] of Object.entries(SECRETS)) {
    assert.ok(!text.includes(secret), what);
    assert.ok(!text.includes(Buffer.from(secret).toString('hex')), `${what} (hex)`);
    assert.ok(!text.includes(Buffer.from(secret).toString('base64')), `${what} (base64)`);
  }
  const [user] = await db.query<{ password_hash: string; ingest_token_hash: string }>('SELECT password_hash, ingest_token_hash FROM users WHERE id = $1', [OWNER_ID]);
  assert.ok(!text.includes(user.password_hash) && !text.includes('scrypt$'), 'password hash');
  assert.ok(!text.includes(user.ingest_token_hash) && !text.includes(ingestToken), 'iPhone token');
  for (const word of ['access_token', 'refresh_token', 'password_hash', 'passwordHash', 'session_version', 'ciphertext', 'whoop_oauth_state', 'data_version', 'abc123sha']) {
    assert.ok(!text.includes(word), word);
  }
  assert.ok(!text.includes('77.777') && !text.includes('BOB-PRIVATE-NOTE') && !text.includes('bob@example.com'), 'another person');
  assert.ok(!text.includes('99.125'), 'demo rows');
});

test('one export a minute', async () => {
  const again = await call('GET', '/api/me/export');
  assert.equal(again.status, 429);
  assert.ok(Number(again.headers.get('retry-after')) > 0);
  await setUserSetting(db, OWNER_ID, 'export_last', String(Date.now() - 61_000));
  assert.equal((await call('GET', '/api/me/export')).status, 200);
});

test('it needs a signed-in person', async () => {
  cookie = '';
  assert.equal((await call('GET', '/api/me/export')).status, 401);
});
