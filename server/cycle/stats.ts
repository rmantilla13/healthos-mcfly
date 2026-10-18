// Small numeric helpers for the cycle engine. Dates are YYYY-MM-DD strings throughout.

/** Whole days from a to b (b later is positive). */
export const between = (a: string, b: string) => Math.round((Date.parse(`${b}T00:00:00Z`) - Date.parse(`${a}T00:00:00Z`)) / 86_400_000);

export const sum = (xs: number[]) => xs.reduce((s, x) => s + x, 0);

export const mean = (xs: number[]) => (xs.length ? sum(xs) / xs.length : NaN);

export function median(xs: number[]): number | null {
  if (!xs.length) return null;
  const s = [...xs].sort((a, b) => a - b);
  const m = s.length >> 1;
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
}

/** Median absolute deviation, scaled to match a standard deviation for normal data. */
export function mad(xs: number[]): number {
  const m = median(xs);
  if (m === null) return 0;
  return (median(xs.map((x) => Math.abs(x - m))) ?? 0) * 1.4826;
}

export const clamp = (v: number, lo: number, hi: number) => Math.min(Math.max(v, lo), hi);

export const round2 = (v: number) => Math.round(v * 100) / 100;

/** Floating-point slack for comparisons against thresholds built from rounded readings. */
export const EPS = 1e-9;
