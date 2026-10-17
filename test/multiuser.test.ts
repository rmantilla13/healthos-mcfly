// Accounts, invites and per-user isolation, end to end over HTTP against an in-memory database.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { AddressInfo } from 'node:net';
import { createApp } from '../server/app.ts';
import { hashPassword } from '../server/auth.ts';
import { OWNER_ID, upsertDaily, upsertEvents, upsertWorkouts } from '../server/db.ts';
import { openStore } from '../server/store.ts';
import * as whoop from '../server/whoop.ts';

process.env.SESSION_SECRET = 'test-secret-'.padEnd(64, 'x');
const OWNER_PASSWORD = 'owner password 123';
process.env.HEALTHOS_PASSWORD_HASH = await hashPassword(OWNER_PASSWORD);
const OWNER_INGEST = 'owner-ingest-token-0123456789';

const db = await openStore();
const app = createApp({ db, hosted: false, ingestToken: OWNER_INGEST });
const server = app.listen(0, '127.0.0.1');
await new Promise((r) => server.once('listening', r));
const base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
test.after(() => {
  server.close();
});

class Client {
  cookie = '';
  async call(method: string, path: string, body?: unknown, headers: Record<string, string> = {}) {
    const res = await fetch(base + path, {
      method,
      redirect: 'manual',
      headers: { 'X-HealthOS': '1', 'Content-Type': 'application/json', ...(this.cookie ? { Cookie: this.cookie } : {}), ...headers },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const set = res.headers.get('set-cookie');
    if (set) this.cookie = set.split(';')[0].endsWith('=') ? '' : set.split(';')[0];
    const text = await res.text();
    let json: any = null;
    try {
      json = JSON.parse(text);
    } catch {
      json = text;
    }
    return { status: res.status, json, headers: res.headers };
  }
  get = (p: string) => this.call('GET', p);
  post = (p: string, b?: unknown) => this.call('POST', p, b ?? {});
}

const owner = new Client();
const bob = new Client();
let bobId = '';
const tokenFrom = (url: string) => url.split('/').at(-1)!;

const day = (d: number) => `2026-10-${String(d).padStart(2, '0')}`;
async function seed(userId: string, rhr: number) {
  await upsertDaily(
    db,
    userId,
    [10, 11, 12, 13, 14, 15, 16].flatMap((d) => [
      { date: day(d), metric: 'resting_hr', source: 'apple', value: rhr },
      { date: day(d), metric: 'steps', source: 'apple', value: rhr * 100 },
    ]),
  );
}

test('before any account exists, the original password creates the admin', async () => {
  const me = await owner.get('/api/auth/me');
  assert.equal(me.json.mode, 'required');
  assert.equal(me.json.setup, true);
  assert.equal((await owner.get('/api/summary')).status, 401);
  assert.equal((await owner.post('/api/auth/login', { email: 'owner@example.com', password: 'nope nope nope' })).status, 401);
  const ok = await owner.post('/api/auth/login', { email: 'Owner@Example.com', password: OWNER_PASSWORD });
  assert.equal(ok.status, 200);
  const me2 = await owner.get('/api/auth/me');
  assert.deepEqual(me2.json.user, { id: OWNER_ID, email: 'owner@example.com', name: '', role: 'admin' });
  assert.equal(me2.json.setup, false);
});

test('an invite link creates exactly one account, for the invited email', async () => {
  const inv = await owner.post('/api/admin/invites', { email: 'bob@example.com', role: 'user' });
  assert.equal(inv.status, 200);
  assert.match(inv.json.url, /\/#\/invite\/[A-Za-z0-9_-]{20,}$/);
  const token = tokenFrom(inv.json.url);

  const check = await bob.post('/api/auth/link', { token });
  assert.deepEqual(check.json, { kind: 'invite', email: 'bob@example.com' });

  const wrongEmail = await bob.post('/api/auth/invite', { token, email: 'eve@example.com', name: 'Eve', password: 'a long password' });
  assert.equal(wrongEmail.status, 400);
  const shortPw = await bob.post('/api/auth/invite', { token, email: 'bob@example.com', name: 'Bob', password: 'short' });
  assert.equal(shortPw.status, 400);

  const ok = await bob.post('/api/auth/invite', { token, email: 'bob@example.com', name: 'Bob', password: 'bob password 123' });
  assert.equal(ok.status, 200);
  const me = await bob.get('/api/auth/me');
  assert.equal(me.json.user.role, 'user');
  bobId = me.json.user.id;

  const again = await new Client().post('/api/auth/invite', { token, email: 'bob@example.com', name: 'Bob 2', password: 'bob password 456' });
  assert.equal(again.status, 404, 'a used link stays used');
});

test("each person sees only their own data, on every endpoint", async () => {
  await seed(OWNER_ID, 60);
  await seed(bobId, 80);
  await upsertWorkouts(db, OWNER_ID, [
    { id: 'w1', source: 'apple', sport: 'Running', start: '2026-10-16T07:00:00-05:00', end: '2026-10-16T07:30:00-05:00', date: day(16), duration_min: 30, energy_kcal: 300, distance_m: 5000, avg_hr: 150, max_hr: 170, strain: null },
  ]);
  await upsertEvents(db, OWNER_ID, [{ id: 'e1', source: 'apple', kind: 'mindful', title: 'Mindfulness', start: '2026-10-16T08:00:00-05:00', end: '2026-10-16T08:10:00-05:00', date: day(16) }]);
  await db.query("INSERT INTO profile_assets (user_id, name, mime, data, updated_at) VALUES ($1, 'cutout.png', 'image/png', $2, 1)", [OWNER_ID, Buffer.from([1, 2, 3])]);
  await db.query("INSERT INTO user_settings (user_id, key, value) VALUES ($1, 'photo_meta', '{\"version\":1}')", [OWNER_ID]);

  const trend = (c: Client) => c.get(`/api/trends?metrics=resting_hr&days=7&date=${day(16)}`);
  assert.deepEqual((await trend(owner)).json.resting_hr.map((p: any) => p.value), [60, 60, 60, 60, 60, 60, 60]);
  assert.deepEqual((await trend(bob)).json.resting_hr.map((p: any) => p.value), [80, 80, 80, 80, 80, 80, 80]);

  const sumBob = (await bob.get(`/api/summary?date=${day(16)}`)).json;
  assert.equal(sumBob.vitals.heart.latest.value, 80);
  assert.equal(sumBob.activity.latest.value, 8000);
  assert.deepEqual(sumBob.timeline.events, []);
  const sumOwner = (await owner.get(`/api/summary?date=${day(16)}`)).json;
  assert.equal(sumOwner.vitals.heart.latest.value, 60);
  assert.equal(sumOwner.timeline.events.length, 2);

  assert.equal((await owner.get(`/api/workouts?days=30&date=${day(16)}`)).json.length, 1);
  assert.deepEqual((await bob.get(`/api/workouts?days=30&date=${day(16)}`)).json, []);

  assert.ok((await owner.get('/api/status')).json.photo);
  assert.equal((await bob.get('/api/status')).json.photo, null);
  assert.equal((await owner.get('/api/profile/cutout.png')).status, 200);
  assert.equal((await bob.get('/api/profile/cutout.png')).status, 404);

  await bob.call('PUT', '/api/settings', { units: 'imperial', name: 'Bobby' });
  assert.equal((await bob.get('/api/status')).json.settings.units, 'imperial');
  assert.equal((await owner.get('/api/status')).json.settings.units, 'metric');
  assert.equal((await bob.get('/api/status')).json.settings.name, 'Bobby');
  assert.notEqual((await owner.get('/api/status')).json.settings.name, 'Bobby');
});

test("an iPhone token writes only into its owner's account", async () => {
  const { json } = await bob.post('/api/me/ingest-token');
  const push = (token: string, value: number) =>
    fetch(`${base}/api/apple/ingest`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-HealthOS': '1', Authorization: `Bearer ${token}` },
      body: JSON.stringify({ daily: [{ date: day(17), metric: 'steps', value }] }),
    });
  assert.equal((await push(json.token, 1234)).status, 200);
  assert.equal((await push(OWNER_INGEST, 999)).status, 200);
  assert.equal((await push('not-a-token', 5)).status, 401);
  const rows = await db.query<{ user_id: string; value: number }>("SELECT user_id, value FROM daily WHERE date = $1 AND metric = 'steps' ORDER BY value", [day(17)]);
  assert.deepEqual(rows.map((r) => ({ ...r })), [
    { user_id: OWNER_ID, value: 999 },
    { user_id: bobId, value: 1234 },
  ]);
});

test('admin routes are admins-only, and show account health without health values', async () => {
  assert.equal((await bob.get('/api/admin/overview')).status, 403);
  assert.equal((await bob.post('/api/admin/invites', {})).status, 403);
  const ov = await owner.get('/api/admin/overview');
  assert.equal(ov.status, 200);
  assert.equal(ov.json.users.length, 2);
  const b = ov.json.users.find((u: any) => u.id === bobId);
  assert.equal(b.data.days, 8);
  assert.equal(b.apple.iphoneToken, true);
  assert.ok(!JSON.stringify(ov.json).includes('resting_hr'), 'no metric values or names in the admin view');
});

test('a reset link sets a new password and ends existing sessions', async () => {
  const link = await owner.post(`/api/admin/users/${bobId}/reset`);
  assert.equal(link.status, 200);
  const fresh = new Client();
  assert.equal((await fresh.post('/api/auth/link', { token: tokenFrom(link.json.url) })).json.kind, 'reset');
  assert.equal((await fresh.post('/api/auth/reset', { token: tokenFrom(link.json.url), password: 'bob new password' })).status, 200);
  assert.equal((await bob.get('/api/summary')).status, 401, "the old session ended");
  assert.equal((await fresh.get('/api/status')).status, 200, 'the reset signs you in');
  assert.equal((await bob.post('/api/auth/login', { email: 'bob@example.com', password: 'bob password 123' })).status, 401);
  assert.equal((await bob.post('/api/auth/login', { email: 'BOB@example.com', password: 'bob new password' })).status, 200);
});

test('disabling an account ends its sessions and blocks sign-in', async () => {
  assert.equal((await owner.call('PATCH', `/api/admin/users/${bobId}`, { status: 'disabled' })).status, 200);
  assert.equal((await bob.get('/api/status')).status, 401);
  assert.equal((await bob.post('/api/auth/login', { email: 'bob@example.com', password: 'bob new password' })).status, 401);
  assert.equal((await owner.call('PATCH', `/api/admin/users/${bobId}`, { status: 'active' })).status, 200);
  assert.equal((await bob.post('/api/auth/login', { email: 'bob@example.com', password: 'bob new password' })).status, 200);
});

test('there is always an active admin', async () => {
  assert.equal((await owner.call('PATCH', `/api/admin/users/${OWNER_ID}`, { role: 'user' })).status, 400);
  assert.equal((await owner.call('PATCH', `/api/admin/users/${OWNER_ID}`, { status: 'disabled' })).status, 400);
  assert.equal((await owner.call('DELETE', `/api/admin/users/${OWNER_ID}`)).status, 400);
});

test('expired and revoked invites, and closed registration, create nothing', async () => {
  const a = await owner.post('/api/admin/invites', {});
  await db.query('UPDATE invites SET expires_at = 1 WHERE id = $1', [a.json.id]);
  assert.equal((await new Client().post('/api/auth/invite', { token: tokenFrom(a.json.url), email: 'x@example.com', password: 'x password 123' })).status, 404);

  const b = await owner.post('/api/admin/invites', {});
  await owner.post(`/api/admin/invites/${b.json.id}/revoke`);
  assert.equal((await new Client().post('/api/auth/invite', { token: tokenFrom(b.json.url), email: 'y@example.com', password: 'y password 123' })).status, 404);

  const c = await owner.post('/api/admin/invites', {});
  await owner.call('PUT', '/api/admin/settings', { registration: 'closed' });
  assert.equal((await new Client().post('/api/auth/invite', { token: tokenFrom(c.json.url), email: 'z@example.com', password: 'z password 123' })).status, 403);
  await owner.call('PUT', '/api/admin/settings', { registration: 'invite' });
  assert.equal((await db.query<{ n: number }>('SELECT COUNT(*)::int AS n FROM users'))[0].n, 2);
});

test('the WHOOP cron syncs active accounts, and the owner before their first sign-in', async () => {
  const fresh = await openStore();
  const token = (userId: string) =>
    fresh.query("INSERT INTO tokens (user_id, provider, access_token, refresh_token, expires_at, scope) VALUES ($1, 'whoop', 'a', 'r', 0, '')", [userId]);
  await token(OWNER_ID);
  assert.deepEqual(await whoop.whoopSyncTargets(fresh), [{ user_id: OWNER_ID }], 'owner with no account row yet');
  await fresh.query("INSERT INTO users (id, email, name, password_hash, role, status, created_at) VALUES ('u1', 'a@example.com', '', 'x', 'user', 'active', 1), ('u2', 'b@example.com', '', 'x', 'user', 'disabled', 1)");
  await token('u1');
  await token('u2');
  await token('ghost');
  assert.deepEqual((await whoop.whoopSyncTargets(fresh)).map((r) => r.user_id), [OWNER_ID, 'u1']);
  await fresh.close();
});

test("a WHOOP sign-in started by one person can't be finished by another", async () => {
  process.env.WHOOP_CLIENT_ID = 'test-client';
  process.env.WHOOP_CLIENT_SECRET = 'test-secret';
  const url = new URL(await whoop.authorizeUrl({ db, userId: OWNER_ID }));
  const state = url.searchParams.get('state')!;
  assert.equal(await whoop.consumeState({ db, userId: bobId }, state), false);
  assert.equal(await whoop.consumeState({ db, userId: OWNER_ID }, state), true);
  delete process.env.WHOOP_CLIENT_ID;
  delete process.env.WHOOP_CLIENT_SECRET;
});

test("deleting an account removes all of that person's data and nobody else's", async () => {
  const before = (await db.query<{ n: number }>('SELECT COUNT(*)::int AS n FROM daily WHERE user_id = $1', [OWNER_ID]))[0].n;
  assert.equal((await owner.call('DELETE', `/api/admin/users/${bobId}`)).status, 200);
  for (const t of ['daily', 'workouts', 'events', 'tokens', 'profile_assets', 'user_settings', 'mcfly_usage']) {
    assert.equal((await db.query<{ n: number }>(`SELECT COUNT(*)::int AS n FROM ${t} WHERE user_id = $1`, [bobId]))[0].n, 0, t);
  }
  assert.equal((await db.query<{ n: number }>('SELECT COUNT(*)::int AS n FROM daily WHERE user_id = $1', [OWNER_ID]))[0].n, before);
  assert.equal((await bob.get('/api/status')).status, 401);
});
