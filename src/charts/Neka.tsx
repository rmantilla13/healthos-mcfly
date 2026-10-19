// Charts for the Sleep and Body pages, after the Neka reference: a score bar, the night's stages (hypnogram,
// bars across the night, one-line timeline), hourly bars and a day curve. Each draws only what it's given.
import { type ReactNode, useId, useState } from 'react';
import type { SleepSegment, SleepStage } from '../../shared/types.ts';
import { Icon } from '../components/Icon.tsx';
import { clock, fmt } from '../lib.ts';
import { barPath, smoothPath, useWidth } from './core.tsx';

const ms = (iso: string) => Date.parse(iso);
const clamp = (v: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, v));

// ---------- score bar ----------

/** A 0–100 score on a gradient track, with the scale under it (the nearest tick in bold). */
export function ScoreBar({ value, label }: { value: number; label: string }) {
  const pct = clamp(value, 0, 100);
  const ticks = [0, 20, 40, 60, 80, 100];
  const near = ticks.reduce((a, t) => (Math.abs(t - pct) < Math.abs(a - pct) ? t : a), 0);
  return (
    <div className="scorebar" role="img" aria-label={label}>
      <div className="scorebar-track">
        {/* The gradient spans the whole track, so a colour always means the same score. */}
        {pct > 0 && <div className="scorebar-fill" style={{ width: `${pct}%`, backgroundSize: `${10_000 / pct}% 100%` }} />}
        <div className="scorebar-knob" style={{ left: `${pct}%` }} />
      </div>
      <div className="scorebar-ticks">
        {ticks.map((t) => (
          <span key={t} className={t === near ? 'is-on' : ''} style={{ left: `${t}%` }}>
            {t}
          </span>
        ))}
      </div>
    </div>
  );
}

// ---------- the night ----------

/** Rows of the hypnogram, top to bottom; stages without a row of their own sit on the nearest one. */
const ROWS: { key: string; label: string; stages: SleepStage[] }[] = [
  { key: 'awake', label: 'Awake', stages: ['awake', 'in_bed'] },
  { key: 'rem', label: 'REM', stages: ['rem'] },
  { key: 'light', label: 'Light', stages: ['light', 'asleep'] },
  { key: 'deep', label: 'Deep', stages: ['deep'] },
];
export const STAGE_COLOR: Record<SleepStage, string> = {
  awake: 'var(--hyp-awake)',
  in_bed: 'var(--hyp-inbed)',
  rem: 'var(--stage-rem)',
  light: 'var(--stage-light)',
  asleep: 'var(--stage-light)',
  deep: 'var(--stage-deep)',
};
export const STAGE_LABEL: Record<SleepStage, string> = { awake: 'Awake', in_bed: 'In bed', rem: 'REM', light: 'Light', asleep: 'Asleep', deep: 'Deep' };

/** Minutes east of UTC in an ISO timestamp's offset ("…-05:00" is −300). */
function offsetOf(iso: string) {
  const m = /([+-])(\d{2}):?(\d{2})$/.exec(iso);
  return m ? (m[1] === '-' ? -1 : 1) * (Number(m[2]) * 60 + Number(m[3])) : 0;
}

/** "HH:MM" of an instant, in the offset an ISO timestamp was written with. */
export function localClock(t: number, offsetIso: string) {
  return new Date(t + offsetOf(offsetIso) * 60_000).toISOString().slice(11, 16);
}

/**
 * The wall clock at an instant, in the offset the night was recorded in then: that of the latest timestamp at or
 * before it. A night the clocks change is written in two offsets, and "woke up 07:00" must match the axis.
 */
export function clockAt(t: number, segments: SleepSegment[], fallbackIso: string) {
  let iso = segments[0]?.start ?? fallbackIso;
  for (const g of segments) {
    if (ms(g.start) <= t) iso = g.start;
    if (ms(g.end) <= t) iso = g.end;
  }
  return localClock(t, iso);
}

/** Whole local hours between two instants, every `every` hours, each labelled in the offset in force then. */
function hourTicks(from: number, to: number, label: (t: number) => string, offsetIso: string, every: number) {
  const off = offsetOf(offsetIso) * 60_000;
  const out: { at: number; label: string }[] = [];
  for (let t = Math.ceil((from + off) / 3_600_000) * 3_600_000 - off; t <= to; t += 3_600_000) {
    const text = label(t);
    if (Number(text.slice(0, 2)) % every === 0) out.push({ at: t, label: text });
  }
  return out;
}

/** The night stage by stage: one row per stage, a block for each stretch, thin lines where it changes. */
export function Hypnogram({ segments, height = 170 }: { segments: SleepSegment[]; height?: number }) {
  const [ref, width] = useWidth<HTMLDivElement>();
  const from = ms(segments[0].start);
  const to = ms(segments[segments.length - 1].end);
  const left = 48;
  const bottom = 22;
  const rowH = (height - bottom) / ROWS.length;
  const x = (t: number) => left + ((t - from) / Math.max(1, to - from)) * (width - left - 4);
  const rowOf = (s: SleepStage) => ROWS.findIndex((r) => r.stages.includes(s));
  const ticks = width > 0 ? hourTicks(from, to, (t) => clockAt(t, segments, segments[0].start), segments[0].start, width < 420 ? 3 : 2) : [];
  return (
    <div className="hypnogram" ref={ref} style={{ height }}>
      {width > 0 && (
        <svg width={width} height={height} role="img" aria-label={`Sleep stages from ${clock(segments[0].start)} to ${clock(segments[segments.length - 1].end)}`}>
          {ROWS.map((r, i) => (
            <g key={r.key}>
              <line x1={left} x2={width} y1={(i + 1) * rowH} y2={(i + 1) * rowH} className="hyp-grid" />
              <text x={0} y={i * rowH + rowH / 2 + 4} className="hyp-label">
                {r.label}
              </text>
            </g>
          ))}
          {segments.map((s, i) => {
            const row = rowOf(s.stage);
            const prev = segments[i - 1];
            const x0 = x(ms(s.start));
            const w = Math.max(1.5, x(ms(s.end)) - x0);
            const pad = rowH * 0.18;
            return (
              <g key={s.start}>
                {prev && rowOf(prev.stage) !== row && (
                  <line x1={x0} x2={x0} y1={Math.min(rowOf(prev.stage), row) * rowH + pad} y2={(Math.max(rowOf(prev.stage), row) + 1) * rowH - pad} className="hyp-step" />
                )}
                <rect x={x0} y={row * rowH + pad} width={w} height={rowH - pad * 2} rx={3} fill={STAGE_COLOR[s.stage]}>
                  <title>{`${STAGE_LABEL[s.stage]} ${clock(s.start)}–${clock(s.end)}`}</title>
                </rect>
              </g>
            );
          })}
          {ticks.map((t) => (
            <text key={t.at} x={x(t.at)} y={height - 4} textAnchor="middle" className="hyp-tick">
              {t.label}
            </text>
          ))}
        </svg>
      )}
    </div>
  );
}

/** How deep each part of the night was, as bars from bedtime to waking (deeper sleep, taller bar). */
const DEPTH: Record<SleepStage, number> = { deep: 1, light: 0.55, asleep: 0.5, rem: 0.4, awake: 0.08, in_bed: 0.04 };

export function NightBars({ segments, height = 64 }: { segments: SleepSegment[]; height?: number }) {
  const [ref, width] = useWidth<HTMLDivElement>();
  const from = ms(segments[0].start);
  const to = ms(segments[segments.length - 1].end);
  const n = Math.max(1, Math.min(32, Math.round((to - from) / (15 * 60_000))));
  const bin = (to - from) / n;
  const depth = Array.from({ length: n }, (_, i) => {
    const a = from + i * bin;
    const b = a + bin;
    let sum = 0;
    for (const s of segments) {
      const overlap = Math.min(b, ms(s.end)) - Math.max(a, ms(s.start));
      if (overlap > 0) sum += overlap * DEPTH[s.stage];
    }
    return sum / bin;
  });
  const slot = width / n;
  const bw = Math.max(2, Math.min(6, slot - 3));
  return (
    <div className="mini" ref={ref} style={{ height: height + 16 }}>
      {width > 0 && (
        <svg width={width} height={height + 16} role="img" aria-label={`Sleep depth through the night, ${clock(segments[0].start)} to ${clock(segments[segments.length - 1].end)}`}>
          {depth.map((d, i) => {
            const h = Math.max(2, d * height);
            return <path key={i} d={barPath(i * slot + (slot - bw) / 2, height - h, bw, h, 3)} className="night-bar" style={{ opacity: 0.35 + d * 0.65 }} />;
          })}
          <text x={0} y={height + 13} className="hyp-tick">
            {clock(segments[0].start)}
          </text>
          <text x={width} y={height + 13} textAnchor="end" className="hyp-tick">
            {clock(segments[segments.length - 1].end)}
          </text>
        </svg>
      )}
    </div>
  );
}

/**
 * The night as one bar, from bed to waking, coloured by stage (one colour without stages). Hovering moves a
 * marker that reads the time and stage there; it rests on `marker` (the deep-sleep peak) otherwise.
 */
export function StageTimeline({ segments, start, end, marker }: { segments: SleepSegment[]; start: string; end: string; marker?: string | null }) {
  const from = ms(start);
  const to = ms(end);
  const [hover, setHover] = useState<number | null>(null);
  const pos = (t: number) => `${clamp(((t - from) / Math.max(1, to - from)) * 100, 0, 100)}%`;
  const at = hover ?? (marker ? ms(marker) : null);
  const stageAt = at !== null ? segments.find((s) => ms(s.start) <= at && at < ms(s.end))?.stage : undefined;
  const ticks = hourTicks(from, to, (t) => clockAt(t, segments, start), start, to - from > 11 * 3_600_000 ? 2 : 1);
  return (
    <div className="stage-tl">
      <div
        className="stage-tl-track"
        onPointerMove={(e) => {
          const r = e.currentTarget.getBoundingClientRect();
          setHover(from + ((e.clientX - r.left) / r.width) * (to - from));
        }}
        onPointerLeave={() => setHover(null)}
      >
        <div className="stage-tl-segs">
          {segments.length ? (
            segments.map((s) => (
              <span key={s.start} className="stage-tl-seg" style={{ left: pos(ms(s.start)), width: `calc(${pos(ms(s.end))} - ${pos(ms(s.start))})`, background: STAGE_COLOR[s.stage] }} />
            ))
          ) : (
            <span className="stage-tl-seg" style={{ left: 0, width: '100%', background: 'var(--stage-light)' }} />
          )}
        </div>
        {at !== null && (
          <div className="stage-tl-marker" style={{ left: pos(at) }}>
            <span>
              {clockAt(at, segments, start)}
              {stageAt ? ` · ${STAGE_LABEL[stageAt]}` : ''}
            </span>
          </div>
        )}
      </div>
      <div className="stage-tl-ticks">
        {ticks.map((t) => (
          <span key={t.at} style={{ left: pos(t.at) }}>
            {t.label}
          </span>
        ))}
      </div>
    </div>
  );
}

// ---------- hours of a day ----------

/** Hourly bars between two hours (the current hour in the accent colour), with clock labels under them. */
export function HourBars({
  hours,
  format,
  label,
  from = 0,
  to = 23,
  accent,
  tone = 'blue',
  height = 120,
}: {
  hours: (number | null)[];
  format: (v: number) => string;
  label: string;
  from?: number;
  to?: number;
  accent?: number | null;
  tone?: 'blue' | 'green' | 'orange';
  height?: number;
}) {
  const [ref, width] = useWidth<HTMLDivElement>();
  const shown = hours.slice(from, to + 1);
  const max = Math.max(1, ...shown.map((v) => v ?? 0));
  const slot = width / shown.length;
  const bw = Math.max(3, Math.min(12, slot - 3));
  const plot = height - 18;
  return (
    <div className="mini" ref={ref} style={{ height }}>
      {width > 0 && (
        <svg width={width} height={height} role="img" aria-label={label} className={`hour-bars hb-${tone}`}>
          {shown.map((v, i) => {
            const h = v ? Math.max(2, (v / max) * (plot - 4)) : 0;
            const hour = from + i;
            return (
              <path key={hour} d={barPath(i * slot + (slot - bw) / 2, plot - h, bw, h, 3)} className={hour === accent ? 'bar bar-accent' : 'bar'}>
                <title>{`${String(hour).padStart(2, '0')}:00 · ${v ? format(v) : 'nothing'}`}</title>
              </path>
            );
          })}
          {shown.map((_, i) =>
            (from + i) % 3 === 0 ? (
              <text key={i} x={i * slot + slot / 2} y={height - 3} textAnchor="middle" className="hyp-tick">
                {`${from + i}:00`}
              </text>
            ) : null,
          )}
        </svg>
      )}
    </div>
  );
}

/**
 * A day as a smooth curve, 00:00 to 24:00, green up to the marker and orange after it, with the marker's
 * value in a pill. Hours without a reading are bridged.
 */
export function AreaCurve({
  hours,
  typical,
  marker,
  format,
  label,
  height = 170,
}: {
  hours: (number | null)[];
  /** A dashed line for the person's typical hour, when there is one. */
  typical?: (number | null)[];
  marker: number | null;
  format: (v: number) => string;
  label: string;
  height?: number;
}) {
  const [ref, width] = useWidth<HTMLDivElement>();
  const id = `curve${useId().replace(/[^\w-]/g, '')}`;
  const pts = hours.map((v, h) => (v === null ? null : ([h, v] as const))).filter((p): p is readonly [number, number] => p !== null);
  if (pts.length < 2) return <div className="chart chart-empty" style={{ height }}>No readings yet today</div>;
  const usual = (typical ?? []).map((v, h) => (v === null ? null : ([h, v] as const))).filter((p): p is readonly [number, number] => p !== null);
  const values = [...pts, ...usual].map((p) => p[1]);
  const lo = Math.min(...values) - 5;
  const hi = Math.max(...values) + 5;
  const plot = height - 20;
  const x = (h: number) => 6 + (h / 24) * (width - 12);
  const y = (v: number) => 8 + (1 - (v - lo) / (hi - lo || 1)) * (plot - 16);
  const xy = pts.map(([h, v]) => [x(h + 0.5), y(v)] as [number, number]);
  const line = smoothPath(xy);
  const area = `${line} L${xy.at(-1)![0]},${plot} L${xy[0][0]},${plot} Z`;
  const mh = marker ?? pts.at(-1)![0];
  const mx = x(mh + 0.5);
  const mv = hours[mh] ?? pts.reduce((a, p) => (Math.abs(p[0] - mh) < Math.abs(a[0] - mh) ? p : a))[1];
  return (
    <div className="mini" ref={ref} style={{ height }}>
      {width > 0 && (
        <svg width={width} height={height} role="img" aria-label={label}>
          <defs>
            <linearGradient id={`${id}-up`} x1="0" y1="0" x2="0" y2="1">
              <stop offset="0%" stopColor="var(--good)" stopOpacity="0.28" />
              <stop offset="100%" stopColor="var(--good)" stopOpacity="0" />
            </linearGradient>
            <linearGradient id={`${id}-down`} x1="0" y1="0" x2="0" y2="1">
              <stop offset="0%" stopColor="var(--series-2)" stopOpacity="0.24" />
              <stop offset="100%" stopColor="var(--series-2)" stopOpacity="0" />
            </linearGradient>
            <clipPath id={`${id}-before`}>
              <rect x={0} y={0} width={mx} height={height} />
            </clipPath>
            <clipPath id={`${id}-after`}>
              <rect x={mx} y={0} width={Math.max(0, width - mx)} height={height} />
            </clipPath>
          </defs>
          {usual.length > 1 && <path d={smoothPath(usual.map(([h, v]) => [x(h + 0.5), y(v)] as [number, number]))} className="typical-line" />}
          <path d={area} fill={`url(#${id}-up)`} clipPath={`url(#${id}-before)`} />
          <path d={area} fill={`url(#${id}-down)`} clipPath={`url(#${id}-after)`} />
          <path d={line} fill="none" stroke="var(--good)" strokeWidth={2} clipPath={`url(#${id}-before)`} />
          <path d={line} fill="none" stroke="var(--series-2)" strokeWidth={2} clipPath={`url(#${id}-after)`} />
          <line x1={mx} x2={mx} y1={18} y2={plot} className="curve-marker" />
          <circle cx={mx} cy={y(mv)} r={4.5} className="curve-dot" />
          <g transform={`translate(${clamp(mx, 24, width - 24)}, 10)`}>
            <rect x={-22} y={-9} width={44} height={18} rx={9} className="curve-pill" />
            <text x={0} y={4} textAnchor="middle" className="curve-pill-text">
              {format(mv)}
            </text>
          </g>
          {[0, 6, 12, 18, 24].map((h) => (
            <text key={h} x={x(h)} y={height - 3} textAnchor={h === 0 ? 'start' : h === 24 ? 'end' : 'middle'} className="hyp-tick">
              {`${String(h).padStart(2, '0')}:00`}
            </text>
          ))}
        </svg>
      )}
    </div>
  );
}

// ---------- small pieces ----------

/** "Label value" pairs under a chart, as in the stage totals. */
export function StatRow({ items }: { items: { label: ReactNode; value: string; note?: string; color?: string }[] }) {
  return (
    <div className="stat-row">
      {items.map((it, i) => (
        <div key={i}>
          <span className="stat-row-label">
            {it.color && <i style={{ background: it.color }} />}
            {it.label}
          </span>
          <b>{it.value}</b>
          {it.note && <small>{it.note}</small>}
        </div>
      ))}
    </div>
  );
}

/** This week against last week, as a small chip. Green only where the direction is plainly the better one. */
export function Change({ pct, better, title = 'This week against last week' }: { pct: number | null | undefined; better?: 'up' | 'down'; title?: string }) {
  if (pct == null || !Number.isFinite(pct) || Math.round(Math.abs(pct)) < 1) return null;
  const up = pct > 0;
  const good = better === (up ? 'up' : 'down');
  return (
    <span className={`chip change-chip${good ? '' : ' is-neutral'}`} title={title}>
      <Icon name={up ? 'trend-up' : 'trend-down'} size={13} /> {fmt(Math.round(Math.abs(pct)))}%
    </span>
  );
}

/** A night's stage totals as one bar, for nights without the stages through the night (WHOOP, or older syncs). */
export function StageBar({ stages }: { stages: { awake: number; rem: number; light: number; deep: number } }) {
  const total = stages.awake + stages.rem + stages.light + stages.deep || 1;
  const order: [keyof typeof stages, SleepStage][] = [['deep', 'deep'], ['light', 'light'], ['rem', 'rem'], ['awake', 'awake']];
  return (
    <div className="stage-bar" role="img" aria-label={order.map(([k]) => `${STAGE_LABEL[k]} ${Math.round((stages[k] / total) * 100)}%`).join(', ')}>
      {order.map(([k, st]) => (stages[k] > 0 ? <span key={k} style={{ flexGrow: stages[k], background: STAGE_COLOR[st] }} /> : null))}
    </div>
  );
}
