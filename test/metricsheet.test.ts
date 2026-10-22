// Detail sheets (GET /api/metric/:key): each range's window and values against GET /api/trends, the card's status and
// the sentence that goes with it, the Day range's rules, units, and that one person never sees another's data.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { AddressInfo } from 'node:net';
import type { MetricSheet } from '../shared/metrics.ts';
import { aboutBefore, mmolFromMgDl } from '../shared/metrics.ts';
import type { Point, Summary } from '../shared/types.ts';
import { createApp } from '../server/app.ts';
import { hashPassword } from '../server/auth.ts';
import { addDays, todayLocal } from '../server/dates.ts';
import { OWNER_ID, type DailyRow, type HourlyRow, upsertDaily, upsertHourly } from '../server/db.ts';
import { isSteady, sentence, weeklyMeans } from '../server/metricsheet.ts';
import { openStore } from '../server/store.ts';

// ---------- the sentence, on its own ----------

const base = { range: 'month' as const, days: 30, possible: 30, today: '2026-10-22' };

test('the sentence gives the average and the change with its direction, or "about the same" when it rounds away', () => {
  assert.equal(
    sentence({ ...base, key: 'resting_hr', unit: 'bpm', average: 54.2, delta: -2.1, previous: 56.3, status: null }),
    'Your resting heart rate averaged 54 bpm over the last 30 days, 2 bpm lower than the 30 days before.',
  );
  assert.equal(
    sentence({ ...base, key: 'resting_hr', unit: 'bpm', average: 54.2, delta: 0.4, previous: 53.8, status: null }),
    'Your resting heart rate averaged 54 bpm over the last 30 days, about the same as the 30 days before.',
  );
  // Sleep in hours and minutes; steps say more and fewer; a week and a year say so.
  assert.equal(
    sentence({ ...base, range: 'week', days: 7, possible: 7, key: 'sleep_hours', unit: 'h', average: 7.2, delta: 0.25, previous: 6.95, status: null }),
    'You slept 7h 12m a night on average over the last 7 days, 15 min more than the 7 days before.',
  );
  assert.equal(
    sentence({ ...base, range: 'year', days: 300, possible: 364, key: 'steps', unit: 'steps', average: 8412, delta: -640, previous: 9052, status: null }),
    'You averaged 8,412 steps a day over the last 12 months (300 days with data), 640 steps fewer than the 12 months before.',
  );
  // A percentage's change is in points, not a relative "%".
  assert.equal(
    sentence({ ...base, key: 'recovery', unit: '%', average: 55, delta: -13, previous: 68, status: null }),
    'Your recovery averaged 55% over the last 30 days, 13 points lower than the 30 days before.',
  );
  // No previous period with enough days: no comparison at all.
  assert.equal(
    sentence({ ...base, days: 4, key: 'weight', unit: 'lb', average: 160.04, delta: null, previous: null, status: null }),
    'Your weight averaged 160.0 lb over the last 30 days (4 days with data).',
  );
});

test("the sentence's status is the card's, in the card's own terms, and never a judgment", () => {
  const latest = { date: '2026-10-21', value: 63, source: 'whoop' };
  const s = (phrase: string) => sentence({ ...base, key: 'resting_hr', unit: 'bpm', average: 55, delta: null, previous: null, status: { phrase, latest } });
  assert.equal(s('is above your usual range'), 'Your resting heart rate averaged 55 bpm over the last 30 days; your latest, 63 bpm yesterday, is above your usual range.');
  const hrv = sentence({ ...base, key: 'hrv', unit: 'ms', average: 48, delta: 4, previous: 44, status: { phrase: 'is at or above your usual', latest: { ...latest, value: 52, date: '2026-10-22' } } });
  assert.equal(hrv, 'Your HRV averaged 48 ms over the last 30 days, 4 ms higher than the 30 days before; your latest, 52 ms today, is at or above your usual.');
  assert.doesNotMatch(hrv, /optimal|good|better|improv/i);
});

test('a change is steady below the metric\'s threshold or once it rounds to nothing', () => {
  assert.equal(isSteady('resting_hr', 0.9, 55, 'bpm'), true);
  assert.equal(isSteady('resting_hr', 1.2, 55, 'bpm'), false);
  assert.equal(isSteady('hrv', 1, 50, 'ms'), true, '2% of HRV is noise');
  assert.equal(isSteady('steps', 300, 8000, 'steps'), true, 'under 5% of steps');
  assert.equal(isSteady('weight', 0.04, 70, 'kg'), true);
  assert.equal(isSteady('weight', 0.3, 70, 'kg'), false);
});

test('a year is drawn as weekly averages, each dated its Monday', () => {
  // 2026-10-19 is a Monday.
  assert.deepEqual(
    weeklyMeans([
      { date: '2026-10-17', value: 2 },
      { date: '2026-10-18', value: 4 },
      { date: '2026-10-19', value: 10 },
      { date: '2026-10-21', value: 20 },
    ]),
    [
      { date: '2026-10-12', value: 3 },
      { date: '2026-10-19', value: 15 },
    ],
  );
});

test('"about 30 days earlier" is a reading near then, or nothing', () => {
  const pts = [
    { date: '2026-08-01', value: 80 },
    { date: '2026-09-20', value: 78 },
    { date: '2026-09-24', value: 77.5 },
    { date: '2026-10-22', value: 76 },
  ];
  assert.deepEqual(aboutBefore(pts), { date: '2026-09-20', value: 78 }, 'the closest to 30 days before (Sep 22)');
  assert.equal(aboutBefore([{ date: '2026-08-01', value: 80 }, { date: '2026-10-22', value: 76 }]), null, 'a reading 82 days before is not "about a month"');
  assert.equal(aboutBefore([]), null);
  assert.equal(Math.round(mmolFromMgDl(100) * 100) / 100, 5.55);
});

// ---------- over HTTP ----------

process.env.SESSION_SECRET = 'metricsheet-test-secret-'.padEnd(64, 'x');
const OWNER_PASSWORD = 'owner password 123';
process.env.HEALTHOS_PASSWORD_HASH = await hashPassword(OWNER_PASSWORD);

const db = await openStore();
// Hosted, so the owner without data isn't shown demo data.
const server = createApp({ db, hosted: true }).listen(0, '127.0.0.1');
await new Promise((r) => server.once('listening', r));
const baseUrl = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
test.after(() => {
  server.close();
  return db.close();
});

class Client {
  cookie = '';
  async call(method: string, path: string, body?: unknown) {
    const res = await fetch(baseUrl + path, {
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
      json = null;
    }
    return { status: res.status, json, text };
  }
  sheet(key: string, query: string) {
    return this.call('GET', `/api/metric/${key}?${query}`).then((r) => r.json as MetricSheet);
  }
}

const owner = new Client();
const bob = new Client();
let bobId = '';
const today = todayLocal();
/** The day the sheets are anchored on: yesterday, a complete day. */
const asOf = addDays(today, -1);
const ago = (n: number, from = asOf) => addDays(from, -n);

test('setup: an owner and a member, each with their own data', async () => {
  assert.equal((await owner.call('POST', '/api/auth/login', { email: 'owner@example.com', password: OWNER_PASSWORD })).status, 200);
  const { code } = (await owner.call('POST', '/api/admin/invites', {})).json;
  assert.equal((await bob.call('POST', '/api/auth/invite', { token: code, email: 'bob@example.com', name: 'Bob', password: 'Bob password 1' })).status, 200);
  bobId = (await bob.call('GET', '/api/auth/me')).json.user.id;

  const rows: DailyRow[] = [];
  for (let i = 0; i < 400; i++) {
    const date = ago(i);
    // Resting heart rate from the Watch every day, and WHOOP's (preferred) on most: the sheet must pick as the dashboard does.
    rows.push({ date, metric: 'resting_hr', source: 'apple', value: 60 + (i % 4) });
    if (i % 5 !== 0) rows.push({ date, metric: 'resting_hr', source: 'whoop', value: 52 + (i % 3) });
    // Blood oxygen from both devices, close enough to be averaged.
    rows.push({ date, metric: 'spo2', source: 'apple', value: 96 + (i % 2) }, { date, metric: 'spo2', source: 'whoop', value: 95.5 });
    rows.push({ date, metric: 'steps', source: 'apple', value: 6000 + ((i * 37) % 5000) });
    rows.push({ date, metric: 'hrv_rmssd', source: 'whoop', value: 40 + (i % 9) });
    if (i % 7 === 0) rows.push({ date, metric: 'weight', source: 'apple', value: 72 + i / 100 });
    if (i < 45) rows.push({ date, metric: 'glucose', source: 'apple', value: 95 + (i % 5) });
  }
  // The latest night's resting heart rate is well above the month before it: the card says "Above your usual".
  rows.push({ date: asOf, metric: 'resting_hr', source: 'whoop', value: 75 });
  // Today's steps so far: an unfinished day. The anchor day's count is what its hours (below) add up to.
  rows.push({ date: today, metric: 'steps', source: 'apple', value: 1200 }, { date: asOf, metric: 'steps', source: 'apple', value: 3500 });
  // Recovery on two days only in the previous month: too few to compare with.
  for (const d of [3, 8, 12, 15, 20, 22, 24, 25, 26, 27, 28]) rows.push({ date: ago(d), metric: 'recovery', source: 'whoop', value: 50 + d });
  rows.push({ date: ago(35), metric: 'recovery', source: 'whoop', value: 40 }, { date: ago(40), metric: 'recovery', source: 'whoop', value: 45 });
  await upsertDaily(db, OWNER_ID, rows);

  // Steps by the hour on the anchor day and the 5 days before it (for a typical day).
  const hours: HourlyRow[] = [];
  for (let d = 0; d <= 5; d++) for (const [h, v] of [[8, 1000], [12, 2000], [18, 500]]) hours.push({ date: ago(d), hour: h, metric: 'steps', source: 'apple', value: v + d * 10 });
  for (const [h, v] of [[7, 58], [8, 92], [9, 71]]) hours.push({ date: asOf, hour: h, metric: 'hr_avg', source: 'apple', value: v });
  await upsertHourly(db, OWNER_ID, hours);

  // Bob: numbers the owner's sheets must never contain.
  const bobRows: DailyRow[] = [];
  for (let i = 0; i < 60; i++) bobRows.push({ date: ago(i), metric: 'resting_hr', source: 'apple', value: 99 }, { date: ago(i), metric: 'steps', source: 'apple', value: 77_777 });
  await upsertDaily(db, bobId, bobRows);
});

test('week and month are the daily values GET /api/trends gives for the same days and date', async () => {
  for (const [range, days] of [
    ['week', 7],
    ['month', 30],
  ] as const) {
    for (const key of ['resting_hr', 'spo2', 'steps']) {
      const sheet = await owner.sheet(key, `range=${range}&date=${asOf}`);
      const trends = (await owner.call('GET', `/api/trends?metrics=${key}&days=${days}&date=${asOf}`)).json[key] as Point[];
      assert.equal(sheet.range, range);
      assert.equal(sheet.resolution, 'day');
      assert.equal(sheet.from, ago(days - 1));
      assert.equal(sheet.to, asOf);
      assert.deepEqual(sheet.points, trends, `${key} ${range}`);
      const avg = trends.reduce((a, p) => a + p.value, 0) / trends.length;
      assert.ok(Math.abs(sheet.headline.value! - avg) < 1e-9, `${key} ${range} average`);
    }
  }
  // Both devices: WHOOP's resting heart rate where there is one; SpO2 averaged.
  const rhr = await owner.sheet('resting_hr', `range=week&date=${asOf}`);
  assert.deepEqual(rhr.sources, ['apple', 'whoop']);
  assert.equal(rhr.points.at(-1)!.value, 75);
});

test('a year is weekly averages of the same daily values, and the day figures come from the days', async () => {
  const sheet = await owner.sheet('resting_hr', `range=year&date=${asOf}`);
  const daily = (await owner.call('GET', `/api/trends?metrics=resting_hr&days=365&date=${asOf}`)).json.resting_hr as Point[];
  assert.equal(sheet.resolution, 'week');
  assert.deepEqual(sheet.points, weeklyMeans(daily));
  assert.equal(sheet.tiles[0].value, Math.min(...daily.map((p) => p.value)));
  assert.equal(sheet.tiles[1].value, Math.max(...daily.map((p) => p.value)));
  assert.equal(sheet.days, 365);
});

test("the status and the sentence are the card's, from the summary for the same date", async () => {
  const s = (await owner.call('GET', `/api/summary?date=${asOf}`)).json as Summary;
  assert.equal(s.vitals.heart.status, 'high');
  const rhr = await owner.sheet('resting_hr', `range=month&date=${asOf}`);
  assert.deepEqual(rhr.status, { text: 'Above your usual', position: 'above' });
  assert.match(rhr.narrative!, /your latest, 75 bpm yesterday, is above your usual range\.$/);
  assert.doesNotMatch(rhr.narrative!, /within|below/);

  // HRV: the summary's metric and status, in Body's words.
  const hrv = await owner.sheet('hrv', `range=month&date=${asOf}`);
  assert.equal(hrv.metric, s.hrv.metric);
  const words = { optimal: 'At or above your usual', normal: 'Within your usual', low: 'Below your usual' } as const;
  assert.equal(hrv.status?.text, words[s.hrv.status!]);
  assert.doesNotMatch(hrv.narrative!, /optimal/i);

  // Blood oxygen: the summary's own range status.
  const spo2 = await owner.sheet('spo2', `range=month&date=${asOf}`);
  // The cards say "Normal" for anything not below the range, so a high reading is "at or above", never just "above".
  const spo2Words = { low: 'Below your usual', normal: 'Within your usual', high: 'At or above your usual' } as const;
  assert.equal(spo2.status?.text, spo2Words[s.spo2.status!]);

  // Steps: the share of the goal the Activity card shows.
  const steps = await owner.sheet('steps', `range=week&date=${asOf}`);
  assert.equal(steps.status?.text, `${Math.round((s.activity.latest!.value / s.stepGoal) * 100)}% of goal`);
});

test("today's unfinished total is drawn but left out of the figures", async () => {
  const sheet = await owner.sheet('steps', `range=week&date=${today}`);
  const trends = (await owner.call('GET', `/api/trends?metrics=steps&days=7&date=${today}`)).json.steps as Point[];
  assert.deepEqual(sheet.points, trends, 'today is on the chart');
  assert.equal(sheet.partialToday, true);
  assert.equal(sheet.days, 6);
  const whole = trends.slice(0, -1);
  assert.ok(Math.abs(sheet.headline.value! - whole.reduce((a, p) => a + p.value, 0) / whole.length) < 1e-9);
  assert.notEqual(sheet.tiles[0].value, 1200, "today's 1,200 so far isn't the lowest day");
  assert.deepEqual([sheet.tiles[2].value, sheet.tiles[2].note], [1200, 'so far today']);
});

test('a change needs enough days in both periods', async () => {
  const rec = await owner.sheet('recovery', `range=month&date=${asOf}`);
  assert.equal(rec.days, 11);
  assert.equal(rec.change, null, 'two days the month before is too few');
  assert.doesNotMatch(rec.narrative!, /than the 30 days before/);
  const rhr = await owner.sheet('resting_hr', `range=month&date=${asOf}`);
  assert.ok(rhr.change);
  assert.equal(rhr.change.days, 30);
});

test('the Day range is for steps, active energy and heart rate only', async () => {
  const day = await owner.sheet('steps', `range=day&date=${asOf}`);
  assert.equal(day.resolution, 'hour');
  assert.deepEqual(day.ranges, ['day', 'week', 'month', 'year']);
  assert.equal(day.day!.metrics.steps!.hours[8], 1000);
  assert.equal(day.headline.value, 3500, 'the whole day, hour by hour');
  assert.match(day.narrative!, /^You took 3,500 steps yesterday, about the same as your typical day\.$/);

  // The phone's day count ahead of its hours (not all synced): the day's count, as the Activity card shows it, and no
  // comparison with a typical day the hours can't stand for.
  await upsertDaily(db, OWNER_ID, [{ date: ago(1), metric: 'steps', source: 'apple', value: 5000 }]);
  const ahead = await owner.sheet('steps', `range=day&date=${ago(1)}`);
  assert.equal(ahead.headline.value, 5000);
  assert.equal(ahead.change, null);
  assert.equal(ahead.tiles[2].note, '50% reached');
  assert.match(ahead.narrative!, /^You took 5,000 steps on .+, the day's count; 3,530 steps in the hours recorded\.$/);

  const hr = await owner.sheet('heart_rate', `date=${asOf}`);
  assert.equal(hr.range, 'day', 'heart rate opens on its only range');
  assert.equal(hr.headline.value, 71);
  assert.deepEqual([hr.tiles[0].value, hr.tiles[1].value], [58, 92]);

  for (const [key, range] of [
    ['heart_rate', 'week'],
    ['resting_hr', 'day'],
    ['glucose', 'day'],
  ]) {
    const r = await owner.call('GET', `/api/metric/${key}?range=${range}&date=${asOf}`);
    assert.equal(r.status, 400, `${key} ${range}`);
  }
  // Someone without hours for a metric isn't offered its Day view.
  assert.deepEqual((await bob.sheet('steps', `range=week&date=${asOf}`)).ranges, ['week', 'month', 'year']);
});

test('unknown metrics, ranges and dates are refused without repeating them', async () => {
  const r = await owner.call('GET', '/api/metric/secret_thing?range=week');
  assert.equal(r.status, 404);
  assert.doesNotMatch(r.text, /secret_thing/);
  assert.equal((await owner.call('GET', '/api/metric/steps?range=decade')).status, 400);
  assert.equal((await owner.call('GET', '/api/metric/steps?range=week&date=yesterday')).status, 400);
  assert.equal((await owner.call('GET', '/api/metric/__proto__?range=week')).status, 404);
});

test("one person's sheet never shows another's data", async () => {
  for (const range of ['week', 'month', 'year']) {
    const mine = await owner.sheet('resting_hr', `range=${range}&date=${asOf}`);
    assert.ok(mine.points.every((p) => p.value !== 99), range);
    const theirs = await bob.sheet('resting_hr', `range=${range}&date=${asOf}`);
    assert.ok(theirs.points.length > 0 && theirs.points.every((p) => p.value === 99), range);
  }
  const steps = await owner.sheet('steps', `range=month&date=${asOf}`);
  assert.ok(steps.points.every((p) => p.value !== 77_777));
  assert.equal((await bob.sheet('steps', `range=day&date=${asOf}`)).day?.metrics.steps, undefined, "the owner's hours aren't Bob's");
  assert.equal((await bob.sheet('weight', `range=month&date=${asOf}`)).points.length, 0);
  // Signed out, nothing.
  assert.equal((await new Client().call('GET', `/api/metric/steps?range=week&date=${asOf}`)).status, 401);
});

test("mass is in the person's units; glucose stays in mg/dL with its own usual range", async () => {
  const kg = await owner.sheet('weight', `range=year&date=${asOf}`);
  assert.equal(kg.unit, 'kg');
  await owner.call('PUT', '/api/settings', { units: 'imperial' });
  const lb = await owner.sheet('weight', `range=year&date=${asOf}`);
  assert.equal(lb.unit, 'lb');
  assert.equal(lb.points.length, kg.points.length);
  lb.points.forEach((p, i) => assert.ok(Math.abs(p.value - kg.points[i].value / 0.45359237) < 1e-9));
  assert.ok(Math.abs(lb.headline.value! - kg.headline.value! / 0.45359237) < 1e-9);
  assert.match(lb.narrative!, / lb /);
  await owner.call('PUT', '/api/settings', { units: 'metric' });

  const glucose = await owner.sheet('glucose', `range=month&date=${asOf}`);
  assert.equal(glucose.unit, 'mg/dL');
  assert.equal(glucose.points.length, 30);
  assert.ok(glucose.status, 'a daily average against its own last 30 days');
  assert.equal(glucose.status.position, 'within');
  assert.match(glucose.narrative!, /mg\/dL/);
});
