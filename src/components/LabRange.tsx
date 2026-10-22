// A lab result against its range: a small bar with the range shaded and the result marked, and the status in words.
// The words carry the meaning; colour and the bar only repeat it. Shared by the Lab tests page and the Body card.
import type { LabResult } from '../../shared/labs.ts';
import { Icon } from './Icon.tsx';

/** Up to three significant figures, without trailing zeros: 4.5, 0.45, 1245. */
export function labNumber(v: number) {
  const abs = Math.abs(v);
  const digits = abs >= 100 ? 0 : abs >= 10 ? 1 : abs >= 1 ? 2 : 3;
  return v.toLocaleString(undefined, { maximumFractionDigits: digits });
}

/** The status in words. A typical range says so, so it's never mistaken for the lab's own. */
export function statusLabel(r: LabResult): string {
  if (r.status) {
    const where = { below: 'Below', within: 'Within', above: 'Above' }[r.status];
    return `${where} ${r.range?.kind === 'typical' ? 'typical range' : 'range'}`;
  }
  if (!r.range) return 'No range printed';
  if (r.value === null) return 'Compare with range';
  return 'Can’t be placed';
}

/** Why there's no status, for a tooltip and screen readers. */
function statusHint(r: LabResult): string | undefined {
  if (r.status && r.range?.kind === 'typical') return `The report printed no range, so this uses a typical adult range${r.range.note ? ` (${r.range.note})` : ''}.`;
  if (r.status) return undefined;
  if (!r.range) return "The report printed no range, and there's no typical range to use for this marker.";
  if (r.value === null) return 'The result is a word, not a number: compare it with the printed range.';
  return `Printed as ${r.valueText}, which could fall on either side of the range.`;
}

function Arrow({ up }: { up: boolean }) {
  return (
    <svg width="12" height="12" viewBox="0 0 12 12" aria-hidden="true" className="lab-arrow">
      <path d={up ? 'M6 10V2M2.5 5.5 6 2l3.5 3.5' : 'M6 2v8M2.5 6.5 6 10l3.5-3.5'} />
    </svg>
  );
}

export function LabStatusChip({ result }: { result: LabResult }) {
  const s = result.status;
  return (
    <span className={`lab-status is-${s ?? 'none'}`} title={statusHint(result)}>
      {s === 'within' ? <Icon name="check" size={12} strokeWidth={2} /> : s ? <Arrow up={s === 'above'} /> : null}
      {statusLabel(result)}
    </span>
  );
}

/** The range text as printed, and a note when it's the typical one. */
export function rangeLabel(r: LabResult) {
  if (!r.range) return '—';
  return r.range.kind === 'typical' ? `${r.range.text} (typical adult${r.range.note ? `, ${r.range.note}` : ''})` : r.range.text;
}

/**
 * The range shaded on a track with the result marked. One-sided ranges ("<200", ">39") shade from zero or to the
 * end. A result far outside sits at the edge; one printed "<0.5" or ">90" is a hollow mark. Decorative: the
 * range and status are always written beside it.
 */
export function LabRangeBar({ result, compact }: { result: LabResult; compact?: boolean }) {
  const range = result.range;
  if (!range || (range.low === null && range.high === null)) return compact ? <span className="lab-bar lab-bar-empty" aria-hidden="true" /> : null;
  const { low, high } = range;
  let lo: number;
  let hi: number;
  let bandFrom: number;
  let bandTo: number;
  if (low !== null && high !== null) {
    const pad = (high - low) * 0.6 || Math.abs(high) * 0.2 || 1;
    lo = Math.max(low >= 0 ? 0 : -Infinity, low - pad);
    hi = high + pad;
    [bandFrom, bandTo] = [low, high];
  } else if (high !== null) {
    lo = 0;
    hi = high * 1.6 || 1;
    [bandFrom, bandTo] = [0, high];
  } else {
    lo = 0;
    hi = low! * 2 || 1;
    [bandFrom, bandTo] = [low!, hi];
  }
  const t = (v: number) => Math.min(1, Math.max(0, (v - lo) / (hi - lo || 1)));
  const v = result.value;
  return (
    <span className={`lab-bar${compact ? ' lab-bar-compact' : ''}`} aria-hidden="true">
      <span className="lab-bar-track" />
      <span className="lab-bar-band" style={{ left: `${t(bandFrom) * 100}%`, width: `${(t(bandTo) - t(bandFrom)) * 100}%` }} />
      {v !== null && (
        <span
          className={`lab-bar-dot${result.qualifier ? ' is-bound' : ''}${result.status === 'below' || result.status === 'above' ? ' is-out' : ''}`}
          style={{ left: `${t(v) * 100}%` }}
        />
      )}
    </span>
  );
}
