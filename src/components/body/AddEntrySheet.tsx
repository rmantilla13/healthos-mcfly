// Add a weight, body fat or lean body mass by hand (POST /api/body/entries): the value in the person's units, its day
// (today by default; never a day that hasn't happened, by their own time zone, which the server checks), an optional
// time, where it's from and a note. Under the form, the recent entries for that metric, each of which can be deleted.
import { type FormEvent, useId, useRef, useState } from 'react';
import { BODY_METHODS, BODY_METRICS, type BodyEntries, type BodyEntry, type BodyMethod, type BodyMetric, LB_PER_KG } from '../../../shared/body.ts';
import { fmt, fmtDate, href, notifyDataChanged, sendJson, useApi, useUnits } from '../../lib.ts';
import { Sheet } from '../Sheet.tsx';
import { inUnits, unitOf } from './MeasurementCard.tsx';

const TITLE: Record<BodyMetric, string> = { weight: 'Add weight', body_fat: 'Add body fat', lean_mass: 'Add lean body mass' };
/** The list shows this many until "Show all". */
const RECENT = 8;

export function AddEntrySheet({ metric, today, demo, onClose }: { metric: BodyMetric; today: string; demo: boolean; onClose: () => void }) {
  const units = useUnits();
  const spec = BODY_METRICS.find((m) => m.metric === metric)!;
  const unit = unitOf(metric, units);
  const [value, setValue] = useState('');
  const [date, setDate] = useState(today);
  const [time, setTime] = useState('');
  const [method, setMethod] = useState<BodyMethod | null>(null);
  const [note, setNote] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const formId = useId();
  const valueId = useId();
  const hintId = useId();
  const fromId = useId();
  const name = spec.label.toLowerCase();
  // The range in the units typed in; the server checks it again in kg.
  const range = unit === 'lb' ? [Math.ceil(spec.min * LB_PER_KG), Math.floor(spec.max * LB_PER_KG)] : [spec.min, spec.max];

  async function save(e: FormEvent) {
    e.preventDefault();
    if (busy) return;
    // A comma works as the decimal point too ("72,4").
    const n = Number(value.trim().replace(',', '.'));
    if (!value.trim() || !Number.isFinite(n)) return setError(`Enter your ${name} as a number.`);
    setBusy(true);
    setError(null);
    try {
      await sendJson('POST', '/body/entries', { metric, value: n, unit, date, time: time || null, method: method ?? undefined, note: note.trim() || undefined });
      notifyDataChanged();
      onClose();
    } catch (err) {
      setError((err as Error).message);
      setBusy(false);
    }
  }

  return (
    <Sheet
      eyebrow="Body"
      title={TITLE[metric]}
      size="sm"
      onClose={onClose}
      footer={
        <>
          <button type="button" className="btn btn-quiet" onClick={onClose}>
            Cancel
          </button>
          <button type="submit" form={formId} className="btn btn-primary" disabled={busy || demo}>
            {busy ? 'Saving…' : 'Save entry'}
          </button>
        </>
      }
    >
      {demo && (
        <p className="entry-demo">
          Turn off demo data in <a href={href('profile')}>your Profile</a> to add your own measurements.
        </p>
      )}
      <form id={formId} className="settings entry-form" onSubmit={save} noValidate>
        {/* The unit and range are the field's description, not part of its name. */}
        <div className="settings-row">
          <label htmlFor={valueId}>{spec.label}</label>
          <span className="entry-value">
            <input
              id={valueId}
              inputMode="decimal"
              autoComplete="off"
              value={value}
              aria-describedby={hintId}
              aria-invalid={error ? true : undefined}
              onChange={(e) => setValue(e.target.value)}
            />
            <span className="entry-unit" aria-hidden="true">
              {unit}
            </span>
          </span>
          <small id={hintId} className="muted">
            {unit === '%' ? `As a percentage, between ${range[0]} and ${range[1]}.` : `In ${unit}, between ${range[0]} and ${range[1]}.`}
          </small>
        </div>
        <div className="entry-when">
          <label>
            <span>Date</span>
            <input type="date" value={date} max={today} min="1900-01-01" required onChange={(e) => setDate(e.target.value)} />
          </label>
          <label>
            <span>
              Time <small className="muted">optional</small>
            </span>
            <input type="time" value={time} onChange={(e) => setTime(e.target.value)} />
          </label>
        </div>
        <div className="settings-row">
          <span id={fromId}>
            Where it's from <small className="muted">optional</small>
          </span>
          <div className="filters" role="group" aria-labelledby={fromId}>
            {BODY_METHODS.map((m) => (
              <button type="button" key={m.method} className={method === m.method ? 'on' : ''} aria-pressed={method === m.method} onClick={() => setMethod(method === m.method ? null : m.method)}>
                {m.label}
              </button>
            ))}
          </div>
        </div>
        <label>
          <span>
            Note <small className="muted">optional</small>
          </span>
          <input value={note} maxLength={200} autoComplete="off" onChange={(e) => setNote(e.target.value)} />
        </label>
        {error && (
          <p className="note-bad small" role="alert">
            {error}
          </p>
        )}
      </form>
      {!demo && <RecentEntries metric={metric} today={today} />}
    </Sheet>
  );
}

/** The metric's entries, newest first, each with Delete (asked twice, since it can't be undone). */
function RecentEntries({ metric, today }: { metric: BodyMetric; today: string }) {
  const units = useUnits();
  const unit = unitOf(metric, units);
  // Every entry, back to 1900.
  const { data, error } = useApi<BodyEntries>(`/body/entries?metric=${metric}&days=36500`);
  const [all, setAll] = useState(false);
  const [asking, setAsking] = useState<string | null>(null);
  const [failed, setFailed] = useState<string | null>(null);
  const heading = useRef<HTMLHeadingElement>(null);
  const refocus = useRef<string | null>(null);
  const headingId = useId();
  const entries = data?.entries ?? [];

  async function remove(id: string) {
    setFailed(null);
    try {
      await sendJson('DELETE', `/body/entries/${id}`);
      setAsking(null);
      // The row goes; focus stays in the sheet, on the list's heading.
      heading.current?.focus();
      notifyDataChanged();
    } catch (err) {
      setFailed((err as Error).message);
    }
  }

  if (!data) return error ? <p className="muted small entry-list-note">Couldn't load your entries.</p> : null;
  if (!entries.length) return null;
  const shown = all ? entries : entries.slice(0, RECENT);
  const sameYear = (d: string) => d.slice(0, 4) === today.slice(0, 4);
  const when = (e: BodyEntry) => `${fmtDate(e.date, { month: 'short', day: 'numeric', year: sameYear(e.date) ? undefined : 'numeric' })}${e.time ? `, ${e.time}` : ''}`;
  const show = (v: number) => (unit === '%' ? `${fmt(inUnits(metric, v, units), 1)}%` : `${fmt(inUnits(metric, v, units), 1)} ${unit}`);

  return (
    <section className="entry-list" aria-labelledby={headingId}>
      <h3 id={headingId} ref={heading} tabIndex={-1}>
        Your entries
      </h3>
      <ul>
        {shown.map((e) => {
          const method = BODY_METHODS.find((m) => m.method === e.method)?.label;
          return (
            <li key={e.id}>
              <span className="entry-list-main">
                <b>{show(e.value)}</b>
                <small>{[when(e), method, e.note].filter(Boolean).join(' · ')}</small>
              </span>
              {asking === e.id ? (
                <span className="entry-list-confirm" role="group" aria-label={`Delete the entry from ${when(e)}?`}>
                  <span className="small" aria-hidden="true">
                    Delete this entry?
                  </span>
                  <button type="button" className="btn btn-danger" onClick={() => void remove(e.id)}>
                    Delete
                  </button>
                  {/* Focus starts on the way out, so a second Enter doesn't delete. */}
                  <button
                    type="button"
                    className="btn btn-quiet"
                    autoFocus
                    onClick={() => {
                      refocus.current = e.id;
                      setAsking(null);
                    }}
                  >
                    Keep
                  </button>
                </span>
              ) : (
                <button
                  type="button"
                  className="btn btn-quiet entry-delete"
                  onClick={() => setAsking(e.id)}
                  ref={(el) => {
                    // Back on its own Delete entry after Keep.
                    if (el && refocus.current === e.id) {
                      refocus.current = null;
                      el.focus();
                    }
                  }}
                >
                  Delete entry<span className="sr-only"> from {when(e)}</span>
                </button>
              )}
            </li>
          );
        })}
      </ul>
      {failed && (
        <p className="note-bad small" role="alert">
          {failed}
        </p>
      )}
      {entries.length > RECENT && (
        <button type="button" className="btn btn-quiet entry-list-more" onClick={() => setAll(!all)} aria-expanded={all}>
          {all ? 'Show fewer' : `Show all ${entries.length}`}
        </button>
      )}
    </section>
  );
}
