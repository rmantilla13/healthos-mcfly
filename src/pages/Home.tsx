import { type KeyboardEvent, type PointerEvent, type ReactNode, useEffect, useRef, useState } from 'react';
import type { DayData, FigureVariant, Insight, NutritionNumbers, Perspective, PhotoMeta, Summary, TimelineEvent, WeekSummary } from '../../shared/types.ts';
import { Gauge, MiniBars } from '../charts/Mini.tsx';
import { clockOf, DAY_MINUTES, eventSpan, type HeartAt, hourClock, type Moment, momentAt, pressMinute, scrubMax, stepMinute, type TotalAt } from '../charts/scrub.ts';
import type { MetricKey, MetricRange } from '../../shared/metrics.ts';
import { AllHiddenNote, CardRow, useAllHidden } from '../components/CardRow.tsx';
import { Figure, type HeartScrub } from '../components/Figure.tsx';
import { JournalPromptCard } from '../components/home/JournalPrompt.tsx';
import { HrvCard, RecoveryCard, RespRateCard, RestingHrCard, SleepCard, Spo2Card, Stale, signed } from '../components/home/Signals.tsx';
import { TodayNutritionCard } from '../components/home/TodayNutrition.tsx';
import { Icon, type IconName } from '../components/Icon.tsx';
import { MetricSheetLink } from '../components/MetricSheet.tsx';
import { NutritionCard } from './Nutrition.tsx';
import { clock, compact, duration, fmt, fmtDate, hoursMinutes, href, relativeDay, useApi } from '../lib.ts';
import '../styles/home.css';

// Body and Sleep build their cards from these too.
export { Stale, signed };

export function Home({
  date,
  onDate: _onDate,
  photo,
  nutrition = null,
  perspective = 'portrait',
  figure = 'man',
}: {
  /** The day shown (null is today); the shell's header picks it (previous and next beside the date). */
  date: string | null;
  onDate: (d: string | null) => void;
  photo: PhotoMeta | null;
  /** What the person chose to see of Nutrition, or null while it's off. */
  nutrition?: NutritionNumbers | null;
  perspective?: Perspective;
  figure?: FigureVariant;
}) {
  const { data, error, loading } = useApi<Summary>(`/summary${date ? `?date=${date}` : ''}`);
  const allHidden = useAllHidden('home');
  // While the timeline is scrubbed, the figure's heart beats at that hour's rate.
  const [heartScrub, setHeartScrub] = useState<HeartScrub | null>(null);
  if (error && !data) return <div className="page-message">Couldn't load your data: {error.message}</div>;
  if (!data) return <div className="page-message">Loading…</div>;
  const s = data;
  const stats = perspective === 'stats';

  // The greeting, the day and the avatar are in the shell's header (ShellHeader, TopBar).
  return (
    <div className={`home ${loading ? 'is-refreshing' : ''}${stats ? ' is-stats' : ''}`}>
      {!stats && (
        <div className="home-left">
          {/* Stays in view while the widgets beside it scroll (the timeline's scrub moves its heart). */}
          <div className="home-figure">
            <Figure
              vitals={s.vitals}
              asOf={s.date}
              photo={photo}
              heartScrub={s.timeline.date === s.date ? heartScrub : null}
              perspective={perspective}
              figure={figure}
              callouts={['spo2', 'breathing', 'heart']}
            />
            {/* A portrait is made from photos in Profile; until then the digital human stands in. */}
            {perspective === 'portrait' && !photo && (
              <p className="home-portrait-note">
                Your portrait appears here once it's made. Add photos in <a href={href('profile')}>Profile → Your portrait photos</a>.
              </p>
            )}
          </div>
          <Tagline />
        </div>
      )}

      <div className="home-right">
        <CardRow
          className="cards home-signals"
          fill={{ wide: 3, mid: 2 }}
          cards={[
            ['home.rhr', <RestingHrCard s={s} />],
            ['home.spo2', <Spo2Card s={s} />],
            ['home.hrv', <HrvCard s={s} />],
            ['home.sleep', <SleepCard s={s} />],
            ['home.readiness', <RecoveryCard s={s} />],
            ['home.resp', <RespRateCard s={s} />],
          ]}
        />
        <CardRow
          className="lower home-lower"
          pair
          cards={[
            ['home.nutrition', <TodayNutritionCard numbers={nutrition} date={s.date} today={s.today} />],
            ['home.journal', <JournalPromptCard />],
          ]}
        />

        {/* The optional widgets (off until turned on in Edit widgets), below the design's own. */}
        <CardRow
          className="cards"
          fill={{ wide: 3, mid: 2 }}
          cards={[
            ['home.load', <LoadCard s={s} />],
            ['home.activity', <ActivityCard s={s} />],
            // Only for people with Nutrition on.
            ...(nutrition ? ([['home.food', <NutritionCard numbers={nutrition} />]] as [string, ReactNode][]) : []),
          ]}
        />
        <CardRow className="lower" pair cards={[['home.timeline', <TimelineCard key={s.timeline.date} timeline={s.timeline} today={s.today} onHeart={setHeartScrub} />]]} />
        <CardRow
          className="lower"
          pair
          cards={[
            ['home.week', <WeekCard week={s.week} stepGoal={s.stepGoal} />],
            ['home.insights', <InsightsCard insights={s.insights} today={s.today} />],
          ]}
        />
        {allHidden && <AllHiddenNote />}
        {stats && <Tagline compact />}
      </div>
    </div>
  );
}

/** The line at the bottom of the figure's column, and the way on to every measurement (Vitals). */
function Tagline({ compact = false }: { compact?: boolean }) {
  return (
    <div className={`home-tagline${compact ? ' is-compact' : ''}`}>
      <p>
        A clearer picture.
        {compact ? ' ' : <br />}A healthier you.
      </p>
      <a className="home-measurements" href={href('vitals')}>
        Your measurements
        <Icon name="arrow-up-right" size={14} />
      </a>
    </div>
  );
}

/** The week so far, as a widget: the sentences that used to sit under the figure. */
function WeekCard({ week, stepGoal }: { week: Summary['week']; stepGoal: number }) {
  return (
    <section className="card home-week">
      {week ? <WeekSummaryText week={week} stepGoal={stepGoal} /> : <p className="week-summary">Vitals from your latest night, compared with your own last 30 days.</p>}
    </section>
  );
}

// ---------- week so far ----------

/** Two or three plain sentences about Monday-to-date, each figure against the same days last week. */
function WeekSummaryText({ week, stepGoal }: { week: WeekSummary; stepGoal: number }) {
  const sentences: ReactNode[] = [];
  const pct = (a: number, b: number) => Math.round(((a - b) / b) * 100);

  const { sleep, steps, workouts, hrv, restingHr, recovery } = week;
  if (sleep.avg !== null) {
    const diff = sleep.prev !== null ? Math.round((sleep.avg - sleep.prev) * 60) : null;
    sentences.push(
      <>
        You're sleeping <b>{hoursMinutes(sleep.avg)}</b> a night
        {diff === null ? '' : Math.abs(diff) < 5 ? ', about the same as last week' : (
          <>
            , <b>{Math.abs(diff)} min {diff > 0 ? 'more' : 'less'}</b> than last week
          </>
        )}
        .
      </>,
    );
  }

  const activity: ReactNode[] = [];
  if (steps.avg !== null) {
    const change = steps.prev ? pct(steps.avg, steps.prev) : null;
    activity.push(
      <>
        Steps average <b>{fmt(Math.round(steps.avg / 10) * 10)}</b> a day
        {change !== null && Math.abs(change) >= 5 ? ` (${change > 0 ? 'up' : 'down'} ${Math.abs(change)}%)` : ''}
        {steps.goalDays > 0 ? (
          <>
            , with your goal met on <b>{steps.goalDays} of {steps.daysWithData}</b> days
          </>
        ) : (
          `, under your ${compact(stepGoal)} goal`
        )}
      </>,
    );
  }
  activity.push(
    workouts.count > 0 ? (
      <>
        <b>
          {workouts.count} workout{workouts.count === 1 ? '' : 's'}
        </b>{' '}
        logged ({duration(workouts.minutes)})
      </>
    ) : (
      'no workouts logged yet'
    ),
  );
  sentences.push(
    <>
      {activity.map((a, i) => (
        <span key={i}>
          {i > 0 ? '; ' : ''}
          {a}
        </span>
      ))}
      .
    </>,
  );

  // Heart clauses are a lead-in plus an optional emphasized value, so the first one can be capitalized.
  const heart: { lead: string; value?: string }[] = [];
  if (restingHr.avg !== null && restingHr.prev !== null) {
    const d = restingHr.avg - restingHr.prev;
    heart.push(Math.abs(d) < 1 ? { lead: 'resting heart rate is steady' } : { lead: 'resting heart rate is ', value: `${d < 0 ? 'down' : 'up'} ${fmt(Math.abs(d), 1)} bpm` });
  }
  if (hrv.avg !== null && hrv.prev) {
    const c = pct(hrv.avg, hrv.prev);
    heart.push(Math.abs(c) < 3 ? { lead: 'HRV is holding steady' } : { lead: 'HRV is ', value: `${c > 0 ? 'up' : 'down'} ${Math.abs(c)}%` });
  }
  if (recovery.avg !== null) heart.push({ lead: 'recovery averages ', value: `${fmt(recovery.avg)}%` });
  if (heart.length) {
    sentences.push(
      <>
        {heart.map((h, i) => (
          <span key={i}>
            {i === 0 ? '' : i === heart.length - 1 ? ' and ' : ', '}
            {i === 0 ? h.lead[0].toUpperCase() + h.lead.slice(1) : h.lead}
            {h.value && <b>{h.value}</b>}
          </span>
        ))}
        .
      </>,
    );
  }

  const nothing = sleep.avg === null && steps.avg === null && workouts.count === 0 && !heart.length;
  const range =
    week.days === 1
      ? fmtDate(week.start, { weekday: 'long' })
      : `${fmtDate(week.start, { weekday: 'short' })}–${fmtDate(week.end, { weekday: 'short' })}`;
  return (
    <div className="week-summary">
      <div className="week-summary-title">Week so far · {range}</div>
      {nothing ? (
        <p>Nothing recorded yet this week.</p>
      ) : (
        <p>
          {sentences.map((x, i) => (
            <span key={i}>
              {i > 0 ? ' ' : ''}
              {x}
            </span>
          ))}
        </p>
      )}
    </div>
  );
}

// ---------- metric cards ----------

/**
 * A card's title and its arrow. With `metric`, the arrow is a button that opens the metric's detail sheet (which
 * links on to `to`); without, it's a link to `to`.
 */
export function CardHead({
  title,
  to,
  metric,
  date,
  section = 'Your signals',
  range,
}: {
  title: string;
  to: string;
  metric?: MetricKey;
  /** The day the card shows, which the sheet's window ends on. */
  date?: string;
  /** The sheet's line above the metric's name ("Your signals", "Your body"). */
  section?: string;
  range?: MetricRange;
}) {
  return (
    <div className="metric-head">
      <span>{title}</span>
      {metric ? (
        <MetricSheetLink metric={metric} title={title} date={date} section={section} to={to} range={range} />
      ) : (
        <a href={to} className="metric-link" aria-label={`Open ${title}`}>
          <Icon name="arrow-up-right" size={16} />
        </a>
      )}
    </div>
  );
}

function Empty({ text }: { text: string }) {
  return (
    <div className="metric-empty">
      <span>{text}</span>
      <a href={href('integrations')}>Connect data</a>
    </div>
  );
}

function LoadCard({ s }: { s: Summary }) {
  const l = s.load;
  if (!l)
    return (
      <article className="card metric metric-pink">
        <CardHead title="Strain" to={href('activity')} metric="strain" date={s.date} />
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
      <CardHead title={strain ? 'Strain' : 'Active energy'} to={href('activity')} metric={strain ? 'strain' : 'active_energy'} date={s.date} />
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
      <CardHead title="Activity" to={href('activity')} metric="steps" date={s.date} />
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

/** The Day view's metrics, in Body's order, so both pages share one download for today. */
const DAY_METRICS = 'heart_rate,steps,active_energy';
/** Keyboard steps along the timeline: the arrows move 15 minutes, Page Up and Page Down an hour. */
const STEP = 15;
const BIG_STEP = 60;
/** Dragging lands on 5-minute marks (or inside a short event it's over). */
const SNAP = 5;
/** How far a touch moves sideways before it's a drag rather than a tap or the start of a scroll, in px. */
const SLOP = 6;

/** What the person was doing at the marker: asleep, napping, or the workout or session's own name. */
const doing = (e: TimelineEvent) => (e.kind === 'sleep' ? 'Asleep' : e.kind === 'nap' ? 'Napping' : e.title);
const hourRange = (h: number) => `${hourClock(h)}–${hourClock(h + 1)}`;

/** Focused from the keyboard (where a screen reader would be), not just left focused by a click or a tap. */
function keyboardFocus(el: Element | null) {
  try {
    return !!el?.matches(':focus-visible');
  } catch {
    return false; // A browser without :focus-visible.
  }
}

/**
 * The browser's date and minute of the day, kept current while `on`, except while `hold` says not to (a live
 * slider with keyboard focus: its value moving every minute would be read out every minute).
 */
function useNow(on: boolean, hold: () => boolean) {
  const read = () => {
    const d = new Date();
    return { day: d.toLocaleDateString('en-CA'), minute: d.getHours() * 60 + d.getMinutes() };
  };
  const [now, setNow] = useState(read);
  const holdRef = useRef(hold);
  holdRef.current = hold;
  useEffect(() => {
    if (!on) return;
    setNow(read());
    const t = setInterval(() => {
      if (holdRef.current()) return;
      const n = read();
      setNow((p) => (p.day === n.day && p.minute === n.minute ? p : n));
    }, 30_000);
    return () => clearInterval(t);
  }, [on]);
  return now;
}

/**
 * The day's events on a 24-hour track, with a marker to scrub through it: drag it (or tap, or use the arrow keys)
 * and the card shows what was going on then, with that hour's heart rate and the steps and energy by then from
 * the hourly readings (GET /api/day). A drag springs back to now on release; a tap or the keys hold the moment
 * until "Now". Without hourly readings (WHOOP has none) it shows the events alone.
 */
function TimelineCard({ timeline, today, onHeart }: { timeline: Summary['timeline']; today: string; onHeart: (h: HeartScrub | null) => void }) {
  const isToday = timeline.date === today;
  const handleRef = useRef<HTMLDivElement>(null);
  const liveRef = useRef(true);
  const now = useNow(isToday, () => liveRef.current && keyboardFocus(handleRef.current));
  // Past midnight, until the summary catches up with the new day (within a minute), the shown day is over.
  const dayOver = now.day > today;
  const nowMin = dayOver ? DAY_MINUTES : now.minute;
  const nowIso = dayOver ? `${now.day}T00:00` : `${today}T${clockOf(now.minute)}`;
  const { data } = useApi<DayData>(`/day?metrics=${DAY_METRICS}${isToday ? '' : `&date=${timeline.date}`}`);
  const day = data?.date === timeline.date ? data : undefined;
  // The end of the track, which is also where live sits: now (or the last synced hour, when the browser's clock is
  // behind the person's time zone) on today, 24:00 on a past day.
  const max = scrubMax(isToday, nowMin, day?.asOf ?? null);
  /** The minute the marker was moved to; null is live. */
  const [scrub, setScrub] = useState<number | null>(null);
  const [dragging, setDragging] = useState(false);
  const live = scrub === null;
  liveRef.current = live;
  const minute = live ? max : Math.min(scrub, max);
  const moment = momentAt(day, timeline.events, timeline.date, minute, live);

  const trackRef = useRef<HTMLDivElement>(null);
  const momentRef = useRef<HTMLDivElement>(null);
  /**
   * The press in progress. `grab`: the minute the marker was at when its own pill was grabbed (it then moves by
   * how far the pointer moves); null for a press elsewhere on the track (the marker jumps there). `started`: the
   * marker follows it (a mouse at once; a touch once it moves sideways). `moved`: it's a drag, not a tap.
   */
  const press = useRef<{ id: number; x: number; mouse: boolean; grab: number | null; started: boolean; moved: boolean } | null>(null);

  // The figure's heart follows the marker (that hour's average, or nothing) only while it's moved off live.
  const h = live ? undefined : moment.heart;
  const bpm = h?.kind === 'reading' ? h.avg : null;
  const heartLabel = h ? figureStatus(h) : null;
  useEffect(() => {
    onHeart(heartLabel === null ? null : { bpm, label: heartLabel });
  }, [bpm, heartLabel, onHeart]);
  useEffect(() => () => onHeart(null), [onHeart]);

  const pos = (m: number) => `${(m / DAY_MINUTES) * 100}%`;
  const state = (e: TimelineEvent) => {
    if (!isToday) return 'Completed';
    const local = (iso: string) => iso.slice(0, 16);
    if (local(e.end) <= nowIso) return 'Completed';
    if (local(e.start) <= nowIso) return 'In progress';
    return 'Upcoming';
  };

  /** Moving to the end (now, or the end of the day) is going live. */
  const toScrub = (m: number) => (m >= max ? null : Math.max(0, m));
  const go = (m: number) => setScrub(toScrub(m));
  // From the latest state, so held-down keys that repeat faster than renders still step one at a time.
  const nudge = (step: number, dir: 1 | -1) => setScrub((cur) => toScrub(stepMinute(cur === null ? minute : Math.min(cur, max), step, dir, max)));
  const trackWidth = () => trackRef.current!.getBoundingClientRect().width;
  const minuteAt = (clientX: number) => {
    const r = trackRef.current!.getBoundingClientRect();
    return pressMinute(timeline.events, timeline.date, ((clientX - r.left) / r.width) * DAY_MINUTES, SNAP);
  };
  // A grabbed marker moves by whole 5-minute steps from where it was, so a click that doesn't move leaves it
  // exactly there (live stays live).
  const follow = (clientX: number) => {
    const p = press.current!;
    go(p.grab === null ? minuteAt(clientX) : p.grab + Math.round((((clientX - p.x) / trackWidth()) * DAY_MINUTES) / SNAP) * SNAP);
  };
  /** While the marker follows a press, the readout keeps at least its height, so the track can't shift under it. */
  const holdHeight = (on: boolean) => {
    const el = momentRef.current;
    if (el) el.style.minHeight = on ? `${el.offsetHeight}px` : '';
  };
  const begin = (clientX: number) => {
    press.current!.started = true;
    setDragging(true);
    holdHeight(true);
    follow(clientX);
  };
  const onPointerDown = (e: PointerEvent<HTMLDivElement>) => {
    if ((e.pointerType === 'mouse' && e.button !== 0) || press.current) return;
    const mouse = e.pointerType === 'mouse';
    const onPill = handleRef.current?.contains(e.target as Node) ?? false;
    press.current = { id: e.pointerId, x: e.clientX, mouse, grab: onPill ? minute : null, started: false, moved: false };
    e.currentTarget.setPointerCapture(e.pointerId);
    // A touch waits: it may be a tap, a sideways drag, or the start of a page scroll.
    if (mouse) begin(e.clientX);
  };
  const onPointerMove = (e: PointerEvent<HTMLDivElement>) => {
    const p = press.current;
    if (!p || p.id !== e.pointerId) return;
    const far = Math.abs(e.clientX - p.x) > (p.mouse ? 3 : SLOP);
    if (far) p.moved = true;
    if (p.started) follow(e.clientX);
    else if (far) begin(e.clientX);
  };
  // A drag springs back to live on release, as a stock chart does; a tap keeps the moment it picked. A touch the
  // browser takes over for a scroll (cancelled before it moved sideways) changes nothing.
  const onPointerEnd = (e: PointerEvent<HTMLDivElement>, cancelled: boolean) => {
    const p = press.current;
    if (!p || p.id !== e.pointerId) return;
    press.current = null;
    setDragging(false);
    holdHeight(false);
    // The marker takes focus (for the arrow keys) once the press is over, so the browser counts it as focus from
    // a pointer, with no keyboard focus ring.
    if (!cancelled) handleRef.current?.focus({ preventScroll: true });
    if (p.moved) setScrub(null);
    else if (!cancelled && !p.mouse && p.grab === null) go(minuteAt(p.x));
  };
  const onKeyDown = (e: KeyboardEvent<HTMLDivElement>) => {
    const keys: Record<string, () => void> = {
      ArrowLeft: () => nudge(STEP, -1),
      ArrowDown: () => nudge(STEP, -1),
      ArrowRight: () => nudge(STEP, 1),
      ArrowUp: () => nudge(STEP, 1),
      PageDown: () => nudge(BIG_STEP, -1),
      PageUp: () => nudge(BIG_STEP, 1),
      Home: () => go(0),
      End: () => setScrub(null),
      Escape: () => setScrub(null),
    };
    if (!keys[e.key] || (e.key === 'Escape' && live)) return;
    e.preventDefault();
    keys[e.key]();
  };
  const toLive = () => {
    setScrub(null);
    handleRef.current?.focus({ preventScroll: true });
  };

  const liveName = isToday ? 'Now' : 'End of day';
  // Live, it says "Now" without the clock, so a focused slider isn't re-read every minute.
  const valueText = spoken(moment, live ? liveName : clockOf(minute));

  // The day's step count, as the Activity card shows it, when the hours don't add up to it: a WHOOP count (its API
  // has no hours), or hours not all sent yet. Small rounding differences don't count.
  const st = day?.metrics.steps;
  const hourSteps = st ? st.hours.reduce<number>((a, v) => a + (v ?? 0), 0) : 0;
  const dayCount = st?.total && st.total.value > hourSteps * 1.01 + 1 ? st.total : null;

  return (
    <section className="card timeline">
      <div className="card-title-row">
        <h2>{isToday ? "Today's timeline" : `Timeline · ${fmtDate(timeline.date, { weekday: 'short', month: 'short', day: 'numeric' })}`}</h2>
        <button type="button" className="pill tl-live" onClick={toLive} disabled={live}>
          {liveName}
        </button>
      </div>
      <div className="tl-moment" ref={momentRef}>
        <div className="tl-moment-head">
          <span className="tl-moment-time">{live ? liveName : clockOf(minute)}</span>
          <span className="tl-moment-what">
            {moment.events.length === 0 ? (
              <span className="muted">Nothing logged</span>
            ) : (
              moment.events.map((e) => (
                <span key={e.id}>
                  <i style={{ background: KIND_COLOR[e.kind] }} />
                  {doing(e)}
                  <small>
                    {clock(e.start)}–{clock(e.end)}
                  </small>
                </span>
              ))
            )}
          </span>
        </div>
        {(moment.heart || moment.steps || moment.energy) && (
          <div className="tl-stats">
            {moment.heart && <HeartStat h={moment.heart} isToday={isToday} />}
            {moment.steps && <TotalStat name="Steps" unit="" t={moment.steps} isToday={isToday} />}
            {moment.energy && <TotalStat name="Active energy" unit="kcal" t={moment.energy} isToday={isToday} />}
          </div>
        )}
        {dayCount && moment.steps && (
          <p className="card-note">
            {dayCount.source === 'whoop'
              ? `Steps by the hour are from your iPhone or Apple Watch. WHOOP counted ${fmt(dayCount.value)} for the day.`
              : `The hours here add up to ${fmt(hourSteps)} steps; the day's count is ${fmt(dayCount.value)}.`}
          </p>
        )}
      </div>
      <div
        className={`tl-track-wrap tl-scrub${dragging ? ' is-dragging' : ''}`}
        onPointerDown={onPointerDown}
        onPointerMove={onPointerMove}
        onPointerUp={(e) => onPointerEnd(e, false)}
        onPointerCancel={(e) => onPointerEnd(e, true)}
        onLostPointerCapture={(e) => onPointerEnd(e, false)}
      >
        <div className="tl-track" ref={trackRef}>
          {timeline.events.map((e) => {
            // An event that started the previous evening is drawn from midnight; a short one at least 12 minutes wide.
            const { from, drawnTo } = eventSpan(e, timeline.date);
            return (
              <span
                key={e.id}
                className="tl-seg"
                style={{ left: pos(from), width: `calc(${pos(drawnTo - from)} - 2px)`, background: KIND_COLOR[e.kind] }}
                title={`${e.title} ${clock(e.start)}–${clock(e.end)}`}
              />
            );
          })}
        </div>
        {isToday && !live && <div className="tl-now-ghost" style={{ left: pos(max) }} aria-hidden="true" />}
        <div
          ref={handleRef}
          className={`tl-now${live ? '' : ' is-scrubbed'}`}
          style={{ left: pos(minute) }}
          role="slider"
          tabIndex={0}
          aria-label={isToday ? "Time on today's timeline" : 'Time on the timeline'}
          aria-valuemin={0}
          aria-valuemax={max}
          aria-valuenow={minute}
          aria-valuetext={valueText}
          onKeyDown={onKeyDown}
        >
          {/* The pill slides from left-aligned at 00:00 to right-aligned at 24:00, so it never leaves the card. */}
          <span style={{ transform: `translateX(-${(minute / DAY_MINUTES) * 100}%)` }}>{clockOf(minute)}</span>
        </div>
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
            <li key={e.id} className={moment.events.includes(e) ? 'is-current' : undefined}>
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

/**
 * Which hour a heart figure is the average of, or why there's none. Today's last synced hour may still be
 * filling up, so it's the average since the hour began.
 */
function heartStatus(h: HeartAt, isToday: boolean): ReactNode {
  // The hour stays on one line: a narrow tile breaks before it, not after its dash.
  const hour = <span className="tl-nowrap">{h.kind === 'reading' && h.partial ? hourClock(h.hour) : h.kind !== 'empty' ? hourRange(h.hour) : ''}</span>;
  if (h.kind === 'reading') return h.partial ? <>avg since {hour}</> : <>avg {hour}</>;
  if (h.kind === 'pending') return 'not synced yet';
  if (h.kind === 'none') return <>none {hour}</>;
  return isToday ? 'none yet today' : 'none that day';
}

/** The same for the figure's heart callout, short enough for its one status line. */
function figureStatus(h: HeartAt) {
  if (h.kind === 'reading') return h.partial ? `Avg since ${hourClock(h.hour)}` : `Avg ${hourRange(h.hour)}`;
  return h.kind === 'pending' ? 'Not synced yet' : h.kind === 'none' ? 'No reading then' : 'No readings';
}

/** The slider's spoken value: the moment, what was going on, and every figure the readout shows, as it labels them. */
function spoken(m: Moment, time: string) {
  const parts = [time, m.events.length ? m.events.map(doing).join(' and ') : 'nothing logged'];
  const h = m.heart;
  if (h?.kind === 'reading')
    parts.push(`heart ${fmt(h.avg)} bpm, average ${h.partial ? `since ${hourClock(h.hour)}` : `from ${hourClock(h.hour)} to ${hourClock(h.hour + 1)}`}`);
  else if (h?.kind === 'none') parts.push(`no heart reading from ${hourClock(h.hour)} to ${hourClock(h.hour + 1)}`);
  else if (h?.kind === 'pending') parts.push('heart rate not synced yet');
  const total = (t: TotalAt | undefined, what: string, unit: string) => {
    if (!t || t.kind === 'empty') return;
    if (t.kind === 'so-far') return parts.push(`${what} ${fmt(t.value)}${unit} so far today`);
    const when = t.at === 24 ? 'for the whole day' : `by ${hourClock(t.at)}`;
    parts.push(`${what} ${fmt(t.value)}${unit} ${when}${t.typical !== null ? `, typical ${fmt(t.typical)}` : ''}`);
  };
  total(m.steps, 'steps', '');
  total(m.energy, 'active energy', ' kcal');
  return parts.join('; ');
}

function HeartStat({ h, isToday }: { h: HeartAt; isToday: boolean }) {
  return (
    <div className="tl-stat">
      <span className="tl-stat-name">Heart rate</span>
      {h.kind === 'reading' ? (
        <>
          <span className="tl-stat-value">
            {fmt(h.avg)}
            <small> bpm</small>
          </span>
          <span className="tl-stat-sub">{heartStatus(h, isToday)}</span>
          {h.min !== null && h.max !== null && (
            <span className="tl-stat-sub">
              range{' '}
              <span className="tl-nowrap">
                {fmt(h.min)}–{fmt(h.max)}
              </span>
            </span>
          )}
        </>
      ) : (
        <>
          <span className="tl-stat-value is-empty">—</span>
          <span className="tl-stat-sub">{heartStatus(h, isToday)}</span>
        </>
      )}
    </div>
  );
}

function TotalStat({ name, unit, t, isToday }: { name: string; unit: string; t: TotalAt; isToday: boolean }) {
  if (t.kind === 'empty')
    return (
      <div className="tl-stat">
        <span className="tl-stat-name">{name}</span>
        <span className="tl-stat-value is-empty">—</span>
        <span className="tl-stat-sub">{isToday ? 'none yet today' : 'none that day'}</span>
      </div>
    );
  return (
    <div className="tl-stat">
      <span className="tl-stat-name">{name}</span>
      <span className="tl-stat-value">
        {fmt(t.value)}
        {unit && <small> {unit}</small>}
      </span>
      {t.kind === 'so-far' ? (
        <span className="tl-stat-sub">so far today</span>
      ) : (
        <>
          <span className="tl-stat-sub">{t.at === 24 ? 'whole day' : `by ${hourClock(t.at)}`}</span>
          {t.typical !== null && <span className="tl-stat-sub">typical {fmt(t.typical)}</span>}
        </>
      )}
    </div>
  );
}

// ---------- insights ----------

export const INSIGHT_TONE: Record<Insight['icon'], string> = {
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
