import { type ReactNode, useEffect, useState } from 'react';
import type { FamilyBoard, FamilyCyclePhase, FamilyMember, FamilyReason, FamilyStatus, Point, Status } from '../../shared/types.ts';
import { BarChart, ChartCard, TrendChart } from '../charts/Charts.tsx';
import { MiniBars, MiniLine } from '../charts/Mini.tsx';
import { hourLabel } from '../charts/day.ts';
import { Icon, type IconName } from '../components/Icon.tsx';
import { compact, daysBetween, fmt, fmtDate, hoursMinutes, href, notifyDataChanged, sendJson, useApi } from '../lib.ts';

/** Other people's changes don't move your data version, so the board re-reads itself while it's open. */
const REFRESH_MS = 5 * 60_000;

/** Everyone who shares, at a glance: each against their own usual, never against each other. */
export function Family({ isAdmin, refreshStatus, params }: { isAdmin: boolean; refreshStatus: () => void; params: URLSearchParams }) {
  const { data, error, reload } = useApi<FamilyBoard>('/family');
  useFamilyRefresh(reload);

  if (error && !data) return <div className="page-message">Couldn't load the family board: {error.message}</div>;
  if (!data) return <div className="page-message">Loading…</div>;
  if (!data.sharing) return <SharingOff onOn={() => (reload(), refreshStatus())} />;
  // One person, bigger: #/family?member=<id>. Someone who stopped sharing is simply not found.
  const person = params.get('member');
  const open = person ? data.members.find((m) => m.id === person) : undefined;
  if (person) return open ? <MemberPage m={open} boardToday={data.today} /> : <NotSharing />;

  const others = data.members.filter((m) => !m.isYou);
  return (
    <div className="page family">
      <header className="greeting family-greeting">
        <h1>Your family, today.</h1>
        <p className="greeting-sub">{groupLine(data.members) || 'Each person against their own last 30 days.'}</p>
      </header>
      <div className="family-grid">
        {data.members.map((m) => (
          <Tile key={m.id} m={m} boardToday={data.today} />
        ))}
        {others.length === 0 && (
          <div className="card family-empty">
            <p>No one else is sharing yet.</p>
            {isAdmin && (
              <a className="btn" href={href('admin')}>
                Invite someone
              </a>
            )}
          </div>
        )}
      </div>
      <p className="muted small family-foot">
        Statuses compare each person with their own last 30 days. They're a nudge to check in, not medical advice. Change what you share in{' '}
        <a href={href('settings')}>Settings</a>.
      </p>
    </div>
  );
}

/**
 * Other people's changes don't move your data version, so a cached board could outlive someone turning
 * sharing off. Re-read it on opening, every few minutes while visible, and on returning to the tab.
 */
function useFamilyRefresh(reload: () => void) {
  useEffect(() => {
    reload();
    const onShow = () => document.visibilityState === 'visible' && reload();
    const t = setInterval(onShow, REFRESH_MS);
    window.addEventListener('focus', onShow);
    document.addEventListener('visibilitychange', onShow);
    return () => {
      clearInterval(t);
      window.removeEventListener('focus', onShow);
      document.removeEventListener('visibilitychange', onShow);
    };
  }, [reload]);
}

const STATUS_ORDER: FamilyStatus[] = ['check', 'off', 'good'];
const GROUP: Partial<Record<FamilyStatus, string>> = { check: 'Check in', off: 'Off their usual', good: 'All good' };

/** "Check in: Leo · Off their usual: Ana · All good: Maria, you" (only the three statuses that say something). */
function groupLine(members: FamilyMember[]) {
  return STATUS_ORDER.map((s) => {
    const names = members.filter((m) => m.status === s).map((m) => (m.isYou ? 'you' : m.name));
    return names.length ? `${GROUP[s]}: ${names.join(', ')}` : '';
  })
    .filter(Boolean)
    .join(' · ');
}

function Tile({ m, boardToday }: { m: FamilyMember; boardToday: string }) {
  const quiet = m.status === 'quiet';
  const body = (
    <>
      <div className="family-head">
        <Avatar m={m} />
        <div className="family-who">
          <div className="family-name">
            <h2>{m.isYou ? `${m.name} (you)` : m.name}</h2>
            {m.cyclePhase && <span className="chip tone-pink">{PHASE[m.cyclePhase]}</span>}
            {m.demo && <span className="pill pill-demo">Demo data</span>}
          </div>
          <p className="muted small">
            {[m.devices.map((d) => DEVICE[d]).join(' + '), m.today !== boardToday ? `their ${fmtDate(m.today, { weekday: 'short' })}` : '']
              .filter(Boolean)
              .join(' · ') || 'No devices yet'}
          </p>
        </div>
        <StatusPill m={m} />
      </div>
      {m.reasons.length > 0 && <p className="family-reasons">{m.reasons.map((r) => REASON[r]).join(' · ')}</p>}
      <div className="family-slots">
        <Slot icon="sleep" label="Sleep" value={m.sleep ? hoursMinutes(m.sleep.hours) : null} note={sleepNote(m)}>
          <Spark kind="bars" points={week(m.history.sleep.points, m.today)} format={hoursMinutes} label={`${m.name}'s sleep, last 7 nights`} />
        </Slot>
        <Slot icon="heart" label={readinessLabel(m)} value={readinessValue(m)} note={readinessNote(m)}>
          <Spark kind="line" points={week(m.history.readiness?.points ?? [], m.today)} format={(v) => readinessFormat(m, v)} label={`${m.name}'s ${readinessLabel(m)}, last 7 days`} />
        </Slot>
        <Slot icon="steps" label="Steps" value={m.steps ? fmt(m.steps.value) : null} note={stepsNote(m)}>
          <Spark kind="bars" points={week(m.history.steps, m.today)} format={(v) => fmt(v)} label={`${m.name}'s steps, last 7 days`} />
        </Slot>
        <Slot icon="vitals" label="Resting HR" value={m.restingHr ? `${m.restingHr.value}` : lastValue(m.history.restingHr)} note={restingNote(m)}>
          <Spark kind="line" points={week(m.history.restingHr, m.today)} format={(v) => `${fmt(v)} bpm`} label={`${m.name}'s resting heart rate, last 7 days`} />
        </Slot>
      </div>
    </>
  );
  // Every tile opens that person's page.
  return (
    <a className={`card family-tile ${quiet ? 'is-quiet' : ''}`} href={memberHref(m.id)} aria-label={`${m.name}: open their last 30 days`}>
      {body}
    </a>
  );
}

const memberHref = (id: string) => `${href('family')}?member=${encodeURIComponent(id)}`;
/** The last 7 days of a 30-day history. */
const week = (points: Point[], today: string) => points.filter((p) => daysBetween(p.date, today) < 7);
const lastValue = (points: Point[]) => (points.length ? `${fmt(points.at(-1)!.value)}` : null);
const readinessLabel = (m: FamilyMember) =>
  m.readiness ? (m.readiness.kind === 'hrv' ? 'HRV' : 'Recovery') : m.history.readiness ? (m.history.readiness.kind === 'recovery' ? 'Recovery' : 'HRV') : m.devices.includes('whoop') ? 'Recovery' : 'HRV';
const readinessFormat = (m: FamilyMember, v: number) => (readinessLabel(m) === 'Recovery' ? `${fmt(v)}%` : `${fmt(v)} ms`);

function restingNote(m: FamilyMember) {
  const r = m.restingHr;
  if (!r) {
    // A reading without a verdict: either too new to have a usual, or not recent (then say when it was).
    const last = m.history.restingHr.at(-1);
    if (!last) return 'None lately';
    return daysBetween(last.date, m.today) <= 2 ? 'bpm · no usual yet' : `bpm · ${since(last.date, m.today)}`;
  }
  if (r.usual === null) return 'bpm';
  return `bpm · ${r.status === 'normal' ? 'about usual' : `${r.status === 'high' ? 'above' : 'below'} usual ${r.usual}`}`;
}

/** A small 7-day chart under a tile's number; nothing when there are fewer than two days. */
function Spark({ kind, points, format, label }: { kind: 'bars' | 'line'; points: Point[]; format: (v: number) => string; label: string }) {
  if (points.length < 2) return null;
  return kind === 'bars' ? <MiniBars points={points} format={format} height={34} label={label} /> : <MiniLine points={points} format={format} height={34} label={label} />;
}

/** Their photo, or their initial when there's none (or it can't be loaded any more). */
function Avatar({ m }: { m: FamilyMember }) {
  const [failed, setFailed] = useState(false);
  return (
    <span className="avatar family-avatar">
      {m.avatar && !failed ? <img src={`/api/family/${encodeURIComponent(m.id)}/avatar.png?v=${m.avatar}`} alt="" onError={() => setFailed(true)} /> : initial(m.name)}
    </span>
  );
}

function StatusPill({ m }: { m: FamilyMember }) {
  if (m.status === null) return null;
  const their = m.isYou ? 'your' : 'their';
  let text: string;
  if (m.status === 'quiet') {
    const allQuiet = m.latestDataDate === null || m.latestDataDate === m.quietSince;
    text = m.quietSince ? `No ${allQuiet ? 'new data' : 'watch or WHOOP data'} since ${since(m.quietSince, m.today)}` : 'No data yet';
  } else if (m.status === 'learning') text = `Getting to know ${their} usual`;
  else text = m.status === 'good' ? 'All good' : m.status === 'off' ? `Off ${their} usual` : 'Check in';
  return (
    <span className={`family-status is-${m.status}`}>
      {m.status !== 'quiet' && m.status !== 'learning' && <i aria-hidden="true" />}
      {text}
    </span>
  );
}

function Slot({ icon, label, value, note, children }: { icon: IconName; label: string; value: string | null; note: ReactNode; children?: ReactNode }) {
  return (
    <div className="family-slot">
      <span className="family-slot-label">
        <Icon name={icon} size={14} /> {label}
      </span>
      <b>{value ?? '—'}</b>
      <span className="muted small">{note}</span>
      {children}
    </div>
  );
}

// ---------- one person, bigger ----------

/** A person's last 30 days: each chart against their own usual (the dashed median line). */
function MemberPage({ m, boardToday }: { m: FamilyMember; boardToday: string }) {
  const h = m.history;
  const rows = (points: Point[], format: (v: number) => string) => points.map((p) => [fmtDate(p.date, { weekday: 'short', month: 'short', day: 'numeric' }), format(p.value)]);
  const readiness = readinessLabel(m);
  return (
    <div className="page family family-person">
      <a className="family-back" href={href('family')}>
        <Icon name="chevron-left" size={16} /> Family
      </a>
      <header className="card family-person-head">
        <Avatar m={m} />
        <div className="family-who">
          <div className="family-name">
            <h1>{m.isYou ? `${m.name} (you)` : m.name}</h1>
            {m.cyclePhase && <span className="chip tone-pink">{PHASE[m.cyclePhase]}</span>}
            {m.demo && <span className="pill pill-demo">Demo data</span>}
          </div>
          <p className="muted small">
            {[m.devices.map((d) => DEVICE[d]).join(' + '), m.today !== boardToday ? `their ${fmtDate(m.today, { weekday: 'short' })}` : '', 'last 30 days']
              .filter(Boolean)
              .join(' · ')}
          </p>
          {m.reasons.length > 0 && <p className="family-reasons">{m.reasons.map((r) => REASON[r]).join(' · ')}</p>}
        </div>
        <StatusPill m={m} />
      </header>
      <div className="grid-2">
        <ChartCard
          title={h.sleep.inBed ? 'Time in bed' : 'Sleep'}
          value={m.sleep ? hoursMinutes(m.sleep.hours) : '—'}
          note={m.sleep?.usual != null && !m.sleep.inBed ? `usual ${hoursMinutes(m.sleep.usual)}` : h.sleep.inBed ? 'from the iPhone' : undefined}
          table={{ columns: ['Night', 'Hours'], rows: rows(h.sleep.points, hoursMinutes) }}
        >
          <BarChart points={h.sleep.points} format={hoursMinutes} tickFormat={(v) => `${fmt(v)}h`} label={`${m.name}'s sleep per night`} />
        </ChartCard>
        <ChartCard
          title={readiness === 'Recovery' ? 'WHOOP recovery' : 'Heart rate variability'}
          value={readinessValue(m) ?? '—'}
          note={m.readiness?.usual != null ? `usual ${readinessFormat(m, m.readiness.usual)}` : undefined}
          table={{ columns: ['Day', readiness], rows: rows(h.readiness?.points ?? [], (v) => readinessFormat(m, v)) }}
        >
          <TrendChart
            points={h.readiness?.points ?? []}
            format={(v) => readinessFormat(m, v)}
            color="var(--series-3)"
            refLines={m.readiness?.usual != null ? [{ value: m.readiness.usual, label: 'usual' }] : []}
            median={false}
            label={`${m.name}'s ${readiness} per day`}
          />
        </ChartCard>
        <ChartCard
          title="Steps"
          value={m.steps ? fmt(m.steps.value) : '—'}
          note={m.steps ? 'today so far' : undefined}
          table={{ columns: ['Day', 'Steps'], rows: rows(h.steps, (v) => fmt(v)) }}
        >
          <BarChart points={h.steps} format={(v) => `${fmt(v)} steps`} tickFormat={compact} label={`${m.name}'s steps per day`} />
        </ChartCard>
        <ChartCard
          title="Resting heart rate"
          value={m.restingHr ? `${m.restingHr.value} bpm` : lastValue(h.restingHr) ? `${lastValue(h.restingHr)} bpm` : '—'}
          note={m.restingHr?.usual != null ? `usual ${m.restingHr.usual} bpm` : undefined}
          table={{ columns: ['Day', 'bpm'], rows: rows(h.restingHr, (v) => fmt(v)) }}
        >
          <TrendChart
            points={h.restingHr}
            format={(v) => `${fmt(v)} bpm`}
            color="var(--series-2)"
            refLines={m.restingHr?.usual != null ? [{ value: m.restingHr.usual, label: 'usual' }] : []}
            median={false}
            label={`${m.name}'s resting heart rate per day`}
          />
        </ChartCard>
        {h.load && (
          <ChartCard
            title={h.load.kind === 'strain' ? 'Day strain' : 'Active energy'}
            value={h.load.points.length ? (h.load.kind === 'strain' ? fmt(h.load.points.at(-1)!.value, 1) : `${fmt(h.load.points.at(-1)!.value)} kcal`) : '—'}
            note={h.load.kind === 'strain' ? 'WHOOP, 0–21' : 'Apple Watch or iPhone'}
            table={{ columns: ['Day', h.load.kind === 'strain' ? 'Strain' : 'kcal'], rows: rows(h.load.points, (v) => (h.load!.kind === 'strain' ? fmt(v, 1) : fmt(v))) }}
          >
            <BarChart points={h.load.points} format={(v) => (h.load!.kind === 'strain' ? fmt(v, 1) : `${fmt(v)} kcal`)} tickFormat={compact} label={`${m.name}'s training load per day`} />
          </ChartCard>
        )}
      </div>
      <p className="muted small family-foot">
        Dashed lines are {m.isYou ? 'your' : 'their'} usual over these 30 days. {m.isYou ? <a href={href('home')}>Open your full dashboard</a> : 'Only what they share is here.'}
      </p>
    </div>
  );
}

function NotSharing() {
  return (
    <div className="page family">
      <a className="family-back" href={href('family')}>
        <Icon name="chevron-left" size={16} /> Family
      </a>
      <section className="card family-empty">
        <p>This person isn't on the Family board right now.</p>
      </section>
    </div>
  );
}

function sleepNote(m: FamilyMember) {
  const s = m.sleep;
  if (!s) return 'No sleep data for last night';
  // Sleep is dated by the morning you woke: yesterday's means last night's hasn't synced yet.
  const parts = [s.date === m.today ? '' : 'the night before', s.inBed ? 'in bed' : ''];
  if (!s.inBed && s.usual !== null) {
    const diff = Math.round((s.hours - s.usual) * 60);
    parts.push(Math.abs(diff) < 10 ? 'about usual' : `${diff > 0 ? '+' : '−'}${hoursMinutes(Math.abs(diff) / 60)} vs usual`);
  }
  return parts.filter(Boolean).join(' · ') || 'last night';
}

function readinessValue(m: FamilyMember) {
  const r = m.readiness;
  if (!r) return null;
  return r.kind === 'recovery' ? `${r.value}%` : `${r.value} ms`;
}

function readinessNote(m: FamilyMember) {
  const r = m.readiness;
  if (!r) return m.devices.some((d) => d !== 'iphone') ? 'None in the last few days' : m.devices.length ? 'Needs a watch or WHOOP' : '';
  if (r.usual === null) return r.kind === 'hrv' ? (r.metric === 'hrv_sdnn' ? 'SDNN' : 'RMSSD') : 'learning their usual';
  if (r.kind === 'recovery') return `usual ${r.usual}%`;
  const pct = Math.round(((r.value - r.usual) / r.usual) * 100);
  return `${Math.abs(pct) < 3 ? 'about usual' : `${pct > 0 ? '+' : '−'}${Math.abs(pct)}% vs usual`} · ${r.metric === 'hrv_sdnn' ? 'SDNN' : 'RMSSD'}`;
}

function stepsNote(m: FamilyMember) {
  const s = m.steps;
  if (!s) return 'None yet today';
  if (s.source === 'whoop') return 'WHOOP, since waking';
  if (s.asOfHour === null) return 'today';
  return `by ${hourLabel(s.asOfHour + 1)}${s.usualByNow !== null ? ` · usually ~${compact(Math.round(s.usualByNow / 100) * 100)}` : ''}`;
}

function SharingOff({ onOn }: { onOn: () => void }) {
  const [busy, setBusy] = useState(false);
  return (
    <div className="page family">
      <header className="greeting family-greeting">
        <h1>Family</h1>
      </header>
      <section className="card family-empty">
        <p>Family is off: you don't see anyone, and nobody sees you.</p>
        <button
          className="btn btn-primary"
          disabled={busy}
          onClick={async () => {
            setBusy(true);
            try {
              await sendJson('PUT', '/settings', { familySharing: true });
              notifyDataChanged();
              onOn();
            } finally {
              setBusy(false);
            }
          }}
        >
          Turn on sharing
        </button>
      </section>
    </div>
  );
}

/** "yesterday", a weekday within the week ("Tue"), else a date ("Oct 12"). */
function since(date: string, today: string) {
  const d = daysBetween(date, today);
  return d <= 0 ? 'today' : d === 1 ? 'yesterday' : d < 7 ? fmtDate(date, { weekday: 'short' }) : fmtDate(date);
}

const initial = (name: string) => (name || '·').slice(0, 1).toUpperCase();
const DEVICE: Record<FamilyMember['devices'][number], string> = { whoop: 'WHOOP', watch: 'Apple Watch', iphone: 'iPhone' };
const PHASE: Record<FamilyCyclePhase, string> = { period: 'Period', follicular: 'Follicular phase', luteal: 'Luteal phase' };
const REASON: Record<FamilyReason, string> = {
  recovery: 'Recovery lower than usual',
  hrv: 'HRV lower than usual',
  resting_hr: 'Resting heart rate above usual',
  sleep: 'Short night',
};

/** Settings: Share with family. Mutual, so the text says both halves. */
export function FamilySettings({ status, refresh }: { status: Status; refresh: () => void }) {
  const on = status.settings.familySharing;
  const { data, reload } = useApi<FamilyBoard>(on ? '/family' : null);
  useFamilyRefresh(reload);
  const [busy, setBusy] = useState(false);
  const others = data?.sharing ? data.members.filter((m) => !m.isYou).map((m) => m.name) : [];
  return (
    <section className="card settings">
      <div>
        <h2>Family</h2>
        <p className="muted small">Your Family board tile: last night's sleep, recovery or HRV, today's steps, resting heart rate and training load, the last 30 days of each, and how they compare with your own usual.</p>
      </div>
      <div className="settings-row cycle-switch-row">
        <div>
          <span>Share with family</span>
          <p className="muted small">
            Members who share see your daily tile. Turn it off and you see no one, and no one sees you.
            {on && others.length > 0 && ` Sharing with: ${others.join(', ')}.`}
          </p>
        </div>
        <button
          className={`switch ${on ? 'is-on' : ''}`}
          role="switch"
          aria-checked={on}
          aria-label="Share with family"
          disabled={busy}
          onClick={async () => {
            setBusy(true);
            try {
              await sendJson('PUT', '/settings', { familySharing: !on });
              refresh();
              notifyDataChanged();
            } finally {
              setBusy(false);
            }
          }}
        >
          <span />
        </button>
      </div>
    </section>
  );
}
