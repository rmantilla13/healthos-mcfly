// Which AI a person's request uses: their own key for that provider when they've stored one (server/ai/keys.ts), and
// otherwise the server's shared Claude key (ANTHROPIC_API_KEY), exactly as before personal keys existed. Everything
// that calls a model (Ask McFly, meal estimates, lab report reading, voice notes, portraits) asks here.
// Scaffold: until the AI build lands, everyone uses the shared key and nobody has a key of their own.
import type { AiSource, AiStatus } from '../../shared/ai.ts';
import { platformSettings } from '../admin.ts';
import type { Db } from '../db.ts';
import type { McflyClient } from '../mcfly.ts';

export type SharedClient = () => McflyClient | null;

/** The server's shared Claude key works for this person: it's set, and the admin hasn't set McFly's limit to 0. */
export async function sharedAvailable(db: Db, shared: SharedClient) {
  return Boolean(shared()) && Number((await platformSettings(db)).mcfly_daily_limit) > 0;
}

/** What this person's AI requests use right now (GET /api/ai). Never includes a key. */
export async function aiStatus(db: Db, _userId: string, shared: SharedClient): Promise<AiStatus> {
  const ok = await sharedAvailable(db, shared);
  const model = String((await platformSettings(db)).mcfly_model);
  const openai = Boolean(process.env.OPENAI_API_KEY);
  return {
    byok: false,
    shared: ok,
    keys: [],
    chat: ok ? { provider: 'anthropic', source: 'shared', model } : null,
    chatChoice: 'shared',
    estimate: ok ? { provider: 'anthropic', source: 'shared' } : null,
    voice: openai,
    portraits: openai,
  };
}

/** A Claude client for this person: their own Anthropic key, else the shared one; null when neither is available. */
export async function anthropicFor(db: Db, _userId: string, shared: SharedClient): Promise<{ client: McflyClient; source: AiSource } | null> {
  const client = shared();
  return client && (await sharedAvailable(db, shared)) ? { client, source: 'shared' } : null;
}

/** An OpenAI key for this person (voice notes, portraits, meal estimates): their own, else the server's OPENAI_API_KEY. */
export async function openaiKeyFor(_db: Db, _userId: string): Promise<{ key: string; source: AiSource } | null> {
  const key = process.env.OPENAI_API_KEY;
  return key ? { key, source: 'shared' } : null;
}
