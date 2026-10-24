// Anonymous peer comparisons (server/peers.ts): where your 30-day average sits among people your age who also
// take part, for the same measurement from the same source. Only aggregates ever leave the server, and only for a
// group of at least PEER_MIN_OTHERS other people, each with PEER_MIN_DAYS recorded days.

export const PEER_MIN_OTHERS = 20;
export const PEER_MIN_DAYS = 7;
export const PEER_WINDOW_DAYS = 30;
/** Comparisons are for adults: under 18, taking part can't be turned on. */
export const PEER_MIN_AGE = 18;

export const AGE_BANDS: { label: string; min: number; max: number }[] = [
  { label: '18–29', min: 18, max: 29 },
  { label: '30–39', min: 30, max: 39 },
  { label: '40–49', min: 40, max: 49 },
  { label: '50–59', min: 50, max: 59 },
  { label: '60–69', min: 60, max: 69 },
  { label: '70+', min: 70, max: 200 },
];

export const ageBand = (age: number | null | undefined) => (age == null ? null : (AGE_BANDS.find((b) => age >= b.min && age <= b.max)?.label ?? null));

/**
 * What can be compared: one measurement from one source, since devices measure differently (WHOOP's resting heart
 * rate is taken asleep, Apple's during the day; WHOOP's HRV is RMSSD, Apple's SDNN). digits is how a value is rounded
 * and shown, as on the metric sheets.
 */
export const PEER_PAIRS: { metric: string; source: string; label: string; unit: string; digits: number }[] = [
  { metric: 'resting_hr', source: 'whoop', label: 'Resting heart rate', unit: 'bpm', digits: 0 },
  { metric: 'resting_hr', source: 'apple', label: 'Resting heart rate', unit: 'bpm', digits: 0 },
  { metric: 'hrv_rmssd', source: 'whoop', label: 'Heart rate variability', unit: 'ms', digits: 0 },
  { metric: 'hrv_sdnn', source: 'apple', label: 'Heart rate variability', unit: 'ms', digits: 0 },
  { metric: 'sleep_hours', source: 'whoop', label: 'Sleep', unit: 'h', digits: 1 },
  { metric: 'sleep_hours', source: 'apple', label: 'Sleep', unit: 'h', digits: 1 },
  { metric: 'steps', source: 'apple', label: 'Steps', unit: 'steps', digits: 0 },
  { metric: 'spo2', source: 'whoop', label: 'Blood oxygen', unit: '%', digits: 1 },
  { metric: 'spo2', source: 'apple', label: 'Blood oxygen', unit: '%', digits: 1 },
  { metric: 'resp_rate', source: 'whoop', label: 'Respiratory rate', unit: 'breaths/min', digits: 1 },
  { metric: 'recovery', source: 'whoop', label: 'Recovery', unit: '%', digits: 0 },
];

/** A pair's label and unit; source 'demo' (the local preview's sample) uses the metric's first pair. */
export const peerPair = (metric: string, source: string) => PEER_PAIRS.find((p) => p.metric === metric && p.source === source) ?? PEER_PAIRS.find((p) => p.metric === metric);

export type PeerMetric = {
  metric: string;
  source: string;
  /** Your 30-day average and how many days it covers; null when you have none. */
  you: number | null;
  yourDays: number;
  status: 'ready' | 'gathering' | 'not_enough_days';
  /** 1–99: the share of the group below you. Only when ready. */
  percentile?: number;
  /** The group, rounded, as a size bucket: never ids, names or anyone's own value. Only when ready. */
  group?: { size: '20+' | '50+' | '100+'; median: number; p25: number; p75: number };
};

/**
 * GET /api/peers. Not participating: 'off' (the person hasn't ticked it), 'no_age' / 'under_age' (it needs an age of
 * 18 or over), 'no_accounts' (a local healthOS without sign-in: there's nobody else). demo: the local preview's
 * made-up group, never real people.
 */
export type PeerData =
  | { participating: false; reason: 'off' | 'no_age' | 'under_age' | 'no_accounts' }
  | { participating: true; ageBand: string; window: { from: string; to: string }; metrics: PeerMetric[]; demo?: true };
