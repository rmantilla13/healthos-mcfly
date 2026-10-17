// WHOOP steps end to end: the real sync against a stubbed WHOOP API, run like the 6-hourly cron over several
// days, so the sliding sync window and the one-time re-read are exercised as in production.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { setUserSetting, upsertDaily, upsertHourly } from '../server/db.ts';
import { dayView } from '../server/day.ts';
import { OWNER_ID, openStore } from '../server/store.ts';
import { syncWhoop } from '../server/whoop.ts';

const score = { strain: 10, kilojoule: 8000, average_heart_rate: 70, max_heart_rate: 150 };
// A split night on Oct 16 (Chicago): two cycles that both wake into Oct 16, then an ordinary Oct 17.
const CYCLES = [
  { id: 5, start: '2026-10-16T04:30:00.000Z', end: '2026-10-16T14:00:00.000Z', timezone_offset: '-05:00', score_state: 'SCORED', score, step_count: 3000 },
  { id: 6, start: '2026-10-16T14:00:00.000Z', end: '2026-10-17T04:30:00.000Z', timezone_offset: '-05:00', score_state: 'SCORED', score, step_count: 2500 },
  { id: 7, start: '2026-10-17T04:30:00.000Z', end: '2026-10-18T04:00:00.000Z', timezone_offset: '-05:00', score_state: 'SCORED', score, step_count: 9400 },
];
const SLEEPS = [
  { id: 's5', cycle_id: 5, start: '2026-10-16T04:30:00.000Z', end: '2026-10-16T09:00:00.000Z', timezone_offset: '-05:00', nap: false, score_state: 'PENDING_SCORE' },
  { id: 's6', cycle_id: 6, start: '2026-10-16T14:00:00.000Z', end: '2026-10-16T16:00:00.000Z', timezone_offset: '-05:00', nap: false, score_state: 'PENDING_SCORE' },
  { id: 's7', cycle_id: 7, start: '2026-10-17T04:30:00.000Z', end: '2026-10-17T12:00:00.000Z', timezone_offset: '-05:00', nap: false, score_state: 'PENDING_SCORE' },
];

const RealDate = Date;
const realFetch = globalThis.fetch;
let fakeNow = RealDate.parse('2026-10-17T00:15:30Z');
class FakeDate extends RealDate {
  constructor(...a: unknown[]) {
    if (a.length === 0) super(fakeNow);
    else super(...(a as [string]));
  }
  static now() {
    return fakeNow;
  }
}

test.before(() => {
  (globalThis as { Date: DateConstructor }).Date = FakeDate as DateConstructor;
  globalThis.fetch = (async (input: string | URL) => {
    const url = new URL(String(input));
    if (url.pathname.endsWith('/user/profile/basic') || url.pathname.endsWith('/user/measurement/body')) return new Response('{}');
    const start = RealDate.parse(url.searchParams.get('start')!);
    const endParam = url.searchParams.get('end');
    const end = endParam ? RealDate.parse(endParam) : Infinity;
    // WHOOP returns records that start inside the window.
    const pick = <T extends { start: string }>(rs: T[]) => rs.filter((r) => RealDate.parse(r.start) >= start && RealDate.parse(r.start) < end);
    const records = url.pathname.endsWith('/cycle') ? pick(CYCLES) : url.pathname.endsWith('/activity/sleep') ? pick(SLEEPS) : [];
    return new Response(JSON.stringify({ records, next_token: null }));
  }) as typeof fetch;
});
test.after(() => {
  (globalThis as { Date: DateConstructor }).Date = RealDate;
  globalThis.fetch = realFetch;
});

test('WHOOP steps survive the sliding sync window, and the first version\'s rows are rebuilt', async () => {
  const db = await openStore();
  const scope = { db, userId: OWNER_ID };
  await db.query("INSERT INTO tokens (user_id, provider, access_token, refresh_token, expires_at, scope) VALUES ($1, 'whoop', 'a', 'r', $2, '')", [OWNER_ID, 9e15]);
  await setUserSetting(db, OWNER_ID, 'whoop_backfill_before', String(RealDate.parse('2014-01-01T00:00:00Z')));
  await setUserSetting(db, OWNER_ID, 'whoop_last_sync', '2026-10-17T00:00:00.000Z');
  // What tonight's first version left behind: a two-day count summed onto one date.
  await upsertDaily(db, OWNER_ID, [{ date: '2026-10-16', metric: 'steps', source: 'whoop', value: 99999 }]);

  const whoopSteps = async (date: string) =>
    (await db.query<{ value: number }>("SELECT value FROM daily WHERE user_id = $1 AND metric = 'steps' AND source = 'whoop' AND date = $2", [OWNER_ID, date]))[0]?.value;
  const seen: number[] = [];
  for (const d of ['17', '18', '19', '20', '21', '22']) {
    for (const h of ['00', '06', '12', '18']) {
      fakeNow = RealDate.parse(`2026-10-${d}T${h}:15:30Z`);
      // The cron runs a recent pass and a history pass for each person.
      await syncWhoop(scope, { backfill: false });
      await syncWhoop(scope, { backfill: true });
      seen.push(await whoopSteps('2026-10-16'));
    }
  }
  assert.ok(seen.every((v) => v === 5500), `Oct 16 should stay 5,500 on every run; saw ${[...new Set(seen)].join(', ')}`);
  assert.equal(await whoopSteps('2026-10-17'), 9400);

  // The Day view shows the day's real total when WHOOP's count wins, next to the phone's hours.
  await upsertDaily(db, OWNER_ID, [{ date: '2026-10-17', metric: 'steps', source: 'apple', value: 2100 }]);
  await upsertHourly(db, OWNER_ID, [
    { date: '2026-10-17', hour: 9, metric: 'steps', source: 'apple', value: 900 },
    { date: '2026-10-17', hour: 17, metric: 'steps', source: 'apple', value: 1200 },
  ]);
  await setUserSetting(db, OWNER_ID, 'timezone', 'America/Chicago');
  const view = await dayView(scope, false, ['steps'], '2026-10-17');
  assert.deepEqual(view.metrics.steps?.total, { value: 9400, source: 'whoop' });
  assert.equal(view.metrics.steps?.hours.reduce((a: number, v) => a + (v ?? 0), 0), 2100);
  await db.close();
});
