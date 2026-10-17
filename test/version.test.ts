// GET /api/version: the cheap "has anything changed?" check clients poll instead of re-downloading data.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { AddressInfo } from 'node:net';
import { createApp } from '../server/app.ts';
import { hashPassword } from '../server/auth.ts';
import { openStore } from '../server/store.ts';

process.env.SESSION_SECRET = 'version-test-secret-'.padEnd(64, 'x');
process.env.HEALTHOS_PASSWORD_HASH = await hashPassword('owner password 123');
const INGEST = 'version-test-ingest-token-0123456789';

const db = await openStore();
const server = createApp({ db, hosted: false, ingestToken: INGEST }).listen(0, '127.0.0.1');
await new Promise((r) => server.once('listening', r));
const base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
test.after(() => {
  server.close();
});

let cookie = '';
async function call(method: string, path: string, body?: unknown, auth?: string) {
  const res = await fetch(base + path, {
    method,
    headers: {
      'X-HealthOS': '1',
      'Content-Type': 'application/json',
      ...(cookie ? { Cookie: cookie } : {}),
      ...(auth ? { Authorization: `Bearer ${auth}` } : {}),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const set = res.headers.get('set-cookie');
  if (set) cookie = set.split(';')[0];
  return { status: res.status, json: (await res.json().catch(() => null)) as any };
}
const version = async () => (await call('GET', '/api/version')).json.version as string | null;

test('the version needs a signed-in person', async () => {
  assert.equal((await call('GET', '/api/version')).status, 401);
  assert.equal((await call('POST', '/api/auth/login', { email: 'owner@example.com', password: 'owner password 123' })).status, 200);
  assert.equal(await version(), null, 'nothing has changed yet');
});

test('an iPhone push that writes data moves the version; an empty one does not', async () => {
  const push = (daily: unknown[]) => call('POST', '/api/apple/ingest', { daily }, INGEST);
  assert.equal((await push([{ date: '2026-10-16', metric: 'steps', value: 4468 }])).status, 200);
  const v1 = await version();
  assert.ok(v1);
  assert.equal((await push([])).status, 200);
  assert.equal(await version(), v1);
  await push([{ date: '2026-10-17', metric: 'steps', value: 120 }]);
  assert.notEqual(await version(), v1);
});

test('changing settings moves the version, so other devices pick up new units', async () => {
  const before = await version();
  await call('PUT', '/api/settings', { units: 'imperial' });
  assert.notEqual(await version(), before);
});
