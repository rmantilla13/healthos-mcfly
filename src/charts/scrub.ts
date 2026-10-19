// Scrubbing through a day on Home's timeline: what was going on at one minute, from the day's events and its
// hourly readings (GET /api/day). Every figure is a real reading or a running total of them, and says which
// hour it covers; nothing is spread across an hour or guessed between readings.
import type { DayData, DaySeries, TimelineEvent } from '../../shared/types.ts';
import { cumulative, drawThrough, lastReading } from './day.ts';

export const DAY_MINUTES = 1440;

/** "07:05"; 1440 is "24:00", the end of the day. */
export const clockOf = (minute: number) => `${String(Math.floor(minute / 60)).padStart(2, '0')}:${String(minute % 60).padStart(2, '0')}`;
/** "07:00", the start of an hour (24 is the end of the day). */
export const hourClock = (hour: number) => `${String(hour).padStart(2, '0')}:00`;

/**
 * How far the marker goes: the whole day for a past day; up to now for today, but never short of the last hour
 * with readings (the browser's clock and the person's saved time zone can disagree).
 */
export function scrubMax(isToday: boolean, nowMinute: number, asOf: number | null): number {
  if (!isToday) return DAY_MINUTES;
  return Math.min(DAY_MINUTES, Math.max(nowMinute, asOf === null ? 0 : asOf * 60));
}

/** Next keyboard stop: `step` minutes on a grid of `step` (so 14:32 goes back to 14:30, then 14:15), within 0–max. */
export function stepMinute(minute: number, step: number, dir: 1 | -1, max: number): number {
  const next = dir < 0 ? Math.ceil(minute / step) * step - step : Math.floor(minute / step) * step + step;
  return Math.min(max, Math.max(0, next));
}

/** The shortest an event is drawn, in minutes, so a brief session can still be seen and pressed. */
export const MIN_DRAWN = 12;

const minutesOf = (iso: string) => Number(iso.slice(11, 13)) * 60 + Number(iso.slice(14, 16));

/**
 * An event's minutes on `date`, as recorded (from–to, clipped to the day: a night that began the evening before
 * starts at 0) and as drawn (at least MIN_DRAWN wide).
 */
export function eventSpan(e: TimelineEvent, date: string) {
  const from = e.start.slice(0, 10) < date ? 0 : minutesOf(e.start);
  const to = e.end.slice(0, 10) > date ? DAY_MINUTES : minutesOf(e.end);
  return { from, to, drawnTo: Math.max(to, from + MIN_DRAWN) };
}

/**
 * The minute a press at `raw` minutes picks: inside an event, that exact minute (so a short one isn't rounded
 * past); on the part of a short event's segment drawn beyond its end, its last real minute (so pressing what you
 * see shows it); anywhere else, the nearest `snap` minutes.
 */
export function pressMinute(events: TimelineEvent[], date: string, raw: number, snap: number): number {
  const m = Math.floor(raw);
  const spans = events.map((e) => eventSpan(e, date));
  if (spans.some((s) => m >= s.from && m < s.to)) return m;
  const drawn = spans.find((s) => s.to > s.from && m >= s.to && m < s.drawnTo);
  return drawn ? drawn.to - 1 : Math.round(raw / snap) * snap;
}

/** The events going on at a minute of `date`, by their recorded wall-clock start and end (not as drawn). */
export function eventsAt(events: TimelineEvent[], date: string, minute: number): TimelineEvent[] {
  const t = `${date}T${clockOf(Math.min(minute, DAY_MINUTES - 1))}`;
  return events.filter((e) => e.start.slice(0, 16) <= t && t < e.end.slice(0, 16));
}

/** Heart rate in the hour holding the marker. */
export type HeartAt =
  /** `partial`: today's last synced hour, which may still be filling up. */
  | { kind: 'reading'; hour: number; avg: number; min: number | null; max: number | null; typical: number | null; partial: boolean }
  /** No reading in that hour. */
  | { kind: 'none'; hour: number }
  /** Today, after the last hour the phone has sent. */
  | { kind: 'pending'; hour: number }
  /** No reading at all that day (so far, for today). */
  | { kind: 'empty' };

/** A summed metric (steps, active energy) up to the marker. */
export type TotalAt =
  /** The running total over whole hours, by `at`:00 (0–24), against the typical total by then. */
  | { kind: 'by'; at: number; value: number; typical: number | null }
  /** Today, with the marker past every synced reading: the total so far, which may end part-way through an hour, so
   *  there's no typical to compare it with. */
  | { kind: 'so-far'; value: number }
  /** Nothing recorded that day (so far, for today). */
  | { kind: 'empty' };

export type Moment = {
  minute: number;
  events: TimelineEvent[];
  /** Each is missing when the person has no hourly data of that kind at all. */
  heart?: HeartAt;
  steps?: TotalAt;
  energy?: TotalAt;
};

/**
 * What a moment of the day looked like. `live` is the resting position: now for today, when heart rate is the
 * latest reading and the totals are so far; the end of the day for a past day.
 */
export function momentAt(day: DayData | undefined, events: TimelineEvent[], date: string, minute: number, live: boolean): Moment {
  const moment: Moment = { minute, events: eventsAt(events, date, minute) };
  if (!day || day.date !== date) return moment;
  const isToday = day.date === day.today;
  const through = drawThrough(day.date, day.today, day.asOf);
  const { heart_rate: hr, steps, active_energy: energy } = day.metrics;
  if (hr) moment.heart = heartAt(hr, through, isToday, day.asOf, minute, live);
  if (steps) moment.steps = totalAt(steps, through, isToday, day.asOf, minute, live);
  if (energy) moment.energy = totalAt(energy, through, isToday, day.asOf, minute, live);
  return moment;
}

function heartAt(hr: DaySeries, through: number | null, isToday: boolean, asOf: number | null, minute: number, live: boolean): HeartAt {
  const latest = lastReading(hr.hours, through);
  // (No reading at all also covers a day with nothing synced: lastReading is null without a cut-off.)
  if (latest === null && (live || through === null)) return { kind: 'empty' };
  const hour = live ? latest! : Math.min(23, Math.floor(minute / 60));
  if (hour > through!) return { kind: 'pending', hour };
  const avg = hr.hours[hour];
  if (avg === null) return { kind: 'none', hour };
  return { kind: 'reading', hour, avg, min: hr.min?.[hour] ?? null, max: hr.max?.[hour] ?? null, typical: hr.typical[hour], partial: isToday && hour === asOf };
}

function totalAt(series: DaySeries, through: number | null, isToday: boolean, asOf: number | null, minute: number, live: boolean): TotalAt {
  // A day where this metric has no hours at all says so, rather than counting up zeros.
  if (through === null || series.hours.slice(0, through + 1).every((v) => v === null)) return { kind: 'empty' };
  const run = cumulative(series.hours, through);
  // Today's last synced hour may still be filling up; the hours before it are whole.
  const whole = isToday ? asOf! - 1 : 23;
  // The hour boundary at or before the marker; live means now (so far) or the end of a past day.
  const at = live ? 24 : Math.min(24, Math.floor(minute / 60));
  if (at - 1 > whole) return { kind: 'so-far', value: run[through]! };
  if (at === 0) return { kind: 'by', at: 0, value: 0, typical: null };
  return { kind: 'by', at, value: run[at - 1]!, typical: series.typical[at - 1] };
}
