import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { Workout } from '../shared/types.ts';
import { addDays, todayLocal } from '../server/dates.ts';
import { type DailyRow, upsertDaily, upsertEvents, upsertHourly } from '../server/db.ts';
import { latest, mergeWorkouts, series, summary, valueOn } from '../server/query.ts';
import { openStore } from '../server/store.ts';

function ctx(rows: [metric: string, source: string, date: string, value: number][]) {
  const daily = new Map<string, Map<string, Map<string, number>>>();
  for (const [m, s, d, v] of rows) {
    if (!daily.has(m)) daily.set(m, new Map());
    if (!daily.get(m)!.has(s)) daily.get(m)!.set(s, new Map());
    daily.get(m)!.get(s)!.set(d, v);
  }
  return { daily, demo: false };
}

test('a fresher reading from another source beats a stale one from the preferred source', () => {
  // resting_hr prefers WHOOP, but the WHOOP stopped on the 3rd while the Watch kept going.
  const c = ctx([
    ['resting_hr', 'whoop', '2026-10-03', 80],
    ['resting_hr', 'apple', '2026-10-15', 58],
    ['resting_hr', 'apple', '2026-10-16', 57],
  ]);
  assert.deepEqual(latest(c, 'resting_hr', '2026-10-16'), { date: '2026-10-16', value: 57, source: 'apple' });
});

test('when both devices agree, the day shows their average', () => {
  const c = ctx([
    ['spo2', 'apple', '2026-10-16', 95],
    ['spo2', 'whoop', '2026-10-16', 94],
  ]);
  assert.deepEqual(latest(c, 'spo2', '2026-10-16'), { date: '2026-10-16', value: 94.5, source: 'apple+whoop' });
  assert.deepEqual(series(c, 'spo2', '2026-10-16', '2026-10-16'), [{ date: '2026-10-16', value: 94.5 }]);
});

test('resting heart rate keeps WHOOP\'s sleeping measure rather than averaging two different methods', () => {
  const c = ctx([
    ['resting_hr', 'apple', '2026-10-16', 84],
    ['resting_hr', 'whoop', '2026-10-16', 77],
  ]);
  assert.deepEqual(valueOn(c, 'resting_hr', '2026-10-16'), { source: 'whoop', value: 77 });
});

test('when they disagree, the trusted device wins instead of a skewed average', () => {
  // The Watch came off at 2am: 3.1h vs WHOOP's 7.4h. Averaging would invent a 5.3h night.
  const c = ctx([
    ['sleep_hours', 'apple', '2026-10-16', 3.1],
    ['sleep_hours', 'whoop', '2026-10-16', 7.4],
    ['sleep_deep', 'apple', '2026-10-16', 0.4],
    ['sleep_deep', 'whoop', '2026-10-16', 1.5],
  ]);
  assert.equal(valueOn(c, 'sleep_hours', '2026-10-16')!.value, 7.4);
  // Stages follow the night's decision, so they stay consistent with the total.
  assert.equal(valueOn(c, 'sleep_deep', '2026-10-16')!.value, 1.5);
});

test("stages are averaged on nights the totals agree", () => {
  const c = ctx([
    ['sleep_hours', 'apple', '2026-10-15', 7.0],
    ['sleep_hours', 'whoop', '2026-10-15', 7.4],
    ['sleep_rem', 'apple', '2026-10-15', 1.6],
    ['sleep_rem', 'whoop', '2026-10-15', 2.0],
  ]);
  assert.equal(valueOn(c, 'sleep_rem', '2026-10-15')!.value, 1.8);
});

test('metrics that differ in kind are never averaged', () => {
  // Average heart rate: Apple's waking-day average vs WHOOP's 24h cycle; Apple is preferred, not blended.
  const c = ctx([
    ['hr_avg', 'apple', '2026-10-16', 99],
    ['hr_avg', 'whoop', '2026-10-16', 88],
  ]);
  assert.deepEqual(valueOn(c, 'hr_avg', '2026-10-16'), { source: 'apple', value: 99 });
});

test('the same session from both devices becomes one workout', () => {
  const base = { date: '2026-10-14', energy_kcal: null, distance_m: null, avg_hr: null, max_hr: null, strain: null, effort: null };
  const list: Workout[] = [
    { ...base, id: 'a1', source: 'apple', sport: 'Running', start: '2026-10-14T07:00:00-05:00', end: '2026-10-14T07:40:00-05:00', duration_min: 40, energy_kcal: 410, distance_m: 6200, avg_hr: 150, max_hr: 171, effort: 6 },
    { ...base, id: 'w1', source: 'whoop', sport: 'Running', start: '2026-10-14T07:02:00-05:00', end: '2026-10-14T07:39:00-05:00', duration_min: 37, energy_kcal: 450, max_hr: 174, strain: 12.3 },
    { ...base, id: 'w2', source: 'whoop', sport: 'Weightlifting', start: '2026-10-14T18:00:00-05:00', end: '2026-10-14T18:45:00-05:00', duration_min: 45, strain: 9.1 },
  ];
  const merged = mergeWorkouts(list);
  assert.equal(merged.length, 2);
  const run = merged.find((w) => w.id === 'a1')!;
  assert.equal(run.source, 'apple+whoop');
  assert.equal(run.energy_kcal, 410);
  assert.equal(run.distance_m, 6200);
  assert.equal(run.strain, 12.3);
  assert.equal(run.max_hr, 174);
  assert.equal(run.effort, 6, "Apple Health's effort score, which WHOOP doesn't have");
  assert.ok(merged.some((w) => w.id === 'w2' && w.source === 'whoop'));
});

test('readings outside the lookback or after the as-of date are ignored', () => {
  const c = ctx([
    ['spo2', 'whoop', '2026-09-01', 96],
    ['spo2', 'apple', '2026-10-20', 97],
  ]);
  assert.equal(latest(c, 'spo2', '2026-10-16', 14), null);
});

// ---------- flags on the summary ----------

const flagDb = await openStore();
const today = todayLocal();
const ago = (n: number) => addDays(today, -n);

/**
 * A month and more of resting heart rate around 55 (54/56), then the most recent `up` readings at 63, 62, 61…,
 * and wrist temperature around 36.5 with today's reading normal or high. Returns the summary's flags.
 */
async function flagsFor(userId: string, opts: { up: number; temp: 'normal' | 'high'; skip?: number; history?: number }) {
  const skip = opts.skip ?? 0;
  const rows: DailyRow[] = [];
  for (let i = skip; i < skip + opts.up + (opts.history ?? 40); i++) {
    rows.push({ date: ago(i), metric: 'resting_hr', source: 'apple', value: i - skip < opts.up ? 63 - (i - skip) : 55 + (i % 2 ? 1 : -1) });
  }
  for (let i = 1; i < 36; i++) rows.push({ date: ago(i), metric: 'wrist_temp', source: 'apple', value: 36.5 + (i % 2 ? 0.05 : -0.05) });
  rows.push({ date: today, metric: 'wrist_temp', source: 'apple', value: opts.temp === 'high' ? 37.3 : 36.52 });
  await upsertDaily(flagDb, userId, rows);
  return summary({ db: flagDb, userId }, false);
}

test('a resting heart rate up two days with a raised temperature is a caution', async () => {
  const s = await flagsFor('flag-temp', { up: 2, temp: 'high' });
  assert.deepEqual(s.flags?.map((f) => [f.id, f.tone, f.page, f.title]), [['rhr_temp', 'caution', 'vitals', 'Your body may be under strain']]);
  assert.match(s.flags![0].text, /^Resting heart rate has been about 8 bpm above your usual for 2 days and your temperature is up\./);
  // Three days up with the temperature raised is still the one caution, not two flags.
  assert.deepEqual((await flagsFor('flag-temp-3', { up: 3, temp: 'high' })).flags?.map((f) => f.id), ['rhr_temp']);
});

test('with a normal temperature, resting heart rate needs three days up for a gentle note', async () => {
  const two = await flagsFor('flag-two', { up: 2, temp: 'normal' });
  assert.equal('flags' in two, false, 'no flags key when there are none');
  const three = await flagsFor('flag-three', { up: 3, temp: 'normal' });
  assert.deepEqual(three.flags?.map((f) => [f.id, f.tone, f.title]), [['rhr_up', 'info', 'Resting heart rate is up']]);
  assert.match(three.flags![0].text, /about 7 bpm above your usual for 3 days/);
});

test('no flag from stale readings or without two weeks of baseline, and flags never mention cycles', async () => {
  // The two high readings are 3 and 4 days old.
  assert.equal((await flagsFor('flag-stale', { up: 2, temp: 'high', skip: 3 })).flags, undefined);
  assert.equal((await flagsFor('flag-new', { up: 3, temp: 'high', history: 10 })).flags, undefined);
  for (const id of ['flag-temp', 'flag-three']) {
    const s = await summary({ db: flagDb, userId: id }, false);
    for (const f of s.flags ?? []) assert.doesNotMatch(`${f.title} ${f.text}`, /cycle|period|menstru|ovulat|luteal/i);
  }
});

/**
 * WHOOP's sleeping resting heart rate around 52 and the Watch's daytime one around 59, on the same days for 40
 * days, except the most recent `appleOnly` days, when the strap stayed off. WHOOP's most recent `whoopUp`
 * readings rise to 60, 59, 58… With `temp: 'high'`, today's wrist temperature reads well above its usual.
 */
async function mixedFlags(userId: string, opts: { appleOnly?: number; whoopUp?: number; temp?: 'normal' | 'high' }) {
  const rows: DailyRow[] = [];
  const wobble = (i: number) => (i % 2 ? 0.5 : -0.5);
  for (let i = 0; i < 40; i++) {
    rows.push({ date: ago(i), metric: 'resting_hr', source: 'apple', value: 59 + wobble(i) });
    if (i >= (opts.appleOnly ?? 0)) rows.push({ date: ago(i), metric: 'resting_hr', source: 'whoop', value: i < (opts.whoopUp ?? 0) ? 60 - i : 52 + wobble(i) });
  }
  if (opts.temp) {
    for (let i = 1; i < 36; i++) rows.push({ date: ago(i), metric: 'wrist_temp', source: 'apple', value: 36.5 + (i % 2 ? 0.05 : -0.05) });
    rows.push({ date: today, metric: 'wrist_temp', source: 'apple', value: opts.temp === 'high' ? 37.3 : 36.52 });
  }
  await upsertDaily(flagDb, userId, rows);
  return summary({ db: flagDb, userId }, false);
}

test('days without the WHOOP strap are not read as a resting heart rate that went up', async () => {
  // The daily value falls back to the Watch's usual ~59 against WHOOP's usual ~52: the device changed, the body didn't.
  const three = await mixedFlags('flag-mixed-3', { appleOnly: 3, temp: 'normal' });
  assert.equal(three.flags, undefined);
  assert.deepEqual([three.vitals.heart.latest?.source, three.vitals.heart.status], ['apple', 'normal']);
  // Two days off the strap with a raised temperature isn't the caution either.
  const two = await mixedFlags('flag-mixed-2', { appleOnly: 2, temp: 'high' });
  assert.equal(two.flags, undefined);
  assert.equal(two.vitals.temp.status, 'high');
});

test("with both devices worn, a rise on WHOOP still shows, measured against WHOOP's own usual", async () => {
  // WHOOP 60, 59, 58 over its usual 52 while the Watch stays at its usual 59.
  const s = await mixedFlags('flag-mixed-up', { whoopUp: 3 });
  assert.deepEqual(s.flags?.map((f) => f.id), ['rhr_up']);
  assert.match(s.flags![0].text, /about 7 bpm above your usual for 3 days/);
  assert.deepEqual([s.vitals.heart.latest?.source, s.vitals.heart.status], ['whoop', 'high']);
});

// ---------- which day the timeline shows ----------

test('the timeline shows the last day with events or hourly readings', async () => {
  const sleep = (id: string, date: string) => ({ id, source: 'apple', kind: 'sleep' as const, title: 'Sleep', start: `${addDays(date, -1)}T23:00:00-05:00`, end: `${date}T06:30:00-05:00`, date });
  // Nothing logged today: the card keeps showing yesterday's night, as before.
  await upsertEvents(flagDb, 'tl-events-only', [sleep('tl-a', ago(1))]);
  assert.equal((await summary({ db: flagDb, userId: 'tl-events-only' }, false)).timeline.date, ago(1));

  // Today's hours from the iPhone app make today the day shown, with its (empty) list of events.
  await upsertEvents(flagDb, 'tl-hours', [sleep('tl-b', ago(1))]);
  await upsertHourly(flagDb, 'tl-hours', [{ date: today, hour: 0, metric: 'steps', source: 'apple', value: 40 }]);
  const s = await summary({ db: flagDb, userId: 'tl-hours' }, false);
  assert.deepEqual([s.timeline.date, s.timeline.events], [today, []]);
  // A past day picked with the date arrows works the same way.
  await upsertHourly(flagDb, 'tl-hours', [{ date: ago(3), hour: 9, metric: 'hr_avg', source: 'apple', value: 70 }]);
  assert.equal((await summary({ db: flagDb, userId: 'tl-hours' }, false, ago(3))).timeline.date, ago(3));
  // Only the metrics the Day view reads count, and only from this person's own sources.
  await upsertEvents(flagDb, 'tl-other', [sleep('tl-c', ago(1))]);
  await upsertHourly(flagDb, 'tl-other', [
    { date: today, hour: 9, metric: 'hr_min', source: 'apple', value: 50 },
    { date: today, hour: 9, metric: 'steps', source: 'demo', value: 300 },
  ]);
  assert.equal((await summary({ db: flagDb, userId: 'tl-other' }, false)).timeline.date, ago(1));
  // With nothing on the chosen day, a later day with only hours wins over an earlier one with events.
  await upsertEvents(flagDb, 'tl-gap', [sleep('tl-d', ago(5))]);
  await upsertHourly(flagDb, 'tl-gap', [{ date: ago(3), hour: 12, metric: 'active_energy', source: 'apple', value: 20 }]);
  assert.deepEqual((await summary({ db: flagDb, userId: 'tl-gap' }, false, ago(1))).timeline, { date: ago(3), events: [] });
});
