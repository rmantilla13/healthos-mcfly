// A ring split into parts of a whole (the Nutrition page's protein, carbs and fat by weight), with an optional
// figure in the middle. Parts sit edge to edge in the order given, starting at twelve o'clock.
import type { ReactNode } from 'react';

export type DonutPart = { key: string; label: string; value: number; color: string };

export function Donut({ parts, center, size = 148, thickness = 16, label }: { parts: DonutPart[]; center?: ReactNode; size?: number; thickness?: number; label: string }) {
  const total = parts.reduce((a, p) => a + p.value, 0);
  const r = (size - thickness) / 2;
  const c = 2 * Math.PI * r;
  // A small break between parts, so neighbours of similar colour stay apart.
  const gap = parts.length > 1 ? Math.min(4, c / 60) : 0;
  let offset = 0;
  return (
    <div className="donut" style={{ width: size, height: size }}>
      <svg width={size} height={size} viewBox={`0 0 ${size} ${size}`} role="img" aria-label={label}>
        <circle cx={size / 2} cy={size / 2} r={r} className="donut-track" strokeWidth={thickness} fill="none" />
        {total > 0 &&
          parts.map((p) => {
            const len = (p.value / total) * c;
            const seg = (
              <circle
                key={p.key}
                cx={size / 2}
                cy={size / 2}
                r={r}
                fill="none"
                stroke={p.color}
                strokeWidth={thickness}
                strokeDasharray={`${Math.max(0, len - gap)} ${c}`}
                strokeDashoffset={-offset}
                transform={`rotate(-90 ${size / 2} ${size / 2})`}
              />
            );
            offset += len;
            return seg;
          })}
      </svg>
      {center !== undefined && <div className="donut-center">{center}</div>}
    </div>
  );
}
