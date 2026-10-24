// The header's right side: the day (with previous and next on Home, which can show past days), Refresh, Home's Edit
// widgets, Search and your avatar (the account menu). The demo note goes first while demo data shows.
import { useState } from 'react';
import type { Status, SyncResult } from '../../../shared/types.ts';
import { fmtDate, href, notifyDataChanged, sendJson, shiftDate } from '../../lib.ts';
import { Icon } from '../Icon.tsx';
import { openSearch } from '../Search.tsx';
import { type AccountProps, AccountAvatar } from './AccountMenu.tsx';
import { EditWidgets } from './EditWidgets.tsx';

/** This browser's today (the server is told this time zone, so its today is the same). */
export const localToday = () => new Date().toLocaleDateString('en-CA');

export function TopBar({
  home,
  datedPage,
  date,
  setDate,
  reload,
  account,
}: {
  home: boolean;
  /** The page follows the shared day (Home, Sleep, Body), so the date shown is that day. */
  datedPage: boolean;
  date: string | null;
  setDate: (d: string | null) => void;
  reload: () => void;
  account: AccountProps;
}) {
  const [editing, setEditing] = useState(false);
  const status = account.status;
  const today = localToday();
  const day = datedPage && date ? date : today;
  const next = shiftDate(day, 1);
  return (
    <div className="topbar">
      {status?.demo && (
        <a className="pill pill-demo" href={href('integrations')}>
          Demo data · Connect yours
        </a>
      )}
      <div className="topbar-date">
        <span>{fmtDate(day, { weekday: 'short', month: 'short', day: 'numeric' })}</span>
        {home && (
          <span className="topbar-days">
            <button type="button" className="day-btn" onClick={() => setDate(shiftDate(day, -1))} aria-label="Previous day">
              <Icon name="chevron-left" size={14} />
            </button>
            <button type="button" className="day-btn" onClick={() => setDate(next >= today ? null : next)} disabled={day >= today} aria-label="Next day">
              <Icon name="chevron-right" size={14} />
            </button>
          </span>
        )}
      </div>
      <RefreshButton status={status} reload={reload} />
      {home && status && (
        <button type="button" className="pill topbar-widgets" aria-haspopup="dialog" aria-label="Edit widgets" onClick={() => setEditing(true)}>
          <Icon name="settings" size={15} />
          <span>Edit widgets</span>
        </button>
      )}
      <button type="button" className="icon-btn topbar-search" onClick={openSearch} aria-label="Search" aria-haspopup="dialog">
        <Icon name="search" size={15} />
      </button>
      <span className="topbar-avatar">
        <AccountAvatar id="top" {...account} />
      </span>
      {editing && status && <EditWidgets status={status} reload={reload} onClose={() => setEditing(false)} />}
    </div>
  );
}

/**
 * Syncs WHOOP now (POST /api/sync; Apple Health comes from the iPhone on its own), then every view refetches. It spins
 * while that runs, and while any sync runs (the dashboard watches status.whoop.syncing until it ends).
 */
export function RefreshButton({ status, reload }: { status: Status | undefined; reload: () => void }) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const running = busy || Boolean(status?.whoop.syncing);
  async function refresh() {
    setBusy(true);
    setError(null);
    try {
      await sendJson<SyncResult>('POST', '/sync');
    } catch (e) {
      setError((e as Error).message);
    } finally {
      reload();
      notifyDataChanged();
      setBusy(false);
    }
  }
  return (
    <button type="button" className={`pill refresh-btn${running ? ' is-running' : ''}`} onClick={refresh} disabled={running} aria-busy={running} title={error ?? undefined}>
      <Icon name="refresh" size={15} />
      <span>Refresh</span>
    </button>
  );
}
