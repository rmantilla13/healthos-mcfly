// Body measurements a person adds themselves (body_entries), mirrored into `daily` as source 'manual': each day's
// latest entry per metric, written in the same transaction (shared/body.ts). Scaffold: the Body build fills it in.
import express from 'express';
import type { BodyEntries } from '../shared/body.ts';
import type { Db } from './db.ts';

export function bodyRouter(_db: Db, _hosted: boolean) {
  const router = express.Router();
  router.get('/entries', (_req, res) => {
    res.json({ entries: [] } satisfies BodyEntries);
  });
  return router;
}
