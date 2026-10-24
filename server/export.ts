// "Export your data": everything one person stored, as a JSON download built only from their own session
// (GET /api/me/export). Scaffold: the Profile build fills it in.
import express from 'express';
import type { Db } from './db.ts';

export function exportRouter(_db: Db, _hosted: boolean) {
  const router = express.Router();
  router.get('/', (_req, res) => {
    res.status(501).json({ error: "Exporting isn't ready yet." });
  });
  return router;
}
