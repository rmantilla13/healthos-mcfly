// Writes need the X-HealthOS header, which a form on another website can't send, whatever the case of the path: Express
// routes /API/... and /Api/... to the same handlers as /api/..., so a check on '/api/' alone let a cross-site form through.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { AddressInfo } from 'node:net';
import { createApp } from '../server/app.ts';
import { hashPassword } from '../server/auth.ts';
import { OWNER_ID } from '../server/db.ts';
import { openStore } from '../server/store.ts';

process.env.SESSION_SECRET = 'write-header-test-secret-'.padEnd(64, 'x');
const OWNER_PASSWORD = 'owner password 123';
process.env.HEALTHOS_PASSWORD_HASH = await hashPassword(OWNER_PASSWORD);

const db = await openStore();
const server = createApp({ db, hosted: false, mcflyClient: () => null }).listen(0, '127.0.0.1');
await new Promise((r) => server.once('listening', r));
const base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
test.after(() => {
  server.close();
});

// The same signed-in cookie throughout, so only the header differs between a refused request and an accepted one.
let cookie = '';
async function post(path: string, header: boolean) {
  const res = await fetch(base + path, { method: 'POST', headers: { ...(header ? { 'X-HealthOS': '1' } : {}), ...(cookie ? { Cookie: cookie } : {}) } });
  const set = res.headers.get('set-cookie');
  if (set) cookie = set.split(';')[0];
  return { status: res.status, json: (await res.json().catch(() => null)) as any };
}
const checkIns = async () => Number((await db.query<{ n: number }>('SELECT count(*)::integer AS n FROM journal_entries WHERE user_id = $1', [OWNER_ID]))[0].n);
const addCheckIn = () =>
  db.query("INSERT INTO journal_entries (user_id, id, date, time, mood, text, origin, created_at, updated_at) VALUES ($1, $2, '2026-10-01', '21:00', 3, 'Fine.', 'web', 1, 1)", [
    OWNER_ID,
    `j-${Math.random()}`,
  ]);

test('setup: signed in', async () => {
  const res = await fetch(`${base}/api/auth/login`, {
    method: 'POST',
    headers: { 'X-HealthOS': '1', 'Content-Type': 'application/json' },
    body: JSON.stringify({ email: 'owner@example.com', password: OWNER_PASSWORD }),
  });
  assert.equal(res.status, 200);
  cookie = (res.headers.get('set-cookie') ?? '').split(';')[0];
  assert.ok(cookie);
});

test('a write without the header is refused, in any case of /api', async () => {
  await addCheckIn();
  for (const path of ['/api/journal/delete', '/API/journal/delete', '/Api/Journal/Delete', '/aPI/journal/delete', '/API/fitbit/clear', '/Api/Fitbit/Clear']) {
    const res = await post(path, false);
    assert.deepEqual([res.status, res.json], [403, { error: 'Missing X-HealthOS header' }], path);
  }
  assert.equal(await checkIns(), 1, 'nothing was deleted');
});

test('with the header, the same requests work as usual', async () => {
  assert.deepEqual(await post('/API/journal/delete', true), { status: 200, json: { deleted: 1 } });
  assert.equal(await checkIns(), 0);
  await addCheckIn();
  assert.deepEqual(await post('/api/journal/delete', true), { status: 200, json: { deleted: 1 } });
  assert.deepEqual(await post('/Api/Fitbit/Clear', true), { status: 200, json: { ok: true } });
  assert.deepEqual(await post('/api/fitbit/clear', true), { status: 200, json: { ok: true } });
});

test('reads need no header, and paths that only start like /api are not checked', async () => {
  assert.equal((await fetch(`${base}/API/journal`, { headers: { Cookie: cookie } })).status, 200);
  // Not the API: the check is for /api and what's under it, not for every path that begins with those letters.
  assert.notEqual((await post('/apiary', false)).status, 403);
});
