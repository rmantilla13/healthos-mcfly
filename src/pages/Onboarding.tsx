// "Make this space yours": the three onboarding steps, shown full screen (no sidebar) to a new account until it's
// done, and again from #/welcome for anyone who wants to re-run it (mode 'edit'). A stand-in for now: it only lets
// you through, by finishing onboarding (PUT /api/settings { onboarding: null }).
import { useState } from 'react';
import type { Status } from '../../shared/types.ts';
import { Icon } from '../components/Icon.tsx';
import { Logo } from '../components/shell/Logo.tsx';
import { href, notifyDataChanged, sendJson, signOut } from '../lib.ts';

export function Onboarding({ status, reload, signedIn, mode }: { status: Status; reload: () => void; signedIn: boolean; mode: 'new' | 'edit' }) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function finish() {
    setBusy(true);
    setError(null);
    try {
      await sendJson('PUT', '/settings', { onboarding: null });
      if (mode === 'edit') location.hash = href('home');
      reload();
      notifyDataChanged();
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="onboarding">
      <header className="onboarding-top">
        <span className="brand">
          <Logo />
          <span>healthOS</span>
        </span>
        {signedIn && mode === 'new' && (
          <button type="button" className="btn btn-quiet" onClick={signOut}>
            Sign out
          </button>
        )}
      </header>
      <section className="card onboarding-card">
        <p className="eyebrow">Make this space yours</p>
        <h1>{status.settings.name ? `Welcome, ${status.settings.name}.` : 'Welcome.'}</h1>
        <p className="muted">A few choices about how healthOS shows you, coming here soon. You can change them anytime in your Profile.</p>
        <div className="onboarding-foot">
          {error && <p className="note-bad small">{error}</p>}
          <button type="button" className="btn btn-primary" disabled={busy} onClick={finish}>
            Continue to healthOS <Icon name="arrow-up-right" size={14} />
          </button>
        </div>
      </section>
      <p className="onboarding-note muted small">Your health, in perspective. Only yours.</p>
    </div>
  );
}
