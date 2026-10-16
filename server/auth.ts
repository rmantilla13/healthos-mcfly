// Single-user sign-in for the hosted dashboard.
// HEALTHOS_PASSWORD_HASH holds an scrypt hash (never the password); SESSION_SECRET signs the session cookie.
// Locally, with neither set, the app stays open as before. On Vercel it refuses everything until both are set.
import { createHash, createHmac, randomBytes, scrypt as scryptCb, timingSafeEqual } from 'node:crypto';
import { promisify } from 'node:util';
import type { NextFunction, Request, Response } from 'express';
import type { Db } from './store.ts';

const scrypt = promisify(scryptCb) as (pw: string, salt: Buffer, len: number, opts: { N: number; r: number; p: number }) => Promise<Buffer>;

const COOKIE = 'hos_session';
const SESSION_DAYS = 30;
const MAX_FAILURES = 8;
const LOCK_MS = 15 * 60_000;

// Compiled in by scripts/build-vercel.mjs, so a local run with pulled Vercel env vars never counts as hosted.
export const onVercel = () => process.env.HEALTHOS_BUILD === 'vercel';
const passwordHash = () => process.env.HEALTHOS_PASSWORD_HASH ?? '';
const sessionSecret = () => process.env.SESSION_SECRET ?? '';

export function authMode(): 'open' | 'required' | 'misconfigured' {
  if (passwordHash() && sessionSecret().length >= 32) return 'required';
  return onVercel() ? 'misconfigured' : 'open';
}

/** Format: scrypt$N$r$p$salt$hash (base64). Made by scripts/hash-password.mjs. */
export async function hashPassword(password: string) {
  const N = 2 ** 15, r = 8, p = 1;
  const salt = randomBytes(16);
  const hash = await scrypt(password, salt, 32, { N, r, p, maxmem: 64 * 1024 * 1024 } as never);
  return ['scrypt', N, r, p, salt.toString('base64'), hash.toString('base64')].join('$');
}

export async function verifyPassword(password: string, stored = passwordHash()) {
  const [kind, N, r, p, salt, expected] = stored.split('$');
  if (kind !== 'scrypt' || !salt || !expected) return false;
  const want = Buffer.from(expected, 'base64');
  const got = await scrypt(password, Buffer.from(salt, 'base64'), want.length, {
    N: Number(N),
    r: Number(r),
    p: Number(p),
    maxmem: 64 * 1024 * 1024,
  } as never);
  return got.length === want.length && timingSafeEqual(got, want);
}

function sign(payload: string) {
  return createHmac('sha256', sessionSecret()).update(payload).digest('base64url');
}

function sessionValid(req: Request) {
  const raw = parseCookies(req.headers.cookie)[COOKIE];
  if (!raw) return false;
  const [v, exp, sig] = raw.split('.');
  if (v !== 'v1' || !exp || !sig) return false;
  const want = Buffer.from(sign(`v1.${exp}`));
  const got = Buffer.from(sig);
  return want.length === got.length && timingSafeEqual(want, got) && Number(exp) > Date.now();
}

function parseCookies(header: string | undefined): Record<string, string> {
  const out: Record<string, string> = {};
  for (const part of (header ?? '').split(';')) {
    const i = part.indexOf('=');
    if (i > 0) out[part.slice(0, i).trim()] = decodeURIComponent(part.slice(i + 1).trim());
  }
  return out;
}

function setCookie(res: Response, value: string, maxAgeSec: number) {
  // Lax, not Strict: the WHOOP OAuth callback is a cross-site redirect back to us and must carry the session.
  const secure = onVercel() || process.env.NODE_ENV === 'production' ? '; Secure' : '';
  res.setHeader('Set-Cookie', `${COOKIE}=${encodeURIComponent(value)}; Path=/; HttpOnly; SameSite=Lax; Max-Age=${maxAgeSec}${secure}`);
}

/**
 * Failed attempts are counted per client address, in the database so the limit holds across serverless
 * instances. Per address, so someone guessing from elsewhere can't lock the owner out.
 */
async function loginGuard(db: Db, req: Request, outcome?: 'fail' | 'ok') {
  const ip = (req.ip ?? req.socket.remoteAddress ?? 'unknown').replace(/^::ffff:/, '');
  const key = `login_guard:${createHash('sha256').update(ip).digest('hex').slice(0, 16)}`;
  const [row] = await db.query<{ value: string }>('SELECT value FROM settings WHERE key = $1', [key]);
  let g = row ? (JSON.parse(row.value) as { fails: number; since: number }) : { fails: 0, since: Date.now() };
  if (Date.now() - g.since > LOCK_MS) g = { fails: 0, since: Date.now() };
  if (outcome === 'fail') {
    g.fails++;
    await db.query('INSERT INTO settings (key, value) VALUES ($1, $2) ON CONFLICT (key) DO UPDATE SET value = excluded.value', [key, JSON.stringify(g)]);
    // Forget other addresses' expired counters.
    await db.query("DELETE FROM settings WHERE key LIKE 'login_guard:%' AND key <> $1 AND (value::json->>'since')::float8 < $2", [key, Date.now() - LOCK_MS]);
  }
  if (outcome === 'ok' && row) await db.query('DELETE FROM settings WHERE key = $1', [key]);
  return { locked: g.fails >= MAX_FAILURES, retryAt: g.since + LOCK_MS };
}

export function authRoutes(getDb: () => Promise<Db>) {
  return {
    async me(req: Request, res: Response) {
      const mode = authMode();
      res.json({ mode, authenticated: mode === 'open' || (mode === 'required' && sessionValid(req)) });
    },
    async login(req: Request, res: Response) {
      if (authMode() !== 'required') return void res.status(400).json({ error: 'Sign-in is not set up on this server.' });
      const db = await getDb();
      const guard = await loginGuard(db, req);
      if (guard.locked) {
        return void res.status(429).json({ error: `Too many attempts. Try again after ${new Date(guard.retryAt).toLocaleTimeString()}.` });
      }
      const password = typeof req.body?.password === 'string' ? req.body.password : '';
      if (!password || !(await verifyPassword(password))) {
        await loginGuard(db, req, 'fail');
        await new Promise((r) => setTimeout(r, 400));
        return void res.status(401).json({ error: 'Wrong password.' });
      }
      await loginGuard(db, req, 'ok');
      const exp = Date.now() + SESSION_DAYS * 86_400_000;
      setCookie(res, `v1.${exp}.${sign(`v1.${exp}`)}`, SESSION_DAYS * 86_400);
      res.json({ ok: true });
    },
    logout(_req: Request, res: Response) {
      setCookie(res, '', 0);
      res.json({ ok: true });
    },
  };
}

/** Gate for /api. `exempt` paths authenticate some other way (bearer token, cron secret) or are the sign-in itself. */
export function requireSession(exempt: (path: string) => boolean) {
  return (req: Request, res: Response, next: NextFunction) => {
    if (exempt(req.path)) return next();
    const mode = authMode();
    if (mode === 'open') return next();
    if (mode === 'misconfigured') {
      return void res.status(503).json({ error: 'Sign-in is not configured. Run scripts/setup-vercel.sh to set the password and secrets.' });
    }
    if (sessionValid(req)) return next();
    res.status(401).json({ error: 'Sign in required', signIn: true });
  };
}

/** Vercel Cron sends `Authorization: Bearer $CRON_SECRET`. */
export function cronAuthorized(req: Request) {
  const secret = process.env.CRON_SECRET ?? '';
  const got = Buffer.from(req.headers.authorization ?? '');
  const want = Buffer.from(`Bearer ${secret}`);
  return secret.length >= 16 && got.length === want.length && timingSafeEqual(got, want);
}
