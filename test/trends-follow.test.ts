// A night's stages follow its sleep_hours decision, even when only a stage is asked for.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { addDays, todayLocal } from '../server/dates.ts';
import { OWNER_ID, setUserSetting, upsertDaily } from '../server/db.ts';
import { trends } from '../server/query.ts';
import { openStore } from '../server/store.ts';

test('deep sleep asked for alone is the same blended value the dashboard shows with the night', async (t) => {
  const db = await openStore();
  t.after(() => db.close());
  await setUserSetting(db, OWNER_ID, 'timezone', 'UTC');
  await setUserSetting(db, OWNER_ID, 'demo', 'off');
  const d = addDays(todayLocal('UTC'), -1);
  // The two devices agree on the night (7.0 and 7.4 hours), so its parts are averaged too.
  await upsertDaily(db, OWNER_ID, [
    { date: d, metric: 'sleep_hours', source: 'apple', value: 7 },
    { date: d, metric: 'sleep_hours', source: 'whoop', value: 7.4 },
    { date: d, metric: 'sleep_deep', source: 'apple', value: 1 },
    { date: d, metric: 'sleep_deep', source: 'whoop', value: 1.6 },
  ]);
  const scope = { db, userId: OWNER_ID };
  const alone = await trends(scope, false, ['sleep_deep'], 7);
  const withNight = await trends(scope, false, ['sleep_hours', 'sleep_deep'], 7);
  assert.equal(alone.sleep_deep[0].value, 1.3);
  assert.deepEqual(alone.sleep_deep, withNight.sleep_deep);
  assert.equal(alone.sleep_hours, undefined, 'only what was asked for comes back');
});
