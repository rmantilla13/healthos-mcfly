// The Body page: one day at a glance (Overview), then a tab per area. Activity lives here as a tab; its old
// address (#/activity) opens that tab. Every number is a reading or a plain sum of readings; none is invented.
import type { ReactNode } from 'react';
import type { DayData, Point, Summary, Trends } from '../../shared/types.ts';
import { cumulative, drawThrough, extent } from '../charts/day.ts';
import { Gauge, MiniBars, MiniDots, MiniLine } from '../charts/Mini.tsx';
import { AreaCurve, Change, HourBars } from '../charts/Neka.tsx';
import { AllHiddenNote, CardRow, useAllHidden } from '../components/CardRow.tsx';
import { Icon, type IconName } from '../components/Icon.tsx';
import { compact, fmt, fmtDate, shiftDate, temp, useApi, useUnits } from '../lib.ts';
import { Activity, DAY, DayNav, Metabolism, PageHead, Tabs, Trend, useRange } from './Detail.tsx';
import { CardHead, Stale, signed } from './Home.tsx';

const TABS = [
  { id: 'overview', label: 'Overview' },
  { id: 'recovery', label: 'Recovery' },
  { id: 'strain', label: 'Strain' },
  { id: 'activity', label: 'Activity' },
  { id: 'temperature', label: 'Temperature' },
  { id: 'cardiovascular', label: 'Cardiovascular' },
  { id: 'metabolism', label: 'Metabolism' },
];
export const bodyHref = (id: string) => (id === 'overview' ? '#/body' : `#/body?tab=${id}`);
const TITLE = 'Body';
const SUB = 'Your heart, recovery, strain and movement, from WHOOP and Apple Watch.';

export function Body({ params, stepGoal, date, setDate }: { params: URLSearchParams; stepGoal: number; date: string | null; setDate: (d: string | null) => void }) {
  const tab = TABS.some((t) => t.id === params.get('tab')) ? params.get('tab')! : 'overview';
  const tabs = <Tabs tabs={TABS} current={tab} hrefOf={bodyHref} label="Body" />;
  if (tab === 'activity') return <Activity stepGoal={stepGoal} title={TITLE} sub={SUB} tabs={tabs} />;
  if (tab === 'metabolism') return <Metabolism tabs={tabs} />;
  const spec = TREND_TABS[tab];
  if (spec) return <TrendTab key={tab} tabs={tabs} specs={spec} />;
  return <Overview tabs={tabs} date={date} setDate={setDate} />;
}

// ---------- Overview: one day ----------

const OVERVIEW_TRENDS = 'resting_hr,recovery,resp_rate,body_temp,wrist_temp,skin_temp,active_energy';
const TEMP_METRIC: Record<string, string> = { 'Body temp': 'body_temp', 'Wrist temp': 'wrist_temp', 'Skin temp': 'skin_temp' };

function Overview({ tabs, date, setDate }: { tabs: ReactNode; date: string | null; setDate: (d: string | null) => void }) {
  const q = date ? `?date=${date}` : '';
  const { data: s, error, loading } = useApi<Summary>(`/summary${q}`);
  // 45 days: the temperature row compares with the 30 days before its latest reading, which can be two weeks old.
  const { data: t } = useApi<Trends>(`/trends?metrics=${OVERVIEW_TRENDS}&days=45${date ? `&date=${date}` : ''}`);
  const { data: day } = useApi<DayData>(`/day?metrics=heart_rate,steps,active_energy${date ? `&date=${date}` : ''}`);
  const allHidden = useAllHidden('body');
  if (error && !s) return <div className="page-message">Couldn't load your data: {error.message}</div>;
  if (!s) return <div className="page-message">Loading…</div>;
  const tr = t ?? {};
  const label = (d: string) => fmtDate(d, { weekday: 'short', month: 'short', day: 'numeric', year: 'numeric' });

  return (
    <div className={`page page-wide ${loading ? 'is-refreshing' : ''}`}>
      <PageHead title={TITLE} sub={SUB} tabs={tabs} tools={<DayNav today={s.today} date={date} setDate={setDate} label={label} />} />
      <CardRow
        className="cards cards-4"
        cards={[
          ['body.rhr', <RestingHrCard s={s} points={tr.resting_hr ?? []} />],
          ['body.hrv', <HrvCard s={s} />],
          ['body.strain', <StrainCard s={s} />],
          ['body.recovery', <RecoveryCard s={s} points={tr.recovery ?? []} />],
        ]}
      />
      <CardRow
        className="split split-body"
        pair
        cards={[
          ['body.heart', <HeartTodayCard day={day} />],
          ['body.metrics', <BodyMetricsCard s={s} t={tr} />],
        ]}
      />
      <CardRow
        className="split split-even"
        pair
        cards={[
          ['body.energy', <EnergyCard day={day} points={tr.active_energy ?? []} date={s.date} />],
          ['body.steps', <StepsCard day={day} s={s} />],
        ]}
      />
      {allHidden && <AllHiddenNote />}
    </div>
  );
}

function NoData({ text }: { text: string }) {
  return <p className="metric-empty">{text}</p>;
}

const mean = (vs: number[]) => (vs.length ? vs.reduce((a, b) => a + b, 0) / vs.length : null);

const STATUS = { low: 'Below your usual', normal: 'Within your usual', high: 'Above your usual' } as const;
/** The summary's HRV status: 'optimal' is any night at or above the person's mean, as on Home. */
const HRV_STATUS = { optimal: 'At or above your usual', normal: 'Within your usual', low: 'Below your usual' } as const;
const weekPct = (w: { avg: number | null; prev: number | null } | undefined) => (w?.avg != null && w.prev ? ((w.avg - w.prev) / w.prev) * 100 : null);

function RestingHrCard({ s, points }: { s: Summary; points: Point[] }) {
  const v = s.vitals.heart;
  return (
    <article className="card metric metric-green">
      <div className="metric-head">
        <span>Resting heart rate</span>
        <a href={bodyHref('cardiovascular')} className="metric-link" aria-label="Open resting heart rate">
          <Icon name="arrow-up-right" size={16} />
        </a>
      </div>
      {v.latest ? (
        <>
          <div className="metric-value">
            {fmt(v.latest.value)}
            <small>bpm</small>
          </div>
          <Change pct={weekPct(s.week?.restingHr)} better="down" />
          {points.length > 1 && <MiniLine points={points.slice(-14)} format={(x) => `${fmt(x)} bpm`} color="var(--good)" height={48} label="Resting heart rate, last 14 days" />}
          <div className="metric-foot">
            <span className="metric-strong">
              {v.status ? STATUS[v.status] : 'Building your baseline'}
              <Stale date={v.latest.date} asOf={s.date} />
            </span>
            <span title="Compared with your own last 30 days, from the same device">last 30 days</span>
          </div>
        </>
      ) : (
        <NoData text="No resting heart rate yet." />
      )}
    </article>
  );
}

function HrvCard({ s }: { s: Summary }) {
  const l = s.hrv.latest;
  const statusText = HRV_STATUS;
  return (
    <article className="card metric metric-blue">
      <CardHead title="HRV" to={bodyHref('recovery')} />
      {l ? (
        <>
          <div className="metric-value">
            {fmt(l.value)}
            <small>ms</small>
          </div>
          <Change pct={weekPct(s.week?.hrv)} better="up" />
          <MiniDots points={s.hrv.series} baseline={s.hrv.baseline} format={(v) => `${fmt(v)} ms`} label="Heart rate variability, last 21 nights, with your usual range" height={56} />
          <div className="metric-foot">
            <span className="metric-strong">
              {s.hrv.status ? statusText[s.hrv.status] : 'Building your baseline'}
              <Stale date={l.date} asOf={s.date} />
            </span>
            <span title={s.hrv.metric === 'hrv_rmssd' ? 'WHOOP measures RMSSD during sleep' : 'Apple Watch measures SDNN'}>{s.hrv.metric === 'hrv_rmssd' ? 'RMSSD' : 'SDNN'}</span>
          </div>
        </>
      ) : (
        <NoData text="No HRV readings yet." />
      )}
    </article>
  );
}

function StrainCard({ s }: { s: Summary }) {
  const l = s.load;
  if (!l)
    return (
      <article className="card metric metric-pink">
        <CardHead title="Strain" to={bodyHref('strain')} />
        <NoData text="Strain comes from WHOOP; active energy from Apple Health." />
      </article>
    );
  const strain = l.kind === 'strain';
  const v = l.latest.value;
  const max = strain ? 21 : Math.max(800, (l.average ?? 0) * 1.6);
  const bandText = strain ? (v < 10 ? 'Light' : v < 14 ? 'Moderate' : v < 18 ? 'High' : 'All out') : v >= (l.average ?? 0) ? 'Above usual' : 'Below usual';
  return (
    <article className="card metric metric-pink">
      <CardHead title={strain ? 'Strain' : 'Active energy'} to={bodyHref('strain')} />
      <div className="metric-value">
        {strain ? fmt(v, 1) : fmt(v)}
        <small>{strain ? '0–21' : 'kcal'}</small>
      </div>
      <div className="gauge-wrap">
        <Gauge value={v} max={max} label={strain ? `Strain ${fmt(v, 1)} of 21` : `${fmt(v)} kcal`} />
      </div>
      <div className="metric-foot">
        <span className="metric-strong">
          {bandText}
          <Stale date={l.latest.date} asOf={s.date} />
        </span>
        {l.average ? <span title="Compared with your 7-day average">{signed(((v - l.average) / l.average) * 100)}% vs avg</span> : null}
      </div>
    </article>
  );
}

const ZONE = { green: { text: 'High', range: '67–100' }, yellow: { text: 'Moderate', range: '34–66' }, red: { text: 'Low', range: '0–33' } };

function RecoveryCard({ s, points }: { s: Summary; points: Point[] }) {
  const r = s.readiness;
  if (r?.kind === 'vo2max') {
    const delta = r.previous !== null ? r.latest.value - r.previous : null;
    return (
      <article className="card metric metric-green">
        <CardHead title="Cardio fitness" to={bodyHref('cardiovascular')} />
        <div className="metric-value">
          {fmt(r.latest.value, 1)}
          <small>VO₂ max, mL/kg·min</small>
        </div>
        {delta !== null && <span className="chip">{signed(delta, 1)} vs last month</span>}
        <div className="metric-foot">
          <span>From Apple Watch</span>
          <Stale date={r.latest.date} asOf={s.date} />
        </div>
      </article>
    );
  }
  if (!r)
    return (
      <article className="card metric metric-green">
        <CardHead title="Recovery" to={bodyHref('recovery')} />
        <NoData text="Recovery comes from WHOOP; cardio fitness from Apple Watch." />
      </article>
    );
  const z = ZONE[r.zone];
  return (
    <article className="card metric metric-green">
      <CardHead title="Recovery" to={bodyHref('recovery')} />
      <div className="metric-value">
        {fmt(r.latest.value)}
        <small>%</small>
      </div>
      <Change pct={weekPct(s.week?.recovery)} better="up" />
      {points.length > 1 && <MiniBars points={points.slice(-14)} format={(v) => `${fmt(v)}%`} tone="green" label="Recovery, last 14 days" height={50} />}
      <div className="metric-foot">
        <span className={`zone-label zone-label-${r.zone}`}>
          <i />
          {z.text}
          <Stale date={r.latest.date} asOf={s.date} />
        </span>
        <span>{z.range}</span>
      </div>
    </article>
  );
}

function HeartTodayCard({ day }: { day: DayData | undefined }) {
  const hr = day?.metrics.heart_rate;
  const isToday = day ? day.date === day.today : true;
  const through = day ? drawThrough(day.date, day.today, day.asOf) : null;
  const hours = hr ? hr.hours.map((v, h) => (through !== null && h <= through ? v : null)) : [];
  const readings = hours.filter((v): v is number => v !== null);
  // The day's lowest and highest readings, not the range of the hourly averages (as on Vitals).
  const upTo = (l?: (number | null)[]) => (through === null ? [] : l?.slice(0, through + 1));
  const range = extent(upTo(hr?.min), upTo(hr?.max)) ?? extent(readings);
  const last = isToday ? (day?.asOf ?? null) : null;
  const latest = last !== null ? hours[last] : null;
  return (
    <section className="card metric heart-today">
      <CardHead title={isToday ? 'Heart rate today' : 'Heart rate'} to="#/vitals" />
      {hr && readings.length > 1 ? (
        <>
          <div className="metric-value-row">
            <div className="metric-value">
              {fmt(latest ?? Math.round(mean(readings)!))}
              <small>{latest !== null ? `bpm, ${String(last).padStart(2, '0')}:00–${String(last! + 1).padStart(2, '0')}:00` : 'bpm, average for the day'}</small>
            </div>
            {range && (
              <span className="metric-status">
                {fmt(range[0])}–{fmt(range[1])} bpm {isToday ? 'so far' : 'that day'}
              </span>
            )}
          </div>
          <AreaCurve hours={hours} typical={hr.typical} marker={last} format={(v) => fmt(v)} label={`Heart rate by the hour, ${isToday ? 'today' : day!.date}`} />
          <div className="metric-foot">
            <span className="legend-item">
              <i className="legend-key dash" /> Your typical hour, last 30 days
            </span>
          </div>
        </>
      ) : (
        <NoData text={day && !hr ? 'Heart rate by the hour comes from Apple Watch, through the healthOS iPhone app.' : 'No heart rate readings on this day.'} />
      )}
    </section>
  );
}

type Row = { key: string; icon: IconName; label: string; value: string; status: string | null; points: Point[]; to: string; color: string };

function BodyMetricsCard({ s, t }: { s: Summary; t: Trends }) {
  const units = useUnits();
  const rows: Row[] = [];
  const tv = s.vitals.temp;
  const tm = TEMP_METRIC[tv.label] ?? 'body_temp';
  if (tv.latest) {
    const pts = t[tm] ?? [];
    // A watch or band reads the skin, so its number means little alone: show the difference from your usual.
    // The 30 days before the latest reading, with seven nights at least: the same window and minimum as its status.
    const prior = pts.filter((p) => p.date < tv.latest!.date && p.date >= shiftDate(tv.latest!.date, -30)).map((p) => p.value);
    const base = tm === 'body_temp' || prior.length < 7 ? null : mean(prior);
    const f = (c: number) => temp(c, units);
    const delta = base !== null ? (tv.latest.value - base) * (units === 'imperial' ? 9 / 5 : 1) : null;
    rows.push({
      key: 'temp',
      icon: 'sun',
      label: tv.label === 'Body temp' ? 'Body temperature' : `${tv.label === 'Wrist temp' ? 'Wrist' : 'Skin'} temperature`,
      value: delta !== null ? `${Math.abs(delta) < 0.05 ? '±' : delta > 0 ? '+' : '−'}${fmt(Math.abs(delta), 1)} ${f(0).unit}` : `${fmt(f(tv.latest.value).value, 1)} ${f(0).unit}`,
      status: tv.status ? STATUS[tv.status] : delta !== null ? 'Against your usual' : tm === 'body_temp' ? null : 'Building your baseline',
      points: pts,
      to: bodyHref('temperature'),
      color: 'var(--series-3)',
    });
  }
  const br = s.vitals.breathing;
  if (br.latest)
    rows.push({ key: 'resp', icon: 'vitals', label: 'Respiratory rate', value: `${fmt(br.latest.value, 1)} rpm`, status: br.status ? STATUS[br.status] : null, points: t.resp_rate ?? [], to: bodyHref('cardiovascular'), color: 'var(--series-1)' });
  if (s.spo2.latest)
    rows.push({
      key: 'spo2',
      icon: 'heart',
      label: 'Blood oxygen',
      value: `${fmt(s.spo2.latest.value, s.spo2.latest.value % 1 ? 1 : 0)}%`,
      status: s.spo2.status === 'low' ? 'Below your range' : s.spo2.status ? 'Normal' : null,
      points: s.spo2.series,
      to: bodyHref('cardiovascular'),
      color: 'var(--series-2)',
    });
  if (s.hrv.latest)
    rows.push({
      key: 'hrv',
      icon: 'trend-up',
      label: 'Heart rate variability',
      value: `${fmt(s.hrv.latest.value)} ms`,
      status: s.hrv.status ? HRV_STATUS[s.hrv.status] : null,
      points: s.hrv.series,
      to: bodyHref('recovery'),
      color: 'var(--series-1)',
    });
  return (
    <section className="card metric body-metrics">
      <CardHead title="Body metrics" to={bodyHref('cardiovascular')} />
      {rows.length === 0 && <NoData text="Overnight readings appear here once WHOOP or Apple Watch has a night." />}
      <ul>
        {rows.map((r) => (
          <li key={r.key}>
            <a href={r.to}>
              <span className="insight-icon tone-neutral">
                <Icon name={r.icon} size={16} />
              </span>
              <span className="body-metric-label">{r.label}</span>
              <span className="body-metric-value">
                <b>{r.value}</b>
                {r.status && <small>{r.status}</small>}
              </span>
              <span className="body-metric-spark">
                {r.points.length > 1 && <MiniLine points={r.points.slice(-14)} format={() => ''} color={r.color} height={28} label={`${r.label}, last two weeks`} />}
              </span>
              <Icon name="chevron-right" size={16} />
            </a>
          </li>
        ))}
      </ul>
    </section>
  );
}

/** Hours to draw: from 6:00 (or the first reading, if earlier) to the last hour of the day. */
const firstHour = (hours: (number | null)[]) => Math.min(6, Math.max(0, hours.findIndex((v) => v !== null && v > 0)));

function EnergyCard({ day, points, date }: { day: DayData | undefined; points: Point[]; date: string }) {
  const e = day?.metrics.active_energy;
  const through = day ? drawThrough(day.date, day.today, day.asOf) : null;
  const hours = e ? e.hours.map((v, h) => (through !== null && h <= through ? v : null)) : [];
  const total = hours.reduce<number>((a, v) => a + (v ?? 0), 0);
  const daily = points.find((p) => p.date === date);
  return (
    <section className="card metric">
      <CardHead title="Energy burned" to={bodyHref('strain')} />
      {e && total > 0 ? (
        <>
          <div className="metric-value">
            {fmt(total)}
            <small>active kcal{day && day.date === day.today ? ' so far' : ''}</small>
          </div>
          <HourBars hours={hours} from={firstHour(hours)} format={(v) => `${fmt(v)} kcal`} tone="orange" accent={day && day.date === day.today ? day.asOf : null} label="Active energy by the hour" />
        </>
      ) : daily ? (
        <>
          <div className="metric-value">
            {fmt(daily.value)}
            <small>active kcal</small>
          </div>
          <NoData text="No hourly readings for this day." />
        </>
      ) : (
        <NoData text="No active energy recorded on this day." />
      )}
    </section>
  );
}

function StepsCard({ day, s }: { day: DayData | undefined; s: Summary }) {
  const st = day?.metrics.steps;
  const through = day ? drawThrough(day.date, day.today, day.asOf) : null;
  const hours = st ? st.hours.map((v, h) => (through !== null && h <= through ? v : null)) : [];
  const run = st ? cumulative(st.hours, through) : [];
  const counted = through !== null ? (run[through] ?? 0) : 0;
  const whoop = st?.total?.source === 'whoop' && st.total.value > counted;
  const value = st?.total ? Math.max(st.total.value, counted) : counted || (s.activity.latest?.date === s.date ? s.activity.latest.value : 0);
  const typical = through !== null ? st?.typical[through] : null;
  const isToday = day ? day.date === day.today : true;
  return (
    <section className="card metric">
      <div className="metric-head">
        <span>Activity level</span>
        <span className="metric-head-tools">
          <Change pct={typical ? ((counted - typical) / typical) * 100 : null} better="up" title={isToday ? 'Against your typical count by this hour' : 'Against your typical day'} />
          <a href={bodyHref('activity')} className="metric-link" aria-label="Open activity">
            <Icon name="arrow-up-right" size={16} />
          </a>
        </span>
      </div>
      {value > 0 ? (
        <>
          <div className="metric-value">
            {fmt(value)}
            <small>
              steps{isToday ? ' so far' : ''} · goal {compact(s.stepGoal)}
            </small>
          </div>
          {counted > 0 && <HourBars hours={hours} from={firstHour(hours)} format={(v) => `${fmt(v)} steps`} tone="green" accent={isToday ? day!.asOf : null} label="Steps by the hour" />}
          {whoop && <p className="card-note">The day's count is WHOOP's; the hours are from your iPhone or Apple Watch ({fmt(counted)}).</p>}
        </>
      ) : (
        <NoData text="No steps recorded on this day." />
      )}
    </section>
  );
}

// ---------- tabs that are trends over a range ----------

type Spec = { key: string; title: string; format: (v: number, u: ReturnType<typeof useUnits>) => string; tick?: (v: number, u: ReturnType<typeof useUnits>) => string; note?: string; color?: string; zero?: boolean; always?: boolean };

const tempF = (c: number, u: ReturnType<typeof useUnits>) => `${fmt(temp(c, u).value, 1)} ${temp(c, u).unit}`;
const tempTick = (c: number, u: ReturnType<typeof useUnits>) => fmt(temp(c, u).value, 1);

const TREND_TABS: Record<string, Spec[]> = {
  recovery: [
    { key: 'recovery', title: 'Recovery', format: (v) => `${fmt(v)}%`, note: 'WHOOP', color: 'var(--series-3)' },
    { key: 'hrv_rmssd', title: 'HRV (RMSSD)', format: (v) => `${fmt(v)} ms`, tick: (v) => fmt(v), note: 'WHOOP, during sleep' },
    { key: 'hrv_sdnn', title: 'HRV (SDNN)', format: (v) => `${fmt(v)} ms`, tick: (v) => fmt(v), note: 'Apple Watch' },
    { key: 'resting_hr', title: 'Resting heart rate', format: (v) => `${fmt(v)} bpm`, tick: (v) => fmt(v), color: 'var(--series-2)', always: true },
  ],
  strain: [
    { key: 'strain', title: 'Day strain', format: (v) => fmt(v, 1), note: 'WHOOP, 0–21', color: 'var(--series-2)', zero: true },
    { key: 'active_energy', title: 'Active energy', format: (v) => `${fmt(v)} kcal`, tick: compact, color: 'var(--series-2)', zero: true, always: true },
    { key: 'exercise_min', title: 'Exercise minutes', format: (v) => `${fmt(v)} min`, tick: (v) => fmt(v), color: 'var(--series-3)', zero: true },
  ],
  temperature: [
    { key: 'body_temp', title: 'Body temperature', format: tempF, tick: tempTick },
    { key: 'wrist_temp', title: 'Wrist temperature', format: tempF, tick: tempTick, note: 'Apple Watch, during sleep' },
    { key: 'skin_temp', title: 'Skin temperature', format: tempF, tick: tempTick, note: 'WHOOP' },
  ],
  cardiovascular: [
    { key: 'resting_hr', title: 'Resting heart rate', format: (v) => `${fmt(v)} bpm`, tick: (v) => fmt(v), color: 'var(--series-2)', always: true },
    { key: 'hrv_rmssd', title: 'HRV (RMSSD)', format: (v) => `${fmt(v)} ms`, tick: (v) => fmt(v), note: 'WHOOP, during sleep' },
    { key: 'hrv_sdnn', title: 'HRV (SDNN)', format: (v) => `${fmt(v)} ms`, tick: (v) => fmt(v), note: 'Apple Watch' },
    { key: 'spo2', title: 'Blood oxygen', format: (v) => `${fmt(v, 1)}%`, tick: (v) => fmt(v), color: 'var(--series-2)', always: true },
    { key: 'resp_rate', title: 'Respiratory rate', format: (v) => `${fmt(v, 1)} rpm`, tick: (v) => fmt(v, 1), always: true },
    { key: 'vo2max', title: 'Cardio fitness (VO₂ max)', format: (v) => fmt(v, 1), note: 'mL/kg·min', color: 'var(--series-3)' },
  ],
};

function TrendTab({ tabs, specs }: { tabs: ReactNode; specs: Spec[] }) {
  const [range, setDays] = useRange();
  const days = range === DAY ? 30 : range;
  const units = useUnits();
  const { data, loading } = useApi<Trends>(`/trends?metrics=${specs.map((x) => x.key).join(',')}&days=${days}`);
  const t = data ?? {};
  const shown = specs.filter((x) => x.always || (t[x.key]?.length ?? 0) > 0);
  return (
    <div className={`page ${loading ? 'is-refreshing' : ''}`}>
      <PageHead title={TITLE} sub={SUB} tabs={tabs} days={days} setDays={setDays} />
      {data && shown.length === 0 && (
        <section className="card">
          <p className="muted">Nothing recorded in this range.</p>
        </section>
      )}
      <div className="grid-2">
        {shown.map((x) => (
          <Trend
            key={x.key}
            title={x.title}
            points={t[x.key] ?? []}
            format={(v) => x.format(v, units)}
            tickFormat={x.tick ? (v) => x.tick!(v, units) : undefined}
            unitNote={x.note}
            color={x.color}
            zero={x.zero}
          />
        ))}
      </div>
    </div>
  );
}
