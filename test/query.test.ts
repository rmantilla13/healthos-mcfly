import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { Workout } from '../shared/types.ts';
import { latest, mergeWorkouts, series, valueOn } from '../server/query.ts';

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
  const base = { date: '2026-10-14', energy_kcal: null, distance_m: null, avg_hr: null, max_hr: null, strain: null };
  const list: Workout[] = [
    { ...base, id: 'a1', source: 'apple', sport: 'Running', start: '2026-10-14T07:00:00-05:00', end: '2026-10-14T07:40:00-05:00', duration_min: 40, energy_kcal: 410, distance_m: 6200, avg_hr: 150, max_hr: 171 },
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
  assert.ok(merged.some((w) => w.id === 'w2' && w.source === 'whoop'));
});

test('readings outside the lookback or after the as-of date are ignored', () => {
  const c = ctx([
    ['spo2', 'whoop', '2026-09-01', 96],
    ['spo2', 'apple', '2026-10-20', 97],
  ]);
  assert.equal(latest(c, 'spo2', '2026-10-16', 14), null);
});
