// Sleep timing and patterns: bed and wake times from sleep events, how steady they are and the sleep debt,
// and the correlational patterns over 180 days, with their guards and wording. Also both routes over HTTP.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { AddressInfo } from 'node:net';
import type { Pattern, Settings, Workout } from '../shared/types.ts';
import { createApp } from '../server/app.ts';
import { addDays, todayLocal } from '../server/dates.ts';
import { type DailyRow, type EventRow, OWNER_ID, upsertDaily, upsertEvents, upsertWorkouts } from '../server/db.ts';
import { findPatterns, patterns, sleepTiming } from '../server/insights.ts';
import type { Ctx } from '../server/query.ts';
import { openStore } from '../server/store.ts';

// Open mode (no session secret): requests act as the local owner.
delete process.env.SESSION_SECRET;

const db = await openStore();
// People other than the owner never see demo data, so their rows are read as stored.
const scopeOf = (userId: string) => ({ db, userId });
const today = todayLocal();
const ago = (n: number) => addDays(today, -n);

const sampleSd = (xs: number[]) => {
  const m = xs.reduce((a, b) => a + b, 0) / xs.length;
  return Math.sqrt(xs.reduce((a, x) => a + (x - m) ** 2, 0) / (xs.length - 1));
};
const avg = (xs: number[]) => xs.reduce((a, b) => a + b, 0) / xs.length;
const isWeekend = (date: string) => [0, 6].includes(new Date(`${date}T00:00:00Z`).getUTCDay());
/** "HH:MM" on a date at UTC-5, as the importers write it. */
const at = (date: string, hhmm: string, offset = '-05:00') => `${date}T${hhmm}:00${offset}`;
const sleepEvent = (id: string, source: string, date: string, start: string, end: string, kind: EventRow['kind'] = 'sleep'): EventRow => ({
  id,
  source,
  kind,
  title: kind === 'nap' ? 'Nap' : 'Sleep',
  start,
  end,
  date,
});

// ---------- sleep timing ----------

test('bed, wake and midpoint read the local wall clock in each timestamp’s own offset', async () => {
  const scope = scopeOf('clock');
  await upsertEvents(db, scope.userId, [
    sleepEvent('a', 'apple', ago(1), at(ago(2), '23:30', '+02:00'), at(ago(1), '07:10', '+02:00')),
    sleepEvent('b', 'whoop', ago(0), at(ago(0), '01:10', '-07:00'), at(ago(0), '08:00', '-07:00')),
  ]);
  const { nights, stats } = await sleepTiming(scope, false, 30);
  assert.deepEqual(
    nights.map((n) => [n.date, n.bedMin, n.wakeMin, n.midMin, n.hours, n.weekend]),
    [
      [ago(1), 330, 430, 330 + 230, 7.67, isWeekend(ago(1))],
      [ago(0), 430, 480, 430 + 205, 6.83, isWeekend(ago(0))],
    ],
  );
  assert.equal(nights[0].bed, at(ago(2), '23:30', '+02:00'));
  // Too few nights for a spread, a sleep need or a debt.
  assert.deepEqual([stats.nights, stats.bedSd, stats.wakeSd, stats.need, stats.debt, stats.debtNights], [2, null, null, null, null, 0]);
});

/** Weekday nights 23:00–07:00 give or take, weekend nights 00:30–09:00; sleep_hours 8 except the last week. */
const LAST_WEEK = [7, 8, 6.5, 9, 7.5, 8, 8];
function regularSleeper() {
  const events: EventRow[] = [];
  const daily: DailyRow[] = [];
  const expected: { date: string; bedMin: number; wakeMin: number; midMin: number }[] = [];
  for (let i = 0; i < 90; i++) {
    const date = ago(i);
    if (isWeekend(date)) {
      events.push(sleepEvent(`s${i}`, 'apple', date, at(date, '00:30'), at(date, '09:00')));
      expected.push({ date, bedMin: 390, wakeMin: 540, midMin: 390 + 255 });
    } else {
      const k = i % 3;
      const bed = 23 * 60 + k * 20;
      const wake = 7 * 60 + k * 10;
      const clock = (m: number) => `${String(Math.floor(m / 60) % 24).padStart(2, '0')}:${String(m % 60).padStart(2, '0')}`;
      events.push(sleepEvent(`s${i}`, 'apple', date, at(addDays(date, -1), clock(bed)), at(date, clock(wake))));
      const bedMin = bed - 18 * 60;
      expected.push({ date, bedMin, wakeMin: wake, midMin: bedMin + (wake + 24 * 60 - bed) / 2 });
    }
    daily.push({ date, metric: 'sleep_hours', source: 'apple', value: i < 7 ? LAST_WEEK[i] : 8 });
  }
  return { events, daily, expected: expected.reverse() };
}

test('one night per wake date, the longest sleep from any device; naps never count', async () => {
  const scope = scopeOf('regular');
  const { events, daily, expected } = regularSleeper();
  await upsertEvents(db, scope.userId, [
    ...events,
    // A shorter night from WHOOP for the same date loses to Apple's; a long nap isn't a night.
    sleepEvent('w3', 'whoop', ago(3), at(ago(3), '01:00'), at(ago(3), '06:00')),
    sleepEvent('nap5', 'apple', ago(5), at(ago(5), '09:30'), at(ago(5), '21:30'), 'nap'),
  ]);
  await upsertDaily(db, scope.userId, daily);
  const { nights } = await sleepTiming(scope, false, 30);
  assert.equal(nights.length, 30);
  assert.deepEqual(
    nights.map((n) => ({ date: n.date, bedMin: n.bedMin, wakeMin: n.wakeMin, midMin: n.midMin })),
    expected.slice(-30),
  );
  assert.ok(nights.every((n, i) => i === 0 || n.date > nights[i - 1].date), 'oldest first');
  assert.equal(nights.at(-1)!.hours, LAST_WEEK[0], "the day's sleep_hours when there is one");
  assert.ok(nights.every((n) => n.weekend === isWeekend(n.date)));
});

test('spread, weekend shift, sleep need and the last week’s debt', async () => {
  const { stats, nights } = await sleepTiming(scopeOf('regular'), false, 30);
  const { expected } = regularSleeper();
  const window = expected.slice(-30);
  assert.equal(stats.nights, 30);
  assert.equal(stats.avgBedMin, Math.round(avg(window.map((n) => n.bedMin))));
  assert.equal(stats.avgWakeMin, Math.round(avg(window.map((n) => n.wakeMin))));
  assert.equal(stats.bedSd, Math.round(sampleSd(window.map((n) => n.bedMin))));
  assert.equal(stats.wakeSd, Math.round(sampleSd(window.map((n) => n.wakeMin))));
  const weekday = avg(window.filter((n) => !isWeekend(n.date)).map((n) => n.midMin));
  assert.equal(stats.midWeekday, Math.round(weekday));
  assert.equal(stats.midWeekend, 645);
  assert.equal(stats.socialJetlag, Math.round(645 - weekday));
  assert.ok(stats.socialJetlag! > 60, 'weekend nights sit later');
  // The need looks back 60 nights even when 30 days were asked for: median 8 h.
  assert.equal(stats.need, 8);
  // Short by 1, 1.5 and 0.5 h on three of the last seven nights; nights over the need don't pay it back.
  assert.equal(stats.debt, 3);
  assert.equal(stats.debtNights, 7);
  assert.equal(nights.length, 30);
});

test('the sleep need stays within 7–9 hours and needs two weeks of nights', async () => {
  const seed = async (userId: string, nights: number, hours: number) => {
    const dates = Array.from({ length: nights }, (_, i) => ago(i));
    await upsertEvents(
      db,
      userId,
      dates.map((d) => sleepEvent(`${userId}-${d}`, 'whoop', d, at(addDays(d, -1), '23:00'), at(d, '07:00'))),
    );
    await upsertDaily(
      db,
      userId,
      dates.map((date) => ({ date, metric: 'sleep_hours', source: 'whoop', value: hours })),
    );
    return (await sleepTiming(scopeOf(userId), false, 30)).stats;
  };
  const short = await seed('short', 20, 6);
  assert.deepEqual([short.need, short.debt, short.debtNights], [7, 7, 7], 'a 6 h median still needs 7 h');
  const long = await seed('long', 20, 10);
  assert.deepEqual([long.need, long.debt, long.debtNights], [9, 0, 7]);
  const fresh = await seed('fresh', 13, 6);
  assert.deepEqual([fresh.need, fresh.debt, fresh.debtNights], [null, null, 0]);
});

test('a debt counts only nights in the last seven days, not the last seven nights on record', async () => {
  const userId = 'gap';
  // 20 nights ending ten days ago, then nothing.
  const dates = Array.from({ length: 20 }, (_, i) => ago(i + 10));
  await upsertEvents(
    db,
    userId,
    dates.map((d) => sleepEvent(`${userId}-${d}`, 'apple', d, at(addDays(d, -1), '23:00'), at(d, '06:00'))),
  );
  const { stats } = await sleepTiming(scopeOf(userId), false, 30);
  assert.equal(stats.need, 7);
  assert.deepEqual([stats.debt, stats.debtNights], [0, 0]);
});

// ---------- patterns ----------

const START = '2026-01-01';
const END = addDays(START, 179);
const SETTINGS: Settings = { name: '', stepGoal: 10_000, units: 'metric', demo: 'off', timeZone: null, sex: null, cycleTracking: false };

type Row = [metric: string, date: string, value: number, source?: string];
function ctxOf(rows: Row[], workouts: Workout[] = []): Ctx {
  const daily: Ctx['daily'] = new Map();
  for (const [m, d, v, s = 'apple'] of rows) {
    if (!daily.has(m)) daily.set(m, new Map());
    if (!daily.get(m)!.has(s)) daily.get(m)!.set(s, new Map());
    daily.get(m)!.get(s)!.set(d, v);
  }
  return { settings: SETTINGS, demo: false, today: END, daily, workouts, sleepStarts: [] };
}

const workout = (date: string, endsAt: string): Workout => ({
  id: `w-${date}`,
  source: 'apple',
  sport: 'Running',
  start: at(date, '17:00'),
  end: endsAt.length === 5 ? at(date, endsAt) : endsAt,
  date,
  duration_min: 45,
  energy_kcal: null,
  distance_m: null,
  avg_hr: null,
  max_hr: null,
  strain: null,
});

/** ±amp, alternating every four days, so each group's mean stays (all but) exactly its set value. */
const wobble = (i: number, amp: number) => (Math.floor(i / 4) % 2 ? amp : -amp);

type Case = {
  id: string;
  /** Rows (and workouts, mindful days) for day i, which meets the rule's condition or not. */
  day: (i: number, d: string, yes: boolean, flip: boolean) => { rows: Row[]; workout?: Workout; mindful?: boolean };
  sign: number;
  unit: Pattern['unit'];
};
const next = (d: string) => addDays(d, 1);
const CASES: Case[] = [
  {
    id: 'steps_sleep',
    sign: 1,
    unit: 'min',
    day: (i, d, yes, flip) => ({ rows: [['steps', d, yes ? 12_000 : 6_000], ['sleep_hours', next(d), (yes !== flip ? 7.8 : 7.2) + wobble(i, 0.1)]] }),
  },
  {
    id: 'late_workout_hrv',
    sign: -1,
    unit: '%',
    day: (i, d, yes, flip) => ({ rows: [['hrv_rmssd', next(d), (yes !== flip ? 54 : 60) + wobble(i, 1)]], workout: workout(d, yes ? '20:30' : '18:00') }),
  },
  {
    id: 'short_sleep_rhr',
    sign: 1,
    unit: 'bpm',
    day: (i, d, yes, flip) => ({ rows: [['sleep_hours', d, yes ? 5.5 : 7.5], ['resting_hr', d, (yes !== flip ? 58 : 55) + wobble(i, 0.5)]] }),
  },
  {
    id: 'strain_recovery',
    sign: -1,
    unit: 'points',
    day: (i, d, yes, flip) => ({ rows: [['strain', d, yes ? 15 : 8, 'whoop'], ['recovery', next(d), (yes !== flip ? 50 : 66) + wobble(i, 2), 'whoop']] }),
  },
  {
    id: 'caffeine_sleep',
    sign: -1,
    unit: 'min',
    day: (i, d, yes, flip) => ({ rows: [['caffeine_mg', d, yes ? 250 : 50], ['sleep_hours', next(d), (yes !== flip ? 6.9 : 7.5) + wobble(i, 0.1)]] }),
  },
  {
    id: 'daylight_sleep',
    sign: 1,
    unit: 'min',
    day: (i, d, yes, flip) => ({ rows: [['daylight_min', d, yes ? 45 : 5], ['sleep_hours', next(d), (yes !== flip ? 7.6 : 7.1) + wobble(i, 0.1)]] }),
  },
  {
    id: 'mindful_hrv',
    sign: 1,
    unit: '%',
    day: (i, d, yes, flip) => ({ rows: [['hrv_rmssd', next(d), (yes !== flip ? 66 : 60) + wobble(i, 1)]], mindful: yes }),
  },
];

/** 180 days of one rule's data, `yesDays` of them meeting its condition (every fourth day until used up). */
function scenario(c: Case, yesDays: number, flip = false) {
  const rows: Row[] = [];
  const workouts: Workout[] = [];
  const mindful = new Set<string>();
  let used = 0;
  for (let i = 0; i < 180; i++) {
    const d = addDays(START, i);
    const yes = i % 4 === 0 && used < yesDays;
    if (yes) used++;
    const out = c.day(i, d, yes, flip);
    rows.push(...out.rows);
    if (out.workout) workouts.push(out.workout);
    if (out.mindful) mindful.add(d);
  }
  return findPatterns(ctxOf(rows, workouts), mindful, START, END);
}

for (const c of CASES) {
  test(`${c.id}: shows with 8+ days in each group, and not with fewer`, () => {
    const found = scenario(c, 20).find((p) => p.id === c.id);
    assert.ok(found, `${c.id} should show`);
    assert.equal(Math.sign(found.effect), c.sign);
    assert.equal(found.unit, c.unit);
    assert.equal(found.n, 20, 'n is the smaller group');
    assert.match(found.detail, /^Based on 20 \w+ .*last 180 days\.$/);
    assert.equal(
      scenario(c, 7).find((p) => p.id === c.id),
      undefined,
      `${c.id} needs 8 days`,
    );
    // The other direction says the opposite.
    const flipped = scenario(c, 20, true).find((p) => p.id === c.id);
    assert.ok(flipped);
    assert.equal(Math.sign(flipped.effect), -c.sign);
  });
}

test('effect sizes are in each rule’s unit: minutes, percent, bpm, points', () => {
  const effect = (id: string) => scenario(CASES.find((c) => c.id === id)!, 20).find((p) => p.id === id)!.effect;
  assert.equal(effect('steps_sleep'), 36);
  assert.equal(effect('late_workout_hrv'), -10);
  assert.equal(effect('short_sleep_rhr'), 3);
  assert.equal(effect('strain_recovery'), -16);
  assert.equal(effect('mindful_hrv'), 10);
});

test('a difference under the rule’s minimum, or small against the day-to-day spread, is left out', () => {
  const steps = (yesSleep: number, amp: number): Case => ({
    ...CASES[0],
    day: (i, d, yes) => ({ rows: [['steps', d, yes ? 12_000 : 6_000], ['sleep_hours', next(d), (yes ? yesSleep : 7.2) + wobble(i, amp)]] }),
  });
  assert.ok(scenario(steps(7.6, 0.1), 20).some((p) => p.id === 'steps_sleep'), '24 min, steady nights: shown');
  assert.ok(!scenario(steps(7.3, 0.01), 20).some((p) => p.id === 'steps_sleep'), '6 min is under the 10 min minimum');
  assert.ok(!scenario(steps(7.6, 2), 20).some((p) => p.id === 'steps_sleep'), '24 min against nights that swing ±2 h');
});

test('short_sleep_rhr reads resting heart rate from one device, so a strap worn only some nights reads as no change', () => {
  // The Watch logs every day (+3 bpm after short nights). WHOOP, ~7 bpm lower, only shows up on some long nights:
  // blending would compare the Watch's short nights with WHOOP's long ones and report ~10 bpm.
  const mixed: Case = {
    ...CASES.find((c) => c.id === 'short_sleep_rhr')!,
    day: (i, d, yes) => ({
      rows: [
        ['sleep_hours', d, yes ? 5.5 : 7.5],
        ['resting_hr', d, (yes ? 58 : 55) + wobble(i, 0.5)],
        ...(!yes && i % 3 === 0 ? ([['resting_hr', d, 48, 'whoop']] as Row[]) : []),
      ],
    }),
  };
  assert.equal(scenario(mixed, 20).find((p) => p.id === 'short_sleep_rhr')?.effect, 3);
});

const CAUSAL = /\b(lowers?|raises?|causes?|improves?|reduces?|increases?|boosts?|hurts?)\b/i;

test('pattern wording is correlational: it says what tends to go together, never what causes what', () => {
  const all = CASES.flatMap((c) => [...scenario(c, 20), ...scenario(c, 20, true)]);
  assert.equal(new Set(all.map((p) => `${p.id}${Math.sign(p.effect)}`)).size, CASES.length * 2, 'every rule, both directions');
  for (const p of all) {
    assert.doesNotMatch(p.text, CAUSAL, p.text);
    assert.doesNotMatch(p.detail, CAUSAL, p.detail);
    assert.match(p.text, /tend/, p.text);
    assert.ok(p.text.includes(`${Math.abs(p.effect)}${p.unit === '%' ? '%' : ` ${p.unit}`}`), p.text);
  }
});

/**
 * All seven rules at once, each in its own stretch of the 180 days (or on its own metrics), with the
 * daylight one clearly the weakest.
 */
function everything(end: string) {
  const start = addDays(end, -179);
  const rows: Row[] = [];
  const workouts: Workout[] = [];
  const mindful: string[] = [];
  for (let i = 0; i < 180; i++) {
    const d = addDays(start, i);
    const yes = i % 3 === 0;
    const last = i === 179;
    if (i < 45) rows.push(['steps', d, yes ? 12_000 : 6_000], ['sleep_hours', next(d), (yes ? 7.9 : 7.2) + wobble(i, 0.1)]);
    else if (i < 90) rows.push(['caffeine_mg', d, yes ? 250 : 50], ['sleep_hours', next(d), (yes ? 6.8 : 7.5) + wobble(i, 0.1)]);
    else if (i < 135) rows.push(['daylight_min', d, yes ? 45 : 5], ['sleep_hours', next(d), (yes ? 7.38 : 7.15) + wobble(i, 0.1)]);
    else if (i > 135) rows.push(['sleep_hours', d, yes ? 5.5 : 7.5], ['resting_hr', d, (yes ? 59 : 55) + wobble(i, 0.5)]);
    if (i < 90) {
      workouts.push(workout(d, yes ? '21:00' : '17:45'));
      rows.push(['hrv_rmssd', next(d), (yes ? 52 : 60) + wobble(i, 1)]);
    } else if (!last) {
      if (yes) mindful.push(d);
      rows.push(['hrv_rmssd', next(d), (yes ? 70 : 60) + wobble(i, 1)]);
    }
    rows.push(['strain', d, yes ? 15 : 8, 'whoop']);
    if (!last) rows.push(['recovery', next(d), (yes ? 50 : 66) + wobble(i, 2), 'whoop']);
  }
  return { start, rows, workouts, mindful };
}

test('at most six patterns, strongest first', async () => {
  const end = ago(1);
  const { start, rows, workouts, mindful } = everything(end);
  const every = findPatterns(ctxOf(rows, workouts), new Set(mindful), start, end);
  assert.equal(every.length, 7);
  assert.equal(every.at(-1)!.id, 'daylight_sleep');

  const userId = 'patterns';
  await upsertDaily(
    db,
    userId,
    rows.map(([metric, date, value, source = 'apple']) => ({ metric, date, value, source })),
  );
  await upsertWorkouts(db, userId, workouts);
  await upsertEvents(
    db,
    userId,
    mindful.map((d) => ({ id: `m-${d}`, source: 'apple', kind: 'mindful' as const, title: 'Mindful', start: at(d, '07:00'), end: at(d, '07:10'), date: d })),
  );
  const out = await patterns(scopeOf(userId), false);
  assert.deepEqual([out.start, out.end], [start, end], '180 days to the latest data date');
  assert.equal(out.patterns.length, 6);
  assert.deepEqual(
    out.patterns.map((p) => p.id),
    every.slice(0, 6).map((p) => p.id),
  );
  assert.ok(!out.patterns.some((p) => p.id === 'daylight_sleep'));
});

test('without enough data there are no patterns, and nothing breaks', async () => {
  const out = await patterns(scopeOf('nobody'), false);
  assert.deepEqual(out, { start: addDays(today, -179), end: today, patterns: [] });
  assert.deepEqual(findPatterns(ctxOf([]), new Set(), START, END), []);
});

// ---------- over HTTP ----------

const app = createApp({ db, hosted: false });
const server = app.listen(0, '127.0.0.1');
await new Promise((r) => server.once('listening', r));
const base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
test.after(() => {
  server.close();
});
const get = async (p: string) => {
  const res = await fetch(base + p);
  return { status: res.status, json: await res.json() };
};

test('GET /api/sleep keeps days between 7 and 365; GET /api/patterns answers for the signed-in person', async () => {
  // Real (non-demo) data for the owner: 400 nights.
  const dates = Array.from({ length: 400 }, (_, i) => ago(i));
  await upsertEvents(
    db,
    OWNER_ID,
    dates.map((d) => sleepEvent(`o-${d}`, 'apple', d, at(addDays(d, -1), '23:15'), at(d, '07:05'))),
  );
  await upsertDaily(db, OWNER_ID, [{ date: today, metric: 'steps', source: 'apple', value: 5000 }]);

  const def = await get('/api/sleep');
  assert.equal(def.status, 200);
  assert.equal(def.json.nights.length, 30);
  assert.equal(def.json.stats.avgBedMin, 315);
  assert.equal(def.json.stats.bedSd, 0);
  assert.equal((await get('/api/sleep?days=2')).json.nights.length, 7);
  assert.equal((await get('/api/sleep?days=5000')).json.nights.length, 365);

  const p = await get('/api/patterns');
  assert.equal(p.status, 200);
  assert.deepEqual(p.json, { start: addDays(today, -179), end: today, patterns: [] });
});
