# healthOS for iPhone

The healthOS dashboard as a native SwiftUI app. It also sends your iPhone's Apple Health data to the server automatically, so you don't need the manual `export.zip` import.

## Dashboard

The app reads the same API as the website (`/api/summary`, `/api/trends`, `/api/workouts`, `/api/status`). It shows the same numbers, including WHOOP recovery and strain, which only the server has.

- **Today:**
  - the greeting, then your profile photo as an organic portrait: it reveals through a short ASCII sweep once per launch (skipped with Reduce Motion), with heart, breathing and temperature dots, leader-line callouts, and Slept, Steps and HRV shapes around it;
  - the day's path, and a "week so far" summary;
  - six cards: recovery or VO₂ max, blood oxygen, HRV, sleep, strain or active energy, and steps against your goal;
  - the day's timeline and insights.
  - Arrows step through past days. Pull down to refresh, which also pushes any new Health data.
  - **Ask McFly:** a pill above the tab bar opens a chat with the dashboard's assistant (`/api/mcfly`, streamed from `/api/mcfly/chat`). The conversation stays in memory only. It shows how many questions are left today, and the pill is hidden when the server has McFly off.
- **Trends:** Vitals, Sleep (stacked stages), Activity (steps against goal, plus workouts) and Body, over 30 days, 90 days or a year. Drag across a chart to read a single day.
- **Cycle** (only while cycle tracking is on): this cycle's phase ring and estimates, each fertile day's estimated chance, the temperature curve for any cycle (cover line, ovulation, the rise after it), a five-week calendar, past cycles split before and after ovulation, and patterns from your own cycles. Estimates never mark a day as safe.
- **Settings:**
  - server address and sign-in status;
  - the profile photo: **Change photo** picks one from Photos and cuts it out on the phone with Apple Vision, using the same steps as the Mac tool `server/photo/cutout.swift`. After a Save/Cancel preview it uploads to `POST /api/profile/photo/upload`;
  - the Apple Health sync controls.

Cards hide or switch to fit your sources, as on the web: no WHOOP means VO₂ max instead of recovery, active energy instead of strain, and HRV labelled SDNN.

**Sign-in:** the same account as the website. On servers with per-person accounts the app asks for email and password; older single-user servers need only the password. The app works with either.
- **Invites:** someone invited taps **Have an invite code?** and enters the code, or pastes the whole invite link. They pick a name, email and password, and land on their own dashboard. No email is ever sent.
- **Session:** the 30-day session cookie lives in the Keychain.
- **Local servers:** one with no password set needs no sign-in.
- **Offline:** the last summary is cached on the phone, so the app opens with numbers even offline.
- **Fresh data without re-downloading:** the app checks `GET /api/version` on open, on return, after syncs and every minute while open. It downloads the summary and trends again only when the version changed or the day rolled over, or on pull to refresh. Servers without `/api/version` get a reload on open, on return and after syncs.

## Apple Health sync

- **Reads** steps, active energy, exercise minutes, walking + running distance, heart rate, resting HR, HRV (SDNN), blood oxygen, respiratory rate, sleeping wrist temperature, body temperature, weight, body fat, lean mass, VO₂ max, sleep stages, mindful sessions and workouts.
- **Finds what changed** with one HealthKit anchored query per type. Only the local days touched by new samples are re-read.
- **Aggregates on the phone** into the same per-day rows as `server/apple/import.ts`:
  - Sum metrics keep the best single source per day.
  - Steps WHOOP writes into Health compete too (iPhone, Watch or WHOOP; the highest total wins, never the sum), and the hours follow the winner. WHOOP's other records stay skipped, because healthOS reads WHOOP's API.
  - Sleep counts toward the wake day (6 h rollover). Overlapping segments are merged, and the source with the most sleep wins.
  - Days use each record's own time zone (`HKMetadataKeyTimeZone`, or the device's).
- **Uploads** a week of days per request to `POST /api/apple/ingest` with the bearer token, newest week first. A day whose upload fails stays queued for the next sync.
  - Every sync sends today, plus any changed day in the last 30.
  - Older days (the first upload, or the one-time hourly backfill) wait in a saved queue. They go up newest first, four weeks per pass, only while the app is open and not in Low Power Mode. Settings shows how many are left.
- **Cycle tracking:** menstrual flow, spotting, ovulation tests, cervical mucus, sexual activity, basal body temperature and Health's cycle symptoms (cramps, bloating, headache and the rest; one logged as "not present" is left out). The app reads these only after you turn cycle tracking on in healthOS settings and the server answers that it stores cycle days. Each day sent replaces that day on the server.
- **Nutrition** (food totals from the apps you log meals in): energy, protein, carbs, fat, fiber, sugar, saturated fat, sodium and alcoholic drinks.
  - **Off by default.** The app reads, asks Health about and watches these types only while the server's ingest reply says you turned Nutrition on (`nutritionOn`) and lists the nutrients it takes (`nutrients`). Off, it reads none of them, and it never writes food.
  - **Turning it on:** the sync that hears it asks Health about the food types and then reads their whole history. Turning it off forgets where reading stopped, so turning it on again sends the history again.
  - **Per app, never summed:** each day goes up as each app's own totals, and the server shows one app a day, because apps copy each other's logs through Health. A meal saved as a Food correlation counts once. Each day sent replaces that day.
  - **Deletions:** a food sample deleted in Health re-sends the last month, and a day left with no food goes up as `apps: []`, which clears it. An empty day is never sent otherwise: Health reads as empty when food access is off.
  - **Late writes:** food apps often write late, so the last three days are read again on every sync. Food energy alone wakes the app in the background.
  - **Values the server would refuse stay on the phone:** a total above its cap (a unit mix-up) is left out, so one bad log can't block a sync. Caffeine and water stay daily metrics, as before.
- **Sleeping wrist temperature** counts toward the morning the night ends, like sleep, so it lines up with WHOOP's skin temperature for the cycle engine. Builds before this dated it by the evening the night began: the first sync after updating reads its history again once and re-sends every day it moved from or to, and the server drops a wrist reading from any day sent without one.
- **Syncs in the background:**
  - **HealthKit wakes:** an `HKObserverQuery` per type plus `enableBackgroundDelivery`. Wakes are hourly for heart rate, steps, energy, distance, exercise and breathing, and immediate for everything else.
  - **Backstop:** a `BGAppRefreshTask` (`health.mcfly.sync.refresh`).
  - **On a wake:** the app pushes changed recent days, then sends `POST /api/sync` so the server refreshes WHOOP, at most every 15 minutes.
  - **Skipped in Low Power Mode.** Health data also can't be read while the phone is locked.

Workouts and mindful sessions are keyed by their HealthKit UUID. If an earlier `export.zip` import holds the same one (same start instant and type), the server replaces the imported copy, so nothing is duplicated.

## Server setup

The app pushes to `https://health.mcfly.bot/api/apple/ingest` by default. Set the shared secret on the server, as a Vercel environment variable or in `.env` locally:

```bash
HEALTHOS_INGEST_TOKEN=paste-the-output-of-openssl-rand-hex-24
```

Without it, the endpoint answers 503 and accepts nothing.

## Install on your iPhone

Needs iOS 17 or later. Built and tested with Xcode 27. Bundle ID `health.mcfly.sync`, team `92X9CP6C6D`.

1. Install the latest build from **TestFlight**. In App Store Connect → TestFlight, add yourself to an internal testing group once; new builds then appear in the TestFlight app. For a quick local install instead, run the `HealthOSSync` scheme on your phone from Xcode.
2. Open the app and sign in, or join with an invite code. It already points at `https://health.mcfly.bot`.
3. In **Settings**, paste your ingest token, then tap **Test connection**. Each person gets their own on the dashboard under Integrations → iPhone app; the owner can also use the `HEALTHOS_INGEST_TOKEN` value set on Vercel.
4. Tap **Sync now**. When the Health sheet asks how much history to share, pick **All Recorded Data** if you want a full backfill. The **First upload covers** setting can limit it further.
5. For background sync, leave **Background App Refresh** on for the app (Settings → General).

### Shipping a new TestFlight build

```bash
ios/testflight.sh
```

The script bumps the build number in `project.yml`, archives a Release build, and uploads it with the Apple account signed in to Xcode. Apple then processes the build, usually in 5–30 minutes, before it shows up in TestFlight. Change `MARKETING_VERSION` in `project.yml` for a new version number.

### Syncing to a Mac instead

To keep data on your Mac, run the server there with `HEALTHOS_LAN=1` as well as the token. It logs a LAN address such as `http://192.168.1.20:8788`, which you enter in the app instead. That port serves only the ingest endpoint. The phone must be on the same network, and iOS asks once for Local Network access.

## Simulator

Simulator builds have an extra **Add sample Health data** button. It writes two weeks of plausible data into the simulator's Health store, so the whole flow can be tried without a phone. Device builds never ask for write access.

**Point the simulator only at a scratch server.** Whatever is in its Health store is uploaded as real Apple Health data. Never use the hosted site. Avoid `localhost:8787` too: with `DATABASE_URL` in `.env.local`, that server writes to the hosted database. Simulator builds start with no server address for this reason. The simulator shares the Mac's network, so a scratch server on the Mac is reachable at localhost:

```bash
env -u DATABASE_URL HEALTHOS_DATA_DIR=/tmp/healthos-scratch PORT=8790 HEALTHOS_INGEST_TOKEN=any-test-token-16chars node server/index.ts
```

Then enter `http://localhost:8790` and that token in the app's Settings.

Build and test from the terminal:

```bash
xcodebuild -project ios/HealthOSSync.xcodeproj -scheme HealthOSSync -destination 'platform=iOS Simulator,name=iPhone 17' test
```

For scripted runs, `xcrun simctl launch booted health.mcfly.sync -healthosToken <token>` sets the token (simulator builds only).

## Project file

`HealthOSSync.xcodeproj` is generated from `project.yml`. After adding files or changing settings, run `xcodegen generate` (`brew install xcodegen`).

## Known limits

- Deleted workouts and mindful sessions are removed on the server too. For other deleted samples, the app re-checks the last 30 days of daily values; for older edits, use **Upload all history again**.
- If every sample of a metric on a day is deleted, the server keeps the old value: a sync only adds and updates.
- Types you don't allow in the Health sheet read as empty. Those metrics just stop updating, and earlier values stay.
