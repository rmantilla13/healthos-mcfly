// Full-size charts for the detail pages.
import { type ReactNode, useCallback, useMemo, useState } from 'react';
import type { Point } from '../../shared/types.ts';
import { Icon } from '../components/Icon.tsx';
import { daysBetween, fmtDate } from '../lib.ts';
import { Tooltip, TooltipRow, barPath, median, niceTicks, smoothPath, useScrub, useWidth } from './core.tsx';
import { BarClimb, EndPulse, Flow, type Pulse, stagger, useSvgId } from './motion.tsx';

export const M = { top: 20, right: 14, bottom: 26, left: 44 };

/** Fewer points than this and a "typical" level means little, so no median line is drawn. */
const MEDIAN_MIN_POINTS = 5;

const medianOf = (points: Point[], on: boolean) => (on && points.length >= MEDIAN_MIN_POINTS ? median(points.map((p) => p.value)) : null);

/**
 * A dashed line at the median of what's plotted, so recent days read as above or below the person's own
 * typical level for the range. Labelled at the left end: the latest-value and goal labels sit on the right.
 */
function MedianLine({ y, width }: { y: number; width: number }) {
  return <line x1={M.left} x2={width - M.right} y1={y} y2={y} className="median-line" />;
}

function MedianLabel({ y, text }: { y: number; text: string }) {
  // Above the line, unless that would run into the top of the plot.
  return (
    <text x={M.left + 4} y={y - 6 < M.top ? y + 14 : y - 6} className="median-label">
      Median {text}
    </text>
  );
}

function xLabels(dates: string[], width: number) {
  if (!dates.length) return [];
  const span = daysBetween(dates[0], dates.at(-1)!);
  const count = Math.max(2, Math.min(6, Math.floor(width / 90)));
  const opts: Intl.DateTimeFormatOptions = span > 200 ? { month: 'short', year: '2-digit' } : { month: 'short', day: 'numeric' };
  const out: { i: number; text: string }[] = [];
  for (let k = 0; k < count; k++) {
    const i = Math.round((k / (count - 1)) * (dates.length - 1));
    if (!out.some((o) => o.i === i)) out.push({ i, text: fmtDate(dates[i], opts) });
  }
  return out;
}

export function YAxis({ ticks, yOf, width, format }: { ticks: number[]; yOf: (v: number) => number; width: number; format: (v: number) => string }) {
  return (
    <g>
      {ticks.map((t) => (
        <g key={t}>
          <line x1={M.left} x2={width - M.right} y1={yOf(t)} y2={yOf(t)} className="grid" />
          <text x={M.left - 8} y={yOf(t)} dy="0.32em" textAnchor="end" className="axis-label">
            {format(t)}
          </text>
        </g>
      ))}
    </g>
  );
}

export function TrendChart({
  points,
  format,
  tickFormat = format,
  color = 'var(--series-1)',
  height = 220,
  zero = false,
  refLines = [],
  median: showMedian = true,
  label,
  pulse,
  flow,
  shimmer = false,
}: {
  points: Point[];
  format: (v: number) => string;
  tickFormat?: (v: number) => string;
  color?: string;
  height?: number;
  zero?: boolean;
  refLines?: { value: number; label: string }[];
  median?: boolean;
  label: string;
  /** The latest point's loop (motion.tsx). */
  pulse?: Pulse;
  /** Seconds for a highlight to run along the line, or none. */
  flow?: number;
  /** The area under the line glows slowly in and out (temperature). */
  shimmer?: boolean;
}) {
  const [ref, width] = useWidth<HTMLDivElement>();
  const n = points.length;
  const mid = medianOf(points, showMedian);
  const first = points[0]?.date;
  const span = n ? Math.max(1, daysBetween(first, points.at(-1)!.date)) : 1;
  const xOf = useCallback(
    (i: number) => (n ? M.left + (daysBetween(first, points[i].date) / span) * (width - M.left - M.right) : 0),
    [n, first, span, width, points],
  );
  const values = points.map((p) => p.value).concat(refLines.map((r) => r.value));
  const ticks = niceTicks(zero ? 0 : Math.min(...values), Math.max(...values), 4);
  const lo = ticks[0] ?? 0;
  const hi = ticks.at(-1) ?? 1;
  const yOf = (v: number) => M.top + (1 - (v - lo) / (hi - lo || 1)) * (height - M.top - M.bottom);
  const { index, handlers } = useScrub(n, xOf);

  // Break the line where days are missing, rather than drawing through the gap.
  const segments = useMemo(() => {
    const segs: [number, number][][] = [];
    let cur: [number, number][] = [];
    points.forEach((p, i) => {
      if (i > 0 && daysBetween(points[i - 1].date, p.date) > 3) {
        segs.push(cur);
        cur = [];
      }
      cur.push([xOf(i), yOf(p.value)]);
    });
    if (cur.length) segs.push(cur);
    return segs;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [points, xOf, lo, hi, height]);

  if (!n) return <EmptyChart height={height} />;
  const last = n - 1;
  const baseY = height - M.bottom;

  return (
    <div className="chart" ref={ref} style={{ height }}>
      {width > 0 && (
        <svg width={width} height={height} {...handlers} role="img" aria-label={mid !== null ? `${label}, median ${format(mid)}` : label}>
          <YAxis ticks={ticks} yOf={yOf} width={width} format={tickFormat} />
          <line x1={M.left} x2={width - M.right} y1={baseY} y2={baseY} className="baseline" />
          {mid !== null && <MedianLine y={yOf(mid)} width={width} />}
          {xLabels(points.map((p) => p.date), width).map(({ i, text }) => (
            <text key={i} x={xOf(i)} y={height - 6} textAnchor={i === 0 ? 'start' : i === last ? 'end' : 'middle'} className="axis-label">
              {text}
            </text>
          ))}
          {refLines.map((r) => (
            <g key={r.label}>
              <line x1={M.left} x2={width - M.right} y1={yOf(r.value)} y2={yOf(r.value)} className="ref-line" />
              <text x={width - M.right} y={yOf(r.value) - 6} textAnchor="end" className="axis-label">
                {r.label}
              </text>
            </g>
          ))}
          {/* Keyed by the data, so the line draws itself in again when the range changes, not on every hover. */}
          <g key={drawKey(points)}>
            {segments.map((seg, k) => {
              const d = smoothPath(seg);
              return (
                <g key={k}>
                  {seg.length > 1 && (
                    <path
                      d={`${d} L${seg.at(-1)![0]},${baseY} L${seg[0][0]},${baseY} Z`}
                      fill={color}
                      opacity={0.1}
                      className={`motion fade-in${shimmer ? ' area-shimmer' : ''}`}
                    />
                  )}
                  <path d={d} pathLength={1} fill="none" stroke={color} strokeWidth={2} strokeLinecap="round" strokeLinejoin="round" className="motion draw-in" />
                  {seg.length > 1 && flow && <Flow d={d} seconds={flow} />}
                  {seg.length === 1 && <circle cx={seg[0][0]} cy={seg[0][1]} r={3} fill={color} className="motion pop-in" />}
                </g>
              );
            })}
          </g>
          {mid !== null && <MedianLabel y={yOf(mid)} text={format(mid)} />}
          {index !== null && <line x1={0} x2={0} y1={M.top - 8} y2={baseY} className="crosshair glide" style={{ transform: `translateX(${xOf(index)}px)` }} />}
          <EndPulse x={xOf(last)} y={yOf(points[last].value)} color={color} pulse={pulse} />
          <circle cx={xOf(index ?? last)} cy={yOf(points[index ?? last].value)} r={4.5} fill={color} className="dot-ring motion pop-in after-draw glide" />
          {index === null && (
            <text x={xOf(last)} y={yOf(points[last].value) - 12} textAnchor="end" className="end-label motion fade-in after-draw">
              {format(points[last].value)}
            </text>
          )}
          <rect width={width} height={height} fill="transparent" />
        </svg>
      )}
      {index !== null && (
        <Tooltip x={xOf(index)} y={yOf(points[index].value)} width={width}>
          <TooltipRow color={color} value={format(points[index].value)} label={fmtDate(points[index].date, { weekday: 'short', month: 'short', day: 'numeric', year: 'numeric' })} />
        </Tooltip>
      )}
    </div>
  );
}

export function BarChart({
  points,
  format,
  tickFormat = format,
  height = 220,
  goal,
  median: showMedian = true,
  label,
  periodLabel,
  live = false,
}: {
  points: Point[];
  format: (v: number) => string;
  tickFormat?: (v: number) => string;
  height?: number;
  goal?: { value: number; label: string };
  median?: boolean;
  label: string;
  periodLabel?: (date: string) => string;
  /** The last bar is today's and still counting: a highlight keeps climbing it. */
  live?: boolean;
}) {
  const [ref, width] = useWidth<HTMLDivElement>();
  const n = points.length;
  const mid = medianOf(points, showMedian);
  const plotW = width - M.left - M.right;
  const slot = n ? plotW / n : 0;
  const barW = Math.max(1, Math.min(24, slot - 2));
  const xOf = useCallback((i: number) => M.left + i * slot + slot / 2, [slot]);
  const ticks = niceTicks(0, Math.max(...points.map((p) => p.value), goal?.value ?? 0, 1), 4);
  const hi = ticks.at(-1) ?? 1;
  const yOf = (v: number) => M.top + (1 - v / hi) * (height - M.top - M.bottom);
  const { index, handlers } = useScrub(n, xOf);
  const climbId = useSvgId('climb');
  if (!n) return <EmptyChart height={height} />;
  const baseY = height - M.bottom;
  const dateText = periodLabel ?? ((d: string) => fmtDate(d, { weekday: 'short', month: 'short', day: 'numeric' }));
  const lastY = yOf(points[n - 1].value);

  return (
    <div className="chart" ref={ref} style={{ height }}>
      {width > 0 && (
        <svg width={width} height={height} {...handlers} role="img" aria-label={mid !== null ? `${label}, median ${format(mid)}` : label}>
          <YAxis ticks={ticks} yOf={yOf} width={width} format={tickFormat} />
          {points.map((p, i) => {
            const y = yOf(p.value);
            return (
              <path
                key={p.date}
                d={barPath(xOf(i) - barW / 2, y, barW, baseY - y, Math.min(4, barW / 2))}
                className={`${index === i ? 'bar bar-hover' : i === n - 1 ? 'bar bar-accent' : 'bar'} motion grow-up`}
                style={stagger(i, n)}
              />
            );
          })}
          {live && <BarClimb id={climbId} x={xOf(n - 1) - barW / 2} y={lastY} w={barW} h={baseY - lastY} />}
          <line x1={M.left} x2={width - M.right} y1={baseY} y2={baseY} className="baseline" />
          {goal && (
            <g>
              <line x1={M.left} x2={width - M.right} y1={yOf(goal.value)} y2={yOf(goal.value)} className="ref-line" />
              <text x={width - M.right} y={yOf(goal.value) - 6} textAnchor="end" className="axis-label">
                {goal.label}
              </text>
            </g>
          )}
          {/* Over the bars, so the line isn't hidden behind them. */}
          {mid !== null && (
            <>
              <MedianLine y={yOf(mid)} width={width} />
              <MedianLabel y={yOf(mid)} text={format(mid)} />
            </>
          )}
          {xLabels(points.map((p) => p.date), width).map(({ i, text }) => (
            <text key={i} x={xOf(i)} y={height - 6} textAnchor={i === 0 ? 'start' : i === n - 1 ? 'end' : 'middle'} className="axis-label">
              {text}
            </text>
          ))}
          <rect width={width} height={height} fill="transparent" />
        </svg>
      )}
      {index !== null && (
        <Tooltip x={xOf(index)} y={Math.max(M.top + 20, yOf(points[index].value))} width={width}>
          <TooltipRow color="" kind="none" value={format(points[index].value)} label={dateText(points[index].date)} />
        </Tooltip>
      )}
    </div>
  );
}

export type StackSeries = { key: string; label: string; color: string };

export function StackedBars({
  rows,
  series,
  format,
  tickFormat = format,
  height = 240,
  label,
  periodLabel,
}: {
  rows: { date: string; values: Record<string, number> }[];
  series: StackSeries[];
  format: (v: number) => string;
  tickFormat?: (v: number) => string;
  height?: number;
  label: string;
  periodLabel?: (date: string) => string;
}) {
  const [ref, width] = useWidth<HTMLDivElement>();
  const n = rows.length;
  const plotW = width - M.left - M.right;
  const slot = n ? plotW / n : 0;
  const barW = Math.max(1, Math.min(24, slot - 2));
  const xOf = useCallback((i: number) => M.left + i * slot + slot / 2, [slot]);
  const totals = rows.map((r) => series.reduce((a, s) => a + (r.values[s.key] ?? 0), 0));
  const ticks = niceTicks(0, Math.max(...totals, 1), 4);
  const hi = ticks.at(-1) ?? 1;
  const scale = (height - M.top - M.bottom) / hi;
  const { index, handlers } = useScrub(n, xOf);
  if (!n) return <EmptyChart height={height} />;
  const baseY = height - M.bottom;
  const dateText = periodLabel ?? ((d: string) => fmtDate(d, { weekday: 'short', month: 'short', day: 'numeric' }));
  const gap = barW >= 6 ? 2 : 1;

  return (
    <div className="chart" ref={ref} style={{ height }}>
      {width > 0 && (
        <svg width={width} height={height} {...handlers} role="img" aria-label={label}>
          <YAxis ticks={ticks} yOf={(v) => baseY - v * scale} width={width} format={tickFormat} />
          {rows.map((r, i) => {
            let y = baseY;
            const segs = series.filter((s) => (r.values[s.key] ?? 0) > 0);
            return (
              <g key={r.date} opacity={index === null || index === i ? 1 : 0.55} className="motion grow-up" style={stagger(i, n)}>
                {segs.map((s, k) => {
                  const h = (r.values[s.key] ?? 0) * scale;
                  y -= h;
                  const top = k === segs.length - 1;
                  // A surface-colored gap separates stacked segments; only the top segment gets the rounded end.
                  const hh = Math.max(0, h - (k > 0 ? gap : 0));
                  return top ? (
                    <path key={s.key} d={barPath(xOf(i) - barW / 2, y, barW, hh, Math.min(4, barW / 2))} fill={s.color} />
                  ) : (
                    <rect key={s.key} x={xOf(i) - barW / 2} y={y} width={barW} height={hh} fill={s.color} />
                  );
                })}
              </g>
            );
          })}
          <line x1={M.left} x2={width - M.right} y1={baseY} y2={baseY} className="baseline" />
          {xLabels(rows.map((r) => r.date), width).map(({ i, text }) => (
            <text key={i} x={xOf(i)} y={height - 6} textAnchor={i === 0 ? 'start' : i === n - 1 ? 'end' : 'middle'} className="axis-label">
              {text}
            </text>
          ))}
          <rect width={width} height={height} fill="transparent" />
        </svg>
      )}
      {index !== null && (
        <Tooltip x={xOf(index)} y={baseY - totals[index] * scale + 30} width={width}>
          <div className="tooltip-title">{dateText(rows[index].date)}</div>
          {[...series].reverse().map((s) => (
            <TooltipRow key={s.key} color={s.color} value={format(rows[index].values[s.key] ?? 0)} label={s.label} />
          ))}
          <TooltipRow color="" kind="none" value={format(totals[index])} label="Total" />
        </Tooltip>
      )}
    </div>
  );
}

export function Legend({ items, kind = 'rect' }: { items: { label: string; color: string; dashed?: boolean }[]; kind?: 'rect' | 'line' }) {
  return (
    <div className="legend">
      {items.map((it) => (
        <span key={it.label} className="legend-item">
          <span className={`legend-key ${it.dashed ? 'dash' : kind}`} style={it.dashed ? { color: it.color } : { background: it.color }} />
          {it.label}
        </span>
      ))}
    </div>
  );
}

function EmptyChart({ height }: { height: number }) {
  return (
    <div className="chart chart-empty" style={{ height }}>
      No data in this range
    </div>
  );
}

/** A chart with a table twin: every value is readable without hovering. */
export function ChartCard({
  title,
  value,
  note,
  legend,
  table,
  children,
  className = '',
  motif,
}: {
  title: string;
  value?: ReactNode;
  note?: ReactNode;
  legend?: ReactNode;
  table: { columns: string[]; rows: (string | number)[][] };
  children: ReactNode;
  className?: string;
  /** A small looping illustration of the topic, beside the headline value (e.g. the heart monitor). */
  motif?: ReactNode;
}) {
  const [view, setView] = useState<'chart' | 'table'>('chart');
  return (
    <section className={`card chart-card ${className}`}>
      <header className="chart-card-head">
        <div>
          <h3>{title}</h3>
          {value !== undefined && <div className="chart-card-value">{value}</div>}
          {note && <div className="chart-card-note">{note}</div>}
        </div>
        {motif && <div className="chart-card-motif">{motif}</div>}
        <div className="seg" role="group" aria-label={`${title} view`}>
          <button className={view === 'chart' ? 'on' : ''} onClick={() => setView('chart')} aria-pressed={view === 'chart'} title="Chart">
            <Icon name="chart" size={15} />
          </button>
          <button className={view === 'table' ? 'on' : ''} onClick={() => setView('table')} aria-pressed={view === 'table'} title="Table">
            <Icon name="table" size={15} />
          </button>
        </div>
      </header>
      {legend}
      {view === 'chart' ? (
        children
      ) : (
        <div className="table-wrap">
          <table>
            <thead>
              <tr>
                {table.columns.map((c) => (
                  <th key={c}>{c}</th>
                ))}
              </tr>
            </thead>
            <tbody>
              {[...table.rows].reverse().map((r, i) => (
                <tr key={i}>
                  {r.map((c, j) => (
                    <td key={j}>{c}</td>
                  ))}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </section>
  );
}

/** Changes when the plotted data does, so entrance animations replay for a new range but not for a hover. */
const drawKey = (points: { date: string }[]) => `${points.length}:${points[0]?.date ?? ''}:${points.at(-1)?.date ?? ''}`;
