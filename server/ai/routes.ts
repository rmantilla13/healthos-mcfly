// GET /api/ai (what this person's AI requests use), and later: storing and removing their own keys, the chat's
// provider, and voice-note transcription. Scaffold: the AI build fills in the rest (shared/ai.ts has the shapes).
import express from 'express';
import { currentUser } from '../auth.ts';
import type { Db } from '../db.ts';
import { type SharedClient, aiStatus } from './resolve.ts';

export function aiRouter(db: Db, { client }: { hosted: boolean; client: SharedClient }) {
  const router = express.Router();
  router.get('/', async (_req, res) => {
    res.json(await aiStatus(db, currentUser(res).id, client));
  });
  router.post('/transcribe', (_req, res) => {
    res.status(503).json({ error: 'Voice notes need an OpenAI key. Connect one in your Profile.' });
  });
  return router;
}
