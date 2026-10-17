// Ask McFly: a chat about your own data. Answers stream in from /api/mcfly/chat (server-sent events),
// with a line for each piece of data McFly reads. The conversation lives only in this browser tab.
import { Fragment, useEffect, useRef, useState } from 'react';
import type { McflyStatus, McflyTurn, SessionUser } from '../../shared/types.ts';
import { Icon } from '../components/Icon.tsx';
import { ShinyText } from '../components/ShinyText.tsx';
import { useApi } from '../lib.ts';

type Msg = { role: 'user' | 'assistant'; content: string; steps?: string[]; error?: string; pending?: boolean };

const SUGGESTIONS = [
  'How did I sleep this week compared with last week?',
  'Is my resting heart rate trending up or down?',
  'What does my HRV say about my recovery lately?',
  'How active was I this month?',
  'When do I usually go to bed and wake up?',
];

const storageKey = (userId: string) => `healthos-mcfly:${userId}`;
const touch = () => matchMedia('(pointer: coarse)').matches;

function load(userId: string): Msg[] {
  try {
    const raw = sessionStorage.getItem(storageKey(userId));
    const msgs = raw ? (JSON.parse(raw) as Msg[]) : [];
    // An answer that was still streaming when the page closed can't resume.
    return msgs.map((m) => (m.pending ? { ...m, pending: false, error: m.content ? undefined : 'Interrupted.' } : m));
  } catch {
    return [];
  }
}

function save(userId: string, msgs: Msg[]) {
  try {
    sessionStorage.setItem(storageKey(userId), JSON.stringify(msgs));
  } catch {
    // Storage full or blocked: the chat still works, it just won't survive a reload.
  }
}

/** The history the server needs: question and answer pairs that completed, then the new question. */
function historyFor(msgs: Msg[], question: string): McflyTurn[] {
  const out: McflyTurn[] = [];
  for (let i = 0; i < msgs.length; i++) {
    const m = msgs[i];
    const next = msgs[i + 1];
    if (m.role === 'user' && next?.role === 'assistant' && !next.error && next.content.trim()) {
      out.push({ role: 'user', content: m.content }, { role: 'assistant', content: next.content });
      i++;
    }
  }
  return [...out, { role: 'user', content: question }];
}

export function McFly({ me }: { me: SessionUser }) {
  const { data: status, reload } = useApi<McflyStatus>('/mcfly');
  const [msgs, setMsgs] = useState<Msg[]>(() => load(me.id));
  const [draft, setDraft] = useState('');
  const [busy, setBusy] = useState(false);
  const abort = useRef<AbortController | null>(null);
  const thread = useRef<HTMLDivElement>(null);
  const input = useRef<HTMLTextAreaElement>(null);
  // Follow new text only while the reader is at the bottom; scrolling up to reread stops it.
  const following = useRef(true);
  const [scrolled, setScrolled] = useState(false);

  useEffect(() => {
    save(me.id, msgs);
  }, [me.id, msgs]);
  useEffect(() => {
    const el = thread.current;
    if (el && following.current) el.scrollTop = el.scrollHeight;
  }, [msgs]);

  function onScroll() {
    const el = thread.current;
    if (!el) return;
    following.current = el.scrollHeight - el.scrollTop - el.clientHeight < 80;
    setScrolled(el.scrollTop > 4);
  }
  useEffect(() => () => abort.current?.abort(), []);

  const update = (fn: (last: Msg) => Msg) => setMsgs((ms) => [...ms.slice(0, -1), fn(ms[ms.length - 1])]);

  async function ask(question: string) {
    const q = question.trim();
    if (!q || busy) return;
    const history = historyFor(msgs, q);
    setDraft('');
    setBusy(true);
    following.current = true;
    // On phones, put the keyboard away while the answer comes in.
    if (touch()) input.current?.blur();
    setMsgs((ms) => [...ms, { role: 'user', content: q }, { role: 'assistant', content: '', steps: [], pending: true }]);
    const controller = new AbortController();
    abort.current = controller;
    try {
      const res = await fetch('/api/mcfly/chat', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'X-HealthOS': '1' },
        body: JSON.stringify({ messages: history }),
        signal: controller.signal,
      });
      if (res.status === 401) window.dispatchEvent(new Event('healthos:signin'));
      if (!res.ok || !res.body) {
        const body = (await res.json().catch(() => null)) as { error?: string } | null;
        throw new Error(body?.error ?? 'McFly could not answer right now.');
      }
      const reader = res.body.getReader();
      const decoder = new TextDecoder();
      let buf = '';
      for (;;) {
        const { value, done } = await reader.read();
        if (done) break;
        buf += decoder.decode(value, { stream: true });
        let cut;
        while ((cut = buf.indexOf('\n\n')) >= 0) {
          const chunk = buf.slice(0, cut);
          buf = buf.slice(cut + 2);
          const event = /^event: (.+)$/m.exec(chunk)?.[1];
          const data = /^data: (.+)$/m.exec(chunk)?.[1];
          if (!event || !data) continue;
          const payload = JSON.parse(data) as { text?: string; label?: string; error?: string };
          if (event === 'text') update((m) => ({ ...m, content: m.content + (payload.text ?? '') }));
          else if (event === 'tool') update((m) => ({ ...m, steps: [...(m.steps ?? []), payload.label ?? ''] }));
          // A refusal can arrive after some text: drop the partial answer.
          else if (event === 'refusal') update((m) => ({ ...m, content: '', error: payload.error }));
          else if (event === 'error') update((m) => ({ ...m, error: payload.error }));
        }
      }
    } catch (e) {
      if (controller.signal.aborted) update((m) => ({ ...m, error: m.content ? undefined : 'Stopped.' }));
      else update((m) => ({ ...m, error: (e as Error).message }));
    } finally {
      update((m) => ({ ...m, pending: false, error: m.error ?? (m.content.trim() ? undefined : 'McFly had no answer. Try asking another way.') }));
      abort.current = null;
      setBusy(false);
      reload();
      // Ready for a follow-up on a computer; on a phone, don't pop the keyboard back up uninvited.
      if (!touch()) input.current?.focus();
    }
  }

  const left = status && status.limit > 0 ? Math.max(status.limit - status.usedToday, 0) : null;
  const unavailable = status && (!status.configured ? 'not-configured' : status.limit <= 0 ? 'off' : null);

  return (
    <div className="page mcfly">
      <header className="page-head">
        <div>
          <h1>Ask McFly</h1>
          <p>Questions about your own sleep, recovery, heart and activity. McFly reads your data to answer. It isn't a doctor.</p>
        </div>
        {msgs.length > 0 && (
          <button
            className="btn"
            disabled={busy}
            onClick={() => {
              setMsgs([]);
              input.current?.focus();
            }}
          >
            New chat
          </button>
        )}
      </header>

      {unavailable ? (
        <section className="card">
          <h2>{unavailable === 'off' ? 'Ask McFly is turned off' : "Ask McFly isn't set up yet"}</h2>
          <p className="muted">
            {me.role === 'admin'
              ? unavailable === 'off'
                ? 'Set a daily question limit above 0 in Admin → Settings.'
                : 'Add ANTHROPIC_API_KEY (from the Claude Console) to the Vercel project, then redeploy.'
              : 'Ask the admin to turn it on.'}
          </p>
        </section>
      ) : (
        <>
          <div className={`mcfly-thread-wrap${scrolled ? ' is-scrolled' : ''}`}>
            <div className="mcfly-fade" aria-hidden="true" />
            <div className="mcfly-thread" ref={thread} onScroll={onScroll} aria-live="polite">
              {msgs.length === 0 && (
                <div className="mcfly-empty">
                  <span className="mcfly-mark" aria-hidden="true">
                    <Icon name="spark" size={22} />
                  </span>
                  <p className="muted">Try one of these, or ask your own.</p>
                  <div className="mcfly-suggestions">
                    {SUGGESTIONS.map((s) => (
                      <button key={s} className="chip-btn" onClick={() => ask(s)} disabled={busy || left === 0}>
                        {s}
                      </button>
                    ))}
                  </div>
                </div>
              )}
              {msgs.map((m, i) =>
                m.role === 'user' ? (
                  <div key={i} className="mcfly-q">
                    {m.content}
                  </div>
                ) : (
                  <div key={i} className="mcfly-a">
                    <span className="mcfly-mark" aria-hidden="true">
                      <Icon name="spark" size={16} />
                    </span>
                    <div className="mcfly-body">
                      {(m.steps?.length ?? 0) > 0 && (
                        <ul className="mcfly-steps" aria-label="What McFly looked at">
                          {m.steps!.map((s, j) => {
                            // The step McFly is on shimmers until its answer starts; finished ones get a check.
                            const working = m.pending && !m.content && j === m.steps!.length - 1;
                            return (
                              <li key={j}>
                                {working ? <span className="mcfly-step-ring" aria-hidden="true" /> : <Icon name="check" size={12} />}
                                {working ? <ShinyText>{s}</ShinyText> : s}
                              </li>
                            );
                          })}
                        </ul>
                      )}
                      {m.content && <Answer text={m.content} />}
                      {m.pending && !m.content && !m.steps?.length && <ShinyText className="mcfly-thinking">McFly is thinking…</ShinyText>}
                      {m.error && (
                        <p className="note-bad">
                          <Icon name="alert" size={15} /> {m.error}
                        </p>
                      )}
                    </div>
                  </div>
                ),
              )}
            </div>
          </div>

          <form
            className="card mcfly-composer"
            onSubmit={(e) => {
              e.preventDefault();
              ask(draft);
            }}
          >
            <textarea
              ref={input}
              rows={2}
              maxLength={4000}
              placeholder={left === 0 ? "You've reached today's question limit." : 'Ask about your health data…'}
              value={draft}
              disabled={left === 0}
              onChange={(e) => setDraft(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === 'Enter' && !e.shiftKey && !e.nativeEvent.isComposing) {
                  e.preventDefault();
                  ask(draft);
                }
              }}
              aria-label="Your question"
            />
            <div className="mcfly-composer-row">
              <span className="muted small">{left === null ? '' : `${left} question${left === 1 ? '' : 's'} left today`}</span>
              {busy ? (
                <button type="button" className="btn" onClick={() => abort.current?.abort()}>
                  Stop
                </button>
              ) : (
                <button type="submit" className="btn btn-primary" disabled={!draft.trim() || left === 0}>
                  Ask
                </button>
              )}
            </div>
          </form>
        </>
      )}
    </div>
  );
}

/** McFly's answers use a little Markdown: paragraphs, "- " and "1. " lists, and **bold**. Rendered as elements, never HTML. */
function Answer({ text }: { text: string }) {
  const blocks = text.trim().split(/\n{2,}/);
  return (
    <div className="mcfly-answer">
      {blocks.map((block, i) => {
        const lines = block.split('\n').filter((l) => l.trim());
        if (lines.length && lines.every((l) => /^\s*[-*•]\s+/.test(l))) {
          return (
            <ul key={i}>
              {lines.map((l, j) => (
                <li key={j}>
                  <Inline text={l.replace(/^\s*[-*•]\s+/, '')} />
                </li>
              ))}
            </ul>
          );
        }
        if (lines.length && lines.every((l) => /^\s*\d+[.)]\s+/.test(l))) {
          return (
            <ol key={i}>
              {lines.map((l, j) => (
                <li key={j}>
                  <Inline text={l.replace(/^\s*\d+[.)]\s+/, '')} />
                </li>
              ))}
            </ol>
          );
        }
        return (
          <p key={i}>
            {lines.map((l, j) => (
              <Fragment key={j}>
                {j > 0 && <br />}
                <Inline text={l.replace(/^#+\s+/, '')} />
              </Fragment>
            ))}
          </p>
        );
      })}
    </div>
  );
}

function Inline({ text }: { text: string }) {
  return (
    <>
      {text.split(/(\*\*[^*]+\*\*)/g).map((part, i) =>
        /^\*\*[^*]+\*\*$/.test(part) ? <strong key={i}>{part.slice(2, -2)}</strong> : <Fragment key={i}>{part}</Fragment>,
      )}
    </>
  );
}
