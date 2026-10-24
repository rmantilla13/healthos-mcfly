// Profile's two AI sheets. Chatbot ("Manage chatbot AI"): which AI answers Ask McFly, and your own key for it.
// OpenAI · Nutrition & portraits ("Connect AI key"): your OpenAI key for meal photos, descriptions, voice notes and
// portraits. A key is sent once, to be checked with its provider and stored encrypted (server/ai/routes.ts); nothing
// here keeps it, and the server only ever sends back its last 4 characters.
import '../../styles/ai.css';
import { type FormEvent, type ReactNode, useEffect, useId, useState } from 'react';
import { AI_PROVIDERS, type AiKeyInfo, type AiProvider, type AiStatus, type ChatChoice } from '../../../shared/ai.ts';
import { getJson, notifyDataChanged, sendJson } from '../../lib.ts';
import { Icon } from '../Icon.tsx';
import { Orb } from '../Orb.tsx';
import { Sheet } from '../Sheet.tsx';

const LABEL: Record<AiProvider, string> = { openai: 'OpenAI', anthropic: 'Claude', gemini: 'Gemini' };
/** Who receives the questions, by name. */
const COMPANY: Record<AiProvider, string> = { openai: 'OpenAI', anthropic: 'Anthropic', gemini: 'Google' };

const NOT_HERE = "Storing your own AI keys isn't set up on this server.";

/** What the server last saw of a stored key, as a kind (keys.ts noteKeyUse). */
const PROBLEM: Record<string, string> = {
  auth: "This key didn't work the last time it was used. Replace it, or check it with the provider.",
  quota: 'Its account was out of credit the last time it was used.',
  unreadable: "This key can't be read any more, because the server's data key changed. Paste it again.",
};

type Note = { ok: boolean; text: string } | null;

function useAiStatus() {
  const [status, setStatus] = useState<AiStatus | null>(null);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    let live = true;
    getJson<AiStatus>('/ai').then(
      (s) => live && setStatus(s),
      (e: Error) => live && setError(e.message),
    );
    return () => {
      live = false;
    };
  }, []);
  return { status, setStatus, error };
}

/** The line at the top: what Ask McFly uses right now. */
function usingLine(s: AiStatus) {
  const c = s.chat;
  if (!c) return s.byok ? "Ask McFly isn't available yet. Connect a key below to use it." : "Ask McFly isn't set up on this server yet.";
  if (c.source === 'shared') return "Using healthOS's shared Claude";
  const last4 = s.keys.find((k) => k.provider === c.provider)?.last4;
  return `Using your ${LABEL[c.provider]} key${last4 ? ` ending ${last4}` : ''}`;
}

/** Where a question goes on each choice. */
function whereLine(pick: ChatChoice) {
  if (pick === 'shared') return "Your questions, and the data McFly reads to answer them, go to Anthropic on healthOS's key, within the daily question limit.";
  return `Your questions, and the data McFly reads to answer them, go to ${COMPANY[pick]} on your key, under your own agreement with them. They don't count toward healthOS's daily limit.`;
}

/** The masked field a key is pasted into. Never remembered by the browser or a password manager. */
function KeyField({ provider, value, onChange, autoFocus }: { provider: AiProvider; value: string; onChange: (v: string) => void; autoFocus?: boolean }) {
  return (
    <label className="ai-field">
      <span>Your {LABEL[provider]} API key</span>
      <input
        type="password"
        name={`ai-key-${provider}`}
        autoComplete="off"
        autoCapitalize="off"
        autoCorrect="off"
        spellCheck={false}
        data-1p-ignore=""
        data-lpignore="true"
        placeholder="Paste your key"
        value={value}
        autoFocus={autoFocus}
        onChange={(e) => onChange(e.target.value)}
      />
    </label>
  );
}

/** A stored key: the last 4 characters, what the server last saw of it, and Replace / Remove. */
function Connected({ info, onReplace, onRemove, busy }: { info: AiKeyInfo; onReplace: () => void; onRemove: () => void; busy: boolean }) {
  return (
    <div className="ai-connected">
      <div className="ai-connected-text">
        {info.lastError ? (
          <span className="badge badge-peach">
            <Icon name="alert" size={11} strokeWidth={2} />
            Needs attention
          </span>
        ) : (
          <span className="ai-ok" aria-hidden="true">
            <Icon name="check" size={12} strokeWidth={2.2} />
          </span>
        )}
        <span>
          {info.lastError ? 'Key' : 'Connected · key'} ending <strong className="ai-last4">{info.last4}</strong>
        </span>
      </div>
      <div className="ai-connected-actions">
        <button type="button" className="btn" onClick={onReplace} disabled={busy}>
          Replace
        </button>
        <button type="button" className="btn btn-quiet ai-remove" onClick={onRemove} disabled={busy}>
          Remove key
        </button>
      </div>
      {info.lastError && PROBLEM[info.lastError] && <p className="ai-problem">{PROBLEM[info.lastError]}</p>}
    </div>
  );
}

/** "Remove your key?" before it goes. */
function ConfirmRemove({ provider, consequence, onRemove, onKeep, busy }: { provider: AiProvider; consequence: string; onRemove: () => void; onKeep: () => void; busy: boolean }) {
  return (
    <div className="ai-confirm" role="group" aria-label={`Remove your ${LABEL[provider]} key`}>
      <p>
        Remove your {LABEL[provider]} key from healthOS? {consequence} You can connect it again anytime.
      </p>
      <div className="btn-row">
        <button type="button" className="btn ai-danger" onClick={onRemove} disabled={busy}>
          {busy ? 'Removing…' : 'Remove key'}
        </button>
        {/* Focus lands on the safe choice, in place of the button that opened this. */}
        <button type="button" className="btn btn-quiet" onClick={onKeep} disabled={busy} autoFocus>
          Keep it
        </button>
      </div>
    </div>
  );
}

function Feedback({ note }: { note: Note }) {
  return (
    <p className={`ai-feedback ${note ? (note.ok ? 'note-good' : 'note-bad') : ''}`} role="status" aria-live="polite">
      {note && <Icon name={note.ok ? 'check' : 'alert'} size={15} />}
      {note?.text}
    </p>
  );
}

function StatusLine({ status }: { status: AiStatus }) {
  return (
    <div className="ai-using">
      <Orb size={20} />
      <div>
        <strong>{usingLine(status)}</strong>
        {status.chat && <span className="muted small">{status.chat.model}</span>}
      </div>
    </div>
  );
}

function Loading({ error }: { error: string | null }) {
  return error ? <p className="note-bad">{error}</p> : <p className="muted">Loading…</p>;
}

/** Turns off storing keys: what happens instead. */
function NotHere({ children }: { children: ReactNode }) {
  return (
    <div className="ai-not-here">
      <Icon name="shield" size={18} />
      <div>
        <p>
          <strong>{NOT_HERE}</strong>
        </p>
        {children && <p className="muted">{children}</p>}
      </div>
    </div>
  );
}

// ---------- Chatbot ----------

export function ChatbotSheet({ onClose }: { onClose: () => void }) {
  const { status, setStatus, error } = useAiStatus();
  const [pick, setPick] = useState<ChatChoice | null>(null);
  const [key, setKey] = useState('');
  const [model, setModel] = useState('');
  const [replacing, setReplacing] = useState(false);
  const [removing, setRemoving] = useState(false);
  const [busy, setBusy] = useState(false);
  const [note, setNote] = useState<Note>(null);
  const formId = useId();

  const stored = (p: ChatChoice | null) => (p && p !== 'shared' ? status?.keys.find((k) => k.provider === p) : undefined);

  // Open on what the chat uses now: the person's choice, else the shared assistant, else the first provider.
  useEffect(() => {
    if (status && pick === null) choose(status.chatChoice !== 'shared' || status.shared || !status.byok ? status.chatChoice : 'openai', status);
  }, [status]);

  function choose(p: ChatChoice, s = status) {
    setPick(p);
    setKey('');
    setReplacing(false);
    setRemoving(false);
    setNote(null);
    setModel((p !== 'shared' && s?.keys.find((k) => k.provider === p)?.model) || '');
  }

  async function run(label: string, work: () => Promise<AiStatus>) {
    setBusy(true);
    setNote(null);
    try {
      const next = await work();
      setStatus(next);
      setKey('');
      setReplacing(false);
      setRemoving(false);
      setNote({ ok: true, text: label });
      notifyDataChanged();
    } catch (e) {
      setNote({ ok: false, text: (e as Error).message });
    } finally {
      setBusy(false);
    }
  }

  if (!status || !pick) {
    return (
      <Sheet eyebrow="Chatbot" title="Manage chatbot AI" onClose={onClose} size="md">
        <Loading error={error} />
      </Sheet>
    );
  }

  const info = stored(pick);
  const entering = pick !== 'shared' && (!info || replacing);
  const modelChanged = Boolean(info) && model.trim() !== (info?.model ?? '');
  const isCurrent = pick === status.chatChoice;

  async function save(e?: FormEvent) {
    e?.preventDefault();
    if (busy || !pick) return;
    if (pick === 'shared') return run("Ask McFly now uses healthOS's shared Claude.", () => sendJson<AiStatus>('PUT', '/ai/chat', { provider: 'shared' }));
    const p = pick;
    if (entering) {
      if (!key.trim()) return;
      return run(`Saved. Ask McFly now uses your ${LABEL[p]} key.`, async () => {
        await sendJson('PUT', `/ai/keys/${p}`, { key: key.trim(), model: model.trim() || null });
        return sendJson<AiStatus>('PUT', '/ai/chat', { provider: p });
      });
    }
    return run(isCurrent ? 'Saved.' : `Ask McFly now uses your ${LABEL[p]} key.`, async () => {
      if (modelChanged) await sendJson('PUT', `/ai/keys/${p}`, { model: model.trim() || null });
      return sendJson<AiStatus>('PUT', '/ai/chat', { provider: p });
    });
  }

  const primary =
    pick === 'shared' ? (
      <button type="submit" form={formId} className="btn btn-primary" disabled={busy || isCurrent}>
        {isCurrent ? 'In use' : 'Use the shared assistant'}
      </button>
    ) : entering ? (
      <button type="submit" form={formId} className="btn btn-primary" disabled={busy || !key.trim()}>
        {busy ? `Checking with ${LABEL[pick]}…` : 'Verify & save'}
      </button>
    ) : (
      <button type="submit" form={formId} className="btn btn-primary" disabled={busy || (isCurrent && !modelChanged)}>
        {isCurrent ? 'Save' : `Use ${LABEL[pick]}`}
      </button>
    );

  return (
    <Sheet
      eyebrow="Chatbot"
      title="Manage chatbot AI"
      onClose={onClose}
      size="md"
      footer={
        status.byok ? (
          <>
            <button type="button" className="btn btn-quiet" onClick={onClose}>
              Close
            </button>
            {primary}
          </>
        ) : (
          <button type="button" className="btn btn-primary" onClick={onClose}>
            Done
          </button>
        )
      }
    >
      <StatusLine status={status} />
      {!status.byok ? (
        <NotHere>{status.shared && "Ask McFly answers with healthOS's shared Claude key, within its daily question limit."}</NotHere>
      ) : (
        <form id={formId} className="ai-form" onSubmit={save} aria-busy={busy}>
          <fieldset className="ai-choices" disabled={busy}>
            <legend>Who answers Ask McFly</legend>
            {AI_PROVIDERS.map(({ provider }) => (
              <Choice key={provider} value={provider} name={LABEL[provider]} checked={pick === provider} onChange={() => choose(provider)} connected={Boolean(stored(provider))} />
            ))}
            {status.shared && <Choice value="shared" name="healthOS shared" sub="Claude" checked={pick === 'shared'} onChange={() => choose('shared')} />}
          </fieldset>

          {pick !== 'shared' && info && !replacing && !removing && <Connected info={info} busy={busy} onReplace={() => setReplacing(true)} onRemove={() => setRemoving(true)} />}
          {pick !== 'shared' && info && removing && (
            <ConfirmRemove
              provider={pick}
              busy={busy}
              consequence={status.chatChoice === pick ? (status.shared ? "Ask McFly goes back to healthOS's shared Claude." : 'Ask McFly stops until you connect a key.') : ''}
              onKeep={() => setRemoving(false)}
              onRemove={() => run(`Your ${LABEL[pick]} key is removed.`, () => sendJson<AiStatus>('DELETE', `/ai/keys/${pick}`))}
            />
          )}
          {entering && <KeyField provider={pick} value={key} onChange={setKey} autoFocus={replacing} />}
          {pick !== 'shared' && !removing && (
            <label className="ai-field">
              <span>
                Model <span className="muted">(optional)</span>
              </span>
              <input value={model} maxLength={100} spellCheck={false} autoCapitalize="off" placeholder="The default model" onChange={(e) => setModel(e.target.value)} />
            </label>
          )}

          <div className="ai-where">
            <Icon name="shield" size={16} />
            <div>
              <p>{whereLine(pick)}</p>
              {pick === 'gemini' && <p className="ai-tip">Use a paid-tier key: Google may use free-tier content to improve its products.</p>}
            </div>
          </div>
          <Feedback note={note} />
        </form>
      )}
    </Sheet>
  );
}

function Choice({ value, name, sub, checked, onChange, connected }: { value: ChatChoice; name: string; sub?: string; checked: boolean; onChange: () => void; connected?: boolean }) {
  return (
    <label className={`ai-choice${checked ? ' is-on' : ''}`}>
      <input type="radio" name="ai-chat-provider" value={value} checked={checked} onChange={onChange} />
      <span className="ai-choice-name">{name}</span>
      {sub && <span className="ai-choice-sub">{sub}</span>}
      {connected && <span className="badge badge-sage">Key added</span>}
    </label>
  );
}

// ---------- OpenAI · Nutrition & portraits ----------

export function OpenAIKeySheet({ onClose }: { onClose: () => void }) {
  const { status, setStatus, error } = useAiStatus();
  const [key, setKey] = useState('');
  const [replacing, setReplacing] = useState(false);
  const [removing, setRemoving] = useState(false);
  const [busy, setBusy] = useState(false);
  const [note, setNote] = useState<Note>(null);
  const formId = useId();

  async function run(label: string, work: () => Promise<AiStatus>) {
    setBusy(true);
    setNote(null);
    try {
      setStatus(await work());
      setKey('');
      setReplacing(false);
      setRemoving(false);
      setNote({ ok: true, text: label });
      notifyDataChanged();
    } catch (e) {
      setNote({ ok: false, text: (e as Error).message });
    } finally {
      setBusy(false);
    }
  }

  const info = status?.keys.find((k) => k.provider === 'openai');
  const entering = !info || replacing;

  function save(e?: FormEvent) {
    e?.preventDefault();
    if (busy || !key.trim()) return;
    run('Connected. Meal photos, descriptions and voice notes now use your OpenAI key.', () => sendJson<AiStatus>('PUT', '/ai/keys/openai', { key: key.trim() }));
  }

  /** What runs instead while no key of their own is connected. */
  function instead(s: AiStatus) {
    const meals =
      s.estimate?.source === 'own' && s.estimate.provider === 'anthropic'
        ? 'Until then, meal estimates use your Claude key.'
        : s.estimate
          ? "Until then, meal estimates use healthOS's shared Claude."
          : s.byok
            ? 'Meal estimates need this key, or a Claude key in Chatbot.'
            : "Meal estimates aren't set up on this server.";
    const voice = s.voice ? "Voice notes and portraits use the server's OpenAI key." : s.byok ? 'Voice notes and portraits need this key.' : "Voice notes and portraits aren't set up on this server.";
    return `${meals} ${voice}`;
  }

  return (
    <Sheet
      eyebrow="OpenAI · Nutrition & portraits"
      title="Connect AI key"
      onClose={onClose}
      size="sm"
      footer={
        status?.byok && entering ? (
          <>
            <button type="button" className="btn btn-quiet" onClick={() => (replacing ? setReplacing(false) : onClose())}>
              {replacing ? 'Cancel' : 'Close'}
            </button>
            <button type="submit" form={formId} className="btn btn-primary" disabled={busy || !key.trim()}>
              {busy ? 'Checking with OpenAI…' : 'Verify & save'}
            </button>
          </>
        ) : (
          <button type="button" className="btn btn-primary" onClick={onClose}>
            Done
          </button>
        )
      }
    >
      {!status ? (
        <Loading error={error} />
      ) : !status.byok ? (
        <NotHere>{instead(status)}</NotHere>
      ) : (
        <form id={formId} className="ai-form" onSubmit={save} aria-busy={busy}>
          <p className="ai-lede">Your own OpenAI API key, for meal photos and descriptions, voice notes and portraits.</p>
          {info && !replacing && !removing && <Connected info={info} busy={busy} onReplace={() => setReplacing(true)} onRemove={() => setRemoving(true)} />}
          {info && removing && (
            <ConfirmRemove
              provider="openai"
              busy={busy}
              consequence={status.chatChoice === 'openai' ? (status.shared ? "Ask McFly goes back to healthOS's shared Claude too." : 'Ask McFly stops too, until you connect a key.') : ''}
              onKeep={() => setRemoving(false)}
              onRemove={() => run('Your OpenAI key is removed.', () => sendJson<AiStatus>('DELETE', '/ai/keys/openai'))}
            />
          )}
          {entering && <KeyField provider="openai" value={key} onChange={setKey} autoFocus={replacing} />}
          {!info && <p className="muted small">{instead(status)}</p>}
          <div className="ai-where">
            <Icon name="shield" size={16} />
            <div>
              <p>
                Meal photos, descriptions and voice notes go to OpenAI on your key, for that one request, and aren't kept by healthOS. Estimates on your key don't count toward
                healthOS's daily limit.
              </p>
              <p>Portrait photos stay in your account, seen only by you and sent only to your own OpenAI key, until you delete them.</p>
              <p className="muted">Choose OpenAI in Chatbot to use this same key for Ask McFly.</p>
            </div>
          </div>
          <Feedback note={note} />
        </form>
      )}
    </Sheet>
  );
}
