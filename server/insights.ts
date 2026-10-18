// Sleep timing (GET /api/sleep) and patterns (GET /api/patterns): when someone sleeps and how steady it is,
// and what tends to go together in their own history. Both read daily values, workouts and events only; the
// cycle table never reaches them. Pattern wording is correlational on purpose: it says what tends to come
// alongside what, never that one thing causes another.
import type { Pattern, Patterns, SleepNight, SleepTiming } from '../shared/types.ts';
import { addDays, zoneOffsets } from './dates.ts';
import { median } from './day.ts';
import type { Scope } from './db.ts';
import { type Ctx, latestDataDate, loadDaily, loadWorkouts, mean, mergeWorkouts, pickMetric, requestContext, sd, sourceList, valueOn } from './query.ts';

const HOUR_MS = 3_600_000;
const dayMs = (date: string) => Date.parse(`${date}T00:00:00Z`);
const round = (v: number, places = 0) => Math.round(v * 10 ** places) / 10 ** places;
const isWeekend = (date: string) => [0, 6].includes(new Date(dayMs(date)).getUTCDay());

/**
 * Wall-clock time of an ISO timestamp as milliseconds of a UTC date, read in the offset it was written with
 * ("2026-10-14T23:30:00-05:00" → 23:30 on the 14th). Every source stores a local offset: WHOOP and the iPhone
 * the one where they were, the export importer the person's zone at that instant (see AppleAggregator). A bare
 * UTC stamp falls back to the person's own time zone.
 */
function wallMs(iso: string, zone: ((ms: number) => number) | null) {
  if (iso.endsWith('Z') && zone) {
    const ms = Date.parse(iso);
    return ms + zone(ms) * 60_000;
  }
  return Date.parse(`${iso.slice(0, 19)}Z`);
}

const zoneOf = (timeZone: string | null) => (timeZone ? zoneOffsets(timeZone) : null);

// ---------- sleep timing ----------

/** The sleep need looks back this many nights, whatever window was asked for. */
const NEED_NIGHTS = 60;
const NEED_MIN_NIGHTS = 14;
const NEED_RANGE = [7, 9] as const;
const DEBT_DAYS = 7;
/** Nights needed before the spread of bed and wake times means anything. */
const SPREAD_MIN_NIGHTS = 7;
const MID_MIN_NIGHTS = 2;

/** Bed and wake times over the last `days` days to today, with how steady they are and the recent sleep debt. */
export async function sleepTiming(scope: Scope, hosted: boolean, days: number): Promise<SleepTiming> {
  const { settings, demo, today } = await requestContext(scope, hosted);
  const from = addDays(today, -(Math.max(days, NEED_NIGHTS) - 1));
  const [daily, events] = await Promise.all([
    loadDaily(scope, demo, from, today, ['sleep_hours']),
    scope.db.query<{ start: string; end: string; date: string }>(
      `SELECT start, "end", date FROM events WHERE user_id = $1 AND kind = 'sleep' AND date BETWEEN $2 AND $3 AND source = ANY($4)`,
      [scope.userId, from, today, sourceList(demo)],
    ),
  ]);
  const zone = zoneOf(settings.timeZone);

  // The main night per wake date: the longest sleep, whichever device recorded it.
  const longest = new Map<string, { start: string; end: string; ms: number }>();
  for (const e of events) {
    const ms = Date.parse(e.end) - Date.parse(e.start);
    if (!(ms > 0)) continue;
    const prev = longest.get(e.date);
    if (!prev || ms > prev.ms) longest.set(e.date, { start: e.start, end: e.end, ms });
  }
  const all = [...longest]
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([date, e]): SleepNight & { hours: number } => {
      // Minutes after 18:00 the evening before, so 23:30 and 00:30 sit next to each other.
      const bedMin = (wallMs(e.start, zone) - dayMs(addDays(date, -1))) / 60_000 - 18 * 60;
      return {
        date,
        bed: e.start,
        wake: e.end,
        bedMin: Math.round(bedMin),
        wakeMin: Math.round((wallMs(e.end, zone) - dayMs(date)) / 60_000),
        // From the real length, so a night the clocks change on still finds its middle.
        midMin: Math.round(bedMin + e.ms / 120_000),
        hours: round(valueOn({ daily, demo }, 'sleep_hours', date)?.value ?? e.ms / HOUR_MS, 2),
        weekend: isWeekend(date),
      };
    });

  const nights = all.filter((n) => n.date >= addDays(today, -(days - 1)));
  const midpoint = (weekend: boolean) => {
    const mids = nights.filter((n) => n.weekend === weekend).map((n) => n.midMin);
    return mids.length >= MID_MIN_NIGHTS ? mean(mids) : null;
  };
  const midWeekday = midpoint(false);
  const midWeekend = midpoint(true);
  const spread = (xs: number[]) => (xs.length >= SPREAD_MIN_NIGHTS ? sd(xs) : null);

  const recent = all.filter((n) => n.date >= addDays(today, -(NEED_NIGHTS - 1))).map((n) => n.hours);
  const need = recent.length >= NEED_MIN_NIGHTS ? Math.min(Math.max(median(recent)!, NEED_RANGE[0]), NEED_RANGE[1]) : null;
  const week = need === null ? [] : all.filter((n) => n.date >= addDays(today, -(DEBT_DAYS - 1)));
  const opt = (v: number | null, places = 0) => (v === null ? null : round(v, places));

  return {
    nights,
    stats: {
      nights: nights.length,
      avgBedMin: opt(mean(nights.map((n) => n.bedMin))),
      avgWakeMin: opt(mean(nights.map((n) => n.wakeMin))),
      bedSd: opt(spread(nights.map((n) => n.bedMin))),
      wakeSd: opt(spread(nights.map((n) => n.wakeMin))),
      midWeekday: opt(midWeekday),
      midWeekend: opt(midWeekend),
      socialJetlag: midWeekday !== null && midWeekend !== null ? round(midWeekend - midWeekday) : null,
      need: opt(need, 2),
      debt: need === null ? null : round(week.reduce((t, n) => t + Math.max(0, need - n.hours), 0), 2),
      debtNights: week.length,
    },
  };
}

// ---------- patterns ----------

/** Patterns look this far back from the latest data date. */
const WINDOW = 180;
const MIN_GROUP = 8;
/** A difference smaller than this share of the day-to-day spread is noise, however many days back it. */
const MIN_SD_SHARE = 0.3;
const MAX_PATTERNS = 6;
const PATTERN_METRICS = ['steps', 'sleep_hours', 'hrv_rmssd', 'hrv_sdnn', 'resting_hr', 'strain', 'recovery', 'caffeine_mg', 'daylight_min'];

/** Outcome values split by whether the day they follow met the condition (`yes`) or the comparison (`no`). */
type Split = { yes: number[]; no: number[] };

type Rule = Pick<Pattern, 'id' | 'page'> & {
  unit: 'min' | '%' | 'bpm' | 'points';
  split: Split;
  /** The smallest effect worth mentioning, in `unit`. */
  min: number;
  /** The effect in `unit` from the two groups' means. */
  effect: (yes: number, no: number) => number;
  places?: number;
  icon: (up: boolean) => Pattern['icon'];
  text: (size: number, up: boolean) => string;
  detail: (yes: number, no: number) => string;
};

/** A rule's pattern, or null when either group is too small or the difference too slight to mention. */
function judge(rule: Rule): (Pattern & { strength: number }) | null {
  const { yes, no } = rule.split;
  if (yes.length < MIN_GROUP || no.length < MIN_GROUP) return null;
  const [a, b] = [mean(yes)!, mean(no)!];
  const pooled = Math.sqrt(((yes.length - 1) * sd(yes)! ** 2 + (no.length - 1) * sd(no)! ** 2) / (yes.length + no.length - 2));
  const raw = rule.effect(a, b);
  if (Math.abs(raw) < rule.min || Math.abs(a - b) < MIN_SD_SHARE * pooled) return null;
  const effect = round(raw, rule.places ?? 0);
  const up = effect > 0;
  return {
    id: rule.id,
    icon: rule.icon(up),
    text: rule.text(Math.abs(effect), up),
    detail: `${rule.detail(yes.length, no.length)}, last ${WINDOW} days.`,
    n: Math.min(yes.length, no.length),
    effect,
    unit: rule.unit,
    page: rule.page,
    strength: pooled > 0 ? Math.abs(a - b) / pooled : Infinity,
  };
}

/**
 * Every pattern that holds over `start`..`end`, strongest first and not yet capped. Day d's condition is
 * compared with an outcome on d (sleep and resting heart rate the same morning) or d+1 (the night or morning after).
 */
export function findPatterns(ctx: Ctx, mindful: Set<string>, start: string, end: string): Pattern[] {
  // Resting heart rate comes from one device: WHOOP's sleeping measure runs ~7 bpm under the Watch's daytime
  // one, so mixing them would read a change of device as a change of heart rate. The device with the most
  // readings in the window is used.
  const ownSource = new Map<string, string>();
  for (const metric of ['resting_hr']) {
    let best: [string, number] | undefined;
    for (const [source, byDate] of ctx.daily.get(metric) ?? []) {
      let n = 0;
      for (const date of byDate.keys()) if (date >= start && date <= end) n++;
      if (!best || n > best[1]) best = [source, n];
    }
    if (best) ownSource.set(metric, best[0]);
  }
  const value = (metric: string, date: string) => {
    const source = ownSource.get(metric);
    return source ? ctx.daily.get(metric)?.get(source)?.get(date) : valueOn(ctx, metric, date)?.value;
  };
  const split = (group: (d: string) => boolean | null, outcome: string, lag: 0 | 1): Split => {
    const s: Split = { yes: [], no: [] };
    for (let d = start; d <= addDays(end, -lag); d = addDays(d, 1)) {
      const g = group(d);
      const y = g === null ? undefined : value(outcome, addDays(d, lag));
      if (y !== undefined) (g ? s.yes : s.no).push(y);
    }
    return s;
  };
  // Days whose `metric` meets `yes`, against days that meet `no`; days in neither (or without it) sit out.
  const by = (metric: string, yes: (x: number) => boolean, no: (x: number) => boolean) => (d: string) => {
    const x = value(metric, d);
    return x === undefined ? null : yes(x) ? true : no(x) ? false : null;
  };

  // Workout days: true when one ended at 20:00 or later (past midnight counts), false when all ended earlier.
  const zone = zoneOf(ctx.settings.timeZone);
  const lateWorkout = new Map<string, boolean>();
  for (const w of ctx.workouts) {
    const late = wallMs(w.end, zone) - dayMs(w.date) >= 20 * HOUR_MS;
    lateWorkout.set(w.date, (lateWorkout.get(w.date) ?? false) || late);
  }

  const hrv = pickMetric(ctx, ['hrv_rmssd', 'hrv_sdnn'], end).metric;
  const minutes = (a: number, b: number) => (a - b) * 60;
  const percent = (a: number, b: number) => (a / b - 1) * 100;
  const diff = (a: number, b: number) => a - b;
  const sleepMore = (up: boolean) => (up ? 'more' : 'less');
  const above = (up: boolean) => (up ? 'above' : 'below');
  const trend = (up: boolean) => (up ? 'trend-up' : 'trend-down');

  const rules: Rule[] = [
    {
      id: 'steps_sleep',
      split: split(by('steps', (x) => x >= 10_000, (x) => x < 10_000), 'sleep_hours', 1),
      min: 10,
      effect: minutes,
      unit: 'min',
      page: 'sleep',
      icon: () => 'steps',
      text: (n, up) => `On days with 10k+ steps, you tend to sleep ${n} min ${sleepMore(up)} that night.`,
      detail: (y, n) => `Based on ${y} days with 10k+ steps and ${n} without`,
    },
    {
      id: 'late_workout_hrv',
      split: split((d) => lateWorkout.get(d) ?? null, hrv, 1),
      min: 4,
      effect: percent,
      unit: '%',
      page: 'vitals',
      icon: trend,
      text: (n, up) => `After workouts that end after 8 pm, your next-morning HRV tends to be ${n}% ${above(up)} what it is after earlier workouts.`,
      detail: (y, n) => `Based on ${y} days with a workout ending after 8 pm and ${n} with only earlier ones`,
    },
    {
      id: 'short_sleep_rhr',
      split: split(by('sleep_hours', (x) => x < 6, (x) => x >= 7), 'resting_hr', 0),
      min: 1.5,
      effect: diff,
      places: 1,
      unit: 'bpm',
      page: 'vitals',
      icon: () => 'heart',
      text: (n, up) => `After nights under 6 hours of sleep, your resting heart rate tends to be ${n} bpm ${above(up)} what it is after 7 hours or more.`,
      detail: (y, n) => `Based on ${y} nights under 6 hours and ${n} of 7 hours or more`,
    },
    {
      id: 'strain_recovery',
      split: split(by('strain', (x) => x >= 14, (x) => x < 10), 'recovery', 1),
      min: 5,
      effect: diff,
      unit: 'points',
      page: 'vitals',
      icon: trend,
      text: (n, up) => `After days with a strain of 14 or more, your next-day recovery tends to be ${n} points ${above(up)} what it is after days under 10.`,
      detail: (y, n) => `Based on ${y} days with a strain of 14+ and ${n} under 10`,
    },
    {
      id: 'caffeine_sleep',
      split: split(by('caffeine_mg', (x) => x >= 200, (x) => x < 100), 'sleep_hours', 1),
      min: 10,
      effect: minutes,
      unit: 'min',
      page: 'sleep',
      icon: () => 'moon',
      text: (n, up) => `On days with 200+ mg of caffeine, you tend to sleep ${n} min ${sleepMore(up)} that night than on days under 100 mg.`,
      detail: (y, n) => `Based on ${y} days with 200 mg or more and ${n} under 100 mg`,
    },
    {
      id: 'daylight_sleep',
      split: split(by('daylight_min', (x) => x >= 30, (x) => x < 15), 'sleep_hours', 1),
      min: 10,
      effect: minutes,
      unit: 'min',
      page: 'sleep',
      icon: () => 'sun',
      text: (n, up) => `On days with 30+ minutes of daylight, you tend to sleep ${n} min ${sleepMore(up)} that night than on days under 15.`,
      detail: (y, n) => `Based on ${y} days with 30+ minutes of daylight and ${n} under 15`,
    },
    {
      id: 'mindful_hrv',
      split: split((d) => mindful.has(d), hrv, 1),
      min: 4,
      effect: percent,
      unit: '%',
      page: 'vitals',
      icon: () => 'spark',
      text: (n, up) => `After days with a mindful session, your next-morning HRV tends to be ${n}% ${above(up)} what it is after days without one.`,
      detail: (y, n) => `Based on ${y} days with a mindful session and ${n} without`,
    },
  ];

  return rules
    .map(judge)
    .filter((p) => p !== null)
    .sort((a, b) => b.strength - a.strength)
    .map(({ strength: _s, ...p }) => p);
}

/** What tends to go together over the 180 days to the latest data date: at most six, strongest first. */
export async function patterns(scope: Scope, hosted: boolean): Promise<Patterns> {
  const { settings, demo, today } = await requestContext(scope, hosted);
  const end = (await latestDataDate(scope, demo, today)) ?? today;
  const start = addDays(end, -(WINDOW - 1));
  const [daily, workouts, mindful] = await Promise.all([
    loadDaily(scope, demo, start, end, PATTERN_METRICS),
    loadWorkouts(scope, demo, start, end),
    scope.db.query<{ date: string }>("SELECT DISTINCT date FROM events WHERE user_id = $1 AND kind = 'mindful' AND date BETWEEN $2 AND $3 AND source = ANY($4)", [
      scope.userId,
      start,
      end,
      sourceList(demo),
    ]),
  ]);
  const ctx: Ctx = { settings, demo, today, daily, workouts: mergeWorkouts(workouts), sleepStarts: [] };
  return { start, end, patterns: findPatterns(ctx, new Set(mindful.map((r) => r.date)), start, end).slice(0, MAX_PATTERNS) };
}
