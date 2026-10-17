// WHOOP steps end to end: the real sync against a stubbed WHOOP API, run like the 6-hourly cron over several
// days, so the sliding sync window and the one-time re-read are exercised as in production.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { setUserSetting, upsertDaily, upsertHourly } from '../server/db.ts';
import { dayView } from '../server/day.ts';
import { OWNER_ID, openStore } from '../server/store.ts';
import { syncWhoop } from '../server/whoop.ts';

const RealDate = Date;
const at = (iso: string) => RealDate.parse(iso);
const score = { strain: 10, kilojoule: 8000, average_heart_rate: 70, max_heart_rate: 150 };
// When WHOOP deletes the split night's second sleep, merging cycles 5 and 6.
const MERGED = at('2026-10-18T00:00:00Z');

// Chicago (-05:00). Each cycle runs from falling asleep to the next sleep; WHOOP only closes it (shows its
// end) once it has processed that next sleep, after you wake.
type Cycle = { id: number; start: string; end: string | null; steps: number; closes: number };
function cycles(now: number): Cycle[] {
  const all: Cycle[] = [
    // Asleep 17:00 Oct 13, up 05:00 Oct 14, next sleep 20:30 Oct 14 (27.5 h): Oct 14's walking.
    { id: 3, start: '2026-10-13T22:00:00.000Z', end: '2026-10-15T01:30:00.000Z', steps: 7000, closes: at('2026-10-15T12:30:00Z') },
    { id: 4, start: '2026-10-15T01:30:00.000Z', end: '2026-10-16T04:30:00.000Z', steps: 8000, closes: at('2026-10-16T09:30:00Z') },
    // A split night on Oct 16: two cycles that both wake into Oct 16, until the second sleep is deleted.
    ...(now < MERGED
      ? [
          { id: 5, start: '2026-10-16T04:30:00.000Z', end: '2026-10-16T14:00:00.000Z', steps: 3000, closes: at('2026-10-16T16:30:00Z') },
          { id: 6, start: '2026-10-16T14:00:00.000Z', end: '2026-10-17T04:30:00.000Z', steps: 2500, closes: at('2026-10-17T12:30:00Z') },
        ]
      : [{ id: 5, start: '2026-10-16T04:30:00.000Z', end: '2026-10-17T04:30:00.000Z', steps: 5500, closes: at('2026-10-17T12:30:00Z') }]),
    { id: 7, start: '2026-10-17T04:30:00.000Z', end: '2026-10-18T04:00:00.000Z', steps: 9400, closes: at('2026-10-18T12:30:00Z') },
    { id: 8, start: '2026-10-18T04:00:00.000Z', end: '2026-10-19T04:00:00.000Z', steps: 11000, closes: at('2026-10-19T12:30:00Z') },
    // The current cycle: the strap came off, so it never closes.
    { id: 9, start: '2026-10-19T04:00:00.000Z', end: null, steps: 6000, closes: Infinity },
  ];
  return all.filter((c) => at(c.start) <= now).map((c) => ({ ...c, end: now >= c.closes ? c.end : null }));
}
const SLEEPS = [
  { id: 's3', cycle_id: 3, start: '2026-10-13T22:00:00.000Z', end: '2026-10-14T10:00:00.000Z' },
  { id: 's4', cycle_id: 4, start: '2026-10-15T01:30:00.000Z', end: '2026-10-15T12:00:00.000Z' },
  { id: 's5', cycle_id: 5, start: '2026-10-16T04:30:00.000Z', end: '2026-10-16T09:00:00.000Z' },
  { id: 's6', cycle_id: 6, start: '2026-10-16T14:00:00.000Z', end: '2026-10-16T16:00:00.000Z' },
  { id: 's7', cycle_id: 7, start: '2026-10-17T04:30:00.000Z', end: '2026-10-17T12:00:00.000Z' },
  { id: 's8', cycle_id: 8, start: '2026-10-18T04:00:00.000Z', end: '2026-10-18T12:00:00.000Z' },
  { id: 's9', cycle_id: 9, start: '2026-10-19T04:00:00.000Z', end: '2026-10-19T12:00:00.000Z' },
];
const sleeps = (now: number) =>
  SLEEPS.filter((s) => at(s.end) <= now && !(s.id === 's6' && now >= MERGED)).map((s) => ({ ...s, timezone_offset: '-05:00', nap: false, score_state: 'PENDING_SCORE' }));

const realFetch = globalThis.fetch;
let fakeNow = at('2026-10-17T00:15:30Z');
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
    const start = at(url.searchParams.get('start')!);
    const endParam = url.searchParams.get('end');
    const end = endParam ? at(endParam) : Infinity;
    // As WHOOP documents it: everything that overlaps the window (still going at its start, or begun before its end).
    const pick = <T extends { start: string; end: string | null }>(rs: T[]) => rs.filter((r) => (r.end === null || at(r.end) >= start) && at(r.start) < end);
    const records = url.pathname.endsWith('/cycle')
      ? pick(cycles(fakeNow)).map(({ steps, closes: _, ...c }) => ({ ...c, timezone_offset: '-05:00', ...(c.end ? { score_state: 'SCORED', score } : { score_state: 'PENDING_SCORE' }), step_count: steps }))
      : url.pathname.endsWith('/activity/sleep')
        ? pick(sleeps(fakeNow))
        : [];
    return new Response(JSON.stringify({ records, next_token: null }));
  }) as typeof fetch;
});
test.after(() => {
  (globalThis as { Date: DateConstructor }).Date = RealDate;
  globalThis.fetch = realFetch;
});

test('WHOOP steps stay on the right days through the sliding sync window, merged cycles and open cycles', async (t) => {
  const db = await openStore();
  // Closed even when an assertion fails; an open database keeps the test process alive.
  t.after(() => db.close());
  const scope = { db, userId: OWNER_ID };
  await db.query("INSERT INTO tokens (user_id, provider, access_token, refresh_token, expires_at, scope) VALUES ($1, 'whoop', 'a', 'r', $2, '')", [OWNER_ID, 9e15]);
  await setUserSetting(db, OWNER_ID, 'whoop_backfill_before', String(at('2014-01-01T00:00:00Z')));
  await setUserSetting(db, OWNER_ID, 'whoop_last_sync', '2026-10-17T00:00:00.000Z');
  // What the first version left behind: a two-day count summed onto one date.
  await upsertDaily(db, OWNER_ID, [{ date: '2026-10-16', metric: 'steps', source: 'whoop', value: 99999 }]);

  const whoopSteps = async () =>
    Object.fromEntries(
      (await db.query<{ date: string; value: number }>("SELECT date, value FROM daily WHERE user_id = $1 AND metric = 'steps' AND source = 'whoop' ORDER BY date", [OWNER_ID])).map((r) => [
        r.date,
        Number(r.value),
      ]),
    );
  // The right count for each day, once its cycle has begun.
  const truth: [string, string, number][] = [
    ['2026-10-14', '2026-10-13T22:00:00Z', 7000],
    ['2026-10-15', '2026-10-15T01:30:00Z', 8000],
    ['2026-10-16', '2026-10-16T04:30:00Z', 5500],
    ['2026-10-17', '2026-10-17T04:30:00Z', 9400],
    ['2026-10-18', '2026-10-18T04:00:00Z', 11000],
    ['2026-10-19', '2026-10-19T04:00:00Z', 6000],
  ];
  for (const d of ['17', '18', '19', '20', '21', '22', '23']) {
    for (const h of ['00', '06', '12', '18']) {
      fakeNow = at(`2026-10-${d}T${h}:15:30Z`);
      // The cron runs a recent pass and a history pass for each person.
      await syncWhoop(scope, { backfill: false });
      await syncWhoop(scope, { backfill: true });
      const expected = Object.fromEntries(truth.filter(([, begun]) => at(begun) <= fakeNow).map(([date, , n]) => [date, n]));
      assert.deepEqual(await whoopSteps(), expected, `after the ${d} ${h}:15 run`);
    }
  }

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
  // A day the phone never synced still has its total for the card, with no hours.
  const quiet = await dayView(scope, false, ['steps'], '2026-10-18');
  assert.equal(quiet.asOf, null);
  assert.deepEqual(quiet.metrics.steps?.total, { value: 11000, source: 'whoop' });
});
