// Ask McFly (/api/mcfly): a Claude agent that answers questions about the signed-in person's own health
// data. It can only read, through the tools below, and every tool runs in that person's scope. The server
// keeps no conversation: the browser sends the visible history (plain text) with each question.
import Anthropic from '@anthropic-ai/sdk';
import express, { type Request, type Response } from 'express';
import type { Units } from '../shared/types.ts';
import { platformSettings } from './admin.ts';
import { currentUser } from './auth.ts';
import { addDays } from './dates.ts';
import type { Db, Scope } from './db.ts';
import { requestContext, summary, trends, workouts } from './query.ts';

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

type Kind = 'temp' | 'mass' | 'distance';
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
};

const round = (v: number) => Math.round(v * 100) / 100;

/** A stored value in the person's preferred units, with its unit label. */
function inUnits(kind: Kind | undefined, value: number, unit: string, units: Units): { value: number; unit: string } {
  if (units === 'imperial' && kind === 'temp') return { value: round((value * 9) / 5 + 32), unit: '°F' };
  if (units === 'imperial' && kind === 'mass') return { value: round(value / 0.45359237), unit: 'lb' };
  if (units === 'imperial' && kind === 'distance') return { value: round(value / 1.609344), unit: 'mi' };
  return { value: round(value), unit };
}

const unitOf = (metric: string, units: Units) => inUnits(METRICS[metric]?.kind, 0, METRICS[metric]?.unit ?? '', units).unit;

type Ctx = { scope: Scope; hosted: boolean; units: Units; today: string; demo: boolean };

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
  if (typeof v !== 'string' || !DATE.test(v)) throw new ToolInputError(`${field} must be a date like 2026-10-16.`);
  return v > ctx.today ? ctx.today : v;
}

function asDays(v: unknown, max: number, fallback: number): number {
  if (v === undefined || v === null) return fallback;
  const n = Math.round(Number(v));
  if (!Number.isFinite(n) || n < 1) throw new ToolInputError('days must be a whole number of at least 1.');
  return Math.min(n, max);
}

const TOOLS: (BetaTool & { label: (input: Record<string, unknown>) => string; run: (ctx: Ctx, input: Record<string, unknown>) => Promise<unknown> })[] = [
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
];

const TOOL_BY_NAME = new Map(TOOLS.map((t) => [t.name, t]));

/** What the API sees: the definitions without our run/label functions. Eager streaming, so we validate inputs ourselves. */
const API_TOOLS: BetaTool[] = TOOLS.map(({ name, description, input_schema }) => ({ name, description, input_schema, eager_input_streaming: true }));

function systemPrompt(name: string, today: string, timeZone: string | null, units: Units) {
  const weekday = new Date(`${today}T12:00:00Z`).toLocaleDateString('en-US', { weekday: 'long', timeZone: 'UTC' });
  return `You are McFly, the health assistant in healthOS, a private dashboard that brings together one person's Apple Health and WHOOP data. You're talking with ${name || 'the person who owns this account'}. Today is ${weekday}, ${today}${timeZone ? ` (${timeZone})` : ''}. They use ${units === 'imperial' ? 'imperial units (°F, lb, miles)' : 'metric units (°C, kg, km)'}, and the tools already return values in those units.

How to answer
- Look numbers up with the tools before answering. Don't estimate or invent values, and mention the dates (and the source, when it matters) of the figures you use.
- If the data needed isn't there, such as a metric they don't record or a gap in dates, say so plainly.
- Lead with the answer, then the few numbers that support it. Keep it short: a few sentences or a short list. Use **bold** and "- " bullets sparingly, and no tables or headings.
- Where you can, compare with their own history (their usual range, recent weeks) rather than population norms.

About the data
- Daily values are what the dashboard shows. On days both devices measured blood oxygen, respiratory rate or sleep, the two are averaged when they agree, and WHOOP's value is used when they don't.
- Resting heart rate comes from WHOOP (measured asleep) when present and otherwise from Apple Watch (measured during the day), so it can shift a few bpm when the source changes.
- HRV is either RMSSD (WHOOP, or newer Apple Watch) or SDNN (Apple Watch). The two measures aren't comparable, so don't compare one with the other.
- Recovery, strain, and sleep performance, efficiency and consistency are WHOOP's own scores.

Boundaries
- You're not a doctor and can't diagnose. Give general, evidence-based wellness context. When something looks concerning, such as a sustained change, a value well outside their usual range, or a symptom they mention, suggest checking with a clinician. If they describe an emergency, tell them to contact emergency services.
- You can only read this person's own data. You can't change data or settings, see anyone else's data, or browse the web.`;
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
async function claimQuestion(db: Db, userId: string, day: string, limit: number): Promise<number | null> {
  const [row] = await db.query<{ questions: number }>(
    `INSERT INTO mcfly_usage (user_id, day, questions) VALUES ($1, $2, 1)
     ON CONFLICT (user_id, day) DO UPDATE SET questions = mcfly_usage.questions + 1 WHERE mcfly_usage.questions < $3
     RETURNING questions`,
    [userId, day, limit],
  );
  return row ? Number(row.questions) : null;
}

async function usedToday(db: Db, userId: string, day: string) {
  const [row] = await db.query<{ questions: number }>('SELECT questions FROM mcfly_usage WHERE user_id = $1 AND day = $2', [userId, day]);
  return row ? Number(row.questions) : 0;
}

// ---------- the router ----------

export type McflyOptions = { hosted: boolean; client?: () => McflyClient | null };

const defaultClient = () => (process.env.ANTHROPIC_API_KEY ? new Anthropic() : null);

export function mcflyRouter(db: Db, { hosted, client = defaultClient }: McflyOptions) {
  const router = express.Router();

  router.get('/', async (_req: Request, res: Response) => {
    const user = currentUser(res);
    const [platform, ctx] = await Promise.all([platformSettings(db), requestContext({ db, userId: user.id }, hosted)]);
    const limit = Number(platform.mcfly_daily_limit);
    res.json({ configured: Boolean(client()), limit, usedToday: await usedToday(db, user.id, ctx.today) });
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
    if ((await claimQuestion(db, user.id, rc.today, limit)) === null) {
      return void res.status(429).json({ error: `You've asked McFly ${limit} questions today, the daily limit. Ask again tomorrow.` });
    }

    const ctx: Ctx = { scope, hosted, units: rc.settings.units, today: rc.today, demo: rc.demo };
    const messages: BetaMessageParam[] = history.map((t) => ({ role: t.role, content: t.content }));
    const system = systemPrompt(rc.settings.name, rc.today, rc.settings.timeZone, rc.settings.units);

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
            tools: API_TOOLS,
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
        const results = await Promise.all(
          calls.map(async (call): Promise<BetaToolResultBlockParam> => {
            const tool = TOOL_BY_NAME.get(call.name);
            const input = call.input && typeof call.input === 'object' && !Array.isArray(call.input) ? (call.input as Record<string, unknown>) : null;
            if (!tool || !input) return { type: 'tool_result', tool_use_id: call.id, is_error: true, content: `Unknown tool or malformed input: ${call.name}` };
            send('tool', { label: tool.label(input) });
            try {
              return { type: 'tool_result', tool_use_id: call.id, content: JSON.stringify(await tool.run(ctx, input)) };
            } catch (err) {
              if (err instanceof ToolInputError) return { type: 'tool_result', tool_use_id: call.id, is_error: true, content: err.message };
              throw err;
            }
          }),
        );
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
    } finally {
      await db
        .query('UPDATE mcfly_usage SET input_tokens = input_tokens + $3, output_tokens = output_tokens + $4 WHERE user_id = $1 AND day = $2', [
          user.id,
          rc.today,
          inputTokens,
          outputTokens,
        ])
        .catch(() => {});
      res.end();
    }
  });

  return router;
}
