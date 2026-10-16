import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { AddressInfo } from 'node:net';
import express from 'express';
import { lanIngestApp, ingestRouter } from '../server/apple/ingest.ts';
import { type Db, getSetting, openDb, upsertDaily } from '../server/db.ts';

const TOKEN = 'test-token-0123456789abcdef';

async function serve(app: express.Express, fn: (url: string) => Promise<void>) {
  const server = app.listen(0, '127.0.0.1');
  await new Promise((resolve) => server.once('listening', resolve));
  try {
    await fn(`http://127.0.0.1:${(server.address() as AddressInfo).port}`);
  } finally {
    server.close();
  }
}

function appFor(db: Db, token: string | undefined) {
  const app = express();
  app.use('/api', ingestRouter(db, token));
  return app;
}

function post(url: string, body: unknown, token: string | null = TOKEN) {
  return fetch(`${url}/api/apple/ingest`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) },
    body: typeof body === 'string' ? body : JSON.stringify(body),
  });
}

const count = (db: Db, table: string) => (db.prepare(`SELECT COUNT(*) n FROM ${table}`).get() as { n: number }).n;
const daily = (db: Db, date: string, metric: string) =>
  db.prepare('SELECT source, value FROM daily WHERE date = ? AND metric = ? ORDER BY source').all(date, metric).map((r) => ({ ...r }));

const workout = {
  id: 'w1',
  source: 'apple',
  sport: 'Running',
  start: '2026-10-13T18:00:00-07:00',
  end: '2026-10-13T18:30:00-07:00',
  date: '2026-10-13',
  duration_min: 30,
  energy_kcal: 300,
  distance_m: 5000,
  avg_hr: 150,
  max_hr: 172,
  strain: null,
};
const sleep = (id: string) => ({
  id,
  source: 'apple',
  kind: 'sleep',
  title: 'Sleep',
  start: '2026-10-13T23:00:00-07:00',
  end: '2026-10-14T06:45:00-07:00',
  date: '2026-10-14',
});

test('ingest needs a configured token and the right bearer', async () => {
  const db = openDb(':memory:');
  await serve(appFor(db, undefined), async (url) => {
    assert.equal((await post(url, { daily: [] })).status, 503);
  });
  await serve(appFor(db, TOKEN), async (url) => {
    const row = { daily: [{ date: '2026-10-13', metric: 'steps', value: 1 }] };
    assert.equal((await post(url, row, null)).status, 401);
    assert.equal((await post(url, row, 'wrong-token')).status, 401);
    assert.equal(count(db, 'daily'), 0);
    assert.equal((await post(url, row)).status, 200);
  });
});

test('ingest upserts rows as source apple and replaces a day on re-send', async () => {
  const db = openDb(':memory:');
  upsertDaily(db, [{ date: '2026-10-13', metric: 'steps', source: 'whoop', value: 42 }]);
  await serve(appFor(db, TOKEN), async (url) => {
    const res = await post(url, {
      daily: [
        // The client's source is ignored: everything pushed by the app is Apple Health.
        { date: '2026-10-13', metric: 'steps', source: 'whoop', value: 8000 },
        { date: '2026-10-14', metric: 'sleep_hours', value: 7.5 },
      ],
      workouts: [workout],
      events: [sleep('s1')],
    });
    assert.equal(res.status, 200);
    assert.deepEqual(await res.json(), { ok: true, daily: 2, workouts: 1, events: 1 });
    assert.deepEqual(daily(db, '2026-10-13', 'steps'), [
      { source: 'apple', value: 8000 },
      { source: 'whoop', value: 42 },
    ]);

    // The same day again with more steps: one row, new value. Same workout id: no duplicate.
    await post(url, { daily: [{ date: '2026-10-13', metric: 'steps', value: 9100 }], workouts: [{ ...workout, energy_kcal: 310 }] });
    assert.deepEqual(daily(db, '2026-10-13', 'steps'), [
      { source: 'apple', value: 9100 },
      { source: 'whoop', value: 42 },
    ]);
    assert.equal(count(db, 'workouts'), 1);
    assert.equal((db.prepare('SELECT energy_kcal FROM workouts').get() as { energy_kcal: number }).energy_kcal, 310);

    // A different source now wins the night: its sleep event replaces the old one for that date.
    await post(url, { events: [sleep('s2')] });
    assert.deepEqual(
      db.prepare("SELECT id, source FROM events WHERE kind = 'sleep'").all().map((r) => ({ ...r })),
      [{ id: 's2', source: 'apple' }],
    );
    assert.equal(JSON.parse(getSetting(db, 'apple_last_sync')!).events, 1);
  });
});

test('ingest rejects malformed rows and writes nothing from that request', async () => {
  const db = openDb(':memory:');
  const good = { date: '2026-10-13', metric: 'steps', value: 100 };
  const bad: [unknown, RegExp][] = [
    ['not json', /JSON|Unexpected/i],
    [{ daily: 'nope' }, /daily: expected an array/],
    [{ daily: [good, { ...good, date: '2026-13-01' }] }, /daily\[1\]\.date/],
    [{ daily: [{ ...good, date: '2026-02-30' }] }, /daily\[0\]\.date/],
    [{ daily: [{ ...good, metric: 'whoop_recovery' }] }, /unknown metric/],
    [{ daily: [{ ...good, value: '100' }] }, /daily\[0\]\.value: expected a finite number/],
    [{ workouts: [{ ...workout, start: '2026-10-13 18:00:00' }] }, /workouts\[0\]\.start/],
    [{ workouts: [{ ...workout, duration_min: -1 }] }, /duration_min/],
    [{ events: [{ ...sleep('s1'), kind: 'workout' }] }, /events\[0\]\.kind/],
  ];
  await serve(appFor(db, TOKEN), async (url) => {
    for (const [body, message] of bad) {
      const res = await post(url, body);
      assert.equal(res.status, 400, JSON.stringify(body));
      assert.match(((await res.json()) as { error: string }).error, message);
    }
  });
  assert.equal(count(db, 'daily'), 0);
});

test('ingest takes a large first-sync chunk', async () => {
  const db = openDb(':memory:');
  const rows = Array.from({ length: 5000 }, (_, i) => ({
    date: new Date(Date.UTC(2015, 0, 1) + i * 86_400_000).toISOString().slice(0, 10),
    metric: 'steps',
    value: 1000 + i,
  }));
  await serve(appFor(db, TOKEN), async (url) => {
    const res = await post(url, { daily: rows });
    assert.equal(res.status, 200);
  });
  assert.equal(count(db, 'daily'), 5000);
});

test('the LAN listener serves ingest and nothing else', async () => {
  const db = openDb(':memory:');
  await serve(lanIngestApp(db, TOKEN), async (url) => {
    assert.equal((await post(url, { daily: [{ date: '2026-10-13', metric: 'steps', value: 5 }] })).status, 200);
    for (const path of ['/api/summary', '/api/status', '/']) {
      assert.equal((await fetch(url + path, { headers: { Authorization: `Bearer ${TOKEN}` } })).status, 404);
    }
  });
});
