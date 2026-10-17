// Profile photo: cut out and measured locally by server/photo/cutout.swift (Apple Vision, macOS only),
// then stored in the database (profile_assets + the photo_meta setting) so the hosted app can serve it.
// The original and working files stay in data/profile on this Mac.
import { execFile } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { promisify } from 'node:util';
import type { PhotoMeta } from '../shared/types.ts';
import { DATA_DIR, OWNER_ID, type Scope, getUserSetting, setUserSetting } from './db.ts';

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

/** Copy a processed photo folder into the database, replacing that person's previous photo. */
export async function storePhoto(scope: Scope, dir = photoDir(scope.userId)): Promise<PhotoMeta> {
  const { db, userId } = scope;
  const meta = JSON.parse(fs.readFileSync(path.join(dir, 'meta.json'), 'utf8')) as Omit<PhotoMeta, 'version'>;
  const version = Date.now();
  await db.tx(async (q) => {
    await q.query('DELETE FROM profile_assets WHERE user_id = $1', [userId]);
    for (const name of PHOTO_ASSETS) {
      const file = path.join(dir, name);
      if (!fs.existsSync(file)) continue;
      await q.query('INSERT INTO profile_assets (user_id, name, mime, data, updated_at) VALUES ($1, $2, $3, $4, $5)', [
        userId,
        name,
        'image/png',
        fs.readFileSync(file),
        version,
      ]);
    }
    await setUserSetting(q, userId, 'photo_meta', JSON.stringify({ ...meta, version }));
  });
  return { ...meta, version } as PhotoMeta;
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
