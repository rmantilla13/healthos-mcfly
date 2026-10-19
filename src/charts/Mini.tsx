// Small charts that live inside the home-page cards.
import { useCallback } from 'react';
import type { Point } from '../../shared/types.ts';
import { fmtDate } from '../lib.ts';
import { Tooltip, TooltipRow, barPath, smoothPath, useScrub, useWidth } from './core.tsx';

type Fmt = (v: number) => string;

export function MiniBars({
  points,
  format,
  height = 72,
  tone = 'blue',
  label,
}: {
  points: Point[];
  format: Fmt;
  height?: number;
  tone?: 'blue' | 'neutral' | 'green';
  label: string;
}) {
  const [ref, width] = useWidth<HTMLDivElement>();
  const n = points.length;
  const max = Math.max(...points.map((p) => p.value), 1);
  const slot = n ? width / n : 0;
  const barW = Math.max(3, Math.min(tone === 'neutral' ? 10 : 5, slot - 2));
  const xOf = useCallback((i: number) => i * slot + slot / 2, [slot]);
  const { index, handlers } = useScrub(n, xOf);
  const yOf = (v: number) => height - (v / max) * (height - 4);

  return (
    <div className="mini" ref={ref} style={{ height }}>
      {width > 0 && (
        <svg width={width} height={height} {...handlers} aria-label={label} role="img" className={tone === 'green' ? 'mini-bars bars-green' : `mini-bars tone-${tone}`}>
          {points.map((p, i) => {
            const x = xOf(i) - barW / 2;
            const y = yOf(p.value);
            return (
              <path
                key={p.date}
                d={barPath(x, y, barW, height - y, Math.min(4, barW / 2))}
                className={i === n - 1 ? 'bar bar-accent' : index === i ? 'bar bar-hover' : 'bar'}
              />
            );
          })}
          <rect width={width} height={height} fill="transparent" />
        </svg>
      )}
      {index !== null && points[index] && (
        <Tooltip x={xOf(index)} y={height / 2} width={width}>
          <TooltipRow color="" kind="none" value={format(points[index].value)} label={fmtDate(points[index].date, { weekday: 'short', month: 'short', day: 'numeric' })} />
        </Tooltip>
      )}
    </div>
  );
}

export function MiniLine({
  points,
  format,
  height = 64,
  domain,
  color = 'var(--series-1)',
  label,
}: {
  points: Point[];
  format: Fmt;
  height?: number;
  domain?: [number, number];
  color?: string;
  label: string;
}) {
  const [ref, width] = useWidth<HTMLDivElement>();
  const n = points.length;
  const values = points.map((p) => p.value);
  const lo = domain?.[0] ?? Math.min(...values);
  const hi = domain?.[1] ?? Math.max(...values);
  const pad = 6;
  const span = hi - lo || 1;
  const xOf = useCallback((i: number) => (n <= 1 ? width / 2 : pad + (i / (n - 1)) * (width - pad * 2)), [n, width]);
  const yOf = (v: number) => pad + (1 - (Math.min(hi, Math.max(lo, v)) - lo) / span) * (height - pad * 2);
  const { index, handlers } = useScrub(n, xOf);
  const pts = points.map((p, i) => [xOf(i), yOf(p.value)] as [number, number]);
  const line = smoothPath(pts);

  return (
    <div className="mini" ref={ref} style={{ height }}>
      {width > 0 && n > 0 && (
        <svg width={width} height={height} {...handlers} aria-label={label} role="img">
          <path d={`${line} L${pts.at(-1)![0]},${height} L${pts[0][0]},${height} Z`} fill={color} opacity={0.1} />
          <path d={line} fill="none" stroke={color} strokeWidth={2} strokeLinecap="round" strokeLinejoin="round" />
          {index !== null && <line x1={xOf(index)} x2={xOf(index)} y1={0} y2={height} className="crosshair" />}
          {(() => {
            const i = index ?? n - 1;
            return <circle cx={pts[i][0]} cy={pts[i][1]} r={4} fill={color} className="dot-ring" />;
          })()}
          <rect width={width} height={height} fill="transparent" />
        </svg>
      )}
      {index !== null && points[index] && (
        <Tooltip x={xOf(index)} y={height / 2} width={width}>
          <TooltipRow color={color} value={format(points[index].value)} label={fmtDate(points[index].date, { weekday: 'short', month: 'short', day: 'numeric' })} />
        </Tooltip>
      )}
    </div>
  );
}

/**
 * One dot per night over a band showing the usual range (mean ± 1 SD of the earlier nights).
 * Dots, not bars: HRV moves within a narrow band, and bars must start at zero, which would flatten it.
 */
export function MiniDots({
  points,
  baseline,
  format,
  height = 70,
  label,
}: {
  points: Point[];
  baseline: number | null;
  format: Fmt;
  height?: number;
  label: string;
}) {
  const [ref, width] = useWidth<HTMLDivElement>();
  const n = points.length;
  const values = points.map((p) => p.value);
  const prior = values.slice(0, -1);
  const mean = baseline ?? (prior.length ? prior.reduce((a, b) => a + b, 0) / prior.length : values[0]);
  const sd = prior.length > 1 ? Math.sqrt(prior.reduce((a, v) => a + (v - mean) ** 2, 0) / (prior.length - 1)) : 0;
  const lo = Math.min(...values, mean - sd) * 0.96;
  const hi = Math.max(...values, mean + sd) * 1.04;
  const pad = 6;
  const xOf = useCallback((i: number) => (n <= 1 ? width / 2 : pad + (i / (n - 1)) * (width - pad * 2)), [n, width]);
  const yOf = (v: number) => pad + (1 - (v - lo) / (hi - lo || 1)) * (height - pad * 2);
  const { index, handlers } = useScrub(n, xOf);

  return (
    <div className="mini" ref={ref} style={{ height }}>
      {width > 0 && n > 0 && (
        <svg width={width} height={height} {...handlers} aria-label={label} role="img">
          {sd > 0 && <rect x={0} width={width} y={yOf(mean + sd)} height={yOf(mean - sd) - yOf(mean + sd)} className="band" rx={4} />}
          <line x1={0} x2={width} y1={yOf(mean)} y2={yOf(mean)} className="band-mid" />
          {index !== null && <line x1={xOf(index)} x2={xOf(index)} y1={0} y2={height} className="crosshair" />}
          {points.map((p, i) => (
            <circle
              key={p.date}
              cx={xOf(i)}
              cy={yOf(p.value)}
              r={i === n - 1 || i === index ? 4.5 : 3}
              className={i === n - 1 ? 'dot dot-accent dot-ring' : i === index ? 'dot dot-accent' : 'dot'}
            />
          ))}
          <rect width={width} height={height} fill="transparent" />
        </svg>
      )}
      {index !== null && points[index] && (
        <Tooltip x={xOf(index)} y={height / 2} width={width}>
          <TooltipRow color="" kind="none" value={format(points[index].value)} label={fmtDate(points[index].date, { weekday: 'short', month: 'short', day: 'numeric' })} />
        </Tooltip>
      )}
    </div>
  );
}

/** Half-circle gauge. The track is a lighter step of the fill's own hue. */
export function Gauge({ value, max, label }: { value: number; max: number; label: string }) {
  const w = 168;
  const h = 92;
  const r = 72;
  const cx = w / 2;
  const cy = h - 6;
  const t = Math.min(1, Math.max(0, value / max));
  const angle = Math.PI * (1 - t);
  const ex = cx + r * Math.cos(angle);
  const ey = cy - r * Math.sin(angle);
  const arc = (to: number) => {
    const a = Math.PI * (1 - to);
    return `M${cx - r},${cy} A${r},${r} 0 0 1 ${cx + r * Math.cos(a)},${cy - r * Math.sin(a)}`;
  };
  return (
    <svg width={w} height={h} viewBox={`0 0 ${w} ${h}`} role="img" aria-label={label} className="gauge">
      <path d={arc(1)} className="gauge-track" />
      {t > 0 && <path d={arc(t)} className="gauge-fill" />}
      {Array.from({ length: 21 }, (_, i) => {
        const a = Math.PI * (1 - i / 20);
        const r1 = r - 12;
        const r2 = r - (i % 5 === 0 ? 18 : 15);
        return <line key={i} x1={cx + r1 * Math.cos(a)} y1={cy - r1 * Math.sin(a)} x2={cx + r2 * Math.cos(a)} y2={cy - r2 * Math.sin(a)} className="gauge-tick" />;
      })}
      <circle cx={ex} cy={ey} r={5} className="gauge-dot" />
    </svg>
  );
}

/** A 0–100 style scale with a marker, e.g. recovery zones or the SpO2 range. */
export function RangeScale({
  value,
  min,
  max,
  zones,
  label,
}: {
  value: number;
  min: number;
  max: number;
  zones?: { to: number; className: string }[];
  label: string;
}) {
  const t = Math.min(1, Math.max(0, (value - min) / (max - min)));
  let from = min;
  return (
    <div className="range-scale" role="img" aria-label={label}>
      <div className="range-track">
        {zones?.map((z) => {
          const left = ((from - min) / (max - min)) * 100;
          const w = ((z.to - from) / (max - min)) * 100;
          from = z.to;
          return <span key={z.to} className={`range-zone ${z.className}`} style={{ left: `${left}%`, width: `calc(${w}% - 2px)` }} />;
        })}
      </div>
      <span className="range-marker" style={{ left: `${t * 100}%` }} />
    </div>
  );
}
