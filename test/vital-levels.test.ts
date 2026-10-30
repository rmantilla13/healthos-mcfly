// The figure's colours: how far each vital is from the person's usual (normal, unusual, off), on the same band as
// its status, so the colour and the words always agree.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { addDays } from '../server/dates.ts';
import { rangeStatus, vitalRange } from '../server/query.ts';
import { SPO2_BANDS, spo2Band } from '../shared/metrics.ts';

const D = '2026-10-19';
/** 30 days of breathing alternating 13.9 and 14.1 (SD 0.1, so the band is its 0.5 minimum), then today's reading. */
function ctx(today: number | null, days = 30) {
  const byDate = new Map<string, number>();
  for (let i = 1; i <= days; i++) byDate.set(addDays(D, -i), i % 2 ? 13.9 : 14.1);
  if (today !== null) byDate.set(D, today);
  return { daily: new Map([['resp_rate', new Map([['apple', byDate]])]]), demo: false } as unknown as Parameters<typeof vitalRange>[0];
}
const at = (value: number) => ({ date: D, value, source: 'apple' });

test('within the band is normal, beyond it unusual, beyond twice it off, in either direction', () => {
  assert.deepEqual(vitalRange(ctx(14.3), 'resp_rate', at(14.3), 0.5), { status: 'normal', level: 'normal' });
  assert.deepEqual(vitalRange(ctx(14.8), 'resp_rate', at(14.8), 0.5), { status: 'high', level: 'unusual' });
  assert.deepEqual(vitalRange(ctx(15.5), 'resp_rate', at(15.5), 0.5), { status: 'high', level: 'off' });
  assert.deepEqual(vitalRange(ctx(13.2), 'resp_rate', at(13.2), 0.5), { status: 'low', level: 'unusual' });
  assert.deepEqual(vitalRange(ctx(12.5), 'resp_rate', at(12.5), 0.5), { status: 'low', level: 'off' });
});

test('no level without a week of history, or without a reading', () => {
  assert.deepEqual(vitalRange(ctx(15.5, 6), 'resp_rate', at(15.5), 0.5), { status: null, level: null });
  assert.deepEqual(vitalRange(ctx(null), 'resp_rate', null, 0.5), { status: null, level: null });
});

test('the level is normal exactly when the status is, and the status matches rangeStatus', () => {
  for (let v = 12; v <= 16; v += 0.01) {
    const value = Math.round(v * 100) / 100;
    const r = vitalRange(ctx(value), 'resp_rate', at(value), 0.5);
    assert.equal(r.level === 'normal', r.status === 'normal', String(value));
    assert.equal(r.status, rangeStatus(ctx(value), 'resp_rate', at(value), 0.5), String(value));
  }
});

test('blood oxygen has fixed bands: higher is better, 95 and up normal, under 95 slightly low, 92 or lower low', () => {
  for (const [v, band] of [
    [100, 'normal'],
    [95, 'normal'],
    [94.96, 'normal'], // reads "95.0%"
    [94.9, 'slightly_low'],
    [92.1, 'slightly_low'],
    [92.04, 'low'], // reads "92.0%"
    [92, 'low'],
    [89.9, 'low'],
    [80, 'low'],
  ] as const)
    assert.equal(spo2Band(v), band, `${v}`);
  assert.deepEqual(
    Object.values(SPO2_BANDS).map((b) => [b.text, b.level]),
    [
      ['Normal', 'normal'],
      ['Slightly low', 'unusual'],
      ['Low', 'off'],
    ],
  );
});
