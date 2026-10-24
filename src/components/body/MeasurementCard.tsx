// One of Body's measurement cards: weight, body fat or lean body mass. With a reading: the latest value in the person's
// units, its change since a reading about a month before (when there's one then), the last 120 days, and where it came
// from; its ↗ opens the metric's sheet. Without one: a dash and "Your measurement, when you're ready". Either way,
// "+ Add entry" opens the form. A day's value is that day's last reading, and an entry typed in wins its day.
import { BODY_METRICS, type BodyLatest, type BodyMetric, type BodySource } from '../../../shared/body.ts';
import { aboutBefore } from '../../../shared/metrics.ts';
import type { Point, Units } from '../../../shared/types.ts';
import { MiniLine } from '../../charts/Mini.tsx';
import { fmt, fmtDate, mass, useUnits } from '../../lib.ts';
import { signed } from '../../pages/Home.tsx';
import { Icon } from '../Icon.tsx';
import { MetricSheetLink } from '../MetricSheet.tsx';

/** Body's long-range charts, the sheet's "Open …" link. */
const TO = '#/body?tab=metabolism';
/** Long enough to find a reading a month before one that's a few weeks old. */
export const MEASURE_DAYS = 120;

const TONE: Record<BodyMetric, string> = { weight: 'slate', body_fat: 'peach', lean_mass: 'green' };
export const SOURCE_NAME: Record<BodySource, string> = { manual: 'Added by you', apple: 'Apple Health', whoop: 'WHOOP', fitbit: 'Fitbit', demo: 'Demo data' };

/** A metric's unit as the person reads it: kg or lb by their units, % for body fat. */
export const unitOf = (metric: BodyMetric, units: Units) => (metric === 'body_fat' ? '%' : mass(0, units).unit);
/** A stored value (kg or %) in the person's units. */
export const inUnits = (metric: BodyMetric, value: number, units: Units) => (metric === 'body_fat' ? value : mass(value, units).value);

/** "−0.8 kg since Sep 21", "+0.4 points since Sep 21"; null without a reading about a month before the latest. */
function changeOf(points: Point[], unit: string) {
  const last = points.at(-1)!;
  const then = aboutBefore(points);
  if (!then) return null;
  const d = last.value - then.value;
  // A change that rounds to nothing has no sign to show.
  if (fmt(Math.abs(d), 1) === fmt(0, 1)) return `about the same as ${fmtDate(then.date)}`;
  return `${signed(d, 1)} ${unit === '%' ? 'points' : unit} since ${fmtDate(then.date)}`;
}

export function MeasurementCard({
  metric,
  points: stored,
  latest,
  asOf,
  onAdd,
}: {
  metric: BodyMetric;
  /** The last 120 days, as stored (kg or %). */
  points: Point[];
  /** Where the latest value came from (GET /api/body/latest); undefined while it loads. */
  latest: BodyLatest[BodyMetric] | undefined;
  /** The day the card shows; the sheet's window ends on it. */
  asOf: string;
  onAdd: (opener: HTMLElement) => void;
}) {
  const units = useUnits();
  const label = BODY_METRICS.find((m) => m.metric === metric)!.label;
  const unit = unitOf(metric, units);
  const points = stored.map((p) => ({ date: p.date, value: inUnits(metric, p.value, units) }));
  const last = points.at(-1);
  const show = (v: number) => (unit === '%' ? `${fmt(v, 1)}%` : `${fmt(v, 1)} ${unit}`);
  const change = last ? changeOf(points, unit) : null;
  // The footer names the source only when it's the same day the chart ends on.
  const source = last && latest?.date === last.date ? SOURCE_NAME[latest.source] : null;
  return (
    <article className={`card metric measure-card metric-${TONE[metric]}${last ? '' : ' is-empty'}`}>
      <div className="metric-head">
        <span>{label}</span>
        {last && <MetricSheetLink metric={metric} title={label} date={asOf} section="Body" to={TO} />}
      </div>
      <div className="measure-main">
        <div className="vital-value">
          {last ? <b>{fmt(last.value, 1)}</b> : <b className="vital-dash" role="img" aria-label="No reading" />}
          <small>{unit}</small>
        </div>
        {/* Nothing to compare with yet: the footer's date says enough. */}
        {(change || !last) && <p className="measure-note">{last ? change : "Your measurement, when you're ready"}</p>}
      </div>
      {points.length > 1 && (
        <div className="measure-chart">
          <MiniLine points={points} format={show} color="var(--series-1)" height={36} label={`${label}, last ${MEASURE_DAYS} days`} />
        </div>
      )}
      <div className="measure-foot">
        <button type="button" className="measure-add" aria-haspopup="dialog" onClick={(e) => onAdd(e.currentTarget)}>
          <Icon name="plus" size={13} strokeWidth={1.8} />
          Add entry
          <span className="sr-only"> for {label.toLowerCase()}</span>
        </button>
        {last && (
          <span className="measure-source">
            Latest {fmtDate(last.date)}
            {source && ` · ${source}`}
          </span>
        )}
      </div>
    </article>
  );
}
