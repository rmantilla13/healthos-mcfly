// Portraits (shared/portraits.ts): private reference photos and likenesses generated from them with the person's own
// OpenAI key. Mounted before the general JSON parser, since a reference photo is a few MB. Scaffold: the Portraits
// build fills it in.
import express from 'express';
import type { PortraitList } from '../shared/portraits.ts';
import type { Db } from './db.ts';

export function portraitsRouter(_db: Db, _hosted: boolean) {
  const router = express.Router();
  router.get('/', (_req, res) => {
    res.json({ portraits: [], chosen: null, canGenerate: false } satisfies PortraitList);
  });
  return router;
}
