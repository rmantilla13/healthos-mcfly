// Ask McFly (/api/mcfly): a Claude agent that answers questions about the signed-in person's own health
// data. It can only read, through the tools below, and every tool runs in that person's scope. The server
// keeps no conversation: the browser sends the visible history (plain text) with each question.
import Anthropic from '@anthropic-ai/sdk';
import express, { type Request, type Response } from 'express';
import { type LabResult, matchBiomarker, normalizeName } from '../shared/labs.ts';
import type { Digest, DigestReply, McflyVisual, NutritionNumbers, Point, Units } from '../shared/types.ts';
import { platformSettings } from './admin.ts';
import { currentUser } from './auth.ts';
import { cycleView } from './cycle/index.ts';
import { labsView } from './labs.ts';
import { nutritionView } from './nutrition.ts';
import { addDays } from './dates.ts';
import { type Db, type Scope, getUserSetting, setUserSetting } from './db.ts';
import { patterns } from './insights.ts';
import { requestContext, sourceList, summary, trends, workouts } from './query.ts';

type BetaMessageParam = Anthropic.Beta.BetaMessageParam;
type BetaTool = Anthropic.Beta.BetaTool;
type BetaToolUseBlock = Anthropic.Beta.BetaToolUseBlock;
type BetaToolResultBlockParam = Anthropic.Beta.BetaToolResultBlockParam;

/** The part of the SDK client McFly uses; tests pass a fake. */
export type McflyClient = Pick<Anthropic, 'beta'>;

const MAX_TURNS = 40;
const MAX_QUESTION = 4_000;
const MAX_HISTORY_CHARS = 80_000;
/** Model calls per question: each round can read several tools at once, so this is generous. */
const MAX_ROUNDS = 10;
const DATE = /^\d{4}-\d{2}-\d{2}$/;

// ---------- the data McFly can read ----------

type Kind = 'temp' | 'mass' | 'distance' | 'speed';
type MetricInfo = { label: string; unit: string; kind?: Kind };

/** Every metric the importers write, as stored (metric units). */
export const METRICS: Record<string, MetricInfo> = {
  steps: { label: 'Steps', unit: 'steps' },
  active_energy: { label: 'Active energy (Apple)', unit: 'kcal' },
  whoop_kcal: { label: 'Calories burned, whole day (WHOOP)', unit: 'kcal' },
  exercise_min: { label: 'Exercise minutes (Apple ring)', unit: 'min' },
  distance_km: { label: 'Walking and running distance', unit: 'km', kind: 'distance' },
  hr_avg: { label: 'Average heart rate', unit: 'bpm' },
  hr_min: { label: 'Lowest heart rate', unit: 'bpm' },
  hr_max: { label: 'Highest heart rate', unit: 'bpm' },
  resting_hr: { label: 'Resting heart rate', unit: 'bpm' },
  hrv_rmssd: { label: 'HRV, RMSSD (WHOOP, during sleep)', unit: 'ms' },
  hrv_rmssd_watch: { label: 'HRV, RMSSD (Apple Watch)', unit: 'ms' },
  hrv_sdnn: { label: 'HRV, SDNN (Apple Watch)', unit: 'ms' },
  spo2: { label: 'Blood oxygen', unit: '%' },
  resp_rate: { label: 'Respiratory rate', unit: 'breaths/min' },
  wrist_temp: { label: 'Wrist temperature during sleep (Apple Watch)', unit: '°C', kind: 'temp' },
  skin_temp: { label: 'Skin temperature (WHOOP)', unit: '°C', kind: 'temp' },
  body_temp: { label: 'Body temperature', unit: '°C', kind: 'temp' },
  weight: { label: 'Weight', unit: 'kg', kind: 'mass' },
  body_fat: { label: 'Body fat', unit: '%' },
  lean_mass: { label: 'Lean body mass', unit: 'kg', kind: 'mass' },
  vo2max: { label: 'VO2 max (cardio fitness)', unit: 'mL/kg/min' },
  sleep_hours: { label: 'Time asleep', unit: 'h' },
  sleep_in_bed: { label: 'Time in bed', unit: 'h' },
  sleep_deep: { label: 'Deep sleep', unit: 'h' },
  sleep_rem: { label: 'REM sleep', unit: 'h' },
  sleep_light: { label: 'Light (core) sleep', unit: 'h' },
  sleep_awake: { label: 'Awake during the night', unit: 'h' },
  sleep_efficiency: { label: 'Sleep efficiency (WHOOP)', unit: '%' },
  sleep_performance: { label: 'Sleep performance (WHOOP)', unit: '%' },
  sleep_consistency: { label: 'Sleep consistency (WHOOP)', unit: '%' },
  recovery: { label: 'Recovery (WHOOP)', unit: '%' },
  strain: { label: 'Day strain (WHOOP, 0 to 21)', unit: '' },
  blood_pressure_systolic: { label: 'Blood pressure, systolic (upper number)', unit: 'mmHg' },
  blood_pressure_diastolic: { label: 'Blood pressure, diastolic (lower number)', unit: 'mmHg' },
  glucose: { label: 'Blood glucose', unit: 'mg/dL' },
  walking_speed: { label: 'Walking speed', unit: 'km/h', kind: 'speed' },
  walking_steadiness: { label: 'Walking steadiness (Apple)', unit: '%' },
  walking_asymmetry: { label: 'Walking asymmetry', unit: '%' },
  daylight_min: { label: 'Time in daylight', unit: 'min' },
  flights: { label: 'Flights climbed', unit: 'flights' },
  stand_hours: { label: 'Stand hours (Apple ring)', unit: 'hours' },
  breathing_disturbances: { label: 'Breathing disturbances during sleep (Apple Watch)', unit: '' },
  caffeine_mg: { label: 'Caffeine', unit: 'mg' },
  water_ml: { label: 'Water', unit: 'mL' },
};

const round = (v: number) => Math.round(v * 100) / 100;

/** A stored value in the person's preferred units, with its unit label. */
function inUnits(kind: Kind | undefined, value: number, unit: string, units: Units): { value: number; unit: string } {
  if (units === 'imperial' && kind === 'temp') return { value: round((value * 9) / 5 + 32), unit: '°F' };
  if (units === 'imperial' && kind === 'mass') return { value: round(value / 0.45359237), unit: 'lb' };
  if (units === 'imperial' && kind === 'distance') return { value: round(value / 1.609344), unit: 'mi' };
  if (units === 'imperial' && kind === 'speed') return { value: round(value / 1.609344), unit: 'mph' };
  return { value: round(value), unit };
}

const unitOf = (metric: string, units: Units) => inUnits(METRICS[metric]?.kind, 0, METRICS[metric]?.unit ?? '', units).unit;

/**
 * cycle: the person has cycle tracking on, so McFly may read it. nutrition: what they chose to see of their food
 * logs, or null while nutrition is off; McFly reads only that much. shown: visuals already in this answer.
 */
type Ctx = { scope: Scope; hosted: boolean; units: Units; today: string; demo: boolean; cycle: boolean; nutrition: NutritionNumbers | null; stepGoal: number; shown: number };

/** Charts and tiles per answer: enough for a trend and a comparison, few enough that the words still lead. */
const MAX_VISUALS = 3;
const TOO_MANY = `This answer already has ${MAX_VISUALS} visuals. Finish in words.`;

const mean = (xs: number[]) => (xs.length ? xs.reduce((a, b) => a + b, 0) / xs.length : null);

/** Monday of the ISO week a date falls in. */
function weekStart(date: string) {
  const day = new Date(`${date}T00:00:00Z`).getUTCDay();
  return addDays(date, -((day + 6) % 7));
}

function bucket(points: { date: string; value: number }[], resolution: 'day' | 'week' | 'month') {
  if (resolution === 'day') return points.map((p) => ({ period: p.date, value: p.value }));
  const groups = new Map<string, number[]>();
  for (const p of points) {
    const key = resolution === 'week' ? weekStart(p.date) : p.date.slice(0, 7);
    groups.set(key, [...(groups.get(key) ?? []), p.value]);
  }
  return [...groups].map(([period, vs]) => ({ period, value: round(mean(vs)!), days: vs.length }));
}

class ToolInputError extends Error {}

function asDate(v: unknown, ctx: Ctx, field: string): string | undefined {
  if (v === undefined || v === null || v === '') return undefined;
  // A real calendar date: 2026-02-30 would roll over to March, and 2026-10-00 would break the date maths.
  const ms = typeof v === 'string' && DATE.test(v) ? Date.parse(`${v}T00:00:00Z`) : NaN;
  if (Number.isNaN(ms) || new Date(ms).toISOString().slice(0, 10) !== v) throw new ToolInputError(`${field} must be a real date like 2026-10-16.`);
  return (v as string) > ctx.today ? ctx.today : (v as string);
}

function asDays(v: unknown, max: number, fallback: number): number {
  if (v === undefined || v === null) return fallback;
  const n = Math.round(Number(v));
  if (!Number.isFinite(n) || n < 1) throw new ToolInputError('days must be a whole number of at least 1.');
  return Math.min(n, max);
}

type Tool = BetaTool & {
  label: (input: Record<string, unknown>) => string;
  run: (ctx: Ctx, input: Record<string, unknown>) => Promise<unknown>;
  /** Offered only when this holds. A tool left out isn't even described to the model. */
  when?: (ctx: Ctx) => boolean;
  /** It draws into the answer: run returns { visual, forModel }, the visual goes to the browser and forModel to McFly. */
  visual?: true;
};

const METRIC_NAMES = Object.keys(METRICS);
/** Daily totals: today's is only so far, so it's left out of averages until the day is over. */
const SUMMED = new Set(['steps', 'active_energy', 'whoop_kcal', 'exercise_min', 'distance_km', 'flights', 'stand_hours', 'daylight_min', 'caffeine_mg', 'water_ml']);
/** The days an average counts: every day with data, except today's unfinished total. */
const forAverage = (ctx: Ctx, metric: string, pts: Point[]) => (SUMMED.has(metric) ? pts.filter((p) => p.date !== ctx.today) : pts);
const lowerLabel = (m: string) => (METRICS[m]?.label ?? m).replace(/ \(.*\)$/, '').toLowerCase();

function asMetric(v: unknown, field: string): string {
  if (typeof v !== 'string' || !(v in METRICS)) throw new ToolInputError(`${field} must be a metric name from list_metrics.`);
  return v;
}

/** A metric's daily values in the person's units, oldest first. */
async function dailyPoints(ctx: Ctx, metric: string, days: number, end?: string): Promise<Point[]> {
  const info = METRICS[metric];
  const t = await trends(ctx.scope, ctx.hosted, [metric], days, end);
  return t[metric].map((p) => ({ date: p.date, value: inUnits(info.kind, p.value, info.unit, ctx.units).value }));
}

const stretch = (points: Point[], key: 'min' | 'max') =>
  points.reduce<Point | null>((a, p) => (!a || (key === 'min' ? p.value < a.value : p.value > a.value) ? p : a), null);

/** One chart or a few tiles for an answer, from the person's own data. Throws ToolInputError when there's nothing to draw. */
async function buildVisual(ctx: Ctx, input: Record<string, unknown>): Promise<{ visual: McflyVisual; forModel: unknown }> {
  const title = typeof input.title === 'string' ? input.title.trim().slice(0, 80) : '';
  if (!title) throw new ToolInputError('title is required: a short plain title for the chart.');
  const end = asDate(input.end_date, ctx, 'end_date');
  const to = end ?? ctx.today;
  const none = (what: string) => new ToolInputError(`No ${what} recorded in that range, so there's nothing to draw. Say so in words instead.`);

  if (input.kind === 'trend' || input.kind === 'bars') {
    const metric = asMetric(input.metric, 'metric');
    const days = asDays(input.days, 730, 30);
    const daily = await dailyPoints(ctx, metric, days, end);
    if (!daily.length) throw none(lowerLabel(metric));
    const resolution = days <= 120 ? 'day' : 'week';
    const points = bucket(daily, resolution).map((b) => ({ date: b.period, value: b.value }));
    const counted = forAverage(ctx, metric, daily);
    const avg = counted.length ? round(mean(counted.map((p) => p.value))!) : null;
    const goal = metric === 'steps' && resolution === 'day' ? ctx.stepGoal : undefined;
    const unit = unitOf(metric, ctx.units);
    const partialToday = counted.length < daily.length;
    return {
      visual: { kind: input.kind, title, unit, resolution, points, mean: avg, days: counted.length, partialToday, ...(goal ? { goal } : {}) },
      forModel: {
        shown: input.kind,
        title,
        unit,
        from: addDays(to, -(days - 1)),
        to,
        chartShows: resolution === 'day' ? 'one value per day' : 'weekly averages of the daily values',
        daysWithData: daily.length,
        averageOfDays: avg,
        ...(partialToday ? { todayLeftOutOfTheAverage: 'today is not over yet' } : {}),
        lowestDay: stretch(daily, 'min'),
        highestDay: stretch(daily, 'max'),
        latestDay: daily.at(-1),
        ...(resolution === 'week' ? { lowestWeek: stretch(points, 'min'), highestWeek: stretch(points, 'max') } : {}),
        ...(goal ? { goal, daysAtGoal: counted.filter((p) => p.value >= goal).length } : {}),
      },
    };
  }

  if (input.kind === 'compare') {
    const metric = asMetric(input.metric, 'metric');
    const raw = input.periods;
    if (!Array.isArray(raw) || raw.length !== 2) throw new ToolInputError('compare needs exactly two periods, each { label, days, end_date? }.');
    const periods = await Promise.all(
      raw.map(async (p, i) => {
        const r = (p && typeof p === 'object' ? p : {}) as Record<string, unknown>;
        const label = typeof r.label === 'string' && r.label.trim() ? r.label.trim().slice(0, 40) : `Period ${i + 1}`;
        const days = asDays(r.days, 366, 7);
        const pEnd = asDate(r.end_date, ctx, `periods[${i}].end_date`) ?? ctx.today;
        const pts = forAverage(ctx, metric, await dailyPoints(ctx, metric, days, pEnd));
        const partialToday = SUMMED.has(metric) && pEnd === ctx.today;
        return { label, from: addDays(pEnd, -(days - 1)), to: pEnd, mean: pts.length ? round(mean(pts.map((x) => x.value))!) : null, days: pts.length, partialToday };
      }),
    );
    if (periods.every((p) => p.mean === null)) throw none(lowerLabel(metric));
    const [a, b] = periods;
    const change = a.mean !== null && b.mean !== null && b.mean !== 0 ? round(((a.mean - b.mean) / Math.abs(b.mean)) * 100) : null;
    const unit = unitOf(metric, ctx.units);
    return { visual: { kind: 'compare', title, unit, periods }, forModel: { shown: 'compare', title, unit, periods, changePercentFirstVsSecond: change } };
  }

  if (input.kind === 'stats') {
    const raw = input.metrics;
    if (!Array.isArray(raw) || raw.length < 1 || raw.length > 4) throw new ToolInputError('stats needs 1 to 4 metrics.');
    const metrics = raw.map((m, i) => asMetric(m, `metrics[${i}]`));
    const latest = input.stat === 'latest';
    const days = asDays(input.days, 366, latest ? 30 : 7);
    const items = await Promise.all(
      metrics.map(async (m) => {
        const all = await dailyPoints(ctx, m, days, end);
        const pts = latest ? all : forAverage(ctx, m, all);
        const label = (METRICS[m].label ?? m).replace(/ \(.*\)$/, '');
        const unit = unitOf(m, ctx.units);
        const from = addDays(to, -(days - 1));
        if (!pts.length) return { label, value: null, unit, note: 'No data', from, to };
        if (latest) return { label, value: pts.at(-1)!.value, unit, note: pts.at(-1)!.date, from, to };
        return { label, value: round(mean(pts.map((p) => p.value))!), unit, note: `average of ${pts.length} ${pts.length === 1 ? 'day' : 'days'}`, from, to };
      }),
    );
    if (items.every((it) => it.value === null)) throw none('of those metrics');
    return { visual: { kind: 'stats', title, items }, forModel: { shown: 'stats', title, items } };
  }

  if (input.kind === 'sleep_stages') {
    const days = asDays(input.days, 90, 14);
    const keys = ['sleep_deep', 'sleep_light', 'sleep_rem', 'sleep_awake'];
    const t = await trends(ctx.scope, ctx.hosted, keys, days, end);
    const byDate = new Map<string, Record<string, number>>();
    for (const k of keys) for (const p of t[k]) byDate.set(p.date, { ...byDate.get(p.date), [k]: round(p.value) });
    const rows = [...byDate].sort(([x], [y]) => x.localeCompare(y)).map(([date, values]) => ({ date, values }));
    if (!rows.length) throw none('sleep stages');
    const avg = Object.fromEntries(keys.map((k) => [k, round(mean(rows.map((r) => r.values[k] ?? 0))!)]));
    return { visual: { kind: 'stages', title, rows }, forModel: { shown: 'sleep_stages', title, unit: 'h', nights: rows.length, averageHours: avg } };
  }

  if (input.kind === 'workouts_by_sport') {
    const days = asDays(input.days, 730, 30);
    const list = await workouts(ctx.scope, ctx.hosted, days, end);
    const by = new Map<string, { count: number; minutes: number }>();
    for (const w of list) {
      const s = by.get(w.sport) ?? { count: 0, minutes: 0 };
      by.set(w.sport, { count: s.count + 1, minutes: s.minutes + w.duration_min });
    }
    const all = [...by].map(([sport, v]) => ({ sport, count: v.count, minutes: Math.round(v.minutes) })).sort((x, y) => y.minutes - x.minutes);
    if (!all.length) throw none('workouts');
    // Up to 8 bars; anything past that is one "Other" bar, so nothing is quietly left out.
    const rest = all.slice(7);
    const items = all.length > 8 ? [...all.slice(0, 7), { sport: `Other (${rest.length} types)`, count: rest.reduce((a, r) => a + r.count, 0), minutes: rest.reduce((a, r) => a + r.minutes, 0) }] : all;
    const total = { count: all.reduce((a, r) => a + r.count, 0), minutes: all.reduce((a, r) => a + r.minutes, 0) };
    return { visual: { kind: 'sports', title, items }, forModel: { shown: 'workouts_by_sport', title, from: addDays(to, -(days - 1)), to, items, total } };
  }

  throw new ToolInputError('kind must be trend, bars, compare, stats, sleep_stages or workouts_by_sport.');
}

const TOOLS: Tool[] = [
  {
    name: 'list_metrics',
    description:
      'List which health metrics this person has data for, with each metric\'s label, unit, first and last date and number of days, plus how many workouts and sleep sessions are recorded. Use it when unsure what data exists or how far back it goes.',
    input_schema: { type: 'object', properties: {}, additionalProperties: false },
    label: () => 'Checking which data you have',
    async run(ctx) {
      const sources = ctx.demo ? ['demo'] : ['apple', 'whoop'];
      const [metrics, w, s] = await Promise.all([
        ctx.scope.db.query<{ metric: string; first: string; last: string; days: number; sources: string }>(
          `SELECT metric, MIN(date) AS first, MAX(date) AS last, COUNT(DISTINCT date)::int AS days, string_agg(DISTINCT source, ',') AS sources
           FROM daily WHERE user_id = $1 AND source = ANY($2) GROUP BY metric ORDER BY metric`,
          [ctx.scope.userId, sources],
        ),
        ctx.scope.db.query<{ n: number; first: string | null; last: string | null }>(
          'SELECT COUNT(*)::int AS n, MIN(date) AS first, MAX(date) AS last FROM workouts WHERE user_id = $1 AND source = ANY($2)',
          [ctx.scope.userId, sources],
        ),
        ctx.scope.db.query<{ n: number; first: string | null; last: string | null }>(
          "SELECT COUNT(*)::int AS n, MIN(date) AS first, MAX(date) AS last FROM events WHERE user_id = $1 AND kind IN ('sleep', 'nap') AND source = ANY($2)",
          [ctx.scope.userId, sources],
        ),
      ]);
      return {
        today: ctx.today,
        metrics: metrics.map((m) => ({
          metric: m.metric,
          label: METRICS[m.metric]?.label ?? m.metric,
          unit: unitOf(m.metric, ctx.units),
          first: m.first,
          last: m.last,
          days: m.days,
          sources: m.sources.split(','),
        })),
        workouts: { count: w[0].n, first: w[0].first, last: w[0].last },
        sleepSessions: { count: s[0].n, first: s[0].first, last: s[0].last },
      };
    },
  },
  {
    name: 'get_day_summary',
    description:
      "The dashboard's summary for one day: heart rate, breathing and temperature with how each compares with the 30 days before, recovery or VO2 max, blood oxygen, HRV against its baseline, last night's sleep, strain or active energy, steps against the goal, that day's timeline (sleep, naps, workouts, mindfulness), the dashboard's insights, and the week so far against the week before.",
    input_schema: {
      type: 'object',
      properties: { date: { type: 'string', description: 'YYYY-MM-DD. Defaults to today.' } },
      additionalProperties: false,
    },
    label: (i) => `Reading your summary for ${typeof i.date === 'string' && i.date ? i.date : 'today'}`,
    async run(ctx, input) {
      const s = await summary(ctx.scope, ctx.hosted, asDate(input.date, ctx, 'date'));
      const vital = (v: (typeof s.vitals)['heart'], metricKind?: Kind, unit = '') =>
        v.latest ? { ...inUnits(metricKind, v.latest.value, unit, ctx.units), date: v.latest.date, source: v.latest.source, vsLast30Days: v.status } : null;
      const latest = (l: { value: number; date: string; source: string } | null, unit: string, kind?: Kind) =>
        l ? { ...inUnits(kind, l.value, unit, ctx.units), date: l.date, source: l.source } : null;
      return {
        date: s.date,
        latestDataDate: s.latestDataDate,
        heartRate: vital(s.vitals.heart, undefined, 'bpm'),
        breathing: vital(s.vitals.breathing, undefined, 'breaths/min'),
        temperature: s.vitals.temp.latest ? { label: s.vitals.temp.label, ...vital(s.vitals.temp, 'temp', '°C') } : null,
        readiness: s.readiness
          ? s.readiness.kind === 'recovery'
            ? { kind: 'WHOOP recovery', ...latest(s.readiness.latest, '%'), average: s.readiness.average === null ? null : round(s.readiness.average), zone: s.readiness.zone }
            : { kind: 'VO2 max', ...latest(s.readiness.latest, 'mL/kg/min'), previous: s.readiness.previous }
          : null,
        bloodOxygen: s.spo2.latest ? { ...latest(s.spo2.latest, '%'), vsLast30Days: s.spo2.status } : null,
        hrv: s.hrv.latest
          ? { measure: s.hrv.metric === 'hrv_rmssd' ? 'RMSSD' : 'SDNN', ...latest(s.hrv.latest, 'ms'), baseline: s.hrv.baseline === null ? null : round(s.hrv.baseline), status: s.hrv.status }
          : null,
        sleep: s.sleep.latest ? { ...latest(s.sleep.latest, 'h asleep'), changeVsUsual: s.sleep.change === null ? null : round(s.sleep.change) } : null,
        load: s.load ? { kind: s.load.kind === 'strain' ? 'WHOOP strain' : 'active energy (kcal)', ...latest(s.load.latest, ''), average: s.load.average === null ? null : round(s.load.average) } : null,
        steps: s.activity.latest ? { ...latest(s.activity.latest, 'steps'), goal: s.stepGoal } : null,
        timeline: s.timeline.events.map((e) => ({ kind: e.kind, title: e.title, start: e.start, end: e.end, detail: e.detail })),
        insights: s.insights.map((i) => i.text),
        weekSoFar: s.week ?? null,
      };
    },
  },
  {
    name: 'get_metric_history',
    description:
      "Daily history of up to 6 metrics (names from list_metrics), as the dashboard computes them, in the person's units, with count, mean, min and max over the range. Long ranges come back as weekly or monthly averages unless you ask for a resolution.",
    input_schema: {
      type: 'object',
      properties: {
        metrics: { type: 'array', items: { type: 'string', enum: Object.keys(METRICS) }, minItems: 1, maxItems: 6 },
        days: { type: 'integer', minimum: 1, maximum: 4000, description: 'How many days back from end_date, inclusive.' },
        end_date: { type: 'string', description: 'YYYY-MM-DD. Defaults to today.' },
        resolution: { type: 'string', enum: ['day', 'week', 'month'], description: 'Defaults to day up to 120 days, week up to 2 years, month beyond.' },
      },
      required: ['metrics', 'days'],
      additionalProperties: false,
    },
    label: (i) => {
      const names = Array.isArray(i.metrics) ? i.metrics.map((m) => (METRICS[String(m)]?.label ?? String(m)).replace(/ \(.*\)$/, '').toLowerCase()) : [];
      return `Looking at ${names.join(', ') || 'your history'} over ${Number(i.days) || '?'} days`;
    },
    async run(ctx, input) {
      const metrics = input.metrics;
      if (!Array.isArray(metrics) || metrics.length < 1 || metrics.length > 6 || !metrics.every((m) => typeof m === 'string' && m in METRICS)) {
        throw new ToolInputError('metrics must be 1 to 6 names from list_metrics.');
      }
      const days = asDays(input.days, 4000, 30);
      const end = asDate(input.end_date, ctx, 'end_date');
      const resolution =
        input.resolution === 'day' || input.resolution === 'week' || input.resolution === 'month' ? input.resolution : days <= 120 ? 'day' : days <= 730 ? 'week' : 'month';
      const t = await trends(ctx.scope, ctx.hosted, metrics as string[], days, end);
      const to = end ?? ctx.today;
      return {
        from: addDays(to, -(days - 1)),
        to,
        resolution,
        metrics: (metrics as string[]).map((m) => {
          const info = METRICS[m];
          const points = t[m].map((p) => ({ date: p.date, value: inUnits(info.kind, p.value, info.unit, ctx.units).value }));
          const values = points.map((p) => p.value);
          const lo = points.reduce<(typeof points)[number] | null>((a, p) => (!a || p.value < a.value ? p : a), null);
          const hi = points.reduce<(typeof points)[number] | null>((a, p) => (!a || p.value > a.value ? p : a), null);
          return {
            metric: m,
            label: info.label,
            unit: unitOf(m, ctx.units),
            daysWithData: points.length,
            mean: values.length ? round(mean(values)!) : null,
            min: lo,
            max: hi,
            points: bucket(points, resolution),
          };
        }),
      };
    },
  },
  {
    name: 'get_workouts',
    description:
      'Workouts in a date range, newest first (Apple and WHOOP copies of the same session are merged), with totals by sport. Each has sport, start time, duration, energy, distance, average and max heart rate, and WHOOP strain when available.',
    input_schema: {
      type: 'object',
      properties: {
        days: { type: 'integer', minimum: 1, maximum: 4000 },
        end_date: { type: 'string', description: 'YYYY-MM-DD. Defaults to today.' },
        sport: { type: 'string', description: 'Only workouts whose sport contains this text, e.g. "run".' },
      },
      required: ['days'],
      additionalProperties: false,
    },
    label: (i) => `Looking at workouts over ${Number(i.days) || '?'} days`,
    async run(ctx, input) {
      const days = asDays(input.days, 4000, 30);
      const sport = typeof input.sport === 'string' ? input.sport.trim().toLowerCase() : '';
      const list = (await workouts(ctx.scope, ctx.hosted, days, asDate(input.end_date, ctx, 'end_date')))
        .filter((w) => !sport || w.sport.toLowerCase().includes(sport))
        .sort((a, b) => b.start.localeCompare(a.start));
      const bySport = new Map<string, { count: number; minutes: number; kcal: number }>();
      for (const w of list) {
        const s = bySport.get(w.sport) ?? { count: 0, minutes: 0, kcal: 0 };
        bySport.set(w.sport, { count: s.count + 1, minutes: s.minutes + w.duration_min, kcal: s.kcal + (w.energy_kcal ?? 0) });
      }
      return {
        count: list.length,
        totalsBySport: [...bySport].map(([name, s]) => ({ sport: name, count: s.count, minutes: Math.round(s.minutes), kcal: Math.round(s.kcal) })),
        workouts: list.slice(0, 100).map((w) => ({
          date: w.date,
          sport: w.sport,
          start: w.start,
          minutes: Math.round(w.duration_min),
          kcal: w.energy_kcal === null ? null : Math.round(w.energy_kcal),
          distance: w.distance_m === null ? null : inUnits('distance', w.distance_m / 1000, 'km', ctx.units),
          avgHr: w.avg_hr === null ? null : Math.round(w.avg_hr),
          maxHr: w.max_hr === null ? null : Math.round(w.max_hr),
          strain: w.strain === null ? null : round(w.strain),
          source: w.source,
        })),
        truncated: list.length > 100,
      };
    },
  },
  {
    name: 'get_sleep_sessions',
    description:
      'Sleep and nap sessions in a date range with their start and end times (in the local time they were recorded) and length, for questions about bedtimes, wake times and consistency. The same night can appear once from each source.',
    input_schema: {
      type: 'object',
      properties: {
        days: { type: 'integer', minimum: 1, maximum: 366 },
        end_date: { type: 'string', description: 'YYYY-MM-DD. Defaults to today.' },
      },
      required: ['days'],
      additionalProperties: false,
    },
    label: (i) => `Looking at sleep times over ${Number(i.days) || '?'} days`,
    async run(ctx, input) {
      const days = asDays(input.days, 366, 14);
      const to = asDate(input.end_date, ctx, 'end_date') ?? ctx.today;
      const rows = await ctx.scope.db.query<{ kind: string; start: string; end: string; date: string; source: string }>(
        `SELECT kind, start, "end", date, source FROM events
         WHERE user_id = $1 AND kind IN ('sleep', 'nap') AND date BETWEEN $2 AND $3 AND source = ANY($4) ORDER BY start`,
        [ctx.scope.userId, addDays(to, -(days - 1)), to, ctx.demo ? ['demo'] : ['apple', 'whoop']],
      );
      return {
        sessions: rows.map((r) => ({
          kind: r.kind,
          date: r.date,
          start: r.start,
          end: r.end,
          hours: round((Date.parse(r.end) - Date.parse(r.start)) / 3_600_000),
          source: r.source,
        })),
      };
    },
  },
  {
    name: 'get_cycle',
    when: (ctx) => ctx.cycle,
    description:
      "This person's menstrual cycle tracking: periods detected from what they logged; each cycle with its length, period length, ovulation (from a sustained temperature rise on their thermometer, Apple Watch or WHOOP, or the day after a positive LH test) and follicular and luteal phase lengths; the current cycle day and phase; estimates of the next period (with a range), ovulation and each fertile day's relative chance; patterns from past cycles (resting heart rate, HRV and temperature after ovulation against before it, when symptoms tend to come, cycles outside the usual ranges); and the entries logged day by day (flow, period start, spotting, ovulation tests, cervical mucus, basal body temperature, symptoms, disturbed temperatures, sexual activity). Periods, cycles, estimates and patterns always use all history; days limits only the entries.",
    input_schema: {
      type: 'object',
      properties: {
        days: { type: 'integer', minimum: 1, maximum: 730, description: 'How many days of entries back from end_date, inclusive. Defaults to 90.' },
        end_date: { type: 'string', description: 'YYYY-MM-DD. Defaults to today.' },
      },
      additionalProperties: false,
    },
    label: () => 'Looking at your cycle',
    async run(ctx, input) {
      if (!ctx.cycle) throw new ToolInputError('Cycle tracking is off.');
      const v = await cycleView(ctx.scope, ctx.hosted, { days: asDays(input.days, 730, 90), end: asDate(input.end_date, ctx, 'end_date') });
      return {
        today: v.today,
        note: "Next period, ovulation and fertile days are estimates from this person's own cycles (typical cycles fill in while they have fewer than two) and this cycle's temperatures and tests: not a diagnosis, and not reliable as contraception. No day is ever safe. Temperatures are deviations from the person's own level on each device, in °C. Patterns are associations, not causes.",
        currentCycle: v.current,
        phase: v.phase,
        stats: v.stats,
        estimate: v.estimate ?? v.earlyEstimate ?? null,
        estimateRestsOnTypicalCycles: !v.estimate && Boolean(v.earlyEstimate),
        noEstimate: v.noEstimate === 'stale' ? 'The latest logged period is long past.' : !v.estimate && !v.earlyEstimate ? 'No period logged yet.' : null,
        fertileDays: v.fertility,
        periods: v.periods.slice(-12),
        cycles: (v.history ?? []).slice(-12),
        patterns: v.insights,
        entries: v.days.map(({ apple: _a, manual: _m, bbt, ...d }) => ({ ...d, ...(bbt !== undefined && { basalTemp: inUnits('temp', bbt, '°C', ctx.units) }) })),
      };
    },
  },
  {
    name: 'get_nutrition',
    when: (ctx) => ctx.nutrition !== null,
    description:
      "What this person logged, in healthOS itself (app 'healthOS', some of it estimated from a photo or description) or in their food app (MyFitnessPal, Cronometer and others, through Apple Health), as daily totals: energy, protein, carbohydrates, fat, fiber, sugar, saturated fat, sodium and alcoholic drinks, as far as their app records them and their setting shows them. One app per day, never a sum of apps. Days with nothing logged are left out: that means nothing was logged, not that nothing was eaten.",
    input_schema: {
      type: 'object',
      properties: {
        days: { type: 'integer', minimum: 1, maximum: 366, description: 'How many days back from end_date, inclusive. Defaults to 30.' },
        end_date: { type: 'string', description: 'YYYY-MM-DD. Defaults to today.' },
      },
      additionalProperties: false,
    },
    label: () => 'Looking at your food log',
    async run(ctx, input) {
      if (!ctx.nutrition) throw new ToolInputError('Nutrition is off.');
      const v = await nutritionView(ctx.scope, ctx.hosted, { days: asDays(input.days, 366, 30), end: asDate(input.end_date, ctx, 'end_date') });
      const hidden = v.numbers === 'none' ? 'They chose to see no amounts, so none are included: only which days they logged.' : v.numbers === 'no_energy' ? 'They chose not to see calories, so energy is left out.' : null;
      return {
        today: v.today,
        window: { start: v.start, end: v.end },
        note: `Self-reported and often incomplete. Energy in kcal, masses in grams except sodium (mg), alcohol in drinks.${hidden ? ` ${hidden}` : ''}`,
        daysLogged: v.days.length,
        apps: v.apps,
        days: v.days.map((d) => ({ date: d.date, app: d.app, ...(v.numbers !== 'none' && { values: d.values }) })),
      };
    },
  },
  {
    name: 'get_lab_results',
    description:
      "This person's lab test results (blood work and other lab panels) that they added to healthOS, typed in or read from a report they uploaded and checked. For each marker: the latest result exactly as printed (a \"<\" or \">\" means the true value is beyond that number), its unit, the reference range the lab printed beside it, where the result sits against that range, the collection date, lab and panel, and earlier results of the same marker. Only when a report printed no range is a typical adult range used instead, and it's labelled so. Use it for any question about their labs, blood tests or biomarkers. Describe a result only as below, within or above the lab's range (or the typical range, saying which), never as a diagnosis or as good or bad, and suggest talking a result outside its range over with their clinician. Ranges differ between labs and units, so read each result against the range printed with it.",
    input_schema: {
      type: 'object',
      properties: { marker: { type: 'string', description: 'Only this marker, by name, e.g. "LDL" or "vitamin D". Leave out for all of them.' } },
      additionalProperties: false,
    },
    label: () => 'Looking at your lab results',
    async run(ctx, input) {
      const v = await labsView(ctx.scope, ctx.hosted);
      const asked = typeof input.marker === 'string' ? input.marker.trim().slice(0, 80) : '';
      const key = asked ? matchBiomarker(asked) : null;
      const words = normalizeName(asked);
      const markers = v.markers.filter(
        (m) => !words || m.key === key || normalizeName(m.name).includes(words) || m.history.some((r) => normalizeName(r.name).includes(words)),
      );
      const against = (r: LabResult) => (r.range?.kind === 'typical' ? 'the typical adult range' : "the lab's range");
      const one = (r: LabResult) => ({
        collected: r.collected,
        printedName: r.name,
        result: r.valueText,
        unit: r.unit,
        range: r.range
          ? {
              printed: r.range.text,
              low: r.range.low,
              high: r.range.high,
              from: r.range.kind === 'lab' ? 'printed by the lab' : `typical adult range${r.range.note ? ` (${r.range.note})` : ''}, used because the report printed none`,
            }
          : null,
        position: r.status ? `${r.status} ${against(r)}` : r.range ? 'not placed against the range (no number, or a "<"/">" result that could fall either side)' : 'no range to compare with',
        ...(r.lab && { lab: r.lab }),
        ...(r.panel && { panel: r.panel }),
      });
      return {
        today: v.today,
        ...(v.demo && { demo: "These are healthOS's demo results, not this person's own." }),
        note: 'Results are as printed on their reports. Position is only where a number sits against a range: not a diagnosis.',
        markersFound: markers.length,
        ...(asked && !markers.length && { notFound: `No results for "${asked}". They have ${v.markers.length} markers recorded.` }),
        markers: markers.map((m) => ({ marker: m.name, latest: one(m.latest), earlier: m.history.slice(0, -1).slice(-10).map(one) })),
      };
    },
  },
  {
    name: 'show_visual',
    visual: true,
    description:
      "Put a chart or a few stat tiles into your answer, drawn from this person's own data: you choose what to show and the numbers are read for you, in their units. Use it when a picture is clearer than words: a change over time (trend for a line, bars for daily amounts like steps or sleep), two periods side by side (compare), a few numbers at once (stats), sleep stages night by night (sleep_stages), or workouts by type (workouts_by_sport). Not for a single number. At most 3 per answer. It returns what it drew, so your words can refer to it without repeating it.",
    input_schema: {
      type: 'object',
      properties: {
        kind: { type: 'string', enum: ['trend', 'bars', 'compare', 'stats', 'sleep_stages', 'workouts_by_sport'] },
        title: { type: 'string', description: 'A short plain title, e.g. "Resting heart rate, last 30 days".' },
        metric: { type: 'string', enum: METRIC_NAMES, description: 'For trend, bars and compare.' },
        metrics: { type: 'array', items: { type: 'string', enum: METRIC_NAMES }, minItems: 1, maxItems: 4, description: 'For stats.' },
        stat: { type: 'string', enum: ['average', 'latest'], description: 'For stats: each metric\'s average over days (the default) or its latest value.' },
        days: {
          type: 'integer',
          minimum: 1,
          maximum: 730,
          description: 'Days back from end_date, inclusive. Defaults: 30 for trend, bars and workouts_by_sport; 7 for stats averages; 14 for sleep_stages (at most 90). Over 120 days, trend and bars show weekly averages.',
        },
        end_date: { type: 'string', description: 'YYYY-MM-DD. Defaults to today.' },
        periods: {
          type: 'array',
          minItems: 2,
          maxItems: 2,
          description: 'For compare: the two periods, the more recent first, e.g. [{ label: "This week", days: 7 }, { label: "The week before", days: 7, end_date: <7 days ago> }].',
          items: {
            type: 'object',
            properties: { label: { type: 'string' }, days: { type: 'integer', minimum: 1, maximum: 366 }, end_date: { type: 'string', description: 'YYYY-MM-DD. Defaults to today.' } },
            required: ['label', 'days'],
            additionalProperties: false,
          },
        },
      },
      required: ['kind', 'title'],
      additionalProperties: false,
    },
    label: (i) => {
      const m = typeof i.metric === 'string' ? lowerLabel(i.metric) : '';
      if (i.kind === 'compare') return `Comparing your ${m || 'numbers'}`;
      if (i.kind === 'stats') return 'Putting your numbers side by side';
      if (i.kind === 'sleep_stages') return 'Drawing your sleep stages';
      if (i.kind === 'workouts_by_sport') return 'Drawing your workouts by type';
      return `Drawing your ${m || 'data'}${Number(i.days) ? ` over ${Number(i.days)} days` : ''}`;
    },
    async run(ctx, input) {
      // Earlier rounds' charts count here; charts drawn together in one round are counted as they go out.
      if (ctx.shown >= MAX_VISUALS) throw new ToolInputError(TOO_MANY);
      return buildVisual(ctx, input);
    },
  },
];

/** The tools this person's question may use. */
const toolsFor = (ctx: Ctx) => TOOLS.filter((t) => !t.when || t.when(ctx));

/** What the API sees: the definitions without our run/label functions. Eager streaming, so we validate inputs ourselves. */
const apiTools = (tools: Tool[]): BetaTool[] => tools.map(({ name, description, input_schema }) => ({ name, description, input_schema, eager_input_streaming: true }));

/** Who McFly is, who it's talking with and when: the opening of both the chat's and the weekly digest's instructions. */
function intro(name: string, today: string, timeZone: string | null, units: Units) {
  const weekday = new Date(`${today}T12:00:00Z`).toLocaleDateString('en-US', { weekday: 'long', timeZone: 'UTC' });
  return `You are McFly, the health assistant in healthOS, a private dashboard that brings together one person's Apple Health and WHOOP data. You're talking with ${name || 'the person who owns this account'}. Today is ${weekday}, ${today}${timeZone ? ` (${timeZone})` : ''}. They use ${units === 'imperial' ? 'imperial units (°F, lb, miles)' : 'metric units (°C, kg, km)'}`;
}

const DATA_NOTES = `About the data
- Daily values are what the dashboard shows. On days both devices measured blood oxygen, respiratory rate or sleep, the two are averaged when they agree, and WHOOP's value is used when they don't.
- Resting heart rate comes from WHOOP (measured asleep) when present and otherwise from Apple Watch (measured during the day), so it can shift a few bpm when the source changes.
- HRV is either RMSSD (WHOOP, or newer Apple Watch) or SDNN (Apple Watch). The two measures aren't comparable, so don't compare one with the other.
- Recovery, strain, and sleep performance, efficiency and consistency are WHOOP's own scores.`;

const BOUNDARIES = `Boundaries
- You're not a doctor and can't diagnose. Give general, evidence-based wellness context. When something looks concerning, such as a sustained change, a value well outside their usual range, or a symptom they mention, suggest checking with a clinician. If they describe an emergency, tell them to contact emergency services.
- You can only read this person's own data. You can't change data or settings, see anyone else's data, or browse the web.`;

/** Only while nutrition is on. Food logs need care: no targets, no judgement, and nothing the person chose not to see. */
function nutritionNotes(numbers: NutritionNumbers) {
  const hidden =
    numbers === 'none'
      ? ' They chose to see no amounts: never state or estimate how much they ate or drank, in any unit.'
      : numbers === 'no_energy'
        ? ' They chose not to see calories: never state, estimate or compute energy or calories.'
        : '';
  return `
- They log food, and get_nutrition reads it. Logs are self-reported and incomplete, and a day missing means nothing was logged.${hidden}
- About food: no calorie, weight or macro targets unless they give you one, no "good" or "bad" foods, no comments on body size, and no advice to eat less unless they're following a clinician's plan. Patterns with sleep or recovery are associations, not causes. If they mention distress about food or eating, respond with care and suggest talking to someone they trust or a professional, such as an eating disorder helpline.`;
}

function systemPrompt(name: string, today: string, timeZone: string | null, units: Units, cycle: boolean, nutrition: NutritionNumbers | null) {
  return `${intro(name, today, timeZone, units)}, and the tools already return values in those units.

How to answer
- Look numbers up with the tools before answering. Don't estimate or invent values, and mention the dates (and the source, when it matters) of the figures you use.
- If the data needed isn't there, such as a metric they don't record or a gap in dates, say so plainly.
- Shape every answer the same simple way:
  1. The answer first, in one plain sentence.
  2. When a picture says it faster (a change over time, two periods compared, several numbers at once, sleep stages, workouts by type), show it with show_visual: usually one, at most two for one question. Skip it for a single number or a yes/no.
  3. Then at most three short "- " bullets with the numbers that matter, rounded, and their dates. Don't walk through the chart point by point; it's right there.
  4. If it helps, one practical takeaway, in a sentence.
- Plain words. Explain a term in a few words if you have to use one. **Bold** at most two key numbers. No tables or headings.
- Where you can, compare with their own history (their usual range, recent weeks) rather than population norms.

${DATA_NOTES}${
    cycle
      ? `
- They track their menstrual cycle, and get_cycle reads it. Its next period, ovulation and fertile days are estimates from their own cycles and temperatures: call them estimates, never call any day safe, and never present them as contraception or a diagnosis.`
      : ''
  }${nutrition ? nutritionNotes(nutrition) : ''}

${BOUNDARIES}`;
}

/** The weekly digest's instructions: the chat's persona and boundaries, no tools, and nothing about cycle tracking. */
function digestPrompt(name: string, today: string, timeZone: string | null, units: Units) {
  return `${intro(name, today, timeZone, units)}.

This time you're writing their weekly digest, a short recap of last week that they'll read in the app rather than a chat. Their week arrives as JSON: daily averages next to the week before, workouts, the dashboard's insights, patterns from their own history, and any heads-ups about recent readings.

How to write it
- 3 to 5 warm, plain sentences on how the week went, using a few of the numbers given (rounded), then one gentle, concrete suggestion for the week ahead.
- 120 words at most. Light markdown: **bold** for a number or two, and no headings, bullets or tables. No greeting or sign-off.
- Use only what's in the JSON. Leave out anything that isn't there rather than guessing.
- Patterns are correlations in their own history: say what tends to go together, never that one thing causes another. Prefer "may" and "tends to", and never word anything as a diagnosis.

${DATA_NOTES}

${BOUNDARIES}`;
}

// ---------- the conversation the browser sends ----------

type Turn = { role: 'user' | 'assistant'; content: string };

function parseHistory(body: unknown): Turn[] | string {
  const raw = (body as { messages?: unknown } | null)?.messages;
  if (!Array.isArray(raw) || raw.length === 0) return 'Ask a question.';
  const turns = raw.slice(-MAX_TURNS);
  let total = 0;
  for (let i = 0; i < turns.length; i++) {
    const t = turns[i] as { role?: unknown; content?: unknown };
    if ((t.role !== 'user' && t.role !== 'assistant') || typeof t.content !== 'string' || !t.content.trim()) return 'That conversation looks malformed. Start a new chat.';
    if (t.role === 'user' && t.content.length > MAX_QUESTION) return `Keep questions under ${MAX_QUESTION.toLocaleString('en-US')} characters.`;
    total += t.content.length;
  }
  if (total > MAX_HISTORY_CHARS) return 'This chat is too long. Start a new one.';
  // Trimming to the last turns can leave an assistant turn first; drop it so the history starts with a question.
  const out = (turns as Turn[]).map((t) => ({ role: t.role, content: t.content }));
  while (out.length && out[0].role !== 'user') out.shift();
  if (!out.length || out[out.length - 1].role !== 'user') return 'Ask a question.';
  for (let i = 1; i < out.length; i++) if (out[i].role === out[i - 1].role) return 'That conversation looks malformed. Start a new chat.';
  return out;
}

// ---------- per-person daily limit ----------

/** Count a question against today's limit; null when the limit is reached. Atomic, so parallel requests can't overshoot. */
export async function claimQuestion(db: Db, userId: string, day: string, limit: number): Promise<number | null> {
  const [row] = await db.query<{ questions: number }>(
    `INSERT INTO mcfly_usage (user_id, day, questions) VALUES ($1, $2, 1)
     ON CONFLICT (user_id, day) DO UPDATE SET questions = mcfly_usage.questions + 1 WHERE mcfly_usage.questions < $3
     RETURNING questions`,
    [userId, day, limit],
  );
  return row ? Number(row.questions) : null;
}

/** Give back a question that never reached Claude (a food estimate whose call failed). */
export async function refundQuestion(db: Db, userId: string, day: string) {
  await db.query('UPDATE mcfly_usage SET questions = questions - 1 WHERE user_id = $1 AND day = $2 AND questions > 0', [userId, day]);
}

/** The limit counts by UTC date, so changing your own time zone can't reset it. */
export const usageDay = () => new Date().toISOString().slice(0, 10);

async function usedToday(db: Db, userId: string, day: string) {
  const [row] = await db.query<{ questions: number }>('SELECT questions FROM mcfly_usage WHERE user_id = $1 AND day = $2', [userId, day]);
  return row ? Number(row.questions) : 0;
}

// ---------- the weekly digest ----------

const DIGEST_KEY = 'mcfly_digest';
/** A week with fewer days of data than this gets no digest, and costs nothing. */
const DIGEST_MIN_DAYS = 3;

/** The last completed Monday to Sunday before `today`: on a Monday, the week that ended yesterday. */
export function digestWeek(today: string) {
  const end = addDays(weekStart(today), -1);
  return { start: addDays(end, -6), end };
}

/** The kept digest, and whether it was written from demo data (one kept before that was known counts as real). */
async function cachedDigest(db: Db, userId: string): Promise<{ digest: Digest; demo: boolean } | null> {
  const raw = await getUserSetting(db, userId, DIGEST_KEY);
  if (!raw) return null;
  try {
    const d = JSON.parse(raw) as Partial<Digest> & { demo?: unknown };
    if (typeof d.weekStart !== 'string' || typeof d.weekEnd !== 'string' || typeof d.text !== 'string' || typeof d.generatedAt !== 'string') return null;
    return { digest: { weekStart: d.weekStart, weekEnd: d.weekEnd, text: d.text, generatedAt: d.generatedAt }, demo: d.demo === true };
  } catch {
    return null;
  }
}

/** Days in the week with anything recorded: a daily value, a workout, or a sleep, nap or mindful session. Never the cycle log. */
async function daysWithData(scope: Scope, demo: boolean, week: { start: string; end: string }) {
  const [row] = await scope.db.query<{ n: number }>(
    `SELECT COUNT(DISTINCT date)::int AS n FROM (
       SELECT date FROM daily WHERE user_id = $1 AND date BETWEEN $2 AND $3 AND source = ANY($4)
       UNION ALL SELECT date FROM workouts WHERE user_id = $1 AND date BETWEEN $2 AND $3 AND source = ANY($4)
       UNION ALL SELECT date FROM events WHERE user_id = $1 AND date BETWEEN $2 AND $3 AND source = ANY($4)) AS days`,
    [scope.userId, week.start, week.end, sourceList(demo)],
  );
  return row ? Number(row.n) : 0;
}

/**
 * What the digest is written from: the summary as of the week's Sunday (its week against the week before,
 * insights and heads-ups) and the patterns in the person's history. Summary and patterns never read the
 * cycle log, and nothing here does either.
 */
async function digestInput(scope: Scope, hosted: boolean, week: { start: string; end: string }, days: number) {
  const [s, p] = await Promise.all([summary(scope, hosted, week.end), patterns(scope, hosted)]);
  const r = (v: number | null, places = 1) => (v === null ? null : Math.round(v * 10 ** places) / 10 ** places);
  const pair = (x: { avg: number | null; prev: number | null }, places = 1) =>
    x.avg === null && x.prev === null ? undefined : { thisWeek: r(x.avg, places), weekBefore: r(x.prev, places) };
  const w = s.week;
  return {
    week: { start: week.start, end: week.end, daysWithData: days },
    ...(w && {
      sleepHoursPerNight: pair(w.sleep, 2),
      steps:
        w.steps.avg === null && w.steps.prev === null
          ? undefined
          : { dailyAverage: r(w.steps.avg, 0), weekBefore: r(w.steps.prev, 0), goal: s.stepGoal, daysAtGoal: w.steps.goalDays, daysWithSteps: w.steps.daysWithData },
      workouts: { count: w.workouts.count, minutes: Math.round(w.workouts.minutes) },
      hrvMs: pair(w.hrv) && { measure: s.hrv.metric === 'hrv_rmssd' ? 'RMSSD' : 'SDNN', ...pair(w.hrv) },
      restingHeartRateBpm: pair(w.restingHr),
      whoopRecoveryPercent: pair(w.recovery, 0),
    }),
    insights: s.insights.map((i) => i.text),
    patterns: p.patterns.map((x) => x.text),
    headsUps: (s.flags ?? []).map((f) => `${f.title}. ${f.text}`),
  };
}

type DigestResult = { status: number; body: DigestReply | { error: string } };

// ---------- the router ----------

export type McflyOptions = { hosted: boolean; client?: () => McflyClient | null };

export const defaultClient = () => (process.env.ANTHROPIC_API_KEY ? new Anthropic() : null);

export function mcflyRouter(db: Db, { hosted, client = defaultClient }: McflyOptions) {
  const router = express.Router();

  router.get('/', async (_req: Request, res: Response) => {
    const user = currentUser(res);
    const platform = await platformSettings(db);
    const limit = Number(platform.mcfly_daily_limit);
    res.json({ configured: Boolean(client()), limit, usedToday: await usedToday(db, user.id, usageDay()) });
  });

  /** Last week's digest, written at most once per person per week and kept in user_settings. */
  async function weeklyDigest(userId: string): Promise<DigestResult> {
    const anthropic = client();
    if (!anthropic) return { status: 200, body: { configured: false, digest: null, reason: 'not_configured' } };
    const scope: Scope = { db, userId };
    const [platform, rc, kept] = await Promise.all([platformSettings(db), requestContext(scope, hosted), cachedDigest(db, userId)]);
    const limit = Number(platform.mcfly_daily_limit);
    if (!(limit > 0)) return { status: 200, body: { configured: true, digest: null, reason: 'off' } };
    // A digest of the demo data isn't this person's week once their own data arrives (or the other way round).
    const cached = kept && kept.demo === rc.demo ? kept.digest : null;
    const week = digestWeek(rc.today);
    if (cached && cached.weekEnd >= week.end) return { status: 200, body: { configured: true, digest: cached } };
    const days = await daysWithData(scope, rc.demo, week);
    if (days < DIGEST_MIN_DAYS) return { status: 200, body: { configured: true, digest: null, reason: 'no_data' } };
    // Claimed before the model is called, like a question, so the limit holds whatever happens next.
    const day = usageDay();
    if ((await claimQuestion(db, userId, day, limit)) === null) return { status: 200, body: { configured: true, digest: cached, reason: 'limit' } };

    let inputTokens = 0;
    let outputTokens = 0;
    try {
      const input = await digestInput(scope, hosted, week, days);
      // No cache_control: each digest's prompt is read once.
      const message = await anthropic.beta.messages.create({
        model: platform.mcfly_model,
        max_tokens: 16_000,
        output_config: { effort: 'medium' },
        betas: ['server-side-fallback-2026-07-01'],
        fallbacks: 'default',
        system: digestPrompt(rc.settings.name, rc.today, rc.settings.timeZone, rc.settings.units),
        messages: [{ role: 'user', content: `Write my digest for the week of ${week.start} to ${week.end}.\n\n${JSON.stringify(input)}` }],
      });
      inputTokens = message.usage.input_tokens + (message.usage.cache_read_input_tokens ?? 0) + (message.usage.cache_creation_input_tokens ?? 0);
      outputTokens = message.usage.output_tokens;
      const text =
        message.stop_reason === 'refusal'
          ? ''
          : message.content
              .filter((b): b is Anthropic.Beta.BetaTextBlock => b.type === 'text')
              .map((b) => b.text)
              .join('')
              .trim();
      if (!text) throw new Error(message.stop_reason === 'refusal' ? 'refusal' : 'empty');
      const digest: Digest = { weekStart: week.start, weekEnd: week.end, text, generatedAt: new Date().toISOString() };
      await setUserSetting(db, userId, DIGEST_KEY, JSON.stringify({ ...digest, demo: rc.demo }));
      return { status: 200, body: { configured: true, digest } };
    } catch (err) {
      // Log the kind of failure only: never the data or the digest.
      console.error('mcfly digest:', err instanceof Anthropic.APIError ? `API ${err.status}` : err instanceof Error ? err.message : 'error');
      // A digest that wasn't written doesn't count against the limit.
      await db.query('UPDATE mcfly_usage SET questions = GREATEST(questions - 1, 0) WHERE user_id = $1 AND day = $2', [userId, day]).catch(() => {});
      return { status: 503, body: { error: "McFly couldn't write this week's digest right now. Try again later." } };
    } finally {
      await db
        .query('UPDATE mcfly_usage SET input_tokens = input_tokens + $3, output_tokens = output_tokens + $4 WHERE user_id = $1 AND day = $2', [
          userId,
          day,
          inputTokens,
          outputTokens,
        ])
        .catch(() => {});
    }
  }

  // One digest at a time per person: clients opening at once share it, and the one charge for it.
  const digesting = new Map<string, Promise<DigestResult>>();

  router.get('/digest', async (_req: Request, res: Response) => {
    const user = currentUser(res);
    let job = digesting.get(user.id);
    if (!job) {
      job = weeklyDigest(user.id).finally(() => digesting.delete(user.id));
      digesting.set(user.id, job);
    }
    const { status, body } = await job;
    res.status(status).json(body);
  });

  router.post('/chat', async (req: Request, res: Response) => {
    const user = currentUser(res);
    const scope: Scope = { db, userId: user.id };
    const anthropic = client();
    if (!anthropic) return void res.status(503).json({ error: "Ask McFly isn't set up on this server yet." });
    const history = parseHistory(req.body);
    if (typeof history === 'string') return void res.status(400).json({ error: history });

    const [platform, rc] = await Promise.all([platformSettings(db), requestContext(scope, hosted)]);
    const limit = Number(platform.mcfly_daily_limit);
    if (!(limit > 0)) return void res.status(403).json({ error: 'Ask McFly is turned off right now.' });
    const day = usageDay();
    if ((await claimQuestion(db, user.id, day, limit)) === null) {
      return void res.status(429).json({ error: `You've asked McFly ${limit} questions today, the daily limit. Ask again tomorrow.` });
    }

    const nutrition = rc.settings.nutrition ? rc.settings.nutritionNumbers : null;
    const ctx: Ctx = { scope, hosted, units: rc.settings.units, today: rc.today, demo: rc.demo, cycle: rc.settings.cycleTracking, nutrition, stepGoal: rc.settings.stepGoal, shown: 0 };
    const tools = toolsFor(ctx);
    const toolByName = new Map(tools.map((t) => [t.name, t]));
    const messages: BetaMessageParam[] = history.map((t) => ({ role: t.role, content: t.content }));
    const system = systemPrompt(rc.settings.name, rc.today, rc.settings.timeZone, rc.settings.units, ctx.cycle, ctx.nutrition);

    res.status(200);
    res.setHeader('Content-Type', 'text/event-stream; charset=utf-8');
    res.setHeader('Cache-Control', 'no-store, no-transform');
    res.setHeader('X-Accel-Buffering', 'no');
    res.flushHeaders();
    const send = (event: string, data: unknown) => {
      if (!res.writableEnded) res.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`);
    };
    const abort = new AbortController();
    res.on('close', () => {
      if (!res.writableFinished) abort.abort();
    });

    let inputTokens = 0;
    let outputTokens = 0;
    let wroteText = false;
    try {
      let jsonRetries = 0;
      for (let round = 0; ; round++) {
        if (round >= MAX_ROUNDS) throw new Error('rounds');
        const stream = anthropic.beta.messages.stream(
          {
            model: platform.mcfly_model,
            max_tokens: 32_000,
            output_config: { effort: 'medium' },
            // A classifier false positive is retried on Anthropic's recommended model instead of failing.
            betas: ['server-side-fallback-2026-07-01'],
            fallbacks: 'default',
            cache_control: { type: 'ephemeral' },
            system,
            tools: apiTools(tools),
            messages,
          },
          { signal: abort.signal },
        );
        let roundText = false;
        stream.on('text', (delta) => {
          // Text from an earlier round (a note before reading data) gets a paragraph break before the next.
          if (!roundText && wroteText) send('text', { text: '\n\n' });
          roundText = wroteText = true;
          send('text', { text: delta });
        });
        let message: Anthropic.Beta.BetaMessage;
        try {
          message = await stream.finalMessage();
          jsonRetries = 0;
        } catch (err) {
          // With eager input streaming, a tool input that isn't parseable JSON rejects the turn: re-issue it.
          if (err instanceof Anthropic.APIError || abort.signal.aborted || jsonRetries++ >= 2) throw err;
          continue;
        }
        inputTokens += message.usage.input_tokens + (message.usage.cache_read_input_tokens ?? 0) + (message.usage.cache_creation_input_tokens ?? 0);
        outputTokens += message.usage.output_tokens;

        if (message.stop_reason === 'refusal') {
          send('refusal', { error: "McFly can't help with that one. Try asking another way." });
          break;
        }
        if (message.stop_reason === 'pause_turn') {
          messages.push({ role: 'assistant', content: message.content });
          continue;
        }
        const calls = message.content.filter((b): b is BetaToolUseBlock => b.type === 'tool_use');
        if (message.stop_reason !== 'tool_use' || calls.length === 0) {
          if (message.stop_reason === 'max_tokens') send('text', { text: '\n\n(The answer was cut off. Ask a narrower question.)' });
          break;
        }

        messages.push({ role: 'assistant', content: message.content });
        // Pictures go out once every call in the round is done, in the order McFly asked for them.
        const drawn: (McflyVisual | null)[] = calls.map(() => null);
        const results = await Promise.all(
          calls.map(async (call, i): Promise<BetaToolResultBlockParam> => {
            const tool = toolByName.get(call.name);
            const input = call.input && typeof call.input === 'object' && !Array.isArray(call.input) ? (call.input as Record<string, unknown>) : null;
            if (!tool || !input) return { type: 'tool_result', tool_use_id: call.id, is_error: true, content: `Unknown tool or malformed input: ${call.name}` };
            send('tool', { label: tool.label(input) });
            try {
              const result = await tool.run(ctx, input);
              if (tool.visual) {
                // The picture goes to the browser; McFly gets back what was drawn.
                const { visual, forModel } = result as { visual: McflyVisual; forModel: unknown };
                drawn[i] = visual;
                return { type: 'tool_result', tool_use_id: call.id, content: JSON.stringify(forModel) };
              }
              return { type: 'tool_result', tool_use_id: call.id, content: JSON.stringify(result) };
            } catch (err) {
              if (err instanceof ToolInputError) return { type: 'tool_result', tool_use_id: call.id, is_error: true, content: err.message };
              throw err;
            }
          }),
        );
        // Only the first charts that fit: one past the limit becomes an error McFly reads, like any other.
        drawn.forEach((visual, i) => {
          if (!visual) return;
          if (ctx.shown < MAX_VISUALS) {
            ctx.shown++;
            send('visual', { visual });
          } else {
            results[i] = { type: 'tool_result', tool_use_id: calls[i].id, is_error: true, content: TOO_MANY };
          }
        });
        messages.push({ role: 'user', content: results });
      }
      send('done', {});
    } catch (err) {
      if (!abort.signal.aborted) {
        const message =
          err instanceof Anthropic.AuthenticationError || err instanceof Anthropic.PermissionDeniedError
            ? "McFly's API key isn't working. The admin needs to check ANTHROPIC_API_KEY."
            : err instanceof Anthropic.RateLimitError || err instanceof Anthropic.InternalServerError
              ? 'McFly is busy right now. Try again in a minute.'
              : err instanceof Anthropic.BadRequestError
                ? "McFly couldn't take that request. Start a new chat and try again."
                : err instanceof Error && err.message === 'rounds'
                  ? 'McFly took too many steps on that one. Try a narrower question.'
                  : "McFly couldn't answer right now. Try again.";
        // Log the kind of failure only: never the question, the data or the answer.
        console.error('mcfly:', err instanceof Anthropic.APIError ? `API ${err.status}` : err instanceof Error ? err.name : 'error');
        send('error', { error: message });
      }
      // A question that failed before any answer doesn't count against the limit.
      if (!wroteText) {
        await db.query('UPDATE mcfly_usage SET questions = GREATEST(questions - 1, 0) WHERE user_id = $1 AND day = $2', [user.id, day]).catch(() => {});
      }
    } finally {
      await db
        .query('UPDATE mcfly_usage SET input_tokens = input_tokens + $3, output_tokens = output_tokens + $4 WHERE user_id = $1 AND day = $2', [
          user.id,
          day,
          inputTokens,
          outputTokens,
        ])
        .catch(() => {});
      res.end();
    }
  });

  return router;
}
