// The Body overview's glucose card, from Apple Health's glucose readings.
// Placeholder from the shared scaffold; the detail-sheets builder fills it in.
import type { Summary } from '../../../shared/types.ts';
import { CardHead } from '../../pages/Home.tsx';

export function GlucoseCard({ s: _s, date: _date }: { s: Summary; date: string | null }) {
  return (
    <article className="card metric">
      <CardHead title="Glucose" to="#/body" />
      <p className="metric-empty">Coming soon.</p>
    </article>
  );
}
