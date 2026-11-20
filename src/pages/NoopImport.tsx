// Integrations → WHOOP strap with NOOP → Import NOOP export: a sheet that reads NOOP's CSV export (src/import/noop.ts)
// in this browser, shows what it found, then sends the per-day readings, nights and workouts to POST /api/noop/import
// in chunks of whole days. The file itself never leaves the device.
import { useMemo, useRef, useState } from 'react';
import type { NoopChunk } from '../../shared/noop.ts';
import type { Status } from '../../shared/types.ts';
import { Icon } from '../components/Icon.tsx';
import { Sheet } from '../components/Sheet.tsx';
import { type NoopFound, noopChunks, noopFinish, noopPreview, noopRows, readNoopZip } from '../import/noop.ts';
import { fmt, notifyDataChanged, sendJson } from '../lib.ts';

type Phase =
  | { kind: 'choose'; error?: string }
  | { kind: 'reading' }
  | { kind: 'preview'; found: NoopFound }
  | { kind: 'sending'; sent: number; total: number }
  | { kind: 'done'; days: number }
  | { kind: 'failed'; message: string; chunks: NoopChunk[]; next: number; found: NoopFound };

/** The person's zone (Settings), else this device's: NOOP writes every time in UTC, and days are local. */
function zoneOf(status: Status) {
  const device = Intl.DateTimeFormat().resolvedOptions().timeZone;
  try {
    new Intl.DateTimeFormat('en-US', { timeZone: status.settings.timeZone ?? device });
    return status.settings.timeZone ?? device;
  } catch {
    return device;
  }
}

const plural = (n: number, one: string, many: string) => `${fmt(n)} ${n === 1 ? one : many}`;

/** "412 days of recovery and strain, 398 nights of sleep and 57 workouts". */
function foundText(p: ReturnType<typeof noopPreview>) {
  const parts = [
    p.recoveryDays > 0 && plural(p.recoveryDays, 'day of recovery and strain', 'days of recovery and strain'),
    p.nights > 0 && plural(p.nights, 'night of sleep', 'nights of sleep'),
    p.workouts > 0 && plural(p.workouts, 'workout', 'workouts'),
  ].filter((x): x is string => Boolean(x));
  return parts.length > 1 ? `${parts.slice(0, -1).join(', ')} and ${parts.at(-1)}` : (parts[0] ?? '');
}

const longDate = (d: string) => new Date(`${d}T12:00:00Z`).toLocaleDateString(undefined, { month: 'short', day: 'numeric', year: 'numeric', timeZone: 'UTC' });

export function NoopImport({ status, refresh, onClose }: { status: Status; refresh: () => void; onClose: () => void }) {
  const [phase, setPhase] = useState<Phase>({ kind: 'choose' });
  const [drag, setDrag] = useState(false);
  const input = useRef<HTMLInputElement>(null);
  const zone = useMemo(() => zoneOf(status), [status]);
  const today = useMemo(() => new Intl.DateTimeFormat('en-CA', { timeZone: zone }).format(new Date()), [zone]);

  async function read(file: File | undefined) {
    if (!file) return;
    if (!/\.zip$/i.test(file.name)) return setPhase({ kind: 'choose', error: 'Choose the .zip NOOP saved (Settings → Backup & restore → Export CSV).' });
    setPhase({ kind: 'reading' });
    try {
      const found = noopRows(await readNoopZip(file), { timeZone: zone, today });
      setPhase({ kind: 'preview', found });
    } catch (e) {
      setPhase({ kind: 'choose', error: (e as Error).message });
    }
  }

  async function send(found: NoopFound, chunks: NoopChunk[], from = 0) {
    for (let i = from; i < chunks.length; i++) {
      setPhase({ kind: 'sending', sent: i, total: chunks.length });
      try {
        await sendJson('POST', '/noop/import', chunks[i]);
      } catch (e) {
        setPhase({ kind: 'failed', message: (e as Error).message, chunks, next: i, found });
        refresh();
        return;
      }
    }
    const finish = noopFinish(found);
    try {
      await sendJson('POST', '/noop/import/finish', finish);
    } catch (e) {
      setPhase({ kind: 'failed', message: (e as Error).message, chunks, next: chunks.length, found });
      return;
    }
    setPhase({ kind: 'done', days: noopPreview(found).days });
    refresh();
    notifyDataChanged();
  }

  const found = phase.kind === 'preview' ? phase.found : null;
  const preview = found ? noopPreview(found) : null;
  const nothing = preview !== null && preview.days === 0;

  const footer =
    phase.kind === 'preview' ? (
      <>
        <button className="btn btn-quiet" onClick={() => setPhase({ kind: 'choose' })}>
          Choose another
        </button>
        {!nothing && found && (
          <button className="btn btn-primary" onClick={() => send(found, noopChunks(found))}>
            Import
          </button>
        )}
      </>
    ) : phase.kind === 'failed' ? (
      <>
        <button className="btn btn-quiet" onClick={onClose}>
          Close
        </button>
        <button className="btn btn-primary" onClick={() => send(phase.found, phase.chunks, phase.next)}>
          Try again
        </button>
      </>
    ) : phase.kind === 'done' ? (
      <button className="btn btn-primary" onClick={onClose}>
        Done
      </button>
    ) : undefined;

  return (
    <Sheet eyebrow="WHOOP strap with NOOP" title="Import NOOP export" onClose={onClose} footer={footer}>
      {phase.kind === 'choose' && (
        <>
          <ol className="fitbit-steps noop-steps">
            <li>In NOOP, sync your strap, then open Settings → Backup &amp; restore → Export CSV.</li>
            <li>Save the .zip (on iPhone, to Files), then choose it here.</li>
          </ol>
          <div
            className={`dropzone${drag ? ' is-drag' : ''}`}
            onDragOver={(e) => {
              e.preventDefault();
              setDrag(true);
            }}
            onDragLeave={() => setDrag(false)}
            onDrop={(e) => {
              e.preventDefault();
              setDrag(false);
              void read(e.dataTransfer.files[0]);
            }}
          >
            <Icon name="upload" size={22} />
            <span>Drop the .zip here</span>
            <div className="btn-row">
              <button className="btn btn-primary" onClick={() => input.current?.click()}>
                Choose .zip
              </button>
            </div>
            <input
              ref={input}
              type="file"
              accept=".zip,application/zip"
              hidden
              onChange={(e) => {
                void read(e.target.files?.[0]);
                e.target.value = '';
              }}
            />
          </div>
          {phase.error && (
            <p className="note-bad" role="alert">
              <Icon name="alert" size={15} /> {phase.error}
            </p>
          )}
          <p className="muted small">
            healthOS reads the export here, in this browser; only per-day readings, each night's sleep times and your workouts are sent to your account. Nothing else about the
            file leaves this device.
          </p>
        </>
      )}

      {phase.kind === 'reading' && (
        <div className="progress fitbit-progress" role="status">
          <div className="progress-label">Reading your export…</div>
          <p className="muted small">It stays on this device while it's read.</p>
        </div>
      )}

      {phase.kind === 'preview' &&
        preview &&
        found &&
        (nothing ? (
          <p className="note-bad" role="status">
            <Icon name="alert" size={15} /> No readings were found in this export. Sync your strap in NOOP, then export again.
          </p>
        ) : (
          <>
            <p className="fitbit-found" role="status">
              Found {foundText(preview)}.
            </p>
            {preview.firstDate && preview.lastDate && (
              <p className="muted small">
                From {longDate(preview.firstDate)} to {longDate(preview.lastDate)}.
              </p>
            )}
            {found.estimatedDays > 0 && (
              <p className="muted small">
                {found.estimatedDays === preview.days ? 'NOOP worked these out' : `NOOP worked out ${plural(found.estimatedDays, 'day', 'days')}`} on your phone from the
                strap's own readings, so recovery, strain and sleep scores are its estimates, not WHOOP's.
              </p>
            )}
            <p className="muted small">
              Days already imported from NOOP are updated from this export. When the WHOOP connection has the same day, WHOOP's own numbers are shown. Apple Health, Fitbit and your
              own entries stay as they are, and each keeps its source.
            </p>
          </>
        ))}

      {phase.kind === 'sending' && (
        <div className="progress fitbit-progress" role="status">
          <div className="progress-label">
            Sending… {fmt(phase.sent + 1)} of {fmt(phase.total)}
          </div>
          <div className="goal-track">
            <div className="goal-fill" style={{ width: `${Math.round((phase.sent / phase.total) * 100)}%` }} />
          </div>
        </div>
      )}

      {phase.kind === 'done' && (
        <p className="note-good" role="status">
          <Icon name="check" size={15} /> Imported {plural(phase.days, 'day', 'days')}. These readings are marked as NOOP.
        </p>
      )}

      {phase.kind === 'failed' && (
        <p className="note-bad" role="alert">
          <Icon name="alert" size={15} /> Sending stopped: {phase.message} The days already sent are saved; try again to send the rest.
        </p>
      )}
    </Sheet>
  );
}
