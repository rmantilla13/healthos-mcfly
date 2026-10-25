# healthOS for iPhone

The healthOS dashboard as a native SwiftUI app. It also sends your iPhone's Apple Health data to the server automatically, so you don't need the manual `export.zip` import.

## Dashboard

The app reads the same API as the website (`/api/summary`, `/api/trends`, `/api/workouts`, `/api/status`). It shows the same numbers, including WHOOP recovery and strain, which only the server has.

- **Today:**
  - the greeting, then your profile photo as an organic portrait: it reveals through a short ASCII sweep once per launch (skipped with Reduce Motion), with heart, breathing and temperature dots, leader-line callouts, and Slept, Steps and HRV shapes around it;
  - four cards: recovery or VO₂ max, blood oxygen, HRV and sleep;
  - optional cards, off until you turn them on in Settings → Cards, as on the web: the day's path (and with it the portrait's heart following its marker), the "week so far" summary, recent insights, strain or active energy, and steps against your goal.
  - Arrows step through past days. Pull down to refresh, which also pushes any new Health data.
  - **Ask McFly:** a pill above the tab bar opens a chat with the dashboard's assistant (`/api/mcfly`, streamed from `/api/mcfly/chat`). The conversation stays in memory only. It shows how many questions are left today, and the pill is hidden when the server has McFly off.
- **Trends:** Vitals, Sleep (stacked stages; sleep performance from WHOOP and sleep efficiency are separate cards, each hidden on its own), Activity (steps against goal, plus workouts) and Body, over 30 days, 90 days or a year. Drag across a chart to read a single day.
- **Nutrition** (only while Nutrition is on): the web's Neka layout from `GET /api/nutrition`.
  - **Overview:** Energy (only when calories are shown), Protein with a neutral week-on-week note, Water in glasses, Days logged, a macro balance donut with fiber, sugar, sodium and caffeine, and food insights worded as associations.
  - **Macros and Hydration:** a bar per logged day over 7, 30 or 90 days. With "No amounts", only the Overview and the Log show, and only which days were logged.
  - **Log** (only on servers with the food log, `GET /api/nutrition/log`): the same log as the web's Log tab, one day at a time. Tap an entry to change its name or portions, swipe to delete it. Entries from the web show here and the other way round.
    - **Water in one tap:** a glass or a bottle (250 or 500 mL, or 8 or 16.9 fl oz), at the sheet's time. Not shown with "No amounts".
    - **Add food or drink:** search USDA and Open Food Facts, scan a barcode (or type its number), ask McFly to estimate a photo or a description (only when the server has McFly on; you review its drafts before they're saved, and saving or discarding touches only that estimate), or quick add your own amounts. Quick add types only what your "numbers" setting shows: no Calories with "No calories", no Quick add with "No amounts".
    - **Photos** are shrunk on the phone to 1,280 px on the long edge and re-encoded, which drops the location and other metadata, and are sent only for that estimate.
    - **Saved to Apple Health:** see Apple Health sync below.
  - **No judgement:** a day with nothing logged is a gap, never a zero. A target you set (Settings → Nutrition targets) is a plain dashed line. No score, no "remaining", no red or green.
- **Cycle** (only while cycle tracking is on): this cycle's phase ring and estimates, each fertile day's estimated chance, the temperature curve for any cycle (cover line, ovulation, the rise after it), a five-week calendar, past cycles split before and after ovulation, and patterns from your own cycles. Estimates never mark a day as safe.
- **Settings:**
  - server address and sign-in status;
  - the profile photo: **Change photo** picks one from Photos and cuts it out on the phone with Apple Vision, using the same steps as the Mac tool `server/photo/cutout.swift`. After a Save/Cancel preview it uploads to `POST /api/profile/photo/upload`;
  - **Cards:** the web's card switches, one list for both. Optional cards are marked and stay off until turned on (the server's `shownCards`). **Show all** brings back every card you hid and leaves the optional ones as they are. A server older than optional cards sends no `shownCards`: there every card shows unless it's hidden, Settings offers only the 33 cards that server knows (its sleep score hides sleep efficiency too), and Show all clears the whole list;
  - the Apple Health sync controls.

Cards hide or switch to fit your sources, as on the web: no WHOOP means VO₂ max instead of recovery, active energy instead of strain, and HRV labelled SDNN.

**Sign-in:** the same account as the website. On servers with per-person accounts the app asks for email and password; older single-user servers need only the password. The app works with either.
- **Invites:** someone invited taps **Have an invite code?** and enters the code, or pastes the whole invite link. They pick a name, email and password, and land on their own dashboard. No email is ever sent.
- **Session:** the 30-day session cookie lives in the Keychain.
- **Local servers:** one with no password set needs no sign-in.
- **Time zone:** after each status read, if the server's `settings.timeZone` isn't this iPhone's, the app sends it (`PUT /api/settings {timeZone}`), as the web does, so the hosted server's "today" is yours. A zone is sent once per session: a server that keeps its own isn't asked again, and one that couldn't be reached is asked on the next read.
- **Signing out pauses the Apple Health sync.** The ingest token belongs to one account, whoever is signed in, so the app remembers which account it was set under (or, for a token from an older build, the first account seen signed in). After a sign-out nothing is read or sent, in the app or in the background, until someone signs in. The same account resumes the sync. Anyone else signing in, or a new account from an invite, removes the token and Settings asks to set this iPhone up again in Integrations, so a phone that changes hands never sends the new person's data to the last account. The next token starts the upload from the beginning. Servers without sign-in work as before.
- **Errors:** when the server refuses something with a message written for people (400, 403, 409 or 429), the app shows that message as it is, as the web does; otherwise it says "Server answered" with the code.
- **Offline:** the last summary is cached on the phone, so the app opens with numbers even offline.
- **Fresh data without re-downloading:** the app checks `GET /api/version` on open, on return, after syncs and every minute while open. It downloads the summary and trends again only when the version changed or the day rolled over, or on pull to refresh. Servers without `/api/version` get a reload on open, on return and after syncs.

## Apple Health sync

- **Reads** steps, active energy, exercise minutes, walking + running distance, heart rate, resting HR, HRV (SDNN), blood oxygen, respiratory rate, sleeping wrist temperature, body temperature, weight, body fat, lean mass, VO₂ max, sleep stages, mindful sessions and workouts.
- **Finds what changed** with one HealthKit anchored query per type. Only the local days touched by new samples are re-read.
- **Aggregates on the phone** into the same per-day rows as `server/apple/import.ts`:
  - Sum metrics keep the best single source per day.
  - Steps WHOOP writes into Health compete too (iPhone, Watch or WHOOP; the highest total wins, never the sum), and the hours follow the winner. WHOOP's other records stay skipped, because healthOS reads WHOOP's API.
  - Sleep counts toward the wake day (6 h rollover). Overlapping segments are merged, and the source with the most sleep wins.
  - Each night's stages also go up as a timeline (`sleepStages`) for the Sleep page: one stage at a time, the main sleep only (a same-day nap counts in the totals but isn't drawn), from the source that won the night. A night with no sleep is sent empty, which clears it, but only when the window had any sleep at all, so a phone without sleep access never erases nights from an export import. The first sync with a server that stores stages sends the last month again once, so recent nights have them; older nights get theirs with "Upload all history".
  - Days use each record's own time zone (`HKMetadataKeyTimeZone`, or the device's).
- **Uploads** a week of days per request to `POST /api/apple/ingest` with the bearer token, newest week first. A day whose upload fails stays queued for the next sync. Nothing goes up while signed out (see Sign-in above).
  - Every sync sends today, plus any changed day in the last 30.
  - Older days (the first upload, or the one-time hourly backfill) wait in a saved queue. They go up newest first, four weeks per pass, only while the app is open and not in Low Power Mode. Settings shows how many are left.
- **Cycle tracking:** menstrual flow, spotting, ovulation tests, cervical mucus, sexual activity, basal body temperature and Health's cycle symptoms (cramps, bloating, headache and the rest; one logged as "not present" is left out). The app reads these only after you turn cycle tracking on in healthOS settings and the server answers that it stores cycle days. Each day sent replaces that day on the server.
- **Nutrition** (food totals from the apps you log meals in): energy, protein, carbs, fat, fiber, sugar, saturated fat, sodium and alcoholic drinks.
  - **Off by default.** The app reads, asks Health about and watches these types only while the server's ingest reply says you turned Nutrition on (`nutritionOn`) and lists the nutrients it takes (`nutrients`). Off, it reads none of them.
  - **Turning it on:** the sync that hears it asks Health about the food types and then reads their whole history. Turning it off forgets where reading stopped, so turning it on again sends the history again.
  - **Per app, never summed:** each day goes up as each app's own totals, and the server shows one app a day, because apps copy each other's logs through Health. A meal saved as a Food correlation counts once. Each day sent replaces that day.
  - **Deletions:** a food sample deleted in Health re-sends the last month, and a day left with no food goes up as `apps: []`, which clears it. An empty day is never sent otherwise: Health reads as empty when food access is off.
  - **Late writes:** food apps often write late, so the last three days are read again on every sync. Food energy alone wakes the app in the background.
  - **Values the server would refuse stay on the phone:** a total above its cap (a unit mix-up) is left out, so one bad log can't block a sync. Caffeine and water stay daily metrics, as before.
- **Food logged on this iPhone is written to Health** (`FoodHealth.swift`), so other apps see it. Only saved entries made here are written, never ones from the web or McFly drafts still waiting for review.
  - **One Food correlation per entry** (water included), plus a separate alcoholic-drinks sample, which a correlation can't hold. Every object carries `HKMetadataKeyFoodType`, `HKMetadataKeySyncIdentifier` `healthos.food.<entry id>` and `HKMetadataKeySyncVersion`, so a changed entry replaces its copy, and `HealthOSFoodLogEntry` = the entry id, which queries can leave out.
  - **Only the amounts you see:** with "No calories" no energy is written; with "No amounts" nothing is, and copies already written are removed.
  - **Asked once, when you save your first entry** (after the Add sheet closes), not at launch. From then on every Health request includes the food write types: on iOS 27 a request that leaves them out resets them.
  - **Reconciled** when Nutrition opens and after each sync, against the last 7 days of the log: changed entries are rewritten, deleted ones (here or on the web) removed. `food-health.json` in Application Support remembers what was written.
  - **Never counted twice:** the server already has the log itself. The water, caffeine and food queries leave out `HealthOSFoodLogEntry` with a NOT predicate, and adding up skips anything marked as ours again (key or `healthos.food.` sync identifier). Our own rewrites and removals don't count as changes either, so an edit never re-sends or clears a month of food.
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
3. In **Settings**, paste your ingest token, then tap **Test connection**. Each person gets their own on the dashboard under Integrations → Apple Watch / Health → Set up the iPhone app; the owner can also use the `HEALTHOS_INGEST_TOKEN` value set on Vercel.
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

Simulator builds have an extra **Add sample Health data** button. It writes two weeks of plausible data into the simulator's Health store, so the whole flow can be tried without a phone. Device builds ask for write access only for the food you log in the app. The live barcode scanner needs a real camera, so in the simulator type the barcode's number instead.

**Point the simulator only at a scratch server.** Whatever is in its Health store is uploaded as real Apple Health data. Never use the hosted site. Avoid `localhost:8787` too: with `DATABASE_URL` in `.env.local`, that server writes to the hosted database. Simulator builds start with no server address for this reason. The simulator shares the Mac's network, so a scratch server on the Mac is reachable at localhost:

```bash
env -u DATABASE_URL HEALTHOS_DATA_DIR=/tmp/healthos-scratch PORT=8790 HEALTHOS_INGEST_TOKEN=any-test-token-16chars node server/index.ts
```

Then enter `http://localhost:8790` and that token in the app's Settings.

Build and test from the terminal:

```bash
xcodebuild -project ios/HealthOSSync.xcodeproj -scheme HealthOSSync -destination 'platform=iOS Simulator,name=iPhone 18 Pro' test
```

For scripted runs, `xcrun simctl launch booted health.mcfly.sync -healthosToken <token>` sets the token (simulator builds only).

## Project file

`HealthOSSync.xcodeproj` is generated from `project.yml`. After adding files or changing settings, run `xcodegen generate` (`brew install xcodegen`).

## Known limits

- Deleted workouts and mindful sessions are removed on the server too. For other deleted samples, the app re-checks the last 30 days of daily values; for older edits, use **Upload all history again**.
- If every sample of a metric on a day is deleted, the server keeps the old value: a sync only adds and updates.
- Types you don't allow in the Health sheet read as empty. Those metrics just stop updating, and earlier values stay.
