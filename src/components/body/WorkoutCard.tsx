// The Body overview's latest-workout card: that session's figures, the sport's recent sessions, and a few general recovery suggestions.
// Placeholder from the shared scaffold; the workouts builder fills it in.
import type { Summary } from '../../../shared/types.ts';
import { CardHead } from '../../pages/Home.tsx';

export function WorkoutCard({ s: _s, date: _date }: { s: Summary; date: string | null }) {
  return (
    <article className="card metric">
      <CardHead title="Latest workout" to="#/body" />
      <p className="metric-empty">Coming soon.</p>
    </article>
  );
}
