// The health journal (/api/journal): private check-ins, a few words and an optional mood, in journal_entries.
// Nothing else on the server reads that table: not the summary, the Family board, peer comparisons, McFly's tools,
// the admin screens or the demo. Only account deletion and the person's own export (server/export.ts) touch it.
// The text is never logged and never repeated in an error.
import { randomUUID } from 'node:crypto';
import express, { type NextFunction, type Request, type Response } from 'express';
import { JOURNAL_MAX_CHARS, type JournalData, type JournalEntry, type Mood } from '../shared/journal.ts';
import { currentUser } from './auth.ts';
import { addDays } from './dates.ts';
import { type Db, bumpDataVersion } from './db.ts';
import { nowIn } from './foodlog.ts';
import { realDate } from './labs.ts';
import { requestContext } from './query.ts';

type Row = { id: string; date: string; time: string; mood: number | null; text: string; created_at: number; updated_at: number };

const toEntry = (r: Row): JournalEntry => ({
  id: r.id,
  date: r.date,
  time: r.time,
  mood: r.mood === null ? null : (Number(r.mood) as Mood),
  text: r.text,
  createdAt: Number(r.created_at),
  updatedAt: Number(r.updated_at),
});

const TIME = /^([01]\d|2[0-3]):[0-5]\d$/;

class JournalError extends Error {
  status = 400;
}
/** Messages say what's accepted, never what was sent. */
const fail = (message: string): never => {
  throw new JournalError(message);
};

type Fields = { text?: string; mood?: Mood | null; date?: string; time?: string };

/** The fields given, checked. A new check-in needs its text; an edit may change any of them. */
function fields(raw: unknown, today: string, isNew: boolean): Fields {
  if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) return fail('Expected a check-in.');
  const b = raw as Record<string, unknown>;
  const out: Fields = {};
  if (b.text !== undefined || isNew) {
    if (typeof b.text !== 'string') return fail('Write a few words first.');
    // Line breaks are kept (it's the person's own writing); only the ends are trimmed.
    const text = b.text.replace(/\r\n?/g, '\n').trim();
    if (!text) fail('Write a few words first.');
    if (text.length > JOURNAL_MAX_CHARS) fail(`A check-in can be up to ${JOURNAL_MAX_CHARS.toLocaleString('en-US')} characters.`);
    out.text = text;
  }
  if (b.mood !== undefined) {
    if (b.mood !== null && !(typeof b.mood === 'number' && Number.isInteger(b.mood) && b.mood >= 1 && b.mood <= 5)) fail('Choose a mood from Rough to Great, or none.');
    out.mood = b.mood as Mood | null;
  }
  if (b.date !== undefined) {
    if (!realDate(b.date)) fail('Expected a real date as YYYY-MM-DD.');
    if ((b.date as string) > today) fail("A check-in can't be dated in the future.");
    if ((b.date as string) < '1900-01-01') fail('Expected a date after 1900.');
    out.date = b.date as string;
  }
  if (b.time !== undefined) {
    if (typeof b.time !== 'string' || !TIME.test(b.time)) fail('Expected a time as HH:MM.');
    out.time = b.time as string;
  }
  return out;
}

export function journalRouter(db: Db, hosted: boolean) {
  const router = express.Router();

  /** The last `days` days of check-ins (1 to 3650, 90 by default), newest first. */
  router.get('/', async (req, res) => {
    const userId = currentUser(res).id;
    const { today } = await requestContext({ db, userId }, hosted);
    const days = Math.min(Math.max(Math.trunc(Number(req.query.days)) || 90, 1), 3650);
    const from = addDays(today, -(days - 1));
    const [rows, [before]] = await Promise.all([
      db.query<Row>(
        'SELECT id, date, time, mood, text, created_at, updated_at FROM journal_entries WHERE user_id = $1 AND date >= $2 ORDER BY date DESC, time DESC, created_at DESC',
        [userId, from],
      ),
      db.query<{ any: boolean }>('SELECT EXISTS (SELECT 1 FROM journal_entries WHERE user_id = $1 AND date < $2) AS any', [userId, from]),
    ]);
    res.json({ today, entries: rows.map(toEntry), older: Boolean(before?.any) } satisfies JournalData);
  });

  /** A new check-in: { text, mood?, date?, time? }. The date and time default to now in the person's time zone. */
  router.post('/', async (req, res) => {
    const userId = currentUser(res).id;
    const { today, settings } = await requestContext({ db, userId }, hosted);
    const f = fields(req.body, today, true);
    const now = nowIn(settings.timeZone);
    const at = Date.now();
    const row: Row = { id: randomUUID(), date: f.date ?? now.date, time: f.time ?? now.time, mood: f.mood ?? null, text: f.text!, created_at: at, updated_at: at };
    const origin = (req.body as { origin?: unknown }).origin === 'iphone' ? 'iphone' : 'web';
    await db.query(
      'INSERT INTO journal_entries (user_id, id, date, time, mood, text, origin, created_at, updated_at) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)',
      [userId, row.id, row.date, row.time, row.mood, row.text, origin, row.created_at, row.updated_at],
    );
    await bumpDataVersion(db, userId);
    res.json({ entry: toEntry(row) });
  });

  /** Change one check-in: the fields sent replace the stored ones. */
  router.patch('/:id', async (req, res) => {
    const userId = currentUser(res).id;
    const { today } = await requestContext({ db, userId }, hosted);
    const f = fields(req.body, today, false);
    const [row] = await db.query<Row>(
      `UPDATE journal_entries SET text = COALESCE($3, text), mood = CASE WHEN $4::boolean THEN $5::smallint ELSE mood END,
       date = COALESCE($6, date), time = COALESCE($7, time), updated_at = $8
       WHERE user_id = $1 AND id = $2 RETURNING id, date, time, mood, text, created_at, updated_at`,
      [userId, req.params.id, f.text ?? null, f.mood !== undefined, f.mood ?? null, f.date ?? null, f.time ?? null, Date.now()],
    );
    if (!row) return void res.status(404).json({ error: 'No such check-in' });
    await bumpDataVersion(db, userId);
    res.json({ entry: toEntry(row) });
  });

  router.delete('/:id', async (req, res) => {
    const userId = currentUser(res).id;
    const gone = await db.query('DELETE FROM journal_entries WHERE user_id = $1 AND id = $2 RETURNING 1', [userId, req.params.id]);
    if (!gone.length) return void res.status(404).json({ error: 'No such check-in' });
    await bumpDataVersion(db, userId);
    res.json({ deleted: 1 });
  });

  /** Every check-in, gone (Profile → Privacy & data). */
  router.post('/delete', async (_req, res) => {
    const userId = currentUser(res).id;
    const gone = await db.query('DELETE FROM journal_entries WHERE user_id = $1 RETURNING 1', [userId]);
    if (gone.length) await bumpDataVersion(db, userId);
    res.json({ deleted: gone.length });
  });

  router.use((err: Error & { status?: number }, _req: Request, res: Response, _next: NextFunction) => {
    if (err instanceof JournalError) return void res.status(400).json({ error: err.message });
    if (err.status && err.status >= 400 && err.status < 500) return void res.status(err.status).json({ error: 'Bad request' });
    // The kind of failure only: a database error's text can quote the check-in it was given.
    console.error('journal:', err.name);
    res.status(500).json({ error: 'Something went wrong' });
  });

  return router;
}
