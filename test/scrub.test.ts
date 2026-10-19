// Scrubbing Home's timeline (src/charts/scrub.ts): which events and hourly figures belong to a moment of the day.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { clockOf, eventsAt, momentAt, scrubMax, stepMinute } from '../src/charts/scrub.ts';
import type { DayData, TimelineEvent } from '../shared/types.ts';

const hours = (values: Record<number, number>) => Array.from({ length: 24 }, (_, h) => values[h] ?? null);
const TODAY = '2026-10-19';
const PAST = '2026-10-18';

/** Steps 1000 at 7, 500 at 8 and 200 at 14; heart rate at 3, 7 and 14 (none at 8); typical totals rising 100 an hour. */
function dayOf(date: string, asOf: number | null): DayData {
  return {
    date,
    today: TODAY,
    asOf,
    metrics: {
      steps: { hours: hours({ 7: 1000, 8: 500, 14: 200 }), typical: Array.from({ length: 24 }, (_, h) => (h + 1) * 100) },
      active_energy: { hours: hours({}), typical: hours({}) },
      heart_rate: {
        hours: hours({ 3: 52, 7: 131.4, 14: 74 }),
        typical: hours({ 7: 80 }),
        min: hours({ 3: 48, 7: 96, 14: 66 }),
        max: hours({ 3: 57, 7: 162, 14: 90 }),
      },
    },
  };
}

const run: TimelineEvent = { id: 'w', kind: 'workout', title: 'Running', start: `${TODAY}T07:05:00-05:00`, end: `${TODAY}T07:08:00-05:00` };
const sleep: TimelineEvent = { id: 's', kind: 'sleep', title: 'Sleep', start: `${PAST}T23:10:00-05:00`, end: `${TODAY}T06:40:00-05:00` };

test('clock labels run from 00:00 to 24:00', () => {
  assert.deepEqual([clockOf(0), clockOf(425), clockOf(1440)], ['00:00', '07:05', '24:00']);
});

test("the marker reaches now on today (at least the last synced hour) and the whole day otherwise", () => {
  assert.equal(scrubMax(true, 872, 14), 872);
  // The browser's clock reads 13:10 but the phone has sent hour 14 in the person's own time zone.
  assert.equal(scrubMax(true, 790, 14), 840);
  assert.equal(scrubMax(true, 30, null), 30);
  assert.equal(scrubMax(false, 872, 14), 1440);
});

test('keyboard steps land on the grid and stay inside the range', () => {
  assert.equal(stepMinute(872, 15, -1, 900), 870);
  assert.equal(stepMinute(870, 15, -1, 900), 855);
  assert.equal(stepMinute(872, 15, 1, 900), 885);
  assert.equal(stepMinute(895, 15, 1, 900), 900);
  assert.equal(stepMinute(5, 60, -1, 900), 0);
});

test("events are matched by their real times, so a 3-minute session doesn't claim the 12 minutes it's drawn as", () => {
  assert.deepEqual(eventsAt([run, sleep], TODAY, 426).map((e) => e.id), ['w']);
  assert.deepEqual(eventsAt([run, sleep], TODAY, 430), []);
  // A night that began the evening before covers the small hours; it has ended by 06:40.
  assert.deepEqual(eventsAt([run, sleep], TODAY, 120).map((e) => e.id), ['s']);
  assert.deepEqual(eventsAt([run, sleep], TODAY, 400), []);
});

test("heart rate is the hour's own average and range; an hour without readings says so", () => {
  const m = momentAt(dayOf(TODAY, 14), [], TODAY, 7 * 60 + 20, false);
  assert.deepEqual(m.heart, { kind: 'reading', hour: 7, avg: 131.4, min: 96, max: 162, typical: 80, partial: false });
  assert.deepEqual(momentAt(dayOf(TODAY, 14), [], TODAY, 8 * 60 + 5, false).heart, { kind: 'none', hour: 8 });
  // Today's last synced hour may still be filling up.
  assert.equal((momentAt(dayOf(TODAY, 14), [], TODAY, 14 * 60 + 40, false).heart as { partial: boolean }).partial, true);
});

test("today's hours after the last sync are pending, not empty", () => {
  const m = momentAt(dayOf(TODAY, 14), [], TODAY, 15 * 60 + 10, false);
  assert.deepEqual(m.heart, { kind: 'pending', hour: 15 });
  // The totals after the last sync are today's so far, with no typical to compare a part-hour with.
  assert.deepEqual(m.steps, { kind: 'so-far', value: 1700 });
});

test('steps and energy count whole hours up to the marker, against the typical total by then', () => {
  // At 08:40 the total is by 08:00: the 1000 of 07:00–08:00, not the 500 still to come in 08:00–09:00.
  assert.deepEqual(momentAt(dayOf(TODAY, 14), [], TODAY, 8 * 60 + 40, false).steps, { kind: 'by', at: 8, value: 1000, typical: 800 });
  assert.deepEqual(momentAt(dayOf(TODAY, 14), [], TODAY, 20, false).steps, { kind: 'by', at: 0, value: 0, typical: null });
  // A metric with no hours that day says so rather than counting zeros.
  assert.deepEqual(momentAt(dayOf(TODAY, 14), [], TODAY, 8 * 60 + 40, false).energy, { kind: 'empty' });
  assert.deepEqual(momentAt(dayOf(TODAY, 14), [], TODAY, 13 * 60 + 59, false).steps, { kind: 'by', at: 13, value: 1000 + 500, typical: 1300 });
  // Inside today's last synced hour (14) the total stays at the whole hours; once the marker is past every synced
  // reading (15:00), it's today's so far.
  assert.deepEqual(momentAt(dayOf(TODAY, 14), [], TODAY, 14 * 60 + 50, false).steps, { kind: 'by', at: 14, value: 1500, typical: 1400 });
  assert.deepEqual(momentAt(dayOf(TODAY, 14), [], TODAY, 15 * 60, false).steps, { kind: 'so-far', value: 1700 });
});

test('live today is the latest heart rate and the totals so far', () => {
  const m = momentAt(dayOf(TODAY, 14), [run], TODAY, 16 * 60 + 2, true);
  assert.deepEqual(m.heart, { kind: 'reading', hour: 14, avg: 74, min: 66, max: 90, typical: null, partial: true });
  assert.deepEqual(m.steps, { kind: 'so-far', value: 1700 });
  assert.deepEqual(m.events, []);
});

test('a past day runs to 24:00, where the totals are the whole day against a typical day', () => {
  const m = momentAt(dayOf(PAST, 14), [], PAST, 1440, true);
  assert.deepEqual(m.heart, { kind: 'reading', hour: 14, avg: 74, min: 66, max: 90, typical: null, partial: false });
  assert.deepEqual(m.steps, { kind: 'by', at: 24, value: 1700, typical: 2400 });
  // Late hours of a past day without readings are "none", never "pending".
  assert.deepEqual(momentAt(dayOf(PAST, 14), [], PAST, 22 * 60, false).heart, { kind: 'none', hour: 22 });
});

test('no hourly data, another day\'s data, or nothing synced yet today: only what is known', () => {
  assert.deepEqual(momentAt(undefined, [run], TODAY, 426, false), { minute: 426, events: [run] });
  assert.deepEqual(momentAt({ date: TODAY, today: TODAY, asOf: null, metrics: {} }, [], TODAY, 600, false), { minute: 600, events: [] });
  assert.deepEqual(momentAt(dayOf(PAST, 14), [], TODAY, 600, false), { minute: 600, events: [] });
  const none = momentAt(dayOf(TODAY, null), [], TODAY, 30, true);
  assert.deepEqual([none.heart, none.steps], [{ kind: 'empty' }, { kind: 'empty' }]);
});
