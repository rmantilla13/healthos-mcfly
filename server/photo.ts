// Profile photo: cut-out, depth relief and avatar, made locally by server/photo/cutout.swift (Apple Vision).
import { execFile } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { promisify } from 'node:util';
import type { PhotoMeta } from '../shared/types.ts';
import { DATA_DIR } from './db.ts';

const run = promisify(execFile);
const SCRIPT = path.join(import.meta.dirname, 'photo', 'cutout.swift');
const BIN = path.join(DATA_DIR, 'bin', 'cutout');
export const PHOTO_DIR = path.join(DATA_DIR, 'profile');

export function photoMeta(): PhotoMeta | null {
  try {
    const file = path.join(PHOTO_DIR, 'meta.json');
    const meta = JSON.parse(fs.readFileSync(file, 'utf8'));
    return { ...meta, version: Math.round(fs.statSync(file).mtimeMs) };
  } catch {
    return null;
  }
}

/** Compile the Swift tool once (and again whenever the script changes). */
async function ensureBinary() {
  const stale = !fs.existsSync(BIN) || fs.statSync(BIN).mtimeMs < fs.statSync(SCRIPT).mtimeMs;
  if (!stale) return;
  if (process.platform !== 'darwin') throw new Error('Photo processing uses Apple Vision and needs macOS.');
  fs.mkdirSync(path.dirname(BIN), { recursive: true });
  await run('swiftc', ['-O', SCRIPT, '-o', BIN], { timeout: 180_000 });
}

/** Process an image file into data/profile. Replaces the previous photo only if processing succeeds. */
export async function processPhoto(input: string): Promise<PhotoMeta> {
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
  return photoMeta()!;
}

export function removePhoto() {
  fs.rmSync(PHOTO_DIR, { recursive: true, force: true });
}

/**
 * When the Swift tool has changed since the photo was processed, process the kept original again so
 * improvements (better cut-out edges, depth, callout points) apply without a new upload.
 */
export async function refreshPhotoIfStale() {
  const meta = path.join(PHOTO_DIR, 'meta.json');
  const original = path.join(PHOTO_DIR, 'original.jpg');
  if (!fs.existsSync(meta) || !fs.existsSync(original)) return;
  if (fs.statSync(meta).mtimeMs >= fs.statSync(SCRIPT).mtimeMs) return;
  // Work from a copy (processing replaces data/profile), then put the untouched original back.
  const copy = path.join(DATA_DIR, `photo-original-${Date.now()}.jpg`);
  fs.copyFileSync(original, copy);
  try {
    await processPhoto(copy);
    fs.copyFileSync(copy, path.join(PHOTO_DIR, 'original.jpg'));
  } finally {
    fs.rmSync(copy, { force: true });
  }
}
