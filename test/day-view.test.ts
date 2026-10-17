import { test } from 'node:test';
import assert from 'node:assert/strict';
import { cumulative, drawThrough, extent, lastReading } from '../src/charts/day.ts';

const day = (values: Record<number, number>) => Array.from({ length: 24 }, (_, h) => values[h] ?? null);

test('today stops at the last synced hour; a past day runs to 11 PM; a day without readings draws nothing', () => {
  assert.equal(drawThrough('2026-10-16', '2026-10-16', 14), 14);
  assert.equal(drawThrough('2026-10-15', '2026-10-16', 18), 23);
  assert.equal(drawThrough('2026-10-15', '2026-10-16', null), null);
});

test('the running total counts quiet hours as zero and stops after the last hour drawn', () => {
  const steps = day({ 7: 1200, 8: 300, 10: 50 });
  const run = cumulative(steps, 10);
  assert.equal(run[6], 0);
  assert.equal(run[7], 1200);
  assert.equal(run[9], 1500);
  assert.equal(run[10], 1550);
  assert.equal(run[11], null);
  assert.deepEqual(cumulative(steps, null), day({}));
});

test('the latest reading skips empty hours and ignores anything after the cut-off', () => {
  const hr = day({ 3: 52, 9: 71, 15: 80 });
  assert.equal(lastReading(hr, 12), 9);
  assert.equal(lastReading(hr, 23), 15);
  assert.equal(lastReading(hr, 2), null);
  assert.equal(lastReading(hr, null), null);
});

test('extent spans every list given and ignores gaps', () => {
  assert.deepEqual(extent(day({ 2: 50, 9: 120 }), day({ 4: 44 }), undefined), [44, 120]);
  assert.equal(extent(day({}), undefined), null);
});
