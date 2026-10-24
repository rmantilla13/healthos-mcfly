// The health journal: private check-ins (journal_entries). Nothing else on the server reads them: not the summary,
// the Family board, peer comparisons, McFly's tools, the admin screens or the demo. Scaffold: the Journal build fills
// in the routes (shared/journal.ts has the shapes).
import express from 'express';
import type { JournalData } from '../shared/journal.ts';
import { currentUser } from './auth.ts';
import type { Db } from './db.ts';
import { requestContext } from './query.ts';

export function journalRouter(db: Db, hosted: boolean) {
  const router = express.Router();
  router.get('/', async (_req, res) => {
    const { today } = await requestContext({ db, userId: currentUser(res).id }, hosted);
    res.json({ today, entries: [] } satisfies JournalData);
  });
  return router;
}
