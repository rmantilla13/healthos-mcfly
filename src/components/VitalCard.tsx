// The pastel signal card on Home, Vitals and Sleep: a title with its ↗ (the metric's sheet, or a link), the value with
// its unit, an optional status and mini chart, and a footer. Without a reading it says so the same way everywhere:
// a bold dash, "Connect a source to get started", and a Connect link to Integrations. Two sizes: 'home' (tall, about
// 1.55:1) and 'compact' (Vitals and Sleep, about 3.6:1).
//
//   <VitalCard title="Blood oxygen" tone="peach" unit="%" value={l ? fmt(l.value, 1) : null} metric="spo2" variant="home" />
import type { ReactNode } from 'react';
import type { MetricKey, MetricRange } from '../../shared/metrics.ts';
import { href } from '../lib.ts';
import { Icon } from './Icon.tsx';
import { MetricSheetLink } from './MetricSheet.tsx';

export type VitalTone = 'green' | 'peach' | 'blue' | 'lavender' | 'pink' | 'mint' | 'slate' | 'cream' | 'blush';

export function VitalCard({
  title,
  tone,
  unit,
  value,
  metric,
  href: to,
  sheetPage = to ?? href('vitals'),
  date,
  range,
  section = 'Your signals',
  status,
  children,
  footLeft,
  footRight,
  variant = 'home',
}: {
  title: string;
  tone: VitalTone;
  unit: string;
  /** The reading as it should read ("62", "7h 12m"); null when there's none. */
  value: string | null;
  /** The ↗ opens this metric's sheet. */
  metric?: MetricKey;
  /** Where the ↗ goes when there's no sheet (and the sheet's "Open …" link when there is). */
  href?: string;
  /** The sheet's "Open …" link; the card's own page by default. */
  sheetPage?: string;
  /** The day the card shows; the sheet's window ends on it. */
  date?: string;
  range?: MetricRange;
  /** The sheet's heading above the metric's name. */
  section?: string;
  /** A line under the value ("Normal", "Slightly low"). */
  status?: ReactNode;
  /** A mini chart, under the value. */
  children?: ReactNode;
  footLeft?: ReactNode;
  footRight?: ReactNode;
  variant?: 'home' | 'compact';
}) {
  const empty = value === null;
  const arrow = metric ? (
    <MetricSheetLink metric={metric} title={title} section={section} to={sheetPage} date={date} range={range} />
  ) : to ? (
    <a href={to} className="metric-link" aria-label={`Open ${title}`}>
      <Icon name="arrow-up-right" size={16} />
    </a>
  ) : null;
  return (
    <article className={`card metric vital-card vital-${variant} metric-${tone}${empty ? ' is-empty' : ''}`}>
      <div className="metric-head">
        <span>{title}</span>
        {arrow}
      </div>
      <div className="vital-value">
        {empty ? (
          <b className="vital-dash" role="img" aria-label="No reading" />
        ) : (
          <b>{value}</b>
        )}
        <small>{unit}</small>
      </div>
      {empty ? (
        <>
          {variant === 'compact' && <p className="vital-note">No reading yet</p>}
          <p className="vital-note">Connect a source to get started</p>
          <div className="vital-foot">
            <span>{variant === 'compact' ? 'Awaiting data' : 'No reading yet'}</span>
            <a href={href('integrations')} className="vital-connect">
              Connect{variant === 'home' && <Icon name="arrow-up-right" size={12} />}
            </a>
          </div>
        </>
      ) : (
        <>
          {status && <div className="vital-status">{status}</div>}
          {children && <div className="vital-chart">{children}</div>}
          {(footLeft || footRight) && (
            <div className="vital-foot">
              <span>{footLeft}</span>
              <span>{footRight}</span>
            </div>
          )}
        </>
      )}
    </article>
  );
}
