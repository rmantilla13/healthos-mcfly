// Helpers for the Day view: one day's readings hour by hour, from GET /api/day (DayData in shared/types.ts).

export const HOURS = 24;

/**
 * The last hour to draw. A past day is complete, so it runs to 11 PM. Today stops at the latest hour that
 * has synced, so a lagging phone doesn't read as a flat, inactive afternoon.
 */
export function drawThrough(date: string, today: string, asOf: number | null): number | null {
  if (asOf === null) return null;
  return date < today ? HOURS - 1 : asOf;
}

/** Running total by the end of each hour, through `through`. Hours without readings add nothing; later hours are null. */
export function cumulative(hours: (number | null)[], through: number | null): (number | null)[] {
  let sum = 0;
  return hours.map((v, h) => (through !== null && h <= through ? (sum += v ?? 0) : null));
}

/** The latest hour, at or before `through`, that has a reading. */
export function lastReading(hours: (number | null)[], through: number | null): number | null {
  if (through === null) return null;
  for (let h = Math.min(through, hours.length - 1); h >= 0; h--) if (hours[h] !== null) return h;
  return null;
}

/** Lowest and highest of the non-null values, or null when there are none. */
export function extent(...lists: ((number | null)[] | undefined)[]): [number, number] | null {
  const vs = lists.flatMap((l) => l ?? []).filter((v): v is number => v !== null && Number.isFinite(v));
  return vs.length ? [Math.min(...vs), Math.max(...vs)] : null;
}

const hourFormat = new Intl.DateTimeFormat(undefined, { hour: 'numeric', timeZone: 'UTC' });

/** "2 PM" (or the locale's own form) for hour 0–24; 24 is midnight at the end of the day. */
export const hourLabel = (h: number) => hourFormat.format(Date.UTC(2000, 0, 1, h % HOURS));

/** "2 PM–3 PM" for the hour starting at h. */
export const hourSpan = (h: number) => `${hourLabel(h)}–${hourLabel(h + 1)}`;
