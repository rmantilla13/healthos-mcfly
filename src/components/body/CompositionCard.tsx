// The Body overview's body composition card: weight, body fat and lean mass from Apple Health (a scale or the Health
// app), each its latest reading and the change from a reading about a month before it, when there's one then. A
// day's value is that day's last reading. Each row opens its own detail sheet.
import { type MetricKey, aboutBefore } from '../../../shared/metrics.ts';
import type { Point, Summary, Trends, Units } from '../../../shared/types.ts';
import { MiniLine } from '../../charts/Mini.tsx';
import { fmt, fmtDate, mass, useApi, useUnits } from '../../lib.ts';
import { CardHead, signed } from '../../pages/Home.tsx';
import { Icon } from '../Icon.tsx';
import { useMetricSheet } from '../MetricSheet.tsx';

const TO = '#/body?tab=metabolism';
/** Long enough to find a weigh-in a month before one that's a few weeks old. */
const DAYS = 120;

type Row = { key: MetricKey; label: string; points: Point[]; unit: string; digits: number };

function rowsOf(t: Trends, units: Units): Row[] {
  const toUnits = (ps: Point[] | undefined) => (ps ?? []).map((p) => ({ date: p.date, value: mass(p.value, units).value }));
  const massUnit = mass(0, units).unit;
  return [
    { key: 'weight' as const, label: 'Weight', points: toUnits(t.weight), unit: massUnit, digits: 1 },
    { key: 'body_fat' as const, label: 'Body fat', points: t.body_fat ?? [], unit: '%', digits: 1 },
    { key: 'lean_mass' as const, label: 'Lean mass', points: toUnits(t.lean_mass), unit: massUnit, digits: 1 },
  ].filter((r) => r.points.length > 0);
}

const show = (r: Row, v: number) => (r.unit === '%' ? `${fmt(v, r.digits)}%` : `${fmt(v, r.digits)} ${r.unit}`);

/** "−0.8 kg since Sep 21", "+0.4 points since Sep 21"; null without a reading about a month before the latest. */
function changeOf(r: Row) {
  const last = r.points.at(-1)!;
  const then = aboutBefore(r.points);
  if (!then) return null;
  const d = last.value - then.value;
  // A change that rounds to nothing has no sign to show.
  if (fmt(Math.abs(d), r.digits) === fmt(0, r.digits)) return { text: `about the same as ${fmtDate(then.date)}`, then };
  const size = r.unit === '%' ? `${signed(d, r.digits)} points` : `${signed(d, r.digits)} ${r.unit}`;
  return { text: `${size} since ${fmtDate(then.date)}`, then };
}

export function CompositionCard({ s }: { s: Summary; date: string | null }) {
  const units = useUnits();
  const { data, error } = useApi<Trends>(`/trends?metrics=weight,body_fat,lean_mass&days=${DAYS}&date=${s.date}`);
  const { open, sheet } = useMetricSheet();
  const rows = data ? rowsOf(data, units) : [];
  const [main, ...rest] = rows;
  const last = main?.points.at(-1);
  const change = main ? changeOf(main) : null;
  return (
    <article className="card metric composition">
      <CardHead title="Body composition" to={TO} metric={main?.key} date={s.date} section="Body" />
      {!data ? (
        <p className="metric-empty">{error ? "Couldn't load body composition." : 'Loading…'}</p>
      ) : main && last ? (
        <>
          <div className="metric-value">
            {fmt(last.value, main.digits)}
            <small>
              {main.label.toLowerCase()}
              {main.unit === '%' ? ', %' : `, ${main.unit}`}
            </small>
          </div>
          {change && <span className="chip chip-neutral">{change.text}</span>}
          {main.points.length > 1 && (
            <MiniLine points={main.points} format={(v) => show(main, v)} color="var(--series-1)" height={40} label={`${main.label}, last ${DAYS} days`} />
          )}
          {rest.length > 0 && (
            <ul className="composition-rows">
              {rest.map((r) => {
                const v = r.points.at(-1)!;
                const c = changeOf(r);
                return (
                  <li key={r.key}>
                    <button type="button" className="composition-row" aria-haspopup="dialog" onClick={(e) => open(r.key, { date: s.date, section: 'Body', to: TO }, e.currentTarget)}>
                      <span className="composition-label">{r.label}</span>
                      <span className="composition-value">
                        <b>{show(r, v.value)}</b>
                        <small>{c ? c.text : fmtDate(v.date)}</small>
                      </span>
                      <Icon name="chevron-right" size={14} />
                    </button>
                  </li>
                );
              })}
            </ul>
          )}
          <div className="metric-foot">
            <span>Latest {fmtDate(last.date)}</span>
            <span>Apple Health</span>
          </div>
        </>
      ) : (
        <p className="metric-empty">Nothing in the last 4 months. Weight and body composition appear when a scale or the Health app records them in Apple Health.</p>
      )}
      {sheet}
    </article>
  );
}
