import { type ReactNode, useId, useState } from 'react';
import type { DayData, DaySeries, Point, Status, Summary, Trends, Workout } from '../../shared/types.ts';
import { BarChart, ChartCard, Legend, type StackSeries, type TickFormat, TrendChart } from '../charts/Charts.tsx';
import { DayChart } from '../charts/Day.tsx';
import { stepDigits } from '../charts/core.tsx';
import { cumulative, drawThrough, extent, hourLabel, hourSpan, lastReading } from '../charts/day.ts';
import { HrvCard, RecoveryCard, RespRateCard, RestingHrCard, Spo2Card, signalCount } from '../components/home/Signals.tsx';
import { Icon } from '../components/Icon.tsx';
import { ManageSources, PageIntro } from '../components/PageIntro.tsx';
import { compact, distance, duration, fmt, fmtDate, mass, relativeDay, shiftDate, temp, useApi, useUnits } from '../lib.ts';
import '../styles/home.css';

export const RANGES = [
  { days: 7, label: '7 days' },
  { days: 30, label: '30 days' },
  { days: 90, label: '90 days' },
  { days: 365, label: '1 year' },
];

/** The Day view's value in the shared range setting. Pages without a Day view treat it as 30 days. */
export const DAY = 1;
export const DAY_RANGE = { days: DAY, label: 'Day' };

export function useRange() {
  const [days, setDays] = useState(() => Number(sessionStorageGet('healthos-range')) || 30);
  const set = (d: number) => {
    setDays(d);
    try {
      sessionStorage.setItem('healthos-range', String(d));
    } catch {
      // Storage can be unavailable (private windows); the range just won't persist.
    }
  };
  return [days, set] as const;
}

function sessionStorageGet(key: string) {
  try {
    return sessionStorage.getItem(key);
  } catch {
    return null;
  }
}

/** The range picker (7 days to a year, and Day once hourly data exists). */
export function RangeFilters({ days, setDays, ranges = RANGES }: { days?: number; setDays: (d: number) => void; ranges?: { days: number; label: string }[] }) {
  return (
    <div className="filters" role="group" aria-label="Date range">
      {ranges.map((r) => (
        <button key={r.days} className={days === r.days ? 'on' : ''} aria-pressed={days === r.days} onClick={() => setDays(r.days)}>
          {r.label}
        </button>
      ))}
    </div>
  );
}

/**
 * What goes in a PageIntro's slot on the health pages: the page's tabs, and its tools (a day picker, a range) on the
 * right, in a row that keeps its height whichever a tab has (.page-head-tools' min-height).
 */
export function IntroTools({
  tabs,
  tools,
  days,
  setDays,
  ranges = RANGES,
}: {
  tabs?: ReactNode;
  tools?: ReactNode;
  days?: number;
  setDays?: (d: number) => void;
  ranges?: { days: number; label: string }[];
}) {
  return (
    <>
      {tabs}
      <div className="page-head-tools">
        {tools}
        {setDays && <RangeFilters days={days} setDays={setDays} ranges={ranges} />}
      </div>
    </>
  );
}

/** A page's tabs: links, so each tab has its own address (#/sleep?tab=stages) and the back button works. */
export function Tabs({ tabs, current, hrefOf, label, center }: { tabs: { id: string; label: string }[]; current: string; hrefOf: (id: string) => string; label: string; center?: boolean }) {
  return (
    <nav className={center ? 'tabs tabs-center' : 'tabs'} aria-label={label}>
      {tabs.map((t) => (
        <a key={t.id} href={hrefOf(t.id)} className={t.id === current ? 'on' : ''} aria-current={t.id === current ? 'page' : undefined}>
          {t.label}
        </a>
      ))}
    </nav>
  );
}

// ---------- Day view ----------

/**
 * One day of these metrics, hour by hour, from GET /api/day. The Day option exists only once that endpoint
 * answers with at least one of them, so it stays hidden until hourly data is being collected.
 */
export function useDay(range: number, metrics: string) {
  const [date, setDate] = useState<string | null>(null);
  const { data, error, loading } = useApi<DayData>(`/day?metrics=${metrics}${date ? `&date=${date}` : ''}`);
  const available = !!data && Object.keys(data.metrics ?? {}).length > 0;
  const settled = data !== undefined || error !== undefined;
  // 'pending' holds the page briefly when Day was picked earlier and availability isn't known yet.
  const mode: 'day' | 'range' | 'pending' = range !== DAY ? 'range' : available ? 'day' : settled ? 'range' : 'pending';
  return { data, available, loading, date, setDate, mode };
}

/** Previous and next day; null is today. */
export function DayNav({ today, date, setDate, label = (d) => relativeDay(d, today) }: { today: string; date: string | null; setDate: (d: string | null) => void; label?: (d: string) => string }) {
  const current = date ?? today;
  const next = shiftDate(current, 1);
  return (
    <div className="date-nav">
      <span>{label(current)}</span>
      <button className="icon-btn" onClick={() => setDate(shiftDate(current, -1))} aria-label="Previous day">
        <Icon name="chevron-left" size={16} />
      </button>
      <button className="icon-btn" onClick={() => setDate(next >= today ? null : next)} disabled={current >= today} aria-label="Next day">
        <Icon name="chevron-right" size={16} />
      </button>
    </div>
  );
}

function DayCard({
  title,
  kind,
  series,
  data,
  format,
  tickFormat = format,
  color,
  goal,
}: {
  title: string;
  kind: 'running' | 'hourly';
  series: DaySeries;
  data: DayData;
  format: (v: number) => string;
  tickFormat?: TickFormat;
  color: string;
  goal?: { value: number; label: string };
}) {
  const through = drawThrough(data.date, data.today, data.asOf);
  const isToday = data.date === data.today;
  const dayLabel = isToday ? 'Today' : fmtDate(data.date, { weekday: 'short', month: 'short', day: 'numeric' });
  const run = cumulative(series.hours, through);
  let value = '—';
  let note = 'No readings on this day';
  if (through !== null && kind === 'running') {
    const typical = series.typical[through];
    value = format(run[through]!);
    note = `${isToday ? `by ${hourLabel(through + 1)}` : 'whole day'}${typical !== null ? ` · typical ${isToday ? 'by now ' : ''}${format(typical)}` : ''}`;
    // WHOOP counted clearly more than the phone or Watch did: that's the day's figure, as on Home; the hours
    // (WHOOP has none) are the phone's or Watch's share of it.
    if (series.total?.source === 'whoop' && series.total.value > (run[through] ?? 0)) {
      value = format(series.total.value);
      note = `${isToday ? 'so far' : 'whole day'}, from WHOOP · hourly line from iPhone or Apple Watch (${format(run[through]!)})`;
    }
  } else if (through !== null) {
    const h = lastReading(series.hours, through);
    const upTo = (l?: (number | null)[]) => l?.slice(0, through + 1);
    const range = extent(upTo(series.min), upTo(series.max)) ?? extent(upTo(series.hours));
    if (h !== null) {
      value = format(series.hours[h]!);
      note = `${hourSpan(h)} average${range ? ` · ${isToday ? 'today' : 'that day'} ${tickFormat(range[0])}–${format(range[1])}` : ''}`;
    }
  } else if (kind === 'running' && series.total) {
    // No hours for this day (the phone didn't sync it), but the day has a count, as Home shows it.
    value = format(series.total.value);
    note = `${isToday ? 'so far' : 'whole day'}${series.total.source === 'whoop' ? ', from WHOOP' : ''} · no hourly readings`;
  }
  const hours = through === null ? [] : Array.from({ length: through + 1 }, (_, h) => h);
  const cell = (v: number | null | undefined) => (v === null || v === undefined ? '—' : format(v));
  const table =
    kind === 'running'
      ? { columns: ['Hour', title, 'So far', 'Typical by then'], rows: hours.map((h) => [hourSpan(h), format(series.hours[h] ?? 0), cell(run[h]), cell(series.typical[h])]) }
      : { columns: ['Hour', 'Average', 'Low', 'High', 'Typical'], rows: hours.map((h) => [hourSpan(h), cell(series.hours[h]), cell(series.min?.[h]), cell(series.max?.[h]), cell(series.typical[h])]) };

  return (
    <ChartCard
      title={title}
      value={value}
      note={note}
      legend={
        <Legend
          kind="line"
          items={[
            { label: dayLabel, color },
            { label: 'Typical (median of the last 30 days)', color: 'var(--ink-2)', dashed: true },
          ]}
        />
      }
      table={table}
    >
      <DayChart kind={kind} series={series} through={through} format={format} tickFormat={tickFormat} color={color} goal={goal} label={`${title} by hour, ${dayLabel}`} />
    </ChartCard>
  );
}

export const avg = (ps: Point[]) => (ps.length ? ps.reduce((a, p) => a + p.value, 0) / ps.length : null);

/** Over long ranges, daily bars get too thin to read; average them by week instead. */
export function weekly(ps: Point[], days: number): Point[] {
  if (days <= 90) return ps;
  const out = new Map<string, number[]>();
  for (const p of ps) {
    const d = new Date(`${p.date}T00:00:00Z`);
    d.setUTCDate(d.getUTCDate() - ((d.getUTCDay() + 6) % 7));
    const k = d.toISOString().slice(0, 10);
    out.set(k, [...(out.get(k) ?? []), p.value]);
  }
  return [...out].map(([date, vs]) => ({ date, value: vs.reduce((a, b) => a + b, 0) / vs.length }));
}

export const weekLabel = (d: string) => `Week of ${fmtDate(d, { month: 'short', day: 'numeric' })}`;

export function Trend({
  title,
  points,
  format,
  tickFormat,
  unitNote,
  color,
  zero,
}: {
  title: string;
  points: Point[];
  format: (v: number) => string;
  tickFormat?: TickFormat;
  unitNote?: string;
  color?: string;
  zero?: boolean;
}) {
  const a = avg(points);
  const last = points.at(-1);
  return (
    <ChartCard
      title={title}
      value={last ? format(last.value) : '—'}
      note={
        last ? (
          <>
            {fmtDate(last.date)}
            {a !== null && ` · average ${format(a)}`}
            {unitNote && ` · ${unitNote}`}
          </>
        ) : (
          'No data in this range'
        )
      }
      table={{ columns: ['Date', title], rows: points.map((p) => [fmtDate(p.date, { year: 'numeric', month: 'short', day: 'numeric' }), format(p.value)]) }}
    >
      <TrendChart points={points} format={format} tickFormat={tickFormat} color={color} zero={zero} label={`${title} trend`} />
    </ChartCard>
  );
}

// ---------- Vitals ----------

/** Axis labels with as many decimals as the chart's tick step needs (stepDigits); `least` is the fewest shown. */
const stepTicks =
  (least = 0): TickFormat =>
  (v, step) =>
    fmt(v, Math.max(least, stepDigits(step)));

/**
 * Who measures HRV as RMSSD, for its trend's note: WHOOP, and Fitbit when its export had it (status.fitbit). WHOOP's
 * alone when neither is known yet, as before.
 */
function rmssdNote(status: Status | undefined) {
  const by = [status?.whoop.connected && 'WHOOP', status?.fitbit?.lastImport?.metrics.includes('hrv_rmssd') && 'Fitbit'].filter(Boolean);
  return `${by.length ? by.join(' or ') : 'WHOOP'}, during sleep`;
}

/**
 * Your five signals as cards (from the summary Home already loaded), then their trends: a range, or a day of heart rate
 * by the hour, once there's anything to chart. With nothing at all yet, only the cards, in the design's empty state.
 */
export function Vitals() {
  const [range, setRange] = useRange();
  const days = range === DAY ? 30 : range;
  const day = useDay(range, 'heart_rate');
  const units = useUnits();
  const trendsId = useId();
  const { data: s, error: summaryError } = useApi<Summary>('/summary');
  const { data: status } = useApi<Status>('/status');
  // Anything ever sent, not only the five signals' latest: their lookbacks can miss older data a year's trend shows.
  // Without the summary (it failed), the trends still show what they have.
  const charted = s ? !!s.latestDataDate : !!summaryError;
  const { data, loading } = useApi<Trends>(
    charted && day.mode === 'range' ? `/trends?metrics=resting_hr,hrv_rmssd,hrv_sdnn,spo2,resp_rate,wrist_temp,skin_temp,body_temp,recovery&days=${days}` : null,
  );
  const t = data ?? {};
  const has = (m: string) => (t[m]?.length ?? 0) > 0;
  const tf = (c: number) => `${fmt(temp(c, units).value, 1)} ${temp(c, units).unit}`;
  const d = day.mode === 'day' ? day.data : undefined;
  const n = s ? signalCount(s) : null;

  return (
    <div className={`page page-wide vitals-page ${loading || (charted && day.mode !== 'range' && day.loading) ? 'is-refreshing' : ''}`}>
      <PageIntro
        title="A closer look at your signals."
        sub={n === null ? 'Overnight readings from your connected sources.' : `${n} available measurement${n === 1 ? '' : 's'} from your connected sources.`}
        actions={<ManageSources />}
      />
      {!s && summaryError && <p className="page-message">Couldn't load your latest readings: {summaryError.message}</p>}
      {s && (
        <div className="vitals-signals">
          <RestingHrCard s={s} variant="compact" />
          <Spo2Card s={s} variant="compact" />
          <HrvCard s={s} variant="compact" />
          <RecoveryCard s={s} variant="compact" />
          <RespRateCard s={s} variant="compact" />
        </div>
      )}
      {charted && (
        <section className="vitals-trends" aria-labelledby={trendsId}>
          <div className="vitals-trends-head">
            <h2 id={trendsId}>Your trends</h2>
            <IntroTools
              days={day.mode === 'range' ? days : DAY}
              setDays={setRange}
              ranges={day.available ? [DAY_RANGE, ...RANGES] : RANGES}
              tools={d && <DayNav today={d.today} date={day.date} setDate={day.setDate} />}
            />
          </div>
          {d && (
            <div className="grid-1">
              {d.metrics.heart_rate && (
                <DayCard title="Heart rate" kind="hourly" series={d.metrics.heart_rate} data={d} format={(v) => `${fmt(v)} bpm`} tickFormat={(v) => fmt(v)} color="var(--series-2)" />
              )}
              <p className="day-footnote">Recovery, HRV, blood oxygen, breathing and temperature are measured once a night. Pick a range to see them.</p>
            </div>
          )}
          {day.mode === 'range' && (
            <div className="grid-2">
              {has('recovery') && <Trend title="Recovery" points={t.recovery} format={(v) => `${fmt(v)}%`} color="var(--series-3)" />}
              <Trend title="Resting heart rate" points={t.resting_hr ?? []} format={(v) => `${fmt(v)} bpm`} tickFormat={stepTicks()} color="var(--series-2)" />
              {(has('hrv_rmssd') || !has('hrv_sdnn')) && (
                <Trend title="HRV (RMSSD)" points={t.hrv_rmssd ?? []} format={(v) => `${fmt(v)} ms`} tickFormat={stepTicks()} unitNote={rmssdNote(status)} />
              )}
              {has('hrv_sdnn') && <Trend title="HRV (SDNN)" points={t.hrv_sdnn} format={(v) => `${fmt(v)} ms`} tickFormat={stepTicks()} unitNote="Apple Watch" />}
              <Trend title="Blood oxygen" points={t.spo2 ?? []} format={(v) => `${fmt(v, 1)}%`} tickFormat={stepTicks()} color="var(--series-2)" />
              <Trend title="Respiratory rate" points={t.resp_rate ?? []} format={(v) => `${fmt(v, 1)} rpm`} tickFormat={stepTicks(1)} />
              {has('body_temp') && <Trend title="Body temperature" points={t.body_temp} format={tf} tickFormat={(v) => fmt(temp(v, units).value, 1)} />}
              {has('wrist_temp') && <Trend title="Wrist temperature" points={t.wrist_temp} format={tf} tickFormat={(v) => fmt(temp(v, units).value, 1)} unitNote="Apple Watch, during sleep" />}
              {has('skin_temp') && <Trend title="Skin temperature" points={t.skin_temp} format={tf} tickFormat={(v) => fmt(temp(v, units).value, 1)} unitNote="WHOOP" />}
            </div>
          )}
        </section>
      )}
    </div>
  );
}

// ---------- Sleep ----------

export const STAGES: StackSeries[] = [
  { key: 'sleep_deep', label: 'Deep', color: 'var(--stage-deep)' },
  { key: 'sleep_light', label: 'Light / core', color: 'var(--stage-light)' },
  { key: 'sleep_rem', label: 'REM', color: 'var(--stage-rem)' },
  { key: 'sleep_awake', label: 'Awake', color: 'var(--stage-awake)' },
];

// ---------- Activity ----------

/** Steps, energy, strain and workouts. The Body page shows it as its Activity tab, under its own title and tabs. */
export function Activity({ stepGoal, title, sub = 'Movement from your iPhone and Apple Watch, strain from WHOOP.', tabs }: { stepGoal: number; title?: string; sub?: string; tabs?: ReactNode }) {
  const [range, setRange] = useRange();
  const days = range === DAY ? 30 : range;
  const day = useDay(range, 'steps,active_energy');
  const units = useUnits();
  const inRange = day.mode === 'range';
  const { data, loading } = useApi<Trends>(inRange ? `/trends?metrics=steps,strain,active_energy,exercise_min&days=${days}` : null);
  const { data: ws } = useApi<Workout[]>(inRange ? `/workouts?days=${days}` : null);
  const t = data ?? {};
  const steps = weekly(t.steps ?? [], days);
  const stepsAvg = avg(t.steps ?? []);
  const d = day.mode === 'day' ? day.data : undefined;

  return (
    <div className={`page page-wide ${loading || (day.mode !== 'range' && day.loading) ? 'is-refreshing' : ''}`}>
      <PageIntro title={title} sub={sub}>
        <IntroTools
          tabs={tabs}
          days={inRange ? days : DAY}
          setDays={setRange}
          ranges={day.available ? [DAY_RANGE, ...RANGES] : RANGES}
          tools={d && <DayNav today={d.today} date={day.date} setDate={day.setDate} />}
        />
      </PageIntro>
      {d && (
        <div className="grid-2">
          {d.metrics.steps && (
            <DayCard
              title="Steps"
              kind="running"
              series={d.metrics.steps}
              data={d}
              format={(v) => `${fmt(v)} steps`}
              tickFormat={compact}
              color="var(--series-1)"
              goal={{ value: stepGoal, label: `Goal ${compact(stepGoal)}` }}
            />
          )}
          {d.metrics.active_energy && (
            <DayCard title="Active energy" kind="running" series={d.metrics.active_energy} data={d} format={(v) => `${fmt(v)} kcal`} tickFormat={compact} color="var(--series-2)" />
          )}
        </div>
      )}
      {inRange && (
        <>
          <div className="grid-1">
            <ChartCard
              title={days > 90 ? 'Steps, weekly daily average' : 'Steps'}
              value={stepsAvg !== null ? `${fmt(stepsAvg)} / day` : '—'}
              note={`goal ${fmt(stepGoal)}`}
              table={{ columns: [days > 90 ? 'Week of' : 'Date', 'Steps'], rows: steps.map((p) => [fmtDate(p.date, { year: 'numeric', month: 'short', day: 'numeric' }), fmt(p.value)]) }}
            >
              <BarChart
                points={steps}
                format={(v) => `${fmt(v)} steps`}
                tickFormat={compact}
                goal={{ value: stepGoal, label: `Goal ${compact(stepGoal)}` }}
                label="Steps per day"
                periodLabel={days > 90 ? weekLabel : undefined}
              />
            </ChartCard>
          </div>
          <div className="grid-2">
            {(t.strain?.length ?? 0) > 0 && <Trend title="Day strain" points={t.strain} format={(v) => fmt(v, 1)} unitNote="WHOOP, 0–21" color="var(--series-2)" zero />}
            <Trend title="Active energy" points={t.active_energy ?? []} format={(v) => `${fmt(v)} kcal`} tickFormat={compact} color="var(--series-2)" zero />
            {(t.exercise_min?.length ?? 0) > 0 && <Trend title="Exercise minutes" points={t.exercise_min} format={(v) => `${fmt(v)} min`} tickFormat={(v) => fmt(v)} color="var(--series-3)" zero />}
          </div>
          <section className="card">
            <div className="card-title-row">
              <h2>Workouts</h2>
              <span className="muted">{ws?.length ?? 0} in this range</span>
            </div>
            <div className="table-wrap">
              <table>
                <thead>
                  <tr>
                    <th>Date</th>
                    <th>Workout</th>
                    <th>Duration</th>
                    <th>Energy</th>
                    <th>Distance</th>
                    <th>Avg HR</th>
                    <th>Strain</th>
                    <th>Source</th>
                  </tr>
                </thead>
                <tbody>
                  {(ws ?? []).slice(0, 200).map((w) => {
                    const d = w.distance_m ? distance(w.distance_m, units) : null;
                    return (
                      <tr key={w.id}>
                        <td>{fmtDate(w.date, { month: 'short', day: 'numeric', year: 'numeric' })}</td>
                        <td>{w.sport}</td>
                        <td>{duration(w.duration_min)}</td>
                        <td>{w.energy_kcal ? `${fmt(w.energy_kcal)} kcal` : '—'}</td>
                        <td>{d ? `${fmt(d.value, 2)} ${d.unit}` : '—'}</td>
                        <td>{w.avg_hr ? `${fmt(w.avg_hr)} bpm` : '—'}</td>
                        <td>{w.strain ? fmt(w.strain, 1) : '—'}</td>
                        <td className="muted">{({ apple: 'Apple Health', whoop: 'WHOOP', 'apple+whoop': 'Apple + WHOOP' } as Record<string, string>)[w.source] ?? 'Demo'}</td>
                      </tr>
                    );
                  })}
                  {ws?.length === 0 && (
                    <tr>
                      <td colSpan={8} className="muted">
                        No workouts in this range.
                      </td>
                    </tr>
                  )}
                </tbody>
              </table>
            </div>
          </section>
        </>
      )}
    </div>
  );
}

// ---------- Body ----------

/** Weight and composition: the Body page's Metabolism tab. */
export function Metabolism({ tabs, title, sub = 'Weight and composition from Apple Health; cardio fitness from Apple Watch.' }: { tabs?: ReactNode; title?: string; sub?: string }) {
  const [range, setDays] = useRange();
  const days = range === DAY ? 30 : range;
  const units = useUnits();
  const { data, loading } = useApi<Trends>(`/trends?metrics=weight,body_fat,lean_mass,vo2max&days=${days}`);
  const t = data ?? {};
  const mf = (kg: number) => `${fmt(mass(kg, units).value, 1)} ${mass(kg, units).unit}`;

  return (
    <div className={`page page-wide ${loading ? 'is-refreshing' : ''}`}>
      <PageIntro title={title} sub={sub}>
        <IntroTools tabs={tabs} days={days} setDays={setDays} />
      </PageIntro>
      <div className="grid-2">
        <Trend title="Weight" points={t.weight ?? []} format={mf} tickFormat={(v, step) => fmt(mass(v, units).value, stepDigits(step))} />
        <Trend title="Body fat" points={t.body_fat ?? []} format={(v) => `${fmt(v, 1)}%`} tickFormat={stepTicks()} color="var(--series-2)" />
        <Trend title="Cardio fitness (VO₂ max)" points={t.vo2max ?? []} format={(v) => fmt(v, 1)} unitNote="mL/kg·min" color="var(--series-3)" />
        {(t.lean_mass?.length ?? 0) > 0 && <Trend title="Lean body mass" points={t.lean_mass} format={mf} tickFormat={(v, step) => fmt(mass(v, units).value, stepDigits(step))} />}
      </div>
    </div>
  );
}
