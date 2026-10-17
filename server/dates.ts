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

/** Local hour (0–23) of the stamp. */
export function localHour(st: Stamp): number {
  return wall(st).getUTCHours();
}

/**
 * The UTC offset an IANA time zone had at an instant, e.g. -300 for America/Chicago in summer. Apple's
 * export prints every timestamp with one fixed offset (today's), so the historical local hour has to come
 * from the zone instead. Cached per hour: an import asks about millions of samples but only ~80k hours.
 */
export function zoneOffsets(timeZone: string): (ms: number) => number {
  const fmt = new Intl.DateTimeFormat('en-US', { timeZone, hourCycle: 'h23', year: 'numeric', month: 'numeric', day: 'numeric', hour: 'numeric', minute: 'numeric' });
  const cache = new Map<number, number>();
  return (ms) => {
    const key = Math.floor(ms / HOUR);
    let off = cache.get(key);
    if (off === undefined) {
      const at = key * HOUR;
      const p = Object.fromEntries(fmt.formatToParts(new Date(at)).map((x) => [x.type, x.value]));
      const wallMs = Date.UTC(Number(p.year), Number(p.month) - 1, Number(p.day), Number(p.hour), Number(p.minute));
      off = Math.round((wallMs - at) / 60_000);
      cache.set(key, off);
    }
    return off;
  };
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

/**
 * Today's date in the user's time zone. The hosted server runs in UTC, so "today" must come from the
 * zone the dashboard reports (stored as a setting), not the server clock. Falls back to the machine's zone.
 */
export function todayLocal(timeZone?: string): string {
  if (timeZone) {
    try {
      // en-CA formats as YYYY-MM-DD.
      return new Intl.DateTimeFormat('en-CA', { timeZone, year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date());
    } catch {
      // Unknown zone name: fall through to the machine's zone.
    }
  }
  const now = new Date();
  return localDate({ ms: now.getTime(), offsetMin: -now.getTimezoneOffset() });
}
