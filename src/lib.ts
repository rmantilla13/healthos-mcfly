import { createContext, useCallback, useContext, useEffect, useState } from 'react';
import type { Page, Units } from '../shared/types.ts';

// ---------- API ----------

const WRITE_HEADERS = { 'X-HealthOS': '1', 'Content-Type': 'application/json' };

async function parse<T>(res: Response): Promise<T> {
  if (res.status === 401) window.dispatchEvent(new Event('healthos:signin'));
  if (!res.ok) {
    const body = (await res.json().catch(() => null)) as { error?: string } | null;
    // A reply without our { error } (a proxy or platform error page) gets plain words, not "Bad Gateway".
    throw new Error(body?.error ?? 'Something went wrong. Try again in a moment.');
  }
  return (await res.json()) as T;
}

/** fetch, with a network failure ("Failed to fetch", "Load failed") put in plain words. */
const request = (path: string, init?: RequestInit) =>
  fetch(`/api${path}`, init).catch(() => {
    throw new Error("Couldn't reach healthOS. Check your connection and try again.");
  });

export const getJson = <T,>(path: string) => request(path).then((r) => parse<T>(r));

export const sendJson = <T,>(method: 'POST' | 'PUT' | 'PATCH' | 'DELETE', path: string, body?: unknown) =>
  request(path, { method, headers: WRITE_HEADERS, body: body === undefined ? undefined : JSON.stringify(body) }).then((r) => parse<T>(r));

export function uploadFile(file: File, onProgress: (sent: number, total: number) => void): Promise<void> {
  return new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    xhr.open('POST', '/api/apple/upload');
    xhr.setRequestHeader('X-HealthOS', '1');
    xhr.setRequestHeader('Content-Type', 'application/octet-stream');
    xhr.upload.onprogress = (e) => onProgress(e.loaded, e.total);
    xhr.onload = () => (xhr.status < 300 ? resolve() : reject(new Error(JSON.parse(xhr.responseText || '{}').error ?? 'Upload failed')));
    xhr.onerror = () => reject(new Error('Upload failed'));
    xhr.send(file);
  });
}

/** Tell every view to refetch (after an import, sync or settings change). */
export const notifyDataChanged = () => window.dispatchEvent(new Event('healthos:data'));

// ---------- loaded data and background freshness ----------
// Views keep what they've loaded, in memory and keyed by path, so switching pages shows it at once without
// a download. A light check of GET /api/version (every minute while the tab is visible, and when it comes
// back into view) tells every view to refetch only when this person's data actually changed.

type Cached = { data: unknown; version: string | null | undefined; at: number; day: string };
const cache = new Map<string, Cached>();
/** The last /api/version seen; undefined until the first check (or on a server without it). */
let dataVersion: string | null | undefined;
/** Loaded data is reused for at most this long, even when nothing changed. */
const MAX_AGE_MS = 5 * 60_000;
const localDay = () => new Date().toLocaleDateString('en-CA');

/** Forget everything loaded (signing out, or another person signing in on this tab). */
export function clearLoadedData() {
  cache.clear();
  dataVersion = undefined;
}

const fresh = (c: Cached) => c.version !== undefined && c.version === dataVersion && Date.now() - c.at < MAX_AGE_MS && c.day === localDay();

/**
 * Keeps the dashboard current in the background: checks the data version every minute while the tab is
 * visible and whenever it's shown again, and refetches every view when the version moves or the day rolls
 * over. Each check is one tiny request; nothing is re-downloaded unless something changed.
 */
export function useBackgroundRefresh() {
  useEffect(() => {
    let day = localDay();
    const check = async () => {
      if (document.visibilityState !== 'visible') return;
      if (localDay() !== day) {
        day = localDay();
        notifyDataChanged();
      }
      try {
        const res = await fetch('/api/version');
        if (res.status === 401) return void window.dispatchEvent(new Event('healthos:signin'));
        if (!res.ok) return; // An older server: views fetch when they open, as before.
        const { version } = (await res.json()) as { version: string | null };
        if (dataVersion === undefined) {
          // First check: what's on screen was loaded moments ago, so it counts as this version.
          dataVersion = version;
          for (const c of cache.values()) if (c.version === undefined) c.version = version;
        } else if (version !== dataVersion) {
          dataVersion = version;
          notifyDataChanged();
        }
      } catch {
        // Offline: try again at the next check.
      }
    };
    check();
    const timer = setInterval(check, 60_000);
    const onShow = () => void check();
    document.addEventListener('visibilitychange', onShow);
    window.addEventListener('focus', onShow);
    return () => {
      clearInterval(timer);
      document.removeEventListener('visibilitychange', onShow);
      window.removeEventListener('focus', onShow);
    };
  }, []);
}

/**
 * Fetches JSON and keeps the previous result on screen while a new one loads. Opening a view reuses what
 * was loaded for the same path if the data hasn't changed since; a data change or reload() refetches.
 * `current` is true once `data` is this path's as it is now (a fresh copy, or the answer to this path's latest
 * request), and false while it's an older copy kept on screen: for decisions that mustn't be made on stale data.
 */
export function useApi<T>(path: string | null) {
  const [data, setData] = useState<T | undefined>(() => (path ? (cache.get(path)?.data as T | undefined) : undefined));
  const [error, setError] = useState<Error>();
  const [loading, setLoading] = useState(false);
  const [version, setVersion] = useState(0);
  // The path whose data is current; null while a request for it is out.
  const [currentFor, setCurrentFor] = useState<string | null>(() => {
    const hit = path ? cache.get(path) : undefined;
    return hit && fresh(hit) ? path : null;
  });

  useEffect(() => {
    const bump = () => setVersion((v) => v + 1);
    window.addEventListener('healthos:data', bump);
    return () => window.removeEventListener('healthos:data', bump);
  }, []);

  useEffect(() => {
    if (!path) return;
    const hit = cache.get(path);
    if (hit) setData(hit.data as T);
    if (version === 0 && hit && fresh(hit)) {
      setError(undefined);
      setCurrentFor(path);
      // A request for the path before may have been cut off before it cleared this.
      setLoading(false);
      return;
    }
    let alive = true;
    setLoading(true);
    setCurrentFor(null);
    getJson<T>(path)
      .then((d) => {
        cache.set(path, { data: d, version: dataVersion, at: Date.now(), day: localDay() });
        if (alive) {
          setData(d);
          setError(undefined);
          setCurrentFor(path);
        }
      })
      .catch((e: Error) => alive && setError(e))
      .finally(() => alive && setLoading(false));
    return () => {
      alive = false;
    };
  }, [path, version]);

  const reload = useCallback(() => setVersion((v) => v + 1), []);
  return { data, error, loading, reload, current: path !== null && currentFor === path };
}

// ---------- routing ----------

const PAGES: Page[] = ['home', 'family', 'vitals', 'sleep', 'activity', 'body', 'nutrition', 'labs', 'cycle', 'mcfly', 'integrations', 'settings', 'admin'];

function readRoute() {
  const [p, q] = location.hash.replace(/^#\/?/, '').split('?');
  const page = (PAGES.includes(p as Page) ? p : 'home') as Page;
  return { page, params: new URLSearchParams(q ?? '') };
}

export function useRoute() {
  const [route, setRoute] = useState(readRoute);
  useEffect(() => {
    const on = () => setRoute(readRoute());
    window.addEventListener('hashchange', on);
    return () => window.removeEventListener('hashchange', on);
  }, []);
  return route;
}

export const href = (page: Page) => `#/${page === 'home' ? '' : page}`;

/** An invite or password-reset link (#/invite/<token>, #/reset/<token>). The token stays in the fragment,
 * so it never reaches a server log. */
export function readAccountLink(): { kind: 'invite' | 'reset'; token: string } | null {
  const m = /^#\/(invite|reset)\/([A-Za-z0-9_-]{8,})$/.exec(location.hash);
  return m ? { kind: m[1] as 'invite' | 'reset', token: m[2] } : null;
}

export function useAccountLink() {
  const [link, setLink] = useState(readAccountLink);
  useEffect(() => {
    const on = () => setLink(readAccountLink());
    window.addEventListener('hashchange', on);
    return () => window.removeEventListener('hashchange', on);
  }, []);
  return link;
}

export async function copyText(text: string) {
  if (!navigator.clipboard) throw new Error('Copy is unavailable here. Select the text instead.');
  await navigator.clipboard.writeText(text);
}

// ---------- units & formatting ----------

export const UnitsContext = createContext<Units>('metric');
export const useUnits = () => useContext(UnitsContext);

/** The cards this person hid (Settings → Cards; shared/cards.ts); null until their settings have loaded. */
export const HiddenCardsContext = createContext<string[] | null>([]);
/** Whether a card shows: every one does, except those the person hid. None until the settings are known, so a hidden card never flashes up. */
export function useCardShown() {
  const hidden = useContext(HiddenCardsContext);
  return useCallback((id: string) => hidden !== null && !hidden.includes(id), [hidden]);
}
/** The person's settings have loaded, so a card that isn't shown was hidden on purpose. */
export const useCardsKnown = () => useContext(HiddenCardsContext) !== null;

export function fmt(value: number, digits = 0) {
  return value.toLocaleString(undefined, { minimumFractionDigits: digits, maximumFractionDigits: digits });
}

export function compact(value: number) {
  return Math.abs(value) >= 1000 ? `${fmt(value / 1000, value % 1000 === 0 ? 0 : 1)}K` : fmt(value);
}

export const temp = (c: number, u: Units) => (u === 'imperial' ? { value: (c * 9) / 5 + 32, unit: '°F' } : { value: c, unit: '°C' });
export const mass = (kg: number, u: Units) => (u === 'imperial' ? { value: kg / 0.45359237, unit: 'lb' } : { value: kg, unit: 'kg' });
export const distance = (m: number, u: Units) => (u === 'imperial' ? { value: m / 1609.344, unit: 'mi' } : { value: m / 1000, unit: 'km' });

const dateFormats = new Map<string, Intl.DateTimeFormat>();
export function fmtDate(date: string, opts: Intl.DateTimeFormatOptions = { month: 'short', day: 'numeric' }) {
  const key = JSON.stringify(opts);
  let f = dateFormats.get(key);
  if (!f) dateFormats.set(key, (f = new Intl.DateTimeFormat(undefined, { timeZone: 'UTC', ...opts })));
  return f.format(new Date(`${date}T00:00:00Z`));
}

export function daysBetween(a: string, b: string) {
  return Math.round((Date.parse(`${b}T00:00:00Z`) - Date.parse(`${a}T00:00:00Z`)) / 86_400_000);
}

export function relativeDay(date: string, today: string) {
  const d = daysBetween(date, today);
  if (d === 0) return 'Today';
  if (d === 1) return 'Yesterday';
  if (d > 1 && d < 7) return `${d} days ago`;
  return fmtDate(date);
}

export function shiftDate(date: string, days: number) {
  return new Date(Date.parse(`${date}T00:00:00Z`) + days * 86_400_000).toISOString().slice(0, 10);
}

/** Wall-clock time as recorded (the ISO strings carry the wearer's own offset). */
export const clock = (iso: string) => iso.slice(11, 16);
export const minutesOfDay = (iso: string) => Number(iso.slice(11, 13)) * 60 + Number(iso.slice(14, 16));

/** "1h 05m" or "45m": whole minutes first, so 59.6 reads 1h 00m, never 60m or 1h 60m. */
export function duration(minutes: number) {
  const t = Math.round(minutes);
  const h = Math.floor(t / 60);
  const m = t % 60;
  return h ? `${h}h ${String(m).padStart(2, '0')}m` : `${m}m`;
}

export function hoursMinutes(hours: number) {
  return duration(hours * 60);
}
