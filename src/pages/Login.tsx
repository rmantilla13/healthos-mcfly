import { useEffect, useState } from 'react';
import { Icon } from '../components/Icon.tsx';

const MIN_PASSWORD = 10;

async function post(path: string, body: unknown) {
  const res = await fetch(`/api${path}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-HealthOS': '1' },
    body: JSON.stringify(body),
  });
  const json = (await res.json().catch(() => ({}))) as { error?: string };
  if (!res.ok) throw new Error(json.error ?? 'Something went wrong. Try again.');
  return json;
}

function Shell({ children, onSubmit }: { children: React.ReactNode; onSubmit?: (e: React.FormEvent) => void }) {
  return (
    <div className="login">
      <form className="card login-card" onSubmit={onSubmit ?? ((e) => e.preventDefault())}>
        <div className="brand login-brand">
          <svg width="30" height="30" viewBox="0 0 32 32" aria-hidden="true">
            <circle cx="16" cy="16" r="2.4" fill="currentColor" />
            <circle cx="16" cy="16" r="11" fill="none" stroke="currentColor" strokeWidth="1.2" strokeDasharray="2 3" />
          </svg>
          <span>healthOS</span>
        </div>
        {children}
      </form>
    </div>
  );
}

function ErrorNote({ error }: { error: string | null }) {
  if (!error) return null;
  return (
    <p className="note-bad" role="alert">
      <Icon name="alert" size={15} /> {error}
    </p>
  );
}

export function Login({ misconfigured, setup, onSignedIn }: { misconfigured: boolean; setup: boolean; onSignedIn: () => void }) {
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError(null);
    try {
      await post('/auth/login', { email, password });
      setPassword('');
      onSignedIn();
    } catch (err) {
      setError((err as Error).message);
    } finally {
      setBusy(false);
    }
  }

  if (misconfigured) {
    return (
      <Shell>
        <p className="muted">Sign-in isn't set up on this server yet. Run scripts/setup-vercel.sh on your Mac, then redeploy.</p>
      </Shell>
    );
  }

  return (
    <Shell onSubmit={submit}>
      {setup && (
        <p className="muted small">
          First sign-in: enter your email and the password you set with the setup script. This creates your admin account.
        </p>
      )}
      <label>
        <span>Email</span>
        <input type="email" autoComplete="username" autoFocus value={email} onChange={(e) => setEmail(e.target.value)} />
      </label>
      <label>
        <span>Password</span>
        <input type="password" autoComplete="current-password" value={password} onChange={(e) => setPassword(e.target.value)} />
      </label>
      <ErrorNote error={error} />
      <button className="btn btn-primary" type="submit" disabled={busy || !email || !password}>
        {busy ? 'Signing in…' : 'Sign in'}
      </button>
      {!setup && <p className="muted small">New here? You need an invite link from the admin. Forgot your password? Ask the admin for a reset link.</p>}
    </Shell>
  );
}

/** The page an invite or reset link opens: set a password (and, for an invite, your name and email). */
export function AccountLinkPage({ kind, token, onDone }: { kind: 'invite' | 'reset'; token: string; onDone: () => void }) {
  const [check, setCheck] = useState<{ state: 'checking' } | { state: 'bad'; error: string } | { state: 'ok'; email: string | null }>({ state: 'checking' });
  const [email, setEmail] = useState('');
  const [name, setName] = useState('');
  const [password, setPassword] = useState('');
  const [confirm, setConfirm] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    post('/auth/link', { token })
      .then((r) => {
        const link = r as { kind: 'invite' | 'reset'; email: string | null };
        if (link.kind !== kind) throw new Error('This link is invalid, expired or already used.');
        setCheck({ state: 'ok', email: link.email });
        if (link.email) setEmail(link.email);
      })
      .catch((err: Error) => setCheck({ state: 'bad', error: err.message }));
  }, [kind, token]);

  const tooShort = password.length > 0 && password.length < MIN_PASSWORD;
  const mismatch = confirm.length > 0 && confirm !== password;

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    if (password.length < MIN_PASSWORD || password !== confirm) return;
    setBusy(true);
    setError(null);
    try {
      if (kind === 'invite') await post('/auth/invite', { token, email, name, password });
      else await post('/auth/reset', { token, password });
      onDone();
    } catch (err) {
      setError((err as Error).message);
    } finally {
      setBusy(false);
    }
  }

  const leave = () => {
    location.hash = '#/';
  };

  if (check.state === 'checking') {
    return (
      <Shell>
        <p className="muted">Checking your link…</p>
      </Shell>
    );
  }
  if (check.state === 'bad') {
    return (
      <Shell>
        <ErrorNote error={check.error} />
        <p className="muted small">Ask the admin for a new link.</p>
        <button type="button" className="btn" onClick={leave}>
          Go to sign-in
        </button>
      </Shell>
    );
  }

  return (
    <Shell onSubmit={submit}>
      <div>
        <h2 className="login-title">{kind === 'invite' ? 'Create your account' : 'Choose a new password'}</h2>
        <p className="muted small">
          {kind === 'invite'
            ? 'Your dashboard is private to you. The admin can manage your account but never sees your health data.'
            : 'Setting a new password signs you out everywhere else.'}
        </p>
      </div>
      {kind === 'invite' && (
        <>
          <label>
            <span>Email</span>
            <input type="email" autoComplete="username" value={email} readOnly={Boolean(check.email)} onChange={(e) => setEmail(e.target.value)} autoFocus={!check.email} />
          </label>
          <label>
            <span>Name</span>
            <input autoComplete="given-name" value={name} maxLength={60} onChange={(e) => setName(e.target.value)} autoFocus={Boolean(check.email)} />
          </label>
        </>
      )}
      <label>
        <span>Password</span>
        <input type="password" autoComplete="new-password" value={password} onChange={(e) => setPassword(e.target.value)} autoFocus={kind === 'reset'} aria-describedby="pw-hint" />
        <small id="pw-hint" className={tooShort ? 'note-bad' : 'muted'}>
          At least {MIN_PASSWORD} characters.
        </small>
      </label>
      <label>
        <span>Confirm password</span>
        <input type="password" autoComplete="new-password" value={confirm} onChange={(e) => setConfirm(e.target.value)} />
        {mismatch && <small className="note-bad">The passwords don't match.</small>}
      </label>
      <ErrorNote error={error} />
      <button
        className="btn btn-primary"
        type="submit"
        disabled={busy || password.length < MIN_PASSWORD || password !== confirm || (kind === 'invite' && !email)}
      >
        {busy ? 'Saving…' : kind === 'invite' ? 'Create account' : 'Set password'}
      </button>
    </Shell>
  );
}
