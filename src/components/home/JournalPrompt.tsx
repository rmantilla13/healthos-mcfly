// Home's "Your health journal": an invitation to write today's check-in (#/journal?new=1 opens a new one), or, once
// there is one today (GET /api/journal?days=1), its mood and first line, and an invitation to add another. Journal
// entries are private to the person, and this is their own Home: nothing here is shared or sent anywhere. Its orb
// follows today's readings against your own usual (Summary.standing), and a line says the same in words, so it never
// rests on colour alone.
import { useId } from 'react';
import { type JournalData, MOODS } from '../../../shared/journal.ts';
import type { FamilyReason, Standing } from '../../../shared/types.ts';
import { useApi } from '../../lib.ts';
import { Icon } from '../Icon.tsx';
import { JournalOrb } from '../JournalOrb.tsx';

const NEW_ENTRY = '#/journal?new=1';

const REASON: Record<FamilyReason, string> = { recovery: 'recovery', hrv: 'HRV', resting_hr: 'resting heart rate', sleep: 'sleep' };
/** "recovery", "recovery and sleep", "recovery, resting heart rate and sleep". */
const list = (words: string[]) => (words.length < 2 ? words.join('') : `${words.slice(0, -1).join(', ')} and ${words.at(-1)}`);

/** What the orb shows, in words: today's readings against your own last 30 days, the Family board's rule. */
export function standingWords(s: Standing): string {
  const off = list(s.reasons.map((r) => REASON[r]));
  switch (s.status) {
    case 'good':
      return 'Your readings are within your usual.';
    case 'off':
      return `Off your usual: ${off}.`;
    case 'check':
      return `Off your usual: ${off}. A good day to check in.`;
    case 'learning':
      return 'Still learning your usual.';
    case 'quiet':
      return 'No recent readings to go by.';
  }
}

export function JournalPromptCard({ standing }: { standing?: Standing }) {
  const titleId = useId();
  const { data } = useApi<JournalData>('/journal?days=1');
  // Newest first, so the first of today's is the latest.
  const latest = data?.entries.find((e) => e.date === data.today) ?? null;
  const mood = latest?.mood ? MOODS.find((m) => m.value === latest.mood)?.label : null;
  const firstLine = latest?.text.split('\n').find((l) => l.trim())?.trim() ?? '';
  return (
    <section className="card metric-blush home-journal" aria-labelledby={titleId}>
      <JournalOrb state={standing?.status} />
      <div className="home-journal-text">
        <p className="home-journal-eyebrow">Your health journal</p>
        <h2 id={titleId}>How are you feeling today?</h2>
        {latest ? (
          <p className="home-journal-latest">
            {mood && <span className="badge badge-sage">{mood}</span>}
            <span className="home-journal-line">{firstLine || `A check-in at ${latest.time}`}</span>
          </p>
        ) : (
          <p className="home-journal-sub">A thought, a feeling, a little context.</p>
        )}
        {standing && <p className="home-journal-standing">{standingWords(standing)}</p>}
      </div>
      <a className="pill home-journal-btn" href={NEW_ENTRY}>
        {latest ? 'Add another' : 'Write a check-in'}
        <Icon name="arrow-up-right" size={14} />
      </a>
    </section>
  );
}
