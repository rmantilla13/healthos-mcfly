import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { pipeline } from 'node:stream/promises';
import express, { type NextFunction, type Request, type Response } from 'express';
import type { ImportJob, Settings, Status } from '../shared/types.ts';
import { importAppleHealth } from './apple/import.ts';
import { ingestRouter, lanIngestApp } from './apple/ingest.ts';
import { DATA_DIR, deleteSource, getDb, getSetting, setSetting } from './db.ts';
import { todayLocal } from './dates.ts';
import { seedDemo } from './demo.ts';
import { PHOTO_DIR, photoMeta, processPhoto, refreshPhotoIfStale, removePhoto } from './photo.ts';
import { demoActive, readSettings, summary, trends, workouts } from './query.ts';
import * as whoop from './whoop.ts';

const ROOT = path.resolve(import.meta.dirname, '..');
const PORT = Number(process.env.PORT ?? 8787);
const HOST = process.env.HOST ?? '127.0.0.1';
const PROD = process.env.NODE_ENV === 'production';
const DATE = /^\d{4}-\d{2}-\d{2}$/;
// Shared secret for POST /api/apple/ingest (the iOS companion app). Unset = ingest off.
const INGEST_TOKEN = process.env.HEALTHOS_INGEST_TOKEN?.trim() || undefined;
// LAN mode: a second listener, reachable from the phone, that serves only the ingest endpoint.
const LAN = process.env.HEALTHOS_LAN === '1';
const LAN_PORT = Number(process.env.HEALTHOS_LAN_PORT ?? 8788);
const LAN_HOST = process.env.HEALTHOS_LAN_HOST ?? '0.0.0.0';

if (LAN && (!INGEST_TOKEN || INGEST_TOKEN.length < 16)) {
  console.error('HEALTHOS_LAN=1 needs HEALTHOS_INGEST_TOKEN set to at least 16 characters (try: openssl rand -hex 24).');
  process.exit(1);
}

const db = getDb();
seedDemo(db);
refreshPhotoIfStale().catch((e) => console.error('[photo] reprocessing failed:', e.message));

const app = express();
app.disable('x-powered-by');

// This server holds health data and only listens on localhost. Reject other Host headers
// (DNS rebinding) and require a custom header on writes, which other websites can't send.
app.use((req, res, next) => {
  const host = (req.headers.host ?? '').replace(/:\d+$/, '');
  if (!['localhost', '127.0.0.1', '[::1]'].includes(host)) return void res.status(403).send('Forbidden host');
  if (!['GET', 'HEAD'].includes(req.method) && req.path.startsWith('/api/') && req.headers['x-healthos'] !== '1') {
    return void res.status(403).json({ error: 'Missing X-HealthOS header' });
  }
  next();
});

const api = express.Router();
// Before the router-wide JSON parser: ingest checks its token first and takes larger bodies.
api.use(ingestRouter(db, INGEST_TOKEN));
api.use(express.json());

const asOf = (req: Request) => (typeof req.query.date === 'string' && DATE.test(req.query.date) ? req.query.date : undefined);
const days = (req: Request) => Math.min(Math.max(Number(req.query.days) || 30, 1), 3650);

api.get('/summary', (req, res) => {
  res.json(summary(db, asOf(req)));
});

api.get('/trends', (req, res) => {
  const metrics = String(req.query.metrics ?? '')
    .split(',')
    .filter((m) => /^[a-z0-9_]+$/.test(m))
    .slice(0, 20);
  res.json(trends(db, metrics, days(req), asOf(req) ?? todayLocal()));
});

api.get('/workouts', (req, res) => {
  res.json(workouts(db, days(req), asOf(req) ?? todayLocal()));
});

// ---------- status & settings ----------

let job: ImportJob = { state: 'idle' };

function status(): Status {
  const last = getSetting(db, 'apple_last_import');
  const lastSync = getSetting(db, 'apple_last_sync');
  return {
    demo: demoActive(db),
    settings: readSettings(db),
    photo: photoMeta(),
    apple: { lastImport: last ? JSON.parse(last) : null, lastSync: lastSync ? JSON.parse(lastSync) : null, job },
    whoop: {
      configured: whoop.isConfigured(),
      connected: whoop.isConnected(db),
      redirectUri: whoop.whoopConfig().redirectUri,
      syncing: whoop.syncState.running,
      lastSync: getSetting(db, 'whoop_last_sync') ?? null,
      lastError: whoop.syncState.lastError ?? null,
    },
  };
}

api.get('/status', (_req, res) => {
  res.json(status());
});

api.put('/settings', (req, res) => {
  const body = req.body as Partial<Settings>;
  if (typeof body.name === 'string') setSetting(db, 'name', body.name.trim().slice(0, 40) || null);
  if (body.stepGoal !== undefined) {
    const goal = Math.round(Number(body.stepGoal));
    if (goal >= 500 && goal <= 100_000) setSetting(db, 'step_goal', String(goal));
  }
  if (body.units === 'metric' || body.units === 'imperial') setSetting(db, 'units', body.units);
  if (body.demo === 'auto' || body.demo === 'on' || body.demo === 'off') setSetting(db, 'demo', body.demo);
  res.json(status());
});

// ---------- profile photo ----------

let photoBusy = false;

api.post('/profile/photo', async (req, res) => {
  if (photoBusy) return void res.status(409).json({ error: 'A photo is already being processed' });
  const size = Number(req.headers['content-length']) || 0;
  if (size > 40 * 1_048_576) return void res.status(413).json({ error: 'That image is over 40 MB' });
  photoBusy = true;
  const tmp = path.join(DATA_DIR, `photo-upload-${Date.now()}`);
  try {
    await pipeline(req, fs.createWriteStream(tmp));
    await processPhoto(tmp);
    res.json(status());
  } catch (err) {
    res.status(422).json({ error: (err as Error).message });
  } finally {
    fs.rmSync(tmp, { force: true });
    photoBusy = false;
  }
});

api.post('/profile/photo/clear', (_req, res) => {
  removePhoto();
  res.json(status());
});

api.get('/profile/:file', (req, res) => {
  const file = req.params.file;
  if (!['cutout.png', 'depth.png', 'avatar.png'].includes(file)) return void res.status(404).json({ error: 'Not found' });
  res.setHeader('Cache-Control', 'private, max-age=31536000, immutable');
  res.sendFile(path.join(PHOTO_DIR, file), (err) => {
    if (err && !res.headersSent) res.status(404).json({ error: 'No profile photo' });
  });
});

// ---------- Apple Health ----------

api.post('/apple/upload', async (req, res) => {
  if (job.state === 'uploading' || job.state === 'parsing') return void res.status(409).json({ error: 'An import is already running' });
  const uploads = path.join(DATA_DIR, 'uploads');
  fs.mkdirSync(uploads, { recursive: true });
  const file = path.join(uploads, `upload-${Date.now()}`);
  const totalBytes = Number(req.headers['content-length']) || 0;
  job = { state: 'uploading', bytesRead: 0, totalBytes, records: 0 };
  req.on('data', (chunk: Buffer) => {
    if (job.state === 'uploading') job.bytesRead += chunk.length;
  });
  try {
    await pipeline(req, fs.createWriteStream(file));
  } catch (err) {
    job = { state: 'error', error: `Upload failed: ${(err as Error).message}` };
    fs.rmSync(file, { force: true });
    return void res.status(400).json({ error: job.error });
  }
  res.json({ ok: true });
  runImport(file, true);
});

api.post('/apple/clear', (_req, res) => {
  if (job.state === 'uploading' || job.state === 'parsing') return void res.status(409).json({ error: 'An import is running' });
  deleteSource(db, 'apple');
  setSetting(db, 'apple_last_import', null);
  job = { state: 'idle' };
  res.json(status());
});

async function runImport(file: string, removeAfter: boolean) {
  job = { state: 'parsing', bytesRead: 0, totalBytes: 0, records: 0 };
  try {
    const result = await importAppleHealth(db, file, (p) => {
      job = { state: 'parsing', ...p };
    });
    job = { state: 'done', records: result.records, days: result.days };
  } catch (err) {
    job = { state: 'error', error: (err as Error).message };
  } finally {
    // The upload is a full copy of the user's health record; don't keep it around.
    if (removeAfter) fs.rmSync(file, { force: true });
  }
}

// ---------- WHOOP ----------

api.get('/whoop/connect', (_req, res) => {
  if (!whoop.isConfigured()) return void res.redirect('/#/integrations?whoop=not-configured');
  res.redirect(whoop.authorizeUrl());
});

api.get('/whoop/callback', async (req, res) => {
  const { code, state, error, error_description } = req.query as Record<string, string | undefined>;
  const back = (q: Record<string, string>) => res.redirect(`/#/integrations?${new URLSearchParams(q)}`);
  if (error) return back({ whoop: 'error', message: error_description || error });
  if (!whoop.consumeState(state)) return back({ whoop: 'error', message: 'Sign-in expired or was started elsewhere. Try connecting again.' });
  if (!code) return back({ whoop: 'error', message: 'WHOOP did not return an authorization code.' });
  try {
    await whoop.exchangeCode(db, code);
  } catch (err) {
    return back({ whoop: 'error', message: (err as Error).message });
  }
  whoop.syncWhoop(db, { full: true }).catch((e) => console.error('[whoop] initial sync failed:', e.message));
  back({ whoop: 'connected' });
});

api.post('/whoop/sync', (req, res) => {
  if (!whoop.isConnected(db)) return void res.status(400).json({ error: 'WHOOP is not connected' });
  whoop.syncWhoop(db, { full: Boolean(req.body?.full) }).catch((e) => console.error('[whoop] sync failed:', e.message));
  res.json(status());
});

api.post('/whoop/disconnect', async (_req, res) => {
  await whoop.disconnect(db);
  res.json(status());
});

app.use('/api', api);
app.use('/api', (_req, res) => void res.status(404).json({ error: 'Not found' }));
app.use('/api', (err: Error, _req: Request, res: Response, _next: NextFunction) => {
  console.error(err);
  res.status(500).json({ error: err.message });
});

// ---------- client ----------

const server = http.createServer(app);

if (PROD) {
  const dist = path.join(ROOT, 'dist');
  app.use(express.static(dist));
  app.get('/{*splat}', (_req, res) => res.sendFile(path.join(dist, 'index.html')));
} else {
  const { createServer } = await import('vite');
  const { default: react } = await import('@vitejs/plugin-react');
  // Config is inline: loading vite.config.ts writes a temp file, which would trip `node --watch` into a restart loop.
  const vite = await createServer({
    root: ROOT,
    configFile: false,
    plugins: [react()],
    appType: 'spa',
    server: { middlewareMode: true, hmr: { server } },
  });
  app.use(vite.middlewares);
}

server.listen(PORT, HOST, () => {
  console.log(`healthOS running at http://localhost:${PORT}`);
});

if (LAN) {
  http.createServer(lanIngestApp(db, INGEST_TOKEN!)).listen(LAN_PORT, LAN_HOST, () => {
    const addresses = Object.values(os.networkInterfaces())
      .flat()
      .filter((a) => a && a.family === 'IPv4' && !a.internal)
      .map((a) => `http://${a!.address}:${LAN_PORT}`);
    console.log(`LAN ingest for the iOS app (token required, nothing else served): ${addresses.join(', ') || `port ${LAN_PORT}`}`);
  });
}

// Keep WHOOP current (and its refresh token fresh) while the app is running.
const SIX_HOURS = 6 * 3_600_000;
const autoSync = () => {
  if (whoop.isConfigured() && whoop.isConnected(db)) whoop.syncWhoop(db).catch((e) => console.error('[whoop] auto sync failed:', e.message));
};
setTimeout(autoSync, 5_000);
setInterval(autoSync, SIX_HOURS).unref();
