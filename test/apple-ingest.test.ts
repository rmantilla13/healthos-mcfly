import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { AddressInfo } from 'node:net';
import express from 'express';
import { APPLE_METRICS, lanIngestApp, ingestRouter } from '../server/apple/ingest.ts';
import { type Db, OWNER_ID, getUserSetting, upsertDaily, upsertEvents, upsertWorkouts } from '../server/db.ts';
import { NUTRIENTS } from '../server/nutrition.ts';
import { openStore } from '../server/store.ts';

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

const count = async (db: Db, table: string) => (await db.query<{ n: number }>(`SELECT COUNT(*)::int AS n FROM ${table}`))[0].n;
const daily = (db: Db, date: string, metric: string) =>
  db.query('SELECT source, value FROM daily WHERE date = $1 AND metric = $2 ORDER BY source', [date, metric]);

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
  const db = await openStore();
  // No server-wide token and nobody has created one: every token is wrong.
  await serve(appFor(db, undefined), async (url) => {
    assert.equal((await post(url, { daily: [] })).status, 401);
  });
  await serve(appFor(db, TOKEN), async (url) => {
    const row = { daily: [{ date: '2026-10-13', metric: 'steps', value: 1 }] };
    assert.equal((await post(url, row, null)).status, 401);
    assert.equal((await post(url, row, 'wrong-token')).status, 401);
    assert.equal(await count(db, 'daily'), 0);
    assert.equal((await post(url, row)).status, 200);
  });
});

test('ingest upserts rows as source apple and replaces a day on re-send', async () => {
  const db = await openStore();
  await upsertDaily(db, OWNER_ID, [{ date: '2026-10-13', metric: 'steps', source: 'whoop', value: 42 }]);
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
    assert.deepEqual(await res.json(), {
      ok: true,
      daily: 2,
      hourly: 0,
      workouts: 1,
      events: 1,
      deleted: 0,
      cycle: 0,
      sleepStages: 0,
      nutrition: 0,
      metrics: [...APPLE_METRICS].sort(),
      nutrients: [...NUTRIENTS],
      nutritionOn: false,
    });
    assert.deepEqual(await daily(db, '2026-10-13', 'steps'), [
      { source: 'apple', value: 8000 },
      { source: 'whoop', value: 42 },
    ]);

    // The same day again with more steps: one row, new value. Same workout id: no duplicate.
    await post(url, { daily: [{ date: '2026-10-13', metric: 'steps', value: 9100 }], workouts: [{ ...workout, energy_kcal: 310 }] });
    assert.deepEqual(await daily(db, '2026-10-13', 'steps'), [
      { source: 'apple', value: 9100 },
      { source: 'whoop', value: 42 },
    ]);
    assert.equal(await count(db, 'workouts'), 1);
    assert.equal((await db.query<{ energy_kcal: number }>('SELECT energy_kcal FROM workouts'))[0].energy_kcal, 310);

    // A different source now wins the night: its sleep event replaces the old one for that date.
    await post(url, { events: [sleep('s2')] });
    assert.deepEqual(
      await db.query("SELECT id, source FROM events WHERE kind = 'sleep'"),
      [{ id: 's2', source: 'apple' }],
    );
    const lastSync = JSON.parse((await getUserSetting(db, OWNER_ID, 'apple_last_sync'))!);
    assert.equal(lastSync.events, 1);
    assert.equal(lastSync.metrics, undefined);
  });
});

test("a day the phone sends without a wrist temperature loses one the old evening dating left there", async () => {
  const db = await openStore();
  await upsertDaily(db, OWNER_ID, [
    { date: '2026-10-12', metric: 'wrist_temp', source: 'apple', value: 34.7 }, // the night of the 12th to the 13th, dated the old way
    { date: '2026-10-11', metric: 'wrist_temp', source: 'apple', value: 34.6 }, // a day not sent: left alone
    { date: '2026-10-12', metric: 'skin_temp', source: 'whoop', value: 33.9 },
  ]);
  await serve(appFor(db, TOKEN), async (url) => {
    const res = await post(url, {
      daily: [
        { date: '2026-10-12', metric: 'steps', value: 4000 },
        { date: '2026-10-13', metric: 'wrist_temp', value: 34.7 },
      ],
    });
    assert.equal(res.status, 200);
    const rows = await db.query<{ date: string; metric: string; source: string }>("SELECT date, metric, source FROM daily WHERE metric IN ('wrist_temp', 'skin_temp') ORDER BY date, metric");
    assert.deepEqual(
      rows.map((r) => `${r.date} ${r.metric} ${r.source}`),
      ['2026-10-11 wrist_temp apple', '2026-10-12 skin_temp whoop', '2026-10-13 wrist_temp apple'],
    );

    // A phone that can't read wrist temperature at all sends none anywhere: it clears nothing an export import stored.
    await post(url, { daily: [{ date: '2026-10-11', metric: 'steps', value: 3000 }] });
    assert.equal((await db.query("SELECT 1 FROM daily WHERE metric = 'wrist_temp' AND date = '2026-10-11'")).length, 1);
  });
});

test('a workout or mindful session from the app replaces the same one from an export import', async () => {
  const db = await openStore();
  // export.zip writes every date with the offset in effect at export time, so a January run reads -05:00.
  await upsertWorkouts(db, OWNER_ID, [{ ...workout, id: '0123456789abcdef0123', start: '2026-01-10T18:00:00-05:00', end: '2026-01-10T18:30:00-05:00', date: '2026-01-10' }]);
  await upsertEvents(db, OWNER_ID, [{ ...sleep('x'), id: 'fedcba98765432100000', kind: 'mindful', start: '2026-01-10T12:30:00-05:00', end: '2026-01-10T12:40:00-05:00', date: '2026-01-10' }]);
  const run = (id: string, sport = 'Running') => ({ ...workout, id, sport, start: '2026-01-10T17:00:00-06:00', end: '2026-01-10T17:30:00-06:00', date: '2026-01-10' });
  await serve(appFor(db, TOKEN), async (url) => {
    await post(url, {
      // Same instant as the imported rows, in the time zone it was recorded in.
      workouts: [run('hk-a'), run('hk-b'), run('hk-c', 'Yoga')],
      events: [{ ...sleep('x'), id: 'hk-m', kind: 'mindful', start: '2026-01-10T11:30:00-06:00', end: '2026-01-10T11:40:00-06:00', date: '2026-01-10' }],
    });
  });
  // The imported copies are gone; two app workouts at the same moment (say Watch and Strava) both stay.
  assert.deepEqual((await db.query<{ id: string }>('SELECT id FROM workouts ORDER BY id')).map((r) => r.id), ['hk-a', 'hk-b', 'hk-c']);
  assert.deepEqual((await db.query<{ id: string }>('SELECT id FROM events')).map((r) => r.id), ['hk-m']);
});

test('workouts and mindful sessions deleted in Health are removed, but only ones the app sent', async () => {
  const db = await openStore();
  await serve(appFor(db, TOKEN), async (url) => {
    await post(url, { workouts: [{ ...workout, id: 'hk-a' }, { ...workout, id: 'hk-b', start: '2026-10-13T07:00:00-07:00' }] });
    const res = await post(url, { deleted: { workouts: ['hk-a', 'hk-missing'] } });
    assert.equal(((await res.json()) as { deleted: number }).deleted, 1);
    assert.equal((await post(url, { deleted: { workouts: ['0123456789abcdef0123'] } })).status, 400);
  });
  assert.deepEqual((await db.query<{ id: string }>('SELECT id FROM workouts')).map((r) => r.id), ['hk-b']);
});

test('ingest rejects malformed rows and writes nothing from that request', async () => {
  const db = await openStore();
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
  assert.equal(await count(db, 'daily'), 0);
});

// What installed apps sent before blood pressure, glucose, mobility, daylight, stand hours, caffeine and water.
const LEGACY = ['steps', 'active_energy', 'exercise_min', 'distance_km', 'hr_avg', 'hr_min', 'hr_max', 'resting_hr', 'hrv_sdnn', 'hrv_rmssd_watch', 'spo2', 'resp_rate', 'wrist_temp', 'body_temp', 'weight', 'body_fat', 'lean_mass', 'vo2max', 'sleep_hours', 'sleep_in_bed', 'sleep_deep', 'sleep_rem', 'sleep_light', 'sleep_awake'];
const ADDED = ['blood_pressure_systolic', 'blood_pressure_diastolic', 'glucose', 'walking_speed', 'walking_steadiness', 'walking_asymmetry', 'daylight_min', 'flights', 'stand_hours', 'breathing_disturbances', 'caffeine_mg', 'water_ml'];

test('ingest takes the newer daily metrics and lists every metric it accepts', async () => {
  const db = await openStore();
  await serve(appFor(db, TOKEN), async (url) => {
    const res = await post(url, { daily: ADDED.map((metric, i) => ({ date: '2026-10-13', metric, value: i + 1 })) });
    assert.equal(res.status, 200);
    const body = (await res.json()) as { daily: number; metrics: string[] };
    assert.equal(body.daily, ADDED.length);
    assert.deepEqual(body.metrics, [...LEGACY, ...ADDED].sort());

    // The app probes with an empty push before sending; the list comes back with it.
    const probe = (await (await post(url, {})).json()) as { daily: number; metrics: string[] };
    assert.equal(probe.daily, 0);
    assert.deepEqual(probe.metrics, body.metrics);

    const unknown = await post(url, { daily: [{ date: '2026-10-13', metric: 'stand_minutes', value: 1 }] });
    assert.equal(unknown.status, 400);
    assert.match(((await unknown.json()) as { error: string }).error, /daily\[0\]\.metric: unknown metric "stand_minutes"/);
  });
  assert.equal(await count(db, 'daily'), ADDED.length);
  assert.deepEqual(await daily(db, '2026-10-13', 'water_ml'), [{ source: 'apple', value: 12 }]);
  assert.deepEqual(await daily(db, '2026-10-13', 'stand_hours'), [{ source: 'apple', value: 9 }]);
});

test('ingest takes a large first-sync chunk', async () => {
  const db = await openStore();
  const rows = Array.from({ length: 5000 }, (_, i) => ({
    date: new Date(Date.UTC(2015, 0, 1) + i * 86_400_000).toISOString().slice(0, 10),
    metric: 'steps',
    value: 1000 + i,
  }));
  await serve(appFor(db, TOKEN), async (url) => {
    const res = await post(url, { daily: rows });
    assert.equal(res.status, 200);
  });
  assert.equal(await count(db, 'daily'), 5000);
});

test('the LAN listener serves ingest and nothing else', async () => {
  const db = await openStore();
  await serve(lanIngestApp(db, TOKEN), async (url) => {
    assert.equal((await post(url, { daily: [{ date: '2026-10-13', metric: 'steps', value: 5 }] })).status, 200);
    for (const path of ['/api/summary', '/api/status', '/']) {
      assert.equal((await fetch(url + path, { headers: { Authorization: `Bearer ${TOKEN}` } })).status, 404);
    }
  });
});
