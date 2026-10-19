// The Day view (GET /api/day): one day of hourly values, next to what a typical day looks like by each hour.
// Hourly rows come from the iPhone app and the export importer; WHOOP has no intraday data.
import type { DayData, DayMetric, DaySeries } from '../shared/types.ts';
import { addDays } from './dates.ts';
import type { Scope } from './db.ts';
import { pickSteps, requestContext, sourceList } from './query.ts';

export const DAY_METRICS: DayMetric[] = ['steps', 'active_energy', 'heart_rate'];
/** The stored hourly metric that says whether a Day metric has data at all. */
const BASE: Record<DayMetric, string> = { steps: 'steps', active_energy: 'active_energy', heart_rate: 'hr_avg' };
const STORED: Record<DayMetric, string[]> = { steps: ['steps'], active_energy: ['active_energy'], heart_rate: ['hr_avg', 'hr_min', 'hr_max'] };

const HOURS = 24;
const TYPICAL_DAYS = 30;
const MIN_DAYS = 3;

type Hours = (number | null)[];
const empty = (): Hours => Array.from({ length: HOURS }, () => null);
const round = (v: number | null) => (v === null ? null : Math.round(v * 100) / 100);

/** Median, with the mean of the two middle values for an even count; null for none. */
export function median(xs: number[]): number | null {
  if (!xs.length) return null;
  const s = [...xs].sort((a, b) => a - b);
  const mid = s.length >> 1;
  return s.length % 2 ? s[mid] : (s[mid - 1] + s[mid]) / 2;
}

/**
 * "Typical by now" for a summed metric: at each hour, the median over the given days of the running total
 * by the end of that hour. Within a day a missing hour adds nothing; needs at least 3 days.
 */
export function typicalRunning(days: Hours[]): Hours {
  if (days.length < MIN_DAYS) return empty();
  const running = days.map((d) => {
    let sum = 0;
    return d.map((v) => (sum += v ?? 0));
  });
  return Array.from({ length: HOURS }, (_, h) => median(running.map((r) => r[h])));
}

/** The typical reading at each hour: the median over the days that have one at that hour (at least 3). */
export function typicalHourly(days: Hours[]): Hours {
  return Array.from({ length: HOURS }, (_, h) => {
    const vs = days.map((d) => d[h]).filter((v): v is number => v !== null);
    return vs.length >= MIN_DAYS ? median(vs) : null;
  });
}

/** One day of the requested metrics, for the signed-in person only. */
export async function dayView(scope: Scope, hosted: boolean, requested: DayMetric[], dateParam?: string): Promise<DayData> {
  const { today, demo } = await requestContext(scope, hosted);
  const date = dateParam && dateParam <= today ? dateParam : today;
  const asked = DAY_METRICS.filter((m) => requested.includes(m));
  // Demo hours only while demo data is shown. (While it is, a phone's own hours still win the day, as before: someone
  // whose phone has sent hours but no day yet is still in demo mode.)
  const sources = demo ? [...sourceList(true), ...sourceList(false)] : sourceList(false);

  // Which of them this person has any hourly data for, on any day.
  const have = await scope.db.query<{ m: string; has: boolean }>(
    'SELECT m, EXISTS (SELECT 1 FROM hourly h WHERE h.user_id = $1 AND h.metric = m AND h.source = ANY($3)) AS has FROM unnest($2::text[]) AS m',
    [scope.userId, asked.map((m) => BASE[m]), sources],
  );
  const present = asked.filter((m) => have.find((r) => r.m === BASE[m])?.has);
  if (!present.length) return { date, today, asOf: null, metrics: {} };

  const from = addDays(date, -TYPICAL_DAYS);
  const rows = await scope.db.query<{ metric: string; date: string; hour: number; source: string; value: number }>(
    'SELECT metric, date, hour, source, value FROM hourly WHERE user_id = $1 AND metric = ANY($2) AND date BETWEEN $3 AND $4 AND source = ANY($5)',
    [scope.userId, present.flatMap((m) => STORED[m]), from, date, sources],
  );

  // metric -> date -> source -> 24 hours. One source per day: Apple's when there is one.
  const grid = new Map<string, Map<string, Map<string, Hours>>>();
  for (const r of rows) {
    const byDate = grid.get(r.metric) ?? new Map<string, Map<string, Hours>>();
    grid.set(r.metric, byDate);
    const bySource = byDate.get(r.date) ?? new Map<string, Hours>();
    byDate.set(r.date, bySource);
    const hours = bySource.get(r.source) ?? empty();
    bySource.set(r.source, hours);
    hours[Number(r.hour)] = Number(r.value);
  }
  const pick = (bySource: Map<string, Hours> | undefined) =>
    bySource ? (bySource.get('apple') ?? [...bySource].sort(([a], [b]) => a.localeCompare(b))[0][1]) : undefined;
  const dayOf = (metric: string, d: string) => pick(grid.get(metric)?.get(d));
  const before = Array.from({ length: TYPICAL_DAYS }, (_, i) => addDays(date, -(i + 1)));
  const previous = (metric: string) => before.map((d) => dayOf(metric, d)).filter((h): h is Hours => h !== undefined);

  const metrics: DayData['metrics'] = {};
  let asOf: number | null = null;
  for (const m of present) {
    const [main] = STORED[m];
    const series: DaySeries = {
      hours: (dayOf(main, date) ?? empty()).map(round),
      typical: (m === 'heart_rate' ? typicalHourly(previous(main)) : typicalRunning(previous(main))).map(round),
    };
    if (m === 'heart_rate') {
      series.min = (dayOf('hr_min', date) ?? empty()).map(round);
      series.max = (dayOf('hr_max', date) ?? empty()).map(round);
    }
    if (m === 'steps') {
      // The day's steps as everything else shows them (same rule), so the card can't silently disagree.
      const rows = await scope.db.query<{ source: string; value: number }>(
        "SELECT source, value FROM daily WHERE user_id = $1 AND metric = 'steps' AND date = $2 AND source = ANY($3)",
        [scope.userId, date, sources],
      );
      const total = pickSteps(rows.find((r) => r.source === 'apple'), rows.find((r) => r.source === 'whoop')) ?? rows.find((r) => r.source === 'demo');
      if (total) series.total = { value: Math.round(Number(total.value)), source: total.source };
    }
    metrics[m] = series;
    for (const stored of STORED[m]) {
      const hours = dayOf(stored, date);
      hours?.forEach((v, h) => {
        if (v !== null && (asOf === null || h > asOf)) asOf = h;
      });
    }
  }
  return { date, today, asOf, metrics };
}
