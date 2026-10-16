// Profile photo: cut out and measured locally by server/photo/cutout.swift (Apple Vision, macOS only),
// then stored in the database (profile_assets + the photo_meta setting) so the hosted app can serve it.
// The original and working files stay in data/profile on this Mac.
import { execFile } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { promisify } from 'node:util';
import type { PhotoMeta } from '../shared/types.ts';
import { DATA_DIR, type Db, type Queryable, getSetting, setSetting } from './db.ts';

const run = promisify(execFile);
const SCRIPT = path.join(import.meta.dirname, 'photo', 'cutout.swift');
const BIN = path.join(DATA_DIR, 'bin', 'cutout');
export const PHOTO_DIR = path.join(DATA_DIR, 'profile');
export const PHOTO_ASSETS = ['cutout.png', 'avatar.png'] as const;

export async function photoMeta(q: Queryable): Promise<PhotoMeta | null> {
  const raw = await getSetting(q, 'photo_meta');
  return raw ? (JSON.parse(raw) as PhotoMeta) : null;
}

export async function photoAsset(q: Queryable, name: string): Promise<Buffer | null> {
  const [row] = await q.query<{ data: Uint8Array }>('SELECT data FROM profile_assets WHERE name = $1', [name]);
  return row ? Buffer.from(row.data) : null;
}

/** Copy a processed data/profile folder into the database, replacing the previous photo. */
export async function storePhoto(db: Db, dir = PHOTO_DIR): Promise<PhotoMeta> {
  const meta = JSON.parse(fs.readFileSync(path.join(dir, 'meta.json'), 'utf8')) as Omit<PhotoMeta, 'version'>;
  const version = Date.now();
  await db.tx(async (q) => {
    await q.query('DELETE FROM profile_assets');
    for (const name of PHOTO_ASSETS) {
      const file = path.join(dir, name);
      if (!fs.existsSync(file)) continue;
      await q.query('INSERT INTO profile_assets (name, mime, data, updated_at) VALUES ($1, $2, $3, $4)', [name, 'image/png', fs.readFileSync(file), version]);
    }
    await setSetting(q, 'photo_meta', JSON.stringify({ ...meta, version }));
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
export async function processPhoto(db: Db, input: string): Promise<PhotoMeta> {
  await ensureBinary();
  const work = fs.mkdtempSync(path.join(DATA_DIR, 'profile-'));
  try {
    await run(BIN, [input, work], { timeout: 120_000 }).catch((err: { stderr?: string; message: string }) => {
      // Vision logs its own diagnostics to stderr; the tool's message is the last line.
      throw new Error(err.stderr?.trim().split('\n').at(-1) || err.message);
    });
    fs.rmSync(PHOTO_DIR, { recursive: true, force: true });
    fs.renameSync(work, PHOTO_DIR);
  } finally {
    fs.rmSync(work, { recursive: true, force: true });
  }
  return storePhoto(db);
}

export async function removePhoto(db: Db) {
  await db.tx(async (q) => {
    await q.query('DELETE FROM profile_assets');
    await setSetting(q, 'photo_meta', null);
  });
  fs.rmSync(PHOTO_DIR, { recursive: true, force: true });
}

/**
 * Local start-up: when the Swift tool has changed since the photo was processed, process the kept
 * original again so improvements apply without a new upload. Also stores a processed photo that the
 * database doesn't have yet (e.g. the first run against a new database).
 */
export async function refreshPhotoIfStale(db: Db) {
  const meta = path.join(PHOTO_DIR, 'meta.json');
  const original = path.join(PHOTO_DIR, 'original.jpg');
  if (!fs.existsSync(meta)) return;
  if (fs.existsSync(original) && fs.statSync(meta).mtimeMs < fs.statSync(SCRIPT).mtimeMs) {
    // Work from a copy (processing replaces data/profile), then put the untouched original back.
    const copy = path.join(DATA_DIR, `photo-original-${Date.now()}.jpg`);
    fs.copyFileSync(original, copy);
    try {
      await processPhoto(db, copy);
      fs.copyFileSync(copy, path.join(PHOTO_DIR, 'original.jpg'));
    } finally {
      fs.rmSync(copy, { force: true });
    }
    return;
  }
  if (!(await photoMeta(db))) await storePhoto(db);
}
