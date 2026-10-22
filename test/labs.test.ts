// Lab tests: the biomarker catalog, adding and reading results for one person only, statuses against each lab's own
// range, units that join up only when converted explicitly, McFly's read-only tool, and reading a report with a fake
// Claude (a draft only: nothing saved, counted as a question, refunded on failure).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { AddressInfo } from 'node:net';
import {
  type LabDraft,
  type LabResult,
  convert,
  draftGroups,
  markerKey,
  markerName,
  matchBiomarker,
  parseRange,
  parseResultValue,
  rangeCount,
  rangeLabel,
  resultStatus,
  statusHint,
  statusLabel,
  statusOf,
  typicalRange,
  undrawnReasons,
} from '../shared/labs.ts';
import { createApp } from '../server/app.ts';
import { hashPassword } from '../server/auth.ts';
import { addDays, todayLocal } from '../server/dates.ts';
import { OWNER_ID } from '../server/db.ts';
import { insertLabResults } from '../server/labs.ts';
import type { McflyClient } from '../server/mcfly.ts';
import { openStore } from '../server/store.ts';
import { prepareReport } from '../src/labsUpload.ts';

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

test('a result and its range are read with one number grammar, so the status matches the printed numbers', () => {
  const s = (v: string, r: string) => resultStatus(parseResultValue(v), parseRange(r));
  // Thousands: platelets printed per µL.
  assert.deepEqual(parseRange('150,000-450,000'), { low: 150000, high: 450000, lowOpen: false, highOpen: false });
  assert.equal(parseResultValue('250,000').value, 250000);
  assert.equal(s('250,000', '150,000-450,000'), 'within');
  assert.equal(s('500,000', '150,000-450,000'), 'above');
  // A minus sign on the first bound (base excess), plain or typographic.
  assert.deepEqual(parseRange('-2.0-2.0'), { low: -2, high: 2, lowOpen: false, highOpen: false });
  assert.deepEqual(parseRange('−2.0 to +2.0'), { low: -2, high: 2, lowOpen: false, highOpen: false });
  assert.equal(parseResultValue('−1.5').value, -1.5);
  assert.equal(s('-1.5', '-2.0-2.0'), 'within');
  assert.equal(s('-3', '-2.0-2.0'), 'below');
  // A hyphen after a word isn't a minus; decimal commas stay decimal across the whole range.
  assert.deepEqual(parseRange('Adult-13-17'), { low: 13, high: 17, lowOpen: false, highOpen: false });
  assert.deepEqual(parseRange('0,450-4,500'), { low: 0.45, high: 4.5, lowOpen: false, highOpen: false });
  assert.deepEqual(parseRange('3,5-5,0'), { low: 3.5, high: 5, lowOpen: false, highOpen: false });
  assert.deepEqual(parseRange('60-90 mL/min/1.73m2'), { low: 60, high: 90, lowOpen: false, highOpen: false }, 'a number in the unit is not a second range');
});

test('a range printed in bands is read for the sex given, never as its first band', () => {
  const hgb = 'Male: 13.0-17.0 Female: 12.0-15.0';
  assert.equal(rangeCount(hgb), 2);
  assert.equal(parseRange(hgb), null, 'no sex: no band, rather than the first');
  assert.equal(parseRange(hgb, 'unspecified'), null);
  assert.deepEqual(parseRange(hgb, 'female'), { low: 12, high: 15, lowOpen: false, highOpen: false });
  assert.deepEqual(parseRange(hgb, 'male'), { low: 13, high: 17, lowOpen: false, highOpen: false });
  assert.equal(resultStatus(parseResultValue('12.5'), parseRange(hgb, 'female')), 'within');
  assert.deepEqual(parseRange('M: <1.2 F: <1.0', 'female'), { low: null, high: 1, lowOpen: false, highOpen: true });
  assert.deepEqual(parseRange('(M) 13-17 (F) 12-15', 'female'), { low: 12, high: 15, lowOpen: false, highOpen: false });
  // Anything that isn't one labelled band per sex shows as printed, with no status.
  assert.equal(parseRange('13.0-17.0 (male) 12.0-15.0 (female)', 'female'), null, 'labels after their ranges');
  assert.equal(parseRange('Female 18-49: 10-20 Male: 5-6', 'female'), null, 'age bands');
  assert.equal(parseRange('Desirable <200 Borderline 200-239'), null, 'categories');
  assert.equal(parseRange('Desirable <200 Borderline 200-239', 'female'), null);
  // One labelled band is the lab's range for this person.
  assert.deepEqual(parseRange('Female: 12.0-15.0', 'male'), { low: 12, high: 15, lowOpen: false, highOpen: false });
});

test('urine and stool results never become a blood marker', () => {
  assert.equal(markerKey('Glucose', 'Urinalysis'), 'other:urine-glucose');
  assert.equal(markerKey('Glucose, Urine'), 'other:urine-glucose', 'the same test, whichever way it was printed');
  assert.equal(markerKey('WBC', 'Microscopic Examination'), 'other:urine-wbc');
  assert.equal(markerKey('RBC', 'UA, Complete'), 'other:urine-rbc');
  assert.equal(markerKey('Occult Blood', 'Stool'), 'other:stool-occult-blood');
  assert.equal(markerKey('Glucose', 'Metabolic'), 'glucose');
  assert.equal(markerKey('Glucose'), 'glucose');
  assert.equal(markerName('other:urine-glucose', 'Glucose'), 'Glucose (urine)', 'told apart from blood glucose');
  assert.equal(markerName('other:urine-glucose', 'Glucose, Urine'), 'Glucose, Urine');
});

const result = (o: Partial<LabResult>): LabResult => ({
  id: 'r',
  collected: '2026-01-01',
  biomarker: 'x',
  name: 'X',
  valueText: '5',
  value: 5,
  qualifier: null,
  unit: 'mg/dL',
  range: { low: 1, high: 10, text: '1-10', kind: 'lab' },
  status: 'within',
  lab: '',
  panel: '',
  source: 'manual',
  ...o,
});

test('each status says which range it is against, or why there is none', () => {
  const plain = result({});
  assert.deepEqual([statusLabel(plain), statusHint(plain)], ['Within range', undefined]);
  const typical = result({ range: { low: 1.6, high: 2.3, text: '1.6–2.3', kind: 'typical' } });
  assert.match(statusHint(typical)!, /typical adult range/);
  const picked = result({ range: { low: 12, high: 15, text: 'Male: 13.0-17.0 Female: 12.0-15.0', kind: 'lab', band: 'female' } });
  assert.equal(rangeLabel(picked), 'Male: 13.0-17.0 Female: 12.0-15.0 (female range used)');
  assert.match(statusHint(picked)!, /the one for women, from the sex in your profile/);
  const unpicked = result({ status: null, range: { low: null, high: null, text: 'Male: 13.0-17.0 Female: 12.0-15.0', kind: 'lab', band: null } });
  assert.equal(statusLabel(unpicked), 'Can’t be placed');
  assert.match(statusHint(unpicked)!, /more than one band/);
  const noNumbers = result({ status: null, range: { low: null, high: null, text: 'See note', kind: 'lab' } });
  assert.equal(statusLabel(noNumbers), 'Compare with range');
  assert.match(statusHint(noNumbers)!, /no numbers to place this against/);
  assert.doesNotMatch(statusHint(noNumbers)!, /either side/);
  const word = result({ status: null, value: null, valueText: 'Negative', range: { low: null, high: null, text: 'Negative', kind: 'lab' } });
  assert.match(statusHint(word)!, /a word, not a number/);
  const bound = result({ status: null, value: 2, valueText: '<2', qualifier: '<', range: { low: 1, high: 3, text: '1-3', kind: 'lab' } });
  assert.match(statusHint(bound)!, /Printed as <2, which could fall on either side/);
  const none = result({ status: null, range: null });
  assert.equal(statusLabel(none), 'No range printed');
});

test("a marker's chart says the reason each result isn't drawn, not always the unit", () => {
  // The demo's hs-CRP: 1.4, then "<0.3". Only one exact value, and the reason is the "<", not a unit.
  const crp = [result({ id: 'a', valueText: '1.4', value: 1.4 }), result({ id: 'b', valueText: '<0.3', value: 0.3, qualifier: '<' })];
  const reasons = undrawnReasons({ history: crp, latest: crp[1], points: [{ id: 'a', date: '2026-01-01', value: 1.4 }] });
  assert.deepEqual(reasons, ['One result is printed with < or >, so it has no exact value to draw.']);
  const mixed = [
    result({ id: 'a', value: 40, unit: 'mg/dL' }),
    result({ id: 'b', value: null, valueText: 'Negative', unit: '' }),
    result({ id: 'c', value: 90, unit: 'nmol/L' }),
    result({ id: 'd', value: 60, unit: 'nmol/L' }),
  ];
  const r2 = undrawnReasons({ history: mixed, latest: mixed[3], points: [{ id: 'c', date: 'x', value: 90 }, { id: 'd', date: 'x', value: 60 }] });
  assert.equal(r2.length, 2);
  assert.match(r2[0], /^One result is a word, not a number/);
  assert.match(r2[1], /^One result is in a unit that can't be put on the same scale as the latest result \(nmol\/L\)/);
  assert.doesNotMatch(r2.join(' '), /< or >/);
});

test('rows read from a report are checked one collection per date and lab, with an unusable date kept apart', () => {
  const row = (o: Partial<LabDraft>): LabDraft => ({ collected: '2026-03-01', name: 'Glucose', valueText: '90', unit: 'mg/dL', refText: '70-99', lab: 'Quest', panel: '', biomarker: 'glucose', ...o });
  const groups = draftGroups([
    row({}),
    row({ name: 'TSH', lab: '' }),
    row({ name: 'HbA1c', lab: 'LabCorp' }),
    row({ collected: '2026-02-01', lab: '' }),
    row({ collected: null, lab: '' }),
    row({ collected: null, lab: '', dateDropped: true }),
  ]);
  assert.deepEqual(
    groups.map((g) => [g.collected, g.lab, g.dateDropped, g.rows.map((r) => r.name).join(',')]),
    [
      ['2026-03-01', 'Quest', false, 'Glucose'],
      ['2026-03-01', 'LabCorp', false, 'HbA1c'],
      ['2026-03-01', '', false, 'TSH'],
      ['2026-02-01', '', false, 'Glucose'],
      ['', '', false, 'Glucose'],
      ['', '', true, 'Glucose'],
    ],
  );
  // One named lab on a day: a row with the lab left blank joins it.
  assert.deepEqual(
    draftGroups([row({}), row({ name: 'TSH', lab: '' })]).map((g) => [g.lab, g.rows.length]),
    [['Quest', 2]],
  );
});

test("a HEIC photo this browser can't open gets advice that works for the photo in hand", async () => {
  await assert.rejects(prepareReport(new File([new Uint8Array(2_000_000)], 'IMG_0001.HEIC', { type: 'image/heic' })), (e: Error) => {
    assert.match(e.message, /screenshot of the photo/);
    assert.match(e.message, /JPEG/);
    assert.doesNotMatch(e.message, /Settings|Most Compatible/, "a camera setting changes new photos, not this one");
    return true;
  });
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

// ---------- urine panels, banded ranges and unusable dates (a fresh member, so the tests above aren't touched) ----------

const carol = new Client();
let carolId = '';

test('setup: another invited member', async () => {
  const inv = await owner.call('POST', '/api/admin/invites', {});
  const token = inv.json.url.split('/').at(-1);
  assert.equal((await carol.call('POST', '/api/auth/invite', { token, email: 'carol@example.com', name: 'Carol', password: 'carol password 123' })).status, 200);
  carolId = (await carol.call('GET', '/api/auth/me')).json.user.id;
});

test('a urinalysis beside a blood panel stays apart from the blood markers, and one request keeps its order', async () => {
  const r = await carol.add([
    { collected: ago(4), name: 'Glucose', valueText: '94', unit: 'mg/dL', refText: '70-99', panel: 'Metabolic' },
    { collected: ago(4), name: 'Glucose', valueText: 'Negative', refText: 'Negative', panel: 'Urinalysis' },
    { collected: ago(4), name: 'WBC', valueText: '6.1', unit: 'x10E3/uL', refText: '3.4-10.8', panel: 'CBC' },
    { collected: ago(4), name: 'WBC', valueText: '0-5', unit: '/hpf', refText: '0-5', panel: 'Microscopic Examination' },
    { collected: ago(3), name: 'Glucose', valueText: '90', unit: 'mg/dL', refText: '70-99', panel: 'Metabolic' },
    { collected: ago(3), name: 'Glucose', valueText: '91', unit: 'mg/dL', refText: '70-99', panel: 'Metabolic' },
  ]);
  assert.equal(r.status, 200, r.text);
  // Rows from one request are stored one millisecond apart, in the order sent: a same-day tie is never a coin toss.
  const stored = await db.query<{ id: string; created_at: number }>('SELECT id, created_at FROM lab_results WHERE user_id = $1', [carolId]);
  const at = r.json.ids.map((id: string) => Number(stored.find((s) => s.id === id)!.created_at));
  assert.ok(
    at.every((t: number, i: number) => i === 0 || t > at[i - 1]),
    'created_at rises with the row index',
  );
  const data = (await carol.labs()).json;
  const m = (key: string) => data.markers.find((x: { key: string }) => x.key === key);
  assert.deepEqual(
    m('glucose').history.map((h: { valueText: string }) => h.valueText),
    ['94', '90', '91'],
    'only blood glucose, the later same-day row last',
  );
  assert.equal(m('glucose').latest.valueText, '91');
  assert.equal(m('glucose').points.length, 3);
  assert.equal(m('glucose').otherUnits, 0);
  assert.deepEqual([m('other:urine-glucose').name, m('other:urine-glucose').latest.valueText], ['Glucose (urine)', 'Negative']);
  assert.deepEqual([m('wbc').latest.valueText, m('wbc').history.length], ['6.1', 1]);
  assert.equal(m('other:urine-wbc').latest.unit, '/hpf');

  // A catalog key can't be forced onto a urine result, and moving a result onto a urine panel matches it again.
  const forced = await carol.add([{ collected: ago(4), name: 'Glucose', valueText: '1+', panel: 'Urinalysis', biomarker: 'glucose' }]);
  assert.equal(forced.status, 400);
  assert.match(forced.json.error, /results\[0\]\.biomarker: the catalog's markers are blood tests/);
  const moved = await carol.call('PATCH', `/api/labs/${m('glucose').latest.id}`, { panel: 'Urinalysis' });
  assert.equal(moved.status, 200);
  assert.equal(moved.json.result.biomarker, 'other:urine-glucose');
});

test('a range printed in bands is read for the sex in the profile, and never as its first band', async () => {
  const r = await carol.add([
    { collected: ago(2), name: 'Hemoglobin', valueText: '12.5', unit: 'g/dL', refText: 'Male: 13.0-17.0 Female: 12.0-15.0', panel: 'CBC' },
    { collected: ago(2), name: 'Platelets', valueText: '250,000', unit: '/uL', refText: '150,000-450,000', panel: 'CBC' },
  ]);
  assert.equal(r.status, 200, r.text);
  const [row] = await db.query<{ ref_low: number | null; ref_high: number | null }>('SELECT ref_low, ref_high FROM lab_results WHERE user_id = $1 AND id = $2', [carolId, r.json.ids[0]]);
  assert.deepEqual([row.ref_low, row.ref_high], [null, null], 'no band is stored: it is picked each time it is read');
  const hgb = async () => (await carol.labs()).json.markers.find((x: { key: string }) => x.key === 'hemoglobin').latest;

  const none = await hgb();
  assert.deepEqual([none.status, none.range], [null, { low: null, high: null, text: 'Male: 13.0-17.0 Female: 12.0-15.0', kind: 'lab', band: null }]);
  await carol.call('PUT', '/api/settings', { sex: 'female' });
  const female = await hgb();
  assert.deepEqual([female.status, female.range.low, female.range.high, female.range.band], ['within', 12, 15, 'female']);
  await carol.call('PUT', '/api/settings', { sex: 'male' });
  const male = await hgb();
  assert.deepEqual([male.status, male.range.band], ['below', 'male']);
  await carol.call('PUT', '/api/settings', { sex: null });

  const plt = (await carol.labs()).json.markers.find((x: { key: string }) => x.key === 'platelets').latest;
  assert.deepEqual([plt.value, plt.range.low, plt.range.high, plt.status], [250000, 150000, 450000, 'within']);
});

test("a date read from a report that can't be used is flagged, and a urinalysis row isn't matched to a blood marker", async () => {
  script = [
    extracted([
      { ...ROW, collected: '2026-02-30' },
      { ...ROW, name: 'TSH', collected: null },
      { ...ROW, panel: 'Urinalysis', value_text: 'Negative', unit: '', ref_text: 'Negative', ref_low: null, ref_high: null },
    ]),
  ];
  const r = await carol.extract('application/pdf', pdf(2000));
  assert.equal(r.status, 200, r.text);
  assert.deepEqual([r.json.rows[0].collected, r.json.rows[0].dateDropped], [null, true], 'a date was read, but it is not a real one');
  assert.deepEqual([r.json.rows[1].collected, 'dateDropped' in r.json.rows[1]], [null, false], 'the report showed no date');
  assert.equal(r.json.rows[2].biomarker, null, 'a urinalysis glucose is not blood glucose');
  assert.equal(r.json.rows[2].collected, ago(2));
  assert.ok(!('dateDropped' in r.json.rows[2]));
});
