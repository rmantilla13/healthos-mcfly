// A WHOOP strap read by NOOP: its CSV export read in the browser (src/import/noop.ts), sent in chunks to
// POST /api/noop/import, stored as source 'noop' for the signed-in person only, ranked after the WHOOP connection, and
// removable without touching other sources. Every value here is made up, in the layout NOOP's export writes.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { AddressInfo } from 'node:net';
import zlib from 'node:zlib';
import type { Workout } from '../shared/types.ts';
import { createApp } from '../server/app.ts';
import { hashPassword } from '../server/auth.ts';
import { OWNER_ID, upsertDaily } from '../server/db.ts';
import { mergeWorkouts } from '../server/query.ts';
import { openStore } from '../server/store.ts';
import { NoopExportError, noopChunks, noopFinish, noopPreview, noopRows, readNoopZip } from '../src/import/noop.ts';

// ---------- the export, as NOOP writes it ----------

const CYCLES_HEAD =
  'Cycle start time,Cycle end time,Cycle timezone,Recovery score %,Resting heart rate (bpm),Heart rate variability (ms),Skin temp (celsius),' +
  'Blood oxygen %,Day Strain,Energy burned (cal),Max HR (bpm),Average HR (bpm),Sleep onset,Wake onset,Sleep performance %,Respiratory rate (rpm),' +
  'Asleep duration (min),In bed duration (min),Light sleep duration (min),Deep (SWS) duration (min),REM duration (min),Awake duration (min),' +
  'Sleep efficiency %,Sleep consistency %,Sleep need (min),Sleep debt (min),Source';
const SLEEPS_HEAD =
  'Cycle start time,Sleep onset,Wake onset,Cycle timezone,Nap,Sleep performance %,Respiratory rate (rpm),Asleep duration (min),In bed duration (min),' +
  'Light sleep duration (min),Deep (SWS) duration (min),REM duration (min),Awake duration (min),Sleep efficiency %,Sleep consistency %,Sleep need (min),Sleep debt (min),Source';
const WORKOUTS_HEAD =
  'Cycle start time,Workout start time,Workout end time,Cycle timezone,Activity name,Activity Strain,Energy burned (cal),Max HR (bpm),Average HR (bpm),' +
  'HR Zone 1 %,HR Zone 2 %,HR Zone 3 %,HR Zone 4 %,HR Zone 5 %,Distance (meters),Source';

const csv = (head: string, rows: string[]) => [head, ...rows].join('\r\n') + '\r\n';

const exportFiles = {
  cycles: csv(CYCLES_HEAD, [
    '2026-07-14 00:00:00,,UTC+00:00,64,52,48.5,-0.3,96.5,11.2,2410,162,71,,,88,14.6,432,470,220,96,116,38,92,81,480,30,noop (APPROXIMATE)',
    '2026-07-15 00:00:00,,UTC+00:00,70,,,,,8,,,,,,,,,,,,,,,,,,import',
    // Out of range only: not a day.
    '2026-07-16 00:00:00,,UTC+00:00,,400,,,,,,,,,,,,,,,,,,,,,,noop (APPROXIMATE)',
    // After today: left out.
    '2026-12-01 00:00:00,,UTC+00:00,50,,,,,,,,,,,,,,,,,,,,,,,noop (APPROXIMATE)',
  ]),
  sleeps: csv(SLEEPS_HEAD, [
    // 22:50 to 06:40 in Chicago (UTC-5 in July): wakes on the 14th.
    '2026-07-14 00:00:00,2026-07-14 03:50:00,2026-07-14 11:40:00,UTC+00:00,false,,,432,470,220,96,116,38,92,,,,noop (APPROXIMATE)',
    // A short lie-in the same morning: not the night.
    '2026-07-14 00:00:00,2026-07-14 13:00:00,2026-07-14 13:30:00,UTC+00:00,false,,,25,30,25,0,0,5,83,,,,noop (APPROXIMATE)',
    // A night the cycles file has no sleep for: its figures come from here.
    '2026-07-15 00:00:00,2026-07-15 04:00:00,2026-07-15 11:00:00,UTC+00:00,false,,,380,420,200,80,100,40,90,,,,import',
    // 20:00 to 23:30 in Chicago on the 16th, though it's the 17th in UTC.
    '2026-07-17 00:00:00,2026-07-17 01:00:00,2026-07-17 04:30:00,UTC+00:00,false,,,190,210,100,40,50,20,90,,,,noop (APPROXIMATE)',
    // Ends before it starts: left out.
    '2026-07-18 00:00:00,2026-07-18 09:00:00,2026-07-18 08:00:00,UTC+00:00,false,,,60,60,60,0,0,0,100,,,,noop (APPROXIMATE)',
  ]),
  workouts: csv(WORKOUTS_HEAD, [
    '2026-07-14 22:30:00,2026-07-14 22:30:00,2026-07-14 23:15:00,UTC+00:00,running,9.4,512,171,148,5,20,40,30,5,7200,noop (APPROXIMATE)',
    // 21:30 on the 14th in Chicago; the name came through NOOP's spreadsheet guard.
    "2026-07-15 02:30:00,2026-07-15 02:30:00,2026-07-15 03:00:00,UTC+00:00,'=cmd,,,,,,,,,,,import",
  ]),
};

const opts = { timeZone: 'America/Chicago', today: '2026-11-11' };
const valueOf = (found: ReturnType<typeof noopRows>, date: string, metric: string) => found.daily.find((r) => r.date === date && r.metric === metric)?.value;

test("NOOP's daily figures arrive in healthOS units, without its skin-temperature change", () => {
  const found = noopRows(exportFiles, opts);
  assert.equal(valueOf(found, '2026-07-14', 'recovery'), 64);
  assert.equal(valueOf(found, '2026-07-14', 'hrv_rmssd'), 48.5);
  assert.equal(valueOf(found, '2026-07-14', 'strain'), 11.2, 'already on 0–21');
  assert.equal(valueOf(found, '2026-07-14', 'whoop_kcal'), 2410);
  assert.equal(valueOf(found, '2026-07-14', 'sleep_hours'), 7.2, '432 min');
  assert.equal(valueOf(found, '2026-07-14', 'sleep_deep'), 1.6, '96 min');
  assert.equal(valueOf(found, '2026-07-14', 'sleep_efficiency'), 92, 'already 0–100');
  assert.equal(valueOf(found, '2026-07-14', 'sleep_performance'), 88);
  assert.ok(!found.daily.some((r) => (r.metric as string) === 'skin_temp'), 'a change from baseline is not a temperature');
  assert.equal(valueOf(found, '2026-07-16', 'resting_hr'), undefined, 'out of range');
  assert.ok(!found.daily.some((r) => r.date > opts.today), 'nothing after today');
  assert.equal(found.estimatedDays, 1);
  assert.equal(found.importedDays, 1);
});

test('nights are dated by when you woke on your own clock, the longest one each morning', () => {
  const found = noopRows(exportFiles, opts);
  assert.deepEqual(found.sleep, [
    { date: '2026-07-14', start: '2026-07-13T22:50:00-05:00', end: '2026-07-14T06:40:00-05:00' },
    { date: '2026-07-15', start: '2026-07-14T23:00:00-05:00', end: '2026-07-15T06:00:00-05:00' },
    { date: '2026-07-16', start: '2026-07-16T20:00:00-05:00', end: '2026-07-16T23:30:00-05:00' },
  ]);
  // The 14th's sleep figures are the cycles file's, not the night plus the lie-in.
  assert.equal(valueOf(found, '2026-07-14', 'sleep_hours'), 7.2);
  // The 15th had none there, so they come from its night.
  assert.equal(valueOf(found, '2026-07-15', 'sleep_hours'), 6.33);
  assert.equal(valueOf(found, '2026-07-15', 'sleep_efficiency'), 90);
});

test('workouts keep their times on your clock, and a name loses the spreadsheet guard', () => {
  const found = noopRows(exportFiles, opts);
  assert.deepEqual(found.workouts, [
    { date: '2026-07-14', start: '2026-07-14T17:30:00-05:00', end: '2026-07-14T18:15:00-05:00', sport: 'Running', energy_kcal: 512, distance_m: 7200, avg_hr: 148, max_hr: 171, strain: 9.4 },
    { date: '2026-07-14', start: '2026-07-14T21:30:00-05:00', end: '2026-07-14T22:00:00-05:00', sport: '=Cmd', energy_kcal: null, distance_m: null, avg_hr: null, max_hr: null, strain: null },
  ]);
});

test("WHOOP's own export, or a zip without the CSVs, is refused in plain words", () => {
  const whoopOwn = { cycles: csv(CYCLES_HEAD.replace(/,Source$/, ''), ['2026-07-14 22:31:00,2026-07-15 21:02:00,UTC-05:00,64,52,48.5,33.9,96.5,11.2,2410,162,71,,,,,,,,,,,,,,']) };
  assert.throws(() => noopRows(whoopOwn, opts), (e: Error) => e instanceof NoopExportError && /WHOOP's own data export/.test(e.message));
  assert.throws(() => noopRows({}, opts), (e: Error) => e instanceof NoopExportError && /no physiological_cycles\.csv/.test(e.message));
  // The sidecar alone marks it as NOOP's, as an export with no rows yet would be.
  assert.equal(noopRows({ cycles: csv(CYCLES_HEAD.replace(/,Source$/, ''), []), sidecar: true }, opts).daily.length, 0);
});

test('the preview counts days, nights and workouts; chunks keep each day whole and within the limits', () => {
  const found = noopRows(exportFiles, opts);
  assert.deepEqual(noopPreview(found), { days: 3, recoveryDays: 2, nights: 3, workouts: 2, firstDate: '2026-07-14', lastDate: '2026-07-16' });
  const chunks = noopChunks(found, { bytes: 3_500_000, rows: 20, nights: 10, workouts: 10 });
  assert.equal(chunks.length, 2, 'the 14th has 18 rows, so the 15th starts another');
  assert.deepEqual(chunks.flatMap((c) => c.daily).length, found.daily.length);
  assert.ok(chunks[0].daily.every((r) => r.date === '2026-07-14'));
  assert.equal(chunks[0].workouts?.length, 2);
  assert.deepEqual(noopFinish(found), { days: 3, firstDate: '2026-07-14', lastDate: '2026-07-16', metrics: [...new Set(found.daily.map((r) => r.metric))].sort() });
});

// ---------- the zip ----------

/** A zip of these files, deflated. */
function makeZip(entries: [string, string][]): Uint8Array<ArrayBuffer> {
  const locals: Buffer[] = [];
  const centrals: Buffer[] = [];
  let offset = 0;
  for (const [name, text] of entries) {
    const raw = Buffer.from(text);
    const data = zlib.deflateRawSync(raw);
    const nameBuf = Buffer.from(name);
    const crc = zlib.crc32(raw);
    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0);
    local.writeUInt16LE(20, 4);
    local.writeUInt16LE(8, 8);
    local.writeUInt32LE(crc, 14);
    local.writeUInt32LE(data.length, 18);
    local.writeUInt32LE(raw.length, 22);
    local.writeUInt16LE(nameBuf.length, 26);
    const central = Buffer.alloc(46);
    central.writeUInt32LE(0x02014b50, 0);
    central.writeUInt16LE(20, 4);
    central.writeUInt16LE(20, 6);
    central.writeUInt16LE(8, 10);
    central.writeUInt32LE(crc, 16);
    central.writeUInt32LE(data.length, 20);
    central.writeUInt32LE(raw.length, 24);
    central.writeUInt16LE(nameBuf.length, 28);
    central.writeUInt32LE(offset, 42);
    locals.push(local, nameBuf, data);
    centrals.push(central, nameBuf);
    offset += 30 + nameBuf.length + data.length;
  }
  const dir = Buffer.concat(centrals);
  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0);
  end.writeUInt16LE(entries.length, 8);
  end.writeUInt16LE(entries.length, 10);
  end.writeUInt32LE(dir.length, 12);
  end.writeUInt32LE(offset, 16);
  return new Uint8Array(Buffer.concat([...locals, dir, end]));
}

test("the export's zip is read in place, wherever in it the CSVs are", async () => {
  const zip = new Blob([
    makeZip([
      ['noop-export/physiological_cycles.csv', exportFiles.cycles],
      ['noop-export/sleeps.csv', exportFiles.sleeps],
      ['noop-export/workouts.csv', exportFiles.workouts],
      ['noop-export/journal_entries.csv', 'Cycle start time,Cycle timezone,Question text,Answered yes/no,Notes\r\n'],
      ['noop-export/noop_metric_series.json', '[]'],
    ]),
  ]);
  const files = await readNoopZip(zip);
  assert.equal(files.cycles, exportFiles.cycles);
  assert.equal(files.workouts, exportFiles.workouts);
  assert.equal(files.sidecar, true);
  await assert.rejects(readNoopZip(new Blob(['not a zip'])), NoopExportError);
});

// ---------- the server ----------

process.env.SESSION_SECRET = 'noop-test-secret-'.padEnd(64, 'x');
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
const prev = (d: string) => new Date(Date.parse(d + 'T00:00:00Z') - 86_400_000).toISOString().slice(0, 10);

const chunk = {
  daily: [
    { date: D1, metric: 'recovery', value: 60 },
    { date: D1, metric: 'strain', value: 10.5 },
    { date: D1, metric: 'hrv_rmssd', value: 45 },
    { date: D1, metric: 'hr_avg', value: 70 },
    { date: D1, metric: 'sleep_hours', value: 7 },
    { date: D1, metric: 'sleep_deep', value: 1.5 },
    { date: D1, metric: 'sleep_performance', value: 85 },
    { date: D2, metric: 'recovery', value: 61 },
    { date: D2, metric: 'resting_hr', value: 54 },
  ],
  sleep: [{ date: D1, start: `${prev(D1)}T23:10:00+00:00`, end: `${D1}T06:20:00+00:00` }],
  workouts: [
    { date: D1, start: `${D1}T17:30:00+00:00`, end: `${D1}T18:15:00+00:00`, sport: 'Running', energy_kcal: 512, distance_m: 7200, avg_hr: 148, max_hr: 171, strain: 9.4 },
  ],
};

const rows = (userId: string, table = 'daily') => db.query<Record<string, unknown>>(`SELECT * FROM ${table} WHERE user_id = $1 AND source = 'noop' ORDER BY 1, 2, 3`, [userId]);

test('importing needs a signed-in person and the X-HealthOS header', async () => {
  assert.equal((await owner.post('/api/noop/import', chunk)).status, 401);
  assert.equal((await owner.post('/api/auth/login', { email: 'owner@example.com', password: 'owner password 123' })).status, 200);
  assert.equal((await owner.call('POST', '/api/noop/import', chunk, {})).status, 403);
  assert.equal((await rows(OWNER_ID)).length, 0);

  const inv = await owner.post('/api/admin/invites', { email: 'bob@example.com', role: 'user' });
  const token = String(inv.json.url).split('/').at(-1);
  assert.equal((await bob.post('/api/auth/invite', { token, email: 'bob@example.com', name: 'Bob', password: 'bob password 123' })).status, 200);
  bobId = (await bob.get('/api/auth/me')).json.user.id;
});

test('a chunk is stored as NOOP: the day rows, one sleep record per night and the workouts', async () => {
  const res = await owner.post('/api/noop/import', chunk);
  assert.equal(res.status, 200);
  assert.deepEqual(res.json, { ok: true, daily: 9, nights: 1, workouts: 1, dropped: 0 });
  assert.equal((await rows(OWNER_ID)).length, 9);
  const events = await rows(OWNER_ID, 'events');
  assert.deepEqual(events.map((e) => [e.id, e.kind, e.date]), [[`noop-sleep-${D1}`, 'sleep', D1]]);
  const workouts = await rows(OWNER_ID, 'workouts');
  assert.equal(workouts.length, 1);
  assert.match(String(workouts[0].id), /^noop-\d+-running$/);
  assert.equal(Number(workouts[0].duration_min), 45);
  // Sending the same export again updates it rather than adding to it.
  assert.equal((await owner.post('/api/noop/import', chunk)).status, 200);
  assert.equal((await rows(OWNER_ID, 'workouts')).length, 1);
  assert.equal((await rows(OWNER_ID, 'events')).length, 1);
  assert.equal((await owner.get('/api/status')).json.noop.lastImport, null, 'until the import finishes');
});

test("WHOOP's own numbers win a day both have; NOOP's come before Apple's for the strap's metrics, after for movement", async () => {
  await upsertDaily(db, OWNER_ID, [
    { date: D1, metric: 'recovery', source: 'whoop', value: 75 },
    { date: D1, metric: 'hr_avg', source: 'apple', value: 66 },
    { date: D2, metric: 'resting_hr', source: 'apple', value: 60 },
  ]);
  const t = (await owner.get('/api/trends?metrics=recovery,hr_avg,resting_hr,strain&days=7')).json;
  const pts = (k: string) => t[k].map((p: { date: string; value: number }) => [p.date, p.value]);
  assert.deepEqual(pts('recovery'), [[D1, 75], [D2, 61]]);
  assert.deepEqual(pts('hr_avg'), [[D1, 66]]);
  assert.deepEqual(pts('resting_hr'), [[D2, 54]]);
  assert.deepEqual(pts('strain'), [[D1, 10.5]]);
});

test("the night shows on the Sleep page as NOOP's, with its sleep performance", async () => {
  const n = (await owner.get(`/api/sleep/night?date=${D1}`)).json;
  assert.equal(n.source, 'noop');
  assert.equal(n.fellAsleep, chunk.sleep[0].start);
  assert.equal(n.wokeUp, chunk.sleep[0].end);
  assert.equal(n.performance, 85);
  assert.equal(n.stages.deep, 1.5);
});

test('a NOOP workout joins the same Apple session, and gives way to the same WHOOP one', () => {
  const w = (id: string, source: string, start: string, end: string, extra: Partial<Workout> = {}): Workout => ({
    id,
    source,
    sport: 'Running',
    start,
    end,
    date: start.slice(0, 10),
    duration_min: 45,
    energy_kcal: null,
    distance_m: null,
    avg_hr: null,
    max_hr: null,
    strain: null,
    ...extra,
  });
  const merged = mergeWorkouts([
    w('hk-1', 'apple', '2026-07-14T17:31:00-05:00', '2026-07-14T18:14:00-05:00', { energy_kcal: 480 }),
    w('noop-1', 'noop', '2026-07-14T17:30:00-05:00', '2026-07-14T18:15:00-05:00', { strain: 9.4, max_hr: 171 }),
    w('whoop-2', 'whoop', '2026-07-15T07:00:00-05:00', '2026-07-15T07:40:00-05:00', { strain: 8 }),
    w('noop-2', 'noop', '2026-07-15T07:01:00-05:00', '2026-07-15T07:40:00-05:00', { strain: 7.1 }),
    w('noop-3', 'noop', '2026-07-16T07:00:00-05:00', '2026-07-16T07:30:00-05:00'),
  ]);
  assert.deepEqual(
    merged.map((x) => [x.id, x.source, x.strain, x.energy_kcal]),
    [
      ['noop-3', 'noop', null, null],
      ['whoop-2', 'whoop', 8, null],
      ['hk-1', 'apple+noop', 9.4, 480],
    ],
  );
});

test('a chunk with anything a NOOP export cannot hold is refused whole', async () => {
  const bad: [string, unknown][] = [
    ['not an object', []],
    ['unknown metric', { daily: [{ date: D1, metric: 'steps', value: 10 }] }],
    ['skin temperature', { daily: [{ date: D1, metric: 'skin_temp', value: -0.3 }] }],
    ['strain over 21', { daily: [{ date: D1, metric: 'strain', value: 60 }] }],
    ['a string value', { daily: [{ date: D1, metric: 'recovery', value: '60' }] }],
    ['a future date', { daily: [{ date: day(-5), metric: 'recovery', value: 60 }] }],
    ['before WHOOP', { daily: [{ date: '2010-01-01', metric: 'recovery', value: 60 }] }],
    ['a night twice', { sleep: [chunk.sleep[0], chunk.sleep[0]] }],
    ['a night ending before it starts', { sleep: [{ ...chunk.sleep[0], end: chunk.sleep[0].start }] }],
    ['a time without offset', { sleep: [{ ...chunk.sleep[0], start: `${D1}T01:00:00` }] }],
    ['a workout without a name', { workouts: [{ ...chunk.workouts[0], sport: ' ' }] }],
    ['a workout heart rate no one has', { workouts: [{ ...chunk.workouts[0], max_hr: 400 }] }],
  ];
  for (const [why, body] of bad) {
    const res = await owner.post('/api/noop/import', body);
    assert.equal(res.status, 400, why);
    assert.equal(typeof res.json.error, 'string', why);
  }
  assert.equal((await rows(OWNER_ID)).length, 9, 'nothing was written');
});

test('finishing keeps the summary Integrations shows, of what is stored', async () => {
  const res = await owner.post('/api/noop/import/finish', { days: 2, firstDate: D1, lastDate: D2, metrics: ['recovery'] });
  assert.equal(res.status, 200);
  const last = (await owner.get('/api/status')).json.noop.lastImport;
  assert.deepEqual(res.json.lastImport, last);
  assert.deepEqual(
    { ...last, importedAt: typeof last.importedAt },
    { days: 2, firstDate: D1, lastDate: D2, metrics: ['hr_avg', 'hrv_rmssd', 'recovery', 'resting_hr', 'sleep_deep', 'sleep_hours', 'sleep_performance', 'strain'], nights: 1, workouts: 1, importedAt: 'string' },
  );
  assert.equal((await owner.post('/api/noop/import/finish', { days: 1, firstDate: null, lastDate: null, metrics: ['steps'] })).status, 400);
});

// ---------- straight from the strap: POST /api/noop/ingest ----------

const bearer = (token: string) => ({ 'X-HealthOS': '1', Authorization: `Bearer ${token}` });
let bobToken = '';

const D3 = day(1);
const strapNight = (date: string) => ({
  date,
  start: `${prev(date)}T23:00:00+00:00`,
  end: `${date}T06:30:00+00:00`,
  segments: [
    { start: `${prev(date)}T23:00:00+00:00`, end: `${prev(date)}T23:20:00+00:00`, stage: 'awake' },
    { start: `${prev(date)}T23:20:00+00:00`, end: `${date}T01:00:00+00:00`, stage: 'light' },
    { start: `${date}T01:00:00+00:00`, end: `${date}T02:30:00+00:00`, stage: 'deep' },
    { start: `${date}T02:30:00+00:00`, end: `${date}T06:30:00+00:00`, stage: 'rem' },
  ],
});
const sync = (extra: Record<string, unknown> = {}) => ({
  window: { from: D2, to: D3 },
  daily: [
    { date: D2, metric: 'recovery', value: 55 },
    { date: D3, metric: 'recovery', value: 71 },
    { date: D3, metric: 'sleep_hours', value: 7.1 },
  ],
  sleep: [strapNight(D3)],
  workouts: [{ ...chunk.workouts[0], date: D2, start: `${D2}T17:30:00+00:00`, end: `${D2}T18:00:00+00:00`, sport: 'Cycling' }],
  ...extra,
});

test('the iPhone app syncs the strap with its ingest token, not a session', async () => {
  const anon = new Client();
  assert.equal((await anon.post('/api/noop/ingest', sync())).status, 401);
  assert.equal((await anon.call('POST', '/api/noop/ingest', sync(), bearer('wrong'))).status, 401);
  bobToken = (await bob.post('/api/me/ingest-token')).json.token;
  assert.ok(bobToken);
  const res = await anon.call('POST', '/api/noop/ingest', sync(), bearer(bobToken));
  assert.equal(res.status, 200);
  assert.equal(res.json.days, 2);
  assert.equal(res.json.nights, 1);
  assert.equal(res.json.workouts, 1);
  const status = (await bob.get('/api/status')).json.noop;
  assert.deepEqual({ ...status.lastSync, syncedAt: typeof status.lastSync.syncedAt }, { syncedAt: 'string', from: D2, to: D3, days: 2, nights: 1, workouts: 1 });
  assert.equal((await rows(bobId, 'sleep_stages')).length, 4, "the night's stages came too");
  const n = (await bob.get(`/api/sleep/night?date=${D3}`)).json;
  assert.equal(n.source, 'noop');
  assert.deepEqual(n.segments.map((g: { stage: string }) => g.stage), ['awake', 'light', 'deep', 'rem']);
});

test("a sync replaces the strap's rows in its window, and only there", async () => {
  // Bob's earlier export import of D2 (recovery 40) is inside the window; D1 isn't.
  assert.equal((await bob.post('/api/noop/import', { daily: [{ date: D1, metric: 'recovery', value: 30 }] })).status, 200);
  const anon = new Client();
  // Rescored: D2 dropped its workout and recovery; D3's night lost its stages.
  const again = sync({ daily: [{ date: D3, metric: 'recovery', value: 73 }], workouts: [], sleep: [{ ...strapNight(D3), segments: undefined }] });
  assert.equal((await anon.call('POST', '/api/noop/ingest', again, bearer(bobToken))).status, 200);
  const daily = await rows(bobId);
  assert.deepEqual(
    daily.map((r) => [r.date, r.metric, Number(r.value)]),
    [
      [D1, 'recovery', 30],
      [D3, 'recovery', 73],
    ],
  );
  assert.equal((await rows(bobId, 'workouts')).length, 0);
  assert.equal((await rows(bobId, 'events')).length, 1);
  assert.equal((await rows(bobId, 'sleep_stages')).length, 0);
});

test('a sync whose window is too long, or holds a record outside it, is refused whole', async () => {
  const anon = new Client();
  const bad: [string, unknown][] = [
    ['no window', { daily: [] }],
    ['backwards', { window: { from: D3, to: D2 }, daily: [] }],
    ['over 31 days', { window: { from: day(40), to: D3 }, daily: [] }],
    ['a day outside', { window: { from: D3, to: D3 }, daily: [{ date: D2, metric: 'recovery', value: 50 }] }],
    ['a night outside', { window: { from: D2, to: D2 }, daily: [], sleep: [strapNight(D3)] }],
    ['an unknown stage', { window: { from: D3, to: D3 }, daily: [], sleep: [{ ...strapNight(D3), segments: [{ ...strapNight(D3).segments[0], stage: 'in_bed' }] }] }],
  ];
  for (const [why, body] of bad) {
    const res = await anon.call('POST', '/api/noop/ingest', body, bearer(bobToken));
    assert.equal(res.status, 400, why);
  }
  assert.equal((await rows(bobId)).length, 2, 'nothing changed');
});

test("each person's import is their own; removing NOOP data leaves other sources and other people alone", async () => {
  assert.equal((await bob.post('/api/noop/import', { daily: [{ date: D2, metric: 'recovery', value: 40 }] })).status, 200);
  assert.equal((await rows(bobId)).length, 3);
  assert.equal((await bob.get('/api/status')).json.noop.lastImport, null);

  const res = await owner.post('/api/noop/clear');
  assert.equal(res.status, 200);
  for (const table of ['daily', 'events', 'workouts']) assert.equal((await rows(OWNER_ID, table)).length, 0, table);
  assert.equal((await owner.get('/api/status')).json.noop.lastImport, null);
  const others = await db.query("SELECT source FROM daily WHERE user_id = $1 AND source IN ('whoop', 'apple')", [OWNER_ID]);
  assert.equal(others.length, 3, "WHOOP's and Apple's days stay");
  assert.equal((await rows(bobId)).length, 3, "Bob's stays");
  assert.ok((await bob.get('/api/status')).json.noop.lastSync, "and so does his last sync");
});
