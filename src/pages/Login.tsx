// Sign-in, joining with an invite code, and the page an invite or reset link opens. They share onboarding's frame
// (WelcomeShell), so a new member's way in reads as one flow: invite code → Create your account → the three steps of
// "Make this space yours" (Onboarding.tsx) → their dashboard.
import { useEffect, useState, type FormEvent, type ReactNode } from 'react';
import { Icon } from '../components/Icon.tsx';
import { WelcomeFoot, WelcomeShell } from '../components/WelcomeShell.tsx';
import '../styles/onboarding.css';

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

/** The sign-in card: an eyebrow and a title over the form, in the welcome frame. */
function Shell({
  eyebrow,
  title,
  lede,
  children,
  onSubmit,
}: {
  eyebrow?: string;
  title?: string;
  lede?: ReactNode;
  children?: ReactNode;
  onSubmit?: (e: FormEvent) => void;
}) {
  return (
    <WelcomeShell main>
      <form className="card onb-card onb-card-narrow" onSubmit={onSubmit ?? ((e) => e.preventDefault())} aria-labelledby={title ? 'onb-title' : undefined}>
        {title && (
          <div className="onb-head">
            {eyebrow && <p className="eyebrow">{eyebrow}</p>}
            <h1 id="onb-title">{title}</h1>
            {lede && <p className="onb-lede">{lede}</p>}
          </div>
        )}
        {children}
      </form>
    </WelcomeShell>
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

/** An invite code as typed: ABCD-EFGH, abcd efgh or a pasted link, ready for #/invite/<code>. */
const cleanCode = (raw: string) => {
  const t = raw.trim().replace(/^.*#\/invite\//, '');
  const compact = t.replace(/[\s-]/g, '').toUpperCase();
  return /^[A-Z2-9]{8}$/.test(compact) ? compact : t;
};

export function Login({ misconfigured, setup, onSignedIn }: { misconfigured: boolean; setup: boolean; onSignedIn: () => void }) {
  const [mode, setMode] = useState<'signin' | 'code'>('signin');
  const [code, setCode] = useState('');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  async function submit(e: FormEvent) {
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
      // Anyone can land here, before we know who they are. The fix (scripts/setup-vercel.sh) is in the server logs.
      <Shell eyebrow="Welcome" title="Sign in to healthOS" lede="Sign-in isn't available right now. Please try again later." />
    );
  }

  if (mode === 'code') {
    return (
      <Shell
        eyebrow="Join healthOS"
        title="Join with an invite code"
        lede="Enter the code the admin gave you, like ABCD-EFGH."
        onSubmit={(e) => {
          e.preventDefault();
          const c = cleanCode(code);
          if (c) location.hash = `#/invite/${c}`;
        }}
      >
        <label className="onb-field">
          <span>Invite code</span>
          <input autoFocus autoCapitalize="characters" autoComplete="off" spellCheck={false} value={code} onChange={(e) => setCode(e.target.value)} />
        </label>
        <WelcomeFoot
          start={
            <button type="button" className="onb-back" onClick={() => setMode('signin')}>
              <span aria-hidden="true">←</span> Back to sign-in
            </button>
          }
        >
          <button className="btn btn-primary onb-next" type="submit" disabled={!cleanCode(code)}>
            Continue <Icon name="arrow-up-right" size={14} />
          </button>
        </WelcomeFoot>
      </Shell>
    );
  }

  return (
    <Shell
      eyebrow={setup ? 'Welcome' : 'Welcome back'}
      title={setup ? 'Create your admin account' : 'Sign in to healthOS'}
      lede={setup ? 'First sign-in: enter your email and the password you set with the setup script. This creates your admin account.' : undefined}
      onSubmit={submit}
    >
      <label className="onb-field">
        <span>Email</span>
        <input type="email" autoComplete="username" autoFocus value={email} onChange={(e) => setEmail(e.target.value)} />
      </label>
      <label className="onb-field">
        <span>Password</span>
        <input type="password" autoComplete="current-password" value={password} onChange={(e) => setPassword(e.target.value)} />
      </label>
      <ErrorNote error={error} />
      <WelcomeFoot
        start={
          !setup && (
            <button type="button" className="onb-back" onClick={() => setMode('code')}>
              Have an invite code?
            </button>
          )
        }
      >
        <button className="btn btn-primary onb-next" type="submit" disabled={busy || !email || !password}>
          {busy ? 'Signing in…' : 'Sign in'}
          {!busy && <Icon name="arrow-up-right" size={14} />}
        </button>
      </WelcomeFoot>
      {!setup && <p className="onb-note">Forgot your password? Ask the admin for a reset link.</p>}
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

  async function submit(e: FormEvent) {
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
  const eyebrow = kind === 'invite' ? 'Join healthOS' : 'Reset your password';

  if (check.state === 'checking') {
    return (
      <Shell>
        <p className="onb-lede" role="status">
          Checking your link…
        </p>
      </Shell>
    );
  }
  if (check.state === 'bad') {
    return (
      <Shell eyebrow={eyebrow} title={kind === 'invite' ? 'Create your account' : 'Choose a new password'}>
        <ErrorNote error={check.error} />
        <p className="onb-note">Ask the admin for a new link.</p>
        <WelcomeFoot>
          <button type="button" className="btn btn-primary onb-next" onClick={leave}>
            Go to sign-in
          </button>
        </WelcomeFoot>
      </Shell>
    );
  }

  return (
    <Shell
      eyebrow={eyebrow}
      title={kind === 'invite' ? 'Create your account' : 'Choose a new password'}
      lede={
        kind === 'invite'
          ? `Invite code ${token.length === 8 ? `${token.slice(0, 4)}-${token.slice(4)}` : 'accepted'}. Your full dashboard is private to you. Members who share, the admin included, see your daily tile and your last 30 days of sleep, recovery or HRV, steps, resting heart rate and training load on the Family board; you can turn that off in your Profile.`
          : 'Setting a new password signs you out everywhere else.'
      }
      onSubmit={submit}
    >
      {kind === 'invite' && (
        <div className="onb-fields">
          <label className="onb-field">
            <span>Email</span>
            <input type="email" autoComplete="username" value={email} readOnly={Boolean(check.email)} onChange={(e) => setEmail(e.target.value)} autoFocus={!check.email} />
          </label>
          <label className="onb-field">
            <span>Name</span>
            <input autoComplete="given-name" value={name} maxLength={60} onChange={(e) => setName(e.target.value)} autoFocus={Boolean(check.email)} />
          </label>
        </div>
      )}
      <div className="onb-fields">
        <label className="onb-field">
          <span>Password</span>
          <input type="password" autoComplete="new-password" value={password} onChange={(e) => setPassword(e.target.value)} autoFocus={kind === 'reset'} aria-describedby="pw-hint" />
          <small id="pw-hint" className={tooShort ? 'note-bad' : 'onb-field-hint'}>
            At least {MIN_PASSWORD} characters.
          </small>
        </label>
        <label className="onb-field">
          <span>Confirm password</span>
          <input type="password" autoComplete="new-password" value={confirm} onChange={(e) => setConfirm(e.target.value)} />
          {mismatch && <small className="note-bad">The passwords don't match.</small>}
        </label>
      </div>
      <ErrorNote error={error} />
      <WelcomeFoot start={kind === 'invite' && <span className="onb-hint">Next, three short steps to make this space yours.</span>}>
        <button
          className="btn btn-primary onb-next"
          type="submit"
          disabled={busy || password.length < MIN_PASSWORD || password !== confirm || (kind === 'invite' && !email)}
        >
          {busy ? 'Saving…' : kind === 'invite' ? 'Create account' : 'Set password'}
          {!busy && <Icon name="arrow-up-right" size={14} />}
        </button>
      </WelcomeFoot>
    </Shell>
  );
}
