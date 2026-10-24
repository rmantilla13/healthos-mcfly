// Every table holding one person's rows is in USER_TABLES, so account deletion (and the export) can't miss a new one.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { USER_TABLES } from '../server/db.ts';
import { openStore } from '../server/store.ts';

const db = await openStore();

/** Tables with a user_id that aren't one person's data: invites name who used them, and are cleared by the admin route. */
const NOT_PERSONAL = new Set(['invites']);

test('USER_TABLES lists every table with a user_id column', async () => {
  const rows = await db.query<{ table_name: string }>(
    "SELECT DISTINCT table_name FROM information_schema.columns WHERE column_name = 'user_id' AND table_schema = 'public' ORDER BY table_name",
  );
  const inSchema = rows.map((r) => r.table_name).filter((t) => !NOT_PERSONAL.has(t));
  assert.deepEqual([...USER_TABLES].sort(), inSchema.sort());
});
