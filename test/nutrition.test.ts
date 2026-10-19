// Nutrition: daily food totals from Apple Health, off until the person turns it on, filtered by what they chose
// to see, and kept apart from everything that reads `daily` (see server/nutrition.ts).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import type { AddressInfo } from 'node:net';
import type { NutritionData } from '../shared/types.ts';
import { importAppleHealth } from '../server/apple/import.ts';
import { createApp } from '../server/app.ts';
import { hashPassword } from '../server/auth.ts';
import { addDays, todayLocal } from '../server/dates.ts';
import { OWNER_ID, deleteSource, setUserSetting } from '../server/db.ts';
import type { McflyClient } from '../server/mcfly.ts';
import { parseNutritionDay, pickDays, shown } from '../server/nutrition.ts';
import { openStore } from '../server/store.ts';

// ---------- choosing and filtering ----------

test('a day shows one app, never a sum: the chosen app, else the one with the most energy', () => {
  const rows = [
    { date: '2026-10-01', nutrient: 'energy_kcal' as const, app: 'MyFitnessPal', value: 2100 },
    { date: '2026-10-01', nutrient: 'protein_g' as const, app: 'MyFitnessPal', value: 90 },
    // Lose It! copied MyFitnessPal's energy from Health into its own log: the same meals, not more food.
    { date: '2026-10-01', nutrient: 'energy_kcal' as const, app: 'Lose It!', value: 2100 },
    { date: '2026-10-02', nutrient: 'energy_kcal' as const, app: 'Cronometer', value: 1800 },
    { date: '2026-10-02', nutrient: 'energy_kcal' as const, app: 'MyFitnessPal', value: 600 },
  ];
  assert.deepEqual(pickDays(rows, null), [
    { date: '2026-10-01', app: 'MyFitnessPal', values: { energy_kcal: 2100, protein_g: 90 }, otherApps: ['Lose It!'] }, // a tie on energy: more nutrients wins
    { date: '2026-10-02', app: 'Cronometer', values: { energy_kcal: 1800 }, otherApps: ['MyFitnessPal'] },
  ]);
  assert.deepEqual(
    pickDays(rows, 'MyFitnessPal').map((d) => [d.date, d.app]),
    [
      ['2026-10-01', 'MyFitnessPal'],
      ['2026-10-02', 'MyFitnessPal'],
    ],
  );
});

test('what the setting hides never leaves the server', () => {
  const values = { energy_kcal: 2100.26, protein_g: 90.04, alcohol_drinks: 2 };
  assert.deepEqual(shown(values, 'all'), { energy_kcal: 2100.3, protein_g: 90, alcohol_drinks: 2 });
  assert.deepEqual(shown(values, 'no_energy'), { protein_g: 90, alcohol_drinks: 2 });
  assert.deepEqual(shown(values, 'none'), {});
});

test("the iPhone's days validate, and errors name the field, never the value", () => {
  const fail = (p: string, m: string): never => {
    throw new Error(`${p}: ${m}`);
  };
  assert.deepEqual(parseNutritionDay({ date: '2026-10-01', apps: [{ app: ' Cronometer ', values: { energy_kcal: 1800, fiber_g: 31 } }] }, 'n', fail), {
    date: '2026-10-01',
    apps: [{ app: 'Cronometer', values: { energy_kcal: 1800, fiber_g: 31 } }],
  });
  assert.deepEqual(parseNutritionDay({ date: '2026-10-01', apps: [] }, 'n', fail), { date: '2026-10-01', apps: [] }, 'no apps clears the day');
  assert.throws(() => parseNutritionDay({ date: '2026-10-01', apps: [{ app: 'X', values: { vitamin_secret: 3 } }] }, 'n', fail), (e: Error) => /unknown nutrient/.test(e.message) && !e.message.includes('vitamin_secret'));
  assert.throws(() => parseNutritionDay({ date: '2026-10-01', apps: [{ app: 'X', values: { energy_kcal: 2_100_000 } }] }, 'n', fail), /n\.apps\[0\]\.values\.energy_kcal: expected a number from 0 to 30000/);
  assert.throws(() => parseNutritionDay({ date: '2026-10-01', apps: [{ app: 'X', values: { protein_g: -4 } }] }, 'n', fail), /expected a number/);
  assert.throws(() => parseNutritionDay({ date: '2026-02-30', apps: [] }, 'n', fail), /n\.date/);
});

// ---------- Apple Health export ----------

const food = (type: string, app: string, start: string, value: number, unit: string) =>
  `<Record type="HKQuantityTypeIdentifier${type}" sourceName="${app}" unit="${unit}" startDate="${start} -0500" endDate="${start} -0500" value="${value}"/>`;

// MyFitnessPal's breakfast as a Food correlation, with the export's second, top-level copy of each sample; Cronometer's
// loose samples in other units; and a lunch, not in a correlation.
const EXPORT = `<?xml version="1.0" encoding="UTF-8"?>
<HealthData locale="en_US">
 <Correlation type="HKCorrelationTypeIdentifierFood" sourceName="MyFitnessPal" startDate="2026-10-01 08:00:00 -0500" endDate="2026-10-01 08:00:00 -0500">
  <MetadataEntry key="HKFoodType" value="Breakfast"/>
  ${food('DietaryEnergyConsumed', 'MyFitnessPal', '2026-10-01 08:00:00', 500, 'kcal')}
  ${food('DietaryProtein', 'MyFitnessPal', '2026-10-01 08:00:00', 30, 'g')}
 </Correlation>
 ${food('DietaryEnergyConsumed', 'MyFitnessPal', '2026-10-01 08:00:00', 500, 'kcal')}
 ${food('DietaryProtein', 'MyFitnessPal', '2026-10-01 08:00:00', 30, 'g')}
 ${food('DietaryEnergyConsumed', 'MyFitnessPal', '2026-10-01 12:30:00', 700, 'kcal')}
 ${food('DietaryEnergyConsumed', 'Cronometer', '2026-10-01 09:00:00', 4184, 'kJ')}
 ${food('DietarySodium', 'Cronometer', '2026-10-01 09:00:00', 1.2, 'g')}
 ${food('DietaryFiber', 'Cronometer', '2026-10-01 09:00:00', 2500, 'mg')}
 ${food('NumberOfAlcoholicBeverages', 'Cronometer', '2026-10-01 20:00:00', 2, 'count')}
 ${food('DietaryCaffeine', 'MyFitnessPal', '2026-10-01 08:00:00', 95, 'mg')}
 ${food('StepCount', 'iPhone', '2026-10-01 10:00:00', 100, 'count')}
</HealthData>`;

async function importExport(db: Awaited<ReturnType<typeof openStore>>) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'healthos-nutrition-'));
  const file = path.join(dir, 'export.xml');
  fs.writeFileSync(file, EXPORT);
  try {
    await importAppleHealth({ db, userId: OWNER_ID }, file);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

test('the importer keeps food by app, counts a correlated meal once, and only for people who turned nutrition on', async () => {
  const db = await openStore();
  await importExport(db);
  assert.equal((await db.query('SELECT 1 FROM nutrition_daily')).length, 0, 'off: nothing stored');
  assert.equal((await db.query("SELECT 1 FROM daily WHERE metric = 'steps'")).length, 1, 'everything else imports as before');

  await setUserSetting(db, OWNER_ID, 'nutrition', 'on');
  await importExport(db);
  await importExport(db); // a re-import replaces, rather than doubles
  const rows = await db.query<{ nutrient: string; app: string; value: number }>("SELECT nutrient, app, value FROM nutrition_daily WHERE date = '2026-10-01' ORDER BY app, nutrient");
  assert.deepEqual(
    rows.map((r) => `${r.app} ${r.nutrient} ${Math.round(r.value * 100) / 100}`),
    ['Cronometer alcohol_drinks 2', 'Cronometer energy_kcal 1000', 'Cronometer fiber_g 2.5', 'Cronometer sodium_mg 1200', 'MyFitnessPal energy_kcal 1200', 'MyFitnessPal protein_g 30'],
  );
  // Caffeine stays a daily metric, as before, and no nutrient became one.
  assert.equal((await db.query("SELECT value FROM daily WHERE metric = 'caffeine_mg'")).length, 1);
  assert.equal((await db.query("SELECT 1 FROM daily WHERE metric LIKE '%kcal%' OR metric LIKE 'protein%'")).length, 0);

  // Off, a re-import neither reads food nor deletes what was kept, hidden, from before.
  await setUserSetting(db, OWNER_ID, 'nutrition', null);
  await importExport(db);
  assert.equal((await db.query('SELECT 1 FROM nutrition_daily')).length, 6);

  await deleteSource(db, OWNER_ID, 'apple');
  assert.equal((await db.query('SELECT 1 FROM nutrition_daily')).length, 0, 'removing Apple Health data removes its food too');
});

// ---------- over HTTP ----------

process.env.SESSION_SECRET = 'nutrition-test-secret-'.padEnd(64, 'x');
const OWNER_PASSWORD = 'owner password 123';
process.env.HEALTHOS_PASSWORD_HASH = await hashPassword(OWNER_PASSWORD);
const OWNER_INGEST = 'owner-ingest-token-nutrition-0123';

// A fake Claude that records each request and replays scripted replies (see test/mcfly.test.ts).
type Block = { type: 'text'; text: string } | { type: 'tool_use'; id: string; name: string; input: unknown };
const reply = (content: Block[], stop_reason: string) => ({
  id: 'msg_test',
  type: 'message',
  role: 'assistant',
  model: 'claude-opus-5-5',
  content,
  stop_reason,
  stop_sequence: null,
  usage: { input_tokens: 10, output_tokens: 5, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 },
});
let script: ReturnType<typeof reply>[] = [];
const requests: any[] = [];
const fake = {
  beta: {
    messages: {
      stream(params: unknown) {
        requests.push(structuredClone(params));
        const msg = script.shift() ?? reply([{ type: 'text', text: 'OK.' }], 'end_turn');
        let onText: ((t: string) => void) | undefined;
        return {
          on(event: string, fn: (t: string) => void) {
            if (event === 'text') onText = fn;
            return this;
          },
          async finalMessage() {
            for (const b of msg.content) if (b.type === 'text') onText?.(b.text);
            return msg;
          },
          abort() {},
        };
      },
    },
  },
} as unknown as McflyClient;

const db = await openStore();
const app = createApp({ db, hosted: false, ingestToken: OWNER_INGEST, mcflyClient: () => fake });
const server = app.listen(0, '127.0.0.1');
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
  get = (p: string) => this.call('GET', p);
  post = (p: string, b?: unknown) => this.call('POST', p, b ?? {});
  put = (p: string, b: unknown) => this.call('PUT', p, b);
}

const owner = new Client();
const bob = new Client();
let bobId = '';
const today = todayLocal();
const ago = (n: number) => addDays(today, -n);
const ingest = (body: unknown) => owner.call('POST', '/api/apple/ingest', body, { Authorization: `Bearer ${OWNER_INGEST}` });
const week = Array.from({ length: 7 }, (_, i) => ({
  date: ago(6 - i),
  apps: [
    { app: 'MyFitnessPal', values: { energy_kcal: 2000 + i * 10, protein_g: 100 + i, carbs_g: 220, fat_g: 70, fiber_g: 25, alcohol_drinks: i === 5 ? 3 : 0 } },
    ...(i === 6 ? [{ app: 'Lose It!', values: { energy_kcal: 2060 } }] : []),
  ],
}));

test('setup: an owner and an invited member', async () => {
  assert.equal((await owner.post('/api/auth/login', { email: 'owner@example.com', password: OWNER_PASSWORD })).status, 200);
  const inv = await owner.post('/api/admin/invites', {});
  const token = inv.json.url.split('/').at(-1);
  assert.equal((await bob.post('/api/auth/invite', { token, email: 'bob@example.com', name: 'Bob', password: 'bob password 123' })).status, 200);
  bobId = (await bob.get('/api/auth/me')).json.user.id;
});

test('while nutrition is off, the iPhone is told so and its food totals are dropped', async () => {
  const settings = (await owner.get('/api/status')).json.settings;
  assert.deepEqual([settings.nutrition, settings.nutritionNumbers, settings.nutritionApp], [false, null, null]);
  const res = await ingest({ nutrition: week, daily: [{ date: ago(0), metric: 'steps', value: 4000 }] });
  assert.equal(res.status, 200);
  assert.equal(res.json.nutrition, 0);
  assert.equal(res.json.nutritionOn, false);
  assert.ok(res.json.nutrients.includes('energy_kcal'), 'the reply lists what the server accepts');
  assert.equal((await db.query('SELECT 1 FROM nutrition_daily')).length, 0);
  assert.deepEqual((await owner.get('/api/nutrition')).json.days, []);
  assert.equal((await owner.get('/api/nutrition')).json.enabled, false);
});

test('turning it on needs a choice of what to see, and a refused request changes nothing', async () => {
  const refused = await owner.put('/api/settings', { nutrition: true, units: 'imperial' });
  assert.equal(refused.status, 400);
  assert.match(refused.json.error, /Choose what to show/);
  const after = (await owner.get('/api/status')).json.settings;
  assert.deepEqual([after.nutrition, after.units], [false, 'metric']);
  const on = await owner.put('/api/settings', { nutrition: true, nutritionNumbers: 'all' });
  assert.equal(on.status, 200);
  assert.deepEqual([on.json.settings.nutrition, on.json.settings.nutritionNumbers], [true, 'all']);
});

test('once on, pushes are stored, one app a day, and each day sent replaces that day', async () => {
  const res = await ingest({ nutrition: week });
  assert.equal(res.json.nutrition, 7);
  assert.equal(res.json.nutritionOn, true);
  // The sync summary on the Integrations page leaves the count out.
  assert.equal((await owner.get('/api/status')).json.apple.lastSync.nutrition, undefined);

  let view: NutritionData = (await owner.get('/api/nutrition?days=7')).json;
  assert.equal(view.enabled, true);
  assert.equal(view.days.length, 7);
  assert.deepEqual(view.days.at(-1), { date: today, app: 'MyFitnessPal', values: { energy_kcal: 2060, protein_g: 106, carbs_g: 220, fat_g: 70, fiber_g: 25, alcohol_drinks: 0 }, otherApps: ['Lose It!'] });
  assert.deepEqual(view.apps, ['MyFitnessPal', 'Lose It!']);

  // A day sent again is that day's whole set: here, Lose It!'s entry was deleted in Health.
  await ingest({ nutrition: [{ date: today, apps: [{ app: 'MyFitnessPal', values: { energy_kcal: 2100 } }] }] });
  view = (await owner.get('/api/nutrition?days=7')).json;
  assert.deepEqual(view.days.at(-1), { date: today, app: 'MyFitnessPal', values: { energy_kcal: 2100 }, otherApps: [] });
  await ingest({ nutrition: [{ date: today, apps: [] }] });
  assert.equal((await owner.get('/api/nutrition?days=7')).json.days.length, 6, 'a day with no apps is cleared');

  const bad = await ingest({ nutrition: [{ date: today, apps: [{ app: 'MyFitnessPal', values: { energy_kcal: 'lots' } }] }] });
  assert.equal(bad.status, 400);
  assert.match(bad.json.error, /^nutrition\[0\]\.apps\[0\]\.values\.energy_kcal/);
});

test('the chosen app wins on days two apps logged', async () => {
  await ingest({ nutrition: [{ date: today, apps: [{ app: 'MyFitnessPal', values: { energy_kcal: 2100 } }, { app: 'Lose It!', values: { energy_kcal: 1500, protein_g: 80 } }] }] });
  assert.equal((await owner.get('/api/nutrition')).json.days.at(-1).app, 'MyFitnessPal');
  await owner.put('/api/settings', { nutritionApp: 'Lose It!' });
  const view: NutritionData = (await owner.get('/api/nutrition')).json;
  assert.equal(view.app, 'Lose It!');
  assert.deepEqual(view.days.at(-1), { date: today, app: 'Lose It!', values: { energy_kcal: 1500, protein_g: 80 }, otherApps: ['MyFitnessPal'] });
  assert.equal(view.days.at(-2)?.app, 'MyFitnessPal', 'days the chosen app missed use the other');
  await owner.put('/api/settings', { nutritionApp: null });
});

test("personal targets are the person's own, blank by default, and shown only as far as their setting allows", async () => {
  const settings = async () => (await owner.get('/api/status')).json.settings;
  assert.deepEqual((await settings()).nutritionTargets, { energy_kcal: null, protein_g: null, water_ml: null });
  assert.deepEqual((await owner.get('/api/nutrition')).json.targets, {}, 'none unless set');
  await owner.put('/api/settings', { nutritionTargets: { energy_kcal: 2200, protein_g: 120, water_ml: 2000 } });
  // One left out stays, null clears one, and a value out of range is ignored.
  await owner.put('/api/settings', { nutritionTargets: { protein_g: 5000, water_ml: null } });
  assert.deepEqual((await settings()).nutritionTargets, { energy_kcal: 2200, protein_g: 120, water_ml: null });
  await owner.put('/api/settings', { nutritionTargets: { water_ml: 2000 } });
  assert.deepEqual((await owner.get('/api/nutrition')).json.targets, { energy_kcal: 2200, protein_g: 120, water_ml: 2000 });
  await owner.put('/api/settings', { nutritionNumbers: 'no_energy' });
  assert.deepEqual((await owner.get('/api/nutrition')).json.targets, { protein_g: 120, water_ml: 2000 });
  await owner.put('/api/settings', { nutritionNumbers: 'none' });
  assert.deepEqual((await owner.get('/api/nutrition')).json.targets, {});
  await owner.put('/api/settings', { nutritionNumbers: 'all' });
});

test('water and caffeine come from the daily metrics as before, and "no amounts" hides them too', async () => {
  await ingest({ daily: [{ date: today, metric: 'water_ml', value: 1750 }, { date: today, metric: 'caffeine_mg', value: 180 }] });
  const view: NutritionData = (await owner.get('/api/nutrition?days=7')).json;
  assert.deepEqual(view.hydration.water.at(-1), { date: today, value: 1750 });
  assert.deepEqual(view.hydration.caffeine.at(-1), { date: today, value: 180 });
  await owner.put('/api/settings', { nutritionNumbers: 'none' });
  const none: NutritionData = (await owner.get('/api/nutrition?days=7&insights=1')).json;
  assert.deepEqual([none.hydration, none.insights], [{ water: [], caffeine: [] }, []]);
  assert.ok(!JSON.stringify(none).includes('1750'));
  await owner.put('/api/settings', { nutritionNumbers: 'all' });
});

test('drinks and next-morning HRV is a food insight on the Nutrition page, and nowhere else', async () => {
  // Five weeks before the test week: food logged every day, 3 drinks every other day, and a lower HRV the next morning.
  const days = Array.from({ length: 38 }, (_, i) => ago(44 - i));
  await ingest({
    nutrition: days.map((date, i) => ({ date, apps: [{ app: 'MyFitnessPal', values: { energy_kcal: 2000, ...(i % 2 ? {} : { alcohol_drinks: 3 }) } }] })),
    daily: days.map((date, i) => ({ date: addDays(date, 1), metric: 'hrv_sdnn', value: (i % 2 ? 55 : 40) + (i % 5) })),
  });
  const view: NutritionData = (await owner.get('/api/nutrition?days=14&insights=1')).json;
  const drinks = view.insights.find((p) => p.id === 'alcohol_hrv');
  assert.ok(drinks, 'found');
  assert.match(drinks.text, /^After days with 2 or more drinks, your next-morning HRV tends to be \d+% below what it is after days with none\.$/);
  assert.ok(view.insights.every((p) => p.id === 'caffeine_sleep' || p.id === 'alcohol_hrv'));
  assert.deepEqual((await owner.get('/api/nutrition?days=14')).json.insights, [], 'only when asked for');
  const general = (await owner.get('/api/patterns')).text;
  for (const word of ['alcohol', 'drinks']) assert.ok(!general.includes(word), word);
});

test('"no calories" and "no amounts" hold everywhere the data goes', async () => {
  await owner.put('/api/settings', { nutritionNumbers: 'no_energy' });
  let text = (await owner.get('/api/nutrition')).text;
  assert.ok(!text.includes('energy_kcal'));
  assert.ok(text.includes('protein_g'));
  await owner.put('/api/settings', { nutritionNumbers: 'none' });
  const view: NutritionData = (await owner.get('/api/nutrition')).json;
  assert.ok(view.days.length > 0, 'the logged days still show');
  assert.ok(view.days.every((d) => Object.keys(d.values).length === 0));
  text = JSON.stringify(view);
  for (const n of ['energy_kcal', 'protein_g', '2100', '1500']) assert.ok(!text.includes(n), n);
  await owner.put('/api/settings', { nutritionNumbers: 'all' });
});

test("nobody else sees it: not another member, not the summary, the admin view or the Family board", async () => {
  const theirs: NutritionData = (await bob.get('/api/nutrition')).json;
  assert.equal(theirs.enabled, false);
  await bob.put('/api/settings', { nutrition: true, nutritionNumbers: 'all' });
  assert.deepEqual((await bob.get('/api/nutrition')).json.days, []);

  for (const p of ['/api/summary', '/api/trends?metrics=steps,weight', '/api/patterns', '/api/admin/overview', '/api/family']) {
    const text = (await owner.get(p)).text;
    for (const word of ['MyFitnessPal', 'Lose It', 'energy_kcal', 'protein_g', 'alcohol', 'nutrition']) assert.ok(!text.includes(word), `${p}: ${word}`);
  }
  const bobsBoard = (await bob.get('/api/family')).text;
  for (const word of ['MyFitnessPal', 'energy_kcal', 'protein', 'nutrition']) assert.ok(!bobsBoard.includes(word), word);
});

test("Nutrition's cards can be hidden by the person, and are invisible to and untouchable by an admin", async () => {
  // Bob hides one Nutrition card and one Home card for himself.
  const mine = await bob.put('/api/settings', { hiddenCards: ['home.hrv', 'nutrition.energy'] });
  assert.deepEqual(mine.json.settings.hiddenCards, ['home.hrv', 'nutrition.energy']);
  const bobRow = async () => (await owner.get('/api/admin/overview')).json.users.find((u: { id: string }) => u.id === bobId);
  // The admin screens see only the Home card, so they can't tell Bob uses Nutrition.
  assert.deepEqual((await bobRow()).hiddenCards, ['home.hrv']);
  // An admin can't set a Nutrition card, either way it's sent, and gets the same answer as for an unknown card.
  for (const body of [{ hiddenCards: ['nutrition.water'] }, { cardShown: { id: 'nutrition.energy', shown: true } }]) {
    const res = await owner.call('PATCH', `/api/admin/users/${bobId}`, body);
    assert.equal(res.status, 400);
    assert.match(res.json.error, /Unknown card/);
  }
  // "Show all" from the admin screens clears the cards it can see and keeps the ones it can't.
  const shown = await owner.call('PATCH', `/api/admin/users/${bobId}`, { hiddenCards: [] });
  assert.deepEqual(shown.json.hiddenCards, []);
  assert.deepEqual((await bob.get('/api/status')).json.settings.hiddenCards, ['nutrition.energy']);
  await bob.put('/api/settings', { hiddenCards: [] });
});

test('Ask McFly gets the nutrition tool only while it is on, and only what the setting shows', async () => {
  requests.length = 0;
  script = [
    reply([{ type: 'tool_use', id: 'tu_1', name: 'get_nutrition', input: { days: 7 } }], 'tool_use'),
    reply([{ type: 'text', text: 'You logged six days.' }], 'end_turn'),
  ];
  assert.equal((await owner.post('/api/mcfly/chat', { messages: [{ role: 'user', content: 'How was my protein?' }] })).status, 200);
  assert.ok(requests[0].tools.some((t: { name: string }) => t.name === 'get_nutrition'));
  assert.match(requests[0].system, /get_nutrition reads it/);
  assert.match(requests[0].system, /no calorie, weight or macro targets/);
  let result = JSON.parse(requests[1].messages.at(-1).content[0].content);
  assert.equal(result.daysLogged, 7);
  assert.equal(result.days.at(-1).values.protein_g, undefined, 'Lose It! had none; MyFitnessPal won the day');
  assert.ok(result.days.some((d: { values: Record<string, number> }) => d.values.energy_kcal), 'everything shown in "all"');

  await owner.put('/api/settings', { nutritionNumbers: 'no_energy' });
  requests.length = 0;
  script = [reply([{ type: 'tool_use', id: 'tu_2', name: 'get_nutrition', input: {} }], 'tool_use'), reply([{ type: 'text', text: 'OK.' }], 'end_turn')];
  await owner.post('/api/mcfly/chat', { messages: [{ role: 'user', content: 'How many calories did I eat?' }] });
  assert.match(requests[0].system, /never state, estimate or compute energy or calories/);
  result = requests[1].messages.at(-1).content[0].content;
  assert.ok(!result.includes('energy_kcal'));

  await owner.put('/api/settings', { nutritionNumbers: 'none' });
  requests.length = 0;
  script = [reply([{ type: 'tool_use', id: 'tu_3', name: 'get_nutrition', input: {} }], 'tool_use'), reply([{ type: 'text', text: 'OK.' }], 'end_turn')];
  await owner.post('/api/mcfly/chat', { messages: [{ role: 'user', content: 'How much did I eat?' }] });
  result = requests[1].messages.at(-1).content[0].content;
  for (const n of ['energy_kcal', 'protein_g', 'carbs_g', 'values']) assert.ok(!result.includes(n), n);
  assert.match(result, /daysLogged/);

  await owner.put('/api/settings', { nutrition: false });
  requests.length = 0;
  script = [reply([{ type: 'tool_use', id: 'tu_4', name: 'get_nutrition', input: {} }], 'tool_use'), reply([{ type: 'text', text: 'OK.' }], 'end_turn')];
  await owner.post('/api/mcfly/chat', { messages: [{ role: 'user', content: 'Read my food log.' }] });
  assert.ok(!requests[0].tools.some((t: { name: string }) => t.name === 'get_nutrition'));
  assert.doesNotMatch(requests[0].system, /get_nutrition/);
  const refused = requests[1].messages.at(-1).content[0];
  assert.equal(refused.is_error, true);
  assert.match(refused.content, /Unknown tool/);
});

test('off hides what is stored; delete removes all of it, for that person only; an account deletion takes it too', async () => {
  assert.equal((await owner.get('/api/nutrition')).json.enabled, false);
  assert.ok((await db.query('SELECT 1 FROM nutrition_daily WHERE user_id = $1', [OWNER_ID])).length > 0, 'off keeps it, hidden');
  assert.equal((await ingest({ nutrition: week })).json.nutrition, 0, 'and stores no more');

  const deleted = await owner.post('/api/nutrition/delete');
  assert.equal(deleted.status, 200);
  assert.ok(deleted.json.deleted > 0);
  assert.equal((await db.query('SELECT 1 FROM nutrition_daily WHERE user_id = $1', [OWNER_ID])).length, 0);

  // Bob's own push, with his own token this time, and then his account goes.
  const token = (await bob.post('/api/me/ingest-token')).json.token;
  await bob.call('POST', '/api/apple/ingest', { nutrition: [{ date: today, apps: [{ app: 'Yazio', values: { energy_kcal: 1900 } }] }] }, { Authorization: `Bearer ${token}` });
  assert.equal((await db.query('SELECT 1 FROM nutrition_daily WHERE user_id = $1', [bobId])).length, 1);
  assert.equal((await owner.call('DELETE', `/api/admin/users/${bobId}`)).status, 200);
  assert.equal((await db.query('SELECT 1 FROM nutrition_daily')).length, 0);
});
