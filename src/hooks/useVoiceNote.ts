// Hold to talk: a voice note recorded in the browser (MediaRecorder), sent once to POST /api/ai/transcribe as the raw
// recording, and its words handed back for the person to check. It never sends anything on its own: the words fill the
// composer, and nothing is estimated until the person sends them. The recording is kept only in memory, for that one
// upload (the server forwards it to OpenAI and keeps nothing).
// - Pointer: press to record, let go to stop, at most a minute (a minute or so stays under the 4 MB upload limit).
// - Keyboard: Space or Enter starts, and again stops, since holding a key down isn't something everyone can do.
// - WebM/Opus where the browser can record it (Chrome, Firefox, Edge), else MP4/AAC (Safari). Never Ogg: OpenAI refuses it.
import { type KeyboardEvent, type MouseEvent, type PointerEvent, useCallback, useEffect, useRef, useState } from 'react';
import type { Transcript } from '../../shared/ai.ts';

export type VoiceState = 'idle' | 'starting' | 'recording' | 'transcribing';

const MAX_MS = 60_000;
/** Shorter than this is a tap, not a note. */
const MIN_MS = 500;
const MAX_BYTES = 4 * 1024 * 1024;

function recordingType() {
  if (typeof MediaRecorder === 'undefined') return null;
  for (const t of ['audio/webm;codecs=opus', 'audio/webm', 'audio/mp4']) if (MediaRecorder.isTypeSupported(t)) return t;
  return '';
}

/** A microphone failure in plain words. */
function micProblem(err: unknown) {
  const name = err instanceof DOMException ? err.name : '';
  if (name === 'NotAllowedError' || name === 'SecurityError') return "The microphone is blocked for healthOS. Allow it in your browser's site settings, or type instead.";
  if (name === 'NotFoundError' || name === 'OverconstrainedError') return 'No microphone was found. Type what you had instead.';
  if (name === 'NotReadableError') return 'The microphone is in use by another app. Try again, or type instead.';
  return "The microphone couldn't start. Type what you had instead.";
}

async function transcribe(blob: Blob): Promise<string> {
  // The base type only: the server reads the format from the recording's first bytes anyway.
  const type = (blob.type.split(';')[0] || 'audio/webm').trim();
  let res: Response;
  try {
    res = await fetch('/api/ai/transcribe', { method: 'POST', headers: { 'X-HealthOS': '1', 'Content-Type': type }, body: blob });
  } catch {
    throw new Error("Couldn't reach healthOS. Check your connection and try again.");
  }
  if (res.status === 401) window.dispatchEvent(new Event('healthos:signin'));
  const body = (await res.json().catch(() => null)) as (Transcript & { error?: string }) | null;
  if (!res.ok || typeof body?.text !== 'string') throw new Error(body?.error ?? "That recording couldn't be transcribed. Try again, or type it instead.");
  return body.text;
}

/**
 * The voice button's state and handlers. `onText` gets the words (never called with nothing). `enabled` is false when
 * this person has no OpenAI key to transcribe with: the button stays focusable, records nothing, and a press calls
 * `onBlocked` so the page can say why.
 */
export function useVoiceNote({ enabled, onText, onBlocked }: { enabled: boolean; onText: (text: string) => void; onBlocked?: () => void }) {
  const [state, setStateNow] = useState<VoiceState>('idle');
  const [seconds, setSeconds] = useState(0);
  const [error, setError] = useState<string | null>(null);
  // Mirrors of the state, for handlers that run before React re-renders (a quick second press, a release).
  const current = useRef<VoiceState>('idle');
  const via = useRef<'pointer' | 'key'>('pointer');
  const setState = (s: VoiceState) => {
    current.current = s;
    setStateNow(s);
  };
  const recorder = useRef<MediaRecorder | null>(null);
  const stream = useRef<MediaStream | null>(null);
  const chunks = useRef<Blob[]>([]);
  const startedAt = useRef(0);
  const timer = useRef<ReturnType<typeof setInterval> | null>(null);
  const limit = useRef<ReturnType<typeof setTimeout> | null>(null);
  // Let go before the recorder started (the browser was still asking for the microphone): don't record after all.
  const released = useRef(false);
  const lastKey = useRef(0);
  const text = useRef(onText);
  text.current = onText;
  const alive = useRef(true);

  const cleanUp = useCallback(() => {
    if (timer.current) clearInterval(timer.current);
    if (limit.current) clearTimeout(limit.current);
    timer.current = limit.current = null;
    for (const t of stream.current?.getTracks() ?? []) t.stop();
    stream.current = null;
    recorder.current = null;
  }, []);

  // Leaving the page mid-recording stops the microphone and throws the recording away.
  useEffect(() => {
    alive.current = true;
    return () => {
      alive.current = false;
      const r = recorder.current;
      if (r) r.ondataavailable = r.onstop = null;
      if (r && r.state !== 'inactive') r.stop();
      cleanUp();
    };
  }, [cleanUp]);

  const stop = useCallback(() => {
    released.current = true;
    const r = recorder.current;
    if (r && r.state !== 'inactive') r.stop();
  }, []);

  async function start(how: 'pointer' | 'key') {
    if (current.current !== 'idle') return;
    setError(null);
    via.current = how;
    const type = recordingType();
    if (type === null || !navigator.mediaDevices?.getUserMedia) {
      setError("Voice notes don't work in this browser. Type what you had instead.");
      return;
    }
    released.current = false;
    setState('starting');
    let media: MediaStream;
    try {
      media = await navigator.mediaDevices.getUserMedia({ audio: true });
    } catch (err) {
      if (alive.current) {
        setState('idle');
        setError(micProblem(err));
      }
      return;
    }
    if (!alive.current || (how === 'pointer' && released.current)) {
      for (const t of media.getTracks()) t.stop();
      if (alive.current) {
        setState('idle');
        setError('Hold the button while you talk, then let go.');
      }
      return;
    }
    stream.current = media;
    chunks.current = [];
    let r: MediaRecorder;
    try {
      r = type ? new MediaRecorder(media, { mimeType: type }) : new MediaRecorder(media);
    } catch {
      cleanUp();
      setState('idle');
      setError("Voice notes don't work in this browser. Type what you had instead.");
      return;
    }
    recorder.current = r;
    r.ondataavailable = (e) => {
      if (e.data.size) chunks.current.push(e.data);
    };
    r.onstop = async () => {
      const took = Date.now() - startedAt.current;
      const blob = new Blob(chunks.current, { type: r.mimeType || type || 'audio/webm' });
      chunks.current = [];
      cleanUp();
      if (!alive.current) return;
      setSeconds(0);
      if (took < MIN_MS || !blob.size) {
        setState('idle');
        setError(how === 'pointer' ? 'Hold the button while you talk, then let go.' : 'That was too short to hear anything. Try again.');
        return;
      }
      if (blob.size > MAX_BYTES) {
        setState('idle');
        setError('That recording is too long. Keep voice notes to about a minute.');
        return;
      }
      setState('transcribing');
      try {
        const words = (await transcribe(blob)).trim();
        if (!alive.current) return;
        if (words) text.current(words);
        else setError('No words came through. Try again a little closer to the microphone.');
      } catch (err) {
        if (alive.current) setError((err as Error).message);
      } finally {
        if (alive.current) setState('idle');
      }
    };
    startedAt.current = Date.now();
    r.start();
    setState('recording');
    setSeconds(0);
    timer.current = setInterval(() => setSeconds(Math.floor((Date.now() - startedAt.current) / 1000)), 250);
    limit.current = setTimeout(stop, MAX_MS);
  }

  const toggle = (how: 'pointer' | 'key') => {
    if (current.current === 'recording') stop();
    else if (current.current === 'idle') void start(how);
  };

  /** Spread on the voice button. */
  const bind = {
    onPointerDown: (e: PointerEvent<HTMLButtonElement>) => {
      if (e.button !== 0) return;
      e.preventDefault();
      if (!enabled) return onBlocked?.();
      // A press during a recording started from the keyboard stops it.
      if (current.current === 'recording' && via.current === 'key') return stop();
      // Keep hearing this press even if the finger slides off the button.
      e.currentTarget.setPointerCapture?.(e.pointerId);
      void start('pointer');
    },
    onPointerUp: () => {
      if (via.current === 'pointer') stop();
    },
    onPointerCancel: () => {
      if (via.current === 'pointer') stop();
    },
    onContextMenu: (e: MouseEvent) => e.preventDefault(),
    onKeyDown: (e: KeyboardEvent<HTMLButtonElement>) => {
      if (e.key !== ' ' && e.key !== 'Enter') return;
      e.preventDefault();
      if (e.repeat) return;
      lastKey.current = Date.now();
      if (!enabled) return onBlocked?.();
      toggle('key');
    },
    // Space activates a button when it's let go: that's handled above already.
    onKeyUp: (e: KeyboardEvent<HTMLButtonElement>) => {
      if (e.key === ' ') e.preventDefault();
    },
    // A click with no pointer behind it is a screen reader or switch activating the button: it toggles, as a key does.
    onClick: (e: MouseEvent<HTMLButtonElement>) => {
      if (e.detail !== 0 || Date.now() - lastKey.current < 500) return;
      if (!enabled) return onBlocked?.();
      toggle('key');
    },
  };

  return { state, seconds, error, byKey: via.current === 'key', bind, clearError: () => setError(null) };
}
