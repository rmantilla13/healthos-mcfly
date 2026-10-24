// Anonymous peer comparisons (server/peers.ts): which quarter of a group of people your age who also take part your
// 30-day average sits in, for the same measurement from the same source. Only aggregates ever leave the server, and only
// for a group of at least PEER_MIN_OTHERS other people, each with PEER_MIN_DAYS recorded days.

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
  /** Which quarter of the group you sit in (PeerBand). Only when ready. */
  band?: PeerBand;
  /** The group, rounded, as a size bucket: never ids, names or anyone's own value. Only when ready. */
  group?: { size: '20+' | '50+' | '100+'; median: number; p25: number; p75: number };
};

/**
 * Where your average sits among the group's quarters, worked out only from the rounded figures in the same answer (your
 * `you` against the group's p25, median and p75), so it says nothing they don't. Equal to a quartile counts inside the
 * middle half, and at the median in its lower quarter, so each label stays true when quartiles round to the same value:
 * below p25 only when under it, above p75 only when over it.
 */
export type PeerBand = 'below_p25' | 'p25_median' | 'median_p75' | 'above_p75';

export const PEER_BANDS: PeerBand[] = ['below_p25', 'p25_median', 'median_p75', 'above_p75'];

export function peerBand(you: number, g: { p25: number; median: number; p75: number }): PeerBand {
  if (you < g.p25) return 'below_p25';
  if (you > g.p75) return 'above_p75';
  return you <= g.median ? 'p25_median' : 'median_p75';
}

/**
 * GET /api/peers. Not participating: 'off' (the person hasn't ticked it), 'no_age' / 'under_age' (it needs an age of
 * 18 or over), 'no_accounts' (a local healthOS without sign-in: there's nobody else). demo: the local preview's
 * made-up group, never real people.
 */
export type PeerData =
  | { participating: false; reason: 'off' | 'no_age' | 'under_age' | 'no_accounts' }
  | { participating: true; ageBand: string; window: { from: string; to: string }; metrics: PeerMetric[]; demo?: true };
