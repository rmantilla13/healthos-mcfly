// One day of the food log (POST /api/nutrition/log/day, the Nutrition page's Today): that person's entries for that
// day only, the estimate waiting, the day added up as their numbers setting allows, which app counts, and who reads an
// estimate for them. The date is in the body, checked like any date a person sends. No test here calls a provider.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { AddressInfo } from 'node:net';
import type { FoodDay } from '../shared/foodday.ts';
import type { AiFetch } from '../server/ai/provider.ts';
import { createApp } from '../server/app.ts';
import { hashPassword } from '../server/auth.ts';
import { addDays, todayLocal } from '../server/dates.ts';
import type { McflyClient } from '../server/mcfly.ts';
import { openStore } from '../server/store.ts';

// Made-up secrets only; and nothing from the shell may change which AI is used.
delete process.env.OPENAI_API_KEY;
delete process.env.ANTHROPIC_API_KEY;
delete process.env.FDC_API_KEY;
delete process.env.HEALTHOS_DATA_KEY_PREVIOUS;
process.env.HEALTHOS_DATA_KEY = 'b2'.repeat(32);
process.env.SESSION_SECRET = 'nutrition-day-test-secret-'.padEnd(64, 'x');
const OWNER_PASSWORD = 'owner password 123';
process.env.HEALTHOS_PASSWORD_HASH = await hashPassword(OWNER_PASSWORD);
const OWNER_INGEST = 'owner-ingest-token-nutrition-day-0123';
const BOB_OPENAI = 'sk-proj-TESTKEY-bob-openai-1234567890abcd';

// The providers' model lists, as a fake: only Bob's made-up key is accepted.
const aiFetch: AiFetch = async (_url, init) => {
  const auth = new Headers(init?.headers).get('authorization');
  return auth === `Bearer ${BOB_OPENAI}` ? new Response(JSON.stringify({ data: [] })) : new Response(JSON.stringify({ error: {} }), { status: 401 });
};

// A fake shared Claude for estimates: one scripted answer.
const ESTIMATE = JSON.stringify({
  items: [
    {
      name: 'Chicken bowl',
      portion: '1 bowl (450 g)',
      energy_kcal: 640,
      protein_g: 42,
      carbs_g: 70,
      fat_g: 20,
      fiber_g: 8,
      sugar_g: 3,
      sat_fat_g: null,
      sodium_mg: 900,
      alcohol_drinks: 0,
      water_ml: null,
    },
  ],
  note: 'Assumed half an avocado.',
});
const fake = {
  beta: {
    messages: {
      async create() {
        return {
          id: 'msg_test',
          type: 'message',
          role: 'assistant',
          model: 'claude-opus-5-5',
          content: [{ type: 'text', text: ESTIMATE }],
          stop_reason: 'end_turn',
          stop_sequence: null,
          usage: { input_tokens: 1000, output_tokens: 200, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 },
        };
      },
    },
  },
} as unknown as McflyClient;

const db = await openStore();
const server = createApp({ db, hosted: false, ingestToken: OWNER_INGEST, mcflyClient: () => fake, foodFetch: async () => new Response('{}'), aiFetch }).listen(0, '127.0.0.1');
await new Promise((r) => server.once('listening', r));
const base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
test.after(() => {
  server.close();
});

class Client {
  cookie = '';
  async call(method: string, p: string, body?: unknown, headers: Record<string, string> = {}) {
    const res = await fetch(base + p, {
      method,
      headers: { 'X-HealthOS': '1', 'Content-Type': 'application/json', ...(this.cookie ? { Cookie: this.cookie } : {}), ...headers },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const set = res.headers.get('set-cookie');
    if (set) this.cookie = set.split(';')[0];
    const text = await res.text();
    let json: any = null;
    try {
      json = JSON.parse(text);
    } catch {
      json = null;
    }
    return { status: res.status, text, json };
  }
  post = (p: string, b?: unknown) => this.call('POST', p, b ?? {});
  put = (p: string, b: unknown) => this.call('PUT', p, b);
  day = (date?: unknown) => this.call('POST', '/api/nutrition/log/day', date === undefined ? {} : { date });
}

const owner = new Client();
const bob = new Client();
const today = todayLocal();
const yesterday = addDays(today, -1);
const quick = (c: Client, name: string, values: Record<string, number>, date = today, time = '12:00') =>
  c.post('/api/nutrition/log', { method: 'quick', name, values, date, time });

test('setup: an owner and an invited member', async () => {
  assert.equal((await owner.post('/api/auth/login', { email: 'owner@example.com', password: OWNER_PASSWORD })).status, 200);
  const inv = await owner.post('/api/admin/invites', {});
  const token = inv.json.url.split('/').at(-1);
  assert.equal((await bob.post('/api/auth/invite', { token, email: 'bob@example.com', name: 'Bob', password: 'bob password 123' })).status, 200);
});

test('while Nutrition is off a day is refused, as every other food log write and read of amounts is', async () => {
  const res = await owner.day();
  assert.equal(res.status, 409);
  assert.match(res.json.error, /Turn on Nutrition/);
});

test("a day: that day's entries only, by time, added up, healthOS counting, today when no date is sent", async () => {
  assert.equal((await owner.put('/api/settings', { nutrition: true, nutritionNumbers: 'all' })).status, 200);
  await quick(owner, 'Toast and eggs', { energy_kcal: 420, protein_g: 22, carbs_g: 30, fat_g: 21 }, today, '08:15');
  await quick(owner, 'Water', { water_ml: 500 }, today, '07:00');
  await quick(owner, 'Soup', { energy_kcal: 300, protein_g: 12 }, yesterday, '19:00');

  const res = await owner.day();
  assert.equal(res.status, 200);
  const day = res.json as FoodDay;
  assert.deepEqual([day.date, day.today, day.numbers], [today, today, 'all']);
  assert.deepEqual(
    day.entries.map((e) => [e.time, e.name]),
    [
      ['07:00', 'Water'],
      ['08:15', 'Toast and eggs'],
    ],
  );
  assert.deepEqual(day.balance, { energy_kcal: 420, protein_g: 22, carbs_g: 30, fat_g: 21, water_ml: 500 });
  assert.equal(day.countedApp, 'healthOS');
  assert.deepEqual([day.drafts, day.draftBatch], [[], null]);
  assert.deepEqual(day.can, { estimate: true, usda: false, estimateProvider: 'anthropic', estimateSource: 'shared', voice: false });

  const before = (await owner.day(yesterday)).json as FoodDay;
  assert.deepEqual(
    before.entries.map((e) => e.name),
    ['Soup'],
  );
  assert.deepEqual(before.balance, { energy_kcal: 300, protein_g: 12 });
});

test('the date is checked: a real day, not after today, at most a year back, and never echoed back', async () => {
  for (const [date, message] of [
    ['2999-01-01', /last year/],
    [addDays(today, 1), /last year/],
    [addDays(today, -367), /last year/],
    ['2026-02-30', /Choose a date/],
    ['yesterday', /Choose a date/],
    [20261023, /Choose a date/],
  ] as const) {
    const res = await owner.day(date);
    assert.equal(res.status, 400, String(date));
    assert.match(res.json.error, message);
    assert.ok(!res.text.includes(String(date)), 'the message never quotes what was sent');
  }
  const oldest = await owner.day(addDays(today, -366));
  assert.deepEqual([oldest.status, oldest.json.entries], [200, []]);
  assert.deepEqual(oldest.json.balance, {}, 'nothing logged is an empty day, never zeros');
  assert.equal(oldest.json.countedApp, null);
});

test('when a Health app counts for the day it is named, and its totals are not added to the log', async () => {
  const ingest = await owner.call(
    'POST',
    '/api/apple/ingest',
    { nutrition: [{ date: yesterday, apps: [{ app: 'MyFitnessPal', values: { energy_kcal: 1900, protein_g: 80 } }] }] },
    { Authorization: `Bearer ${OWNER_INGEST}` },
  );
  assert.equal(ingest.status, 200);
  const day = (await owner.day(yesterday)).json as FoodDay;
  assert.equal(day.countedApp, 'MyFitnessPal', 'it logged more that day');
  assert.deepEqual(day.balance, { energy_kcal: 300, protein_g: 12 }, 'the balance is what was logged here');
  // The person's own choice of app wins on the days it logged.
  await owner.put('/api/settings', { nutritionApp: 'healthOS' });
  assert.equal(((await owner.day(yesterday)).json as FoodDay).countedApp, 'healthOS');
  await owner.put('/api/settings', { nutritionApp: null });
});

test('the estimate waiting for review is there on any day viewed, and only until it is saved', async () => {
  const est = await owner.post('/api/nutrition/estimate', { description: 'a chicken bowl with rice and avocado', date: yesterday, time: '13:00' });
  assert.equal(est.status, 200);
  for (const date of [today, yesterday]) {
    const day = (await owner.day(date)).json as FoodDay;
    assert.equal(day.draftBatch, est.json.batch);
    assert.deepEqual(
      day.drafts.map((d) => [d.name, d.date, d.time]),
      [['Chicken bowl', yesterday, '13:00']],
    );
  }
  assert.deepEqual(((await owner.day(yesterday)).json as FoodDay).balance, { energy_kcal: 300, protein_g: 12 }, 'a draft counts for nothing');
  await owner.post('/api/nutrition/log/save', { batch: est.json.batch, ids: est.json.drafts.map((d: { id: string }) => d.id) });
  const saved = (await owner.day(yesterday)).json as FoodDay;
  assert.deepEqual([saved.drafts, saved.draftBatch], [[], null]);
  assert.deepEqual(
    saved.entries.map((e) => e.name),
    ['Chicken bowl', 'Soup'],
  );
  assert.equal(saved.balance.energy_kcal, 940);
  assert.equal(saved.balance.sodium_mg, 900);
});

test('no calories: none in the entries or the balance; no amounts: names only, and a balance with nothing in it', async () => {
  await owner.put('/api/settings', { nutritionNumbers: 'no_energy' });
  const noEnergy = await owner.day();
  assert.deepEqual(noEnergy.json.balance, { protein_g: 22, carbs_g: 30, fat_g: 21, water_ml: 500 });
  assert.ok(!noEnergy.text.includes('energy_kcal'));

  await owner.put('/api/settings', { nutritionNumbers: 'none' });
  const none = await owner.day(yesterday);
  assert.equal(none.json.numbers, 'none');
  assert.deepEqual(none.json.balance, {});
  assert.deepEqual(
    none.json.entries.map((e: { name: string }) => e.name),
    ['Chicken bowl', 'Soup'],
  );
  assert.ok(none.json.entries.every((e: { values: object }) => Object.keys(e.values).length === 0));
  assert.ok(!/energy_kcal|protein_g|water_ml/.test(none.text));
  await owner.put('/api/settings', { nutritionNumbers: 'all' });
});

test("someone else's day: none of the owner's entries, drafts or apps, and their own AI", async () => {
  await bob.put('/api/settings', { nutrition: true, nutritionNumbers: 'all' });
  await owner.post('/api/nutrition/estimate', { description: 'pasta' });
  for (const date of [today, yesterday]) {
    const day = (await bob.day(date)).json as FoodDay;
    assert.deepEqual([day.entries, day.drafts, day.draftBatch, day.balance, day.countedApp], [[], [], null, {}, null], date);
  }
  await quick(bob, 'Oats', { energy_kcal: 350 });
  assert.deepEqual(
    ((await bob.day()).json as FoodDay).entries.map((e) => e.name),
    ['Oats'],
  );
  assert.ok(!((await owner.day()).json as FoodDay).entries.some((e) => e.name === 'Oats'));

  // Bob's own OpenAI key reads his estimates and his voice notes; the owner stays on the shared assistant.
  assert.equal((await bob.put('/api/ai/keys/openai', { key: BOB_OPENAI })).status, 200);
  assert.deepEqual(((await bob.day()).json as FoodDay).can, { estimate: true, usda: false, estimateProvider: 'openai', estimateSource: 'own', voice: true });
  assert.deepEqual(((await owner.day()).json as FoodDay).can, { estimate: true, usda: false, estimateProvider: 'anthropic', estimateSource: 'shared', voice: false });
  assert.equal((await bob.call('GET', '/api/nutrition/log')).json.can.estimateProvider, 'openai', 'GET /log says the same');

  // With the shared assistant off, only a person with their own key can estimate.
  await owner.call('PUT', '/api/admin/settings', { mcfly_daily_limit: 0 });
  assert.deepEqual(((await owner.day()).json as FoodDay).can, { estimate: false, usda: false, estimateProvider: null, estimateSource: null, voice: false });
  assert.equal(((await bob.day()).json as FoodDay).can.estimate, true);
  await owner.call('PUT', '/api/admin/settings', { mcfly_daily_limit: 50 });
});
