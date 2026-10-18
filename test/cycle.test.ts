// Cycle tracking: estimates from a person's own history, the Apple Health import, and over HTTP who can see
// what: hidden while tracking is off, never across accounts, never in the admin view or the summary.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { Readable } from 'node:stream';
import type { AddressInfo } from 'node:net';
import type { CycleDay } from '../shared/types.ts';
import { importAppleHealth, parseStream } from '../server/apple/import.ts';
import { createApp } from '../server/app.ts';
import { hashPassword } from '../server/auth.ts';
import { analyzeCycle, cyclePhase, temperatureShift, upsertCycle } from '../server/cycle.ts';
import { addDays, todayLocal } from '../server/dates.ts';
import { OWNER_ID, deleteSource } from '../server/db.ts';
import type { McflyClient } from '../server/mcfly.ts';
import { openStore } from '../server/store.ts';

// ---------- estimates ----------

/** Five days of flow from each start. */
const periodsFrom = (...starts: string[]): CycleDay[] =>
  starts.flatMap((s) => (['medium', 'heavy', 'medium', 'light', 'light'] as const).map((flow, i) => ({ date: addDays(s, i), flow })));

test('28-day cycles give a next period, ovulation and fertile window', () => {
  const a = analyzeCycle(periodsFrom('2026-07-01', '2026-07-29', '2026-08-26'), '2026-09-10');
  assert.deepEqual(
    a.periods.map((p) => [p.start, p.end, p.days]),
    [
      ['2026-07-01', '2026-07-05', 5],
      ['2026-07-29', '2026-08-02', 5],
      ['2026-08-26', '2026-08-30', 5],
    ],
  );
  assert.deepEqual(a.cycles, [
    { start: '2026-07-01', days: 28 },
    { start: '2026-07-29', days: 28 },
  ]);
  assert.deepEqual(a.stats, { cycleDays: 28, periodDays: 5, shortest: 28, longest: 28 });
  assert.deepEqual(a.current, { start: '2026-08-26', day: 16 });
  assert.deepEqual(a.estimate, {
    nextPeriod: { date: '2026-09-23', earliest: '2026-09-21', latest: '2026-09-25' },
    ovulation: '2026-09-09',
    fertile: { start: '2026-09-04', end: '2026-09-10' },
    basis: 'calendar',
    cycles: 2,
  });
  assert.equal(a.noEstimate, null);
});

test('no estimate before two complete cycles, or once the latest period is long past', () => {
  const one = analyzeCycle(periodsFrom('2026-07-29', '2026-08-26'), '2026-09-10');
  assert.equal(one.estimate, null);
  assert.equal(one.noEstimate, 'cycles');
  assert.deepEqual(one.current, { start: '2026-08-26', day: 16 });
  const stale = analyzeCycle(periodsFrom('2026-07-01', '2026-07-29', '2026-08-26'), '2026-12-01');
  assert.equal(stale.estimate, null);
  assert.equal(stale.noEstimate, 'stale');
  assert.equal(analyzeCycle([], '2026-09-10').noEstimate, 'cycles');
});

test('a marked first day wins over flow logged the day before; spotting and a skipped day start nothing', () => {
  const days: CycleDay[] = [
    ...periodsFrom('2026-07-01'),
    { date: '2026-07-15', spotting: true },
    { date: '2026-07-28', flow: 'light' },
    { date: '2026-07-29', flow: 'heavy', periodStart: true },
    { date: '2026-07-31', flow: 'medium' }, // after a day with nothing logged: still the same period
    { date: '2026-08-26', flow: 'none' }, // logged "no flow" isn't bleeding
  ];
  const a = analyzeCycle(days, '2026-08-27');
  assert.deepEqual(
    a.periods.map((p) => [p.start, p.end]),
    [
      ['2026-07-01', '2026-07-05'],
      ['2026-07-29', '2026-07-31'],
    ],
  );
});

test("an LH surge this cycle moves ovulation and the next period; past cycles' luteal phase is used", () => {
  const history = periodsFrom('2026-07-01', '2026-07-29', '2026-08-26');
  // Last cycle: surge on 08-12, so ovulation 08-13 and 13 days to the 08-26 period.
  const past: CycleDay = { date: '2026-08-12', ovulationTest: 'lh_surge' };
  const calendar = analyzeCycle([...history, past], '2026-09-05');
  assert.deepEqual(calendar.ovulations, [{ date: '2026-08-13', basis: 'lh_test' }]);
  assert.equal(calendar.estimate?.ovulation, '2026-09-10'); // 09-23 less 13, not 14
  assert.equal(calendar.estimate?.basis, 'calendar');

  const surged = analyzeCycle([...history, past, { date: '2026-09-07', ovulationTest: 'negative' }, { date: '2026-09-11', ovulationTest: 'lh_surge' }], '2026-09-14');
  assert.equal(surged.estimate?.basis, 'lh_test');
  assert.equal(surged.estimate?.ovulation, '2026-09-12');
  assert.deepEqual(surged.estimate?.nextPeriod, { date: '2026-09-25', earliest: '2026-09-23', latest: '2026-09-27' });
  assert.deepEqual(surged.estimate?.fertile, { start: '2026-09-07', end: '2026-09-13' });
});

test('a basal temperature rise (three over six) marks ovulation the day before it', () => {
  const temps = (from: string, values: number[]): CycleDay[] => values.map((bbt, i) => ({ date: addDays(from, i), bbt }));
  assert.equal(temperatureShift(temps('2026-08-31', [36.3, 36.35, 36.3, 36.25, 36.3, 36.3, 36.3, 36.4, 36.45, 36.6])), '2026-09-06');
  // Higher, but the third reading isn't 0.2 °C above the six before: not a shift.
  assert.equal(temperatureShift(temps('2026-08-31', [36.3, 36.35, 36.3, 36.25, 36.3, 36.3, 36.4, 36.4, 36.45])), null);
  const a = analyzeCycle(
    [...periodsFrom('2026-07-01', '2026-07-29', '2026-08-26'), ...temps('2026-08-31', [36.3, 36.35, 36.3, 36.25, 36.3, 36.3, 36.3, 36.4, 36.45, 36.6])],
    '2026-09-10',
  );
  assert.equal(a.estimate?.basis, 'bbt');
  assert.equal(a.estimate?.ovulation, '2026-09-06');
});

// ---------- where today falls ----------

const phaseOn = (days: CycleDay[], today: string) => cyclePhase(analyzeCycle(days, today), days, today);

test('the phase follows the cycle: menstrual, follicular, ovulatory, luteal', () => {
  const days = periodsFrom('2026-07-01', '2026-07-29', '2026-08-26');
  // Next period estimated 09-23, ovulation 09-09, fertile 09-04 to 09-10.
  assert.deepEqual(phaseOn(days, '2026-08-27'), { name: 'menstrual', day: 2, nextPeriodIn: 27, basis: 'logged' });
  assert.deepEqual(phaseOn(days, '2026-09-01'), { name: 'follicular', day: 7, nextPeriodIn: 22, basis: 'estimate' });
  assert.deepEqual(phaseOn(days, '2026-09-06'), { name: 'ovulatory', day: 12, nextPeriodIn: 17, basis: 'estimate' });
  assert.deepEqual(phaseOn(days, '2026-09-15'), { name: 'luteal', day: 21, nextPeriodIn: 8, basis: 'estimate' });
  // A late period reads as due, not a negative count.
  assert.equal(phaseOn(days, '2026-09-27')?.nextPeriodIn, 0);
});

test('menstrual needs bleeding logged this period; an LH surge makes the luteal phase logged; no cycle, no phase', () => {
  const history = periodsFrom('2026-07-01', '2026-07-29');
  // Only the first day logged so far: still menstrual within the usual 5 days, not after.
  const firstDay: CycleDay[] = [...history, { date: '2026-08-26', flow: 'medium' }];
  assert.equal(phaseOn(firstDay, '2026-08-29')?.name, 'menstrual');
  assert.equal(phaseOn(firstDay, '2026-09-01')?.name, 'follicular');
  // A start marked with no bleeding logged isn't a period day.
  assert.equal(phaseOn([...history, { date: '2026-08-26', periodStart: true }], '2026-08-27')?.name, 'follicular');

  const surged = [...periodsFrom('2026-07-01', '2026-07-29', '2026-08-26'), { date: '2026-09-11', ovulationTest: 'lh_surge' as const }];
  assert.deepEqual(phaseOn(surged, '2026-09-12'), { name: 'ovulatory', day: 18, nextPeriodIn: 14, basis: 'logged' });
  assert.deepEqual(phaseOn(surged, '2026-09-14'), { name: 'luteal', day: 20, nextPeriodIn: 12, basis: 'logged' });

  assert.equal(phaseOn([], '2026-09-10'), null);
  assert.equal(phaseOn(periodsFrom('2026-07-01', '2026-07-29', '2026-08-26'), '2026-12-01'), null, 'long past');
});

// ---------- Apple Health export ----------

const rec = (type: string, start: string, value: string, extra = '', children = '') =>
  `<Record type="${type}" sourceName="${extra || 'Health'}" startDate="${start} -0500" endDate="${start} -0500" value="${value}"${children ? `>${children}</Record>` : '/>'}`;
const meta = (key: string, value: string) => `<MetadataEntry key="${key}" value="${value}"/>`;

const EXPORT = `<?xml version="1.0" encoding="UTF-8"?>
<HealthData locale="en_US">
 ${rec('HKCategoryTypeIdentifierMenstrualFlow', '2026-09-01 00:00:00', 'HKCategoryValueVaginalBleedingMedium', '', meta('HKMenstrualCycleStart', '1'))}
 ${rec('HKCategoryTypeIdentifierMenstrualFlow', '2026-09-02 00:00:00', 'HKCategoryValueMenstrualFlowHeavy', '', meta('HKMenstrualCycleStart', '0'))}
 ${rec('HKCategoryTypeIdentifierMenstrualFlow', '2026-09-02 08:00:00', 'HKCategoryValueMenstrualFlowLight', 'Clue')}
 ${rec('HKCategoryTypeIdentifierMenstrualFlow', '2026-09-03 00:00:00', '2')}
 ${rec('HKCategoryTypeIdentifierMenstrualFlow', '2026-09-05 00:00:00', 'HKCategoryValueMenstrualFlowHeavy', 'WHOOP')}
 ${rec('HKCategoryTypeIdentifierIntermenstrualBleeding', '2026-09-10 00:00:00', 'HKCategoryValueNotApplicable')}
 ${rec('HKCategoryTypeIdentifierOvulationTestResult', '2026-09-13 07:00:00', '1')}
 ${rec('HKCategoryTypeIdentifierOvulationTestResult', '2026-09-14 07:00:00', 'HKCategoryValueOvulationTestResultLuteinizingHormoneSurge')}
 ${rec('HKCategoryTypeIdentifierCervicalMucusQuality', '2026-09-14 07:00:00', 'HKCategoryValueCervicalMucusQualityEggWhite')}
 ${rec('HKCategoryTypeIdentifierSexualActivity', '2026-09-14 22:00:00', 'HKCategoryValueNotApplicable', '', meta('HKSexualActivityProtectionUsed', '0'))}
 ${rec('HKCategoryTypeIdentifierSexualActivity', '2026-09-20 22:00:00', 'HKCategoryValueNotApplicable')}
 <Record type="HKQuantityTypeIdentifierBasalBodyTemperature" sourceName="Health" unit="degF" startDate="2026-09-14 06:30:00 -0500" endDate="2026-09-14 06:30:00 -0500" value="97.7"/>
 <Record type="HKQuantityTypeIdentifierBasalBodyTemperature" sourceName="Health" unit="degF" startDate="2026-09-14 09:30:00 -0500" endDate="2026-09-14 09:30:00 -0500" value="98.6"/>
 <Record type="HKQuantityTypeIdentifierStepCount" sourceName="iPhone" unit="count" startDate="2026-09-14 10:00:00 -0500" endDate="2026-09-14 10:05:00 -0500" value="100">${meta('HKMenstrualCycleStart', '1')}</Record>
</HealthData>`;

test('the importer reads cycle records, old and new spellings, into the cycle table only', async () => {
  const db = await openStore();
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'healthos-cycle-'));
  const file = path.join(dir, 'export.xml');
  fs.writeFileSync(file, EXPORT);
  await upsertCycle(db, OWNER_ID, [{ date: '2026-09-02', kind: 'flow', source: 'manual', value: 'light' }]);
  try {
    await importAppleHealth({ db, userId: OWNER_ID }, file);
    await importAppleHealth({ db, userId: OWNER_ID }, file); // a re-import replaces, rather than doubles, Apple's rows
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
  const rows = await db.query<{ date: string; kind: string; source: string; value: string }>('SELECT date, kind, source, value FROM cycle ORDER BY date, kind, source');
  assert.deepEqual(
    rows.map((r) => `${r.date} ${r.kind} ${r.source} ${r.value}`),
    [
      '2026-09-01 flow apple medium',
      '2026-09-01 period_start apple 1',
      '2026-09-02 flow apple heavy', // Health's heavy beats Clue's light the same day
      '2026-09-02 flow manual light', // what was logged by hand stays through a re-import
      '2026-09-03 flow apple light', // raw value 2
      '2026-09-10 spotting apple 1',
      '2026-09-13 ovulation_test apple negative',
      '2026-09-14 bbt apple 36.5', // the first reading of the day, in °C
      '2026-09-14 mucus apple egg_white',
      '2026-09-14 ovulation_test apple lh_surge',
      '2026-09-14 sexual_activity apple unprotected',
      '2026-09-20 sexual_activity apple unspecified',
    ],
  );
  // Steps still import, and its stray metadata didn't become a period start.
  const [steps] = await db.query<{ value: number }>("SELECT value FROM daily WHERE metric = 'steps'");
  assert.equal(steps.value, 100);
  assert.equal((await db.query("SELECT 1 FROM daily WHERE metric LIKE '%flow%' OR metric LIKE '%bbt%'")).length, 0);

  // Clearing Apple Health removes its cycle rows too, and leaves manual entries.
  await deleteSource(db, OWNER_ID, 'apple');
  assert.deepEqual(await db.query('SELECT source FROM cycle'), [{ source: 'manual' }]);
});

test("cycle days use the person's own time zone, not the export's one fixed offset", async () => {
  // Made in winter, the export prints a summer day's local midnight (00:00 CDT on Jul 2) as 23:00 the day before.
  const xml = `<HealthData>${rec('HKCategoryTypeIdentifierMenstrualFlow', '2026-07-01 23:00:00', 'HKCategoryValueVaginalBleedingLight').replace('-0500', '-0600').replace('-0500', '-0600')}</HealthData>`;
  const dates = async (timeZone?: string) => (await parseStream(Readable.from([xml]), undefined, { timeZone })).finish().cycle.map((r) => r.date);
  assert.deepEqual(await dates('America/Chicago'), ['2026-07-02']);
  assert.deepEqual(await dates(), ['2026-07-01'], 'without a saved zone, the export offset is all there is');
});

// ---------- over HTTP ----------

process.env.SESSION_SECRET = 'cycle-test-secret-'.padEnd(64, 'x');
const OWNER_PASSWORD = 'owner password 123';
process.env.HEALTHOS_PASSWORD_HASH = await hashPassword(OWNER_PASSWORD);
const OWNER_INGEST = 'owner-ingest-token-0123456789';

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
}

const owner = new Client();
const bob = new Client();
let bobId = '';
// "Today" on the server is this machine's date: the test accounts have no time zone saved.
const today = todayLocal();
const ago = (n: number) => addDays(today, -n);
const ingest = (body: unknown) => owner.call('POST', '/api/apple/ingest', body, { Authorization: `Bearer ${OWNER_INGEST}` });

test('setup: an owner and an invited member', async () => {
  assert.equal((await owner.post('/api/auth/login', { email: 'owner@example.com', password: OWNER_PASSWORD })).status, 200);
  const inv = await owner.post('/api/admin/invites', {});
  const token = inv.json.url.split('/').at(-1);
  assert.equal((await bob.post('/api/auth/invite', { token, email: 'bob@example.com', name: 'Bob', password: 'bob password 123' })).status, 200);
  bobId = (await bob.get('/api/auth/me')).json.user.id;
});

test('while tracking is off, iPhone cycle records are stored but nothing shows them', async () => {
  const settings = (await owner.get('/api/status')).json.settings;
  assert.equal(settings.cycleTracking, false);
  assert.equal(settings.sex, null);

  const days = [56, 28, 0].flatMap((n) => [
    { date: ago(n + 2), flow: 'medium', periodStart: true },
    { date: ago(n + 1), flow: 'heavy' },
  ]);
  const res = await ingest({ cycle: [...days, { date: ago(10), ovulationTest: 'lh_surge', sexualActivity: 'protected', bbt: 36.6 }] });
  assert.equal(res.status, 200);
  assert.equal(res.json.cycle, 7);
  assert.equal((await db.query('SELECT 1 FROM cycle WHERE user_id = $1', [OWNER_ID])).length, 12); // flow and start, flow, x3; three on one day
  // The saved sync summary, shown on the Integrations page, leaves the cycle count out.
  assert.equal((await owner.get('/api/status')).json.apple.lastSync.cycle, undefined);

  const view = await owner.get('/api/cycle');
  assert.equal(view.status, 200);
  assert.equal(view.json.enabled, false);
  assert.deepEqual([view.json.days, view.json.periods, view.json.estimate], [[], [], null]);
  assert.equal((await owner.post('/api/cycle/day', { date: ago(3), flow: 'light' })).status, 403);
});

test('turning tracking on shows the history and estimates', async () => {
  const status = (await owner.call('PUT', '/api/settings', { sex: 'female', cycleTracking: true })).json;
  assert.equal(status.settings.sex, 'female');
  assert.equal(status.settings.cycleTracking, true);
  const view = (await owner.get('/api/cycle')).json;
  assert.equal(view.enabled, true);
  assert.equal(view.today, today);
  assert.equal(view.periods.length, 3);
  assert.deepEqual(
    view.cycles.map((c: { days: number }) => c.days),
    [28, 28],
  );
  assert.deepEqual(view.current, { start: ago(2), day: 3 });
  assert.equal(view.estimate.nextPeriod.date, addDays(ago(2), 28));
  const tested = view.days.find((d: CycleDay) => d.date === ago(10));
  assert.deepEqual(tested, { date: ago(10), ovulationTest: 'lh_surge', sexualActivity: 'protected', bbt: 36.6, apple: { ovulationTest: 'lh_surge', sexualActivity: 'protected', bbt: 36.6 } });
});

test('the cycle view says where today falls, and nothing while tracking is off', async () => {
  // Two days of bleeding logged per period, and today is day 3: past this person's usual period length.
  assert.deepEqual((await owner.get('/api/cycle')).json.phase, { name: 'follicular', day: 3, nextPeriodIn: 26, basis: 'estimate' });
  assert.equal((await bob.get('/api/cycle')).json.phase, null);
});

test('entries made by hand override Apple Health field by field, and validate without echoing values', async () => {
  assert.equal((await owner.post('/api/cycle/day', { date: ago(1), flow: 'light', mucus: 'creamy' })).status, 200);
  let day = (await owner.get('/api/cycle')).json.days.find((d: CycleDay) => d.date === ago(1));
  assert.deepEqual(day, { date: ago(1), flow: 'light', mucus: 'creamy', apple: { flow: 'heavy' }, manual: { flow: 'light', mucus: 'creamy' } });

  // The body is the day's whole manual entry: sending the date alone clears it, and Apple's value shows again.
  assert.equal((await owner.post('/api/cycle/day', { date: ago(1) })).status, 200);
  day = (await owner.get('/api/cycle')).json.days.find((d: CycleDay) => d.date === ago(1));
  assert.deepEqual(day, { date: ago(1), flow: 'heavy', apple: { flow: 'heavy' } });

  const bad = await owner.post('/api/cycle/day', { date: ago(1), flow: 'gushing-secret' });
  assert.equal(bad.status, 400);
  assert.ok(!bad.text.includes('gushing-secret'));
  assert.equal((await owner.post('/api/cycle/day', { date: ago(1), bbt: 98.6 })).status, 400, 'bbt is °C');
  assert.equal((await owner.post('/api/cycle/day', { date: addDays(today, 1), flow: 'light' })).status, 400);
  assert.equal((await owner.post('/api/cycle/day', { date: '2026-02-30', flow: 'light' })).status, 400);
});

test('an iPhone push replaces its own days and leaves manual entries alone', async () => {
  await owner.post('/api/cycle/day', { date: ago(10), spotting: true });
  assert.equal((await ingest({ cycle: [{ date: ago(10) }] })).status, 200);
  const day = (await owner.get('/api/cycle')).json.days.find((d: CycleDay) => d.date === ago(10));
  assert.deepEqual(day, { date: ago(10), spotting: true, manual: { spotting: true } });
  const bad = await ingest({ cycle: [{ date: ago(1), flow: 'torrent' }] });
  assert.equal(bad.status, 400);
  assert.match(bad.json.error, /^cycle\[0\]\.flow: expected one of/);
});

test("nobody else sees a person's cycle data: not another member, not the admin view, not the summary", async () => {
  assert.equal((await bob.get('/api/cycle')).json.enabled, false);
  await bob.call('PUT', '/api/settings', { cycleTracking: true });
  const empty = (await bob.get('/api/cycle')).json;
  assert.equal(empty.enabled, true);
  assert.deepEqual(empty.days, []);
  assert.equal((await bob.post('/api/cycle/day', { date: ago(4), flow: 'medium' })).status, 200);
  assert.deepEqual(
    (await bob.get('/api/cycle')).json.days.map((d: CycleDay) => d.date),
    [ago(4)],
  );
  assert.ok(!(await owner.get('/api/cycle')).json.days.some((d: CycleDay) => d.date === ago(4) && d.flow === 'medium'));

  const overview = (await owner.get('/api/admin/overview')).text;
  for (const word of ['flow', 'heavy', 'lh_surge', 'sexual', 'protected', 'cycle', 'female', 'mucus']) assert.ok(!overview.includes(word), word);
  const summary = (await owner.get('/api/summary')).text;
  for (const word of ['heavy', 'lh_surge', 'protected', 'mucus', 'spotting']) assert.ok(!summary.includes(word), word);
  assert.equal((await bob.get('/api/admin/overview')).status, 403);
});

test('Ask McFly gets the cycle tool only while tracking is on, and it reads only the asker', async () => {
  await owner.post('/api/cycle/day', { date: ago(5), bbt: 36.6 });
  await owner.call('PUT', '/api/settings', { units: 'imperial' });
  requests.length = 0;
  script = [
    reply([{ type: 'tool_use', id: 'tu_1', name: 'get_cycle', input: { days: 120 } }], 'tool_use'),
    reply([{ type: 'text', text: 'Your next period is estimated around then.' }], 'end_turn'),
  ];
  assert.equal((await owner.post('/api/mcfly/chat', { messages: [{ role: 'user', content: 'When is my next period?' }] })).status, 200);
  assert.ok(requests[0].tools.some((t: { name: string }) => t.name === 'get_cycle'));
  assert.match(requests[0].system, /menstrual cycle/);
  const result = JSON.parse(requests[1].messages.at(-1).content[0].content);
  assert.equal(result.periods.length, 3);
  assert.equal(result.estimate.nextPeriod.date, addDays(ago(2), 28));
  assert.ok(!result.entries.some((d: CycleDay) => d.date === ago(4) && d.flow === 'medium'), "Bob's entry isn't in the owner's answer");
  assert.deepEqual(result.entries.find((d: { basalTemp?: unknown }) => d.basalTemp)?.basalTemp, { value: 97.88, unit: '°F' }, 'in their units');

  await owner.call('PUT', '/api/settings', { cycleTracking: false });
  requests.length = 0;
  script = [];
  await owner.post('/api/mcfly/chat', { messages: [{ role: 'user', content: 'When is my next period?' }] });
  assert.ok(!requests[0].tools.some((t: { name: string }) => t.name === 'get_cycle'));
  assert.doesNotMatch(requests[0].system, /menstrual/);
  // A model that asks for the tool anyway gets "unknown tool", not data.
  requests.length = 0;
  script = [reply([{ type: 'tool_use', id: 'tu_2', name: 'get_cycle', input: {} }], 'tool_use'), reply([{ type: 'text', text: 'OK.' }], 'end_turn')];
  await owner.post('/api/mcfly/chat', { messages: [{ role: 'user', content: 'Read my cycle.' }] });
  const refused = requests[1].messages.at(-1).content[0];
  assert.equal(refused.is_error, true);
  assert.match(refused.content, /Unknown tool/);
});

test('delete removes all of one person’s cycle data, whether tracking is on or off', async () => {
  const deleted = await owner.post('/api/cycle/delete');
  assert.equal(deleted.status, 200);
  assert.ok(deleted.json.deleted > 0);
  assert.equal((await db.query('SELECT 1 FROM cycle WHERE user_id = $1', [OWNER_ID])).length, 0);
  assert.equal((await db.query('SELECT 1 FROM cycle WHERE user_id = $1', [bobId])).length, 1, "Bob's stays");

  // Deleting an account takes its cycle data with it.
  assert.equal((await owner.call('DELETE', `/api/admin/users/${bobId}`)).status, 200);
  assert.equal((await db.query('SELECT 1 FROM cycle')).length, 0);
});
