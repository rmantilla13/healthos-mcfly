// Accounts and sign-in. Invite-only: an admin creates single-use invite links; there's no open sign-up.
//
// - Passwords: scrypt hashes, per user.
// - Sessions: a signed cookie `v2.<userId>.<sessionVersion>.<expires>.<sig>`. Every request reloads the
//   user, so disabling an account or resetting its password (both bump session_version) ends its sessions.
// - Roles come from the database on each request, never from the cookie.
// - Owner setup: before any account exists, the first sign-in with the original HEALTHOS_PASSWORD_HASH
//   password creates the admin account (id "owner", which already owns all pre-multi-user data).
// - Locally with no SESSION_SECRET the app stays open as the owner, as before.
import { createHash, createHmac, randomBytes, randomUUID, scrypt as scryptCb, timingSafeEqual } from 'node:crypto';
import { promisify } from 'node:util';
import type { NextFunction, Request, Response } from 'express';
import { OWNER_ID, type Db, type Queryable } from './db.ts';

const scrypt = promisify(scryptCb) as (pw: string, salt: Buffer, len: number, opts: object) => Promise<Buffer>;

const COOKIE = 'hos_session';
const SESSION_DAYS = 30;
const MAX_FAILURES = 8;
const LOCK_MS = 15 * 60_000;
export const MIN_PASSWORD = 10;

// Compiled in by scripts/build-vercel.mjs, so a local run with pulled Vercel env vars never counts as hosted.
export const onVercel = () => process.env.HEALTHOS_BUILD === 'vercel';
const sessionSecret = () => process.env.SESSION_SECRET ?? '';
const ownerSetupHash = () => process.env.HEALTHOS_PASSWORD_HASH ?? '';

export type Role = 'admin' | 'user';
export type User = { id: string; email: string; name: string; role: Role; status: 'active' | 'disabled'; session_version: number };

/** The signed-in person for this request (set by requireSession). */
export const currentUser = (res: Response) => res.locals.user as User;

/** Local, no secret configured: open, acting as the owner (single-person local use, as before). */
const LOCAL_OWNER: User = { id: OWNER_ID, email: '', name: '', role: 'admin', status: 'active', session_version: 1 };

export function authMode(): 'open' | 'required' | 'misconfigured' {
  if (sessionSecret().length >= 32) return 'required';
  return onVercel() ? 'misconfigured' : 'open';
}

// ---------- passwords ----------

/** Format: scrypt$N$r$p$salt$hash (base64). The same format scripts/hash-password.mjs produces. */
export async function hashPassword(password: string) {
  const N = 2 ** 15, r = 8, p = 1;
  const salt = randomBytes(16);
  const hash = await scrypt(password, salt, 32, { N, r, p, maxmem: 64 * 1024 * 1024 });
  return ['scrypt', N, r, p, salt.toString('base64'), hash.toString('base64')].join('$');
}

export async function verifyPassword(password: string, stored: string) {
  const [kind, N, r, p, salt, expected] = stored.split('$');
  if (kind !== 'scrypt' || !salt || !expected) return false;
  const want = Buffer.from(expected, 'base64');
  const got = await scrypt(password, Buffer.from(salt, 'base64'), want.length, { N: Number(N), r: Number(r), p: Number(p), maxmem: 64 * 1024 * 1024 });
  return got.length === want.length && timingSafeEqual(got, want);
}

export const normalizeEmail = (e: unknown) => (typeof e === 'string' ? e.trim().toLowerCase() : '');
const validEmail = (e: string) => /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(e) && e.length <= 254;
export const sha256 = (s: string) => createHash('sha256').update(s).digest('hex');

// ---------- users ----------

const USER_COLS = 'id, email, name, role, status, session_version';

export async function getUser(q: Queryable, id: string): Promise<User | null> {
  const [u] = await q.query<User>(`SELECT ${USER_COLS} FROM users WHERE id = $1`, [id]);
  return u ? { ...u, session_version: Number(u.session_version) } : null;
}

export async function countUsers(q: Queryable) {
  const [r] = await q.query<{ n: number }>('SELECT COUNT(*)::int AS n FROM users');
  return Number(r.n);
}

export async function countActiveAdmins(q: Queryable) {
  const [r] = await q.query<{ n: number }>("SELECT COUNT(*)::int AS n FROM users WHERE role = 'admin' AND status = 'active'");
  return Number(r.n);
}

// ---------- sessions ----------

function sign(payload: string) {
  return createHmac('sha256', sessionSecret()).update(payload).digest('base64url');
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

export function startSession(res: Response, user: Pick<User, 'id' | 'session_version'>) {
  const exp = Date.now() + SESSION_DAYS * 86_400_000;
  const payload = `v2.${user.id}.${user.session_version}.${exp}`;
  setCookie(res, `${payload}.${sign(payload)}`, SESSION_DAYS * 86_400);
}

/** The user a valid session cookie names, or null. Checks signature, expiry, account status and session version. */
async function sessionUser(q: Queryable, req: Request): Promise<User | null> {
  const raw = parseCookies(req.headers.cookie)[COOKIE];
  if (!raw) return null;
  const parts = raw.split('.');
  if (parts.length !== 5 || parts[0] !== 'v2') return null;
  const [, id, sv, exp, sig] = parts;
  const want = Buffer.from(sign(`v2.${id}.${sv}.${exp}`));
  const got = Buffer.from(sig);
  if (want.length !== got.length || !timingSafeEqual(want, got) || Number(exp) <= Date.now()) return null;
  const user = await getUser(q, id);
  if (!user || user.status !== 'active' || user.session_version !== Number(sv)) return null;
  return user;
}

// ---------- rate limiting ----------

/**
 * Failed attempts are counted per client address, in the database so the limit holds across serverless
 * instances. Per address, so someone guessing from elsewhere can't lock the owner out.
 */
async function guard(db: Db, req: Request, outcome?: 'fail' | 'ok') {
  const ip = (req.ip ?? req.socket.remoteAddress ?? 'unknown').replace(/^::ffff:/, '');
  const key = `login_guard:${sha256(ip).slice(0, 16)}`;
  const [row] = await db.query<{ value: string }>('SELECT value FROM settings WHERE key = $1', [key]);
  let g = row ? (JSON.parse(row.value) as { fails: number; since: number }) : { fails: 0, since: Date.now() };
  if (Date.now() - g.since > LOCK_MS) g = { fails: 0, since: Date.now() };
  if (outcome === 'fail') {
    g.fails++;
    await db.query('INSERT INTO settings (key, value) VALUES ($1, $2) ON CONFLICT (key) DO UPDATE SET value = excluded.value', [key, JSON.stringify(g)]);
    await db.query("DELETE FROM settings WHERE key LIKE 'login_guard:%' AND key <> $1 AND (value::json->>'since')::float8 < $2", [key, Date.now() - LOCK_MS]);
  }
  if (outcome === 'ok' && row) await db.query('DELETE FROM settings WHERE key = $1', [key]);
  return { locked: g.fails >= MAX_FAILURES, retryAt: g.since + LOCK_MS };
}

const slowDown = () => new Promise((r) => setTimeout(r, 400));

// ---------- invite and reset links ----------
// One mechanism for both. Only a hash of the token is stored; the link carries it in the URL fragment
// (#/invite/… or #/reset/…), which browsers never send to a server, so it can't end up in logs.

export async function createLink(
  q: Queryable,
  opts: { kind: 'invite' | 'reset'; createdBy: string; email?: string; role?: Role; userId?: string; days: number },
) {
  const token = randomBytes(24).toString('base64url');
  const id = randomUUID();
  await q.query(
    `INSERT INTO invites (id, kind, token_hash, email, role, user_id, created_by, created_at, expires_at)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)`,
    [id, opts.kind, sha256(token), normalizeEmail(opts.email) || null, opts.role ?? 'user', opts.userId ?? null, opts.createdBy, Date.now(), Date.now() + opts.days * 86_400_000],
  );
  return { id, token };
}

type LinkRow = { id: string; kind: 'invite' | 'reset'; email: string | null; role: Role; user_id: string | null };

/** Use a link up atomically: two requests racing with the same token can't both succeed. */
async function consumeLink(q: Queryable, token: string, kind: 'invite' | 'reset', usedBy: string) {
  const [row] = await q.query<LinkRow>(
    `UPDATE invites SET used_at = $1, used_by = $2
     WHERE token_hash = $3 AND kind = $4 AND used_at IS NULL AND revoked_at IS NULL AND expires_at > $1
     RETURNING id, kind, email, role, user_id`,
    [Date.now(), usedBy, sha256(token), kind],
  );
  return row ?? null;
}

async function peekLink(q: Queryable, token: string) {
  const [row] = await q.query<LinkRow>(
    'SELECT id, kind, email, role, user_id FROM invites WHERE token_hash = $1 AND used_at IS NULL AND revoked_at IS NULL AND expires_at > $2',
    [sha256(token), Date.now()],
  );
  return row ?? null;
}

// ---------- routes ----------

class HttpError extends Error {
  status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

function checkPassword(password: unknown): string {
  if (typeof password !== 'string' || password.length < MIN_PASSWORD) throw new HttpError(400, `Use a password of at least ${MIN_PASSWORD} characters.`);
  if (password.length > 200) throw new HttpError(400, 'That password is too long.');
  return password;
}

export function authRoutes(db: Db) {
  const handle =
    (fn: (req: Request, res: Response) => Promise<void>) =>
    async (req: Request, res: Response, next: NextFunction) => {
      try {
        await fn(req, res);
      } catch (err) {
        if (err instanceof HttpError) res.status(err.status).json({ error: err.message });
        else next(err);
      }
    };

  /** Rate-limited endpoints count failures per address and refuse while locked. */
  const limited =
    (fn: (req: Request, res: Response) => Promise<boolean>) =>
    handle(async (req, res) => {
      const g = await guard(db, req);
      if (g.locked) throw new HttpError(429, `Too many attempts. Try again after ${new Date(g.retryAt).toLocaleTimeString()}.`);
      const ok = await fn(req, res);
      await guard(db, req, ok ? 'ok' : 'fail');
      if (!ok) await slowDown();
    });

  return {
    me: handle(async (req, res) => {
      const mode = authMode();
      if (mode !== 'required') return void res.json({ mode, authenticated: mode === 'open', setup: false, user: mode === 'open' ? publicUser(LOCAL_OWNER) : null });
      const user = await sessionUser(db, req);
      const setup = (await countUsers(db)) === 0 && Boolean(ownerSetupHash());
      res.json({ mode, authenticated: Boolean(user), setup, user: user ? publicUser(user) : null });
    }),

    login: limited(async (req, res) => {
      if (authMode() !== 'required') throw new HttpError(400, 'Sign-in is not set up on this server.');
      const email = normalizeEmail(req.body?.email);
      const password = typeof req.body?.password === 'string' ? req.body.password : '';
      if (!email || !password) throw new HttpError(400, 'Enter your email and password.');

      // First sign-in on a fresh multi-user database: the original password creates the admin account.
      if ((await countUsers(db)) === 0) {
        if (!ownerSetupHash() || !(await verifyPassword(password, ownerSetupHash()))) {
          res.status(401).json({ error: 'Wrong email or password.' });
          return false;
        }
        if (!validEmail(email)) throw new HttpError(400, 'Enter a valid email address.');
        await db.query(
          // Keep the name the owner already set in Settings (single-user healthOS stored it there).
          `INSERT INTO users (id, email, name, password_hash, role, created_at, last_login_at)
           VALUES ($1, $2, COALESCE((SELECT value FROM user_settings WHERE user_id = $1 AND key = 'name'), ''), $3, 'admin', $4, $4)
           ON CONFLICT (id) DO NOTHING`,
          [OWNER_ID, email, ownerSetupHash(), Date.now()],
        );
        startSession(res, { id: OWNER_ID, session_version: 1 });
        res.json({ ok: true, created: 'owner' });
        return true;
      }

      const [row] = await db.query<User & { password_hash: string }>(`SELECT ${USER_COLS}, password_hash FROM users WHERE email = $1`, [email]);
      if (!row || row.status !== 'active' || !(await verifyPassword(password, row.password_hash))) {
        res.status(401).json({ error: 'Wrong email or password.' });
        return false;
      }
      await db.query('UPDATE users SET last_login_at = $1 WHERE id = $2', [Date.now(), row.id]);
      startSession(res, { id: row.id, session_version: Number(row.session_version) });
      res.json({ ok: true });
      return true;
    }),

    logout: handle(async (_req, res) => {
      setCookie(res, '', 0);
      res.json({ ok: true });
    }),

    /** What a link is for, so the page can show the right form (and a locked email). */
    checkLink: limited(async (req, res) => {
      const link = typeof req.body?.token === 'string' ? await peekLink(db, req.body.token) : null;
      if (!link) {
        res.status(404).json({ error: 'This link is invalid, expired or already used.' });
        return false;
      }
      res.json({ kind: link.kind, email: link.email });
      return true;
    }),

    acceptInvite: limited(async (req, res) => {
      if (authMode() !== 'required') throw new HttpError(400, 'Sign-in is not set up on this server.');
      const [reg] = await db.query<{ value: string }>("SELECT value FROM settings WHERE key = 'registration'");
      if (reg?.value === 'closed') throw new HttpError(403, 'New accounts are closed right now. Ask the admin.');
      const token = typeof req.body?.token === 'string' ? req.body.token : '';
      const email = normalizeEmail(req.body?.email);
      const name = typeof req.body?.name === 'string' ? req.body.name.trim().slice(0, 60) : '';
      const password = checkPassword(req.body?.password);
      if (!validEmail(email)) throw new HttpError(400, 'Enter a valid email address.');
      const id = randomUUID();
      const hash = await hashPassword(password);
      const created = await db.tx(async (q) => {
        const link = await consumeLink(q, token, 'invite', id);
        if (!link) throw new HttpError(404, 'This invite is invalid, expired or already used.');
        if (link.email && link.email !== email) throw new HttpError(400, `This invite is for ${link.email}.`);
        const [taken] = await q.query('SELECT 1 FROM users WHERE email = $1', [email]);
        if (taken) throw new HttpError(409, 'An account with that email already exists. Sign in instead.');
        await q.query(
          `INSERT INTO users (id, email, name, password_hash, role, created_at, last_login_at) VALUES ($1, $2, $3, $4, $5, $6, $6)`,
          [id, email, name, hash, link.role, Date.now()],
        );
        // The dashboard reads the name from the person's settings, like everything else they can edit.
        if (name) await q.query("INSERT INTO user_settings (user_id, key, value) VALUES ($1, 'name', $2)", [id, name]);
        return true;
      }).catch((err) => {
        if (err instanceof HttpError && err.status === 404) return false;
        throw err;
      });
      if (!created) {
        res.status(404).json({ error: 'This invite is invalid, expired or already used.' });
        return false;
      }
      startSession(res, { id, session_version: 1 });
      res.json({ ok: true });
      return true;
    }),

    resetPassword: limited(async (req, res) => {
      if (authMode() !== 'required') throw new HttpError(400, 'Sign-in is not set up on this server.');
      const token = typeof req.body?.token === 'string' ? req.body.token : '';
      const hash = await hashPassword(checkPassword(req.body?.password));
      const user = await db.tx(async (q) => {
        const link = await consumeLink(q, token, 'reset', 'self');
        if (!link?.user_id) return null;
        const [u] = await q.query<{ id: string; session_version: number }>(
          "UPDATE users SET password_hash = $1, session_version = session_version + 1 WHERE id = $2 AND status = 'active' RETURNING id, session_version",
          [hash, link.user_id],
        );
        return u ?? null;
      });
      if (!user) {
        res.status(404).json({ error: 'This reset link is invalid, expired or already used.' });
        return false;
      }
      startSession(res, { id: user.id, session_version: Number(user.session_version) });
      res.json({ ok: true });
      return true;
    }),

    /** A signed-in person changes their own password; other sessions end, this one continues. */
    changePassword: handle(async (req, res) => {
      const user = currentUser(res);
      if (authMode() !== 'required') throw new HttpError(400, 'Sign-in is not set up on this server.');
      const next = checkPassword(req.body?.next);
      const [row] = await db.query<{ password_hash: string }>('SELECT password_hash FROM users WHERE id = $1', [user.id]);
      if (!row || !(await verifyPassword(String(req.body?.current ?? ''), row.password_hash))) throw new HttpError(403, 'Your current password is wrong.');
      const [u] = await db.query<{ session_version: number }>(
        'UPDATE users SET password_hash = $1, session_version = session_version + 1 WHERE id = $2 RETURNING session_version',
        [await hashPassword(next), user.id],
      );
      startSession(res, { id: user.id, session_version: Number(u.session_version) });
      res.json({ ok: true });
    }),
  };
}

export function publicUser(u: User) {
  return { id: u.id, email: u.email, name: u.name, role: u.role };
}

/** Gate for the API: sets res.locals.user, or answers 401/503. */
export function requireSession(db: Db) {
  return async (req: Request, res: Response, next: NextFunction) => {
    try {
      const mode = authMode();
      if (mode === 'open') {
        res.locals.user = LOCAL_OWNER;
        return next();
      }
      if (mode === 'misconfigured') {
        return void res.status(503).json({ error: 'Sign-in is not configured. Run scripts/setup-vercel.sh to set the secrets.' });
      }
      const user = await sessionUser(db, req);
      if (!user) return void res.status(401).json({ error: 'Sign in required', signIn: true });
      res.locals.user = user;
      next();
    } catch (err) {
      next(err);
    }
  };
}

export function requireAdmin(_req: Request, res: Response, next: NextFunction) {
  if (currentUser(res)?.role !== 'admin') return void res.status(403).json({ error: 'Admins only' });
  next();
}

/** Vercel Cron sends `Authorization: Bearer $CRON_SECRET`. */
export function cronAuthorized(req: Request) {
  const secret = process.env.CRON_SECRET ?? '';
  const got = Buffer.from(req.headers.authorization ?? '');
  const want = Buffer.from(`Bearer ${secret}`);
  return secret.length >= 16 && got.length === want.length && timingSafeEqual(got, want);
}

export { HttpError };
