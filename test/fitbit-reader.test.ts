// The browser side of the Fitbit import (src/import/): which files of a Takeout export are read, what each kind gives,
// and the zip reader, over small synthetic exports in test/fixtures/fitbit (made-up values, both layouts Google has used).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';
import { FitbitReader, type FitbitFound, fitbitChunks, fitbitFileKind, fitbitFinish, fitbitPreview, fitbitRows, needsWeightUnit, parseCsv, typicalWeight } from '../src/import/fitbit.ts';
import { readFitbitFiles } from '../src/import/fitbitFiles.ts';
import { listZip, readZipText } from '../src/import/zip.ts';
import { FITBIT_CHUNK } from '../shared/fitbitRanges.ts';

const FIXTURES = path.join(import.meta.dirname, 'fixtures', 'fitbit');
const ZONE = 'America/Chicago';

/** Every file under a fixture, as [path inside the export, text]. */
function files(name: string): [string, string][] {
  const root = path.join(FIXTURES, name);
  return (fs.readdirSync(root, { recursive: true }) as string[])
    .filter((p) => fs.statSync(path.join(root, p)).isFile())
    .sort()
    .map((p) => [p.split(path.sep).join('/'), fs.readFileSync(path.join(root, p), 'utf8')]);
}

function read(name: string): FitbitFound {
  const reader = new FitbitReader(ZONE);
  for (const [p, text] of files(name)) reader.add(p, text);
  return reader.result();
}

const rowsOf = (found: FitbitFound, weightUnit: 'kg' | 'lb' | null = null) => fitbitRows(found, { weightUnit, today: '2026-11-02' });
const value = (rows: { daily: { date: string; metric: string; value: number }[] }, date: string, metric: string) =>
  rows.daily.find((r) => r.date === date && r.metric === metric)?.value;

test('files are recognised by name wherever they sit, and nothing else is opened', () => {
  const kinds: [string, string | null][] = [
    ['Takeout/Fitbit/Global Export Data/heart_rate-2024-03-01.json', 'heart_rate_json'],
    ['MyFitbitData/Me/Physical Activity/heart_rate-2019-01-01.json', 'heart_rate_json'],
    ['Takeout/Fitbit/Global Export Data/resting_heart_rate-2024-03-01.json', 'resting_hr_json'],
    ['Takeout/Fitbit/Global Export Data/sleep-2024-03-02.json', 'sleep_json'],
    ['Takeout/Fitbit/Global Export Data/weight-2024-03-02.json', 'weight_json'],
    ['Takeout/Fitbit/Global Export Data/steps-2024-03-02.json', 'steps_json'],
    ['Takeout/Fitbit/Physical Activity_GoogleData/heart_rate_2024-10-27.csv', 'heart_rate_csv'],
    ['Takeout/Google Health/Physical Activity_GoogleData/Heart Rate/heart_rate_2026-09-01.csv', 'heart_rate_csv'],
    ['Takeout/Google Health/Physical Activity_GoogleData/Heart Rate/Heart Rate 2026-09.csv', 'heart_rate_csv'],
    ['Takeout/Google Health/Physical Activity_GoogleData/Daily Resting Heart Rate/daily_resting_heart_rate.csv', 'resting_hr_csv'],
    ['Takeout/Google Health/Health Fitness Data_GoogleData/UserSleeps_2026-05-20.csv', 'sleeps_csv'],
    ['Takeout/Google Health/Health Fitness Data_GoogleData/UserSleepStages_2026-05-20.csv', 'sleep_stages_csv'],
    ['Takeout/Fitbit/Physical Activity_GoogleData/weight.csv', 'weight_csv'],
    ['Takeout/Fitbit/Physical Activity_GoogleData/body_fat_2024-01-01.csv', 'body_fat_csv'],
    ['Takeout/Fitbit/Heart Rate Variability/Daily Heart Rate Variability Summary - 2024-07-(21).csv', 'hrv_csv'],
    ['Takeout/Fitbit/Heart Rate Variability/Daily Heart Rate Variability Summary - 2024-07-.csv', 'hrv_csv'],
    ['Takeout/Fitbit/Heart Rate Variability/Daily Respiratory Rate Summary - 2024-07-22.csv', 'resp_csv'],
    ['Takeout/Google Health/Physical Activity_GoogleData/respiratory_rate_sleep_summary_2025-12-01.csv', 'resp_csv'],
    ['Takeout/Fitbit/Oxygen Saturation (SpO2)/Daily SpO2 - 2025-12-19-2026-01-08.csv', 'spo2_csv'],
    // Never opened: other kinds, intraday detail, scores, the profile, macOS copies.
    ['Takeout/Fitbit/Global Export Data/calories-2024-03-01.json', null],
    ['Takeout/Fitbit/Heart Rate Variability/Heart Rate Variability Details - 2024-07-21.csv', null],
    ['Takeout/Fitbit/Oxygen Saturation (SpO2)/Minute SpO2 - 2024-07-21.csv', null],
    ['Takeout/Fitbit/Sleep Score/sleep_score.csv', null],
    ['Takeout/Google Health/Health Fitness Data_GoogleData/UserSleepScores_2026-01-01.csv', null],
    ['Takeout/Google Health/Your Profile/Profile.csv', null],
    ['Takeout/Google Health/Physical Activity_GoogleData/Calories/calories_2026-09-01.csv', null],
    ['__MACOSX/Takeout/Fitbit/Global Export Data/._heart_rate-2024-03-01.json', null],
    ['Takeout/Fitbit/Global Export Data/heart_rate-2024-03-01.json.gz', null],
  ];
  for (const [p, kind] of kinds) assert.equal(fitbitFileKind(p), kind, p);
});

test('heart rate and steps are UTC minutes, counted toward the local day; a strap worn for a moment is no day', () => {
  const rows = rowsOf(read('legacy'), 'lb');
  // 03:00 UTC on the 15th is 22:00 on the 14th in Chicago, so it joins the 14th.
  assert.equal(value(rows, '2026-09-14', 'hr_avg'), 69);
  assert.equal(value(rows, '2026-09-14', 'hr_min'), 60);
  assert.equal(value(rows, '2026-09-14', 'hr_max'), 120);
  assert.equal(value(rows, '2026-09-13', 'hr_avg'), undefined, 'one sample on the 13th');
  assert.equal(value(rows, '2026-09-14', 'steps'), 250);
  assert.equal(value(rows, '2026-09-15', 'steps'), undefined, 'a day of zeros is no day of steps');
});

test("resting heart rate skips Fitbit's padding; the nightly files give HRV, breathing and blood oxygen by date", () => {
  const rows = rowsOf(read('legacy'), 'lb');
  assert.deepEqual(
    rows.daily.filter((r) => r.metric === 'resting_hr'),
    [{ date: '2026-09-14', metric: 'resting_hr', value: 52.4 }],
  );
  assert.equal(value(rows, '2026-09-14', 'hrv_rmssd'), 42.5);
  assert.equal(value(rows, '2026-09-16', 'hrv_rmssd'), 38);
  assert.equal(value(rows, '2026-09-14', 'resp_rate'), 14.6);
  assert.equal(value(rows, '2026-09-14', 'spo2'), 95.7);
  // The 5-minute HRV detail and minute SpO2 files aren't read.
  assert.equal(rows.daily.filter((r) => r.metric === 'hrv_rmssd').length, 2);
});

test('a night: the main sleep gives its stages and timeline, naps add to the total, classic nights only say asleep', () => {
  const rows = rowsOf(read('legacy'), 'lb');
  assert.equal(value(rows, '2026-09-14', 'sleep_hours'), Math.round(((430 + 28) / 60) * 1000) / 1000);
  assert.equal(value(rows, '2026-09-14', 'sleep_in_bed'), 8);
  assert.equal(value(rows, '2026-09-14', 'sleep_efficiency'), 90);
  assert.equal(value(rows, '2026-09-14', 'sleep_deep'), 1.333);
  assert.equal(value(rows, '2026-09-14', 'sleep_rem'), 1.667);
  assert.equal(value(rows, '2026-09-14', 'sleep_light'), 4.167);
  assert.equal(value(rows, '2026-09-14', 'sleep_awake'), 0.833);
  const night = rows.sleep.find((n) => n.date === '2026-09-14')!;
  assert.equal(night.start, '2026-09-13T22:30:00-05:00');
  assert.equal(night.end, '2026-09-14T06:30:00-05:00');
  assert.equal(night.segments.length, 6, 'the main sleep only, without its short wakes');
  assert.deepEqual(night.segments[0], { start: '2026-09-13T22:30:00-05:00', end: '2026-09-13T22:40:00-05:00', stage: 'awake' });
  assert.deepEqual(night.segments[2], { start: '2026-09-13T23:40:00-05:00', end: '2026-09-14T01:00:00-05:00', stage: 'deep' });

  // A classic night: asleep and restless (awake) stretches, and no stage totals.
  assert.equal(value(rows, '2026-09-16', 'sleep_hours'), 6.667);
  assert.equal(value(rows, '2026-09-16', 'sleep_deep'), undefined);
  const classic = rows.sleep.find((n) => n.date === '2026-09-16')!;
  assert.deepEqual(
    classic.segments.map((g) => g.stage),
    ['asleep', 'awake', 'asleep', 'awake'],
  );

  // The night the clocks went back: each end keeps the offset it had.
  const dst = rows.sleep.find((n) => n.date === '2026-11-01')!;
  assert.equal(dst.start, '2026-10-31T23:00:00-05:00');
  assert.equal(dst.end, '2026-11-01T07:00:00-06:00');
});

test('weigh-ins: a grams file on the same day tells the JSON unit; the day keeps its last weigh-in', () => {
  const found = read('legacy');
  assert.equal(found.weightUnit, 'lb');
  assert.equal(needsWeightUnit(found), false);
  const rows = rowsOf(found);
  assert.equal(value(rows, '2026-09-14', 'weight'), Math.round((166 / 2.20462) * 100) / 100);
  assert.equal(value(rows, '2026-09-16', 'weight'), 74.75, 'the grams reading wins its day');
  assert.equal(value(rows, '2026-09-14', 'body_fat'), 18.5);
  assert.equal(value(rows, '2026-09-16', 'body_fat'), 18.9);
});

test("without a grams file the unit is asked, and weigh-ins wait for it", () => {
  const reader = new FitbitReader(ZONE);
  for (const [p, text] of files('legacy')) if (!p.endsWith('weight.csv')) reader.add(p, text);
  const found = reader.result();
  assert.equal(found.weightUnit, null);
  assert.equal(needsWeightUnit(found), true);
  assert.equal(typicalWeight(found), 166);
  assert.equal(rowsOf(found).daily.filter((r) => r.metric === 'weight').length, 0);
  assert.equal(value(rowsOf(found, 'kg'), '2026-09-14', 'weight'), 166);
  assert.equal(value(rowsOf(found, 'lb'), '2026-09-16', 'weight'), 74.75);
});

test('the newer layout: CSVs with overlapping data sources, and the sleep tables joined on sleep_id', () => {
  const found = read('google-health');
  const rows = rowsOf(found);
  // The band's heart rate alone (most samples), not averaged with Health Connect's copy.
  assert.equal(value(rows, '2026-09-20', 'hr_avg'), 75.5);
  assert.equal(value(rows, '2026-09-20', 'hr_max'), 81);
  // Steps from one source a day (the most complete), never the sum of copies.
  assert.equal(value(rows, '2026-09-20', 'steps'), 150);
  assert.equal(value(rows, '2026-09-20', 'resting_hr'), 54);
  assert.equal(value(rows, '2026-09-20', 'weight'), 80.5);
  assert.equal(value(rows, '2026-09-20', 'resp_rate'), 14.2, 'milli-breaths become breaths a minute');
  assert.equal(value(rows, '2026-09-20', 'sleep_hours'), 6.833);
  assert.equal(value(rows, '2026-09-20', 'sleep_in_bed'), 7.5);
  assert.equal(value(rows, '2026-09-20', 'sleep_deep'), 1.5);
  assert.equal(value(rows, '2026-09-20', 'sleep_light'), 3.833);
  assert.equal(value(rows, '2026-09-20', 'sleep_awake'), 0.667);
  assert.equal(value(rows, '2026-09-20', 'sleep_efficiency'), undefined, "the newer tables don't give Fitbit's efficiency");
  const night = rows.sleep[0];
  assert.equal(night.start, '2026-09-19T23:00:00-05:00');
  assert.equal(night.end, '2026-09-20T06:30:00-05:00');
  assert.deepEqual(night.segments[2], { start: '2026-09-20T01:10:00-05:00', end: '2026-09-20T02:40:00-05:00', stage: 'deep' });
  assert.equal(needsWeightUnit(found), false);
});

test('readings outside what a Fitbit records, and days after today, are left out', () => {
  const reader = new FitbitReader(ZONE);
  reader.add('Global Export Data/resting_heart_rate-2026-09-01.json', JSON.stringify([{ dateTime: '09/14/26 00:00:00', value: { date: '09/14/26', value: 400, error: 1 } }]));
  reader.add('Oxygen Saturation (SpO2)/Daily SpO2 - 2026-09-01.csv', 'timestamp,average_value\n2026-09-14T00:00:00Z,96\n2026-12-01T00:00:00Z,97\n');
  reader.add('Global Export Data/steps-2026-09-01.json', 'not json');
  const found = reader.result();
  assert.equal(found.skipped, 1);
  const rows = rowsOf(found);
  assert.deepEqual(rows.daily, [{ date: '2026-09-14', metric: 'spo2', value: 96 }]);
});

test('CSV cells are trimmed, quoted cells kept whole, and a byte-order mark ignored', () => {
  assert.deepEqual(parseCsv('\uFEFFtimestamp, average_value ,note\r\n2026-09-14T00:00:00Z, 96.5 ,"a, b ""c"""\r\n'), [{ timestamp: '2026-09-14T00:00:00Z', average_value: '96.5', note: 'a, b "c"' }]);
  assert.deepEqual(parseCsv('timestamp,rmssd\n'), []);
});

test('chunks keep whole days, a night with its day, under the size asked for', () => {
  const rows = rowsOf(read('legacy'), 'lb');
  const chunks = fitbitChunks(rows, { ...FITBIT_CHUNK, bytes: 1200 });
  assert.ok(chunks.length > 1);
  const dates = chunks.map((c) => new Set([...c.daily.map((r) => r.date), ...(c.sleep ?? []).map((n) => n.date)]));
  for (let i = 0; i < dates.length; i++) for (let j = i + 1; j < dates.length; j++) for (const d of dates[i]) assert.ok(!dates[j].has(d), `${d} split across chunks`);
  for (const c of chunks) for (const n of c.sleep ?? []) assert.ok(c.daily.some((r) => r.date === n.date && r.metric === 'sleep_hours'));
  assert.equal(chunks.flatMap((c) => c.daily).length, rows.daily.length);
  assert.equal(fitbitChunks(rows).length, 1);
  const finish = fitbitFinish(rows);
  assert.equal(finish.firstDate, '2026-09-14');
  assert.equal(finish.lastDate, '2026-11-01');
  assert.equal(finish.days, 3);
  const preview = fitbitPreview(rows);
  assert.deepEqual([preview.heartDays, preview.sleepNights, preview.hrvNights, preview.weighIns, preview.days], [1, 3, 2, 2, 3]);
});

test("years of nights without stages still fit the server's limits on rows and nights per chunk", () => {
  const sleep = Array.from({ length: 3_200 }, (_, i) => {
    const date = new Date(Date.parse('2016-01-01T00:00:00Z') + i * 86_400_000).toISOString().slice(0, 10);
    return { date, start: `${date}T00:30:00-05:00`, end: `${date}T07:00:00-05:00`, segments: [] };
  });
  const daily = sleep.map((n) => ({ date: n.date, metric: 'sleep_hours' as const, value: 6.5 }));
  const chunks = fitbitChunks({ daily, sleep });
  assert.ok(chunks.length >= 3);
  for (const c of chunks) {
    assert.ok((c.sleep ?? []).length <= FITBIT_CHUNK.nights);
    assert.ok(c.daily.length <= FITBIT_CHUNK.rows);
    assert.ok(JSON.stringify(c).length <= FITBIT_CHUNK.bytes);
  }
  assert.equal(chunks.flatMap((c) => c.sleep ?? []).length, 3_200);
});

// ---------- zip ----------

/** A zip of these files, deflated (or stored), optionally written the zip64 way, like an export over 4 GB. */
function makeZip(entries: [string, string][], { zip64 = false, store = false } = {}): Uint8Array<ArrayBuffer> {
  const locals: Buffer[] = [];
  const centrals: Buffer[] = [];
  let offset = 0;
  for (const [name, text] of entries) {
    const raw = Buffer.from(text);
    const data = store ? raw : zlib.deflateRawSync(raw);
    const nameBuf = Buffer.from(name);
    const crc = zlib.crc32(raw);
    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0);
    local.writeUInt16LE(20, 4);
    local.writeUInt16LE(0x0800, 6);
    local.writeUInt16LE(store ? 0 : 8, 8);
    local.writeUInt32LE(crc, 14);
    local.writeUInt32LE(data.length, 18);
    local.writeUInt32LE(raw.length, 22);
    local.writeUInt16LE(nameBuf.length, 26);
    locals.push(local, nameBuf, data);
    const extra = zip64 ? Buffer.alloc(28) : Buffer.alloc(0);
    if (zip64) {
      extra.writeUInt16LE(0x0001, 0);
      extra.writeUInt16LE(24, 2);
      extra.writeBigUInt64LE(BigInt(raw.length), 4);
      extra.writeBigUInt64LE(BigInt(data.length), 12);
      extra.writeBigUInt64LE(BigInt(offset), 20);
    }
    const central = Buffer.alloc(46);
    central.writeUInt32LE(0x02014b50, 0);
    central.writeUInt16LE(zip64 ? 45 : 20, 4);
    central.writeUInt16LE(zip64 ? 45 : 20, 6);
    central.writeUInt16LE(0x0800, 8);
    central.writeUInt16LE(store ? 0 : 8, 10);
    central.writeUInt32LE(crc, 16);
    central.writeUInt32LE(zip64 ? 0xffffffff : data.length, 20);
    central.writeUInt32LE(zip64 ? 0xffffffff : raw.length, 24);
    central.writeUInt16LE(nameBuf.length, 28);
    central.writeUInt16LE(extra.length, 30);
    central.writeUInt32LE(zip64 ? 0xffffffff : offset, 42);
    centrals.push(central, nameBuf, extra);
    offset += 30 + nameBuf.length + data.length;
  }
  const dir = Buffer.concat(centrals);
  const tail: Buffer[] = [];
  if (zip64) {
    const end64 = Buffer.alloc(56);
    end64.writeUInt32LE(0x06064b50, 0);
    end64.writeBigUInt64LE(44n, 4);
    end64.writeUInt16LE(45, 12);
    end64.writeUInt16LE(45, 14);
    end64.writeBigUInt64LE(BigInt(entries.length), 24);
    end64.writeBigUInt64LE(BigInt(entries.length), 32);
    end64.writeBigUInt64LE(BigInt(dir.length), 40);
    end64.writeBigUInt64LE(BigInt(offset), 48);
    const locator = Buffer.alloc(20);
    locator.writeUInt32LE(0x07064b50, 0);
    locator.writeBigUInt64LE(BigInt(offset + dir.length), 8);
    locator.writeUInt32LE(1, 16);
    tail.push(end64, locator);
  }
  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0);
  end.writeUInt16LE(zip64 ? 0xffff : entries.length, 8);
  end.writeUInt16LE(zip64 ? 0xffff : entries.length, 10);
  end.writeUInt32LE(zip64 ? 0xffffffff : dir.length, 12);
  end.writeUInt32LE(zip64 ? 0xffffffff : offset, 16);
  return new Uint8Array(Buffer.concat([...locals, dir, ...tail, end]));
}

test('the zip reader lists the central directory and inflates one file at a time, zip64 included', async () => {
  const entries = files('legacy');
  for (const opts of [{}, { zip64: true }, { store: true }]) {
    const zip = new Blob([makeZip(entries, opts)]);
    const listed = await listZip(zip);
    assert.deepEqual(
      listed.map((e) => e.name),
      entries.map(([n]) => n),
    );
    const sleep = listed.find((e) => e.name.endsWith('sleep-2026-09-01.json'))!;
    assert.equal(await readZipText(zip, sleep), entries.find(([n]) => n === sleep.name)![1]);
  }
  await assert.rejects(listZip(new Blob(['not a zip at all'])), /isn't a \.zip/);
});

test('reading a chosen .zip gives what reading the unzipped folder gives', async () => {
  const entries = files('google-health');
  const zipped = await readFitbitFiles([{ file: new File([makeZip(entries)], 'takeout-20261023T000000Z-001.zip'), path: 'takeout.zip' }], ZONE, () => {});
  const progress: number[] = [];
  const folder = await readFitbitFiles(
    entries.map(([p, text]) => ({ file: new File([text], p.split('/').at(-1)!), path: p })),
    ZONE,
    (p) => progress.push(p.read),
  );
  assert.deepEqual(zipped, folder);
  assert.equal(folder.files, 7, 'calories and the sleep scores are never read');
  assert.equal(progress.at(-1), 7);
  await assert.rejects(readFitbitFiles([{ file: new File(['x'], 'takeout.tgz'), path: 'takeout.tgz' }], ZONE, () => {}), /\.tgz/);
});
