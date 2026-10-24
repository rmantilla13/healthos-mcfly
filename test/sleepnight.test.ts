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

test('a night both devices recorded keeps every figure on one device', async (t) => {
  const db = await openStore();
  t.after(() => db.close());
  const scope = { db, userId: OWNER_ID };
  await setUserSetting(db, OWNER_ID, 'timezone', 'UTC');
  await setUserSetting(db, OWNER_ID, 'demo', 'off');
  const night = (whoopHours: number) => [
    { date: today, metric: 'sleep_hours', source: 'apple', value: 7.4 },
    { date: today, metric: 'sleep_in_bed', source: 'apple', value: 8 },
    { date: today, metric: 'sleep_deep', source: 'apple', value: 0.9 },
    { date: today, metric: 'sleep_rem', source: 'apple', value: 1.6 },
    { date: today, metric: 'sleep_light', source: 'apple', value: 4.9 },
    { date: today, metric: 'sleep_awake', source: 'apple', value: 0.6 },
    { date: today, metric: 'sleep_hours', source: 'whoop', value: whoopHours },
    { date: today, metric: 'sleep_in_bed', source: 'whoop', value: whoopHours + 0.5 },
    { date: today, metric: 'sleep_deep', source: 'whoop', value: 1.6 },
    { date: today, metric: 'sleep_rem', source: 'whoop', value: 1.5 },
    { date: today, metric: 'sleep_light', source: 'whoop', value: whoopHours - 3.1 },
    { date: today, metric: 'sleep_awake', source: 'whoop', value: 0.5 },
  ];
  await upsertEvents(db, OWNER_ID, [
    { id: 'a', source: 'apple', kind: 'sleep', title: 'Sleep', start: at(back(1), '22:40'), end: at(today, '06:40'), date: today },
    // WHOOP's record is its whole sleep, so usually the longer one.
    { id: 'w', source: 'whoop', kind: 'sleep', title: 'Sleep', start: at(back(1), '22:10'), end: at(today, '06:55'), date: today },
  ]);
  await insertMany(db, 'sleep_stages', ['user_id', 'date', 'source', 'start', 'end', 'stage'], [
    [OWNER_ID, today, 'apple', at(back(1), '22:40'), at(today, '01:00'), 'light'],
    [OWNER_ID, today, 'apple', at(today, '01:00'), at(today, '01:54'), 'deep'],
    [OWNER_ID, today, 'apple', at(today, '01:54'), at(today, '06:40'), 'light'],
  ]);

  // They agree (7.4 and 7.1 hours): the total is their average, and the night is the Watch's, the one with stages.
  await upsertDaily(db, OWNER_ID, night(7.1));
  const both = await sleepNight(scope, false, today);
  assert.equal(both.source, 'apple');
  assert.equal(both.stages?.deep, 0.9, "the Watch's deep sleep, under the Watch's hypnogram");
  assert.equal(both.segments.length, 3);
  assert.equal(both.fellAsleep, at(back(1), '22:40'));
  assert.equal(both.inBedHours, 8);

  // They disagree (the strap slipped off): WHOOP is trusted, so it's WHOOP's night throughout, with no Apple timeline.
  await upsertDaily(db, OWNER_ID, night(3.2));
  const whoop = await sleepNight(scope, false, today);
  assert.equal(whoop.source, 'whoop');
  assert.equal(whoop.stages?.deep, 1.6);
  assert.deepEqual(whoop.segments, []);
  assert.equal(whoop.fellAsleep, at(back(1), '22:10'));
  assert.equal(whoop.latencyMin, null);
});

test('stretches come back in time order even when the clocks went back that night', async (t) => {
  const db = await openStore();
  t.after(() => db.close());
  const scope = { db, userId: OWNER_ID };
  await setUserSetting(db, OWNER_ID, 'timezone', 'UTC');
  await setUserSetting(db, OWNER_ID, 'demo', 'off');
  await upsertDaily(db, OWNER_ID, [{ date: today, metric: 'sleep_hours', source: 'apple', value: 7 }]);
  await insertMany(db, 'sleep_stages', ['user_id', 'date', 'source', 'start', 'end', 'stage'], [
    [OWNER_ID, today, 'apple', `${back(1)}T23:10:00-05:00`, `${today}T01:20:00-05:00`, 'light'],
    [OWNER_ID, today, 'apple', `${today}T01:20:00-05:00`, `${today}T01:05:00-06:00`, 'deep'],
    [OWNER_ID, today, 'apple', `${today}T01:05:00-06:00`, `${today}T06:40:00-06:00`, 'light'],
  ]);
  const n = await sleepNight(scope, false, today);
  assert.deepEqual(n.segments.map((g) => g.stage), ['light', 'deep', 'light']);
});

test("a WHOOP nap alone doesn't blank the Watch's night; an unstaged Watch night keeps WHOOP's stages", async (t) => {
  const db = await openStore();
  t.after(() => db.close());
  const scope = { db, userId: OWNER_ID };
  await setUserSetting(db, OWNER_ID, 'timezone', 'UTC');
  await setUserSetting(db, OWNER_ID, 'demo', 'off');
  // The strap was off overnight but worn for a nap: WHOOP's 0.5 h (a nap, not a sleep record) disagrees with the
  // Watch's 7.2 h, so WHOOP's total is trusted. Its device has no night, though, so the night is the Watch's.
  await upsertDaily(db, OWNER_ID, [
    { date: today, metric: 'sleep_hours', source: 'apple', value: 7.2 },
    { date: today, metric: 'sleep_in_bed', source: 'apple', value: 7.8 },
    { date: today, metric: 'sleep_deep', source: 'apple', value: 1 },
    { date: today, metric: 'sleep_rem', source: 'apple', value: 1.5 },
    { date: today, metric: 'sleep_light', source: 'apple', value: 4.7 },
    { date: today, metric: 'sleep_awake', source: 'apple', value: 0.6 },
    { date: today, metric: 'sleep_hours', source: 'whoop', value: 0.5 },
  ]);
  await upsertEvents(db, OWNER_ID, [{ id: 'a', source: 'apple', kind: 'sleep', title: 'Sleep', start: at(back(1), '23:00'), end: at(today, '06:30'), date: today }]);
  await insertMany(db, 'sleep_stages', ['user_id', 'date', 'source', 'start', 'end', 'stage'], [
    [OWNER_ID, today, 'apple', at(back(1), '23:00'), at(today, '02:00'), 'light'],
    [OWNER_ID, today, 'apple', at(today, '02:00'), at(today, '03:00'), 'deep'],
    [OWNER_ID, today, 'apple', at(today, '03:00'), at(today, '06:30'), 'light'],
  ]);
  const nap = await sleepNight(scope, false, today);
  assert.equal(nap.source, 'apple');
  assert.equal(nap.fellAsleep, at(back(1), '23:00'));
  assert.equal(nap.inBedHours, 7.8);
  assert.equal(nap.stages?.deep, 1);
  assert.equal(nap.segments.length, 3);

  // An older Watch (or another app) wrote only "asleep" the next night, and WHOOP agrees on the total and has stages.
  const d = back(1);
  await upsertDaily(db, OWNER_ID, [
    { date: d, metric: 'sleep_hours', source: 'apple', value: 7.2 },
    { date: d, metric: 'sleep_hours', source: 'whoop', value: 7 },
    { date: d, metric: 'sleep_deep', source: 'whoop', value: 1.5 },
    { date: d, metric: 'sleep_rem', source: 'whoop', value: 1.6 },
    { date: d, metric: 'sleep_light', source: 'whoop', value: 3.9 },
    { date: d, metric: 'sleep_awake', source: 'whoop', value: 0.6 },
  ]);
  await insertMany(db, 'sleep_stages', ['user_id', 'date', 'source', 'start', 'end', 'stage'], [[OWNER_ID, d, 'apple', at(back(2), '23:00'), at(d, '06:12'), 'asleep']]);
  const unstaged = await sleepNight(scope, false, d);
  assert.equal(unstaged.source, 'whoop');
  assert.equal(unstaged.stages?.deep, 1.5);
  assert.deepEqual(unstaged.segments, []);
});

test("performance and efficiency apart: WHOOP's own two numbers, a Fitbit night's efficiency, the Watch's worked out", async (t) => {
  const db = await openStore();
  t.after(() => db.close());
  const scope = { db, userId: OWNER_ID };
  await setUserSetting(db, OWNER_ID, 'timezone', 'UTC');
  await setUserSetting(db, OWNER_ID, 'demo', 'off');
  assert.equal((await sleepNight(scope, false, today)).lastNight, null, 'no night ever');

  // WHOOP: 7.1 of 7.9 hours would work out at 90%, but WHOOP says 92%, and that's the one shown.
  await upsertDaily(db, OWNER_ID, [
    { date: back(4), metric: 'sleep_hours', source: 'whoop', value: 7.1 },
    { date: back(4), metric: 'sleep_in_bed', source: 'whoop', value: 7.9 },
    { date: back(4), metric: 'sleep_deep', source: 'whoop', value: 1.5 },
    { date: back(4), metric: 'sleep_performance', source: 'whoop', value: 84.4 },
    { date: back(4), metric: 'sleep_efficiency', source: 'whoop', value: 91.6 },
  ]);
  const whoop = await sleepNight(scope, false, back(4));
  assert.equal(whoop.source, 'whoop');
  assert.deepEqual([whoop.performance, whoop.efficiency], [84, 92]);
  assert.deepEqual(whoop.score, { kind: 'performance', value: 84 }, 'the old single score is unchanged');
  assert.equal(whoop.lastNight, back(4));

  // A Fitbit export's night is Fitbit's, not Apple's, with its own efficiency and no performance.
  await upsertDaily(db, OWNER_ID, [
    { date: back(2), metric: 'sleep_hours', source: 'fitbit', value: 6.5 },
    { date: back(2), metric: 'sleep_in_bed', source: 'fitbit', value: 7.2 },
    { date: back(2), metric: 'sleep_deep', source: 'fitbit', value: 1.1 },
    { date: back(2), metric: 'sleep_efficiency', source: 'fitbit', value: 93 },
  ]);
  const fitbit = await sleepNight(scope, false, back(2));
  assert.equal(fitbit.source, 'fitbit');
  assert.deepEqual([fitbit.performance, fitbit.efficiency], [null, 93]);

  // An Apple Watch night: no performance, and efficiency from its own time asleep and in bed.
  await upsertDaily(db, OWNER_ID, [
    { date: back(1), metric: 'sleep_hours', source: 'apple', value: 7.4 },
    { date: back(1), metric: 'sleep_in_bed', source: 'apple', value: 8.43 },
  ]);
  const apple = await sleepNight(scope, false, back(1));
  assert.deepEqual([apple.source, apple.performance, apple.efficiency], ['apple', null, 88]);

  // A night with nothing still knows there were nights before it.
  const none = await sleepNight(scope, false, today);
  assert.deepEqual([none.asleepHours, none.performance, none.efficiency, none.lastNight], [null, null, null, back(1)]);
});
