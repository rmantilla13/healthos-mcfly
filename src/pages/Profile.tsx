// Profile (formerly Settings): your name, step goal and units, which cards show, Family, Cycle, Nutrition, your
// account and your photo. Reached from the account menu (#/profile; #/settings still opens it). The shell's header
// gives the page its title.
import { useEffect, useRef, useState } from 'react';
import type { Settings, Status } from '../../shared/types.ts';
import { Icon } from '../components/Icon.tsx';
import { CardChoices, useOwnCardEditor } from '../components/CardChoices.tsx';
import { notifyDataChanged, sendJson, signOut } from '../lib.ts';
import { CycleSettings } from './Cycle.tsx';
import { NutritionSettings } from './Nutrition.tsx';
import { FamilySettings } from './Family.tsx';

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

export function Profile({ status, refresh, signedIn }: { status: Status; refresh: () => void; signedIn: boolean }) {
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
    <div className="page profile-page">
      <p className="muted small">{status.hosted ? 'Saved to your healthOS account.' : 'Stored locally with your data.'}</p>
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
      <CardSettings status={status} refresh={refresh} />
      {signedIn && <FamilySettings status={status} refresh={refresh} />}
      <CycleSettings status={status} refresh={refresh} family={signedIn && status.settings.familySharing} />
      <NutritionSettings status={status} refresh={refresh} />
      {signedIn && <AccountSettings status={status} />}
      <PhotoSettings status={status} refresh={refresh} />
    </div>
  );
}

/** Which cards show on Home, Sleep, Body and Nutrition. Only the layout: nothing is deleted, and an unticked card comes back as it was. */
function CardSettings({ status, refresh }: { status: Status; refresh: () => void }) {
  const cards = useOwnCardEditor(status.settings, refresh);
  return (
    <section className="card settings-cards" id="cards">
      <div className="card-title-row">
        <h2>Cards</h2>
        {cards.lists.hidden.length > 0 && (
          <button className="btn btn-quiet" onClick={cards.showAll}>
            Show all
          </button>
        )}
      </div>
      <p className="muted small">
        Choose the cards you see on Home, Sleep{status.settings.nutrition ? ', Body and Nutrition' : ' and Body'}. Hiding one only changes the page; your data stays.
      </p>
      <CardChoices lists={cards.lists} onToggle={cards.toggle} idPrefix="me" nutrition={status.settings.nutrition} />
      {cards.error && <p className="note-bad small">{cards.error}</p>}
    </section>
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
      <div className="card-title-row">
        <h2>Account</h2>
        {/* Also in the account menu; kept here too for now. */}
        <button className="btn" onClick={signOut}>
          Sign out
        </button>
      </div>
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
