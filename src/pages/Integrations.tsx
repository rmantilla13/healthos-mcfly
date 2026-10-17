import { useEffect, useRef, useState } from 'react';
import type { Settings, Status, SyncResult } from '../../shared/types.ts';
import { Icon } from '../components/Icon.tsx';
import { copyText, fmt, fmtDate, notifyDataChanged, sendJson, uploadFile } from '../lib.ts';
import { CycleSettings } from './Cycle.tsx';

function ago(iso: string) {
  const mins = Math.round((Date.now() - Date.parse(iso)) / 60_000);
  if (mins < 1) return 'just now';
  if (mins < 60) return `${mins} min ago`;
  if (mins < 48 * 60) return `${Math.round(mins / 60)} h ago`;
  return fmtDate(iso.slice(0, 10), { month: 'short', day: 'numeric', year: 'numeric' });
}

const mb = (b: number) => `${fmt(b / 1_048_576, b > 100 * 1_048_576 ? 0 : 1)} MB`;

export function Integrations({ status, params, refresh, signedIn }: { status: Status; params: URLSearchParams; refresh: () => void; signedIn: boolean }) {
  const isAdmin = status.user.role === 'admin';
  const whoopParam = params.get('whoop');
  const job = status.apple.job;
  const busy = job.state === 'uploading' || job.state === 'parsing';
  const [uploadPct, setUploadPct] = useState<number | null>(null);
  const [uploadError, setUploadError] = useState<string | null>(null);
  const [drag, setDrag] = useState(false);
  const fileInput = useRef<HTMLInputElement>(null);
  const wasBusy = useRef(false);

  // Poll while an Apple Health import runs here, and tell the dashboard when it finishes. (A WHOOP sync is
  // watched by the dashboard itself, on every page.)
  useEffect(() => {
    const running = busy || uploadPct !== null;
    if (wasBusy.current && !running) notifyDataChanged();
    wasBusy.current = running;
    if (!running) return;
    const t = setInterval(refresh, 1000);
    return () => clearInterval(t);
  }, [busy, uploadPct, refresh]);

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
          <p>{status.hosted ? 'Your data is stored privately in your own healthOS account.' : 'Everything stays on this Mac, in a local database under data/.'}</p>
        </div>
        <SyncNow status={status} refresh={refresh} />
      </header>

      {whoopParam === 'connected' && (
        <div className="banner banner-good">
          <Icon name="check" size={16} /> WHOOP connected. Your last year is syncing now.
        </div>
      )}
      {whoopParam === 'error' && (
        <div className="banner banner-bad">
          <Icon name="alert" size={16} /> WHOOP connection failed: {params.get('message')}
        </div>
      )}
      {whoopParam === 'not-configured' && (
        <div className="banner banner-bad">
          <Icon name="alert" size={16} />{' '}
          {status.hosted ? "WHOOP isn't set up on this server yet." : 'Add your WHOOP client ID and secret to .env first (steps below).'}
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
                {status.apple.lastSync && `Synced from iPhone ${ago(status.apple.lastSync.syncedAt)}${status.apple.lastImport ? ' · ' : ''}`}
                {status.apple.lastImport
                  ? `Imported ${ago(status.apple.lastImport.importedAt)} · ${fmt(status.apple.lastImport.records)} records · ${fmtDate(status.apple.lastImport.firstDate ?? '', { month: 'short', year: 'numeric' })} – ${fmtDate(status.apple.lastImport.lastDate ?? '', { month: 'short', day: 'numeric', year: 'numeric' })}`
                  : !status.apple.lastSync && 'Not imported yet'}
              </p>
            </div>
          </div>
          {status.hosted ? (
            <p className="muted">
              Apple Health arrives here from the healthOS iPhone app, which syncs on its own. Create an app token below and add it in the app.
              {isAdmin && (
                <>
                  {' '}
                  To import a full export.zip into your own account, run healthOS on your Mac against this database (<code>vercel env pull .env.local</code>, then{' '}
                  <code>npm run import:apple -- ~/Downloads/export.zip</code>).
                </>
              )}
            </p>
          ) : (
            <>
              <ol className="steps">
                <li>
                  On your iPhone, open <b>Health</b>, tap your profile picture, then <b>Export All Health Data</b>.
                </li>
                <li>
                  AirDrop or save the <b>export.zip</b> to this Mac.
                </li>
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
            </>
          )}
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

          {!status.whoop.configured && status.hosted && (
            <p className="muted">{isAdmin ? 'Add WHOOP_CLIENT_ID and WHOOP_CLIENT_SECRET to the Vercel project, then redeploy.' : "The admin hasn't set up WHOOP on this server yet."}</p>
          )}
          {!status.whoop.configured && !status.hosted && (
            <ol className="steps">
              <li>
                Sign in at{' '}
                <a href="https://developer.whoop.com" target="_blank" rel="noreferrer">
                  developer.whoop.com
                </a>{' '}
                with your WHOOP account and create an app.
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
              <p className="muted">
                Syncs every 6 hours{status.hosted ? '' : ' while the app is running'}. Each sync rechecks the last few days, since WHOOP rescores recent nights.
              </p>
              <div className="btn-row">
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

      {signedIn && <IphoneToken status={status} refresh={refresh} />}
      {/* Demo rows are seeded only in a local database, for the owner. */}
      {!status.hosted && status.user.id === 'owner' && <DemoCard status={status} refresh={refresh} />}
    </div>
  );
}

/**
 * The one sync control: WHOOP syncs on the server (also every 6 hours, and when the dashboard opens with
 * stale data); Apple Health comes from the iPhone app on its own, so here it's a status line.
 */
function SyncNow({ status, refresh }: { status: Status; refresh: () => void }) {
  const [error, setError] = useState<string | null>(null);
  const w = status.whoop;
  const apple = status.apple.lastSync?.syncedAt ?? status.apple.lastImport?.importedAt ?? null;
  const appleStale = status.hosted && (!apple || Date.now() - Date.parse(apple) > 86_400_000);
  return (
    <div className="sync-now">
      {w.connected && (
        <button
          className="btn btn-primary"
          disabled={w.syncing}
          onClick={async () => {
            setError(null);
            try {
              await sendJson<SyncResult>('POST', '/sync');
            } catch (e) {
              setError((e as Error).message);
            }
            refresh();
          }}
        >
          <Icon name="refresh" size={15} /> {w.syncing ? 'Syncing…' : 'Sync now'}
        </button>
      )}
      <p className="muted small">
        Apple Health {apple ? `synced ${ago(apple)}` : 'not synced yet'}
        {w.connected ? ` · WHOOP ${w.syncing ? 'syncing…' : w.lastSync ? `synced ${ago(w.lastSync)}` : 'not synced yet'}` : ''}
      </p>
      {appleStale && <p className="muted small">Open the healthOS app on your iPhone to send Apple Health.</p>}
      {error && (
        <p className="note-bad">
          <Icon name="alert" size={15} /> {error}
        </p>
      )}
    </div>
  );
}

/** A personal token for the iPhone app. Shown once; the server keeps only its hash. */
function IphoneToken({ status, refresh }: { status: Status; refresh: () => void }) {
  const [token, setToken] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const has = status.apple.iphoneToken;

  async function create() {
    if (has && !confirm('Create a new token? The iPhone app stops syncing until you paste the new one.')) return;
    setError(null);
    try {
      setToken((await sendJson<{ token: string }>('POST', '/me/ingest-token')).token);
      refresh();
    } catch (e) {
      setError((e as Error).message);
    }
  }

  async function revoke() {
    if (!confirm('Revoke the iPhone app token? The app stops syncing until you create a new one.')) return;
    setError(null);
    try {
      await sendJson('DELETE', '/me/ingest-token');
      setToken(null);
      refresh();
    } catch (e) {
      setError((e as Error).message);
    }
  }

  return (
    <section className="card integration">
      <div className="integration-head">
        <span className="integration-logo logo-whoop">
          <Icon name="link" size={18} />
        </span>
        <div>
          <h2>iPhone app</h2>
          <p className="muted">{has ? 'Token set. The app can send your Apple Health data here.' : 'No token yet.'}</p>
        </div>
      </div>
      {token ? (
        <>
          <p className="muted">In the healthOS iPhone app, open Settings and paste these. The token is shown only now.</p>
          <div className="settings-row">
            <span>Server</span>
            <CopyField value={location.origin} label="Copy server address" />
          </div>
          <div className="settings-row">
            <span>Token</span>
            <CopyField value={token} label="Copy token" />
          </div>
        </>
      ) : (
        <p className="muted">The token lets the app write to your account only. It can't read anything back or sign in to the dashboard.</p>
      )}
      <div className="btn-row">
        <button className="btn btn-primary" onClick={create}>
          {has ? 'Create a new token' : 'Create token'}
        </button>
        {has && (
          <button className="btn btn-quiet" onClick={revoke}>
            Revoke
          </button>
        )}
      </div>
      {error && (
        <p className="note-bad">
          <Icon name="alert" size={15} /> {error}
        </p>
      )}
    </section>
  );
}

export function CopyField({ value, label = 'Copy redirect URL' }: { value: string; label?: string }) {
  const [copied, setCopied] = useState(false);
  return (
    <span className="copy-field">
      <code>{value}</code>
      <button
        className="icon-btn"
        type="button"
        aria-label={copied ? 'Copied' : label}
        onClick={() => {
          copyText(value)
            .then(() => {
              setCopied(true);
              setTimeout(() => setCopied(false), 1500);
            })
            .catch(() => {});
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

type Processed = { cutout: Blob; avatar: Blob; meta: unknown; cutoutUrl: string; avatarUrl: string };

const base64 = (blob: Blob) =>
  new Promise<string>((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(String(reader.result).split(',')[1] ?? '');
    reader.onerror = () => reject(new Error("Couldn't read the processed photo."));
    reader.readAsDataURL(blob);
  });

function PhotoSettings({ status, refresh }: { status: Status; refresh: () => void }) {
  const [busy, setBusy] = useState(false);
  const [step, setStep] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [drag, setDrag] = useState(false);
  const [preview, setPreview] = useState<Processed | null>(null);
  const input = useRef<HTMLInputElement>(null);
  const photo = status.photo;

  useEffect(
    () => () => {
      if (preview) {
        URL.revokeObjectURL(preview.cutoutUrl);
        URL.revokeObjectURL(preview.avatarUrl);
      }
    },
    [preview],
  );

  /** On the Mac: the server cuts the photo out with Apple Vision. */
  async function uploadToMac(file: File) {
    const res = await fetch('/api/profile/photo', { method: 'POST', headers: { 'X-HealthOS': '1', 'Content-Type': 'application/octet-stream' }, body: file });
    if (!res.ok) throw new Error(((await res.json().catch(() => ({}))) as { error?: string }).error ?? 'Processing failed');
    refresh();
    notifyDataChanged();
  }

  /** Hosted: cut out and measured right here in the browser; nothing is uploaded until you save. */
  async function processHere(file: File) {
    const { processPhoto } = await import('../photo/process.ts');
    const done = await processPhoto(file, setStep);
    setPreview({ ...done, cutoutUrl: URL.createObjectURL(done.cutout), avatarUrl: URL.createObjectURL(done.avatar) });
  }

  async function choose(file: File) {
    setError(null);
    if (!file.type.startsWith('image/') && !/\.(heic|heif)$/i.test(file.name)) return setError('Choose an image file (JPEG or PNG).');
    setBusy(true);
    try {
      await (status.hosted ? processHere(file) : uploadToMac(file));
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
      setStep(null);
    }
  }

  async function save() {
    if (!preview) return;
    setBusy(true);
    setError(null);
    try {
      const res = await fetch('/api/profile/photo/upload', {
        method: 'POST',
        headers: { 'X-HealthOS': '1', 'Content-Type': 'application/json' },
        body: JSON.stringify({ cutout: await base64(preview.cutout), avatar: await base64(preview.avatar), meta: preview.meta }),
      });
      if (res.status === 413) throw new Error('That photo came out too large to save. Try a smaller or tighter photo.');
      if (!res.ok) throw new Error(((await res.json().catch(() => ({}))) as { error?: string }).error ?? "Couldn't save the photo.");
      setPreview(null);
      refresh();
      notifyDataChanged();
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
          {status.hosted
            ? 'Used for the figure on Home and your avatar. It\'s cut out on this device; only the cut-out, avatar and the points for your vitals are saved.'
            : "Used for the figure on Home and your avatar. It's cut out and analyzed on this Mac with Apple's Vision framework, then saved to your healthOS database."}
        </p>
      </div>
      {preview ? (
        <div className="photo-row">
          <img className="photo-preview" src={preview.cutoutUrl} alt="Your new cut-out" />
          <div className="photo-confirm">
            <img className="photo-avatar-preview" src={preview.avatarUrl} alt="Your new avatar" />
            <p className="muted small">Here's how it came out. Save it to use it on Home and as your avatar.</p>
            <div className="btn-row">
              <button className="btn btn-primary" disabled={busy} onClick={save}>
                {busy ? 'Saving…' : 'Save photo'}
              </button>
              <button className="btn btn-quiet" disabled={busy} onClick={() => setPreview(null)}>
                Cancel
              </button>
            </div>
          </div>
        </div>
      ) : (
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
              if (f && !busy) choose(f);
            }}
          >
            {busy ? (
              <span className="progress-label">
                {status.hosted ? (step ?? 'Working…') : 'Cutting out and measuring… (the first run compiles the tool, about 15s)'}
              </span>
            ) : (
              <>
                <Icon name="upload" size={22} />
                <span>{photo ? 'Drop a new photo to replace it' : 'Drop a photo of yourself here'}</span>
                <button className="btn" onClick={() => input.current?.click()}>
                  {photo ? 'Choose a new photo' : 'Upload a photo'}
                </button>
              </>
            )}
            <input
              ref={input}
              type="file"
              accept="image/*,.heic,.heif"
              hidden
              onChange={(e) => {
                const f = e.target.files?.[0];
                e.target.value = '';
                if (f) choose(f);
              }}
            />
          </div>
        </div>
      )}
      {error && (
        <p className="note-bad">
          <Icon name="alert" size={15} /> {error}
        </p>
      )}
      {photo && !busy && !preview && (
        <button
          className="btn btn-quiet"
          onClick={async () => {
            await sendJson('POST', '/profile/photo/clear');
            refresh();
            notifyDataChanged();
          }}
        >
          Remove photo
        </button>
      )}
    </section>
  );
}

export function SettingsPage({ status, refresh, signedIn }: { status: Status; refresh: () => void; signedIn: boolean }) {
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
          <p>{status.hosted ? 'Saved to your healthOS account.' : 'Stored locally with your data.'}</p>
        </div>
        {signedIn && (
          <button
            className="btn"
            onClick={async () => {
              await sendJson('POST', '/auth/logout');
              window.location.reload();
            }}
          >
            Sign out
          </button>
        )}
      </header>
      <section className="card settings">
        <label>
          <span>Name</span>
          <input value={name} onChange={(e) => setName(e.target.value)} onBlur={() => name !== status.settings.name && save({ name })} />
        </label>
        <label>
          <span>Daily step goal</span>
          <input
            inputMode="numeric"
            value={goal}
            onChange={(e) => setGoal(e.target.value.replace(/\D/g, ''))}
            onBlur={() => Number(goal) !== status.settings.stepGoal && save({ stepGoal: Number(goal) })}
          />
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
      <CycleSettings status={status} refresh={refresh} />
      {signedIn && <AccountSettings status={status} />}
      <PhotoSettings status={status} refresh={refresh} />
    </div>
  );
}

function AccountSettings({ status }: { status: Status }) {
  const [current, setCurrent] = useState('');
  const [next, setNext] = useState('');
  const [confirmNext, setConfirmNext] = useState('');
  const [busy, setBusy] = useState(false);
  const [result, setResult] = useState<{ ok: boolean; text: string } | null>(null);
  const valid = current.length > 0 && next.length >= 10 && next === confirmNext;

  async function change(e: React.FormEvent) {
    e.preventDefault();
    if (!valid) return;
    setBusy(true);
    setResult(null);
    try {
      await sendJson('POST', '/auth/password', { current, next });
      setCurrent('');
      setNext('');
      setConfirmNext('');
      setResult({ ok: true, text: 'Password changed. Other devices are signed out.' });
    } catch (err) {
      setResult({ ok: false, text: (err as Error).message });
    } finally {
      setBusy(false);
    }
  }

  return (
    <section className="card settings">
      <h2>Account</h2>
      <div className="settings-row">
        <span>Email</span>
        <span className="muted">
          {status.user.email}
          {status.user.role === 'admin' && ' · admin'}
        </span>
      </div>
      <form className="settings" onSubmit={change}>
        <label>
          <span>Current password</span>
          <input type="password" autoComplete="current-password" value={current} onChange={(e) => setCurrent(e.target.value)} />
        </label>
        <label>
          <span>New password</span>
          <input type="password" autoComplete="new-password" value={next} onChange={(e) => setNext(e.target.value)} />
          <small className={next && next.length < 10 ? 'note-bad' : 'muted'}>At least 10 characters.</small>
        </label>
        <label>
          <span>Confirm new password</span>
          <input type="password" autoComplete="new-password" value={confirmNext} onChange={(e) => setConfirmNext(e.target.value)} />
          {confirmNext && confirmNext !== next && <small className="note-bad">The passwords don't match.</small>}
        </label>
        <button className="btn btn-primary" type="submit" disabled={busy || !valid}>
          {busy ? 'Changing…' : 'Change password'}
        </button>
        {result && (
          <p className={result.ok ? 'note-good' : 'note-bad'} role="status">
            <Icon name={result.ok ? 'check' : 'alert'} size={15} /> {result.text}
          </p>
        )}
      </form>
    </section>
  );
}
