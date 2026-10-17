// Profile photo: cut out and measured locally by server/photo/cutout.swift (Apple Vision, macOS only),
// then stored in the database (profile_assets + the photo_meta setting) so the hosted app can serve it.
// The original and working files stay in data/profile on this Mac.
import { execFile } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { promisify } from 'node:util';
import type { PhotoMeta } from '../shared/types.ts';
import { DATA_DIR, OWNER_ID, type Scope, bumpDataVersion, getUserSetting, setUserSetting } from './db.ts';

const run = promisify(execFile);
const SCRIPT = path.join(import.meta.dirname, 'photo', 'cutout.swift');
const BIN = path.join(DATA_DIR, 'bin', 'cutout');
export const PHOTO_ASSETS = ['cutout.png', 'avatar.png'] as const;

/** Working files on this Mac. The owner's stay where they were before healthOS was multi-user. */
export function photoDir(userId: string) {
  return userId === OWNER_ID ? path.join(DATA_DIR, 'profile') : path.join(DATA_DIR, 'profiles', userId);
}

export async function photoMeta(scope: Scope): Promise<PhotoMeta | null> {
  const raw = await getUserSetting(scope.db, scope.userId, 'photo_meta');
  return raw ? (JSON.parse(raw) as PhotoMeta) : null;
}

export async function photoAsset(scope: Scope, name: string): Promise<Buffer | null> {
  const [row] = await scope.db.query<{ data: Uint8Array }>('SELECT data FROM profile_assets WHERE user_id = $1 AND name = $2', [scope.userId, name]);
  return row ? Buffer.from(row.data) : null;
}

export type PhotoLayout = Omit<PhotoMeta, 'version'>;

/** Store a processed photo (cut-out, avatar, layout), replacing that person's previous one. */
export async function storePhotoAssets(scope: Scope, assets: { cutout: Buffer; avatar: Buffer | null; meta: PhotoLayout }): Promise<PhotoMeta> {
  const { db, userId } = scope;
  // Every store gets a new version: the images are served immutable, keyed by ?v=.
  const version = Math.max(Date.now(), ((await photoMeta(scope))?.version ?? 0) + 1);
  await db.tx(async (q) => {
    await q.query('DELETE FROM profile_assets WHERE user_id = $1', [userId]);
    for (const [name, data] of [['cutout.png', assets.cutout], ['avatar.png', assets.avatar]] as const) {
      if (!data) continue;
      await q.query('INSERT INTO profile_assets (user_id, name, mime, data, updated_at) VALUES ($1, $2, $3, $4, $5)', [userId, name, 'image/png', data, version]);
    }
    await setUserSetting(q, userId, 'photo_meta', JSON.stringify({ ...assets.meta, version }));
  });
  await bumpDataVersion(db, userId);
  return { ...assets.meta, version } as PhotoMeta;
}

/** Copy a processed photo folder (the Mac tool's output) into the database. */
export async function storePhoto(scope: Scope, dir = photoDir(scope.userId)): Promise<PhotoMeta> {
  const read = (name: string) => (fs.existsSync(path.join(dir, name)) ? fs.readFileSync(path.join(dir, name)) : null);
  const meta = JSON.parse(fs.readFileSync(path.join(dir, 'meta.json'), 'utf8')) as PhotoLayout;
  return storePhotoAssets(scope, { cutout: read('cutout.png')!, avatar: read('avatar.png'), meta });
}

const MAX_PNG_BYTES = 4 * 1_048_576;

/** Width and height of a PNG, or null when the bytes aren't one. */
export function pngSize(buf: Buffer): { width: number; height: number } | null {
  const signature = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
  if (buf.length < 24 || signature.some((b, i) => buf[i] !== b) || buf.toString('latin1', 12, 16) !== 'IHDR') return null;
  return { width: buf.readUInt32BE(16), height: buf.readUInt32BE(20) };
}

/**
 * A processed photo sent by the browser or the iPhone app ({ cutout, avatar: base64 PNG, meta }). Nothing is
 * trusted: the images must be real PNGs of sensible size, and every layout number 0–1, so a bad upload
 * can't break anyone's Home page. Returns an error message, or the decoded upload.
 */
export function parsePhotoUpload(body: unknown): { cutout: Buffer; avatar: Buffer; meta: PhotoLayout } | string {
  const b = (body ?? {}) as { cutout?: unknown; avatar?: unknown; meta?: unknown };
  const png = (v: unknown) => (typeof v === 'string' && v.length < MAX_PNG_BYTES * 1.4 ? Buffer.from(v, 'base64') : null);
  const cutout = png(b.cutout);
  const avatar = png(b.avatar);
  if (!cutout || !avatar) return 'Send the cut-out and the avatar as PNG images.';
  if (cutout.length > MAX_PNG_BYTES || avatar.length > MAX_PNG_BYTES) return 'That photo is too large. Try a smaller one.';
  const c = pngSize(cutout);
  const a = pngSize(avatar);
  if (!c || !a) return 'Send the cut-out and the avatar as PNG images.';
  if (c.width < 64 || c.height < 64 || c.width > 2400 || c.height > 2400) return 'The cut-out must be 64 to 2,400 pixels on each side.';
  if (a.width < 64 || a.height < 64 || a.width > 1024 || a.height > 1024) return 'The avatar must be 64 to 1,024 pixels on each side.';

  const m = (b.meta ?? {}) as Record<string, unknown>;
  const unit = (v: unknown) => typeof v === 'number' && Number.isFinite(v) && v >= 0 && v <= 1;
  const pair = (v: unknown): v is [number, number] => Array.isArray(v) && v.length === 2 && v.every(unit);
  if (m.width !== c.width || m.height !== c.height) return "The layout doesn't match the cut-out's size.";
  const face = m.face;
  if (!Array.isArray(face) || face.length !== 4 || !face.every(unit) || !(face[2] > 0 && face[3] > 0)) return 'The face box is missing or out of range.';
  if (!unit(m.shoulderY)) return 'The shoulder line is out of range.';
  if (m.outline !== undefined && !(Array.isArray(m.outline) && m.outline.length === 100 && m.outline.every(pair))) return 'The outline must be 100 rows of two numbers from 0 to 1.';
  const dots = (m.dots ?? {}) as Record<string, unknown>;
  const allowed = ['temp', 'breathing', 'heart', 'wrist'];
  if (!pair(dots.temp) || !pair(dots.breathing) || !pair(dots.heart)) return 'The temperature, breathing and heart points are required.';
  if (Object.keys(dots).some((k) => !allowed.includes(k)) || (dots.wrist !== undefined && !pair(dots.wrist))) return 'Unknown or invalid layout point.';
  const meta = {
    width: c.width,
    height: c.height,
    face: face as [number, number, number, number],
    shoulderY: m.shoulderY as number,
    ...(m.outline ? { outline: m.outline as [number, number][] } : {}),
    dots: { temp: dots.temp, breathing: dots.breathing, heart: dots.heart, ...(dots.wrist ? { wrist: dots.wrist as [number, number] } : {}) },
  } as PhotoLayout;
  return { cutout, avatar, meta };
}

/** Compile the Swift tool once (and again whenever the script changes). */
async function ensureBinary() {
  const stale = !fs.existsSync(BIN) || fs.statSync(BIN).mtimeMs < fs.statSync(SCRIPT).mtimeMs;
  if (!stale) return;
  if (process.platform !== 'darwin') throw new Error('Photo processing uses Apple Vision and needs macOS.');
  fs.mkdirSync(path.dirname(BIN), { recursive: true });
  await run('swiftc', ['-O', SCRIPT, '-o', BIN], { timeout: 180_000 });
}

/** Process an image file into data/profile, then store it. Replaces the previous photo only if processing succeeds. */
export async function processPhoto(scope: Scope, input: string): Promise<PhotoMeta> {
  await ensureBinary();
  const dir = photoDir(scope.userId);
  fs.mkdirSync(path.dirname(dir), { recursive: true });
  const work = fs.mkdtempSync(path.join(DATA_DIR, 'profile-'));
  try {
    await run(BIN, [input, work], { timeout: 120_000 }).catch((err: { stderr?: string; message: string }) => {
      // Vision logs its own diagnostics to stderr; the tool's message is the last line.
      throw new Error(err.stderr?.trim().split('\n').at(-1) || err.message);
    });
    fs.rmSync(dir, { recursive: true, force: true });
    fs.renameSync(work, dir);
  } finally {
    fs.rmSync(work, { recursive: true, force: true });
  }
  return storePhoto(scope);
}

export async function removePhoto(scope: Scope) {
  await scope.db.tx(async (q) => {
    await q.query('DELETE FROM profile_assets WHERE user_id = $1', [scope.userId]);
    await setUserSetting(q, scope.userId, 'photo_meta', null);
  });
  await bumpDataVersion(scope.db, scope.userId);
  // Local working files (none on the hosted app, where there's no data folder).
  fs.rmSync(photoDir(scope.userId), { recursive: true, force: true });
}

/**
 * Local start-up: when the Swift tool has changed since the photo was processed, process the kept
 * original again so improvements apply without a new upload. Also stores a processed photo that the
 * database doesn't have yet (e.g. the first run against a new database).
 */
export async function refreshPhotoIfStale(scope: Scope) {
  const dir = photoDir(scope.userId);
  const meta = path.join(dir, 'meta.json');
  const original = path.join(dir, 'original.jpg');
  if (!fs.existsSync(meta)) return;
  if (fs.existsSync(original) && fs.statSync(meta).mtimeMs < fs.statSync(SCRIPT).mtimeMs) {
    // Work from a copy (processing replaces data/profile), then put the untouched original back.
    const copy = path.join(DATA_DIR, `photo-original-${Date.now()}.jpg`);
    fs.copyFileSync(original, copy);
    try {
      await processPhoto(scope, copy);
      fs.copyFileSync(copy, path.join(dir, 'original.jpg'));
    } finally {
      fs.rmSync(copy, { force: true });
    }
    return;
  }
  if (!(await photoMeta(scope))) await storePhoto(scope);
}
