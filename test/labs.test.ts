// Lab tests: the biomarker catalog, adding and reading results for one person only, statuses against each lab's own
// range, units that join up only when converted explicitly, McFly's read-only tool, and reading a report with a fake
// Claude (a draft only: nothing saved, counted as a question, refunded on failure).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { AddressInfo } from 'node:net';
import { convert, matchBiomarker, markerKey, parseRange, parseResultValue, resultStatus, statusOf, typicalRange } from '../shared/labs.ts';
import { createApp } from '../server/app.ts';
import { hashPassword } from '../server/auth.ts';
import { addDays, todayLocal } from '../server/dates.ts';
import { OWNER_ID } from '../server/db.ts';
import { insertLabResults } from '../server/labs.ts';
import type { McflyClient } from '../server/mcfly.ts';
import { openStore } from '../server/store.ts';

process.env.SESSION_SECRET = 'labs-test-secret-'.padEnd(64, 'x');
const OWNER_PASSWORD = 'owner password 123';
process.env.HEALTHOS_PASSWORD_HASH = await hashPassword(OWNER_PASSWORD);

// ---------- the catalog ----------

test('printed names match the catalog exactly, never partly', () => {
  for (const n of ['25-OH Vitamin D', 'Vitamin D, 25-Hydroxy', '25(OH)D', 'vitamin d']) assert.equal(matchBiomarker(n), 'vitamin_d', n);
  assert.equal(matchBiomarker('LDL Chol Calc (NIH)'), 'ldl');
  assert.equal(matchBiomarker('Cholesterol, Total'), 'total_cholesterol');
  assert.equal(matchBiomarker('Hemoglobin A1c'), 'hba1c');
  assert.equal(matchBiomarker('Hemoglobin'), 'hemoglobin');
  assert.equal(matchBiomarker('Glucose, Serum'), 'glucose');
  assert.equal(matchBiomarker('Non-HDL Cholesterol'), 'non_hdl');
  assert.equal(matchBiomarker('HDL'), 'hdl');
  // Different tests that only share a word stay apart.
  assert.equal(matchBiomarker('Free Testosterone'), null);
  assert.equal(matchBiomarker('C-Reactive Protein'), null);
  assert.equal(matchBiomarker('Cortisol'), null, 'could be an afternoon draw');
  assert.equal(markerKey('Bilirubin, Total'), 'other:bilirubin-total');
});

test('results as printed: "<", ">", words and flags', () => {
  assert.deepEqual(parseResultValue('5.4'), { value: 5.4, qualifier: null });
  assert.deepEqual(parseResultValue('<0.5'), { value: 0.5, qualifier: '<' });
  assert.deepEqual(parseResultValue('> 90'), { value: 90, qualifier: '>' });
  assert.deepEqual(parseResultValue('Negative'), { value: null, qualifier: null });
  assert.deepEqual(parseResultValue('250 H'), { value: 250, qualifier: null });
  assert.deepEqual(parseResultValue('1,234'), { value: 1234, qualifier: null });
  assert.deepEqual(parseResultValue('5,4'), { value: 5.4, qualifier: null });
  assert.deepEqual(parseRange('3.5 – 5.0 mmol/L'), { low: 3.5, high: 5, lowOpen: false, highOpen: false });
  assert.deepEqual(parseRange('<200'), { low: null, high: 200, lowOpen: false, highOpen: true });
  assert.deepEqual(parseRange('> OR = 40'), { low: 40, high: null, lowOpen: false, highOpen: false });
  assert.equal(parseRange('Negative'), null);
});

test('status is position against a range, with "<" and ">" placed only when they can be', () => {
  assert.equal(statusOf(3.4, 3.5, 5), 'below');
  assert.equal(statusOf(3.5, 3.5, 5), 'within');
  assert.equal(statusOf(5.1, 3.5, 5), 'above');
  assert.equal(statusOf(200, null, 200, { high: true }), 'above', 'printed "<200" leaves out 200');
  assert.equal(statusOf(5, null, null), null);
  const s = (v: string, r: string) => resultStatus(parseResultValue(v), parseRange(r));
  assert.equal(s('<0.5', '<3.0'), 'within');
  assert.equal(s('<0.3', '0.00-3.00'), 'within');
  assert.equal(s('<0.5', '1-3'), 'below');
  assert.equal(s('<2', '1-3'), null, 'could be either side of 1');
  assert.equal(s('>90', '>59'), 'within');
  assert.equal(s('>12', '1-10'), 'above');
  assert.equal(s('Negative', 'Negative'), null);
});

test('units convert only with an explicit factor', () => {
  assert.equal(Number(convert(30, 'ng/mL', 'nmol/L', 'vitamin_d')!.toFixed(2)), 74.88);
  assert.equal(Math.round(convert(5.5, 'mmol/L', 'mg/dL', 'glucose')!), 99);
  assert.equal(Number(convert(48, 'mmol/mol', '%', 'hba1c')!.toFixed(1)), 6.5, 'HbA1c is affine, not a factor');
  assert.equal(Math.round(convert(5, 'mmol/L', 'mg/dL', 'ldl')!), 193);
  assert.equal(convert(7, 'K/uL', '10^9/L', 'wbc'), 7, 'the same count, spelled differently');
  assert.equal(convert(50, 'mg/dL', 'nmol/L', 'lpa'), null, 'Lp(a) mass and particle count have no factor');
  assert.equal(convert(5, 'mg/dL', 'mmol/L', 'other:bilirubin'), null);
});

test('the typical range is only for its own unit, and per sex where it differs', () => {
  assert.deepEqual(typicalRange('magnesium', 'mg/dL', null), { low: 1.6, high: 2.3, text: '1.6–2.3', kind: 'typical' });
  assert.equal(typicalRange('magnesium', 'mmol/L', null), null);
  assert.equal(typicalRange('ferritin', 'ng/mL', null), null);
  assert.equal(typicalRange('ferritin', 'ng/mL', 'unspecified'), null);
  assert.equal(typicalRange('ferritin', 'ug/L', 'female')!.text, '15–150');
  assert.equal(typicalRange('estradiol', 'pg/mL', 'female'), null);
});

// ---------- a fake Claude ----------

type Block = { type: 'text'; text: string } | { type: 'tool_use'; id: string; name: string; input: unknown };
const reply = (content: Block[], stop_reason: string) => ({
  id: 'msg_test',
  type: 'message',
  role: 'assistant',
  model: 'claude-opus-5-5',
  content,
  stop_reason,
  stop_sequence: null,
  usage: { input_tokens: 1200, output_tokens: 300, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 },
});
let script: (ReturnType<typeof reply> | Error)[] = [];
const requests: any[] = [];
let configured = true;
const next = () => {
  const msg = script.shift();
  if (!msg) throw new Error('fake Claude ran out of scripted replies');
  if (msg instanceof Error) throw msg;
  return msg;
};
const fake = {
  beta: {
    messages: {
      async create(params: unknown) {
        requests.push(structuredClone(params));
        return next();
      },
      stream(params: unknown) {
        requests.push(structuredClone(params));
        const msg = next();
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
const app = createApp({ db, hosted: false, mcflyClient: () => (configured ? fake : null) });
const server = app.listen(0, '127.0.0.1');
await new Promise((r) => server.once('listening', r));
const base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
test.after(async () => {
  server.close();
  await db.close();
});

class Client {
  cookie = '';
  async call(method: string, path: string, body?: unknown, raw?: { type: string; data: Uint8Array<ArrayBuffer> }) {
    const res = await fetch(base + path, {
      method,
      headers: { 'X-HealthOS': '1', 'Content-Type': raw ? raw.type : 'application/json', ...(this.cookie ? { Cookie: this.cookie } : {}) },
      body: raw ? raw.data : body === undefined ? undefined : JSON.stringify(body),
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
  labs() {
    return this.call('GET', '/api/labs');
  }
  add(results: unknown[]) {
    return this.call('POST', '/api/labs', { results });
  }
  extract(type: string, data: Uint8Array<ArrayBuffer>) {
    return this.call('POST', '/api/labs/extract', undefined, { type, data });
  }
}

const owner = new Client();
const bob = new Client();
let bobId = '';
const today = todayLocal();
const ago = (d: number) => addDays(today, -d);
const count = async (userId: string) => (await db.query<{ n: number }>('SELECT COUNT(*)::int AS n FROM lab_results WHERE user_id = $1', [userId]))[0].n;
const used = async (c: Client) => (await c.call('GET', '/api/mcfly')).json.usedToday as number;

test('setup: an owner and an invited member', async () => {
  assert.equal((await owner.call('POST', '/api/auth/login', { email: 'owner@example.com', password: OWNER_PASSWORD })).status, 200);
  const inv = await owner.call('POST', '/api/admin/invites', {});
  const token = inv.json.url.split('/').at(-1);
  assert.equal((await bob.call('POST', '/api/auth/invite', { token, email: 'bob@example.com', name: 'Bob', password: 'bob password 123' })).status, 200);
  bobId = (await bob.call('GET', '/api/auth/me')).json.user.id;
});

test('nothing yet: an empty list, not an error', async () => {
  const r = await bob.labs();
  assert.equal(r.status, 200);
  assert.deepEqual([r.json.count, r.json.markers, r.json.panels], [0, [], []]);
});

// ---------- adding results ----------

test('bad rows are refused with plain messages that never repeat the value', async () => {
  const ok = { collected: ago(3), name: 'Vitamin D', valueText: '31', unit: 'ng/mL' };
  const cases: [unknown, RegExp][] = [
    [{ ...ok, collected: addDays(today, 1) }, /results\[0\]\.collected: can't be in the future/],
    [{ ...ok, collected: '2026-02-30' }, /results\[0\]\.collected: expected a real date/],
    [{ ...ok, name: '   ' }, /results\[0\]\.name: is required/],
    [{ ...ok, name: '---' }, /results\[0\]\.name: expected a marker name/],
    [{ ...ok, valueText: undefined }, /results\[0\]\.valueText: is required/],
    [{ ...ok, valueText: 'x'.repeat(61) }, /at most 60 characters/],
    [{ ...ok, refLow: 10, refHigh: 5 }, /refLow: must not be above refHigh/],
    [{ ...ok, refLow: 'low' }, /refLow: expected a number/],
    [{ ...ok, biomarker: 'not_a_marker' }, /biomarker: expected a marker from the catalog/],
  ];
  for (const [row, message] of cases) {
    const r = await bob.add([ok, row]);
    assert.equal(r.status, 400, JSON.stringify(row));
    assert.match(r.json.error, new RegExp(message.source.replace('results\\[0\\]', 'results\\[1\\]')));
    assert.ok(!r.text.includes('2026-02-30') && !r.text.includes('xxxxx'));
  }
  assert.equal((await bob.call('POST', '/api/labs', { results: [] })).status, 400);
  assert.equal((await bob.call('POST', '/api/labs', { results: Array.from({ length: 201 }, () => ok) })).status, 400);
  assert.equal((await bob.call('POST', '/api/labs', 'nope')).status, 400);
  assert.equal((await bob.call('POST', '/api/labs', { results: [ok], source: 'demo' })).status, 400, "nobody can write the demo's rows");
  assert.equal(await count(bobId), 0, 'one bad row and none of the batch is stored');
});

test("each result is read against its own printed range, or a labelled typical one only when none was printed", async () => {
  const r = await bob.add([
    { collected: ago(30), name: 'Vitamin D, 25-Hydroxy', valueText: '24', unit: 'ng/mL', refText: '30-100', lab: 'Quest', panel: 'Vitamins' },
    { collected: ago(30), name: 'Magnesium', valueText: '2.0', unit: 'mg/dL', lab: 'Quest', panel: 'Vitamins' },
    { collected: ago(30), name: 'Ferritin', valueText: '12', unit: 'ng/mL', lab: 'Quest', panel: 'Vitamins' },
    { collected: ago(30), name: 'LDL Cholesterol', valueText: '130 H', unit: 'mg/dL', refText: '<100', lab: 'Quest', panel: 'Lipid panel' },
    { collected: ago(30), name: 'hs-CRP', valueText: '<0.3', unit: 'mg/L', refText: '0.00-3.00', lab: 'Quest', panel: 'Inflammation' },
    { collected: ago(30), name: 'HIV 1/2 Antibody', valueText: 'Non-reactive', refText: 'Non-reactive', lab: 'Quest', panel: 'Screening' },
    { collected: ago(30), name: 'Bilirubin, Total', valueText: '0.6', unit: 'mg/dL', refText: '0.2-1.2', lab: 'Quest', panel: 'Liver' },
  ]);
  assert.equal(r.status, 200);
  assert.equal(r.json.added, 7);
  const data = (await bob.labs()).json;
  const m = (key: string) => data.markers.find((x: { key: string }) => x.key === key);
  assert.deepEqual([m('vitamin_d').latest.status, m('vitamin_d').latest.range], ['below', { low: 30, high: 100, text: '30-100', kind: 'lab' }]);
  assert.deepEqual([m('magnesium').latest.status, m('magnesium').latest.range.kind, m('magnesium').latest.range.text], ['within', 'typical', '1.6–2.3']);
  // Ferritin's typical range differs by sex, and Bob hasn't chosen one: no fallback, no status.
  assert.deepEqual([m('ferritin').latest.status, m('ferritin').latest.range], [null, null]);
  assert.deepEqual([m('ldl').latest.status, m('ldl').latest.value, m('ldl').latest.valueText], ['above', 130, '130 H']);
  assert.deepEqual([m('hs_crp').latest.status, m('hs_crp').latest.qualifier], ['within', '<']);
  const hiv = data.markers.find((x: { name: string }) => x.name === 'HIV 1/2 Antibody');
  assert.deepEqual([hiv.key, hiv.latest.status, hiv.latest.range.text, hiv.latest.value], ['other:hiv-1-2-antibody', null, 'Non-reactive', null]);
  assert.equal(m('other:bilirubin-total').latest.status, 'within');
  // One collection on one day, grouped by panel.
  assert.deepEqual(
    data.panels.map((p: { panel: string }) => p.panel),
    ['Inflammation', 'Lipid panel', 'Liver', 'Screening', 'Vitamins'],
  );

  // Choosing a sex in the profile gives ferritin its typical range, labelled as one.
  await bob.call('PUT', '/api/settings', { sex: 'female' });
  const after = (await bob.labs()).json.markers.find((x: { key: string }) => x.key === 'ferritin').latest;
  assert.deepEqual([after.status, after.range.kind, after.range.text], ['below', 'typical', '15–150']);
  await bob.call('PUT', '/api/settings', { sex: null });
});

test('history joins values in the same unit or converted explicitly, and never draws a "<" value as a point', async () => {
  await bob.add([
    { collected: ago(400), name: '25-OH Vitamin D', valueText: '60', unit: 'nmol/L', refText: '75-250' },
    { collected: ago(200), name: 'Vitamin D', valueText: '<20', unit: 'ng/mL', refText: '30-100' },
    { collected: ago(400), name: 'Lp(a)', valueText: '40', unit: 'mg/dL', refText: '<30' },
    { collected: ago(10), name: 'Lipoprotein(a)', valueText: '90', unit: 'nmol/L', refText: '<75' },
  ]);
  const data = (await bob.labs()).json;
  const vd = data.markers.find((x: { key: string }) => x.key === 'vitamin_d');
  assert.equal(vd.history.length, 3);
  assert.equal(vd.latest.valueText, '24', 'latest by collection date');
  assert.deepEqual(
    vd.points.map((p: { value: number }) => p.value),
    [24.04, 24],
    'the nmol/L result converted to ng/mL; "<20" listed, not drawn',
  );
  // Each result keeps its own status, against its own printed range and in its own unit.
  assert.deepEqual(
    vd.history.map((r: { status: string }) => r.status),
    ['below', 'below', 'below'],
  );
  const lpa = data.markers.find((x: { key: string }) => x.key === 'lpa');
  assert.deepEqual([lpa.points.length, lpa.otherUnits, lpa.latest.status], [1, 1, 'above']);
});

test("a result can be corrected, and its status follows", async () => {
  const vd = (await bob.labs()).json.markers.find((x: { key: string }) => x.key === 'vitamin_d').latest;
  const r = await bob.call('PATCH', `/api/labs/${vd.id}`, { valueText: '42' });
  assert.equal(r.status, 200);
  assert.deepEqual([r.json.result.valueText, r.json.result.value, r.json.result.status], ['42', 42, 'within']);
  const range = await bob.call('PATCH', `/api/labs/${vd.id}`, { refText: '50-100' });
  assert.deepEqual([range.json.result.range.low, range.json.result.status], [50, 'below']);
  assert.equal((await bob.call('PATCH', `/api/labs/${vd.id}`, { collected: addDays(today, 2) })).status, 400);
  assert.equal((await bob.call('PATCH', '/api/labs/nope', { valueText: '1' })).status, 404);
});

test("another person can't read, change or delete them", async () => {
  await owner.add([{ collected: ago(5), name: 'TSH', valueText: '2.2', unit: 'mIU/L', refText: '0.45-4.5' }]);
  const mine = (await owner.labs()).json;
  assert.deepEqual(
    mine.markers.map((x: { key: string }) => x.key),
    ['tsh'],
    "the owner sees only their own result, none of Bob's",
  );
  const bobs = (await bob.labs()).json;
  assert.ok(!bobs.markers.some((x: { key: string }) => x.key === 'tsh'));
  const id = mine.markers[0].latest.id;
  assert.equal((await bob.call('PATCH', `/api/labs/${id}`, { valueText: '9.9' })).status, 404);
  assert.equal((await bob.call('DELETE', `/api/labs/${id}`)).status, 404);
  assert.equal((await owner.labs()).json.markers[0].latest.valueText, '2.2');
  assert.equal((await new Client().labs()).status, 401);
});

test('deleting removes only that result', async () => {
  const before = await count(bobId);
  const bili = (await bob.labs()).json.markers.find((x: { key: string }) => x.key === 'other:bilirubin-total').latest;
  assert.equal((await bob.call('DELETE', `/api/labs/${bili.id}`)).status, 200);
  assert.equal(await count(bobId), before - 1);
  assert.equal((await bob.call('DELETE', `/api/labs/${bili.id}`)).status, 404);
});

test("demo results show only for the owner's local demo, and only until they add their own", async () => {
  const demoRow = (userId: string) => ({
    id: `demo-lab-x-${userId}`,
    collected: ago(20),
    biomarker: 'hdl',
    name: 'HDL Cholesterol',
    value: 55,
    value_text: '55',
    unit: 'mg/dL',
    ref_low: 39,
    ref_high: null,
    ref_text: '>39',
    lab: 'Demo Lab',
    panel: 'Lipid panel',
    source: 'demo',
    created_at: Date.now(),
  });
  await insertLabResults(db, OWNER_ID, [demoRow(OWNER_ID)]);
  await insertLabResults(db, bobId, [demoRow(bobId)]);
  // The owner has a result of their own (TSH), so the demo stays hidden.
  assert.deepEqual(
    (await owner.labs()).json.markers.map((x: { key: string }) => x.key),
    ['tsh'],
  );
  const tsh = (await owner.labs()).json.markers[0].latest.id;
  await owner.call('DELETE', `/api/labs/${tsh}`);
  const demo = (await owner.labs()).json;
  assert.deepEqual([demo.demo, demo.markers.map((x: { key: string }) => x.key)], [true, ['hdl']]);
  // Never for anyone but the local owner.
  assert.ok(!(await bob.labs()).json.markers.some((x: { latest: { source: string } }) => x.latest.source === 'demo'));
  await db.query("DELETE FROM lab_results WHERE source = 'demo'");
});

// ---------- McFly ----------

test("McFly's lab tool reads only the asking person's results, with positions, not verdicts", async () => {
  requests.length = 0;
  script = [
    reply([{ type: 'tool_use', id: 'tl_1', name: 'get_lab_results', input: { marker: 'vitamin D' } }], 'tool_use'),
    reply([{ type: 'text', text: 'Your latest vitamin D is below the range printed with it.' }], 'end_turn'),
  ];
  const res = await bob.call('POST', '/api/mcfly/chat', { messages: [{ role: 'user', content: 'How is my vitamin D?' }] });
  assert.equal(res.status, 200);
  assert.ok(requests[0].tools.some((t: { name: string }) => t.name === 'get_lab_results'));
  const desc = requests[0].tools.find((t: { name: string }) => t.name === 'get_lab_results').description;
  assert.match(desc, /below, within or above the lab's range/);
  assert.match(desc, /never as a diagnosis/);
  const result = JSON.parse(requests[1].messages.at(-1).content[0].content);
  assert.equal(result.markersFound, 1);
  const vd = result.markers[0];
  assert.equal(vd.marker, 'Vitamin D (25-OH)');
  assert.deepEqual([vd.latest.result, vd.latest.unit, vd.latest.position, vd.latest.range.from], ['42', 'ng/mL', "below the lab's range", 'printed by the lab']);
  assert.equal(vd.earlier.length, 2);
  // The owner's TSH (deleted above) and anything else of theirs never appears.
  assert.ok(!requests[1].messages.at(-1).content[0].content.includes('TSH'));

  requests.length = 0;
  script = [
    reply([{ type: 'tool_use', id: 'tl_2', name: 'get_lab_results', input: {} }], 'tool_use'),
    reply([{ type: 'text', text: 'ok' }], 'end_turn'),
  ];
  await bob.call('POST', '/api/mcfly/chat', { messages: [{ role: 'user', content: 'All my labs?' }] });
  const all = JSON.parse(requests[1].messages.at(-1).content[0].content);
  const mag = all.markers.find((m: { marker: string }) => m.marker === 'Magnesium');
  assert.equal(mag.latest.range.from, 'typical adult range, used because the report printed none');
  assert.equal(mag.latest.position, 'within the typical adult range');
});

// ---------- reading a report ----------

const pdf = (bytes: number) => {
  const b = new Uint8Array(bytes).fill(0x20);
  b.set(new TextEncoder().encode('%PDF-1.7\n'));
  return b;
};
const png = () => {
  const b = new Uint8Array(4096);
  b.set([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  return b;
};
const extracted = (rows: unknown[], extra: Record<string, unknown> = {}) => reply([{ type: 'text', text: JSON.stringify({ is_lab_report: true, note: null, results: rows, ...extra }) }], 'end_turn');
const ROW = { name: 'Glucose', value_text: '92', unit: 'mg/dL', ref_text: '70-99', ref_low: 70, ref_high: 99, collected: ago(2), lab: 'Quest', panel: 'Metabolic' };

test("reading reports isn't offered until an API key is configured", async () => {
  configured = false;
  const r = await bob.extract('application/pdf', pdf(2000));
  assert.equal(r.status, 503);
  assert.match(r.json.error, /isn't set up/);
  configured = true;
});

test('a report is read into a draft: nothing is saved, and it counts as one McFly question', async () => {
  const [rowsBefore, usedBefore] = [await count(bobId), await used(bob)];
  requests.length = 0;
  script = [
    extracted([
      ROW,
      { ...ROW, name: 'Vitamin D, 25-Hydroxy', value_text: '<10', unit: 'ng/mL', ref_text: '', ref_low: 30, ref_high: 100, panel: 'Vitamins' },
      { ...ROW, name: 'HIV Screen', value_text: 'Non-reactive', unit: '', ref_text: 'Non-reactive', ref_low: null, ref_high: null, collected: addDays(today, 3) },
      { ...ROW, name: '', value_text: '1' },
    ]),
  ];
  // About 1 MB: past the general 100 kB JSON limit, so this proves the file reaches the route as its own bytes.
  const r = await bob.extract('application/pdf', pdf(1_000_000));
  assert.equal(r.status, 200, r.text);
  assert.deepEqual(r.json.rows[0], { collected: ago(2), name: 'Glucose', valueText: '92', unit: 'mg/dL', refText: '70-99', lab: 'Quest', panel: 'Metabolic', biomarker: 'glucose' });
  assert.deepEqual([r.json.rows[1].refText, r.json.rows[1].biomarker], ['30–100', 'vitamin_d'], 'a range from the numbers when none was printed as text');
  assert.deepEqual([r.json.rows[2].collected, r.json.rows[2].biomarker], [null, null], 'a future date is left for the person to fill in');
  assert.equal(r.json.rows.length, 3, 'a row without a name is dropped');

  // The request: the file as a base64 PDF block, the platform's model, structured output, no forced tool.
  const sent = requests[0];
  assert.equal(sent.model, 'claude-opus-5-5');
  assert.equal(sent.messages[0].content[0].type, 'document');
  assert.equal(sent.messages[0].content[0].source.media_type, 'application/pdf');
  assert.equal(Buffer.from(sent.messages[0].content[0].source.data, 'base64').length, 1_000_000);
  assert.equal(sent.output_config.format.type, 'json_schema');
  assert.equal(sent.tool_choice, undefined);
  assert.equal(sent.tools, undefined);
  assert.equal(sent.fallbacks, 'default');
  assert.match(sent.system, /never invent/i);

  assert.equal(await count(bobId), rowsBefore, 'a draft only');
  assert.equal(await used(bob), usedBefore + 1);
  assert.equal(r.json.usedToday, usedBefore + 1);
  const [usage] = await db.query<{ input_tokens: number }>('SELECT input_tokens FROM mcfly_usage WHERE user_id = $1', [bobId]);
  assert.ok(Number(usage.input_tokens) >= 1200, 'its tokens are counted for the admin view');

  // Saving the checked rows is an ordinary add, marked as read from a report.
  const save = await bob.call('POST', '/api/labs', { results: r.json.rows.slice(0, 2), source: 'report' });
  assert.equal(save.status, 200);
  const [row] = await db.query<{ source: string }>('SELECT source FROM lab_results WHERE user_id = $1 AND id = $2', [bobId, save.json.ids[0]]);
  assert.equal(row.source, 'report');
});

test('a photo goes as an image block', async () => {
  requests.length = 0;
  script = [extracted([ROW])];
  const r = await bob.extract('image/png', png());
  assert.equal(r.status, 200);
  assert.deepEqual([requests[0].messages[0].content[0].type, requests[0].messages[0].content[0].source.media_type], ['image', 'image/png']);
});

test('a file that is not a lab report comes back empty, with a note', async () => {
  script = [reply([{ type: 'text', text: JSON.stringify({ is_lab_report: false, note: null, results: [] }) }], 'end_turn')];
  const r = await bob.extract('image/png', png());
  assert.deepEqual([r.status, r.json.rows], [200, []]);
  assert.match(r.json.note, /doesn't look like a lab report/);
});

test('a report that fails to be read is refunded, and nothing about it is logged', async () => {
  const before = await used(bob);
  const logged: string[] = [];
  const original = console.error;
  console.error = (...args: unknown[]) => void logged.push(args.map(String).join(' '));
  try {
    script = [new Error('upstream')];
    const failed = await bob.extract('application/pdf', pdf(2000));
    assert.equal(failed.status, 502);
    assert.match(failed.json.error, /Couldn't read that report/);
    // A reply that isn't the JSON asked for: the parse error's text would quote it, so only the kind is logged.
    script = [reply([{ type: 'text', text: 'Glucose 92 secret-value' }], 'end_turn')];
    assert.equal((await bob.extract('application/pdf', pdf(2000))).status, 502);
    script = [reply([{ type: 'text', text: '' }], 'refusal')];
    assert.equal((await bob.extract('application/pdf', pdf(2000))).status, 502);
  } finally {
    console.error = original;
  }
  assert.equal(await used(bob), before, 'none of the three counted');
  assert.ok(logged.length >= 3);
  assert.ok(logged.every((l) => !l.includes('secret-value') && !l.includes('Glucose')));
});

test('the wrong kind of file, a mislabelled one or one over 4 MB is refused before anything is counted', async () => {
  const before = await used(bob);
  requests.length = 0;
  const heic = await bob.extract('image/heic', new Uint8Array(100));
  assert.equal(heic.status, 415);
  assert.match(heic.json.error, /PDF, or a photo/);
  const fakePdf = await bob.extract('application/pdf', png());
  assert.equal(fakePdf.status, 400);
  assert.match(fakePdf.json.error, /doesn't look like a PDF/);
  assert.equal((await bob.extract('application/pdf', new Uint8Array(0))).status, 400);
  const big = await bob.extract('application/pdf', pdf(4 * 1024 * 1024 + 1));
  assert.equal(big.status, 413);
  assert.match(big.json.error, /over 4 MB/);
  assert.equal(requests.length, 0, 'Claude was never called');
  assert.equal(await used(bob), before);
});

test("over the daily limit it's refused, and with the limit at 0 it's off", async () => {
  const u = await used(bob);
  await owner.call('PUT', '/api/admin/settings', { mcfly_daily_limit: u });
  const over = await bob.extract('application/pdf', pdf(2000));
  assert.equal(over.status, 429);
  assert.match(over.json.error, /counts as an Ask McFly question/);
  await owner.call('PUT', '/api/admin/settings', { mcfly_daily_limit: 0 });
  assert.equal((await bob.extract('application/pdf', pdf(2000))).status, 403);
  await owner.call('PUT', '/api/admin/settings', { mcfly_daily_limit: 50 });
});
