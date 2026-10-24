// A Fitbit export (Google Takeout → Fitbit), read in the browser (src/import/fitbit.ts) and sent here in chunks
// (POST /api/fitbit/import, server/fitbit.ts) as source 'fitbit'. Nothing else about the file leaves the device.

/** The daily metrics a Fitbit export can supply, with the units stored (weight in kg). */
export const FITBIT_METRICS = [
  'resting_hr',
  'hr_avg',
  'hr_min',
  'hr_max',
  'hrv_rmssd',
  'spo2',
  'resp_rate',
  'steps',
  'sleep_hours',
  'sleep_in_bed',
  'sleep_deep',
  'sleep_rem',
  'sleep_light',
  'sleep_awake',
  'sleep_efficiency',
  'weight',
  'body_fat',
] as const;

export type FitbitMetric = (typeof FITBIT_METRICS)[number];

export type FitbitSleepSegment = { start: string; end: string; stage: 'awake' | 'rem' | 'light' | 'deep' | 'asleep' };

/** One chunk: at most a few MB, split on whole days. */
export type FitbitChunk = {
  daily: { date: string; metric: FitbitMetric; value: number }[];
  /** Nights by wake date, each with its stages and the night's start and end (ISO with offset). */
  sleep?: { date: string; start: string; end: string; segments: FitbitSleepSegment[] }[];
};

/** POST /api/fitbit/import/finish. */
export type FitbitFinish = { days: number; firstDate: string | null; lastDate: string | null; metrics: string[] };
