// Every timestamp is kept with the UTC offset it was recorded in, so a day is
// always the wearer's local calendar day, wherever they were at the time.

export type Stamp = { ms: number; offsetMin: number };

const HOUR = 3_600_000;
export const DAY_MS = 24 * HOUR;

// Sleep that ends (or a WHOOP cycle that starts) up to 6h before midnight
// belongs to the next day: the night of the 15th counts toward the 16th.
export const DAY_ROLLOVER_MS = 6 * HOUR;

/** Apple Health export format: "2024-01-15 07:30:00 -0800". */
export function parseAppleDate(s: string): Stamp {
  const m = /^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2}) ([+-])(\d{2})(\d{2})$/.exec(s.trim());
  if (!m) throw new Error(`Unrecognized Apple Health date: ${s}`);
  const [, y, mo, d, h, mi, se, sign, oh, om] = m;
  const offsetMin = (sign === '-' ? -1 : 1) * (Number(oh) * 60 + Number(om));
  const wall = Date.UTC(Number(y), Number(mo) - 1, Number(d), Number(h), Number(mi), Number(se));
  return { ms: wall - offsetMin * 60_000, offsetMin };
}

/** WHOOP timezone_offset format: "-05:00" or "+0530". */
export function parseOffset(s: string | null | undefined): number {
  const m = /^([+-])(\d{2}):?(\d{2})$/.exec((s ?? '').trim());
  if (!m) return 0;
  return (m[1] === '-' ? -1 : 1) * (Number(m[2]) * 60 + Number(m[3]));
}

export function stampFromIso(iso: string, offset: string | null | undefined): Stamp {
  return { ms: Date.parse(iso), offsetMin: parseOffset(offset) };
}

function wall(st: Stamp, shiftMs = 0) {
  return new Date(st.ms + st.offsetMin * 60_000 + shiftMs);
}

/** Local calendar date (YYYY-MM-DD) of the stamp. */
export function localDate(st: Stamp, shiftMs = 0): string {
  return wall(st, shiftMs).toISOString().slice(0, 10);
}

/** ISO string carrying the local offset, e.g. 2024-01-15T07:30:00-08:00. */
export function toLocalIso(st: Stamp): string {
  const sign = st.offsetMin < 0 ? '-' : '+';
  const abs = Math.abs(st.offsetMin);
  const off = `${sign}${String(Math.floor(abs / 60)).padStart(2, '0')}:${String(abs % 60).padStart(2, '0')}`;
  return wall(st).toISOString().slice(0, 19) + off;
}

export function addDays(date: string, days: number): string {
  return new Date(Date.parse(date + 'T00:00:00Z') + days * DAY_MS).toISOString().slice(0, 10);
}

export function todayLocal(): string {
  const now = new Date();
  return localDate({ ms: now.getTime(), offsetMin: -now.getTimezoneOffset() });
}
