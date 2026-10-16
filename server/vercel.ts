// Entry point for the hosted function (bundled by scripts/build-vercel.mjs).
import express from 'express';
import { createApp } from './app.ts';
import { getStore } from './store.ts';

async function build() {
  if (!process.env.DATABASE_URL) {
    // Fail clearly instead of crashing: the Neon integration hasn't been connected to this project yet.
    const app = express();
    app.use((_req, res) => void res.status(503).json({ error: 'No database connected. Add Neon under the healthos project → Storage.' }));
    return app;
  }
  return createApp({ db: await getStore(), hosted: true, ingestToken: process.env.HEALTHOS_INGEST_TOKEN?.trim() || undefined });
}

export default await build();
