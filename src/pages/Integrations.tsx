// Integrations: Apple Health (the iPhone app, or an export on the Mac), WHOOP, the iPhone app's token and, locally,
// the demo data. Your own settings are on Profile (src/pages/Profile.tsx).
import { useEffect, useRef, useState } from 'react';
import type { Settings, Status, SyncResult } from '../../shared/types.ts';
import { Icon } from '../components/Icon.tsx';
import { PageIntro } from '../components/PageIntro.tsx';
import { copyText, fmt, fmtDate, notifyDataChanged, sendJson, uploadFile } from '../lib.ts';

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
      <PageIntro title="Bring your health together." sub="Your account. Your measurements. Your choice." actions={<SyncNow status={status} refresh={refresh} />} />
      <p className="muted small">{status.hosted ? 'Your data is stored privately in your own healthOS account.' : 'Everything stays on this Mac, in a local database under data/.'}</p>

      {whoopParam === 'connected' && (
        <div className="banner banner-good">
          <Icon name="check" size={16} /> WHOOP connected. Your last year is syncing now.
        </div>
      )}
      {whoopParam === 'error' && (
        <div className="banner banner-bad">
          <Icon name="alert" size={16} />{' '}
          {/* The reason can be WHOOP's own technical wording, so only admins see it. */}
          {isAdmin || !status.hosted ? `WHOOP connection failed: ${params.get('message')}` : "WHOOP didn't connect. Try connecting again."}
        </div>
      )}
      {whoopParam === 'not-configured' && (
        <div className="banner banner-bad">
          <Icon name="alert" size={16} />{' '}
          {!status.hosted
            ? 'Add your WHOOP client ID and secret to .env first (steps below).'
            : isAdmin
              ? "WHOOP isn't set up yet. Add WHOOP_CLIENT_ID and WHOOP_CLIENT_SECRET to the Vercel project, then redeploy."
              : "WHOOP isn't available here yet."}
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
                    : status.hosted && !isAdmin
                      ? 'Not available yet'
                      : 'Needs a developer app'}
              </p>
            </div>
          </div>

          {!status.whoop.configured && status.hosted && (
            <p className="muted">
              {isAdmin ? 'Add WHOOP_CLIENT_ID and WHOOP_CLIENT_SECRET to the Vercel project, then redeploy.' : "WHOOP isn't turned on here yet. Ask the admin if you'd like to use it."}
            </p>
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
                Syncs every hour{status.hosted ? '' : ' while the app is running'}. Each sync rechecks the last few days, since WHOOP rescores recent nights.
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
 * The one sync control: WHOOP syncs on the server (also every hour, and when the dashboard opens with
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
