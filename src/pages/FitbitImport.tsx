// Integrations → Fitbit / Google Health → Import Fitbit data: a sheet that reads a Takeout export in this browser
// (src/import/, in a Web Worker), shows what it found, asks the weight unit when the export doesn't say, then sends the
// per-day readings to POST /api/fitbit/import in chunks of whole days. The file itself never leaves the device.
import { useEffect, useId, useMemo, useRef, useState } from 'react';
import type { Status } from '../../shared/types.ts';
import { Icon } from '../components/Icon.tsx';
import { Sheet } from '../components/Sheet.tsx';
import { type FitbitFound, type FitbitPreview, LB_PER_KG, fitbitChunks, fitbitFinish, fitbitPreview, fitbitRows, needsWeightUnit, typicalWeight } from '../import/fitbit.ts';
import type { FitbitInput } from '../import/fitbitFiles.ts';
import { readFitbitExport } from '../import/readFitbit.ts';
import { fmt, notifyDataChanged, sendJson } from '../lib.ts';
import type { FitbitChunk } from '../../shared/fitbit.ts';

type Phase =
  | { kind: 'choose'; error?: string }
  | { kind: 'reading'; read: number; total: number }
  | { kind: 'preview'; found: FitbitFound }
  | { kind: 'sending'; sent: number; total: number }
  | { kind: 'done'; days: number }
  | { kind: 'failed'; message: string; found: FitbitFound; chunks: FitbitChunk[]; next: number };

/** The person's zone (Settings), else this device's: Fitbit stamps many readings in UTC, and days are local. */
function zoneOf(status: Status) {
  const device = Intl.DateTimeFormat().resolvedOptions().timeZone;
  try {
    new Intl.DateTimeFormat('en-US', { timeZone: status.settings.timeZone ?? device });
    return status.settings.timeZone ?? device;
  } catch {
    return device;
  }
}

/** "812 days of heart rate, 640 nights of sleep, 410 HRV nights and 96 weigh-ins". */
function foundText(p: FitbitPreview) {
  const parts = (
    [
      [p.heartDays, 'day of heart rate', 'days of heart rate'],
      [p.restingDays, 'day of resting heart rate', 'days of resting heart rate'],
      [p.sleepNights, 'night of sleep', 'nights of sleep'],
      [p.hrvNights, 'HRV night', 'HRV nights'],
      [p.spo2Nights, 'night of blood oxygen', 'nights of blood oxygen'],
      [p.respNights, 'night of breathing rate', 'nights of breathing rate'],
      [p.stepDays, 'day of steps', 'days of steps'],
      [p.weighIns, 'weigh-in', 'weigh-ins'],
    ] as const
  )
    .filter(([n]) => n > 0)
    .map(([n, one, many]) => `${fmt(n)} ${n === 1 ? one : many}`);
  return parts.length > 1 ? `${parts.slice(0, -1).join(', ')} and ${parts.at(-1)}` : (parts[0] ?? '');
}

export function FitbitImport({ status, refresh, onClose }: { status: Status; refresh: () => void; onClose: () => void }) {
  const [phase, setPhase] = useState<Phase>({ kind: 'choose' });
  const [unit, setUnit] = useState<'kg' | 'lb' | null>(null);
  const [drag, setDrag] = useState(false);
  const zipInput = useRef<HTMLInputElement>(null);
  const folderInput = useRef<HTMLInputElement>(null);
  const cancel = useRef<(() => void) | null>(null);
  const unitLabel = useId();
  const zone = useMemo(() => zoneOf(status), [status]);
  const today = useMemo(() => new Intl.DateTimeFormat('en-CA', { timeZone: zone }).format(new Date()), [zone]);

  // A folder picker is a non-standard attribute React doesn't type; every current browser supports it.
  useEffect(() => {
    folderInput.current?.setAttribute('webkitdirectory', '');
  }, [phase.kind]);
  // Closing the sheet mid-read stops the worker. (Closing while sending lets the last few parts finish.)
  useEffect(() => () => cancel.current?.(), []);

  function read(inputs: FitbitInput[]) {
    if (!inputs.length) return;
    setUnit(null);
    setPhase({ kind: 'reading', read: 0, total: 0 });
    const job = readFitbitExport(inputs, zone, (p) => setPhase((now) => (now.kind === 'reading' ? { kind: 'reading', ...p } : now)));
    cancel.current = job.cancel;
    job.done
      .then((found) => setPhase((now) => (now.kind === 'reading' ? { kind: 'preview', found } : now)))
      .catch((e: Error) => setPhase((now) => (now.kind === 'reading' ? { kind: 'choose', error: e.message } : now)))
      .finally(() => {
        cancel.current = null;
      });
  }

  function stop() {
    cancel.current?.();
    cancel.current = null;
    setPhase({ kind: 'choose' });
  }

  async function send(found: FitbitFound, chunks: FitbitChunk[], from = 0) {
    for (let i = from; i < chunks.length; i++) {
      setPhase({ kind: 'sending', sent: i, total: chunks.length });
      try {
        await sendJson('POST', '/fitbit/import', chunks[i]);
      } catch (e) {
        setPhase({ kind: 'failed', message: (e as Error).message, found, chunks, next: i });
        refresh();
        return;
      }
    }
    const finish = fitbitFinish({ daily: chunks.flatMap((c) => c.daily) });
    try {
      await sendJson('POST', '/fitbit/import/finish', finish);
    } catch (e) {
      setPhase({ kind: 'failed', message: (e as Error).message, found, chunks, next: chunks.length });
      return;
    }
    setPhase({ kind: 'done', days: finish.days });
    refresh();
    notifyDataChanged();
  }

  const found = phase.kind === 'preview' ? phase.found : null;
  const askUnit = found ? needsWeightUnit(found) : false;
  // Counted as if the unit were known, so the weigh-ins show before it's chosen.
  const preview = found ? fitbitPreview(fitbitRows(found, { weightUnit: unit ?? 'kg', today })) : null;
  const typical = found ? typicalWeight(found) : null;
  const nothing = preview !== null && preview.days === 0;

  const footer =
    phase.kind === 'reading' ? (
      <button className="btn btn-quiet" onClick={stop}>
        Stop
      </button>
    ) : phase.kind === 'preview' ? (
      <>
        <button className="btn btn-quiet" onClick={() => setPhase({ kind: 'choose' })}>
          Choose another
        </button>
        {!nothing && (
          <button className="btn btn-primary" disabled={askUnit && !unit} onClick={() => found && send(found, fitbitChunks(fitbitRows(found, { weightUnit: unit, today })))}>
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
    <Sheet eyebrow="Fitbit / Google Health" title="Import Fitbit data" onClose={onClose} footer={footer}>
      {phase.kind === 'choose' && (
        <>
          <p className="fitbit-steps">
            Request your Fitbit data at{' '}
            <a href="https://takeout.google.com" target="_blank" rel="noreferrer">
              takeout.google.com
            </a>{' '}
            — choose only Fitbit (or Google Health, if your account moved to Google) — then choose the .zip here, or the unzipped Fitbit folder.
          </p>
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
              const zips = [...e.dataTransfer.files].filter((f) => /\.zip$/i.test(f.name));
              if (zips.length) read(zips.map((file) => ({ file, path: file.name })));
              else setPhase({ kind: 'choose', error: 'Drop the .zip from Takeout here, or choose the unzipped folder.' });
            }}
          >
            <Icon name="upload" size={22} />
            <span>Drop the .zip here</span>
            <div className="btn-row">
              <button className="btn btn-primary" onClick={() => zipInput.current?.click()}>
                Choose .zip
              </button>
              <button className="btn" onClick={() => folderInput.current?.click()}>
                Choose folder
              </button>
            </div>
            <input
              ref={zipInput}
              type="file"
              accept=".zip,application/zip"
              multiple
              hidden
              onChange={(e) => {
                read([...(e.target.files ?? [])].map((file) => ({ file, path: file.name })));
                e.target.value = '';
              }}
            />
            <input
              ref={folderInput}
              type="file"
              multiple
              hidden
              onChange={(e) => {
                read([...(e.target.files ?? [])].map((file) => ({ file, path: file.webkitRelativePath || file.name })));
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
            A large export comes as several .zip files: choose them all at once. healthOS reads the export here, in this browser; only the daily readings it finds are sent to your
            account. Nothing else about the file leaves this device.
          </p>
        </>
      )}

      {phase.kind === 'reading' && (
        <div className="progress fitbit-progress" role="status">
          <div className="progress-label">Reading your export… {fmt(phase.read)} files</div>
          <div className="goal-track">
            <div className="goal-fill" style={{ width: `${phase.total ? Math.round((phase.read / phase.total) * 100) : 0}%` }} />
          </div>
          <p className="muted small">It stays on this device while it's read.</p>
        </div>
      )}

      {phase.kind === 'preview' &&
        preview &&
        (nothing ? (
          <p className="note-bad" role="status">
            <Icon name="alert" size={15} /> No Fitbit readings were found here. Choose the export from Takeout with Fitbit (or Google Health) selected.
          </p>
        ) : (
          <>
            <p className="fitbit-found" role="status">
              Found {foundText(preview)}.
            </p>
            {preview.firstDate && preview.lastDate && (
              <p className="muted small">
                From {new Date(`${preview.firstDate}T12:00:00Z`).toLocaleDateString(undefined, { month: 'short', day: 'numeric', year: 'numeric', timeZone: 'UTC' })} to{' '}
                {new Date(`${preview.lastDate}T12:00:00Z`).toLocaleDateString(undefined, { month: 'short', day: 'numeric', year: 'numeric', timeZone: 'UTC' })}.
              </p>
            )}
            {askUnit && (
              <div className="fitbit-unit">
                <p id={unitLabel}>
                  {typical !== null ? `Your weigh-ins read about ${fmt(typical, typical % 1 ? 1 : 0)}. ` : ''}The export doesn't say which unit: are they in kilograms or pounds?
                </p>
                <div className="filters" role="group" aria-labelledby={unitLabel}>
                  <button className={unit === 'kg' ? 'on' : ''} aria-pressed={unit === 'kg'} onClick={() => setUnit('kg')}>
                    kg
                  </button>
                  <button className={unit === 'lb' ? 'on' : ''} aria-pressed={unit === 'lb'} onClick={() => setUnit('lb')}>
                    lb
                  </button>
                </div>
                {typical !== null && unit === 'lb' && <p className="muted small">{fmt(typical / LB_PER_KG, 1)} kg</p>}
              </div>
            )}
            <p className="muted small">
              Days already imported from Fitbit are updated from this export. Readings from Apple Health, WHOOP and your own entries stay as they are, and each keeps its source.
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
          <Icon name="check" size={15} /> Imported {fmt(phase.days)} {phase.days === 1 ? 'day' : 'days'}. Fitbit readings are marked as Fitbit.
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
