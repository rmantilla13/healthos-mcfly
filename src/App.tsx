import { useEffect, useState } from 'react';
import type { Page, Status } from '../shared/types.ts';
import { Icon, type IconName } from './components/Icon.tsx';
import { UnitsContext, fmtDate, href, notifyDataChanged, sendJson, useApi, useRoute } from './lib.ts';
import { Activity, Body, Sleep, Vitals } from './pages/Detail.tsx';
import { Home } from './pages/Home.tsx';
import { Integrations, SettingsPage } from './pages/Integrations.tsx';
import { Login } from './pages/Login.tsx';

const NAV: { page: Page; label: string; icon: IconName }[] = [
  { page: 'home', label: 'Home', icon: 'home' },
  { page: 'vitals', label: 'Vitals', icon: 'vitals' },
  { page: 'sleep', label: 'Sleep', icon: 'sleep' },
  { page: 'activity', label: 'Activity', icon: 'activity' },
  { page: 'body', label: 'Body', icon: 'body' },
];

const DATA_NAV: { page: Page; label: string; icon: IconName }[] = [
  { page: 'integrations', label: 'Integrations', icon: 'integrations' },
  { page: 'settings', label: 'Settings', icon: 'settings' },
];

type AuthState = 'checking' | 'open' | 'signin' | 'misconfigured';

/** The hosted app asks for the password first; locally (no password configured) it opens straight away. */
export function App() {
  const [auth, setAuth] = useState<AuthState>('checking');

  useEffect(() => {
    fetch('/api/auth/me')
      .then((r) => r.json() as Promise<{ mode: 'open' | 'required' | 'misconfigured'; authenticated: boolean }>)
      .then((me) => setAuth(me.mode === 'misconfigured' ? 'misconfigured' : me.authenticated ? 'open' : 'signin'))
      .catch(() => setAuth('open'));
    // Any API call that comes back 401 (e.g. the session expired) returns to the sign-in screen.
    const onSignin = () => setAuth('signin');
    window.addEventListener('healthos:signin', onSignin);
    return () => window.removeEventListener('healthos:signin', onSignin);
  }, []);

  if (auth === 'checking') return null;
  if (auth !== 'open') return <Login misconfigured={auth === 'misconfigured'} onSignedIn={() => setAuth('open')} />;
  return <Dashboard />;
}

function Dashboard() {
  const { page, params } = useRoute();
  const { data: status, reload } = useApi<Status>('/status');
  const [date, setDate] = useState<string | null>(null);

  // The hosted server runs in UTC; tell it this browser's time zone so "today" is your today.
  useEffect(() => {
    if (!status) return;
    const tz = Intl.DateTimeFormat().resolvedOptions().timeZone;
    if (tz && status.settings.timeZone !== tz) {
      sendJson('PUT', '/settings', { timeZone: tz }).then(() => {
        reload();
        notifyDataChanged();
      });
    }
  }, [status, reload]);

  return (
    <UnitsContext.Provider value={status?.settings.units ?? 'metric'}>
      <div className="app">
        <aside className="sidebar">
          <a className="brand" href={href('home')}>
            <Logo />
            <span>healthOS</span>
          </a>
          <nav aria-label="Main">
            {NAV.map((n) => (
              <a key={n.page} href={href(n.page)} className={page === n.page ? 'nav-item is-active' : 'nav-item'} aria-current={page === n.page ? 'page' : undefined}>
                <Icon name={n.icon} />
                <span>{n.label}</span>
              </a>
            ))}
            <div className="nav-section">Data</div>
            {DATA_NAV.map((n) => (
              <a key={n.page} href={href(n.page)} className={page === n.page ? 'nav-item is-active' : 'nav-item'} aria-current={page === n.page ? 'page' : undefined}>
                <Icon name={n.icon} />
                <span>{n.label}</span>
              </a>
            ))}
          </nav>
          {status && <SourceCard status={status} />}
        </aside>

        <main className="main">
          {page === 'home' && <Home date={date} onDate={setDate} photo={status?.photo ?? null} />}
          {page === 'vitals' && <Vitals />}
          {page === 'sleep' && <Sleep />}
          {page === 'activity' && <Activity stepGoal={status?.settings.stepGoal ?? 10_000} />}
          {page === 'body' && <Body />}
          {page === 'integrations' && status && <Integrations status={status} params={params} refresh={reload} />}
          {page === 'settings' && status && <SettingsPage key={status.settings.name} status={status} refresh={reload} />}
        </main>
      </div>
    </UnitsContext.Provider>
  );
}

function SourceCard({ status }: { status: Status }) {
  const apple = status.apple.lastImport;
  const synced = status.apple.lastSync && new Date(status.apple.lastSync.syncedAt).toLocaleDateString('en-CA');
  return (
    <a className="source-card" href={href('integrations')}>
      {status.demo ? (
        <>
          <span className="source-title">Showing demo data</span>
          <span className="muted small">Connect Apple Health or WHOOP</span>
        </>
      ) : (
        <>
          <span className="source-row">
            <i className={apple || synced ? 'on' : ''} /> Apple Health
            <small>{synced ? fmtDate(synced) : apple?.lastDate ? fmtDate(apple.lastDate) : 'off'}</small>
          </span>
          <span className="source-row">
            <i className={status.whoop.connected ? 'on' : ''} /> WHOOP
            <small>{status.whoop.connected ? (status.whoop.syncing ? 'syncing' : 'on') : 'off'}</small>
          </span>
        </>
      )}
      <Icon name="chevron-right" size={16} />
    </a>
  );
}

function Logo() {
  return (
    <svg width="30" height="30" viewBox="0 0 32 32" aria-hidden="true" className="logo">
      <g fill="none" stroke="currentColor" strokeWidth="1.1" strokeLinecap="round">
        {Array.from({ length: 24 }, (_, i) => {
          const a = (i / 24) * Math.PI * 2;
          const r1 = 5 + (i % 2) * 1.5;
          const r2 = 13 - (i % 3);
          return <line key={i} x1={16 + r1 * Math.cos(a)} y1={16 + r1 * Math.sin(a)} x2={16 + r2 * Math.cos(a)} y2={16 + r2 * Math.sin(a)} />;
        })}
      </g>
      <circle cx="16" cy="16" r="2.4" fill="currentColor" />
    </svg>
  );
}
