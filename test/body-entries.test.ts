// /api/body: measurements a person adds themselves, end to end over HTTP. Each entry is kept as given and mirrored
// into `daily` as source 'manual' (the day's latest entry), where it wins its day over a scale's Apple Health reading.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { AddressInfo } from 'node:net';
import { createApp } from '../server/app.ts';
import { hashPassword } from '../server/auth.ts';
import { addDays, todayLocal } from '../server/dates.ts';
import { OWNER_ID, setUserSetting, upsertDaily } from '../server/db.ts';
import { openStore } from '../server/store.ts';

process.env.SESSION_SECRET = 'body-entries-test-secret-'.padEnd(64, 'x');
const OWNER_PASSWORD = 'owner password 123';
process.env.HEALTHOS_PASSWORD_HASH = await hashPassword(OWNER_PASSWORD);

const db = await openStore();
const server = createApp({ db, hosted: false, ingestToken: 'body-entries-ingest-token-0123456789' }).listen(0, '127.0.0.1');
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
      headers: { 'Content-Type': 'application/json', ...headers, ...(this.cookie ? { Cookie: this.cookie } : {}) },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const set = res.headers.get('set-cookie');
    if (set) this.cookie = set.split(';')[0];
    return { status: res.status, json: (await res.json().catch(() => null)) as any };
  }
  get = (p: string) => this.call('GET', p);
  post = (p: string, b?: unknown) => this.call('POST', p, b ?? {});
}

const owner = new Client();
const bob = new Client();
const today = todayLocal('UTC');
const back = (n: number) => addDays(today, -n);
const weights = async (c: Client, date = today) => (await c.get(`/api/trends?metrics=weight&days=30&date=${date}`)).json.weight as { date: string; value: number }[];
const weightOn = async (c: Client, date: string) => (await weights(c)).find((p) => p.date === date)?.value;

test('while the demo data shows, entries are refused rather than hidden as they save', async () => {
  assert.equal((await owner.post('/api/auth/login', { email: 'owner@example.com', password: OWNER_PASSWORD })).status, 200);
  await setUserSetting(db, OWNER_ID, 'timezone', 'UTC');
  const r = await owner.post('/api/body/entries', { metric: 'weight', value: 72, date: today });
  assert.equal(r.status, 409);
  assert.equal(r.json.error, 'Turn off demo data in your Profile to add your own measurements.');
  assert.deepEqual((await owner.get('/api/body/entries')).json, { entries: [] });
});

test('every field is checked, and the messages never repeat the value sent', async () => {
  // A scale's Apple Health readings: real data, so the local demo is off from here on.
  await upsertDaily(db, OWNER_ID, [back(3), back(2), back(1), today].map((date) => ({ date, metric: 'weight', source: 'apple', value: 80 })));
  const bad = async (body: Record<string, unknown>, error: string | RegExp) => {
    const r = await owner.post('/api/body/entries', { metric: 'weight', value: 72, date: today, ...body });
    assert.equal(r.status, 400, JSON.stringify(body));
    if (typeof error === 'string') assert.equal(r.json.error, error);
    else assert.match(r.json.error, error);
    return r.json.error as string;
  };
  await bad({ metric: 'height' }, 'Choose weight, body fat or lean body mass.');
  await bad({ value: '72' }, 'Enter your weight as a number.');
  await bad({ value: Number.NaN }, 'Enter your weight as a number.');
  assert.doesNotMatch(await bad({ value: 512 }, 'Enter a weight between 20 and 400 kg.'), /512/);
  await bad({ value: 30, unit: 'lb' }, 'Enter a weight between 45 and 881 lb.');
  await bad({ metric: 'body_fat', value: 90 }, 'Enter a body fat between 2 and 75%.');
  await bad({ metric: 'body_fat', value: 20, unit: 'lb' }, 'Body fat is a percentage.');
  await bad({ metric: 'lean_mass', value: 5 }, 'Enter a lean body mass between 10 and 250 kg.');
  await bad({ unit: 'stone' }, 'Choose kg or lb.');
  await bad({ date: '2026-02-30' }, 'Enter the date as YYYY-MM-DD.');
  await bad({ date: addDays(today, 1) }, "That day hasn't happened yet.");
  await bad({ date: '1899-12-31' }, 'Enter a date from 1900 on.');
  await bad({ time: '25:00' }, 'Enter the time as HH:MM, or leave it empty.');
  await bad({ method: 'guess' }, 'Choose Scale, Scan or Records.');
  await bad({ note: 'x'.repeat(201) }, 'Keep the note to 200 characters.');
  // A write without the app's header is refused before it's read.
  assert.equal((await owner.call('POST', '/api/body/entries', { metric: 'weight', value: 72, date: today }, {})).status, 403);
  assert.deepEqual((await owner.get('/api/body/entries')).json, { entries: [] });
});

test('pounds are stored as kilograms, and a typed entry wins its day over the scale', async () => {
  const r = await owner.post('/api/body/entries', { metric: 'weight', value: 154.3, unit: 'lb', date: back(1), method: 'scale', note: '  after a run  ' });
  assert.equal(r.status, 200);
  assert.equal(r.json.entry.value, 69.989);
  assert.equal(r.json.entry.note, 'after a run');
  assert.equal(r.json.entry.method, 'scale');
  assert.equal(r.json.entry.time, null);
  assert.equal(await weightOn(owner, back(1)), 69.989);
  assert.equal(await weightOn(owner, back(2)), 80, 'a day without an entry keeps the scale');
  const latest = (await owner.get(`/api/body/latest?date=${back(1)}`)).json;
  assert.deepEqual(latest.weight, { date: back(1), value: 69.989, source: 'manual' });
  assert.equal(latest.body_fat, null);
  assert.deepEqual((await owner.get('/api/body/latest')).json.weight, { date: today, value: 80, source: 'apple' });
});

test("a day's value is its latest entry: by time, and an entry without one counts as earlier", async () => {
  const add = async (value: number, time?: string) => (await owner.post('/api/body/entries', { metric: 'body_fat', value, date: back(2), time })).json.entry.id as string;
  const morning = await add(21.4, '07:10');
  await add(21.0);
  const fat = async () => (await owner.get(`/api/trends?metrics=body_fat&days=7&date=${today}`)).json.body_fat as { date: string; value: number }[];
  assert.deepEqual(await fat(), [{ date: back(2), value: 21.4 }], 'the timed entry is later than the untimed one');
  const evening = await add(20.8, '21:30');
  assert.deepEqual(await fat(), [{ date: back(2), value: 20.8 }]);
  const list = (await owner.get('/api/body/entries?metric=body_fat')).json.entries as { id: string; time: string | null }[];
  assert.deepEqual(list.map((e) => e.time), ['21:30', '07:10', null], 'newest first');
  assert.equal((await owner.call('DELETE', `/api/body/entries/${evening}`)).status, 200);
  assert.deepEqual(await fat(), [{ date: back(2), value: 21.4 }]);
  assert.ok(morning);
});

test('moving an entry to another day clears the day it left; deleting it gives the scale its day back', async () => {
  const id = (await owner.post('/api/body/entries', { metric: 'weight', value: 75, date: back(3) })).json.entry.id as string;
  assert.equal(await weightOn(owner, back(3)), 75);
  const moved = await owner.call('PATCH', `/api/body/entries/${id}`, { date: today, time: '08:00' });
  assert.equal(moved.status, 200);
  assert.equal(moved.json.entry.value, 75, 'the stored kilograms stay when only the date changes');
  assert.equal(await weightOn(owner, back(3)), 80);
  assert.equal(await weightOn(owner, today), 75);
  assert.equal((await owner.call('PATCH', `/api/body/entries/${id}`, { value: 170, unit: 'lb' })).json.entry.value, 77.111);
  assert.equal((await owner.call('PATCH', `/api/body/entries/${id}`, { date: addDays(today, 2) })).status, 400);
  assert.equal((await owner.call('DELETE', `/api/body/entries/${id}`)).status, 200);
  assert.equal(await weightOn(owner, today), 80);
  assert.equal((await owner.call('DELETE', `/api/body/entries/${id}`)).status, 404);
  assert.equal((await owner.call('PATCH', `/api/body/entries/${id}`, { value: 70 })).status, 404);
  // The manual rows went with them: only the pounds entry from earlier is left in `daily`.
  const rows = await db.query<{ date: string }>("SELECT date FROM daily WHERE user_id = $1 AND metric = 'weight' AND source = 'manual'", [OWNER_ID]);
  assert.deepEqual(rows.map((r) => r.date), [back(1)]);
});

test("each person reads and changes only their own entries", async () => {
  const inv = await owner.post('/api/admin/invites', { email: 'bob@example.com', role: 'user' });
  const token = (inv.json.url as string).split('/').at(-1)!;
  assert.equal((await bob.post('/api/auth/invite', { token, email: 'bob@example.com', name: 'Bob', password: 'bob password 123' })).status, 200);
  const bobToday = (await bob.get('/api/sleep/night')).json.today as string;

  assert.deepEqual((await bob.get('/api/body/entries')).json, { entries: [] });
  const mine = (await owner.get('/api/body/entries?metric=weight')).json.entries as { id: string }[];
  assert.equal(mine.length, 1);
  assert.equal((await bob.call('PATCH', `/api/body/entries/${mine[0].id}`, { value: 50 })).status, 404);
  assert.equal((await bob.call('DELETE', `/api/body/entries/${mine[0].id}`)).status, 404);

  const r = await bob.post('/api/body/entries', { metric: 'weight', value: 90, date: bobToday });
  assert.equal(r.status, 200, 'a second account never has demo data');
  assert.equal((await bob.get('/api/body/latest')).json.weight.value, 90);
  assert.equal(await weightOn(owner, back(1)), 69.989);
  assert.equal((await owner.get('/api/body/entries?metric=weight')).json.entries.length, 1);
  assert.equal((await owner.call('DELETE', `/api/body/entries/${r.json.entry.id}`)).status, 404);
});
