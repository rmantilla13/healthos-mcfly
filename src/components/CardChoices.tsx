// Which cards show on Home, Sleep and Body: a checkbox per card, grouped by page. Used in Settings for yourself
// and on the Admin page for anyone.
import { useEffect, useRef, useState } from 'react';
import { CARD_PAGES, CARDS } from '../../shared/cards.ts';

export function CardChoices({ hidden, onToggle, idPrefix }: { hidden: string[]; onToggle: (id: string, shown: boolean) => void; idPrefix: string }) {
  const set = new Set(hidden);
  return (
    <div className="card-choices">
      {CARD_PAGES.map((p) => (
        <fieldset key={p.page}>
          <legend>{p.label}</legend>
          {CARDS.filter((c) => c.page === p.page).map((c) => (
            <label key={c.id} htmlFor={`${idPrefix}-${c.id}`}>
              <input id={`${idPrefix}-${c.id}`} type="checkbox" checked={!set.has(c.id)} onChange={(e) => onToggle(c.id, e.target.checked)} />
              <span>{c.label}</span>
            </label>
          ))}
        </fieldset>
      ))}
    </div>
  );
}

/**
 * Card choices edited one card at a time. Each click shows at once and goes to the server in order, as that one
 * card's change, which the server applies to the list as stored then, so nothing changed elsewhere meanwhile
 * (another tab, or an admin) is undone. Whenever nothing is on its way, the boxes follow the stored list.
 * `send` returns the list the server stored.
 */
export function useCardEditor(saved: string[], send: (body: { cardShown: { id: string; shown: boolean } } | { hiddenCards: string[] }) => Promise<string[]>) {
  const [hidden, setHidden] = useState(saved);
  const [error, setError] = useState<string | null>(null);
  const pending = useRef(0);
  const queue = useRef<Promise<void>>(Promise.resolve());
  const latest = useRef(saved);
  latest.current = saved;
  const key = saved.join(',');
  useEffect(() => {
    if (pending.current === 0) setHidden(latest.current);
  }, [key]);

  function apply(body: Parameters<typeof send>[0], next: (list: string[]) => string[]) {
    setError(null);
    setHidden(next);
    pending.current++;
    queue.current = queue.current.then(async () => {
      try {
        const stored = await send(body);
        if (pending.current === 1) setHidden(stored);
      } catch (e) {
        setError((e as Error).message);
        if (pending.current === 1) setHidden(latest.current);
      } finally {
        pending.current--;
      }
    });
  }

  return {
    hidden,
    error,
    toggle: (id: string, shown: boolean) => apply({ cardShown: { id, shown } }, (list) => (shown ? list.filter((x) => x !== id) : [...list, id])),
    showAll: () => apply({ hiddenCards: [] }, () => []),
  };
}
