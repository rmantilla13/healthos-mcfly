// Cycle entries as stored: one row per (person, date, kind, source) in the `cycle` table, and back into days.
// Also the validation shared by logging by hand and the iPhone app. Messages name the field and what it
// accepts, never the value sent.
import type { CervicalMucus, CycleDay, CycleFields, CycleLogDay, Flow, OvulationTest, SexualActivity, Symptom, TempDisturbance } from '../../shared/types.ts';
import type { Queryable } from '../db.ts';
import { insertMany } from '../store.ts';

/** Symptoms take one row each (`symptom:cramps`), so a day can have several under the table's key. */
export type CycleKind = 'flow' | 'period_start' | 'spotting' | 'ovulation_test' | 'mucus' | 'bbt' | 'sexual_activity' | 'temp_disturbed' | `symptom:${Symptom}`;

/** One stored value: a choice from the lists below, '1' for flags, °C for bbt. */
export type CycleRow = { date: string; kind: CycleKind; source: string; value: string };

/** Manual entries; Apple Health's are 'apple'. Nothing derived is ever stored: the iPhone ingest replaces 'apple' rows. */
export const MANUAL = 'manual';

// Each list runs from least to most: when one day has two records of the same kind (two flow logs, two
// tests), the later in the list wins.
export const FLOWS: readonly Flow[] = ['none', 'unspecified', 'light', 'medium', 'heavy'];
export const OVULATION_TESTS: readonly OvulationTest[] = ['negative', 'indeterminate', 'estrogen_surge', 'lh_surge'];
export const MUCUS: readonly CervicalMucus[] = ['dry', 'sticky', 'creamy', 'watery', 'egg_white'];
export const SEXUAL_ACTIVITY: readonly SexualActivity[] = ['protected', 'unspecified', 'unprotected'];
export const SYMPTOMS: readonly Symptom[] = [
  'cramps',
  'bloating',
  'breast_tenderness',
  'headache',
  'acne',
  'fatigue',
  'mood_changes',
  'back_pain',
  'nausea',
  'appetite_changes',
  'sleep_changes',
  'hot_flashes',
];
export const TEMP_DISTURBANCES: readonly TempDisturbance[] = ['sick', 'alcohol', 'sleep', 'travel', 'other'];

const RANKED: Partial<Record<CycleKind, readonly string[]>> = { flow: FLOWS, ovulation_test: OVULATION_TESTS, mucus: MUCUS, sexual_activity: SEXUAL_ACTIVITY };

/** Basal body temperatures accepted from a person or the iPhone, °C. The analysis is stricter (temperature.ts). */
export const BBT_RANGE = [34, 40] as const;

// ---------- rows and days ----------

export function toRows(day: CycleDay, source: string): CycleRow[] {
  const rows: CycleRow[] = [];
  const add = (kind: CycleKind, value: string) => rows.push({ date: day.date, kind, source, value });
  if (day.flow) add('flow', day.flow);
  if (day.periodStart) add('period_start', '1');
  if (day.spotting) add('spotting', '1');
  if (day.ovulationTest) add('ovulation_test', day.ovulationTest);
  if (day.mucus) add('mucus', day.mucus);
  if (day.bbt !== undefined) add('bbt', String(Math.round(day.bbt * 100) / 100));
  if (day.sexualActivity) add('sexual_activity', day.sexualActivity);
  if (day.tempDisturbed) add('temp_disturbed', day.tempDisturbed);
  for (const s of new Set(day.symptoms ?? [])) add(`symptom:${s}`, '1');
  return rows;
}

function setField(f: CycleFields, kind: string, value: string) {
  const pick = <T extends string>(list: readonly T[]) => (list.includes(value as T) ? (value as T) : undefined);
  if (kind === 'flow') f.flow = pick(FLOWS);
  else if (kind === 'period_start') f.periodStart = true;
  else if (kind === 'spotting') f.spotting = true;
  else if (kind === 'ovulation_test') f.ovulationTest = pick(OVULATION_TESTS);
  else if (kind === 'mucus') f.mucus = pick(MUCUS);
  else if (kind === 'sexual_activity') f.sexualActivity = pick(SEXUAL_ACTIVITY);
  else if (kind === 'temp_disturbed') f.tempDisturbed = pick(TEMP_DISTURBANCES);
  else if (kind === 'bbt' && Number.isFinite(Number(value))) f.bbt = Number(value);
  else if (kind.startsWith('symptom:')) {
    const s = kind.slice(8) as Symptom;
    if (SYMPTOMS.includes(s)) f.symptoms = [...new Set([...(f.symptoms ?? []), s])].sort();
  }
}

function fold(kind: CycleKind, a: string, b: string) {
  const rank = RANKED[kind];
  if (rank) return rank.indexOf(b) > rank.indexOf(a) ? b : a;
  return b;
}

export async function upsertCycle(q: Queryable, userId: string, rows: CycleRow[]) {
  // One value per (date, kind, source); two in one batch fold together rather than make Postgres reject it.
  const unique = new Map<string, CycleRow>();
  for (const r of rows) {
    const k = `${r.date}|${r.kind}|${r.source}`;
    const prev = unique.get(k);
    unique.set(k, prev ? { ...r, value: fold(r.kind, prev.value, r.value) } : r);
  }
  await insertMany(
    q,
    'cycle',
    ['user_id', 'date', 'kind', 'source', 'value'],
    [...unique.values()].map((r) => [userId, r.date, r.kind, r.source, r.value]),
    'ON CONFLICT (user_id, date, kind, source) DO UPDATE SET value = excluded.value',
  );
}

/** Each day given is that source's complete record for its date: cleared, then written. A day with no fields clears it. */
export async function replaceCycleDays(q: Queryable, userId: string, source: string, days: CycleDay[]) {
  const dates = [...new Set(days.map((d) => d.date))];
  if (!dates.length) return;
  await q.query('DELETE FROM cycle WHERE user_id = $1 AND source = $2 AND date = ANY($3)', [userId, source, dates]);
  await upsertCycle(
    q,
    userId,
    days.flatMap((d) => toRows(d, source)),
  );
}

/** Stored rows as days: a field logged by hand overrides Apple Health's for the same day. */
export function logDays(rows: Pick<CycleRow, 'date' | 'kind' | 'source' | 'value'>[]): CycleLogDay[] {
  const byDate = new Map<string, { apple?: CycleFields; manual?: CycleFields }>();
  for (const r of rows) {
    let d = byDate.get(r.date);
    if (!d) byDate.set(r.date, (d = {}));
    setField((d[r.source === MANUAL ? 'manual' : 'apple'] ??= {}), r.kind, r.value);
  }
  const clean = (f: CycleFields | undefined) => (f ? (Object.fromEntries(Object.entries(f).filter(([, v]) => v !== undefined)) as CycleFields) : undefined);
  return [...byDate]
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([date, s]) => {
      const apple = clean(s.apple);
      const manual = clean(s.manual);
      return { date, ...apple, ...manual, ...(apple && { apple }), ...(manual && { manual }) };
    });
}

/** Everything one person has logged, from Apple Health and by hand. */
export async function readLogDays(q: Queryable, userId: string): Promise<CycleLogDay[]> {
  const rows = await q.query<CycleRow>("SELECT date, kind, source, value FROM cycle WHERE user_id = $1 AND source IN ('apple', 'manual') ORDER BY date", [userId]);
  return logDays(rows);
}

// ---------- validation (manual entries and the iPhone app) ----------

export type Fail = (path: string, message: string) => never;

function validDate(v: unknown): v is string {
  if (typeof v !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(v)) return false;
  const ms = Date.parse(`${v}T00:00:00Z`);
  // Date.parse rolls 2026-02-30 over to March; the round trip catches that.
  return !Number.isNaN(ms) && new Date(ms).toISOString().slice(0, 10) === v;
}

/** One day's entries. */
export function parseCycleDay(raw: unknown, path: string, fail: Fail): CycleDay {
  if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) fail(path, 'expected an object');
  const r = raw as Record<string, unknown>;
  if (!validDate(r.date)) fail(`${path}.date`, 'expected a date as YYYY-MM-DD');
  const day: CycleDay = { date: r.date };
  const given = (key: string) => r[key] !== undefined && r[key] !== null;
  const oneOf = <T extends string>(key: string, list: readonly T[]): T | undefined => {
    if (!given(key)) return undefined;
    if (typeof r[key] !== 'string' || !list.includes(r[key] as T)) fail(`${path}.${key}`, `expected one of ${list.join(', ')}`);
    return r[key] as T;
  };
  const flag = (key: string) => {
    if (!given(key)) return undefined;
    if (typeof r[key] !== 'boolean') fail(`${path}.${key}`, 'expected true or false');
    return r[key] ? true : undefined;
  };
  const flow = oneOf('flow', FLOWS);
  const periodStart = flag('periodStart');
  const spotting = flag('spotting');
  const ovulationTest = oneOf('ovulationTest', OVULATION_TESTS);
  const mucus = oneOf('mucus', MUCUS);
  const sexualActivity = oneOf('sexualActivity', SEXUAL_ACTIVITY);
  const tempDisturbed = oneOf('tempDisturbed', TEMP_DISTURBANCES);
  let bbt: number | undefined;
  if (given('bbt')) {
    const v = r.bbt;
    if (typeof v !== 'number' || !Number.isFinite(v) || v < BBT_RANGE[0] || v > BBT_RANGE[1]) fail(`${path}.bbt`, `expected °C from ${BBT_RANGE[0]} to ${BBT_RANGE[1]}`);
    bbt = v;
  }
  let symptoms: Symptom[] | undefined;
  if (given('symptoms')) {
    const v = r.symptoms;
    if (!Array.isArray(v) || v.some((s) => typeof s !== 'string' || !SYMPTOMS.includes(s as Symptom))) fail(`${path}.symptoms`, `expected a list from ${SYMPTOMS.join(', ')}`);
    symptoms = v.length ? [...new Set(v as Symptom[])].sort() : undefined;
  }
  return Object.assign(
    day,
    Object.fromEntries(
      Object.entries({ flow, periodStart, spotting, ovulationTest, mucus, bbt, sexualActivity, symptoms, tempDisturbed }).filter(([, v]) => v !== undefined),
    ),
  );
}
