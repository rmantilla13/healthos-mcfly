// The journal's art, on Home's journal card and beside the Journal composer: a soft glass orb in the blush family
// (peach, rose, a touch of lavender), drawn in CSS (.journal-orb in styles.css; where it sits is the page's). Its
// colours drift and swirl slowly inside it and its glow breathes; held still under reduced motion. Kept apart from
// McFly's red Orb, so the journal never reads as McFly's. On Home it follows today's readings against your usual
// (`state`, Summary.standing): warm and lively when they're within it, cooler and slower when one is off, calm
// lavender when several are, pale and slow with nothing recent to go by. The card says which in words.
import type { FamilyStatus } from '../../shared/types.ts';

export function JournalOrb({ state }: { state?: FamilyStatus }) {
  return (
    <div className="journal-orb-area" data-state={state} aria-hidden="true">
      <div className="journal-orb">
        <span className="journal-orb-halo" />
        <span className="journal-orb-ball">
          <span className="journal-orb-swirl">
            <span className="journal-orb-blob" data-blob="rose" />
            <span className="journal-orb-blob" data-blob="peach" />
            <span className="journal-orb-blob" data-blob="lilac" />
            <span className="journal-orb-blob" data-blob="glow" />
          </span>
          <span className="journal-orb-veil" />
        </span>
      </div>
    </div>
  );
}
