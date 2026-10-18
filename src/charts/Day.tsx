// One day, hour by hour: the Day view on the detail pages.
import { useCallback } from 'react';
import type { DaySeries } from '../../shared/types.ts';
import { M, YAxis } from './Charts.tsx';
import { Tooltip, TooltipRow, niceTicks, smoothPath, useScrub, useWidth } from './core.tsx';
import { HOURS, cumulative, extent, hourLabel, hourSpan, lastReading } from './day.ts';
import { EndPulse, type Pulse } from './motion.tsx';

type Pt = [number, number];

/** Runs of consecutive hours that have values, so a gap in the data isn't drawn through. */
function runs(values: (number | null)[], x: (h: number) => number, y: (v: number) => number): Pt[][] {
  const out: Pt[][] = [];
  let cur: Pt[] = [];
  values.forEach((v, h) => {
    if (v === null) {
      if (cur.length) out.push(cur);
      cur = [];
    } else cur.push([x(h), y(v)]);
  });
  if (cur.length) out.push(cur);
  return out;
}

/**
 * `running`: a running total (steps, energy) climbing through the day from zero at midnight, plotted at the end of
 * each hour, against the dashed typical running total for that hour, so "ahead of or behind a usual day" reads at a
 * glance. `hourly`: an hourly average (heart rate) at the middle of each hour, with its low–high band and the dashed
 * typical average. Only hours up to `through` are drawn; the typical line spans the whole day.
 */
export function DayChart({
  kind,
  series,
  through,
  format,
  tickFormat = format,
  color = 'var(--series-1)',
  height = 220,
  goal,
  label,
  pulse,
}: {
  kind: 'running' | 'hourly';
  series: DaySeries;
  through: number | null;
  format: (v: number) => string;
  tickFormat?: (v: number) => string;
  color?: string;
  height?: number;
  goal?: { value: number; label: string };
  label: string;
  /** The latest hour's loop (motion.tsx). */
  pulse?: Pulse;
}) {
  const [ref, width] = useWidth<HTMLDivElement>();
  const running = kind === 'running';
  const plotW = Math.max(0, width - M.left - M.right);
  const x = useCallback((h: number) => M.left + ((running ? h + 1 : h + 0.5) / HOURS) * plotW, [running, plotW]);
  const shown = running ? cumulative(series.hours, through) : series.hours.map((v, h) => (through !== null && h <= through ? v : null));
  const band = !running && series.min && series.max ? { min: series.min, max: series.max } : null;
  const span = extent(shown, series.typical, band?.min, band?.max, goal ? [goal.value] : undefined);
  const ticks = span ? niceTicks(running ? 0 : span[0], span[1], 4) : [];
  const lo = ticks[0] ?? 0;
  const hi = ticks.at(-1) ?? 1;
  const baseY = height - M.bottom;
  const y = (v: number) => M.top + (1 - (v - lo) / (hi - lo || 1)) * (height - M.top - M.bottom);
  const { index, handlers } = useScrub(through === null ? 0 : through + 1, x);

  if (through === null || !span) {
    return (
      <div className="chart chart-empty" style={{ height }}>
        {series.total ? 'No hourly readings on this day' : 'No readings on this day'}
      </div>
    );
  }

  // Running totals start from zero at midnight.
  const fromMidnight = (r: Pt[]): Pt[] => (running ? [[M.left, y(0)], ...r] : r);
  const lines = runs(shown, x, y).map(fromMidnight);
  const typical = runs(series.typical, x, y).map(fromMidnight);

  // Low–high band: the max edge left to right, then the min edge back.
  const bands: string[] = [];
  if (band) {
    let top: Pt[] = [];
    let bottom: Pt[] = [];
    const flush = () => {
      if (top.length > 1) bands.push(`${smoothPath(top)} L${smoothPath([...bottom].reverse()).slice(1)} Z`);
      top = [];
      bottom = [];
    };
    for (let h = 0; h <= through; h++) {
      const a = band.min[h];
      const b = band.max[h];
      if (a === null || b === null) flush();
      else {
        top.push([x(h), y(b)]);
        bottom.push([x(h), y(a)]);
      }
    }
    flush();
  }

  const endH = running ? through : lastReading(shown, through);
  const focusH = index ?? endH;
  const focusV = focusH === null ? null : shown[focusH];
  const xTicks = plotW > 260 ? [0, 6, 12, 18, 24] : [0, 12, 24];
  const xAt = (h: number) => M.left + (h / HOURS) * plotW;

  return (
    <div className="chart" ref={ref} style={{ height }}>
      {width > 0 && (
        <svg width={width} height={height} {...handlers} role="img" aria-label={label}>
          <YAxis ticks={ticks} yOf={y} width={width} format={tickFormat} />
          <line x1={M.left} x2={width - M.right} y1={baseY} y2={baseY} className="baseline" />
          {xTicks.map((h) => (
            <text key={h} x={xAt(h)} y={height - 6} textAnchor={h === 0 ? 'start' : h === 24 ? 'end' : 'middle'} className="axis-label">
              {hourLabel(h)}
            </text>
          ))}
          {goal && (
            <g>
              <line x1={M.left} x2={width - M.right} y1={y(goal.value)} y2={y(goal.value)} className="ref-line" />
              <text x={width - M.right} y={y(goal.value) - 6} textAnchor="end" className="axis-label">
                {goal.label}
              </text>
            </g>
          )}
          {/* Keyed by the day and how far it runs, so the line draws in again for a new day, not on every hover. */}
          <g key={`${label}:${through}`}>
            {bands.map((d, k) => (
              <path key={k} d={d} fill={color} opacity={0.16} className="motion fade-in" />
            ))}
            {typical.map((r, k) => (
              <path key={k} d={smoothPath(r)} className="typical-line motion fade-in" />
            ))}
            {running &&
              lines.map((r, k) => (
                <path key={k} d={`${smoothPath(r)} L${r.at(-1)![0]},${baseY} L${r[0][0]},${baseY} Z`} fill={color} opacity={0.1} className="motion fade-in" />
              ))}
            {lines.map((r, k) =>
              r.length > 1 ? (
                <path
                  key={k}
                  d={smoothPath(r)}
                  pathLength={1}
                  fill="none"
                  stroke={color}
                  strokeWidth={2}
                  strokeLinecap="round"
                  strokeLinejoin="round"
                  className="motion draw-in"
                />
              ) : (
                <circle key={k} cx={r[0][0]} cy={r[0][1]} r={3} fill={color} className="motion pop-in" />
              ),
            )}
          </g>
          {index !== null && <line x1={0} x2={0} y1={M.top - 8} y2={baseY} className="crosshair glide" style={{ transform: `translateX(${x(index)}px)` }} />}
          {endH !== null && shown[endH] !== null && <EndPulse x={x(endH)} y={y(shown[endH]!)} color={color} pulse={pulse} />}
          {focusH !== null && focusV !== null && <circle cx={x(focusH)} cy={y(focusV)} r={4.5} fill={color} className="dot-ring motion pop-in after-draw glide" />}
          {index === null && endH !== null && shown[endH] !== null && (
            <text x={x(endH)} y={y(shown[endH]!) - 12} textAnchor="end" className="end-label motion fade-in after-draw">
              {format(shown[endH]!)}
            </text>
          )}
          <rect width={width} height={height} fill="transparent" />
        </svg>
      )}
      {index !== null && (
        <Tooltip x={x(index)} y={y(shown[index] ?? series.typical[index] ?? (lo + hi) / 2)} width={width}>
          <div className="tooltip-title">{hourSpan(index)}</div>
          {running ? (
            <>
              <TooltipRow color={color} value={format(shown[index] ?? 0)} label="so far" />
              <TooltipRow color="" kind="none" value={format(series.hours[index] ?? 0)} label="this hour" />
            </>
          ) : shown[index] !== null ? (
            <>
              <TooltipRow color={color} value={format(shown[index]!)} label="average" />
              {band && band.min[index] !== null && band.max[index] !== null && (
                <TooltipRow color="" kind="none" value={`${tickFormat(band.min[index]!)}–${format(band.max[index]!)}`} label="range" />
              )}
            </>
          ) : (
            <TooltipRow color="" kind="none" value="—" label="no reading" />
          )}
          {series.typical[index] !== null && (
            <TooltipRow color="" kind="none" value={format(series.typical[index]!)} label={running ? 'typical by then' : 'typical'} />
          )}
        </Tooltip>
      )}
    </div>
  );
}
