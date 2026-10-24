// Profile (formerly Settings), reached from the account menu (#/profile; #/settings still opens it). The shell's
// header gives the page its title. A "Your profile" card of rows (how you're shown, your AI, account, sources, the
// export, privacy, signing out), a "Your settings" card holding everything Settings had (each row opens it in a
// sheet), then two cards that open in place: your age-group comparison and your portrait photos.
import '../styles/profile.css';
import { type ReactNode, useEffect, useId, useRef, useState } from 'react';
import { AI_PROVIDERS, type AiStatus } from '../../shared/ai.ts';
import { PEER_MIN_DAYS, PEER_MIN_OTHERS, type PeerData, type PeerMetric, peerPair } from '../../shared/peers.ts';
import type { PortraitList } from '../../shared/portraits.ts';
import type { Settings, Status } from '../../shared/types.ts';
import { ChatbotSheet, OpenAIKeySheet } from '../components/ai/AiSheets.tsx';
import { CardChoices, useOwnCardEditor } from '../components/CardChoices.tsx';
import { figureVariant } from '../components/Figure.tsx';
import { Icon, type IconName } from '../components/Icon.tsx';
import { PortraitStudio } from '../components/portraits/PortraitStudio.tsx';
import { Sheet } from '../components/Sheet.tsx';
import { localToday } from '../components/shell/TopBar.tsx';
import { fmt, fmtDate, hoursMinutes, href, notifyDataChanged, sendJson, signOut, useApi } from '../lib.ts';
import { CycleSettings } from './Cycle.tsx';
import { FamilySettings } from './Family.tsx';
import { NutritionSettings } from './Nutrition.tsx';

type SheetKey = 'chatbot' | 'openai' | 'basics' | 'cards' | 'family' | 'cycle' | 'nutrition';

/** Sheets other pages can open by link: #/profile?connect=openai (Nutrition's setup line) or ?connect=chatbot. */
const LINKED: Record<string, SheetKey> = { openai: 'openai', chatbot: 'chatbot' };

export function Profile({ status, refresh, signedIn, params }: { status: Status; refresh: () => void; signedIn: boolean; params?: URLSearchParams }) {
  const [sheet, setSheet] = useState<SheetKey | null>(() => LINKED[params?.get('connect') ?? ''] ?? null);
  // Once opened from a link, drop the query, so a refresh or Back doesn't open the sheet again.
  useEffect(() => {
    if (params?.has('connect')) history.replaceState(null, '', `${location.pathname}${location.search}#/profile`);
  }, [params]);
  const [password, setPassword] = useState(false);
  const passwordId = useId();
  const { data: ai, reload: reloadAi } = useApi<AiStatus>('/ai');
  const s = status.settings;
  const close = () => setSheet(null);
  const closeAi = () => {
    setSheet(null);
    reloadAi();
  };
  const openai = ai?.keys.find((k) => k.provider === 'openai');
  const ownChat = ai?.chat?.source === 'own' ? ai.chat : null;
  const manage = (key: SheetKey, label = 'Manage') => (
    <button type="button" className="btn" onClick={() => setSheet(key)}>
      {label}
    </button>
  );

  return (
    <div className="page profile-page">
      <section className="card profile-card" aria-labelledby="profile-yours">
        <h2 id="profile-yours">Your profile</h2>
        <div className="profile-list">
          <Row
            title="Your profile & perspective"
            action={
              <a className="btn" href={href('welcome')}>
                Edit preferences
              </a>
            }
          >
            <p>{perspectiveLine(s)}</p>
            <p>{s.peerComparison ? 'Peer comparisons enabled.' : 'Peer comparisons off.'} Change your image, age or participation anytime.</p>
          </Row>
          <Row title="Chatbot" action={manage('chatbot', 'Manage chatbot AI')}>
            <p>Choose OpenAI, Claude or Gemini and connect your own API key.</p>
            {ownChat && <p>Ask McFly uses your own {providerLabel(ownChat.provider)} key.</p>}
          </Row>
          <Row
            title="Account"
            action={
              signedIn && (
                <>
                  <span className="badge badge-sage">Signed in</span>
                  <button type="button" className="btn btn-quiet" aria-expanded={password} aria-controls={passwordId} onClick={() => setPassword(!password)}>
                    Change password
                  </button>
                </>
              )
            }
            more={
              signedIn && (
                <div id={passwordId} hidden={!password}>
                  {password && <PasswordForm />}
                </div>
              )
            }
          >
            <p>
              {signedIn ? status.user.email : 'This Mac, no sign-in'}
              {signedIn && status.user.role === 'admin' && ' · admin'}
            </p>
          </Row>
          <Row title="OpenAI · Nutrition & portraits" action={manage('openai', openai ? 'Manage AI key' : 'Connect AI key')}>
            <p>Connect your own OpenAI API key for meal photos, descriptions and voice notes.</p>
            {openai && <p className="profile-ok">Connected · key ending ••••{openai.last4}</p>}
          </Row>
          <Row
            title="Connected sources"
            action={
              <a className="btn" href={href('integrations')}>
                Manage sources
              </a>
            }
          >
            <p>Manage what comes into your health profile.</p>
          </Row>
          <ExportRow />
          <Row
            title="Privacy & data use"
            action={
              <a className="btn" href="/privacy.html" target="_blank" rel="noopener">
                Read details<span className="sr-only"> (opens in a new tab)</span>
              </a>
            }
          >
            <p>Understand how files, food descriptions and recordings are handled.</p>
          </Row>
          {signedIn && (
            <Row
              title="End your session"
              action={
                <button type="button" className="btn" onClick={signOut}>
                  Sign out
                </button>
              }
            >
              <p>Sign out on this device.</p>
            </Row>
          )}
        </div>
      </section>

      <section className="card profile-card" aria-labelledby="profile-settings">
        <h2 id="profile-settings">Your settings</h2>
        <div className="profile-list">
          <Row title="Units & daily goal" action={manage('basics', 'Edit')}>
            <p>
              {s.name ? `${s.name} · ` : ''}
              {s.units === 'imperial' ? 'Imperial (lb, °F, mi)' : 'Metric (kg, °C, km)'} · {fmt(s.stepGoal)} steps a day
            </p>
          </Row>
          <Row title="Cards" action={manage('cards', 'Choose cards')}>
            <p>Choose the cards you see on Home, Sleep{s.nutrition ? ', Body and Nutrition' : ' and Body'}.</p>
          </Row>
          {signedIn && (
            <Row title="Family board" action={manage('family')}>
              <p>{s.familySharing ? 'Sharing on. Members who share see your tile and its last 30 days.' : 'Sharing off. You see no one, and no one sees you.'}</p>
            </Row>
          )}
          <Row title="Cycle tracking" action={manage('cycle')}>
            <p>
              {s.cycleTracking ? 'On' : 'Off'} · Sex for health calculations: {s.sex === 'female' ? 'female' : s.sex === 'male' ? 'male' : s.sex === 'unspecified' ? 'prefer not to say' : 'not set'}
            </p>
          </Row>
          <Row title="Nutrition" action={manage('nutrition')}>
            <p>{s.nutrition ? `On · ${NUMBERS_SEEN[s.nutritionNumbers ?? 'all']}` : 'Off'}</p>
          </Row>
        </div>
      </section>

      <PeerComparison />
      <PortraitPhotos status={status} refresh={refresh} />

      {sheet === 'chatbot' && <ChatbotSheet onClose={closeAi} />}
      {sheet === 'openai' && <OpenAIKeySheet onClose={closeAi} />}
      {sheet === 'basics' && <BasicsSheet status={status} refresh={refresh} onClose={close} />}
      {sheet === 'cards' && <CardsSheet status={status} refresh={refresh} onClose={close} />}
      {sheet === 'family' && (
        <Sheet eyebrow="Profile" title="Family board" onClose={close}>
          <div className="profile-sheet">
            <FamilySettings status={status} refresh={refresh} />
          </div>
        </Sheet>
      )}
      {sheet === 'cycle' && (
        <Sheet eyebrow="Profile" title="Cycle tracking" onClose={close}>
          <div className="profile-sheet">
            <CycleSettings status={status} refresh={refresh} family={signedIn && s.familySharing} />
          </div>
        </Sheet>
      )}
      {sheet === 'nutrition' && (
        <Sheet eyebrow="Profile" title="Nutrition" onClose={close}>
          <div className="profile-sheet">
            <NutritionSettings status={status} refresh={refresh} />
          </div>
        </Sheet>
      )}
    </div>
  );
}

const NUMBERS_SEEN: Record<NonNullable<Settings['nutritionNumbers']>, string> = {
  all: 'calories and nutrients',
  no_energy: 'nutrients without calories',
  none: 'what you logged, no amounts',
};

const providerLabel = (p: string) => AI_PROVIDERS.find((x) => x.provider === p)?.label ?? p;

/** "Digital man · 33 years": how Home and Body show you, and your age. */
function perspectiveLine(s: Settings) {
  const look =
    s.perspective === 'digital' ? (figureVariant(s) === 'woman' ? 'Digital woman' : 'Digital man') : s.perspective === 'stats' ? 'Just the statistics' : 'Your portrait';
  return s.age != null ? `${look} · ${s.age} years` : `${look} · no age given`;
}

/** One row of a profile card: a title and a line or two on the left, its pill on the right, and an optional part under both. */
function Row({ title, children, action, more }: { title: string; children: ReactNode; action?: ReactNode; more?: ReactNode }) {
  return (
    <div className="profile-row">
      <div className="profile-row-main">
        <div className="profile-row-text">
          <h3>{title}</h3>
          {children}
        </div>
        {action && <div className="profile-row-action">{action}</div>}
      </div>
      {more}
    </div>
  );
}

// ---------- Export your data ----------

/** GET /api/me/export, fetched (not a link) so the button can say it's preparing and a failure can say so. */
function ExportRow() {
  const [busy, setBusy] = useState(false);
  const [result, setResult] = useState<{ ok: boolean; text: string } | null>(null);

  async function download() {
    setBusy(true);
    setResult(null);
    try {
      const res = await fetch('/api/me/export').catch(() => {
        throw new Error("Couldn't reach healthOS. Check your connection and try again.");
      });
      if (res.status === 401) window.dispatchEvent(new Event('healthos:signin'));
      if (!res.ok) throw new Error(((await res.json().catch(() => null)) as { error?: string } | null)?.error ?? "Couldn't prepare your export. Try again in a moment.");
      // A connection broken part-way (the server stops rather than send half a file) fails here.
      const blob = await res.blob().catch(() => {
        throw new Error('The download stopped before it finished. Try again in a minute.');
      });
      const name = /filename="([^"]+)"/.exec(res.headers.get('content-disposition') ?? '')?.[1] ?? `healthos-export-${localToday()}.json`;
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = name;
      document.body.append(a);
      a.click();
      a.remove();
      setTimeout(() => URL.revokeObjectURL(url), 60_000);
      setResult({ ok: true, text: `Saved ${name}.` });
    } catch (e) {
      setResult({ ok: false, text: (e as Error).message });
    } finally {
      setBusy(false);
    }
  }

  return (
    <Row
      title="Export your data"
      action={
        <button type="button" className="btn" disabled={busy} onClick={download}>
          {busy ? 'Preparing…' : 'Download JSON'}
        </button>
      }
    >
      <p>Download your complete meal history, readings, lab results and file metadata.</p>
      <p className={result ? (result.ok ? 'profile-ok' : 'profile-bad') : 'sr-only'} role="status">
        {result?.text}
      </p>
    </Row>
  );
}

// ---------- the settings sheets ----------

/** Name, step goal and units. Name and goal are saved as the sheet closes (a new name reloads the page), units at once. */
function BasicsSheet({ status, refresh, onClose }: { status: Status; refresh: () => void; onClose: () => void }) {
  const [name, setName] = useState(status.settings.name);
  const [goal, setGoal] = useState(String(status.settings.stepGoal));
  const [saved, setSaved] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const timer = useRef<ReturnType<typeof setTimeout>>(undefined);
  useEffect(() => () => clearTimeout(timer.current), []);

  async function save(patch: Partial<Settings>) {
    await sendJson('PUT', '/settings', patch);
    refresh();
    notifyDataChanged();
  }

  async function units(u: Settings['units']) {
    setError(null);
    try {
      await save({ units: u });
      setSaved(true);
      clearTimeout(timer.current);
      timer.current = setTimeout(() => setSaved(false), 1500);
    } catch (e) {
      setError((e as Error).message);
    }
  }

  async function done() {
    const patch: Partial<Settings> = {};
    if (name.trim() !== status.settings.name) patch.name = name;
    if (Number(goal) !== status.settings.stepGoal && goal) patch.stepGoal = Number(goal);
    if (Object.keys(patch).length) {
      try {
        await save(patch);
      } catch (e) {
        return setError((e as Error).message);
      }
    }
    onClose();
  }

  return (
    <Sheet
      eyebrow="Profile"
      title="Units & daily goal"
      onClose={done}
      footer={
        <button type="button" className="btn btn-primary" onClick={done}>
          Done
        </button>
      }
    >
      <form
        className="settings profile-form"
        onSubmit={(e) => {
          e.preventDefault();
          void done();
        }}
      >
        <label>
          <span>Name</span>
          <input value={name} maxLength={40} autoComplete="given-name" onChange={(e) => setName(e.target.value)} />
        </label>
        <label>
          <span>Daily step goal</span>
          <input inputMode="numeric" value={goal} onChange={(e) => setGoal(e.target.value.replace(/\D/g, ''))} />
          <small className="muted">Between 500 and 100,000.</small>
        </label>
        <div className="settings-row">
          <span>Units</span>
          <div className="filters" role="group" aria-label="Units">
            {(['metric', 'imperial'] as const).map((u) => (
              <button type="button" key={u} className={status.settings.units === u ? 'on' : ''} aria-pressed={status.settings.units === u} onClick={() => units(u)}>
                {u === 'metric' ? 'Metric (kg, °C, km)' : 'Imperial (lb, °F, mi)'}
              </button>
            ))}
          </div>
        </div>
        <p className={`muted small saved ${saved ? 'is-on' : ''}`} role="status">
          <Icon name="check" size={14} /> Saved
        </p>
        {error && <p className="note-bad small">{error}</p>}
        {/* Enter in a field saves and closes. */}
        <button type="submit" hidden />
      </form>
    </Sheet>
  );
}

/** Which cards show on Home, Sleep, Body and Nutrition. Only the layout: nothing is deleted, and an unticked card comes back as it was. */
function CardsSheet({ status, refresh, onClose }: { status: Status; refresh: () => void; onClose: () => void }) {
  const cards = useOwnCardEditor(status.settings, refresh);
  return (
    <Sheet
      eyebrow="Profile"
      title="Cards"
      size="lg"
      onClose={onClose}
      footer={
        <>
          {cards.lists.hidden.length > 0 && (
            <button type="button" className="btn btn-quiet" onClick={cards.showAll}>
              Show all
            </button>
          )}
          <button type="button" className="btn btn-primary" onClick={onClose}>
            Done
          </button>
        </>
      }
    >
      <div className="settings-cards profile-cards">
        <p className="muted small">
          Choose the cards you see on Home, Sleep{status.settings.nutrition ? ', Body and Nutrition' : ' and Body'}. Hiding one only changes the page; your data stays.
        </p>
        <CardChoices lists={cards.lists} onToggle={cards.toggle} idPrefix="me" nutrition={status.settings.nutrition} />
        {cards.error && <p className="note-bad small">{cards.error}</p>}
      </div>
    </Sheet>
  );
}

function PasswordForm() {
  const [current, setCurrent] = useState('');
  const [next, setNext] = useState('');
  const [confirmNext, setConfirmNext] = useState('');
  const [busy, setBusy] = useState(false);
  const [result, setResult] = useState<{ ok: boolean; text: string } | null>(null);
  const valid = current.length > 0 && next.length >= 10 && next === confirmNext;

  async function change(e: React.FormEvent) {
    e.preventDefault();
    if (!valid) return;
    setBusy(true);
    setResult(null);
    try {
      await sendJson('POST', '/auth/password', { current, next });
      setCurrent('');
      setNext('');
      setConfirmNext('');
      setResult({ ok: true, text: 'Password changed. Other devices are signed out.' });
    } catch (err) {
      setResult({ ok: false, text: (err as Error).message });
    } finally {
      setBusy(false);
    }
  }

  return (
    <form className="settings profile-form profile-password" onSubmit={change}>
      <label>
        <span>Current password</span>
        <input type="password" autoComplete="current-password" value={current} onChange={(e) => setCurrent(e.target.value)} />
      </label>
      <label>
        <span>New password</span>
        <input type="password" autoComplete="new-password" value={next} onChange={(e) => setNext(e.target.value)} />
        <small className={next && next.length < 10 ? 'note-bad' : 'muted'}>At least 10 characters.</small>
      </label>
      <label>
        <span>Confirm new password</span>
        <input type="password" autoComplete="new-password" value={confirmNext} onChange={(e) => setConfirmNext(e.target.value)} />
        {confirmNext && confirmNext !== next && <small className="note-bad">The passwords don't match.</small>}
      </label>
      <button className="btn btn-primary" type="submit" disabled={busy || !valid}>
        {busy ? 'Changing…' : 'Change password'}
      </button>
      {result && (
        <p className={result.ok ? 'note-good' : 'note-bad'} role="status">
          <Icon name={result.ok ? 'check' : 'alert'} size={15} /> {result.text}
        </p>
      )}
    </form>
  );
}

// ---------- cards that open in place ----------

function Collapsible({ icon, title, meta, children }: { icon: IconName; title: string; meta: ReactNode; children: (open: boolean) => ReactNode }) {
  const [open, setOpen] = useState(false);
  const id = useId();
  return (
    <section className={`card profile-collapse ${open ? 'is-open' : ''}`}>
      <h2 className="profile-collapse-head">
        <button type="button" aria-expanded={open} aria-controls={id} onClick={() => setOpen(!open)}>
          <Icon name={icon} size={17} />
          <span className="profile-collapse-text">
            <span className="profile-collapse-title">{title}</span>
            {/* Keeps the button's name "Your portrait photos, 0 files" rather than one run-on word. */}
            {meta && <span className="sr-only">, </span>}
            <span className="profile-collapse-meta">{meta}</span>
          </span>
          <Icon name={open ? 'minus' : 'plus'} size={16} strokeWidth={1.8} />
        </button>
      </h2>
      <div id={id} className="profile-collapse-body" hidden={!open}>
        {open && children(open)}
      </div>
    </section>
  );
}

function PeerComparison() {
  return (
    <Collapsible icon="chart" title="Your age-group comparison" meta="Private to you">
      {() => <PeerBody />}
    </Collapsible>
  );
}

const NOT_TAKING_PART: Record<Extract<PeerData, { participating: false }>['reason'], ReactNode> = {
  off: (
    <>
      You're not taking part. Turn it on in <a href={href('welcome')}>Edit preferences</a>.
    </>
  ),
  no_age: (
    <>
      Add your age in <a href={href('welcome')}>Edit preferences</a> to take part.
    </>
  ),
  under_age: 'Peer comparisons are for people aged 18 and over.',
  no_accounts: "There's no one to compare with here: this healthOS runs on this Mac without accounts.",
};

const SOURCE_LABEL: Record<string, string> = { whoop: 'WHOOP', apple: 'Apple Health', demo: 'Sample' };

function PeerBody() {
  const { data, error } = useApi<PeerData>('/peers');
  if (error) return <p className="profile-bad">Couldn't load your comparison: {error.message}</p>;
  if (!data) return <p className="muted small">Loading…</p>;
  const fine = (
    <p className="profile-fine">A percentile describes your position in this healthOS group. A higher number does not necessarily mean better health.</p>
  );
  if (!data.participating) {
    return (
      <>
        <p className="profile-peer-note">{NOT_TAKING_PART[data.reason]}</p>
        {fine}
      </>
    );
  }
  const gathering = data.metrics.some((m) => m.status === 'gathering') && !data.metrics.some((m) => m.status === 'ready');
  return (
    <>
      <p className="profile-peer-window">
        Ages {data.ageBand} · your averages for {fmtDate(data.window.from)} – {fmtDate(data.window.to)}
      </p>
      {data.demo && <p className="profile-peer-demo">Sample group: in this local preview the people you're compared with are made up.</p>}
      {gathering && (
        <p className="profile-peer-note">
          Not enough people in your age group yet. Results appear once at least {PEER_MIN_OTHERS} others have {PEER_MIN_DAYS} recorded days.
        </p>
      )}
      {data.metrics.length ? (
        <ul className="profile-peers">
          {data.metrics.map((m) => (
            <PeerRow key={`${m.metric}|${m.source}`} m={m} />
          ))}
        </ul>
      ) : (
        <p className="profile-peer-note">No readings from WHOOP or Apple Health in the last 30 days to compare yet.</p>
      )}
      {fine}
    </>
  );
}

/** 62 → "62nd". */
function ordinal(n: number) {
  const teen = n % 100 >= 11 && n % 100 <= 13;
  return `${n}${teen ? 'th' : ({ 1: 'st', 2: 'nd', 3: 'rd' } as Record<number, string>)[n % 10] ?? 'th'}`;
}

function PeerRow({ m }: { m: PeerMetric }) {
  const pair = peerPair(m.metric, m.source);
  const digits = pair?.digits ?? 0;
  const unit = pair?.unit === '%' ? '%' : pair?.unit ? ` ${pair.unit}` : '';
  const sleep = m.metric === 'sleep_hours';
  const show = (v: number) => (sleep ? hoursMinutes(v) : `${fmt(v, digits)}${unit}`);
  const range = (lo: number, hi: number) => (sleep ? `${hoursMinutes(lo)}–${hoursMinutes(hi)}` : `${fmt(lo, digits)}–${fmt(hi, digits)}${unit}`);
  const yours = m.you === null ? null : `Your average ${show(m.you)} over ${m.yourDays} ${m.yourDays === 1 ? 'day' : 'days'}`;
  return (
    <li className="profile-peer">
      <div className="profile-peer-text">
        <h3>
          {pair?.label ?? m.metric} · {SOURCE_LABEL[m.source] ?? m.source}
        </h3>
        {m.status === 'ready' && m.percentile !== undefined && m.group ? (
          <>
            <p className="profile-peer-figure">
              {ordinal(m.percentile)} percentile · group median {show(m.group.median)}
            </p>
            {yours && <p>{yours}</p>}
            <p>
              Middle half of the group {range(m.group.p25, m.group.p75)} · {m.group.size} people
            </p>
          </>
        ) : m.status === 'not_enough_days' ? (
          <p>
            {m.yourDays} of {PEER_MIN_DAYS} recorded days so far: your result appears after {PEER_MIN_DAYS}.
          </p>
        ) : (
          <p>{yours && `${yours}. `}Waiting for enough people in your age group to compare with.</p>
        )}
      </div>
      {m.status === 'ready' && m.percentile !== undefined && (
        // The group's middle half is the 25th to 75th percentile by definition, so the band sits there; the dot is you.
        <div className="profile-peer-bar" aria-hidden="true">
          <span className="profile-peer-band" />
          <span className="profile-peer-dot" style={{ left: `${m.percentile}%` }} />
        </div>
      )}
    </li>
  );
}

function PortraitPhotos({ status, refresh }: { status: Status; refresh: () => void }) {
  const { data, reload } = useApi<PortraitList>('/portraits');
  const n = data?.portraits.length;
  return (
    <Collapsible icon="camera" title="Your portrait photos" meta={n === undefined ? '' : `${n} ${n === 1 ? 'file' : 'files'}`}>
      {() => (
        <>
          <PortraitStudio
            status={status}
            reload={() => {
              reload();
              refresh();
            }}
          />
          <PhotoSettings status={status} refresh={refresh} />
        </>
      )}
    </Collapsible>
  );
}

// ---------- Use a photo as is (the on-device cut-out) ----------

type Processed = { cutout: Blob; avatar: Blob; meta: unknown; cutoutUrl: string; avatarUrl: string };

const base64 = (blob: Blob) =>
  new Promise<string>((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(String(reader.result).split(',')[1] ?? '');
    reader.onerror = () => reject(new Error("Couldn't read the processed photo."));
    reader.readAsDataURL(blob);
  });

function PhotoSettings({ status, refresh }: { status: Status; refresh: () => void }) {
  const [busy, setBusy] = useState(false);
  const [step, setStep] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [drag, setDrag] = useState(false);
  const [preview, setPreview] = useState<Processed | null>(null);
  const input = useRef<HTMLInputElement>(null);
  const photo = status.photo;

  useEffect(
    () => () => {
      if (preview) {
        URL.revokeObjectURL(preview.cutoutUrl);
        URL.revokeObjectURL(preview.avatarUrl);
      }
    },
    [preview],
  );

  /** On the Mac: the server cuts the photo out with Apple Vision. */
  async function uploadToMac(file: File) {
    const res = await fetch('/api/profile/photo', { method: 'POST', headers: { 'X-HealthOS': '1', 'Content-Type': 'application/octet-stream' }, body: file });
    if (!res.ok) throw new Error(((await res.json().catch(() => ({}))) as { error?: string }).error ?? 'Processing failed');
    refresh();
    notifyDataChanged();
  }

  /** Hosted: cut out and measured right here in the browser; nothing is uploaded until you save. */
  async function processHere(file: File) {
    const { processPhoto } = await import('../photo/process.ts');
    const done = await processPhoto(file, setStep);
    setPreview({ ...done, cutoutUrl: URL.createObjectURL(done.cutout), avatarUrl: URL.createObjectURL(done.avatar) });
  }

  async function choose(file: File) {
    setError(null);
    if (!file.type.startsWith('image/') && !/\.(heic|heif)$/i.test(file.name)) return setError('Choose an image file (JPEG or PNG).');
    setBusy(true);
    try {
      await (status.hosted ? processHere(file) : uploadToMac(file));
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
      setStep(null);
    }
  }

  async function save() {
    if (!preview) return;
    setBusy(true);
    setError(null);
    try {
      const res = await fetch('/api/profile/photo/upload', {
        method: 'POST',
        headers: { 'X-HealthOS': '1', 'Content-Type': 'application/json' },
        body: JSON.stringify({ cutout: await base64(preview.cutout), avatar: await base64(preview.avatar), meta: preview.meta }),
      });
      if (res.status === 413) throw new Error('That photo came out too large to save. Try a smaller or tighter photo.');
      if (!res.ok) throw new Error(((await res.json().catch(() => ({}))) as { error?: string }).error ?? "Couldn't save the photo.");
      setPreview(null);
      refresh();
      notifyDataChanged();
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  }

  return (
    <section className="settings profile-photo">
      <div>
        <h3>Use a photo as is</h3>
        <p className="muted small">
          {status.hosted
            ? "Used for the figure on Home and your avatar. It's cut out on this device; only the cut-out, avatar and the points for your vitals are saved."
            : "Used for the figure on Home and your avatar. It's cut out and analyzed on this Mac with Apple's Vision framework, then saved to your healthOS database."}
        </p>
      </div>
      {preview ? (
        <div className="photo-row">
          <img className="photo-preview" src={preview.cutoutUrl} alt="Your new cut-out" />
          <div className="photo-confirm">
            <img className="photo-avatar-preview" src={preview.avatarUrl} alt="Your new avatar" />
            <p className="muted small">Here's how it came out. Save it to use it on Home and as your avatar.</p>
            <div className="btn-row">
              <button className="btn btn-primary" disabled={busy} onClick={save}>
                {busy ? 'Saving…' : 'Save photo'}
              </button>
              <button className="btn btn-quiet" disabled={busy} onClick={() => setPreview(null)}>
                Cancel
              </button>
            </div>
          </div>
        </div>
      ) : (
        <div className="photo-row">
          {photo && <img className="photo-preview" src={`/api/profile/cutout.png?v=${photo.version}`} alt="Your cut-out photo" />}
          <div
            className={`dropzone photo-drop ${drag ? 'is-drag' : ''}`}
            onDragOver={(e) => {
              e.preventDefault();
              setDrag(true);
            }}
            onDragLeave={() => setDrag(false)}
            onDrop={(e) => {
              e.preventDefault();
              setDrag(false);
              const f = e.dataTransfer.files[0];
              if (f && !busy) choose(f);
            }}
          >
            {busy ? (
              <span className="progress-label">
                {status.hosted ? (step ?? 'Working…') : 'Cutting out and measuring… (the first run compiles the tool, about 15s)'}
              </span>
            ) : (
              <>
                <Icon name="upload" size={22} />
                <span>{photo ? 'Drop a new photo to replace it' : 'Drop a photo of yourself here'}</span>
                <button className="btn" onClick={() => input.current?.click()}>
                  {photo ? 'Choose a new photo' : 'Upload a photo'}
                </button>
              </>
            )}
            <input
              ref={input}
              type="file"
              accept="image/*,.heic,.heif"
              hidden
              onChange={(e) => {
                const f = e.target.files?.[0];
                e.target.value = '';
                if (f) choose(f);
              }}
            />
          </div>
        </div>
      )}
      {error && (
        <p className="note-bad">
          <Icon name="alert" size={15} /> {error}
        </p>
      )}
      {photo && !busy && !preview && (
        <button
          className="btn btn-quiet"
          onClick={async () => {
            await sendJson('POST', '/profile/photo/clear');
            refresh();
            notifyDataChanged();
          }}
        >
          Remove photo
        </button>
      )}
    </section>
  );
}
