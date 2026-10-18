// Entry point for the hosted function (bundled by scripts/build-vercel.mjs).
import express from 'express';
import { createApp } from './app.ts';
import { getStore } from './store.ts';

async function build() {
  if (!process.env.DATABASE_URL) {
    // Fail clearly instead of crashing: the Neon integration hasn't been connected to this project yet.
    // The fix goes to the logs; anyone who opens the site just sees that it's unavailable.
    console.error('[healthos] No database connected. Add Neon under the healthos project → Storage, then redeploy.');
    const app = express();
    app.use((_req, res) => void res.status(503).json({ error: "healthOS isn't available right now. Try again later." }));
    return app;
  }
  return createApp({ db: await getStore(), hosted: true, ingestToken: process.env.HEALTHOS_INGEST_TOKEN?.trim() || undefined });
}

export default await build();
