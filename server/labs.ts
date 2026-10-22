// Lab tests (/api/labs): a person's lab results as printed, each against the lab's own reference range.
// - Results live in their own table (lab_results), never `daily`, so summaries, patterns, the weekly digest, the
//   admin view and the Family board can't reach them. Ask McFly reads them through get_lab_results only.
// - A status is where a number sits against a range: the one printed by the lab, or, only when none was printed, a
//   typical adult range from shared/labs.ts, labelled as such. Never a diagnosis.
// - Importing a report sends the file to Claude to read the rows and returns them as a draft. Nothing is saved
//   until the person checks the rows and adds them; the file is never kept, and nothing here logs values.
import { randomUUID } from 'node:crypto';
import Anthropic from '@anthropic-ai/sdk';
import express, { type NextFunction, type Request, type Response } from 'express';
import {
  type Bounds,
  type LabDraft,
  type LabExtract,
  type LabInput,
  type LabMarker,
  type LabPanel,
  type LabRange,
  type LabResult,
  type LabsData,
  type Sex,
  biomarker,
  convert,
  isOther,
  markerGroup,
  markerKey,
  markerName,
  markerOrder,
  parseRange,
  parseResultValue,
  rangeText,
  resultStatus,
  typicalRange,
} from '../shared/labs.ts';
import { platformSettings } from './admin.ts';
import { currentUser } from './auth.ts';
import { type Db, type Queryable, type Scope, bumpDataVersion } from './db.ts';
import { type McflyClient, claimQuestion, defaultClient, usageDay } from './mcfly.ts';
import { requestContext } from './query.ts';
import { insertMany } from './store.ts';

/** Rows in one POST: a full panel or two, with room to spare. */
const MAX_ROWS = 200;
/**
 * The largest report Claude is sent. The file goes up as its own bytes (not base64 JSON, which adds a third), so 4 MB
 * fits inside Vercel's 4.5 MB request limit. Photos are made smaller in the browser first; PDFs can't be.
 */
export const MAX_REPORT_BYTES = 4 * 1024 * 1024;
const REPORT_TYPES = ['application/pdf', 'image/jpeg', 'image/png', 'image/webp', 'image/gif'] as const;
type ReportType = (typeof REPORT_TYPES)[number];

// ---------- storage ----------

export type LabRow = {
  id: string;
  collected: string;
  biomarker: string;
  name: string;
  value: number | null;
  value_text: string;
  unit: string;
  ref_low: number | null;
  ref_high: number | null;
  ref_text: string;
  lab: string;
  panel: string;
  source: string;
  created_at: number;
};

const COLS = ['id', 'collected', 'biomarker', 'name', 'value', 'value_text', 'unit', 'ref_low', 'ref_high', 'ref_text', 'lab', 'panel', 'source', 'created_at'] as const;

export async function insertLabResults(q: Queryable, userId: string, rows: LabRow[]) {
  await insertMany(
    q,
    'lab_results',
    ['user_id', ...COLS],
    rows.map((r) => [userId, ...COLS.map((c) => r[c])]),
  );
}

/** A clean row from validated input; the number always comes from the result as printed. */
export function labRow(input: Required<Omit<LabInput, 'biomarker' | 'refLow' | 'refHigh'>> & { biomarker: string; refLow: number | null; refHigh: number | null }, source: string): LabRow {
  return {
    id: randomUUID(),
    collected: input.collected,
    biomarker: input.biomarker,
    name: input.name,
    value: parseResultValue(input.valueText).value,
    value_text: input.valueText,
    unit: input.unit,
    ref_low: input.refLow,
    ref_high: input.refHigh,
    ref_text: input.refText,
    lab: input.lab,
    panel: input.panel,
    source,
    created_at: Date.now(),
  };
}

// ---------- validation ----------

class LabInputError extends Error {
  status = 400;
}

/** Messages name the field and what it accepts, never the value sent. */
const fail = (path: string, message: string): never => {
  throw new LabInputError(`${path}: ${message}`);
};

export function realDate(v: unknown): v is string {
  if (typeof v !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(v)) return false;
  const ms = Date.parse(`${v}T00:00:00Z`);
  return !Number.isNaN(ms) && new Date(ms).toISOString().slice(0, 10) === v;
}

function text(v: unknown, path: string, max: number, required: boolean): string {
  if (v === undefined || v === null) return required ? fail(path, 'is required') : '';
  if (typeof v === 'number' && Number.isFinite(v)) v = String(v);
  if (typeof v !== 'string') return fail(path, 'expected text');
  const s = v.replace(/\s+/g, ' ').trim();
  if (required && !s) fail(path, 'is required');
  if (s.length > max) fail(path, `at most ${max} characters`);
  return s;
}

function bound(v: unknown, path: string): number | null {
  if (v === undefined || v === null || v === '') return null;
  if (typeof v !== 'number' || !Number.isFinite(v) || Math.abs(v) >= 1e7) return fail(path, 'expected a number');
  return v;
}

type CleanInput = Parameters<typeof labRow>[0];

/** One result to store, checked: a real date no later than the person's today, a name, the result as printed. */
export function parseLabInput(raw: unknown, path: string, today: string): CleanInput {
  if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) return fail(path, 'expected an object');
  const r = raw as Record<string, unknown>;
  if (!realDate(r.collected)) fail(`${path}.collected`, 'expected a real date as YYYY-MM-DD');
  const collected = r.collected as string;
  if (collected > today) fail(`${path}.collected`, "can't be in the future");
  if (collected < '1900-01-01') fail(`${path}.collected`, 'expected a date after 1900');
  const name = text(r.name, `${path}.name`, 120, true);
  if (!/[\p{L}\p{N}]/u.test(name)) fail(`${path}.name`, 'expected a marker name');
  const valueText = text(r.valueText, `${path}.valueText`, 60, true);
  const unit = text(r.unit, `${path}.unit`, 30, false);
  const refText = text(r.refText, `${path}.refText`, 80, false);
  let refLow = bound(r.refLow, `${path}.refLow`);
  let refHigh = bound(r.refHigh, `${path}.refHigh`);
  // The numbers come from the printed range unless they were given.
  if (refLow === null && refHigh === null && refText) {
    const b = parseRange(refText);
    if (b) [refLow, refHigh] = [b.low, b.high];
  }
  if (refLow !== null && refHigh !== null && refLow > refHigh) fail(`${path}.refLow`, 'must not be above refHigh');
  let key: string;
  if (r.biomarker !== undefined && r.biomarker !== null && r.biomarker !== '') {
    if (typeof r.biomarker !== 'string' || !biomarker(r.biomarker)) return fail(`${path}.biomarker`, 'expected a marker from the catalog');
    key = r.biomarker;
  } else key = markerKey(name);
  return {
    collected,
    name,
    valueText,
    unit,
    refText,
    refLow,
    refHigh,
    lab: text(r.lab, `${path}.lab`, 80, false),
    panel: text(r.panel, `${path}.panel`, 80, false),
    biomarker: key,
  };
}

// ---------- reading ----------

/** A stored row's printed range, open where it was printed open ("<200" leaves out 200). */
function printedBounds(r: LabRow): Bounds | null {
  if (r.ref_low === null && r.ref_high === null) return null;
  const p = r.ref_text ? parseRange(r.ref_text) : null;
  const same = p && p.low === r.ref_low && p.high === r.ref_high;
  return { low: r.ref_low, high: r.ref_high, lowOpen: Boolean(same && p.lowOpen), highOpen: Boolean(same && p.highOpen) };
}

export function toResult(r: LabRow, sex: Sex): LabResult {
  const parsed = parseResultValue(r.value_text);
  const printed = printedBounds(r);
  let range: LabRange | null;
  let bounds: Bounds | null = null;
  if (printed) {
    range = { low: printed.low, high: printed.high, text: r.ref_text || rangeText(printed.low, printed.high), kind: 'lab' };
    bounds = printed;
  } else if (r.ref_text) {
    // A printed range without numbers ("Negative", "See note") is still the lab's: shown as printed, not replaced.
    range = { low: null, high: null, text: r.ref_text, kind: 'lab' };
  } else {
    // Only when the report printed no range at all.
    range = typicalRange(r.biomarker, r.unit, sex);
    bounds = range && { low: range.low, high: range.high, lowOpen: false, highOpen: false };
  }
  return {
    id: r.id,
    collected: r.collected,
    biomarker: r.biomarker,
    name: r.name,
    valueText: r.value_text,
    value: parsed.value,
    qualifier: parsed.qualifier,
    unit: r.unit,
    range,
    status: resultStatus(parsed, bounds),
    lab: r.lab,
    panel: r.panel,
    source: r.source,
  };
}

const sig = (v: number) => Number(v.toPrecision(4));

/** Every result for one marker, oldest first, as one marker: its latest result and the values that share a scale. */
function marker(key: string, results: LabResult[]): LabMarker {
  const latest = results.at(-1)!;
  const points: LabMarker['points'] = [];
  let otherUnits = 0;
  for (const r of results) {
    const v = r.value === null ? null : convert(r.value, r.unit, latest.unit, key);
    if (r.value !== null && v === null) otherUnits++;
    // "<0.5" isn't a point at 0.5, so it's listed but not drawn.
    if (v !== null && !r.qualifier) points.push({ id: r.id, date: r.collected, value: sig(v) });
  }
  return { key, name: markerName(key, latest.name), group: markerGroup(key), latest, history: results, points, otherUnits };
}

/**
 * The person's own results, or the demo panel while the demo is showing and they've added none. Real results always
 * win: one typed in during the demo must not disappear.
 */
async function rowsFor(scope: Scope, demo: boolean): Promise<LabRow[]> {
  const rows = await scope.db.query<LabRow>(
    `SELECT id, collected, biomarker, name, value, value_text, unit, ref_low, ref_high, ref_text, lab, panel, source, created_at
     FROM lab_results WHERE user_id = $1 ORDER BY collected, created_at, id`,
    [scope.userId],
  );
  const own = rows.filter((r) => r.source !== 'demo');
  return own.length ? own : demo ? rows.filter((r) => r.source === 'demo') : [];
}

export async function labsView(scope: Scope, hosted: boolean): Promise<LabsData> {
  const { settings, demo, today } = await requestContext(scope, hosted);
  const rows = await rowsFor(scope, demo);
  const results = rows.map((r) => toResult(r, settings.sex));
  const byKey = new Map<string, LabResult[]>();
  for (const r of results) byKey.set(r.biomarker, [...(byKey.get(r.biomarker) ?? []), r]);
  const markers = [...byKey]
    .map(([key, rs]) => marker(key, rs))
    .sort((a, b) => markerOrder(a.key) - markerOrder(b.key) || a.name.localeCompare(b.name));
  const panels = new Map<string, LabPanel>();
  for (const r of [...results].reverse()) {
    const k = `${r.collected}\u0000${r.lab}\u0000${r.panel}`;
    const p = panels.get(k) ?? { collected: r.collected, lab: r.lab, panel: r.panel, results: [] };
    p.results.push(r);
    panels.set(k, p);
  }
  for (const p of panels.values()) p.results.sort((a, b) => markerOrder(a.biomarker) - markerOrder(b.biomarker) || a.name.localeCompare(b.name));
  return {
    today,
    demo: rows.some((r) => r.source === 'demo'),
    count: results.length,
    markers,
    panels: [...panels.values()].sort((a, b) => b.collected.localeCompare(a.collected) || a.panel.localeCompare(b.panel)),
  };
}

// ---------- reading a report (Claude) ----------

/** What a report's rows come back as: structured output, so the reply is JSON of exactly this shape. */
const nullable = (type: 'string' | 'number') => ({ anyOf: [{ type }, { type: 'null' }] });
const EXTRACT_SCHEMA = {
  type: 'object',
  properties: {
    is_lab_report: { type: 'boolean', description: 'Whether the file is a lab report with results.' },
    note: { ...nullable('string'), description: 'Anything the person should know, such as pages that could not be read. Null if nothing.' },
    results: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          name: { type: 'string', description: 'The test name exactly as printed.' },
          value_text: { type: 'string', description: 'The result exactly as printed, without the unit or a high/low flag: "5.4", "<0.5", "Negative".' },
          unit: { type: 'string', description: 'The unit as printed, or an empty string.' },
          ref_text: { type: 'string', description: 'The reference range exactly as printed, or an empty string.' },
          ref_low: { ...nullable('number'), description: 'The lower bound of the printed range, or null.' },
          ref_high: { ...nullable('number'), description: 'The upper bound of the printed range, or null.' },
          collected: { ...nullable('string'), description: 'The date the sample was collected, as YYYY-MM-DD, or null if the report does not show it.' },
          lab: { type: 'string', description: 'The laboratory name, or an empty string.' },
          panel: { type: 'string', description: 'The panel or section heading the test is printed under, or an empty string.' },
        },
        required: ['name', 'value_text', 'unit', 'ref_text', 'ref_low', 'ref_high', 'collected', 'lab', 'panel'],
        additionalProperties: false,
      },
    },
  },
  required: ['is_lab_report', 'note', 'results'],
  additionalProperties: false,
};

const EXTRACT_PROMPT = `You read a person's lab report for healthOS, their private health dashboard, so they can add the results to it. You transcribe; you don't interpret.

- List every test result on the report, one row each, copying the name, result, unit and reference range exactly as printed. Keep "<", ">" and words like "Negative" in the result; leave out high/low flags (H, L, *) and the unit.
- Use the collection date (not the report or print date) when the report shows one, written as YYYY-MM-DD. If it doesn't show one, use null.
- Never invent, estimate, calculate or correct a value or a range, and never add a test that isn't printed. If something is unreadable, leave that row out and say so in note.
- If the file isn't a lab report, set is_lab_report to false and return no results.
- Don't comment on whether results are good or bad.`;

/** Draft rows from Claude's reply, each checked like a typed row; anything malformed is dropped, never repaired. */
export function draftRows(raw: unknown, today: string): LabDraft[] {
  const results = (raw as { results?: unknown } | null)?.results;
  if (!Array.isArray(results)) return [];
  const str = (v: unknown, max: number) => (typeof v === 'string' ? v.replace(/\s+/g, ' ').trim().slice(0, max) : '');
  const num = (v: unknown) => (typeof v === 'number' && Number.isFinite(v) && Math.abs(v) < 1e7 ? v : null);
  const out: LabDraft[] = [];
  for (const item of results.slice(0, MAX_ROWS)) {
    if (typeof item !== 'object' || item === null) continue;
    const r = item as Record<string, unknown>;
    const name = str(r.name, 120);
    const valueText = str(r.value_text, 60);
    if (!name || !valueText || !/[\p{L}\p{N}]/u.test(name)) continue;
    const low = num(r.ref_low);
    const high = num(r.ref_high);
    const printed = str(r.ref_text, 80);
    const collected = realDate(r.collected) && r.collected <= today && r.collected >= '1900-01-01' ? r.collected : null;
    out.push({
      collected,
      name,
      valueText,
      unit: str(r.unit, 30),
      // One editable range: as printed, or written from the numbers when only those came back.
      refText: printed || (low !== null && high !== null && low > high ? '' : rangeText(low, high)),
      lab: str(r.lab, 80),
      panel: str(r.panel, 80),
      biomarker: isOther(markerKey(name)) ? null : markerKey(name),
    });
  }
  return out;
}

/** The file's first bytes match what it says it is, so a mislabelled file isn't charged as a question. */
function looksLike(type: ReportType, b: Buffer) {
  const at = (i: number, s: string) => b.subarray(i, i + s.length).toString('latin1') === s;
  if (type === 'application/pdf') return at(0, '%PDF-');
  if (type === 'image/png') return at(0, '\x89PNG');
  if (type === 'image/jpeg') return b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff;
  if (type === 'image/gif') return at(0, 'GIF8');
  return at(0, 'RIFF') && at(8, 'WEBP');
}

class ExtractError extends Error {}

// ---------- the router ----------

export function labsRouter(db: Db, { hosted, client = defaultClient }: { hosted: boolean; client?: () => McflyClient | null }) {
  const router = express.Router();
  const scopeOf = (res: Response): Scope => ({ db, userId: currentUser(res).id });

  router.get('/', async (_req, res) => {
    res.json(await labsView(scopeOf(res), hosted));
  });

  /** Add one result or many: { results: [...] }, or a single result object. */
  router.post('/', async (req, res) => {
    const scope = scopeOf(res);
    const body = req.body as { results?: unknown; source?: unknown } | null;
    const list = Array.isArray(body?.results) ? body.results : body && typeof body === 'object' && 'name' in body ? [body] : null;
    if (!list) return void res.status(400).json({ error: 'results: expected a list of results' });
    if (list.length < 1 || list.length > MAX_ROWS) return void res.status(400).json({ error: `results: expected 1 to ${MAX_ROWS} results` });
    const source = body?.source === undefined ? 'manual' : body.source;
    if (source !== 'manual' && source !== 'report') return void res.status(400).json({ error: "source: expected 'manual' or 'report'" });
    const { today } = await requestContext(scope, hosted);
    const rows = list.map((r, i) => labRow(parseLabInput(r, `results[${i}]`, today), source));
    await insertLabResults(db, scope.userId, rows);
    await bumpDataVersion(db, scope.userId);
    res.json({ added: rows.length, ids: rows.map((r) => r.id) });
  });

  /** Change one of your own results. The fields sent replace the stored ones; the rest are checked again as they are. */
  router.patch('/:id', async (req, res) => {
    const scope = scopeOf(res);
    const [row] = await db.query<LabRow>('SELECT * FROM lab_results WHERE user_id = $1 AND id = $2', [scope.userId, req.params.id]);
    if (!row) return void res.status(404).json({ error: 'No such result' });
    const patch = req.body;
    if (typeof patch !== 'object' || patch === null || Array.isArray(patch)) return void res.status(400).json({ error: 'expected an object' });
    const p = patch as Record<string, unknown>;
    // A new printed range brings its own numbers, and new numbers replace the printed text they came from.
    const newText = 'refText' in p;
    const newNumbers = 'refLow' in p || 'refHigh' in p;
    const merged = {
      collected: row.collected,
      name: row.name,
      valueText: row.value_text,
      unit: row.unit,
      refText: newNumbers && !newText ? '' : row.ref_text,
      ...(newText && !newNumbers ? {} : { refLow: row.ref_low, refHigh: row.ref_high }),
      lab: row.lab,
      panel: row.panel,
      // A new name is matched again, unless a marker was picked with it.
      ...('name' in p ? {} : { biomarker: isOther(row.biomarker) ? undefined : row.biomarker }),
      ...p,
    };
    const { today, settings } = await requestContext(scope, hosted);
    const clean = parseLabInput(merged, 'result', today);
    const next = labRow(clean, row.source);
    await db.query(
      `UPDATE lab_results SET collected = $3, biomarker = $4, name = $5, value = $6, value_text = $7, unit = $8, ref_low = $9, ref_high = $10,
       ref_text = $11, lab = $12, panel = $13 WHERE user_id = $1 AND id = $2`,
      [scope.userId, row.id, next.collected, next.biomarker, next.name, next.value, next.value_text, next.unit, next.ref_low, next.ref_high, next.ref_text, next.lab, next.panel],
    );
    await bumpDataVersion(db, scope.userId);
    res.json({ result: toResult({ ...next, id: row.id, created_at: row.created_at }, settings.sex) });
  });

  router.delete('/:id', async (req, res) => {
    const scope = scopeOf(res);
    const gone = await db.query('DELETE FROM lab_results WHERE user_id = $1 AND id = $2 RETURNING 1', [scope.userId, req.params.id]);
    if (!gone.length) return void res.status(404).json({ error: 'No such result' });
    await bumpDataVersion(db, scope.userId);
    res.json({ deleted: 1 });
  });

  /**
   * Read a report: the file as the request body, with its own Content-Type (a PDF or a JPEG, PNG, WebP or GIF image).
   * Claude reads it and the rows come back as a draft; nothing is saved. Counted as one Ask McFly question.
   */
  router.post(
    '/extract',
    (_req, res, next) => {
      if (!client()) return void res.status(503).json({ error: "Reading reports isn't set up on this server yet. You can still type results in." });
      next();
    },
    express.raw({ type: [...REPORT_TYPES], limit: MAX_REPORT_BYTES }),
    async (req, res) => {
      const scope = scopeOf(res);
      const anthropic = client();
      if (!anthropic) return void res.status(503).json({ error: "Reading reports isn't set up on this server yet. You can still type results in." });
      const type = String(req.headers['content-type'] ?? '')
        .split(';')[0]
        .trim()
        .toLowerCase() as ReportType;
      if (!REPORT_TYPES.includes(type) || !Buffer.isBuffer(req.body)) {
        return void res.status(415).json({ error: 'Choose a PDF, or a photo or screenshot of the report (JPEG or PNG).' });
      }
      const file = req.body as Buffer;
      if (!file.length) return void res.status(400).json({ error: 'That file is empty.' });
      if (!looksLike(type, file)) return void res.status(400).json({ error: "That file doesn't look like a PDF or an image. Try exporting it again." });

      const [platform, rc] = await Promise.all([platformSettings(db), requestContext(scope, hosted)]);
      const limit = Number(platform.mcfly_daily_limit);
      if (!(limit > 0)) return void res.status(403).json({ error: 'Reading reports uses Ask McFly, which is turned off right now. You can still type results in.' });
      const day = usageDay();
      const used = await claimQuestion(db, scope.userId, day, limit);
      if (used === null) {
        return void res.status(429).json({ error: `Reading a report counts as an Ask McFly question, and you've used all ${limit} for today. Try again tomorrow, or type the results in.` });
      }

      let inputTokens = 0;
      let outputTokens = 0;
      try {
        const data = file.toString('base64');
        const block: Anthropic.Beta.BetaContentBlockParam =
          type === 'application/pdf' ? { type: 'document', source: { type: 'base64', media_type: type, data } } : { type: 'image', source: { type: 'base64', media_type: type, data } };
        // Structured output, not a forced tool call: the default model (Opus 5.5) doesn't accept a forced tool_choice.
        const message = await anthropic.beta.messages.create({
          model: platform.mcfly_model,
          max_tokens: 16_000,
          output_config: { effort: 'medium', format: { type: 'json_schema', schema: EXTRACT_SCHEMA } },
          betas: ['server-side-fallback-2026-07-01'],
          fallbacks: 'default',
          system: EXTRACT_PROMPT,
          messages: [{ role: 'user', content: [block, { type: 'text', text: `Today is ${rc.today}. List every result on this report.` }] }],
        });
        inputTokens = message.usage.input_tokens + (message.usage.cache_read_input_tokens ?? 0) + (message.usage.cache_creation_input_tokens ?? 0);
        outputTokens = message.usage.output_tokens;
        if (message.stop_reason === 'refusal') throw new ExtractError('refusal');
        if (message.stop_reason === 'max_tokens') throw new ExtractError('too_long');
        const reply = message.content
          .filter((b): b is Anthropic.Beta.BetaTextBlock => b.type === 'text')
          .map((b) => b.text)
          .join('');
        let parsed: unknown;
        try {
          parsed = JSON.parse(reply);
        } catch {
          throw new ExtractError('unparseable');
        }
        const p = parsed as { is_lab_report?: unknown; note?: unknown };
        const rows = p.is_lab_report === false ? [] : draftRows(parsed, rc.today);
        const note =
          p.is_lab_report === false
            ? "That doesn't look like a lab report, so nothing was read from it."
            : !rows.length
              ? 'No results could be read from that file.'
              : typeof p.note === 'string' && p.note.trim()
                ? p.note.trim().slice(0, 300)
                : null;
        const out: LabExtract = { rows, note, usedToday: used, limit };
        res.json(out);
      } catch (err) {
        // The kind of failure only: never the file, the reply or the results (a JSON error's text can quote them).
        console.error('labs extract:', err instanceof Anthropic.APIError ? `API ${err.status}` : err instanceof ExtractError ? err.message : err instanceof Error ? err.name : 'error');
        // A report that wasn't read doesn't count against the limit.
        await db.query('UPDATE mcfly_usage SET questions = GREATEST(questions - 1, 0) WHERE user_id = $1 AND day = $2', [scope.userId, day]).catch(() => {});
        const message =
          err instanceof ExtractError && err.message === 'too_long'
            ? 'That report has too many results to read at once. Try a photo of one page at a time.'
            : err instanceof ExtractError && err.message === 'refusal'
              ? "Claude couldn't read that file. Try a clearer photo, or type the results in."
              : err instanceof Anthropic.RateLimitError || err instanceof Anthropic.InternalServerError
                ? 'Claude is busy right now. Try again in a minute.'
                : "Couldn't read that report right now. Try again, or type the results in.";
        res.status(502).json({ error: message });
      } finally {
        await db
          .query('UPDATE mcfly_usage SET input_tokens = input_tokens + $3, output_tokens = output_tokens + $4 WHERE user_id = $1 AND day = $2', [scope.userId, day, inputTokens, outputTokens])
          .catch(() => {});
      }
    },
  );

  router.use((err: Error & { status?: number; type?: string }, _req: Request, res: Response, _next: NextFunction) => {
    if (err instanceof LabInputError) return void res.status(400).json({ error: err.message });
    if (err.status === 413) return void res.status(413).json({ error: `That file is over ${MAX_REPORT_BYTES / 1024 / 1024} MB, the most that can be read. Try a photo or screenshot of the results pages instead.` });
    if (err.status && err.status >= 400 && err.status < 500) return void res.status(err.status).json({ error: 'Bad request' });
    // The kind of failure only: a database error's text can quote the values it was given.
    console.error('labs:', err.name);
    res.status(500).json({ error: 'Something went wrong' });
  });

  return router;
}
