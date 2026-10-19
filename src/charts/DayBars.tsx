// Small per-day charts for the Nutrition cards: a fixed run of calendar days where a day with nothing logged is a
// gap (a faint dot), never a zero bar, and a target the person set is a plain dashed line, never a goal to pass.
import { useCallback } from 'react';
import { fmtDate } from '../lib.ts';
import { Tooltip, TooltipRow, barPath, useScrub, useWidth } from './core.tsx';

export type DayValue = { date: string; value: number | null };

function useDays(days: DayValue[], height: number, top: number) {
  const [ref, width] = useWidth<HTMLDivElement>();
  const n = days.length;
  const slot = n ? width / n : 0;
  const xOf = useCallback((i: number) => i * slot + slot / 2, [slot]);
  const scrub = useScrub(n, xOf);
  const yOf = (v: number) => height - (v / top) * (height - 6);
  return { ref, width, n, slot, xOf, yOf, ...scrub };
}

function Target({ y, width }: { y: number; width: number }) {
  return <line x1={0} x2={width} y1={y} y2={y} className="target-line" />;
}

export function DayBars({
  days,
  format,
  target,
  height = 64,
  label,
}: {
  days: DayValue[];
  format: (v: number) => string;
  target?: number;
  height?: number;
  label: string;
}) {
  const top = Math.max(...days.map((d) => d.value ?? 0), target ?? 0, 1) * 1.05;
  const { ref, width, n, slot, xOf, yOf, index, handlers } = useDays(days, height, top);
  const barW = Math.max(4, Math.min(16, slot - 8));
  const hovered = index !== null ? days[index] : null;
  return (
    <div className="mini day-bars" ref={ref} style={{ height }}>
      {width > 0 && (
        <svg width={width} height={height} {...handlers} role="img" aria-label={label}>
          {days.map((d, i) =>
            d.value === null ? (
              <circle key={d.date} cx={xOf(i)} cy={height - 2} r={2} className="bar-gap" />
            ) : (
              <path
                key={d.date}
                d={barPath(xOf(i) - barW / 2, yOf(d.value), barW, height - yOf(d.value), 4)}
                className={index === i ? 'bar bar-hover' : i === n - 1 ? 'bar bar-accent' : 'bar'}
              />
            ),
          )}
          {target !== undefined && <Target y={yOf(target)} width={width} />}
          <rect width={width} height={height} fill="transparent" />
        </svg>
      )}
      {hovered && index !== null && (
        <Tooltip x={xOf(index)} y={height / 2} width={width}>
          <TooltipRow color="" kind="none" value={hovered.value === null ? 'Nothing logged' : format(hovered.value)} label={fmtDate(hovered.date, { weekday: 'short', month: 'short', day: 'numeric' })} />
        </Tooltip>
      )}
    </div>
  );
}

/** Water as glasses (250 mL each), stacked per day: only the glasses drunk, no empty ones to fill. */
export function GlassBars({
  days,
  format,
  target,
  glassMl = 250,
  height = 72,
  label,
}: {
  days: DayValue[];
  format: (ml: number) => string;
  target?: number;
  glassMl?: number;
  height?: number;
  label: string;
}) {
  const most = Math.max(...days.map((d) => (d.value ?? 0) / glassMl), (target ?? 0) / glassMl, 1);
  const top = Math.ceil(most);
  const { ref, width, n, slot, xOf, yOf, index, handlers } = useDays(
    days.map((d) => ({ ...d, value: d.value === null ? null : d.value / glassMl })),
    height,
    top,
  );
  const glassW = Math.max(6, Math.min(16, slot - 8));
  const step = (height - 6) / top;
  const gap = Math.min(2, step / 4);
  const hovered = index !== null ? days[index] : null;
  return (
    <div className="mini glass-bars" ref={ref} style={{ height }}>
      {width > 0 && (
        <svg width={width} height={height} {...handlers} role="img" aria-label={label}>
          {days.map((d, i) => {
            if (d.value === null) return <circle key={d.date} cx={xOf(i)} cy={height - 2} r={2} className="bar-gap" />;
            const glasses = d.value / glassMl;
            const x = xOf(i) - glassW / 2;
            return (
              <g key={d.date} className={index === i ? 'glass-col is-hover' : i === n - 1 ? 'glass-col is-last' : 'glass-col'}>
                {Array.from({ length: Math.ceil(glasses) }, (_, g) => {
                  const fill = Math.min(1, glasses - g);
                  const h = Math.max(1, (step - gap) * fill);
                  const y = height - (g + 1) * step + (step - gap) * (1 - fill) + gap;
                  // A glass narrows a little toward its base.
                  const inset = glassW * 0.12;
                  return <path key={g} d={`M${x + inset},${y + h} L${x},${y} H${x + glassW} L${x + glassW - inset},${y + h} Z`} />;
                })}
              </g>
            );
          })}
          {target !== undefined && <Target y={yOf(target / glassMl)} width={width} />}
          <rect width={width} height={height} fill="transparent" />
        </svg>
      )}
      {hovered && index !== null && (
        <Tooltip x={xOf(index)} y={height / 2} width={width}>
          <TooltipRow color="" kind="none" value={hovered.value === null ? 'Nothing logged' : format(hovered.value)} label={fmtDate(hovered.date, { weekday: 'short', month: 'short', day: 'numeric' })} />
        </Tooltip>
      )}
    </div>
  );
}
