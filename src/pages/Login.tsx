import { useState } from 'react';
import { Icon } from '../components/Icon.tsx';

export function Login({ misconfigured, onSignedIn }: { misconfigured: boolean; onSignedIn: () => void }) {
  const [password, setPassword] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError(null);
    try {
      const res = await fetch('/api/auth/login', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'X-HealthOS': '1' },
        body: JSON.stringify({ password }),
      });
      if (!res.ok) throw new Error(((await res.json().catch(() => ({}))) as { error?: string }).error ?? 'Sign-in failed');
      setPassword('');
      onSignedIn();
    } catch (err) {
      setError((err as Error).message);
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="login">
      <form className="card login-card" onSubmit={submit}>
        <div className="brand login-brand">
          <svg width="30" height="30" viewBox="0 0 32 32" aria-hidden="true">
            <circle cx="16" cy="16" r="2.4" fill="currentColor" />
            <circle cx="16" cy="16" r="11" fill="none" stroke="currentColor" strokeWidth="1.2" strokeDasharray="2 3" />
          </svg>
          <span>healthOS</span>
        </div>
        {misconfigured ? (
          <p className="muted">Sign-in isn't set up on this server yet. Run scripts/setup-vercel.sh on your Mac, then redeploy.</p>
        ) : (
          <>
            <label>
              <span>Password</span>
              <input type="password" autoComplete="current-password" autoFocus value={password} onChange={(e) => setPassword(e.target.value)} />
            </label>
            {error && (
              <p className="note-bad">
                <Icon name="alert" size={15} /> {error}
              </p>
            )}
            <button className="btn btn-primary" type="submit" disabled={busy || !password}>
              {busy ? 'Signing in…' : 'Sign in'}
            </button>
          </>
        )}
      </form>
    </div>
  );
}
