// The latest-workout card's arithmetic (shared/workouts.ts): which workout is the latest, pace and units, the
// recent-session bars, the general suggestions' rules, and the remembered ticks.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { Workout } from '../shared/types.ts';
import {
  barMetric,
  clockDuration,
  distanceIn,
  endsLate,
  formatPace,
  latestWorkout,
  num,
  paceOf,
  readTicks,
  recentSessions,
  recoverySuggestions,
  SUGGESTION_HOURS,
  sportKind,
  suggestionsApply,
  tickKey,
  writeTicks,
} from '../shared/workouts.ts';
import { duration } from '../src/lib.ts';

const workout = (o: Partial<Workout> & { id: string; start: string; duration_min: number }): Workout => {
  const end = o.end ?? new Date(Date.parse(o.start) + o.duration_min * 60_000).toISOString().replace('.000Z', 'Z');
  return { source: 'apple', sport: 'Running', date: o.start.slice(0, 10), energy_kcal: null, distance_m: null, avg_hr: null, max_hr: null, strain: null, effort: null, ...o, end };
};
const ids = (list: { id: string }[]) => list.map((w) => w.id);
const ids2 = (list: { id: string }[]) => ids(list).join(' ');

test('sports are sorted into kinds from the names Apple Health and WHOOP use', () => {
  assert.equal(sportKind('Running'), 'run');
  assert.equal(sportKind('Trail Running'), 'run');
  assert.equal(sportKind('Walking'), 'walk');
  assert.equal(sportKind('Hiking'), 'walk');
  assert.equal(sportKind('Cycling'), 'cycle');
  assert.equal(sportKind('Mountain Biking'), 'cycle');
  assert.equal(sportKind('Spinning'), 'cycle');
  assert.equal(sportKind('Swimming'), 'swim');
  assert.equal(sportKind('Traditional Strength Training'), 'strength');
  assert.equal(sportKind('Functional Strength Training'), 'strength');
  assert.equal(sportKind('Weightlifting'), 'strength');
  assert.equal(sportKind('Yoga'), 'mind');
  assert.equal(sportKind('Mind And Body'), 'mind');
  assert.equal(sportKind('Rowing'), 'other');
  assert.equal(sportKind('Tennis'), 'other');
});

test('pace on foot is duration over distance, in the person units, rounded to whole seconds', () => {
  // 5 km in 25:35 is 5:07 per km.
  const run = { sport: 'Running', distance_m: 5000, duration_min: 25 + 35 / 60 };
  const p = paceOf(run, 'metric')!;
  assert.deepEqual(p.kind === 'pace' && [Math.round(p.seconds), p.per], [307, 'km']);
  assert.equal(formatPace(p), '5:07 /km');
  // The same run per mile: 25:35 over 3.107 mi is 8:14 per mile.
  assert.equal(formatPace(paceOf(run, 'imperial')!), '8:14 /mi');
  // A walk, 3.9 km in 45 min: 11:32 per km.
  assert.equal(formatPace(paceOf({ sport: 'Walking', distance_m: 3900, duration_min: 45 }, 'metric')!), '11:32 /km');
  // Database rows can hold the numbers as text.
  assert.equal(formatPace(paceOf({ sport: 'Running', distance_m: '5000' as unknown as number, duration_min: '30' as unknown as number }, 'metric')!), '6:00 /km');
});

test('seconds are rounded before splitting, so a pace never reads 5:60', () => {
  assert.equal(clockDuration(359.7), '6:00');
  assert.equal(clockDuration(359.4), '5:59');
  assert.equal(clockDuration(59.5), '1:00');
  assert.equal(clockDuration(3725), '1:02:05');
  assert.equal(formatPace({ kind: 'pace', seconds: 359.6, per: 'km' }), '6:00 /km');
});

test('minutes are rounded before splitting, so a duration never reads 60m or 1h 60m', () => {
  assert.equal(duration(59.6), '1h 00m');
  assert.equal(duration(119.7), '2h 00m');
  assert.equal(duration(59.4), '59m');
  assert.equal(duration(45.4), '45m');
  assert.equal(duration(61), '1h 01m');
  assert.equal(duration(0.3), '0m');
});

test('a ride gets speed, a swim pace per 100, other sports nothing', () => {
  // 30 km in 75 min is 24 km/h, or 14.9 mph.
  const ride = { sport: 'Cycling', distance_m: 30_000, duration_min: 75 };
  assert.equal(formatPace(paceOf(ride, 'metric')!), '24.0 km/h');
  assert.equal(formatPace(paceOf(ride, 'imperial')!), '14.9 mph');
  // A custom number format is used for the speed (the app passes its own).
  assert.equal(formatPace(paceOf(ride, 'metric')!, (v, d) => `${v.toFixed(d).replace('.', ',')}`), '24,0 km/h');
  // 1,500 m in 30 min is 2:00 per 100 m.
  assert.equal(formatPace(paceOf({ sport: 'Pool Swimming', distance_m: 1500, duration_min: 30 }, 'metric')!), '2:00 /100 m');
  assert.equal(formatPace(paceOf({ sport: 'Pool Swimming', distance_m: 1500, duration_min: 30 }, 'imperial')!), '1:50 /100 yd');
  assert.equal(paceOf({ sport: 'Yoga', distance_m: 100, duration_min: 30 }, 'metric'), null);
  assert.equal(paceOf({ sport: 'Traditional Strength Training', distance_m: null, duration_min: 50 }, 'metric'), null);
});

test('no pace without both figures, or when they cannot be a real session', () => {
  assert.equal(paceOf({ sport: 'Running', distance_m: null, duration_min: 30 }, 'metric'), null);
  assert.equal(paceOf({ sport: 'Running', distance_m: 0, duration_min: 30 }, 'metric'), null);
  assert.equal(paceOf({ sport: 'Running', distance_m: 5000, duration_min: 0 }, 'metric'), null);
  // 40 m logged over an hour (a slip), or 10 km in 5 minutes.
  assert.equal(paceOf({ sport: 'Walking', distance_m: 40, duration_min: 60 }, 'metric'), null);
  assert.equal(paceOf({ sport: 'Running', distance_m: 10_000, duration_min: 5 }, 'metric'), null);
  assert.equal(paceOf({ sport: 'Cycling', distance_m: 100_000, duration_min: 30 }, 'metric'), null);
});

test('distances read in km or miles, a swim in metres or yards', () => {
  assert.deepEqual(distanceIn(5210, 'metric', 'run'), { value: 5.21, unit: 'km', digits: 2 });
  const mi = distanceIn(16_093.44, 'imperial', 'run');
  assert.equal(mi.unit, 'mi');
  assert.ok(Math.abs(mi.value - 10) < 1e-9);
  assert.equal(mi.digits, 1);
  assert.deepEqual(distanceIn(1500, 'metric', 'swim'), { value: 1500, unit: 'm', digits: 0 });
  assert.equal(distanceIn(1500, 'imperial', 'swim').unit, 'yd');
  assert.equal(Math.round(distanceIn(1500, 'imperial', 'swim').value), 1640);
  assert.equal(distanceIn(120_000, 'metric', 'cycle').digits, 0);
});

test('numbers are read leniently: text, zero and missing all handled', () => {
  assert.equal(num('42.5'), 42.5);
  assert.equal(num(7), 7);
  assert.equal(num(0), null);
  assert.equal(num(null), null);
  assert.equal(num(undefined), null);
  assert.equal(num(''), null);
  assert.equal(num('abc'), null);
});

test('the latest workout is the last one finished, never one still to come', () => {
  const now = Date.parse('2026-10-22T19:00:00-05:00');
  const list = [
    // Later today: the demo adds an evening walk like this one.
    workout({ id: 'walk-later', sport: 'Walking', start: '2026-10-22T19:30:00-05:00', duration_min: 45 }),
    workout({ id: 'lift-now', sport: 'Weightlifting', start: '2026-10-22T18:30:00-05:00', duration_min: 60 }),
    workout({ id: 'run-noon', start: '2026-10-22T12:00:00-05:00', duration_min: 30 }),
    workout({ id: 'run-yesterday', start: '2026-10-21T18:30:00-05:00', duration_min: 30 }),
  ];
  assert.equal(latestWorkout(list, now)?.id, 'run-noon', 'the lifting session is still going');
  assert.equal(latestWorkout(list, Date.parse('2026-10-22T21:00:00-05:00'))?.id, 'walk-later');
  // A past page: everything has happened; the order given doesn't matter.
  assert.equal(latestWorkout([...list].reverse(), Date.parse('2026-11-01T00:00:00Z'))?.id, 'walk-later');
  assert.equal(latestWorkout([], now), null);
});

test('recent sessions are the same sport up to this one, oldest first, at most six', () => {
  const runs = Array.from({ length: 9 }, (_, i) => workout({ id: `run-${i}`, start: `2026-10-${String(10 + i).padStart(2, '0')}T07:00:00-05:00`, duration_min: 30 }));
  const other = [workout({ id: 'ride', sport: 'Cycling', start: '2026-10-15T07:00:00-05:00', duration_min: 60 }), workout({ id: 'run-caps', sport: 'running ', start: '2026-10-16T19:00:00-05:00', duration_min: 20 })];
  const list = [...runs, ...other].reverse();
  const at = runs[6]; // Oct 16, 07:00
  assert.equal(ids2(recentSessions(list, at)), 'run-1 run-2 run-3 run-4 run-5 run-6');
  // The name is matched without case or spaces around it.
  assert.equal(ids2(recentSessions(list, runs[8], 3)), 'run-caps run-7 run-8');
  // Two the same day are both kept, in time order.
  assert.deepEqual(ids(recentSessions(list, runs[7], 3)), ['run-6', 'run-caps', 'run-7']);
});

test('the bars compare distance when there is one, otherwise time', () => {
  const a = workout({ id: 'a', start: '2026-10-20T07:00:00Z', duration_min: 30, distance_m: 5000 });
  const b = workout({ id: 'b', start: '2026-10-21T07:00:00Z', duration_min: 30, distance_m: 6000 });
  const c = workout({ id: 'c', start: '2026-10-22T07:00:00Z', duration_min: 30, distance_m: null });
  assert.equal(barMetric([a, b], b), 'distance');
  assert.equal(barMetric([a, b, c], c), 'duration', 'this one has no distance');
  assert.equal(barMetric([c, { ...c, id: 'd' }, b], b), 'duration', 'most of the others have none');
  assert.equal(barMetric([a, c, b], b), 'distance');
});

test('suggestions follow the session: water after 45 min or high strain, protein after strength or an hour', () => {
  const at = (o: Partial<Workout>) => recoverySuggestions(workout({ id: 'w', start: '2026-10-22T07:00:00-05:00', duration_min: 30, ...o })).map((s) => s.id);
  // Short and easy: just the usual night's sleep.
  assert.deepEqual(at({}), ['sleep']);
  assert.deepEqual(at({ duration_min: 44 }), ['sleep']);
  assert.deepEqual(at({ duration_min: 45 }), ['water']);
  assert.deepEqual(at({ strain: 14.2 }), ['water']);
  assert.deepEqual(at({ strain: 13.9 }), ['sleep']);
  assert.deepEqual(at({ sport: 'Traditional Strength Training' }), ['protein']);
  assert.deepEqual(at({ duration_min: 60 }), ['water', 'protein']);
  assert.deepEqual(at({ duration_min: 95 }), ['water', 'protein', 'lighter']);
  assert.deepEqual(at({ strain: 18.4 }), ['water', 'lighter']);
  // Strain can arrive as text.
  assert.deepEqual(at({ strain: '15' as unknown as number }), ['water']);
});

test('an evening session ending at 20:00 or later (or past midnight) adds winding down', () => {
  const late = workout({ id: 'late', start: '2026-10-22T19:30:00-05:00', end: '2026-10-22T20:10:00-05:00', duration_min: 40 });
  const early = workout({ id: 'early', start: '2026-10-22T18:30:00-05:00', end: '2026-10-22T19:15:00-05:00', duration_min: 45 });
  const midnight = workout({ id: 'mid', start: '2026-10-22T23:30:00-05:00', end: '2026-10-23T00:20:00-05:00', duration_min: 50 });
  assert.ok(endsLate(late));
  assert.ok(!endsLate(early));
  assert.ok(endsLate(midnight));
  const s = recoverySuggestions(late);
  assert.deepEqual(
    s.map((x) => x.id),
    ['winddown'],
  );
  // The reason quotes the clock as recorded, not this computer's time zone.
  assert.equal(s[0].why, 'Ended at 20:10');
  assert.deepEqual(
    recoverySuggestions(early).map((x) => x.id),
    ['water'],
  );
});

test('suggestions are for a session that ended in the last few hours, by the real clock', () => {
  const w = workout({ id: 'run', start: '2026-10-22T07:00:00-05:00', end: '2026-10-22T07:45:00-05:00', duration_min: 45 });
  const end = Date.parse(w.end);
  const hour = 3_600_000;
  assert.ok(suggestionsApply(w, end + 2 * hour), 'two hours ago');
  assert.ok(suggestionsApply(w, end), 'just ended');
  assert.ok(suggestionsApply(w, end + SUGGESTION_HOURS * hour), 'at the edge of the window');
  assert.ok(!suggestionsApply(w, end + SUGGESTION_HOURS * hour + 60_000), 'just past it');
  // A past day's workout, looked at today: no "drink some water over the next hour".
  assert.ok(!suggestionsApply(w, Date.parse('2026-11-01T12:00:00-05:00')), 'ten days ago');
  // The day before's evening session still counts the next morning, whichever day the page shows.
  const evening = workout({ id: 'eve', start: '2026-10-21T19:00:00-05:00', end: '2026-10-21T20:00:00-05:00', duration_min: 60 });
  assert.ok(suggestionsApply(evening, Date.parse('2026-10-22T08:00:00-05:00')));
  // The clock is the ISO string's own offset, not this computer's time zone: 20:00 at -05:00 is 01:00Z.
  assert.ok(suggestionsApply(evening, Date.parse('2026-10-22T02:00:00Z')));
  // Not one still going, and not one without a readable end.
  assert.ok(!suggestionsApply(w, end - 60_000));
  assert.ok(!suggestionsApply({ end: '' }, end));
  assert.ok(!suggestionsApply({ end: 'not a time' }, end));
});

test('every suggestion says why, and none reads as a prescription or a diagnosis', () => {
  const all = [
    workout({ id: 'a', start: '2026-10-22T19:30:00-05:00', end: '2026-10-22T21:30:00-05:00', duration_min: 120, strain: 19, sport: 'Weightlifting' }),
    workout({ id: 'b', start: '2026-10-22T07:00:00-05:00', duration_min: 20 }),
  ].flatMap(recoverySuggestions);
  assert.deepEqual(new Set(all.map((s) => s.id)), new Set(['water', 'protein', 'winddown', 'lighter', 'sleep']));
  for (const s of all) {
    assert.ok(s.text.length > 0 && s.why.length > 0, s.id);
    assert.doesNotMatch(`${s.text} ${s.why}`, /\b(must|should|optimal|diagnos|treat|dehydrat|injur|you need)\b/i, s.id);
  }
});

test('ticks are kept per person, workout and day, in one small entry, pruned to the latest', () => {
  const k1 = tickKey('u1', 'w1', '2026-10-22');
  const k2 = tickKey('u2', 'w1', '2026-10-22');
  let raw: string | null = null;
  raw = writeTicks(raw, k1, ['water', 'protein', 'water'], 1);
  assert.deepEqual(readTicks(raw, k1), ['water', 'protein']);
  assert.deepEqual(readTicks(raw, k2), [], "another person's ticks are their own");
  assert.deepEqual(readTicks(raw, tickKey('u1', 'w1', '2026-10-23')), [], 'a new day starts clear');
  raw = writeTicks(raw, k1, [], 2);
  assert.equal(raw, '{}', 'unticking everything leaves nothing behind');
  // Only ids are stored: no figures.
  raw = writeTicks(null, k1, ['water'], 3);
  assert.equal(raw, JSON.stringify({ 'u1|w1|2026-10-22': { ids: ['water'], at: 3 } }));
  // At most 20 workout-days are kept, the most recent.
  for (let i = 0; i < 25; i++) raw = writeTicks(raw, tickKey('u1', `w${i}`, '2026-10-22'), ['sleep'], 10 + i);
  const kept = Object.keys(JSON.parse(raw));
  assert.equal(kept.length, 20);
  assert.ok(kept.includes(tickKey('u1', 'w24', '2026-10-22')));
  assert.ok(!kept.includes(k1));
});

test('stored ticks that are missing or broken read as none', () => {
  const k = tickKey('u', 'w', '2026-10-22');
  assert.deepEqual(readTicks(null, k), []);
  assert.deepEqual(readTicks('not json', k), []);
  assert.deepEqual(readTicks('[1,2]', k), []);
  assert.deepEqual(readTicks(JSON.stringify({ [k]: { ids: ['water', 3, null] } }), k), ['water']);
  assert.deepEqual(readTicks(JSON.stringify({ [k]: 'water' }), k), []);
  // Writing over a broken entry starts again.
  assert.deepEqual(readTicks(writeTicks('not json', k, ['sleep'], 1), k), ['sleep']);
});
