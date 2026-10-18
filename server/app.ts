// The API, shared by the local server (server/index.ts) and the hosted function (server/vercel.ts).
// Every health-data route runs for the signed-in person only: handlers build a scope { db, userId } from
// the session and pass it down, and every query filters on that user id.
import { randomBytes } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { pipeline } from 'node:stream/promises';
import { waitUntil } from '@vercel/functions';
import express, { type NextFunction, type Request, type Response } from 'express';
import type { ImportJob, Settings, Status } from '../shared/types.ts';
import { adminRouter } from './admin.ts';
import { DAY_METRICS, dayView } from './day.ts';
import { importAppleHealth } from './apple/import.ts';
import { ingestRouter } from './apple/ingest.ts';
import { authRoutes, cronAuthorized, currentUser, publicUser, requireSession, sha256 } from './auth.ts';
import { cycleRouter } from './cycle/index.ts';
import { familyRouter } from './family.ts';
import { DATA_DIR, type Db, type Scope, bumpDataVersion, deleteSource, getUserSetting, setUserSetting } from './db.ts';
import { patterns, sleepTiming } from './insights.ts';
import { type McflyClient, mcflyRouter } from './mcfly.ts';
import { PHOTO_ASSETS, parsePhotoUpload, photoAsset, photoMeta, processPhoto, removePhoto, storePhotoAssets } from './photo.ts';
import { readSettings, requestContext, summary, trends, workouts } from './query.ts';
import * as whoop from './whoop.ts';

const DATE = /^\d{4}-\d{2}-\d{2}$/;
/** How soon a WHOOP sync may run again from POST /api/sync. */
const SYNC_COOLDOWN_MS = 2 * 60_000;

export type AppOptions = {
  db: Db;
  /** Running on Vercel: no Host check (public domain), and features that need the Mac are off. */
  hosted: boolean;
  /** The server-wide iPhone ingest token from before multi-user (HEALTHOS_INGEST_TOKEN); it maps to the owner. */
  ingestToken?: string;
  /** Ask McFly's Claude client (tests pass a fake). Defaults to one from ANTHROPIC_API_KEY. */
  mcflyClient?: () => McflyClient | null;
};

export function createApp({ db, hosted, ingestToken, mcflyClient }: AppOptions) {
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
  const auth = authRoutes(db);

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
    if (!whoop.isConfigured()) return void res.json({ skipped: 'WHOOP not configured' });
    res.json(await whoop.syncAllWhoop(db));
  });

  // A processed photo is a few MB, over the general JSON limit below, so it's parsed here first. The image
  // work happens on the person's own device (browser or iPhone); this only checks and stores the result.
  api.post('/profile/photo/upload', requireSession(db), express.json({ limit: '6mb' }), async (req, res) => {
    const upload = parsePhotoUpload(req.body);
    if (typeof upload === 'string') return void res.status(400).json({ error: upload });
    await storePhotoAssets({ db, userId: currentUser(res).id }, upload);
    res.json({ ok: true });
  });

  api.use(express.json());
  api.get('/auth/me', auth.me);
  api.post('/auth/login', auth.login);
  api.post('/auth/logout', auth.logout);
  api.post('/auth/link', auth.checkLink);
  api.post('/auth/invite', auth.acceptInvite);
  api.post('/auth/reset', auth.resetPassword);

  // ---------- everything below needs a signed-in person ----------
  api.use(requireSession(db));
  const scopeOf = (res: Response): Scope => ({ db, userId: currentUser(res).id });

  api.post('/auth/password', auth.changePassword);
  api.use('/admin', adminRouter(db));
  api.use('/mcfly', mcflyRouter(db, { hosted, client: mcflyClient }));
  api.use('/cycle', cycleRouter(db, hosted));
  api.use('/family', familyRouter(db, hosted));

  const asOf = (req: Request) => (typeof req.query.date === 'string' && DATE.test(req.query.date) ? req.query.date : undefined);
  const days = (req: Request) => Math.min(Math.max(Number(req.query.days) || 30, 1), 3650);
  const macOnly = (res: Response, what: string) =>
    void res.status(501).json({ error: `${what} runs on your Mac. Start healthOS there (npm run dev) and do it from that copy; it writes to the same database.` });

  api.get('/summary', async (req, res) => {
    res.json(await summary(scopeOf(res), hosted, asOf(req)));
  });

  api.get('/trends', async (req, res) => {
    const metrics = String(req.query.metrics ?? '')
      .split(',')
      .filter((m) => /^[a-z0-9_]+$/.test(m))
      .slice(0, 20);
    res.json(await trends(scopeOf(res), hosted, metrics, days(req), asOf(req)));
  });

  api.get('/day', async (req, res) => {
    // Unknown names are ignored; with none left the answer is simply an empty Day view.
    const asked = String(req.query.metrics ?? DAY_METRICS.join(',')).split(',');
    const metrics = DAY_METRICS.filter((m) => asked.includes(m));
    const date = req.query.date === undefined ? undefined : String(req.query.date);
    if (date !== undefined && !DATE.test(date)) return void res.status(400).json({ error: 'date must be YYYY-MM-DD' });
    res.json(await dayView(scopeOf(res), hosted, metrics, date));
  });

  api.get('/workouts', async (req, res) => {
    res.json(await workouts(scopeOf(res), hosted, days(req), asOf(req)));
  });

  api.get('/sleep', async (req, res) => {
    res.json(await sleepTiming(scopeOf(res), hosted, Math.min(Math.max(Number(req.query.days) || 30, 7), 365)));
  });

  api.get('/patterns', async (_req, res) => {
    res.json(await patterns(scopeOf(res), hosted));
  });

  // ---------- status, settings, account ----------

  // Upload/import progress, per person (local only).
  const jobs = new Map<string, ImportJob>();
  const jobOf = (userId: string): ImportJob => jobs.get(userId) ?? { state: 'idle' };

  async function status(res: Response): Promise<Status> {
    const scope = scopeOf(res);
    const user = currentUser(res);
    const [settings, last, lastSync, photo, connected, sync, whoopLast, tokenRows] = await Promise.all([
      readSettings(scope, hosted),
      getUserSetting(db, scope.userId, 'apple_last_import'),
      getUserSetting(db, scope.userId, 'apple_last_sync'),
      photoMeta(scope),
      whoop.isConnected(scope),
      whoop.syncState(scope),
      getUserSetting(db, scope.userId, 'whoop_last_sync'),
      db.query<{ has: boolean }>('SELECT ingest_token_hash IS NOT NULL AS has FROM users WHERE id = $1', [scope.userId]),
    ]);
    const { demo } = await requestContext(scope, hosted);
    return {
      hosted,
      demo,
      user: publicUser(user),
      settings,
      photo,
      apple: {
        lastImport: last ? JSON.parse(last) : null,
        lastSync: lastSync ? JSON.parse(lastSync) : null,
        job: jobOf(scope.userId),
        iphoneToken: Boolean(tokenRows[0]?.has),
      },
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

  /** A cheap "has anything changed?" check: compare it with the last one seen, and refetch only if it moved. */
  api.get('/version', async (_req, res) => {
    res.json({ version: (await getUserSetting(db, currentUser(res).id, 'data_version')) ?? null });
  });

  api.get('/status', async (_req, res) => {
    res.json(await status(res));
  });

  api.put('/settings', async (req, res) => {
    const { userId } = scopeOf(res);
    const body = req.body as Partial<Settings>;
    if (typeof body.name === 'string') {
      const name = body.name.trim().slice(0, 40);
      await setUserSetting(db, userId, 'name', name || null);
      await db.query('UPDATE users SET name = $1 WHERE id = $2', [name, userId]);
    }
    if (body.stepGoal !== undefined) {
      const goal = Math.round(Number(body.stepGoal));
      if (goal >= 500 && goal <= 100_000) await setUserSetting(db, userId, 'step_goal', String(goal));
    }
    if (body.units === 'metric' || body.units === 'imperial') await setUserSetting(db, userId, 'units', body.units);
    if (body.demo === 'auto' || body.demo === 'on' || body.demo === 'off') await setUserSetting(db, userId, 'demo', body.demo);
    if (typeof body.timeZone === 'string' && validZone(body.timeZone)) await setUserSetting(db, userId, 'timezone', body.timeZone);
    if (body.sex === null || body.sex === 'female' || body.sex === 'male' || body.sex === 'unspecified') await setUserSetting(db, userId, 'sex', body.sex);
    // Off hides cycle data everywhere; it doesn't delete it (POST /api/cycle/delete does).
    if (typeof body.cycleTracking === 'boolean') await setUserSetting(db, userId, 'cycle_tracking', body.cycleTracking ? 'on' : null);
    // The Family board: sharing is on unless turned off. A shared cycle phase needs both tracking and sharing,
    // and turning either off withdraws it, so turning them back on doesn't share it again by surprise.
    if (typeof body.familySharing === 'boolean') await setUserSetting(db, userId, 'family_sharing', body.familySharing ? null : 'off');
    if (body.familyNoticeSeen === true) await setUserSetting(db, userId, 'family_notice_seen', '2');
    if (body.cycleTracking === false || body.familySharing === false) await setUserSetting(db, userId, 'family_cycle_phase', null);
    else if (typeof body.shareCyclePhase === 'boolean') {
      const now = await readSettings({ db, userId }, hosted);
      await setUserSetting(db, userId, 'family_cycle_phase', body.shareCyclePhase && now.cycleTracking && now.familySharing ? 'on' : null);
    }
    // Units, names and time zone change what every view shows, on every device.
    await bumpDataVersion(db, userId);
    res.json(await status(res));
  });

  /** A person's own iPhone app token. Shown once; only its hash is kept. Creating a new one replaces the old. */
  api.post('/me/ingest-token', async (_req, res) => {
    const token = randomBytes(24).toString('base64url');
    const saved = await db.query('UPDATE users SET ingest_token_hash = $1 WHERE id = $2 RETURNING id', [sha256(token), currentUser(res).id]);
    // Without sign-in (local, no accounts) there's no account row to hold it; HEALTHOS_INGEST_TOKEN covers that case.
    if (!saved.length) return void res.status(400).json({ error: 'Set HEALTHOS_INGEST_TOKEN in .env for the iPhone app on this Mac.' });
    res.json({ token });
  });

  api.delete('/me/ingest-token', async (_req, res) => {
    await db.query('UPDATE users SET ingest_token_hash = NULL WHERE id = $1', [currentUser(res).id]);
    res.json(await status(res));
  });

  // ---------- profile photo ----------

  const photoBusy = new Set<string>();

  api.post('/profile/photo', async (req, res) => {
    if (hosted) return macOnly(res, 'Photo processing (Apple Vision)');
    const scope = scopeOf(res);
    if (photoBusy.has(scope.userId)) return void res.status(409).json({ error: 'A photo is already being processed' });
    const size = Number(req.headers['content-length']) || 0;
    if (size > 40 * 1_048_576) return void res.status(413).json({ error: 'That image is over 40 MB' });
    photoBusy.add(scope.userId);
    const tmp = path.join(DATA_DIR, `photo-upload-${Date.now()}`);
    try {
      fs.mkdirSync(DATA_DIR, { recursive: true });
      await pipeline(req, fs.createWriteStream(tmp));
      await processPhoto(scope, tmp);
      res.json(await status(res));
    } catch (err) {
      res.status(422).json({ error: (err as Error).message });
    } finally {
      fs.rmSync(tmp, { force: true });
      photoBusy.delete(scope.userId);
    }
  });

  api.post('/profile/photo/clear', async (_req, res) => {
    await removePhoto(scopeOf(res));
    res.json(await status(res));
  });

  api.get('/profile/:file', async (req, res) => {
    const file = req.params.file;
    if (!(PHOTO_ASSETS as readonly string[]).includes(file)) return void res.status(404).json({ error: 'Not found' });
    const data = await photoAsset(scopeOf(res), file);
    if (!data) return void res.status(404).json({ error: 'No profile photo' });
    // Versioned URLs (?v=) change whenever the photo does; private keeps shared caches out of it.
    res.setHeader('Cache-Control', 'private, max-age=31536000, immutable');
    res.type('png').send(data);
  });

  // ---------- Apple Health ----------

  api.post('/apple/upload', async (req, res) => {
    if (hosted) return macOnly(res, 'Importing an Apple Health export');
    const scope = scopeOf(res);
    const current = jobOf(scope.userId);
    if (current.state === 'uploading' || current.state === 'parsing') return void res.status(409).json({ error: 'An import is already running' });
    const uploads = path.join(DATA_DIR, 'uploads');
    fs.mkdirSync(uploads, { recursive: true });
    const file = path.join(uploads, `upload-${Date.now()}`);
    const totalBytes = Number(req.headers['content-length']) || 0;
    const job: ImportJob = { state: 'uploading', bytesRead: 0, totalBytes, records: 0 };
    jobs.set(scope.userId, job);
    req.on('data', (chunk: Buffer) => {
      if (job.state === 'uploading') job.bytesRead += chunk.length;
    });
    try {
      await pipeline(req, fs.createWriteStream(file));
    } catch (err) {
      jobs.set(scope.userId, { state: 'error', error: `Upload failed: ${(err as Error).message}` });
      fs.rmSync(file, { force: true });
      return void res.status(400).json({ error: 'Upload failed' });
    }
    res.json({ ok: true });
    runImport(scope, file);
  });

  api.post('/apple/clear', async (_req, res) => {
    const scope = scopeOf(res);
    const current = jobOf(scope.userId);
    if (current.state === 'uploading' || current.state === 'parsing') return void res.status(409).json({ error: 'An import is running' });
    await deleteSource(db, scope.userId, 'apple');
    await setUserSetting(db, scope.userId, 'apple_last_import', null);
    await setUserSetting(db, scope.userId, 'apple_last_sync', null);
    await bumpDataVersion(db, scope.userId);
    jobs.delete(scope.userId);
    res.json(await status(res));
  });

  async function runImport(scope: Scope, file: string) {
    jobs.set(scope.userId, { state: 'parsing', bytesRead: 0, totalBytes: 0, records: 0 });
    try {
      const result = await importAppleHealth(scope, file, (p) => {
        jobs.set(scope.userId, { state: 'parsing', ...p });
      });
      jobs.set(scope.userId, { state: 'done', records: result.records, days: result.days });
    } catch (err) {
      jobs.set(scope.userId, { state: 'error', error: (err as Error).message });
    } finally {
      // The upload is a full copy of the person's health record; don't keep it around.
      fs.rmSync(file, { force: true });
    }
  }

  // ---------- WHOOP ----------

  // Background work must outlive the response on Vercel; waitUntil keeps the function alive for it.
  const inBackground = (label: string, work: Promise<unknown>) =>
    waitUntil(work.catch((e: Error) => console.error(`[whoop] ${label} failed:`, e.message)));

  api.get('/whoop/connect', async (_req, res) => {
    if (!whoop.isConfigured()) return void res.redirect('/#/integrations?whoop=not-configured');
    res.redirect(await whoop.authorizeUrl(scopeOf(res)));
  });

  api.get('/whoop/callback', async (req, res) => {
    const scope = scopeOf(res);
    const { code, state, error, error_description } = req.query as Record<string, string | undefined>;
    const back = (q: Record<string, string>) => res.redirect(`/#/integrations?${new URLSearchParams(q)}`);
    if (error) return back({ whoop: 'error', message: error_description || error });
    // The state must be the one this same signed-in person started; anyone else's is refused.
    if (!(await whoop.consumeState(scope, state))) return back({ whoop: 'error', message: 'Sign-in expired or was started elsewhere. Try connecting again.' });
    if (!code) return back({ whoop: 'error', message: 'WHOOP did not return an authorization code.' });
    try {
      await whoop.exchangeCode(scope, code);
    } catch (err) {
      return back({ whoop: 'error', message: (err as Error).message });
    }
    inBackground('initial sync', whoop.syncWhoop(scope, { full: true }));
    back({ whoop: 'connected' });
  });

  api.post('/whoop/sync', async (req, res) => {
    const scope = scopeOf(res);
    if (!(await whoop.isConnected(scope))) return void res.status(400).json({ error: 'WHOOP is not connected' });
    inBackground('sync', whoop.syncWhoop(scope, { full: Boolean(req.body?.full) }));
    res.json(await status(res));
  });

  /**
   * One sync for everything the server can fetch, used by the web's Sync now, the dashboard when it opens,
   * and the iPhone app after it pushes Apple Health. Today that's WHOOP, in the background. A sync that
   * is running or finished in the last two minutes isn't repeated, so opening several tabs doesn't pile up.
   */
  api.post('/sync', async (_req, res) => {
    const scope = scopeOf(res);
    let started = false;
    if (await whoop.isConnected(scope)) {
      const s = await whoop.syncState(scope);
      const recent = s.lastSync && Date.now() - Date.parse(s.lastSync) < SYNC_COOLDOWN_MS;
      if (!s.running && !recent) {
        inBackground('sync', whoop.syncWhoop(scope));
        started = true;
      }
    }
    const out = await status(res);
    // The background run hasn't marked itself running yet; say so, so callers know to watch /status.
    if (started) out.whoop.syncing = true;
    res.json({ ...out, whoopStarted: started });
  });

  api.post('/whoop/disconnect', async (_req, res) => {
    await whoop.disconnect(scopeOf(res));
    res.json(await status(res));
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
