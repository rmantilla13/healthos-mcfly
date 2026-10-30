import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { Readable } from 'node:stream';
import { type Db, OWNER_ID } from '../server/db.ts';
import { openStore } from '../server/store.ts';
import { importAppleHealth, parseStream, sportName } from '../server/apple/import.ts';

const FIXTURE = path.join(import.meta.dirname, 'fixtures', 'export.xml');

async function value(db: Db, date: string, metric: string) {
  const [row] = await db.query<{ value: number }>("SELECT value FROM daily WHERE date = $1 AND metric = $2 AND source = 'apple'", [date, metric]);
  return row?.value;
}

test('imports export.xml into per-day values', async () => {
  const db = await openStore();
  const result = await importAppleHealth({ db, userId: OWNER_ID }, FIXTURE);
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
  await importAppleHealth({ db, userId: OWNER_ID }, FIXTURE);
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

test("the Watch's sleeping wrist temperature counts toward the morning the night ends", async () => {
  const night = (start: string, end: string) =>
    `<Record type="HKQuantityTypeIdentifierAppleSleepingWristTemperature" sourceName="Watch" unit="degC" startDate="${start} -0500" endDate="${end} -0500" value="34.8"/>`;
  const xml = `<?xml version="1.0"?><HealthData>${night('2026-10-12 23:30:00', '2026-10-13 06:30:00')}${night('2026-10-14 00:40:00', '2026-10-14 07:10:00')}</HealthData>`;
  const rows = (await parseStream(Readable.from([Buffer.from(xml)]))).finish().daily.filter((r) => r.metric === 'wrist_temp');
  // Asleep before midnight or after it, each night belongs to the day it ends, like sleep and WHOOP's skin temperature.
  assert.deepEqual(
    rows.map((r) => r.date),
    ['2026-10-13', '2026-10-14'],
  );
});

test('reads workouts in both the old and new export formats', async () => {
  const db = await openStore();
  await importAppleHealth({ db, userId: OWNER_ID }, FIXTURE);
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
  await importAppleHealth({ db, userId: OWNER_ID }, FIXTURE);
  await importAppleHealth({ db, userId: OWNER_ID }, FIXTURE);
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
  const result = await importAppleHealth({ db, userId: OWNER_ID }, path.join(dir, 'export.zip'));
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

const sleepEvents = async (xml: string) =>
  (await parseStream(Readable.from([Buffer.from(xml)]))).finish().events.filter((e) => e.kind === 'sleep').map(({ start, end, date }) => ({ start, end, date }));

test("a nap the same app wrote for the wake day adds to the day's sleep but not to the night's span", async () => {
  const xml = sleepXml([
    ['Watch', 'AsleepCore', '14 22:30:00', '15 06:00:00'],
    ['Watch', 'AsleepCore', '15 13:00:00', '15 14:00:00'],
  ]);
  // Naps count toward the day's total, as WHOOP's do.
  assert.equal((await nightValues(xml)).sleep_hours, 8.5);
  // The night still ends at 06:00, so bed and wake times aren't stretched to the end of the nap.
  assert.deepEqual(await sleepEvents(xml), [{ start: '2026-10-14T22:30:00-07:00', end: '2026-10-15T06:00:00-07:00', date: '2026-10-15' }]);
});

test('a long wake recorded in the night, or a short gap with nothing recorded, is still one night', async () => {
  const xml = sleepXml([
    ['Watch', 'AsleepCore', '14 22:00:00', '15 01:00:00'],
    ['Watch', 'Awake', '15 01:00:00', '15 03:30:00'],
    // An hour with nothing recorded (the watch on its charger), then back to sleep.
    ['Watch', 'AsleepCore', '15 04:30:00', '15 07:00:00'],
  ]);
  assert.equal((await nightValues(xml)).sleep_hours, 5.5);
  assert.deepEqual(await sleepEvents(xml), [{ start: '2026-10-14T22:00:00-07:00', end: '2026-10-15T07:00:00-07:00', date: '2026-10-15' }]);
});

test("WHOOP's own copies in Apple Health are skipped (WHOOP is read from its API)", async () => {
  const xml = `<?xml version="1.0"?><HealthData>
    <Record type="HKQuantityTypeIdentifierRestingHeartRate" sourceName="WHOOP" unit="count/min" startDate="2026-10-13 00:00:00 -0700" endDate="2026-10-13 00:00:00 -0700" value="49"/>
    <Record type="HKQuantityTypeIdentifierRestingHeartRate" sourceName="Ricky’s Apple Watch" unit="count/min" startDate="2026-10-13 00:00:00 -0700" endDate="2026-10-13 23:59:00 -0700" value="57"/>
    <Record type="HKCategoryTypeIdentifierSleepAnalysis" sourceName="WHOOP" startDate="2026-10-12 22:00:00 -0700" endDate="2026-10-13 07:00:00 -0700" value="HKCategoryValueSleepAnalysisAsleepUnspecified"/>
    <Record type="HKCategoryTypeIdentifierSleepAnalysis" sourceName="Ricky’s Apple Watch" startDate="2026-10-12 23:00:00 -0700" endDate="2026-10-13 06:00:00 -0700" value="HKCategoryValueSleepAnalysisAsleepCore"/>
    <Record type="HKQuantityTypeIdentifierHeartRateVariabilityRMSSD" sourceName="Ricky’s Apple Watch" unit="ms" startDate="2026-10-13 03:00:00 -0700" endDate="2026-10-13 03:01:00 -0700" value="42"/>
    <Workout workoutActivityType="HKWorkoutActivityTypeWalking" duration="30" durationUnit="min" sourceName="WHOOP" startDate="2026-10-13 12:00:00 -0700" endDate="2026-10-13 12:30:00 -0700">
      <WorkoutStatistics type="HKQuantityTypeIdentifierActiveEnergyBurned" startDate="2026-10-13 12:00:00 -0700" endDate="2026-10-13 12:30:00 -0700" sum="120" unit="kcal"/>
    </Workout>
  </HealthData>`;
  const agg = await parseStream(Readable.from([Buffer.from(xml)]));
  const { daily, workouts } = agg.finish();
  const v = (m: string) => daily.find((d) => d.metric === m)?.value;
  assert.equal(v('resting_hr'), 57, 'only the Watch reading counts');
  assert.equal(v('sleep_hours'), 7, "the Watch's night, not WHOOP's 9h copy");
  assert.equal(v('hrv_rmssd_watch'), 42);
  assert.equal(workouts.length, 0);
  assert.equal(agg.skipped, 3);
});

// ---- blood pressure, glucose, mobility, daylight, stand hours, caffeine and water ----

const METRICS_FIXTURE = path.join(import.meta.dirname, 'fixtures', 'export-metrics.xml');
const round = (v: number | undefined, places = 2) => (v === undefined ? undefined : Math.round(v * 10 ** places) / 10 ** places);

test('imports the newer Health types in the units healthOS stores', async () => {
  const db = await openStore();
  const result = await importAppleHealth({ db, userId: OWNER_ID }, METRICS_FIXTURE);
  assert.equal(result.skipped, 1, "WHOOP's water");
  const v = async (metric: string, date = '2026-10-13') => round(await value(db, date, metric));
  assert.equal(await v('glucose'), 100);
  assert.equal(await v('glucose', '2026-10-14'), 99.09, '5.5 mmol/L');
  assert.equal(await v('walking_speed'), 4.71, '4.8 km/h, 3 mph and 1.25 m/s');
  assert.equal(await v('walking_steadiness'), 90, 'the later reading, as a percent');
  assert.equal(await v('walking_asymmetry'), 3);
  assert.equal(await v('daylight_min'), 35, 'the Watch with the most, not both added');
  assert.equal(await v('flights'), 7);
  assert.equal(await v('breathing_disturbances'), 4);
  assert.equal(await v('stand_hours'), 4);
  assert.equal(await v('caffeine_mg'), 175, '95 mg in one app and 0.08 g in another, the meal counted once');
  assert.equal(await v('water_ml'), 986.59, '500 mL + 8 US fl oz + 0.25 L, without WHOOP');
});

test('a blood pressure reading inside a correlation counts once', async () => {
  const db = await openStore();
  await importAppleHealth({ db, userId: OWNER_ID }, METRICS_FIXTURE);
  // 120/78 is in the export twice (top level and in its correlation), 132/86 once. Twice would give 124/80.67.
  assert.equal(await value(db, '2026-10-13', 'blood_pressure_systolic'), 126);
  assert.equal(await value(db, '2026-10-13', 'blood_pressure_diastolic'), 82);
});

async function dailyOf(records: string[]) {
  const agg = await parseStream(Readable.from([Buffer.from(`<?xml version="1.0"?><HealthData>${records.join('')}</HealthData>`)]));
  return Object.fromEntries(agg.finish().daily.map((d) => [d.metric, round(d.value)]));
}

const sample = (type: string, source: string, time: string, value: string | number, unit = '') =>
  `<Record type="HKQuantityTypeIdentifier${type}" sourceName="${source}" unit="${unit}" startDate="2026-10-13 ${time} -0700" endDate="2026-10-13 ${time} -0700" value="${value}"/>`;

test('caffeine and water add up across apps; flights and daylight keep one device', async () => {
  const v = await dailyOf([
    sample('DietaryCaffeine', 'Caffeine Tracker', '08:00:00', 100, 'mg'),
    sample('DietaryCaffeine', 'Coffee App', '14:00:00', 150, 'mg'),
    sample('DietaryWater', 'WaterMinder', '09:00:00', 1, 'L'),
    sample('DietaryWater', 'Health', '12:00:00', 300, 'mL'),
    sample('FlightsClimbed', 'iPhone', '08:00:00', 6, 'count'),
    sample('FlightsClimbed', 'Watch', '08:00:00', 5, 'count'),
    sample('TimeInDaylight', 'Watch', '10:00:00', 30, 'min'),
    sample('TimeInDaylight', 'Old Watch', '10:00:00', 25, 'min'),
  ]);
  assert.equal(v.caffeine_mg, 250);
  assert.equal(v.water_ml, 1300);
  assert.equal(v.flights, 6);
  assert.equal(v.daylight_min, 30);
});

test('resting energy keeps one device like active energy; heart rate recovery averages the day', async () => {
  const v = await dailyOf([
    sample('BasalEnergyBurned', 'Watch', '08:00:00', 900, 'kcal'),
    sample('BasalEnergyBurned', 'Watch', '20:00:00', 3347.2, 'kJ'),
    sample('BasalEnergyBurned', 'iPhone', '08:00:00', 1500, 'kcal'),
    sample('HeartRateRecoveryOneMinute', 'Watch', '07:30:00', 24, 'count/min'),
    sample('HeartRateRecoveryOneMinute', 'Watch', '18:30:00', 30, 'count/min'),
  ]);
  assert.equal(v.resting_energy, 1700, '900 kcal and 800 kcal (3347.2 kJ) from the Watch, not the iPhone added on');
  assert.equal(v.hr_recovery, 27);
});

test("each workout gets the effort score its time overlaps, the person's own rating before the Watch's estimate", async () => {
  const run = (start: string, end: string, type = 'Running') =>
    `<Workout workoutActivityType="HKWorkoutActivityType${type}" duration="30" durationUnit="min" sourceName="Watch" startDate="2026-10-13 ${start} -0700" endDate="2026-10-13 ${end} -0700"/>`;
  const effort = (kind: 'WorkoutEffortScore' | 'EstimatedWorkoutEffortScore', start: string, end: string, value: number) =>
    `<Record type="HKQuantityTypeIdentifier${kind}" sourceName="Watch" unit="appleEffortScore" startDate="2026-10-13 ${start} -0700" endDate="2026-10-13 ${end} -0700" value="${value}"/>`;
  const xml = `<?xml version="1.0"?><HealthData>
    ${effort('EstimatedWorkoutEffortScore', '07:00:00', '07:30:00', 5.4)}
    ${effort('WorkoutEffortScore', '07:00:00', '07:30:00', 8)}
    ${run('07:00:00', '07:30:00')}
    ${run('12:00:00', '12:30:00', 'Yoga')}
    ${effort('EstimatedWorkoutEffortScore', '12:30:00', '12:30:00', 3)}
    ${run('18:00:00', '18:30:00', 'Cycling')}
    ${effort('WorkoutEffortScore', '20:00:00', '20:10:00', 6)}
    ${effort('WorkoutEffortScore', '07:00:00', '07:30:00', 11)}
  </HealthData>`;
  const { workouts } = (await parseStream(Readable.from([Buffer.from(xml)]))).finish();
  const by = Object.fromEntries(workouts.map((w) => [w.sport, w.effort]));
  assert.deepEqual(by, { Running: 8, Yoga: 3, Cycling: null }, 'the rating beats the estimate; a score at the end still counts; one out of range or matching nothing is dropped');
});

test('stand hours count each local hour once across watches, and idle hours not at all', async () => {
  const hour = (source: string, h: number, value: string) =>
    `<Record type="HKCategoryTypeIdentifierAppleStandHour" sourceName="${source}" startDate="2026-10-13 ${String(h).padStart(2, '0')}:00:00 -0700" endDate="2026-10-13 ${String(h + 1).padStart(2, '0')}:00:00 -0700" value="${value}"/>`;
  const v = await dailyOf([
    hour('Watch', 9, 'HKCategoryValueAppleStandHourStood'),
    hour('Old Watch', 9, 'HKCategoryValueAppleStandHourStood'),
    hour('Watch', 10, 'HKCategoryValueAppleStandHourIdle'),
    hour('Watch', 11, '0'),
  ]);
  assert.equal(v.stand_hours, 2);
});

test('a correlated sample counts once whichever copy comes first; separate identical samples both count', async () => {
  const sys = (value: number) => sample('BloodPressureSystolic', 'Omron', '08:00:00', value, 'mmHg');
  const v = await dailyOf([
    `<Correlation type="HKCorrelationTypeIdentifierBloodPressure" sourceName="Omron" startDate="2026-10-13 08:00:00 -0700" endDate="2026-10-13 08:00:00 -0700">`,
    `<MetadataEntry key="HKWasUserEntered" value="0"/>${sys(110)}</Correlation>`,
    sys(110),
    sample('BloodPressureSystolic', 'Health', '20:00:00', 140, 'mmHg'),
    // The same glass logged twice at the same moment, neither in a correlation.
    sample('DietaryWater', 'WaterMinder', '09:00:00', 250, 'mL'),
    sample('DietaryWater', 'WaterMinder', '09:00:00', 250, 'mL'),
  ]);
  assert.equal(v.blood_pressure_systolic, 125);
  assert.equal(v.water_ml, 500);
});

test("WHOOP's copies of the newer types are skipped too", async () => {
  const v = await dailyOf([
    sample('FlightsClimbed', 'WHOOP', '08:00:00', 9, 'count'),
    sample('FlightsClimbed', 'iPhone', '08:00:00', 2, 'count'),
    sample('DietaryCaffeine', 'WHOOP', '08:00:00', 200, 'mg'),
  ]);
  assert.equal(v.flights, 2);
  assert.equal(v.caffeine_mg, undefined);
});

// ---- times in the person's own zone ----

test("with the person's zone, sleep, workouts and mindful sessions keep the local time they happened at", async () => {
  // Exported in October (CDT, -0500), so a February evening (CST, -0600) prints an hour late: a night slept
  // 23:30 to 07:00, a run ending 20:30, a late session from 23:30 past midnight, and breathing at 23:15.
  const xml = `<?xml version="1.0"?><HealthData>
    <Record type="HKCategoryTypeIdentifierSleepAnalysis" sourceName="Watch" startDate="2026-02-11 00:30:00 -0500" endDate="2026-02-11 08:00:00 -0500" value="HKCategoryValueSleepAnalysisAsleepCore"/>
    <Record type="HKCategoryTypeIdentifierSleepAnalysis" sourceName="Watch" startDate="2026-10-14 23:30:00 -0500" endDate="2026-10-15 07:00:00 -0500" value="HKCategoryValueSleepAnalysisAsleepCore"/>
    <Workout workoutActivityType="HKWorkoutActivityTypeRunning" duration="45" durationUnit="min" sourceName="Watch" startDate="2026-02-11 20:45:00 -0500" endDate="2026-02-11 21:30:00 -0500"/>
    <Workout workoutActivityType="HKWorkoutActivityTypeYoga" duration="45" durationUnit="min" sourceName="Watch" startDate="2026-02-12 00:30:00 -0500" endDate="2026-02-12 01:15:00 -0500"/>
    <Record type="HKCategoryTypeIdentifierMindfulSession" sourceName="Breathe" startDate="2026-02-11 00:15:00 -0500" endDate="2026-02-11 00:20:00 -0500" value="HKCategoryValueNotApplicable"/>
  </HealthData>`;
  const run = async (timeZone?: string) => {
    const { events, workouts, daily } = (await parseStream(Readable.from([Buffer.from(xml)]), undefined, { timeZone })).finish();
    const pick = (x: { start: string; end: string; date: string }) => ({ start: x.start, end: x.end, date: x.date });
    return {
      sleep: events.filter((e) => e.kind === 'sleep').map(pick).sort((a, b) => a.date.localeCompare(b.date)),
      mindful: events.filter((e) => e.kind === 'mindful').map(pick),
      workouts: workouts.map(pick),
      sleepDays: daily.filter((d) => d.metric === 'sleep_hours').map((d) => d.date).sort(),
      ids: [...events, ...workouts].map((x) => x.id).sort(),
    };
  };

  const zoned = await run('America/Chicago');
  assert.deepEqual(zoned.sleep, [
    { start: '2026-02-10T23:30:00-06:00', end: '2026-02-11T07:00:00-06:00', date: '2026-02-11' },
    // October already had the export's offset, so it's as written.
    { start: '2026-10-14T23:30:00-05:00', end: '2026-10-15T07:00:00-05:00', date: '2026-10-15' },
  ]);
  assert.deepEqual(zoned.workouts, [
    { start: '2026-02-11T19:45:00-06:00', end: '2026-02-11T20:30:00-06:00', date: '2026-02-11' },
    // Started at 23:30 on the 11th, so it's the 11th's, and it ended past midnight (a late workout).
    { start: '2026-02-11T23:30:00-06:00', end: '2026-02-12T00:15:00-06:00', date: '2026-02-11' },
  ]);
  assert.deepEqual(zoned.mindful, [{ start: '2026-02-10T23:15:00-06:00', end: '2026-02-10T23:20:00-06:00', date: '2026-02-10' }]);
  assert.deepEqual(zoned.sleepDays, ['2026-02-11', '2026-10-15']);

  // Without a zone, the export's own offsets, as before.
  const plain = await run();
  assert.deepEqual(plain.sleep[0], { start: '2026-02-11T00:30:00-05:00', end: '2026-02-11T08:00:00-05:00', date: '2026-02-11' });
  assert.deepEqual(plain.workouts[1], { start: '2026-02-12T00:30:00-05:00', end: '2026-02-12T01:15:00-05:00', date: '2026-02-12' });
  // The same instants and ids either way, so an iPhone push of the same records still finds and replaces them.
  for (const k of ['sleep', 'workouts', 'mindful'] as const) {
    assert.deepEqual(
      zoned[k].map((x) => [Date.parse(x.start), Date.parse(x.end)]),
      plain[k].map((x) => [Date.parse(x.start), Date.parse(x.end)]),
    );
  }
  assert.deepEqual(zoned.ids, plain.ids);
});
