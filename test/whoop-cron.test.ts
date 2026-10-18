// The hourly WHOOP cron (syncAllWhoop) against a stubbed WHOOP API: how many requests one run makes per person.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { OWNER_ID, getUserSetting, setUserSetting } from '../server/db.ts';
import { openStore } from '../server/store.ts';
import { syncAllWhoop, syncState } from '../server/whoop.ts';

const HISTORY_START = Date.parse('2015-01-01T00:00:00Z');
const DAY = 86_400_000;

let calls: URL[] = [];
let failCycles = false;
const realFetch = globalThis.fetch;
test.before(() => {
  globalThis.fetch = (async (input: string | URL) => {
    const url = new URL(String(input));
    calls.push(url);
    if (failCycles && url.pathname.endsWith('/cycle')) return new Response('{"error":"bad request"}', { status: 400 });
    if (url.pathname.endsWith('/user/profile/basic') || url.pathname.endsWith('/user/measurement/body')) return new Response('{}');
    return new Response(JSON.stringify({ records: [], next_token: null }));
  }) as typeof fetch;
});
test.after(() => {
  globalThis.fetch = realFetch;
});

test('a cron run syncs history only for people who still have some to fetch', async (t) => {
  const db = await openStore();
  t.after(() => db.close());
  await db.query("INSERT INTO tokens (user_id, provider, access_token, refresh_token, expires_at, scope) VALUES ($1, 'whoop', 'a', 'r', $2, '')", [OWNER_ID, 9e15]);
  await setUserSetting(db, OWNER_ID, 'whoop_last_sync', new Date(Date.now() - DAY).toISOString());
  await setUserSetting(db, OWNER_ID, 'whoop_steps_v2', '2026-09-20T00:00:00.000Z');
  // Two 120-day windows of history left to fetch.
  await setUserSetting(db, OWNER_ID, 'whoop_backfill_before', String(HISTORY_START + 200 * DAY));

  const run = async () => {
    calls = [];
    return { out: await syncAllWhoop(db), calls };
  };
  // History windows are the only requests with an end.
  const windows = (cs: URL[]) => cs.filter((u) => u.searchParams.has('end')).length;
  // Profile, body, then cycles, sleep, recovery and workouts over the recent days (one page each here).
  const RECENT = 6;

  // History left: the recent sync, then the history sync (which re-reads recent days) with both windows.
  let r = await run();
  assert.deepEqual(r.out.results, { [OWNER_ID]: 'ok' });
  assert.equal(windows(r.calls), 2 * 4);
  assert.equal(r.calls.length, RECENT + RECENT + 2 * 4);
  assert.equal(Number(await getUserSetting(db, OWNER_ID, 'whoop_backfill_before')), HISTORY_START);

  // History complete: one sync of the recent days, not two.
  r = await run();
  assert.deepEqual(r.out.results, { [OWNER_ID]: 'ok' });
  assert.equal(r.calls.length, RECENT);
  assert.equal(windows(r.calls), 0);
  assert.equal((await syncState({ db, userId: OWNER_ID })).lastCounts?.historyComplete, 1);

  // A failed recent sync isn't followed by a history sync in the same run, and the person sees plain words.
  await setUserSetting(db, OWNER_ID, 'whoop_backfill_before', String(HISTORY_START + 100 * DAY));
  failCycles = true;
  r = await run();
  failCycles = false;
  assert.match(r.out.results[OWNER_ID], /\/cycle failed \(400\)/);
  assert.equal(windows(r.calls), 0);
  assert.equal(r.calls.length, 3);
  const state = await syncState({ db, userId: OWNER_ID });
  assert.equal(state.lastError, "The WHOOP sync didn't finish. healthOS will try again within the hour.");
  assert.match(state.lastErrorDetail ?? '', /\/cycle failed \(400\)/);

  // The next run picks the history up again.
  r = await run();
  assert.equal(windows(r.calls), 4);
  assert.equal((await syncState({ db, userId: OWNER_ID })).lastError, undefined);
});
