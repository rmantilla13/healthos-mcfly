// Onboarding ("Make this space yours"): new accounts start at step 1, older ones never see it, and the fields it
// saves are checked. Gender never changes `sex`, and peer comparisons need an age of 18 or over.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { AddressInfo } from 'node:net';
import { createApp } from '../server/app.ts';
import { hashPassword } from '../server/auth.ts';
import { OWNER_ID } from '../server/db.ts';
import { currentAge } from '../server/query.ts';
import { openStore } from '../server/store.ts';

process.env.SESSION_SECRET = 'onboarding-test-secret-'.padEnd(64, 'x');
process.env.HEALTHOS_PASSWORD_HASH = await hashPassword('owner password 123');

const db = await openStore();
// An existing single-user healthOS: the owner already has settings, so moving to accounts skips onboarding.
await db.query("INSERT INTO user_settings (user_id, key, value) VALUES ($1, 'units', 'metric')", [OWNER_ID]);
const server = createApp({ db, hosted: false }).listen(0, '127.0.0.1');
await new Promise((r) => server.once('listening', r));
const base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
test.after(() => {
  server.close();
});

class Client {
  cookie = '';
  async call(method: string, path: string, body?: unknown) {
    const res = await fetch(base + path, {
      method,
      headers: { 'X-HealthOS': '1', 'Content-Type': 'application/json', ...(this.cookie ? { Cookie: this.cookie } : {}) },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const set = res.headers.get('set-cookie');
    if (set) this.cookie = set.split(';')[0];
    return { status: res.status, json: (await res.json().catch(() => null)) as any };
  }
}

const owner = new Client();
const amy = new Client();

test('the owner of an existing healthOS is not sent through onboarding', async () => {
  assert.equal((await owner.call('POST', '/api/auth/login', { email: 'owner@example.com', password: 'owner password 123' })).status, 200);
  const s = (await owner.call('GET', '/api/status')).json.settings;
  assert.equal(s.onboarding, null);
  assert.equal(s.perspective, 'portrait');
  assert.equal(s.peerComparison, false);
});

test('a new account starts at step 1 and moves through the steps', async () => {
  const invite = (await owner.call('POST', '/api/admin/invites', { role: 'user' })).json;
  const token = invite.code ?? invite.token;
  assert.ok(token);
  assert.equal((await amy.call('POST', '/api/auth/invite', { token, email: 'amy@example.com', name: 'Amy', password: 'amy password 123' })).status, 200);
  assert.equal((await amy.call('GET', '/api/status')).json.settings.onboarding, 1);
  const s = (await amy.call('PUT', '/api/settings', { perspective: 'digital', onboarding: 2 })).json.settings;
  assert.equal(s.perspective, 'digital');
  assert.equal(s.onboarding, 2);
});

test('the fields are checked, and gender never changes sex', async () => {
  assert.equal((await amy.call('PUT', '/api/settings', { perspective: 'avatar' })).status, 400);
  assert.equal((await amy.call('PUT', '/api/settings', { gender: 'other' })).status, 400);
  assert.equal((await amy.call('PUT', '/api/settings', { age: 33.5 })).status, 400);
  assert.equal((await amy.call('PUT', '/api/settings', { age: 0 })).status, 400);
  const s = (await amy.call('PUT', '/api/settings', { gender: 'woman', age: 33 })).json.settings;
  assert.equal(s.gender, 'woman');
  assert.equal(s.age, 33);
  assert.equal(s.sex, null);
});

test('peer comparisons need an age of 18 or over, and an age under 18 turns them off', async () => {
  let s = (await amy.call('PUT', '/api/settings', { peerComparison: true })).json.settings;
  assert.equal(s.peerComparison, true);
  s = (await amy.call('PUT', '/api/settings', { age: 16 })).json.settings;
  assert.equal(s.peerComparison, false);
  assert.equal((await amy.call('PUT', '/api/settings', { peerComparison: true })).status, 400);
  // Age and the switch in one request: the age is applied first.
  s = (await amy.call('PUT', '/api/settings', { age: 40, peerComparison: true })).json.settings;
  assert.equal(s.peerComparison, true);
});

test('finishing clears the step, and an account without one never gets one', async () => {
  assert.equal((await amy.call('PUT', '/api/settings', { onboarding: null })).json.settings.onboarding, null);
  assert.equal((await amy.call('PUT', '/api/settings', { onboarding: 2 })).json.settings.onboarding, null);
  assert.equal((await owner.call('PUT', '/api/settings', { onboarding: 1 })).json.settings.onboarding, null);
});

test('an age stays current from the day it was given', () => {
  assert.equal(currentAge(JSON.stringify({ age: 33, asOf: '2025-10-24' }), '2026-10-23'), 33);
  assert.equal(currentAge(JSON.stringify({ age: 33, asOf: '2025-10-23' }), '2026-10-23'), 34);
  assert.equal(currentAge('nonsense', '2026-10-23'), null);
  assert.equal(currentAge(undefined, '2026-10-23'), null);
});
