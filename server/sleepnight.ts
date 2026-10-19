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
  const at = (metric: string, source: string | undefined, d: string) => (source ? daily.get(metric)?.get(source)?.get(d) : undefined);
  // Segments by start instant: a night the clocks went back mixes offsets, so their text doesn't sort by time.
  segmentRows.sort((a, b) => Date.parse(a.start) - Date.parse(b.start));
  const segmentsFrom = (source: string | undefined, d: string) =>
    segmentRows.filter((r) => r.date === d && r.source === source).map(({ start, end, stage }): SleepSegment => ({ start, end, stage }));
  const hasSegments = (source: string, d: string) => segmentRows.some((r) => r.date === d && r.source === source);
  const eventsOf = (d: string, source?: string) =>
    events
      .filter((e) => e.date === d && (source === undefined || e.source === source) && Date.parse(e.end) > Date.parse(e.start))
      .sort((a, b) => Date.parse(b.end) - Date.parse(b.start) - (Date.parse(a.end) - Date.parse(a.start)));

  /** The device has this night: its sleep record, stretches or stage totals. */
  const recorded = (x: string, d: string) => hasSegments(x, d) || eventsOf(d, x).length > 0 || at('sleep_deep', x, d) !== undefined;
  /** Its stretches show stages (not only "asleep" from an older Watch or another app). */
  const staged = (x: string, d: string) => segmentRows.some((r) => r.date === d && r.source === x && (r.stage === 'deep' || r.stage === 'rem' || r.stage === 'light'));

  /**
   * The one device a night's stages, timeline, bed and wake times and source come from, so none of them is
   * paired with another device's. It's the device the night's total came from, when that device has the night
   * at all (a WHOOP nap alone isn't one); when the total is both devices' average, the one with the stages
   * through the night, else the one with stage totals.
   */
  const deviceOf = (d: string): string | undefined => {
    const src = valueOn(ctx, 'sleep_hours', d)?.source;
    const both = ['apple', 'whoop'];
    if (src === 'apple+whoop') {
      return both.find((x) => staged(x, d)) ?? both.find((x) => at('sleep_deep', x, d) !== undefined) ?? both.find((x) => recorded(x, d)) ?? 'apple';
    }
    if (src && recorded(src, d)) return src;
    // No total that night, or one from a device with nothing else for it: whichever device recorded the night.
    return [...sources].find((x) => recorded(x, d)) ?? src;
  };
  const device = deviceOf(date);
  const night = device ? eventsOf(date, device)[0] : undefined;
  // Bedtimes week against week from one device: WHOOP's record starts when you got into bed, Apple's at the first
  // moment asleep, so mixing them would show a change in steadiness that's only the devices. The one with the
  // most nights in both weeks.
  const weekDays = (fromBack: number, toBack: number) => Array.from({ length: fromBack - toBack + 1 }, (_, i) => addDays(date, -(fromBack - i)));
  const bedDevice = [...sources]
    .map((x) => ({ x, n: Math.min(...[weekDays(6, 0), weekDays(13, 7)].map((ds) => ds.filter((d) => eventsOf(d, x).length > 0).length)) }))
    .sort((a, b) => b.n - a.n)[0]?.x;

  const hours = valueOn(ctx, 'sleep_hours', date);
  const stages =
    at('sleep_deep', device, date) !== undefined
      ? {
          awake: round(at('sleep_awake', device, date) ?? 0, 2),
          rem: round(at('sleep_rem', device, date) ?? 0, 2),
          light: round(at('sleep_light', device, date) ?? 0, 2),
          deep: round(at('sleep_deep', device, date) ?? 0, 2),
        }
      : null;
  const segments = segmentsFrom(device, date);
  const inBed = at('sleep_in_bed', device, date);

  const performance = at('sleep_performance', 'whoop', date) ?? at('sleep_performance', 'demo', date);
  const asleep = hours?.value ?? null;
  // Efficiency only from one device's own two numbers, and only when it measured sleep (not just time in bed).
  const effSource = hours && hours.source !== 'apple+whoop' ? hours.source : undefined;
  const effBed = at('sleep_in_bed', effSource, date);
  const efficiency = asleep !== null && effBed && effBed - asleep > 1 / 60 ? (asleep / effBed) * 100 : null;
  const score: SleepNightDetail['score'] =
    performance !== undefined ? { kind: 'performance', value: Math.round(performance) } : efficiency !== null ? { kind: 'efficiency', value: Math.round(efficiency) } : null;

  return {
    date,
    today,
    source: device ? (device === 'whoop' ? 'whoop' : 'apple') : null,
    fellAsleep: night?.start ?? null,
    wokeUp: night?.end ?? null,
    asleepHours: asleep === null ? null : round(asleep, 2),
    inBedHours: inBed !== undefined ? round(inBed, 2) : null,
    stages,
    score,
    segments,
    latencyMin: latency(segments),
    deepPeak: deepPeak(segments),
    insights: nightInsights({ date, ctx, segmentsOf: (d) => segmentsFrom(deviceOf(d), d), nights: (d) => (bedDevice ? eventsOf(d, bedDevice)[0] : undefined) }),
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
  const minutes = (m: number) => {
    const r = Math.round(m);
    return r >= 60 ? `${Math.floor(r / 60)}h ${String(r % 60).padStart(2, '0')}m` : `${r} min`;
  };

  // Falling asleep, against the last two weeks.
  const tonight = latency(segmentsOf(date));
  const before = days(14, 1).map((d) => latency(segmentsOf(d))).filter((v): v is number => v !== null);
  const usualLatency = before.length >= 5 ? mean(before) : null;
  if (tonight !== null && usualLatency !== null && Math.abs(tonight - usualLatency) >= 5) {
    const diff = Math.round(Math.abs(tonight - usualLatency));
    out.push({ id: 'latency', icon: 'moon', text: `You fell asleep ${diff} min ${tonight < usualLatency ? 'faster' : 'slower'} than usual.` });
  }

  // Deep sleep, this week against last week, from one device: Apple's deep and WHOOP's slow-wave sleep are measured
  // differently, so a week on each would show a change that's only the device. The one with the most nights in both.
  const deepBy = ctx.daily.get('sleep_deep');
  const deepSource = [...(deepBy?.keys() ?? [])]
    .map((src) => ({ src, n: Math.min(...[days(6, 0), days(13, 7)].map((ds) => ds.filter((d) => deepBy!.get(src)!.has(d)).length)) }))
    .sort((a, b) => b.n - a.n)[0]?.src;
  const avg = (ds: string[]) => {
    const vs = ds.map((d) => (deepSource ? deepBy?.get(deepSource)?.get(d) : undefined)).filter((v): v is number => v !== undefined);
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
      out.push({ id: 'consistency', icon: 'shield', text: `Your bedtimes were ${sNow < sBefore ? 'steadier' : 'less steady'} this week: usually within about ${minutes(sNow)} of your average bedtime.` });
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

