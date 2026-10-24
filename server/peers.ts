// Anonymous peer comparisons (shared/peers.ts): the second place, after the Family board (server/family.ts), where one
// person's readings are read for another, and only ever as aggregates of a large enough group. Scaffold: the
// Profile build fills it in.
import express from 'express';
import type { PeerData } from '../shared/peers.ts';
import type { Db } from './db.ts';

export function peersRouter(_db: Db, _hosted: boolean) {
  const router = express.Router();
  router.get('/', (_req, res) => {
    res.json({ participating: false, reason: 'off' } satisfies PeerData);
  });
  return router;
}
