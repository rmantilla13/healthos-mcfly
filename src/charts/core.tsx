import { type KeyboardEvent, type PointerEvent, type ReactNode, useCallback, useRef, useState } from 'react';

/**
 * Width of a container, kept current with a ResizeObserver. A callback ref, so it also
 * picks up an element that only mounts later (e.g. once data has arrived).
 */
export function useWidth<T extends HTMLElement>() {
  const [width, setWidth] = useState(0);
  const observer = useRef<ResizeObserver | null>(null);
  const ref = useCallback((el: T | null) => {
    observer.current?.disconnect();
    observer.current = null;
    if (!el) return;
    setWidth(el.getBoundingClientRect().width);
    observer.current = new ResizeObserver(([entry]) => setWidth(entry.contentRect.width));
    observer.current.observe(el);
  }, []);
  return [ref, width] as const;
}

/**
 * Hover and keyboard scrubbing over n evenly spaced items. The pointer snaps to the
 * nearest item, so readers aim at a date rather than a 2px line; arrow keys do the same.
 */
export function useScrub(n: number, xOf: (i: number) => number) {
  const [index, setIndex] = useState<number | null>(null);

  const onPointerMove = useCallback(
    (e: PointerEvent<SVGElement>) => {
      if (!n) return;
      const rect = (e.currentTarget as SVGElement).getBoundingClientRect();
      const x = e.clientX - rect.left;
      let best = 0;
      let bestDist = Infinity;
      for (let i = 0; i < n; i++) {
        const d = Math.abs(xOf(i) - x);
        if (d < bestDist) {
          best = i;
          bestDist = d;
        }
      }
      setIndex(best);
    },
    [n, xOf],
  );

  const onKeyDown = useCallback(
    (e: KeyboardEvent) => {
      if (!n) return;
      if (e.key === 'ArrowLeft' || e.key === 'ArrowRight') {
        e.preventDefault();
        setIndex((i) => Math.min(n - 1, Math.max(0, (i ?? n - 1) + (e.key === 'ArrowLeft' ? -1 : 1))));
      } else if (e.key === 'Home') setIndex(0);
      else if (e.key === 'End') setIndex(n - 1);
      else if (e.key === 'Escape') setIndex(null);
    },
    [n],
  );

  return {
    index,
    handlers: {
      onPointerMove,
      onPointerLeave: () => setIndex(null),
      onFocus: () => setIndex(n - 1),
      onBlur: () => setIndex(null),
      onKeyDown,
      tabIndex: 0,
    },
  };
}

/** Middle value (the mean of the two middle values for an even count), or null when there are none. */
export function median(values: number[]): number | null {
  if (!values.length) return null;
  const s = [...values].sort((a, b) => a - b);
  const mid = s.length >> 1;
  return s.length % 2 ? s[mid] : (s[mid - 1] + s[mid]) / 2;
}

/** Clean axis ticks: 1, 2, 2.5 or 5 times a power of ten. */
/** Decimals a tick step needs, so 0.5 steps read 96.5, 97.0, 97.5 rather than 97, 97, 98 (0.25 steps need two). */
export const stepDigits = (step: number | undefined) => (step ? (String(Number(step.toFixed(10))).split('.')[1]?.length ?? 0) : 0);

export function niceTicks(min: number, max: number, count = 4): number[] {
  if (!Number.isFinite(min) || !Number.isFinite(max)) return [];
  if (min === max) {
    min -= 1;
    max += 1;
  }
  const raw = (max - min) / count;
  const pow = 10 ** Math.floor(Math.log10(raw));
  const step = [1, 2, 2.5, 5, 10].map((m) => m * pow).find((s) => s >= raw) ?? raw;
  const ticks: number[] = [];
  for (let t = Math.floor(min / step) * step; t <= max + step * 0.001; t += step) ticks.push(Number(t.toFixed(10)));
  if (ticks.at(-1)! < max) ticks.push(ticks.at(-1)! + step);
  return ticks;
}

export function Tooltip({ x, y, width, children }: { x: number; y: number; width: number; children: ReactNode }) {
  const flip = x > width - 150;
  return (
    <div className="tooltip" style={{ left: x, top: y, transform: `translate(${flip ? 'calc(-100% - 12px)' : '12px'}, -50%)` }} role="status">
      {children}
    </div>
  );
}

export function TooltipRow({ color, value, label, kind = 'line' }: { color: string; value: ReactNode; label: ReactNode; kind?: 'line' | 'none' }) {
  return (
    <div className="tooltip-row">
      {kind === 'line' && <span className="tooltip-key" style={{ background: color }} />}
      <strong>{value}</strong>
      <span>{label}</span>
    </div>
  );
}

/** Smooth path through points (monotone cubic), so trend lines never overshoot their data. */
export function smoothPath(pts: [number, number][]): string {
  const n = pts.length;
  if (n === 0) return '';
  if (n === 1) return `M${pts[0][0]},${pts[0][1]}`;
  const dx: number[] = [];
  const slope: number[] = [];
  for (let i = 0; i < n - 1; i++) {
    dx.push(pts[i + 1][0] - pts[i][0]);
    slope.push((pts[i + 1][1] - pts[i][1]) / (dx[i] || 1));
  }
  const tangent: number[] = [slope[0]];
  for (let i = 1; i < n - 1; i++) tangent.push(slope[i - 1] * slope[i] <= 0 ? 0 : (slope[i - 1] + slope[i]) / 2);
  tangent.push(slope[n - 2]);
  for (let i = 0; i < n - 1; i++) {
    if (slope[i] === 0) {
      tangent[i] = tangent[i + 1] = 0;
      continue;
    }
    const a = tangent[i] / slope[i];
    const b = tangent[i + 1] / slope[i];
    const h = a * a + b * b;
    if (h > 9) {
      const t = 3 / Math.sqrt(h);
      tangent[i] = t * a * slope[i];
      tangent[i + 1] = t * b * slope[i];
    }
  }
  let d = `M${pts[0][0]},${pts[0][1]}`;
  for (let i = 0; i < n - 1; i++) {
    const [x0, y0] = pts[i];
    const [x1, y1] = pts[i + 1];
    const h = dx[i] / 3;
    d += ` C${x0 + h},${y0 + tangent[i] * h} ${x1 - h},${y1 - tangent[i + 1] * h} ${x1},${y1}`;
  }
  return d;
}

/** Bar path with a 4px rounded data end and a square foot on the baseline. */
export function barPath(x: number, y: number, w: number, h: number, r = 4): string {
  if (h <= 0) return '';
  const rr = Math.min(r, w / 2, h);
  return `M${x},${y + h} V${y + rr} Q${x},${y} ${x + rr},${y} H${x + w - rr} Q${x + w},${y} ${x + w},${y + rr} V${y + h} Z`;
}
