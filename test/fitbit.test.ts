// POST /api/fitbit/import, /import/finish and /clear: a Fitbit export's per-day readings, sent from the browser in chunks,
// checked, stored as source 'fitbit' for the signed-in person only, and removable without touching other sources.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { AddressInfo } from 'node:net';
import { createApp } from '../server/app.ts';
import { hashPassword } from '../server/auth.ts';
import { OWNER_ID, upsertDaily } from '../server/db.ts';
import { openStore } from '../server/store.ts';

process.env.SESSION_SECRET = 'fitbit-test-secret-'.padEnd(64, 'x');
process.env.HEALTHOS_PASSWORD_HASH = await hashPassword('owner password 123');

const db = await openStore();
const server = createApp({ db, hosted: false }).listen(0, '127.0.0.1');
await new Promise((r) => server.once('listening', r));
const base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
test.after(() => {
  server.close();
});

class Client {
  cookie = '';
  async call(method: string, path: string, body?: unknown, headers: Record<string, string> = { 'X-HealthOS': '1' }) {
    const res = await fetch(base + path, {
      method,
      headers: { 'Content-Type': 'application/json', ...(this.cookie ? { Cookie: this.cookie } : {}), ...headers },
      body: body === undefined ? undefined : typeof body === 'string' ? body : JSON.stringify(body),
    });
    const set = res.headers.get('set-cookie');
    if (set) this.cookie = set.split(';')[0];
    return { status: res.status, json: (await res.json().catch(() => null)) as any };
  }
  post = (p: string, b: unknown = {}) => this.call('POST', p, b);
  get = (p: string) => this.call('GET', p);
}

const owner = new Client();
const bob = new Client();
let bobId = '';

const day = (back: number) => new Date(Date.now() - back * 86_400_000).toISOString().slice(0, 10);
const D1 = day(3);
const D2 = day(2);

/** A night from 23:00 the day before to 06:30 on the wake date, in Chicago's summer offset. */
function night(date: string) {
  const prev = new Date(Date.parse(date + 'T00:00:00Z') - 86_400_000).toISOString().slice(0, 10);
  return {
    date,
    start: `${prev}T23:00:00-05:00`,
    end: `${date}T06:30:00-05:00`,
    segments: [
      { start: `${prev}T23:00:00-05:00`, end: `${prev}T23:10:00-05:00`, stage: 'awake' },
      { start: `${prev}T23:10:00-05:00`, end: `${date}T01:00:00-05:00`, stage: 'light' },
      { start: `${date}T01:00:00-05:00`, end: `${date}T02:30:00-05:00`, stage: 'deep' },
      { start: `${date}T02:30:00-05:00`, end: `${date}T06:30:00-05:00`, stage: 'rem' },
    ],
  };
}

const chunk = {
  daily: [
    { date: D1, metric: 'resting_hr', value: 52.4 },
    { date: D1, metric: 'hr_avg', value: 68.1 },
    { date: D1, metric: 'sleep_hours', value: 7.2 },
    { date: D1, metric: 'weight', value: 75.3 },
    { date: D2, metric: 'resting_hr', value: 53 },
    { date: D2, metric: 'hrv_rmssd', value: 41.5 },
  ],
  sleep: [night(D1)],
};

const rows = (userId: string, table = 'daily') => db.query<Record<string, unknown>>(`SELECT * FROM ${table} WHERE user_id = $1 AND source = 'fitbit' ORDER BY 1, 2, 3`, [userId]);
const version = async (c: Client) => (await c.get('/api/version')).json.version as string | null;

test('importing needs a signed-in person and the X-HealthOS header', async () => {
  assert.equal((await owner.post('/api/fitbit/import', chunk)).status, 401);
  assert.equal((await owner.post('/api/auth/login', { email: 'owner@example.com', password: 'owner password 123' })).status, 200);
  assert.equal((await owner.call('POST', '/api/fitbit/import', chunk, {})).status, 403);
  assert.equal((await rows(OWNER_ID)).length, 0);

  const inv = await owner.post('/api/admin/invites', { email: 'bob@example.com', role: 'user' });
  const token = String(inv.json.url).split('/').at(-1);
  assert.equal((await bob.post('/api/auth/invite', { token, email: 'bob@example.com', name: 'Bob', password: 'bob password 123' })).status, 200);
  bobId = (await bob.get('/api/auth/me')).json.user.id;
});

test('a chunk is stored as Fitbit: the day rows, the night stretches and one sleep record per night', async () => {
  const before = await version(owner);
  const res = await owner.post('/api/fitbit/import', chunk);
  assert.equal(res.status, 200);
  assert.deepEqual(res.json, { ok: true, daily: 6, nights: 1, dropped: 0 });
  assert.notEqual(await version(owner), before);
  const daily = await rows(OWNER_ID);
  assert.equal(daily.length, 6);
  assert.ok(daily.every((r) => r.source === 'fitbit'));
  const events = await db.query<{ id: string; kind: string; date: string; start: string }>("SELECT id, kind, date, start FROM events WHERE user_id = $1 AND source = 'fitbit'", [OWNER_ID]);
  assert.deepEqual(events.map((e) => [e.id, e.kind, e.date]), [[`fitbit-sleep-${D1}`, 'sleep', D1]]);
  assert.equal((await rows(OWNER_ID, 'sleep_stages')).length, 4);

  // Until the import finishes, Integrations shows no import.
  assert.equal((await owner.get('/api/status')).json.fitbit.lastImport, null);
});

test('the readings show like any other source, and the night on the Sleep page', async () => {
  const trends = (await owner.get('/api/trends?metrics=resting_hr,hrv_rmssd&days=7')).json;
  assert.deepEqual(trends.resting_hr.map((p: { date: string; value: number }) => [p.date, p.value]), [[D1, 52.4], [D2, 53]]);
  assert.deepEqual(trends.hrv_rmssd.map((p: { date: string }) => p.date), [D2]);
  const n = (await owner.get(`/api/sleep/night?date=${D1}`)).json;
  assert.equal(n.fellAsleep, chunk.sleep[0].start);
  assert.deepEqual(n.segments.map((g: { stage: string }) => g.stage), ['awake', 'light', 'deep', 'rem']);
});

test('importing the same export again updates its days and replaces its nights instead of adding to them', async () => {
  const again = { ...chunk, daily: chunk.daily.map((r) => (r.metric === 'resting_hr' && r.date === D1 ? { ...r, value: 51 } : r)) };
  assert.equal((await owner.post('/api/fitbit/import', again)).status, 200);
  assert.equal((await owner.post('/api/fitbit/import', again)).status, 200);
  let daily = await rows(OWNER_ID);
  assert.equal(daily.length, 6);
  assert.equal(daily.find((r) => r.date === D1 && r.metric === 'resting_hr')!.value, 51);
  assert.equal((await rows(OWNER_ID, 'events')).length, 1);
  assert.equal((await rows(OWNER_ID, 'sleep_stages')).length, 4);

  // Another part of a split export, sent later, bringing only the night's sleep: the day's other readings stay.
  assert.equal((await owner.post('/api/fitbit/import', { daily: [{ date: D1, metric: 'sleep_hours', value: 7.4 }], sleep: [night(D1)] })).status, 200);
  daily = await rows(OWNER_ID);
  assert.equal(daily.length, 6);
  assert.equal(daily.find((r) => r.date === D1 && r.metric === 'sleep_hours')!.value, 7.4);
  assert.equal(daily.find((r) => r.date === D1 && r.metric === 'weight')!.value, 75.3);
});

test('finishing keeps the summary Integrations shows, of what is stored', async () => {
  const before = await version(owner);
  // The browser's summary of this run leaves out weight; the stored days have it, and the summary is theirs.
  const res = await owner.post('/api/fitbit/import/finish', { days: 2, firstDate: D1, lastDate: D2, metrics: ['resting_hr', 'hr_avg', 'sleep_hours', 'hrv_rmssd'] });
  assert.equal(res.status, 200);
  assert.notEqual(await version(owner), before);
  const last = (await owner.get('/api/status')).json.fitbit.lastImport;
  assert.deepEqual(res.json.lastImport, last);
  assert.deepEqual({ ...last, importedAt: typeof last.importedAt }, { days: 2, firstDate: D1, lastDate: D2, metrics: ['hr_avg', 'hrv_rmssd', 'resting_hr', 'sleep_hours', 'weight'], importedAt: 'string' });
  assert.ok(Date.now() - Date.parse(last.importedAt) < 60_000);
  assert.equal((await owner.post('/api/fitbit/import/finish', { days: -1, firstDate: null, lastDate: null, metrics: [] })).status, 400);
  assert.equal((await owner.post('/api/fitbit/import/finish', { days: 1, firstDate: 'yesterday', lastDate: null, metrics: [] })).status, 400);
  assert.equal((await owner.post('/api/fitbit/import/finish', { days: 1, firstDate: null, lastDate: null, metrics: ['strain'] })).status, 400);
});

test('a chunk with anything a Fitbit export cannot hold is refused whole', async () => {
  const bad: [string, unknown][] = [
    ['not an object', []],
    ['unknown metric', { daily: [{ date: D1, metric: 'strain', value: 10 }] }],
    ['an Apple metric', { daily: [{ date: D1, metric: 'active_energy', value: 10 }] }],
    ['out of range', { daily: [{ date: D1, metric: 'resting_hr', value: 400 }] }],
    ['negative steps', { daily: [{ date: D1, metric: 'steps', value: -1 }] }],
    ['a string value', { daily: [{ date: D1, metric: 'steps', value: '100' }] }],
    ['not a date', { daily: [{ date: '2026-02-30', metric: 'steps', value: 100 }] }],
    ['a future date', { daily: [{ date: day(-5), metric: 'steps', value: 100 }] }],
    ['before Fitbit', { daily: [{ date: '1999-01-01', metric: 'steps', value: 100 }] }],
    ['an unknown stage', { sleep: [{ ...night(D1), segments: [{ ...night(D1).segments[0], stage: 'in_bed' }] }] }],
    ['a night twice', { sleep: [night(D1), night(D1)] }],
    ['a night ending before it starts', { sleep: [{ ...night(D1), end: night(D1).start }] }],
    ['a time without offset', { sleep: [{ ...night(D1), start: `${D1}T01:00:00` }] }],
  ];
  for (const [why, body] of bad) {
    const res = await owner.post('/api/fitbit/import', body);
    assert.equal(res.status, 400, why);
    assert.equal(typeof res.json.error, 'string', why);
  }
  assert.equal((await rows(OWNER_ID)).length, 6, 'nothing was written');
});

test('stretches that are empty or overlap the one before are left out, and counted', async () => {
  const n = night(D2);
  const odd = { ...n, segments: [...n.segments, { ...n.segments[1] }, { start: n.segments[0].start, end: n.segments[0].start, stage: 'awake' }] };
  const res = await bob.post('/api/fitbit/import', { daily: [{ date: D2, metric: 'sleep_hours', value: 7 }], sleep: [odd] });
  assert.equal(res.status, 200);
  assert.equal(res.json.dropped, 2);
  assert.equal((await rows(bobId, 'sleep_stages')).length, 4);
});

test('a body over 4 MB is refused with plain words', async () => {
  const big = JSON.stringify({ daily: [], pad: 'x'.repeat(4_300_000) });
  const res = await owner.call('POST', '/api/fitbit/import', big);
  assert.equal(res.status, 413);
  assert.match(res.json.error, /4 MB/);
});

test("each person's import is their own; removing Fitbit data leaves other sources and other people alone", async () => {
  // Bob's chunk landed in his account only.
  assert.equal((await rows(bobId)).length, 1);
  assert.equal((await rows(OWNER_ID)).length, 6);
  assert.equal((await bob.get('/api/status')).json.fitbit.lastImport, null);

  await upsertDaily(db, OWNER_ID, [{ date: D1, metric: 'sleep_hours', source: 'apple', value: 6.9 }]);
  const res = await owner.post('/api/fitbit/clear');
  assert.equal(res.status, 200);
  for (const table of ['daily', 'events', 'sleep_stages']) assert.equal((await rows(OWNER_ID, table)).length, 0, table);
  assert.equal((await owner.get('/api/status')).json.fitbit.lastImport, null);
  const apple = await db.query("SELECT value FROM daily WHERE user_id = $1 AND source = 'apple' AND date = $2 AND metric = 'sleep_hours'", [OWNER_ID, D1]);
  assert.equal(apple.length, 1, "Apple's night stays");
  assert.equal((await rows(bobId)).length, 1, "Bob's import stays");
  assert.equal((await rows(bobId, 'sleep_stages')).length, 4);
});

test("a split export imported one part at a time: the summary spans every part, not just the last one's", async () => {
  // Part 1 (2016) and part 2 (2020), each finished on its own run, as Import again does; the browser's summary is the run's.
  const part1 = [
    { date: '2016-03-01', metric: 'steps', value: 9100 },
    { date: '2016-03-02', metric: 'steps', value: 7400 },
  ];
  assert.equal((await owner.post('/api/fitbit/import', { daily: part1 })).status, 200);
  assert.equal((await owner.post('/api/fitbit/import/finish', { days: 2, firstDate: '2016-03-01', lastDate: '2016-03-02', metrics: ['steps'] })).status, 200);
  const part2 = [{ date: '2020-05-01', metric: 'resting_hr', value: 55 }];
  assert.equal((await owner.post('/api/fitbit/import', { daily: part2 })).status, 200);
  assert.equal((await owner.post('/api/fitbit/import/finish', { days: 1, firstDate: '2020-05-01', lastDate: '2020-05-01', metrics: ['resting_hr'] })).status, 200);
  const last = (await owner.get('/api/status')).json.fitbit.lastImport;
  assert.deepEqual([last.days, last.firstDate, last.lastDate, last.metrics], [3, '2016-03-01', '2020-05-01', ['resting_hr', 'steps']]);
  // Someone else's import doesn't count towards it, and theirs is their own.
  assert.equal((await bob.post('/api/fitbit/import/finish', { days: 0, firstDate: null, lastDate: null, metrics: [] })).status, 200);
  const bobs = (await bob.get('/api/status')).json.fitbit.lastImport;
  assert.deepEqual([bobs.days, bobs.firstDate, bobs.lastDate, bobs.metrics], [1, D2, D2, ['sleep_hours']]);
});
