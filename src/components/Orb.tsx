// McFly's mark: a glowing red orb (a dark red core into an orange-red rim), drawn in CSS (.orb in styles.css). Used on
// the Ask McFly pill, the nutrition composer and Today's nutrition card; the healthOS brand keeps its sunburst Logo.
// `busy` pulses it gently while McFly works (held still under reduced motion).
import type { CSSProperties } from 'react';

export function Orb({ size = 24, busy = false, className = '' }: { size?: number; busy?: boolean; className?: string }) {
  return <span className={`orb${busy ? ' is-busy' : ''}${className ? ` ${className}` : ''}`} style={{ '--orb-size': `${size}px` } as CSSProperties} aria-hidden="true" />;
}
