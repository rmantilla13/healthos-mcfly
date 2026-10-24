// The ⌘K palette finds the Fitbit export import, which lives on Integrations (shared/search.ts).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { type SearchAccess, rank, searchItems } from '../shared/search.ts';

const EVERYONE: SearchAccess = { cycleTracking: false, nutrition: false, nutritionAmounts: false, family: false, admin: false };

test('fitbit, google health and takeout find Integrations', () => {
  for (const q of ['fitbit', 'google health', 'takeout']) {
    const ids = rank(q, searchItems(EVERYONE)).flatMap((s) => s.items.map((it) => it.id));
    assert.ok(ids.includes('page.integrations'), q);
    assert.ok(ids.includes('action.connect'), q);
  }
});
