// Patterns from a person's own cycles: how their body changes after ovulation, when their symptoms tend to come,
// and recent cycles outside the usual ranges. Cycle-derived, so these live only inside the gated /api/cycle:
// never in the summary, flags, patterns, the weekly digest or the family board.
import type { CycleDay, CycleInsights, CyclePhase, Symptom } from '../../shared/types.ts';
import { addDays } from '../dates.ts';
import { type CycleAnalysis, PERIOD_DAYS } from './engine.ts';
import { between, mean } from './stats.ts';

/** One daily value from `daily`. */
export type VitalRow = { date: string; metric: string; source: string; value: number };

/** Typical luteal phase, for placing days in cycles where ovulation wasn't found. */
const LUTEAL_GUESS = 12;
const RECENT = 6;
/** FIGO 2018: cycles of 24 to 38 days, periods up to 8 days, and shortest to longest within 7 to 9 days. */
const FIGO = { shortest: 24, longest: 38, period: 8, spread: 9 };

/** The phase a past day fell in, from its cycle's period and ovulation (found, else guessed back from the next period). */
export function phaseOf(a: CycleAnalysis, date: string): CyclePhase['name'] | null {
  const h = [...a.history].reverse().find((c) => c.start <= date);
  if (!h || (h.end && date > h.end)) return null;
  const day = between(h.start, date) + 1;
  if (day <= (h.periodDays ?? PERIOD_DAYS)) return 'menstrual';
  const ovulation = h.ovulation?.date ?? (h.end ? addDays(h.end, -LUTEAL_GUESS) : a.estimate?.ovulation);
  if (!ovulation) return null;
  const off = between(ovulation, date);
  if (off >= -1 && off <= 1) return 'ovulatory';
  return off > 1 ? 'luteal' : 'follicular';
}

function bodyByPhase(a: CycleAnalysis, vitals: VitalRow[]): CycleInsights['body'] {
  const out: CycleInsights['body'] = [];
  // Cycles where ovulation was found and the next period came: before is from the end of the period to the day
  // before ovulation, after is from two days after it to the cycle's end.
  const windows = a.history.flatMap((h) =>
    h.ovulation && h.end
      ? [{ before: [addDays(h.start, h.periodDays ?? PERIOD_DAYS), addDays(h.ovulation.date, -1)], after: [addDays(h.ovulation.date, 2), h.end], source: h.temperature?.source }]
      : [],
  );
  const compare = (values: Map<string, number>, metric: CycleInsights['body'][number]['metric'], unit: CycleInsights['body'][number]['unit'], digits: number, perCycle?: (w: (typeof windows)[number]) => Map<string, number>) => {
    const pairs = windows.flatMap((w) => {
      const v = perCycle ? perCycle(w) : values;
      const inRange = ([from, to]: string[]) => [...v].filter(([d]) => d >= from && d <= to).map(([, x]) => x);
      const before = inRange(w.before);
      const after = inRange(w.after);
      return before.length >= 4 && after.length >= 4 ? [[mean(before), mean(after)]] : [];
    });
    if (pairs.length < 2) return;
    const r = (x: number) => Math.round(x * 10 ** digits) / 10 ** digits;
    out.push({ metric, follicular: r(mean(pairs.map((p) => p[0]))), luteal: r(mean(pairs.map((p) => p[1]))), unit, cycles: pairs.length });
  };
  // One device per metric: the one with the most days, since devices measure at different levels.
  const series = (metrics: string[]) => {
    const counts = new Map<string, number>();
    for (const v of vitals) if (metrics.includes(v.metric)) counts.set(`${v.metric}|${v.source}`, (counts.get(`${v.metric}|${v.source}`) ?? 0) + 1);
    const top = [...counts].sort((x, y) => y[1] - x[1])[0]?.[0];
    return new Map(vitals.filter((v) => `${v.metric}|${v.source}` === top).map((v) => [v.date, v.value]));
  };
  compare(series(['resting_hr']), 'resting_hr', 'bpm', 1);
  compare(series(['hrv_rmssd', 'hrv_sdnn']), 'hrv', 'ms', 0);
  compare(new Map(), 'temperature', '°C', 2, (w) => new Map(a.temperatures.filter((t) => !t.excluded && t.source === w.source).map((t) => [t.date, t.deviation])));
  return out;
}

function symptomPatterns(a: CycleAnalysis, days: CycleDay[]): CycleInsights['symptoms'] {
  const bySymptom = new Map<Symptom, { phases: (CyclePhase['name'] | null)[]; cycles: Set<string> }>();
  for (const d of days) {
    for (const s of d.symptoms ?? []) {
      const cycle = [...a.history].reverse().find((c) => c.start <= d.date);
      if (!cycle) continue;
      const e = bySymptom.get(s) ?? { phases: [], cycles: new Set() };
      e.phases.push(phaseOf(a, d.date));
      e.cycles.add(cycle.start);
      bySymptom.set(s, e);
    }
  }
  return [...bySymptom]
    .filter(([, e]) => e.cycles.size >= 2)
    .map(([symptom, e]) => {
      const counts = new Map<CyclePhase['name'], number>();
      for (const p of e.phases) if (p) counts.set(p, (counts.get(p) ?? 0) + 1);
      const [top, n] = [...counts].sort((x, y) => y[1] - x[1])[0] ?? [null, 0];
      // A phase only when most of the days fall in it.
      return { symptom, days: e.phases.length, cycles: e.cycles.size, phase: top && n / e.phases.length >= 0.6 ? top : null };
    })
    .sort((x, y) => y.days - x.days || x.symptom.localeCompare(y.symptom));
}

function deviations(a: CycleAnalysis, days: CycleDay[], today: string): CycleInsights['deviations'] {
  // Recent: the last six complete cycles that started within about a year.
  const recent = a.history.filter((h) => h.end && between(h.start, today) <= 400).slice(-RECENT);
  const out: CycleInsights['deviations'] = [];
  if (recent.length < 2) return out;
  const short = recent.filter((h) => h.days < FIGO.shortest).length;
  const long = recent.filter((h) => h.days > FIGO.longest).length;
  if (short >= 2) out.push({ kind: 'frequent', count: short, of: recent.length });
  if (long >= 2) out.push({ kind: 'infrequent', count: long, of: recent.length });
  const lengths = recent.map((h) => h.days);
  if (recent.length >= 4 && Math.max(...lengths) - Math.min(...lengths) > FIGO.spread) {
    out.push({ kind: 'irregular', count: recent.length, of: recent.length, spread: Math.max(...lengths) - Math.min(...lengths) });
  }
  const prolonged = recent.filter((h) => (h.periodDays ?? 0) > FIGO.period).length;
  if (prolonged >= 2) out.push({ kind: 'prolonged', count: prolonged, of: recent.length });
  const spotted = recent.filter((h) => days.some((d) => d.spotting && d.date >= h.start && h.end && d.date <= h.end && between(h.start, d.date) + 1 > (h.periodDays ?? PERIOD_DAYS))).length;
  if (spotted >= 2) out.push({ kind: 'spotting', count: spotted, of: recent.length });
  return out;
}

export function cycleInsights(a: CycleAnalysis, days: CycleDay[], vitals: VitalRow[], today: string): CycleInsights {
  return { body: bodyByPhase(a, vitals), symptoms: symptomPatterns(a, days), deviations: deviations(a, days, today) };
}
