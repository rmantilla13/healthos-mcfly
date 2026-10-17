// POST /api/sync: the one sync the web and the iPhone app call. These cases never reach WHOOP's API.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { AddressInfo } from 'node:net';
import { createApp } from '../server/app.ts';
import { hashPassword } from '../server/auth.ts';
import { OWNER_ID, setUserSetting } from '../server/db.ts';
import { openStore } from '../server/store.ts';

process.env.SESSION_SECRET = 'sync-test-secret-'.padEnd(64, 'x');
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
  return { status: res.status, json: (await res.json().catch(() => null)) as any };
}

test('sync needs a signed-in person', async () => {
  assert.equal((await call('POST', '/api/sync', {})).status, 401);
  assert.equal((await call('POST', '/api/auth/login', { email: 'owner@example.com', password: 'owner password 123' })).status, 200);
});

test('without WHOOP connected, sync answers with the status and starts nothing', async () => {
  const r = await call('POST', '/api/sync', {});
  assert.equal(r.status, 200);
  assert.equal(r.json.whoopStarted, false);
  assert.equal(r.json.whoop.connected, false);
  assert.ok('apple' in r.json && 'settings' in r.json, 'the same shape as /api/status');
});

test("a sync that's running, or finished moments ago, isn't started again", async () => {
  await db.query("INSERT INTO tokens (user_id, provider, access_token, refresh_token, expires_at, scope) VALUES ($1, 'whoop', 'a', 'r', 0, '')", [OWNER_ID]);

  await setUserSetting(db, OWNER_ID, 'whoop_sync', JSON.stringify({ running: true, startedAt: new Date().toISOString() }));
  let r = await call('POST', '/api/sync', {});
  assert.deepEqual([r.json.whoop.connected, r.json.whoop.syncing, r.json.whoopStarted], [true, true, false]);

  await setUserSetting(db, OWNER_ID, 'whoop_sync', JSON.stringify({ running: false, lastSync: new Date().toISOString() }));
  r = await call('POST', '/api/sync', {});
  assert.deepEqual([r.json.whoop.syncing, r.json.whoopStarted], [false, false]);
});
