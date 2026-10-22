// The Body overview's glucose card, from Apple Health's blood glucose. A day's value is the mean of that day's readings
// (server/apple/import.ts and the iPhone app's HealthTypes both average them), so it's called a daily average, and
// it's only placed against the person's own recent days: fasting and after-meal ranges are for single readings taken
// at known times, not for a day's mean. The figures and the status come from the glucose detail sheet's own
// endpoint (GET /api/metric/glucose), so the card and the sheet it opens can't disagree.
import { type MetricSheet, mmolFromMgDl } from '../../../shared/metrics.ts';
import type { Summary } from '../../../shared/types.ts';
import { MiniLine } from '../../charts/Mini.tsx';
import { fmt, fmtDate, useApi } from '../../lib.ts';
import { CardHead } from '../../pages/Home.tsx';

export function GlucoseCard({ s }: { s: Summary; date: string | null }) {
  const { data, error } = useApi<MetricSheet>(`/metric/glucose?range=month&date=${s.date}`);
  const g = data?.key === 'glucose' ? data : undefined;
  const l = g?.latest ?? null;
  return (
    <article className="card metric metric-glucose">
      <CardHead title="Glucose" to="#/body" metric={l ? 'glucose' : undefined} date={s.date} section="Body" />
      {!g ? (
        <p className="metric-empty">{error ? "Couldn't load glucose." : 'Loading…'}</p>
      ) : l ? (
        <>
          <div className="metric-value-row">
            <div className="metric-value">
              {fmt(l.value)}
              <small>mg/dL</small>
            </div>
            <span className="metric-status">{g.status ? g.status.text : 'Building your baseline'}</span>
          </div>
          <span className="glucose-alt">{fmt(mmolFromMgDl(l.value), 1)} mmol/L</span>
          {g.points.length > 1 && <MiniLine points={g.points} format={(v) => `${fmt(v)} mg/dL`} color="var(--series-3)" height={44} label="Glucose, daily averages over the last 30 days" />}
          <div className="metric-foot">
            <span className="metric-strong">Daily average</span>
            <span>{l.date === s.today ? 'Today' : fmtDate(l.date, { month: 'short', day: 'numeric', year: l.date.slice(0, 4) === s.today.slice(0, 4) ? undefined : 'numeric' })}</span>
          </div>
        </>
      ) : (
        <p className="metric-empty">Glucose appears when a CGM or meter writes to Apple Health.</p>
      )}
    </article>
  );
}
