// The figure beside your vitals, in the perspective you chose (Settings.perspective): your own photo ('portrait'), a
// digital human ('digital', a woman or a man), or none at all ('stats'). Each callout points at its place on the body
// (forehead or wrist, throat, shoulder, chest) with the latest reading, animated by it.
import '../styles/figure.css';
import { type CSSProperties, type Ref, useEffect, useId, useLayoutEffect, useMemo, useRef, useState } from 'react';
import type { FigureVariant, Perspective, PhotoMeta, Settings, Summary, Vital } from '../../shared/types.ts';
import { useWidth } from '../charts/core.tsx';
import { fmt, fmtDate, temp, useUnits } from '../lib.ts';
import { PhotoReveal } from './PhotoReveal.tsx';

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

/** A callout: temperature, breathing, heart or blood oxygen. */
export type CalloutKey = keyof Summary['vitals'];
type Callout = { key: CalloutKey; dot: [number, number]; anchor: [number, number]; side: 'left' | 'right' };

/** Home's set (as designed: blood oxygen and heart on the left, breathing on the right); Sleep keeps temperature. */
export const DEFAULT_CALLOUTS: CalloutKey[] = ['temp', 'breathing', 'heart'];

const SILHOUETTE: Record<'forehead' | 'wrist' | 'shoulder', Callout[]> = {
  forehead: [
    { key: 'temp', dot: [258, 128], anchor: [214, 112], side: 'left' },
    { key: 'breathing', dot: [300, 246], anchor: [214, 230], side: 'left' },
    { key: 'heart', dot: [332, 372], anchor: [404, 226], side: 'right' },
  ],
  // The silhouette has no hands, so the dot sits low on the left arm, above where the figure fades out.
  // Breathing's label moves up to leave the slot below it for temperature.
  wrist: [
    { key: 'breathing', dot: [300, 246], anchor: [214, 140], side: 'left' },
    { key: 'temp', dot: [168, 456], anchor: [214, 230], side: 'left' },
    { key: 'heart', dot: [332, 372], anchor: [404, 226], side: 'right' },
  ],
  // With blood oxygen (Home): its dot on the shoulder and heart's label both on the left, breathing on the right.
  shoulder: [
    { key: 'spo2', dot: [258, 290], anchor: [214, 190], side: 'left' },
    { key: 'heart', dot: [332, 372], anchor: [214, 300], side: 'left' },
    { key: 'breathing', dot: [300, 246], anchor: [404, 190], side: 'right' },
  ],
};

/** Wrist and skin temperature come from a watch or band, so they go at the wrist; body temperature (a thermometer) stays on the forehead. */
const atWrist = (v: Vital) => v.label === 'Wrist temp' || v.label === 'Skin temp';

/**
 * How a callout is coloured: green within the person's usual, amber beyond it, red well beyond it. A reading older
 * than the figure's day stays neutral (its date shows instead), so last week's number never alarms today's figure.
 */
type Level = 'normal' | 'unusual' | 'off' | 'none';
function levelOf(v: Vital, asOf: string): Level {
  if (!v.latest || v.latest.date !== asOf || !v.status) return 'none';
  // Servers before levels: the status alone says normal or not.
  return v.level ?? (v.status === 'normal' ? 'normal' : 'unusual');
}

/** The words with the colour, so it never rests on colour alone. */
function statusText(v: Vital) {
  if (!v.status) return v.latest ? 'Building baseline' : 'No data';
  if (v.status === 'normal') return 'Normal';
  const up = v.status === 'high';
  if (v.level === 'off') return up ? 'Well above usual' : 'Well below usual';
  return up ? 'Above usual' : 'Below usual';
}

/** The value and its unit; with no reading a dash, still with its unit ("— %"). */
function display(key: CalloutKey, v: Vital, units: ReturnType<typeof useUnits>) {
  const n = v.latest?.value;
  if (key === 'heart') return { value: n === undefined ? null : fmt(n), unit: 'bpm' };
  if (key === 'breathing') return { value: n === undefined ? null : fmt(n, 1), unit: '/min' };
  if (key === 'spo2') return { value: n === undefined ? null : fmt(n, Number.isInteger(n) ? 0 : 1), unit: '%' };
  const t = temp(n ?? 0, units);
  return { value: n === undefined ? null : fmt(t.value, 1), unit: t.unit };
}

/** Servers before the blood oxygen callout send no spo2: shown as no reading. */
const NO_SPO2: Vital = { label: 'Blood oxygen', latest: null, status: null, level: null };
const vitalOf = (vitals: Summary['vitals'], k: CalloutKey): Vital => (k === 'spo2' ? (vitals.spo2 ?? NO_SPO2) : vitals[k]);

/**
 * While Home's timeline is scrubbed, the heart callout shows that hour's average heart rate instead of the resting
 * rate, with its hour as the status (bpm null: no reading in that hour). It has no level: that's for resting rates.
 */
export type HeartScrub = { bpm: number | null; label: string };

function CalloutLabel({
  k,
  v,
  asOf,
  side,
  style,
  innerRef,
  scrub,
}: {
  k: CalloutKey;
  v: Vital;
  asOf: string;
  side: 'left' | 'right';
  style: CSSProperties;
  innerRef?: Ref<HTMLDivElement>;
  scrub?: HeartScrub | null;
}) {
  const units = useUnits();
  if (k === 'heart' && scrub)
    return (
      <div className={`callout callout-${side} is-scrubbed`} style={style} ref={innerRef}>
        <div className="callout-label">Heart</div>
        <div className="callout-value">
          {scrub.bpm === null ? '—' : fmt(scrub.bpm)} <span>bpm</span>
        </div>
        <div className="callout-status">{scrub.label}</div>
      </div>
    );
  const d = display(k, v, units);
  const stale = v.latest && v.latest.date !== asOf;
  const level = levelOf(v, asOf);
  return (
    <div className={`callout callout-${side}${d.value === null ? ' is-empty' : ''}`} style={style} ref={innerRef}>
      <div className="callout-label">{k === 'heart' ? 'Heart' : v.label}</div>
      <div className="callout-value">
        {d.value === null ? (
          <b className="callout-dash" role="img" aria-label="No reading">
            —
          </b>
        ) : (
          d.value
        )}{' '}
        <span>{d.unit}</span>
      </div>
      {/* Nothing to compare without a reading, so no status line then. */}
      {v.latest && (
        <div className="callout-status" title="From your latest night, compared with your own previous 30 days">
          {level !== 'none' && <i className="callout-level" data-level={level} aria-hidden="true" />}
          {statusText(v)}
          {stale ? ` · ${fmtDate(v.latest.date)}` : ''}
        </div>
      )}
    </div>
  );
}

const clamp = (n: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, n));

/**
 * CSS custom properties that drive a callout's animation from its reading, or null when there's nothing to show.
 * Heart beats once per 60/bpm s and breathing cycles once per 60/rpm s; the clamps only catch impossible data,
 * so a bad row can't freeze or strobe the dot. Every dot's colour, and temperature's glow, come from its level.
 */
function liveVars(k: Key, v: Vital, scrub?: HeartScrub | null): CSSProperties | null {
  const value = k === 'heart' && scrub ? scrub.bpm : v.latest?.value;
  if (value == null || !Number.isFinite(value)) return null;
  if (k === 'heart') return value > 0 ? ({ '--beat': `${(60 / clamp(value, 30, 220)).toFixed(3)}s` } as CSSProperties) : null;
  if (k === 'breathing') return value > 0 ? ({ '--breath': `${(60 / clamp(value, 4, 40)).toFixed(3)}s` } as CSSProperties) : null;
  return {};
}

/**
 * A callout's dot and halo, animated by its own number (styles.css, "vitals animations"): the heart dot beats with
 * a pulse ring at the resting rate, the throat halo breathes at the respiratory rate, and the temperature glows
 * in its level's colour. Each dot is green, amber or red by how far it is from the person's usual (levelOf).
 * Radii are in the parent SVG's units.
 */
function CalloutMark({ k, v, asOf, cx, cy, halo, dot, scrub }: { k: Key; v: Vital; asOf: string; cx: number; cy: number; halo: number; dot: number; scrub?: HeartScrub | null }) {
  // Sanitised so the id is safe inside url(#…) whatever format React's ids take.
  const glowId = `temp-glow-${useId().replace(/[^\w-]/g, '')}`;
  const scrubbed = k === 'heart' && !!scrub;
  const vars = liveVars(k, v, scrub);
  return (
    <g className={`callout-mark mark-${k}${vars ? ' is-live' : ''}`} style={vars ?? undefined} data-level={scrubbed ? 'none' : levelOf(v, asOf)}>
      {k === 'temp' && vars && (
        <>
          <radialGradient id={glowId}>
            <stop offset="0%" className="temp-glow-stop" stopOpacity="0.85" />
            <stop offset="45%" className="temp-glow-stop" stopOpacity="0.4" />
            <stop offset="100%" className="temp-glow-stop" stopOpacity="0" />
          </radialGradient>
          <circle cx={cx} cy={cy} r={halo * 2.4} fill={`url(#${glowId})`} className="temp-glow" />
        </>
      )}
      <circle cx={cx} cy={cy} r={halo} className="callout-halo" />
      {k === 'heart' && vars && <circle cx={cx} cy={cy} r={halo} className="pulse-ring" />}
      <circle cx={cx} cy={cy} r={dot} className="callout-dot" />
    </g>
  );
}

/** The digital human to show: the one chosen, else the one that follows gender (woman or man), else the man. */
export const figureVariant = (s: Pick<Settings, 'figure' | 'gender'> | undefined): FigureVariant => s?.figure ?? (s?.gender === 'woman' ? 'woman' : 'man');

/**
 * The figure for a perspective: 'portrait' is your photo (the digital human until you add one), 'digital' the woman
 * or man figure, 'stats' nothing at all (the page lays out without it). `callouts` picks which vitals point at it.
 */
export function Figure({
  vitals,
  asOf,
  photo,
  heartScrub,
  perspective = 'portrait',
  figure = 'man',
  callouts = DEFAULT_CALLOUTS,
}: {
  vitals: Summary['vitals'];
  asOf: string;
  photo: PhotoMeta | null;
  heartScrub?: HeartScrub | null;
  perspective?: Perspective;
  figure?: FigureVariant;
  callouts?: CalloutKey[];
}) {
  if (perspective === 'stats') return null;
  if (perspective === 'portrait' && photo) return <PhotoFigure vitals={vitals} asOf={asOf} photo={photo} scrub={heartScrub} callouts={callouts} />;
  return <DigitalFigure key={figure} vitals={vitals} asOf={asOf} variant={figure} scrub={heartScrub} callouts={callouts} />;
}

type Key = CalloutKey;
type Side = 'left' | 'right';
type Placed = { key: Key; side: Side; x: number; y: number; w: number; h: number };
type Slot = { key: Key; side: Side; overFade: boolean };
/** Photos processed since the Vision tool looked for wrists also carry a wrist point (server/photo/cutout.swift). */
type PhotoDots = PhotoMeta['dots'] & { wrist?: [number, number] };

/** The photo fades out toward the bottom (.figure-photo's mask); from here down it's faint enough to write over. */
const FADED_FROM = 0.8;

/**
 * Where each callout points on the photo, and which side its label goes. Wrist temperature uses the wrist when
 * Vision found one, with its label on the wrist's side; on each side labels run top to bottom by their dots, so
 * leader lines never cross.
 */
function photoLayout(photo: PhotoMeta, wristTemp: boolean, callouts: CalloutKey[]) {
  const wrist = wristTemp ? (photo.dots as PhotoDots).wrist : undefined;
  const dots: Record<Key, [number, number]> = { temp: wrist ?? photo.dots.temp, breathing: photo.dots.breathing, heart: photo.dots.heart, spo2: spo2Dot(photo) };
  // With blood oxygen (Home's set), its label and heart's go on the left and breathing's on the right, as designed.
  const withSpo2 = callouts.includes('spo2');
  const all: Slot[] = [
    // Below the shoulders the arms fill the width, so a wrist label may sit over the faded bottom instead.
    { key: 'temp', side: wrist && wrist[0] >= 0.5 ? 'right' : 'left', overFade: !!wrist },
    { key: 'breathing', side: withSpo2 ? 'right' : 'left', overFade: false },
    { key: 'heart', side: withSpo2 ? 'left' : 'right', overFade: false },
    { key: 'spo2', side: 'left', overFade: false },
  ];
  const slots = all.filter((x) => callouts.includes(x.key));
  slots.sort((a, b) => dots[a.key][1] - dots[b.key][1]);
  return { dots, slots };
}

/**
 * Blood oxygen's dot on a photo: on the shoulder line (just under shoulderY), on the side opposite the heart dot.
 * Photos carry no such point (Vision and MediaPipe give forehead, throat, chest and wrist), so it's derived: the chest
 * dot mirrored across the throat, then a third of the way on toward the outline's edge on that row.
 */
function spo2Dot(photo: PhotoMeta): [number, number] {
  const [bx] = photo.dots.breathing;
  const [hx] = photo.dots.heart;
  const y = Math.min(1, photo.shoulderY + 0.03);
  const mirrored = 2 * bx - hx;
  const row = photo.outline?.[Math.min(99, Math.max(0, Math.floor(y * 100)))];
  const toLeft = mirrored <= bx;
  const edge = row && row[0] <= row[1] ? (toLeft ? row[0] : row[1]) : mirrored + (toLeft ? -0.15 : 0.15);
  return [mirrored + (edge - mirrored) * 0.35, y];
}

/**
 * Put each label in empty page space beside the silhouette, as close as possible (vertically) to its dot.
 * Left labels sit left of the outline, right labels right of it; all units are 0–1 of the cut-out.
 */
function placeLabels(
  photo: PhotoMeta,
  dots: Record<Key, [number, number]>,
  slots: Slot[],
  sizes: Record<Key, [number, number]>,
  width: number,
  height: number,
): Placed[] {
  const [fx, fy, fw, fh] = photo.face;
  // Older metadata has no outline: treat the face as the obstacle above the shoulders and everything below as body.
  const outline: [number, number][] =
    photo.outline ??
    Array.from({ length: 100 }, (_, i) => {
      const y = (i + 0.5) / 100;
      if (y >= photo.shoulderY - 0.04) return [0, 1];
      return y >= fy - fh * 0.15 ? [fx - fw * 0.1, fx + fw * 1.1] : [1, 0];
    });
  // Rows the label would cover; with overFade, rows in the faded bottom count as empty page.
  const rows = (top: number, bottom: number, overFade: boolean) => {
    const from = Math.max(0, Math.floor(top * 100));
    return outline
      .slice(from, Math.min(100, Math.ceil(bottom * 100)))
      .map((r, i): [number, number] => (overFade && (from + i) / 100 >= FADED_FROM ? [1, 0] : r));
  };
  const gapX = 12 / width;
  const gapY = 10 / height;

  const placed: Placed[] = [];
  for (const { key, side, overFade } of slots) {
    const w = sizes[key][0] / width;
    const h = sizes[key][1] / height;
    const [dotX, dotY] = dots[key];
    // Below the label above it on the same side.
    const above = placed.filter((p) => p.side === side).at(-1);
    const minTop = above ? above.y + above.h + gapY : 0;
    let best: Placed | null = null;
    let bestScore = Infinity;
    let widest: Placed | null = null;
    for (let top = minTop; top + h <= 1; top += 0.005) {
      const span = rows(top, top + h, overFade);
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
 * (forehead or wrist, throat, chest); labels go in the page space beside the silhouette, measured from its outline.
 */
function PhotoFigure({ vitals, asOf, photo, scrub, callouts }: { vitals: Summary['vitals']; asOf: string; photo: PhotoMeta; scrub?: HeartScrub | null; callouts: CalloutKey[] }) {
  const ratio = photo.height / photo.width;
  const [wrapRef, width] = useWidth<HTMLDivElement>();
  const height = width * ratio;
  const labelEls = useRef<Partial<Record<Key, HTMLDivElement | null>>>({});
  const [sizes, setSizes] = useState<Record<Key, [number, number]>>({ temp: [110, 64], breathing: [100, 64], heart: [100, 64], spo2: [110, 64] });
  const wristTemp = atWrist(vitals.temp);
  const set = callouts.join(',');
  const { dots, slots } = useMemo(() => photoLayout(photo, wristTemp, set.split(',') as CalloutKey[]), [photo, wristTemp, set]);

  // Labels are measured after each render (their text and the font size change with data and screen width).
  useLayoutEffect(() => {
    const next = { ...sizes };
    let changed = false;
    for (const { key } of slots) {
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

  const labels = useMemo(
    () => (width > 0 ? placeLabels(photo, dots, slots, sizes, width, height) : []),
    [photo, dots, slots, sizes, width, height],
  );
  // Leader lines meet each label beside its value line.
  const lineEnd = (l: Placed): [number, number] => [l.x + (l.side === 'left' ? 6 / width : -6 / width), l.y + 30 / height];

  return (
    <div className="figure figure-photo-wrap" ref={wrapRef} style={{ aspectRatio: `${photo.width} / ${photo.height}` }}>
      <PhotoToneFilters />
      <div className="figure-glow" />
      <PhotoReveal className="figure-photo" src={`/api/profile/cutout.png?v=${photo.version}`} version={photo.version} />
      <svg className="figure-svg" viewBox={`0 0 1000 ${1000 * ratio}`} preserveAspectRatio="none" aria-hidden="true">
        {labels.map((l) => {
          const [dx, dy] = dots[l.key];
          const [ex, ey] = lineEnd(l);
          // The viewBox scales with the photo; keep dots the same on-screen size as on the silhouette.
          const px = 1000 / width;
          return (
            <g key={l.key}>
              <line x1={dx * 1000} y1={dy * 1000 * ratio} x2={ex * 1000} y2={ey * 1000 * ratio} className="callout-line" />
              <CalloutMark k={l.key} v={vitalOf(vitals, l.key)} asOf={asOf} cx={dx * 1000} cy={dy * 1000 * ratio} halo={13 * px} dot={5 * px} scrub={scrub} />
            </g>
          );
        })}
      </svg>
      {slots.map(({ key, side }) => {
        const l = labels.find((p) => p.key === key);
        return (
          <CalloutLabel
            key={key}
            k={key}
            v={vitalOf(vitals, key)}
            asOf={asOf}
            side={side}
            scrub={scrub}
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
 * in the light theme (kept deep in the dark theme) so the photo sits softly on the page. The shell renders it
 * once too, for the avatar on every page.
 */
export function PhotoToneFilters() {
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

function Silhouette({ vitals, asOf, scrub, keys = DEFAULT_CALLOUTS }: { vitals: Summary['vitals']; asOf: string; scrub?: HeartScrub | null; keys?: CalloutKey[] }) {
  const layout = keys.includes('spo2') ? 'shoulder' : atWrist(vitals.temp) ? 'wrist' : 'forehead';
  const callouts = SILHOUETTE[layout].filter((c) => keys.includes(c.key));
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
        {callouts.map((c) => (
          <g key={c.key}>
            <line x1={c.dot[0]} y1={c.dot[1]} x2={c.anchor[0] + (c.side === 'left' ? 6 : -6)} y2={c.anchor[1] + 26} className="callout-line" />
            <CalloutMark k={c.key} v={vitalOf(vitals, c.key)} asOf={asOf} cx={c.dot[0]} cy={c.dot[1]} halo={15} dot={5} scrub={scrub} />
          </g>
        ))}
      </svg>
      {callouts.map((c) => (
        <CalloutLabel
          key={c.key}
          k={c.key}
          v={vitalOf(vitals, c.key)}
          asOf={asOf}
          side={c.side}
          scrub={scrub}
          style={{
            top: `${pctY(c.anchor[1])}%`,
            ...(c.side === 'left' ? { right: `${100 - pctX(c.anchor[0])}%` } : { left: `${pctX(c.anchor[0])}%` }),
          }}
        />
      ))}
    </div>
  );
}

// ---------- the digital human ----------

type Point = [number, number];
/** One callout on an artwork, as fractions of its width and height: the dot, where its label's top-left goes, and where
 * the leader line from the dot ends beside the label. */
type ArtCallout = { dot: Point; label: Point; line: Point; side: 'left' | 'right' };
type Art = { src: string; width: number; height: number; callouts: Record<CalloutKey | 'wrist', ArtCallout> };

/**
 * Every digital-human artwork and where its callouts go. New art needs only its entry here: the file in
 * public/figures/ and these fractions. Temperature has two places (forehead, or the wrist for a watch or band's
 * reading); the wrist one takes blood oxygen's label spot, as no page shows both.
 */
const MAN: Art = {
  src: '/figures/digital-man.webp',
  width: 640,
  height: 600,
  callouts: {
    spo2: { dot: [0.397, 0.2095], label: [0.016, 0.163], line: [0.094, 0.18], side: 'left' },
    breathing: { dot: [0.495, 0.17], label: [0.92, 0.15], line: [0.909, 0.165], side: 'right' },
    heart: { dot: [0.534, 0.2505], label: [0.016, 0.28], line: [0.07, 0.297], side: 'left' },
    temp: { dot: [0.494, 0.075], label: [0.6, 0.0], line: [0.592, 0.035], side: 'right' },
    wrist: { dot: [0.0625, 0.233], label: [0.016, 0.135], line: [0.06, 0.2], side: 'left' },
  },
};
const ART: Record<FigureVariant, Art> = {
  man: MAN,
  // Until the woman's render arrives it uses the man's places; the file itself falls back to the man's (DigitalFigure).
  woman: { ...MAN, src: '/figures/digital-woman.webp' },
};

/** Whether the woman's file loaded, once anything asked: null until then. Kept while the page is open, so later labels don't flicker. */
let womanLoads: boolean | null = null;

/**
 * The digital human actually drawn for `variant`: the woman only once her file loads, as DigitalFigure falls back to the
 * man without it. Every label that names the figure uses this, so none says "woman" over the man's artwork, and
 * dropping her file into public/figures/ makes them all say so.
 */
export function useDrawnVariant(variant: FigureVariant): FigureVariant {
  const [woman, setWoman] = useState(womanLoads);
  useEffect(() => {
    if (variant !== 'woman') return;
    // Another label's probe may have finished since this one rendered.
    if (womanLoads !== null) return setWoman(womanLoads);
    let alive = true;
    const img = new Image();
    const done = (ok: boolean) => {
      womanLoads = ok;
      if (alive) setWoman(ok);
    };
    img.onload = () => done(true);
    img.onerror = () => done(false);
    img.src = ART.woman.src;
    return () => {
      alive = false;
    };
  }, [variant]);
  return variant === 'woman' && woman ? 'woman' : 'man';
}

/**
 * The digital human: the artwork for `variant`, falling back to the man's when that file is missing, and to the drawn
 * silhouette when neither loads, so a new file dropped into public/figures/ just works.
 */
function DigitalFigure({ vitals, asOf, variant, scrub, callouts }: { vitals: Summary['vitals']; asOf: string; variant: FigureVariant; scrub?: HeartScrub | null; callouts: CalloutKey[] }) {
  const [shown, setShown] = useState<FigureVariant | null>(variant);
  const [wrapRef, width] = useWidth<HTMLDivElement>();
  const labelEls = useRef<Partial<Record<Key, HTMLDivElement | null>>>({});
  // How far each label moved from its place in the table: down, below the label above it on the same side (a reading
  // adds a status line, and a small figure has less room), and left, to stay inside the figure. In pixels.
  const [nudge, setNudge] = useState<Partial<Record<Key, [number, number]>>>({});
  const art = ART[shown ?? 'man'];
  const ratio = art.height / art.width;
  const height = width * ratio;
  const wrist = atWrist(vitals.temp);
  const spot = (k: CalloutKey) => art.callouts[k === 'temp' && wrist ? 'wrist' : k];

  useLayoutEffect(() => {
    if (!width) return;
    const next: Partial<Record<Key, [number, number]>> = {};
    for (const side of ['left', 'right'] as const) {
      let bottom = -Infinity;
      for (const k of callouts.filter((c) => spot(c).side === side).sort((a, b) => spot(a).label[1] - spot(b).label[1])) {
        const el = labelEls.current[k];
        if (!el) continue;
        const top = spot(k).label[1] * height;
        const dy = Math.max(0, bottom + 6 - top);
        const dx = Math.min(0, width - (spot(k).label[0] * width + el.offsetWidth));
        next[k] = [dx, dy];
        bottom = top + dy + el.offsetHeight;
      }
    }
    const same = callouts.every((k) => (nudge[k]?.[0] ?? 0) === (next[k]?.[0] ?? 0) && (nudge[k]?.[1] ?? 0) === (next[k]?.[1] ?? 0));
    if (!same) setNudge(next);
  });

  if (!shown) return <Silhouette vitals={vitals} asOf={asOf} scrub={scrub} keys={callouts} />;
  // Dots keep the same on-screen size whatever the figure's width (the viewBox scales with it).
  const px = width > 0 ? 1000 / width : 1;
  return (
    <div className="figure figure-digital" ref={wrapRef} style={{ aspectRatio: `${art.width} / ${art.height}` }}>
      <img className="figure-art" src={art.src} alt="" onError={() => setShown(shown === 'man' ? null : 'man')} />
      <svg className="figure-svg" viewBox={`0 0 1000 ${1000 * ratio}`} preserveAspectRatio="none" aria-hidden="true">
        {callouts.map((k) => {
          const c = spot(k);
          const [dx, dy] = nudge[k] ?? [0, 0];
          return (
            <g key={k}>
              <line x1={c.dot[0] * 1000} y1={c.dot[1] * 1000 * ratio} x2={c.line[0] * 1000 + dx * px} y2={c.line[1] * 1000 * ratio + dy * px} className="callout-line" />
              <CalloutMark k={k} v={vitalOf(vitals, k)} asOf={asOf} cx={c.dot[0] * 1000} cy={c.dot[1] * 1000 * ratio} halo={9 * px} dot={3.5 * px} scrub={scrub} />
            </g>
          );
        })}
      </svg>
      {callouts.map((k) => {
        const c = spot(k);
        const [dx, dy] = nudge[k] ?? [0, 0];
        return (
          <CalloutLabel
            key={k}
            k={k}
            v={vitalOf(vitals, k)}
            asOf={asOf}
            side={c.side}
            scrub={scrub}
            innerRef={(el) => {
              labelEls.current[k] = el;
            }}
            style={{ left: `calc(${c.label[0] * 100}% + ${dx}px)`, top: `calc(${c.label[1] * 100}% + ${dy}px)` }}
          />
        );
      })}
    </div>
  );
}
