// Shiny text: a soft band of light sweeps across the text, on a loop. Used for Ask McFly's "thinking" state.
//
// Adapted from React Bits' ShinyText (https://reactbits.dev, src/content/TextAnimations/ShinyText), trimmed to
// the looping sweep and given theme colors. Its license:
//   MIT + Commons Clause License Condition v1.0. Copyright (c) 2026 David Haz. Permission is hereby granted,
//   free of charge, to any person obtaining a copy of this software and associated documentation files (the
//   "Software"), to deal in the Software without restriction, including without limitation the rights to use,
//   copy, modify, merge, publish, and distribute the Software as part of an application, website, or product,
//   subject to the following conditions: The above copyright notice and this permission notice shall be
//   included in all copies or substantial portions of the Software.
import { type ReactNode, useEffect, useRef } from 'react';

type Rgba = [number, number, number, number];
const FALLOFF = [0, 0.2, 0.4, 0.6, 0.8, 1];
const smooth = (t: number) => 0.5 - Math.cos(Math.PI * t) / 2;

let paint: CanvasRenderingContext2D | null = null;

/** Any CSS color, or var(--name) resolved against the page, as [r, g, b, a]. */
function parseColor(value: string): Rgba | null {
  const v = value.startsWith('var(') ? getComputedStyle(document.documentElement).getPropertyValue(value.slice(4, -1).trim()).trim() : value;
  paint ??= document.createElement('canvas').getContext('2d');
  if (!paint || !v) return null;
  paint.fillStyle = '#000000';
  paint.fillStyle = v;
  const resolved = String(paint.fillStyle);
  if (resolved.startsWith('#')) return [1, 3, 5].map((i) => parseInt(resolved.slice(i, i + 2), 16)).concat(1) as Rgba;
  const parts = resolved.match(/[\d.]+/g);
  if (!parts || parts.length < 3) return null;
  return [Number(parts[0]), Number(parts[1]), Number(parts[2]), parts.length > 3 ? Number(parts[3]) : 1];
}

/** Mix two colors in linear light, so the highlight's edges don't go muddy. */
function blend(from: Rgba, to: Rgba, amount: number) {
  const channel = (a: number, b: number) => Math.round(((a / 255) ** 2.2 * (1 - amount) + (b / 255) ** 2.2 * amount) ** (1 / 2.2) * 255);
  const alpha = from[3] * (1 - amount) + to[3] * amount;
  return `rgba(${channel(from[0], to[0])}, ${channel(from[1], to[1])}, ${channel(from[2], to[2])}, ${Math.round(alpha * 1000) / 1000})`;
}

export function ShinyText({
  children,
  color = 'var(--ink-3)',
  shineColor = 'var(--ink)',
  speed = 1.6,
  delay = 0.2,
  angle = 120,
  shineWidth = 34,
  softness = 0.8,
  className = '',
}: {
  children: ReactNode;
  /** The text's resting color and the color at the center of the sweep; CSS colors or var(--token). */
  color?: string;
  shineColor?: string;
  /** Seconds per sweep, and the pause between sweeps. */
  speed?: number;
  delay?: number;
  angle?: number;
  /** The highlight's width, in percent of the text's width. */
  shineWidth?: number;
  softness?: number;
  className?: string;
}) {
  const root = useRef<HTMLSpanElement>(null);

  useEffect(() => {
    const el = root.current;
    if (!el) return;
    const base = parseColor(color);
    const shine = parseColor(shineColor);
    const flat = () => {
      el.style.backgroundImage = `linear-gradient(${color}, ${color})`;
    };
    // Reduced motion, or a color we can't read: plain text in the resting color.
    if (!base || !shine || matchMedia('(prefers-reduced-motion: reduce)').matches) return flat();

    const half = shineWidth / 2;
    const core = half * (1 - softness);
    const fade = half - core;
    const reach = half + 2;
    const gradient = (pos: number) => {
      const stops: [number, number][] = [];
      for (const side of [-1, 1]) {
        for (const f of FALLOFF) stops.push([pos + side * (core + fade * (1 - f)), f * f * (3 - 2 * f)]);
      }
      stops.sort((a, b) => a[0] - b[0]);
      const list = stops.map(([at, amount]) => `${blend(base, shine, amount)} ${at.toFixed(2)}%`);
      return `linear-gradient(${angle}deg, ${blend(base, shine, 0)} 0%, ${list.join(', ')}, ${blend(base, shine, 0)} 100%)`;
    };

    let raf = 0;
    let timer = 0;
    let visible = true;
    let start = -1;
    const tick = (now: number) => {
      raf = 0;
      if (start < 0) start = now;
      const t = Math.min(1, (now - start) / (speed * 1000));
      // Left to right, entering and leaving fully outside the text.
      el.style.backgroundImage = gradient(-reach + (100 + 2 * reach) * smooth(t));
      if (t < 1) raf = requestAnimationFrame(tick);
      else {
        start = -1;
        timer = window.setTimeout(() => {
          timer = 0;
          if (visible) raf = requestAnimationFrame(tick);
        }, delay * 1000);
      }
    };
    // Off screen (scrolled away in a long chat), the sweep waits.
    const observer = new IntersectionObserver((entries) => {
      visible = entries.some((e) => e.isIntersecting);
      if (visible && !raf && !timer) raf = requestAnimationFrame(tick);
    });
    observer.observe(el);
    raf = requestAnimationFrame(tick);
    return () => {
      cancelAnimationFrame(raf);
      window.clearTimeout(timer);
      observer.disconnect();
    };
  }, [color, shineColor, speed, delay, angle, shineWidth, softness]);

  return (
    <span ref={root} className={`shiny-text${className ? ` ${className}` : ''}`} style={{ backgroundImage: `linear-gradient(${color}, ${color})` }}>
      {children}
    </span>
  );
}
