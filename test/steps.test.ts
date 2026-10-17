// Steps from more than one device: WHOOP's cycle step count, and Apple's (iPhone, Watch, or WHOOP's copy in
// Health). They count the same walking, so a day keeps the higher count and never the sum.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Readable } from 'node:stream';
import { parseStream } from '../server/apple/import.ts';
import { valueOn } from '../server/query.ts';
import { mapWhoop } from '../server/whoop.ts';

const cycle = (id: number, start: string, step_count: number | null | undefined, scored = true) => ({
  id,
  start,
  end: null,
  timezone_offset: '-05:00',
  score_state: scored ? 'SCORED' : 'PENDING_SCORE',
  ...(scored ? { score: { strain: 10, kilojoule: 8000, average_heart_rate: 70, max_heart_rate: 150 } } : {}),
  ...(step_count !== undefined ? { step_count } : {}),
});
const whoopSteps = (cycles: ReturnType<typeof cycle>[]) =>
  mapWhoop({ cycles, sleeps: [], recoveries: [], workouts: [] }).daily.filter((d) => d.metric === 'steps');

test("WHOOP's cycle step count becomes that day's WHOOP steps", () => {
  // Fell asleep 23:30 Chicago on Oct 15: the cycle is Oct 16's day, and its steps are Oct 16's walking.
  assert.deepEqual(whoopSteps([cycle(1, '2026-10-16T04:30:00.000Z', 8234)]), [{ date: '2026-10-16', metric: 'steps', source: 'whoop', value: 8234 }]);
});

test("the current, unscored cycle still reports today's steps so far", () => {
  assert.equal(whoopSteps([cycle(2, '2026-10-17T05:00:00.000Z', 1520, false)])[0]?.value, 1520);
});

test('no step count (the strap was off, or a cycle from before WHOOP reported steps) stores nothing', () => {
  assert.deepEqual(whoopSteps([cycle(3, '2026-10-16T04:30:00.000Z', null), cycle(4, '2026-09-01T04:30:00.000Z', undefined)]), []);
});

test('two cycles on one day (a split night) add their steps', () => {
  const rows = whoopSteps([cycle(5, '2026-10-16T04:30:00.000Z', 3000), cycle(6, '2026-10-16T14:00:00.000Z', 2500)]);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].value, 5500);
});

const snapshot = (apple: number | undefined, whoop: number | undefined) => {
  const bySource = new Map<string, Map<string, number>>();
  if (apple !== undefined) bySource.set('apple', new Map([['2026-10-16', apple]]));
  if (whoop !== undefined) bySource.set('whoop', new Map([['2026-10-16', whoop]]));
  return { daily: new Map([['steps', bySource]]), demo: false } as unknown as Parameters<typeof valueOn>[0];
};

test('a day takes the higher of Apple and WHOOP, never the sum', () => {
  // Wore WHOOP all day, phone mostly on the desk.
  assert.deepEqual(valueOn(snapshot(2100, 9400), 'steps', '2026-10-16'), { source: 'whoop', value: 9400 });
  // WHOOP charging most of the day, phone in the pocket.
  assert.deepEqual(valueOn(snapshot(7800, 1200), 'steps', '2026-10-16'), { source: 'apple', value: 7800 });
  // One device only.
  assert.deepEqual(valueOn(snapshot(undefined, 5000), 'steps', '2026-10-16'), { source: 'whoop', value: 5000 });
  assert.deepEqual(valueOn(snapshot(6000, undefined), 'steps', '2026-10-16'), { source: 'apple', value: 6000 });
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
