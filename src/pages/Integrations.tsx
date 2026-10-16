import { useEffect, useRef, useState } from 'react';
import type { Settings, Status } from '../../shared/types.ts';
import { Icon } from '../components/Icon.tsx';
import { fmt, fmtDate, notifyDataChanged, sendJson, uploadFile } from '../lib.ts';

function ago(iso: string) {
  const mins = Math.round((Date.now() - Date.parse(iso)) / 60_000);
  if (mins < 1) return 'just now';
  if (mins < 60) return `${mins} min ago`;
  if (mins < 48 * 60) return `${Math.round(mins / 60)} h ago`;
  return fmtDate(iso.slice(0, 10), { month: 'short', day: 'numeric', year: 'numeric' });
}

const mb = (b: number) => `${fmt(b / 1_048_576, b > 100 * 1_048_576 ? 0 : 1)} MB`;

export function Integrations({ status, params, refresh }: { status: Status; params: URLSearchParams; refresh: () => void }) {
  const whoopParam = params.get('whoop');
  const job = status.apple.job;
  const busy = job.state === 'uploading' || job.state === 'parsing';
  const [uploadPct, setUploadPct] = useState<number | null>(null);
  const [uploadError, setUploadError] = useState<string | null>(null);
  const [drag, setDrag] = useState(false);
  const fileInput = useRef<HTMLInputElement>(null);
  const wasBusy = useRef(false);

  // Poll while something is running, and tell the dashboard when it finishes.
  useEffect(() => {
    const running = busy || uploadPct !== null || status.whoop.syncing;
    if (wasBusy.current && !running) notifyDataChanged();
    wasBusy.current = running;
    if (!running) return;
    const t = setInterval(refresh, 1000);
    return () => clearInterval(t);
  }, [busy, uploadPct, status.whoop.syncing, refresh]);

  async function upload(file: File) {
    setUploadError(null);
    if (!/\.(zip|xml)$/i.test(file.name)) {
      setUploadError('Choose the export.zip (or export.xml) from the Health app.');
      return;
    }
    setUploadPct(0);
    try {
      await uploadFile(file, (sent, total) => setUploadPct(total ? sent / total : 0));
    } catch (e) {
      setUploadError((e as Error).message);
    } finally {
      setUploadPct(null);
      refresh();
    }
  }

  async function whoopAction(path: string, body?: unknown) {
    await sendJson('POST', path, body);
    refresh();
  }

  const appleProgress =
    uploadPct !== null
      ? { label: `Uploading… ${Math.round(uploadPct * 100)}%`, pct: uploadPct }
      : job.state === 'parsing'
        ? { label: `Reading records… ${fmt(job.records)}`, pct: job.totalBytes ? job.bytesRead / job.totalBytes : 0 }
        : null;

  return (
    <div className="page">
      <header className="page-head">
        <div>
          <h1>Integrations</h1>
          <p>Everything stays on this Mac, in a local database under data/.</p>
        </div>
      </header>

      {whoopParam === 'connected' && <div className="banner banner-good"><Icon name="check" size={16} /> WHOOP connected. Your last year is syncing now.</div>}
      {whoopParam === 'error' && (
        <div className="banner banner-bad">
          <Icon name="alert" size={16} /> WHOOP connection failed: {params.get('message')}
        </div>
      )}
      {whoopParam === 'not-configured' && (
        <div className="banner banner-bad">
          <Icon name="alert" size={16} /> Add your WHOOP client ID and secret to .env first (steps below).
        </div>
      )}

      <div className="grid-2">
        <section className="card integration">
          <div className="integration-head">
            <span className="integration-logo logo-apple">
              <Icon name="heart" size={20} />
            </span>
            <div>
              <h2>Apple Health</h2>
              <p className="muted">
                {status.apple.lastImport
                  ? `Imported ${ago(status.apple.lastImport.importedAt)} · ${fmt(status.apple.lastImport.records)} records · ${fmtDate(status.apple.lastImport.firstDate ?? '', { month: 'short', year: 'numeric' })} – ${fmtDate(status.apple.lastImport.lastDate ?? '', { month: 'short', day: 'numeric', year: 'numeric' })}`
                  : 'Not imported yet'}
              </p>
            </div>
          </div>
          <ol className="steps">
            <li>On your iPhone, open <b>Health</b>, tap your profile picture, then <b>Export All Health Data</b>.</li>
            <li>AirDrop or save the <b>export.zip</b> to this Mac.</li>
            <li>Drop it below. A new import replaces the previous one.</li>
          </ol>
          <div
            className={`dropzone ${drag ? 'is-drag' : ''} ${busy || uploadPct !== null ? 'is-busy' : ''}`}
            onDragOver={(e) => {
              e.preventDefault();
              setDrag(true);
            }}
            onDragLeave={() => setDrag(false)}
            onDrop={(e) => {
              e.preventDefault();
              setDrag(false);
              const f = e.dataTransfer.files[0];
              if (f && !busy) upload(f);
            }}
          >
            {appleProgress ? (
              <div className="progress">
                <div className="progress-label">{appleProgress.label}</div>
                <div className="goal-track">
                  <div className="goal-fill" style={{ width: `${Math.round(appleProgress.pct * 100)}%` }} />
                </div>
                {job.state === 'parsing' && job.totalBytes > 0 && (
                  <div className="muted small">
                    {mb(job.bytesRead)} of {mb(job.totalBytes)}
                  </div>
                )}
              </div>
            ) : (
              <>
                <Icon name="upload" size={22} />
                <span>Drop export.zip here</span>
                <button className="btn" onClick={() => fileInput.current?.click()}>
                  Choose file
                </button>
              </>
            )}
            <input ref={fileInput} type="file" accept=".zip,.xml" hidden onChange={(e) => e.target.files?.[0] && upload(e.target.files[0])} />
          </div>
          {job.state === 'done' && uploadPct === null && (
            <p className="note-good">
              <Icon name="check" size={15} /> Imported {fmt(job.records)} records across {fmt(job.days)} days.
            </p>
          )}
          {(uploadError || job.state === 'error') && (
            <p className="note-bad">
              <Icon name="alert" size={15} /> {uploadError ?? (job.state === 'error' ? job.error : '')}
            </p>
          )}
          <p className="muted small">
            Very large exports (several GB) are quicker from the terminal: <code>npm run import:apple -- ~/Downloads/export.zip</code>
          </p>
          {status.apple.lastImport && !busy && (
            <button
              className="btn btn-quiet"
              onClick={async () => {
                if (!confirm('Remove all imported Apple Health data from healthOS? Your iPhone is not affected.')) return;
                await sendJson('POST', '/apple/clear');
                refresh();
                notifyDataChanged();
              }}
            >
              Remove Apple Health data
            </button>
          )}
        </section>

        <section className="card integration">
          <div className="integration-head">
            <span className="integration-logo logo-whoop">W</span>
            <div>
              <h2>WHOOP</h2>
              <p className="muted">
                {status.whoop.connected
                  ? status.whoop.syncing
                    ? 'Syncing…'
                    : status.whoop.lastSync
                      ? `Connected · synced ${ago(status.whoop.lastSync)}`
                      : 'Connected'
                  : status.whoop.configured
                    ? 'Ready to connect'
                    : 'Needs a developer app'}
              </p>
            </div>
          </div>

          {!status.whoop.configured && (
            <ol className="steps">
              <li>
                Sign in at <a href="https://developer.whoop.com" target="_blank" rel="noreferrer">developer.whoop.com</a> with your WHOOP account and create an app.
              </li>
              <li>
                Add this redirect URL to the app:
                <CopyField value={status.whoop.redirectUri} />
              </li>
              <li>Select every read scope (recovery, cycles, sleep, workout, profile, body measurement).</li>
              <li>
                Copy <code>.env.example</code> to <code>.env</code>, paste the client ID and secret, then restart <code>npm run dev</code>.
              </li>
            </ol>
          )}

          {status.whoop.configured && !status.whoop.connected && (
            <>
              <p className="muted">You'll sign in on WHOOP's site and come straight back. The app reads recovery, sleep, strain, workouts and your profile.</p>
              <a className="btn btn-primary" href="/api/whoop/connect">
                Connect WHOOP
              </a>
            </>
          )}

          {status.whoop.connected && (
            <>
              <p className="muted">Syncs every 6 hours while the app is running. Each sync rechecks the last few days, since WHOOP rescores recent nights.</p>
              <div className="btn-row">
                <button className="btn btn-primary" disabled={status.whoop.syncing} onClick={() => whoopAction('/whoop/sync')}>
                  <Icon name="refresh" size={15} /> {status.whoop.syncing ? 'Syncing…' : 'Sync now'}
                </button>
                <button className="btn" disabled={status.whoop.syncing} onClick={() => whoopAction('/whoop/sync', { full: true })}>
                  Re-sync full year
                </button>
                <button className="btn btn-quiet" onClick={() => whoopAction('/whoop/disconnect')}>
                  Disconnect
                </button>
              </div>
            </>
          )}
          {status.whoop.lastError && (
            <p className="note-bad">
              <Icon name="alert" size={15} /> Last sync failed: {status.whoop.lastError}
            </p>
          )}
        </section>
      </div>

      <DemoCard status={status} refresh={refresh} />
    </div>
  );
}

function CopyField({ value }: { value: string }) {
  const [copied, setCopied] = useState(false);
  return (
    <span className="copy-field">
      <code>{value}</code>
      <button
        className="icon-btn"
        aria-label="Copy redirect URL"
        onClick={() => {
          navigator.clipboard?.writeText(value).then(() => {
            setCopied(true);
            setTimeout(() => setCopied(false), 1500);
          });
        }}
      >
        <Icon name={copied ? 'check' : 'copy'} size={14} />
      </button>
    </span>
  );
}

function DemoCard({ status, refresh }: { status: Status; refresh: () => void }) {
  const mode = status.settings.demo;
  const set = async (demo: Settings['demo']) => {
    await sendJson('PUT', '/settings', { demo });
    refresh();
    notifyDataChanged();
  };
  return (
    <section className="card integration">
      <div className="integration-head">
        <div>
          <h2>Demo data</h2>
          <p className="muted">
            {status.demo ? 'Showing synthetic data. ' : 'Showing your data. '}
            On automatic, the demo turns off once Apple Health or WHOOP data arrives.
          </p>
        </div>
        <div className="filters" role="group" aria-label="Demo data">
          {(['auto', 'on', 'off'] as const).map((m) => (
            <button key={m} className={mode === m ? 'on' : ''} aria-pressed={mode === m} onClick={() => set(m)}>
              {m === 'auto' ? 'Automatic' : m === 'on' ? 'Always' : 'Off'}
            </button>
          ))}
        </div>
      </div>
    </section>
  );
}

function PhotoSettings({ status, refresh }: { status: Status; refresh: () => void }) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [drag, setDrag] = useState(false);
  const input = useRef<HTMLInputElement>(null);
  const photo = status.photo;

  async function upload(file: File) {
    setError(null);
    if (!file.type.startsWith('image/') && !/\.(heic|heif)$/i.test(file.name)) return setError('Choose an image file (JPEG, PNG or HEIC).');
    setBusy(true);
    try {
      const res = await fetch('/api/profile/photo', { method: 'POST', headers: { 'X-HealthOS': '1', 'Content-Type': 'application/octet-stream' }, body: file });
      if (!res.ok) throw new Error(((await res.json().catch(() => ({}))) as { error?: string }).error ?? 'Processing failed');
      refresh();
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  }

  return (
    <section className="card settings">
      <div>
        <h2>Profile photo</h2>
        <p className="muted small">
          Used for the figure on Home, your avatar and the 3D view. It's cut out and analyzed on this Mac with Apple's Vision framework, and stored only in data/profile.
        </p>
      </div>
      <div className="photo-row">
        {photo && <img className="photo-preview" src={`/api/profile/cutout.png?v=${photo.version}`} alt="Your cut-out photo" />}
        <div
          className={`dropzone photo-drop ${drag ? 'is-drag' : ''}`}
          onDragOver={(e) => {
            e.preventDefault();
            setDrag(true);
          }}
          onDragLeave={() => setDrag(false)}
          onDrop={(e) => {
            e.preventDefault();
            setDrag(false);
            const f = e.dataTransfer.files[0];
            if (f && !busy) upload(f);
          }}
        >
          {busy ? (
            <span className="progress-label">Cutting out and measuring… (the first run compiles the tool, about 15s)</span>
          ) : (
            <>
              <Icon name="upload" size={22} />
              <span>{photo ? 'Drop a new photo to replace it' : 'Drop a photo of yourself here'}</span>
              <button className="btn" onClick={() => input.current?.click()}>
                Choose photo
              </button>
            </>
          )}
          <input ref={input} type="file" accept="image/*,.heic,.heif" hidden onChange={(e) => e.target.files?.[0] && upload(e.target.files[0])} />
        </div>
      </div>
      {error && (
        <p className="note-bad">
          <Icon name="alert" size={15} /> {error}
        </p>
      )}
      {photo && !busy && (
        <button
          className="btn btn-quiet"
          onClick={async () => {
            await sendJson('POST', '/profile/photo/clear');
            refresh();
          }}
        >
          Remove photo
        </button>
      )}
    </section>
  );
}

export function SettingsPage({ status, refresh }: { status: Status; refresh: () => void }) {
  const [name, setName] = useState(status.settings.name);
  const [goal, setGoal] = useState(String(status.settings.stepGoal));
  const [saved, setSaved] = useState(false);

  async function save(patch: Partial<Settings>) {
    await sendJson('PUT', '/settings', patch);
    refresh();
    notifyDataChanged();
    setSaved(true);
    setTimeout(() => setSaved(false), 1500);
  }

  return (
    <div className="page">
      <header className="page-head">
        <div>
          <h1>Settings</h1>
          <p>Stored locally with your data.</p>
        </div>
      </header>
      <section className="card settings">
        <label>
          <span>Name</span>
          <input value={name} onChange={(e) => setName(e.target.value)} onBlur={() => name !== status.settings.name && save({ name })} />
        </label>
        <label>
          <span>Daily step goal</span>
          <input inputMode="numeric" value={goal} onChange={(e) => setGoal(e.target.value.replace(/\D/g, ''))} onBlur={() => Number(goal) !== status.settings.stepGoal && save({ stepGoal: Number(goal) })} />
        </label>
        <div className="settings-row">
          <span>Units</span>
          <div className="filters" role="group" aria-label="Units">
            {(['metric', 'imperial'] as const).map((u) => (
              <button key={u} className={status.settings.units === u ? 'on' : ''} aria-pressed={status.settings.units === u} onClick={() => save({ units: u })}>
                {u === 'metric' ? 'Metric (kg, °C, km)' : 'Imperial (lb, °F, mi)'}
              </button>
            ))}
          </div>
        </div>
        <p className={`muted small saved ${saved ? 'is-on' : ''}`}>
          <Icon name="check" size={14} /> Saved
        </p>
      </section>
      <PhotoSettings status={status} refresh={refresh} />
    </div>
  );
}
