// The charts and tiles McFly puts in an answer (show_visual in server/mcfly.ts). The server read every number
// from the person's own data; this only draws them, with the dashboard's own charts and a table view for each.
import type { McflyVisual as Visual } from '../../shared/types.ts';
import { BarChart, ChartCard, Legend, StackedBars, TrendChart } from '../charts/Charts.tsx';
import { Change } from '../charts/Neka.tsx';
import { compact, fmt, fmtDate, hoursMinutes } from '../lib.ts';
import { STAGES, weekLabel } from '../pages/Detail.tsx';

/** How a unit's values read: hours as "7h 24m", percentages with "%", small fractional values to one decimal. */
function formats(unit: string, values: number[]) {
  if (unit === 'h') return { format: hoursMinutes, tick: (v: number) => `${fmt(v)}h` };
  const decimals = values.some((v) => Math.abs(v) < 100 && Math.round(v) !== v) ? 1 : 0;
  const suffix = !unit ? '' : unit === '%' ? '%' : ` ${unit}`;
  return {
    format: (v: number) => `${fmt(v, decimals)}${suffix}`,
    tick: (v: number) => (Math.abs(v) >= 10_000 ? compact(v) : fmt(v, Math.abs(v) < 10 ? decimals : 0)),
  };
}

const dayLabel = (d: string) => fmtDate(d, { weekday: 'short', month: 'short', day: 'numeric' });
const longDate = (d: string) => fmtDate(d, { year: 'numeric', month: 'short', day: 'numeric' });

export function McflyVisual({ visual: v }: { visual: Visual }) {
  if (v.kind === 'trend' || v.kind === 'bars') {
    const { format, tick } = formats(v.unit, v.points.map((p) => p.value));
    const weekly = v.resolution !== 'day';
    return (
      <ChartCard
        className="mcfly-visual"
        title={v.title}
        value={v.mean !== null ? format(v.mean) : undefined}
        note={`${weekly ? 'weekly averages · ' : ''}average over ${v.points.length} ${weekly ? 'weeks' : v.points.length === 1 ? 'day' : 'days'}`}
        table={{ columns: [weekly ? 'Week of' : 'Date', v.title], rows: v.points.map((p) => [longDate(p.date), format(p.value)]) }}
      >
        {v.kind === 'bars' ? (
          <BarChart
            points={v.points}
            format={format}
            tickFormat={tick}
            height={180}
            goal={v.goal ? { value: v.goal, label: `Goal ${compact(v.goal)}` } : undefined}
            label={v.title}
            periodLabel={weekly ? weekLabel : undefined}
          />
        ) : (
          <TrendChart points={v.points} format={format} tickFormat={tick} height={180} label={v.title} />
        )}
      </ChartCard>
    );
  }

  if (v.kind === 'compare') {
    const { format } = formats(v.unit, v.periods.map((p) => p.mean ?? 0));
    const max = Math.max(...v.periods.map((p) => Math.abs(p.mean ?? 0)), 1e-9);
    const [a, b] = v.periods;
    const pct = a.mean !== null && b.mean !== null && b.mean !== 0 ? ((a.mean - b.mean) / Math.abs(b.mean)) * 100 : null;
    return (
      <section className="card mcfly-visual mcfly-compare" aria-label={v.title}>
        <header className="mcfly-visual-head">
          <h3>{v.title}</h3>
          <Change pct={pct} title={`${a.label} against ${b.label.toLowerCase()}`} />
        </header>
        <ul>
          {v.periods.map((p, i) => (
            <li key={i}>
              <span className="mcfly-compare-label">
                {p.label}
                <small>
                  {fmtDate(p.from)} – {fmtDate(p.to)} · {p.days} {p.days === 1 ? 'day' : 'days'} with data
                </small>
              </span>
              <span className="mcfly-compare-track">
                <span className={i === 0 ? 'is-first' : ''} style={{ width: `${p.mean === null ? 0 : (Math.abs(p.mean) / max) * 100}%` }} />
              </span>
              <b>{p.mean === null ? 'No data' : format(p.mean)}</b>
            </li>
          ))}
        </ul>
      </section>
    );
  }

  if (v.kind === 'stats') {
    return (
      <section className="card mcfly-visual" aria-label={v.title}>
        <header className="mcfly-visual-head">
          <h3>{v.title}</h3>
        </header>
        <div className="mcfly-stats">
          {v.items.map((it, i) => {
            const { format } = formats(it.unit, it.value === null ? [] : [it.value]);
            return (
              <div key={i}>
                <span>{it.label}</span>
                <b>{it.value === null ? '—' : format(it.value)}</b>
                <small>{/^\d{4}-\d{2}-\d{2}$/.test(it.note) ? dayLabel(it.note) : it.note}</small>
              </div>
            );
          })}
        </div>
      </section>
    );
  }

  if (v.kind === 'stages') {
    return (
      <ChartCard
        className="mcfly-visual"
        title={v.title}
        legend={<Legend items={STAGES.map((s) => ({ label: s.label, color: s.color }))} />}
        table={{
          columns: ['Night', ...STAGES.map((s) => s.label)],
          rows: v.rows.map((r) => [longDate(r.date), ...STAGES.map((s) => hoursMinutes(r.values[s.key] ?? 0))]),
        }}
      >
        <StackedBars rows={v.rows} series={STAGES} format={hoursMinutes} tickFormat={(x) => `${fmt(x)}h`} height={190} label={v.title} />
      </ChartCard>
    );
  }

  // Workouts by type: one bar per sport, by time spent. (Anything else is from a newer server: leave it out.)
  if (v.kind !== 'sports') return null;
  const max = Math.max(...v.items.map((it) => it.minutes), 1);
  return (
    <section className="card mcfly-visual mcfly-sports" aria-label={v.title}>
      <header className="mcfly-visual-head">
        <h3>{v.title}</h3>
      </header>
      <ul>
        {v.items.map((it) => (
          <li key={it.sport}>
            <span className="mcfly-compare-label">
              {it.sport}
              <small>
                {it.count} {it.count === 1 ? 'workout' : 'workouts'}
              </small>
            </span>
            <span className="mcfly-compare-track">
              <span style={{ width: `${(it.minutes / max) * 100}%` }} />
            </span>
            <b>{hoursMinutes(it.minutes / 60)}</b>
          </li>
        ))}
      </ul>
    </section>
  );
}

/** The one line a visual leaves in the conversation McFly reads back next time. */
export const visualNote = (v: Visual) => `[Showed a chart: ${v.title}]`;
