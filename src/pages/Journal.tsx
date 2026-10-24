// Journal (#/journal): your private health journal. A stand-in until the journal itself is built on
// shared/journal.ts and server/journal.ts; the line at the top is the page's loading line, as the real page shows it.
import type { Status } from '../../shared/types.ts';
import { Icon } from '../components/Icon.tsx';

export function Journal({ status: _status }: { status: Status }) {
  return (
    <div className="page page-wide journal-page">
      <p className="page-loading">Opening your private journal…</p>
      <section className="card journal-placeholder">
        <Icon name="journal" size={20} />
        <h2>Your health journal</h2>
        <p className="muted">A thought, a feeling, a little context. Check-ins you write here stay private to you.</p>
      </section>
    </div>
  );
}
