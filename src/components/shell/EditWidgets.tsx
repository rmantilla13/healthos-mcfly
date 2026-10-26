// Home's "Edit widgets": which cards Home shows, the optional ones included, in a dialog. The same choices as
// Profile → Cards (one card's change at a time, applied to the lists as stored), for Home only.
import type { Status } from '../../../shared/types.ts';
import { href } from '../../lib.ts';
import { CardChoices, useOwnCardEditor } from '../CardChoices.tsx';
import { Sheet } from '../Sheet.tsx';

export function EditWidgets({ status, reload, onClose }: { status: Status; reload: () => void; onClose: () => void }) {
  const cards = useOwnCardEditor(status.settings, reload);
  return (
    <Sheet
      eyebrow="Home"
      title="Edit widgets"
      size="sm"
      onClose={onClose}
      footer={
        <>
          <a className="btn btn-quiet" href={`${href('profile')}`} onClick={onClose}>
            Every page's cards
          </a>
          <button type="button" className="btn btn-primary" onClick={onClose}>
            Done
          </button>
        </>
      }
    >
      <p className="muted small">Choose what Home shows. Hiding a widget only changes the page; your data stays.</p>
      <CardChoices lists={cards.lists} onToggle={cards.toggle} idPrefix="widgets" nutrition={status.settings.nutrition} page="home" />
      {cards.error && <p className="note-bad small">{cards.error}</p>}
    </Sheet>
  );
}
