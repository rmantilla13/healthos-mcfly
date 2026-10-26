// Home's "Your health journal": an invitation to write today's check-in (#/journal?new=1 opens a new one), or, once
// there is one today (GET /api/journal?days=1), its mood and first line, and an invitation to add another. Journal
// entries are private to the person, and this is their own Home: nothing here is shared or sent anywhere.
import { useId } from 'react';
import { type JournalData, MOODS } from '../../../shared/journal.ts';
import { useApi } from '../../lib.ts';
import { Icon } from '../Icon.tsx';

const NEW_ENTRY = '#/journal?new=1';

export function JournalPromptCard() {
  const titleId = useId();
  const { data } = useApi<JournalData>('/journal?days=1');
  // Newest first, so the first of today's is the latest.
  const latest = data?.entries.find((e) => e.date === data.today) ?? null;
  const mood = latest?.mood ? MOODS.find((m) => m.value === latest.mood)?.label : null;
  const firstLine = latest?.text.split('\n').find((l) => l.trim())?.trim() ?? '';
  return (
    <section className="card metric-blush home-journal" aria-labelledby={titleId}>
      <img className="home-journal-art" src="/figures/journal-gut.webp" alt="" aria-hidden="true" />
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
      </div>
      <a className="pill home-journal-btn" href={NEW_ENTRY}>
        {latest ? 'Add another' : 'Write a check-in'}
        <Icon name="arrow-up-right" size={14} />
      </a>
    </section>
  );
}
