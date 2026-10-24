// The portrait studio, in Profile → Your portrait photos: reference photos of you, and likenesses made from them in the
// healthOS style on OpenAI (server/portraits.ts). A reference stays private: only you can open it, and it's sent to
// OpenAI only when you make a portrait from it. Nothing made here reaches the dashboard until you choose it with
// "Use this portrait", which cuts it out on this device and saves it as your profile photo (src/portraits.ts).
import '../../styles/portraits.css';
import { useEffect, useId, useRef, useState } from 'react';
import type { AiStatus } from '../../../shared/ai.ts';
import { MAX_REFERENCES, type Portrait, type PortraitCreated, type PortraitList } from '../../../shared/portraits.ts';
import type { Status } from '../../../shared/types.ts';
import { notifyDataChanged, sendJson, useApi } from '../../lib.ts';
import { isImageFile, makeProfilePhoto, portraitImage, shrinkReference, uploadReference } from '../../portraits.ts';
import { Icon } from '../Icon.tsx';

/** How often the list is checked while a portrait is being made. */
const POLL_MS = 3500;

const added = (ms: number) => new Date(ms).toLocaleDateString(undefined, { month: 'short', day: 'numeric' });

export function PortraitStudio({ status, reload }: { status: Status; reload: () => void }) {
  const { data, error: loadError, reload: reloadList } = useApi<PortraitList>('/portraits');
  const { data: ai } = useApi<AiStatus>('/ai');
  const [busy, setBusy] = useState<string | null>(null);
  const [note, setNote] = useState<string | null>(null);
  const [using, setUsing] = useState<{ id: string; step: string } | null>(null);
  const [failed, setFailed] = useState<{ id: string; text: string } | null>(null);
  const input = useRef<HTMLInputElement>(null);
  const keyNoteId = useId();

  const portraits = data?.portraits ?? [];
  const references = portraits.filter((p) => p.kind === 'reference');
  const made = portraits.filter((p) => p.kind === 'generated');
  const making = made.some((p) => p.status === 'pending');
  const orphans = made.filter((p) => !references.some((r) => r.id === p.referenceId));

  // While one is being made, check now and then; the server says ready or failed.
  useEffect(() => {
    if (!making) return;
    const timer = setInterval(reloadList, POLL_MS);
    return () => clearInterval(timer);
  }, [making, reloadList]);

  /** After a change: this list, and Profile's count and status. */
  const changed = () => {
    reloadList();
    reload();
  };

  async function act(what: string, work: () => Promise<unknown>) {
    setBusy(what);
    setNote(null);
    try {
      await work();
      changed();
    } catch (e) {
      setNote((e as Error).message);
    } finally {
      setBusy(null);
    }
  }

  async function add(file: File | undefined) {
    if (!file) return;
    if (!isImageFile(file)) return setNote('Choose an image file (JPEG or PNG).');
    await act('add', async () => {
      const shrunk = await shrinkReference(file).catch(() => {
        throw new Error("That photo couldn't be opened here. Try a JPEG or PNG.");
      });
      await uploadReference(shrunk.input);
    });
  }

  const make = (ref: Portrait) => act(`make:${ref.id}`, () => sendJson<PortraitCreated>('POST', '/portraits/generate', { referenceId: ref.id }));

  function remove(p: Portrait) {
    const question =
      p.kind === 'reference'
        ? 'Delete this reference photo? Portraits already made from it stay until you delete them. It can’t be undone.'
        : p.id === data?.chosen
          ? 'Delete this portrait? Your profile photo made from it stays; you can remove that under “Use a photo as is”.'
          : 'Delete this portrait? It can’t be undone.';
    if (!confirm(question)) return;
    void act(`delete:${p.id}`, () => sendJson('DELETE', `/portraits/${encodeURIComponent(p.id)}`));
  }

  async function use(p: Portrait) {
    if (status.photo && !confirm('Use this portrait as your profile photo? It replaces the photo you have now on Home, Body and your avatar.')) return;
    setFailed(null);
    setUsing({ id: p.id, step: 'Loading your portrait…' });
    try {
      await makeProfilePhoto(p, (step) => setUsing({ id: p.id, step }));
      changed();
      notifyDataChanged();
    } catch (e) {
      setFailed({ id: p.id, text: (e as Error).message });
    } finally {
      setUsing(null);
    }
  }

  const ownKey = Boolean(ai?.keys.some((k) => k.provider === 'openai'));
  const canGenerate = data?.canGenerate ?? false;
  // Honest about whose OpenAI account a reference goes to: the person's own key, or this server's.
  const intro = canGenerate
    ? ownKey
      ? 'Your reference photos are kept in your healthOS account, where only you can open them. One goes to OpenAI, on your own key, only when you make a portrait from it.'
      : 'Your reference photos are kept in your healthOS account, where only you can open them. One goes to OpenAI, on this healthOS server’s key, only when you make a portrait from it.'
    : 'Your reference photos are kept in your healthOS account, where only you can open them. Making a portrait sends one to OpenAI on your own key.';
  const keyNote = !data || canGenerate ? null : ai && !ai.byok ? 'Making a portrait needs an OpenAI key, and storing your own key isn’t available on this server.' : 'Connect your OpenAI key in your Profile (OpenAI · Nutrition & portraits, above) to make a portrait.';
  const full = references.length >= MAX_REFERENCES;

  const tiles = (list: Portrait[]) =>
    list.length > 0 && (
      <ul className="portrait-grid">
        {list.map((p) => (
          <PortraitTile
            key={p.id}
            p={p}
            chosen={p.id === data?.chosen}
            using={using?.id === p.id ? using.step : null}
            failed={failed?.id === p.id ? failed.text : null}
            locked={busy !== null || using !== null}
            onUse={() => void use(p)}
            onDelete={() => remove(p)}
          />
        ))}
      </ul>
    );

  return (
    <section className="portrait-studio" aria-labelledby="portrait-studio-title">
      <div className="portrait-studio-head">
        <div className="portrait-studio-text">
          <h3 id="portrait-studio-title">Portrait studio</h3>
          <p>{intro} Nothing you make here appears on your dashboard until you choose it.</p>
        </div>
        <button type="button" className="btn" onClick={() => input.current?.click()} disabled={full || busy !== null || using !== null}>
          <Icon name="plus" size={15} /> {busy === 'add' ? 'Adding…' : 'Add a reference photo'}
        </button>
        <input
          ref={input}
          type="file"
          accept="image/*,.heic,.heif"
          hidden
          onChange={(e) => {
            void add(e.target.files?.[0]);
            // The same file can be chosen again after deleting it.
            e.target.value = '';
          }}
        />
      </div>
      {keyNote && (
        <p className="portrait-key-note" id={keyNoteId}>
          {keyNote}
        </p>
      )}
      {full && <p className="portrait-fine">You have {MAX_REFERENCES} reference photos, the most there can be. Delete one to add another.</p>}
      {note && (
        <p className="note-bad" role="alert">
          <Icon name="alert" size={15} /> {note}
        </p>
      )}
      {loadError && !data && <p className="note-bad">Couldn't load your portrait photos: {loadError.message}</p>}
      {data && references.length === 0 && (
        <div className="portrait-empty">
          <Icon name="camera" size={20} />
          <p>Add a clear photo of just you, ideally head to toe and facing the camera. It’s what your portrait is made from.</p>
        </div>
      )}
      {references.length > 0 && (
        <ul className="portrait-refs">
          {references.map((ref) => {
            const fromIt = made.filter((p) => p.referenceId === ref.id);
            const makingThis = fromIt.some((p) => p.status === 'pending');
            return (
              <li key={ref.id} className="portrait-ref">
                <div className="portrait-ref-head">
                  <img className="portrait-ref-thumb" src={portraitImage(ref)} alt={`Your reference photo from ${added(ref.createdAt)}`} loading="lazy" />
                  <div className="portrait-ref-text">
                    <h4>Reference photo</h4>
                    <p>
                      Added {added(ref.createdAt)} · private to you
                      {fromIt.length > 0 && ` · ${fromIt.length} ${fromIt.length === 1 ? 'portrait' : 'portraits'}`}
                    </p>
                  </div>
                  <div className="portrait-ref-actions">
                    <button
                      type="button"
                      className="btn"
                      onClick={() => void make(ref)}
                      disabled={!canGenerate || making || busy !== null || using !== null}
                      // Why it's disabled, for screen readers too: the key note above.
                      aria-describedby={keyNote ? keyNoteId : undefined}
                      title={keyNote ?? (making ? 'One portrait at a time.' : undefined)}
                    >
                      {busy === `make:${ref.id}` || makingThis ? 'Making…' : 'Make my portrait'}
                    </button>
                    <button
                      type="button"
                      className="btn btn-quiet"
                      onClick={() => remove(ref)}
                      disabled={busy !== null || using !== null}
                      aria-label={`Delete the reference photo from ${added(ref.createdAt)}`}
                    >
                      Delete
                    </button>
                  </div>
                </div>
                {tiles(fromIt)}
              </li>
            );
          })}
        </ul>
      )}
      {orphans.length > 0 && (
        <div className="portrait-orphans">
          <h4>From reference photos you’ve deleted</h4>
          {tiles(orphans)}
        </div>
      )}
    </section>
  );
}

type TileProps = { p: Portrait; chosen: boolean; using: string | null; failed: string | null; locked: boolean; onUse: () => void; onDelete: () => void };

function PortraitTile({ p, chosen, using, failed, locked, onUse, onDelete }: TileProps) {
  const when = added(p.createdAt);
  return (
    <li className={`portrait-tile is-${p.status}${chosen ? ' is-chosen' : ''}`}>
      <div className="portrait-tile-art">
        {p.status === 'ready' ? (
          <img src={portraitImage(p)} alt={`Your portrait from ${when}`} loading="lazy" />
        ) : p.status === 'pending' ? (
          <span className="portrait-making" aria-hidden="true" />
        ) : (
          <Icon name="alert" size={20} />
        )}
        {chosen && <span className="badge badge-sage portrait-in-use">In use</span>}
      </div>
      <div className="portrait-tile-foot">
        {p.status === 'pending' && (
          <p className="portrait-tile-state" role="status">
            Making your portrait… this can take a minute
          </p>
        )}
        {p.status === 'failed' && <p className="portrait-tile-state is-bad">{p.error || 'This portrait couldn’t be made. Try again.'}</p>}
        {using && (
          <p className="portrait-tile-state" role="status">
            {using}
          </p>
        )}
        {failed && (
          <p className="portrait-tile-state is-bad" role="alert">
            {failed}
          </p>
        )}
        <div className="portrait-tile-actions">
          {p.status === 'ready' && !chosen && (
            <button type="button" className="btn btn-primary" onClick={onUse} disabled={locked}>
              {using ? 'Using…' : 'Use this portrait'}
            </button>
          )}
          <button type="button" className="btn btn-quiet" onClick={onDelete} disabled={locked} aria-label={`Delete the portrait from ${when}`}>
            Delete
          </button>
        </div>
      </div>
    </li>
  );
}
