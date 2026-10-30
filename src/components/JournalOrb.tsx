// The journal's art, on Home's journal card and beside the Journal composer: a soft glass orb in the blush family
// (peach, rose, a touch of lavender), drawn in CSS (.journal-orb in styles.css; where it sits is the page's). Its
// colours drift and swirl slowly inside it and its glow breathes; held still under reduced motion. Kept apart from
// McFly's red Orb, so the journal never reads as McFly's.
export function JournalOrb() {
  return (
    <div className="journal-orb-area" aria-hidden="true">
      <div className="journal-orb">
        <span className="journal-orb-halo" />
        <span className="journal-orb-ball">
          <span className="journal-orb-swirl">
            <span className="journal-orb-blob" data-blob="rose" />
            <span className="journal-orb-blob" data-blob="peach" />
            <span className="journal-orb-blob" data-blob="lilac" />
            <span className="journal-orb-blob" data-blob="glow" />
          </span>
        </span>
      </div>
    </div>
  );
}
