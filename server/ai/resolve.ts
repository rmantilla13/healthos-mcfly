// Which AI a person's request uses: their own key for that provider when they've stored one (server/ai/keys.ts), and
// otherwise the server's shared Claude key (ANTHROPIC_API_KEY), exactly as before personal keys existed. Everything
// that calls a model (Ask McFly, meal estimates, lab report reading, voice notes, portraits) asks here.
// - Ask McFly: the provider the person chose (Profile → Chatbot) while its key is stored, else shared Claude.
// - Meal estimates: their OpenAI key, then their Claude key, then shared Claude. Never the server's OPENAI_API_KEY, so
//   nobody's food photos go to OpenAI unless they connected OpenAI themselves.
// - Voice notes and portraits: an OpenAI key, theirs or the server's.
// A key is opened here only for the call being made, and never leaves the server except in that provider's header.
import Anthropic from '@anthropic-ai/sdk';
import type { AiProvider, AiSource, AiStatus } from '../../shared/ai.ts';
import { platformSettings } from '../admin.ts';
import { type Db, getUserSetting } from '../db.ts';
import type { McflyClient } from '../mcfly.ts';
import { anthropicProvider } from './anthropic.ts';
import { geminiProvider } from './gemini.ts';
import { type OwnKey, isProvider, keyInfos, keysAvailable, noteKeyUse, ownKeys } from './keys.ts';
import { openaiProvider } from './openai.ts';
import { AiError, type AiFetch, type ChatProviderApi } from './provider.ts';

export type SharedClient = () => McflyClient | null;

/** The server's shared Claude key works for this person: it's set, and the admin hasn't set McFly's limit to 0. */
export async function sharedAvailable(db: Db, shared: SharedClient) {
  return Boolean(shared()) && Number((await platformSettings(db)).mcfly_daily_limit) > 0;
}

/** Where one request runs: the provider, whose key pays for it, the model, and the provider to call. */
export type AiRoute = { provider: AiProvider; source: AiSource; model: string; api: ChatProviderApi };
/** Nowhere to run: 'off' when the shared Claude key is set but the admin set McFly's limit to 0; 'none' when nothing is set up. */
export type NoRoute = 'off' | 'none';

type Platform = Record<string, string>;
type Context = { platform: Platform; keys: Map<AiProvider, OwnKey>; choice: string | undefined; chosenModel: string | undefined };

async function contextOf(db: Db, userId: string): Promise<Context> {
  const [platform, keys, choice, chosenModel] = await Promise.all([
    platformSettings(db),
    ownKeys(db, userId),
    getUserSetting(db, userId, 'chat_provider'),
    getUserSetting(db, userId, 'chat_model'),
  ]);
  return { platform, keys, choice, chosenModel };
}

/** The admin's default model for a provider (Admin → Settings). */
export const defaultModel = (platform: Platform, provider: AiProvider) =>
  provider === 'anthropic' ? platform.mcfly_model : provider === 'openai' ? platform.openai_model : platform.gemini_model;

/** A Claude client on a person's own key. A fetch is passed only by tests; the SDK otherwise uses its own. */
const ownClaude = (apiKey: string, fetchFn?: AiFetch): McflyClient => new Anthropic({ apiKey, ...(fetchFn ? { fetch: fetchFn as unknown as typeof fetch } : {}) });

function apiFor(provider: AiProvider, key: string, model: string, fetchFn?: AiFetch): ChatProviderApi {
  if (provider === 'openai') return openaiProvider({ key, model, fetchFn: fetchFn ?? fetch });
  if (provider === 'gemini') return geminiProvider({ key, model, fetchFn: fetchFn ?? fetch });
  return anthropicProvider(ownClaude(key, fetchFn), model);
}

function sharedRoute(shared: SharedClient, platform: Platform): AiRoute | NoRoute {
  const client = shared();
  if (!client) return 'none';
  if (!(Number(platform.mcfly_daily_limit) > 0)) return 'off';
  return { provider: 'anthropic', source: 'shared', model: platform.mcfly_model, api: anthropicProvider(client, platform.mcfly_model) };
}

function chatRoute(c: Context, shared: SharedClient, fetchFn?: AiFetch): AiRoute | NoRoute {
  const own = isProvider(c.choice) ? c.keys.get(c.choice) : undefined;
  if (own && isProvider(c.choice)) {
    const model = c.chosenModel || own.model || defaultModel(c.platform, c.choice);
    return { provider: c.choice, source: 'own', model, api: apiFor(c.choice, own.key, model, fetchFn) };
  }
  return sharedRoute(shared, c.platform);
}

// Estimates run on the admin's models, which read photos and answer in a fixed JSON shape; a person's chat model may not.
function estimateRoute(c: Context, shared: SharedClient, fetchFn?: AiFetch): AiRoute | NoRoute {
  for (const provider of ['openai', 'anthropic'] as const) {
    const own = c.keys.get(provider);
    const model = provider === 'openai' ? c.platform.openai_vision_model : c.platform.mcfly_model;
    if (own) return { provider, source: 'own', model, api: apiFor(provider, own.key, model, fetchFn) };
  }
  return sharedRoute(shared, c.platform);
}

/** What Ask McFly runs on for this person right now. */
export async function chatFor(db: Db, userId: string, shared: SharedClient, fetchFn?: AiFetch) {
  return chatRoute(await contextOf(db, userId), shared, fetchFn);
}

/** What reads this person's meal photo or description right now. */
export async function estimateFor(db: Db, userId: string, shared: SharedClient, fetchFn?: AiFetch) {
  return estimateRoute(await contextOf(db, userId), shared, fetchFn);
}

/** What this person's AI requests use right now (GET /api/ai). Never includes a key. */
export async function aiStatus(db: Db, userId: string, shared: SharedClient): Promise<AiStatus> {
  const byok = keysAvailable();
  const [c, infos] = await Promise.all([contextOf(db, userId), byok ? keyInfos(db, userId) : []]);
  const chat = chatRoute(c, shared);
  const estimate = estimateRoute(c, shared);
  const openai = c.keys.has('openai') || Boolean(process.env.OPENAI_API_KEY);
  return {
    byok,
    shared: Boolean(shared()) && Number(c.platform.mcfly_daily_limit) > 0,
    keys: infos,
    chat: typeof chat === 'object' ? { provider: chat.provider, source: chat.source, model: chat.model } : null,
    chatChoice: byok && isProvider(c.choice) ? c.choice : 'shared',
    estimate: typeof estimate === 'object' ? { provider: estimate.provider, source: estimate.source } : null,
    voice: openai,
    portraits: openai,
  };
}

/** A Claude client for this person: their own Anthropic key, else the shared one; null when neither is available. */
export async function anthropicFor(db: Db, userId: string, shared: SharedClient, fetchFn?: AiFetch): Promise<{ client: McflyClient; source: AiSource } | null> {
  const own = (await ownKeys(db, userId)).get('anthropic');
  if (own) return { client: ownClaude(own.key, fetchFn), source: 'own' };
  const client = shared();
  return client && (await sharedAvailable(db, shared)) ? { client, source: 'shared' } : null;
}

/** An OpenAI key for this person (voice notes, portraits): their own, else the server's OPENAI_API_KEY. */
export async function openaiKeyFor(db: Db, userId: string): Promise<{ key: string; source: AiSource } | null> {
  const own = (await ownKeys(db, userId)).get('openai');
  if (own) return { key: own.key, source: 'own' };
  const key = process.env.OPENAI_API_KEY;
  return key ? { key, source: 'shared' } : null;
}

/**
 * After a call on a person's own key, what it says about the key: it worked, or it was refused ('auth') or out of
 * credit ('quota'), shown in Profile. Other failures (busy, a dropped connection) say nothing about the key.
 */
export async function noteOwnUse(db: Db, userId: string, provider: AiProvider, source: AiSource, err?: unknown) {
  if (source !== 'own') return;
  const kind = err instanceof AiError ? err.kind : null;
  if (err !== undefined && kind !== 'auth' && kind !== 'quota') return;
  await noteKeyUse(db, userId, provider, err === undefined ? null : (kind as 'auth' | 'quota')).catch(() => {});
}
