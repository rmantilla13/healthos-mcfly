// Detail sheets, the redesign's additions: "What this means" for every metric, whether a metric was ever measured (the
// sheet's "No measurement yet", which must not move to Year looking for something), and the two sleep scores the Sleep
// cards open (WHOOP's performance, and efficiency, worked out from a device's own two numbers where it sent none).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { AddressInfo } from 'node:net';
import { METRIC_INFO, METRIC_KEYS, type MetricSheet, showSheet, widerRange } from '../shared/metrics.ts';
import type { Point } from '../shared/types.ts';
import { createApp } from '../server/app.ts';
import { hashPassword } from '../server/auth.ts';
import { addDays, todayLocal } from '../server/dates.ts';
import { OWNER_ID, type DailyRow, upsertDaily, upsertHourly } from '../server/db.ts';
import { withDerivedEfficiency } from '../server/metricsheet.ts';
import { openStore } from '../server/store.ts';

test('every metric has a plain explainer, a caveat and an https source', () => {
  for (const key of METRIC_KEYS) {
    const { about, label } = METRIC_INFO[key];
    assert.ok(about.what.length > 20 && about.what.endsWith('.'), `${key} what`);
    assert.match(about.caveat, /context/, `${key} caveat`);
    assert.match(about.source.href, /^https:\/\/[a-z0-9.-]+\.[a-z]{2,}\//, `${key} href`);
    assert.match(about.source.label, /^[A-Za-z ]+ · \S/, `${key} source label`);
    assert.ok(label.length > 0);
    // The design's mock named another brand; nothing here may.
    assert.doesNotMatch(JSON.stringify(about), /xeyo/i);
  }
  // Blood oxygen's explainer points at a page about blood oxygen, not the mock's placeholder about recovery.
  assert.doesNotMatch(METRIC_INFO.spo2.about.source.label, /recovery/i);
});

test("efficiency is a device's time asleep over its own time in bed, never two devices' numbers mixed", () => {
  const daily = new Map([
    ['sleep_hours', new Map([['apple', new Map([['2026-10-01', 7], ['2026-10-02', 6], ['2026-10-03', 8]])], ['whoop', new Map([['2026-10-01', 7.2]])]])],
    ['sleep_in_bed', new Map([['apple', new Map([['2026-10-01', 7.5], ['2026-10-02', 6]])], ['whoop', new Map([['2026-10-03', 9]])]])],
    ['sleep_efficiency', new Map([['whoop', new Map([['2026-10-01', 91]])]])],
  ]);
  const eff = withDerivedEfficiency(daily).get('sleep_efficiency')!;
  assert.ok(Math.abs(eff.get('apple')!.get('2026-10-01')! - (7 / 7.5) * 100) < 1e-9);
  // No awake time at all: Apple recorded time in bed only, so there's no efficiency to give.
  assert.equal(eff.get('apple')!.has('2026-10-02'), false);
  // Apple's sleep with WHOOP's time in bed isn't one device's night.
  assert.equal(eff.get('apple')!.has('2026-10-03'), false);
  assert.equal(eff.get('whoop')!.has('2026-10-03'), false);
  // WHOOP's own figure stays as sent.
  assert.equal(eff.get('whoop')!.get('2026-10-01'), 91);
});

// ---------- over HTTP ----------

process.env.SESSION_SECRET = 'metricsheet-ever-test-secret-'.padEnd(64, 'x');
const OWNER_PASSWORD = 'owner password 123';
process.env.HEALTHOS_PASSWORD_HASH = await hashPassword(OWNER_PASSWORD);

const db = await openStore();
// Hosted, so a person without data isn't shown demo data.
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
const asOf = addDays(today, -1);
const ago = (n: number) => addDays(asOf, -n);

test('setup: an owner and a member, each with their own data', async () => {
  assert.equal((await owner.call('POST', '/api/auth/login', { email: 'owner@example.com', password: OWNER_PASSWORD })).status, 200);
  const { code } = (await owner.call('POST', '/api/admin/invites', {})).json;
  assert.equal((await bob.call('POST', '/api/auth/invite', { token: code, email: 'bob@example.com', name: 'Bob', password: 'Bob password 1' })).status, 200);
  bobId = (await bob.call('GET', '/api/auth/me')).json.user.id;

  const rows: DailyRow[] = [
    // One VO₂ max estimate, well over a year ago.
    { date: ago(500), metric: 'vo2max', source: 'apple', value: 41 },
    // HRV from the Watch only (SDNN).
    { date: ago(3), metric: 'hrv_sdnn', source: 'apple', value: 48 },
  ];
  for (let i = 0; i < 30; i++) {
    rows.push({ date: ago(i), metric: 'sleep_performance', source: 'whoop', value: 70 + (i % 20) });
    // WHOOP's own efficiency on even days; on odd days only the Watch's night, with its time in bed.
    if (i % 2 === 0) rows.push({ date: ago(i), metric: 'sleep_efficiency', source: 'whoop', value: 90 + (i % 5) });
    else rows.push({ date: ago(i), metric: 'sleep_hours', source: 'apple', value: 7 }, { date: ago(i), metric: 'sleep_in_bed', source: 'apple', value: 8 });
  }
  await upsertDaily(db, OWNER_ID, rows);
  // Heart rate and steps by the hour only, as the iPhone app sends them before any daily total.
  await upsertHourly(db, OWNER_ID, [
    { date: asOf, hour: 9, metric: 'hr_avg', source: 'apple', value: 72 },
    { date: asOf, hour: 9, metric: 'steps', source: 'apple', value: 800 },
  ]);

  // Bob: readings the owner has never had. They must not count as the owner's.
  await upsertDaily(db, bobId, [
    { date: ago(2), metric: 'resp_rate', source: 'whoop', value: 15 },
    { date: ago(2), metric: 'spo2', source: 'apple', value: 97 },
  ]);
});

test('never measured: the sheet says so, stays on its range and is shown at once', async () => {
  for (const key of ['spo2', 'resp_rate', 'recovery', 'glucose', 'weight']) {
    const sheet = await owner.sheet(key, `range=month&date=${asOf}`);
    assert.equal(sheet.everMeasured, false, key);
    assert.deepEqual(sheet.points, [], key);
    assert.equal(widerRange(sheet), null, `${key} doesn't move to Year looking for something`);
    assert.equal(showSheet(sheet, 'month', false), true, key);
  }
  // Bob has the readings the owner lacks.
  assert.equal((await bob.sheet('resp_rate', `range=month&date=${asOf}`)).everMeasured, true);
  assert.equal((await bob.sheet('spo2', `range=month&date=${asOf}`)).everMeasured, true);
  // And none of the owner's.
  for (const key of ['vo2max', 'hrv', 'sleep_performance', 'sleep_efficiency']) assert.equal((await bob.sheet(key, `range=month&date=${asOf}`)).everMeasured, false, key);
  assert.equal((await bob.sheet('heart_rate', `date=${asOf}`)).everMeasured, false);
});

test('measured once, however long ago: the empty window still moves to the longest range', async () => {
  const month = await owner.sheet('vo2max', `range=month&date=${asOf}`);
  assert.equal(month.everMeasured, true);
  assert.equal(month.headline.value, null);
  assert.equal(widerRange(month), 'year');
  // Older than the year too: measured, though nothing is in any window.
  const year = await owner.sheet('vo2max', `range=year&date=${asOf}`);
  assert.equal(year.everMeasured, true);
  assert.deepEqual(year.points, []);
});

test('HRV counts either measure; heart rate and steps count their hours', async () => {
  const hrv = await owner.sheet('hrv', `range=week&date=${asOf}`);
  assert.equal(hrv.everMeasured, true);
  assert.equal(hrv.metric, 'hrv_sdnn');
  const hr = await owner.sheet('heart_rate', `date=${asOf}`);
  assert.equal(hr.everMeasured, true);
  assert.equal(hr.headline.value, 72);
  // Steps with hours and no daily total yet: measured, on every range.
  assert.equal((await owner.sheet('steps', `range=day&date=${asOf}`)).everMeasured, true);
  assert.equal((await owner.sheet('steps', `range=month&date=${asOf}`)).everMeasured, true);
});

test("sleep performance is WHOOP's nightly score, as GET /api/trends gives it", async () => {
  const sheet = await owner.sheet('sleep_performance', `range=month&date=${asOf}`);
  const trends = (await owner.call('GET', `/api/trends?metrics=sleep_performance&days=30&date=${asOf}`)).json.sleep_performance as Point[];
  assert.equal(sheet.unit, '%');
  assert.equal(sheet.everMeasured, true);
  assert.deepEqual(sheet.points, trends);
  assert.deepEqual(sheet.sources, ['whoop']);
  assert.match(sheet.narrative!, /^Your sleep performance averaged \d+% over the last 30 days\.$/);
});

test("sleep efficiency is WHOOP's where it sent one, and the Watch's own asleep over in bed where not", async () => {
  const sheet = await owner.sheet('sleep_efficiency', `range=month&date=${asOf}`);
  assert.equal(sheet.everMeasured, true);
  assert.equal(sheet.points.length, 30);
  for (const p of sheet.points) {
    const i = (Date.parse(`${asOf}T00:00:00Z`) - Date.parse(`${p.date}T00:00:00Z`)) / 86_400_000;
    assert.equal(p.value, i % 2 === 0 ? 90 + (i % 5) : 87.5, p.date);
  }
  assert.deepEqual(sheet.sources, ['apple', 'whoop']);
  // Someone with only the Watch's nights has a sleep efficiency too, so the sheet never says "No measurement yet" to them.
  await upsertDaily(db, bobId, [
    { date: ago(1), metric: 'sleep_hours', source: 'apple', value: 6 },
    { date: ago(1), metric: 'sleep_in_bed', source: 'apple', value: 7.5 },
  ]);
  const watch = await bob.sheet('sleep_efficiency', `range=week&date=${asOf}`);
  assert.equal(watch.everMeasured, true);
  assert.deepEqual(watch.points, [{ date: ago(1), value: 80 }]);
});
