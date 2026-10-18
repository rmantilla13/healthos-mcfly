// The Family board end to end over HTTP: who sees whom (mutual, on by default), what a tile carries, the
// avatar route, the cycle phase switch, and the status rules.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { AddressInfo } from 'node:net';
import type { FamilyMember } from '../shared/types.ts';
import { createApp } from '../server/app.ts';
import { hashPassword } from '../server/auth.ts';
import { analyzeCycle, toRows, upsertCycle } from '../server/cycle/index.ts';
import { addDays, todayLocal } from '../server/dates.ts';
import { OWNER_ID, setUserSetting, upsertDaily, upsertHourly } from '../server/db.ts';
import { familyPhase, familyStatus, stepsPace } from '../server/family.ts';
import { openStore } from '../server/store.ts';

process.env.SESSION_SECRET = 'family-test-secret-'.padEnd(64, 'x');
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
    return { status: res.status, json, headers: res.headers };
  }
  get = (p: string) => this.call('GET', p);
}

const owner = new Client();
const ana = new Client();
const leo = new Client();
const ids: Record<string, string> = {};
const today = todayLocal('UTC');
const back = (n: number) => addDays(today, -n);

async function join(c: Client, email: string, name: string) {
  const { code } = (await owner.call('POST', '/api/admin/invites', {})).json;
  assert.equal((await c.call('POST', '/api/auth/invite', { token: code, email, name, password: `${name} password 1` })).status, 200);
  return (await c.get('/api/auth/me')).json.user.id as string;
}

test('setup: an admin, a WHOOP wearer and an Apple Watch wearer, each with 30 days of history', async () => {
  assert.equal((await owner.call('POST', '/api/auth/login', { email: 'owner@example.com', password: OWNER_PASSWORD })).status, 200);
  ids.owner = OWNER_ID;
  ids.ana = await join(ana, 'ana@example.com', 'Ana');
  ids.leo = await join(leo, 'leo@example.com', 'Leo');
  for (const id of Object.values(ids)) await setUserSetting(db, id, 'timezone', 'UTC');

  // Ana: WHOOP. A hard night today: low recovery, resting HR up, a short sleep.
  const history = Array.from({ length: 30 }, (_, i) => back(i + 1));
  await upsertDaily(db, ids.ana, [
    ...history.flatMap((date, i) => [
      { date, metric: 'recovery', source: 'whoop', value: i % 2 ? 60 : 70 },
      { date, metric: 'resting_hr', source: 'whoop', value: i % 2 ? 52 : 54 },
      { date, metric: 'sleep_hours', source: 'whoop', value: 7.5 },
      { date, metric: 'sleep_in_bed', source: 'whoop', value: 8.2 },
    ]),
    { date: today, metric: 'recovery', source: 'whoop', value: 30 },
    { date: today, metric: 'resting_hr', source: 'whoop', value: 62 },
    { date: today, metric: 'sleep_hours', source: 'whoop', value: 5.6 },
    { date: today, metric: 'sleep_in_bed', source: 'whoop', value: 6.2 },
    { date: today, metric: 'steps', source: 'whoop', value: 9000 },
    { date: today, metric: 'weight', source: 'apple', value: 61.5 },
    // Never on the board: temperature (it follows the cycle), SpO2, breathing.
    { date: today, metric: 'skin_temp', source: 'whoop', value: 33.417 },
    { date: back(1), metric: 'wrist_temp', source: 'apple', value: 35.913 },
    { date: today, metric: 'spo2', source: 'whoop', value: 96.271 },
    { date: today, metric: 'resp_rate', source: 'whoop', value: 15.383 },
  ]);
  await db.query("INSERT INTO tokens (user_id, provider, access_token, refresh_token, expires_at, scope) VALUES ($1, 'whoop', 'a', 'r', $2, '')", [ids.ana, 9e15]);
  await db.query("INSERT INTO profile_assets (user_id, name, mime, data, updated_at) VALUES ($1, 'avatar.png', 'image/png', $2, 1234), ($1, 'cutout.png', 'image/png', $2, 1234)", [
    ids.ana,
    Buffer.from('fake png'),
  ]);

  // Leo: Apple Watch, an ordinary day; the phone has counted today's steps hour by hour.
  await upsertDaily(db, ids.leo, [
    ...history.flatMap((date, i) => [
      { date, metric: 'hrv_sdnn', source: 'apple', value: i % 2 ? 42 : 48 },
      { date, metric: 'resting_hr', source: 'apple', value: i % 2 ? 59 : 61 },
      { date, metric: 'sleep_hours', source: 'apple', value: 7 },
      { date, metric: 'sleep_in_bed', source: 'apple', value: 7.6 },
      { date, metric: 'steps', source: 'apple', value: 8000 },
    ]),
    { date: today, metric: 'hrv_sdnn', source: 'apple', value: 46 },
    { date: today, metric: 'resting_hr', source: 'apple', value: 60 },
    { date: today, metric: 'sleep_hours', source: 'apple', value: 7.1 },
    { date: today, metric: 'sleep_in_bed', source: 'apple', value: 7.5 },
    { date: today, metric: 'steps', source: 'apple', value: 4000 },
  ]);
  await db.query("INSERT INTO profile_assets (user_id, name, mime, data, updated_at) VALUES ($1, 'avatar.png', 'image/png', $2, 99)", [ids.leo, Buffer.from('leo png')]);
  await upsertHourly(db, ids.leo, [
    ...history.slice(0, 10).flatMap((date) => [8, 9, 10, 18].map((hour) => ({ date, hour, metric: 'steps', source: 'apple', value: 1000 }))),
    ...[8, 9, 10].map((hour) => ({ date: today, hour, metric: 'steps', source: 'apple', value: hour === 10 ? 2000 : 1000 })),
  ]);
});

const board = async (c: Client) => (await c.get('/api/family')).json;
const member = (b: { members: FamilyMember[] }, id: string) => b.members.find((m) => m.id === id)!;

test('everyone shares by default and sees everyone: you first, then by name', async () => {
  const b = await board(owner);
  assert.equal(b.sharing, true);
  assert.deepEqual(
    b.members.map((m: FamilyMember) => [m.name, m.isYou]),
    [
      ['Owner', true],
      ['Ana', false],
      ['Leo', false],
    ].map(([n, you]) => [you ? (b.members[0].name as string) : n, you]),
  );
  assert.equal((await board(ana)).members.length, 3);
});

test("a tile: each person against their own usual, with only what's listed", async () => {
  const b = await board(leo);
  const a = member(b, ids.ana);
  assert.equal(a.status, 'check');
  assert.deepEqual(a.reasons, ['recovery', 'resting_hr'], 'the first two of three');
  assert.deepEqual(a.readiness, { kind: 'recovery', value: 30, date: today, usual: 65 });
  assert.deepEqual(a.restingHr, { status: 'high', date: today, value: 62, usual: 53 });
  assert.deepEqual(a.sleep, { hours: 5.6, date: today, usual: 7.5, inBed: false });
  assert.deepEqual(a.steps, { value: 9000, source: 'whoop', asOfHour: null, usualByNow: null });
  assert.deepEqual(a.devices, ['whoop']);
  assert.equal(a.avatar, 1234);
  assert.equal(a.cyclePhase, undefined);

  const l = member(b, ids.leo);
  assert.equal(l.status, 'good');
  assert.equal(l.readiness?.kind, 'hrv');
  assert.deepEqual(l.devices, ['watch']);
  assert.deepEqual(l.steps, { value: 4000, source: 'apple', asOfHour: 10, usualByNow: 3000 });

  // The owner has no data at all.
  const o = member(b, ids.owner);
  assert.deepEqual([o.status, o.quietSince, o.sleep, o.steps], ['quiet', null, null, null]);

  // Nothing beyond the listed fields: no email, no weight, no history.
  const allowed = ['id', 'name', 'isYou', 'demo', 'today', 'avatar', 'devices', 'latestDataDate', 'quietSince', 'status', 'reasons', 'sleep', 'readiness', 'restingHr', 'steps', 'cyclePhase', 'history'];
  for (const m of b.members) for (const k of Object.keys(m)) assert.ok(allowed.includes(k), `unexpected field ${k}`);
  const text = JSON.stringify(b);
  assert.ok(!text.includes('@example.com') && !text.includes('61.5'), 'no email or weight');
});

test("the avatar is served only between people who share, never the cut-out, and cached briefly", async () => {
  const ok = await leo.get(`/api/family/${ids.ana}/avatar.png`);
  assert.equal(ok.status, 200);
  assert.equal(ok.headers.get('cache-control'), 'private, max-age=300');
  assert.equal((await leo.get(`/api/family/${ids.ana}/cutout.png`)).status, 404);
  assert.equal((await leo.get(`/api/family/${ids.owner}/avatar.png`)).status, 404, 'no photo');
  assert.equal((await new Client().get(`/api/family/${ids.ana}/avatar.png`)).status, 401);
});

test('turning sharing off is mutual: they see no one, and no one sees them or their photo', async () => {
  assert.equal((await owner.get(`/api/family/${ids.leo}/avatar.png`)).status, 200, 'while both share');
  assert.equal((await leo.call('PUT', '/api/settings', { familySharing: false })).json.settings.familySharing, false);
  assert.equal((await owner.get(`/api/family/${ids.leo}/avatar.png`)).status, 404, "a sharer can't load the photo of someone who stopped");
  assert.deepEqual(await board(leo), { sharing: false });
  const b = await board(owner);
  assert.deepEqual(
    b.members.map((m: FamilyMember) => m.id),
    [ids.owner, ids.ana],
  );
  assert.ok(!JSON.stringify(b).includes('Leo'), 'not named or counted');
  assert.equal((await leo.get(`/api/family/${ids.ana}/avatar.png`)).status, 404, 'a non-sharer sees no photos');
  assert.equal((await leo.call('PUT', '/api/settings', { familySharing: true })).json.settings.familySharing, true);
  assert.equal((await board(owner)).members.length, 3);
  assert.equal((await owner.get(`/api/family/${ids.leo}/avatar.png`)).status, 200);
});

test('a disabled account leaves the board', async () => {
  assert.equal((await owner.call('PATCH', `/api/admin/users/${ids.leo}`, { status: 'disabled' })).status, 200);
  assert.deepEqual(
    (await board(owner)).members.map((m: FamilyMember) => m.id),
    [ids.owner, ids.ana],
  );
  assert.equal((await owner.get(`/api/family/${ids.leo}/avatar.png`)).status, 404, "nor a disabled member's photo");
  assert.equal((await owner.call('PATCH', `/api/admin/users/${ids.leo}`, { status: 'active' })).status, 200);
});

test('a cycle phase shows only with tracking and its own switch on, and either turning off withdraws it', async () => {
  await upsertCycle(db, ids.ana, [...toRows({ date: back(1), flow: 'medium', periodStart: true }, 'manual'), ...toRows({ date: today, flow: 'light' }, 'manual')]);
  const phase = async () => member(await board(owner), ids.ana).cyclePhase;
  assert.equal(await phase(), undefined, 'off by default');
  await ana.call('PUT', '/api/settings', { shareCyclePhase: true });
  assert.equal(await phase(), undefined, 'not without cycle tracking');
  await ana.call('PUT', '/api/settings', { cycleTracking: true });
  assert.equal(await phase(), undefined, 'turning tracking on later shares nothing by surprise');
  const s = (await ana.call('PUT', '/api/settings', { shareCyclePhase: true })).json.settings;
  assert.equal(s.shareCyclePhase, true);
  assert.equal(await phase(), 'period');
  assert.equal((await ana.call('PUT', '/api/settings', { cycleTracking: false })).json.settings.shareCyclePhase, false);
  assert.equal(await phase(), undefined);
  await ana.call('PUT', '/api/settings', { cycleTracking: true });
  await ana.call('PUT', '/api/settings', { shareCyclePhase: true });
  assert.equal((await ana.call('PUT', '/api/settings', { familySharing: false })).json.settings.shareCyclePhase, false, 'sharing off withdraws it too');
  await ana.call('PUT', '/api/settings', { familySharing: true });
  assert.equal(await phase(), undefined);
});

test('each reading is judged against its own kind: one device, nights a watch measured, a usual before a verdict', async () => {
  const kai = await join(new Client(), 'kai@example.com', 'Kai');
  const noa = await join(new Client(), 'noa@example.com', 'Noa');
  const ivy = await join(new Client(), 'ivy@example.com', 'Ivy');
  for (const id of [kai, noa, ivy]) await setUserSetting(db, id, 'timezone', 'UTC');
  const history = Array.from({ length: 30 }, (_, i) => back(i + 1));
  // Kai wears WHOOP (resting HR asleep, ~52) and an Apple Watch (over the day, ~64). This morning only the
  // watch has synced: 64 is ordinary for the watch, though far above WHOOP's usual.
  await upsertDaily(db, kai, [
    ...history.flatMap((date, i) => [
      { date, metric: 'resting_hr', source: 'whoop', value: i % 2 ? 51 : 53 },
      { date, metric: 'resting_hr', source: 'apple', value: i % 2 ? 63 : 65 },
    ]),
    { date: today, metric: 'resting_hr', source: 'apple', value: 64 },
  ]);
  // Noa's watch is three days old: fresh readings, nothing to compare with yet.
  await upsertDaily(db, noa, [0, 1, 2].map((n) => ({ date: back(n), metric: 'resting_hr', source: 'apple', value: 60 })));
  // Ivy charges her watch overnight on alternate nights: the phone then logs time in bed (9 h). Her watch
  // nights are 7 h; tonight's 6 h 50 m is ordinary for her.
  await upsertDaily(db, ivy, [
    ...history.flatMap((date, i) =>
      i % 2
        ? [{ date, metric: 'sleep_hours', source: 'apple', value: 9 }, { date, metric: 'sleep_in_bed', source: 'apple', value: 9 }]
        : [{ date, metric: 'sleep_hours', source: 'apple', value: 7 }, { date, metric: 'sleep_in_bed', source: 'apple', value: 7.6 }],
    ),
    { date: today, metric: 'sleep_hours', source: 'apple', value: 6.83 },
    { date: today, metric: 'sleep_in_bed', source: 'apple', value: 7.4 },
  ]);
  const b = await board(owner);
  assert.deepEqual([member(b, kai).restingHr?.status, member(b, kai).status], ['normal', 'good']);
  assert.deepEqual([member(b, noa).status, member(b, noa).quietSince], ['learning', null]);
  assert.deepEqual([member(b, ivy).sleep?.usual, member(b, ivy).status, member(b, ivy).reasons], [7, 'good', []]);
  // Her chart keeps only the nights the watch measured.
  assert.equal(member(b, ivy).history.sleep.inBed, false);
  assert.ok(member(b, ivy).history.sleep.points.every((p) => p.value < 8), 'no 9-hour phone nights');
  assert.equal(member(b, ivy).history.sleep.points.length, 16, '15 watch nights in the window, and last night');
  for (const id of [kai, noa, ivy]) assert.equal((await owner.call('DELETE', `/api/admin/users/${id}`)).status, 200);
});

test('a stale tile carries no reasons, whatever its old readings said', async () => {
  const sam = await join(new Client(), 'sam@example.com', 'Sam');
  await setUserSetting(db, sam, 'timezone', 'UTC');
  // Newest data two days ago, and that day's HRV and resting HR were both well off the usual.
  await upsertDaily(db, sam, [
    ...Array.from({ length: 30 }, (_, i) => back(i + 3)).flatMap((date, i) => [
      { date, metric: 'hrv_sdnn', source: 'apple', value: i % 2 ? 48 : 52 },
      { date, metric: 'resting_hr', source: 'apple', value: i % 2 ? 59 : 61 },
    ]),
    { date: back(2), metric: 'hrv_sdnn', source: 'apple', value: 30 },
    { date: back(2), metric: 'resting_hr', source: 'apple', value: 70 },
  ]);
  const m = member(await board(owner), sam);
  assert.deepEqual([m.status, m.quietSince, m.reasons], ['quiet', back(2), []]);
  assert.equal((await owner.call('DELETE', `/api/admin/users/${sam}`)).status, 200);
});

test("each tile carries 30 days of the metrics it shows, and nothing else", async () => {
  const b = await board(owner);
  const a = member(b, ids.ana);
  assert.equal(a.history.sleep.points.length, 30, 'the last 30 nights, today included');
  assert.equal(a.history.sleep.points.at(-1)?.date, today);
  assert.equal(a.history.sleep.points[0].date, back(29));
  assert.equal(a.history.sleep.inBed, false);
  assert.deepEqual(a.history.readiness?.kind, 'recovery');
  assert.equal(a.history.readiness?.points.at(-1)?.value, 30);
  assert.deepEqual(a.history.steps, [{ date: today, value: 9000 }]);
  assert.equal(a.history.restingHr.length, 30);
  assert.equal(a.history.load, null, 'no strain or active energy recorded');
  const l = member(b, ids.leo);
  assert.equal(l.history.readiness?.kind, 'hrv_sdnn');
  assert.equal(l.history.steps.length, 30);
  for (const m of b.members as FamilyMember[]) assert.deepEqual(Object.keys(m.history).sort(), ['load', 'readiness', 'restingHr', 'sleep', 'steps']);
  // Recorded for Ana, and on no tile or history: weight, temperature, SpO2, breathing.
  const text = JSON.stringify(b);
  for (const v of ['61.5', '33.417', '35.913', '96.271', '15.383', '33.42', '96.27']) assert.ok(!text.includes(v), `${v} leaked`);
});

test('history picks: the device used now, phone nights marked, nothing older than 30 days', async () => {
  const people: Record<string, string> = {};
  for (const n of ['mia', 'bo', 'pat', 'kim']) {
    people[n] = await join(new Client(), `${n}@example.com`, n);
    await setUserSetting(db, people[n], 'timezone', 'UTC');
  }
  const days = (n: number, from = 0) => Array.from({ length: n }, (_, i) => back(i + from));
  // Mia put her WHOOP away four weeks ago and wears an Apple Watch now.
  await upsertDaily(db, people.mia, [
    ...days(4, 26).map((date) => ({ date, metric: 'strain', source: 'whoop', value: 14.2 })),
    ...days(4, 26).map((date) => ({ date, metric: 'hrv_rmssd', source: 'whoop', value: 80 })),
    ...days(30).map((date) => ({ date, metric: 'active_energy', source: 'apple', value: 420.4 })),
    ...days(25, 4).map((date) => ({ date, metric: 'hrv_sdnn', source: 'apple', value: 40 })),
    ...days(25, 10).map((date) => ({ date, metric: 'resting_hr', source: 'whoop', value: 50 })),
    ...days(5, 4).map((date) => ({ date, metric: 'resting_hr', source: 'apple', value: 63 })),
  ]);
  // Bo has worn WHOOP for 40 days: the charts start 29 days back.
  await upsertDaily(db, people.bo, days(40).map((date, i) => ({ date, metric: 'strain', source: 'whoop', value: 10 + (i % 3) })));
  // Pat has only an iPhone: time in bed every night.
  await upsertDaily(db, people.pat, days(30).flatMap((date) => [{ date, metric: 'sleep_hours', source: 'apple', value: 8 }, { date, metric: 'sleep_in_bed', source: 'apple', value: 8 }]));
  // Pat's partner slept with a Watch until three weeks ago; since then only the phone logs nights.
  people.zoe = await join(new Client(), 'zoe@example.com', 'zoe');
  await setUserSetting(db, people.zoe, 'timezone', 'UTC');
  await upsertDaily(db, people.zoe, [
    ...days(9, 21).flatMap((date) => [{ date, metric: 'sleep_hours', source: 'apple', value: 7 }, { date, metric: 'sleep_in_bed', source: 'apple', value: 7.6 }]),
    ...days(21).flatMap((date) => [{ date, metric: 'sleep_hours', source: 'apple', value: 8.5 }, { date, metric: 'sleep_in_bed', source: 'apple', value: 8.5 }]),
  ]);
  // Kim has a Watch but no sleep at all.
  await upsertDaily(db, people.kim, days(10).map((date) => ({ date, metric: 'resting_hr', source: 'apple', value: 58 })));

  const b = await board(owner);
  const mia = member(b, people.mia).history;
  assert.equal(mia.load?.kind, 'energy', 'strain from four weeks ago does not hide the Watch');
  assert.equal(mia.load?.points.length, 30);
  assert.equal(mia.readiness?.kind, 'hrv_sdnn', 'the HRV measured most recently');
  assert.deepEqual(new Set(mia.restingHr.map((p) => p.value)), new Set([63]), 'one device: the one read most recently');
  const bo = member(b, people.bo).history;
  assert.equal(bo.load?.points.length, 30);
  assert.equal(bo.load?.points[0].date, back(29));
  assert.deepEqual(member(b, people.pat).history.sleep.inBed, true);
  assert.equal(member(b, people.pat).history.sleep.points.length, 30);
  assert.deepEqual(member(b, people.kim).history.sleep, { inBed: false, points: [] }, 'no nights is not time in bed');
  const zoe = member(b, people.zoe).history.sleep;
  assert.equal(zoe.inBed, true, 'old watch nights give way to the recent phone nights');
  assert.equal(zoe.points.length, 21);
  assert.equal(zoe.points.at(-1)?.date, today);
  for (const id of Object.values(people)) assert.equal((await owner.call('DELETE', `/api/admin/users/${id}`)).status, 200);
});

test('the one-time notice is remembered, and shown again for the bigger board', async () => {
  await setUserSetting(db, ids.ana, 'family_notice_seen', 'on'); // dismissed before the board showed 30 days
  assert.equal((await ana.get('/api/status')).json.settings.familyNoticeSeen, false);
  assert.equal((await ana.call('PUT', '/api/settings', { familyNoticeSeen: true })).json.settings.familyNoticeSeen, true);
});

test('status rules: stale data, phone only, a quiet strap, no usual yet, then the count of departures', () => {
  const base = { today: '2026-10-17', newest: '2026-10-17', wearableNewest: '2026-10-17', fresh: true, baselines: true, signals: [] as never[] };
  assert.deepEqual(familyStatus({ ...base, newest: '2026-10-14' }), { status: 'quiet', quietSince: '2026-10-14' });
  assert.deepEqual(familyStatus({ ...base, newest: null }), { status: 'quiet', quietSince: null });
  assert.deepEqual(familyStatus({ ...base, newest: '2026-10-16' }).status, 'good', 'yesterday is still fresh');
  assert.deepEqual(familyStatus({ ...base, wearableNewest: null }), { status: null, quietSince: null });
  assert.deepEqual(familyStatus({ ...base, fresh: false, wearableNewest: '2026-10-12' }), { status: 'quiet', quietSince: '2026-10-12' });
  assert.equal(familyStatus({ ...base, baselines: false }).status, 'learning');
  assert.equal(familyStatus({ ...base, signals: ['sleep'] }).status, 'off');
  assert.equal(familyStatus({ ...base, signals: ['sleep', 'hrv'] }).status, 'check');
});

test("steps pace: today's hours so far against the median running total of earlier days", () => {
  const rows = [
    ...['2026-10-14', '2026-10-15', '2026-10-16'].flatMap((date, i) => [9, 12].map((hour) => ({ date, hour, value: 1000 * (i + 1) }))),
    { date: '2026-10-17', hour: 9, value: 500 },
  ];
  assert.deepEqual(stepsPace(rows, '2026-10-17'), { asOfHour: 9, usualByNow: 2000 });
  assert.deepEqual(stepsPace(rows.slice(0, -1), '2026-10-17'), { asOfHour: null, usualByNow: null });
});

test('a shared phase: a period from logged bleeding; otherwise only with an estimate, and never near the next period', () => {
  // Four regular 28-day cycles, the latest starting Sep 26.
  const starts = ['2026-07-04', '2026-08-01', '2026-08-29', '2026-09-26'];
  const days = starts.flatMap((s) => [0, 1, 2, 3].map((i) => ({ date: addDays(s, i), flow: 'medium' as const, ...(i === 0 ? { periodStart: true } : {}) })));
  const at = (today: string) => familyPhase(analyzeCycle(days, today), days, today);
  assert.equal(at('2026-09-27'), 'period');
  assert.equal(at('2026-10-02'), 'follicular');
  const a = analyzeCycle(days, '2026-10-15');
  assert.ok(a.estimate, 'an estimate from four cycles');
  assert.equal(at('2026-10-15'), '2026-10-15' <= a.estimate.ovulation ? 'follicular' : 'luteal');
  assert.equal(at(a.estimate.nextPeriod.earliest), null, 'hidden from the earliest the next period could come');
  assert.equal(familyPhase(analyzeCycle(days.slice(0, 4), '2026-07-20'), days.slice(0, 4), '2026-07-20'), null, 'no estimate yet');
});
