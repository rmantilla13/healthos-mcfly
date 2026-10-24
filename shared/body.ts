// Body measurements a person adds themselves (server/body.ts): weight, body fat and lean mass from a scale, a scan
// or their records. Stored in kg and %, and mirrored into `daily` as source 'manual' (the day's latest entry), so
// every chart, sheet and summary picks them up like a scale's reading.

export type BodyMetric = 'weight' | 'body_fat' | 'lean_mass';
export type BodyMethod = 'scale' | 'scan' | 'records' | 'other';

export const BODY_METRICS: { metric: BodyMetric; label: string; unit: 'kg' | '%'; min: number; max: number }[] = [
  { metric: 'weight', label: 'Weight', unit: 'kg', min: 20, max: 400 },
  { metric: 'body_fat', label: 'Body fat', unit: '%', min: 2, max: 75 },
  { metric: 'lean_mass', label: 'Lean body mass', unit: 'kg', min: 10, max: 250 },
];

export const BODY_METHODS: { method: BodyMethod; label: string }[] = [
  { method: 'scale', label: 'Scale' },
  { method: 'scan', label: 'Scan' },
  { method: 'records', label: 'Records' },
];

export type BodyEntry = {
  id: string;
  metric: BodyMetric;
  /** kg for weight and lean mass, % for body fat. */
  value: number;
  date: string;
  /** HH:MM, or null when not given. */
  time: string | null;
  method: BodyMethod;
  note: string;
  createdAt: number;
};

/** GET /api/body/entries?metric=&days=: newest first. */
export type BodyEntries = { entries: BodyEntry[] };

/** POST /api/body/entries. unit 'lb' is converted to kg on the server; weight and lean mass default to kg. */
export type BodyEntryInput = { metric: BodyMetric; value: number; unit?: 'kg' | 'lb' | '%'; date: string; time?: string | null; method?: BodyMethod; note?: string };

export const LB_PER_KG = 1 / 0.45359237;

/** Where a day's value came from: typed in by the person, a device, a Fitbit export, or the local demo. */
export type BodySource = 'manual' | 'apple' | 'whoop' | 'fitbit' | 'demo';

/**
 * GET /api/body/latest?date=: each metric's latest value in the 120 days to `date` (today by default), as the charts
 * show it (a typed entry wins its day), and where it came from; null when there's none in that window.
 */
export type BodyLatest = Record<BodyMetric, { date: string; value: number; source: BodySource } | null>;
