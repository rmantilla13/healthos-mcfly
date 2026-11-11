// Reads NOOP's CSV export (github.com/ryanbr/noop: Settings → Backup & restore → Export CSV) in the browser. The zip
// is in WHOOP's own export layout, written by NOOP: physiological_cycles.csv (one row a day), sleeps.csv and
// workouts.csv, each with a trailing Source column ("noop (APPROXIMATE)" for NOOP's own estimates, "import" for WHOOP
// history it imported). Every time is in UTC with a "UTC+00:00" zone column; each day is the date in "Cycle start
// time". What's read becomes per-day readings, nights and workouts (shared/noop.ts), sent in chunks to
// POST /api/noop/import. The file itself never leaves the device.
import { NOOP_CHUNK, NOOP_FIRST_DATE, type NoopChunk, type NoopDay, type NoopFinish, type NoopMetric, type NoopNight, type NoopWorkout, inNoopRange } from '../../shared/noop.ts';
import { dateAt, isoAt, parseCsv, zoneOffsets } from './fitbit.ts';
import { type ZipEntry, ZipError, listZip, readZipText } from './zip.ts';

export class NoopExportError extends Error {
  name = 'NoopExportError';
}

/** The CSVs' text, as found in the zip, and whether NOOP's metric-series sidecar came with them. */
export type NoopFiles = { cycles?: string; sleeps?: string; workouts?: string; sidecar?: boolean };

const H_MIN = 60;
const DAY_MS = 86_400_000;
const MAX_SPAN_MS = DAY_MS;

/** physiological_cycles.csv's columns (as parseCsv lower-cases them) and the metric each becomes. Minutes go to hours. */
const CYCLE_COLUMNS: [column: string, metric: NoopMetric, minutes?: true][] = [
  ['recovery score %', 'recovery'],
  ['resting heart rate (bpm)', 'resting_hr'],
  // NOOP's HRV is RMSSD, as WHOOP measures it.
  ['heart rate variability (ms)', 'hrv_rmssd'],
  ['blood oxygen %', 'spo2'],
  // Already on WHOOP's 0–21 scale: NOOP converts its own 0–100 effort down when it exports.
  ['day strain', 'strain'],
  // WHOOP's "cal" are kilocalories.
  ['energy burned (cal)', 'whoop_kcal'],
  ['average hr (bpm)', 'hr_avg'],
  ['max hr (bpm)', 'hr_max'],
  ['respiratory rate (rpm)', 'resp_rate'],
  ['sleep performance %', 'sleep_performance'],
  ['asleep duration (min)', 'sleep_hours', true],
  ['in bed duration (min)', 'sleep_in_bed', true],
  ['light sleep duration (min)', 'sleep_light', true],
  ['deep (sws) duration (min)', 'sleep_deep', true],
  ['rem duration (min)', 'sleep_rem', true],
  ['awake duration (min)', 'sleep_awake', true],
  ['sleep efficiency %', 'sleep_efficiency'],
  ['sleep consistency %', 'sleep_consistency'],
  // "Skin temp (celsius)" is left out on purpose: NOOP's figure is the change from your own baseline, not a
  // temperature, and stored as skin_temp it would read as about 0 °C next to WHOOP's ~34.
];

const SLEEP_METRICS = new Set<NoopMetric>(['sleep_hours', 'sleep_in_bed', 'sleep_light', 'sleep_deep', 'sleep_rem', 'sleep_awake', 'sleep_efficiency']);

const round = (v: number, places = 2) => Math.round(v * 10 ** places) / 10 ** places;
const validDate = (d: string) => /^\d{4}-\d{2}-\d{2}$/.test(d) && new Date(Date.parse(d + 'T00:00:00Z')).toISOString().slice(0, 10) === d;

function num(v: string | undefined): number | undefined {
  if (v === undefined || v.trim() === '') return undefined;
  const n = Number(v);
  return Number.isFinite(n) ? n : undefined;
}

/** "UTC+00:00", "UTC-05:00" or "+05:30" as minutes east of UTC. */
function zoneMinutes(s: string | undefined): number | null {
  const m = /^\s*(?:UTC|GMT)?\s*([+-])(\d{1,2}):?(\d{2})\s*$/i.exec(s ?? '');
  return m ? (m[1] === '-' ? -1 : 1) * (Number(m[2]) * 60 + Number(m[3])) : null;
}

/** "2026-08-05 22:31:00" in the row's zone column (NOOP writes UTC) as an instant. */
function instant(wall: string | undefined, zone: string | undefined): number | null {
  const m = /^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2})(?::(\d{2}))?/.exec((wall ?? '').trim());
  if (!m) return null;
  const off = zoneMinutes(zone) ?? 0;
  return Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3]), Number(m[4]), Number(m[5]), Number(m[6] ?? 0)) - off * 60_000;
}

/** NOOP puts an apostrophe before text that starts with = + - @ or a tab, so a spreadsheet won't run it as a formula. */
const unguard = (s: string) => (/^'[=+\-@\t\r]/.test(s) ? s.slice(1) : s);

function titleCase(s: string) {
  return s.replace(/[-_]+/g, ' ').trim().replace(/\b\w/g, (c) => c.toUpperCase());
}

/** The header row's cells, lower-cased: NOOP's export ends with a Source column; WHOOP's own doesn't have one. */
const headerOf = (text: string) =>
  (text.replace(/^﻿/, '').split(/\r?\n/, 1)[0] ?? '')
    .split(',')
    .map((h) => h.trim().replace(/^"|"$/g, '').toLowerCase());

export type NoopFound = {
  daily: NoopDay[];
  sleep: NoopNight[];
  workouts: NoopWorkout[];
  /** How many days NOOP worked out itself, and how many came from WHOOP history it had imported. */
  estimatedDays: number;
  importedDays: number;
};

/**
 * Turns the CSVs into readings. `timeZone` places NOOP's UTC times on the person's own clock (their Settings zone,
 * else this device's); `today` (in that zone) is the last date kept. Throws a NoopExportError, in words for the
 * person, when this isn't a NOOP export.
 */
export function noopRows(files: NoopFiles, opts: { timeZone: string; today: string }): NoopFound {
  if (files.cycles === undefined && files.sleeps === undefined) {
    throw new NoopExportError("This doesn't look like a NOOP export: it has no physiological_cycles.csv or sleeps.csv. In NOOP, use Settings → Backup & restore → Export CSV.");
  }
  const marked = [files.cycles, files.sleeps, files.workouts].some((t) => t !== undefined && headerOf(t).at(-1) === 'source');
  if (!marked && !files.sidecar) {
    throw new NoopExportError(
      "This looks like WHOOP's own data export, not NOOP's. healthOS reads WHOOP through Connect WHOOP on this page; for a strap you use with NOOP, export from NOOP (Settings → Backup & restore → Export CSV).",
    );
  }
  const offsetAt = zoneOffsets(opts.timeZone);
  const keep = (d: string) => validDate(d) && d >= NOOP_FIRST_DATE && d <= opts.today;

  const daily = new Map<string, NoopDay>();
  /** Keeps a reading that's in range; says whether it did. */
  const add = (date: string, metric: NoopMetric, value: number | undefined) => {
    if (value === undefined) return false;
    const v = round(value);
    if (!inNoopRange(metric, v)) return false;
    daily.set(`${date}|${metric}`, { date, metric, value: v });
    return true;
  };
  let estimatedDays = 0;
  let importedDays = 0;

  for (const row of files.cycles ? parseCsv(files.cycles) : []) {
    const date = (row['cycle start time'] ?? '').slice(0, 10);
    if (!keep(date)) continue;
    let any = false;
    for (const [column, metric, minutes] of CYCLE_COLUMNS) {
      const v = num(row[column]);
      if (v !== undefined && add(date, metric, minutes ? v / H_MIN : v)) any = true;
    }
    if (!any) continue;
    if (/approx/i.test(row.source ?? '')) estimatedDays++;
    else importedDays++;
  }

  // Each night by the date you woke, in your zone. The longest one that date is the night; any day without sleep
  // figures in the cycles file takes them from its nights.
  const nights = new Map<string, { start: number; end: number; asleep?: number; inBed?: number; light?: number; deep?: number; rem?: number; awake?: number; efficiency?: number }[]>();
  for (const row of files.sleeps ? parseCsv(files.sleeps) : []) {
    if ((row.nap ?? '').toLowerCase() === 'true') continue;
    const zone = row['cycle timezone'];
    const start = instant(row['sleep onset'], zone);
    const end = instant(row['wake onset'], zone);
    if (start === null || end === null || end <= start || end - start > MAX_SPAN_MS) continue;
    const date = dateAt(end, offsetAt(end));
    if (!keep(date)) continue;
    const list = nights.get(date) ?? [];
    list.push({
      start,
      end,
      asleep: num(row['asleep duration (min)']),
      inBed: num(row['in bed duration (min)']),
      light: num(row['light sleep duration (min)']),
      deep: num(row['deep (sws) duration (min)']),
      rem: num(row['rem duration (min)']),
      awake: num(row['awake duration (min)']),
      efficiency: num(row['sleep efficiency %']),
    });
    nights.set(date, list);
  }
  const sleep: NoopNight[] = [];
  for (const [date, list] of nights) {
    const main = list.reduce((a, b) => (b.end - b.start > a.end - a.start ? b : a));
    sleep.push({ date, start: isoAt(main.start, offsetAt(main.start)), end: isoAt(main.end, offsetAt(main.end)) });
    if (daily.has(`${date}|sleep_hours`)) continue;
    const total = (pick: (n: (typeof list)[number]) => number | undefined) => {
      const vs = list.map(pick).filter((v): v is number => v !== undefined);
      return vs.length ? vs.reduce((t, v) => t + v, 0) : undefined;
    };
    const hours = (v: number | undefined) => (v === undefined ? undefined : v / H_MIN);
    add(date, 'sleep_hours', hours(total((n) => n.asleep)));
    add(date, 'sleep_in_bed', hours(total((n) => n.inBed)));
    add(date, 'sleep_light', hours(total((n) => n.light)));
    add(date, 'sleep_deep', hours(total((n) => n.deep)));
    add(date, 'sleep_rem', hours(total((n) => n.rem)));
    add(date, 'sleep_awake', hours(total((n) => n.awake)));
    add(date, 'sleep_efficiency', main.efficiency);
  }

  const workouts = new Map<string, NoopWorkout>();
  const within = (v: number | undefined, lo: number, hi: number) => (v !== undefined && v >= lo && v <= hi ? round(v) : null);
  for (const row of files.workouts ? parseCsv(files.workouts) : []) {
    const zone = row['cycle timezone'];
    const start = instant(row['workout start time'], zone);
    const end = instant(row['workout end time'], zone);
    if (start === null || end === null || end <= start || end - start > MAX_SPAN_MS) continue;
    const date = dateAt(start, offsetAt(start));
    if (!keep(date)) continue;
    const sport = titleCase(unguard(row['activity name'] ?? '')).slice(0, 60) || 'Activity';
    workouts.set(`${start}|${sport.toLowerCase()}`, {
      date,
      start: isoAt(start, offsetAt(start)),
      end: isoAt(end, offsetAt(end)),
      sport,
      energy_kcal: within(num(row['energy burned (cal)']), 0, 20_000),
      distance_m: within(num(row['distance (meters)']), 0, 1_000_000),
      avg_hr: within(num(row['average hr (bpm)']), 25, 230),
      max_hr: within(num(row['max hr (bpm)']), 25, 230),
      strain: within(num(row['activity strain']), 0, 21),
    });
  }

  const byDate = <T extends { date: string }>(a: T, b: T) => a.date.localeCompare(b.date);
  return {
    daily: [...daily.values()].sort(byDate),
    sleep: sleep.sort(byDate),
    workouts: [...workouts.values()].sort((a, b) => Date.parse(a.start) - Date.parse(b.start)),
    estimatedDays,
    importedDays,
  };
}

/** What the preview says was found. */
export type NoopPreview = { days: number; recoveryDays: number; nights: number; workouts: number; firstDate: string | null; lastDate: string | null };

export function noopPreview(found: Pick<NoopFound, 'daily' | 'sleep' | 'workouts'>): NoopPreview {
  const dates = [...new Set([...found.daily.map((r) => r.date), ...found.sleep.map((n) => n.date), ...found.workouts.map((w) => w.date)])].sort();
  const daysWith = (pred: (m: NoopMetric) => boolean) => new Set(found.daily.filter((r) => pred(r.metric)).map((r) => r.date)).size;
  return {
    days: dates.length,
    recoveryDays: daysWith((m) => m === 'recovery' || m === 'strain'),
    nights: Math.max(found.sleep.length, daysWith((m) => SLEEP_METRICS.has(m))),
    workouts: found.workouts.length,
    firstDate: dates[0] ?? null,
    lastDate: dates.at(-1) ?? null,
  };
}

/** The readings in chunks of whole days, each within what the server takes (NOOP_CHUNK). */
export function noopChunks(found: Pick<NoopFound, 'daily' | 'sleep' | 'workouts'>, limits: { bytes: number; rows: number; nights: number; workouts: number } = NOOP_CHUNK): NoopChunk[] {
  const days = new Map<string, { daily: NoopDay[]; sleep: NoopNight[]; workouts: NoopWorkout[] }>();
  const day = (date: string) => days.get(date) ?? (days.set(date, { daily: [], sleep: [], workouts: [] }).get(date) as { daily: NoopDay[]; sleep: NoopNight[]; workouts: NoopWorkout[] });
  for (const r of found.daily) day(r.date).daily.push(r);
  for (const n of found.sleep) day(n.date).sleep.push(n);
  for (const w of found.workouts) day(w.date).workouts.push(w);
  const chunks: NoopChunk[] = [];
  let current = { daily: [] as NoopDay[], sleep: [] as NoopNight[], workouts: [] as NoopWorkout[] };
  let size = 0;
  for (const date of [...days.keys()].sort()) {
    const d = days.get(date)!;
    const bytes = JSON.stringify(d).length;
    const full =
      size + bytes > limits.bytes - 100 ||
      current.daily.length + d.daily.length > limits.rows ||
      current.sleep.length + d.sleep.length > limits.nights ||
      current.workouts.length + d.workouts.length > limits.workouts;
    if (full && size > 0) {
      chunks.push(current);
      current = { daily: [], sleep: [], workouts: [] };
      size = 0;
    }
    current.daily.push(...d.daily);
    current.sleep.push(...d.sleep);
    current.workouts.push(...d.workouts);
    size += bytes;
  }
  if (size > 0) chunks.push(current);
  return chunks;
}

/** The summary POST /api/noop/import/finish checks, from what was sent. */
export function noopFinish(found: Pick<NoopFound, 'daily'>): NoopFinish {
  const dates = [...new Set(found.daily.map((r) => r.date))].sort();
  return { days: dates.length, firstDate: dates[0] ?? null, lastDate: dates.at(-1) ?? null, metrics: [...new Set(found.daily.map((r) => r.metric))].sort() };
}

/** The CSVs in a NOOP export .zip, wherever in it they are. */
export async function readNoopZip(file: Blob): Promise<NoopFiles> {
  let entries: ZipEntry[];
  try {
    entries = await listZip(file);
  } catch (e) {
    throw e instanceof ZipError ? new NoopExportError(e.message.replace('Download the export again.', 'Export it from NOOP again.')) : e;
  }
  const named = (name: string) => entries.find((e) => (e.name.split('/').pop() ?? '').toLowerCase() === name);
  const text = async (name: string) => {
    const entry = named(name);
    if (!entry) return undefined;
    if (entry.size > 200_000_000) throw new NoopExportError(`${name} in this export is too large to read here.`);
    return readZipText(file, entry);
  };
  const [cycles, sleeps, workouts] = await Promise.all([text('physiological_cycles.csv'), text('sleeps.csv'), text('workouts.csv')]);
  return { cycles, sleeps, workouts, sidecar: Boolean(named('noop_metric_series.json')) };
}
