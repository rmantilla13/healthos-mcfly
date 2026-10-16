# healthOS Sync (iOS)

A small SwiftUI app that reads Apple Health on your iPhone and pushes it to the healthOS server on your Mac. It replaces the manual `export.zip` import.

## What it does

- **Reads** steps, active energy, exercise minutes, walking + running distance, heart rate, resting HR, HRV (SDNN), blood oxygen, respiratory rate, sleeping wrist temperature, body temperature, weight, body fat, lean mass, VO₂ max, sleep stages, mindful sessions and workouts.
- **Finds what changed** with one HealthKit anchored query per type. Only the local days touched by new samples are re-read.
- **Aggregates on the phone** into the same per-day rows as `server/apple/import.ts`:
  - Sum metrics keep the best single source per day.
  - Sleep counts toward the wake day (6 h rollover). Overlapping segments are merged, and the source with the most sleep wins.
  - Days use each record's own time zone (`HKMetadataKeyTimeZone`, or the device's).
- **Uploads** a week of days per request to `POST /api/apple/ingest` with the bearer token. A day whose upload fails stays queued for the next sync.
- **Syncs in the background:** an `HKObserverQuery` per type plus `enableBackgroundDelivery`. iOS decides the cadence (at most hourly for steps), and Health data can't be read while the phone is locked.

Workouts and mindful sessions are keyed by their HealthKit UUID. If an earlier `export.zip` import holds the same one (same start instant and type), the server replaces the imported copy, so nothing is duplicated.

## Server setup

The app pushes to `https://health.mcfly.bot/api/apple/ingest` by default. Set the shared secret on the server, as a Vercel environment variable or in `.env` locally:

```bash
HEALTHOS_INGEST_TOKEN=paste-the-output-of-openssl-rand-hex-24
```

Without it, the endpoint answers 503 and accepts nothing.

## Install on your iPhone

Needs iOS 17 or later. Built and tested with Xcode 27.

1. Open `ios/HealthOSSync.xcodeproj`.
2. Under **Signing & Capabilities**, pick your team. The bundle identifier is `health.mcfly.sync`.
3. Run on your phone.
4. In the app, paste the token, then tap **Test connection**. The server address is already filled in.
5. Tap **Sync now**. When the Health sheet asks how much history to share, pick **All Recorded Data** if you want a full backfill. The **First upload covers** setting can limit it further.
6. For background sync, leave **Background App Refresh** on for the app (Settings → General).

### Syncing to a Mac instead

To keep data on your Mac, run the server there with `HEALTHOS_LAN=1` as well as the token. It logs a LAN address such as `http://192.168.1.20:8788`, which you enter in the app instead. That port serves only the ingest endpoint. The phone must be on the same network, and iOS asks once for Local Network access.

## Simulator

The simulator shares the Mac's network, so `http://localhost:8787` (the default there) reaches the normal localhost-only server. You still need `HEALTHOS_INGEST_TOKEN` in `.env`.

The simulator has an extra **Add sample Health data** button. It writes two weeks of plausible data into the simulator's Health store, so the whole flow can be tried without a phone. Device builds never ask for write access.

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
