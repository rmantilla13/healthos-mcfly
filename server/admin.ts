// Admin API (/api/admin/*). Admins manage accounts, invites and platform settings, and see each
// account's data volume and sync health, but never anyone's health values.
import express, { type NextFunction, type Request, type Response } from 'express';
import { HttpError, type Role, countActiveAdmins, createLink, currentUser, getUser, normalizeEmail, requireAdmin } from './auth.ts';
import { type Db, deleteUserData, getSettings, setSetting } from './db.ts';
import * as whoop from './whoop.ts';

const ROLES: Role[] = ['admin', 'user'];

/** Platform settings an admin can change, with their defaults. */
export const PLATFORM_DEFAULTS = {
  registration: 'invite', // 'invite' (invite links work) | 'closed' (no new accounts, even with a link)
  default_units: 'metric',
  default_step_goal: '10000',
  invite_days: '7',
  mcfly_model: 'claude-opus-5-5',
  mcfly_daily_limit: '50',
} as const;

export async function platformSettings(db: Db) {
  const saved = await getSettings(db);
  const out: Record<string, string> = {};
  for (const [k, v] of Object.entries(PLATFORM_DEFAULTS)) out[k] = saved.get(k) ?? v;
  return out;
}

/** The public origin, for building invite and reset links (behind Vercel's proxy, Host is the real domain). */
const origin = (req: Request) => `${req.protocol}://${req.get('host')}`;

export function adminRouter(db: Db) {
  const router = express.Router();
  router.use(requireAdmin);
  const h =
    (fn: (req: Request, res: Response) => Promise<void>) =>
    async (req: Request, res: Response, next: NextFunction) => {
      try {
        await fn(req, res);
      } catch (err) {
        if (err instanceof HttpError) res.status(err.status).json({ error: err.message });
        else next(err);
      }
    };

  router.get(
    '/overview',
    h(async (_req, res) => {
      // McFly use over the last 30 days: counts and tokens only, never the questions.
      const since = new Date(Date.now() - 30 * 86_400_000).toISOString().slice(0, 10);
      const [users, volume, settingsRows, whoopRows, invites, platform, mcflyRows] = await Promise.all([
        db.query<{ id: string; email: string; name: string; role: Role; status: string; created_at: number; last_login_at: number | null; has_ingest_token: boolean }>(
          `SELECT u.id, u.email, COALESCE(NULLIF(u.name, ''), n.value, '') AS name, u.role, u.status, u.created_at, u.last_login_at,
                  u.ingest_token_hash IS NOT NULL AS has_ingest_token
           FROM users u LEFT JOIN user_settings n ON n.user_id = u.id AND n.key = 'name' ORDER BY u.created_at`,
        ),
        db.query<{ user_id: string; rows: number; days: number; first: string | null; last: string | null }>(
          "SELECT user_id, COUNT(*)::int AS rows, COUNT(DISTINCT date)::int AS days, MIN(date) AS first, MAX(date) AS last FROM daily WHERE source <> 'demo' GROUP BY user_id",
        ),
        db.query<{ user_id: string; key: string; value: string }>(
          "SELECT user_id, key, value FROM user_settings WHERE key IN ('apple_last_import', 'apple_last_sync', 'whoop_last_sync', 'whoop_sync', 'photo_meta')",
        ),
        db.query<{ user_id: string }>("SELECT user_id FROM tokens WHERE provider = 'whoop'"),
        db.query<{ id: string; kind: string; email: string | null; role: Role; user_id: string | null; created_at: number; expires_at: number; used_at: number | null; used_by: string | null; revoked_at: number | null }>(
          'SELECT id, kind, email, role, user_id, created_at, expires_at, used_at, used_by, revoked_at FROM invites ORDER BY created_at DESC LIMIT 100',
        ),
        platformSettings(db),
        db.query<{ user_id: string; questions: number; tokens: number }>(
          'SELECT user_id, SUM(questions)::int AS questions, SUM(input_tokens + output_tokens)::float8 AS tokens FROM mcfly_usage WHERE day >= $1 GROUP BY user_id',
          [since],
        ),
      ]);
      const mcfly = new Map(mcflyRows.map((r) => [r.user_id, r]));
      const vol = new Map(volume.map((v) => [v.user_id, v]));
      const setting = (uid: string, key: string) => settingsRows.find((r) => r.user_id === uid && r.key === key)?.value;
      const parse = (v: string | undefined) => (v ? (JSON.parse(v) as Record<string, unknown>) : null);
      const connected = new Set(whoopRows.map((r) => r.user_id));
      res.json({
        users: users.map((u) => {
          const sync = parse(setting(u.id, 'whoop_sync'));
          return {
            id: u.id,
            email: u.email,
            name: u.name,
            role: u.role,
            status: u.status,
            createdAt: Number(u.created_at),
            lastLoginAt: u.last_login_at === null ? null : Number(u.last_login_at),
            data: { rows: vol.get(u.id)?.rows ?? 0, days: vol.get(u.id)?.days ?? 0, first: vol.get(u.id)?.first ?? null, last: vol.get(u.id)?.last ?? null },
            apple: {
              lastImport: (parse(setting(u.id, 'apple_last_import'))?.importedAt as string) ?? null,
              lastSync: (parse(setting(u.id, 'apple_last_sync'))?.syncedAt as string) ?? null,
              iphoneToken: Boolean(u.has_ingest_token),
            },
            whoop: {
              connected: connected.has(u.id),
              lastSync: setting(u.id, 'whoop_last_sync') ?? null,
              lastError: (sync?.lastError as string) ?? null,
              historyComplete: Boolean((sync?.lastCounts as Record<string, number> | undefined)?.historyComplete),
            },
            photo: Boolean(setting(u.id, 'photo_meta')),
            mcfly: { questions30d: mcfly.get(u.id)?.questions ?? 0, tokens30d: Number(mcfly.get(u.id)?.tokens ?? 0) },
          };
        }),
        invites: invites.map((i) => ({
          id: i.id,
          kind: i.kind,
          email: i.email,
          role: i.role,
          userId: i.user_id,
          createdAt: Number(i.created_at),
          expiresAt: Number(i.expires_at),
          usedAt: i.used_at === null ? null : Number(i.used_at),
          usedBy: i.used_by,
          revokedAt: i.revoked_at === null ? null : Number(i.revoked_at),
        })),
        settings: platform,
        whoop: { configured: whoop.isConfigured(), redirectUri: whoop.whoopConfig().redirectUri },
        mcfly: { configured: Boolean(process.env.ANTHROPIC_API_KEY) },
      });
    }),
  );

  router.post(
    '/invites',
    h(async (req, res) => {
      const role = ROLES.includes(req.body?.role) ? (req.body.role as Role) : 'user';
      const email = normalizeEmail(req.body?.email);
      if (email && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) throw new HttpError(400, 'That email address looks wrong.');
      if (email) {
        const [taken] = await db.query('SELECT 1 FROM users WHERE email = $1', [email]);
        if (taken) throw new HttpError(409, 'Someone with that email already has an account.');
      }
      const platform = await platformSettings(db);
      const days = Math.min(Math.max(Number(req.body?.days) || Number(platform.invite_days) || 7, 1), 30);
      const link = await createLink(db, { kind: 'invite', createdBy: currentUser(res).id, email, role, days });
      // The token is shown once, here. Only its hash is stored.
      res.json({ id: link.id, url: `${origin(req)}/#/invite/${link.token}`, expiresInDays: days });
    }),
  );

  router.post(
    '/invites/:id/revoke',
    h(async (req, res) => {
      await db.query('UPDATE invites SET revoked_at = $1 WHERE id = $2 AND used_at IS NULL AND revoked_at IS NULL', [Date.now(), req.params.id]);
      res.json({ ok: true });
    }),
  );

  router.patch(
    '/users/:id',
    h(async (req, res) => {
      const me = currentUser(res);
      const target = await getUser(db, String(req.params.id));
      if (!target) throw new HttpError(404, 'No such account.');
      const role = req.body?.role as Role | undefined;
      const status = req.body?.status as 'active' | 'disabled' | undefined;
      if (role !== undefined && !ROLES.includes(role)) throw new HttpError(400, 'Unknown role.');
      if (status !== undefined && !['active', 'disabled'].includes(status)) throw new HttpError(400, 'Unknown status.');
      if (target.id === me.id && (role === 'user' || status === 'disabled')) throw new HttpError(400, "You can't demote or disable your own account.");
      const losesAdmin = target.role === 'admin' && target.status === 'active' && (role === 'user' || status === 'disabled');
      if (losesAdmin && (await countActiveAdmins(db)) <= 1) throw new HttpError(400, 'There must always be at least one active admin.');
      await db.query(
        `UPDATE users SET role = COALESCE($1, role), status = COALESCE($2, status),
         session_version = session_version + CASE WHEN $2::text = 'disabled' THEN 1 ELSE 0 END WHERE id = $3`,
        [role ?? null, status ?? null, target.id],
      );
      res.json({ ok: true });
    }),
  );

  router.post(
    '/users/:id/reset',
    h(async (req, res) => {
      const target = await getUser(db, String(req.params.id));
      if (!target) throw new HttpError(404, 'No such account.');
      // A link the admin passes on. The admin never sees or sets the password; using the link ends the
      // account's other sessions.
      const link = await createLink(db, { kind: 'reset', createdBy: currentUser(res).id, userId: target.id, days: 2 });
      res.json({ url: `${origin(req)}/#/reset/${link.token}`, expiresInDays: 2 });
    }),
  );

  router.delete(
    '/users/:id',
    h(async (req, res) => {
      const me = currentUser(res);
      const target = await getUser(db, String(req.params.id));
      if (!target) throw new HttpError(404, 'No such account.');
      if (target.id === me.id) throw new HttpError(400, "You can't delete your own account.");
      if (target.role === 'admin' && target.status === 'active' && (await countActiveAdmins(db)) <= 1) {
        throw new HttpError(400, 'There must always be at least one active admin.');
      }
      // Revoke WHOOP's access first (best effort), then remove everything in one transaction.
      await whoop.disconnect({ db, userId: target.id }).catch(() => {});
      await db.tx(async (q) => {
        await deleteUserData(q, target.id);
        await q.query('DELETE FROM invites WHERE user_id = $1', [target.id]);
        await q.query('DELETE FROM users WHERE id = $1', [target.id]);
      });
      res.json({ ok: true });
    }),
  );

  router.put(
    '/settings',
    h(async (req, res) => {
      const b = req.body ?? {};
      if (b.registration !== undefined) {
        if (!['invite', 'closed'].includes(b.registration)) throw new HttpError(400, 'Registration must be invite or closed.');
        await setSetting(db, 'registration', b.registration);
      }
      if (b.default_units !== undefined) {
        if (!['metric', 'imperial'].includes(b.default_units)) throw new HttpError(400, 'Units must be metric or imperial.');
        await setSetting(db, 'default_units', b.default_units);
      }
      if (b.default_step_goal !== undefined) {
        const goal = Math.round(Number(b.default_step_goal));
        if (!(goal >= 500 && goal <= 100_000)) throw new HttpError(400, 'Step goal must be between 500 and 100,000.');
        await setSetting(db, 'default_step_goal', String(goal));
      }
      if (b.invite_days !== undefined) {
        const days = Math.round(Number(b.invite_days));
        if (!(days >= 1 && days <= 30)) throw new HttpError(400, 'Invite links last 1 to 30 days.');
        await setSetting(db, 'invite_days', String(days));
      }
      if (b.mcfly_model !== undefined) {
        if (typeof b.mcfly_model !== 'string' || !/^claude-[a-z0-9-]+$/.test(b.mcfly_model)) throw new HttpError(400, 'Unknown model id.');
        await setSetting(db, 'mcfly_model', b.mcfly_model);
      }
      if (b.mcfly_daily_limit !== undefined) {
        const n = Math.round(Number(b.mcfly_daily_limit));
        if (!(n >= 0 && n <= 1000)) throw new HttpError(400, 'Daily limit must be 0 to 1,000.');
        await setSetting(db, 'mcfly_daily_limit', String(n));
      }
      res.json({ settings: await platformSettings(db) });
    }),
  );

  return router;
}
