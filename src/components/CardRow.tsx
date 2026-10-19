// Rows of dashboard cards that leave out the ones a person hid (Settings → Cards).
import { Fragment, type ReactNode } from 'react';
import { CARDS, type CardPage } from '../../shared/cards.ts';
import { href, useCardShown, useCardsKnown } from '../lib.ts';

/**
 * A grid of cards, each with its id, minus the hidden ones. Nothing at all when every one is hidden. A `pair`
 * (two side by side) with one left shows it full width.
 */
export function CardRow({ className, cards, pair }: { className: string; cards: [id: string, card: ReactNode][]; pair?: boolean }) {
  const shown = useCardShown();
  const visible = cards.filter(([id]) => shown(id));
  if (!visible.length) return null;
  return (
    <div className={pair && visible.length === 1 ? `${className} is-single` : className}>
      {visible.map(([id, card]) => (
        <Fragment key={id}>{card}</Fragment>
      ))}
    </div>
  );
}

/** Every card on this page is hidden (known only once the person's settings have loaded). */
export function useAllHidden(page: CardPage) {
  const shown = useCardShown();
  const known = useCardsKnown();
  return known && CARDS.filter((c) => c.page === page).every((c) => !shown(c.id));
}

export function AllHiddenNote() {
  return (
    <section className="card all-hidden">
      <p className="muted">
        All the cards on this page are hidden. Choose the ones to show in <a href={href('settings')}>Settings → Cards</a>.
      </p>
    </section>
  );
}
