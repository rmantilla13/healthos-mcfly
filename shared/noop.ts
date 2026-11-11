// A WHOOP strap read with NOOP's code (github.com/ryanbr/noop, an offline WHOOP companion), as source 'noop'. Two
// ways in (server/noop.ts):
// - the iPhone app reads the strap over Bluetooth itself, scores the days on the phone, and posts each sync to
//   POST /api/noop/ingest with the person's ingest token: a window of days that replaces the strap's rows in it.
// - NOOP's own Settings → Backup & restore → Export CSV zip (WHOOP's export layout plus a Source column), read in
//   the browser (src/import/noop.ts) and sent in chunks to POST /api/noop/import, which only adds and updates.
// Nothing else leaves the device.
//
// Most of NOOP's numbers are its own estimates, worked out on the phone from the strap's raw readings: its export marks
// them "noop (APPROXIMATE)". Rows it imported from a WHOOP export are marked "import". Both are stored as 'noop', which
// ranks just after the WHOOP connection (server/query.ts), so WHOOP's own numbers win any day both have.

/** The daily metrics a NOOP export can supply, in the units stored (sleep in hours, strain on WHOOP's 0–21 scale). */
export const NOOP_METRICS = [
  'recovery',
  'strain',
  'resting_hr',
  'hrv_rmssd',
  'spo2',
  'resp_rate',
  'whoop_kcal',
  'hr_avg',
  'hr_max',
  'sleep_hours',
  'sleep_in_bed',
  'sleep_deep',
  'sleep_rem',
  'sleep_light',
  'sleep_awake',
  'sleep_efficiency',
  'sleep_performance',
  'sleep_consistency',
] as const;

export type NoopMetric = (typeof NOOP_METRICS)[number];

/** The values a reading can take. The browser leaves out anything outside them and the server refuses a chunk with one. */
export const NOOP_RANGES: Record<NoopMetric, [number, number]> = {
  recovery: [0, 100],
  strain: [0, 21],
  resting_hr: [25, 150],
  hrv_rmssd: [1, 300],
  spo2: [70, 100],
  resp_rate: [4, 40],
  whoop_kcal: [0, 20_000],
  hr_avg: [25, 230],
  hr_max: [25, 230],
  sleep_hours: [0, 24],
  sleep_in_bed: [0, 24],
  sleep_deep: [0, 24],
  sleep_rem: [0, 24],
  sleep_light: [0, 24],
  sleep_awake: [0, 24],
  sleep_efficiency: [0, 100],
  sleep_performance: [0, 100],
  sleep_consistency: [0, 100],
};

export const inNoopRange = (metric: NoopMetric, value: number) => Number.isFinite(value) && value >= NOOP_RANGES[metric][0] && value <= NOOP_RANGES[metric][1];

/** The earliest date a reading can have: the first WHOOP strap shipped in 2015 (an imported WHOOP history can go back that far). */
export const NOOP_FIRST_DATE = '2015-01-01';

/** What one POST /api/noop/import may carry: under the server's 4 MB body limit, itself under Vercel's 4.5 MB. */
export const NOOP_CHUNK = { bytes: 3_500_000, rows: 80_000, nights: 1_500, workouts: 2_000, stagesPerNight: 1_000 } as const;

/** The most days one POST /api/noop/ingest may replace: a first sync sends its history window by window. */
export const NOOP_INGEST_MAX_DAYS = 31;

export const NOOP_STAGES = ['awake', 'rem', 'light', 'deep', 'asleep'] as const;
export type NoopStage = (typeof NOOP_STAGES)[number];

export type NoopDay = { date: string; metric: NoopMetric; value: number };
/**
 * A night by its wake date, with when it started and ended (local ISO with offset), and, from the strap itself, its
 * stages through the night (a NOOP export has only the totals).
 */
export type NoopNight = { date: string; start: string; end: string; segments?: { start: string; end: string; stage: NoopStage }[] };
export type NoopWorkout = {
  /** The local date it started on. */
  date: string;
  start: string;
  end: string;
  sport: string;
  energy_kcal: number | null;
  distance_m: number | null;
  avg_hr: number | null;
  max_hr: number | null;
  /** WHOOP's 0–21 scale. */
  strain: number | null;
};

export type NoopChunk = { daily: NoopDay[]; sleep?: NoopNight[]; workouts?: NoopWorkout[] };

/**
 * POST /api/noop/ingest: everything the phone scored for the local dates `from`..`to` (inclusive). The strap's rows in
 * that window are replaced by these, so a night NOOP rescored or a workout it renamed leaves no stale copy behind.
 * Every record's date must fall inside the window.
 */
export type NoopIngest = NoopChunk & { window: { from: string; to: string } };

/** POST /api/noop/import/finish. */
export type NoopFinish = { days: number; firstDate: string | null; lastDate: string | null; metrics: string[] };
