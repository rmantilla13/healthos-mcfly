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
  | 'heart_rate'
  | 'sleep_performance'
  | 'sleep_efficiency';

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
  /** The sheet's "What this means": one plain sentence, what to keep in mind, and a reputable explainer to read on. */
  about: MetricAbout;
};

export type MetricAbout = { what: string; caveat: string; source: { label: string; href: string } };

const ALL: MetricRange[] = ['week', 'month', 'year'];
const WITH_DAY: MetricRange[] = ['day', 'week', 'month', 'year'];

// The explainers' links were each opened and checked to be about the metric (October 2026). Recovery, strain and sleep
// performance are WHOOP's own scores, so WHOOP's pages explain them best.
const CLEVELAND_HR = { label: 'Cleveland Clinic · Heart rate', href: 'https://my.clevelandclinic.org/health/diagnostics/heart-rate' };
const MUSCLE_FAT = { label: 'Cleveland Clinic · Muscle weight vs. fat weight', href: 'https://health.clevelandclinic.org/muscle-vs-fat-weight' };
const WEARABLE = 'A wearable reading is a signal to put in context, not a diagnosis.';
const SCORE = 'A score is a signal to put in context, not a diagnosis.';

export const METRIC_INFO: Record<MetricKey, MetricInfo> = {
  resting_hr: {
    label: 'Resting heart rate',
    unit: 'bpm',
    digits: 0,
    chart: 'trend',
    ranges: ALL,
    initial: 'month',
    about: {
      what: "How many times a minute your heart beats while you're fully at rest. WHOOP reads it as you sleep; Apple Watch and Fitbit also use still moments in the day.",
      caveat: `${WEARABLE} Illness, alcohol, heat, stress and a hard day's training can all raise it for a while.`,
      source: CLEVELAND_HR,
    },
  },
  hrv: {
    label: 'Heart rate variability',
    unit: 'ms',
    digits: 0,
    chart: 'trend',
    ranges: ALL,
    initial: 'month',
    about: {
      what: "How much the time between your heartbeats varies, a sign of how your body is balancing stress and rest. It's personal: compare it with your own usual.",
      caveat: `${WEARABLE} WHOOP and Fitbit measure RMSSD as you sleep and Apple Watch measures SDNN, so the two don't compare.`,
      source: { label: 'Cleveland Clinic · Heart rate variability', href: 'https://my.clevelandclinic.org/health/symptoms/21773-heart-rate-variability-hrv' },
    },
  },
  sleep_hours: {
    label: 'Sleep',
    unit: 'h',
    digits: 1,
    duration: true,
    chart: 'trend',
    ranges: ALL,
    initial: 'week',
    about: {
      what: 'The time you spent asleep, not just in bed. Most adults need between 7 and 9 hours a night.',
      caveat: `${WEARABLE} A device estimates sleep from movement and heart rate, so short wakings are its best guess.`,
      source: { label: 'NHLBI · How much sleep is enough?', href: 'https://www.nhlbi.nih.gov/health/sleep/how-much-sleep' },
    },
  },
  recovery: {
    label: 'Recovery',
    unit: '%',
    digits: 0,
    chart: 'trend',
    ranges: ALL,
    initial: 'month',
    about: {
      what: "WHOOP's daily score, 0 to 100%, of how ready your body is to take on strain, mostly from your heart rate variability, resting heart rate and sleep.",
      caveat: `${SCORE} It's WHOOP's own measure, judged against your own baseline.`,
      source: { label: 'WHOOP · How does WHOOP Recovery work?', href: 'https://www.whoop.com/us/en/thelocker/how-does-whoop-recovery-work-101/' },
    },
  },
  strain: {
    label: 'Day strain',
    unit: '',
    digits: 1,
    chart: 'bars',
    ranges: ALL,
    initial: 'week',
    about: {
      what: "WHOOP's measure, from 0 to 21, of the load on your heart and muscles over a day. Each point takes more effort than the last.",
      caveat: `${SCORE} Stress or illness that keeps your heart rate up counts toward it too.`,
      source: { label: 'WHOOP · How does WHOOP Strain work?', href: 'https://www.whoop.com/us/en/thelocker/how-does-whoop-strain-work-101/' },
    },
  },
  steps: {
    label: 'Steps',
    unit: 'steps',
    digits: 0,
    chart: 'bars',
    ranges: WITH_DAY,
    initial: 'week',
    about: {
      what: 'The steps you took in a day. In large studies, more steps a day went with better long-term health, more than how fast they were taken.',
      caveat: 'A count is a signal to put in context, not a diagnosis. A phone left on a desk misses steps, and cycling or swimming barely counts.',
      source: { label: 'NIH · Number of steps per day more important than step intensity', href: 'https://www.nih.gov/news-events/nih-research-matters/number-steps-day-more-important-step-intensity' },
    },
  },
  active_energy: {
    label: 'Active energy',
    unit: 'kcal',
    digits: 0,
    chart: 'bars',
    ranges: WITH_DAY,
    initial: 'week',
    about: {
      what: "The calories you burned by moving, on top of what your body uses at rest. It's what Apple Watch's Move ring counts.",
      caveat: 'An estimate from movement and heart rate, so a signal to put in context rather than an exact count. Without a watch, your iPhone estimates it from your steps.',
      source: { label: 'Apple · Track daily activity with Apple Watch', href: 'https://support.apple.com/guide/watch/track-daily-activity-apd3bf6d85a6/watchos' },
    },
  },
  spo2: {
    label: 'Blood oxygen',
    unit: '%',
    digits: 1,
    chart: 'trend',
    ranges: ALL,
    initial: 'month',
    about: {
      what: 'An estimate of the percentage of oxygen-saturated haemoglobin in your blood.',
      caveat: `${WEARABLE} Sensor fit and measurement conditions matter.`,
      source: { label: 'Cleveland Clinic · Blood oxygen level', href: 'https://my.clevelandclinic.org/health/diagnostics/22447-blood-oxygen-level' },
    },
  },
  resp_rate: {
    label: 'Respiratory rate',
    unit: 'breaths/min',
    digits: 1,
    chart: 'trend',
    ranges: ALL,
    initial: 'month',
    about: {
      what: 'How many breaths you take a minute, measured as you sleep. Most adults breathe 12 to 18 times a minute at rest.',
      caveat: `${WEARABLE} A rise above your own usual often comes with illness, heat or a hard day.`,
      source: { label: 'Cleveland Clinic · Vital signs', href: 'https://my.clevelandclinic.org/health/articles/10881-vital-signs' },
    },
  },
  glucose: {
    label: 'Glucose',
    unit: 'mg/dL',
    digits: 0,
    chart: 'trend',
    ranges: ALL,
    initial: 'month',
    about: {
      what: "The sugar in your blood, from a continuous glucose monitor or a meter. Each day here is the average of that day's readings.",
      caveat: "A day's average hides its highs and lows, so it's a signal to put in context, not a diagnosis. Your clinician can tell you your own targets.",
      source: { label: 'NIDDK · Continuous glucose monitoring', href: 'https://www.niddk.nih.gov/health-information/diabetes/overview/managing-diabetes/continuous-glucose-monitoring' },
    },
  },
  weight: {
    label: 'Weight',
    unit: 'kg',
    digits: 1,
    chart: 'trend',
    ranges: ALL,
    initial: 'month',
    about: {
      what: 'Your body weight. It moves from day to day with water, food and salt, so the trend over weeks says more than one weigh-in.',
      caveat: 'A signal to put in context, not a diagnosis. Weigh at the same time of day on the same scale, so readings compare.',
      source: { label: 'NHS · Healthy weight', href: 'https://www.nhs.uk/live-well/healthy-weight/' },
    },
  },
  body_fat: {
    label: 'Body fat',
    unit: '%',
    digits: 1,
    chart: 'trend',
    ranges: ALL,
    initial: 'month',
    about: {
      what: "The share of your weight that's fat. A smart scale estimates it by sending a small electrical current through your body.",
      caveat: "An estimate that can be several points off and moves with how much water you carry, so it's a signal to put in context, not a diagnosis.",
      source: MUSCLE_FAT,
    },
  },
  lean_mass: {
    label: 'Lean body mass',
    unit: 'kg',
    digits: 1,
    chart: 'trend',
    ranges: ALL,
    initial: 'month',
    about: {
      what: "Everything in your body that isn't fat: muscle, bone, organs and water. A smart scale estimates it from your weight and body fat.",
      caveat: "An estimate that moves with how much water you carry, so it's a signal to put in context, not a diagnosis.",
      source: MUSCLE_FAT,
    },
  },
  vo2max: {
    label: 'Cardio fitness (VO₂ max)',
    unit: 'mL/kg·min',
    digits: 1,
    chart: 'trend',
    ranges: ALL,
    initial: 'month',
    about: {
      what: 'The most oxygen your body can use in hard exercise, a measure of cardio fitness. Apple Watch estimates it from outdoor walks, runs and hikes.',
      caveat: 'An estimate, not a lab test, so a signal to put in context rather than a diagnosis. Medicines that limit your heart rate can make it read high.',
      source: { label: 'Apple · Track your cardio fitness levels', href: 'https://support.apple.com/en-us/108790' },
    },
  },
  heart_rate: {
    label: 'Heart rate',
    unit: 'bpm',
    digits: 0,
    chart: 'trend',
    ranges: ['day'],
    initial: 'day',
    about: {
      what: "Your heart rate through the day: each hour is the average of that hour's readings, with its lowest and highest.",
      caveat: `${WEARABLE} Exercise, caffeine, stress and heat all raise it for a while.`,
      source: CLEVELAND_HR,
    },
  },
  sleep_performance: {
    label: 'Sleep performance',
    unit: '%',
    digits: 0,
    chart: 'trend',
    ranges: ALL,
    initial: 'month',
    about: {
      what: "WHOOP's score for a night, 0 to 100%: how much of the sleep you needed you got, and in its newer version how consistent, efficient and calm that sleep was.",
      caveat: `${SCORE} It's WHOOP's own measure, and its formula has changed over time.`,
      source: { label: 'WHOOP · WHOOP Sleep', href: 'https://support.whoop.com/s/article/WHOOP-Sleep?language=en_US' },
    },
  },
  sleep_efficiency: {
    label: 'Sleep efficiency',
    unit: '%',
    digits: 0,
    chart: 'trend',
    ranges: ALL,
    initial: 'month',
    about: {
      what: 'The share of your time in bed that you spent asleep. A slow start to the night or long wakings lower it.',
      caveat: `${WEARABLE} A device estimates when you're asleep, and reading in bed counts as time awake.`,
      source: { label: 'WHOOP · Sleep efficiency', href: 'https://www.whoop.com/us/en/thelocker/app-feature-improve-sleep-efficiency/' },
    },
  },
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
  /**
   * Whether this person has ever had a reading of it, on any day and from any of their sources: false is "No
   * measurement yet", with no ranges to try. Missing from older servers.
   */
  everMeasured?: boolean;
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
 * says why it's empty), a window with data, one that's already the longest, or a metric never measured at all
 * (no range has anything, and the sheet says so at once).
 */
export function widerRange(sheet: Pick<MetricSheet, 'range' | 'ranges' | 'headline' | 'points' | 'everMeasured'>): MetricRange | null {
  // A point without a headline is today's unfinished total, which is drawn but not counted: not an empty window.
  if (sheet.everMeasured === false || sheet.range === 'day' || sheet.headline.value !== null || sheet.points.length) return null;
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

/**
 * Whether the window a sheet opened on is still empty, as the longer range it moved to shows it: no latest reading,
 * or one from before that window's first day. A reading synced since the move makes the note above untrue.
 */
export function stillEmpty(from: MetricRange, sheet: Pick<MetricSheet, 'to' | 'latest'>): boolean {
  if (!sheet.latest) return true;
  const days = from === 'day' ? 1 : RANGE_DAYS[from];
  return Date.parse(`${sheet.latest.date}T00:00:00Z`) < Date.parse(`${sheet.to}T00:00:00Z`) - (days - 1) * 86_400_000;
}

/**
 * Whether a sheet has nothing to show for its window: no average, and no unfinished total for today either. Today's
 * total so far is drawn and given as the latest, though not counted, so a window holding only it isn't called empty.
 */
export function nothingToShow(sheet: Pick<MetricSheet, 'headline' | 'partialToday'>): boolean {
  return sheet.headline.value === null && !sheet.partialToday;
}

/**
 * Whether the sheet on hand is shown while `range` is the one asked for. Not one that's about to move to a longer
 * range by itself, nor, while the range asked for loads, another range's empty one: either would flash "Nothing in
 * the last 30 days" on the way to a range that has something.
 */
export function showSheet(sheet: Pick<MetricSheet, 'range' | 'ranges' | 'headline' | 'points' | 'partialToday' | 'everMeasured'>, range: MetricRange, picked: boolean): boolean {
  return sheet.range === range ? picked || !widerRange(sheet) : !nothingToShow(sheet);
}
