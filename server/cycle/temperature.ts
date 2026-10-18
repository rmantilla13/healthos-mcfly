// Temperatures for the cycle engine: a thermometer's basal readings (logged, or from Apple Health), Apple Watch's
// sleeping wrist temperature and WHOOP's skin temperature. Each device reads at its own level (a wrist sits a
// degree or two below the mouth), so a reading is only ever compared with readings from the same device:
// devices are never blended, and the analysis of one cycle uses one device.
//
// The method follows what Natural Cycles has published about its own (Bull et al. 2019, npj Digital Medicine
// 2:83; Berglund Scherwitzl et al. 2016): leave out implausible readings and any the person marks as disturbed
// (illness, alcohol, poor sleep), find the first of a run of readings that sits above the cover line (the
// highest of the low readings before it) and above the low-phase level, confirm it's sustained, and take
// ovulation as the last low day. A positive LH test lets fewer high readings confirm it. The thresholds are
// the classic ones for a thermometer (three readings, the third 0.2 °C above the cover line) and a little
// lower for wearables, whose post-ovulation rise is smaller; their algorithm itself is not public.
import type { CycleTemperature, TempSource } from '../../shared/types.ts';
import { addDays } from '../dates.ts';
import { EPS, between, mad, mean, median, round2 } from './stats.ts';

export type TempReading = { date: string; source: TempSource; value: number };

/** Readings outside these are faults (a cold room, a loose band), not body temperature. °C. */
export const PLAUSIBLE: Record<TempSource, readonly [number, number]> = { bbt: [35, 37.5], wrist: [30, 39], skin: [30, 39] };

/** When two devices covered a cycle equally well, the first in this list is used. */
export const PREFERENCE: readonly TempSource[] = ['bbt', 'wrist', 'skin'];

/** How far the high readings must clear the cover line, °C. */
export const RISE: Record<TempSource, number> = { bbt: 0.2, wrist: 0.15, skin: 0.15 };

/** The person's own level on a device: the median of its readings within this many days either side. */
const BASELINE_DAYS = 28;

/** A reading this far from the median of its neighbours (and three of their spreads) is left out. °C. */
const OUTLIER_FLOOR = 0.5;

/**
 * Every plausible reading, with its deviation from the person's own level on that device, and marked when the
 * analysis leaves it out. Oldest first; one reading per device per day (the first given wins).
 */
export function prepareTemperatures(readings: TempReading[], disturbed: Set<string>): CycleTemperature[] {
  const out: CycleTemperature[] = [];
  for (const source of PREFERENCE) {
    const seen = new Set<string>();
    const rs = readings
      .filter((r) => r.source === source && Number.isFinite(r.value) && r.value >= PLAUSIBLE[source][0] && r.value <= PLAUSIBLE[source][1])
      .filter((r) => !seen.has(r.date) && seen.add(r.date))
      .sort((a, b) => a.date.localeCompare(b.date));
    const usable = rs.filter((r) => !disturbed.has(r.date));
    let lo = 0;
    let hi = 0;
    for (const r of rs) {
      // A sliding window over the usable readings within BASELINE_DAYS of this one.
      while (lo < usable.length && between(usable[lo].date, r.date) > BASELINE_DAYS) lo++;
      while (hi < usable.length && between(r.date, usable[hi].date) <= BASELINE_DAYS) hi++;
      const level = median(usable.slice(lo, hi).map((u) => u.value)) ?? r.value;
      const t: CycleTemperature = { date: r.date, source, value: round2(r.value), deviation: round2(r.value - level) };
      if (disturbed.has(r.date)) t.excluded = 'disturbed';
      out.push(t);
    }
    // Outliers: against up to three usable neighbours each side within a week.
    const kept = out.filter((t) => t.source === source && !t.excluded);
    kept.forEach((t, i) => {
      const near = [...kept.slice(Math.max(0, i - 3), i), ...kept.slice(i + 1, i + 4)].filter((n) => Math.abs(between(n.date, t.date)) <= 7).map((n) => n.value);
      if (near.length < 3) return;
      const m = median(near) ?? t.value;
      if (Math.abs(t.value - m) > Math.max(OUTLIER_FLOOR, 3 * mad(near))) t.excluded = 'outlier';
    });
  }
  return out.sort((a, b) => a.date.localeCompare(b.date) || PREFERENCE.indexOf(a.source) - PREFERENCE.indexOf(b.source));
}

export type Shift = {
  /** The last low day. */
  ovulation: string;
  firstHigh: string;
  /** Deviations, °C: the highest low reading the rise had to clear, and the mean levels either side of it. */
  coverline: number;
  low: number;
  high: number;
};

type Point = { date: string; deviation: number };

/**
 * The cycle's temperature rise, from one device's usable readings in the cycle (oldest first), or null.
 * `earliest`: the first cycle day ovulation can fall on. `lhSurge`: a positive LH test this cycle, if any.
 */
export function detectShift(points: Point[], o: { start: string; earliest: number; rise: number; lhSurge?: string | null }): Shift | null {
  for (let i = 1; i < points.length; i++) {
    const first = points[i];
    const ovulation = addDays(first.date, -1);
    if (between(o.start, ovulation) + 1 < o.earliest) continue;
    // The low run: up to six readings before, within ten days. Gaps are fine; too few to judge is not.
    const low = points.slice(Math.max(0, i - 6), i).filter((p) => between(p.date, first.date) <= 10);
    if (low.length < 4) continue;
    const cover = Math.max(...low.map((p) => p.deviation));
    const lowMean = mean(low.map((p) => p.deviation));
    if (first.deviation <= cover + EPS) continue;

    // The high run: the readings within six days of the first.
    const next = points.slice(i).filter((p) => between(first.date, p.date) <= 6);
    const lhNear = o.lhSurge ? between(o.lhSurge, first.date) >= 0 && between(o.lhSurge, first.date) <= 4 : false;
    const need = lhNear ? 2 : 3;
    const above = (p: Point) => p.deviation > cover + EPS;
    const clears = (p: Point) => p.deviation >= cover + o.rise - EPS;
    const run = next.slice(0, need);
    const extra = next.slice(0, need + 1);
    const confirmed =
      // The rule: `need` readings above the cover line, the last of them clearly above it.
      (run.length === need && run.every(above) && clears(run[need - 1])) ||
      // Not quite clear by the last: one more above confirms it.
      (extra.length === need + 1 && extra.every(above)) ||
      // One dip to the cover line among the rest is skipped if the reading after clears it.
      (extra.length === need + 1 && extra.slice(1, need).filter((p) => !above(p)).length === 1 && clears(extra[need]));
    if (!confirmed) continue;

    // Sustained, not a spike: most of the readings that follow sit well above the low level.
    const after = points.slice(i, i + 8);
    const highs = after.filter((p) => p.deviation >= lowMean + o.rise / 2 - EPS).length;
    if (highs * 3 < after.length * 2) continue;

    // The rule can fire a day or two early on a noisy night that happens to clear the cover line. Once the rise
    // is confirmed, the first high reading is the nearby split that best separates the readings before from after.
    const k = refine(points, i, (p) => between(o.start, addDays(p.date, -1)) + 1 >= o.earliest);
    const firstHigh = points[k];
    const lowRun = points.slice(Math.max(0, k - 6), k).map((p) => p.deviation);
    return {
      ovulation: addDays(firstHigh.date, -1),
      firstHigh: firstHigh.date,
      coverline: round2(Math.max(...lowRun)),
      low: round2(mean(lowRun)),
      high: round2(mean(points.slice(k, k + 10).map((p) => p.deviation))),
    };
  }
  return null;
}

/**
 * Of the readings within two of index i, the one where six before and six after differ most relative to their
 * spread. The rule's own answer stands unless another is clearly better (a third more separation), so a slow,
 * stepwise rise keeps its first high reading.
 */
function refine(points: Point[], i: number, allowed: (p: Point) => boolean): number {
  const score = (k: number) => {
    const before = points.slice(Math.max(0, k - 6), k).map((p) => p.deviation);
    const after = points.slice(k, k + 6).map((p) => p.deviation);
    if (before.length < 3 || after.length < 2) return -Infinity;
    const spread = Math.sqrt(((before.length - 1) * variance(before) + (after.length - 1) * variance(after)) / Math.max(1, before.length + after.length - 2));
    return (mean(after) - mean(before)) / Math.max(spread, 0.03);
  };
  const own = score(i);
  let best = i;
  let bestScore = own;
  for (let k = Math.max(1, i - 2); k <= Math.min(points.length - 1, i + 2); k++) {
    if (k === i || !allowed(points[k])) continue;
    const s = score(k);
    if (s > bestScore + EPS && s >= own * 1.3) [best, bestScore] = [k, s];
  }
  return best;
}

const variance = (xs: number[]) => {
  const m = mean(xs);
  return xs.length > 1 ? xs.reduce((s, x) => s + (x - m) ** 2, 0) / (xs.length - 1) : 0;
};

/** The device with the most usable readings in [from, to], with its readings; ties go by PREFERENCE. */
export function bestSource(temps: CycleTemperature[], from: string, to: string): { source: TempSource; points: Point[] } | null {
  let best: { source: TempSource; points: Point[] } | null = null;
  for (const source of PREFERENCE) {
    const points = temps.filter((t) => t.source === source && !t.excluded && t.date >= from && t.date <= to);
    if (points.length && (!best || points.length > best.points.length)) best = { source, points };
  }
  return best;
}
