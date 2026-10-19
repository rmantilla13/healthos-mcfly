// GET /api/sleep/night: one night's figures for the Sleep page, from one device at a time.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { addDays, todayLocal } from '../server/dates.ts';
import { OWNER_ID, setUserSetting, upsertDaily, upsertEvents } from '../server/db.ts';
import { deepPeak, latency, sleepNight } from '../server/sleepnight.ts';
import { insertMany, openStore } from '../server/store.ts';

const today = todayLocal('UTC');
const back = (n: number) => addDays(today, -n);
const at = (date: string, hhmm: string) => `${date}T${hhmm}:00-05:00`;

test('a night: stages and score from one device, the timeline only from the iPhone app', async (t) => {
  const db = await openStore();
  t.after(() => db.close());
  const scope = { db, userId: OWNER_ID };
  await setUserSetting(db, OWNER_ID, 'timezone', 'UTC');
  await setUserSetting(db, OWNER_ID, 'demo', 'off');
  // An Apple Watch night: asleep 7.4 h of 8.43 h in bed, with stages.
  await upsertDaily(db, OWNER_ID, [
    { date: today, metric: 'sleep_hours', source: 'apple', value: 7.4 },
    { date: today, metric: 'sleep_in_bed', source: 'apple', value: 8.43 },
    { date: today, metric: 'sleep_awake', source: 'apple', value: 0.53 },
    { date: today, metric: 'sleep_rem', source: 'apple', value: 1.8 },
    { date: today, metric: 'sleep_light', source: 'apple', value: 4.2 },
    { date: today, metric: 'sleep_deep', source: 'apple', value: 1.2 },
  ]);
  await upsertEvents(db, OWNER_ID, [{ id: 'n1', source: 'apple', kind: 'sleep', title: 'Sleep', start: at(back(1), '22:18'), end: at(today, '06:44'), date: today }]);
  const segment = (start: string, end: string, stage: string, date = today) => [OWNER_ID, date, 'apple', start, end, stage];
  await insertMany(db, 'sleep_stages', ['user_id', 'date', 'source', 'start', 'end', 'stage'], [
    segment(at(back(1), '22:00'), at(back(1), '22:18'), 'in_bed'),
    segment(at(back(1), '22:18'), at(back(1), '23:30'), 'light'),
    segment(at(back(1), '23:30'), at(today, '00:10'), 'deep'),
    segment(at(today, '00:10'), at(today, '03:00'), 'light'),
    segment(at(today, '03:00'), at(today, '03:48'), 'deep'),
    segment(at(today, '03:48'), at(today, '06:44'), 'rem'),
  ]);
  // Two weeks of nights before, each taking 30 minutes to fall asleep.
  for (let n = 1; n <= 14; n++) {
    const d = back(n);
    await insertMany(db, 'sleep_stages', ['user_id', 'date', 'source', 'start', 'end', 'stage'], [
      segment(at(addDays(d, -1), '22:00'), at(addDays(d, -1), '22:30'), 'in_bed', d),
      segment(at(addDays(d, -1), '22:30'), at(d, '06:30'), 'light', d),
    ]);
  }
  const night = await sleepNight(scope, false, today);
  assert.equal(night.source, 'apple');
  assert.equal(night.fellAsleep, at(back(1), '22:18'));
  assert.equal(night.wokeUp, at(today, '06:44'));
  assert.deepEqual(night.stages, { awake: 0.53, rem: 1.8, light: 4.2, deep: 1.2 });
  assert.deepEqual(night.score, { kind: 'efficiency', value: 88 }, '7.4 of 8.43 hours in bed');
  assert.equal(night.segments.length, 6);
  assert.equal(night.latencyMin, 18);
  assert.equal(night.deepPeak, at(today, '03:24'), 'the middle of the longest deep stretch');
  assert.ok(night.insights.some((i) => i.id === 'latency' && i.text === 'You fell asleep 12 min faster than usual.'), JSON.stringify(night.insights));
});

test("WHOOP's sleep performance is the score; WHOOP nights have no timeline", async (t) => {
  const db = await openStore();
  t.after(() => db.close());
  const scope = { db, userId: OWNER_ID };
  await setUserSetting(db, OWNER_ID, 'timezone', 'UTC');
  await setUserSetting(db, OWNER_ID, 'demo', 'off');
  await upsertDaily(db, OWNER_ID, [
    { date: today, metric: 'sleep_hours', source: 'whoop', value: 7.1 },
    { date: today, metric: 'sleep_in_bed', source: 'whoop', value: 7.9 },
    { date: today, metric: 'sleep_deep', source: 'whoop', value: 1.5 },
    { date: today, metric: 'sleep_rem', source: 'whoop', value: 1.9 },
    { date: today, metric: 'sleep_light', source: 'whoop', value: 3.7 },
    { date: today, metric: 'sleep_awake', source: 'whoop', value: 0.8 },
    { date: today, metric: 'sleep_performance', source: 'whoop', value: 84 },
  ]);
  const night = await sleepNight(scope, false, today);
  assert.deepEqual(night.score, { kind: 'performance', value: 84 });
  assert.equal(night.stages?.deep, 1.5);
  assert.deepEqual(night.segments, []);
  assert.equal(night.latencyMin, null);
});

test('phone-only time in bed gives no efficiency score; a night with nothing is empty', async (t) => {
  const db = await openStore();
  t.after(() => db.close());
  const scope = { db, userId: OWNER_ID };
  await setUserSetting(db, OWNER_ID, 'timezone', 'UTC');
  await setUserSetting(db, OWNER_ID, 'demo', 'off');
  await upsertDaily(db, OWNER_ID, [
    { date: today, metric: 'sleep_hours', source: 'apple', value: 8 },
    { date: today, metric: 'sleep_in_bed', source: 'apple', value: 8 },
  ]);
  assert.equal((await sleepNight(scope, false, today)).score, null);
  const empty = await sleepNight(scope, false, back(3));
  assert.deepEqual([empty.source, empty.stages, empty.score, empty.segments, empty.insights], [null, null, null, [], []]);
});

test('latency and deep peak from segments', () => {
  assert.equal(latency([]), null);
  assert.equal(latency([{ start: '2026-10-18T22:00:00-05:00', end: '2026-10-18T23:00:00-05:00', stage: 'light' }]), null, 'no time in bed recorded');
  assert.equal(deepPeak([{ start: '2026-10-19T01:00:00+02:00', end: '2026-10-19T02:00:00+02:00', stage: 'deep' }]), '2026-10-19T01:30:00+02:00');
});
