// The Sleep page: one night (Overview), the stages over a range, trends, and coaching from the person's own
// nights. Every figure is from one device for that night; nothing here is a score we made up.
import '../styles/sleep.css';
import type { ReactNode } from 'react';
import { type MetricKey, isMetricKey } from '../../shared/metrics.ts';
import type { Insight, Pattern, Patterns, PhotoMeta, SleepNightDetail, SleepSegment, SleepTiming, Status, Summary, Trends } from '../../shared/types.ts';
import { ChartCard, Legend, StackedBars } from '../charts/Charts.tsx';
import { MiniBars, MiniLine } from '../charts/Mini.tsx';
import { Change, Hypnogram, NightBars, STAGE_COLOR, ScoreBar, StageBar, StageTimeline } from '../charts/Neka.tsx';
import { AllHiddenNote, CardRow, useAllHidden } from '../components/CardRow.tsx';
import { Icon, type IconName } from '../components/Icon.tsx';
import { VitalCard, type VitalTone } from '../components/VitalCard.tsx';
import { clock, daysBetween, fmt, fmtDate, hoursMinutes, href, useApi } from '../lib.ts';
import { DAY, DayNav, IntroTools, STAGES, Tabs, Trend, avg, useRange, weekLabel, weekly } from './Detail.tsx';
import { ManageSources, PageIntro } from '../components/PageIntro.tsx';
import { CardHead, INSIGHT_TONE } from './Home.tsx';

const TABS = [
  { id: 'overview', label: 'Overview' },
  { id: 'stages', label: 'Stages' },
  { id: 'trends', label: 'Trends' },
  { id: 'coaching', label: 'Coaching' },
];
const tabHref = (id: string) => (id === 'overview' ? '#/sleep' : `#/sleep?tab=${id}`);
// The intro on every tab (the page's title, Sleep, is in the shell's header).
const TITLE = 'Your night, in perspective.';
const SUB = 'Understand and improve your rest. Each night counts on the day you wake up.';
/** Before the first night from any source. */
const SUB_NONE = 'Connect a wearable to see your sleep.';

/** `photo` is still passed by the shell; Sleep no longer shows the figure (Home and Body do). */
export function Sleep({ params, date, setDate }: { params: URLSearchParams; photo?: PhotoMeta | null; date: string | null; setDate: (d: string | null) => void }) {
  const tab = TABS.some((t) => t.id === params.get('tab')) ? params.get('tab')! : 'overview';
  const tabs = <Tabs tabs={TABS} current={tab} hrefOf={tabHref} label="Sleep" center />;
  if (tab === 'stages') return <StagesTab tabs={tabs} />;
  if (tab === 'trends') return <TrendsTab tabs={tabs} />;
  if (tab === 'coaching') return <CoachingTab tabs={tabs} />;
  return <Overview tabs={tabs} date={date} setDate={setDate} />;
}

// ---------- Overview: one night ----------

const SOURCE_NAME = { apple: 'Apple Health', whoop: 'WHOOP', fitbit: 'Fitbit' } as const;

/** Some source that can record a night is set up: WHOOP, the iPhone app or an export, a Fitbit export, or the demo. */
const hasSleepSource = (st: Status | undefined) => !!st && (st.demo || st.whoop.connected || !!st.apple.lastSync || !!st.apple.lastImport || !!st.fitbit?.lastImport);

function Overview({ tabs, date, setDate }: { tabs: ReactNode; date: string | null; setDate: (d: string | null) => void }) {
  const q = date ? `?date=${date}` : '';
  const { data: night, error, loading } = useApi<SleepNightDetail>(`/sleep/night${q}`);
  const { data: s } = useApi<Summary>(`/summary${q}`);
  const { data: t } = useApi<Trends>(`/trends?metrics=resting_hr&days=14${date ? `&date=${date}` : ''}`);
  const { data: p } = useApi<Patterns>('/patterns');
  // Already loaded by the shell: which sources are set up.
  const { data: status } = useApi<Status>('/status');
  const allHidden = useAllHidden('sleep');

  if (error && !night) return <div className="page-message">Couldn't load your sleep: {error.message}</div>;
  if (!night) return <div className="page-message">Loading…</div>;
  const nightLabel = (d: string) => (d === night.today ? 'Last night' : `Night to ${fmtDate(d, { weekday: 'short', month: 'short', day: 'numeric' })}`);
  // lastNight is missing from older servers: then there's no way to tell, and the page is the full one.
  const noNights = night.lastNight === null;
  // Nothing set up and no night ever: just the three cards, as they'll look once a wearable is connected.
  const bare = noNights && !hasSleepSource(status);
  const ctx: NightCtx = {
    night,
    bare,
    label: nightLabel(night.date),
    demo: !!status?.demo,
    whoop: !!status && (status.demo || status.whoop.connected || status.whoop.lastSync !== null),
  };

  return (
    <div className={`page page-wide ${loading ? 'is-refreshing' : ''}`}>
      <PageIntro title={TITLE} sub={noNights ? SUB_NONE : SUB} actions={<ManageSources />}>
        {bare ? null : <IntroTools tabs={tabs} tools={<DayNav today={night.today} date={date} setDate={setDate} label={nightLabel} />} />}
      </PageIntro>
      <CardRow
        className="cards sleep-cards"
        fill={{ wide: 3, mid: 3 }}
        cards={[
          ['sleep.total', <TotalSleepCard c={ctx} s={s} />],
          ['sleep.score', <PerformanceCard c={ctx} />],
          ['sleep.efficiency', <EfficiencyCard c={ctx} />],
        ]}
      />
      {!bare && (
        <>
          <CardRow
            className="split split-stages"
            pair
            cards={[
              ['sleep.stages', <StagesCard night={night} />],
              ['sleep.insights', <InsightsCard night={night} home={s?.insights ?? []} patterns={p?.patterns ?? []} />],
            ]}
          />
          <CardRow
            className="split sleep-lower"
            pair
            cards={[
              ['sleep.timeline', <TimelineCard night={night} />],
              ['sleep.rhr', <RestingHrCard s={s} points={t?.resting_hr ?? []} />],
            ]}
          />
        </>
      )}
      {allHidden && <AllHiddenNote />}
    </div>
  );
}

function NoData({ text }: { text: string }) {
  return <p className="metric-empty">{text}</p>;
}

/** What the three cards need to know about the night and the person's sources. */
type NightCtx = {
  night: SleepNightDetail;
  /** No source and no night ever: the cards' empty state as designed. */
  bare: boolean;
  /** "Last night", "Night to Tue, Oct 20". */
  label: string;
  demo: boolean;
  /** WHOOP is connected, was, or the demo stands in for it: the only source of sleep performance. */
  whoop: boolean;
};

const band = (v: number) => (v >= 85 ? 'Good' : v >= 70 ? 'Fair' : 'Low');

/**
 * The detail sheet for a metric the sheet knows: sleep_performance and sleep_efficiency get their sheets from
 * shared/metrics.ts (the Home build adds them). Until a key is there, its card's ↗ opens the Trends tab instead.
 */
const sheetFor = (key: string): MetricKey | undefined => (isMetricKey(key) ? key : undefined);

/**
 * A card without a reading, for the cases the shared empty card (VitalCard) doesn't cover: a source that doesn't
 * measure this, or a night with nothing recorded. The same look and parts as VitalCard's own empty state.
 */
function NoReading({ title, tone, unit, notes, footLeft, footRight }: { title: string; tone: VitalTone; unit: string; notes: string[]; footLeft: ReactNode; footRight?: ReactNode }) {
  return (
    <article className={`card metric vital-card vital-compact metric-${tone} is-empty`}>
      <div className="metric-head">
        <span>{title}</span>
        <a href={tabHref('trends')} className="metric-link" aria-label={`Open ${title} trends`}>
          <Icon name="arrow-up-right" size={16} />
        </a>
      </div>
      <div className="vital-value">
        <b className="vital-dash" role="img" aria-label="No reading" />
        <small>{unit}</small>
      </div>
      {notes.map((n) => (
        <p key={n} className="vital-note">
          {n}
        </p>
      ))}
      <div className="vital-foot">
        <span>{footLeft}</span>
        {footRight}
      </div>
    </article>
  );
}

const NO_NIGHT = 'No sleep recorded for this night.';

function TotalSleepCard({ c, s }: { c: NightCtx; s: Summary | undefined }) {
  const { night } = c;
  const h = night.asleepHours;
  if (h === null) {
    if (c.bare) return <VitalCard title="Sleep" tone="lavender" unit="hours" value={null} metric="sleep_hours" sheetPage={tabHref('trends')} section="Sleep" variant="compact" />;
    return <NoReading title="Sleep" tone="lavender" unit="hours" notes={[NO_NIGHT]} footLeft={c.label} />;
  }
  const change = s?.sleep.change != null ? s.sleep.change * 100 : null;
  const source = c.demo ? 'Demo data' : night.source ? SOURCE_NAME[night.source] : null;
  return (
    <VitalCard
      title="Sleep"
      tone="lavender"
      unit="hours"
      value={fmt(h, 1)}
      metric="sleep_hours"
      sheetPage={tabHref('trends')}
      date={night.date}
      section="Sleep"
      variant="compact"
      status={change !== null && Math.round(Math.abs(change)) >= 1 ? <Change pct={change} better="up" title="This week's average night against last week's" /> : undefined}
      footLeft={c.label}
      footRight={source}
    >
      {night.segments.length > 1 ? (
        <NightBars segments={night.segments} height={48} />
      ) : s && s.sleep.series.length > 1 ? (
        <MiniBars points={s.sleep.series} format={hoursMinutes} label="Time asleep, last 14 nights" height={44} />
      ) : null}
    </VitalCard>
  );
}

/** A score card: the value, Good, Fair or Low, and the bar. */
function Score({ title, tone, value, metric, c, foot }: { title: string; tone: VitalTone; value: number; metric: string; c: NightCtx; foot: string }) {
  const b = band(value);
  const sheet = sheetFor(metric);
  return (
    <VitalCard
      title={title}
      tone={tone}
      unit="%"
      value={String(value)}
      metric={sheet}
      href={sheet ? undefined : tabHref('trends')}
      sheetPage={tabHref('trends')}
      date={c.night.date}
      section="Sleep"
      variant="compact"
      status={<span className={`score-pill score-${b.toLowerCase()}`}>{b}</span>}
      footLeft={foot}
    >
      <ScoreBar value={value} label={`${title} ${value}%, ${b.toLowerCase()}`} />
    </VitalCard>
  );
}

function PerformanceCard({ c }: { c: NightCtx }) {
  const v = c.night.performance ?? null;
  const title = 'Sleep performance';
  if (v !== null) return <Score title={title} tone="green" value={v} metric="sleep_performance" c={c} foot="WHOOP: the sleep you got against the sleep you needed" />;
  if (c.bare) {
    const sheet = sheetFor('sleep_performance');
    return <VitalCard title={title} tone="green" unit="%" value={null} metric={sheet} href={sheet ? undefined : tabHref('trends')} section="Sleep" variant="compact" />;
  }
  // Only WHOOP scores a night this way: say so, rather than wait for a reading that won't come.
  if (!c.whoop)
    return (
      <NoReading
        title={title}
        tone="green"
        unit="%"
        notes={['No reading yet', 'Sleep performance comes from WHOOP']}
        footLeft="WHOOP only"
        footRight={
          <a href={href('integrations')} className="vital-connect">
            Connect
          </a>
        }
      />
    );
  return <NoReading title={title} tone="green" unit="%" notes={c.night.asleepHours === null ? [NO_NIGHT] : ['No WHOOP sleep for this night']} footLeft={c.label} />;
}

function EfficiencyCard({ c }: { c: NightCtx }) {
  const v = c.night.efficiency ?? null;
  const title = 'Sleep efficiency';
  if (v !== null) return <Score title={title} tone="blue" value={v} metric="sleep_efficiency" c={c} foot="Time asleep as a share of time in bed" />;
  if (c.bare) {
    const sheet = sheetFor('sleep_efficiency');
    return <VitalCard title={title} tone="blue" unit="%" value={null} metric={sheet} href={sheet ? undefined : tabHref('trends')} section="Sleep" variant="compact" />;
  }
  return (
    <NoReading
      title={title}
      tone="blue"
      unit="%"
      notes={c.night.asleepHours === null ? [NO_NIGHT] : ['No reading for this night', 'It needs time asleep and time in bed from one device']}
      footLeft={c.label}
    />
  );
}

const STATUS_TEXT = { low: 'Below your usual', normal: 'Within your usual', high: 'Above your usual' };

function RestingHrCard({ s, points }: { s: Summary | undefined; points: { date: string; value: number }[] }) {
  const v = s?.vitals.heart;
  const w = s?.week?.restingHr;
  return (
    <article className="card metric rhr-card">
      <div className="metric-head">
        <span>Resting heart rate</span>
        <Change pct={w?.avg != null && w.prev ? ((w.avg - w.prev) / w.prev) * 100 : null} better="down" title="This week's average against last week's" />
      </div>
      {v?.latest ? (
        <>
          <div className="metric-value">
            {fmt(v.latest.value)}
            <small>bpm</small>
          </div>
          {points.length > 1 && <MiniLine points={points} format={(x) => `${fmt(x)} bpm`} color="var(--series-1)" height={52} label="Resting heart rate, last 14 days" />}
          <div className="metric-foot">
            <span className="metric-strong">{v.status ? STATUS_TEXT[v.status] : 'Building your baseline'}</span>
            {v.latest.date !== s!.date && <span className="stale">{fmtDate(v.latest.date)}</span>}
          </div>
        </>
      ) : (
        <NoData text="No resting heart rate yet." />
      )}
    </article>
  );
}

const STAGE_ROWS = [
  { key: 'awake', label: 'Awake', color: STAGE_COLOR.awake },
  { key: 'rem', label: 'REM', color: STAGE_COLOR.rem },
  { key: 'light', label: 'Light', color: STAGE_COLOR.light },
  { key: 'deep', label: 'Deep', color: STAGE_COLOR.deep },
] as const;

/** Hours in each stage, added up from the night's stretches (for a night with no stage totals of its own). */
function totalsOf(segments: SleepSegment[]) {
  const t = { awake: 0, rem: 0, light: 0, deep: 0 };
  for (const g of segments) {
    const h = (Date.parse(g.end) - Date.parse(g.start)) / 3_600_000;
    if (g.stage === 'awake') t.awake += h;
    else if (g.stage === 'rem') t.rem += h;
    else if (g.stage === 'light' || g.stage === 'asleep') t.light += h;
    else if (g.stage === 'deep') t.deep += h;
  }
  return t;
}

function StagesCard({ night }: { night: SleepNightDetail }) {
  // Watch nights recorded before stages ("asleep" only) have nothing to draw by stage.
  const staged = night.segments.some((x) => x.stage === 'deep' || x.stage === 'rem' || x.stage === 'light');
  // A short night the Watch scored as core and awake only gets no stage totals from the phone; its stretches still add up.
  const st = night.stages ?? (staged ? totalsOf(night.segments) : null);
  const total = st ? st.awake + st.rem + st.light + st.deep : 0;
  return (
    <section className="card night-stages">
      <CardHead title="Sleep stages" to={tabHref('stages')} />
      {staged ? <Hypnogram segments={night.segments} /> : st && total > 0 ? <StageBar stages={st} /> : null}
      {st && total > 0 ? (
        <div className="stage-totals">
          {STAGE_ROWS.map((r) => (
            <div key={r.key}>
              <span className="stage-totals-label">
                <i style={{ background: r.color }} />
                {r.label}
              </span>
              <b>{hoursMinutes(st[r.key])}</b>
              <small>{Math.round((st[r.key] / total) * 100)}%</small>
            </div>
          ))}
        </div>
      ) : (
        <NoData text="No stages for this night. Apple Watch, WHOOP and Fitbit all record them." />
      )}
      {st && total > 0 && !staged && (
        <p className="card-note">
          {night.source === 'whoop'
            ? "WHOOP shares each stage's total, not when in the night it happened."
            : night.source === 'fitbit'
              ? "The Fitbit export has this night's stage totals, not when in the night each happened."
              : daysBetween(night.date, night.today) <= RESENT_DAYS
              ? 'The stages through the night arrive once the healthOS iPhone app is updated and syncs.'
              : "The stages through the night aren't available for this night."}
        </p>
      )}
    </section>
  );
}

/** The iPhone app sends the last month's nights again once, with their stages (SyncState.recentDays). */
const RESENT_DAYS = 30;

const PATTERN_TONE: Record<Pattern['icon'], string> = { ...INSIGHT_TONE, spark: 'tone-blue' };

function InsightsCard({ night, home, patterns }: { night: SleepNightDetail; home: Insight[]; patterns: Pattern[] }) {
  const rows: { id: string; icon: IconName; tone: string; text: string; note?: string; to: string }[] = [
    ...night.insights.map((i) => ({ id: i.id, icon: i.icon as IconName, tone: INSIGHT_TONE[i.icon], text: i.text, to: tabHref(i.id === 'latency' ? 'stages' : 'trends') })),
    // Home's sleep insights, when they say something the night's own don't (sleep debt, need, timing).
    ...home
      .filter((i) => i.page === 'sleep' && !night.insights.some((n) => n.id === i.id || (n.id === 'consistency' && i.id === 'bedtime')))
      .map((i) => ({ id: `home-${i.id}`, icon: i.icon as IconName, tone: INSIGHT_TONE[i.icon], text: i.text, to: tabHref('coaching') })),
    ...patterns
      .filter((p) => p.page === 'sleep')
      .map((p) => ({ id: p.id, icon: p.icon as IconName, tone: PATTERN_TONE[p.icon], text: p.text, note: p.detail, to: tabHref('coaching') })),
  ].slice(0, 4);
  return (
    <section className="card insights">
      <div className="card-title-row">
        <h2>Sleep insights</h2>
      </div>
      {rows.length === 0 && <p className="tl-empty">Insights appear after a week or two of nights.</p>}
      <ul>
        {rows.map((r) => (
          <li key={r.id}>
            <a href={r.to}>
              <span className={`insight-icon ${r.tone}`}>
                <Icon name={r.icon} size={17} />
              </span>
              <span className="insight-text">
                <span>{r.text}</span>
                {r.note && <small>{r.note}</small>}
              </span>
              <Icon name="chevron-right" size={16} />
            </a>
          </li>
        ))}
      </ul>
    </section>
  );
}

function TimelineCard({ night }: { night: SleepNightDetail }) {
  const segs = night.segments;
  const start = segs[0]?.start ?? night.fellAsleep;
  const end = segs.at(-1)?.end ?? night.wokeUp;
  return (
    <section className="card night-timeline">
      <div className="card-title-row">
        <h2>Sleep timeline</h2>
      </div>
      {start && end ? (
        <>
          <StageTimeline segments={segs} start={start} end={end} marker={night.deepPeak} />
          <div className="night-facts">
            {night.fellAsleep && <Fact color={STAGE_COLOR.awake} label="Fell asleep" value={clock(night.fellAsleep)} />}
            {night.deepPeak && <Fact color={STAGE_COLOR.deep} label="Deepest sleep" value={clock(night.deepPeak)} />}
            {night.wokeUp && <Fact color={STAGE_COLOR.light} label="Woke up" value={clock(night.wokeUp)} />}
            {night.inBedHours !== null && <Fact label="In bed" value={hoursMinutes(night.inBedHours)} />}
          </div>
          {night.source === 'whoop' && segs.length === 0 && <p className="card-note">From WHOOP's sleep record: when it started and ended.</p>}
        </>
      ) : (
        <NoData text="No sleep recorded for this night." />
      )}
    </section>
  );
}

function Fact({ color, label, value }: { color?: string; label: string; value: string }) {
  return (
    <div className="night-fact">
      {color ? <i style={{ background: color }} /> : <Icon name="sleep" size={16} />}
      <span>
        {label}
        <b>{value}</b>
      </span>
    </div>
  );
}

// ---------- Stages: a range of nights ----------

function StagesTab({ tabs }: { tabs: ReactNode }) {
  const [range, setDays] = useRange();
  const days = range === DAY ? 30 : range;
  const { data, loading } = useApi<Trends>(`/trends?metrics=sleep_hours,sleep_deep,sleep_light,sleep_rem,sleep_awake&days=${days}`);
  const t = data ?? {};
  const byDate = new Map<string, Record<string, number>>();
  for (const s of STAGES) for (const p of t[s.key] ?? []) byDate.set(p.date, { ...byDate.get(p.date), [s.key]: p.value });
  const nights = [...byDate].sort(([a], [b]) => a.localeCompare(b)).map(([date, values]) => ({ date, values }));
  let rows = nights;
  if (days > 90) {
    const weeks = new Map<string, { n: number; values: Record<string, number> }>();
    for (const r of nights) {
      const k = weekly([{ date: r.date, value: 0 }], days)[0].date;
      const w = weeks.get(k) ?? { n: 0, values: {} };
      w.n++;
      for (const [key, v] of Object.entries(r.values)) w.values[key] = (w.values[key] ?? 0) + v;
      weeks.set(k, w);
    }
    rows = [...weeks].map(([date, w]) => ({ date, values: Object.fromEntries(Object.entries(w.values).map(([k, v]) => [k, v / w.n])) }));
  }
  const a = avg(t.sleep_hours ?? []);
  // Each stage's average over the nights that recorded stages, and its share of those nights.
  const mean = (key: string) => (nights.length ? nights.reduce((x, r) => x + (r.values[key] ?? 0), 0) / nights.length : 0);
  const totals = STAGES.map((s) => ({ ...s, hours: mean(s.key) }));
  const sum = totals.reduce((x, s) => x + s.hours, 0) || 1;

  return (
    <div className={`page page-wide ${loading ? 'is-refreshing' : ''}`}>
      <PageIntro title={TITLE} sub={SUB} actions={<ManageSources />}>
        <IntroTools tabs={tabs} days={days} setDays={setDays} />
      </PageIntro>
      <div className="grid-1">
        <ChartCard
          title={days > 90 ? 'Sleep stages, weekly average' : 'Sleep stages'}
          value={a !== null ? hoursMinutes(a) : '—'}
          note="average time asleep"
          legend={<Legend items={STAGES.map((s) => ({ label: s.label, color: s.color }))} />}
          table={{
            columns: ['Night', ...STAGES.map((s) => s.label)],
            rows: rows.map((r) => [fmtDate(r.date, { year: 'numeric', month: 'short', day: 'numeric' }), ...STAGES.map((s) => hoursMinutes(r.values[s.key] ?? 0))]),
          }}
        >
          <StackedBars rows={rows} series={STAGES} format={hoursMinutes} tickFormat={(v) => `${fmt(v)}h`} label="Sleep stages per night" periodLabel={days > 90 ? weekLabel : undefined} />
        </ChartCard>
        {nights.length > 0 && (
          <section className="card">
            <div className="card-title-row">
              <h2>An average night</h2>
              <span className="muted">{nights.length} nights with stages</span>
            </div>
            <div className="stage-totals">
              {totals.map((s) => (
                <div key={s.key}>
                  <span className="stage-totals-label">
                    <i style={{ background: s.color }} />
                    {s.label}
                  </span>
                  <b>{hoursMinutes(s.hours)}</b>
                  <small>{Math.round((s.hours / sum) * 100)}%</small>
                </div>
              ))}
            </div>
          </section>
        )}
      </div>
    </div>
  );
}

// ---------- Trends ----------

function TrendsTab({ tabs }: { tabs: ReactNode }) {
  const [range, setDays] = useRange();
  const days = range === DAY ? 30 : range;
  const { data, loading } = useApi<Trends>(`/trends?metrics=sleep_hours,sleep_in_bed,sleep_performance,sleep_efficiency,sleep_consistency,sleep_deep,sleep_rem&days=${days}`);
  const t = data ?? {};
  const has = (m: string) => (t[m]?.length ?? 0) > 0;
  const h = (v: number) => `${fmt(v)}h`;
  return (
    <div className={`page page-wide ${loading ? 'is-refreshing' : ''}`}>
      <PageIntro title={TITLE} sub={SUB} actions={<ManageSources />}>
        <IntroTools tabs={tabs} days={days} setDays={setDays} />
      </PageIntro>
      <div className="grid-2">
        <Trend title="Time asleep" points={t.sleep_hours ?? []} format={hoursMinutes} tickFormat={h} />
        {has('sleep_performance') && <Trend title="Sleep performance" points={t.sleep_performance} format={(v) => `${fmt(v)}%`} unitNote="WHOOP: sleep vs sleep needed" color="var(--series-3)" />}
        {/* WHOOP's and a Fitbit export's own figures; an Apple Watch night's is worked out on the Overview only. */}
        {has('sleep_efficiency') && <Trend title="Sleep efficiency" points={t.sleep_efficiency} format={(v) => `${fmt(v)}%`} unitNote="Time asleep ÷ time in bed" color="var(--series-3)" />}
        {has('sleep_in_bed') && <Trend title="Time in bed" points={t.sleep_in_bed} format={hoursMinutes} tickFormat={h} />}
        {has('sleep_consistency') && <Trend title="Sleep consistency" points={t.sleep_consistency} format={(v) => `${fmt(v)}%`} unitNote="WHOOP" color="var(--series-3)" />}
        {has('sleep_deep') && <Trend title="Deep sleep" points={t.sleep_deep} format={hoursMinutes} tickFormat={h} color="var(--stage-deep)" />}
        {has('sleep_rem') && <Trend title="REM sleep" points={t.sleep_rem} format={hoursMinutes} tickFormat={h} color="var(--stage-rem)" />}
      </div>
    </div>
  );
}

// ---------- Coaching: timing, need and debt, and what goes with better nights ----------

/** Minutes after 18:00 as a clock time ("330" is 23:30). */
const fromSix = (m: number) => {
  const t = Math.round(m + 18 * 60) % (24 * 60);
  return `${String(Math.floor(t / 60)).padStart(2, '0')}:${String(t % 60).padStart(2, '0')}`;
};
const ofDay = (m: number) => `${String(Math.floor(m / 60) % 24).padStart(2, '0')}:${String(Math.round(m % 60)).padStart(2, '0')}`;

function CoachingTab({ tabs }: { tabs: ReactNode }) {
  const { data, loading } = useApi<SleepTiming>('/sleep?days=60');
  const { data: p } = useApi<Patterns>('/patterns');
  const st = data?.stats;
  const sleepPatterns = (p?.patterns ?? []).filter((x) => x.page === 'sleep');
  return (
    <div className={`page page-wide ${loading ? 'is-refreshing' : ''}`}>
      <PageIntro title={TITLE} sub={SUB} actions={<ManageSources />}>
        <IntroTools tabs={tabs} />
      </PageIntro>
      {!st ? (
        <div className="page-message">Loading…</div>
      ) : st.nights < 7 ? (
        <section className="card">
          <h2>Coaching</h2>
          <p className="muted">This needs a week of nights. {st.nights === 1 ? 'There is 1 so far.' : `There are ${st.nights} so far.`}</p>
        </section>
      ) : (
        <>
          <div className="cards">
            <article className="card metric">
              <div className="metric-head">
                <span>Your sleep need</span>
              </div>
              <div className="metric-value">
                {st.need !== null ? hoursMinutes(st.need) : '—'}
                <small>a night</small>
              </div>
              <div className="metric-foot">
                <span>{st.need !== null ? 'Your own median over the last 60 nights, held within 7–9 hours' : 'Needs two weeks of nights'}</span>
              </div>
            </article>
            <article className="card metric">
              <div className="metric-head">
                <span>Sleep debt, last 7 days</span>
              </div>
              <div className="metric-value">
                {st.debt !== null ? hoursMinutes(st.debt) : '—'}
                <small>{st.debt !== null ? `over ${st.debtNights} night${st.debtNights === 1 ? '' : 's'}` : 'short of your need'}</small>
              </div>
              <div className="metric-foot">
                <span>Hours short of your need, added up</span>
              </div>
            </article>
            <article className="card metric">
              <div className="metric-head">
                <span>Usual times</span>
              </div>
              <div className="coach-times">
                <div>
                  <small>Bedtime</small>
                  <b>{st.avgBedMin !== null ? fromSix(st.avgBedMin) : '—'}</b>
                  {st.bedSd !== null && <small>± {Math.round(st.bedSd)} min</small>}
                </div>
                <div>
                  <small>Wake</small>
                  <b>{st.avgWakeMin !== null ? ofDay(st.avgWakeMin) : '—'}</b>
                  {st.wakeSd !== null && <small>± {Math.round(st.wakeSd)} min</small>}
                </div>
              </div>
              <div className="metric-foot">
                <span>
                  {st.socialJetlag !== null && Math.abs(st.socialJetlag) >= 30
                    ? `Weekends run ${hoursMinutes(Math.abs(st.socialJetlag) / 60)} ${st.socialJetlag > 0 ? 'later' : 'earlier'} than weekdays`
                    : `Over ${st.nights} nights`}
                </span>
              </div>
            </article>
          </div>
          <section className="card insights">
            <div className="card-title-row">
              <h2>What goes with your better nights</h2>
              {p && <span className="muted">{fmtDate(p.start)} – {fmtDate(p.end)}</span>}
            </div>
            {sleepPatterns.length === 0 && <p className="tl-empty">Nothing stands out yet. Patterns need a few months of days with and without each habit.</p>}
            <ul>
              {sleepPatterns.map((x) => (
                <li key={x.id}>
                  <span className="insight-row">
                    <span className={`insight-icon ${PATTERN_TONE[x.icon]}`}>
                      <Icon name={x.icon as IconName} size={17} />
                    </span>
                    <span className="insight-text">
                      <span>{x.text}</span>
                      <small>{x.detail}</small>
                    </span>
                  </span>
                </li>
              ))}
            </ul>
            <p className="card-note">These are your own days compared with each other. They show what tends to go together, not what causes what.</p>
          </section>
        </>
      )}
    </div>
  );
}

