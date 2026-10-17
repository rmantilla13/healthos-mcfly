import { createContext, useCallback, useContext, useEffect, useState } from 'react';
import type { Page, Units } from '../shared/types.ts';

// ---------- API ----------

const WRITE_HEADERS = { 'X-HealthOS': '1', 'Content-Type': 'application/json' };

async function parse<T>(res: Response): Promise<T> {
  if (res.status === 401) window.dispatchEvent(new Event('healthos:signin'));
  if (!res.ok) {
    const body = (await res.json().catch(() => null)) as { error?: string } | null;
    throw new Error(body?.error ?? res.statusText);
  }
  return (await res.json()) as T;
}

export const getJson = <T,>(path: string) => fetch(`/api${path}`).then((r) => parse<T>(r));

export const sendJson = <T,>(method: 'POST' | 'PUT' | 'PATCH' | 'DELETE', path: string, body?: unknown) =>
  fetch(`/api${path}`, { method, headers: WRITE_HEADERS, body: body === undefined ? undefined : JSON.stringify(body) }).then((r) => parse<T>(r));

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

/** Fetches JSON and keeps the previous result on screen while a new one loads. */
export function useApi<T>(path: string | null) {
  const [data, setData] = useState<T>();
  const [error, setError] = useState<Error>();
  const [loading, setLoading] = useState(false);
  const [version, setVersion] = useState(0);

  useEffect(() => {
    const bump = () => setVersion((v) => v + 1);
    window.addEventListener('healthos:data', bump);
    return () => window.removeEventListener('healthos:data', bump);
  }, []);

  useEffect(() => {
    if (!path) return;
    let alive = true;
    setLoading(true);
    getJson<T>(path)
      .then((d) => alive && (setData(d), setError(undefined)))
      .catch((e: Error) => alive && setError(e))
      .finally(() => alive && setLoading(false));
    return () => {
      alive = false;
    };
  }, [path, version]);

  const reload = useCallback(() => setVersion((v) => v + 1), []);
  return { data, error, loading, reload };
}

// ---------- routing ----------

const PAGES: Page[] = ['home', 'vitals', 'sleep', 'activity', 'body', 'mcfly', 'integrations', 'settings', 'admin'];

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
  const m = /^#\/(invite|reset)\/([A-Za-z0-9_-]{16,})$/.exec(location.hash);
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

export function duration(minutes: number) {
  const h = Math.floor(minutes / 60);
  const m = Math.round(minutes % 60);
  return h ? `${h}h ${String(m).padStart(2, '0')}m` : `${m}m`;
}

export function hoursMinutes(hours: number) {
  return duration(hours * 60);
}
