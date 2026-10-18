// Local server: the API (server/app.ts) plus the Vite dev server or the built client, on localhost.
// With DATABASE_URL set (e.g. pulled from Vercel into .env.local) it reads and writes the hosted
// database, which is how exports and photos processed on this Mac reach health.mcfly.bot.
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import express from 'express';
import { lanIngestApp } from './apple/ingest.ts';
import { createApp } from './app.ts';
import { seedDemo } from './demo.ts';
import { refreshPhotoIfStale } from './photo.ts';
import { OWNER_ID, getStore } from './store.ts';
import * as whoop from './whoop.ts';

const ROOT = path.resolve(import.meta.dirname, '..');
const PORT = Number(process.env.PORT ?? 8787);
const HOST = process.env.HOST ?? '127.0.0.1';
const PROD = process.env.NODE_ENV === 'production';
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

const db = await getStore();
// Demo rows only ever go into a local database, never the hosted one.
if (db.kind === 'pglite') await seedDemo(db);
refreshPhotoIfStale({ db, userId: OWNER_ID }).catch((e) => console.error('[photo] reprocessing failed:', e.message));

const app = createApp({ db, hosted: false, ingestToken: INGEST_TOKEN });
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
  console.log(`healthOS running at http://localhost:${PORT} (${db.kind === 'neon' ? 'hosted database' : 'local database'})`);
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

// Keep WHOOP current while the app runs locally. Against the hosted database, the Vercel cron does this.
if (db.kind === 'pglite') {
  const autoSync = async () => {
    if (!whoop.isConfigured()) return;
    await whoop.syncAllWhoop(db);
  };
  const run = () => autoSync().catch((e) => console.error('[whoop] auto sync failed:', e.message));
  setTimeout(run, 5_000);
  setInterval(run, 3_600_000).unref();
}
