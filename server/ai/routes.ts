// /api/ai: what this person's AI requests use (GET /), their own keys (PUT and DELETE /keys/:provider), the chat's
// provider (PUT /chat) and voice notes (POST /transcribe). shared/ai.ts has the shapes.
// - A key is checked with its provider (a cheap authenticated list of models) before it's stored, then stored
//   encrypted (keys.ts). No reply ever carries a key, and no log line or error message does either: a provider's own
//   error text can echo part of one, so only its status and kind are kept.
// - A voice note goes to OpenAI's transcription for this one call, and is never stored or logged. On the server's own
//   OpenAI key it counts toward VOICE_NOTES_PER_DAY; on the person's own key it isn't counted.
import express, { type NextFunction, type Request, type Response } from 'express';
import { type AiProvider, VOICE_NOTES_PER_DAY } from '../../shared/ai.ts';
import { platformSettings } from '../admin.ts';
import { HttpError, currentUser } from '../auth.ts';
import { type Db, bumpDataVersion, setUserSetting } from '../db.ts';
import { usageDay } from '../mcfly.ts';
import { GEMINI_API, geminiError } from './gemini.ts';
import { deleteKey, isProvider, keyInfos, keyProblem, keysAvailable, ownKeys, saveKey, setKeyModel } from './keys.ts';
import { OPENAI_API, openaiError } from './openai.ts';
import { AiError, type AiFetch, MODEL_ID, PROVIDER_LABEL, send } from './provider.ts';
import { type SharedClient, aiStatus, noteOwnUse, openaiKeyFor } from './resolve.ts';

export const NOT_SET_UP = "Connecting your own key isn't set up on this server.";

/** A recording is a minute or so of speech, well under Vercel's 4.5 MB request limit. */
const MAX_AUDIO = 4 * 1024 * 1024;

/** The audio OpenAI transcribes, by what its first bytes say. Ogg isn't one of them (OpenAI's list has no ogg). */
const AUDIO: Record<string, { ext: string; is: (b: Buffer) => boolean }> = {
  'audio/webm': { ext: 'webm', is: (b) => b.length > 4 && b.subarray(0, 4).equals(Buffer.from([0x1a, 0x45, 0xdf, 0xa3])) },
  'audio/mp4': { ext: 'm4a', is: (b) => b.length > 12 && b.subarray(4, 8).toString('latin1') === 'ftyp' },
  'audio/mpeg': { ext: 'mp3', is: (b) => b.length > 3 && (b.subarray(0, 3).toString('latin1') === 'ID3' || (b[0] === 0xff && (b[1] & 0xe0) === 0xe0)) },
  'audio/wav': { ext: 'wav', is: (b) => b.length > 12 && b.subarray(0, 4).toString('latin1') === 'RIFF' && b.subarray(8, 12).toString('latin1') === 'WAVE' },
};
const AUDIO_ALIASES: Record<string, string> = { 'audio/x-m4a': 'audio/mp4', 'audio/m4a': 'audio/mp4', 'audio/mp3': 'audio/mpeg', 'audio/x-wav': 'audio/wav', 'audio/wave': 'audio/wav' };

/**
 * Counts a voice note on the server's OpenAI key; null at the day's limit. One statement, so parallel requests can't both
 * take the last one (as claimQuestion in server/mcfly.ts). Never counted as a McFly question: the meal estimate a note
 * becomes is one already.
 */
async function claimVoiceNote(db: Db, userId: string, day: string): Promise<number | null> {
  const [row] = await db.query<{ voice_notes: number }>(
    `INSERT INTO mcfly_usage (user_id, day, voice_notes) VALUES ($1, $2, 1)
     ON CONFLICT (user_id, day) DO UPDATE SET voice_notes = mcfly_usage.voice_notes + 1 WHERE mcfly_usage.voice_notes < $3
     RETURNING voice_notes`,
    [userId, day, VOICE_NOTES_PER_DAY],
  );
  return row ? Number(row.voice_notes) : null;
}

/** Gives back a voice note OpenAI didn't transcribe. */
async function refundVoiceNote(db: Db, userId: string, day: string) {
  await db.query('UPDATE mcfly_usage SET voice_notes = voice_notes - 1 WHERE user_id = $1 AND day = $2 AND voice_notes > 0', [userId, day]);
}

/** Does the provider accept this key? A cheap authenticated call; a rate limit still means the key was recognised. */
export async function verifyKey(fetchFn: AiFetch, provider: AiProvider, key: string): Promise<'ok' | 'rejected' | 'unreachable'> {
  const [url, headers] =
    provider === 'anthropic'
      ? ['https://api.anthropic.com/v1/models?limit=1', { 'x-api-key': key, 'anthropic-version': '2023-06-01' }]
      : provider === 'openai'
        ? [`${OPENAI_API}/models`, { Authorization: `Bearer ${key}` }]
        : [`${GEMINI_API}/models?pageSize=1`, { 'x-goog-api-key': key }];
  let res: globalThis.Response;
  try {
    res = await send(fetchFn, url, { headers, signal: AbortSignal.timeout(10_000) });
  } catch {
    return 'unreachable';
  }
  if (res.ok || res.status === 429) {
    await res.body?.cancel().catch(() => {});
    return 'ok';
  }
  const kind = provider === 'gemini' ? (await geminiError(res)).kind : res.status === 401 || res.status === 403 ? 'auth' : null;
  await res.body?.cancel().catch(() => {});
  return kind === 'auth' ? 'rejected' : 'unreachable';
}

/** An optional model id: null for the default; refused when it can't be one of this provider's. */
function modelFrom(provider: AiProvider, v: unknown): string | null {
  if (v === undefined || v === null || (typeof v === 'string' && !v.trim())) return null;
  if (typeof v !== 'string' || !MODEL_ID[provider].test(v.trim())) throw new HttpError(400, `That isn't a ${PROVIDER_LABEL[provider]} model id. Leave it empty for the default.`);
  return v.trim();
}

export function aiRouter(db: Db, { client, aiFetch = fetch }: { hosted: boolean; client: SharedClient; aiFetch?: AiFetch }) {
  const router = express.Router();
  // Errors are answered here rather than by the app's handler, which logs the whole error.
  const h = (fn: (req: Request, res: Response) => Promise<void>) => async (req: Request, res: Response) => {
    try {
      await fn(req, res);
    } catch (err) {
      if (err instanceof HttpError) return void res.status(err.status).json({ error: err.message });
      // The kind of failure only, never what was sent (a key, or a recording).
      console.error('ai:', err instanceof AiError ? err.message : err instanceof Error ? err.name : 'error');
      if (!res.headersSent) res.status(500).json({ error: 'Something went wrong. Try again in a moment.' });
    }
  };
  const providerOf = (req: Request): AiProvider => {
    const p = req.params.provider;
    if (!isProvider(p)) throw new HttpError(404, 'Unknown AI provider.');
    return p;
  };
  const status = async (res: Response) => res.json(await aiStatus(db, currentUser(res).id, client));

  router.get(
    '/',
    h(async (_req, res) => {
      await status(res);
    }),
  );

  router.put(
    '/keys/:provider',
    h(async (req, res) => {
      const provider = providerOf(req);
      if (!keysAvailable()) throw new HttpError(503, NOT_SET_UP);
      const userId = currentUser(res).id;
      const b = (req.body ?? {}) as { key?: unknown; model?: unknown };
      const key = typeof b.key === 'string' ? b.key.trim() : '';
      const stored = (await keyInfos(db, userId)).find((k) => k.provider === provider);
      // No key: just the model for the one already stored (Profile → Chatbot). Left out, a new key keeps the model.
      const model = b.model === undefined ? (stored?.model ?? null) : modelFrom(provider, b.model);
      if (!key && stored) {
        await setKeyModel(db, userId, provider, model);
        await bumpDataVersion(db, userId);
        return void (await status(res));
      }
      if (!key) throw new HttpError(400, 'Paste your API key.');
      const problem = keyProblem(provider, key);
      if (problem) throw new HttpError(400, problem);
      const label = PROVIDER_LABEL[provider];
      const check = await verifyKey(aiFetch, provider, key);
      if (check === 'rejected') throw new HttpError(400, `That key wasn't accepted by ${label}.`);
      if (check === 'unreachable') throw new HttpError(502, `Couldn't reach ${label} to check the key. Try again in a moment.`);
      await saveKey(db, userId, provider, key, model);
      await bumpDataVersion(db, userId);
      await status(res);
    }),
  );

  // Works even where keys can no longer be stored: removing your own data is never refused.
  router.delete(
    '/keys/:provider',
    h(async (req, res) => {
      const provider = providerOf(req);
      const userId = currentUser(res).id;
      await db.tx(async (q) => {
        await deleteKey(q, userId, provider);
        // A chat that used this key goes back to the shared assistant.
        const [chosen] = await q.query<{ value: string }>("SELECT value FROM user_settings WHERE user_id = $1 AND key = 'chat_provider'", [userId]);
        if (chosen?.value === provider) {
          await setUserSetting(q, userId, 'chat_provider', null);
          await setUserSetting(q, userId, 'chat_model', null);
        }
      });
      await bumpDataVersion(db, userId);
      await status(res);
    }),
  );

  router.put(
    '/chat',
    h(async (req, res) => {
      const userId = currentUser(res).id;
      const b = (req.body ?? {}) as { provider?: unknown; model?: unknown };
      if (b.provider === 'shared') {
        await setUserSetting(db, userId, 'chat_provider', null);
        await setUserSetting(db, userId, 'chat_model', null);
      } else if (isProvider(b.provider)) {
        if (!keysAvailable()) throw new HttpError(503, NOT_SET_UP);
        const model = modelFrom(b.provider, b.model);
        if (!(await ownKeys(db, userId)).has(b.provider)) throw new HttpError(400, `Connect your ${PROVIDER_LABEL[b.provider]} key first.`);
        await setUserSetting(db, userId, 'chat_provider', b.provider);
        await setUserSetting(db, userId, 'chat_model', model);
      } else {
        throw new HttpError(400, 'Choose OpenAI, Claude, Gemini or the shared assistant.');
      }
      await bumpDataVersion(db, userId);
      await status(res);
    }),
  );

  /** A voice note's words, for the person to check before they're used. The audio is forwarded and forgotten. */
  router.post(
    '/transcribe',
    express.raw({ type: (req) => /^audio\//i.test(String(req.headers['content-type'] ?? '')), limit: MAX_AUDIO }),
    h(async (req, res) => {
      const raw = String(req.headers['content-type'] ?? '')
        .split(';')[0]
        .trim()
        .toLowerCase();
      const type = AUDIO_ALIASES[raw] ?? raw;
      const audio = Buffer.isBuffer(req.body) ? req.body : null;
      const format = AUDIO[type];
      if (!format || !audio) throw new HttpError(415, 'Send the recording as WebM, MP4, MP3 or WAV audio.');
      if (!audio.length) throw new HttpError(400, 'That recording is empty.');
      if (!format.is(audio)) throw new HttpError(400, "That recording couldn't be read.");
      const userId = currentUser(res).id;
      const openai = await openaiKeyFor(db, userId);
      if (!openai) throw new HttpError(503, 'Voice notes need an OpenAI key. Connect one in your Profile.');
      const platform = await platformSettings(db);
      const form = new FormData();
      form.append('file', new Blob([new Uint8Array(audio)], { type }), `voice-note.${format.ext}`);
      form.append('model', platform.openai_transcribe_model);
      form.append('response_format', 'json');
      // Counted just before the call, and given back if it fails.
      const day = usageDay();
      if (openai.source === 'shared' && (await claimVoiceNote(db, userId, day)) === null) {
        const orOwn = keysAvailable() ? ', or connect your own OpenAI key in your Profile' : '';
        throw new HttpError(429, `You've used today's ${VOICE_NOTES_PER_DAY} voice notes on healthOS's shared key. Type what you had instead${orOwn}.`);
      }
      let text: string;
      try {
        // FormData sets its own multipart Content-Type, with the boundary.
        const r = await send(aiFetch, `${OPENAI_API}/audio/transcriptions`, { method: 'POST', headers: { Authorization: `Bearer ${openai.key}` }, body: form, signal: AbortSignal.timeout(60_000) });
        if (!r.ok) throw await openaiError(r);
        const body = (await r.json().catch(() => null)) as { text?: unknown } | null;
        if (typeof body?.text !== 'string') throw new AiError('server');
        text = body.text.trim();
      } catch (err) {
        if (openai.source === 'shared') await refundVoiceNote(db, userId, day).catch(() => {});
        await noteOwnUse(db, userId, 'openai', openai.source, err);
        const kind = err instanceof AiError ? err.kind : 'network';
        console.error('transcribe:', kind);
        const own = openai.source === 'own';
        if (kind === 'auth') throw new HttpError(502, own ? "Your OpenAI key isn't working. Check it in your Profile." : "Voice notes aren't working on this server right now.");
        if (kind === 'quota') throw new HttpError(502, own ? 'Your OpenAI account is out of credit.' : "Voice notes aren't working on this server right now.");
        if (kind === 'rate' || kind === 'server') throw new HttpError(503, 'OpenAI is busy right now. Try again in a minute.');
        if (kind === 'bad_request') throw new HttpError(400, "That recording couldn't be transcribed. Try again, or type it instead.");
        throw new HttpError(502, "Couldn't reach OpenAI. Try again in a moment.");
      }
      await noteOwnUse(db, userId, 'openai', openai.source);
      res.json({ text });
    }),
  );

  // A recording over the limit, or one that couldn't be read, in plain words (the body parser's own are technical).
  router.use((err: Error & { status?: number; type?: string }, _req: Request, res: Response, next: NextFunction) => {
    if (err.type === 'entity.too.large') return void res.status(413).json({ error: 'That recording is too long. Keep voice notes to about a minute.' });
    if (err.status && err.status >= 400 && err.status < 500) return void res.status(400).json({ error: "That recording couldn't be read." });
    next(err);
  });

  return router;
}
