# healthOS

A personal health dashboard for **Apple Health** and **WHOOP** data. It runs in two places:

- **Hosted** at https://health.mcfly.bot: the `healthos` project on Vercel, with a Neon Postgres database. Accounts are invite-only, and each person gets their own dashboard; members who share see each other's daily tile and last 30 days on the Family board. This is where you look at it.
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
- WHOOP syncs every hour from a Vercel cron.
- The iPhone app posts to `/api/apple/ingest` with its own token.
- Your photo is served from the database, behind the same sign-in.
- The only public page is the privacy policy at `/privacy` (`public/privacy.html`), which the WHOOP developer app requires. It holds no data.

## Accounts and the admin panel

healthOS is multi-user and invite-only. There is no open sign-up.

- **First sign-in:** on a database with no accounts yet, sign in with your email and the password from `setup-vercel.sh`. That creates the first admin account, which keeps every row you already had.
- **Inviting someone:** open **Admin → Invites** and create a code, such as `8DX7-X782`. You can lock it to one email address, but nothing is emailed: you share the code yourself. They enter it under **Have an invite code?** on the sign-in page, or in the iPhone app. The link shown with it carries the same code. A code creates one account and expires after the number of days you set (7 by default).
  - Codes are 8 characters with no look-alikes (0/O, 1/I/L). They work in any case, with or without the dash, or as a pasted link.
  - Failed attempts are rate-limited per address, like sign-in.
- **First run:** a new account (and the first admin on a fresh install) goes through three short steps, **Make this space yours**: how Home and Body show you (your portrait, a digital human or just the statistics), a little about you (how you describe yourself, never used for health calculations, and your age), and whether to take part in anonymous peer comparisons. Each step saves as it goes (`Settings.onboarding` holds the step), so a refresh resumes where you were. Existing accounts never see it; anyone can run it again from **Profile → Edit preferences** (`#/welcome`). Nothing on the server waits for it, so the iPhone app works the same throughout.
- **Forgotten passwords:** there's no email service. An admin creates a reset link under **Admin → People** and passes it on. Using it sets a new password and signs that person out everywhere else.
- **Admins can:**
  - change roles
  - disable and enable accounts (disabling signs the person out at once)
  - delete accounts (this removes all of that person's data: every table in `USER_TABLES`, server/db.ts, which `test/user-tables.test.ts` checks against the schema)
  - close sign-ups
  - set the default units and step goal

  There is always at least one active admin.
- **What admins see:** each account's email, name, last sign-in, how many days of data it has, and whether its Apple Health and WHOOP syncs are healthy. The admin screens never show anyone's health values, journal, blood records, body measurements, portraits, age, keys or peer-comparison choice.
- **Profile** (`#/profile`, also `#/settings`) holds everything a person sets: perspective and age, the chatbot and their own AI keys, units and step goal, cards, the Family board, cycle tracking, nutrition, the password, portraits, **Export your data** (a JSON download built only from their own session, `GET /api/me/export`, once a minute; nutrition amounts the person's Nutrition setting hides are left out, as everywhere else) and **Your age-group comparison** (`GET /api/peers`).
- **Isolation:** every row in `daily`, `workouts`, `events`, `tokens`, `profile_assets` and `user_settings` carries a `user_id`, and every query filters on it. `test/multiuser.test.ts` checks this over HTTP with two accounts.
- **Each person's data sources:**
  - WHOOP, connected from **Integrations**.
  - The iPhone app, using a personal token created under **Integrations → Apple Watch / Health → Set up the iPhone app**. The token can only write to that person's account.
- **Mac-only steps:** the Apple Health export import and photo processing run on the Mac. Both go to the owner's account. The terminal import can target someone else: `HEALTHOS_USER_ID=<id> npm run import:apple -- export.zip`.

## Ask McFly

Ask McFly (`#/mcfly`, or the pill on Home) is a chat assistant for questions about your own data. It runs on Claude with the server's key, or on a person's own OpenAI, Claude or Gemini key (below). Each person who signs in gets their own.

- **What it can read:** five read-only tools in `server/mcfly.ts`:
  - which metrics exist
  - a day's summary
  - up to six metrics' history, at daily, weekly or monthly resolution
  - workouts
  - sleep times

  Every tool runs in the signed-in person's scope and returns values in their units. It can't change data or settings, or read anyone else's.
- **Model and limits:**
  - The default model is `claude-opus-5-5` with medium effort. Server-side refusal fallbacks are on.
  - Admins can change the model and the per-person daily question limit under **Admin → Settings**. A limit of 0 turns McFly off.
- **Privacy:**
  - The server keeps no conversation. The browser holds the chat in session storage and sends it as plain text with each question.
  - healthOS stores only daily counts of questions and tokens per person (`mcfly_usage`). Admins see those counts, never the questions.
  - Questions, data and answers are never logged.
- **Setup:** create an API key in the Claude Console and add it to the Vercel project as `ANTHROPIC_API_KEY`. Then redeploy:

```bash
vercel env add ANTHROPIC_API_KEY production
```

  Without the key, the page says McFly isn't set up yet. Locally, put the key in `.env`.

### Your own AI keys (optional)

Set `HEALTHOS_DATA_KEY` (generate it once with `openssl rand -hex 32`) to let people connect their own OpenAI, Claude or Gemini key under **Profile → Chatbot** and **Profile → OpenAI · Nutrition & portraits**. Keys are checked with the provider, then stored encrypted with it (AES-256-GCM, bound to the account, `server/ai/keys.ts`); the browser only ever sees the last 4 characters. Unset, nobody can store a key and everyone uses `ANTHROPIC_API_KEY` as before.

- **Routing** (`server/ai/resolve.ts`): Ask McFly uses the provider the person chose when its key is stored, else the shared Claude key. Meal estimates use their own OpenAI key, else their own Claude key, else the shared key. Lab report reading uses their own Claude key, else the shared key. Voice notes (`POST /api/ai/transcribe`) and portraits need an OpenAI key: their own, or the server's optional `OPENAI_API_KEY`, which is never used for estimates. On the server's key, voice notes are limited to `VOICE_NOTES_PER_DAY` (40) a person a day (`mcfly_usage.voice_notes`, by UTC date, given back when OpenAI fails); on a person's own key they aren't counted, and they never count as McFly questions.
- **Limits:** the admin's daily limit applies only to the shared key. Questions on a person's own key are counted apart (`mcfly_usage.own_*`, up to 200 a day across chat, estimates and the digest) and never appear in the admin's cost view.
- **Models** for people's own OpenAI and Gemini keys are platform settings: `openai_model`, `openai_vision_model`, `openai_transcribe_model`, `gemini_model`.
- **Rotating `HEALTHOS_DATA_KEY`:** don't change or lose it casually: stored keys become unreadable and people have to paste them again. To rotate, set the new key as `HEALTHOS_DATA_KEY` and the old one as `HEALTHOS_DATA_KEY_PREVIOUS`; each stored key is re-encrypted the next time it's used, so keep the previous key set until everyone has used theirs. `scripts/setup-vercel.sh` doesn't set it: add it once with `vercel env add HEALTHOS_DATA_KEY production`.

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

### Fitbit / Google Health (file import)

Request your data at takeout.google.com, choosing only Fitbit (or Google Health, for accounts moved to Google). Then open **Integrations → Import Fitbit data** and choose the .zip file(s) or the unzipped folder. The export is read in the browser, in a Web Worker (`src/import/`), and the file is never uploaded: per-day readings and each night's sleep stretches go to `POST /api/fitbit/import` in chunks of whole days under 3.5 MB, stored as source `fitbit`, which ranks after Apple Health and WHOOP. **Remove Fitbit data** deletes them. The summary on Integrations counts every Fitbit day stored, so a split export can be imported one .zip at a time. Google doesn't document the Takeout layout, so files are matched by name pattern; check a real export if something doesn't come through. There's no automatic Fitbit sync: the Fitbit Web API is being retired, and the Google Health API's scopes are restricted.

### The iPhone app

`ios/` holds **healthOS for iPhone**, which does two jobs:

- It shows the full dashboard natively: Today, Trends and workouts, read from the same API as the website.
- It pushes HealthKit data to this server, so you don't have to export by hand. It applies the same rules as the export import, on the phone, and sends only the days that changed. The first sync uploads your history; after that, Health wakes the app when new data arrives.

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

The first sync pulls the last year. After that it syncs every hour (a Vercel cron when hosted, a timer when local), and on demand. Each sync re-reads the last few days, because WHOOP rescores recent nights.

## Profile photo and portraits

Home and Body show you as your portrait, a digital human (`public/figures/digital-man.webp`; a `digital-woman.webp` dropped next to it is picked up, and each figure's callout points are in the `ART` table in `src/components/Figure.tsx`), or just the statistics, as chosen in onboarding or **Profile → Edit preferences**.

**Portraits** (Profile → Your portrait photos): a person uploads private reference photos (`portraits` table, owner-only), and **Make my portrait** sends one, with the healthOS figure as the style reference, to OpenAI's image edit on their own OpenAI key or else the server's `OPENAI_API_KEY`. Nothing generated shows until they choose **Use this portrait**, which runs the usual in-browser cut-out and saves it as their photo. The style reference is copied into `server/portraitStyle.ts` so the hosted function has it: after replacing `digital-man.webp`, run `node scripts/portrait-style.mjs` (`npm test` fails until you do).

**Use a photo as is** (the same section) adds a photo directly. Hosted, it's cut out in the browser. On the Mac, the first run compiles a small Swift tool (`server/photo/cutout.swift`). It uses Apple's Vision framework, entirely on this Mac, to:

- cut you out of the background for the Home figure, cleaning the edges so no rim of the old backdrop shows
- find your face, neck and shoulders, so the vitals callouts land on your forehead, throat and chest, with labels placed in the open space beside your outline
- make a square avatar

On the dashboard the photo and avatar are shown in black and white. In the light theme the blacks are lifted toward the page's ink; in dark mode they stay deep.

The cut-out, avatar and layout points are saved to the database, which is how the hosted copy shows them. The working files, including a downscaled copy of the original, stay in `data/profile/` on your Mac. That copy means an improved version of the tool reprocesses your photo automatically the next time the local server starts. **Remove photo** deletes all of it.


## When both sources are connected

| Metric | Preferred source |
|---|---|
| Recovery, strain, HRV, resting HR, SpO₂, respiratory rate, sleep | WHOOP, then Apple |
| Steps, active energy, workouts, weight, body fat, VO₂ max | Apple, then WHOOP |
| Weight, body fat, lean mass you add yourself | Yours, then the devices |

A Fitbit export comes after both devices for every metric.

WHOOP reports HRV as RMSSD and Apple Watch reports SDNN. The two aren't comparable, so the dashboard labels whichever one it's showing.

## Body measurements

Weight, body fat and lean body mass can be added by hand on Body (**+ Add entry**): `GET/POST /api/body/entries`, `PATCH`/`DELETE /api/body/entries/:id`, and `GET /api/body/latest`. Entries are stored in kg and % (`body_entries`) and each day's latest is mirrored into `daily` as source `manual`, so every chart, sheet and McFly sees it and it wins that day over a device's reading. Locally, entries can't be added while demo data is showing.

## Blood records and the journal

Blood records (`#/labs`) keeps each result as printed (`lab_results`) and, separately, the original reports (`lab_documents`): a PDF or a photo, HEIC turned into JPEG and shrunk to 4 MB in the browser, up to 200 per person. Reports are served only to their owner, inline, sandboxed and with `nosniff`. Reading a report's results with Claude (`POST /api/labs/extract?document=`) happens only when the person asks, and the rows come back as a draft to check.

The journal (`#/journal`, `/api/journal`) holds private check-ins in `journal_entries`. Nothing else on the server reads that table; account deletion and the person's own export are the only other code that touches it.

## Nutrition

Nutrition (`#/nutrition`) is off until a person turns it on and chooses how much they see. Today is a conversation: tell McFly what you ate, in words, a photo or a voice note, check its estimate, then save it. Trends, Macros, Hydration and Log (`?tab=…`) show more days. The day is read with `POST /api/nutrition/log/day {date}`, since no nutrition URL carries a date or an amount.

## Peer comparisons

Profile → Your age-group comparison (`GET /api/peers`, `server/peers.ts`) needs sign-in, the person's own opt-in and an age of 18 or over. It compares 30-day averages for the same metric from the same source within an age band, and shows results only when at least 20 other participants each have 7 recorded days; only the group's rounded quartiles, a size range, and which quarter the person's own average falls in leave the server (never a fine percentile, which repeated queries could turn into other people's values). At family scale it will mostly say there aren't enough people yet. Locally, the demo owner sees a made-up sample group.

## Cycle tracking

Cycle tracking (`#/cycle`, `GET /api/cycle`) is off until a person turns on **Track my cycle** in their Profile. It reads periods, ovulation tests, mucus, thermometer readings and symptoms from Apple Health and what's logged on the Cycle page, together with the nightly temperature Apple Watch (`wrist_temp`) and WHOOP (`skin_temp`) already record. The engine lives in `server/cycle/`:

- `records.ts`: storage in the `cycle` table, one row per date, kind and source (symptoms take one row each), and input validation.
- `temperature.ts`: each device's readings against the person's own level on that device (a rolling median), with outliers and mornings marked as disturbed left out. Devices are never mixed: each cycle uses the one that covered it best. A rise counts when three readings clear the cover line (the highest of the six low readings before), the third by 0.2 °C on a thermometer or 0.15 °C on a wearable, and the readings after stay high. A positive LH test lets two readings confirm it. Ovulation is the last low day.
- `engine.ts`: periods, each cycle's ovulation and phase lengths, and the current cycle's forecast. Cycle and luteal lengths start from typical values and shift to the person's own, recent cycles counting most. Ovulation is a distribution that this cycle's LH tests, mucus and temperatures reshape. Each day's chance of conception follows from it. The next period's date and range are that distribution's median and 10th to 90th percentiles.
- `insights.ts`: resting heart rate, HRV and temperature before and after ovulation, when symptoms tend to come, and recent cycles outside the FIGO 2018 ranges.

The temperature method follows what Natural Cycles has published about its own, which is closed source: Bull et al. 2019 ([npj Digital Medicine 2:83](https://www.nature.com/articles/s41746-019-0152-7)) and Berglund Scherwitzl et al. 2016. The typical values come from Bull et al.: cycles of 29.3 days and luteal phases of 12.4. Fertile-day weights follow Wilcox et al. 1995. Nothing marks a day as safe, and none of it is fit to use as contraception.

Until two of the person's own cycles are complete, the estimate is in `earlyEstimate` and `estimate` stays `null`, so iPhone builds that predate it keep saying "not yet". The Family board's phase word only uses `estimate`.

## Scripts

| Command | What it does |
|---|---|
| `npm run dev` | App with hot reload on http://localhost:8787 |
| `npm run build` then `npm start` | Production build |
| `npm test` | Importer, iPhone ingest, WHOOP mapping, data blending, account isolation and Ask McFly tests |
| `npm run typecheck` | TypeScript check |
| `npm run sync:whoop -- --full` | Re-sync a full year of WHOOP data from the terminal |
| `npm run deploy` | Build for Vercel and deploy health.mcfly.bot |
| `npm run migrate:sqlite` | Copy data from the original SQLite file (`data/healthos.db`) into the current database |

## Privacy

- **Hosted:**
  - Nothing is readable without signing in, and each person reads only their own data, apart from the Family board tiles of members who share (GET /api/family; see server/family.ts).
  - Only hashes of passwords, invite codes, reset links and iPhone tokens are stored.
  - Preview deployments and `*.vercel.app` URLs are also behind Vercel's own login.
  - Responses carry strict security headers.
- **Local:** the server listens only on `127.0.0.1`.
- It rejects requests with any other Host header.
- LAN mode (`HEALTHOS_LAN=1`, opt-in) adds one port that accepts Apple Health pushes from your phone with a bearer token. It serves no health data. The connection is plain HTTP, so use it only on a network you trust.
- Every write requires a custom header, so other websites open in your browser can't post to it.
- `data/` and `.env` are git-ignored.
