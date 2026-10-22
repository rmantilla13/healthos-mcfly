// ⌘K: search pages, tabs, metrics and a few actions from anywhere. ⌘K on a Mac, Ctrl+K elsewhere, or the Search
// button; not while you're typing in a field. A dialog with a combobox and its listbox of results (the ARIA
// combobox pattern): arrow keys move, Enter opens, Escape closes and focus goes back where it was. The catalogue
// and its ranking live in shared/search.ts. What's typed stays on the page: it never goes into the address.
import { type KeyboardEvent as ReactKeyboardEvent, useCallback, useEffect, useId, useMemo, useRef, useState } from 'react';
import { createPortal, flushSync } from 'react-dom';
import { type SearchAccess, type SearchItem, isPaletteShortcut, isTypingTarget, rank, searchItems } from '../../shared/search.ts';
import type { AuthMe, Status } from '../../shared/types.ts';
import { useApi } from '../lib.ts';
import { Icon, type IconName } from './Icon.tsx';

/** The Search button and the palette mount in different places; this event joins them. */
const OPEN_EVENT = 'healthos:search';
export const openSearch = () => window.dispatchEvent(new Event(OPEN_EVENT));

const isMac = () => typeof navigator !== 'undefined' && /Mac|iPhone|iPad|iPod/.test(navigator.platform || navigator.userAgent);

/**
 * A sidebar item that opens the palette. On a phone's top bar its label hides, as the other items' do, so the
 * button carries its name itself.
 */
export function SearchButton() {
  const mac = useMemo(isMac, []);
  return (
    <button
      type="button"
      className="nav-item search-button"
      onClick={openSearch}
      aria-label="Search"
      aria-haspopup="dialog"
      aria-keyshortcuts={mac ? 'Meta+K' : 'Control+K'}
    >
      <Icon name="search" />
      <span>Search</span>
      <kbd aria-hidden="true">{mac ? '⌘K' : 'Ctrl K'}</kbd>
    </button>
  );
}

/**
 * Listens for the shortcut and the button, and shows the palette. Renders nothing while closed (it sits in the
 * app's grid, where anything in the flow would take a cell); when open, the dialog goes to the end of the page.
 */
export function CommandPalette() {
  const [open, setOpen] = useState(false);
  const returnTo = useRef<HTMLElement | null>(null);

  const show = useCallback(() => {
    if (!returnTo.current) returnTo.current = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    setOpen(true);
  }, []);

  useEffect(() => {
    const mac = isMac();
    const onKey = (e: KeyboardEvent) => {
      if (e.defaultPrevented || !isPaletteShortcut(e, mac)) return;
      // In a field, ⌘K belongs to the field (the palette's own input handles it itself).
      if (isTypingTarget(e.target as HTMLElement | null)) return;
      e.preventDefault();
      show();
    };
    window.addEventListener('keydown', onKey);
    window.addEventListener(OPEN_EVENT, show);
    return () => {
      window.removeEventListener('keydown', onKey);
      window.removeEventListener(OPEN_EVENT, show);
    };
  }, [show]);

  const close = useCallback((to?: string) => {
    const back = returnTo.current;
    returnTo.current = null;
    // Take the dialog away first, so focus goes back where it was rather than landing inside it.
    flushSync(() => setOpen(false));
    if (to && location.hash !== to) location.hash = to;
    if (back?.isConnected) back.focus({ preventScroll: true });
  }, []);

  return open ? createPortal(<Palette onClose={close} />, document.body) : null;
}

// ---------- handing a question to Ask McFly ----------
// "Ask McFly about …" passes what was typed to the Ask McFly page in this tab's sessionStorage (as the chat itself
// is kept), never in the address. The page takes it once, with useMcflyDraft.

const draftKey = (userId: string) => `healthos-mcfly-draft:${userId}`;
const DRAFT_EVENT = 'healthos:mcfly-draft';

function handOver(userId: string, question: string) {
  try {
    sessionStorage.setItem(draftKey(userId), question);
  } catch {
    // Storage blocked: Ask McFly still opens, with an empty box.
  }
  window.dispatchEvent(new Event(DRAFT_EVENT));
}

/** The question handed over from the palette, if any, removed as it's read. */
export function takeMcflyDraft(userId: string): string {
  try {
    const q = sessionStorage.getItem(draftKey(userId)) ?? '';
    sessionStorage.removeItem(draftKey(userId));
    return q;
  } catch {
    return '';
  }
}

/** For the Ask McFly page: put a question handed over from the palette into its box, on opening and while open. */
export function useMcflyDraft(userId: string, setDraft: (q: string) => void) {
  useEffect(() => {
    const take = () => {
      const q = takeMcflyDraft(userId);
      if (q) setDraft(q);
    };
    take();
    window.addEventListener(DRAFT_EVENT, take);
    return () => window.removeEventListener(DRAFT_EVENT, take);
  }, [userId, setDraft]);
}

// ---------- the palette ----------

const PAGE_ICON: Record<string, IconName> = {
  'page.home': 'home',
  'page.family': 'family',
  'page.vitals': 'vitals',
  'page.body': 'body',
  'page.cycle': 'cycle',
  'page.sleep': 'sleep',
  'page.nutrition': 'nutrition',
  'page.labs': 'labs',
  'page.mcfly': 'spark',
  'page.integrations': 'integrations',
  'page.settings': 'settings',
  'page.admin': 'shield',
};

function iconOf(it: SearchItem): IconName {
  if (PAGE_ICON[it.id]) return PAGE_ICON[it.id];
  if (it.group === 'tabs') return 'table';
  if (it.group === 'metrics') return 'chart';
  if (it.id === 'action.ask' || it.id === 'action.mcfly') return 'spark';
  return 'arrow-up-right';
}

function useAccess(): { access: SearchAccess; userId: string | null } {
  // Both were loaded when the dashboard opened, so these are usually answered from what's already in memory.
  const { data: status } = useApi<Status>('/status');
  const { data: me } = useApi<AuthMe>('/auth/me');
  const s = status?.settings;
  // As in the sidebar: Family and Admin need sign-in (without it there's only you).
  const signedIn = me?.mode === 'required' && me.authenticated;
  return {
    access: {
      cycleTracking: Boolean(s?.cycleTracking),
      nutrition: Boolean(s?.nutrition && s.nutritionNumbers),
      nutritionAmounts: Boolean(s?.nutritionNumbers && s.nutritionNumbers !== 'none'),
      family: signedIn && Boolean(s?.familySharing),
      admin: signedIn && status?.user.role === 'admin',
    },
    userId: status?.user.id ?? null,
  };
}

function Palette({ onClose }: { onClose: (to?: string) => void }) {
  const dialog = useRef<HTMLDialogElement>(null);
  const input = useRef<HTMLInputElement>(null);
  const base = useId().replace(/[^\w-]/g, '');
  const [query, setQuery] = useState('');
  const [active, setActive] = useState(0);
  const { access, userId } = useAccess();
  const items = useMemo(() => searchItems(access), [access.cycleTracking, access.nutrition, access.nutritionAmounts, access.family, access.admin]);
  const sections = useMemo(() => rank(query, items), [query, items]);
  const flat = useMemo(() => sections.flatMap((s) => s.items), [sections]);
  const current = Math.min(active, Math.max(0, flat.length - 1));
  const optionId = (i: number) => `${base}-opt-${i}`;

  useEffect(() => {
    const d = dialog.current;
    if (d && !d.open) d.showModal();
    input.current?.focus();
  }, []);

  useEffect(() => {
    document.getElementById(optionId(current))?.scrollIntoView({ block: 'nearest' });
  });

  const choose = (it: SearchItem | undefined) => {
    if (!it) return;
    if (it.ask && userId) handOver(userId, it.ask);
    onClose(it.to);
  };

  const onKeyDown = (e: ReactKeyboardEvent<HTMLInputElement>) => {
    if (e.nativeEvent.isComposing) return;
    const n = flat.length;
    if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
      e.preventDefault();
      if (n) setActive((current + (e.key === 'ArrowDown' ? 1 : n - 1)) % n);
    } else if (e.key === 'Enter') {
      e.preventDefault();
      choose(flat[current]);
    } else if (e.key === 'Escape') {
      e.preventDefault();
      onClose();
    } else if (isPaletteShortcut(e.nativeEvent, isMac())) {
      // ⌘K again closes it, and keeps the browser's own Ctrl+K (its search bar) out of the way.
      e.preventDefault();
      onClose();
    }
  };

  let i = -1;
  return (
    <dialog
      ref={dialog}
      className="palette"
      aria-label="Search healthOS"
      onCancel={(e) => {
        e.preventDefault();
        onClose();
      }}
      // A click on the backdrop (the dialog itself, outside its panel) closes it.
      onClick={(e) => e.target === e.currentTarget && onClose()}
    >
      <div className="palette-panel">
        <div className="palette-field">
          <Icon name="search" />
          <input
            ref={input}
            type="text"
            role="combobox"
            aria-label="Search pages, tabs, metrics and actions"
            aria-expanded={flat.length > 0}
            aria-controls={`${base}-list`}
            aria-autocomplete="list"
            aria-activedescendant={flat.length ? optionId(current) : undefined}
            placeholder="Search pages, metrics and actions"
            value={query}
            onChange={(e) => {
              setQuery(e.target.value);
              setActive(0);
            }}
            onKeyDown={onKeyDown}
            autoComplete="off"
            autoCorrect="off"
            autoCapitalize="none"
            spellCheck={false}
            enterKeyHint="go"
          />
          <button type="button" className="palette-close" onClick={() => onClose()} aria-label="Close search">
            <span className="palette-close-key">Esc</span>
            <span className="palette-close-word">Close</span>
          </button>
        </div>
        <div id={`${base}-list`} role="listbox" aria-label="Results" className="palette-list">
          {sections.map((s) => (
            <div key={s.group} role="group" aria-labelledby={`${base}-${s.group}`} className="palette-group">
              <div id={`${base}-${s.group}`} role="presentation" className="palette-group-label">
                {s.label}
              </div>
              {s.items.map((it) => {
                i++;
                const at = i;
                return (
                  <div
                    key={it.id}
                    id={optionId(at)}
                    role="option"
                    aria-selected={at === current}
                    className={at === current ? 'palette-option is-active' : 'palette-option'}
                    onMouseDown={(e) => e.preventDefault()}
                    onMouseMove={() => at !== current && setActive(at)}
                    onClick={() => choose(it)}
                  >
                    <span className="palette-option-icon">
                      <Icon name={iconOf(it)} size={16} />
                    </span>
                    <span className="palette-option-label">{it.label}</span>
                    {it.hint && <span className="palette-option-hint">{it.hint}</span>}
                  </div>
                );
              })}
            </div>
          ))}
        </div>
        <p className="palette-foot" aria-hidden="true">
          <span>
            <kbd>↑</kbd>
            <kbd>↓</kbd> to move
          </span>
          <span>
            <kbd>Enter</kbd> to open
          </span>
          <span>
            <kbd>Esc</kbd> to close
          </span>
        </p>
        <p className="sr-only" aria-live="polite">
          {query.trim() ? `${flat.length} ${flat.length === 1 ? 'result' : 'results'}` : ''}
        </p>
      </div>
    </dialog>
  );
}
