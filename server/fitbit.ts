// A Fitbit export (Google Takeout), read in the browser and sent here in chunks as source 'fitbit' (shared/fitbit.ts).
// Mounted before the general JSON parser, since a chunk is a few MB. Scaffold: the Integrations build fills it in.
import express from 'express';
import type { Db } from './db.ts';

export const FITBIT = 'fitbit';

export function fitbitRouter(_db: Db, _hosted: boolean) {
  const router = express.Router();
  router.post('/import', (_req, res) => {
    res.status(501).json({ error: "Fitbit import isn't ready yet." });
  });
  return router;
}
