// Show and hide dashboard cards: each person's own list (Settings → Cards), checked against the registry, and
// an admin can set it for anyone. Layout only.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { AddressInfo } from 'node:net';
import { CARDS, cleanHiddenCards, fillColumns, readHiddenCards } from '../shared/cards.ts';
import { createApp } from '../server/app.ts';
import { hashPassword } from '../server/auth.ts';
import { getUserSetting } from '../server/db.ts';
import { openStore } from '../server/store.ts';

test('a hidden-cards list is known card ids, once each, in the registry order', () => {
  assert.deepEqual(cleanHiddenCards(['body.steps', 'home.spo2', 'home.spo2']), ['home.spo2', 'body.steps']);
  assert.deepEqual(cleanHiddenCards([]), []);
  assert.equal(cleanHiddenCards(['home.spo2', 'home.nope']), null);
  assert.equal(cleanHiddenCards('home.spo2'), null);
  assert.equal(cleanHiddenCards([1]), null);
  // A stored list is read leniently: a card that no longer exists is just dropped.
  assert.deepEqual(readHiddenCards('["home.hrv","gone.card"]'), ['home.hrv']);
  assert.deepEqual(readHiddenCards('not json'), []);
  assert.deepEqual(readHiddenCards(undefined), []);
  assert.equal(new Set(CARDS.map((c) => c.id)).size, CARDS.length, 'ids are unique');
  // Each id starts with its page, and every Nutrition card is offered only with Nutrition on.
  for (const c of CARDS) assert.ok(c.id.startsWith(`${c.page}.`), c.id);
  assert.ok(CARDS.filter((c) => c.page === 'nutrition').every((c) => c.nutrition));
  assert.ok(CARDS.find((c) => c.id === 'home.food')?.nutrition);
});

test('a row takes as few even rows as fit: what is left after hiding fills the space', () => {
  // Home's row of up to 3: 6 → 3 + 3, 5 → 3 + 2 (the 2 stretch), 4 → 2 × 2, then 3, 2, 1 across.
  assert.deepEqual([6, 5, 4, 3, 2, 1].map((n) => fillColumns(n, 3)), [3, 3, 2, 3, 2, 1]);
  // Body's row of up to 4.
  assert.deepEqual([4, 3, 2, 1].map((n) => fillColumns(n, 4)), [4, 3, 2, 1]);
  // Two across on a medium screen: 5 → 2 + 2 + 1 (the 1 stretches).
  assert.deepEqual([6, 5, 4, 3, 2, 1, 0].map((n) => fillColumns(n, 2)), [2, 2, 2, 2, 2, 1, 1]);
});

process.env.SESSION_SECRET = 'cards-test-secret-'.padEnd(64, 'x');
const OWNER_PASSWORD = 'owner password 123';
process.env.HEALTHOS_PASSWORD_HASH = await hashPassword(OWNER_PASSWORD);

const db = await openStore();
const server = createApp({ db, hosted: true }).listen(0, '127.0.0.1');
await new Promise((r) => server.once('listening', r));
const base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
test.after(() => {
  server.close();
  return db.close();
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
    const text = await res.text();
    let json: any = null;
    try {
      json = JSON.parse(text);
    } catch {
      json = text;
    }
    return { status: res.status, json };
  }
}

const owner = new Client();
const ana = new Client();
let anaId = '';

test('setup: an admin and a member', async () => {
  assert.equal((await owner.call('POST', '/api/auth/login', { email: 'owner@example.com', password: OWNER_PASSWORD })).status, 200);
  const { code } = (await owner.call('POST', '/api/admin/invites', {})).json;
  assert.equal((await ana.call('POST', '/api/auth/invite', { token: code, email: 'ana@example.com', name: 'Ana', password: 'Ana password 1' })).status, 200);
  anaId = (await ana.call('GET', '/api/auth/me')).json.user.id;
});

test('each person hides cards for themselves only, and a bad list changes nothing', async () => {
  assert.deepEqual((await ana.call('GET', '/api/status')).json.settings.hiddenCards, []);
  const saved = await ana.call('PUT', '/api/settings', { hiddenCards: ['body.strain', 'home.spo2'] });
  assert.equal(saved.status, 200);
  assert.deepEqual(saved.json.settings.hiddenCards, ['home.spo2', 'body.strain']);
  assert.deepEqual((await owner.call('GET', '/api/status')).json.settings.hiddenCards, [], "the owner's cards are untouched");

  // An unknown card fails the whole request, before anything in it is written.
  const bad = await ana.call('PUT', '/api/settings', { name: 'Renamed', hiddenCards: ['home.spo2', 'home.everything'] });
  assert.equal(bad.status, 400);
  const after = (await ana.call('GET', '/api/status')).json.settings;
  assert.equal(after.name, 'Ana');
  assert.deepEqual(after.hiddenCards, ['home.spo2', 'body.strain']);

  // Showing everything again leaves nothing stored.
  assert.deepEqual((await ana.call('PUT', '/api/settings', { hiddenCards: [] })).json.settings.hiddenCards, []);
  assert.equal(await getUserSetting(db, anaId, 'hidden_cards'), undefined);
});

test("an admin can set a member's cards; a member can't use the admin route", async () => {
  const set = await owner.call('PATCH', `/api/admin/users/${anaId}`, { hiddenCards: ['sleep.insights'] });
  assert.equal(set.status, 200);
  assert.deepEqual((await ana.call('GET', '/api/status')).json.settings.hiddenCards, ['sleep.insights']);
  const row = (await owner.call('GET', '/api/admin/overview')).json.users.find((u: { id: string }) => u.id === anaId);
  assert.deepEqual(row.hiddenCards, ['sleep.insights']);
  // Role and status are unchanged by a cards-only change.
  assert.deepEqual([row.role, row.status], ['user', 'active']);

  assert.equal((await owner.call('PATCH', `/api/admin/users/${anaId}`, { hiddenCards: ['nope'] })).status, 400);
  assert.equal((await ana.call('PATCH', `/api/admin/users/${anaId}`, { hiddenCards: [] })).status, 403);
  assert.deepEqual((await ana.call('GET', '/api/status')).json.settings.hiddenCards, ['sleep.insights']);
});

test("one card's change applies to the list as stored now, so a change made elsewhere stays", async () => {
  // Ana's own page loaded when nothing was hidden; meanwhile an admin hid sleep.insights for her.
  await owner.call('PATCH', `/api/admin/users/${anaId}`, { hiddenCards: ['sleep.insights'] });
  const r = await ana.call('PUT', '/api/settings', { cardShown: { id: 'home.hrv', shown: false } });
  assert.deepEqual(r.json.settings.hiddenCards, ['home.hrv', 'sleep.insights']);
  // And the other way round: the admin shows one card for her without undoing hers.
  const a = await owner.call('PATCH', `/api/admin/users/${anaId}`, { cardShown: { id: 'sleep.insights', shown: true } });
  assert.deepEqual(a.json.hiddenCards, ['home.hrv']);
  assert.deepEqual((await ana.call('GET', '/api/status')).json.settings.hiddenCards, ['home.hrv']);
  // Unknown cards and wrong shapes are refused.
  assert.equal((await ana.call('PUT', '/api/settings', { cardShown: { id: 'home.nope', shown: false } })).status, 400);
  assert.equal((await ana.call('PUT', '/api/settings', { cardShown: { id: 'home.hrv', shown: 'yes' } })).status, 400);
  assert.equal((await owner.call('PATCH', `/api/admin/users/${anaId}`, { cardShown: 'home.hrv' })).status, 400);
});

test('optional cards are off until turned on, by the person or an admin, and Show all leaves them as they are', async () => {
  let s = (await ana.call('GET', '/api/status')).json.settings;
  assert.deepEqual(s.shownCards, []);
  s = (await ana.call('PUT', '/api/settings', { cardShown: { id: 'home.timeline', shown: true } })).json.settings;
  assert.deepEqual(s.shownCards, ['home.timeline']);
  // Turning an optional card on doesn't touch the hidden list, and Show all doesn't turn it off.
  assert.deepEqual(s.hiddenCards, ['home.hrv']);
  s = (await ana.call('PUT', '/api/settings', { hiddenCards: [] })).json.settings;
  assert.deepEqual([s.hiddenCards, s.shownCards], [[], ['home.timeline']]);
  const a = await owner.call('PATCH', `/api/admin/users/${anaId}`, { cardShown: { id: 'home.insights', shown: true } });
  assert.deepEqual(a.json.shownCards, ['home.timeline', 'home.insights']);
  const row = (await owner.call('GET', '/api/admin/overview')).json.users.find((u: { id: string }) => u.id === anaId);
  assert.deepEqual(row.shownCards, ['home.timeline', 'home.insights']);
  // Nutrition's optional card stays the person's own: an admin can't set it.
  assert.equal((await owner.call('PATCH', `/api/admin/users/${anaId}`, { cardShown: { id: 'home.food', shown: true } })).status, 400);
  assert.equal((await ana.call('PUT', '/api/settings', { shownCards: ['home.hrv'] })).status, 400);
});
