import { test } from 'node:test';
import assert from 'node:assert/strict';
import { latest, series } from '../server/query.ts';

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

test('on the same day, the preferred source wins', () => {
  const c = ctx([
    ['resting_hr', 'apple', '2026-10-16', 57],
    ['resting_hr', 'whoop', '2026-10-16', 55],
  ]);
  assert.equal(latest(c, 'resting_hr', '2026-10-16')!.source, 'whoop');
  assert.deepEqual(series(c, 'resting_hr', '2026-10-16', '2026-10-16'), [{ date: '2026-10-16', value: 55 }]);
});

test('readings outside the lookback or after the as-of date are ignored', () => {
  const c = ctx([
    ['spo2', 'whoop', '2026-09-01', 96],
    ['spo2', 'apple', '2026-10-20', 97],
  ]);
  assert.equal(latest(c, 'spo2', '2026-10-16', 14), null);
});
