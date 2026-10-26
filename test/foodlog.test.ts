// The food log: entries made in healthOS (quick add, a food database, a barcode, McFly's estimate), counted as one
// more app among the Health apps, filtered by the person's numbers setting, and only while Nutrition is on (see
// server/foodlog.ts, server/foods.ts, server/estimate.ts). No test here calls USDA, Open Food Facts or Claude.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import type { AddressInfo } from 'node:net';
import type { FoodEntry, FoodLog, FoodSearch, NutritionData } from '../shared/types.ts';
import { importAppleHealth } from '../server/apple/import.ts';
import { createApp } from '../server/app.ts';
import { hashPassword } from '../server/auth.ts';
import { todayLocal } from '../server/dates.ts';
import { OWNER_ID, setUserSetting } from '../server/db.ts';
import { parseEstimateInput, readEstimate } from '../server/estimate.ts';
import { gtin14, offCode, offFood, usdaFood } from '../server/foods.ts';
import type { McflyClient } from '../server/mcfly.ts';
import { pickDays } from '../server/nutrition.ts';
import { openStore } from '../server/store.ts';

// ---------- the food databases, mapped ----------

const nutrient = (nutrientId: number, unitName: string, value: number) => ({ nutrientId, unitName, value });

const FNDDS = {
  fdcId: 2705441,
  description: 'Yogurt, Greek, with oats',
  dataType: 'Survey (FNDDS)',
  foodMeasures: [
    { disseminationText: '1 cup', gramWeight: 245, rank: 3 },
    { disseminationText: '1 container, NFS', gramWeight: 150, rank: 2 },
    { disseminationText: 'Quantity not specified', gramWeight: 150, rank: 1 },
  ],
  foodNutrients: [nutrient(1008, 'KCAL', 149), nutrient(1003, 'G', 9.22), nutrient(1005, 'G', 20.02), nutrient(1004, 'G', 3.67), nutrient(1093, 'MG', 58), nutrient(1018, 'G', 0), nutrient(1051, 'G', 66)],
};
const BRANDED = {
  fdcId: 2057648,
  description: 'CHEDDAR CHEESE',
  dataType: 'Branded',
  brandName: 'GRAFTON VILLAGE',
  gtinUpc: '094395000172',
  servingSize: 28,
  servingSizeUnit: 'g',
  householdServingFullText: '1 ONZ',
  foodNutrients: [nutrient(1008, 'KCAL', 393), nutrient(1003, 'G', 21.4), nutrient(1258, 'G', 21.4), nutrient(1093, 'MG', 679)],
};
const NUTELLA = {
  code: '3017620422003',
  product_name: 'Nutella',
  brands: 'Ferrero, Nutella',
  serving_size: '15 g',
  serving_quantity: 15,
  quantity: '400 g',
  nutriments: { 'energy-kcal_100g': 539, proteins_100g: 6.3, carbohydrates_100g: 57.5, fat_100g: 30.9, sugars_100g: 56.3, 'saturated-fat_100g': 10.6, sodium_100g: 0.0428 },
};

test('USDA foods: per 100 g, portions from the survey measures or the label serving, names tidied', () => {
  const yogurt = usdaFood(FNDDS)!;
  assert.equal(yogurt.ref, 'fdc:2705441');
  assert.deepEqual(yogurt.per100, { energy_kcal: 149, protein_g: 9.22, carbs_g: 20.02, fat_g: 3.67, sodium_mg: 58 }, 'no alcohol when there is none; food moisture is not drinking water');
  assert.deepEqual(
    yogurt.portions.map((p) => p.label),
    ['1 container, NFS (150 g)', '1 cup (245 g)', '100 g', '1 oz (28.35 g)'],
    'by rank, without "quantity not specified"',
  );
  const cheese = usdaFood(BRANDED)!;
  assert.equal(cheese.name, 'Cheddar cheese');
  assert.equal(cheese.brand, 'Grafton village');
  assert.deepEqual(cheese.portions[0], { label: '1 onz (28 g)', grams: 28 });
  // Foundation foods may give energy only as Atwater energy.
  assert.equal(usdaFood({ fdcId: 1, description: 'Kale', dataType: 'Foundation', foodNutrients: [nutrient(2047, 'KCAL', 43)] })!.per100.energy_kcal, 43);
  // A unit mix-up (kJ in the kcal field) is dropped rather than shown as 1800 kcal per 100 g.
  assert.equal(usdaFood({ fdcId: 2, description: 'X', foodNutrients: [nutrient(1008, 'KCAL', 1800), nutrient(1003, 'G', 3)] })!.per100.energy_kcal, undefined);
  assert.equal(usdaFood({ fdcId: 3, description: 'Nothing', foodNutrients: [] }), null);
});

test('Open Food Facts products: sodium in mg, alcohol by volume as drinks, the label serving first', () => {
  const nutella = offFood(NUTELLA)!;
  assert.equal(nutella.ref, 'off:3017620422003');
  assert.equal(nutella.brand, 'Ferrero');
  assert.equal(Math.round(nutella.per100.sodium_mg!), 43);
  assert.deepEqual(nutella.portions, [
    { label: '1 serving (15 g)', grams: 15 },
    { label: '100 g', grams: 100 },
  ]);
  const beer = offFood({ code: '5410228142218', product_name: 'Lager', quantity: '330 ml', serving_quantity: 330, serving_size: 'Can', nutriments: { 'energy-kcal_100g': 42, alcohol_100g: 5.2 } })!;
  assert.equal(beer.portions[0].label, 'Can (330 mL)');
  // 330 mL at 5.2% is 13.5 g of alcohol: about one standard drink.
  assert.equal(Math.round(((beer.per100.alcohol_drinks! * 330) / 100) * 100) / 100, 0.97);
  assert.equal(offFood({ code: '1', product_name: 'Empty', nutriments: {} }), null);
});

test('barcodes pad to GTIN-14 and look up in the form each database lists them', () => {
  assert.equal(gtin14('094395000172'), '00094395000172');
  assert.equal(gtin14('3017620422003'), '03017620422003');
  assert.equal(gtin14('96385074'), '00000096385074');
  assert.equal(gtin14('12345'), null);
  assert.equal(offCode('03017620422003'), '3017620422003');
  assert.equal(offCode('00094395000172'), '0094395000172');
  assert.equal(offCode('00000096385074'), '96385074');
});

test("McFly's answer is checked: names trimmed, amounts in range, nulls left out, at most 15 items", () => {
  const { items, note } = readEstimate(
    JSON.stringify({
      items: [
        { name: '  Pasta  with pesto ', portion: '1 plate (300 g)', energy_kcal: 620, protein_g: 18, carbs_g: 80, fat_g: 24, fiber_g: null, sugar_g: 4, sat_fat_g: null, sodium_mg: 700, alcohol_drinks: 0, water_ml: null },
        { name: 'Wine', portion: '1 glass (150 mL)', energy_kcal: 9e9, protein_g: -3, carbs_g: 4, fat_g: 0, fiber_g: null, sugar_g: null, sat_fat_g: null, sodium_mg: null, alcohol_drinks: 1, water_ml: null },
        { name: '', portion: '', energy_kcal: 1, protein_g: 1, carbs_g: 1, fat_g: 1, fiber_g: 1, sugar_g: 1, sat_fat_g: 1, sodium_mg: 1, alcohol_drinks: 0, water_ml: 1 },
      ],
      note: 'Assumed a tablespoon of olive oil.',
    }),
  );
  assert.equal(note, 'Assumed a tablespoon of olive oil.');
  assert.deepEqual(items[0], { name: 'Pasta with pesto', portion: '1 plate (300 g)', values: { energy_kcal: 620, protein_g: 18, carbs_g: 80, fat_g: 24, sugar_g: 4, sodium_mg: 700 } });
  assert.deepEqual(items[1].values, { energy_kcal: 30_000, carbs_g: 4, fat_g: 0, alcohol_drinks: 1 }, 'clamped to the ceiling; a negative dropped');
  assert.equal(items.length, 2, 'an item without a name is dropped');
  assert.equal(readEstimate(JSON.stringify({ items: Array.from({ length: 30 }, () => ({ name: 'x' })), note: '' })).items.length, 15);
});

const jpeg = Buffer.concat([Buffer.from([0xff, 0xd8, 0xff, 0xe0]), Buffer.alloc(64)]);
const png = Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), Buffer.alloc(64)]);

test('a photo must be what it says it is, and something must be sent', () => {
  assert.deepEqual(parseEstimateInput({ description: '  two eggs ', image: null }), { description: 'two eggs', image: null });
  assert.equal(parseEstimateInput({ image: { mediaType: 'image/jpeg', data: jpeg.toString('base64') } }).image?.mediaType, 'image/jpeg');
  assert.throws(() => parseEstimateInput({ image: { mediaType: 'image/jpeg', data: png.toString('base64') } }), /couldn't be read/);
  assert.throws(() => parseEstimateInput({ image: { mediaType: 'image/heic', data: jpeg.toString('base64') } }), /JPEG, PNG or WebP/);
  assert.throws(() => parseEstimateInput({}), /Add a photo or describe/);
  assert.throws(() => parseEstimateInput({ description: 'x'.repeat(1001) }), /under 1000/);
});

test("healthOS's log is one more app on a day, never added on top: an app that copied it from Health doesn't double it", () => {
  const rows = [
    { date: '2026-10-01', nutrient: 'energy_kcal' as const, app: 'healthOS', value: 650 },
    { date: '2026-10-01', nutrient: 'protein_g' as const, app: 'healthOS', value: 30 },
    // MacroFactor read healthOS's entries from Health into its own log.
    { date: '2026-10-01', nutrient: 'energy_kcal' as const, app: 'MacroFactor', value: 650 },
  ];
  assert.deepEqual(pickDays(rows, null), [{ date: '2026-10-01', app: 'healthOS', values: { energy_kcal: 650, protein_g: 30 }, otherApps: ['MacroFactor'] }]);
});

// ---------- the export importer ----------

test("the importer skips food healthOS itself wrote to Health, but not other apps' food or healthOS's other data", async () => {
  const db = await openStore();
  await setUserSetting(db, OWNER_ID, 'nutrition', 'on');
  const rec = (type: string, app: string, value: number, unit: string) =>
    `<Record type="HKQuantityTypeIdentifier${type}" sourceName="${app}" unit="${unit}" startDate="2026-10-01 12:00:00 -0500" endDate="2026-10-01 12:00:00 -0500" value="${value}"/>`;
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'healthos-foodlog-'));
  const file = path.join(dir, 'export.xml');
  fs.writeFileSync(
    file,
    `<?xml version="1.0" encoding="UTF-8"?><HealthData locale="en_US">
     ${rec('DietaryEnergyConsumed', 'healthOS', 650, 'kcal')}
     ${rec('DietaryWater', 'healthOS', 500, 'mL')}
     ${rec('DietaryEnergyConsumed', 'Cronometer', 900, 'kcal')}
     ${rec('DietaryWater', 'WaterMinder', 250, 'mL')}
     ${rec('StepCount', 'healthOS', 10, 'count')}
     </HealthData>`,
  );
  try {
    await importAppleHealth({ db, userId: OWNER_ID }, file);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
  assert.deepEqual((await db.query<{ app: string }>('SELECT app FROM nutrition_daily')).map((r) => r.app), ['Cronometer']);
  assert.deepEqual((await db.query<{ value: number }>("SELECT value FROM daily WHERE metric = 'water_ml'")).map((r) => Number(r.value)), [250]);
  assert.equal((await db.query("SELECT 1 FROM daily WHERE metric = 'steps'")).length, 1);
});

// ---------- over HTTP ----------

process.env.SESSION_SECRET = 'foodlog-test-secret-'.padEnd(64, 'x');
const OWNER_PASSWORD = 'owner password 123';
process.env.HEALTHOS_PASSWORD_HASH = await hashPassword(OWNER_PASSWORD);
const OWNER_INGEST = 'owner-ingest-token-foodlog-01234';
const FDC_KEY = 'fdc-test-key-never-in-a-url';
process.env.FDC_API_KEY = FDC_KEY;

// Fake food databases: every call is recorded.
const calls: { url: string; init?: RequestInit }[] = [];
let offDown = false;
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
async function fakeFetch(url: string, init?: RequestInit) {
  calls.push({ url, init });
  if (url.startsWith('https://api.nal.usda.gov/fdc/v1/foods/search')) {
    const body = JSON.parse(String(init?.body)) as { query: string; dataType: string[] };
    if (body.dataType.length === 1 && body.dataType[0] === 'Branded') return json({ foods: body.query === '094395000172' ? [BRANDED] : [] });
    return json({ foods: body.query === 'greek yogurt' ? [FNDDS, BRANDED] : [] });
  }
  if (url.startsWith('https://search.openfoodfacts.org/search')) return offDown ? json({}, 503) : json({ hits: [NUTELLA] });
  if (url.startsWith('https://world.openfoodfacts.org/api/v3/product/')) {
    if (offDown) return json({}, 503);
    return url.includes('/3017620422003?') ? json({ code: NUTELLA.code, product: NUTELLA }) : json({ status: 'failure' }, 404);
  }
  throw new Error(`unexpected fetch ${url}`);
}

// A fake Claude for estimates: records each request, replays scripted answers or failures.
type Answer = { text?: string; stop_reason?: string; error?: Error };
let answers: Answer[] = [];
const claude: any[] = [];
const fake = {
  beta: {
    messages: {
      async create(params: unknown) {
        claude.push(structuredClone(params));
        const a = answers.shift() ?? { text: JSON.stringify({ items: [], note: '' }) };
        if (a.error) throw a.error;
        return {
          id: 'msg_test',
          type: 'message',
          role: 'assistant',
          model: 'claude-opus-5-5',
          content: [{ type: 'text', text: a.text ?? '' }],
          stop_reason: a.stop_reason ?? 'end_turn',
          stop_sequence: null,
          usage: { input_tokens: 1200, output_tokens: 300, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 },
        };
      },
    },
  },
} as unknown as McflyClient;

const db = await openStore();
const app = createApp({ db, hosted: false, ingestToken: OWNER_INGEST, mcflyClient: () => fake, foodFetch: fakeFetch });
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
    let parsed: any = null;
    try {
      parsed = JSON.parse(text);
    } catch {
      parsed = null;
    }
    return { status: res.status, text, json: parsed };
  }
  get = (p: string) => this.call('GET', p);
  post = (p: string, b?: unknown) => this.call('POST', p, b ?? {});
  put = (p: string, b: unknown) => this.call('PUT', p, b);
  patch = (p: string, b: unknown) => this.call('PATCH', p, b);
  del = (p: string) => this.call('DELETE', p);
}

const owner = new Client();
const bob = new Client();
let bobId = '';
const today = todayLocal();
const ingest = (body: unknown) => owner.call('POST', '/api/apple/ingest', body, { Authorization: `Bearer ${OWNER_INGEST}` });
const logOf = async (c: Client) => (await c.get('/api/nutrition/log')).json as FoodLog;
const todayIn = async (c: Client) => ((await c.get('/api/nutrition')).json as NutritionData).days.find((d) => d.date === today);
const usage = async () => Number((await db.query<{ questions: number }>('SELECT questions FROM mcfly_usage WHERE user_id = $1', [OWNER_ID]))[0]?.questions ?? 0);

test('setup: an owner and an invited member', async () => {
  assert.equal((await owner.post('/api/auth/login', { email: 'owner@example.com', password: OWNER_PASSWORD })).status, 200);
  const inv = await owner.post('/api/admin/invites', {});
  const token = inv.json.url.split('/').at(-1);
  assert.equal((await bob.post('/api/auth/invite', { token, email: 'bob@example.com', name: 'Bob', password: 'bob password 123' })).status, 200);
  bobId = (await bob.get('/api/auth/me')).json.user.id;
});

test('while Nutrition is off nothing can be logged, looked up or estimated, and nothing is called', async () => {
  const log = await logOf(owner);
  assert.equal(log.enabled, false);
  assert.deepEqual(log.can, { estimate: true, usda: true, estimateProvider: 'anthropic', estimateSource: 'shared', voice: Boolean(process.env.OPENAI_API_KEY) });
  for (const [p, body] of [
    ['/api/nutrition/log', { method: 'quick', values: { energy_kcal: 300 } }],
    ['/api/nutrition/foods/search', { query: 'greek yogurt' }],
    ['/api/nutrition/foods/barcode', { code: '3017620422003' }],
    ['/api/nutrition/estimate', { description: 'two eggs' }],
  ] as const) {
    const res = await owner.post(p, body);
    assert.equal(res.status, 409, p);
    assert.match(res.json.error, /Turn on Nutrition/);
  }
  assert.equal(calls.length + claude.length, 0);
  assert.equal((await db.query('SELECT 1 FROM food_log')).length, 0);
});

let quickId = '';

test('quick add: typed amounts for one portion, water on its own as "Water", into the day as healthOS', async () => {
  assert.equal((await owner.put('/api/settings', { nutrition: true, nutritionNumbers: 'all' })).status, 200);
  const added = await owner.post('/api/nutrition/log', { method: 'quick', name: 'Toast and eggs', values: { energy_kcal: 420, protein_g: 22, carbs_g: 30, fat_g: 21 }, time: '08:15' });
  assert.equal(added.status, 201);
  const entry = added.json as FoodEntry;
  quickId = entry.id;
  assert.deepEqual([entry.date, entry.time, entry.name, entry.method, entry.origin, entry.version], [today, '08:15', 'Toast and eggs', 'quick', 'web', 1]);
  assert.deepEqual(entry.values, { energy_kcal: 420, protein_g: 22, carbs_g: 30, fat_g: 21 });

  const water = await owner.post('/api/nutrition/log', { method: 'quick', values: { water_ml: 500 }, origin: 'iphone', id: '3f1d2c4b-5a6e-4f70-8a9b-0c1d2e3f4a5b' });
  assert.deepEqual([water.json.name, water.json.origin], ['Water', 'iphone']);
  // The iPhone resending the same id after a dropped reply changes nothing.
  await owner.post('/api/nutrition/log', { method: 'quick', values: { water_ml: 500 }, origin: 'iphone', id: '3f1d2c4b-5a6e-4f70-8a9b-0c1d2e3f4a5b' });
  assert.equal((await logOf(owner)).entries.length, 2);

  const day = (await todayIn(owner))!;
  assert.deepEqual([day.app, day.values], ['healthOS', { energy_kcal: 420, protein_g: 22, carbs_g: 30, fat_g: 21 }]);
  const n = (await owner.get('/api/nutrition')).json as NutritionData;
  assert.equal(n.hydration.water.find((p) => p.date === today)?.value, 500, 'water joins Hydration');
  assert.ok(n.apps.includes('healthOS'));
});

test('what is sent is checked, and the message never quotes it', async () => {
  for (const [body, message] of [
    [{ method: 'quick', values: {} }, /at least one amount/],
    [{ method: 'quick', values: { energy_kcal: 99_999 } }, /from 0 to 30,000/],
    [{ method: 'quick', values: { vitamin_q: 3 } }, /Unknown amount/],
    [{ method: 'quick', values: { energy_kcal: 1 }, date: '2999-01-01' }, /last year/],
    [{ method: 'quick', values: { energy_kcal: 1 }, time: '25:00' }, /Choose a time/],
    [{ method: 'quick', values: { energy_kcal: 1 }, quantity: 0 }, /above 0/],
    [{ method: 'estimate', values: { energy_kcal: 1 } }, /quick, search or barcode/],
    [{ method: 'search', ref: 'fdc:999' }, /no longer available/],
  ] as const) {
    const res = await owner.post('/api/nutrition/log', body);
    assert.equal(res.status, 400, JSON.stringify(body));
    assert.match(res.json.error, message);
    assert.ok(!res.text.includes('99999') && !res.text.includes('vitamin_q'));
  }
});

test('a Health app that copied the log is not added on top; healthOS rows from Health are dropped as its own copies', async () => {
  const res = await ingest({
    nutrition: [
      {
        date: today,
        apps: [
          { app: 'MacroFactor', values: { energy_kcal: 420 } },
          { app: 'healthOS', values: { energy_kcal: 420, protein_g: 22 } },
        ],
      },
    ],
  });
  assert.equal(res.status, 200);
  assert.deepEqual((await db.query<{ app: string }>('SELECT DISTINCT app FROM nutrition_daily')).map((r) => r.app), ['MacroFactor']);
  const day = (await todayIn(owner))!;
  assert.deepEqual([day.app, day.values.energy_kcal, day.otherApps], ['healthOS', 420, ['MacroFactor']]);
});

test('search: both databases from the server, the words in a body, the USDA key in a header, never a URL', async () => {
  calls.length = 0;
  const res = await owner.post('/api/nutrition/foods/search', { query: '  greek   yogurt ' });
  assert.equal(res.status, 200);
  const found = res.json as FoodSearch;
  assert.deepEqual(found.results.map((r) => r.ref), ['fdc:2705441', 'fdc:2057648', 'off:3017620422003']);
  assert.deepEqual(found.notes, []);
  const yogurt = found.results[0];
  assert.deepEqual(yogurt.portions[0], { label: '1 container, NFS (150 g)', values: { energy_kcal: 223.5, protein_g: 13.8, carbs_g: 30, fat_g: 5.5, sodium_mg: 87 } });
  const usda = calls.find((c) => c.url.includes('nal.usda.gov'))!;
  assert.equal((usda.init?.headers as Record<string, string>)['X-Api-Key'], FDC_KEY);
  assert.ok(calls.every((c) => !c.url.includes(FDC_KEY)), 'the key is never in a URL');
  const off = calls.find((c) => c.url.includes('openfoodfacts'))!;
  assert.match((off.init?.headers as Record<string, string>)['User-Agent'], /^healthOS\//);
  assert.ok(!res.text.includes(FDC_KEY));

  // The same words again come from this server's memory of the results.
  calls.length = 0;
  assert.equal((await owner.post('/api/nutrition/foods/search', { query: 'Greek yogurt' })).json.results.length, 3);
  assert.equal(calls.length, 0);
  // Nothing anywhere keeps the words.
  assert.equal((await db.query("SELECT 1 FROM food_cache WHERE data LIKE '%greek yogurt%' OR ref LIKE '%greek%'")).length, 0);
});

test('saving a database food by its ref and portion: the server works out the amounts', async () => {
  const res = await owner.post('/api/nutrition/log', { method: 'search', ref: 'fdc:2705441', portionIndex: 1, quantity: 0.5, time: '12:00' });
  assert.equal(res.status, 201);
  assert.deepEqual([res.json.name, res.json.portion, res.json.quantity, res.json.ref], ['Yogurt, Greek, with oats', '1 cup (245 g)', 0.5, 'fdc:2705441']);
  assert.equal(res.json.values.energy_kcal, 182.5);
  assert.equal((await owner.post('/api/nutrition/log', { method: 'search', ref: 'fdc:2705441', portionIndex: 9 })).status, 400);
});

test('barcodes: Open Food Facts first, then USDA branded foods; a found code is remembered; a code typed in search works too', async () => {
  calls.length = 0;
  const nutella = await owner.post('/api/nutrition/foods/barcode', { code: '3017620422003' });
  assert.deepEqual(nutella.json.results.map((r: { ref: string }) => r.ref), ['off:3017620422003']);
  assert.equal(calls.length, 1);
  calls.length = 0;
  assert.equal((await owner.post('/api/nutrition/foods/barcode', { code: '3017620422003' })).json.results.length, 1);
  assert.equal(calls.length, 0, 'the second scan needs no network');

  const cheese = await owner.post('/api/nutrition/foods/search', { query: '094395000172' });
  assert.deepEqual(cheese.json.results.map((r: { ref: string }) => r.ref), ['fdc:2057648'], 'not in Open Food Facts, found in USDA');

  const missing = await owner.post('/api/nutrition/foods/barcode', { code: '0000000000000' });
  assert.deepEqual([missing.status, missing.json.results], [200, []]);
  assert.equal((await owner.post('/api/nutrition/foods/barcode', { code: '12' })).status, 400);
});

test('a database that is down leaves its results out and says so', async () => {
  offDown = true;
  try {
    const res = await owner.post('/api/nutrition/foods/search', { query: 'oat milk' });
    assert.equal(res.status, 200);
    assert.match(res.json.notes.join(' '), /Open Food Facts didn't answer/);
  } finally {
    offDown = false;
  }
});

test('editing: a new quantity scales every amount, typed amounts are the whole entry, the version moves', async () => {
  const res = await owner.patch(`/api/nutrition/log/${quickId}`, { quantity: 2 });
  assert.deepEqual([res.json.quantity, res.json.values.energy_kcal, res.json.values.protein_g, res.json.version], [2, 840, 44, 2]);
  const typed = await owner.patch(`/api/nutrition/log/${quickId}`, { values: { protein_g: 30, fat_g: null } });
  assert.deepEqual(typed.json.values, { energy_kcal: 840, protein_g: 30, carbs_g: 60 });
  assert.equal((await owner.patch(`/api/nutrition/log/${quickId}`, { name: '' })).status, 400);
  // Back to one portion for the rest of the file.
  await owner.patch(`/api/nutrition/log/${quickId}`, { quantity: 1 });
});

test('no calories: hidden in every answer and refused when sent, yet kept and scaled on the server', async () => {
  assert.equal((await owner.put('/api/settings', { nutritionNumbers: 'no_energy' })).status, 200);
  const log = await logOf(owner);
  assert.ok(log.entries.every((e) => e.values.energy_kcal === undefined));
  const search = (await owner.post('/api/nutrition/foods/search', { query: 'greek yogurt' })).json as FoodSearch;
  assert.ok(search.results[0].portions[0].values.protein_g !== undefined, 'the rest still shows');
  assert.ok(!JSON.stringify(search).includes('energy_kcal'));
  const refused = await owner.post('/api/nutrition/log', { method: 'quick', values: { energy_kcal: 300 } });
  assert.equal(refused.status, 400);
  assert.match(refused.json.error, /hidden by your Nutrition setting/);

  // Doubling the quantity doubles the calories nobody sent or saw.
  const doubled = await owner.patch(`/api/nutrition/log/${quickId}`, { quantity: 2 });
  assert.equal(doubled.json.values.energy_kcal, undefined);
  await owner.put('/api/settings', { nutritionNumbers: 'all' });
  assert.equal(((await logOf(owner)).entries.find((e) => e.id === quickId)!).values.energy_kcal, 840);
  await owner.patch(`/api/nutrition/log/${quickId}`, { quantity: 1 });
});

test('no amounts: names and portions only, quick add and typed amounts refused, a database food still saves', async () => {
  await owner.put('/api/settings', { nutritionNumbers: 'none' });
  const log = await logOf(owner);
  assert.ok(log.entries.length > 0 && log.entries.every((e) => Object.keys(e.values).length === 0));
  const search = (await owner.post('/api/nutrition/foods/search', { query: 'greek yogurt' })).json as FoodSearch;
  assert.ok(search.results.every((r) => r.portions.every((p) => Object.keys(p.values).length === 0)));
  assert.match((await owner.post('/api/nutrition/log', { method: 'quick', values: { water_ml: 250 } })).json.error, /Quick add needs amounts/);
  assert.equal((await owner.patch(`/api/nutrition/log/${quickId}`, { values: { protein_g: 1 } })).status, 400);
  const saved = await owner.post('/api/nutrition/log', { method: 'barcode', ref: 'off:3017620422003', portionIndex: 0 });
  assert.deepEqual([saved.status, saved.json.values], [201, {}]);
  assert.ok(!(await owner.get('/api/nutrition/log')).text.includes('energy_kcal'));
  await owner.put('/api/settings', { nutritionNumbers: 'all' });
  assert.equal(((await logOf(owner)).entries.find((e) => e.id === saved.json.id)!).values.energy_kcal, 80.9, '15 g of Nutella, kept all along');
  await owner.del(`/api/nutrition/log/${saved.json.id}`);
});

const ESTIMATE = JSON.stringify({
  items: [
    { name: 'Pasta with pesto', portion: '1 plate (300 g)', energy_kcal: 620, protein_g: 18, carbs_g: 80, fat_g: 24, fiber_g: 5, sugar_g: 4, sat_fat_g: 5, sodium_mg: 700, alcohol_drinks: 0, water_ml: null },
    { name: 'Red wine', portion: '1 glass (150 mL)', energy_kcal: 125, protein_g: 0, carbs_g: 4, fat_g: 0, fiber_g: null, sugar_g: 1, sat_fat_g: null, sodium_mg: 6, alcohol_drinks: 1, water_ml: null },
  ],
  note: 'Assumed a tablespoon of olive oil in the pesto.',
});

test('an estimate: one McFly question, the photo and words to Claude only, drafts that count for nothing until saved', async () => {
  const before = await usage();
  answers = [{ text: ESTIMATE }];
  const res = await owner.post('/api/nutrition/estimate', { description: 'pasta with pesto and a glass of red', image: { mediaType: 'image/jpeg', data: jpeg.toString('base64') }, time: '19:30' });
  assert.equal(res.status, 200);
  assert.equal(await usage(), before + 1);
  assert.equal(res.json.note, 'Assumed a tablespoon of olive oil in the pesto.');
  const drafts = res.json.drafts as FoodEntry[];
  assert.deepEqual(drafts.map((d) => [d.name, d.method, d.time, d.values.energy_kcal]), [
    ['Pasta with pesto', 'estimate', '19:30', 620],
    ['Red wine', 'estimate', '19:30', 125],
  ]);

  const req = claude.at(-1);
  assert.equal(req.model, 'claude-opus-5-5', "McFly's model");
  assert.equal(req.output_config.format.type, 'json_schema');
  assert.equal(req.messages[0].content[0].type, 'image');
  assert.match(req.messages[0].content[1].text, /pasta with pesto/);
  assert.equal((await db.query("SELECT 1 FROM food_log WHERE per LIKE '%/9j/%' OR name LIKE '%glass of red%'")).length, 0, 'neither the photo nor the words are kept');

  // Drafts don't count, and are listed for review if the page is reopened.
  // Toast and eggs (420) and half a cup of yogurt (182.5) so far.
  assert.equal((await todayIn(owner))!.values.energy_kcal, 602.5);
  assert.equal((await logOf(owner)).drafts.length, 2);

  // Reviewed: the wine is changed, the pasta saved, the rest discarded.
  const edited = await owner.patch(`/api/nutrition/log/${drafts[0].id}`, { quantity: 0.5 });
  assert.equal(edited.json.values.energy_kcal, 310);
  assert.equal((await logOf(owner)).draftBatch, res.json.batch);
  const saved = await owner.post('/api/nutrition/log/save', { batch: res.json.batch, ids: [drafts[0].id] });
  assert.deepEqual(saved.json.entries.map((e: FoodEntry) => e.name), ['Pasta with pesto']);
  const log = await logOf(owner);
  assert.equal(log.drafts.length, 0);
  assert.ok(log.entries.some((e) => e.id === drafts[0].id));
  assert.equal((await todayIn(owner))!.values.energy_kcal, 912.5);
});

test('a new estimate replaces an unsaved one; save and discard touch only their own estimate', async () => {
  answers = [{ text: ESTIMATE }, { text: ESTIMATE }];
  const first = (await owner.post('/api/nutrition/estimate', { description: 'pasta' })).json;
  const second = (await owner.post('/api/nutrition/estimate', { description: 'pasta again' })).json;
  assert.notEqual(first.batch, second.batch);
  assert.deepEqual((await logOf(owner)).drafts.map((d) => d.id), second.drafts.map((d: FoodEntry) => d.id));
  // A tab still showing the first estimate saves or discards nothing of the second.
  assert.deepEqual((await owner.post('/api/nutrition/log/save', { batch: first.batch, ids: first.drafts.map((d: FoodEntry) => d.id) })).json.entries, []);
  assert.equal((await owner.post('/api/nutrition/log/discard', { batch: first.batch })).json.deleted, 0);
  assert.equal((await logOf(owner)).drafts.length, 2);
  assert.equal((await owner.post('/api/nutrition/log/discard', { batch: second.batch })).json.deleted, 2);
  assert.equal((await owner.post('/api/nutrition/log/discard', {})).status, 400);
});

test('drafts go after a day: on the next visit, on the hourly cron, even with Nutrition off, and a day-old one can no longer be saved', async () => {
  answers = [{ text: ESTIMATE }];
  const old = (await owner.post('/api/nutrition/estimate', { description: 'pasta' })).json;
  await db.query('UPDATE food_log SET created_at = created_at - 25 * 3600000 WHERE draft');
  assert.deepEqual((await owner.post('/api/nutrition/log/save', { batch: old.batch, ids: old.drafts.map((d: FoodEntry) => d.id) })).json.entries, []);
  assert.equal((await db.query('SELECT 1 FROM food_log WHERE draft')).length, 0);

  // Someone who never comes back: the cron takes them.
  answers = [{ text: ESTIMATE }];
  await owner.post('/api/nutrition/estimate', { description: 'pasta' });
  await owner.put('/api/settings', { nutrition: false });
  await db.query('UPDATE food_log SET created_at = created_at - 25 * 3600000 WHERE draft');
  process.env.CRON_SECRET = 'cron-test-secret';
  const cron = await owner.call('GET', '/api/cron/whoop', undefined, { Authorization: 'Bearer cron-test-secret' });
  assert.equal(cron.status, 200);
  assert.equal((await db.query('SELECT 1 FROM food_log WHERE draft')).length, 0);
  await owner.put('/api/settings', { nutrition: true, nutritionNumbers: 'all' });
});

test("McFly's note and names never carry a number the person hides", async () => {
  const leaky = JSON.stringify({
    items: [{ name: 'Pasta (about 650 kcal)', portion: '1 plate (300 g), ~25 g protein', energy_kcal: 650, protein_g: 25, carbs_g: 80, fat_g: 24, fiber_g: null, sugar_g: null, sat_fat_g: null, sodium_mg: null, alcohol_drinks: 0, water_ml: null }],
    note: 'Assumed a tablespoon of olive oil, about 120 kcal. That adds 14 g of fat. The sauce is roughly 250kcal, or 1050kJ. The plate looked about half full.',
  });
  answers = [{ text: leaky }];
  const all = (await owner.post('/api/nutrition/estimate', { description: 'pasta' })).json;
  assert.equal(all.note, 'Assumed a tablespoon of olive oil, about 120 kcal. That adds 14 g of fat. The sauce is roughly 250kcal, or 1050kJ. The plate looked about half full.', 'everything, for someone who sees everything');
  assert.deepEqual([all.drafts[0].name, all.drafts[0].portion], ['Pasta', '1 plate (300 g)'], 'amounts never in a name or portion');
  assert.match(claude.at(-1).system, /never put calories or other nutrient amounts/);

  await owner.put('/api/settings', { nutritionNumbers: 'no_energy' });
  answers = [{ text: leaky }];
  const noEnergy = await owner.post('/api/nutrition/estimate', { description: 'pasta' });
  assert.equal(noEnergy.json.note, 'That adds 14 g of fat. The plate looked about half full.');
  assert.match(claude.at(-1).system, /chose not to see calories/);
  assert.ok(!/kcal|calor|kj/i.test(noEnergy.text), 'not even written without a space');

  await owner.put('/api/settings', { nutritionNumbers: 'none' });
  answers = [{ text: leaky }];
  const none = await owner.post('/api/nutrition/estimate', { description: 'pasta' });
  assert.equal(none.json.note, 'The plate looked about half full.');
  assert.deepEqual(none.json.drafts[0].values, {});
  assert.ok(!/kcal|calor|kj|\d+ g of fat/i.test(none.text));
  await owner.post('/api/nutrition/log/discard', { batch: none.json.batch });
  await owner.put('/api/settings', { nutritionNumbers: 'all' });
});

test('an entry can never add up to more than a day: a portion times how many is checked', async () => {
  const res = await owner.post('/api/nutrition/log', { method: 'quick', values: { energy_kcal: 30_000 }, quantity: 50 });
  assert.equal(res.status, 400);
  assert.match(res.json.error, /more than anyone eats in a day/);
  // A quantity change alone scales the stored amounts: 1,000 kcal × 40 is checked too.
  const big = await owner.post('/api/nutrition/log', { method: 'quick', values: { energy_kcal: 1000 } });
  assert.equal((await owner.patch(`/api/nutrition/log/${big.json.id}`, { quantity: 40 })).status, 400);
  await owner.del(`/api/nutrition/log/${big.json.id}`);
});

test("an estimate that fails gives the question back; a refusal or nothing found says so; the limit is McFly's", async () => {
  const before = await usage();
  answers = [{ error: Object.assign(new Error('overloaded'), { status: 529 }) }];
  const failed = await owner.post('/api/nutrition/estimate', { description: 'soup' });
  assert.equal(failed.status, 502);
  assert.equal(await usage(), before, 'refunded');

  answers = [{ text: '', stop_reason: 'refusal' }];
  assert.equal((await owner.post('/api/nutrition/estimate', { description: 'soup' })).status, 422);
  answers = [{ text: '{"items": [', stop_reason: 'max_tokens' }];
  assert.equal((await owner.post('/api/nutrition/estimate', { description: 'soup' })).status, 502);
  assert.equal(await usage(), before, 'a refusal or a cut-off answer is given back too');
  answers = [{ text: JSON.stringify({ items: [], note: '' }) }];
  const nothing = await owner.post('/api/nutrition/estimate', { image: { mediaType: 'image/png', data: png.toString('base64') } });
  assert.deepEqual([nothing.json.drafts, nothing.json.note], [[], "McFly didn't find food or drink to estimate."]);

  await owner.call('PUT', '/api/admin/settings', { mcfly_daily_limit: await usage() });
  const limited = await owner.post('/api/nutrition/estimate', { description: 'soup' });
  assert.equal(limited.status, 429);
  assert.match(limited.json.error, /daily limit/);
  await owner.call('PUT', '/api/admin/settings', { mcfly_daily_limit: 0 });
  assert.equal((await logOf(owner)).can.estimate, false);
  assert.equal((await owner.post('/api/nutrition/estimate', { description: 'soup' })).status, 403);
  await owner.call('PUT', '/api/admin/settings', { mcfly_daily_limit: 50 });
});

test('a photo over the limit is refused before anything reaches Claude', async () => {
  const sent = claude.length;
  const big = Buffer.concat([jpeg, Buffer.alloc(5.5 * 1024 * 1024)]).toString('base64');
  const res = await owner.post('/api/nutrition/estimate', { image: { mediaType: 'image/jpeg', data: big } });
  assert.equal(res.status, 413);
  assert.equal(claude.length, sent);
});

test("someone else's entries can't be read, changed, deleted or saved", async () => {
  await bob.put('/api/settings', { nutrition: true, nutritionNumbers: 'all' });
  assert.deepEqual((await logOf(bob)).entries, []);
  assert.equal((await bob.patch(`/api/nutrition/log/${quickId}`, { name: 'Mine now' })).status, 404);
  assert.equal((await bob.del(`/api/nutrition/log/${quickId}`)).json.deleted, 0);
  assert.equal((await bob.post('/api/nutrition/log/save', { batch: 'x', ids: [quickId] })).json.entries.length, 0);
  assert.equal((await todayIn(bob)), undefined);
  assert.ok((await logOf(owner)).entries.some((e) => e.id === quickId && e.name === 'Toast and eggs'));
});

test('off hides the log and refuses changes; delete removes it with the rest; an account deletion takes it too', async () => {
  await owner.put('/api/settings', { nutrition: false });
  assert.deepEqual((await logOf(owner)).entries, []);
  assert.equal((await owner.del(`/api/nutrition/log/${quickId}`)).status, 409);
  assert.ok((await db.query('SELECT 1 FROM food_log WHERE user_id = $1', [OWNER_ID])).length > 0, 'kept, hidden');

  const deleted = await owner.post('/api/nutrition/delete');
  assert.ok(deleted.json.deleted > 0);
  assert.equal((await db.query('SELECT 1 FROM food_log WHERE user_id = $1', [OWNER_ID])).length, 0);

  await bob.post('/api/nutrition/log', { method: 'quick', values: { energy_kcal: 300 } });
  assert.equal((await db.query('SELECT 1 FROM food_log WHERE user_id = $1', [bobId])).length, 1);
  assert.equal((await owner.call('DELETE', `/api/admin/users/${bobId}`)).status, 200);
  assert.equal((await db.query('SELECT 1 FROM food_log')).length, 0);
});
