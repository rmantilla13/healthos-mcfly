// Journal (#/journal): your private health journal. A check-in is a few words and, if you like, a mood, kept for you
// alone (server/journal.ts): never on the Family board, in peer comparisons, with Ask McFly or on the admin screens.
// What you're writing stays in this tab (sessionStorage, per person) until it's saved, so a failed save never loses it.
import '../styles/journal.css';
import { type KeyboardEvent, useEffect, useMemo, useRef, useState } from 'react';
import { JOURNAL_MAX_CHARS, MOODS, type JournalData, type JournalEntry, type Mood } from '../../shared/journal.ts';
import type { Status } from '../../shared/types.ts';
import { Icon } from '../components/Icon.tsx';
import { PageIntro } from '../components/PageIntro.tsx';
import { daysBetween, fmtDate, sendJson, useApi, useRoute } from '../lib.ts';

/** Past this many characters, the box says how many are left. */
const COUNT_FROM = 3500;
/** The first load: the last 90 days. "Show earlier check-ins" loads the rest (ten years, the server's most). */
const RECENT_DAYS = 90;
const ALL_DAYS = 3650;

type Draft = { text: string; mood: Mood | null };
const EMPTY: Draft = { text: '', mood: null };
const isMood = (v: unknown): v is Mood => typeof v === 'number' && MOODS.some((m) => m.value === v);

// Kept per person, so someone else signing in on this tab never sees another's words. Storage can be unavailable
// (a private window, blocked site data): the composer then just works without it.
const draftKey = (userId: string) => `healthos:journal-draft:${userId}`;
function readDraft(userId: string): Draft {
  try {
    const d = JSON.parse(sessionStorage.getItem(draftKey(userId)) ?? 'null') as Partial<Draft> | null;
    if (d && typeof d.text === 'string') return { text: d.text.slice(0, JOURNAL_MAX_CHARS), mood: isMood(d.mood) ? d.mood : null };
  } catch {
    // Nothing kept, or nothing readable.
  }
  return EMPTY;
}
function writeDraft(userId: string, d: Draft) {
  try {
    if (!d.text && d.mood === null) sessionStorage.removeItem(draftKey(userId));
    else sessionStorage.setItem(draftKey(userId), JSON.stringify(d));
  } catch {
    // Not kept: the words stay on screen.
  }
}

const moodLabel = (m: Mood) => MOODS.find((x) => x.value === m)?.label ?? '';
/** Softer colours for the harder days, the app's sage for the good ones; the word always says which. */
const MOOD_BADGE: Record<Mood, string> = { 1: 'badge-peach', 2: 'badge-peach', 3: 'badge-muted', 4: 'badge-sage', 5: 'badge-sage' };

/** A stored HH:MM as this device writes times ("9:41 PM", or "21:41"). */
const clockFormat = new Intl.DateTimeFormat(undefined, { hour: 'numeric', minute: '2-digit', timeZone: 'UTC' });
const clockOf = (hhmm: string) => clockFormat.format(new Date(`1970-01-01T${hhmm}:00Z`));

/** Today, Yesterday, or "Mon, Oct 19" (with the year when it isn't this year). */
function dayLabel(date: string, today: string) {
  const d = daysBetween(date, today);
  if (d === 0) return 'Today';
  if (d === 1) return 'Yesterday';
  return fmtDate(date, { weekday: 'short', month: 'short', day: 'numeric', ...(date.slice(0, 4) === today.slice(0, 4) ? {} : { year: 'numeric' }) });
}

/** "Friday 9:41 PM" in the person's own time zone, kept current. */
function useNowLine(timeZone: string | null) {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    const timer = setInterval(() => setNow(Date.now()), 20_000);
    return () => clearInterval(timer);
  }, []);
  const format = (zone?: string) =>
    `${new Intl.DateTimeFormat(undefined, { weekday: 'long', timeZone: zone }).format(now)} ${new Intl.DateTimeFormat(undefined, { hour: 'numeric', minute: '2-digit', timeZone: zone }).format(now)}`;
  try {
    return format(timeZone ?? undefined);
  } catch {
    // A time zone this browser doesn't know: its own.
    return format();
  }
}

export function Journal({ status }: { status: Status }) {
  const { params } = useRoute();
  const userId = status.user.id;
  const [days, setDays] = useState(RECENT_DAYS);
  const { data, error, loading, current, reload } = useApi<JournalData>(`/journal?days=${days}`);
  const [draft, setDraft] = useState<Draft>(() => readDraft(userId));
  const [busy, setBusy] = useState(false);
  const [saved, setSaved] = useState(false);
  const [err, setErr] = useState('');
  const box = useRef<HTMLTextAreaElement>(null);
  const historyHeading = useRef<HTMLHeadingElement>(null);
  const nowLine = useNowLine(status.settings.timeZone);

  useEffect(() => writeDraft(userId, draft), [userId, draft]);

  // #/journal?new=1 (Home's "Write a check-in"): straight to the words, once the composer is on screen.
  const wantsNew = params.get('new') === '1';
  const ready = data !== undefined;
  useEffect(() => {
    if (wantsNew && ready) box.current?.focus();
  }, [wantsNew, ready]);

  const groups = useMemo(() => {
    const out: { date: string; entries: JournalEntry[] }[] = [];
    for (const e of data?.entries ?? []) {
      const last = out.at(-1);
      if (last?.date === e.date) last.entries.push(e);
      else out.push({ date: e.date, entries: [e] });
    }
    return out;
  }, [data]);

  const change = (next: Partial<Draft>) => {
    setSaved(false);
    setDraft((d) => ({ ...d, ...next }));
  };

  async function save() {
    const text = draft.text.trim();
    if (!text || busy) return;
    setBusy(true);
    setErr('');
    setSaved(false);
    try {
      await sendJson<{ entry: JournalEntry }>('POST', '/journal', { text, mood: draft.mood });
      setDraft(EMPTY);
      setSaved(true);
      reload();
      box.current?.focus();
    } catch (e) {
      setErr(`${(e as Error).message} Your check-in is still here.`);
    } finally {
      setBusy(false);
    }
  }
  // ⌘↩ or Ctrl+Enter saves, as in a message box; Enter alone is a new line.
  const onKey = (e: KeyboardEvent) => {
    if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) {
      e.preventDefault();
      save();
    }
  };

  async function deleteAll() {
    if (!confirm('Delete every check-in in your journal? This can’t be undone.')) return;
    setErr('');
    try {
      await sendJson('POST', '/journal/delete');
      reload();
    } catch (e) {
      setErr((e as Error).message);
    }
  }

  if (!data) {
    return (
      <div className="page page-wide journal-page">
        {error ? (
          <p className="note-bad" role="alert">
            <Icon name="alert" size={15} /> Couldn't open your journal. Try Refresh.
          </p>
        ) : (
          <p className="page-loading" role="status">
            Opening your private journal…
          </p>
        )}
      </div>
    );
  }

  const left = JOURNAL_MAX_CHARS - draft.text.length;
  // Earlier check-ins asked for and not here yet: useApi keeps the 90 days on screen meanwhile, and if they fail to load.
  // The button stays (with focus on it) until they arrive, and a failure says so under the list.
  const awaiting = days === ALL_DAYS && !current && Boolean(data.older);
  const moreFailed = awaiting && Boolean(error);
  const busyMore = awaiting && loading;
  return (
    <div className="page page-wide journal-page">
      <PageIntro title="How are you feeling today?" sub="A few words, and a mood if you like. Only you can see your journal." />

      <section className="card journal-compose" aria-label="New check-in">
        <div className="journal-compose-body">
          <p className="eyebrow">Today, {nowLine}</p>
          <MoodChips mood={draft.mood} onChange={(mood) => change({ mood })} label="How you feel, if you'd like to say" />
          <label className="sr-only" htmlFor="journal-text">
            Your check-in
          </label>
          <textarea
            id="journal-text"
            ref={box}
            className="journal-box"
            rows={4}
            maxLength={JOURNAL_MAX_CHARS}
            placeholder="A thought, a feeling, a little context."
            value={draft.text}
            onChange={(e) => change({ text: e.target.value })}
            onKeyDown={onKey}
            aria-describedby={left <= JOURNAL_MAX_CHARS - COUNT_FROM ? 'journal-count' : undefined}
          />
          {left <= JOURNAL_MAX_CHARS - COUNT_FROM && (
            <p id="journal-count" className="journal-count" aria-live="polite">
              {left.toLocaleString()} {left === 1 ? 'character' : 'characters'} left
            </p>
          )}
          <div className="journal-compose-foot">
            <button className="btn btn-primary" disabled={busy || !draft.text.trim()} onClick={save}>
              {busy ? 'Saving…' : 'Save check-in'}
            </button>
            <p className="journal-saved" role="status">
              {saved && (
                <>
                  <Icon name="check" size={15} /> Saved. Only you can see this.
                </>
              )}
            </p>
          </div>
          {err && (
            <p className="note-bad" role="alert">
              <Icon name="alert" size={15} /> {err}
            </p>
          )}
        </div>
        <img className="journal-art" src="/figures/journal-gut.webp" alt="" aria-hidden="true" />
      </section>

      <section className="card journal-history" aria-labelledby="journal-history-title">
        <h2 id="journal-history-title" tabIndex={-1} ref={historyHeading}>
          Earlier check-ins
        </h2>
        {groups.length === 0 ? (
          <p className="journal-empty">{data.older ? `No check-ins in the last ${RECENT_DAYS} days.` : 'Your journal is empty. Write your first check-in above.'}</p>
        ) : (
          groups.map((g) => (
            <div className="journal-day" key={g.date}>
              <h3 className="journal-day-title">{dayLabel(g.date, data.today)}</h3>
              <ul className="journal-entries">
                {g.entries.map((e) => (
                  <Entry key={e.id} entry={e} day={dayLabel(e.date, data.today)} onChanged={reload} onDeleted={() => historyHeading.current?.focus()} />
                ))}
              </ul>
            </div>
          ))
        )}
        {moreFailed && (
          <p className="note-bad" role="alert">
            <Icon name="alert" size={15} /> Couldn't load your earlier check-ins. Try again.
          </p>
        )}
        {data.older && (days < ALL_DAYS || awaiting) && (
          // aria-disabled, not disabled, while they load: a disabled button would drop the focus of whoever pressed it.
          <button className="btn journal-more" aria-disabled={busyMore || undefined} onClick={() => !busyMore && (days < ALL_DAYS ? setDays(ALL_DAYS) : reload())}>
            {busyMore ? 'Loading…' : 'Show earlier check-ins'}
          </button>
        )}
      </section>

      <div className="journal-privacy">
        <p>
          <Icon name="shield" size={15} /> Your journal is private. It isn't shared on the Family board, in peer comparisons, or with Ask McFly.
        </p>
        {(groups.length > 0 || data.older) && (
          <button className="btn btn-quiet btn-danger" onClick={deleteAll}>
            Delete all check-ins
          </button>
        )}
      </div>
    </div>
  );
}

/** Five optional moods, one at a time: choosing the chosen one again clears it. */
function MoodChips({ mood, onChange, label }: { mood: Mood | null; onChange: (m: Mood | null) => void; label: string }) {
  return (
    <div className="journal-moods" role="group" aria-label={label}>
      {MOODS.map((m) => (
        <button key={m.value} type="button" className="journal-mood" aria-pressed={mood === m.value} onClick={() => onChange(mood === m.value ? null : m.value)}>
          {m.label}
        </button>
      ))}
    </div>
  );
}

/** One check-in: its time, mood and words, changed in place or deleted (after asking). */
function Entry({ entry, day, onChanged, onDeleted }: { entry: JournalEntry; day: string; onChanged: () => void; onDeleted: () => void }) {
  const [editing, setEditing] = useState(false);
  const [text, setText] = useState(entry.text);
  const [mood, setMood] = useState<Mood | null>(entry.mood);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState('');
  // What was just saved, shown until the reloaded check-in arrives with it.
  const [justSaved, setJustSaved] = useState<{ text: string; mood: Mood | null } | null>(null);
  const box = useRef<HTMLTextAreaElement>(null);
  const editButton = useRef<HTMLButtonElement>(null);
  const when = `${day === 'Today' || day === 'Yesterday' ? day.toLowerCase() : day} at ${clockOf(entry.time)}`;
  const shown = justSaved ?? entry;

  const refocus = useRef(false);
  // Opening the editor puts the cursor after the last word, ready to add to it; closing it goes back to Edit.
  useEffect(() => {
    const el = box.current;
    if (editing && el) {
      el.focus();
      el.setSelectionRange(el.value.length, el.value.length);
    } else if (!editing && refocus.current) {
      refocus.current = false;
      editButton.current?.focus();
    }
  }, [editing]);
  useEffect(() => setJustSaved(null), [entry.updatedAt]);

  // The check-in as it is now (it may have changed on another device since this one loaded).
  const start = () => {
    setText(entry.text);
    setMood(entry.mood);
    setErr('');
    setEditing(true);
  };
  const stop = () => {
    refocus.current = true;
    setEditing(false);
    setErr('');
  };

  async function save() {
    if (!text.trim()) return setErr('Write a few words, or delete the check-in instead.');
    setBusy(true);
    setErr('');
    try {
      await sendJson('PATCH', `/journal/${encodeURIComponent(entry.id)}`, { text: text.trim(), mood });
      setJustSaved({ text: text.trim(), mood });
      stop();
      onChanged();
    } catch (e) {
      setErr((e as Error).message);
    } finally {
      setBusy(false);
    }
  }

  async function remove() {
    if (!confirm(`Delete the check-in from ${when}? It can’t be undone.`)) return;
    setErr('');
    try {
      await sendJson('DELETE', `/journal/${encodeURIComponent(entry.id)}`);
      onDeleted();
      onChanged();
    } catch (e) {
      setErr((e as Error).message);
    }
  }

  return (
    <li className="journal-entry">
      <div className="journal-entry-head">
        <time className="journal-time" dateTime={`${entry.date}T${entry.time}`}>
          {clockOf(entry.time)}
        </time>
        {shown.mood !== null && !editing && <span className={`badge ${MOOD_BADGE[shown.mood]}`}>{moodLabel(shown.mood)}</span>}
        {!editing && (
          <div className="journal-entry-actions">
            <button ref={editButton} className="btn btn-quiet" onClick={start} aria-label={`Edit the check-in from ${when}`}>
              Edit
            </button>
            <button className="btn btn-quiet btn-danger" onClick={remove} aria-label={`Delete the check-in from ${when}`}>
              Delete
            </button>
          </div>
        )}
      </div>
      {editing ? (
        <form
          className="journal-edit"
          onSubmit={(e) => {
            e.preventDefault();
            save();
          }}
          onKeyDown={(e) => e.key === 'Escape' && !busy && stop()}
        >
          <MoodChips mood={mood} onChange={setMood} label={`Mood for the check-in from ${when}`} />
          <label className="sr-only" htmlFor={`journal-edit-${entry.id}`}>
            The check-in from {when}
          </label>
          <textarea
            id={`journal-edit-${entry.id}`}
            ref={box}
            className="journal-box"
            rows={4}
            maxLength={JOURNAL_MAX_CHARS}
            value={text}
            onChange={(e) => setText(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) {
                e.preventDefault();
                save();
              }
            }}
          />
          <div className="btn-row">
            <button type="submit" className="btn btn-primary" disabled={busy || !text.trim()}>
              {busy ? 'Saving…' : 'Save changes'}
            </button>
            <button type="button" className="btn btn-quiet" onClick={stop} disabled={busy}>
              Cancel
            </button>
          </div>
        </form>
      ) : (
        <p className="journal-text">{shown.text}</p>
      )}
      {err && (
        <p className="note-bad" role="alert">
          <Icon name="alert" size={15} /> {err}
        </p>
      )}
    </li>
  );
}
