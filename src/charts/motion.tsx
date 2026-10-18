// Looping chart animations, paced by the person's own readings (styles.css, "chart motion"). Every animated
// element carries the `motion` class, so one reduced-motion rule holds them all still. Loops sit on top of the
// data as rings, glows and highlights; they never move a mark that encodes a value.
import { type CSSProperties, useId, useMemo } from 'react';
import { barPath, useWidth } from './core.tsx';

export const clamp = (n: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, n));

const usable = (v: number | null | undefined): v is number => v != null && Number.isFinite(v) && v > 0;

/** Seconds per heartbeat. The clamp only catches impossible data, so a bad row can't freeze or strobe a loop. */
export const beatSeconds = (bpm: number) => 60 / clamp(bpm, 30, 220);
/** Seconds per breath at a respiratory rate. */
export const breathSeconds = (rpm: number) => 60 / clamp(rpm, 4, 40);

/** --beat for a heart rate, or null without a usable reading. */
export const beatVar = (bpm: number | null | undefined): CSSProperties | null =>
  usable(bpm) ? ({ '--beat': `${beatSeconds(bpm).toFixed(3)}s` } as CSSProperties) : null;
/** --breath for a respiratory rate, or null without a usable reading. */
export const breathVar = (rpm: number | null | undefined): CSSProperties | null =>
  usable(rpm) ? ({ '--breath': `${breathSeconds(rpm).toFixed(3)}s` } as CSSProperties) : null;

/** Blood oxygen's highlight runs the line once every four heartbeats, or every five seconds without a heart rate. */
export const oxygenFlow = (bpm: number | null | undefined) => (usable(bpm) ? beatSeconds(bpm) * 4 : 5);

/** Effort's highlight runs up the gauge faster the harder the day: 3.4 s at rest down to 1 s all out (t is 0–1). */
export const effortFlow = (t: number) => 3.4 - 2.4 * clamp(t, 0, 1);

/** Animations are cut off at this many staggered items, so a year of bars still finishes in about half a second. */
export const stagger = (i: number, n: number, total = 480): CSSProperties => ({ animationDelay: `${Math.round(i * Math.min(24, total / Math.max(1, n)))}ms` });

/** Sanitised so the id is safe inside url(#…) whatever format React's ids take. */
export const useSvgId = (prefix: string) => `${prefix}-${useId().replace(/[^\w-]/g, '')}`;

/**
 * How the latest point of a chart moves:
 * - beat: a ring leaves the point once per heartbeat (resting heart rate).
 * - variability: the same ring, with beats alternately early and late by the HRV, so the spacing visibly varies.
 * - breath: a halo fills on the inhale and empties on the longer exhale (respiratory rate).
 * - calm: a slow ping that only says "latest reading"; `seconds` sets its pace (sleep is slower than body).
 */
export type Pulse =
  | { kind: 'beat'; bpm: number }
  | { kind: 'variability'; bpm: number; hrvMs: number }
  | { kind: 'breath'; rpm: number }
  | { kind: 'calm'; seconds?: number };

function pulseStyle(p: Pulse): CSSProperties | null {
  if (p.kind === 'beat') return beatVar(p.bpm);
  if (p.kind === 'breath') return breathVar(p.rpm);
  if (p.kind === 'calm') return { '--calm': `${p.seconds ?? 3.2}s` } as CSSProperties;
  if (!usable(p.bpm)) return null;
  // Two rings, two beats apart; the second comes early by the HRV, so intervals alternate short and long.
  // Successive intervals then differ by 2j, which is the RMSSD when j = RMSSD / 2.
  const rr = beatSeconds(p.bpm);
  const j = usable(p.hrvMs) ? Math.min(rr * 0.2, p.hrvMs / 2000) : 0;
  return { '--pair': `${(rr * 2).toFixed(3)}s`, '--early': `${(rr - j).toFixed(3)}s` } as CSSProperties;
}

/** The latest point's loop. Pinned to the last point (not the hovered one), so scrubbing never restarts it. */
export function EndPulse({ x, y, r = 4.5, color, pulse }: { x: number; y: number; r?: number; color: string; pulse?: Pulse }) {
  const style = pulse && pulseStyle(pulse);
  if (!pulse || !style) return null;
  return (
    <g className={`end-pulse pulse-${pulse.kind}`} style={{ ...style, color }} aria-hidden="true">
      {pulse.kind === 'breath' ? (
        <circle cx={x} cy={y} r={r * 2.4} className="motion pulse-halo" />
      ) : (
        <>
          <circle cx={x} cy={y} r={r} className="motion pulse-ring" />
          {pulse.kind === 'variability' && <circle cx={x} cy={y} r={r} className="motion pulse-ring pulse-ring-b" />}
        </>
      )}
    </g>
  );
}

/**
 * A highlight that runs along a line, start to end, then rests a moment: blood oxygen "flowing" over the
 * readings, or energy running up the strain gauge. Draws over the line it copies; never changes it.
 */
export function Flow({ d, seconds, className = '' }: { d: string; seconds: number; className?: string }) {
  return <path d={d} pathLength={1} className={`motion flow ${className}`} style={{ '--flow': `${seconds.toFixed(2)}s` } as CSSProperties} aria-hidden="true" />;
}

/**
 * A soft highlight climbing today's bar from the baseline to its top, over and over: the count is still going up.
 * Clipped to the bar, so it never draws past the value.
 */
export function BarClimb({ id, x, y, w, h }: { id: string; x: number; y: number; w: number; h: number }) {
  if (h <= 2) return null;
  const band = Math.min(h, Math.max(14, h * 0.45));
  return (
    <g aria-hidden="true" className="bar-climb">
      <defs>
        <clipPath id={`${id}-clip`}>
          <path d={barPath(x, y, w, h, Math.min(4, w / 2))} />
        </clipPath>
        <linearGradient id={`${id}-glint`} x1="0" y1="1" x2="0" y2="0">
          <stop offset="0%" stopColor="#fff" stopOpacity="0" />
          <stop offset="55%" stopColor="#fff" stopOpacity="0.55" />
          <stop offset="100%" stopColor="#fff" stopOpacity="0" />
        </linearGradient>
      </defs>
      <g clipPath={`url(#${id}-clip)`}>
        <rect
          x={x}
          y={y + h}
          width={w}
          height={band}
          fill={`url(#${id}-glint)`}
          className="motion bar-climb-glint"
          style={{ '--climb': `${-(h + band)}px` } as CSSProperties}
        />
      </g>
    </g>
  );
}

/** Four-point sparkle centred on (x, y). */
const sparkle = (x: number, y: number, s: number) => {
  const k = s * 0.22;
  return `M${x},${y - s}L${x + k},${y - k}L${x + s},${y}L${x + k},${y + k}L${x},${y + s}L${x - k},${y + k}L${x - s},${y}L${x - k},${y - k}Z`;
};

const STARS: [number, number, number][] = [
  [14, 12, 4.2],
  [52, 8, 3],
  [62, 30, 3.6],
  [30, 38, 2.6],
];

/** Sleep's motif: a crescent moon drifting slowly while stars twinkle out of step, on sleep's calm 5.5 s clock. */
export function NightSky({ className = '' }: { className?: string }) {
  return (
    <svg className={`night-sky ${className}`} viewBox="0 0 76 48" aria-hidden="true">
      <path className="motion sky-moon" d="M44,10 A12,12 0 1 0 44,34 A9.5,12 0 1 1 44,10 Z" />
      {STARS.map(([x, y, s], i) => (
        <path key={i} d={sparkle(x, y, s)} className="motion sky-star" style={{ animationDelay: `${(i * 1.37).toFixed(2)}s` }} />
      ))}
    </svg>
  );
}

/**
 * Decorative concentric rings; the dot sits at the score's position on the outer ring. Ripples spread out from the
 * centre in the zone's colour, stronger the higher the score: recovery charging up.
 */
export function Rings({ value, tone }: { value: number; tone: 'red' | 'yellow' | 'green' | 'fitness' }) {
  const v = Math.min(1, Math.max(0, value));
  const a = Math.PI * (0.75 - 1.5 * v);
  return (
    <svg className={`rings rings-${tone}`} viewBox="0 0 120 120" aria-hidden="true" style={{ '--ripple-peak': (0.25 + 0.45 * v).toFixed(2) } as CSSProperties}>
      {[56, 44, 32, 20].map((r) => (
        <circle key={r} cx="60" cy="60" r={r} />
      ))}
      <circle cx="60" cy="60" r="56" className="motion rings-ripple" />
      <circle cx="60" cy="60" r="56" className="motion rings-ripple rings-ripple-b" />
      <circle cx={60 + 56 * Math.cos(a)} cy={60 - 56 * Math.sin(a)} r="3.5" className="rings-dot" />
    </svg>
  );
}

// ---------- heart monitor ----------

/** Monitor sweep speed in px per second, before rounding to a whole number of beats per sweep. */
const SWEEP_PX_PER_SEC = 52;
/** Glowing tail behind the sweep head, and the erased gap ahead of it, in px. */
const TRAIL = 90;
const GAP = 10;

/** Repeatable pseudo-random numbers, so a given reading always draws the same rhythm. */
function mulberry32(seed: number) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/**
 * n beat-to-beat intervals (s) averaging 60/bpm exactly, varying by the HRV. Successive differences are scaled
 * to the RMSSD (wrapping last to first, since the sweep loops), with part of the variation following the
 * breath, as the heart speeds on the inhale and slows on the exhale. No HRV, no variation.
 */
export function rrIntervals(n: number, bpm: number, hrvMs?: number | null, rpm?: number | null): number[] {
  const mean = beatSeconds(bpm);
  if (!usable(hrvMs) || n < 2) return Array(n).fill(mean);
  const rand = mulberry32(Math.round(bpm * 100 + hrvMs * 10));
  const breath = usable(rpm) ? breathSeconds(rpm) : 4;
  let t = 0;
  const e = Array.from({ length: n }, () => {
    const noise = rand() + rand() + rand() - 1.5;
    const rsa = Math.sin((2 * Math.PI * t) / breath);
    t += mean;
    return noise * 0.6 + rsa * 0.4;
  });
  const centre = (xs: number[]) => {
    const m = xs.reduce((a, b) => a + b, 0) / xs.length;
    return xs.map((x) => x - m);
  };
  const rmssd = (xs: number[]) => Math.sqrt(xs.reduce((a, x, i) => a + (xs[(i + 1) % xs.length] - x) ** 2, 0) / xs.length);
  let d = centre(e);
  const scale = Math.min(hrvMs / 1000, mean * 0.12) / (rmssd(d) || 1);
  d = centre(d.map((x) => clamp(x * scale, -mean * 0.2, mean * 0.2)));
  return d.map((x) => mean + x);
}

/** QRS complex as straight segments (s from the R peak, height in R units), so the spike stays sharp at any width. */
const QRS: [number, number][] = [
  [-0.035, 0],
  [-0.02, -0.12],
  [0, 1],
  [0.025, -0.3],
  [0.05, 0],
];

/** One beat's height at `tau` s from its R peak: P wave, QRS, and a T wave that stretches with the interval. */
function beat(tau: number, rr: number): number {
  let v = 0;
  if (tau > -0.22 && tau < -0.12) v += 0.11 * Math.sin((Math.PI * (tau + 0.22)) / 0.1);
  if (tau > QRS[0][0] && tau < QRS.at(-1)![0]) {
    for (let i = 0; i < QRS.length - 1; i++) {
      const [t0, v0] = QRS[i];
      const [t1, v1] = QRS[i + 1];
      if (tau >= t0 && tau <= t1) {
        v += v0 + ((tau - t0) / (t1 - t0)) * (v1 - v0);
        break;
      }
    }
  }
  const tLen = 0.2 * Math.sqrt(rr);
  if (tau > 0.12 && tau < 0.12 + tLen) v += 0.26 * Math.sin((Math.PI * (tau - 0.12)) / tLen) ** 1.4;
  return v;
}

/**
 * A monitor trace exactly `width` px wide holding a whole number of beats, so the sweep loops without a hitch:
 * the last beat's interval runs into the first beat of the next sweep.
 */
export function ecgTrace(width: number, height: number, bpm: number, hrvMs?: number | null, rpm?: number | null) {
  const mean = beatSeconds(bpm);
  const n = Math.max(2, Math.round(width / (SWEEP_PX_PER_SEC * mean)));
  const rr = rrIntervals(n, bpm, hrvMs, rpm);
  const seconds = rr.reduce((a, b) => a + b, 0);
  const pxPerSec = width / seconds;
  // R peaks a little in from the left, plus one beat either side, so waves crossing the seam are drawn on both ends.
  const peaks: { t: number; rr: number }[] = [];
  let t = rr[0] * 0.3;
  rr.forEach((r) => {
    peaks.push({ t, rr: r });
    t += r;
  });
  const all = [{ t: peaks.at(-1)!.t - seconds, rr: rr.at(-1)! }, ...peaks, { t: peaks[0].t + seconds, rr: rr[0] }];

  const times = new Set<number>();
  for (let x = 0; x <= width; x++) times.add(x / pxPerSec);
  for (const p of all) for (const [tau] of QRS) if (p.t + tau >= 0 && p.t + tau <= seconds) times.add(p.t + tau);
  const pad = 5;
  const yOf = (v: number) => pad + (1 - (v + 0.32) / 1.32) * (height - pad * 2);
  const d = [...times]
    .sort((a, b) => a - b)
    .map((s, i) => {
      const v = all.reduce((sum, p) => sum + beat(s - p.t, p.rr), 0);
      return `${i ? 'L' : 'M'}${(s * pxPerSec).toFixed(1)},${yOf(v).toFixed(1)}`;
    })
    .join('');
  return { d, seconds, beats: n };
}

/**
 * A simulated heart monitor: the classic sweep, drawing a PQRST trace left to right at the person's heart rate,
 * with beat-to-beat spacing varied by their HRV and swayed by their breathing. A glowing tail follows the head;
 * a small gap ahead of it erases the last sweep. All CSS: one transform loop, no per-frame script.
 * Reduced motion shows the whole trace, still.
 */
export function HeartTrace({
  bpm,
  hrvMs,
  rpm,
  height = 40,
  caption,
  color = 'var(--vital-pulse)',
}: {
  bpm: number;
  hrvMs?: number | null;
  rpm?: number | null;
  height?: number;
  caption?: string;
  color?: string;
}) {
  const [ref, width] = useWidth<HTMLDivElement>();
  const id = useSvgId('ecg');
  const w = Math.round(width);
  const trace = useMemo(() => (w > 40 && usable(bpm) ? ecgTrace(w, height, bpm, hrvMs, rpm) : null), [w, height, bpm, hrvMs, rpm]);
  return (
    <div className="heart-trace" style={{ color }} title={caption}>
      <div className="heart-trace-screen" ref={ref} style={{ height }} aria-hidden="true">
        {trace && (
          <svg width={w} height={height} style={{ '--sweep': `${trace.seconds.toFixed(3)}s`, '--sweep-w': `${w}px` } as CSSProperties}>
            <defs>
              <linearGradient id={`${id}-tail`}>
                <stop offset="0%" stopColor="#fff" stopOpacity="0" />
                <stop offset="70%" stopColor="#fff" stopOpacity="0.7" />
                <stop offset="100%" stopColor="#fff" stopOpacity="1" />
              </linearGradient>
              {/* Two copies, one sweep apart, so the tail wraps from the right edge onto the left. */}
              <mask id={`${id}-live`} maskUnits="userSpaceOnUse" x={0} y={0} width={w} height={height}>
                <g className="motion trace-sweep">
                  <rect x={-TRAIL} width={TRAIL} height={height} fill={`url(#${id}-tail)`} />
                  <rect x={w - TRAIL} width={TRAIL} height={height} fill={`url(#${id}-tail)`} />
                </g>
              </mask>
              <mask id={`${id}-old`} maskUnits="userSpaceOnUse" x={0} y={0} width={w} height={height}>
                <rect width={w} height={height} fill="#fff" />
                <g className="motion trace-sweep">
                  <rect x={0} width={GAP} height={height} fill="#000" />
                  <rect x={-w} width={GAP} height={height} fill="#000" />
                </g>
              </mask>
            </defs>
            <path d={trace.d} className="trace-old" mask={`url(#${id}-old)`} />
            <path d={trace.d} className="trace-live" mask={`url(#${id}-live)`} />
          </svg>
        )}
      </div>
      {caption && <div className="heart-trace-caption">{caption}</div>}
    </div>
  );
}
