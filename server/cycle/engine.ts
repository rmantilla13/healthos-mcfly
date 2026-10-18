// The cycle engine: periods and cycles from what a person logged, ovulation per cycle from their temperatures and
// tests, and estimates for the current cycle. Pure, so tests can drive it.
//
// Estimates are a small Bayesian model rather than a calendar rule:
// - Cycle and luteal-phase lengths start from typical values (Bull et al. 2019: 612,613 cycles, mean cycle
//   29.3 days, luteal phase 12.4) and move to the person's own as their cycles come in, recent ones counting most.
// - Ovulation in the current cycle is a distribution over cycle days. This cycle's signals reshape it: a
//   positive LH test, an estrogen surge, fertile-quality mucus, a negative test, and temperatures that keep
//   tracking with no rise yet (ovulation can't be long past). A confirmed temperature rise settles it.
// - Each day's chance of conception sums that distribution against how fertile each day around ovulation is
//   (after Wilcox et al. 1995, NEJM 333:1517, smoothed): five days before, the day itself, a little the day after.
// Everything is an estimate: nothing here marks a day as safe, and none of it is fit to use as contraception.
import type { CycleDay, CycleEstimate, CycleHistory, CyclePhase, CycleTemperature, FertilityDay, TempSource } from '../../shared/types.ts';
import { addDays } from '../dates.ts';
import { EPS, between, clamp, mad, median } from './stats.ts';
import { RISE, type TempReading, bestSource, detectShift, prepareTemperatures } from './temperature.ts';

// ---------- constants ----------

/** Bleeding after this many days without any starts a new period. */
const QUIET_DAYS = 7;
/** Two period starts closer than this are the same period. */
const MIN_GAP = 10;
/** Cycles outside this range are more likely a missed or stray log than a real cycle; estimates skip them. */
export const PLAUSIBLE_CYCLE = [15, 90] as const;
const PLAUSIBLE_LUTEAL = [7, 19] as const;
/** No ovulation is inferred in the first days of a cycle (a stray test or reading). */
const EARLIEST_OVULATION = 6;
/** A period this many days long when the person's own history doesn't say. */
export const PERIOD_DAYS = 5;
/** Stats describe this many recent cycles; estimates weigh up to RECENT_MAX, newest most. */
const RECENT = 6;
const RECENT_MAX = 12;
const DECAY = 0.9;

/** Typical values, until a person's own cycles take over (Bull et al. 2019). Within-person spreads are this model's. */
const PRIOR = { cycle: 29.3, cycleSd: 2.5, luteal: 12.4, lutealSd: 1.5 };
/** How many cycles' worth of weight the typical values carry. */
const PRIOR_WEIGHT = { cycle: 0.5, luteal: 1 };
/** The share of ovulation timing given to a broad tail around the usual day. */
const PRIOR_TAIL = 0.2;

/** How fertile each day around ovulation is, relative to the most fertile, by offset from ovulation day. */
const FERTILE_BY_OFFSET: Record<number, number> = { [-5]: 0.3, [-4]: 0.45, [-3]: 0.55, [-2]: 0.8, [-1]: 0.95, 0: 1, 1: 0.1 };
const LEVELS = { medium: 0.15, high: 0.4, peak: 0.8 } as const;
/** The share of next-period dates the range covers (80%: ±1.28 standard deviations). */
const Z80 = 1.2816;

const isBleeding = (d: CycleDay) => d.flow !== undefined && d.flow !== 'none';

// ---------- the person's own model ----------

type Fit = { mean: number; sd: number; predSd: number; n: number };

/**
 * A length (cycle or luteal phase) from the person's values, oldest first, blended with the typical value:
 * newest values count most, ones far from the rest are set aside, and the spread shrinks as values come in.
 */
export function fitLength(values: number[], prior: number, priorSd: number, priorWeight: number, trimFloor: number): Fit {
  const recent = values.slice(-RECENT_MAX);
  const m = median(recent);
  const kept = m === null ? [] : recent.filter((v) => Math.abs(v - m) <= Math.max(trimFloor, 3 * mad(recent)));
  let wsum = 0;
  let wx = 0;
  kept.forEach((v, i) => {
    const w = DECAY ** (kept.length - 1 - i);
    wsum += w;
    wx += w * v;
  });
  const mean = (wx + priorWeight * prior) / (wsum + priorWeight);
  const avg = kept.length ? kept.reduce((s, v) => s + v, 0) / kept.length : prior;
  const ss = kept.reduce((s, v) => s + (v - avg) ** 2, 0);
  const nu = 2;
  const sd = Math.sqrt((ss + nu * priorSd ** 2) / (Math.max(0, kept.length - 1) + nu));
  return { mean, sd, predSd: sd * Math.sqrt(1 + 1 / (kept.length + priorWeight)), n: kept.length };
}

// ---------- analysis ----------

export type CycleAnalysis = {
  periods: { start: string; end: string; days: number }[];
  cycles: { start: string; days: number }[];
  stats: {
    cycleDays: number | null;
    periodDays: number | null;
    shortest: number | null;
    longest: number | null;
    variation: number | null;
    regular: boolean | null;
    follicularDays: number | null;
    lutealDays: number | null;
  };
  current: { start: string; day: number } | null;
  estimate: CycleEstimate | null;
  noEstimate: 'cycles' | 'stale' | null;
  /** The estimate while fewer than two of the person's own cycles are complete (see CycleData). */
  earlyEstimate: CycleEstimate | null;
  ovulations: { date: string; basis: 'bbt' | 'lh_test' }[];
  history: CycleHistory[];
  temperatures: CycleTemperature[];
  fertility: FertilityDay[];
};

/**
 * Periods, cycles, ovulation and estimates from a person's days (any order) and their wearables' nightly
 * temperatures. Thermometer readings come from the days' bbt.
 */
export function analyzeCycle(days: CycleDay[], today: string, wearable: TempReading[] = []): CycleAnalysis {
  const sorted = [...days].filter((d) => d.date <= today).sort((a, b) => a.date.localeCompare(b.date));

  // ---- periods ----
  const bleeding = sorted.filter(isBleeding).map((d) => d.date);
  const bleedingSet = new Set(bleeding);
  // A start someone marked wins over one inferred from bleeding nearby (spotting logged as flow the day before).
  const spaced = (dates: string[]) => dates.reduce<string[]>((out, d) => (out.length && between(out[out.length - 1], d) < MIN_GAP ? out : [...out, d]), []);
  const marked = spaced(sorted.filter((d) => d.periodStart).map((d) => d.date));
  const inferred = bleeding.filter((d) => {
    for (let i = 1; i <= QUIET_DAYS; i++) if (bleedingSet.has(addDays(d, -i))) return false;
    return marked.every((m) => Math.abs(between(m, d)) >= MIN_GAP);
  });
  const starts = spaced([...marked, ...inferred].sort());
  const periods = starts.map((start, i) => {
    const next = starts[i + 1];
    let end = start;
    for (const b of bleeding) {
      if (b <= start) continue;
      if ((next && b >= next) || between(end, b) > 2) break;
      end = b;
    }
    return { start, end, days: between(start, end) + 1 };
  });
  const cycles = starts.slice(1).map((s, i) => ({ start: starts[i], days: between(starts[i], s) }));

  // ---- temperatures ----
  const disturbed = new Set(sorted.filter((d) => d.tempDisturbed).map((d) => d.date));
  const readings: TempReading[] = [
    ...sorted.filter((d) => d.bbt !== undefined).map((d) => ({ date: d.date, source: 'bbt' as const, value: d.bbt as number })),
    ...wearable.filter((r) => r.date <= today),
  ];
  const temperatures = prepareTemperatures(readings, disturbed);

  // ---- each cycle ----
  const history: CycleHistory[] = starts.map((start, i) => {
    const next = starts[i + 1] ?? null;
    const last = next ? addDays(next, -1) : today;
    const inCycle = sorted.filter((d) => d.date >= start && d.date <= last);
    const cycleDay = (date: string) => between(start, date) + 1;
    const surge = inCycle.find((d) => d.ovulationTest === 'lh_surge' && cycleDay(d.date) + 1 >= EARLIEST_OVULATION)?.date ?? null;
    const temp = bestSource(temperatures, start, last);
    const source = temp?.source;
    const shift = temp && temp.points.length >= 7 && source ? detectShift(temp.points, { start, earliest: EARLIEST_OVULATION, rise: RISE[source], lhSurge: surge }) : null;

    let ovulation: CycleHistory['ovulation'] = null;
    if (shift && source) ovulation = { date: shift.ovulation, basis: 'bbt', tempSource: source };
    else if (surge && addDays(surge, 1) <= today) ovulation = { date: addDays(surge, 1), basis: 'lh_test' };

    const length = next ? between(start, next) : between(start, today) + 1;
    const covered = (temp?.points.length ?? 0) >= Math.max(10, 0.6 * length);
    const status: CycleHistory['status'] = shift ? 'confirmed' : ovulation ? 'lh_test' : !next ? 'waiting' : covered ? 'not_found' : 'no_data';
    const luteal = ovulation && next ? between(ovulation.date, next) - 1 : null;
    return {
      start,
      end: next ? last : null,
      days: length,
      periodDays: periods[i]?.days ?? null,
      ovulation,
      status,
      follicularDays: ovulation ? cycleDay(ovulation.date) : null,
      lutealDays: luteal,
      temperature: temp && source ? { source, readings: temp.points.length, coverline: shift?.coverline ?? null, rise: shift ? Math.round((shift.high - shift.low) * 100) / 100 : null } : null,
      symptoms: inCycle.filter((d) => d.symptoms?.length).length,
    };
  });
  const ovulations = history.flatMap((h) => (h.ovulation ? [{ date: h.ovulation.date, basis: h.ovulation.basis }] : []));

  // ---- stats ----
  const plausible = cycles.filter((c) => c.days >= PLAUSIBLE_CYCLE[0] && c.days <= PLAUSIBLE_CYCLE[1]).map((c) => c.days);
  const recent = plausible.slice(-RECENT);
  const complete = history.filter((h) => h.end !== null);
  const luteals = complete.flatMap((h) => (h.lutealDays !== null && h.lutealDays >= PLAUSIBLE_LUTEAL[0] && h.lutealDays <= PLAUSIBLE_LUTEAL[1] ? [h.lutealDays] : []));
  const follicular = complete.flatMap((h) => (h.follicularDays !== null && h.lutealDays !== null ? [h.follicularDays] : []));
  const roundOrNull = (v: number | null) => (v === null ? null : Math.round(v));
  const stats: CycleAnalysis['stats'] = {
    cycleDays: roundOrNull(median(recent)),
    periodDays: roundOrNull(median(periods.slice(-RECENT).map((p) => p.days))),
    shortest: recent.length ? Math.min(...recent) : null,
    longest: recent.length ? Math.max(...recent) : null,
    variation: recent.length >= 3 ? Math.max(...recent) - Math.min(...recent) : null,
    // FIGO 2018: shortest to longest within 7 to 9 days is regular.
    regular: recent.length >= 3 ? Math.max(...recent) - Math.min(...recent) <= 9 : null,
    follicularDays: roundOrNull(median(follicular.slice(-RECENT))),
    lutealDays: roundOrNull(median(luteals.slice(-RECENT))),
  };

  // ---- the current cycle ----
  const lastStart = starts.at(-1);
  const current = lastStart ? { start: lastStart, day: between(lastStart, today) + 1 } : null;
  const cycleFit = fitLength(plausible, PRIOR.cycle, PRIOR.cycleSd, PRIOR_WEIGHT.cycle, 7);
  const lutealFit = fitLength(luteals, PRIOR.luteal, PRIOR.lutealSd, PRIOR_WEIGHT.luteal, 4);

  let estimate: CycleEstimate | null = null;
  let earlyEstimate: CycleEstimate | null = null;
  let noEstimate: CycleAnalysis['noEstimate'] = null;
  let fertility: FertilityDay[] = [];
  if (!current) noEstimate = 'cycles';
  else if (current.day - 1 > 2 * Math.max(cycleFit.mean, PLAUSIBLE_CYCLE[0])) noEstimate = 'stale';
  else {
    const now = history.at(-1) as CycleHistory;
    const forecast = forecastCycle({
      start: current.start,
      today,
      days: sorted.filter((d) => d.date >= current.start),
      confirmed: now.status === 'confirmed' ? now.ovulation : null,
      temps: temperatures,
      cycleFit,
      lutealFit,
    });
    fertility = forecast.fertility;
    const built: CycleEstimate = {
      nextPeriod: forecast.nextPeriod,
      ovulation: forecast.ovulation,
      fertile: fertility.length ? { start: fertility[0].date, end: fertility.at(-1)!.date } : { start: addDays(forecast.ovulation, -5), end: addDays(forecast.ovulation, 1) },
      basis: forecast.basis,
      cycles: cycleFit.n,
      confidence:
        forecast.basis === 'bbt' || (cycleFit.n >= 6 && cycleFit.sd <= 2) ? 'high' : forecast.basis === 'lh_test' || (cycleFit.n >= 3 && cycleFit.sd <= 4) ? 'medium' : 'low',
      ...(forecast.basis === 'bbt' && now.ovulation?.tempSource ? { tempSource: now.ovulation.tempSource } : {}),
    };
    if (cycleFit.n >= 2) estimate = built;
    else [earlyEstimate, noEstimate] = [built, 'cycles'];
  }
  return { periods, cycles, stats, current, estimate, noEstimate, earlyEstimate, ovulations, history, temperatures, fertility };
}

// ---------- the current cycle's forecast ----------

type ForecastInput = {
  start: string;
  today: string;
  /** This cycle's days, to today. */
  days: CycleDay[];
  confirmed: CycleHistory['ovulation'];
  temps: CycleTemperature[];
  cycleFit: Fit;
  lutealFit: Fit;
};

/** A distribution over the cycle day of ovulation, each signal this cycle reshaping the calendar's guess. */
function ovulationOdds(f: ForecastInput): { odds: Map<number, number>; basis: CycleEstimate['basis']; signals: boolean } {
  const cd = (date: string) => between(f.start, date) + 1;
  const todayCd = cd(f.today);
  if (f.confirmed?.basis === 'bbt') {
    const o = cd(f.confirmed.date);
    return {
      odds: new Map([
        [o - 1, 0.15],
        [o, 0.7],
        [o + 1, 0.15],
      ]),
      basis: 'bbt',
      signals: true,
    };
  }
  const center = f.cycleFit.mean - f.lutealFit.mean;
  const spread = Math.max(1.5, Math.sqrt(Math.max(0, f.cycleFit.predSd ** 2 - f.lutealFit.sd ** 2)));
  // Mostly the person's usual timing, with a broad tail: an ovulation well off the usual day happens more often
  // than a bell curve allows (stress, illness, travel).
  const tail = Math.min(3 * spread, 6);
  const last = Math.max(Math.round(center + 3 * tail), todayCd + 10, EARLIEST_OVULATION + 1);
  const bell = (o: number, sd: number) => Math.exp(-((o - center) ** 2) / (2 * sd ** 2)) / sd;
  const odds = new Map<number, number>();
  for (let o = EARLIEST_OVULATION; o <= last; o++) odds.set(o, PRIOR_TAIL * bell(o, tail) + (1 - PRIOR_TAIL) * bell(o, spread));
  const scale = (fn: (o: number) => number) => odds.forEach((p, o) => odds.set(o, p * fn(o)));

  let basis: CycleEstimate['basis'] = 'calendar';
  let signals = false;
  const surge = f.days.find((d) => d.ovulationTest === 'lh_surge' && cd(d.date) + 1 >= EARLIEST_OVULATION);
  if (surge) {
    // Ovulation usually follows a positive LH test within a day or two.
    const s = cd(surge.date);
    scale((o) => ({ [s]: 0.5, [s + 1]: 1, [s + 2]: 0.5, [s + 3]: 0.15 })[o] ?? 0.01);
    basis = 'lh_test';
    signals = true;
  }
  for (const d of f.days) {
    const day = cd(d.date);
    if (d.ovulationTest === 'negative' && !surge) {
      scale((o) => (o === day + 1 ? 0.4 : o === day ? 0.7 : 1));
      signals = true;
    }
    if (d.ovulationTest === 'estrogen_surge' && !surge) {
      scale((o) => (o > day && o <= day + 5 ? 1 : 0.35));
      signals = true;
    }
    if ((d.mucus === 'egg_white' || d.mucus === 'watery') && !surge) {
      // Fertile-quality mucus comes in the days up to ovulation.
      scale((o) => (o >= day - 1 && o <= day + 5 ? 1 : 0.3));
      signals = true;
    }
  }
  // Temperatures kept up with no rise: an ovulation three or more days before the latest reading would have
  // shown its three high readings by now.
  const temp = bestSource(f.temps, f.start, f.today);
  const latest = temp?.points.at(-1)?.date;
  const recentReadings = latest ? (temp?.points.filter((p) => between(p.date, latest) <= 9).length ?? 0) : 0;
  if (temp && latest && temp.points.length >= 7 && recentReadings >= 6 && between(latest, f.today) <= 2) {
    const seen = cd(latest) - 3;
    scale((o) => (o <= seen ? 0.1 : 1));
    signals = true;
  }
  const total = [...odds.values()].reduce((s, p) => s + p, 0);
  odds.forEach((p, o) => odds.set(o, p / total));
  return { odds, basis, signals };
}

export function forecastCycle(f: ForecastInput): {
  nextPeriod: CycleEstimate['nextPeriod'];
  ovulation: string;
  basis: CycleEstimate['basis'];
  fertility: FertilityDay[];
} {
  const { odds, basis, signals } = ovulationOdds(f);
  const cdDate = (cd: number) => addDays(f.start, cd - 1);
  let mode = 0;
  let best = -1;
  odds.forEach((p, o) => {
    if (p > best + EPS) [mode, best] = [o, p];
  });

  // The next period follows ovulation by the luteal phase: day 1 of the next cycle is ovulation day + luteal + 1,
  // so its offset from this cycle's start is ovulation's cycle day + the luteal length. The date is the median of
  // that distribution, and the range runs from its 10th to its 90th percentile.
  const luteal = new Map<number, number>();
  const { mean: lm, sd: ls } = f.lutealFit;
  for (let k = Math.floor(lm - 4 * ls); k <= Math.ceil(lm + 4 * ls); k++) luteal.set(k, Math.exp(-((k - lm) ** 2) / (2 * ls ** 2)));
  const lutealTotal = [...luteal.values()].reduce((a, b) => a + b, 0);
  const offsets = new Map<number, number>();
  odds.forEach((p, o) => luteal.forEach((q, k) => offsets.set(o + k, (offsets.get(o + k) ?? 0) + (p * q) / lutealTotal)));
  const sortedOffsets = [...offsets].sort((a, b) => a[0] - b[0]);
  const quantile = (q: number) => {
    let acc = 0;
    for (const [offset, p] of sortedOffsets) if ((acc += p) >= q - EPS) return offset;
    return sortedOffsets.at(-1)![0];
  };
  const mid = quantile(0.5);
  const date = addDays(f.start, mid);
  const nextPeriod = {
    date,
    earliest: addDays(f.start, clamp(quantile(0.1), mid - 10, mid - 1)),
    latest: addDays(f.start, clamp(quantile(0.9), mid + 1, mid + 10)),
  };

  // Each day's chance: the odds of each ovulation day, times how fertile that day is relative to it.
  const lastDay = Math.max(...odds.keys()) + 1;
  const fertility: FertilityDay[] = [];
  for (let d = 1; d <= lastDay; d++) {
    let chance = 0;
    odds.forEach((p, o) => (chance += p * (FERTILE_BY_OFFSET[d - o] ?? 0)));
    if (chance < LEVELS.medium) continue;
    const date = cdDate(d);
    if (date >= nextPeriod.date) break;
    fertility.push({
      date,
      chance: Math.round(chance * 100) / 100,
      level: chance >= LEVELS.peak ? 'peak' : chance >= LEVELS.high ? 'high' : 'medium',
      basis: signals ? 'logged' : 'estimate',
    });
  }
  return { nextPeriod, ovulation: cdDate(mode), basis, fertility };
}

// ---------- where today falls ----------

/**
 * Where today falls in the current cycle. Menstrual while today is in the period's logged bleeding run, or within
 * the usual period length once bleeding was logged in it; ovulatory on the days of high or peak fertility; luteal
 * after this cycle's ovulation (found, else estimated); otherwise follicular. null with no current cycle, or one
 * so long past that it isn't really current.
 */
export function cyclePhase(a: CycleAnalysis, days: CycleDay[], today: string): CyclePhase | null {
  const { current } = a;
  if (!current || a.noEstimate === 'stale' || current.day > PLAUSIBLE_CYCLE[1]) return null;
  // The phase may lean on an early estimate; days to the next period only come from a full one.
  const estimate = a.estimate ?? a.earlyEstimate;
  // A period that's late reads as due today rather than a negative count.
  const nextPeriodIn = a.estimate ? Math.max(0, between(today, a.estimate.nextPeriod.date)) : null;
  const phase = (name: CyclePhase['name'], basis: CyclePhase['basis']): CyclePhase => ({ name, day: current.day, nextPeriodIn, basis });

  const period = a.periods.find((p) => p.start === current.start);
  const bled = days.some((d) => d.date >= current.start && d.date <= today && isBleeding(d));
  if (bled && ((period && today <= period.end) || current.day <= (a.stats.periodDays ?? PERIOD_DAYS))) return phase('menstrual', 'logged');

  const found = a.history.at(-1)?.ovulation ?? null;
  const basis = found ? 'logged' : 'estimate';
  const todayFertility = a.fertility.find((f) => f.date === today);
  if (todayFertility && todayFertility.level !== 'medium' && (!found || today <= addDays(found.date, 1))) return phase('ovulatory', basis);
  const ovulation = found?.date ?? estimate?.ovulation;
  if (ovulation && today > ovulation) return phase('luteal', basis);
  return phase('follicular', basis);
}
