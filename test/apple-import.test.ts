import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { Readable } from 'node:stream';
import { type Db } from '../server/db.ts';
import { openStore } from '../server/store.ts';
import { importAppleHealth, parseStream, sportName } from '../server/apple/import.ts';

const FIXTURE = path.join(import.meta.dirname, 'fixtures', 'export.xml');

async function value(db: Db, date: string, metric: string) {
  const [row] = await db.query<{ value: number }>("SELECT value FROM daily WHERE date = $1 AND metric = $2 AND source = 'apple'", [date, metric]);
  return row?.value;
}

test('imports export.xml into per-day values', async () => {
  const db = await openStore();
  const result = await importAppleHealth(db, FIXTURE);
  assert.equal(result.workouts, 2);

  // iPhone 5000 vs Watch 5500 for the same walks: keep the larger source, not 10,500.
  assert.equal(await value(db, '2026-10-13', 'steps'), 5500);
  assert.equal(await value(db, '2026-10-14', 'steps'), undefined);

  assert.equal(await value(db, '2026-10-13', 'hr_avg'), 75);
  assert.equal(await value(db, '2026-10-13', 'hr_min'), 60);
  assert.equal(await value(db, '2026-10-13', 'hr_max'), 90);
  assert.equal(await value(db, '2026-10-13', 'resting_hr'), 54);
  assert.equal(await value(db, '2026-10-13', 'hrv_sdnn'), 60);
  assert.equal(await value(db, '2026-10-13', 'spo2'), 97);
  assert.equal(Math.round((await value(db, '2026-10-13', 'active_energy'))!), 100);
  assert.equal(Math.round((await value(db, '2026-10-13', 'weight'))! * 10) / 10, 82.6); // last reading of the day (182 lb)
  assert.equal(await value(db, '2026-10-13', 'wrist_temp'), 36);
});

test('assigns a night that crosses midnight to the wake day and picks one source', async () => {
  const db = await openStore();
  await importAppleHealth(db, FIXTURE);
  // Watch: core 2h + deep 1.5h + REM 1.5h + core 2.5h = 7.5h asleep; awake 15m is not sleep.
  assert.equal(await value(db, '2026-10-14', 'sleep_hours'), 7.5);
  assert.equal(await value(db, '2026-10-14', 'sleep_deep'), 1.5);
  assert.equal(await value(db, '2026-10-14', 'sleep_rem'), 1.5);
  assert.equal(await value(db, '2026-10-14', 'sleep_light'), 4.5);
  assert.equal(await value(db, '2026-10-14', 'sleep_awake'), 0.25);
  assert.equal(await value(db, '2026-10-13', 'sleep_hours'), undefined);

  const sleep = await db.query(`SELECT start, "end" FROM events WHERE kind = 'sleep'`);
  assert.deepEqual(sleep, [{ start: '2026-10-13T23:00:00-07:00', end: '2026-10-14T06:45:00-07:00' }]);
});

test('reads workouts in both the old and new export formats', async () => {
  const db = await openStore();
  await importAppleHealth(db, FIXTURE);
  const rows = await db.query<any>('SELECT sport, date, duration_min, energy_kcal, distance_m, avg_hr FROM workouts ORDER BY start');
  assert.equal(rows[0].sport, 'Running');
  assert.equal(rows[0].duration_min, 30);
  assert.equal(Math.round(rows[0].distance_m), 4989);
  assert.equal(rows[1].sport, 'Traditional Strength Training');
  assert.equal(rows[1].energy_kcal, 310);
  assert.equal(rows[1].avg_hr, 128);
  assert.equal(rows[1].date, '2026-10-14');
});

test('re-importing replaces the earlier import instead of doubling it', async () => {
  const db = await openStore();
  await importAppleHealth(db, FIXTURE);
  await importAppleHealth(db, FIXTURE);
  assert.equal(await value(db, '2026-10-13', 'steps'), 5500);
  assert.equal((await db.query<{ n: number }>('SELECT COUNT(*)::int AS n FROM workouts'))[0].n, 2);
});

test('reads export.xml out of the export.zip, ignoring export_cda.xml', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'healthos-'));
  const inner = path.join(dir, 'apple_health_export');
  fs.mkdirSync(inner);
  fs.copyFileSync(FIXTURE, path.join(inner, 'export.xml'));
  fs.writeFileSync(path.join(inner, 'export_cda.xml'), '<ClinicalDocument/>');
  execFileSync('zip', ['-qr', 'export.zip', 'apple_health_export'], { cwd: dir });

  const db = await openStore();
  const result = await importAppleHealth(db, path.join(dir, 'export.zip'));
  assert.equal(result.workouts, 2);
  assert.equal(await value(db, '2026-10-13', 'steps'), 5500);
  fs.rmSync(dir, { recursive: true });
});

test('formats workout type names', () => {
  assert.equal(sportName('HKWorkoutActivityTypeHighIntensityIntervalTraining'), 'High Intensity Interval Training');
  assert.equal(sportName('HKWorkoutActivityTypeYoga'), 'Yoga');
});

// ---- overlapping and duplicated sleep records (as written by SleepWatch, Oura, Clock) ----

function sleepXml(records: [source: string, stage: string, start: string, end: string][]) {
  const rows = records.map(
    ([src, stage, start, end]) =>
      `<Record type="HKCategoryTypeIdentifierSleepAnalysis" sourceName="${src}" startDate="2026-10-${start} -0700" endDate="2026-10-${end} -0700" value="HKCategoryValueSleepAnalysis${stage}"/>`,
  );
  return `<?xml version="1.0"?><HealthData>${rows.join('')}</HealthData>`;
}

async function nightValues(xml: string) {
  const agg = await parseStream(Readable.from([Buffer.from(xml)]));
  const { daily } = agg.finish();
  return Object.fromEntries(daily.filter((d) => d.metric.startsWith('sleep')).map((d) => [d.metric, Math.round(d.value * 100) / 100]));
}

test('the same night written many times counts once', async () => {
  const dup: [string, string, string, string] = ['SleepWatch', 'AsleepUnspecified', '14 23:00:00', '15 07:00:00'];
  const v = await nightValues(sleepXml(Array(16).fill(dup)));
  assert.equal(v.sleep_hours, 8);
});

test('overlapping stages from one source are merged, deeper stage wins', async () => {
  const v = await nightValues(
    sleepXml([
      ['Watch', 'AsleepCore', '14 23:30:00', '15 03:30:00'],
      ['Watch', 'AsleepDeep', '15 02:30:00', '15 04:00:00'],
      ['Watch', 'Awake', '15 03:00:00', '15 03:15:00'],
      ['Watch', 'AsleepREM', '15 04:00:00', '15 05:00:00'],
      ['Watch', 'AsleepUnspecified', '14 23:30:00', '15 05:00:00'],
      ['Watch', 'Awake', '15 05:00:00', '15 05:20:00'],
    ]),
  );
  assert.equal(v.sleep_hours, 5.5);
  assert.equal(v.sleep_light, 3);
  assert.equal(v.sleep_deep, 1.5);
  assert.equal(v.sleep_rem, 1);
  assert.equal(Math.round(v.sleep_awake * 60), 20);
});

test('overlapping in-bed records count as their union', async () => {
  const v = await nightValues(
    sleepXml([
      ['iPhone', 'InBed', '14 23:00:00', '15 07:00:00'],
      ['iPhone', 'InBed', '14 23:00:00', '15 07:00:00'],
      ['iPhone', 'InBed', '15 00:00:00', '15 06:00:00'],
    ]),
  );
  assert.equal(v.sleep_hours, 8);
  assert.equal(v.sleep_in_bed, 8);
});

test('a record longer than any real night is ignored', async () => {
  const v = await nightValues(
    sleepXml([
      ['BuggyApp', 'AsleepUnspecified', '12 23:00:00', '15 07:00:00'],
      ['Watch', 'AsleepCore', '14 23:00:00', '15 06:00:00'],
    ]),
  );
  assert.equal(v.sleep_hours, 7);
});
