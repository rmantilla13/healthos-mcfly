import { useState } from 'react';
import type { Point, Trends, Workout } from '../../shared/types.ts';
import { BarChart, ChartCard, Legend, StackedBars, TrendChart, type StackSeries } from '../charts/Charts.tsx';
import { compact, distance, duration, fmt, fmtDate, hoursMinutes, mass, temp, useApi, useUnits } from '../lib.ts';

const RANGES = [
  { days: 30, label: '30 days' },
  { days: 90, label: '90 days' },
  { days: 365, label: '1 year' },
];

function useRange() {
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

function PageHead({ title, sub, days, setDays }: { title: string; sub: string; days: number; setDays: (d: number) => void }) {
  return (
    <header className="page-head">
      <div>
        <h1>{title}</h1>
        <p>{sub}</p>
      </div>
      <div className="filters" role="group" aria-label="Date range">
        {RANGES.map((r) => (
          <button key={r.days} className={days === r.days ? 'on' : ''} aria-pressed={days === r.days} onClick={() => setDays(r.days)}>
            {r.label}
          </button>
        ))}
      </div>
    </header>
  );
}

const avg = (ps: Point[]) => (ps.length ? ps.reduce((a, p) => a + p.value, 0) / ps.length : null);

/** Over long ranges, daily bars get too thin to read; average them by week instead. */
function weekly(ps: Point[], days: number): Point[] {
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

const weekLabel = (d: string) => `Week of ${fmtDate(d, { month: 'short', day: 'numeric' })}`;

function Trend({
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
  tickFormat?: (v: number) => string;
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

export function Vitals() {
  const [days, setDays] = useRange();
  const units = useUnits();
  const { data, loading } = useApi<Trends>(`/trends?metrics=resting_hr,hrv_rmssd,hrv_sdnn,spo2,resp_rate,wrist_temp,skin_temp,body_temp,recovery&days=${days}`);
  const t = data ?? {};
  const has = (m: string) => (t[m]?.length ?? 0) > 0;
  const tf = (c: number) => `${fmt(temp(c, units).value, 1)} ${temp(c, units).unit}`;

  return (
    <div className={`page ${loading ? 'is-refreshing' : ''}`}>
      <PageHead title="Vitals" sub="Overnight readings from WHOOP and Apple Watch." days={days} setDays={setDays} />
      <div className="grid-2">
        {has('recovery') && <Trend title="Recovery" points={t.recovery} format={(v) => `${fmt(v)}%`} color="var(--series-3)" />}
        <Trend title="Resting heart rate" points={t.resting_hr ?? []} format={(v) => `${fmt(v)} bpm`} tickFormat={(v) => fmt(v)} color="var(--series-2)" />
        {(has('hrv_rmssd') || !has('hrv_sdnn')) && (
          <Trend title="HRV (RMSSD)" points={t.hrv_rmssd ?? []} format={(v) => `${fmt(v)} ms`} tickFormat={(v) => fmt(v)} unitNote="WHOOP, during sleep" />
        )}
        {has('hrv_sdnn') && <Trend title="HRV (SDNN)" points={t.hrv_sdnn} format={(v) => `${fmt(v)} ms`} tickFormat={(v) => fmt(v)} unitNote="Apple Watch" />}
        <Trend title="Blood oxygen" points={t.spo2 ?? []} format={(v) => `${fmt(v, 1)}%`} tickFormat={(v) => fmt(v)} color="var(--series-2)" />
        <Trend title="Respiratory rate" points={t.resp_rate ?? []} format={(v) => `${fmt(v, 1)} rpm`} tickFormat={(v) => fmt(v, 1)} />
        {has('body_temp') && <Trend title="Body temperature" points={t.body_temp} format={tf} tickFormat={(v) => fmt(temp(v, units).value, 1)} />}
        {has('wrist_temp') && <Trend title="Wrist temperature" points={t.wrist_temp} format={tf} tickFormat={(v) => fmt(temp(v, units).value, 1)} unitNote="Apple Watch, during sleep" />}
        {has('skin_temp') && <Trend title="Skin temperature" points={t.skin_temp} format={tf} tickFormat={(v) => fmt(temp(v, units).value, 1)} unitNote="WHOOP" />}
      </div>
    </div>
  );
}

// ---------- Sleep ----------

const STAGES: StackSeries[] = [
  { key: 'sleep_deep', label: 'Deep', color: 'var(--stage-deep)' },
  { key: 'sleep_light', label: 'Light / core', color: 'var(--stage-light)' },
  { key: 'sleep_rem', label: 'REM', color: 'var(--stage-rem)' },
  { key: 'sleep_awake', label: 'Awake', color: 'var(--stage-awake)' },
];

export function Sleep() {
  const [days, setDays] = useRange();
  const { data, loading } = useApi<Trends>(`/trends?metrics=sleep_hours,sleep_deep,sleep_light,sleep_rem,sleep_awake,sleep_performance,sleep_efficiency&days=${days}`);
  const t = data ?? {};
  const byDate = new Map<string, Record<string, number>>();
  for (const s of STAGES) for (const p of t[s.key] ?? []) byDate.set(p.date, { ...byDate.get(p.date), [s.key]: p.value });
  let rows = [...byDate].sort(([a], [b]) => a.localeCompare(b)).map(([date, values]) => ({ date, values }));
  if (days > 90) {
    const weeks = new Map<string, { n: number; values: Record<string, number> }>();
    for (const r of rows) {
      const k = weekly([{ date: r.date, value: 0 }], days)[0].date;
      const w = weeks.get(k) ?? { n: 0, values: {} };
      w.n++;
      for (const [key, v] of Object.entries(r.values)) w.values[key] = (w.values[key] ?? 0) + v;
      weeks.set(k, w);
    }
    rows = [...weeks].map(([date, w]) => ({ date, values: Object.fromEntries(Object.entries(w.values).map(([k, v]) => [k, v / w.n])) }));
  }
  const hours = t.sleep_hours ?? [];
  const a = avg(hours);

  return (
    <div className={`page ${loading ? 'is-refreshing' : ''}`}>
      <PageHead title="Sleep" sub="Each night is counted on the day you wake up." days={days} setDays={setDays} />
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
          <StackedBars
            rows={rows}
            series={STAGES}
            format={hoursMinutes}
            tickFormat={(v) => `${fmt(v)}h`}
            label="Sleep stages per night"
            periodLabel={days > 90 ? weekLabel : undefined}
          />
        </ChartCard>
      </div>
      <div className="grid-2">
        <Trend title="Time asleep" points={hours} format={hoursMinutes} tickFormat={(v) => `${fmt(v)}h`} />
        {(t.sleep_performance?.length ?? 0) > 0 ? (
          <Trend title="Sleep performance" points={t.sleep_performance} format={(v) => `${fmt(v)}%`} unitNote="WHOOP: sleep vs sleep needed" color="var(--series-3)" />
        ) : (
          <Trend title="Sleep efficiency" points={t.sleep_efficiency ?? []} format={(v) => `${fmt(v)}%`} color="var(--series-3)" />
        )}
      </div>
    </div>
  );
}

// ---------- Activity ----------

export function Activity({ stepGoal }: { stepGoal: number }) {
  const [days, setDays] = useRange();
  const units = useUnits();
  const { data, loading } = useApi<Trends>(`/trends?metrics=steps,strain,active_energy,exercise_min&days=${days}`);
  const { data: ws } = useApi<Workout[]>(`/workouts?days=${days}`);
  const t = data ?? {};
  const steps = weekly(t.steps ?? [], days);
  const stepsAvg = avg(t.steps ?? []);

  return (
    <div className={`page ${loading ? 'is-refreshing' : ''}`}>
      <PageHead title="Activity" sub="Movement from your iPhone and Apple Watch, strain from WHOOP." days={days} setDays={setDays} />
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
    </div>
  );
}

// ---------- Body ----------

export function Body() {
  const [days, setDays] = useRange();
  const units = useUnits();
  const { data, loading } = useApi<Trends>(`/trends?metrics=weight,body_fat,lean_mass,vo2max&days=${days}`);
  const t = data ?? {};
  const mf = (kg: number) => `${fmt(mass(kg, units).value, 1)} ${mass(kg, units).unit}`;

  return (
    <div className={`page ${loading ? 'is-refreshing' : ''}`}>
      <PageHead title="Body" sub="Weight and composition from Apple Health; cardio fitness from Apple Watch." days={days} setDays={setDays} />
      <div className="grid-2">
        <Trend title="Weight" points={t.weight ?? []} format={mf} tickFormat={(v) => fmt(mass(v, units).value)} />
        <Trend title="Body fat" points={t.body_fat ?? []} format={(v) => `${fmt(v, 1)}%`} tickFormat={(v) => fmt(v)} color="var(--series-2)" />
        <Trend title="Cardio fitness (VO₂ max)" points={t.vo2max ?? []} format={(v) => fmt(v, 1)} unitNote="mL/kg·min" color="var(--series-3)" />
        {(t.lean_mass?.length ?? 0) > 0 && <Trend title="Lean body mass" points={t.lean_mass} format={mf} tickFormat={(v) => fmt(mass(v, units).value)} />}
      </div>
    </div>
  );
}
