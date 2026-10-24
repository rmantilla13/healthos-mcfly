// Which cards show on Home, Sleep, Body and (with Nutrition on) Nutrition: a checkbox per card, grouped by page.
// Used in Profile for yourself, in Home's Edit widgets (one page), and on the Admin page for anyone. Nutrition's cards
// are offered only to someone with it on, so the Admin page, which doesn't know who has, never shows them. Optional
// cards (off until turned on) are left out there too: the admin endpoint only knows the hidden list.
import { useEffect, useRef, useState } from 'react';
import { CARD_PAGES, CARDS, type CardPage, OPTIONAL_CARDS, cardShown } from '../../shared/cards.ts';
import type { Settings, Status } from '../../shared/types.ts';
import { type CardLists, cardListsOf, sendJson } from '../lib.ts';

export function CardChoices({
  lists,
  onToggle,
  idPrefix,
  nutrition = false,
  optional = true,
  page,
}: {
  lists: CardLists;
  onToggle: (id: string, shown: boolean) => void;
  idPrefix: string;
  nutrition?: boolean;
  /** Offer the optional cards (false on the Admin page). */
  optional?: boolean;
  /** Only this page's cards, split into the ones it shows by default and the extras (Edit widgets). */
  page?: CardPage;
}) {
  const offered = CARDS.filter((c) => (nutrition || !c.nutrition) && (optional || !c.defaultHidden) && (!page || c.page === page));
  const box = (c: (typeof CARDS)[number]) => (
    <label key={c.id} htmlFor={`${idPrefix}-${c.id}`}>
      <input id={`${idPrefix}-${c.id}`} type="checkbox" checked={cardShown(c.id, lists.hidden, lists.shown)} onChange={(e) => onToggle(c.id, e.target.checked)} />
      <span>{c.label}</span>
      {!page && c.defaultHidden && <small className="muted">Optional</small>}
    </label>
  );
  if (page) {
    const extras = offered.filter((c) => c.defaultHidden);
    return (
      <div className="card-choices">
        <fieldset>
          <legend>On this page</legend>
          {offered.filter((c) => !c.defaultHidden).map(box)}
        </fieldset>
        {extras.length > 0 && (
          <fieldset>
            <legend>More you can add</legend>
            {extras.map(box)}
          </fieldset>
        )}
      </div>
    );
  }
  return (
    <div className="card-choices">
      {CARD_PAGES.filter((p) => offered.some((c) => c.page === p.page)).map((p) => (
        <fieldset key={p.page}>
          <legend>{p.label}</legend>
          {offered.filter((c) => c.page === p.page).map(box)}
        </fieldset>
      ))}
    </div>
  );
}

export type CardChange = { cardShown: { id: string; shown: boolean } } | { hiddenCards: string[] };

/**
 * Card choices edited one card at a time. Each click shows at once and goes to the server in order, as that one
 * card's change, which the server applies to the lists as stored then, so nothing changed elsewhere meanwhile
 * (another tab, or an admin) is undone. Whenever nothing is on its way, the boxes follow the stored lists.
 * `send` returns the lists the server stored. An optional card moves in or out of `shown` (and the other way in `hidden`, for the
 * iPhone), any other in or out of `hidden`.
 */
export function useCardEditor(saved: CardLists, send: (body: CardChange) => Promise<CardLists>) {
  const [lists, setLists] = useState(saved);
  const [error, setError] = useState<string | null>(null);
  const pending = useRef(0);
  const queue = useRef<Promise<void>>(Promise.resolve());
  const latest = useRef(saved);
  latest.current = saved;
  const key = `${saved.hidden.join(',')}|${saved.shown.join(',')}`;
  useEffect(() => {
    if (pending.current === 0) setLists(latest.current);
  }, [key]);

  function apply(body: CardChange, next: (l: CardLists) => CardLists) {
    setError(null);
    setLists(next);
    pending.current++;
    queue.current = queue.current.then(async () => {
      try {
        const stored = await send(body);
        if (pending.current === 1) setLists(stored);
      } catch (e) {
        setError((e as Error).message);
        if (pending.current === 1) setLists(latest.current);
      } finally {
        pending.current--;
      }
    });
  }

  const flip = (list: string[], id: string, on: boolean) => (on ? [...list.filter((x) => x !== id), id] : list.filter((x) => x !== id));
  return {
    lists,
    error,
    toggle: (id: string, shown: boolean) =>
      // As withCardToggled does on the server: an optional card moves in or out of `shown`, and the other way in `hidden`.
      apply({ cardShown: { id, shown } }, (l) =>
        OPTIONAL_CARDS.has(id) ? { shown: flip(l.shown, id, shown), hidden: flip(l.hidden, id, !shown) } : { ...l, hidden: flip(l.hidden, id, !shown) },
      ),
    /** Every default card back on; the optional ones stay as they are. */
    showAll: () => apply({ hiddenCards: [] }, (l) => ({ ...l, hidden: [] })),
  };
}

/** Your own cards (Profile → Cards, Home → Edit widgets): saved with PUT /api/settings, then the status reloads. */
export function useOwnCardEditor(settings: Settings, refresh: () => void) {
  return useCardEditor(cardListsOf(settings), async (body) => {
    const next = await sendJson<Status>('PUT', '/settings', body);
    refresh();
    return cardListsOf(next.settings);
  });
}
