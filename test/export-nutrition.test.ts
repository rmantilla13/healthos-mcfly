// "Export your data" and the Nutrition setting: the amounts a person chose not to see are left out of the file, as they
// are from every other nutrition response. Seeing everything, the file keeps the amounts exactly as stored.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { AddressInfo } from 'node:net';
import { createApp } from '../server/app.ts';
import { hashPassword } from '../server/auth.ts';
import { OWNER_ID, setUserSetting } from '../server/db.ts';
import { openStore } from '../server/store.ts';

process.env.SESSION_SECRET = 'export-nutrition-test-secret-'.padEnd(64, 'x');
process.env.HEALTHOS_PASSWORD_HASH = await hashPassword('owner password 123');

const db = await openStore();
const server = createApp({ db, hosted: false, mcflyClient: () => null }).listen(0, '127.0.0.1');
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
  return { status: res.status, text: await res.text() };
}

/** The file's nutrition section, as the person would download it with this setting. */
async function exported(numbers: 'all' | 'no_energy' | 'none') {
  assert.equal((await call('PUT', '/api/settings', { nutrition: true, nutritionNumbers: numbers })).status, 200);
  // One export a minute: each setting here gets its own.
  await setUserSetting(db, OWNER_ID, 'export_last', null);
  const res = await call('GET', '/api/me/export');
  assert.equal(res.status, 200, res.text);
  return JSON.parse(res.text).nutrition;
}

test('setup: the owner, two logged foods and a food app’s totals', async () => {
  assert.equal((await call('POST', '/api/auth/login', { email: 'owner@example.com', password: 'owner password 123' })).status, 200);
  await db.query(
    `INSERT INTO food_log (user_id, id, date, time, name, portion, quantity, per, method, origin, draft, created_at, updated_at)
     VALUES ($1, 'f1', '2026-10-01', '08:30', 'Porridge', '1 bowl', 1.5, $2, 'quick', 'web', false, 1, 1),
            ($1, 'f2', '2026-10-01', '10:00', 'Water', '1 glass', 1, $3, 'quick', 'web', false, 1, 1)`,
    [OWNER_ID, JSON.stringify({ energy_kcal: 210.25, protein_g: 12.34, water_ml: 150.4 }), JSON.stringify({ water_ml: 250 })],
  );
  await db.query(
    `INSERT INTO nutrition_daily (user_id, date, nutrient, source, app, value)
     VALUES ($1, '2026-10-01', 'energy_kcal', 'apple', 'Cronometer', 1980), ($1, '2026-10-01', 'protein_g', 'apple', 'Cronometer', 95)`,
    [OWNER_ID],
  );
});

test("'none': no amounts at all, but what was logged and when", async () => {
  const nutrition = await exported('none');
  assert.ok(!JSON.stringify(nutrition).includes('energy_kcal'));
  assert.deepEqual(
    nutrition.log.map((e: any) => [e.name, e.portion, e.date, e.time, e.quantity, e.per]),
    [
      ['Porridge', '1 bowl', '2026-10-01', '08:30', 1.5, {}],
      ['Water', '1 glass', '2026-10-01', '10:00', 1, {}],
    ],
  );
  assert.deepEqual(nutrition.daily, [], "every food app's total is an amount");
});

test("'no_energy': everything but calories, as the food log shows it", async () => {
  const nutrition = await exported('no_energy');
  assert.ok(!JSON.stringify(nutrition).includes('energy_kcal'));
  assert.deepEqual(
    nutrition.log.map((e: any) => e.per),
    [{ protein_g: 12.3, water_ml: 150 }, { water_ml: 250 }],
  );
  assert.deepEqual(
    nutrition.daily.map((r: any) => [r.nutrient, r.value]),
    [['protein_g', 95]],
  );
});

test("'all': every amount, exactly as stored", async () => {
  const nutrition = await exported('all');
  assert.deepEqual(nutrition.log[0].per, { energy_kcal: 210.25, protein_g: 12.34, water_ml: 150.4 });
  assert.deepEqual(
    nutrition.daily.map((r: any) => [r.nutrient, r.value]),
    [
      ['energy_kcal', 1980],
      ['protein_g', 95],
    ],
  );
});

test('an entry whose amounts can’t be read leaks nothing when amounts are hidden', async () => {
  await db.query(
    `INSERT INTO food_log (user_id, id, date, time, name, portion, quantity, per, method, origin, draft, created_at, updated_at)
     VALUES ($1, 'f3', '2026-10-02', '09:00', 'Odd', '', 1, 'not json {"energy_kcal": 500}', 'quick', 'web', false, 1, 1)`,
    [OWNER_ID],
  );
  const nutrition = await exported('none');
  assert.deepEqual(nutrition.log.find((e: any) => e.id === 'f3').per, {});
  assert.ok(!JSON.stringify(nutrition).includes('energy_kcal'));
});
