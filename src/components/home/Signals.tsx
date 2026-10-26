// Your signals, as pastel cards (VitalCard): resting heart rate, blood oxygen, HRV, sleep, recovery and respiratory
// rate, from GET /api/summary. Home shows them tall, with each one's mini chart; Vitals shows them short, with the
// value and its status (its trend charts are right below). Every ↗ opens the metric's sheet, with a reading or not.
// Without one, a card is the design's empty state; Recovery is WHOOP's, so an Apple-only person sees it empty (their
// cardio fitness is on Body).
import type { ReactNode } from 'react';
import type { Summary, Vital, VitalLevel } from '../../../shared/types.ts';
import { MiniDots, MiniLine, RangeScale } from '../../charts/Mini.tsx';
import { fmt, fmtDate, hoursMinutes, href } from '../../lib.ts';
import { VitalCard } from '../VitalCard.tsx';

type Variant = 'home' | 'compact';
type CardProps = { s: Summary; variant?: Variant };

export function signed(n: number, digits = 0) {
  const v = fmt(Math.abs(n), digits);
  return n > 0 ? `+${v}` : n < 0 ? `−${v}` : v;
}

/** A reading's date when it isn't the day shown. */
export function Stale({ date, asOf }: { date: string; asOf: string }) {
  return date === asOf ? null : <span className="stale">{fmtDate(date)}</span>;
}

/** A vital's status as the figure's callouts say it, with its level's dot (the words carry it too). */
function VitalStatus({ v, asOf }: { v: Vital; asOf: string }) {
  if (!v.latest) return null;
  const level: VitalLevel | null = v.status ? (v.level ?? (v.status === 'normal' ? 'normal' : 'unusual')) : null;
  const up = v.status === 'high';
  const words = !v.status ? 'Building baseline' : v.status === 'normal' ? 'Normal' : level === 'off' ? (up ? 'Well above usual' : 'Well below usual') : up ? 'Above usual' : 'Below usual';
  return (
    <span className="vital-status-line" title="Your latest reading, compared with your own previous 30 days">
      {level && <i className="callout-level" data-level={level} aria-hidden="true" />}
      {words}
      <Stale date={v.latest.date} asOf={asOf} />
    </span>
  );
}

const NO_VITAL: Vital = { label: '', latest: null, status: null, level: null };

/** The card's frame: its tone, unit and sheet, the same on both pages. */
function Signal({ variant = 'home', ...p }: Parameters<typeof VitalCard>[0] & { variant?: Variant }) {
  return <VitalCard variant={variant} href={href('vitals')} {...p} />;
}

/** Home only: the chart and foot. Vitals has its trend charts right below the cards. */
const homeOnly = (variant: Variant, node: ReactNode) => (variant === 'home' ? node : undefined);

export function RestingHrCard({ s, variant = 'home' }: CardProps) {
  const v = s.vitals.heart;
  const l = s.restingHr?.latest ?? v.latest;
  const series = s.restingHr?.series ?? [];
  return (
    <Signal
      variant={variant}
      title="Resting heart rate"
      tone="green"
      unit="bpm"
      metric="resting_hr"
      date={s.date}
      value={l ? fmt(l.value) : null}
      status={<VitalStatus v={{ ...v, latest: l }} asOf={s.date} />}
      footLeft={homeOnly(variant, series.length > 1 ? 'Last 30 days' : null)}
    >
      {homeOnly(variant, series.length > 1 && <MiniLine points={series} format={(x) => `${fmt(x)} bpm`} color="var(--series-3)" height={52} label="Resting heart rate, last 30 days" />)}
    </Signal>
  );
}

export function Spo2Card({ s, variant = 'home' }: CardProps) {
  const l = s.spo2.latest;
  return (
    <Signal
      variant={variant}
      title="Blood oxygen"
      tone="peach"
      unit="%"
      metric="spo2"
      date={s.date}
      value={l ? fmt(l.value, l.value % 1 ? 1 : 0) : null}
      // The card calls anything not below the usual range "Normal" (the sheet's status says "at or above" for a high one).
      status={
        l && (
          <span className="vital-status-line">
            {s.spo2.status ? (s.spo2.status === 'low' ? 'Below your range' : 'Normal') : 'Building baseline'}
            <Stale date={l.date} asOf={s.date} />
          </span>
        )
      }
      footLeft={homeOnly(variant, '90')}
      footRight={homeOnly(variant, '100')}
    >
      {l &&
        homeOnly(
          variant,
          <>
            <MiniLine points={s.spo2.series} format={(x) => `${fmt(x, 1)}%`} domain={[90, 100]} color="var(--series-2)" height={44} label="Blood oxygen, last 30 days" />
            <RangeScale value={l.value} min={90} max={100} label={`Blood oxygen ${fmt(l.value, 1)}% on a 90 to 100 scale`} />
          </>,
        )}
    </Signal>
  );
}

const HRV_STATUS = { optimal: 'Optimal', normal: 'Normal', low: 'Below baseline' };

export function HrvCard({ s, variant = 'home' }: CardProps) {
  const l = s.hrv.latest;
  const rmssd = s.hrv.metric === 'hrv_rmssd';
  return (
    <Signal
      variant={variant}
      title="HRV"
      tone="blue"
      unit="ms"
      metric="hrv"
      date={s.date}
      value={l ? fmt(l.value) : null}
      status={
        l && (
          <span className="vital-status-line">
            {s.hrv.status ? HRV_STATUS[s.hrv.status] : 'Building baseline'}
            <Stale date={l.date} asOf={s.date} />
          </span>
        )
      }
      footLeft={
        l && (
          <span className="band-key" title={rmssd ? 'WHOOP and Fitbit measure RMSSD during sleep' : 'Apple Watch measures SDNN'}>
            {variant === 'home' ? (
              <>
                <i /> usual · {rmssd ? 'RMSSD' : 'SDNN'}
              </>
            ) : rmssd ? (
              'RMSSD'
            ) : (
              'SDNN'
            )}
          </span>
        )
      }
    >
      {l &&
        homeOnly(
          variant,
          <MiniDots points={s.hrv.series} baseline={s.hrv.baseline} format={(x) => `${fmt(x)} ms`} label="Heart rate variability, last 21 nights, with your usual range" height={56} />,
        )}
    </Signal>
  );
}

export function SleepCard({ s, variant = 'home' }: CardProps) {
  const l = s.sleep.latest;
  const quality = !l ? '' : l.value >= 7 ? 'Good' : l.value >= 6 ? 'Fair' : 'Short';
  return (
    <Signal
      variant={variant}
      title="Sleep"
      tone="lavender"
      unit="hours"
      metric="sleep_hours"
      href={href('sleep')}
      date={s.date}
      value={l ? fmt(l.value, 1) : null}
      status={
        l && (
          <span className="vital-status-line" title={hoursMinutes(l.value)}>
            {quality}
            <Stale date={l.date} asOf={s.date} />
          </span>
        )
      }
      footLeft={homeOnly(variant, l && 'Last 14 nights')}
      footRight={homeOnly(variant, l && s.sleep.change !== null && <span title="This week's average vs last week's">{signed(s.sleep.change * 100)}% wk</span>)}
    >
      {l && homeOnly(variant, <MiniLine points={s.sleep.series} format={hoursMinutes} color="var(--series-1)" height={48} label="Sleep duration, last 14 nights" />)}
    </Signal>
  );
}

const ZONE = { red: 'Low', yellow: 'Moderate', green: 'High' };

export function RecoveryCard({ s, variant = 'home' }: CardProps) {
  const r = s.readiness?.kind === 'recovery' ? s.readiness : null;
  const delta = r && r.average !== null ? r.latest.value - r.average : null;
  return (
    <Signal
      variant={variant}
      title="Recovery"
      tone="pink"
      unit="%"
      metric="recovery"
      date={s.date}
      value={r ? fmt(r.latest.value) : null}
      status={
        r && (
          <span className={`zone-label zone-label-${r.zone}`}>
            <i aria-hidden="true" />
            {ZONE[r.zone]}
            <Stale date={r.latest.date} asOf={s.date} />
          </span>
        )
      }
      footLeft={homeOnly(variant, delta !== null && `${signed(delta)} vs 30-day avg`)}
    >
      {r &&
        homeOnly(
          variant,
          <>
            <Rings value={r.latest.value / 100} />
            <RangeScale
              value={r.latest.value}
              min={0}
              max={100}
              label={`Recovery ${Math.round(r.latest.value)}%, ${ZONE[r.zone].toLowerCase()} zone`}
              zones={[
                { to: 33, className: 'zone-critical' },
                { to: 66, className: 'zone-warning' },
                { to: 100, className: 'zone-good' },
              ]}
            />
          </>,
        )}
    </Signal>
  );
}

/** Decorative concentric rings; the dot sits at the score's position on the outer ring. */
function Rings({ value }: { value: number }) {
  const a = Math.PI * (0.75 - 1.5 * Math.min(1, Math.max(0, value)));
  return (
    <svg className="rings" viewBox="0 0 120 120" aria-hidden="true">
      {[56, 44, 32, 20].map((r) => (
        <circle key={r} cx="60" cy="60" r={r} />
      ))}
      <circle cx={60 + 56 * Math.cos(a)} cy={60 - 56 * Math.sin(a)} r="3.5" className="rings-dot" />
    </svg>
  );
}

export function RespRateCard({ s, variant = 'home' }: CardProps) {
  const v = s.vitals.breathing;
  const l = s.respRate?.latest ?? v.latest;
  const series = s.respRate?.series ?? [];
  return (
    <Signal
      variant={variant}
      title="Respiratory rate"
      tone="mint"
      unit="breaths/min"
      metric="resp_rate"
      date={s.date}
      value={l ? fmt(l.value, 1) : null}
      status={<VitalStatus v={l ? { ...v, latest: l } : NO_VITAL} asOf={s.date} />}
      footLeft={homeOnly(variant, series.length > 1 ? 'Last 30 days' : null)}
    >
      {homeOnly(variant, series.length > 1 && <MiniLine points={series} format={(x) => `${fmt(x, 1)} /min`} color="var(--series-3)" height={52} label="Respiratory rate, last 30 days" />)}
    </Signal>
  );
}

/** How many of Vitals' five signals have a reading: resting heart rate, blood oxygen, HRV, recovery, respiratory rate. */
export function signalCount(s: Summary) {
  return [s.restingHr?.latest ?? s.vitals.heart.latest, s.spo2.latest, s.hrv.latest, s.readiness?.kind === 'recovery' ? s.readiness : null, s.respRate?.latest ?? s.vitals.breathing.latest].filter(Boolean).length;
}
