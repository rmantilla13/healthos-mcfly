// The Body overview's latest-workout card: that session's figures, the sport's recent sessions, and a few general
// recovery suggestions. Every figure is the workout's own, as Apple Health or WHOOP recorded it; pace and speed are
// its duration divided by its distance. There's no route or heart-rate trace, so instead of drawing one the card
// shows the same sport's last few sessions side by side. The suggestions come from plain rules (shared/workouts.ts),
// are labelled as general, and their ticks stay in this browser.
import { useId, useState } from 'react';
import type { Status, Summary, Units, Workout } from '../../../shared/types.ts';
import {
  type SportKind,
  type WorkoutLike,
  TICKS_KEY,
  barMetric,
  distanceIn,
  formatPace,
  latestWorkout,
  num,
  paceOf,
  readTicks,
  recentSessions,
  recoverySuggestions,
  sportKind,
  suggestionsApply,
  tickKey,
  wallClock,
  writeTicks,
} from '../../../shared/workouts.ts';
import { barPath, useWidth } from '../../charts/core.tsx';
import { duration, fmt, fmtDate, relativeDay, useApi, useUnits } from '../../lib.ts';
import { CardHead } from '../../pages/Home.tsx';
import { Icon, type IconName } from '../Icon.tsx';

/** How far back to look for the latest workout and its sport's earlier sessions. */
const DAYS = 90;
const ACTIVITY = '#/body?tab=activity';
const SOURCE: Record<string, string> = { apple: 'Apple Health', whoop: 'WHOOP', 'apple+whoop': 'Apple Health and WHOOP' };
const KIND_ICON: Record<SportKind, IconName> = { run: 'steps', walk: 'steps', cycle: 'activity', swim: 'activity', strength: 'body', mind: 'spark', other: 'activity' };

export function WorkoutCard({ s, date }: { s: Summary; date: string | null }) {
  const units = useUnits();
  const { data: list, error } = useApi<Workout[]>(`/workouts?days=${DAYS}${date ? `&date=${date}` : ''}`);
  // Already loaded by the dashboard: whose ticks these are.
  const { data: status } = useApi<Status>('/status');
  const w = list ? latestWorkout(list, Date.now()) : null;

  return (
    <article className="card metric workout-card">
      <CardHead title="Latest workout" to={ACTIVITY} />
      {!list ? (
        <p className="metric-empty">{error ? `Couldn't load your workouts: ${error.message}` : 'Loading…'}</p>
      ) : !w ? (
        <p className="metric-empty">
          No workouts in the {DAYS} days up to {s.date === s.today ? 'today' : fmtDate(s.date, { month: 'short', day: 'numeric', year: 'numeric' })}. Workouts come from Apple Health and WHOOP.
        </p>
      ) : (
        <Latest w={w} list={list} s={s} units={units} userId={status?.user.id ?? null} />
      )}
    </article>
  );
}

function Latest({ w, list, s, units, userId }: { w: Workout; list: Workout[]; s: Summary; units: Units; userId: string | null }) {
  const kind = sportKind(w.sport);
  const minutes = num(w.duration_min);
  const metres = num(w.distance_m);
  const dist = metres !== null ? distanceIn(metres, units, kind) : null;
  const pace = paceOf(w, units);
  const avg = num(w.avg_hr);
  const max = num(w.max_hr);
  const kcal = num(w.energy_kcal);
  const strain = num(w.strain);
  const effort = num(w.effort);
  const sessions = recentSessions(list, w, 6);
  // Suggestions are for a session that ended in the last 18 hours (SUGGESTION_HOURS), by the real clock: for an
  // older one (a past day's, or the latest of a quiet week) they'd be beside the point. Ticks are kept per workout,
  // so the same ones show on today's page and the day before's, and across midnight.
  const recent = suggestionsApply(w, Date.now());
  const ticks = userId ? tickKey(userId, w.id, w.date) : null;

  const stats: { label: string; value: string; title?: string }[] = [];
  if (dist && minutes !== null) stats.push({ label: 'Duration', value: duration(minutes) });
  if (pace)
    stats.push({
      label: pace.kind === 'speed' ? 'Avg speed' : 'Avg pace',
      value: formatPace(pace, fmt),
      title: pace.kind === 'speed' ? 'Distance divided by duration' : 'Duration divided by distance',
    });
  if (avg !== null) stats.push({ label: 'Avg heart rate', value: `${fmt(avg)} bpm` });
  if (max !== null) stats.push({ label: 'Max heart rate', value: `${fmt(max)} bpm` });
  if (kcal !== null) stats.push({ label: 'Energy', value: `${fmt(kcal)} kcal` });
  if (strain !== null) stats.push({ label: 'Strain', value: `${fmt(strain, 1)} of 21`, title: "WHOOP's strain, on its 0 to 21 scale" });
  if (effort !== null) stats.push({ label: 'Effort', value: `${fmt(effort)} of 10`, title: "Apple Health's effort score: your own rating, or Apple Watch's estimate" });

  return (
    <>
      <div className="workout-sport">
        <span className="insight-icon tone-neutral">
          <Icon name={KIND_ICON[kind]} size={16} />
        </span>
        <span>
          <b>{w.sport}</b>
          <small>
            {relativeDay(w.date, s.today)} · {wallClock(w.start)}
          </small>
        </span>
      </div>
      {dist ? (
        <div className="metric-value">
          {fmt(dist.value, dist.digits)}
          <small>{dist.unit}</small>
        </div>
      ) : minutes !== null ? (
        <div className="metric-value">
          {duration(minutes)}
          <small>duration</small>
        </div>
      ) : null}
      {stats.length > 0 && (
        <dl className="workout-stats">
          {stats.map((x) => (
            <div key={x.label} title={x.title}>
              <dt>{x.label}</dt>
              <dd>{x.value}</dd>
            </div>
          ))}
        </dl>
      )}
      {sessions.length > 1 ? (
        <SessionBars sessions={sessions} latest={w} units={units} kind={kind} />
      ) : (
        <p className="card-note">No other {w.sport.toLowerCase()} sessions in the last {DAYS} days to compare with.</p>
      )}
      {recent && ticks && <Suggestions key={ticks} w={w} storageKey={ticks} />}
      <div className="metric-foot">
        <span>From {SOURCE[w.source] ?? 'demo data'}</span>
      </div>
    </>
  );
}

// ---------- the sport's recent sessions ----------

/** One bar per session, oldest to newest (this one in the accent colour), each with its value above and date below. */
function SessionBars({ sessions, latest, units, kind }: { sessions: WorkoutLike[]; latest: WorkoutLike; units: Units; kind: SportKind }) {
  const [ref, width] = useWidth<HTMLDivElement>();
  const metric = barMetric(sessions, latest);
  const unit = metric === 'distance' ? distanceIn(1000, units, kind).unit : 'min';
  const valueOf = (w: WorkoutLike) => {
    if (metric === 'duration') return num(w.duration_min);
    const m = num(w.distance_m);
    return m === null ? null : distanceIn(m, units, kind).value;
  };
  const text = (v: number | null) => (v === null ? '—' : metric === 'duration' ? fmt(v) : fmt(v, v >= 100 ? 0 : 1));
  const values = sessions.map(valueOf);
  const top = Math.max(1, ...values.map((v) => v ?? 0));
  const height = 92;
  const plot = height - 34; // room for the value above and the date below
  const slot = width / sessions.length;
  const bw = Math.max(6, Math.min(22, slot - 10));
  const sport = latest.sport.toLowerCase();
  const caption = `${metric === 'distance' ? `Distance (${unit})` : 'Duration (min)'}, last ${sessions.length} ${sport} sessions`;

  return (
    <figure className="workout-bars">
      <figcaption>{caption}</figcaption>
      <div className="mini" ref={ref} style={{ height }} aria-hidden="true">
        {width > 0 && (
          <svg width={width} height={height}>
            {sessions.map((w, i) => {
              const v = values[i];
              const h = v ? Math.max(2, (v / top) * (plot - 4)) : 0;
              const x = i * slot + (slot - bw) / 2;
              const y = 14 + plot - h;
              return (
                <g key={w.id}>
                  {h > 0 && <path d={barPath(x, y, bw, h, 3)} className={w.id === latest.id ? 'bar bar-accent' : 'bar'} />}
                  <text x={x + bw / 2} y={y - 4} textAnchor="middle" className={w.id === latest.id ? 'workout-bar-value is-latest' : 'workout-bar-value'}>
                    {text(v)}
                  </text>
                  <text x={x + bw / 2} y={height - 4} textAnchor="middle" className="hyp-tick">
                    {fmtDate(w.date)}
                  </text>
                </g>
              );
            })}
          </svg>
        )}
      </div>
      <ol className="sr-only">
        {sessions.map((w, i) => (
          <li key={w.id}>
            {fmtDate(w.date, { weekday: 'short', month: 'short', day: 'numeric' })}: {values[i] === null ? 'not recorded' : `${text(values[i])} ${unit}`}
            {w.id === latest.id ? ' (this workout)' : ''}
          </li>
        ))}
      </ol>
    </figure>
  );
}

// ---------- general suggestions, with ticks kept in this browser ----------

function loadTicks(key: string): string[] {
  try {
    return readTicks(localStorage.getItem(TICKS_KEY), key);
  } catch {
    return [];
  }
}

function saveTicks(key: string, ids: string[]) {
  try {
    localStorage.setItem(TICKS_KEY, writeTicks(localStorage.getItem(TICKS_KEY), key, ids, Date.now()));
  } catch {
    // Storage blocked or full: the ticks still work, for as long as the page is open.
  }
}

function Suggestions({ w, storageKey }: { w: WorkoutLike; storageKey: string }) {
  const id = useId();
  const list = recoverySuggestions(w);
  const [ticked, setTicked] = useState(() => loadTicks(storageKey));
  const toggle = (sid: string, on: boolean) => {
    const next = on ? [...ticked.filter((x) => x !== sid), sid] : ticked.filter((x) => x !== sid);
    setTicked(next);
    saveTicks(storageKey, next);
  };
  return (
    <section className="workout-recovery" aria-labelledby={`${id}-title`}>
      <h3 id={`${id}-title`}>General suggestions</h3>
      <p className="workout-recovery-note" id={`${id}-note`}>
        Common ideas after a session like this, not personal or medical advice.
      </p>
      <ul aria-describedby={`${id}-note`}>
        {list.map((sg) => (
          <li key={sg.id}>
            <label>
              <input type="checkbox" checked={ticked.includes(sg.id)} onChange={(e) => toggle(sg.id, e.target.checked)} />
              <span>
                {sg.text}
                <small>{sg.why}</small>
              </span>
            </label>
          </li>
        ))}
      </ul>
    </section>
  );
}
