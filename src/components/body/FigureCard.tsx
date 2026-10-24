// Body's figure card: the figure in the perspective the person chose (their portrait, or the digital woman or man),
// with blood oxygen, breathing and heart pointing at it, a caption that says what it is (artwork, not a scan; a
// portrait, not a measurement), and a way to change it (onboarding, in its edit mode). 'stats' has no card at all.
import type { FigureVariant, Perspective, PhotoMeta, Summary } from '../../../shared/types.ts';
import { href } from '../../lib.ts';
import { Figure, useDrawnVariant } from '../Figure.tsx';
import { Icon } from '../Icon.tsx';

export function FigureCard({ s, photo, perspective, figure }: { s: Summary; photo: PhotoMeta | null; perspective: Perspective; figure: FigureVariant }) {
  const drawn = useDrawnVariant(figure);
  // A portrait without a photo draws the digital human, so it's captioned as one.
  const portrait = perspective === 'portrait' && photo !== null;
  return (
    <section className="card body-figure-card" aria-label="Your figure">
      <div className="body-figure">
        <Figure vitals={s.vitals} asOf={s.date} photo={photo} perspective={perspective} figure={figure} callouts={['spo2', 'breathing', 'heart']} />
      </div>
      <div className="body-figure-caption">
        <p>{portrait ? 'Your portrait · A visual representation, not a measurement' : `Digital ${drawn} · Illustrative artwork · Not a body composition scan`}</p>
        <a href={href('welcome')}>
          Change my representation
          <Icon name="arrow-up-right" size={12} />
        </a>
      </div>
    </section>
  );
}
