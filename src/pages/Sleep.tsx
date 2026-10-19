// The Sleep page: one night (Overview), the stages over a range, trends, and coaching from the person's own
// nights. Every figure is from one device for that night; nothing here is a score we made up.
import type { ReactNode } from 'react';
import type { Insight, Pattern, Patterns, PhotoMeta, SleepNightDetail, SleepTiming, Summary, Trends } from '../../shared/types.ts';
import { ChartCard, Legend, StackedBars } from '../charts/Charts.tsx';
import { MiniBars, MiniLine } from '../charts/Mini.tsx';
import { Change, Hypnogram, NightBars, STAGE_COLOR, ScoreBar, StageBar, StageTimeline } from '../charts/Neka.tsx';
import { Figure } from '../components/Figure.tsx';
import { Icon, type IconName } from '../components/Icon.tsx';
import { clock, daysBetween, fmt, fmtDate, hoursMinutes, useApi } from '../lib.ts';
import { DAY, DayNav, PageHead, STAGES, Tabs, Trend, avg, useRange, weekLabel, weekly } from './Detail.tsx';
import { CardHead, INSIGHT_TONE } from './Home.tsx';

const TABS = [
  { id: 'overview', label: 'Overview' },
  { id: 'stages', label: 'Stages' },
  { id: 'trends', label: 'Trends' },
  { id: 'coaching', label: 'Coaching' },
];
const tabHref = (id: string) => (id === 'overview' ? '#/sleep' : `#/sleep?tab=${id}`);
const SUB = 'Understand and improve your rest. Each night counts on the day you wake up.';

export function Sleep({ params, photo, date, setDate }: { params: URLSearchParams; photo: PhotoMeta | null; date: string | null; setDate: (d: string | null) => void }) {
  const tab = TABS.some((t) => t.id === params.get('tab')) ? params.get('tab')! : 'overview';
  const tabs = <Tabs tabs={TABS} current={tab} hrefOf={tabHref} label="Sleep" center />;
  if (tab === 'stages') return <StagesTab tabs={tabs} />;
  if (tab === 'trends') return <TrendsTab tabs={tabs} />;
  if (tab === 'coaching') return <CoachingTab tabs={tabs} />;
  return <Overview tabs={tabs} photo={photo} date={date} setDate={setDate} />;
}

// ---------- Overview: one night ----------

function Overview({ tabs, photo, date, setDate }: { tabs: ReactNode; photo: PhotoMeta | null; date: string | null; setDate: (d: string | null) => void }) {
  const q = date ? `?date=${date}` : '';
  const { data: night, error, loading } = useApi<SleepNightDetail>(`/sleep/night${q}`);
  const { data: s } = useApi<Summary>(`/summary${q}`);
  const { data: t } = useApi<Trends>(`/trends?metrics=resting_hr&days=14${date ? `&date=${date}` : ''}`);
  const { data: p } = useApi<Patterns>('/patterns');

  if (error && !night) return <div className="page-message">Couldn't load your sleep: {error.message}</div>;
  if (!night) return <div className="page-message">Loading…</div>;
  const nightLabel = (d: string) => (d === night.today ? 'Last night' : `Night to ${fmtDate(d, { weekday: 'short', month: 'short', day: 'numeric' })}`);

  return (
    <div className={`page page-wide ${loading ? 'is-refreshing' : ''}`}>
      <PageHead title="Sleep" sub={SUB} tabs={tabs} tools={<DayNav today={night.today} date={date} setDate={setDate} label={nightLabel} />} />
      <div className={s ? 'night-layout has-hero' : 'night-layout'}>
        {s && (
          <div className="page-hero">
            <Figure vitals={s.vitals} asOf={s.date} photo={photo} />
          </div>
        )}
        <div className="night-main">
          <div className="cards night-cards">
            <ScoreCard night={night} />
            <TotalSleepCard night={night} s={s} />
            <RestingHrCard s={s} points={t?.resting_hr ?? []} />
          </div>
          <div className="split split-stages">
            <StagesCard night={night} />
            <InsightsCard night={night} home={s?.insights ?? []} patterns={p?.patterns ?? []} />
          </div>
          <TimelineCard night={night} />
        </div>
      </div>
    </div>
  );
}

function NoData({ text }: { text: string }) {
  return <p className="metric-empty">{text}</p>;
}

const band = (v: number) => (v >= 85 ? 'Good' : v >= 70 ? 'Fair' : 'Low');

function ScoreCard({ night }: { night: SleepNightDetail }) {
  const sc = night.score;
  if (!sc)
    return (
      <article className="card metric">
        <CardHead title="Sleep score" to={tabHref('trends')} />
        <NoData text="No score for this night. WHOOP nights have its sleep performance; Apple Watch nights get an efficiency when time in bed was recorded." />
      </article>
    );
  const title = sc.kind === 'performance' ? 'Sleep performance' : 'Sleep efficiency';
  const b = band(sc.value);
  return (
    <article className="card metric">
      <CardHead title={title} to={tabHref('trends')} />
      <div className="metric-value">
        {sc.value}
        <small>%</small>
      </div>
      <span className={`score-pill score-${b.toLowerCase()}`}>{b}</span>
      <ScoreBar value={sc.value} label={`${title} ${sc.value}%, ${b.toLowerCase()}`} />
      <div className="metric-foot">
        <span>{sc.kind === 'performance' ? 'WHOOP: the sleep you got against the sleep you needed' : 'Time asleep as a share of time in bed'}</span>
      </div>
    </article>
  );
}

function TotalSleepCard({ night, s }: { night: SleepNightDetail; s: Summary | undefined }) {
  const h = night.asleepHours;
  return (
    <article className="card metric">
      <div className="metric-head">
        <span>Total sleep</span>
        <Change pct={s?.sleep.change != null ? s.sleep.change * 100 : null} better="up" title="This week's average night against last week's" />
      </div>
      {h !== null ? (
        <>
          <div className="metric-value">
            {fmt(h, 1)}
            <small>hours</small>
          </div>
          {night.segments.length > 1 ? (
            <NightBars segments={night.segments} />
          ) : s && s.sleep.series.length > 1 ? (
            <>
              <MiniBars points={s.sleep.series} format={hoursMinutes} label="Time asleep, last 14 nights" height={58} />
              <div className="metric-foot">
                <span>Last 14 nights</span>
              </div>
            </>
          ) : null}
        </>
      ) : (
        <NoData text="No sleep recorded for this night." />
      )}
    </article>
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

function StagesCard({ night }: { night: SleepNightDetail }) {
  const st = night.stages;
  // Watch nights recorded before stages ("asleep" only) have nothing to draw by stage.
  const staged = night.segments.some((x) => x.stage === 'deep' || x.stage === 'rem' || x.stage === 'light');
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
        <NoData text="No stages for this night. Apple Watch and WHOOP both record them." />
      )}
      {st && total > 0 && !staged && (
        <p className="card-note">
          {night.source === 'whoop'
            ? "WHOOP shares each stage's total, not when in the night it happened."
            : daysBetween(night.date, night.today) <= RESENT_DAYS
              ? 'The stages through the night arrive with the next sync from the healthOS iPhone app.'
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
          {night.source === 'whoop' && <p className="card-note">From WHOOP's sleep record: when it started and ended.</p>}
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
    <div className={`page ${loading ? 'is-refreshing' : ''}`}>
      <PageHead title="Sleep" sub={SUB} tabs={tabs} days={days} setDays={setDays} />
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
    <div className={`page ${loading ? 'is-refreshing' : ''}`}>
      <PageHead title="Sleep" sub={SUB} tabs={tabs} days={days} setDays={setDays} />
      <div className="grid-2">
        <Trend title="Time asleep" points={t.sleep_hours ?? []} format={hoursMinutes} tickFormat={h} />
        {has('sleep_performance') ? (
          <Trend title="Sleep performance" points={t.sleep_performance} format={(v) => `${fmt(v)}%`} unitNote="WHOOP: sleep vs sleep needed" color="var(--series-3)" />
        ) : (
          <Trend title="Sleep efficiency" points={t.sleep_efficiency ?? []} format={(v) => `${fmt(v)}%`} unitNote="time asleep ÷ time in bed" color="var(--series-3)" />
        )}
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
    <div className={`page ${loading ? 'is-refreshing' : ''}`}>
      <PageHead title="Sleep" sub={SUB} tabs={tabs} />
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

