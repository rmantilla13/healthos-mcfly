// Which cards show on Home, Sleep and Body: a checkbox per card, grouped by page. Used in Settings for yourself
// and on the Admin page for anyone.
import { CARD_PAGES, CARDS } from '../../shared/cards.ts';

export function CardChoices({ hidden, onChange, busy, idPrefix }: { hidden: string[]; onChange: (hidden: string[]) => void; busy?: boolean; idPrefix: string }) {
  const set = new Set(hidden);
  const toggle = (id: string, show: boolean) => {
    const next = new Set(set);
    if (show) next.delete(id);
    else next.add(id);
    onChange(CARDS.filter((c) => next.has(c.id)).map((c) => c.id));
  };
  return (
    <div className="card-choices">
      {CARD_PAGES.map((p) => (
        <fieldset key={p.page} disabled={busy}>
          <legend>{p.label}</legend>
          {CARDS.filter((c) => c.page === p.page).map((c) => (
            <label key={c.id} htmlFor={`${idPrefix}-${c.id}`}>
              <input id={`${idPrefix}-${c.id}`} type="checkbox" checked={!set.has(c.id)} onChange={(e) => toggle(c.id, e.target.checked)} />
              <span>{c.label}</span>
            </label>
          ))}
        </fieldset>
      ))}
    </div>
  );
}
