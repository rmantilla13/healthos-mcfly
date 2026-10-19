// One night for the Sleep page (GET /api/sleep/night?date=): when you fell asleep and woke, the stages, a score,
// and, when the iPhone app sent them, the stages through the night. Read for the signed-in person only.
import type { SleepNightDetail, SleepSegment, SleepStage } from '../shared/types.ts';
import { addDays } from './dates.ts';
import type { Scope } from './db.ts';
import { loadDaily, mean, requestContext, sourceList, valueOn } from './query.ts';

const round = (v: number, places = 0) => Math.round(v * 10 ** places) / 10 ** places;
const STAGE_METRICS = ['sleep_awake', 'sleep_rem', 'sleep_light', 'sleep_deep'] as const;
const ASLEEP: SleepStage[] = ['rem', 'light', 'deep', 'asleep'];
/** Nights of history the comparisons look at. */
const HISTORY_NIGHTS = 21;

export async function sleepNight(scope: Scope, hosted: boolean, dateParam?: string): Promise<SleepNightDetail> {
  const { demo, today } = await requestContext(scope, hosted);
  const date = dateParam && dateParam <= today ? dateParam : today;
  const from = addDays(date, -HISTORY_NIGHTS);
  const sources = sourceList(demo);
  const [daily, events, segmentRows] = await Promise.all([
    loadDaily(scope, demo, from, date, ['sleep_hours', 'sleep_in_bed', ...STAGE_METRICS, 'sleep_performance', 'sleep_consistency']),
    scope.db.query<{ start: string; end: string; date: string; source: string }>(
      `SELECT start, "end", date, source FROM events WHERE user_id = $1 AND kind = 'sleep' AND date BETWEEN $2 AND $3 AND source = ANY($4)`,
      [scope.userId, from, date, sources],
    ),
    scope.db.query<{ date: string; start: string; end: string; stage: SleepStage; source: string }>(
      `SELECT date, start, "end", stage, source FROM sleep_stages WHERE user_id = $1 AND date BETWEEN $2 AND $3 AND source = ANY($4) ORDER BY start`,
      [scope.userId, from, date, sources],
    ),
  ]);
  const ctx = { daily, demo };
  const at = (bySource: Map<string, number> | undefined, d: string) => bySource?.get(d);

  // The night: the longest sleep that ended on this wake date, from whichever device recorded it.
  const nightOf = (d: string) =>
    events
      .filter((e) => e.date === d && Date.parse(e.end) > Date.parse(e.start))
      .sort((a, b) => Date.parse(b.end) - Date.parse(b.start) - (Date.parse(a.end) - Date.parse(a.start)))[0];
  const night = nightOf(date);

  // Stage totals from one device: the one the night's total comes from when it measured stages, else either.
  const hours = valueOn(ctx, 'sleep_hours', date);
  const stageSource = [hours?.source, 'whoop', 'apple', 'demo'].find((s) => s && at(daily.get('sleep_deep')?.get(s), date) !== undefined);
  const stages = stageSource
    ? {
        awake: round(at(daily.get('sleep_awake')?.get(stageSource), date) ?? 0, 2),
        rem: round(at(daily.get('sleep_rem')?.get(stageSource), date) ?? 0, 2),
        light: round(at(daily.get('sleep_light')?.get(stageSource), date) ?? 0, 2),
        deep: round(at(daily.get('sleep_deep')?.get(stageSource), date) ?? 0, 2),
      }
    : null;

  // Segments from one device too: the stages chart's, else the night's.
  const bySource = (d: string) => {
    const rows = segmentRows.filter((r) => r.date === d);
    const pick = [stageSource, night?.source, 'apple', 'demo'].find((s) => s && rows.some((r) => r.source === s));
    return rows.filter((r) => r.source === pick).map(({ start, end, stage }): SleepSegment => ({ start, end, stage }));
  };
  const segments = bySource(date);

  const inBed = valueOn(ctx, 'sleep_in_bed', date);
  const performance = at(daily.get('sleep_performance')?.get('whoop'), date) ?? at(daily.get('sleep_performance')?.get('demo'), date);
  const asleep = hours?.value ?? null;
  // Efficiency only from one device's own two numbers, and only when it measured sleep (not just time in bed).
  const effSource = hours && hours.source !== 'apple+whoop' ? hours.source : undefined;
  const effBed = effSource ? at(daily.get('sleep_in_bed')?.get(effSource), date) : undefined;
  const efficiency = asleep !== null && effBed && effBed - asleep > 1 / 60 ? (asleep / effBed) * 100 : null;
  const score: SleepNightDetail['score'] =
    performance !== undefined ? { kind: 'performance', value: Math.round(performance) } : efficiency !== null ? { kind: 'efficiency', value: Math.round(efficiency) } : null;

  return {
    date,
    today,
    source: night ? (night.source === 'whoop' ? 'whoop' : 'apple') : hours ? (hours.source === 'whoop' ? 'whoop' : 'apple') : null,
    fellAsleep: night?.start ?? null,
    wokeUp: night?.end ?? null,
    asleepHours: asleep === null ? null : round(asleep, 2),
    inBedHours: inBed ? round(inBed.value, 2) : null,
    stages,
    score,
    segments,
    latencyMin: latency(segments),
    deepPeak: deepPeak(segments),
    insights: nightInsights({ date, ctx, segmentsOf: bySource, nights: (d) => nightOf(d) }),
  };
}

/** Minutes in bed before first falling asleep, when the night starts with time in bed. */
export function latency(segments: SleepSegment[]): number | null {
  const bed = segments.find((s) => s.stage === 'in_bed');
  const first = segments.find((s) => ASLEEP.includes(s.stage));
  if (!bed || !first || Date.parse(bed.start) > Date.parse(first.start)) return null;
  const min = (Date.parse(first.start) - Date.parse(bed.start)) / 60_000;
  return min >= 0 && min < 4 * 60 ? Math.round(min) : null;
}

/** The middle of the longest unbroken stretch of deep sleep. */
export function deepPeak(segments: SleepSegment[]): string | null {
  const deep = segments.filter((s) => s.stage === 'deep');
  const longest = deep.sort((a, b) => Date.parse(b.end) - Date.parse(b.start) - (Date.parse(a.end) - Date.parse(a.start)))[0];
  if (!longest) return null;
  const mid = (Date.parse(longest.start) + Date.parse(longest.end)) / 2;
  // In the offset the segment was written with.
  const offset = longest.start.slice(19);
  const local = new Date(mid + offsetMinutes(offset) * 60_000).toISOString().slice(0, 19);
  return `${local}${offset || 'Z'}`;
}

function offsetMinutes(offset: string) {
  const m = /^([+-])(\d{2}):?(\d{2})$/.exec(offset);
  return m ? (m[1] === '-' ? -1 : 1) * (Number(m[2]) * 60 + Number(m[3])) : 0;
}

type InsightInput = {
  date: string;
  ctx: Parameters<typeof valueOn>[0];
  segmentsOf: (date: string) => SleepSegment[];
  nights: (date: string) => { start: string; end: string } | undefined;
};

/** Up to four sentences, each against the person's own recent nights, only when there's enough to say it. */
export function nightInsights({ date, ctx, segmentsOf, nights }: InsightInput): SleepNightDetail['insights'] {
  const out: SleepNightDetail['insights'] = [];
  const back = (n: number) => addDays(date, -n);
  const days = (fromBack: number, toBack: number) => Array.from({ length: fromBack - toBack + 1 }, (_, i) => back(fromBack - i));
  const minutes = (m: number) => (m >= 60 ? `${Math.floor(m / 60)}h ${String(Math.round(m % 60)).padStart(2, '0')}m` : `${Math.round(m)} min`);

  // Falling asleep, against the last two weeks.
  const tonight = latency(segmentsOf(date));
  const before = days(14, 1).map((d) => latency(segmentsOf(d))).filter((v): v is number => v !== null);
  const usualLatency = before.length >= 5 ? mean(before) : null;
  if (tonight !== null && usualLatency !== null && Math.abs(tonight - usualLatency) >= 5) {
    const diff = Math.round(Math.abs(tonight - usualLatency));
    out.push({ id: 'latency', icon: 'moon', text: `You fell asleep ${diff} min ${tonight < usualLatency ? 'faster' : 'slower'} than usual.` });
  }

  // Deep sleep, this week against last week.
  const avg = (ds: string[]) => {
    const vs = ds.map((d) => valueOn(ctx, 'sleep_deep', d)?.value).filter((v): v is number => v !== undefined);
    return vs.length >= 4 ? mean(vs) : null;
  };
  const thisWeek = avg(days(6, 0));
  const lastWeek = avg(days(13, 7));
  if (thisWeek !== null && lastWeek !== null && Math.abs(thisWeek - lastWeek) * 60 >= 10) {
    const more = thisWeek > lastWeek;
    out.push({ id: 'deep', icon: more ? 'trend-up' : 'trend-down', text: `Deep sleep was ${more ? 'higher' : 'lower'} this week, ${minutes(Math.abs(thisWeek - lastWeek) * 60)} a night ${more ? 'more' : 'less'} than last week.` });
  }

  // Consistency: WHOOP's score when there is one, else how much bedtimes moved.
  const consistency = (ds: string[]) => {
    const vs = ds.map((d) => valueOn(ctx, 'sleep_consistency', d)?.value).filter((v): v is number => v !== undefined);
    return vs.length >= 4 ? mean(vs) : null;
  };
  const cNow = consistency(days(6, 0));
  const cBefore = consistency(days(13, 7));
  if (cNow !== null && cBefore !== null && Math.abs(cNow - cBefore) >= 5) {
    out.push({ id: 'consistency', icon: 'shield', text: `Your sleep consistency is ${cNow > cBefore ? 'improving' : 'slipping'}: ${Math.round(cNow)}% this week, ${Math.round(cBefore)}% the week before.` });
  } else if (cNow === null) {
    const spread = (ds: string[]) => {
      const beds = ds.map((d) => nights(d)?.start).filter((s): s is string => Boolean(s)).map((s) => (Date.parse(`${s.slice(0, 19)}Z`) / 60_000 + 12 * 60) % (24 * 60));
      if (beds.length < 4) return null;
      const m = mean(beds)!;
      return Math.sqrt(beds.reduce((a, b) => a + (b - m) ** 2, 0) / beds.length);
    };
    const sNow = spread(days(6, 0));
    const sBefore = spread(days(13, 7));
    if (sNow !== null && sBefore !== null && Math.abs(sNow - sBefore) >= 10) {
      out.push({ id: 'consistency', icon: 'shield', text: `Your bedtimes were ${sNow < sBefore ? 'steadier' : 'less steady'} this week (within about ${minutes(sNow)} of each other).` });
    }
  }

  // Total sleep, this week against last week.
  const total = (ds: string[]) => {
    const vs = ds.map((d) => valueOn(ctx, 'sleep_hours', d)?.value).filter((v): v is number => v !== undefined);
    return vs.length >= 4 ? mean(vs) : null;
  };
  const tNow = total(days(6, 0));
  const tBefore = total(days(13, 7));
  if (tNow !== null && tBefore !== null && Math.abs(tNow - tBefore) * 60 >= 15) {
    out.push({ id: 'total', icon: 'sun', text: `You slept ${minutes(Math.abs(tNow - tBefore) * 60)} ${tNow > tBefore ? 'more' : 'less'} a night this week than last.` });
  }
  return out.slice(0, 4);
}

