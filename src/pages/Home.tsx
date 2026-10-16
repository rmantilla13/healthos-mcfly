import { lazy, Suspense, useState } from 'react';
import type { Insight, PhotoMeta, Summary, TimelineEvent } from '../../shared/types.ts';
import { Gauge, MiniBars, MiniDots, MiniLine, RangeScale } from '../charts/Mini.tsx';
import { Figure } from '../components/Figure.tsx';
import { Icon, type IconName } from '../components/Icon.tsx';
import { clock, compact, fmt, fmtDate, hoursMinutes, href, minutesOfDay, relativeDay, shiftDate, useApi } from '../lib.ts';

// three.js is only fetched when the 3D view is opened.
const Body3D = lazy(() => import('../components/Body3D.tsx'));

export function Home({ date, onDate, photo }: { date: string | null; onDate: (d: string | null) => void; photo: PhotoMeta | null }) {
  const { data, error, loading } = useApi<Summary>(`/summary${date ? `?date=${date}` : ''}`);
  const [show3d, setShow3d] = useState(false);
  if (error && !data) return <div className="page-message">Couldn't load your data: {error.message}</div>;
  if (!data) return <div className="page-message">Loading…</div>;
  const s = data;
  const isToday = s.date === s.today;

  return (
    <div className={`home ${loading ? 'is-refreshing' : ''}`}>
      <div className="home-left">
        <header className="greeting">
          <p className="greeting-hello">Hello,</p>
          <h1>{s.name}.</h1>
          <p className="greeting-sub">{isToday ? "Here's your health today." : `Here's your health on ${fmtDate(s.date, { weekday: 'long', month: 'long', day: 'numeric' })}.`}</p>
        </header>
        <Figure vitals={s.vitals} asOf={s.date} photo={photo} />
        <div className="figure-caption">
          <p>Vitals from your latest night, compared with your own last 30 days.</p>
          {photo ? (
            <button className="pill pill-3d" onClick={() => setShow3d(true)}>
              View in 3D
            </button>
          ) : (
            <a className="pill pill-3d" href={href('settings')}>
              Add your photo
            </a>
          )}
        </div>
        {show3d && photo && (
          <Suspense fallback={<div className="viewer"><div className="viewer-note">Loading 3D…</div></div>}>
            <Body3D photo={photo} onClose={() => setShow3d(false)} />
          </Suspense>
        )}
      </div>

      <div className="home-right">
        <div className="topbar">
          {s.demo && (
            <a className="pill pill-demo" href={href('integrations')}>
              Demo data · Connect yours
            </a>
          )}
          <div className="date-nav">
            <span>{fmtDate(s.date, { weekday: 'short', month: 'short', day: 'numeric', year: 'numeric' })}</span>
            <button className="icon-btn" onClick={() => onDate(shiftDate(s.date, -1))} aria-label="Previous day">
              <Icon name="chevron-left" size={16} />
            </button>
            <button className="icon-btn" onClick={() => onDate(shiftDate(s.date, 1) >= s.today ? null : shiftDate(s.date, 1))} disabled={isToday} aria-label="Next day">
              <Icon name="chevron-right" size={16} />
            </button>
          </div>
          <a className="avatar" href={href('settings')} aria-label="Settings">
            {photo ? <img src={`/api/profile/avatar.png?v=${photo.version}`} alt="" /> : s.name.slice(0, 1).toUpperCase()}
          </a>
        </div>

        <div className="cards">
          <ReadinessCard s={s} />
          <Spo2Card s={s} />
          <HrvCard s={s} />
          <SleepCard s={s} />
          <LoadCard s={s} />
          <ActivityCard s={s} />
        </div>

        <div className="lower">
          <TimelineCard timeline={s.timeline} today={s.today} />
          <InsightsCard insights={s.insights} today={s.today} />
        </div>
      </div>
    </div>
  );
}

// ---------- metric cards ----------

function CardHead({ title, to }: { title: string; to: string }) {
  return (
    <div className="metric-head">
      <span>{title}</span>
      <a href={to} className="metric-link" aria-label={`Open ${title}`}>
        <Icon name="arrow-up-right" size={16} />
      </a>
    </div>
  );
}

function Stale({ date, asOf }: { date: string; asOf: string }) {
  return date === asOf ? null : <span className="stale">{fmtDate(date)}</span>;
}

function Empty({ text }: { text: string }) {
  return (
    <div className="metric-empty">
      <span>{text}</span>
      <a href={href('integrations')}>Connect data</a>
    </div>
  );
}

function signed(n: number, digits = 0) {
  const v = fmt(Math.abs(n), digits);
  return n > 0 ? `+${v}` : n < 0 ? `−${v}` : v;
}

function ReadinessCard({ s }: { s: Summary }) {
  const r = s.readiness;
  if (!r)
    return (
      <article className="card metric metric-green">
        <CardHead title="Recovery" to={href('vitals')} />
        <Empty text="Recovery comes from WHOOP; cardio fitness from Apple Watch." />
      </article>
    );

  if (r.kind === 'vo2max') {
    const delta = r.previous !== null ? r.latest.value - r.previous : null;
    return (
      <article className="card metric metric-green">
        <CardHead title="Cardio fitness" to={href('body')} />
        <div className="metric-value">
          {fmt(r.latest.value, 1)}
          <small>VO₂ max</small>
        </div>
        {delta !== null && <span className="chip">{signed(delta, 1)} vs last month</span>}
        <Rings value={Math.min(1, (r.latest.value - 25) / 35)} />
        <div className="metric-foot">
          <span>mL/kg·min</span>
          <Stale date={r.latest.date} asOf={s.date} />
        </div>
      </article>
    );
  }

  const zoneText = { red: 'Low', yellow: 'Moderate', green: 'High' }[r.zone];
  const delta = r.average !== null ? r.latest.value - r.average : null;
  return (
    <article className="card metric metric-green">
      <CardHead title="Recovery" to={href('vitals')} />
      <div className="metric-value">
        {fmt(r.latest.value)}
        <small>%</small>
      </div>
      {delta !== null && <span className="chip">{signed(delta)} vs 30-day avg</span>}
      <Rings value={r.latest.value / 100} />
      <RangeScale
        value={r.latest.value}
        min={0}
        max={100}
        label={`Recovery ${Math.round(r.latest.value)}%, ${zoneText.toLowerCase()} zone`}
        zones={[
          { to: 33, className: 'zone-critical' },
          { to: 66, className: 'zone-warning' },
          { to: 100, className: 'zone-good' },
        ]}
      />
      <div className="metric-foot">
        <span className={`zone-label zone-label-${r.zone}`}>
          <i />
          {zoneText}
        </span>
        <Stale date={r.latest.date} asOf={s.date} />
      </div>
    </article>
  );
}

/** Decorative concentric rings; the dot sits at the score's position on the outer ring. */
function Rings({ value }: { value: number }) {
  const a = Math.PI * (0.75 - 1.5 * Math.min(1, Math.max(0, value)));
  return (
    <svg className="rings" viewBox="0 0 120 120" aria-hidden="true">
      {[56, 44, 32, 20].map((r) => (
        <circle key={r} cx="60" cy="60" r={r} />
      ))}
      <circle cx={60 + 56 * Math.cos(a)} cy={60 - 56 * Math.sin(a)} r="3.5" className="rings-dot" />
    </svg>
  );
}

function Spo2Card({ s }: { s: Summary }) {
  const l = s.spo2.latest;
  return (
    <article className="card metric metric-peach">
      <CardHead title="Blood oxygen" to={href('vitals')} />
      {l ? (
        <>
          <div className="metric-value-row">
            <div className="metric-value">
              {fmt(l.value, l.value % 1 ? 1 : 0)}
              <small>%</small>
            </div>
            <span className="metric-status">{s.spo2.status === 'low' ? 'Below your range' : 'Normal'}</span>
          </div>
          <MiniLine points={s.spo2.series} format={(v) => `${fmt(v, 1)}%`} domain={[90, 100]} color="var(--series-2)" height={58} label="Blood oxygen, last 30 days" />
          <RangeScale value={l.value} min={90} max={100} label={`Blood oxygen ${fmt(l.value, 1)}% on a 90 to 100 scale`} />
          <div className="metric-foot">
            <span>90</span>
            <Stale date={l.date} asOf={s.date} />
            <span>100</span>
          </div>
        </>
      ) : (
        <Empty text="No blood oxygen readings yet." />
      )}
    </article>
  );
}

function HrvCard({ s }: { s: Summary }) {
  const l = s.hrv.latest;
  const statusText = { optimal: 'Optimal', normal: 'Normal', low: 'Below baseline' };
  return (
    <article className="card metric">
      <CardHead title="HRV" to={href('vitals')} />
      {l ? (
        <>
          <div className="metric-value">
            {fmt(l.value)}
            <small>ms</small>
          </div>
          <MiniDots points={s.hrv.series} baseline={s.hrv.baseline} format={(v) => `${fmt(v)} ms`} label="Heart rate variability, last 21 nights, with your usual range" height={70} />
          <div className="metric-foot">
            <span className="metric-strong">{s.hrv.status ? statusText[s.hrv.status] : 'Building baseline'}</span>
            <span className="band-key" title={s.hrv.metric === 'hrv_rmssd' ? 'WHOOP measures RMSSD during sleep' : 'Apple Watch measures SDNN'}>
              <i /> usual · {s.hrv.metric === 'hrv_rmssd' ? 'RMSSD' : 'SDNN'}
            </span>
          </div>
        </>
      ) : (
        <Empty text="No HRV readings yet." />
      )}
    </article>
  );
}

function SleepCard({ s }: { s: Summary }) {
  const l = s.sleep.latest;
  const quality = !l ? '' : l.value >= 7 ? 'Good' : l.value >= 6 ? 'Fair' : 'Short';
  return (
    <article className="card metric">
      <CardHead title="Sleep" to={href('sleep')} />
      {l ? (
        <>
          <div className="metric-value">
            {fmt(l.value, 1)}
            <small>hours</small>
          </div>
          <MiniLine points={s.sleep.series} format={hoursMinutes} color="var(--series-1)" height={58} label="Sleep duration, last 14 nights" />
          <div className="metric-foot">
            <span className="metric-strong">
              {quality}
              <Stale date={l.date} asOf={s.date} />
            </span>
            {s.sleep.change !== null && <span title="This week's average vs last week's">{signed(s.sleep.change * 100)}% wk</span>}
          </div>
        </>
      ) : (
        <Empty text="No sleep recorded yet." />
      )}
    </article>
  );
}

function LoadCard({ s }: { s: Summary }) {
  const l = s.load;
  if (!l)
    return (
      <article className="card metric metric-pink">
        <CardHead title="Strain" to={href('activity')} />
        <Empty text="Strain comes from WHOOP; active energy from Apple Health." />
      </article>
    );
  const strain = l.kind === 'strain';
  const v = l.latest.value;
  const max = strain ? 21 : Math.max(800, (l.average ?? 0) * 1.6);
  const band = strain ? (v < 10 ? 'Light' : v < 14 ? 'Moderate' : v < 18 ? 'High' : 'All out') : v >= (l.average ?? 0) ? 'Above usual' : 'Below usual';
  const change = l.average ? (v - l.average) / l.average : null;
  return (
    <article className="card metric metric-pink">
      <CardHead title={strain ? 'Strain' : 'Active energy'} to={href('activity')} />
      <div className="metric-value">
        {strain ? fmt(v, 1) : fmt(v)}
        <small>{strain ? 'of 21' : 'kcal'}</small>
      </div>
      <div className="gauge-wrap">
        <Gauge value={v} max={max} label={strain ? `Strain ${fmt(v, 1)} of 21` : `${fmt(v)} kcal`} />
      </div>
      <div className="metric-foot">
        <span className="metric-strong">
          {band}
          <Stale date={l.latest.date} asOf={s.date} />
        </span>
        {change !== null && <span title="Compared with your 7-day average">{signed(change * 100)}% vs avg</span>}
      </div>
    </article>
  );
}

function ActivityCard({ s }: { s: Summary }) {
  const l = s.activity.latest;
  const pct = l ? Math.min(1, l.value / s.stepGoal) : 0;
  return (
    <article className="card metric">
      <CardHead title="Activity" to={href('activity')} />
      {l ? (
        <>
          <div className="metric-value">
            {fmt(l.value)}
            <small>steps</small>
          </div>
          <MiniBars points={s.activity.series} format={(v) => `${fmt(v)} steps`} tone="neutral" label="Steps, last 7 days" height={52} />
          <div className="goal">
            <div className="goal-text">
              <span>{Math.round((l.value / s.stepGoal) * 100)}% of goal</span>
              <span>{compact(s.stepGoal)}</span>
            </div>
            <div className="goal-track" role="progressbar" aria-valuenow={Math.round(pct * 100)} aria-valuemin={0} aria-valuemax={100} aria-label="Step goal">
              <div className="goal-fill" style={{ width: `${pct * 100}%` }} />
            </div>
          </div>
        </>
      ) : (
        <Empty text="No steps recorded yet." />
      )}
    </article>
  );
}

// ---------- timeline ----------

const KIND_COLOR: Record<TimelineEvent['kind'], string> = {
  sleep: 'var(--series-1)',
  nap: 'var(--series-1)',
  workout: 'var(--series-2)',
  mindful: 'var(--series-3)',
};

function TimelineCard({ timeline, today }: { timeline: Summary['timeline']; today: string }) {
  const isToday = timeline.date === today;
  const now = new Date();
  const nowMin = now.getHours() * 60 + now.getMinutes();
  const nowIso = `${today}T${String(now.getHours()).padStart(2, '0')}:${String(now.getMinutes()).padStart(2, '0')}`;
  const pos = (m: number) => `${(m / 1440) * 100}%`;
  // An event that started the previous evening is drawn from midnight.
  const span = (e: TimelineEvent) => {
    const s = e.start.slice(0, 10) < timeline.date ? 0 : minutesOfDay(e.start);
    const end = e.end.slice(0, 10) > timeline.date ? 1440 : minutesOfDay(e.end);
    return [s, Math.max(end, s + 12)] as const;
  };
  const state = (e: TimelineEvent) => {
    if (!isToday) return 'Completed';
    const local = (iso: string) => iso.slice(0, 16);
    if (local(e.end) <= nowIso) return 'Completed';
    if (local(e.start) <= nowIso) return 'In progress';
    return 'Upcoming';
  };

  return (
    <section className="card timeline">
      <div className="card-title-row">
        <h2>{isToday ? "Today's timeline" : `Timeline · ${fmtDate(timeline.date, { weekday: 'short', month: 'short', day: 'numeric' })}`}</h2>
      </div>
      <div className="tl-track-wrap">
        <div className="tl-track">
          {timeline.events.map((e) => {
            const [a, b] = span(e);
            return (
              <span
                key={e.id}
                className="tl-seg"
                style={{ left: pos(a), width: `calc(${pos(b - a)} - 2px)`, background: KIND_COLOR[e.kind] }}
                title={`${e.title} ${clock(e.start)}–${clock(e.end)}`}
              />
            );
          })}
        </div>
        {isToday && (
          <div className="tl-now" style={{ left: pos(nowMin) }}>
            <span>{clock(nowIso + ':00')}</span>
          </div>
        )}
        <div className="tl-ticks">
          {[0, 6, 12, 18, 24].map((h) => (
            <span key={h} style={{ left: pos(h * 60) }}>
              {String(h).padStart(2, '0')}:00
            </span>
          ))}
        </div>
      </div>
      <ul className="tl-list">
        {timeline.events.length === 0 && <li className="tl-empty">Nothing recorded for this day.</li>}
        {timeline.events.slice(-4).map((e) => {
          const st = state(e);
          return (
            <li key={e.id}>
              <span className="tl-dot" style={{ background: KIND_COLOR[e.kind] }} />
              <div>
                <div className="tl-title">{e.title}</div>
                <div className="tl-time">
                  {clock(e.start)} – {clock(e.end)}
                  {e.detail ? ` · ${e.detail}` : ''}
                </div>
              </div>
              <span className={`tl-state tl-state-${st.replace(' ', '-').toLowerCase()}`}>{st}</span>
            </li>
          );
        })}
      </ul>
    </section>
  );
}

// ---------- insights ----------

const INSIGHT_TONE: Record<Insight['icon'], string> = {
  'trend-up': 'tone-green',
  'trend-down': 'tone-peach',
  moon: 'tone-blue',
  shield: 'tone-green',
  sun: 'tone-yellow',
  steps: 'tone-neutral',
  heart: 'tone-pink',
};

function InsightsCard({ insights, today }: { insights: Insight[]; today: string }) {
  return (
    <section className="card insights">
      <div className="card-title-row">
        <h2>Recent insights</h2>
      </div>
      {insights.length === 0 && <p className="tl-empty">Insights appear after a week or two of data.</p>}
      <ul>
        {insights.map((i) => (
          <li key={i.id}>
            <a href={href(i.page)}>
              <span className={`insight-icon ${INSIGHT_TONE[i.icon]}`}>
                <Icon name={i.icon as IconName} size={17} />
              </span>
              <span className="insight-text">
                <span>{i.text}</span>
                <small>{relativeDay(i.date, today)}</small>
              </span>
              <Icon name="chevron-right" size={16} />
            </a>
          </li>
        ))}
      </ul>
    </section>
  );
}
