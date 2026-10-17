// Steps from more than one device: WHOOP's API count per cycle (falling asleep to falling asleep), and Apple's
// calendar day (iPhone, Watch, or WHOOP's copy in Health). They count the same walking and are never added.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Readable } from 'node:stream';
import { parseStream } from '../server/apple/import.ts';
import { pickSteps } from '../server/query.ts';
import { openStore } from '../server/store.ts';
import { mapWhoop, storeCycleSteps } from '../server/whoop.ts';

const cycle = (id: number, start: string, step_count: number | null | undefined, opts: { scored?: boolean; end?: string | null } = {}) => ({
  id,
  start,
  end: opts.end === undefined ? null : opts.end,
  timezone_offset: '-05:00',
  score_state: opts.scored === false ? 'PENDING_SCORE' : 'SCORED',
  ...(opts.scored === false ? {} : { score: { strain: 10, kilojoule: 8000, average_heart_rate: 70, max_heart_rate: 150 } }),
  ...(step_count !== undefined ? { step_count } : {}),
});
const sleep = (cycleId: number, start: string, end: string, nap = false) => ({ id: `s${cycleId}`, cycle_id: cycleId, start, end, timezone_offset: '-05:00', nap, score_state: 'PENDING_SCORE' });
const NOW = Date.parse('2026-10-17T18:00:00Z');
const steps = (cycles: ReturnType<typeof cycle>[], sleeps: ReturnType<typeof sleep>[] = []) =>
  mapWhoop({ cycles, sleeps: sleeps as never, recoveries: [], workouts: [] }, NOW).cycleSteps;

test("a WHOOP cycle's steps go on the day you woke up, and nothing is added to the daily rows directly", () => {
  // Fell asleep 23:30 Chicago on Oct 15, woke 07:00 Oct 16: Oct 16's walking.
  const mapped = mapWhoop({ cycles: [cycle(1, '2026-10-16T04:30:00.000Z', 8234, { end: '2026-10-17T04:00:00.000Z' })], sleeps: [sleep(1, '2026-10-16T04:30:00.000Z', '2026-10-16T12:00:00.000Z')] as never, recoveries: [], workouts: [] }, NOW);
  assert.deepEqual(mapped.cycleSteps, [{ cycleId: 1, date: '2026-10-16', steps: 8234 }]);
  assert.equal(mapped.daily.find((d) => d.metric === 'steps'), undefined);
});

test('an early bedtime (asleep at 17:00) still dates the cycle by the morning you woke', () => {
  // Oct 15: asleep 17:00 local (22:00Z), woke 07:00 Oct 16 local. Without the wake-up this would be Oct 15.
  const [c] = steps([cycle(2, '2026-10-15T22:00:00.000Z', 6100, { end: '2026-10-17T03:00:00.000Z' })], [sleep(2, '2026-10-15T22:00:00.000Z', '2026-10-16T12:00:00.000Z')]);
  assert.equal(c.date, '2026-10-16');
});

test("the current cycle reports today's steps so far", () => {
  const [c] = steps([cycle(3, '2026-10-17T05:00:00.000Z', 1520, { scored: false })]);
  assert.deepEqual(c, { cycleId: 3, date: '2026-10-17', steps: 1520 });
});

test("a cycle over 28 hours (the strap was off overnight) spans two days, so its steps aren't used", () => {
  const ended = steps([cycle(4, '2026-10-15T04:30:00.000Z', 17000, { end: '2026-10-17T04:00:00.000Z' })]);
  const open = steps([cycle(5, '2026-10-16T04:00:00.000Z', 15000)]); // still open 38 h later
  assert.equal(ended[0].steps, null);
  assert.equal(open[0].steps, null);
});

test('no step count (the strap was off, or a cycle from before WHOOP reported steps) gives nothing to store', () => {
  assert.deepEqual(steps([cycle(6, '2026-10-16T04:30:00.000Z', null, { end: '2026-10-17T04:00:00.000Z' }), cycle(7, '2026-09-01T04:30:00.000Z', undefined, { end: '2026-09-02T04:00:00.000Z' })]).map((c) => c.steps), [null, null]);
});

test("a day's WHOOP steps are rebuilt from every stored cycle, so a partial batch can't shrink the total", async () => {
  const db = await openStore();
  const day = async () => (await db.query<{ value: number }>("SELECT value FROM daily WHERE user_id = 'u' AND metric = 'steps' AND source = 'whoop' AND date = '2026-10-16'"))[0]?.value;
  await storeCycleSteps(db, 'u', [
    { cycleId: 1, date: '2026-10-16', steps: 3000 },
    { cycleId: 2, date: '2026-10-16', steps: 2500 },
  ]);
  assert.equal(await day(), 5500, 'two cycles on one day add up');
  await storeCycleSteps(db, 'u', [{ cycleId: 2, date: '2026-10-16', steps: 2500 }]);
  assert.equal(await day(), 5500, 'a later window that only sees cycle 2 keeps the total');
  await storeCycleSteps(db, 'u', [{ cycleId: 2, date: '2026-10-16', steps: 2600 }]);
  assert.equal(await day(), 5600, "an updated count (the current cycle) replaces that cycle's share");
  await storeCycleSteps(db, 'u', [{ cycleId: 2, date: '2026-10-17', steps: 2600 }]);
  assert.equal(await day(), 3000, 'a re-dated cycle leaves its old day');
  await storeCycleSteps(db, 'u', [{ cycleId: 1, date: '2026-10-16', steps: null }]);
  assert.equal(await day(), undefined, 'a day with no usable cycles has no WHOOP row');
  await db.close();
});

test("a day's steps: Apple's calendar day, unless WHOOP's count is clearly larger", () => {
  const p = (apple?: number, whoop?: number) =>
    pickSteps(apple === undefined ? undefined : { source: 'apple', value: apple }, whoop === undefined ? undefined : { source: 'whoop', value: whoop })?.source;
  assert.equal(p(2100, 9400), 'whoop', 'wore WHOOP, phone on the desk');
  assert.equal(p(7800, 1200), 'apple', 'strap charging, phone in the pocket');
  assert.equal(p(8000, 9200), 'apple', "close: the same walking over a different window; the calendar day wins (late-night steps aren't counted twice)");
  assert.equal(p(2626, 3373), 'apple', 'over 20% higher but under 1,000 more');
  assert.equal(p(2128, 3641), 'whoop');
  assert.equal(p(undefined, 5000), 'whoop');
  assert.equal(p(6000, undefined), 'apple');
});

test("in a Health export, WHOOP's steps compete with the iPhone's for the day; its other data is still skipped", async () => {
  const rec = (source: string, start: string, end: string, value: number) =>
    `<Record type="HKQuantityTypeIdentifierStepCount" sourceName="${source}" unit="count" startDate="2026-10-16 ${start} -0500" endDate="2026-10-16 ${end} -0500" value="${value}"/>`;
  const xml = `<?xml version="1.0"?><HealthData>
    ${rec('Sami’s iPhone', '09:00:00', '09:10:00', 400)}
    ${rec('Sami’s iPhone', '17:00:00', '17:10:00', 600)}
    ${rec('WHOOP', '08:00:00', '09:00:00', 2500)}
    ${rec('WHOOP', '12:00:00', '13:00:00', 3000)}
    ${rec('WHOOP', '17:00:00', '18:00:00', 1800)}
    <Record type="HKQuantityTypeIdentifierRestingHeartRate" sourceName="WHOOP" unit="count/min" startDate="2026-10-16 00:00:00 -0500" endDate="2026-10-16 00:00:00 -0500" value="52"/>
  </HealthData>`;
  const agg = await parseStream(Readable.from([Buffer.from(xml)]));
  const { daily, hourly } = agg.finish();
  const steps = daily.filter((d) => d.metric === 'steps');
  assert.deepEqual(steps.map((d) => d.value), [7300], "WHOOP's 7,300 beats the iPhone's 1,000; nothing is added together");
  assert.equal(daily.find((d) => d.metric === 'resting_hr'), undefined, "WHOOP's other copies stay skipped");
  assert.equal(agg.skipped, 1);
  // The day's hours follow the device that won the day, so the Day view adds up to the day's total.
  const hours = hourly.filter((h) => h.metric === 'steps');
  assert.deepEqual(
    hours.map((h) => [h.hour, h.value]).sort((a, b) => a[0] - b[0]),
    [
      [8, 2500],
      [12, 3000],
      [17, 1800],
    ],
  );
});
