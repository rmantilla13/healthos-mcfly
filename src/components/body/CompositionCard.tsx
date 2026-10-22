// The Body overview's body composition card: weight, body fat and lean mass with their changes.
// Placeholder from the shared scaffold; the detail-sheets builder fills it in.
import type { Summary } from '../../../shared/types.ts';
import { CardHead } from '../../pages/Home.tsx';

export function CompositionCard({ s: _s, date: _date }: { s: Summary; date: string | null }) {
  return (
    <article className="card metric">
      <CardHead title="Body composition" to="#/body" />
      <p className="metric-empty">Coming soon.</p>
    </article>
  );
}
