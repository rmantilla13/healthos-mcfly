// The profile photo's entrance: it's uncovered from the bottom up, and just ahead of the rising edge the
// photo is drawn as flickering ASCII characters (denser glyphs where the photo is darker, or lighter in
// dark mode), which the real image then replaces. Once per page load and photo; skipped for reduced motion.
import { useEffect, useRef, useState } from 'react';

const played = new Set<number>();
const RAMP = ' .:-=+*#%@';
const DURATION = 2160;
/** The ASCII band's height, as a fraction of the photo. */
const BAND = 0.2;
/** Where the edge starts: lower than this the photo's own fade (.figure-photo's mask) leaves too little to see. */
const START = 0.88;

const reducedMotion = () => matchMedia('(prefers-reduced-motion: reduce)').matches;
/** Quicker through the faint bottom of the photo, slowing as it reaches the face, still moving to the end. */
const easeOut = (t: number) => 1 - (1 - t) ** 2;

/** The same vertical fade the photo wears, so the characters fade out exactly where the photo does. */
function photoFade(y: number) {
  if (y <= 0.42) return 1;
  if (y <= 0.66) return 1 - ((y - 0.42) / 0.24) * 0.45;
  if (y <= 0.92) return 0.55 * (1 - (y - 0.66) / 0.26);
  return 0;
}

/** Ink is light in dark mode: then bright parts of the photo get the dense glyphs. */
function inkIsLight(ink: string) {
  const probe = document.createElement('canvas').getContext('2d')!;
  probe.fillStyle = ink;
  const hex = probe.fillStyle; // normalized to #rrggbb
  const n = parseInt(hex.slice(1), 16);
  return ((n >> 16) & 255) * 0.299 + ((n >> 8) & 255) * 0.587 + (n & 255) * 0.114 > 128;
}

function run(img: HTMLImageElement, canvas: HTMLCanvasElement, onDone: () => void) {
  const w = img.clientWidth;
  const h = img.clientHeight;
  const ctx = canvas.getContext('2d');
  if (!w || !h || !ctx) return onDone(), () => {};
  const dpr = Math.min(window.devicePixelRatio || 1, 2);
  canvas.width = Math.round(w * dpr);
  canvas.height = Math.round(h * dpr);
  ctx.scale(dpr, dpr);

  const charH = Math.max(7, Math.round(h / 70));
  ctx.font = `${charH}px ui-monospace, SFMono-Regular, Menlo, monospace`;
  const charW = Math.max(4, ctx.measureText('M').width);
  const cols = Math.ceil(w / charW);
  const rows = Math.ceil(h / charH);

  // One sample per character cell: how present the cut-out is there, and how bright.
  const sample = document.createElement('canvas');
  sample.width = cols;
  sample.height = rows;
  const sctx = sample.getContext('2d', { willReadFrequently: true })!;
  sctx.drawImage(img, 0, 0, cols, rows);
  const px = sctx.getImageData(0, 0, cols, rows).data;
  const ink = getComputedStyle(document.documentElement).getPropertyValue('--ink').trim() || '#0b0b0b';
  const light = inkIsLight(ink);
  const level = new Int8Array(cols * rows).fill(-1);
  for (let i = 0; i < cols * rows; i++) {
    const a = px[i * 4 + 3] / 255;
    if (a < 0.35) continue;
    const lum = (px[i * 4] * 0.299 + px[i * 4 + 1] * 0.587 + px[i * 4 + 2] * 0.114) / 255;
    const density = light ? lum : 1 - lum;
    level[i] = Math.min(RAMP.length - 1, Math.max(1, Math.round(density * (RAMP.length - 1))));
  }

  ctx.fillStyle = ink;
  ctx.textBaseline = 'top';
  // The clock starts at the first frame drawn: a tab opened in the background shows the reveal when it's
  // looked at, instead of finishing unseen.
  let t0 = -1;
  let frame = 0;
  const tick = (now: number) => {
    if (t0 < 0) t0 = now;
    const t = Math.min(1, (now - t0) / DURATION);
    // The edge rises from the bottom of the visible photo to just past the top, band and all.
    const edge = START - easeOut(t) * (START + BAND);
    img.style.clipPath = `inset(${Math.max(0, edge * 100)}% 0 0 0)`;
    ctx.clearRect(0, 0, w, h);
    const top = Math.max(0, Math.floor((edge - BAND) * rows));
    const bottom = Math.min(rows - 1, Math.ceil((edge + 0.02) * rows));
    for (let r = top; r <= bottom; r++) {
      const y = (r + 0.5) / rows;
      // 0 at the edge, 1 at the top of the band: the band thins and fades as it gets further from the photo.
      const d = Math.min(1, Math.max(0, (edge - y) / BAND));
      const fade = photoFade(y);
      if (fade <= 0) continue;
      for (let c = 0; c < cols; c++) {
        const base = level[r * cols + c];
        if (base < 0 || Math.random() < d * 0.85) continue;
        const flicker = Math.random() < 0.3 ? (Math.random() < 0.5 ? -1 : 1) : 0;
        const ch = RAMP[Math.min(RAMP.length - 1, Math.max(1, base + flicker))];
        ctx.globalAlpha = fade * (1 - d * 0.8) * (y > edge ? 0.5 : 1);
        ctx.fillText(ch, c * charW, r * charH);
      }
    }
    if (t < 1) frame = requestAnimationFrame(tick);
    else {
      img.style.clipPath = '';
      onDone();
    }
  };
  frame = requestAnimationFrame(tick);
  return () => {
    cancelAnimationFrame(frame);
    img.style.clipPath = '';
  };
}

export function PhotoReveal({ src, version, className }: { src: string; version: number; className: string }) {
  const img = useRef<HTMLImageElement>(null);
  const canvas = useRef<HTMLCanvasElement>(null);
  const [reveal] = useState(() => !played.has(version) && !reducedMotion());
  const [done, setDone] = useState(!reveal);

  useEffect(() => {
    const el = img.current;
    const cv = canvas.current;
    if (!reveal || done || !el || !cv) return;
    let stop = () => {};
    const start = () => {
      played.add(version);
      stop = run(el, cv, () => setDone(true));
    };
    const fail = () => setDone(true);
    if (el.complete && el.naturalWidth) start();
    else {
      el.addEventListener('load', start, { once: true });
      el.addEventListener('error', fail, { once: true });
    }
    return () => {
      el.removeEventListener('load', start);
      el.removeEventListener('error', fail);
      stop();
    };
  }, [reveal, done, version]);

  return (
    <>
      <img ref={img} className={`${className}${reveal && !done ? ' is-revealing' : ''}`} src={src} alt="" />
      {reveal && !done && <canvas ref={canvas} className="photo-ascii" aria-hidden="true" />}
    </>
  );
}
