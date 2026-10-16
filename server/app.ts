// The API, shared by the local server (server/index.ts) and the hosted function (server/vercel.ts).
import fs from 'node:fs';
import path from 'node:path';
import { pipeline } from 'node:stream/promises';
import { waitUntil } from '@vercel/functions';
import express, { type NextFunction, type Request, type Response } from 'express';
import type { ImportJob, Settings, Status } from '../shared/types.ts';
import { importAppleHealth } from './apple/import.ts';
import { ingestRouter } from './apple/ingest.ts';
import { authRoutes, cronAuthorized, requireSession } from './auth.ts';
import { DATA_DIR, type Db, deleteSource, getSetting, setSetting } from './db.ts';
import { PHOTO_ASSETS, photoAsset, photoMeta, processPhoto, removePhoto } from './photo.ts';
import { readSettings, requestContext, summary, trends, workouts } from './query.ts';
import * as whoop from './whoop.ts';

const DATE = /^\d{4}-\d{2}-\d{2}$/;

export type AppOptions = {
  db: Db;
  /** Running on Vercel: no Host check (public domain), and features that need the Mac are off. */
  hosted: boolean;
  /** Shared secret for POST /api/apple/ingest (the iOS companion app). Unset = ingest off. */
  ingestToken?: string;
};

export function createApp({ db, hosted, ingestToken }: AppOptions) {
  const app = express();
  app.disable('x-powered-by');
  app.set('trust proxy', hosted);

  app.use((req, res, next) => {
    // Locally the server only listens on localhost: reject other Host headers (DNS rebinding).
    if (!hosted) {
      const host = (req.headers.host ?? '').replace(/:\d+$/, '');
      if (!['localhost', '127.0.0.1', '[::1]'].includes(host)) return void res.status(403).send('Forbidden host');
    }
    // Writes need a custom header, which a form or link on another website can't send.
    if (!['GET', 'HEAD'].includes(req.method) && req.path.startsWith('/api/') && req.headers['x-healthos'] !== '1') {
      return void res.status(403).json({ error: 'Missing X-HealthOS header' });
    }
    next();
  });

  const api = express.Router();
  const auth = authRoutes(async () => db);

  // Health data and sign-in state must not sit in browser or proxy caches (and a cached
  // "signed out" answer must never be reused). Photo assets set their own, versioned, private caching.
  api.use((_req, res, next) => {
    res.setHeader('Cache-Control', 'private, no-store');
    next();
  });

  // These authenticate themselves (bearer token, cron secret), so they come before the session gate.
  api.use(ingestRouter(db, ingestToken));
  api.get('/cron/whoop', async (req, res) => {
    if (!cronAuthorized(req)) return void res.status(401).json({ error: 'Unauthorized' });
    if (!whoop.isConfigured() || !(await whoop.isConnected(db))) return void res.json({ skipped: 'WHOOP not connected' });
    const { settings } = await requestContext(db, hosted);
    await whoop.syncWhoop(db, { timeZone: settings.timeZone ?? undefined });
    res.json({ ok: true, ...(await whoop.syncState(db)) });
  });

  api.use(express.json());
  api.get('/auth/me', auth.me);
  api.post('/auth/login', auth.login);
  api.post('/auth/logout', auth.logout);
  api.use(requireSession(() => false));

  const asOf = (req: Request) => (typeof req.query.date === 'string' && DATE.test(req.query.date) ? req.query.date : undefined);
  const days = (req: Request) => Math.min(Math.max(Number(req.query.days) || 30, 1), 3650);
  const macOnly = (res: Response, what: string) =>
    void res.status(501).json({ error: `${what} runs on your Mac. Start healthOS there (npm run dev) and do it from that copy; it writes to the same database.` });

  api.get('/summary', async (req, res) => {
    res.json(await summary(db, hosted, asOf(req)));
  });

  api.get('/trends', async (req, res) => {
    const metrics = String(req.query.metrics ?? '')
      .split(',')
      .filter((m) => /^[a-z0-9_]+$/.test(m))
      .slice(0, 20);
    res.json(await trends(db, hosted, metrics, days(req), asOf(req)));
  });

  api.get('/workouts', async (req, res) => {
    res.json(await workouts(db, hosted, days(req), asOf(req)));
  });

  // ---------- status & settings ----------

  let job: ImportJob = { state: 'idle' };

  async function status(): Promise<Status> {
    const [settings, last, lastSync, photo, connected, sync, whoopLast] = await Promise.all([
      readSettings(db, hosted),
      getSetting(db, 'apple_last_import'),
      getSetting(db, 'apple_last_sync'),
      photoMeta(db),
      whoop.isConnected(db),
      whoop.syncState(db),
      getSetting(db, 'whoop_last_sync'),
    ]);
    const { demo } = await requestContext(db, hosted);
    return {
      hosted,
      demo,
      settings,
      photo,
      apple: { lastImport: last ? JSON.parse(last) : null, lastSync: lastSync ? JSON.parse(lastSync) : null, job },
      whoop: {
        configured: whoop.isConfigured(),
        connected,
        redirectUri: whoop.whoopConfig().redirectUri,
        syncing: sync.running,
        lastSync: whoopLast ?? null,
        lastError: sync.lastError ?? null,
      },
    };
  }

  api.get('/status', async (_req, res) => {
    res.json(await status());
  });

  api.put('/settings', async (req, res) => {
    const body = req.body as Partial<Settings>;
    if (typeof body.name === 'string') await setSetting(db, 'name', body.name.trim().slice(0, 40) || null);
    if (body.stepGoal !== undefined) {
      const goal = Math.round(Number(body.stepGoal));
      if (goal >= 500 && goal <= 100_000) await setSetting(db, 'step_goal', String(goal));
    }
    if (body.units === 'metric' || body.units === 'imperial') await setSetting(db, 'units', body.units);
    if (body.demo === 'auto' || body.demo === 'on' || body.demo === 'off') await setSetting(db, 'demo', body.demo);
    if (typeof body.timeZone === 'string' && validZone(body.timeZone)) await setSetting(db, 'timezone', body.timeZone);
    res.json(await status());
  });

  // ---------- profile photo ----------

  let photoBusy = false;

  api.post('/profile/photo', async (req, res) => {
    if (hosted) return macOnly(res, 'Photo processing (Apple Vision)');
    if (photoBusy) return void res.status(409).json({ error: 'A photo is already being processed' });
    const size = Number(req.headers['content-length']) || 0;
    if (size > 40 * 1_048_576) return void res.status(413).json({ error: 'That image is over 40 MB' });
    photoBusy = true;
    const tmp = path.join(DATA_DIR, `photo-upload-${Date.now()}`);
    try {
      fs.mkdirSync(DATA_DIR, { recursive: true });
      await pipeline(req, fs.createWriteStream(tmp));
      await processPhoto(db, tmp);
      res.json(await status());
    } catch (err) {
      res.status(422).json({ error: (err as Error).message });
    } finally {
      fs.rmSync(tmp, { force: true });
      photoBusy = false;
    }
  });

  api.post('/profile/photo/clear', async (_req, res) => {
    await removePhoto(db);
    res.json(await status());
  });

  api.get('/profile/:file', async (req, res) => {
    const file = req.params.file;
    if (!(PHOTO_ASSETS as readonly string[]).includes(file)) return void res.status(404).json({ error: 'Not found' });
    const data = await photoAsset(db, file);
    if (!data) return void res.status(404).json({ error: 'No profile photo' });
    // Versioned URLs (?v=) change whenever the photo does; private keeps shared caches out of it.
    res.setHeader('Cache-Control', 'private, max-age=31536000, immutable');
    res.type('png').send(data);
  });

  // ---------- Apple Health ----------

  api.post('/apple/upload', async (req, res) => {
    if (hosted) return macOnly(res, 'Importing an Apple Health export');
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
    runImport(file);
  });

  api.post('/apple/clear', async (_req, res) => {
    if (job.state === 'uploading' || job.state === 'parsing') return void res.status(409).json({ error: 'An import is running' });
    await deleteSource(db, 'apple');
    await setSetting(db, 'apple_last_import', null);
    await setSetting(db, 'apple_last_sync', null);
    job = { state: 'idle' };
    res.json(await status());
  });

  async function runImport(file: string) {
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
      fs.rmSync(file, { force: true });
    }
  }

  // ---------- WHOOP ----------

  // Background work must outlive the response on Vercel; waitUntil keeps the function alive for it.
  const inBackground = (label: string, work: Promise<unknown>) =>
    waitUntil(work.catch((e: Error) => console.error(`[whoop] ${label} failed:`, e.message)));

  api.get('/whoop/connect', async (_req, res) => {
    if (!whoop.isConfigured()) return void res.redirect('/#/integrations?whoop=not-configured');
    res.redirect(await whoop.authorizeUrl(db));
  });

  api.get('/whoop/callback', async (req, res) => {
    const { code, state, error, error_description } = req.query as Record<string, string | undefined>;
    const back = (q: Record<string, string>) => res.redirect(`/#/integrations?${new URLSearchParams(q)}`);
    if (error) return back({ whoop: 'error', message: error_description || error });
    if (!(await whoop.consumeState(db, state))) return back({ whoop: 'error', message: 'Sign-in expired or was started elsewhere. Try connecting again.' });
    if (!code) return back({ whoop: 'error', message: 'WHOOP did not return an authorization code.' });
    try {
      await whoop.exchangeCode(db, code);
    } catch (err) {
      return back({ whoop: 'error', message: (err as Error).message });
    }
    const { settings } = await requestContext(db, hosted);
    inBackground('initial sync', whoop.syncWhoop(db, { full: true, timeZone: settings.timeZone ?? undefined }));
    back({ whoop: 'connected' });
  });

  api.post('/whoop/sync', async (req, res) => {
    if (!(await whoop.isConnected(db))) return void res.status(400).json({ error: 'WHOOP is not connected' });
    const { settings } = await requestContext(db, hosted);
    inBackground('sync', whoop.syncWhoop(db, { full: Boolean(req.body?.full), timeZone: settings.timeZone ?? undefined }));
    res.json(await status());
  });

  api.post('/whoop/disconnect', async (_req, res) => {
    await whoop.disconnect(db);
    res.json(await status());
  });

  app.use('/api', api);
  app.use('/api', (_req, res) => void res.status(404).json({ error: 'Not found' }));
  app.use('/api', (err: Error & { status?: number }, _req: Request, res: Response, _next: NextFunction) => {
    // Client mistakes (e.g. a malformed JSON body) keep their 4xx status; only real failures are 500s.
    if (err.status && err.status >= 400 && err.status < 500) return void res.status(err.status).json({ error: err.message });
    console.error(err);
    res.status(500).json({ error: hosted ? 'Something went wrong' : err.message });
  });
  return app;
}

function validZone(tz: string) {
  try {
    new Intl.DateTimeFormat('en-US', { timeZone: tz });
    return tz.length < 64;
  } catch {
    return false;
  }
}
