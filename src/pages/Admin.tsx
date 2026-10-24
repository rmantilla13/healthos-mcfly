// Admin panel: accounts, invite links and platform settings. It shows how much data each account has and
// whether its syncs are healthy, never the health values themselves (the server doesn't send them).
import { useState } from 'react';
import type { AdminInvite, AdminOverview, AdminUser, PlatformSettings, Role, SessionUser } from '../../shared/types.ts';
import { Icon } from '../components/Icon.tsx';
import { fmt, fmtDate, notifyDataChanged, sendJson, useApi } from '../lib.ts';
import { CardChoices, useCardEditor } from '../components/CardChoices.tsx';
import { PageIntro } from '../components/PageIntro.tsx';
import { CopyField } from './Integrations.tsx';

type Tab = 'users' | 'invites' | 'settings';
type Shown = { title: string; url: string; note: string; code?: string } | null;

// Local dates: these are moments (sign-ins, link times), not the wearer's recorded days.
const shortDate = (ms: number, year = false) =>
  new Date(ms).toLocaleDateString(undefined, { month: 'short', day: 'numeric', ...(year ? { year: 'numeric' } : {}) });

function ago(when: number | string | null) {
  if (when === null) return 'never';
  const ms = typeof when === 'number' ? when : Date.parse(when);
  const mins = Math.round((Date.now() - ms) / 60_000);
  if (mins < 1) return 'just now';
  if (mins < 60) return `${mins} min ago`;
  if (mins < 48 * 60) return `${Math.round(mins / 60)} h ago`;
  return shortDate(ms, true);
}

export function Admin({ me }: { me: SessionUser }) {
  const [tab, setTab] = useState<Tab>('users');
  const { data, error, reload } = useApi<AdminOverview>('/admin/overview');
  const [shown, setShown] = useState<Shown>(null);
  const [actionError, setActionError] = useState<string | null>(null);

  /** Run an admin action, surface its error, and refresh the overview. */
  async function act<T>(fn: () => Promise<T>): Promise<T | undefined> {
    setActionError(null);
    try {
      return await fn();
    } catch (e) {
      setActionError((e as Error).message);
      return undefined;
    } finally {
      reload();
    }
  }

  return (
    <div className="page">
      <PageIntro
        sub="Accounts, invites and platform settings. Nobody's health values are shown here."
        actions={
          <div className="filters" role="tablist" aria-label="Admin sections">
            {(['users', 'invites', 'settings'] as const).map((t) => (
              <button key={t} role="tab" aria-selected={tab === t} className={tab === t ? 'on' : ''} onClick={() => setTab(t)}>
                {t === 'users' ? `People${data ? ` · ${data.users.length}` : ''}` : t === 'invites' ? 'Invites' : 'Settings'}
              </button>
            ))}
          </div>
        }
      />

      {shown && (
        <section className="card admin-link" aria-live="polite">
          <div className="card-title-row">
            <h2>{shown.title}</h2>
            <button className="icon-btn" aria-label="Dismiss" onClick={() => setShown(null)}>
              <Icon name="check" size={16} />
            </button>
          </div>
          {shown.code && (
            <div className="admin-code">
              <code>{shown.code}</code>
              <CopyField value={shown.code} label="Copy code" />
            </div>
          )}
          {shown.code && <span className="muted small">Or share the link, which carries the same code:</span>}
          <CopyField value={shown.url} label="Copy link" />
          <p className="muted small">{shown.note}</p>
        </section>
      )}
      {(actionError || error) && (
        <div className="banner banner-bad" role="alert">
          <Icon name="alert" size={16} /> {actionError ?? error?.message}
        </div>
      )}

      {!data ? (
        !error && <p className="muted">Loading…</p>
      ) : tab === 'users' ? (
        <People data={data} me={me} act={act} onLink={setShown} />
      ) : tab === 'invites' ? (
        <Invites data={data} act={act} onLink={setShown} />
      ) : (
        <PlatformSettingsCard data={data} act={act} />
      )}
    </div>
  );
}

type Act = <T>(fn: () => Promise<T>) => Promise<T | undefined>;

function People({ data, me, act, onLink }: { data: AdminOverview; me: SessionUser; act: Act; onLink: (s: Shown) => void }) {
  const admins = data.users.filter((u) => u.role === 'admin' && u.status === 'active').length;

  async function reset(u: AdminUser) {
    const r = await act(() => sendJson<{ url: string; expiresInDays: number }>('POST', `/admin/users/${u.id}/reset`));
    if (r) onLink({ title: `Password reset link for ${u.name || u.email}`, url: r.url, note: `Send it to them privately. It works once, for ${r.expiresInDays} days, and signs them out everywhere else.` });
  }

  async function remove(u: AdminUser) {
    const typed = prompt(`Delete ${u.email}? This removes the account and all of its health data, and can't be undone.\n\nType their email to confirm.`);
    if (typed === null) return;
    if (typed.trim().toLowerCase() !== u.email) return void alert("That email didn't match, so nothing was deleted.");
    await act(() => sendJson('DELETE', `/admin/users/${u.id}`));
  }

  return (
    <section className="card">
      <div className="admin-table">
        <table>
          <thead>
            <tr>
              <th>Person</th>
              <th>Role</th>
              <th>Status</th>
              <th>Last sign-in</th>
              <th>Data</th>
              <th>Apple Health</th>
              <th>WHOOP</th>
              <th>McFly, 30 days</th>
              <th>
                <span className="sr-only">Actions</span>
              </th>
            </tr>
          </thead>
          <tbody>
            {data.users.map((u) => {
              const self = u.id === me.id;
              const lastAdmin = u.role === 'admin' && u.status === 'active' && admins <= 1;
              return (
                <tr key={u.id} className={u.status === 'disabled' ? 'is-off' : ''}>
                  <td>
                    <div className="admin-person">
                      <b>{u.name || '—'}</b>
                      {self && <span className="pill">You</span>}
                    </div>
                    <div className="muted small">{u.email}</div>
                  </td>
                  <td>{u.role === 'admin' ? 'Admin' : 'Member'}</td>
                  <td>
                    <span className={`admin-status ${u.status === 'active' ? 'is-on' : ''}`}>
                      <i aria-hidden="true" /> {u.status === 'active' ? 'Active' : 'Disabled'}
                    </span>
                  </td>
                  <td>{ago(u.lastLoginAt)}</td>
                  <td>
                    {u.data.days ? (
                      <>
                        {fmt(u.data.days)} days
                        <div className="muted small">
                          {fmtDate(u.data.first!, { month: 'short', year: 'numeric' })} – {fmtDate(u.data.last!, { month: 'short', day: 'numeric', year: 'numeric' })}
                        </div>
                      </>
                    ) : (
                      <span className="muted">None yet</span>
                    )}
                  </td>
                  <td>
                    {u.apple.lastSync ? `iPhone ${ago(u.apple.lastSync)}` : u.apple.lastImport ? `Import ${ago(u.apple.lastImport)}` : <span className="muted">Off</span>}
                    <div className="muted small">{u.apple.iphoneToken ? 'App token set' : 'No app token'}</div>
                  </td>
                  <td>
                    {u.whoop.connected ? (u.whoop.lastSync ? `Synced ${ago(u.whoop.lastSync)}` : 'Connected') : <span className="muted">Off</span>}
                    {u.whoop.lastError && (
                      <div className="note-bad small" title={u.whoop.lastError}>
                        <Icon name="alert" size={13} /> Last sync failed
                      </div>
                    )}
                    {u.whoop.connected && !u.whoop.lastError && <div className="muted small">{u.whoop.historyComplete ? 'History complete' : 'History loading'}</div>}
                  </td>
                  <td>
                    {u.mcfly.questions30d ? `${fmt(u.mcfly.questions30d)} question${u.mcfly.questions30d === 1 ? '' : 's'}` : <span className="muted">None</span>}
                    {u.mcfly.tokens30d > 0 && <div className="muted small">{fmt(u.mcfly.tokens30d / 1000)}K tokens</div>}
                  </td>
                  <td>
                    <AdminCards u={u} self={self} act={act} />
                    {self ? (
                      <span className="muted small">Change your own password in your Profile.</span>
                    ) : (
                      <div className="btn-row admin-actions">
                        <button
                          className="btn"
                          disabled={lastAdmin}
                          onClick={() => act(() => sendJson('PATCH', `/admin/users/${u.id}`, { role: (u.role === 'admin' ? 'user' : 'admin') satisfies Role }))}
                        >
                          {u.role === 'admin' ? 'Make member' : 'Make admin'}
                        </button>
                        <button
                          className="btn"
                          disabled={lastAdmin}
                          onClick={() => {
                            if (u.status === 'active' && !confirm(`Disable ${u.email}? They're signed out now and can't sign in until you enable them. Their data stays.`)) return;
                            act(() => sendJson('PATCH', `/admin/users/${u.id}`, { status: u.status === 'active' ? 'disabled' : 'active' }));
                          }}
                        >
                          {u.status === 'active' ? 'Disable' : 'Enable'}
                        </button>
                        <button className="btn" disabled={u.status !== 'active'} onClick={() => reset(u)}>
                          Reset link
                        </button>
                        <button className="btn btn-quiet btn-danger" disabled={lastAdmin} onClick={() => remove(u)}>
                          Delete
                        </button>
                      </div>
                    )}
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
    </section>
  );
}

/** The cards a person sees, which an admin can change for them (only the layout, never their data). */
function AdminCards({ u, self, act }: { u: AdminUser; self: boolean; act: Act }) {
  // A server older than optional cards sends no shownCards: then they aren't offered.
  const optional = u.shownCards !== undefined;
  const cards = useCardEditor({ hidden: u.hiddenCards ?? [], shown: u.shownCards ?? [] }, async (body) => {
    const r = await act(() => sendJson<{ hiddenCards: string[]; shownCards?: string[] }>('PATCH', `/admin/users/${u.id}`, body));
    if (!r) throw new Error('Not saved.');
    // Your own pages pick it up now, not at the next background check.
    if (self) notifyDataChanged();
    return { hidden: r.hiddenCards, shown: r.shownCards ?? [] };
  });
  return (
    <details className="admin-cards">
      <summary>{cards.lists.hidden.length ? `Cards · ${cards.lists.hidden.length} hidden` : 'Cards · all shown'}</summary>
      <p className="muted small">{self ? 'The cards on your Home, Sleep and Body pages.' : `The cards ${u.name || u.email} sees on Home, Sleep and Body. They can change these in their Profile too.`}</p>
      <CardChoices lists={cards.lists} onToggle={cards.toggle} idPrefix={`admin-${u.id}`} optional={optional} />
    </details>
  );
}

function inviteState(i: AdminInvite) {
  if (i.revokedAt) return 'Revoked';
  if (i.usedAt) return 'Used';
  if (i.expiresAt < Date.now()) return 'Expired';
  return 'Pending';
}

function Invites({ data, act, onLink }: { data: AdminOverview; act: Act; onLink: (s: Shown) => void }) {
  const [email, setEmail] = useState('');
  const [role, setRole] = useState<Role>('user');
  const [days, setDays] = useState(data.settings.invite_days);
  const byId = new Map(data.users.map((u) => [u.id, u]));
  const closed = data.settings.registration === 'closed';

  async function create(e: React.FormEvent) {
    e.preventDefault();
    const r = await act(() =>
      sendJson<{ code: string; url: string; expiresInDays: number }>('POST', '/admin/invites', { email: email.trim() || undefined, role, days: Number(days) }),
    );
    if (!r) return;
    onLink({
      title: email.trim() ? `Invite code for ${email.trim()}` : 'Invite code',
      code: r.code,
      url: r.url,
      note: `Share it privately. They enter it under "Have an invite code?" on the sign-in page or in the iPhone app. It creates one account${email.trim() ? ' for that email' : ''}, works for ${r.expiresInDays} days, and is shown only now.`,
    });
    setEmail('');
    setRole('user');
  }

  return (
    <>
      {closed && (
        <div className="banner banner-bad">
          <Icon name="alert" size={16} /> Sign-ups are closed, so invite codes won't create accounts until you reopen them in Settings.
        </div>
      )}
      <section className="card">
        <h2>Invite someone</h2>
        <form className="admin-invite" onSubmit={create}>
          <label>
            <span>Only for this email (optional)</span>
            <input type="email" placeholder="Anyone with the code" value={email} onChange={(e) => setEmail(e.target.value)} />
          </label>
          <label>
            <span>Role</span>
            <select value={role} onChange={(e) => setRole(e.target.value as Role)}>
              <option value="user">Member</option>
              <option value="admin">Admin</option>
            </select>
          </label>
          <label>
            <span>Expires after (days)</span>
            <input inputMode="numeric" value={days} onChange={(e) => setDays(e.target.value.replace(/\D/g, ''))} />
          </label>
          <button className="btn btn-primary" type="submit" disabled={!days}>
            Create code
          </button>
        </form>
        <p className="muted small">Nothing is emailed: you share the code yourself. Leave the email empty for a code anyone can use once; with one, only that address can sign up with it.</p>
      </section>

      <section className="card">
        <h2>Codes and reset links</h2>
        {data.invites.length === 0 ? (
          <p className="muted">None yet.</p>
        ) : (
          <div className="admin-table">
            <table>
              <thead>
                <tr>
                  <th>For</th>
                  <th>Kind</th>
                  <th>Created</th>
                  <th>Expires</th>
                  <th>Status</th>
                  <th>
                    <span className="sr-only">Actions</span>
                  </th>
                </tr>
              </thead>
              <tbody>
                {data.invites.map((i) => {
                  const state = inviteState(i);
                  const target = i.kind === 'reset' ? byId.get(i.userId ?? '')?.email : i.email;
                  const usedBy = i.usedBy && byId.get(i.usedBy);
                  return (
                    <tr key={i.id} className={state === 'Pending' ? '' : 'is-off'}>
                      <td>
                        {target ?? <span className="muted">Anyone</span>}
                        {i.kind === 'invite' && usedBy && <div className="muted small">Joined as {usedBy.email}</div>}
                      </td>
                      <td>{i.kind === 'invite' ? `Invite code · ${i.role === 'admin' ? 'admin' : 'member'}` : 'Password reset'}</td>
                      <td>{shortDate(i.createdAt)}</td>
                      <td>{shortDate(i.expiresAt)}</td>
                      <td>{state}</td>
                      <td>
                        {state === 'Pending' && (
                          <button className="btn btn-quiet" onClick={() => act(() => sendJson('POST', `/admin/invites/${i.id}/revoke`))}>
                            Revoke
                          </button>
                        )}
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}
      </section>
    </>
  );
}

function PlatformSettingsCard({ data, act }: { data: AdminOverview; act: Act }) {
  const s = data.settings;
  const [goal, setGoal] = useState(s.default_step_goal);
  const [days, setDays] = useState(s.invite_days);
  const [model, setModel] = useState(s.mcfly_model);
  const [limit, setLimit] = useState(s.mcfly_daily_limit);
  const [saved, setSaved] = useState(false);

  async function save(patch: Partial<PlatformSettings>) {
    const r = await act(() => sendJson('PUT', '/admin/settings', patch));
    if (!r) return;
    setSaved(true);
    setTimeout(() => setSaved(false), 1500);
  }

  return (
    <>
      <section className="card settings">
        <h2>Sign-ups</h2>
        <div className="settings-row">
          <span>New accounts</span>
          <div className="filters" role="group" aria-label="New accounts">
            {(['invite', 'closed'] as const).map((v) => (
              <button key={v} className={s.registration === v ? 'on' : ''} aria-pressed={s.registration === v} onClick={() => save({ registration: v })}>
                {v === 'invite' ? 'By invite code' : 'Closed'}
              </button>
            ))}
          </div>
          <small className="muted">There's no open sign-up. Closed also stops codes you've already shared.</small>
        </div>
        <label>
          <span>Invite codes last (days)</span>
          <input inputMode="numeric" value={days} onChange={(e) => setDays(e.target.value.replace(/\D/g, ''))} onBlur={() => days !== s.invite_days && save({ invite_days: days })} />
        </label>
      </section>

      <section className="card settings">
        <h2>Defaults</h2>
        <div className="settings-row">
          <span>Units</span>
          <div className="filters" role="group" aria-label="Default units">
            {(['metric', 'imperial'] as const).map((u) => (
              <button key={u} className={s.default_units === u ? 'on' : ''} aria-pressed={s.default_units === u} onClick={() => save({ default_units: u })}>
                {u === 'metric' ? 'Metric' : 'Imperial'}
              </button>
            ))}
          </div>
        </div>
        <label>
          <span>Daily step goal</span>
          <input inputMode="numeric" value={goal} onChange={(e) => setGoal(e.target.value.replace(/\D/g, ''))} onBlur={() => goal !== s.default_step_goal && save({ default_step_goal: goal })} />
        </label>
        <small className="muted">For anyone who hasn't picked their own in their Profile.</small>
        <p className={`muted small saved ${saved ? 'is-on' : ''}`}>
          <Icon name="check" size={14} /> Saved
        </p>
      </section>

      <section className="card settings">
        <h2>Ask McFly</h2>
        {data.mcfly.configured ? (
          <p className="muted">Each person can ask McFly about their own data. It reads only that person's data, and their questions aren't stored.</p>
        ) : (
          <p className="muted">Not set up. Add ANTHROPIC_API_KEY (from the Claude Console) to the Vercel project, then redeploy.</p>
        )}
        <label>
          <span>Model</span>
          <input value={model} onChange={(e) => setModel(e.target.value.trim())} onBlur={() => model && model !== s.mcfly_model && save({ mcfly_model: model })} />
        </label>
        <label>
          <span>Questions per person per day</span>
          <input inputMode="numeric" value={limit} onChange={(e) => setLimit(e.target.value.replace(/\D/g, ''))} onBlur={() => limit !== s.mcfly_daily_limit && save({ mcfly_daily_limit: limit })} />
          <small className="muted">0 turns Ask McFly off for everyone.</small>
        </label>
      </section>

      <section className="card settings">
        <h2>WHOOP</h2>
        {data.whoop.configured ? (
          <>
            <p className="muted">The WHOOP developer app is set up. Each person connects their own WHOOP from Integrations.</p>
            <div className="settings-row">
              <span>Redirect URL</span>
              <CopyField value={data.whoop.redirectUri} />
            </div>
          </>
        ) : (
          <p className="muted">Not set up. Add WHOOP_CLIENT_ID and WHOOP_CLIENT_SECRET to the Vercel project, then redeploy.</p>
        )}
      </section>
    </>
  );
}
