import { useCallback, useEffect, useRef, useState } from 'react';
import type { AuthMe, Page, Status, SyncResult } from '../shared/types.ts';
import { Icon, type IconName } from './components/Icon.tsx';
import { UnitsContext, clearLoadedData, fmtDate, href, notifyDataChanged, sendJson, useAccountLink, useApi, useBackgroundRefresh, useRoute } from './lib.ts';
import { Admin } from './pages/Admin.tsx';
import { Cycle } from './pages/Cycle.tsx';
import { Activity, Body, Sleep, Vitals } from './pages/Detail.tsx';
import { Home } from './pages/Home.tsx';
import { Integrations, SettingsPage } from './pages/Integrations.tsx';
import { McFly } from './pages/McFly.tsx';
import { AccountLinkPage, Login } from './pages/Login.tsx';

const NAV: { page: Page; label: string; icon: IconName }[] = [
  { page: 'home', label: 'Home', icon: 'home' },
  { page: 'vitals', label: 'Vitals', icon: 'vitals' },
  { page: 'sleep', label: 'Sleep', icon: 'sleep' },
  { page: 'activity', label: 'Activity', icon: 'activity' },
  { page: 'body', label: 'Body', icon: 'body' },
  { page: 'mcfly', label: 'Ask McFly', icon: 'spark' },
];

/** Shown after Body, only to people who turned cycle tracking on. */
const CYCLE_NAV: { page: Page; label: string; icon: IconName } = { page: 'cycle', label: 'Cycle', icon: 'cycle' };

const DATA_NAV: { page: Page; label: string; icon: IconName }[] = [
  { page: 'integrations', label: 'Integrations', icon: 'integrations' },
  { page: 'settings', label: 'Settings', icon: 'settings' },
];

const ADMIN_NAV: { page: Page; label: string; icon: IconName }[] = [{ page: 'admin', label: 'Admin', icon: 'shield' }];

type AuthState = { state: 'checking' } | { state: 'signin' | 'misconfigured'; setup: boolean } | { state: 'open'; signedIn: boolean };

/** The hosted app asks you to sign in first; locally (no sign-in configured) it opens straight away. */
export function App() {
  const [auth, setAuth] = useState<AuthState>({ state: 'checking' });
  const link = useAccountLink();

  const check = useCallback(() => {
    fetch('/api/auth/me')
      .then((r) => r.json() as Promise<AuthMe>)
      .then((me) =>
        setAuth(
          me.mode === 'misconfigured'
            ? { state: 'misconfigured', setup: false }
            : me.authenticated
              ? { state: 'open', signedIn: me.mode === 'required' }
              : { state: 'signin', setup: me.setup },
        ),
      )
      .catch(() => setAuth({ state: 'open', signedIn: false }));
  }, []);

  useEffect(() => {
    // On phones, close the keyboard once a form is sent (tapping elsewhere already does).
    const onSubmit = () => {
      if (matchMedia('(pointer: coarse)').matches) (document.activeElement as HTMLElement | null)?.blur();
    };
    document.addEventListener('submit', onSubmit, true);
    return () => document.removeEventListener('submit', onSubmit, true);
  }, []);

  useEffect(() => {
    check();
    // Any API call that comes back 401 (e.g. the session expired) returns to the sign-in screen.
    const onSignin = () => {
      // Whoever signs in next on this tab mustn't see what was loaded for the last person.
      clearLoadedData();
      setAuth({ state: 'signin', setup: false });
    };
    window.addEventListener('healthos:signin', onSignin);
    return () => window.removeEventListener('healthos:signin', onSignin);
  }, [check]);

  // An invite or reset link opens its own page, signed in or not.
  if (link) {
    return (
      <AccountLinkPage
        key={link.token}
        kind={link.kind}
        token={link.token}
        onDone={() => {
          // Drop the used token from the address bar and history, then load the (now signed-in) dashboard.
          history.replaceState(null, '', location.pathname + location.search);
          window.location.reload();
        }}
      />
    );
  }
  if (auth.state === 'checking') return null;
  if (auth.state !== 'open') return <Login misconfigured={auth.state === 'misconfigured'} setup={auth.setup} onSignedIn={check} />;
  return <Dashboard signedIn={auth.signedIn} />;
}

function Dashboard({ signedIn }: { signedIn: boolean }) {
  const { page, params } = useRoute();
  const { data: status, reload } = useApi<Status>('/status');
  const [date, setDate] = useState<string | null>(null);
  // Only meaningful when sign-in is on; the server enforces it either way.
  const isAdmin = signedIn && status?.user.role === 'admin';
  useAutoSync(status, reload);
  useBackgroundRefresh();

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
            {NAV.flatMap((n) => (n.page === 'body' && status?.settings.cycleTracking ? [n, CYCLE_NAV] : [n])).map((n) => (
              <a key={n.page} href={href(n.page)} className={page === n.page ? 'nav-item is-active' : 'nav-item'} aria-current={page === n.page ? 'page' : undefined}>
                <Icon name={n.icon} />
                <span>{n.label}</span>
              </a>
            ))}
            <div className="nav-section">Data</div>
            {[...DATA_NAV, ...(isAdmin ? ADMIN_NAV : [])].map((n) => (
              <a key={n.page} href={href(n.page)} className={page === n.page ? 'nav-item is-active' : 'nav-item'} aria-current={page === n.page ? 'page' : undefined}>
                <Icon name={n.icon} />
                <span>{n.label}</span>
              </a>
            ))}
          </nav>
          {status && <SourceCard status={status} />}
        </aside>

        <main className="main">
          {page === 'home' && status && noSources(status) && (
            <a className="banner banner-start" href={href('integrations')}>
              <Icon name="integrations" size={16} /> Your dashboard fills in once you connect WHOOP or the healthOS iPhone app.
              <Icon name="chevron-right" size={16} />
            </a>
          )}
          {page === 'home' && <Home date={date} onDate={setDate} photo={status?.photo ?? null} />}
          {page === 'vitals' && <Vitals />}
          {page === 'sleep' && <Sleep />}
          {page === 'activity' && <Activity stepGoal={status?.settings.stepGoal ?? 10_000} />}
          {page === 'body' && <Body />}
          {page === 'cycle' && status && <Cycle status={status} />}
          {page === 'mcfly' && status && <McFly key={status.user.id} me={status.user} />}
          {page === 'integrations' && status && <Integrations status={status} params={params} refresh={reload} signedIn={signedIn} />}
          {page === 'settings' && status && <SettingsPage key={status.settings.name} status={status} refresh={reload} signedIn={signedIn} />}
          {page === 'admin' && (isAdmin ? <Admin me={status!.user} /> : status && <NotAllowed />)}
        </main>
      </div>
    </UnitsContext.Provider>
  );
}

/** How old WHOOP data may get before opening the dashboard syncs it. */
const STALE_MS = 30 * 60_000;

/**
 * Keeps WHOOP fresh without a button press: opening the dashboard syncs it when the last sync is over
 * half an hour old, and while any sync runs (from here, Integrations or the iPhone app) the status is
 * re-read until it finishes, then every view refetches. Apple Health arrives on its own from the iPhone.
 */
function useAutoSync(status: Status | undefined, reload: () => void) {
  const tried = useRef(false);
  const wasSyncing = useRef(false);
  useEffect(() => {
    if (!status || tried.current) return;
    tried.current = true;
    const w = status.whoop;
    const last = w.lastSync ? Date.parse(w.lastSync) : 0;
    if (w.connected && !w.syncing && Date.now() - last > STALE_MS) {
      sendJson<SyncResult>('POST', '/sync')
        .then(reload)
        .catch(() => {});
    }
  }, [status, reload]);
  const syncing = Boolean(status?.whoop.syncing);
  useEffect(() => {
    if (wasSyncing.current && !syncing) notifyDataChanged();
    wasSyncing.current = syncing;
    if (!syncing) return;
    const t = setInterval(reload, 3000);
    return () => clearInterval(t);
  }, [syncing, reload]);
}

const noSources = (s: Status) => !s.demo && !s.apple.lastImport && !s.apple.lastSync && !s.whoop.connected;

function NotAllowed() {
  return (
    <div className="page">
      <section className="card">
        <h2>Admins only</h2>
        <p className="muted">This page is for the people who run this healthOS. Your own data is under Home.</p>
      </section>
    </div>
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
