# healthOS

A personal health dashboard for **Apple Health** and **WHOOP** data. It runs on your Mac. Your data goes into a local SQLite database under `data/` and never leaves the machine, except for the requests that pull your own WHOOP data from WHOOP's API.

Until you connect a source, the dashboard shows clearly labeled demo data.

## Run it

Requires Node 22.18+ (it uses Node's built-in TypeScript and SQLite support).

```bash
npm install
```

```bash
npm run dev
```

Then open http://localhost:8787.

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

## WHOOP

WHOOP data comes from the official [WHOOP API](https://developer.whoop.com) (v2) over OAuth.

1. Create an app at developer.whoop.com.
2. Add the redirect URL `http://localhost:8787/api/whoop/callback`.
3. Enable the read scopes: recovery, cycles, sleep, workout, profile and body measurement.
4. Copy `.env.example` to `.env` and fill in `WHOOP_CLIENT_ID` and `WHOOP_CLIENT_SECRET`.
5. Restart `npm run dev`, then click **Connect WHOOP** on the Integrations page.

The first sync pulls the last year. After that the app syncs every 6 hours while it's running, and on demand. Each sync re-reads the last few days, because WHOOP rescores recent nights.

## Profile photo and 3D view

Add a photo of yourself under **Settings → Profile photo**. The first run compiles a small Swift tool (`server/photo/cutout.swift`). It uses Apple's Vision framework, entirely on this Mac, to:

- cut you out of the background for the Home figure, which uses the same fade as the rest of the design
- find your face, neck and shoulders, so the vitals callouts land on your forehead, throat and chest
- make a square avatar
- estimate a depth relief for **View in 3D**

That 3D view comes from a single photo, so it's a 2.5D relief: you can turn it about ±35°, but there is no back or side to show. Everything is stored in `data/profile/`, and **Remove photo** deletes it.

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
| `npm test` | Importer and WHOOP mapping tests |
| `npm run typecheck` | TypeScript check |
| `npm run sync:whoop -- --full` | Re-sync a full year of WHOOP data from the terminal |

## Privacy

- The server listens only on `127.0.0.1`.
- It rejects requests with any other Host header.
- Every write requires a custom header, so other websites open in your browser can't post to it.
- `data/` and `.env` are git-ignored.
