import { type CSSProperties, type Ref, useLayoutEffect, useMemo, useRef, useState } from 'react';
import type { PhotoMeta, Summary, Vital } from '../../shared/types.ts';
import { useWidth } from '../charts/core.tsx';
import { fmt, fmtDate, temp, useUnits } from '../lib.ts';

// The figure is drawn in a 600×640 space and shown through a tighter viewBox; callouts are
// positioned in the same coordinates (as percentages) so labels, lines and dots stay aligned at any size.
const W = 600;
const H = 640;
const VB = { x: 80, y: 24, w: 440, h: 600 };
const pctX = (x: number) => ((x - VB.x) / VB.w) * 100;
const pctY = (y: number) => ((y - VB.y) / VB.h) * 100;

const BODY =
  'M300,44 C338,44 363,72 363,116 C363,154 350,190 330,210 L332,260 C350,270 384,276 406,288 C430,301 442,326 446,364 ' +
  'L456,640 L144,640 L154,364 C158,326 170,301 194,288 C216,276 250,270 268,260 L270,210 C250,190 237,154 237,116 C237,72 262,44 300,44 Z';

type Callout = { key: keyof Summary['vitals']; dot: [number, number]; anchor: [number, number]; side: 'left' | 'right' };

const CALLOUTS: Callout[] = [
  { key: 'temp', dot: [258, 128], anchor: [214, 112], side: 'left' },
  { key: 'breathing', dot: [300, 246], anchor: [214, 230], side: 'left' },
  { key: 'heart', dot: [332, 372], anchor: [404, 226], side: 'right' },
];

const STATUS_TEXT = { low: 'Below your range', normal: 'Normal', high: 'Above your range' } as const;

function display(key: Callout['key'], v: Vital, units: ReturnType<typeof useUnits>) {
  if (!v.latest) return { value: '—', unit: '' };
  if (key === 'heart') return { value: fmt(v.latest.value), unit: 'bpm' };
  if (key === 'breathing') return { value: fmt(v.latest.value, 1), unit: 'rpm' };
  const t = temp(v.latest.value, units);
  return { value: fmt(t.value, 1), unit: t.unit };
}

function CalloutLabel({
  k,
  v,
  asOf,
  side,
  style,
  innerRef,
}: {
  k: Callout['key'];
  v: Vital;
  asOf: string;
  side: 'left' | 'right';
  style: CSSProperties;
  innerRef?: Ref<HTMLDivElement>;
}) {
  const units = useUnits();
  const d = display(k, v, units);
  const stale = v.latest && v.latest.date !== asOf;
  return (
    <div className={`callout callout-${side}`} style={style} ref={innerRef}>
      <div className="callout-label">{k === 'heart' ? 'Heart' : v.label}</div>
      <div className="callout-value">
        {d.value} <span>{d.unit}</span>
      </div>
      <div className="callout-status" title="From your latest night, compared with your own previous 30 days">
        {v.status ? STATUS_TEXT[v.status] : v.latest ? 'Building baseline' : 'No data'}
        {stale && v.latest ? ` · ${fmtDate(v.latest.date)}` : ''}
      </div>
    </div>
  );
}

export function Figure({ vitals, asOf, photo }: { vitals: Summary['vitals']; asOf: string; photo: PhotoMeta | null }) {
  return photo ? <PhotoFigure vitals={vitals} asOf={asOf} photo={photo} /> : <Silhouette vitals={vitals} asOf={asOf} />;
}

type Key = Callout['key'];
type Placed = { key: Key; side: 'left' | 'right'; x: number; y: number; w: number; h: number };

const LABEL_ORDER: { key: Key; side: 'left' | 'right' }[] = [
  { key: 'temp', side: 'left' },
  { key: 'breathing', side: 'left' },
  { key: 'heart', side: 'right' },
];

/**
 * Put each label in empty page space beside the silhouette, as close as possible (vertically) to its dot.
 * Left labels sit left of the outline, right labels right of it; all units are 0–1 of the cut-out.
 */
function placeLabels(photo: PhotoMeta, sizes: Record<Key, [number, number]>, width: number, height: number): Placed[] {
  const [fx, fy, fw, fh] = photo.face;
  // Older metadata has no outline: treat the face as the obstacle above the shoulders and everything below as body.
  const outline: [number, number][] =
    photo.outline ??
    Array.from({ length: 100 }, (_, i) => {
      const y = (i + 0.5) / 100;
      if (y >= photo.shoulderY - 0.04) return [0, 1];
      return y >= fy - fh * 0.15 ? [fx - fw * 0.1, fx + fw * 1.1] : [1, 0];
    });
  const rows = (top: number, bottom: number) => outline.slice(Math.max(0, Math.floor(top * 100)), Math.min(100, Math.ceil(bottom * 100)));
  const gapX = 12 / width;
  const gapY = 10 / height;

  const placed: Placed[] = [];
  for (const { key, side } of LABEL_ORDER) {
    const w = sizes[key][0] / width;
    const h = sizes[key][1] / height;
    const [dotX, dotY] = photo.dots[key];
    const minTop = key === 'breathing' ? (placed.find((p) => p.key === 'temp')?.y ?? 0) + (placed.find((p) => p.key === 'temp')?.h ?? 0) + gapY : 0;
    let best: Placed | null = null;
    let bestScore = Infinity;
    let widest: Placed | null = null;
    for (let top = minTop; top + h <= 1; top += 0.005) {
      const span = rows(top, top + h);
      let x: number;
      let fits: boolean;
      if (side === 'left') {
        x = Math.min(Math.min(...span.map((r) => r[0])) - gapX, dotX - gapX);
        fits = x - w >= 0;
      } else {
        x = Math.max(Math.max(...span.map((r) => r[1])) + gapX, dotX + gapX);
        fits = x + w <= 1;
      }
      const candidate: Placed = { key, side, x, y: top, w, h };
      const room = side === 'left' ? x - w : 1 - (x + w);
      if (!widest || room > (widest.side === 'left' ? widest.x - widest.w : 1 - (widest.x + widest.w))) widest = candidate;
      if (!fits) continue;
      const score = Math.abs(top + h / 2 - dotY);
      if (score < bestScore) {
        best = candidate;
        bestScore = score;
      }
    }
    // Nowhere free: use the roomiest spot and keep the label inside the figure.
    const p = best ?? (widest ? { ...widest, x: side === 'left' ? Math.max(widest.x, w) : Math.min(widest.x, 1 - w) } : { key, side, x: 0.5, y: 0, w, h });
    placed.push(p);
  }
  return placed;
}

/**
 * The user's own cut-out photo with the same fade. Callouts are pinned to points Vision found
 * (forehead, throat, chest); labels go in the page space beside the silhouette, measured from its outline.
 */
function PhotoFigure({ vitals, asOf, photo }: { vitals: Summary['vitals']; asOf: string; photo: PhotoMeta }) {
  const ratio = photo.height / photo.width;
  const [wrapRef, width] = useWidth<HTMLDivElement>();
  const height = width * ratio;
  const labelEls = useRef<Partial<Record<Key, HTMLDivElement | null>>>({});
  const [sizes, setSizes] = useState<Record<Key, [number, number]>>({ temp: [110, 64], breathing: [100, 64], heart: [100, 64] });

  // Labels are measured after each render (their text and the font size change with data and screen width).
  useLayoutEffect(() => {
    const next = { ...sizes };
    let changed = false;
    for (const { key } of LABEL_ORDER) {
      const el = labelEls.current[key];
      if (!el) continue;
      const m: [number, number] = [el.offsetWidth, el.offsetHeight];
      if (Math.abs(m[0] - sizes[key][0]) > 1 || Math.abs(m[1] - sizes[key][1]) > 1) {
        next[key] = m;
        changed = true;
      }
    }
    if (changed) setSizes(next);
  });

  const labels = useMemo(() => (width > 0 ? placeLabels(photo, sizes, width, height) : []), [photo, sizes, width, height]);
  // Leader lines meet each label beside its value line.
  const lineEnd = (l: Placed): [number, number] => [l.x + (l.side === 'left' ? 6 / width : -6 / width), l.y + 30 / height];

  return (
    <div className="figure figure-photo-wrap" ref={wrapRef} style={{ aspectRatio: `${photo.width} / ${photo.height}` }}>
      <PhotoToneFilters />
      <div className="figure-glow" />
      <img className="figure-photo" src={`/api/profile/cutout.png?v=${photo.version}`} alt="" />
      <svg className="figure-svg" viewBox={`0 0 1000 ${1000 * ratio}`} preserveAspectRatio="none" aria-hidden="true">
        {labels.map((l) => {
          const [dx, dy] = photo.dots[l.key];
          const [ex, ey] = lineEnd(l);
          // The viewBox scales with the photo; keep dots the same on-screen size as on the silhouette.
          const px = 1000 / width;
          return (
            <g key={l.key}>
              <line x1={dx * 1000} y1={dy * 1000 * ratio} x2={ex * 1000} y2={ey * 1000 * ratio} className="callout-line" />
              <circle cx={dx * 1000} cy={dy * 1000 * ratio} r={13 * px} className="callout-halo" />
              <circle cx={dx * 1000} cy={dy * 1000 * ratio} r={5 * px} className="callout-dot" />
            </g>
          );
        })}
      </svg>
      {LABEL_ORDER.map(({ key, side }) => {
        const l = labels.find((p) => p.key === key);
        return (
          <CalloutLabel
            key={key}
            k={key}
            v={vitals[key]}
            asOf={asOf}
            side={side}
            innerRef={(el) => {
              labelEls.current[key] = el;
            }}
            style={
              l
                ? { top: `${l.y * 100}%`, ...(side === 'left' ? { right: `${(1 - l.x) * 100}%` } : { left: `${l.x * 100}%` }) }
                : { top: 0, left: 0, visibility: 'hidden' }
            }
          />
        );
      })}
    </div>
  );
}

/**
 * Black-and-white grade for the profile photo: fully desaturated, with blacks lifted to the UI's warm ink
 * in the light theme (kept deep in the dark theme) so the photo sits softly on the page.
 */
function PhotoToneFilters() {
  return (
    <svg width="0" height="0" className="svg-defs" aria-hidden="true" focusable="false">
      <filter id="photo-tone-light" colorInterpolationFilters="sRGB">
        <feColorMatrix type="saturate" values="0" />
        <feComponentTransfer>
          <feFuncR type="table" tableValues="0.2 0.97" />
          <feFuncG type="table" tableValues="0.2 0.97" />
          <feFuncB type="table" tableValues="0.2 0.97" />
        </feComponentTransfer>
      </filter>
      <filter id="photo-tone-dark" colorInterpolationFilters="sRGB">
        <feColorMatrix type="saturate" values="0" />
        <feComponentTransfer>
          <feFuncR type="table" tableValues="0.06 0.93" />
          <feFuncG type="table" tableValues="0.06 0.93" />
          <feFuncB type="table" tableValues="0.06 0.93" />
        </feComponentTransfer>
      </filter>
    </svg>
  );
}

function Silhouette({ vitals, asOf }: { vitals: Summary['vitals']; asOf: string }) {
  return (
    <div className="figure" style={{ aspectRatio: `${VB.w} / ${VB.h}` }}>
      <svg viewBox={`${VB.x} ${VB.y} ${VB.w} ${VB.h}`} className="figure-svg" aria-hidden="true">
        <defs>
          <radialGradient id="fig-glow" cx="50%" cy="38%" r="55%">
            <stop offset="0%" stopColor="var(--figure-glow)" stopOpacity="1" />
            <stop offset="100%" stopColor="var(--figure-glow)" stopOpacity="0" />
          </radialGradient>
          <linearGradient id="fig-skin" x1="0" y1="0" x2="0.35" y2="1">
            <stop offset="0%" stopColor="var(--figure-1)" />
            <stop offset="60%" stopColor="var(--figure-2)" />
            <stop offset="100%" stopColor="var(--figure-3)" />
          </linearGradient>
          <radialGradient id="fig-light" cx="40%" cy="22%" r="45%">
            <stop offset="0%" stopColor="var(--figure-highlight)" stopOpacity="0.55" />
            <stop offset="100%" stopColor="var(--figure-highlight)" stopOpacity="0" />
          </radialGradient>
          <linearGradient id="fig-fade" x1="0" y1="0" x2="0" y2="1">
            <stop offset="0.55" stopColor="#fff" stopOpacity="1" />
            <stop offset="0.97" stopColor="#fff" stopOpacity="0" />
          </linearGradient>
          <mask id="fig-mask">
            <rect width={W} height={H} fill="url(#fig-fade)" />
          </mask>
          <filter id="fig-soft" x="-10%" y="-10%" width="120%" height="120%">
            <feGaussianBlur stdDeviation="1.4" />
          </filter>
          <filter id="fig-blur" x="-30%" y="-30%" width="160%" height="160%">
            <feGaussianBlur stdDeviation="22" />
          </filter>
        </defs>
        <ellipse cx="300" cy="300" rx="250" ry="290" fill="url(#fig-glow)" />
        <g mask="url(#fig-mask)">
          <path d={BODY} fill="var(--figure-shadow)" filter="url(#fig-blur)" transform="translate(10 18)" />
          <g filter="url(#fig-soft)">
            <ellipse cx="236" cy="138" rx="9" ry="19" fill="url(#fig-skin)" />
            <ellipse cx="364" cy="138" rx="9" ry="19" fill="url(#fig-skin)" />
            <path d={BODY} fill="url(#fig-skin)" />
            <path d={BODY} fill="url(#fig-light)" />
            <path d="M270,214 C284,232 316,232 330,214 L331,236 C318,250 282,250 269,236 Z" fill="var(--figure-shade)" opacity="0.5" />
          </g>
        </g>
        {CALLOUTS.map((c) => (
          <g key={c.key}>
            <line x1={c.dot[0]} y1={c.dot[1]} x2={c.anchor[0] + (c.side === 'left' ? 6 : -6)} y2={c.anchor[1] + 26} className="callout-line" />
            <circle cx={c.dot[0]} cy={c.dot[1]} r="15" className="callout-halo" />
            <circle cx={c.dot[0]} cy={c.dot[1]} r="5" className="callout-dot" />
          </g>
        ))}
      </svg>
      {CALLOUTS.map((c) => (
        <CalloutLabel
          key={c.key}
          k={c.key}
          v={vitals[c.key]}
          asOf={asOf}
          side={c.side}
          style={{
            top: `${pctY(c.anchor[1])}%`,
            ...(c.side === 'left' ? { right: `${100 - pctX(c.anchor[0])}%` } : { left: `${pctX(c.anchor[0])}%` }),
          }}
        />
      ))}
    </div>
  );
}
