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

/** GET /api/peers. */
export type PeerData =
  | { participating: false; reason: 'off' | 'no_age' | 'under_age' | 'no_accounts' }
  | { participating: true; ageBand: string; window: { from: string; to: string }; metrics: PeerMetric[]; demo?: true };
