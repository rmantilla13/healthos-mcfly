// Nutrition's Today (#/nutrition): a conversation about what you ate, beside the day it adds up to. Tell McFly in your
// own words (typed, a voice note or a photo) and it answers with an estimate to check: rename, change how many, leave
// things out, then save. Nothing counts until you save it, and a follow-up while an estimate is open corrects it (the
// server replaces the draft). Searching, typed amounts and water are under +. The thread lives only in this browser
// tab (sessionStorage, per person, photos as small thumbnails); the server's drafts are the truth, so a reload, or an
// estimate made on the iPhone, reopens the review. The day is read with a POST, so no date is ever in an address.
import { type FormEvent, type ReactNode, useEffect, useId, useRef, useState } from 'react';
import type { AiStatus } from '../../shared/ai.ts';
import type { FoodDay } from '../../shared/foodday.ts';
import type { FoodEntry, FoodEstimate, FoodLog, FoodValues, NutritionNumbers, Status } from '../../shared/types.ts';
import { Donut } from '../charts/Donut.tsx';
import { Icon } from '../components/Icon.tsx';
import { Orb } from '../components/Orb.tsx';
import { PageIntro } from '../components/PageIntro.tsx';
import { Sheet } from '../components/Sheet.tsx';
import { MenuButton } from '../components/shell/Menu.tsx';
import { localToday } from '../components/shell/TopBar.tsx';
import { useVoiceNote } from '../hooks/useVoiceNote.ts';
import { fmt, fmtDate, notifyDataChanged, relativeDay, sendJson, shiftDate, useApi } from '../lib.ts';
import {
  COMPANY,
  EntryRow,
  KEY_LABEL,
  QuickAdd,
  SearchFood,
  type Units,
  WaterButtons,
  type When,
  amounts,
  grams,
  nowTime,
  scaled,
  shrinkPhoto,
  useEstimateReview,
  waterText,
} from './FoodLog.tsx';

/** One line of the conversation. McFly's estimates keep what they were made from, so a correction can build on them. */
type Turn =
  | { id: string; role: 'you'; text: string; photo?: string }
  | {
      id: string;
      role: 'mcfly';
      kind: 'estimate';
      batch: string;
      note: string;
      /** The words the estimate was made from. */
      asked: string;
      /** It was made from a photo (the photo itself is kept in memory only, for a correction). */
      photo: boolean;
      /** Its items as "name (portion)", for a correction once the photo is gone. */
      items: string[];
      date: string;
      time: string;
      state: 'open' | 'saved' | 'discarded' | 'replaced';
      saved?: number;
      /** When it arrived: a day read before then doesn't know about it yet. */
      at: number;
      /** Found waiting when the page opened: made in another tab or on the iPhone. */
      found?: boolean;
    }
  | { id: string; role: 'mcfly'; kind: 'note'; text: string; error?: boolean };
type EstimateTurn = Extract<Turn, { kind: 'estimate' }>;
type Photo = { data: string; preview: string };
type Sheets = 'search' | 'quick' | 'water';

const MAX_TURNS = 40;
/** The server's limit on a description. */
const MAX_DESCRIPTION = 1000;
/** The long edge of a photo's thumbnail in the thread: sharp at its shown size, and a few KB in storage. */
const THUMB_EDGE = 240;

const storageKey = (userId: string) => `healthos-nutrition-chat:${userId}`;
const uid = () => crypto.randomUUID?.() ?? `${Date.now()}-${Math.random()}`;
const touch = () => matchMedia('(pointer: coarse)').matches;

function loadTurns(userId: string): Turn[] {
  try {
    const raw = sessionStorage.getItem(storageKey(userId));
    const turns = raw ? (JSON.parse(raw) as unknown) : [];
    return Array.isArray(turns) ? (turns as Turn[]) : [];
  } catch {
    return [];
  }
}

function saveTurns(userId: string, turns: Turn[]) {
  try {
    sessionStorage.setItem(storageKey(userId), JSON.stringify(turns.slice(-MAX_TURNS)));
  } catch {
    // Storage full or blocked: the conversation still works, it just won't survive a reload.
  }
}

/** A small copy of a photo for the thread, so the full one never sits in storage. */
async function thumbnail(dataUrl: string) {
  const img = new Image();
  img.src = dataUrl;
  await img.decode();
  const scale = Math.min(1, THUMB_EDGE / Math.max(img.naturalWidth, img.naturalHeight));
  const canvas = document.createElement('canvas');
  canvas.width = Math.round(img.naturalWidth * scale);
  canvas.height = Math.round(img.naturalHeight * scale);
  canvas.getContext('2d')!.drawImage(img, 0, 0, canvas.width, canvas.height);
  return canvas.toDataURL('image/jpeg', 0.7);
}

/** A correction as one description: what the estimate was made from, then what to change, within the server's limit. */
function corrected(previous: string, correction: string) {
  if (!correction) return previous.slice(0, MAX_DESCRIPTION);
  if (!previous) return correction.slice(0, MAX_DESCRIPTION);
  const tail = `. Correction: ${correction}`;
  const head = previous.replace(/[\s.]+$/, '');
  return tail.length >= MAX_DESCRIPTION ? correction.slice(0, MAX_DESCRIPTION) : `${head.slice(0, MAX_DESCRIPTION - tail.length)}${tail}`;
}

/**
 * One day of the food log, read with a POST (the date goes in the body). Refetched when anything changes
 * (healthos:data: a save, an edit, the background version check) and when the person's numbers setting does.
 */
function useFoodDay(date: string | null, numbers: NutritionNumbers) {
  const [data, setData] = useState<FoodDay & { askedAt: number }>();
  const [error, setError] = useState<Error>();
  const [loading, setLoading] = useState(false);
  const [version, setVersion] = useState(0);
  useEffect(() => {
    const bump = () => setVersion((v) => v + 1);
    window.addEventListener('healthos:data', bump);
    return () => window.removeEventListener('healthos:data', bump);
  }, []);
  useEffect(() => {
    // A reply for a day that's no longer asked for (a quick change of date) is dropped.
    let alive = true;
    const askedAt = Date.now();
    setLoading(true);
    sendJson<FoodDay>('POST', '/nutrition/log/day', date ? { date } : {})
      .then((d) => {
        if (!alive) return;
        setData({ ...d, askedAt });
        setError(undefined);
      })
      .catch((e: Error) => alive && setError(e))
      .finally(() => alive && setLoading(false));
    return () => {
      alive = false;
    };
  }, [date, numbers, version]);
  return { data, error, loading };
}

// ---------- the view ----------

export function NutritionToday({ status, views, compose }: { status: Status; views: ReactNode; compose?: boolean }) {
  const numbers = status.settings.nutritionNumbers ?? 'none';
  const units = status.settings.units;
  // null: today, whichever day that is when the answer comes back.
  const [date, setDate] = useState<string | null>(null);
  const { data: day, error, loading } = useFoodDay(date, numbers);
  const { data: ai } = useApi<AiStatus>('/ai');
  const today = day?.today ?? localToday();
  const viewing = date ?? today;
  const oldest = shiftDate(today, -366);

  return (
    <div className="page page-wide nutrition-page">
      <PageIntro
        sub="A conversation about what nourishes you."
        actions={
          <label className="nutri-viewing">
            <span>Viewing</span>
            <input
              type="date"
              value={viewing}
              min={oldest}
              max={today}
              onChange={(e) => {
                const v = e.target.value;
                // Cleared, or typed past either end: keep the day shown.
                if (v && v >= oldest && v <= today) setDate(v === today ? null : v);
              }}
            />
          </label>
        }
      >
        {views}
      </PageIntro>
      {error && !day ? (
        <div className="page-message">Couldn't load your food log: {error.message}</div>
      ) : (
        <div className="nutri-today">
          {/* Keyed by person: someone else signing in on this tab never sees, or saves over, another's conversation. */}
          <NutritionChat key={status.user.id} userId={status.user.id} day={day} ai={ai} viewing={viewing} today={today} numbers={numbers} units={units} compose={compose} />
          <div className={`nutri-side ${loading && day ? 'is-refreshing' : ''}`}>
            <DailyBalance day={day} numbers={numbers} units={units} />
            <FoodJournal day={day} viewing={viewing} today={today} numbers={numbers} units={units} />
          </div>
        </div>
      )}
    </div>
  );
}

// ---------- the conversation ----------

function NutritionChat({
  userId,
  day,
  ai,
  viewing,
  today,
  numbers,
  units,
  compose,
}: {
  userId: string;
  day: (FoodDay & { askedAt: number }) | undefined;
  ai: AiStatus | undefined;
  viewing: string;
  today: string;
  numbers: NutritionNumbers;
  units: Units;
  compose?: boolean;
}) {
  const [turns, setTurns] = useState<Turn[]>(() => loadTurns(userId));
  const [text, setText] = useState('');
  const [photo, setPhoto] = useState<Photo | null>(null);
  const [busy, setBusy] = useState(false);
  const [sheet, setSheet] = useState<Sheets | null>(null);
  const [problem, setProblem] = useState<string | null>(null);
  // What a screen reader hears as the conversation moves on (the thread itself isn't a live region: the review's
  // fields change as people type, and would be read out again each time).
  const [said, setSaid] = useState('');
  // Each estimate's drafts as it came back, shown until the day is read again (which a save or the next sync does).
  const [fresh, setFresh] = useState<Record<string, FoodEntry[]>>({});
  // The last estimate's full photo, in memory only, so a correction can send it again.
  const lastPhoto = useRef<{ batch: string; image: { mediaType: 'image/jpeg'; data: string } } | null>(null);
  const input = useRef<HTMLTextAreaElement>(null);
  const fileInput = useRef<HTMLInputElement>(null);
  const thread = useRef<HTMLDivElement>(null);
  const voiceHint = useId();
  const can = day?.can;
  const canEstimate = Boolean(can?.estimate);

  useEffect(() => saveTurns(userId, turns), [userId, turns]);

  // An estimate waiting on the server that this tab didn't make (another tab, the iPhone) joins the conversation.
  const batch = day?.draftBatch ?? null;
  useEffect(() => {
    if (!batch || !day?.drafts.length) return;
    const first = day.drafts[0];
    setTurns((t) =>
      t.some((x) => x.role === 'mcfly' && x.kind === 'estimate' && x.batch === batch)
        ? t
        : [
            ...t,
            {
              id: uid(),
              role: 'mcfly',
              kind: 'estimate',
              batch,
              note: '',
              asked: '',
              photo: false,
              items: day.drafts.map(itemText),
              date: first.date,
              time: first.time,
              state: 'open',
              found: true,
              at: Date.now(),
            },
          ],
    );
    // Only a new batch matters here; its drafts come with it.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [batch]);

  // The newest line in view: on a new line, and once the day has loaded (a waiting review is taller than its stand-in).
  const loaded = Boolean(day);
  useEffect(() => {
    const el = thread.current;
    if (el) el.scrollTop = el.scrollHeight;
  }, [turns.length, busy, loaded]);

  useEffect(() => {
    if (compose) input.current?.focus();
  }, [compose]);

  /** The estimate being reviewed right now: a follow-up message corrects it. */
  const open = turns.findLast((t): t is EstimateTurn => t.role === 'mcfly' && t.kind === 'estimate' && t.state === 'open' && t.batch === batch) ?? null;

  const voiceOff = !can?.voice
    ? ai?.byok === false
      ? "Voice notes need an OpenAI key, and storing your own key isn't available on this server."
      : 'Connect your OpenAI key for voice notes.'
    : null;
  const voice = useVoiceNote({
    enabled: Boolean(can?.voice),
    onText: (words) => {
      setText((t) => (t.trim() ? `${t.trimEnd()} ${words}` : words));
      input.current?.focus();
    },
    onBlocked: () => setProblem(voiceOff),
  });

  const when: When = () => ({ date: viewing, time: viewing === today ? nowTime() : '12:00' });

  async function choose(file: File | undefined) {
    if (!file) return;
    setProblem(null);
    try {
      setPhoto(await shrinkPhoto(file));
      input.current?.focus();
    } catch {
      setProblem("That photo couldn't be opened here. Try a JPEG or PNG, or describe it instead.");
    }
  }

  async function send(e?: FormEvent) {
    e?.preventDefault();
    const words = text.replace(/\s+/g, ' ').trim();
    if ((!words && !photo) || busy || !canEstimate) return;
    setProblem(null);
    let description = words;
    let image = photo ? { mediaType: 'image/jpeg' as const, data: photo.data } : null;
    let at = when();
    if (open) {
      // A correction: what the estimate was made from, plus what to change, on the same day and time.
      if (!image && lastPhoto.current?.batch === open.batch) image = lastPhoto.current.image;
      const items = open.items.join('; ');
      const previous = open.photo && !image ? [open.asked, items && `From a photo: ${items}`].filter(Boolean).join('. ') : open.asked || items;
      description = corrected(previous, words);
      at = { date: open.date, time: open.time };
    }
    const sent = { words, photo };
    const thumb = photo ? await thumbnail(photo.preview).catch(() => undefined) : undefined;
    setTurns((t) => [...t, { id: uid(), role: 'you', text: words, photo: thumb }]);
    setText('');
    setPhoto(null);
    setBusy(true);
    setSaid('McFly is estimating…');
    try {
      const r = await sendJson<FoodEstimate>('POST', '/nutrition/estimate', { description, image, ...at });
      if (r.drafts.length) {
        lastPhoto.current = image ? { batch: r.batch, image } : null;
        setFresh({ [r.batch]: r.drafts });
        const turn: EstimateTurn = {
          id: uid(),
          role: 'mcfly',
          kind: 'estimate',
          batch: r.batch,
          note: r.note,
          asked: description,
          photo: Boolean(image),
          items: r.drafts.map(itemText),
          date: at.date,
          time: at.time,
          state: 'open',
          at: Date.now(),
        };
        // The server replaced the estimate a correction was for.
        setTurns((t) => [...t.map((x) => (open && x.id === open.id ? { ...x, state: 'replaced' as const } : x)), turn]);
        setSaid(`McFly's estimate is ready to check: ${turn.items.join(', ')}.`);
      } else {
        // Nothing found: the server still dropped the estimate a correction was for.
        setTurns((t) => [
          ...t.map((x) => (open && x.id === open.id ? { ...x, state: 'discarded' as const } : x)),
          { id: uid(), role: 'mcfly', kind: 'note', text: r.note || "McFly didn't find food or drink to estimate." },
        ]);
        setSaid(r.note || "McFly didn't find food or drink to estimate.");
      }
      notifyDataChanged();
    } catch (err) {
      setTurns((t) => [...t, { id: uid(), role: 'mcfly', kind: 'note', text: (err as Error).message, error: true }]);
      setSaid((err as Error).message);
      // What was sent comes back, to try again.
      setText(sent.words);
      setPhoto(sent.photo);
    } finally {
      setBusy(false);
    }
  }

  const finish = (id: string, saved: number | null) => {
    setSaid(saved === null ? 'Discarded. Nothing was saved.' : 'Saved to your food journal.');
    setTurns((t) =>
      t.map((x) => (x.id === id && x.role === 'mcfly' && x.kind === 'estimate' ? { ...x, state: saved === null ? 'discarded' : 'saved', saved: saved ?? undefined } : x)),
    );
  };

  const ready = canEstimate && !busy && (Boolean(text.trim()) || Boolean(photo));
  const placeholder = open ? 'Anything to correct?' : 'I ate…';

  return (
    <section className="card nutri-chat" aria-labelledby="nutri-chat-title">
      <header className="nutri-chat-head">
        <div>
          <p className="eyebrow">healthOS nutrition</p>
          <h2 id="nutri-chat-title">What's on your plate?</h2>
          <p className="nutri-chat-sub">Tell me in your own words. I'll take care of the numbers.</p>
        </div>
        {turns.length > 0 && !busy && (
          <button type="button" className="btn btn-quiet small" onClick={() => setTurns(open ? [open] : [])} aria-label="Clear this conversation">
            Clear
          </button>
        )}
      </header>

      <p className="sr-only" aria-live="polite">
        {said}
      </p>
      <div className="nutri-thread" ref={thread}>
        {turns.length === 0 && !busy ? (
          <div className="nutri-empty">
            <Orb size={48} />
            <p className="nutri-empty-title">
              Good food.
              <br />
              One simple conversation.
            </p>
            <p className="nutri-empty-example">“I had a chicken bowl with rice and avocado.”</p>
          </div>
        ) : (
          <>
            {turns.map((t) =>
              t.role === 'you' ? (
                <div key={t.id} className="nutri-turn nutri-you">
                  <div className="nutri-bubble">
                    {t.photo && <img src={t.photo} alt="Your photo" />}
                    {t.text && <p>{t.text}</p>}
                  </div>
                </div>
              ) : (
                <div key={t.id} className="nutri-turn nutri-mcfly">
                  <Orb size={20} className="nutri-turn-orb" />
                  <div className="nutri-turn-body">
                    {t.kind === 'note' ? (
                      <p className={t.error ? 'note-bad' : undefined}>
                        {t.error && <Icon name="alert" size={15} />} {t.text}
                      </p>
                    ) : (
                      <EstimateLine turn={t} day={day} fresh={fresh[t.batch]} today={today} numbers={numbers} units={units} onDone={(saved) => finish(t.id, saved)} />
                    )}
                  </div>
                </div>
              ),
            )}
            {busy && (
              <div className="nutri-turn nutri-mcfly">
                <Orb size={20} busy className="nutri-turn-orb" />
                <div className="nutri-turn-body">
                  <p className="muted">McFly is estimating…</p>
                </div>
              </div>
            )}
          </>
        )}
      </div>

      <form className={`nutri-composer${canEstimate || !day ? '' : ' is-off'}`} onSubmit={send}>
        {photo && (
          <div className="nutri-attached">
            <img src={photo.preview} alt="Your photo, as it will be sent" />
            <button type="button" className="nutri-attached-x" onClick={() => setPhoto(null)} aria-label="Remove the photo">
              <Icon name="x" size={13} strokeWidth={2} />
            </button>
          </div>
        )}
        <textarea
          ref={input}
          rows={2}
          maxLength={MAX_DESCRIPTION}
          value={text}
          placeholder={placeholder}
          disabled={Boolean(day) && !canEstimate}
          aria-label={open ? 'A correction to the estimate' : 'What did you eat?'}
          onChange={(e) => setText(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === 'Enter' && !e.shiftKey && !e.nativeEvent.isComposing && !touch()) {
              e.preventDefault();
              void send();
            }
          }}
        />
        <div className="nutri-composer-row">
          <MenuButton
            id="nutrition-add"
            className="nutri-round nutri-plus"
            label="Add to your food journal"
            buttonLabel="More ways to add food"
            placement="up"
            menu={
              <>
                {canEstimate && (
                  <button type="button" role="menuitem" className="menu-item" onClick={() => fileInput.current?.click()}>
                    <Icon name="camera" size={17} />
                    Add a photo
                  </button>
                )}
                <button type="button" role="menuitem" className="menu-item" onClick={() => setSheet('search')}>
                  <Icon name="search" size={17} />
                  Search foods or a barcode
                </button>
                {numbers !== 'none' && (
                  <>
                    <button type="button" role="menuitem" className="menu-item" onClick={() => setSheet('quick')}>
                      <Icon name="sliders" size={17} />
                      Type amounts
                    </button>
                    <button type="button" role="menuitem" className="menu-item" onClick={() => setSheet('water')}>
                      <Icon name="cycle" size={17} />
                      Water
                    </button>
                  </>
                )}
              </>
            }
          >
            <Icon name="plus" size={17} />
          </MenuButton>
          <span className="nutri-composer-gap" />
          <span className="nutri-voice-label" id={`${voiceHint}-state`}>
            {voice.state === 'recording' ? (
              <>
                Recording {Math.floor(voice.seconds / 60)}:{String(voice.seconds % 60).padStart(2, '0')}
                <span className="nutri-voice-more"> · {voice.byKey ? 'press again to stop' : 'let go to stop'}</span>
              </>
            ) : voice.state === 'transcribing' ? (
              'Writing it down…'
            ) : voice.state === 'starting' ? (
              'Starting the microphone…'
            ) : (
              'Hold to talk'
            )}
          </span>
          {voiceOff && (
            <span id={voiceHint} className="sr-only">
              {voiceOff}
            </span>
          )}
          <button
            type="button"
            className={`nutri-round nutri-voice is-${voice.state}`}
            aria-label="Voice note"
            aria-describedby={voiceOff ? voiceHint : `${voiceHint}-state`}
            aria-disabled={voiceOff ? true : undefined}
            aria-pressed={voice.state === 'recording'}
            title={voiceOff ?? undefined}
            disabled={busy || (Boolean(day) && !canEstimate && !voiceOff)}
            {...voice.bind}
          >
            <Orb size={20} busy={voice.state === 'transcribing'} />
          </button>
          <button type="submit" className="nutri-round nutri-send" disabled={!ready} aria-label={open ? 'Send the correction' : 'Send to McFly'}>
            <Icon name="arrow-up-right" size={17} strokeWidth={1.8} />
          </button>
        </div>
      </form>
      <input ref={fileInput} type="file" accept="image/*" capture="environment" hidden onChange={(e) => void choose(e.target.files?.[0]).finally(() => (e.target.value = ''))} />
      {(problem || voice.error) && (
        <p className={`note-bad small nutri-problem${problem && problem === voiceOff ? ' is-quiet' : ''}`} role="status">
          {problem ?? voice.error}
        </p>
      )}
      <SetupLine can={can} ai={ai} numbers={numbers} />

      {sheet === 'search' && (
        <Sheet eyebrow="Nutrition" title="Search foods or a barcode" onClose={() => setSheet(null)}>
          <div className="food-sheet">
            <p className="muted small">Adds to {dayWords(viewing, today)}.</p>
            <SearchFood when={when} units={units} usda={Boolean(can?.usda)} />
          </div>
        </Sheet>
      )}
      {sheet === 'quick' && (
        <Sheet eyebrow="Nutrition" title="Type amounts" size="sm" onClose={() => setSheet(null)}>
          <div className="food-sheet">
            <p className="muted small">From a label or another app, for {dayWords(viewing, today)}.</p>
            <QuickAdd when={when} numbers={numbers} units={units} />
          </div>
        </Sheet>
      )}
      {sheet === 'water' && (
        <Sheet eyebrow="Nutrition" title="Water" size="sm" onClose={() => setSheet(null)}>
          <div className="food-sheet">
            <p className="muted small">In one tap, for {dayWords(viewing, today)}. Any other amount goes in Type amounts.</p>
            <WaterButtons when={when} units={units} />
          </div>
        </Sheet>
      )}
    </section>
  );
}

const itemText = (d: FoodEntry) => (d.portion ? `${d.name} (${d.portion})` : d.name);
const dayWords = (date: string, today: string) => (date === today ? 'today' : fmtDate(date, { weekday: 'long', month: 'long', day: 'numeric' }));

/** Under the composer: what reads an estimate, or what's missing for one. */
function SetupLine({ can, ai, numbers }: { can: FoodLog['can'] | undefined; ai: AiStatus | undefined; numbers: NutritionNumbers }) {
  if (!can || !ai) return null;
  if (!can.estimate) {
    const rest = numbers === 'none' ? 'You can still search foods from +.' : 'You can still search foods, type amounts or add water from +.';
    return ai.byok ? (
      <p className="nutri-setup">
        One-time setup: <a href="#/profile?connect=openai">connect your OpenAI key</a> to start.
      </p>
    ) : (
      <p className="nutri-setup">Estimates need an AI key, and storing your own isn't available on this server. {rest}</p>
    );
  }
  const provider = can.estimateProvider ?? 'anthropic';
  const where = `your words and photos go to ${COMPANY[provider]} for each estimate, and healthOS doesn't keep them.`;
  return (
    <p className="nutri-setup is-quiet">
      {can.estimateSource === 'own' ? `Using your own ${KEY_LABEL[provider]} key` : "Using healthOS's shared assistant"} · {where}
    </p>
  );
}

/** McFly's reply with an estimate: the review while it waits, then what became of it. */
function EstimateLine({
  turn,
  day,
  fresh,
  today,
  numbers,
  units,
  onDone,
}: {
  turn: EstimateTurn;
  day: (FoodDay & { askedAt: number }) | undefined;
  /** The drafts this estimate came back with, in this tab. */
  fresh: FoodEntry[] | undefined;
  today: string;
  numbers: NutritionNumbers;
  units: Units;
  onDone: (saved: number | null) => void;
}) {
  if (turn.state === 'saved') return <p>{turn.saved === 1 || turn.saved === undefined ? 'Saved to your food journal.' : `Saved ${turn.saved} items to your food journal.`}</p>;
  if (turn.state === 'discarded') return <p className="muted">Discarded. Nothing was saved.</p>;
  if (turn.state === 'replaced') return <p className="muted small">{turn.items.join(', ')}. Corrected below.</p>;
  // The day as last read, unless it was read before this estimate arrived: then the estimate's own drafts.
  const drafts = day && day.draftBatch === turn.batch ? day.drafts : fresh && (!day || day.askedAt < turn.at) ? fresh : null;
  if (!drafts) {
    if (!day) return <p className="muted small">{turn.items.join(', ')}</p>;
    return <p className="muted">{turn.items.join(', ')}. This estimate isn't waiting any more: it was saved or discarded somewhere else, or it went after a day.</p>;
  }
  return <ChatReview key={drafts.map((d) => d.id).join()} turn={turn} drafts={drafts} today={today} numbers={numbers} units={units} onDone={onDone} />;
}

/** The estimate to check, in the conversation: the same review as the Log tab's (useEstimateReview), drawn inline. */
function ChatReview({
  turn,
  drafts,
  today,
  numbers,
  units,
  onDone,
}: {
  turn: EstimateTurn;
  drafts: FoodEntry[];
  today: string;
  numbers: NutritionNumbers;
  units: Units;
  onDone: (saved: number | null) => void;
}) {
  const { kept, byId, update, leaveOut, time, setTime, save, discard, busy, error } = useEstimateReview(drafts, turn.batch, onDone);
  const timeId = useId();
  const first = drafts[0];
  // The kept items added up, at the quantities typed.
  const total: FoodValues = {};
  for (const k of kept) {
    const d = byId.get(k.id)!;
    const q = Number(k.quantity.replace(',', '.'));
    if (!(q > 0)) continue;
    for (const [key, v] of Object.entries(scaled(d.values, q / d.quantity)) as [keyof FoodValues, number][]) total[key] = (total[key] ?? 0) + v;
  }
  const sum = numbers !== 'none' && kept.length > 1 ? amounts(total, units) : '';
  return (
    <div className="nutri-review">
      <p>
        {turn.found ? 'This estimate is waiting for you to check.' : "Here's my estimate."} <span className="muted">Check it, then save. Nothing counts until you do.</span>
      </p>
      {turn.note && <p className="nutri-note">{turn.note}</p>}
      <ul className="nutri-items">
        {kept.map((k, i) => {
          const d = byId.get(k.id)!;
          const q = Number(k.quantity.replace(',', '.'));
          const line = numbers !== 'none' && q > 0 ? amounts(scaled(d.values, q / d.quantity), units) : '';
          return (
            <li key={k.id} className="nutri-item">
              <div className="nutri-item-row">
                <input className="nutri-item-name" value={k.name} onChange={(e) => update(k.id, { name: e.target.value })} maxLength={100} aria-label={`Item ${i + 1}, name`} />
                <label className="nutri-item-qty">
                  <span className="muted small">How many</span>
                  <input
                    inputMode="decimal"
                    value={k.quantity}
                    onChange={(e) => update(k.id, { quantity: e.target.value })}
                    aria-label={`How many of ${k.name || `item ${i + 1}`}`}
                  />
                </label>
                <button type="button" className="btn btn-quiet small" onClick={() => leaveOut(k.id)} aria-label={`Leave out ${k.name}`}>
                  Leave out
                </button>
              </div>
              {(d.portion || line) && <span className="muted small">{[d.portion, line].filter(Boolean).join(' · ')}</span>}
            </li>
          );
        })}
      </ul>
      {!kept.length && <p className="muted small">Everything is left out. Discard it, or tell me what you had instead.</p>}
      {sum && (
        <p className="small nutri-sum">
          <span className="muted">Altogether</span> {sum}
        </p>
      )}
      <div className="nutri-review-foot">
        <label className="nutri-review-when" htmlFor={timeId}>
          <span className="muted small">{first.date === today ? 'Today' : relativeDay(first.date, today)} at</span>
          <input id={timeId} type="time" value={time} onChange={(e) => setTime(e.target.value)} required />
        </label>
        <div className="btn-row">
          <button type="button" className="btn btn-primary" disabled={busy || !kept.length} onClick={() => void save()}>
            {busy ? 'Saving…' : kept.length === 1 ? 'Save 1 item' : `Save ${kept.length} items`}
          </button>
          <button type="button" className="btn btn-quiet" disabled={busy} onClick={() => void discard()}>
            Discard
          </button>
        </div>
      </div>
      {error && <p className="note-bad small">{error}</p>}
      <p className="muted small">Not quite right? Tell me what to change, and I'll redo it. Estimates are rough, so you can fix any amount after saving, too.</p>
    </div>
  );
}

// ---------- the day ----------

/** Protein, carbs and fat in the design's soft greens, peach and lavender; never a colour for more or less. */
const MACROS = [
  { key: 'protein_g', label: 'Protein', color: 'var(--nutri-protein)' },
  { key: 'carbs_g', label: 'Carbs', color: 'var(--nutri-carbs)' },
  { key: 'fat_g', label: 'Fat', color: 'var(--nutri-fat)' },
] as const;

/**
 * The day's saved entries added up: kcal in the ring, protein, carbs and fat by weight beside it, the rest underneath.
 * Nothing logged is a dash, never a zero. No amounts at all ('none'): only how many meals were logged.
 */
function DailyBalance({ day, numbers, units }: { day: FoodDay | undefined; numbers: NutritionNumbers; units: Units }) {
  const entries = day?.entries ?? [];
  const b = day?.balance ?? {};
  const parts = MACROS.flatMap((m) => (b[m.key] ? [{ key: m.key, label: m.label, value: b[m.key]!, color: m.color }] : []));
  const total = parts.reduce((a, p) => a + p.value, 0);
  const pct = (v: number | undefined) => (v !== undefined && total > 0 ? `${Math.round((v / total) * 100)}%` : '—');
  // A meal is what was logged at one time (an estimate's items share theirs).
  const meals = new Set(entries.map((e) => e.time)).size;
  const extras = (
    [
      ['Fiber', b.fiber_g, (v: number) => `${grams(v)} g`],
      ['Sugar', b.sugar_g, (v: number) => `${grams(v)} g`],
      ['Sodium', b.sodium_mg, (v: number) => `${fmt(v)} mg`],
      ['Alcohol', b.alcohol_drinks, (v: number) => `${Number(v.toFixed(1))} ${v === 1 ? 'drink' : 'drinks'}`],
      ['Water', b.water_ml, (v: number) => waterText(v, units)],
    ] as const
  ).flatMap(([label, v, show]) => (v ? [{ label, value: show(v) }] : []));
  const label =
    numbers === 'none'
      ? `${meals || 'No'} ${meals === 1 ? 'meal' : 'meals'} logged`
      : total > 0
        ? `By weight: ${parts.map((p) => `${p.label.toLowerCase()} ${pct(p.value)}`).join(', ')}`
        : 'No protein, carbs or fat logged';
  return (
    <section className="card nutri-balance" aria-labelledby="nutri-balance-title">
      <header className="nutri-card-head">
        <h2 id="nutri-balance-title">Your daily balance</h2>
        <span className="badge badge-sage">
          {entries.length} {entries.length === 1 ? 'entry' : 'entries'}
        </span>
      </header>
      <div className="nutri-balance-body">
        <div className={`nutri-ring${total > 0 ? ' has-parts' : ''}`}>
          <Donut
            parts={numbers === 'none' ? [] : parts}
            size={112}
            thickness={11}
            label={label}
            center={
              numbers === 'none' ? (
                <>
                  <strong>{meals || '—'}</strong>
                  <span>{meals === 1 ? 'meal logged' : 'meals logged'}</span>
                </>
              ) : numbers === 'all' ? (
                <>
                  <strong>{b.energy_kcal !== undefined ? fmt(b.energy_kcal) : '—'}</strong>
                  <span>kcal logged</span>
                </>
              ) : (
                <>
                  {total > 0 ? null : <strong>—</strong>}
                  <span>by weight</span>
                </>
              )
            }
          />
        </div>
        {numbers === 'none' ? (
          <p className="muted small nutri-balance-none">You chose to see no amounts, so this counts your meals, not what's in them.</p>
        ) : (
          <ul className="nutri-macros">
            {MACROS.map((m) => (
              <li key={m.key}>
                <i style={{ background: m.color }} />
                <span>{m.label}</span>
                <strong>
                  {b[m.key] !== undefined ? (
                    <>
                      {grams(b[m.key]!)}
                      <small> g</small>
                    </>
                  ) : (
                    '—'
                  )}
                </strong>
                <span className="muted">{pct(b[m.key])}</span>
              </li>
            ))}
          </ul>
        )}
      </div>
      {extras.length > 0 && (
        <dl className="nutri-extras">
          {extras.map((x) => (
            <div key={x.label}>
              <dt>{x.label}</dt>
              <dd>{x.value}</dd>
            </div>
          ))}
        </dl>
      )}
      <p className="muted small">{numbers === 'none' ? 'Counted from your food journal.' : 'Estimated from your logged meals.'}</p>
    </section>
  );
}

/** The day's saved entries, each editable, as on the Log tab. */
function FoodJournal({ day, viewing, today, numbers, units }: { day: FoodDay | undefined; viewing: string; today: string; numbers: NutritionNumbers; units: Units }) {
  const entries = day?.entries ?? [];
  const counted = day?.countedApp;
  const isToday = viewing === today;
  return (
    <section className="card nutri-journal" aria-labelledby="nutri-journal-title">
      <header className="nutri-card-head">
        <h2 id="nutri-journal-title">Your food journal</h2>
        <span className="muted small">{fmtDate(viewing)}</span>
      </header>
      {!day ? (
        <p className="muted small">Loading…</p>
      ) : entries.length ? (
        <ul className="food-entries">
          {entries.map((e) => (
            <EntryRow key={e.id} entry={e} numbers={numbers} units={units} />
          ))}
        </ul>
      ) : (
        <div className="nutri-journal-empty">
          <Icon name="utensils" size={22} />
          <p className="nutri-journal-empty-title">{isToday ? 'Your day starts with a bite.' : 'Nothing logged here that day.'}</p>
          <p className="muted small">
            {isToday ? 'Tell McFly what you ate.' : 'Tell McFly what you had, and it goes on this day.'}
            <br />
            Your meals will appear here.
          </p>
        </div>
      )}
      {day && counted && counted !== 'healthOS' && (
        <p className="muted small nutri-counted">
          {entries.length ? (
            <>
              This day's totals elsewhere in Nutrition come from {counted}. When two apps log the same day, one app's totals count and the other's aren't added in, because apps
              copy each other's food through Apple Health.
              {numbers !== 'none' && (
                <>
                  {' '}
                  You can choose which app counts on <a href="#/nutrition?tab=macros">Macros</a>.
                </>
              )}
            </>
          ) : (
            <>
              You logged food in {counted} that day. Its totals are on <a href="#/nutrition?tab=trends">Trends</a>.
            </>
          )}
        </p>
      )}
    </section>
  );
}
