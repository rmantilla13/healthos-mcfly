// The values a Fitbit export reading can take, in the units stored (shared/fitbit.ts). The browser reader leaves out
// anything outside them (a strap read while off the wrist, a typo in a logged weight) and the server refuses a chunk
// that carries one, so the two agree on what counts as a reading.
import type { FitbitMetric } from './fitbit.ts';

export const FITBIT_RANGES: Record<FitbitMetric, [number, number]> = {
  resting_hr: [25, 150],
  hr_avg: [25, 230],
  hr_min: [25, 230],
  hr_max: [25, 230],
  hrv_rmssd: [1, 300],
  spo2: [70, 100],
  resp_rate: [4, 40],
  steps: [0, 150_000],
  sleep_hours: [0, 24],
  sleep_in_bed: [0, 24],
  sleep_deep: [0, 24],
  sleep_rem: [0, 24],
  sleep_light: [0, 24],
  sleep_awake: [0, 24],
  sleep_efficiency: [0, 100],
  weight: [20, 350],
  body_fat: [2, 75],
};

/** The earliest date a reading can have: Fitbit's first tracker shipped in 2009. */
export const FITBIT_FIRST_DATE = '2008-01-01';

/**
 * What one POST /api/fitbit/import may carry. The browser closes a chunk at whichever it reaches first, and at 3.5 MB:
 * the server's body limit is 4 MB, under Vercel's 4.5 MB.
 */
export const FITBIT_CHUNK = { bytes: 3_500_000, rows: 80_000, nights: 1_500, stagesPerNight: 1_000 } as const;

export const inFitbitRange = (metric: FitbitMetric, value: number) => Number.isFinite(value) && value >= FITBIT_RANGES[metric][0] && value <= FITBIT_RANGES[metric][1];
