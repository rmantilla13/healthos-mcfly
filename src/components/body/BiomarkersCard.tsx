// The Body overview's key biomarkers card: the latest lab results against each lab's own range.
// Placeholder from the shared scaffold; the lab tests builder fills it in.
import type { Summary } from '../../../shared/types.ts';
import { CardHead } from '../../pages/Home.tsx';

export function BiomarkersCard({ s: _s, date: _date }: { s: Summary; date: string | null }) {
  return (
    <article className="card metric">
      <CardHead title="Key biomarkers" to="#/body" />
      <p className="metric-empty">Coming soon.</p>
    </article>
  );
}
