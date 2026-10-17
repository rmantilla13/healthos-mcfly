// The Day view: hourly rows from the iPhone app and the export importer, and GET /api/day over HTTP.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import type { AddressInfo } from 'node:net';
import path from 'node:path';
import { Readable } from 'node:stream';
import { createApp } from '../server/app.ts';
import { importAppleHealth, parseStream } from '../server/apple/import.ts';
import { hashPassword } from '../server/auth.ts';
import { median, typicalHourly, typicalRunning } from '../server/day.ts';
import { OWNER_ID } from '../server/db.ts';
import { openStore } from '../server/store.ts';

process.env.SESSION_SECRET = 'day-test-secret-'.padEnd(64, 'x');
const OWNER_PASSWORD = 'owner password 123';
process.env.HEALTHOS_PASSWORD_HASH = await hashPassword(OWNER_PASSWORD);
const OWNER_INGEST = 'owner-ingest-token-for-day-tests';
const FIXTURE = path.join(import.meta.dirname, 'fixtures', 'export.xml');

// ---------- the typical-day maths ----------

const day = (entries: Record<number, number>) => Array.from({ length: 24 }, (_, h) => entries[h] ?? null);

test('median takes the middle value, or the mean of the two middle values', () => {
  assert.equal(median([]), null);
  assert.equal(median([5]), 5);
  assert.equal(median([9, 1, 5]), 5);
  assert.equal(median([1, 2, 3, 10]), 2.5);
});

test('typical-by-now is the median running total, with missing hours adding nothing', () => {
  const typical = typicalRunning([day({ 8: 1000, 12: 2000 }), day({ 9: 500 }), day({ 8: 3000, 9: 1000 })]);
  assert.equal(typical.length, 24);
  assert.equal(typical[7], 0); // nothing yet on any day
  assert.equal(typical[8], 1000); // running totals 1000, 0, 3000
  assert.equal(typical[9], 1000); // 1000, 500, 4000
  assert.equal(typical[23], 3000); // 3000, 500, 4000
  assert.deepEqual(typicalRunning([day({ 8: 1 }), day({ 8: 2 })]), day({}), 'needs at least 3 days');
});

test('the typical hourly reading needs 3 days with a reading at that hour', () => {
  const typical = typicalHourly([day({ 8: 60, 9: 70 }), day({ 8: 64 }), day({ 8: 80, 9: 72 })]);
  assert.equal(typical[8], 64);
  assert.equal(typical[9], null);
});

// ---------- the export importer ----------

test('the importer keeps one source per day hour by hour, as days do', async () => {
  const agg = await parseStream(fs.createReadStream(FIXTURE));
  const { hourly } = agg.finish();
  const at = (metric: string, date: string) =>
    Object.fromEntries(hourly.filter((h) => h.metric === metric && h.date === date).map((h) => [h.hour, Math.round(h.value * 10) / 10]));
  // The Watch logged 5,500 steps that day and the iPhone 5,000 for the same walks: only the Watch's hours count.
  assert.deepEqual(at('steps', '2026-10-13'), { 8: 3200, 17: 2100, 23: 200 });
  assert.deepEqual(at('active_energy', '2026-10-13'), { 10: 100 });
  assert.deepEqual(at('hr_avg', '2026-10-13'), { 9: 60, 12: 90 });
  assert.deepEqual(at('hr_min', '2026-10-13'), { 9: 60, 12: 90 });
  assert.ok(hourly.every((h) => h.source === 'apple'));
});

test("with the person's time zone, export hours follow the zone, not the export's one fixed offset", async () => {
  // Apple prints every timestamp with today's offset (-05:00, summer time). In January Chicago is at -06:00,
  // so a walk printed at 09:30 -0500 happened at 08:30 local time.
  const xml = `<?xml version="1.0" encoding="UTF-8"?><HealthData>
    <Record type="HKQuantityTypeIdentifierStepCount" sourceName="Watch" unit="count" startDate="2026-01-15 09:30:00 -0500" endDate="2026-01-15 09:40:00 -0500" value="700"/>
    <Record type="HKQuantityTypeIdentifierStepCount" sourceName="Watch" unit="count" startDate="2026-07-15 09:30:00 -0500" endDate="2026-07-15 09:40:00 -0500" value="900"/>
    <Record type="HKQuantityTypeIdentifierActiveEnergyBurned" sourceName="WHOOP" unit="kcal" startDate="2026-07-15 10:30:00 -0500" endDate="2026-07-15 10:40:00 -0500" value="500"/>
  </HealthData>`;
  const hours = async (timeZone?: string) =>
    (await parseStream(Readable.from([Buffer.from(xml)]), undefined, { timeZone })).finish().hourly.map((h) => `${h.date} ${h.hour} ${h.value}`);
  assert.deepEqual(await hours('America/Chicago'), ['2026-01-15 8 700', '2026-07-15 9 900']);
  assert.deepEqual(await hours(), ['2026-01-15 9 700', '2026-07-15 9 900'], "without a zone, the export's own wall clock");
});

test('an import replaces the Apple hourly rows along with the daily ones', async () => {
  const db = await openStore();
  await db.query("INSERT INTO hourly (user_id, metric, date, hour, source, value) VALUES ($1, 'steps', '2020-01-01', 5, 'apple', 1)", [OWNER_ID]);
  await importAppleHealth({ db, userId: OWNER_ID }, FIXTURE);
  const rows = await db.query<{ date: string; hour: number; value: number }>("SELECT date, hour, value FROM hourly WHERE metric = 'steps' ORDER BY date, hour");
  assert.deepEqual(
    rows.map((r) => [r.date, r.hour, r.value]),
    [
      ['2026-10-13', 8, 3200],
      ['2026-10-13', 17, 2100],
      ['2026-10-13', 23, 200],
    ],
  );
});

// ---------- the iPhone app and GET /api/day ----------

const db = await openStore();
const app = createApp({ db, hosted: false, ingestToken: OWNER_INGEST });
const server = app.listen(0, '127.0.0.1');
await new Promise((r) => server.once('listening', r));
const base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
test.after(() => {
  server.close();
});

class Client {
  cookie = '';
  async call(method: string, p: string, body?: unknown) {
    const res = await fetch(base + p, {
      method,
      headers: { 'X-HealthOS': '1', 'Content-Type': 'application/json', ...(this.cookie ? { Cookie: this.cookie } : {}) },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const set = res.headers.get('set-cookie');
    if (set) this.cookie = set.split(';')[0];
    return { status: res.status, json: (await res.json().catch(() => null)) as any };
  }
}

const push = (token: string, hourly: unknown[]) =>
  fetch(`${base}/api/apple/ingest`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-HealthOS': '1', Authorization: `Bearer ${token}` },
    body: JSON.stringify({ hourly }),
  });

const owner = new Client();
const bob = new Client();
let bobToken = '';
const D = '2026-10-16';
const back = (n: number) => new Date(Date.parse(`${D}T00:00:00Z`) - n * 86_400_000).toISOString().slice(0, 10);

test('setup: the owner and an invited member', async () => {
  assert.equal((await owner.call('POST', '/api/auth/login', { email: 'owner@example.com', password: OWNER_PASSWORD })).status, 200);
  const { code } = (await owner.call('POST', '/api/admin/invites', {})).json;
  assert.equal((await bob.call('POST', '/api/auth/invite', { token: code, email: 'bob@example.com', name: 'Bob', password: 'bob password 123' })).status, 200);
  bobToken = (await bob.call('POST', '/api/me/ingest-token')).json.token;
});

test('the iPhone app sends hourly buckets; bad ones are refused whole', async () => {
  const bad = [
    { date: D, hour: 24, metric: 'steps', value: 1 },
    { date: D, hour: 1.5, metric: 'steps', value: 1 },
    { date: D, hour: 1, metric: 'spo2', value: 97 },
    { date: D, hour: 1, metric: 'steps', value: -3 },
    { date: '2026-02-30', hour: 1, metric: 'steps', value: 3 },
  ];
  for (const row of bad) assert.equal((await push(OWNER_INGEST, [row])).status, 400, JSON.stringify(row));

  const hourly = [
    // Three earlier days for the typical curve, then the day itself.
    ...[1, 2, 3].flatMap((n) => [
      { date: back(n), hour: 8, metric: 'steps', value: 1000 * n },
      { date: back(n), hour: 12, metric: 'steps', value: 500 },
      { date: back(n), hour: 8, metric: 'hr_avg', value: 60 + n },
    ]),
    { date: D, hour: 8, metric: 'steps', value: 1500 },
    { date: D, hour: 9, metric: 'steps', value: 300 },
    // The hour that repeats when clocks go back arrives twice: the two fold into one bucket.
    { date: D, hour: 1, metric: 'steps', value: 20 },
    { date: D, hour: 1, metric: 'steps', value: 30 },
    { date: D, hour: 8, metric: 'hr_avg', value: 72 },
    { date: D, hour: 8, metric: 'hr_min', value: 58 },
    { date: D, hour: 8, metric: 'hr_max', value: 131 },
  ];
  const res = await push(OWNER_INGEST, hourly);
  assert.equal(res.status, 200);
  assert.equal((await res.json()).hourly, hourly.length);
});

test("the Day view shows one person's own day, next to their typical day", async () => {
  const { status, json } = await owner.call('GET', `/api/day?metrics=steps,active_energy,heart_rate&date=${D}`);
  assert.equal(status, 200);
  assert.equal(json.date, D);
  assert.deepEqual(Object.keys(json.metrics).sort(), ['heart_rate', 'steps'], 'no active energy rows at all, so no active energy series');
  const steps = json.metrics.steps;
  assert.equal(steps.hours.length, 24);
  assert.deepEqual([steps.hours[0], steps.hours[1], steps.hours[8], steps.hours[9], steps.hours[10]], [null, 50, 1500, 300, null]);
  // Running totals by 8 AM on the three days before: 1000, 2000, 3000. By noon: 1500, 2500, 3500.
  // The other 27 of the 30 days have no rows and are left out: counted as zeros, every median would be 0.
  assert.deepEqual([steps.typical[7], steps.typical[8], steps.typical[12]], [0, 2000, 2500]);
  const hr = json.metrics.heart_rate;
  assert.deepEqual([hr.hours[8], hr.min[8], hr.max[8], hr.typical[8], hr.typical[9]], [72, 58, 131, 62, null]);
  assert.equal(json.asOf, 9);
});

test('a re-sent day replaces its hours, and other people never see them', async () => {
  // The phone recomputed the day: the 9 AM sample was deleted in Health.
  assert.equal((await push(OWNER_INGEST, [{ date: D, hour: 8, metric: 'steps', value: 1500 }])).status, 200);
  const steps = (await owner.call('GET', `/api/day?metrics=steps&date=${D}`)).json.metrics.steps;
  assert.deepEqual([steps.hours[1], steps.hours[8], steps.hours[9]], [null, 1500, null]);

  // Bob has no hourly data at all: no Day view for him, whatever the owner has.
  assert.deepEqual((await bob.call('GET', `/api/day?metrics=steps,heart_rate&date=${D}`)).json.metrics, {});
  assert.equal((await push(bobToken, [{ date: D, hour: 14, metric: 'steps', value: 4242 }])).status, 200);
  const his = (await bob.call('GET', `/api/day?metrics=steps,heart_rate&date=${D}`)).json;
  assert.deepEqual(Object.keys(his.metrics), ['steps']);
  assert.equal(his.metrics.steps.hours[14], 4242);
  assert.equal(his.metrics.steps.hours[8], null);
  assert.equal(his.asOf, 14);
  // And the owner's day is untouched by Bob's push.
  assert.equal((await owner.call('GET', `/api/day?metrics=steps&date=${D}`)).json.metrics.steps.hours[14], null);
});

test('the date defaults to today, a future date shows today, and bad requests are refused', async () => {
  const now = await owner.call('GET', '/api/day?metrics=steps');
  assert.equal(now.json.date, now.json.today);
  assert.equal((await owner.call('GET', '/api/day?metrics=steps&date=2999-01-01')).json.date, now.json.today);
  const unknown = await owner.call('GET', '/api/day?metrics=sleep,steps_typo');
  assert.deepEqual([unknown.status, unknown.json.metrics, unknown.json.asOf], [200, {}, null], 'unknown names are ignored');
  assert.equal((await owner.call('GET', '/api/day?metrics=steps&date=yesterday')).status, 400);
  assert.equal((await new Client().call('GET', '/api/day?metrics=steps')).status, 401);
});

test('deleting an account removes its hourly rows too', async () => {
  const id = (await bob.call('GET', '/api/auth/me')).json.user.id;
  assert.equal((await owner.call('DELETE', `/api/admin/users/${id}`)).status, 200);
  assert.equal((await db.query<{ n: number }>('SELECT COUNT(*)::int AS n FROM hourly WHERE user_id = $1', [id]))[0].n, 0);
  assert.ok((await db.query<{ n: number }>('SELECT COUNT(*)::int AS n FROM hourly WHERE user_id = $1', [OWNER_ID]))[0].n > 0);
});
