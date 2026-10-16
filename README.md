# healthOS

A personal health dashboard for **Apple Health** and **WHOOP** data. It runs in two places:

- **Hosted** at https://health.mcfly.bot: the `healthos` project on Vercel, behind a password, with a Neon Postgres database. This is where you look at it.
- **Locally** on your Mac. The two jobs that need the Mac happen here: importing an Apple Health export, and processing your photo with Apple Vision. Point the local copy at the hosted database and those land on health.mcfly.bot too.

With no `DATABASE_URL`, the local copy uses its own Postgres (PGlite, under `data/pglite`). It shows clearly labeled demo data until you connect a source.

## Run it locally

Requires Node 22.18+ (it uses Node's built-in TypeScript support).

```bash
npm install
```

```bash
npm run dev
```

Then open http://localhost:8787.

## Hosted at health.mcfly.bot

One-time setup:

1. Run `bash scripts/setup-vercel.sh`. It asks for your dashboard password and stores only an scrypt hash on Vercel. It also generates the session, cron and iPhone-ingest secrets, and optionally takes your WHOOP app credentials.
2. In Vercel, open project **healthos** → Storage → Create Database → **Neon**, in US East. Connect it to Production and Development. This adds `DATABASE_URL`.
3. Deploy:

```bash
npm run deploy
```

4. Bring your data across. `vercel env pull .env.local` gives the local copy the hosted `DATABASE_URL`. Then either move what you already have locally:

```bash
npm run migrate:sqlite
```

   or import a fresh export (`npm run import:apple -- ~/Downloads/export.zip`).

How the hosted copy works:

- Every API call needs your session (a signed, HttpOnly cookie, valid for 30 days). Failed sign-ins lock out the guessing address for 15 minutes.
- WHOOP syncs every 6 hours from a Vercel cron.
- The iPhone app posts to `/api/apple/ingest` with its own token.
- Your photo is served from the database, behind the same sign-in.

## Apple Health

Apple has no web API for HealthKit. Data reaches the dashboard through the export file:

1. On your iPhone, open **Health**, tap your profile picture, then **Export All Health Data**.
2. AirDrop or save `export.zip` to your Mac.
3. Drop it on the **Integrations** page, or import it from the terminal. The terminal is faster for multi-GB exports:

```bash
npm run import:apple -- ~/Downloads/export.zip
```

A new import replaces the previous one. The uploaded copy is deleted once it has been read.

How the export is interpreted:

- **Days follow the wearer's local time.** Each record keeps its own UTC offset, so travel doesn't shift days.
- **Steps, energy and distance:** when both iPhone and Watch log the same walk, the day uses the larger source rather than adding them together.
- **Sleep counts toward the day you wake up.** When several apps log the same night, the source with the most sleep wins.

### Automatic sync with the iPhone app

`ios/` holds **healthOS Sync**, a small iPhone app that reads HealthKit and pushes changes to this server, so you don't have to export by hand. It applies the same rules as the export import, on the phone, and sends only the days that changed. The first sync uploads your history; after that, Health wakes the app when new data arrives.

1. Set `HEALTHOS_INGEST_TOKEN` on the server (create one with `openssl rand -hex 24`). Without it the endpoint is off.
2. Build the app onto your iPhone (see [ios/README.md](ios/README.md)). It posts to `https://health.mcfly.bot/api/apple/ingest` by default.
3. Paste the token, allow Health access, then tap **Sync now**.

To sync to a Mac instead, also set `HEALTHOS_LAN=1`. That opens a second port (8788) serving only `POST /api/apple/ingest`, and only with the token, while the dashboard stays on `127.0.0.1`. Enter the LAN address it prints in the app.

A sync only adds and updates days. The exceptions are workouts and mindful sessions you delete in Health, which are removed too. An export import still replaces all Apple Health data, including what the app sent.

## WHOOP

WHOOP data comes from the official [WHOOP API](https://developer.whoop.com) (v2) over OAuth.

1. Create an app at developer.whoop.com.
2. Add the redirect URL `https://health.mcfly.bot/api/whoop/callback`. For a purely local setup, use `http://localhost:8787/api/whoop/callback`.
3. Enable the read scopes: recovery, cycles, sleep, workout, profile and body measurement.
4. Hosted: give the client ID and secret to `scripts/setup-vercel.sh`. Local: put `WHOOP_CLIENT_ID` and `WHOOP_CLIENT_SECRET` in `.env`.
5. Click **Connect WHOOP** on the Integrations page.

The first sync pulls the last year. After that it syncs every 6 hours (a Vercel cron when hosted, a timer when local), and on demand. Each sync re-reads the last few days, because WHOOP rescores recent nights.

## Profile photo

Add a photo of yourself under **Settings → Profile photo**. The first run compiles a small Swift tool (`server/photo/cutout.swift`). It uses Apple's Vision framework, entirely on this Mac, to:

- cut you out of the background for the Home figure, cleaning the edges so no rim of the old backdrop shows
- find your face, neck and shoulders, so the vitals callouts land on your forehead, throat and chest, with labels placed in the open space beside your outline
- make a square avatar

On the dashboard the photo and avatar are shown in black and white. In the light theme the blacks are lifted toward the page's ink; in dark mode they stay deep.

The cut-out, avatar and layout points are saved to the database, which is how the hosted copy shows them. The working files, including a downscaled copy of the original, stay in `data/profile/` on your Mac. That copy means an improved version of the tool reprocesses your photo automatically the next time the local server starts. **Remove photo** deletes all of it.

Photos can only be added or replaced from the local copy, since Vision runs on macOS.

## When both sources are connected

| Metric | Preferred source |
|---|---|
| Recovery, strain, HRV, resting HR, SpO₂, respiratory rate, sleep | WHOOP, then Apple |
| Steps, active energy, workouts, weight, body fat, VO₂ max | Apple, then WHOOP |

WHOOP reports HRV as RMSSD and Apple Watch reports SDNN. The two aren't comparable, so the dashboard labels whichever one it's showing.

## Scripts

| Command | What it does |
|---|---|
| `npm run dev` | App with hot reload on http://localhost:8787 |
| `npm run build` then `npm start` | Production build |
| `npm test` | Importer, iPhone ingest and WHOOP mapping tests |
| `npm run typecheck` | TypeScript check |
| `npm run sync:whoop -- --full` | Re-sync a full year of WHOOP data from the terminal |
| `npm run deploy` | Build for Vercel and deploy health.mcfly.bot |
| `npm run migrate:sqlite` | Copy data from the original SQLite file (`data/healthos.db`) into the current database |

## Privacy

- **Hosted:**
  - Nothing is readable without signing in.
  - Only a hash of your password is stored.
  - Preview deployments and `*.vercel.app` URLs are also behind Vercel's own login.
  - Responses carry strict security headers.
- **Local:** the server listens only on `127.0.0.1`.
- It rejects requests with any other Host header.
- LAN mode (`HEALTHOS_LAN=1`, opt-in) adds one port that accepts Apple Health pushes from your phone with a bearer token. It serves no health data. The connection is plain HTTP, so use it only on a network you trust.
- Every write requires a custom header, so other websites open in your browser can't post to it.
- `data/` and `.env` are git-ignored.
