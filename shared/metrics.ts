// Detail sheets (GET /api/metric/:key): one metric over a day, week, month or year, with three summary figures,
// how it compares with the period before, and one plain sentence about it. Shared by the server and the dashboard.
import type { DayData, Point } from './types.ts';

export type MetricKey =
  | 'resting_hr'
  | 'hrv'
  | 'sleep_hours'
  | 'recovery'
  | 'strain'
  | 'steps'
  | 'active_energy'
  | 'spo2'
  | 'resp_rate'
  | 'glucose'
  | 'weight'
  | 'body_fat'
  | 'lean_mass'
  | 'vo2max'
  | 'heart_rate';

export type MetricRange = 'day' | 'week' | 'month' | 'year';

/** Rolling windows ending on the day asked for: the last 7, 30 and 365 days. */
export const RANGE_DAYS: Record<Exclude<MetricRange, 'day'>, number> = { week: 7, month: 30, year: 365 };
export const RANGE_LABEL: Record<MetricRange, string> = { day: 'Day', week: 'Week', month: 'Month', year: 'Year' };
/** A range's window as the sheet says it. */
export const RANGE_WINDOW: Record<Exclude<MetricRange, 'day'>, string> = { week: 'the last 7 days', month: 'the last 30 days', year: 'the last 12 months' };

export type MetricInfo = {
  label: string;
  /** The stored unit. Mass is converted to the person's units (kg or lb) by the server. */
  unit: string;
  /** Decimal places a value is shown with. */
  digits: number;
  /** Hours shown as hours and minutes (sleep). */
  duration?: boolean;
  /** A line for readings (nightly, weekly), bars for a day's total. */
  chart: 'trend' | 'bars';
  /** In the order the sheet offers them. */
  ranges: MetricRange[];
  /** The range a sheet opens on. */
  initial: MetricRange;
};

const ALL: MetricRange[] = ['week', 'month', 'year'];
const WITH_DAY: MetricRange[] = ['day', 'week', 'month', 'year'];

export const METRIC_INFO: Record<MetricKey, MetricInfo> = {
  resting_hr: { label: 'Resting heart rate', unit: 'bpm', digits: 0, chart: 'trend', ranges: ALL, initial: 'month' },
  hrv: { label: 'Heart rate variability', unit: 'ms', digits: 0, chart: 'trend', ranges: ALL, initial: 'month' },
  sleep_hours: { label: 'Sleep', unit: 'h', digits: 1, duration: true, chart: 'trend', ranges: ALL, initial: 'week' },
  recovery: { label: 'Recovery', unit: '%', digits: 0, chart: 'trend', ranges: ALL, initial: 'month' },
  strain: { label: 'Day strain', unit: '', digits: 1, chart: 'bars', ranges: ALL, initial: 'week' },
  steps: { label: 'Steps', unit: 'steps', digits: 0, chart: 'bars', ranges: WITH_DAY, initial: 'week' },
  active_energy: { label: 'Active energy', unit: 'kcal', digits: 0, chart: 'bars', ranges: WITH_DAY, initial: 'week' },
  spo2: { label: 'Blood oxygen', unit: '%', digits: 1, chart: 'trend', ranges: ALL, initial: 'month' },
  resp_rate: { label: 'Respiratory rate', unit: 'breaths/min', digits: 1, chart: 'trend', ranges: ALL, initial: 'month' },
  glucose: { label: 'Glucose', unit: 'mg/dL', digits: 0, chart: 'trend', ranges: ALL, initial: 'month' },
  weight: { label: 'Weight', unit: 'kg', digits: 1, chart: 'trend', ranges: ALL, initial: 'month' },
  body_fat: { label: 'Body fat', unit: '%', digits: 1, chart: 'trend', ranges: ALL, initial: 'month' },
  lean_mass: { label: 'Lean body mass', unit: 'kg', digits: 1, chart: 'trend', ranges: ALL, initial: 'month' },
  vo2max: { label: 'Cardio fitness (VO₂ max)', unit: 'mL/kg·min', digits: 1, chart: 'trend', ranges: ALL, initial: 'month' },
  heart_rate: { label: 'Heart rate', unit: 'bpm', digits: 0, chart: 'trend', ranges: ['day'], initial: 'day' },
};

export const METRIC_KEYS = Object.keys(METRIC_INFO) as MetricKey[];
export const isMetricKey = (v: unknown): v is MetricKey => typeof v === 'string' && Object.hasOwn(METRIC_INFO, v);
export const isMetricRange = (v: unknown): v is MetricRange => v === 'day' || v === 'week' || v === 'month' || v === 'year';

/** Blood glucose: mg/dL per mmol/L (glucose's molar mass, 180.16 g/mol, over 10). */
export const MG_DL_PER_MMOL_L = 18.016;
export const mmolFromMgDl = (mgDl: number) => mgDl / MG_DL_PER_MMOL_L;

/** One figure on the sheet: a value with its unit, and what it is (its date, or a note such as "so far today"). */
export type MetricFigure = { label: string; value: number | null; unit: string; date?: string; note?: string };

/** Where the latest reading sits, in the words the dashboard's cards use for it. */
export type MetricStatus = { text: string; position: 'below' | 'within' | 'above' | 'at_or_above' | 'band' };

export type MetricChange = {
  /** The previous period's average (or, on a day, the typical day by the same hour). */
  previous: number;
  /** This period's average less the previous one, in `unit`. */
  delta: number;
  /** delta as a fraction of previous; null when previous is 0. */
  pct: number | null;
  /** What it's compared with, for the label: "the 30 days before", "your typical day by 2 PM". */
  against: string;
  from?: string;
  to?: string;
  /** Days with data in the previous period. */
  days?: number;
};

export type MetricSheet = {
  key: MetricKey;
  /** The stored metric behind the sheet (HRV: hrv_rmssd or hrv_sdnn); null for heart rate by the hour. */
  metric: string | null;
  label: string;
  /** In the person's units. */
  unit: string;
  digits: number;
  range: MetricRange;
  /** The ranges this metric has. */
  ranges: MetricRange[];
  /** The window shown, first and last day (the same day for a Day range). */
  from: string;
  to: string;
  today: string;
  /** What one chart point is: an hour (Day), a day (Week, Month), or a week's average of its days (Year). */
  resolution: 'hour' | 'day' | 'week';
  /** Daily values for Week and Month; weekly averages (each dated its Monday) for Year; empty for Day. */
  points: Point[];
  /** The Day range's hours, as GET /api/day gives them for this one metric. */
  day: DayData | null;
  /** Which devices the values in the window came from ('apple', 'whoop', 'demo'). */
  sources: string[];
  /** Days with a value in the window (today's unfinished total left out where it would be). */
  days: number;
  /** A daily total whose today isn't over: shown on the chart, left out of the figures. */
  partialToday: boolean;
  /** The big number: the window's average (or a day's total so far). */
  headline: MetricFigure;
  /** Three more figures: lowest day, highest day, latest (or, on a Day, their hourly counterparts). */
  tiles: MetricFigure[];
  change: MetricChange | null;
  /**
   * The latest reading as the card shows it, in the person's units: the one `status` is about when there's a status
   * (it may be older than the window), else the window's last value. Null on a Day range.
   */
  latest: Point | null;
  /** The status the dashboard's card shows for the latest reading, when it has one. */
  status: MetricStatus | null;
  /** Steps: the person's daily goal, for the chart's goal line. */
  goal: number | null;
  /** One plain sentence built from the figures above. */
  narrative: string | null;
};

/**
 * The reading nearest `days` before the latest one, within `slack` days either side; null without one.
 * For "change vs about 30 days earlier": a reading from three months before isn't "about a month".
 */
export function aboutBefore(points: Point[], days = 30, slack = 9): Point | null {
  const last = points.at(-1);
  if (!last) return null;
  const at = Date.parse(`${last.date}T00:00:00Z`) - days * 86_400_000;
  let best: Point | null = null;
  let bestGap = Infinity;
  for (const p of points) {
    const gap = Math.abs(Date.parse(`${p.date}T00:00:00Z`) - at) / 86_400_000;
    if (gap <= slack && gap < bestGap) {
      best = p;
      bestGap = gap;
    }
  }
  return best;
}

/**
 * The range a sheet moves to when the one it opened on has nothing in it: its longest. The card it was opened from
 * can show a reading older than a month (a weigh-in, a VO₂ max estimate, a meter's last glucose day; each card looks
 * back 120 days at most), and the sheet shouldn't then say there's nothing. Null to stay where it is: a Day (which
 * says why it's empty), a window with data, or one that's already the longest.
 */
export function widerRange(sheet: Pick<MetricSheet, 'range' | 'ranges' | 'headline' | 'points'>): MetricRange | null {
  // A point without a headline is today's unfinished total, which is drawn but not counted: not an empty window.
  if (sheet.range === 'day' || sheet.headline.value !== null || sheet.points.length) return null;
  const longest = sheet.ranges.at(-1);
  return longest && longest !== sheet.range ? longest : null;
}

/**
 * What an empty window says when a longer range may have something: "Nothing in the last 30 days. Year shows the
 * last 12 months." Null for a Day or the longest range, which say why there's nothing at all.
 */
export function emptyWindowText(sheet: Pick<MetricSheet, 'range' | 'ranges' | 'points'>): string | null {
  const longest = sheet.ranges.at(-1);
  if (sheet.range === 'day' || sheet.points.length || !longest || longest === 'day' || longest === sheet.range) return null;
  return `Nothing in ${RANGE_WINDOW[sheet.range]}. ${RANGE_LABEL[longest]} shows ${RANGE_WINDOW[longest]}.`;
}

/** The note a sheet shows when it moved to a longer range by itself: "Nothing in the last 30 days, so this shows the last 12 months." */
export function widenedNote(from: MetricRange, to: MetricRange): string | null {
  if (from === 'day' || to === 'day' || from === to) return null;
  return `Nothing in ${RANGE_WINDOW[from]}, so this shows ${RANGE_WINDOW[to]}.`;
}
