// Rows of dashboard cards that leave out the ones a person hid (Settings → Cards).
import { type CSSProperties, Fragment, type ReactNode } from 'react';
import { CARDS, type CardPage, fillColumns } from '../../shared/cards.ts';
import { href, useCardShown, useCardsKnown } from '../lib.ts';

/** A row that lays out from how many of its cards show: the most columns it takes on a wide screen and a medium one. */
export type Fill = {
  wide: number;
  mid: number;
  /** At most this many on a small screen (≤1080px), when it's fewer than `mid`. */
  small?: number;
  /** Sleep's wide layout beside the figure: two columns, without this card (the figure shows it instead). */
  hero?: { without: string };
};

/**
 * A row of cards, each with its id, minus the hidden ones. Nothing at all when every one is hidden (so no empty
 * row or gap is left). A `pair` (two side by side) with one left shows it full width. A `fill` row picks its
 * columns from how many cards are left, as evenly as they go, and a short last row stretches to fill.
 */
export function CardRow({ className, cards, pair, fill }: { className: string; cards: [id: string, card: ReactNode][]; pair?: boolean; fill?: Fill }) {
  const shown = useCardShown();
  const visible = cards.filter(([id]) => shown(id));
  if (!visible.length) return null;
  const n = visible.length;
  const style = fill
    ? ({
        '--cols-wide': fillColumns(n, fill.wide),
        '--cols-mid': fillColumns(n, fill.mid),
        ...(fill.small ? { '--cols-small': fillColumns(n, fill.small) } : {}),
        ...(fill.hero ? { '--cols-hero': fillColumns(n - (visible.some(([id]) => id === fill.hero!.without) ? 1 : 0), 2) } : {}),
      } as CSSProperties)
    : undefined;
  const classes = [className, pair && n === 1 ? 'is-single' : '', fill ? 'fill-row' : ''].filter(Boolean).join(' ');
  return (
    <div className={classes} style={style}>
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
