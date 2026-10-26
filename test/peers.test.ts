// Anonymous peer comparisons (GET /api/peers): results only for someone taking part, only against 20 or more other
// people taking part in the same age band with 7 days of the same measurement from the same source, and never an id,
// a name, anyone else's own value, or a place finer than the rounded quartiles give. Everyone here is made up and
// inserted by SQL.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { AddressInfo } from 'node:net';
import { createApp } from '../server/app.ts';
import { hashPassword } from '../server/auth.ts';
import { addDays, todayLocal } from '../server/dates.ts';
import { OWNER_ID, type Db, setUserSetting, upsertDaily } from '../server/db.ts';
import { compare, peerComparison } from '../server/peers.ts';
import { peerBand } from '../shared/peers.ts';
import { openStore } from '../server/store.ts';

process.env.SESSION_SECRET = 'peers-test-secret-'.padEnd(64, 'x');
process.env.HEALTHOS_PASSWORD_HASH = await hashPassword('owner password 123');

const db = await openStore();
const server = createApp({ db, hosted: false }).listen(0, '127.0.0.1');
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
  const text = await res.text();
  return { status: res.status, text, json: JSON.parse(text || 'null') as any };
}

const today = todayLocal();
const days = (n: number) => Array.from({ length: n }, (_, i) => addDays(today, -i));

/** Each person's readings are one value every day, so their average is exactly it: easy to look for in the answer. */
async function person(q: Db, id: string, o: { age?: number; on?: boolean; status?: string; metric?: string; source?: string; value: number; days?: number }) {
  await q.query("INSERT INTO users (id, email, name, password_hash, role, status, created_at) VALUES ($1, $2, $3, 'x', 'user', $4, 1)", [
    id,
    `${id}@example.com`,
    `Name ${id}`,
    o.status ?? 'active',
  ]);
  if (o.age !== undefined) await setUserSetting(q, id, 'age', JSON.stringify({ age: o.age, asOf: today }));
  if (o.on !== false) await setUserSetting(q, id, 'peer_comparison', 'on');
  const metric = o.metric ?? 'resting_hr';
  await upsertDaily(q, id, days(o.days ?? 10).map((date) => ({ date, metric, source: o.source ?? 'apple', value: o.value })));
}

// The others' averages have more decimals than resting heart rate is shown with, so none can appear by chance.
const value = (i: number) => 50 + i * 1.234567;
const peers = (r: any) => r.metrics.find((m: any) => m.metric === 'resting_hr' && m.source === 'apple');

test('setup: the owner takes part, with a month of Apple resting heart rate', async () => {
  assert.equal((await call('POST', '/api/auth/login', { email: 'owner@example.com', password: 'owner password 123' })).status, 200);
  assert.equal((await call('PUT', '/api/settings', { age: 34, peerComparison: true })).status, 200);
  await upsertDaily(db, OWNER_ID, days(30).map((date) => ({ date, metric: 'resting_hr', source: 'apple', value: 58 })));
  // Six days of HRV: not enough of the viewer's own.
  await upsertDaily(db, OWNER_ID, days(6).map((date) => ({ date, metric: 'hrv_sdnn', source: 'apple', value: 40 })));
});

test('19 others is still gathering, and only people who qualify count', async () => {
  for (let i = 1; i <= 19; i++) await person(db, `p${String(i).padStart(2, '0')}`, { age: 30 + (i % 10), value: value(i) });
  await person(db, 'six-days', { age: 33, value: 61.5, days: 6 });
  await person(db, 'whoop-only', { age: 33, value: 61.5, source: 'whoop' });
  await person(db, 'older', { age: 45, value: 61.5 });
  await person(db, 'not-in', { age: 33, value: 61.5, on: false });
  await person(db, 'disabled', { age: 33, value: 61.5, status: 'disabled' });
  await person(db, 'no-age', { value: 61.5 });
  const r = (await call('GET', '/api/peers')).json;
  assert.equal(r.participating, true);
  assert.equal(r.ageBand, '30–39');
  assert.deepEqual(r.window, { from: addDays(today, -29), to: today });
  const rhr = peers(r);
  assert.equal(rhr.status, 'gathering');
  assert.equal(rhr.band, undefined);
  assert.equal(rhr.group, undefined);
  assert.equal(rhr.you, 58);
  assert.equal(rhr.yourDays, 30);
});

test('the viewer needs 7 days of their own, and pairs they have no readings for are left out', async () => {
  const r = (await call('GET', '/api/peers')).json;
  const hrv = r.metrics.find((m: any) => m.metric === 'hrv_sdnn');
  assert.equal(hrv.status, 'not_enough_days');
  assert.equal(hrv.yourDays, 6);
  assert.equal(r.metrics.some((m: any) => m.source === 'whoop'), false);
});

test('phone-only nights (time in bed, not sleep) are not the same measurement and don’t count', async () => {
  const nights = days(10);
  await upsertDaily(db, OWNER_ID, nights.map((date) => ({ date, metric: 'sleep_hours', source: 'apple', value: 7.5 })));
  await upsertDaily(db, OWNER_ID, nights.slice(0, 4).map((date) => ({ date, metric: 'sleep_in_bed', source: 'apple', value: 7.5 })));
  const sleep = (await call('GET', '/api/peers')).json.metrics.find((m: any) => m.metric === 'sleep_hours');
  assert.equal(sleep.yourDays, 6);
  assert.equal(sleep.status, 'not_enough_days');
});

test('with 20 others the comparison is ready, and the answer has no ids, names or anyone else’s value', async () => {
  await person(db, 'p20', { age: 39, value: value(20) });
  const res = await call('GET', '/api/peers');
  const rhr = peers(res.json);
  assert.equal(rhr.status, 'ready');
  assert.equal(rhr.group.size, '20+');
  // The median of 20 is halfway between the 10th and 11th, rounded to whole bpm as the metric is shown.
  assert.equal(rhr.group.median, Math.round((value(10) + value(11)) / 2));
  assert.deepEqual(rhr.group, { size: '20+', p25: 57, median: 63, p75: 69 });
  // 58 is between the rounded 25th percentile (57) and median (63), and that quarter is all the answer says.
  assert.equal(rhr.band, 'p25_median');
  assert.equal('percentile' in rhr, false);
  for (let i = 1; i <= 20; i++) assert.ok(!res.text.includes(String(value(i))), `no one's own average (${value(i)})`);
  for (const id of ['p01', 'p20', 'six-days', 'whoop-only', 'older', 'not-in', 'disabled']) assert.ok(!res.text.includes(id), `no id (${id})`);
  assert.ok(!res.text.includes('example.com') && !res.text.includes('Name p'), 'no emails or names');
  assert.ok(!/"(?:n|count|users?|ids?)"/.test(res.text), 'no counts or id lists');
});

test('the viewer is not in their own group, and moving their own average within a quarter changes nothing else', async () => {
  const at = async (v: number) => {
    await upsertDaily(db, OWNER_ID, days(30).map((date) => ({ date, metric: 'resting_hr', source: 'apple', value: v })));
    return call('GET', '/api/peers');
  };
  const before = await at(58);
  // Within the same rounded value: not one character of the answer changes.
  assert.equal((await at(58.3)).text, before.text);
  assert.equal((await at(57.6)).text, before.text);
  // Within the same quarter: only the viewer's own average does.
  const moved = peers((await at(61)).json);
  assert.deepEqual({ ...moved, you: 58 }, peers(before.json));
  // Far away: another quarter, and the group's figures are exactly as they were, as the viewer isn't one of them.
  const far = peers((await at(90)).json);
  assert.equal(far.band, 'above_p75');
  assert.deepEqual(far.group, peers(before.json).group);
  assert.equal(peers((await at(10)).json).band, 'below_p25');
  await at(58);
});

test('opting out takes effect at once, and it is mutual', async () => {
  await db.query("DELETE FROM user_settings WHERE user_id = 'p05' AND key = 'peer_comparison'");
  assert.equal(peers((await call('GET', '/api/peers')).json).status, 'gathering');
  await setUserSetting(db, 'p05', 'peer_comparison', 'on');
  assert.equal(peers((await call('GET', '/api/peers')).json).status, 'ready');
  // The viewer turns it off: no results at all, and back on, they're there again.
  assert.deepEqual((await call('PUT', '/api/settings', { peerComparison: false })).status, 200);
  assert.deepEqual((await call('GET', '/api/peers')).json, { participating: false, reason: 'off' });
  await call('PUT', '/api/settings', { peerComparison: true });
  assert.equal(peers((await call('GET', '/api/peers')).json).status, 'ready');
});

test('someone who stops taking part is no longer counted for anyone else', async () => {
  // p20 views: the owner is one of their 20 others while taking part.
  const before = await peerComparison(db, false, 'p20');
  assert.equal(before.participating && before.metrics[0].status, 'ready');
  await call('PUT', '/api/settings', { peerComparison: false });
  const after = await peerComparison(db, false, 'p20');
  assert.equal(after.participating && after.metrics[0].status, 'gathering');
  await call('PUT', '/api/settings', { peerComparison: true });
});

test('age bands: the group is the viewer’s own band', async () => {
  // 'older' (45) sees only people in 40–49: nobody else.
  const r = await peerComparison(db, false, 'older');
  assert.ok(r.participating);
  assert.equal(r.ageBand, '40–49');
  assert.equal(r.metrics[0].status, 'gathering');
});

test('a viewer without an age, or under 18, gets no results', async () => {
  assert.deepEqual(await peerComparison(db, false, 'no-age'), { participating: false, reason: 'no_age' });
  await person(db, 'teen', { age: 16, value: 70 });
  assert.deepEqual(await peerComparison(db, false, 'teen'), { participating: false, reason: 'under_age' });
  assert.deepEqual(await peerComparison(db, false, 'not-in'), { participating: false, reason: 'off' });
});

test('without sign-in there is nobody to compare with', async () => {
  const secret = process.env.SESSION_SECRET;
  delete process.env.SESSION_SECRET;
  try {
    assert.deepEqual(await peerComparison(db, false, OWNER_ID), { participating: false, reason: 'no_accounts' });
  } finally {
    process.env.SESSION_SECRET = secret;
  }
});

test('the local demo owner gets a made-up group, flagged demo', async () => {
  const fresh = await openStore();
  await setUserSetting(fresh, OWNER_ID, 'age', JSON.stringify({ age: 34, asOf: today }));
  await setUserSetting(fresh, OWNER_ID, 'peer_comparison', 'on');
  await upsertDaily(fresh, OWNER_ID, days(20).map((date) => ({ date, metric: 'resting_hr', source: 'demo', value: 60 })));
  const r = await peerComparison(fresh, false, OWNER_ID);
  assert.ok(r.participating);
  assert.equal(r.demo, true);
  assert.equal(r.metrics[0].status, 'ready');
  // 60 is the sample's median, which counts in the quarter below it.
  assert.equal(r.metrics[0].group?.median, 60);
  assert.equal(r.metrics[0].band, 'p25_median');
  // Never hosted.
  const hosted = await peerComparison(fresh, true, OWNER_ID);
  assert.ok(hosted.participating && !hosted.demo && hosted.metrics.length === 0);
  await fresh.close();
});

test('quarters: equal to a quartile is inside the middle half, and at the median in its lower quarter', () => {
  const g = { p25: 6, median: 11, p75: 15 };
  assert.equal(peerBand(5.9, g), 'below_p25');
  assert.equal(peerBand(6, g), 'p25_median');
  assert.equal(peerBand(11, g), 'p25_median');
  assert.equal(peerBand(11.1, g), 'median_p75');
  assert.equal(peerBand(15, g), 'median_p75');
  assert.equal(peerBand(15.1, g), 'above_p75');
  // Quartiles that round to one value: never "above the 75th" for a value equal to it.
  assert.equal(peerBand(97, { p25: 97, median: 97, p75: 97 }), 'p25_median');
});

test('the quarter comes from the rounded figures shown, and quartiles interpolate', () => {
  const group = Array.from({ length: 20 }, (_, i) => i + 1);
  const r = compare('steps', 'apple', 0, { avg: 15.2, days: 9 }, group);
  assert.deepEqual(r.group, { size: '20+', median: 11, p25: 6, p75: 15 });
  // Shown as 15, the rounded p75: inside the middle half, as the numbers on screen say.
  assert.equal(r.you, 15);
  assert.equal(r.band, 'median_p75');
  assert.equal(compare('steps', 'apple', 0, { avg: 1, days: 9 }, Array.from({ length: 50 }, (_, i) => i)).group?.size, '50+');
});
