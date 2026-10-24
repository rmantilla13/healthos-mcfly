// Reads a Fitbit export (Google Takeout → Fitbit, or Google Health once an account moved to Google) in the browser,
// one file at a time, into per-day readings for POST /api/fitbit/import (shared/fitbit.ts). Pure functions, so the
// Web Worker (fitbit.worker.ts) and the tests (test/fitbit-reader.test.ts) run the same code.
//
// Google doesn't document the export's layout, and it has changed (Global Export Data JSON, then *_GoogleData CSVs,
// then one folder per kind), so files are recognised by name, wherever they sit, never by a fixed path:
//   heart_rate-DATE.json            [{dateTime: "MM/DD/YY HH:MM:SS" (UTC), value: {bpm, confidence}}]
//   heart_rate_DATE.csv             timestamp (UTC, Z), beats per minute[, data source]
//   resting_heart_rate-DATE.json    [{dateTime, value: {date: "MM/DD/YY" | null, value, error}}]; 0 means no reading
//   daily_resting_heart_rate*.csv   timestamp (the local date at T00:00:00Z), beats per minute
//   sleep-DATE.json                 the sleep logs: dateOfSleep (wake date), startTime/endTime (local, no offset),
//                                   minutesAsleep, timeInBed, efficiency, type stages|classic, mainSleep, levels
//   UserSleeps_DATE.csv, UserSleepStages_DATE.csv   the newer sleep tables, joined on sleep_id (UTC + offsets)
//   weight-DATE.json                [{weight (the account's unit, unstated), fat, date "MM/DD/YY", time}]
//   weight*.csv, body_fat_DATE.csv  timestamp (UTC), weight grams | body fat percentage
//   steps-DATE.json, steps_DATE.csv per-minute counts (UTC); a CSV can repeat a minute per data source
//   Daily Heart Rate Variability Summary - *.csv   timestamp, rmssd, nremhr, entropy
//   Daily Respiratory Rate Summary - *.csv, respiratory_rate_sleep_summary_*.csv   breaths per minute
//   Daily SpO2 - *.csv              timestamp, average_value, lower_bound, upper_bound
// Anything else (calories, badges, the profile, settings…) is never opened.
import type { FitbitChunk, FitbitFinish, FitbitMetric, FitbitSleepSegment } from '../../shared/fitbit.ts';
import { FITBIT_CHUNK, FITBIT_FIRST_DATE, inFitbitRange } from '../../shared/fitbitRanges.ts';

export type FitbitFileKind =
  | 'heart_rate_json'
  | 'heart_rate_csv'
  | 'resting_hr_json'
  | 'resting_hr_csv'
  | 'sleep_json'
  | 'sleeps_csv'
  | 'sleep_stages_csv'
  | 'weight_json'
  | 'weight_csv'
  | 'body_fat_csv'
  | 'steps_json'
  | 'steps_csv'
  | 'hrv_csv'
  | 'resp_csv'
  | 'spo2_csv';

const JSON_KINDS: Record<string, FitbitFileKind> = {
  heart_rate: 'heart_rate_json',
  resting_heart_rate: 'resting_hr_json',
  sleep: 'sleep_json',
  weight: 'weight_json',
  steps: 'steps_json',
};
const CSV_KINDS: Record<string, FitbitFileKind> = {
  heart_rate: 'heart_rate_csv',
  daily_resting_heart_rate: 'resting_hr_csv',
  usersleeps: 'sleeps_csv',
  usersleepstages: 'sleep_stages_csv',
  weight: 'weight_csv',
  body_fat: 'body_fat_csv',
  steps: 'steps_csv',
  daily_heart_rate_variability_summary: 'hrv_csv',
  daily_respiratory_rate_summary: 'resp_csv',
  respiratory_rate_sleep_summary: 'resp_csv',
  daily_spo2: 'spo2_csv',
};
/** The 2026 layout puts each kind in its own folder under Physical Activity_GoogleData ("Heart Rate/…"). */
const CSV_FOLDERS: Record<string, FitbitFileKind> = {
  heart_rate: 'heart_rate_csv',
  daily_resting_heart_rate: 'resting_hr_csv',
  weight: 'weight_csv',
  body_fat: 'body_fat_csv',
  steps: 'steps_csv',
};

/** A file or folder name without its dates and extension, in lower_snake_case: "Daily SpO2 - 2025-12-19…" → daily_spo2. */
const stem = (name: string) =>
  name
    .replace(/\.(json|csv)$/i, '')
    .replace(/\d{4}-\d{2}.*$/, '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '_')
    .replace(/^_+|_+$/g, '');

/** What a file in the export holds, from its name (and, for the newest layout, its folder); null for anything else. */
export function fitbitFileKind(path: string): FitbitFileKind | null {
  const parts = path.replace(/\\/g, '/').split('/').filter(Boolean);
  const base = parts.at(-1) ?? '';
  // macOS adds "._name" copies and a __MACOSX folder to zips it makes; they aren't the data.
  if (base.startsWith('.') || parts.includes('__MACOSX')) return null;
  const ext = /\.(json|csv)$/i.exec(base)?.[1].toLowerCase();
  if (ext === 'json') return JSON_KINDS[stem(base)] ?? null;
  if (ext !== 'csv') return null;
  const byName = CSV_KINDS[stem(base)];
  if (byName) return byName;
  if (parts.length >= 3 && stem(parts.at(-3)!) === 'physical_activity_googledata') return CSV_FOLDERS[stem(parts.at(-2)!)] ?? null;
  return null;
}

// ---------- time ----------

const HOUR_MS = 3_600_000;
/** A nightly reading stamped up to 6 h before midnight belongs to the next day, as the server dates sleep (server/dates.ts). */
const ROLLOVER_MS = 6 * HOUR_MS;

/** The UTC offset, in minutes, that an IANA time zone had at an instant; cached per hour. */
export function zoneOffsets(timeZone: string): (ms: number) => number {
  const fmt = new Intl.DateTimeFormat('en-US', { timeZone, hourCycle: 'h23', year: 'numeric', month: 'numeric', day: 'numeric', hour: 'numeric', minute: 'numeric' });
  const cache = new Map<number, number>();
  return (ms) => {
    const key = Math.floor(ms / HOUR_MS);
    let off = cache.get(key);
    if (off === undefined) {
      const at = key * HOUR_MS;
      const p = Object.fromEntries(fmt.formatToParts(new Date(at)).map((x) => [x.type, x.value]));
      off = Math.round((Date.UTC(Number(p.year), Number(p.month) - 1, Number(p.day), Number(p.hour), Number(p.minute)) - at) / 60_000);
      cache.set(key, off);
    }
    return off;
  };
}

const pad = (n: number) => String(n).padStart(2, '0');
const offsetText = (min: number) => `${min < 0 ? '-' : '+'}${pad(Math.floor(Math.abs(min) / 60))}:${pad(Math.abs(min) % 60)}`;
/** An instant as local ISO with its offset: 2024-03-20T22:04:00-07:00. */
const isoAt = (ms: number, offMin: number) => new Date(ms + offMin * 60_000).toISOString().slice(0, 19) + offsetText(offMin);
const dateAt = (ms: number, offMin: number) => new Date(ms + offMin * 60_000).toISOString().slice(0, 10);
const validDate = (d: string) => /^\d{4}-\d{2}-\d{2}$/.test(d) && new Date(Date.parse(d + 'T00:00:00Z')).toISOString().slice(0, 10) === d;

/** "MM/DD/YY HH:MM:SS" (or just the date) as wall-clock parts' UTC milliseconds. */
function fitbitWall(s: string): number | null {
  const m = /^(\d{2})\/(\d{2})\/(\d{2})(?: (\d{2}):(\d{2})(?::(\d{2}))?)?$/.exec(s.trim());
  if (!m) return null;
  const [, mo, d, y, h = '0', mi = '0', se = '0'] = m;
  return Date.UTC(2000 + Number(y), Number(mo) - 1, Number(d), Number(h), Number(mi), Number(se));
}

type Stamp = { wall: number; zone: 'utc' | 'none' | number };
/** "2024-10-27T00:00:04Z", "…T00:00:04.123456Z", "2024-03-20T22:04:00.000", "…+05:30": the wall clock and what it's in. */
function isoStamp(s: string): Stamp | null {
  const m = /^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2}))?(?:\.\d+)?)?\s*(Z|[+-]\d{2}:?\d{2})?$/i.exec(s.trim());
  if (!m) return null;
  const [, y, mo, d, h = '0', mi = '0', se = '0', z] = m;
  const wall = Date.UTC(Number(y), Number(mo) - 1, Number(d), Number(h), Number(mi), Number(se));
  if (!z) return { wall, zone: 'none' };
  if (z.toUpperCase() === 'Z') return { wall, zone: 'utc' };
  const om = /([+-])(\d{2}):?(\d{2})/.exec(z)!;
  return { wall, zone: (om[1] === '-' ? -1 : 1) * (Number(om[2]) * 60 + Number(om[3])) };
}

function offsetMin(s: string | undefined): number | null {
  const m = /^\s*([+-])(\d{2}):?(\d{2})\s*$/.exec(s ?? '');
  return m ? (m[1] === '-' ? -1 : 1) * (Number(m[2]) * 60 + Number(m[3])) : null;
}

// ---------- CSV ----------

/** Rows as objects keyed by the trimmed, lower-case header. Quoted cells are handled; Fitbit pads cells with spaces. */
export function parseCsv(text: string): Record<string, string>[] {
  const rows: string[][] = [];
  if (!text.includes('"')) {
    for (const line of text.split(/\r?\n/)) if (line.trim()) rows.push(line.split(','));
  } else {
    let row: string[] = [];
    let cell = '';
    let quoted = false;
    for (let i = 0; i < text.length; i++) {
      const ch = text[i];
      if (quoted) {
        if (ch === '"' && text[i + 1] === '"') {
          cell += '"';
          i++;
        } else if (ch === '"') quoted = false;
        else cell += ch;
      } else if (ch === '"') quoted = true;
      else if (ch === ',') {
        row.push(cell);
        cell = '';
      } else if (ch === '\n' || ch === '\r') {
        if (ch === '\r' && text[i + 1] === '\n') i++;
        row.push(cell);
        if (row.some((c) => c.trim())) rows.push(row);
        row = [];
        cell = '';
      } else cell += ch;
    }
    row.push(cell);
    if (row.some((c) => c.trim())) rows.push(row);
  }
  const [head, ...body] = rows;
  if (!head) return [];
  const keys = head.map((h) => h.replace(/^\uFEFF/, '').trim().toLowerCase());
  return body.map((r) => Object.fromEntries(keys.map((k, i) => [k, (r[i] ?? '').trim()])));
}

/** The first header that contains every one of these words. */
const column = (row: Record<string, string> | undefined, ...words: string[]) => (row ? Object.keys(row).find((k) => words.every((w) => k.includes(w))) : undefined);
const number = (v: unknown) => (typeof v === 'number' ? v : typeof v === 'string' && v.trim() !== '' ? Number(v) : NaN);

// ---------- reading ----------

type Stat = { sum: number; n: number; min: number; max: number };
type Dated = { at: number; value: number };
type SleepLog = {
  start: number;
  end: number;
  offStart: number;
  offEnd: number;
  main: boolean;
  asleepMin: number;
  inBedMin: number;
  efficiency: number | null;
  /** Stage minutes, for a night recorded in stages. */
  stages: { deep: number; light: number; rem: number; awake: number } | null;
  segments: FitbitSleepSegment[];
};

/** Everything found in the export, by local date, before the weight unit is known. Plain data: it crosses from the worker. */
export type FitbitFound = {
  /** Per day: heart rate from the JSON files, or from the CSVs' best-covered data source. */
  heart: Record<string, Stat>;
  resting: Record<string, number>;
  hrv: Record<string, number>;
  spo2: Record<string, number>;
  resp: Record<string, number>;
  steps: Record<string, number>;
  /** The day's last weigh-in in the export's own unit (the JSON doesn't say which). */
  weightExport: Record<string, number>;
  /** The day's last weigh-in from a CSV that gives grams, in kg. */
  weightKg: Record<string, number>;
  bodyFat: Record<string, number>;
  /** One night per wake date: the main sleep's timeline, with naps' minutes added to the total. */
  nights: Record<string, { start: string; end: string; asleepMin: number; inBedMin: number; efficiency: number | null; stages: SleepLog['stages']; segments: FitbitSleepSegment[] }>;
  /** kg or lb when weigh-ins in both forms agree on a unit; null when they can't tell. */
  weightUnit: 'kg' | 'lb' | null;
  files: number;
  /** Files with a known name that couldn't be read (not JSON, an unexpected shape). */
  skipped: number;
};

const STAGE: Record<string, FitbitSleepSegment['stage']> = { wake: 'awake', awake: 'awake', restless: 'awake', asleep: 'asleep', light: 'light', deep: 'deep', rem: 'rem' };

/** Collects the export's files one by one (in any order) and resolves them into FitbitFound. */
export class FitbitReader {
  private off: (ms: number) => number;
  private hrJson = new Map<string, Stat>();
  private hrCsv = new Map<string, Map<string, Stat>>();
  private stepsJson = new Map<string, number>();
  private stepsCsv = new Map<string, Map<string, number>>();
  private resting = new Map<string, number>();
  private hrv = new Map<string, number>();
  private spo2 = new Map<string, number>();
  private resp = new Map<string, number>();
  private weightJson = new Map<string, Dated>();
  private weightCsv = new Map<string, Dated>();
  private fat = new Map<string, Dated>();
  private sleepJson = new Map<string, SleepLog[]>();
  private sleepRows = new Map<string, Record<string, string>>();
  private stageRows = new Map<string, Record<string, string>[]>();
  private files = 0;
  private skipped = 0;

  constructor(timeZone: string) {
    this.off = zoneOffsets(timeZone);
  }

  /** The local date of an instant given in UTC (or with its own offset). */
  private localDate(st: Stamp, shiftMs = 0): string {
    if (st.zone === 'none') return new Date(st.wall + shiftMs).toISOString().slice(0, 10);
    const ms = st.zone === 'utc' ? st.wall : st.wall - st.zone * 60_000;
    return dateAt(ms + shiftMs, st.zone === 'utc' ? this.off(ms) : st.zone);
  }

  /** A local wall-clock time with no offset as an instant, in the person's zone (twice, for the hour clocks change). */
  private wallMs(wall: number): number {
    const first = wall - this.off(wall) * 60_000;
    return wall - this.off(first) * 60_000;
  }

  /** A stamp as an instant: UTC, its own offset, or (with neither) the person's zone. */
  private instant(st: Stamp): number {
    return st.zone === 'utc' ? st.wall : typeof st.zone === 'number' ? st.wall - st.zone * 60_000 : this.wallMs(st.wall);
  }

  /**
   * A daily file's date: the date part when stamped at midnight or without a zone (Fitbit writes the local date that
   * way), else the local date of the instant, rolled forward from the evening so a night counts toward its morning.
   */
  private dailyDate(ts: string): string | null {
    const st = isoStamp(ts);
    if (!st) return null;
    const midnight = st.wall % 86_400_000 === 0;
    return midnight || st.zone === 'none' ? new Date(st.wall).toISOString().slice(0, 10) : this.localDate(st, ROLLOVER_MS);
  }

  /** Reads one file. False when its name is unknown or its contents aren't what that name should hold. */
  add(path: string, text: string): boolean {
    const kind = fitbitFileKind(path);
    if (!kind) return false;
    try {
      const ok = kind.endsWith('_json') ? this.addJson(kind, JSON.parse(text)) : this.addCsv(kind, parseCsv(text));
      if (ok) this.files++;
      else this.skipped++;
      return ok;
    } catch {
      this.skipped++;
      return false;
    }
  }

  private addJson(kind: FitbitFileKind, data: unknown): boolean {
    if (!Array.isArray(data)) return false;
    for (const raw of data as Record<string, unknown>[]) {
      if (!raw || typeof raw !== 'object') continue;
      if (kind === 'heart_rate_json') {
        const wall = fitbitWall(String(raw.dateTime ?? ''));
        const bpm = number((raw.value as { bpm?: unknown } | undefined)?.bpm);
        if (wall !== null && Number.isFinite(bpm)) this.stat(this.hrJson, this.localDate({ wall, zone: 'utc' }), bpm);
      } else if (kind === 'steps_json') {
        const wall = fitbitWall(String(raw.dateTime ?? ''));
        const n = number(raw.value);
        if (wall !== null && n > 0) {
          const d = this.localDate({ wall, zone: 'utc' });
          this.stepsJson.set(d, (this.stepsJson.get(d) ?? 0) + n);
        }
      } else if (kind === 'resting_hr_json') {
        const v = raw.value as { date?: unknown; value?: unknown } | undefined;
        // Fitbit pads the file with {date: null, value: 0} for days without a reading.
        const wall = typeof v?.date === 'string' ? fitbitWall(v.date) : v?.date === undefined ? fitbitWall(String(raw.dateTime ?? '')) : null;
        const bpm = number(v?.value);
        if (wall !== null && bpm > 0) this.resting.set(new Date(wall).toISOString().slice(0, 10), bpm);
      } else if (kind === 'weight_json') {
        const wall = fitbitWall(`${String(raw.date ?? '')} ${String(raw.time ?? '00:00:00')}`);
        const w = number(raw.weight);
        if (wall === null || !(w > 0)) continue;
        const d = new Date(wall).toISOString().slice(0, 10);
        this.latest(this.weightJson, d, wall, w);
        const f = number(raw.fat);
        if (f > 0) this.latest(this.fat, d, wall, f);
      } else if (kind === 'sleep_json') {
        this.addSleepLog(raw);
      }
    }
    return true;
  }

  private addSleepLog(raw: Record<string, unknown>) {
    const date = String(raw.dateOfSleep ?? '');
    const s = isoStamp(String(raw.startTime ?? ''));
    const e = isoStamp(String(raw.endTime ?? ''));
    if (!validDate(date) || !s || !e) return;
    const start = this.instant(s);
    const end = this.instant(e);
    if (!(end > start)) return;
    const levels = (raw.levels ?? {}) as { summary?: Record<string, { minutes?: unknown }>; data?: { dateTime?: unknown; level?: unknown; seconds?: unknown }[] };
    const sum = levels.summary ?? {};
    const mins = (k: string) => number(sum[k]?.minutes);
    const staged = raw.type === 'stages' && Number.isFinite(mins('deep'));
    const segments: FitbitSleepSegment[] = [];
    for (const d of Array.isArray(levels.data) ? levels.data : []) {
      const at = isoStamp(String(d.dateTime ?? ''));
      const stage = STAGE[String(d.level)];
      const secs = number(d.seconds);
      if (!at || !stage || !(secs > 0)) continue;
      const from = this.instant(at);
      const to = from + secs * 1000;
      segments.push({ start: isoAt(from, this.off(from)), end: isoAt(to, this.off(to)), stage });
    }
    const log: SleepLog = {
      start,
      end,
      offStart: this.off(start),
      offEnd: this.off(end),
      main: raw.mainSleep === true,
      asleepMin: Math.max(0, number(raw.minutesAsleep) || 0),
      inBedMin: Math.max(0, number(raw.timeInBed) || 0),
      efficiency: Number.isFinite(number(raw.efficiency)) ? number(raw.efficiency) : null,
      stages: staged ? { deep: mins('deep') || 0, light: mins('light') || 0, rem: mins('rem') || 0, awake: mins('wake') || 0 } : null,
      segments,
    };
    const list = this.sleepJson.get(date) ?? [];
    list.push(log);
    this.sleepJson.set(date, list);
  }

  private addCsv(kind: FitbitFileKind, rows: Record<string, string>[]): boolean {
    const first = rows[0];
    if (!first) return true; // A header-only file (no readings yet) is still a file of that kind.
    if (kind === 'sleeps_csv') {
      if (!('sleep_id' in first && 'sleep_start' in first && 'sleep_end' in first)) return false;
      for (const r of rows) if (r.sleep_id) this.sleepRows.set(r.sleep_id, r);
      return true;
    }
    if (kind === 'sleep_stages_csv') {
      if (!('sleep_id' in first && 'sleep_stage_start' in first)) return false;
      for (const r of rows) {
        const list = this.stageRows.get(r.sleep_id) ?? [];
        list.push(r);
        this.stageRows.set(r.sleep_id, list);
      }
      return true;
    }
    if (!('timestamp' in first)) return false;
    const source = column(first, 'data source') ?? column(first, 'data_source');
    if (kind === 'heart_rate_csv' || kind === 'steps_csv') {
      const col = kind === 'heart_rate_csv' ? (column(first, 'beats per minute') ?? column(first, 'bpm')) : column(first, 'steps');
      if (!col) return false;
      for (const r of rows) {
        const st = isoStamp(r.timestamp);
        const v = number(r[col]);
        if (!st || !Number.isFinite(v)) continue;
        const d = this.localDate(st);
        const src = (source && r[source]) || '';
        if (kind === 'heart_rate_csv') {
          const bySource = this.hrCsv.get(d) ?? new Map<string, Stat>();
          this.hrCsv.set(d, bySource);
          this.stat(bySource, src, v);
        } else if (v > 0) {
          const bySource = this.stepsCsv.get(d) ?? new Map<string, number>();
          this.stepsCsv.set(d, bySource);
          bySource.set(src, (bySource.get(src) ?? 0) + v);
        }
      }
      return true;
    }
    if (kind === 'weight_csv' || kind === 'body_fat_csv') {
      const col = kind === 'weight_csv' ? column(first, 'weight', 'gram') : (column(first, 'fat') ?? column(first, 'percent'));
      if (!col) return false;
      for (const r of rows) {
        const st = isoStamp(r.timestamp);
        const v = number(r[col]);
        if (!st || !(v > 0)) continue;
        const d = this.localDate(st);
        if (kind === 'weight_csv') this.latest(this.weightCsv, d, st.wall, v / 1000);
        else this.latest(this.fat, d, st.wall, v);
      }
      return true;
    }
    // One reading a day (or a night): the column is chosen by name, the date from the timestamp.
    const col =
      kind === 'resting_hr_csv'
        ? (column(first, 'beats per minute') ?? column(first, 'resting'))
        : kind === 'hrv_csv'
          ? column(first, 'rmssd')
          : kind === 'spo2_csv'
            ? (column(first, 'average_value') ?? column(first, 'average'))
            : (column(first, 'full sleep', 'breath') ?? column(first, 'daily_respiratory_rate') ?? column(first, 'breathing_rate') ?? column(first, 'respiratory_rate'));
    if (!col) return false;
    const into = kind === 'resting_hr_csv' ? this.resting : kind === 'hrv_csv' ? this.hrv : kind === 'spo2_csv' ? this.spo2 : this.resp;
    for (const r of rows) {
      const d = this.dailyDate(r.timestamp);
      let v = number(r[col]);
      if (!d || !(v > 0)) continue;
      // The newer breathing file's header says milli-breaths; when the numbers are, bring them to breaths a minute.
      if (kind === 'resp_csv' && v > 100) v /= 1000;
      into.set(d, v);
    }
    return true;
  }

  private stat(map: Map<string, Stat>, key: string, v: number) {
    const s = map.get(key);
    if (s) {
      s.sum += v;
      s.n++;
      if (v < s.min) s.min = v;
      if (v > s.max) s.max = v;
    } else map.set(key, { sum: v, n: 1, min: v, max: v });
  }

  private latest(map: Map<string, Dated>, date: string, at: number, value: number) {
    const prev = map.get(date);
    if (!prev || at >= prev.at) map.set(date, { at, value });
  }

  /** The newer sleep tables, as logs by wake date (local, rolled forward like the server's). */
  private csvNights(): Map<string, SleepLog[]> {
    const out = new Map<string, SleepLog[]>();
    for (const [id, r] of this.sleepRows) {
      const s = isoStamp(r.sleep_start);
      const e = isoStamp(r.sleep_end);
      if (!s || !e) continue;
      const start = this.instant(s);
      const end = this.instant(e);
      if (!(end > start)) continue;
      const offStart = offsetMin(r.start_utc_offset) ?? this.off(start);
      const offEnd = offsetMin(r.end_utc_offset) ?? this.off(end);
      const segments: FitbitSleepSegment[] = [];
      const totals = { deep: 0, light: 0, rem: 0, awake: 0 };
      for (const g of this.stageRows.get(id) ?? []) {
        const gs = isoStamp(g.sleep_stage_start);
        const ge = isoStamp(g.sleep_stage_end);
        const stage = STAGE[(g.sleep_stage_type ?? '').toLowerCase()];
        if (!gs || !ge || !stage) continue;
        const from = this.instant(gs);
        const to = this.instant(ge);
        if (!(to > from)) continue;
        const o = offsetMin(g.start_utc_offset) ?? offStart;
        segments.push({ start: isoAt(from, o), end: isoAt(to, offsetMin(g.end_utc_offset) ?? o), stage });
        if (stage !== 'asleep') totals[stage] += (to - from) / 60_000;
      }
      const staged = totals.deep + totals.light + totals.rem > 0;
      const date = dateAt(end + ROLLOVER_MS, offEnd);
      const log: SleepLog = {
        start,
        end,
        offStart,
        offEnd,
        main: false,
        asleepMin: Math.max(0, number(r.minutes_asleep) || 0),
        inBedMin: Math.max(0, number(r.minutes_in_sleep_period) || 0),
        efficiency: null,
        stages: staged ? totals : null,
        segments: segments.sort((a, b) => Date.parse(a.start) - Date.parse(b.start)),
      };
      const list = out.get(date) ?? [];
      list.push(log);
      out.set(date, list);
    }
    return out;
  }

  result(): FitbitFound {
    const heart: FitbitFound['heart'] = {};
    for (const [d, s] of this.hrJson) heart[d] = s;
    for (const [d, bySource] of this.hrCsv) {
      // The JSON files are Fitbit's own merged stream; a CSV's sources overlap, so take the best-covered one alone.
      if (heart[d]) continue;
      const best = [...bySource.values()].sort((a, b) => b.n - a.n)[0];
      if (best) heart[d] = best;
    }
    const steps: Record<string, number> = Object.fromEntries(this.stepsJson);
    for (const [d, bySource] of this.stepsCsv) if (steps[d] === undefined) steps[d] = Math.max(...bySource.values());

    const nights: FitbitFound['nights'] = {};
    const csv = this.csvNights();
    for (const [date, logs] of [...csv, ...this.sleepJson]) {
      // The JSON logs come last, so where both have a night, Fitbit's own (with its stages and efficiency) wins.
      const main = logs.find((l) => l.main) ?? [...logs].sort((a, b) => b.end - b.start - (a.end - a.start))[0];
      nights[date] = {
        start: isoAt(main.start, main.offStart),
        end: isoAt(main.end, main.offEnd),
        // Naps add to the day's total sleep; time in bed, stages and efficiency are the main sleep's, as for WHOOP.
        asleepMin: logs.reduce((t, l) => t + l.asleepMin, 0),
        inBedMin: main.inBedMin,
        efficiency: main.efficiency,
        stages: main.stages,
        segments: main.segments,
      };
    }

    const weightExport: Record<string, number> = {};
    for (const [d, w] of this.weightJson) weightExport[d] = w.value;
    const weightKg: Record<string, number> = {};
    for (const [d, w] of this.weightCsv) weightKg[d] = w.value;
    const bodyFat: Record<string, number> = {};
    for (const [d, f] of this.fat) bodyFat[d] = f.value;

    return {
      heart,
      resting: Object.fromEntries(this.resting),
      hrv: Object.fromEntries(this.hrv),
      spo2: Object.fromEntries(this.spo2),
      resp: Object.fromEntries(this.resp),
      steps,
      weightExport,
      weightKg,
      bodyFat,
      nights,
      weightUnit: detectUnit(weightExport, weightKg),
      files: this.files,
      skipped: this.skipped,
    };
  }
}

export const LB_PER_KG = 2.20462;

/** Where a day has a weigh-in in grams too, their ratio says what unit the JSON's weights are in. */
function detectUnit(exported: Record<string, number>, kg: Record<string, number>): 'kg' | 'lb' | null {
  const ratios = Object.keys(exported)
    .filter((d) => kg[d])
    .map((d) => exported[d] / kg[d])
    .sort((a, b) => a - b);
  if (!ratios.length) return null;
  const mid = ratios[Math.floor(ratios.length / 2)];
  if (Math.abs(mid - 1) < 0.03) return 'kg';
  if (Math.abs(mid - LB_PER_KG) < 0.07) return 'lb';
  return null;
}

/** The middle of the export's own weigh-ins, to ask about: "about 172 — kilograms or pounds?". */
export function typicalWeight(found: FitbitFound): number | null {
  const ws = Object.values(found.weightExport).sort((a, b) => a - b);
  return ws.length ? ws[Math.floor(ws.length / 2)] : null;
}

/** The weight unit still to ask: weigh-ins with no unit, which a grams file didn't settle. */
export const needsWeightUnit = (found: FitbitFound) => found.weightUnit === null && Object.keys(found.weightExport).some((d) => found.weightKg[d] === undefined);

// ---------- rows, preview, chunks ----------

export type FitbitDay = { date: string; metric: FitbitMetric; value: number };
export type FitbitNight = NonNullable<FitbitChunk['sleep']>[number];

const round = (v: number, places: number) => Math.round(v * 10 ** places) / 10 ** places;
/** Fewer heart-rate samples than this in a day is a strap put on for a minute, not a day's heart rate. */
const MIN_HR_SAMPLES = 10;

/**
 * The readings to send, in stored units, each within the ranges the server accepts, from 2008 to today. Weigh-ins with
 * no unit are left out until it's given (weightUnit), and a day's grams reading wins over the unitless one.
 */
export function fitbitRows(found: FitbitFound, opts: { weightUnit: 'kg' | 'lb' | null; today: string }): { daily: FitbitDay[]; sleep: FitbitNight[] } {
  const daily: FitbitDay[] = [];
  const ok = (date: string) => date >= FITBIT_FIRST_DATE && date <= opts.today;
  const push = (date: string, metric: FitbitMetric, value: number, places: number) => {
    const v = round(value, places);
    if (ok(date) && inFitbitRange(metric, v)) daily.push({ date, metric, value: v });
  };
  for (const [d, s] of Object.entries(found.heart)) {
    if (s.n < MIN_HR_SAMPLES) continue;
    push(d, 'hr_avg', s.sum / s.n, 1);
    push(d, 'hr_min', s.min, 0);
    push(d, 'hr_max', s.max, 0);
  }
  for (const [d, v] of Object.entries(found.resting)) push(d, 'resting_hr', v, 1);
  for (const [d, v] of Object.entries(found.hrv)) push(d, 'hrv_rmssd', v, 1);
  for (const [d, v] of Object.entries(found.spo2)) push(d, 'spo2', v, 1);
  for (const [d, v] of Object.entries(found.resp)) push(d, 'resp_rate', v, 1);
  for (const [d, v] of Object.entries(found.steps)) push(d, 'steps', v, 0);
  const unit = found.weightUnit ?? opts.weightUnit;
  const weights: Record<string, number> = {};
  if (unit) for (const [d, w] of Object.entries(found.weightExport)) weights[d] = unit === 'lb' ? w / LB_PER_KG : w;
  Object.assign(weights, found.weightKg);
  for (const [d, kg] of Object.entries(weights)) push(d, 'weight', kg, 2);
  for (const [d, v] of Object.entries(found.bodyFat)) push(d, 'body_fat', v, 1);

  const sleep: FitbitNight[] = [];
  for (const [d, n] of Object.entries(found.nights)) {
    // A "night" longer than a day is a log gone wrong (a timer left running), not sleep.
    const span = Date.parse(n.end) - Date.parse(n.start);
    if (!ok(d) || !(n.asleepMin > 0) || !(span > 0 && span <= 86_400_000)) continue;
    push(d, 'sleep_hours', n.asleepMin / 60, 3);
    if (n.inBedMin > 0) push(d, 'sleep_in_bed', n.inBedMin / 60, 3);
    if (n.efficiency !== null) push(d, 'sleep_efficiency', n.efficiency, 0);
    if (n.stages) {
      push(d, 'sleep_deep', n.stages.deep / 60, 3);
      push(d, 'sleep_rem', n.stages.rem / 60, 3);
      push(d, 'sleep_light', n.stages.light / 60, 3);
      push(d, 'sleep_awake', n.stages.awake / 60, 3);
    }
    sleep.push({ date: d, start: n.start, end: n.end, segments: n.segments.slice(0, FITBIT_CHUNK.stagesPerNight) });
  }
  daily.sort((a, b) => (a.date < b.date ? -1 : a.date > b.date ? 1 : 0));
  sleep.sort((a, b) => (a.date < b.date ? -1 : 1));
  return { daily, sleep };
}

export type FitbitPreview = {
  heartDays: number;
  restingDays: number;
  sleepNights: number;
  hrvNights: number;
  spo2Nights: number;
  respNights: number;
  stepDays: number;
  /** Days with a weigh-in: the day's last one is kept. */
  weighIns: number;
  days: number;
  firstDate: string | null;
  lastDate: string | null;
};

/** What the import would bring in, counted from the rows it would send. */
export function fitbitPreview(rows: { daily: FitbitDay[] }): FitbitPreview {
  const count = (metric: FitbitMetric) => rows.daily.filter((r) => r.metric === metric).length;
  const dates = [...new Set(rows.daily.map((r) => r.date))].sort();
  return {
    heartDays: count('hr_avg'),
    restingDays: count('resting_hr'),
    sleepNights: count('sleep_hours'),
    hrvNights: count('hrv_rmssd'),
    spo2Nights: count('spo2'),
    respNights: count('resp_rate'),
    stepDays: count('steps'),
    weighIns: count('weight'),
    days: dates.length,
    firstDate: dates[0] ?? null,
    lastDate: dates.at(-1) ?? null,
  };
}

/**
 * The rows in chunks of whole days, each within what the server takes (FITBIT_CHUNK: bytes, rows and nights): a day's
 * readings, its night's stretches and its sleep record always travel together, since the stretches replace the night's.
 */
export function fitbitChunks(rows: { daily: FitbitDay[]; sleep: FitbitNight[] }, limits: { bytes: number; rows: number; nights: number } = FITBIT_CHUNK): FitbitChunk[] {
  const byDate = new Map<string, { daily: FitbitDay[]; night?: FitbitNight }>();
  for (const r of rows.daily) {
    const day = byDate.get(r.date) ?? { daily: [] };
    day.daily.push(r);
    byDate.set(r.date, day);
  }
  for (const n of rows.sleep) {
    const day = byDate.get(n.date) ?? { daily: [] };
    day.night = n;
    byDate.set(n.date, day);
  }
  const chunks: FitbitChunk[] = [];
  let current = { daily: [] as FitbitDay[], sleep: [] as FitbitNight[] };
  let size = 0;
  for (const date of [...byDate.keys()].sort()) {
    const day = byDate.get(date)!;
    const bytes = JSON.stringify(day.daily).length + (day.night ? JSON.stringify(day.night).length : 0) + 2;
    const full =
      size + bytes > limits.bytes - 100 || current.daily.length + day.daily.length > limits.rows || current.sleep.length + (day.night ? 1 : 0) > limits.nights;
    if (full && size > 0) {
      chunks.push(current);
      current = { daily: [], sleep: [] };
      size = 0;
    }
    current.daily.push(...day.daily);
    if (day.night) current.sleep.push(day.night);
    size += bytes;
  }
  if (size > 0) chunks.push(current);
  return chunks;
}

/** The summary POST /api/fitbit/import/finish keeps, from what was sent. */
export function fitbitFinish(rows: { daily: FitbitDay[] }): FitbitFinish {
  const dates = [...new Set(rows.daily.map((r) => r.date))].sort();
  return { days: dates.length, firstDate: dates[0] ?? null, lastDate: dates.at(-1) ?? null, metrics: [...new Set(rows.daily.map((r) => r.metric))].sort() };
}
