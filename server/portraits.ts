// Portraits (shared/portraits.ts): private reference photos, and likenesses made from them in the healthOS style on an
// OpenAI key: the person's own when they've connected one, else the server's OPENAI_API_KEY (server/ai/resolve.ts).
// Mounted before the general JSON parser, since a reference photo is a few MB.
//
//   GET    /            every photo's metadata (never the images), the portrait in use, and whether one can be made
//   POST   /reference   a JPEG shrunk on the device, checked by its own bytes; at most MAX_REFERENCES
//   GET    /:id/image   the image, to its owner only
//   POST   /generate    starts a portrait from a reference; it's made in the background and the client polls GET /
//   POST   /:id/choose  marks a ready portrait as the one in use (the browser has just saved it as the profile photo)
//   DELETE /:id         one photo or portrait
//
// A reference is a face photo: only its owner reads it, it goes nowhere but that one OpenAI call, and neither it nor
// anything generated is ever logged. Nothing generated is shown on the dashboard until the person chooses it; then the
// browser cuts it out on the device and saves it as the profile photo (POST /api/profile/photo/upload), which Home,
// Body, the Family board and the iPhone app show.
import { randomUUID } from 'node:crypto';
import { waitUntil } from '@vercel/functions';
import express, { type NextFunction, type Request, type Response } from 'express';
import type { AiSource } from '../shared/ai.ts';
import {
  MAX_GENERATED,
  MAX_REFERENCE_BASE64,
  MAX_REFERENCE_EDGE,
  MAX_REFERENCES,
  PORTRAITS_PER_DAY,
  type Portrait,
  type PortraitCreated,
  type PortraitList,
} from '../shared/portraits.ts';
import { OPENAI_API } from './ai/openai.ts';
import { AiError, type AiFetch, errorCodes, kindOf, send } from './ai/provider.ts';
import { noteOwnUse, openaiKeyFor } from './ai/resolve.ts';
import { HttpError, currentUser } from './auth.ts';
import { type Db, type Queryable, bumpDataVersion, getUserSetting, setUserSetting } from './db.ts';
import { pngSize } from './photo.ts';
import { STYLE_REFERENCE, STYLE_REFERENCE_BASE64 } from './portraitStyle.ts';

/**
 * OpenAI's image model for portraits. Checked against OpenAI's image generation guide and model pages in October 2026:
 * GPT Image 2.5 Sunburst is the one "for workflows where editing precision matters most" (keeping a likeness is exactly
 * that), on the edits endpoint with several input images; gpt-image-1 has been shut down. A constant rather than an
 * admin setting: another model means checking the prompt and the parameters below against it.
 */
export const PORTRAIT_MODEL = 'gpt-image-2.5-sunburst';

/**
 * Image 1 is the person, image 2 the healthOS figure. The face has to stay a real face (the figure's is blank): the
 * browser's cut-out finds the face first, and a portrait without one can't become the profile photo.
 */
export const PORTRAIT_PROMPT = [
  'Image 1 is a photo of a person. Image 2 is the healthOS figure, the style to follow.',
  'Make a full-body, front-facing figure of the person in image 1 in exactly the style of image 2: a smooth matte porcelain-ivory 3D sculpture,',
  'soft studio light with a warm amber rim light.',
  'Keep their likeness: face shape and features (eyes, nose, mouth, eyebrows), hairstyle, build and proportions, all sculpted in the same ivory',
  'material. The face is clearly visible, looking straight ahead, eyes open.',
  'Neutral standing pose, arms relaxed and a little away from the body, feet slightly apart; the whole figure in frame from the top of the head',
  'to the feet, centered, with some space around it.',
  'Simple close-fitting clothes in the same ivory material, with no logos or patterns.',
  'Transparent background, no ground shadow, no text, no other people or objects.',
].join(' ');

/** Portrait-shaped, and WebP: a transparent figure at a fraction of a PNG's size (it's stored, and shown as thumbnails). */
const OUTPUT = { size: '1024x1536', quality: 'high', format: 'webp', compression: '90' } as const;
/** OpenAI says a complex image can take two minutes. Under the hosted function's 300 s limit, with time left to save it. */
const GENERATE_TIMEOUT_MS = 240_000;
/** Still pending after this, a portrait was cut off (the function ended, or the server restarted): it's marked failed. */
const STALE_MS = 6 * 60_000;
/** A generated image larger than this isn't kept. */
const MAX_IMAGE_BYTES = 12 * 1_048_576;

const BASE64 = /^[A-Za-z0-9+/]+={0,2}$/;
const IMAGE_TYPES = new Set(['image/jpeg', 'image/png', 'image/webp']);

export const NO_KEY = 'Connect your OpenAI key in your Profile to make a portrait.';
const NOT_A_JPEG = "That photo couldn't be read as a JPEG. Choose it again: healthOS converts it on your device.";
const TOO_LARGE = 'That photo is too large to save. Choose it again: healthOS shrinks it on your device.';
const TOOK_TOO_LONG = 'Making this portrait took too long. Try again.';
const NOTHING_BACK = "OpenAI didn't send back a portrait. Try again.";
const DECLINED = 'OpenAI declined to make a portrait from this photo. Try another photo of just you.';

/** A failure whose message is already the plain words to show. */
class PortraitError extends Error {}

type Row = {
  id: string;
  kind: Portrait['kind'];
  status: Portrait['status'];
  mime: string;
  width: number | null;
  height: number | null;
  bytes: number;
  reference_id: string | null;
  error: string;
  created_at: number;
};
/** Everything but the image itself. */
const COLS = 'id, kind, status, mime, width, height, bytes, reference_id, error, created_at';

const portraitOf = (r: Row): Portrait => ({
  id: r.id,
  kind: r.kind,
  status: r.status,
  mime: r.mime,
  width: r.width === null ? null : Number(r.width),
  height: r.height === null ? null : Number(r.height),
  bytes: Number(r.bytes),
  referenceId: r.reference_id,
  error: r.error,
  createdAt: Number(r.created_at),
});

// ---------- images, by their own bytes ----------

type Size = { width: number; height: number };

/** Width and height of a JPEG (its frame header), or null when the bytes aren't one. */
export function jpegSize(buf: Buffer): Size | null {
  if (buf.length < 4 || buf[0] !== 0xff || buf[1] !== 0xd8 || buf[2] !== 0xff) return null;
  let i = 2;
  while (i + 9 <= buf.length) {
    if (buf[i] !== 0xff) return null;
    const marker = buf[i + 1];
    // Fill bytes, and the markers that have no length.
    if (marker === 0xff) i += 1;
    else if (marker === 0x01 || (marker >= 0xd0 && marker <= 0xd8)) i += 2;
    // The image data (or its end) before any frame header: not a usable JPEG.
    else if (marker === 0xd9 || marker === 0xda) return null;
    // SOF0–SOF15, except DHT (C4), JPG (C8) and DAC (CC): height, then width.
    else if (marker >= 0xc0 && marker <= 0xcf && marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc) {
      return { height: buf.readUInt16BE(i + 5), width: buf.readUInt16BE(i + 7) };
    } else {
      const len = buf.readUInt16BE(i + 2);
      if (len < 2) return null;
      i += 2 + len;
    }
  }
  return null;
}

/** Width and height of a WebP (lossy, lossless or extended), or null when the bytes aren't one. */
export function webpSize(buf: Buffer): Size | null {
  if (buf.length < 30 || buf.toString('latin1', 0, 4) !== 'RIFF' || buf.toString('latin1', 8, 12) !== 'WEBP') return null;
  const chunk = buf.toString('latin1', 12, 16);
  if (chunk === 'VP8X') return { width: 1 + buf.readUIntLE(24, 3), height: 1 + buf.readUIntLE(27, 3) };
  if (chunk === 'VP8L' && buf[20] === 0x2f) {
    const bits = buf.readUInt32LE(21);
    return { width: 1 + (bits & 0x3fff), height: 1 + ((bits >>> 14) & 0x3fff) };
  }
  if (chunk === 'VP8 ' && buf.readUIntLE(23, 3) === 0x2a019d) return { width: buf.readUInt16LE(26) & 0x3fff, height: buf.readUInt16LE(28) & 0x3fff };
  return null;
}

/** What an image is by its bytes, and its size; null for anything else. */
function imageOf(buf: Buffer): (Size & { mime: string }) | null {
  const jpeg = jpegSize(buf);
  if (jpeg) return { mime: 'image/jpeg', ...jpeg };
  const png = pngSize(buf);
  if (png) return { mime: 'image/png', ...png };
  const webp = webpSize(buf);
  return webp ? { mime: 'image/webp', ...webp } : null;
}

let style: Uint8Array<ArrayBuffer> | null = null;
const styleBytes = () => (style ??= new Uint8Array(Buffer.from(STYLE_REFERENCE_BASE64, 'base64')));

// ---------- the day's count, and the portrait in use ----------

const utcDay = () => new Date().toISOString().slice(0, 10);

/** The day's count from its stored value: 0 when it's from an earlier day, or can't be read. */
function countOn(raw: string | undefined, day: string): number {
  try {
    const u = JSON.parse(raw ?? 'null') as { day?: unknown; count?: unknown } | null;
    return u?.day === day && typeof u.count === 'number' ? u.count : 0;
  } catch {
    return 0;
  }
}

/**
 * Changes the count of portraits started today (UTC), which is kept apart from the rows so deleting portraits doesn't
 * make room for more. Its row is locked while it's read and written: requests in parallel can't both take the day's
 * last portrait, or lose each other's change. False, with nothing changed, when it would go past PORTRAITS_PER_DAY.
 */
async function changeUsage(db: Db, userId: string, day: string, n: 1 | -1): Promise<boolean> {
  return db.tx(async (q) => {
    // A row to lock, when there isn't one yet.
    await q.query(`INSERT INTO user_settings (user_id, key, value) VALUES ($1, 'portrait_usage', $2) ON CONFLICT (user_id, key) DO NOTHING`, [
      userId,
      JSON.stringify({ day, count: 0 }),
    ]);
    const [row] = await q.query<{ value: string }>(`SELECT value FROM user_settings WHERE user_id = $1 AND key = 'portrait_usage' FOR UPDATE`, [userId]);
    const count = countOn(row?.value, day) + n;
    if (count > PORTRAITS_PER_DAY) return false;
    await setUserSetting(q, userId, 'portrait_usage', JSON.stringify({ day, count: Math.max(0, count) }));
    return true;
  });
}

/** Counts a portrait toward today's; false when today's are used up. */
export const claimPortrait = (db: Db, userId: string, day: string) => changeUsage(db, userId, day, 1);

/** One that wasn't made doesn't count toward the day's. After midnight there's nothing to give back. */
async function refundPortrait(db: Db, userId: string, day: string) {
  if (day === utcDay()) await changeUsage(db, userId, day, -1);
}

const photoVersion = (raw: string | undefined) => {
  try {
    const v = (JSON.parse(raw ?? 'null') as { version?: unknown } | null)?.version;
    return typeof v === 'number' ? String(v) : null;
  } catch {
    return null;
  }
};

/**
 * The portrait in use: the one chosen, while the profile photo is still the one made from it. A new photo since
 * ("Use a photo as is", the Mac or the iPhone app) or removing it means no portrait is in use any more.
 */
async function chosenOf(q: Queryable, userId: string): Promise<string | null> {
  const [id, photo, meta] = await Promise.all([
    getUserSetting(q, userId, 'portrait_chosen'),
    getUserSetting(q, userId, 'portrait_chosen_photo'),
    getUserSetting(q, userId, 'photo_meta'),
  ]);
  const version = photoVersion(meta);
  return id && version !== null && photo === version ? id : null;
}

/** Pending for longer than any run can last: it was cut off, so it says so rather than blocking the next one. */
async function expireStale(q: Queryable, userId: string) {
  await q.query(`UPDATE portraits SET status = 'failed', error = $3 WHERE user_id = $1 AND status = 'pending' AND created_at < $2`, [
    userId,
    Date.now() - STALE_MS,
    TOOK_TOO_LONG,
  ]);
}

async function portraitList(db: Db, userId: string): Promise<PortraitList> {
  await expireStale(db, userId);
  const [rows, chosen, openai] = await Promise.all([
    db.query<Row>(`SELECT ${COLS} FROM portraits WHERE user_id = $1 ORDER BY created_at, id`, [userId]),
    chosenOf(db, userId),
    openaiKeyFor(db, userId),
  ]);
  return { portraits: rows.map(portraitOf), chosen, canGenerate: openai !== null };
}

// ---------- making a portrait ----------

/** OpenAI's image edit with two inputs, the person and the healthOS figure. Returns the image, checked by its bytes. */
async function requestPortrait(fetchFn: AiFetch, key: string, reference: Uint8Array<ArrayBuffer>) {
  const form = new FormData();
  form.append('model', PORTRAIT_MODEL);
  form.append('prompt', PORTRAIT_PROMPT);
  // The person first and the style second, as the prompt says.
  form.append('image[]', new Blob([reference], { type: 'image/jpeg' }), 'person.jpg');
  form.append('image[]', new Blob([styleBytes()], { type: STYLE_REFERENCE.mime }), STYLE_REFERENCE.name);
  form.append('background', 'transparent');
  form.append('output_format', OUTPUT.format);
  form.append('output_compression', OUTPUT.compression);
  form.append('size', OUTPUT.size);
  form.append('quality', OUTPUT.quality);
  form.append('n', '1');
  // FormData sets its own multipart Content-Type, with the boundary.
  const r = await send(fetchFn, `${OPENAI_API}/images/edits`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${key}` },
    body: form,
    signal: AbortSignal.timeout(GENERATE_TIMEOUT_MS),
  });
  if (!r.ok) {
    // Only the error's codes are read, never its message (it can echo part of the key).
    const codes = await errorCodes(r);
    if (/moderation_blocked|content_policy/.test(codes)) throw new PortraitError(DECLINED);
    const kind = kindOf(r.status, /insufficient_quota|credit_balance|spend_limit|usage_limit|billing/.test(codes));
    // A refused request is most likely a parameter or the model id: its codes (kinds, never the message) say which.
    if (kind === 'bad_request') console.error('portraits: bad request', r.status, codes);
    throw new AiError(kind, r.status);
  }
  const body = (await r.json().catch(() => null)) as { data?: { b64_json?: unknown }[] } | null;
  const b64 = body?.data?.[0]?.b64_json;
  if (typeof b64 !== 'string' || !BASE64.test(b64)) throw new PortraitError(NOTHING_BACK);
  const data = Buffer.from(b64, 'base64');
  const image = imageOf(data);
  if (!image || data.length > MAX_IMAGE_BYTES) throw new PortraitError(NOTHING_BACK);
  return { data, ...image };
}

/** What went wrong, in plain words for the portrait's card. */
function failureText(err: unknown, source: AiSource) {
  if (err instanceof PortraitError) return err.message;
  if (err instanceof Error && (err.name === 'TimeoutError' || err.name === 'AbortError')) return TOOK_TOO_LONG;
  const kind = err instanceof AiError ? err.kind : 'server';
  const own = source === 'own';
  if (kind === 'auth') return own ? "Your OpenAI key isn't working. Check it in your Profile." : "Portraits aren't working on this server right now.";
  if (kind === 'quota') return own ? 'Your OpenAI account is out of credit.' : "Portraits aren't working on this server right now.";
  if (kind === 'rate' || kind === 'server') return 'OpenAI is busy right now. Try again in a minute.';
  if (kind === 'network') return "Couldn't reach OpenAI. Try again in a minute.";
  // Not the photo's fault as far as we know (that's DECLINED): more likely the request, so don't send them to another photo.
  return "OpenAI couldn't make this portrait just now. Try again later.";
}

/** The kind of failure for the log: never the image, the key or what the provider said. */
const logKind = (err: unknown) =>
  err instanceof AiError ? err.message : err instanceof PortraitError ? 'no portrait' : err instanceof Error ? err.name : 'error';

type Job = { userId: string; id: string; reference: Uint8Array<ArrayBuffer>; openai: { key: string; source: AiSource }; day: string };

/** Runs after the response: the portrait ends up ready with its image, or failed with a reason. */
async function makePortrait(db: Db, fetchFn: AiFetch, { userId, id, reference, openai, day }: Job) {
  try {
    const image = await requestPortrait(fetchFn, openai.key, reference);
    await db.query(
      `UPDATE portraits SET status = 'ready', mime = $3, data = $4, width = $5, height = $6, bytes = $7, error = '' WHERE user_id = $1 AND id = $2 AND status = 'pending'`,
      [userId, id, image.mime, image.data, image.width, image.height, image.data.length],
    );
    await noteOwnUse(db, userId, 'openai', openai.source);
  } catch (err) {
    console.error('portraits:', logKind(err));
    await noteOwnUse(db, userId, 'openai', openai.source, err);
    await db.query(`UPDATE portraits SET status = 'failed', error = $3 WHERE user_id = $1 AND id = $2 AND status = 'pending'`, [userId, id, failureText(err, openai.source)]);
    await refundPortrait(db, userId, day);
  }
  await bumpDataVersion(db, userId);
}

// ---------- the routes ----------

export function portraitsRouter(db: Db, _hosted: boolean, aiFetch: AiFetch = fetch) {
  const router = express.Router();
  // The reference's base64, and a little for the rest of its JSON.
  const referenceJson = express.json({ limit: MAX_REFERENCE_BASE64 + 64 * 1024 });
  const smallJson = express.json({ limit: '16kb' });
  const userOf = (res: Response) => currentUser(res).id;
  const idOf = (req: Request) => String(req.params.id);
  // Errors are answered here rather than by the app's handler, which logs the whole error.
  const h = (fn: (req: Request, res: Response) => Promise<void>) => async (req: Request, res: Response) => {
    try {
      await fn(req, res);
    } catch (err) {
      if (err instanceof HttpError) return void res.status(err.status).json({ error: err.message });
      console.error('portraits:', logKind(err));
      if (!res.headersSent) res.status(500).json({ error: 'Something went wrong. Try again in a moment.' });
    }
  };

  router.get(
    '/',
    h(async (_req, res) => {
      res.json(await portraitList(db, userOf(res)));
    }),
  );

  router.post(
    '/reference',
    referenceJson,
    h(async (req, res) => {
      const userId = userOf(res);
      const image = (req.body as { image?: unknown } | undefined)?.image;
      if (typeof image !== 'string' || !image) throw new HttpError(400, NOT_A_JPEG);
      if (image.length > MAX_REFERENCE_BASE64) throw new HttpError(413, TOO_LARGE);
      // Checked before decoding: Buffer.from skips anything that isn't base64 rather than refusing it.
      if (image.length % 4 !== 0 || !BASE64.test(image)) throw new HttpError(400, NOT_A_JPEG);
      const data = Buffer.from(image, 'base64');
      // The bytes say what it is and how big, whatever the request says.
      const size = jpegSize(data);
      if (!size || !size.width || !size.height) throw new HttpError(400, NOT_A_JPEG);
      if (Math.max(size.width, size.height) > MAX_REFERENCE_EDGE) throw new HttpError(413, TOO_LARGE);
      const rows = await db.query<Row>(
        `INSERT INTO portraits (user_id, id, kind, status, mime, data, width, height, bytes, created_at)
         SELECT $1, $2, 'reference', 'ready', 'image/jpeg', $3::bytea, $4::integer, $5::integer, $6::integer, $7::double precision
         WHERE (SELECT count(*) FROM portraits WHERE user_id = $1 AND kind = 'reference') < $8::integer
         RETURNING ${COLS}`,
        [userId, randomUUID(), data, size.width, size.height, data.length, Date.now(), MAX_REFERENCES],
      );
      if (!rows.length) throw new HttpError(409, `You already have ${MAX_REFERENCES} reference photos. Delete one, such as the oldest, to add another.`);
      await bumpDataVersion(db, userId);
      res.json({ portrait: portraitOf(rows[0]) } satisfies PortraitCreated);
    }),
  );

  router.get(
    '/:id/image',
    h(async (req, res) => {
      const [row] = await db.query<{ mime: string; data: Uint8Array | null }>('SELECT mime, data FROM portraits WHERE user_id = $1 AND id = $2', [
        userOf(res),
        idOf(req),
      ]);
      // Someone else's looks exactly like one that doesn't exist.
      if (!row?.data || !IMAGE_TYPES.has(row.mime)) throw new HttpError(404, 'Not found');
      res.setHeader('X-Content-Type-Options', 'nosniff');
      res.setHeader('Cache-Control', 'private, no-store');
      res.type(row.mime).send(Buffer.from(row.data));
    }),
  );

  router.post(
    '/generate',
    smallJson,
    h(async (req, res) => {
      const userId = userOf(res);
      const referenceId = (req.body as { referenceId?: unknown } | undefined)?.referenceId;
      if (typeof referenceId !== 'string' || !referenceId) throw new HttpError(400, 'Choose the reference photo to make your portrait from.');
      // Read now, in the request: the background run doesn't go back to the database for it.
      const [ref] = await db.query<{ data: Uint8Array | null }>(`SELECT data FROM portraits WHERE user_id = $1 AND id = $2 AND kind = 'reference'`, [
        userId,
        referenceId,
      ]);
      if (!ref?.data) throw new HttpError(404, 'That reference photo is gone. Add it again to make a portrait.');
      const openai = await openaiKeyFor(db, userId);
      if (!openai) throw new HttpError(409, NO_KEY);
      await expireStale(db, userId);
      // The count includes the one being made, and only one can be (below), so two requests can't pass it together.
      const [made] = await db.query<{ n: number }>(`SELECT count(*)::integer AS n FROM portraits WHERE user_id = $1 AND kind = 'generated'`, [userId]);
      if (Number(made?.n) >= MAX_GENERATED) throw new HttpError(409, `You have ${MAX_GENERATED} portraits. Delete one you don't need to make another.`);
      const day = utcDay();
      if (!(await claimPortrait(db, userId, day))) {
        throw new HttpError(429, `You've made ${PORTRAITS_PER_DAY} portraits today, the most in a day. Try again tomorrow.`);
      }
      // One at a time: the new one goes in only when none is being made. The unique index on pending portraits (migration
      // 16) holds that for requests in parallel too: the one that loses inserts nothing, and gets the same answer.
      const rows = await db
        .query<Row>(
          `INSERT INTO portraits (user_id, id, kind, status, mime, bytes, reference_id, model, created_at)
           SELECT $1, $2, 'generated', 'pending', $3, 0, $4, $5, $6::double precision
           WHERE NOT EXISTS (SELECT 1 FROM portraits WHERE user_id = $1 AND kind = 'generated' AND status = 'pending')
           ON CONFLICT DO NOTHING
           RETURNING ${COLS}`,
          [userId, randomUUID(), `image/${OUTPUT.format}`, referenceId, PORTRAIT_MODEL, Date.now()],
        )
        .catch(async (err) => {
          await refundPortrait(db, userId, day).catch(() => {});
          throw err;
        });
      if (!rows.length) {
        await refundPortrait(db, userId, day);
        throw new HttpError(409, 'Your portrait is still being made. It can take a minute or two.');
      }
      const portrait = portraitOf(rows[0]);
      // Background work must outlive the response on Vercel; waitUntil keeps the function alive for it. Started first:
      // from here on, a portrait that isn't made is given back by makePortrait.
      const job: Job = { userId, id: portrait.id, reference: new Uint8Array(ref.data), openai, day };
      waitUntil(makePortrait(db, aiFetch, job).catch((err) => console.error('portraits: saving failed:', logKind(err))));
      await bumpDataVersion(db, userId);
      res.status(202).json({ portrait } satisfies PortraitCreated);
    }),
  );

  router.post(
    '/:id/choose',
    h(async (req, res) => {
      const userId = userOf(res);
      const id = idOf(req);
      const [row] = await db.query<{ kind: string; status: string }>('SELECT kind, status FROM portraits WHERE user_id = $1 AND id = $2', [userId, id]);
      if (!row) throw new HttpError(404, 'That portrait is gone.');
      if (row.kind !== 'generated' || row.status !== 'ready') throw new HttpError(400, 'Only a finished portrait can be used.');
      // Remembered with the profile photo it became, so a different photo later means it's no longer the one in use.
      const version = photoVersion(await getUserSetting(db, userId, 'photo_meta'));
      await db.tx(async (q) => {
        await setUserSetting(q, userId, 'portrait_chosen', id);
        await setUserSetting(q, userId, 'portrait_chosen_photo', version);
      });
      await bumpDataVersion(db, userId);
      res.json(await portraitList(db, userId));
    }),
  );

  router.delete(
    '/:id',
    h(async (req, res) => {
      const userId = userOf(res);
      const id = idOf(req);
      const gone = await db.query('DELETE FROM portraits WHERE user_id = $1 AND id = $2 RETURNING id', [userId, id]);
      if (!gone.length) throw new HttpError(404, 'That photo is already gone.');
      // The profile photo made from it stays (Profile → Use a photo as is removes that); it's just no longer "in use".
      if ((await getUserSetting(db, userId, 'portrait_chosen')) === id) {
        await db.tx(async (q) => {
          await setUserSetting(q, userId, 'portrait_chosen', null);
          await setUserSetting(q, userId, 'portrait_chosen_photo', null);
        });
      }
      await bumpDataVersion(db, userId);
      res.json(await portraitList(db, userId));
    }),
  );

  router.use((err: Error & { status?: number; type?: string }, _req: Request, res: Response, next: NextFunction) => {
    // Body errors get plain words; anything else goes on to the app's handler.
    if (err.type === 'entity.too.large') return void res.status(413).json({ error: TOO_LARGE });
    if (err.type === 'entity.parse.failed') return void res.status(400).json({ error: "That request wasn't readable. Try again." });
    next(err);
  });

  return router;
}
