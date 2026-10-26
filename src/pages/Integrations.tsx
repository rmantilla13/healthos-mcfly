// Integrations: where readings come from. Three sources side by side (stacked on a phone): WHOOP (connected through
// WHOOP's sign-in), a Fitbit / Google Health export read in this browser (FitbitImport.tsx), and Apple Health (the
// iPhone app, or an export on the Mac). Then a note on what a reading is and, locally, the demo data. Your own settings
// are on Profile (src/pages/Profile.tsx).
import '../styles/integrations.css';
import { type ReactNode, useEffect, useId, useRef, useState } from 'react';
import type { Settings, Status, SyncResult } from '../../shared/types.ts';
import { Icon } from '../components/Icon.tsx';
import { PageIntro } from '../components/PageIntro.tsx';
import { Sheet } from '../components/Sheet.tsx';
import { copyText, fmt, fmtDate, notifyDataChanged, sendJson, uploadFile } from '../lib.ts';
import { FitbitImport } from './FitbitImport.tsx';

function ago(iso: string) {
  const mins = Math.round((Date.now() - Date.parse(iso)) / 60_000);
  if (mins < 1) return 'just now';
  if (mins < 60) return `${mins} min ago`;
  if (mins < 48 * 60) return `${Math.round(mins / 60)} h ago`;
  return fmtDate(iso.slice(0, 10), { month: 'short', day: 'numeric', year: 'numeric' });
}

/** "Oct 23" for an import's moment, in this device's own calendar. */
const shortDay = (iso: string) => new Date(iso).toLocaleDateString(undefined, { month: 'short', day: 'numeric' });

/** "Mar 2021 – Oct 2026" for the span of an import. */
const span = (first: string | null, last: string | null) =>
  first && last ? `${fmtDate(first, { month: 'short', year: 'numeric' })} – ${fmtDate(last, { month: 'short', year: 'numeric' })}` : '';

const mb = (b: number) => `${fmt(b / 1_048_576, b > 100 * 1_048_576 ? 0 : 1)} MB`;

type Tone = 'sage' | 'peach' | 'muted' | 'bad';
const Chip = ({ tone, children }: { tone: Tone; children: ReactNode }) => <span className={`badge badge-${tone} source-chip`}>{children}</span>;

/** One source: its letter tile, name and state, what it brings, then its actions and a footnote along the bottom. */
function SourceCard({ tile, title, chip, children, actions, foot }: { tile: string; title: string; chip: ReactNode; children: ReactNode; actions?: ReactNode; foot?: ReactNode }) {
  const id = useId();
  return (
    <section className="card source-card" aria-labelledby={id}>
      <span className="source-tile" aria-hidden="true">
        {tile}
      </span>
      <div className="source-title">
        <h2 id={id}>{title}</h2>
        {chip}
      </div>
      <div className="source-body">{children}</div>
      {(actions || foot) && (
        <div className="source-end">
          {actions && <div className="btn-row">{actions}</div>}
          {foot}
        </div>
      )}
    </section>
  );
}

export function Integrations({ status, params, refresh, signedIn }: { status: Status; params: URLSearchParams; refresh: () => void; signedIn: boolean }) {
  const isAdmin = status.user.role === 'admin';
  const whoopParam = params.get('whoop');
  return (
    <div className="page integrations">
      <PageIntro title="Bring your health together." sub="Your account. Your measurements. Your choice." />

      {whoopParam === 'connected' && (
        <div className="banner banner-good" role="status">
          <Icon name="check" size={16} /> WHOOP connected. Your last year is syncing now.
        </div>
      )}
      {whoopParam === 'error' && (
        <div className="banner banner-bad" role="alert">
          <Icon name="alert" size={16} />{' '}
          {/* The reason can be WHOOP's own technical wording, so only admins see it. */}
          {isAdmin || !status.hosted ? `WHOOP connection failed: ${params.get('message')}` : "WHOOP didn't connect. Try connecting again."}
        </div>
      )}
      {whoopParam === 'not-configured' && (
        <div className="banner banner-bad" role="alert">
          <Icon name="alert" size={16} />{' '}
          {!status.hosted
            ? 'Add your WHOOP client ID and secret to .env first (the steps are on the WHOOP card).'
            : isAdmin
              ? "WHOOP isn't set up yet. Add WHOOP_CLIENT_ID and WHOOP_CLIENT_SECRET to the Vercel project, then redeploy."
              : "WHOOP isn't available here yet."}
        </div>
      )}

      <div className="sources-grid">
        <WhoopCard status={status} refresh={refresh} />
        <FitbitCard status={status} refresh={refresh} />
        <AppleCard status={status} refresh={refresh} signedIn={signedIn} />
      </div>

      <section className="card sources-note" aria-labelledby="sources-note">
        <h2 id="sources-note">Measured. Always clear.</h2>
        <p>
          Every reading keeps its source and date. Disconnecting stops access; previously imported measurements stay in your records. Nutrition logs do not measure glucose,
          inflammation or water retention.
        </p>
      </section>

      {/* Demo rows are seeded only in a local database, for the owner. */}
      {!status.hosted && status.user.id === 'owner' && <DemoCard status={status} refresh={refresh} />}
    </div>
  );
}

// ---------- WHOOP ----------

function WhoopCard({ status, refresh }: { status: Status; refresh: () => void }) {
  const isAdmin = status.user.role === 'admin';
  const w = status.whoop;
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  async function act(path: string, body?: unknown) {
    setError(null);
    setBusy(true);
    try {
      await sendJson<SyncResult>('POST', path, body);
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
      refresh();
    }
  }

  const chip = w.lastError ? (
    <Chip tone="bad">Needs attention</Chip>
  ) : w.connected ? (
    w.syncing ? (
      <Chip tone="muted">Syncing…</Chip>
    ) : (
      <Chip tone="sage">Connected</Chip>
    )
  ) : w.configured ? (
    <Chip tone="peach">Ready to connect</Chip>
  ) : status.hosted && !isAdmin ? (
    <Chip tone="muted">Not available yet</Chip>
  ) : (
    <Chip tone="peach">Needs a developer app</Chip>
  );

  const actions = w.connected ? (
    <>
      <button className="btn" disabled={w.syncing || busy} onClick={() => act('/sync')}>
        <Icon name="refresh" size={15} /> {w.syncing ? 'Syncing…' : 'Sync now'}
      </button>
      <button className="btn" disabled={w.syncing || busy} onClick={() => act('/whoop/sync', { full: true })}>
        Re-sync full year
      </button>
      <button className="btn btn-quiet" disabled={busy} onClick={() => act('/whoop/disconnect')}>
        Disconnect
      </button>
    </>
  ) : w.configured ? (
    <a className="btn" href="/api/whoop/connect">
      Connect WHOOP
    </a>
  ) : undefined;

  return (
    <SourceCard tile="W" title="WHOOP" chip={chip} actions={actions}>
      <p>
        Recovery, sleep, resting heart rate, HRV, blood oxygen and respiratory rate. Includes skin temperature, sleep stages, efficiency and consistency. Imports your last year
        right away, then the rest of your history.
      </p>
      {w.connected && (
        <p className="source-state" aria-live="polite">
          {w.syncing ? 'Syncing now…' : w.lastSync ? `Synced ${ago(w.lastSync)}` : 'Not synced yet'}
          {` · syncs every hour${status.hosted ? '' : ' while healthOS is running'}`}
        </p>
      )}
      {w.configured && !w.connected && <p className="source-state">You'll sign in on WHOOP's site and come straight back.</p>}
      {!w.configured && status.hosted && (
        <p className="source-state">
          {isAdmin ? 'Add WHOOP_CLIENT_ID and WHOOP_CLIENT_SECRET to the Vercel project, then redeploy.' : "WHOOP isn't turned on here yet. Ask the admin if you'd like to use it."}
        </p>
      )}
      {!w.configured && !status.hosted && (
        <details className="source-more">
          <summary>
            Set up a WHOOP developer app <Icon name="chevron-down" size={14} />
          </summary>
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
              <CopyField value={w.redirectUri} />
            </li>
            <li>Select every read scope (recovery, cycles, sleep, workout, profile, body measurement).</li>
            <li>
              Copy <code>.env.example</code> to <code>.env</code>, paste the client ID and secret, then restart <code>npm run dev</code>.
            </li>
          </ol>
        </details>
      )}
      {w.lastError && (
        <p className="note-bad">
          <Icon name="alert" size={15} /> Last sync failed: {w.lastError}
        </p>
      )}
      {error && (
        <p className="note-bad" role="alert">
          <Icon name="alert" size={15} /> {error}
        </p>
      )}
    </SourceCard>
  );
}

// ---------- Fitbit / Google Health ----------

function FitbitCard({ status, refresh }: { status: Status; refresh: () => void }) {
  const [open, setOpen] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // Missing from servers older than the Fitbit import; there's nothing imported then.
  const last = status.fitbit?.lastImport ?? null;

  async function remove() {
    if (!confirm('Remove all imported Fitbit data from healthOS? Your Fitbit account and the export file are not affected.')) return;
    setError(null);
    try {
      await sendJson('POST', '/fitbit/clear');
      notifyDataChanged();
    } catch (e) {
      setError((e as Error).message);
    }
    refresh();
  }

  return (
    <SourceCard
      tile="G"
      title="Fitbit / Google Health"
      chip={<Chip tone="sage">{last ? `Imported ${shortDay(last.importedAt)}` : 'File import available'}</Chip>}
      actions={
        <>
          <button className="btn" onClick={() => setOpen(true)} aria-haspopup="dialog">
            {last ? 'Import again' : 'Import Fitbit data'}
          </button>
          {last && (
            <button className="btn btn-quiet" onClick={remove}>
              Remove Fitbit data
            </button>
          )}
        </>
      }
      foot={<p className="source-foot">Automatic sync needs an approved Google Health app.</p>}
    >
      <p>Import recorded heart rate, sleep, HRV, weight and body-fat measurements from your data export.</p>
      {last && (
        <p className="source-state">
          {fmt(last.days)} {last.days === 1 ? 'day' : 'days'}
          {last.firstDate && ` · ${span(last.firstDate, last.lastDate)}`}
        </p>
      )}
      {error && (
        <p className="note-bad" role="alert">
          <Icon name="alert" size={15} /> {error}
        </p>
      )}
      {open && <FitbitImport status={status} refresh={refresh} onClose={() => setOpen(false)} />}
    </SourceCard>
  );
}

// ---------- Apple Health ----------

function AppleCard({ status, refresh, signedIn }: { status: Status; refresh: () => void; signedIn: boolean }) {
  const isAdmin = status.user.role === 'admin';
  const a = status.apple;
  const [importing, setImporting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const busy = a.job.state === 'uploading' || a.job.state === 'parsing';
  const wasBusy = useRef(false);
  // Poll while an export import runs here (sheet open or not), and tell the dashboard when it finishes. (A WHOOP sync
  // is watched by the dashboard itself, on every page.)
  useEffect(() => {
    if (wasBusy.current && !busy) notifyDataChanged();
    wasBusy.current = busy;
    if (!busy) return;
    const t = setInterval(refresh, 1000);
    return () => clearInterval(t);
  }, [busy, refresh]);
  // The iPhone app is the automatic way in: once it has a token, or has sent anything, that's how this account syncs.
  const phone = a.iphoneToken || a.lastSync !== null;
  const stale = status.hosted && phone && (!a.lastSync || Date.now() - Date.parse(a.lastSync.syncedAt) > 86_400_000);

  async function remove() {
    if (!confirm('Remove all imported Apple Health data from healthOS? Your iPhone is not affected.')) return;
    setError(null);
    try {
      await sendJson('POST', '/apple/clear');
      notifyDataChanged();
    } catch (e) {
      setError((e as Error).message);
    }
    refresh();
  }

  const chip = phone ? (
    <Chip tone="sage">Syncing from iPhone</Chip>
  ) : busy ? (
    <Chip tone="muted">Importing…</Chip>
  ) : a.lastImport ? (
    <Chip tone="sage">Imported {shortDay(a.lastImport.importedAt)}</Chip>
  ) : status.hosted ? (
    // Hosted, the export import runs on the Mac only: the iPhone app is how Apple Health gets here.
    <Chip tone="peach">Ready to connect</Chip>
  ) : (
    <Chip tone="sage">File import available</Chip>
  );

  return (
    <SourceCard
      tile="⌘"
      title="Apple Watch / Health"
      chip={chip}
      actions={
        (!status.hosted || (a.lastImport && !busy)) && (
          <>
            {!status.hosted && (
              <button className="btn" onClick={() => setImporting(true)} aria-haspopup="dialog">
                Import Apple Health
              </button>
            )}
            {a.lastImport && !busy && (
              <button className="btn btn-quiet" onClick={remove}>
                Remove Apple Health data
              </button>
            )}
          </>
        )
      }
      foot={
        <>
          {!phone && <p className="source-foot">Automatic sync needs an iPhone companion app.</p>}
          {a.lastSync && <p className="source-foot">Synced from iPhone {ago(a.lastSync.syncedAt)}</p>}
          {signedIn && (
            <details className="source-more">
              <summary>
                Set up the iPhone app <Icon name="chevron-down" size={14} />
              </summary>
              <IphoneToken status={status} refresh={refresh} />
            </details>
          )}
        </>
      }
    >
      {status.hosted ? (
        <>
          <p>Heart rate, HRV, oxygen, breathing and scale measurements arrive from your iPhone through the healthOS iPhone app, which syncs on its own.</p>
          <p className="source-state">
            Importing an export file works from healthOS on your Mac.
            {isAdmin && (
              <>
                {' '}
                To import a full export.zip into your own account, run healthOS on your Mac against this database (<code>vercel env pull .env.local</code>, then{' '}
                <code>npm run import:apple -- ~/Downloads/export.zip</code>).
              </>
            )}
          </p>
        </>
      ) : (
        <p>Import heart rate, HRV, oxygen, breathing and scale measurements from your iPhone Health export.</p>
      )}
      {a.lastImport && (
        <p className="source-state">
          Imported {ago(a.lastImport.importedAt)} · {fmt(a.lastImport.records)} records{a.lastImport.firstDate && ` · ${span(a.lastImport.firstDate, a.lastImport.lastDate)}`}
        </p>
      )}
      {busy && !importing && (
        <p className="source-state" aria-live="polite">
          {a.job.state === 'uploading' ? 'Uploading your export…' : `Reading records… ${fmt(a.job.state === 'parsing' ? a.job.records : 0)}`}
        </p>
      )}
      {stale && <p className="source-state">Open the healthOS app on your iPhone to send Apple Health.</p>}
      {error && (
        <p className="note-bad" role="alert">
          <Icon name="alert" size={15} /> {error}
        </p>
      )}
      {importing && <AppleImport status={status} refresh={refresh} onClose={() => setImporting(false)} />}
    </SourceCard>
  );
}

/** The local export import (POST /api/apple/upload, read on this Mac), in a sheet: the steps, a drop zone and its progress. */
function AppleImport({ status, refresh, onClose }: { status: Status; refresh: () => void; onClose: () => void }) {
  const job = status.apple.job;
  const busy = job.state === 'uploading' || job.state === 'parsing';
  const [uploadPct, setUploadPct] = useState<number | null>(null);
  const [uploadError, setUploadError] = useState<string | null>(null);
  const [drag, setDrag] = useState(false);
  const fileInput = useRef<HTMLInputElement>(null);

  // While the file uploads, refresh until the server's job shows it (the card polls from there on).
  const uploading = uploadPct !== null;
  useEffect(() => {
    if (!uploading || busy) return;
    const t = setInterval(refresh, 1000);
    return () => clearInterval(t);
  }, [uploading, busy, refresh]);

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

  const progress =
    uploadPct !== null
      ? { label: `Uploading… ${Math.round(uploadPct * 100)}%`, pct: uploadPct }
      : job.state === 'parsing'
        ? { label: `Reading records… ${fmt(job.records)}`, pct: job.totalBytes ? job.bytesRead / job.totalBytes : 0 }
        : null;

  return (
    <Sheet
      eyebrow="Apple Watch / Health"
      title="Import Apple Health"
      onClose={onClose}
      footer={
        <button className="btn btn-primary" onClick={onClose}>
          {busy || uploadPct !== null ? 'Keep importing in the background' : 'Done'}
        </button>
      }
    >
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
        {progress ? (
          <div className="progress" role="status">
            <div className="progress-label">{progress.label}</div>
            <div className="goal-track">
              <div className="goal-fill" style={{ width: `${Math.round(progress.pct * 100)}%` }} />
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
            <button className="btn" onClick={() => fileInput.current?.click()} disabled={busy}>
              Choose file
            </button>
          </>
        )}
        <input ref={fileInput} type="file" accept=".zip,.xml" hidden onChange={(e) => e.target.files?.[0] && upload(e.target.files[0])} />
      </div>
      {job.state === 'done' && uploadPct === null && (
        <p className="note-good" role="status">
          <Icon name="check" size={15} /> Imported {fmt(job.records)} records across {fmt(job.days)} days.
        </p>
      )}
      {(uploadError || job.state === 'error') && (
        <p className="note-bad" role="alert">
          <Icon name="alert" size={15} /> {uploadError ?? (job.state === 'error' ? job.error : '')}
        </p>
      )}
      <p className="muted small">
        Very large exports (several GB) are quicker from the terminal: <code>npm run import:apple -- ~/Downloads/export.zip</code>
      </p>
    </Sheet>
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
    <div className="iphone-token">
      <p>{has ? 'Token set. The app can send your Apple Health data here.' : 'No token yet.'}</p>
      {token ? (
        <>
          <p>In the healthOS iPhone app, open Settings and paste these. The token is shown only now.</p>
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
        <p>The token lets the app write to your account only. It can't read anything back or sign in to the dashboard.</p>
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
        <p className="note-bad" role="alert">
          <Icon name="alert" size={15} /> {error}
        </p>
      )}
    </div>
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
    <section className="card demo-card" aria-labelledby="demo-card">
      <div>
        <h2 id="demo-card">Demo data</h2>
        <p>
          {status.demo ? 'Showing synthetic data. ' : 'Showing your data. '}
          On automatic, the demo turns off once your own readings arrive.
        </p>
      </div>
      <div className="filters" role="group" aria-label="Demo data">
        {(['auto', 'on', 'off'] as const).map((m) => (
          <button key={m} className={mode === m ? 'on' : ''} aria-pressed={mode === m} onClick={() => set(m)}>
            {m === 'auto' ? 'Automatic' : m === 'on' ? 'Always' : 'Off'}
          </button>
        ))}
      </div>
    </section>
  );
}
