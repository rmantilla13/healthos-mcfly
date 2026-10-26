// Your own AI keys, stored encrypted (table ai_keys, migration 13). AES-256-GCM with a key derived (HKDF-SHA256) from
// HEALTHOS_DATA_KEY, a random 12-byte IV per row, and the row's user and provider as associated data, so a row copied to
// another account or provider doesn't decrypt. Never from SESSION_SECRET: setup-vercel.sh rotates that on every run.
// - Without HEALTHOS_DATA_KEY nobody can store a key, and everyone uses the server's shared Claude key as before.
// - To rotate: set the new key as HEALTHOS_DATA_KEY and the old one as HEALTHOS_DATA_KEY_PREVIOUS. Each row names the
//   key that sealed it (key_version, a short fingerprint), and is sealed again with the new key the next time it's read.
// - A key is never logged, returned or exported: the browser sees the provider and its last 4 characters only.
import { createCipheriv, createDecipheriv, createHmac, hkdfSync, randomBytes } from 'node:crypto';
import type { AiKeyInfo, AiProvider } from '../../shared/ai.ts';
import type { Queryable } from '../db.ts';

const INFO = 'healthos:ai-keys:v1';
export const PROVIDERS: AiProvider[] = ['openai', 'anthropic', 'gemini'];
export const isProvider = (v: unknown): v is AiProvider => PROVIDERS.includes(v as AiProvider);

type DataKey = { version: number; key: Buffer };

/** HEALTHOS_DATA_KEY as bytes: hex or base64, at least 32 bytes; null when unset or too short. */
function secretBytes(raw: string | undefined): Buffer | null {
  const s = raw?.trim();
  if (!s) return null;
  const bytes = /^[0-9a-f]+$/i.test(s) && s.length % 2 === 0 ? Buffer.from(s, 'hex') : /^[A-Za-z0-9+/_-]+={0,2}$/.test(s) ? Buffer.from(s, 'base64') : null;
  return bytes && bytes.length >= 32 ? bytes : null;
}

const derived = new Map<string, DataKey>();
let warned = false;

function dataKey(raw: string | undefined): DataKey | null {
  const bytes = secretBytes(raw);
  if (!bytes) {
    if (raw?.trim() && !warned) {
      warned = true;
      console.error("HEALTHOS_DATA_KEY isn't 32 bytes of hex or base64: storing your own AI keys is off.");
    }
    return null;
  }
  const id = bytes.toString('hex');
  let k = derived.get(id);
  if (!k) {
    const key = Buffer.from(hkdfSync('sha256', bytes, Buffer.alloc(0), INFO, 32));
    // Which key sealed a row, without saying anything about the key: 15 bits of an HMAC under it (1 to 32767).
    const version = (createHmac('sha256', key).update('healthos:ai-keys:version').digest().readUInt16BE(0) & 0x7fff) || 1;
    k = { version, key };
    derived.set(id, k);
  }
  return k;
}

const currentKey = () => dataKey(process.env.HEALTHOS_DATA_KEY);
const previousKey = () => dataKey(process.env.HEALTHOS_DATA_KEY_PREVIOUS);

/** Keys can be stored on this server. */
export const keysAvailable = () => currentKey() !== null;

const aad = (userId: string, provider: AiProvider) => Buffer.from(`${userId}|${provider}`, 'utf8');

export type Sealed = { ciphertext: Buffer; iv: Buffer; tag: Buffer; keyVersion: number };

export function seal(userId: string, provider: AiProvider, secret: string): Sealed {
  const k = currentKey();
  if (!k) throw new Error('no data key');
  const iv = randomBytes(12);
  const cipher = createCipheriv('aes-256-gcm', k.key, iv);
  cipher.setAAD(aad(userId, provider));
  const ciphertext = Buffer.concat([cipher.update(secret, 'utf8'), cipher.final()]);
  return { ciphertext, iv, tag: cipher.getAuthTag(), keyVersion: k.version };
}

/** The secret, and whether it was sealed with the previous key (so it should be sealed again); null if it won't open. */
export function open(userId: string, provider: AiProvider, s: Sealed): { secret: string; stale: boolean } | null {
  const cur = currentKey();
  const prev = previousKey();
  // The key the row names first; the other too, in case two fingerprints ever match.
  const order = [cur, prev].filter((k): k is DataKey => k !== null).sort((a, b) => Number(b.version === s.keyVersion) - Number(a.version === s.keyVersion));
  for (const k of order) {
    try {
      const decipher = createDecipheriv('aes-256-gcm', k.key, s.iv);
      decipher.setAAD(aad(userId, provider));
      decipher.setAuthTag(s.tag);
      const secret = Buffer.concat([decipher.update(s.ciphertext), decipher.final()]).toString('utf8');
      return { secret, stale: k !== cur };
    } catch {
      // Not this key (or the row was moved or altered): try the next.
    }
  }
  return null;
}

type Row = { provider: AiProvider; ciphertext: Uint8Array; iv: Uint8Array; tag: Uint8Array; key_version: number; model: string | null };

/** Store (or replace) a person's key for a provider. */
export async function saveKey(q: Queryable, userId: string, provider: AiProvider, secret: string, model: string | null) {
  const s = seal(userId, provider, secret);
  const now = Date.now();
  await q.query(
    `INSERT INTO ai_keys (user_id, provider, ciphertext, iv, tag, key_version, last4, model, created_at, updated_at, last_used_at, last_error)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $9, NULL, NULL)
     ON CONFLICT (user_id, provider) DO UPDATE SET ciphertext = excluded.ciphertext, iv = excluded.iv, tag = excluded.tag,
       key_version = excluded.key_version, last4 = excluded.last4, model = excluded.model, updated_at = excluded.updated_at,
       last_used_at = NULL, last_error = NULL`,
    [userId, provider, s.ciphertext, s.iv, s.tag, s.keyVersion, secret.slice(-4), model, now],
  );
}

/** The model to use with a stored key (null for the admin's default). */
export async function setKeyModel(q: Queryable, userId: string, provider: AiProvider, model: string | null) {
  await q.query('UPDATE ai_keys SET model = $3, updated_at = $4 WHERE user_id = $1 AND provider = $2', [userId, provider, model, Date.now()]);
}

export async function deleteKey(q: Queryable, userId: string, provider: AiProvider) {
  const rows = await q.query('DELETE FROM ai_keys WHERE user_id = $1 AND provider = $2 RETURNING 1', [userId, provider]);
  return rows.length > 0;
}

/** What the browser may know about a person's keys: never the key. */
export async function keyInfos(q: Queryable, userId: string): Promise<AiKeyInfo[]> {
  const rows = await q.query<{ provider: AiProvider; last4: string; model: string | null; created_at: number; last_used_at: number | null; last_error: string | null }>(
    'SELECT provider, last4, model, created_at, last_used_at, last_error FROM ai_keys WHERE user_id = $1 ORDER BY provider',
    [userId],
  );
  return rows.map((r) => ({
    provider: r.provider,
    last4: r.last4,
    model: r.model,
    addedAt: Number(r.created_at),
    lastUsedAt: r.last_used_at === null ? null : Number(r.last_used_at),
    lastError: r.last_error,
  }));
}

export type OwnKey = { key: string; model: string | null };

/**
 * A person's usable keys, opened for the call being made. A row that won't open (the data key changed without
 * HEALTHOS_DATA_KEY_PREVIOUS) counts as no key, and says so in last_error; one sealed with the previous key is
 * sealed again with the current one.
 */
export async function ownKeys(q: Queryable, userId: string): Promise<Map<AiProvider, OwnKey>> {
  const out = new Map<AiProvider, OwnKey>();
  if (!keysAvailable()) return out;
  const rows = await q.query<Row>('SELECT provider, ciphertext, iv, tag, key_version, model FROM ai_keys WHERE user_id = $1', [userId]);
  for (const r of rows) {
    if (!isProvider(r.provider)) continue;
    const opened = open(userId, r.provider, { ciphertext: Buffer.from(r.ciphertext), iv: Buffer.from(r.iv), tag: Buffer.from(r.tag), keyVersion: Number(r.key_version) });
    if (!opened) {
      await noteKeyUse(q, userId, r.provider, 'unreadable').catch(() => {});
      continue;
    }
    if (opened.stale) {
      const s = seal(userId, r.provider, opened.secret);
      await q
        .query('UPDATE ai_keys SET ciphertext = $3, iv = $4, tag = $5, key_version = $6 WHERE user_id = $1 AND provider = $2', [userId, r.provider, s.ciphertext, s.iv, s.tag, s.keyVersion])
        .catch(() => {});
    }
    out.set(r.provider, { key: opened.secret, model: r.model });
  }
  return out;
}

/** After a call on a person's own key: when it last worked, or why it didn't ('auth', 'quota', 'unreadable'; a kind, never a message). */
export async function noteKeyUse(q: Queryable, userId: string, provider: AiProvider, error: 'auth' | 'quota' | 'unreadable' | null) {
  if (error) await q.query('UPDATE ai_keys SET last_error = $3 WHERE user_id = $1 AND provider = $2', [userId, provider, error]);
  else await q.query('UPDATE ai_keys SET last_used_at = $3, last_error = NULL WHERE user_id = $1 AND provider = $2', [userId, provider, Date.now()]);
}

/**
 * Why a pasted key can't be right, or null. Loose on purpose (providers change their formats); the provider's own
 * check before saving is the real test. It does catch a key pasted under the wrong provider.
 */
export function keyProblem(provider: AiProvider, key: string): string | null {
  if (key.length < 20 || key.length > 400 || !/^[\x21-\x7e]+$/.test(key)) return "That doesn't look like an API key. Paste the whole key, with nothing around it.";
  if (provider !== 'anthropic' && key.startsWith('sk-ant-')) return 'That looks like a Claude key. Choose Claude for it, or paste your key for this provider.';
  if (provider !== 'gemini' && key.startsWith('AIza')) return 'That looks like a Gemini key. Choose Gemini for it, or paste your key for this provider.';
  return null;
}
