import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import type { AuthMe, Page, Status, SyncResult } from '../shared/types.ts';
import { Icon } from './components/Icon.tsx';
import { PhotoToneFilters, figureVariant } from './components/Figure.tsx';
import { AppFooter } from './components/shell/AppFooter.tsx';
import { AskPill } from './components/shell/AskPill.tsx';
import { MenuContext } from './components/shell/Menu.tsx';
import { MobileBar, TabBar } from './components/shell/MobileNav.tsx';
import { mainNav } from './components/shell/nav.ts';
import { ShellHeader } from './components/shell/ShellHeader.tsx';
import { Sidebar } from './components/shell/Sidebar.tsx';
import { CardListsContext, UnitsContext, cardListsOf, clearLoadedData, href, notifyDataChanged, sendJson, useAccountLink, useApi, useBackgroundRefresh, useRoute } from './lib.ts';
import { Admin } from './pages/Admin.tsx';
import { Cycle } from './pages/Cycle.tsx';
import { Family } from './pages/Family.tsx';
import { Body } from './pages/Body.tsx';
import { Vitals } from './pages/Detail.tsx';
import { Home } from './pages/Home.tsx';
import { Integrations } from './pages/Integrations.tsx';
import { Journal } from './pages/Journal.tsx';
import { Labs } from './pages/Labs.tsx';
import { McFly } from './pages/McFly.tsx';
import { CommandPalette } from './components/Search.tsx';
import { Nutrition } from './pages/Nutrition.tsx';
import { Onboarding } from './pages/Onboarding.tsx';
import { Profile } from './pages/Profile.tsx';
import { Sleep } from './pages/Sleep.tsx';
import { AccountLinkPage, Login } from './pages/Login.tsx';

/** From an older server without the settings: nothing hidden, nothing optional on. One object, so the context stays stable. */
const NO_CHOICES = { hidden: [], shown: [] };

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
  const { page: route, params } = useRoute();
  // Activity is a tab of Body now, and Settings is Profile; their old addresses still open them.
  const page: Page = route === 'activity' ? 'body' : route === 'settings' ? 'profile' : route;
  const { data: status, error: statusError, reload } = useApi<Status>('/status');
  const [date, setDate] = useState<string | null>(null);
  // Which shell menu is open (the account menu from one of its buttons, or More on a phone): one at a time.
  const [menu, setMenu] = useState<string | null>(null);
  // Only meaningful when sign-in is on; the server enforces it either way.
  const isAdmin = signedIn && status?.user.role === 'admin';
  // The board needs accounts: without sign-in there's only you.
  const family = signedIn && Boolean(status?.settings.familySharing);
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

  // A menu left open doesn't follow you to the next page.
  useEffect(() => setMenu(null), [page]);

  const settings = status?.settings;
  // Until the settings load, no card shows (so a hidden one never flashes up); if they can't load, all do.
  const cards = useMemo(() => (settings ? cardListsOf(settings) : statusError ? NO_CHOICES : null), [settings, statusError]);
  const menus = useMemo(() => ({ open: menu, setOpen: setMenu }), [menu]);
  const nav = mainNav({ family, cycle: Boolean(settings?.cycleTracking) });
  const account = { status, signedIn, isAdmin };

  // Nothing until the status is known: a new account goes straight to onboarding, without the dashboard flashing first.
  if (!status && !statusError) return null;
  // A new account sees onboarding, full screen, until it's done; #/welcome runs it again for anyone.
  const onboarding = status && (settings?.onboarding != null ? 'new' : page === 'welcome' ? 'edit' : null);

  return (
    <UnitsContext.Provider value={settings?.units ?? 'metric'}>
      <CardListsContext.Provider value={cards}>
        <MenuContext.Provider value={menus}>
          {status && onboarding ? (
            <main className="fullscreen">
              <Onboarding status={status} reload={reload} signedIn={signedIn} mode={onboarding} />
            </main>
          ) : (
            <div className="app">
              <Sidebar page={page} nav={nav} account={account} />
              <MobileBar page={page} account={account} />
              <CommandPalette />

              <main className="main">
                <div className="main-inner">
                  <ShellHeader page={page} date={date} setDate={setDate} reload={reload} account={account} />
                  {page === 'home' && status && noSources(status) && (
                    <a className="banner banner-start" href={href('integrations')}>
                      <Icon name="integrations" size={16} /> Your dashboard fills in once you connect WHOOP or the healthOS iPhone app.
                      <Icon name="chevron-right" size={16} />
                    </a>
                  )}
                  {page === 'home' && status && family && !status.settings.familyNoticeSeen && <FamilyNotice refresh={reload} />}
                  <div className="main-page">
                    {page === 'home' && (
                      <Home
                        date={date}
                        onDate={setDate}
                        photo={status?.photo ?? null}
                        nutrition={status?.settings.nutrition ? status.settings.nutritionNumbers : null}
                        perspective={settings?.perspective ?? 'portrait'}
                        figure={figureVariant(settings)}
                      />
                    )}
                    {page === 'family' && (family ? <Family isAdmin={isAdmin} refreshStatus={reload} params={params} /> : status && <FamilyOff signedIn={signedIn} />)}
                    {page === 'vitals' && <Vitals />}
                    {page === 'sleep' && <Sleep params={params} photo={status?.photo ?? null} date={date} setDate={setDate} />}
                    {page === 'body' && (
                      <Body params={route === 'activity' ? new URLSearchParams('tab=activity') : params} stepGoal={status?.settings.stepGoal ?? 10_000} date={date} setDate={setDate} />
                    )}
                    {page === 'nutrition' && status && <Nutrition status={status} params={params} refresh={reload} />}
                    {page === 'journal' && status && <Journal status={status} />}
                    {page === 'labs' && status && <Labs status={status} params={params} />}
                    {page === 'cycle' && status && <Cycle status={status} />}
                    {page === 'mcfly' && status && <McFly key={status.user.id} me={status.user} />}
                    {page === 'integrations' && status && <Integrations status={status} params={params} refresh={reload} signedIn={signedIn} />}
                    {page === 'profile' && status && <Profile key={status.settings.name} status={status} refresh={reload} signedIn={signedIn} />}
                    {page === 'admin' && (isAdmin ? <Admin me={status!.user} /> : status && <NotAllowed />)}
                  </div>
                  <AppFooter home={page === 'home'} />
                </div>
              </main>

              {page === 'home' && <AskPill />}
              <TabBar page={page} nav={nav} />
              {/* The avatar's photo takes the same tone as the figure's, on every page. */}
              <PhotoToneFilters />
            </div>
          )}
        </MenuContext.Provider>
      </CardListsContext.Provider>
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

/** Once, for everyone: sharing is on by default, so say so where people will see it. */
function FamilyNotice({ refresh }: { refresh: () => void }) {
  const dismiss = () => sendJson('PUT', '/settings', { familyNoticeSeen: true }).then(refresh);
  return (
    <div className="banner banner-start family-notice">
      <Icon name="family" size={16} />
      <span>
        Your family can see your daily status and your last 30 days on the <a href={href('family')}>Family</a> board. Change this in <a href={href('profile')}>your Profile</a>.
      </span>
      <button className="btn btn-quiet" onClick={dismiss}>
        Got it
      </button>
    </div>
  );
}

function FamilyOff({ signedIn }: { signedIn: boolean }) {
  return (
    <div className="page">
      <section className="card">
        <h2>Family</h2>
        <p className="muted">
          {signedIn ? (
            <>
              Family is off: you don't see anyone, and nobody sees you. Turn on <a href={href('profile')}>Share with family</a> in your Profile.
            </>
          ) : (
            'The Family board needs sign-in, so each person has their own account.'
          )}
        </p>
      </section>
    </div>
  );
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
