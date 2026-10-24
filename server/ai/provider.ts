// What every AI provider offers healthOS, whatever its API: a chat session for Ask McFly's tool loop, a plain reply (the
// weekly digest) and a structured JSON reply (meal estimates). Claude (anthropic.ts), OpenAI (openai.ts) and Gemini
// (gemini.ts) each fill it in. A session keeps that provider's own transcript for the rounds of one question (Claude
// needs its tool_use blocks back, OpenAI its reasoning items, Gemini its thought signatures); between questions the
// history is plain-text turns, so a person can switch provider at any time.
import type { AiProvider } from '../../shared/ai.ts';

/** fetch, injectable so tests never call a provider (the FetchFn of server/foods.ts). */
export type AiFetch = (url: string, init?: RequestInit) => Promise<globalThis.Response>;

/** A tool the model may call. schema is plain JSON Schema; each tool still checks its own input. */
export type ToolDef = { name: string; description: string; schema: Record<string, unknown> };
/** input is null when the model's arguments weren't a JSON object. */
export type ToolCall = { id: string; name: string; input: Record<string, unknown> | null };
export type ToolResult = { id: string; name: string; content: string; isError: boolean };

/**
 * Why a round ended. 'continue': nothing to add, ask again (Claude paused a long turn, or a streamed tool input
 * wasn't parseable and the round is re-issued); it uses up a round like any other.
 */
export type Stop = 'end' | 'tool_calls' | 'length' | 'refusal' | 'continue';
export type Usage = { input: number; output: number };
export type Round = { stop: Stop; calls: ToolCall[]; usage: Usage };
export type Turn = { role: 'user' | 'assistant'; content: string };

export type ChatSession = {
  /** One model call: streams its words to onText, and says what it wants next. */
  next(onText: (delta: string) => void, signal: AbortSignal): Promise<Round>;
  /** The tool results for the last round's calls, in the order they were asked for. */
  addResults(results: ToolResult[]): void;
};

/** A one-shot reply. text is '' when nothing came back. */
export type Reply = { text: string; stop: 'end' | 'length' | 'refusal'; usage: Usage };
export type ImageInput = { mediaType: 'image/jpeg' | 'image/png' | 'image/webp'; data: string };

export type ChatProviderApi = {
  id: AiProvider;
  chat(o: { system: string; tools: ToolDef[]; history: Turn[]; maxTokens: number }): ChatSession;
  text(o: { system: string; text: string; maxTokens: number }): Promise<Reply>;
  /** A reply that matches the JSON Schema (each provider's structured outputs). */
  json(o: { system: string; text: string; image: ImageInput | null; schema: Record<string, unknown>; name: string; maxTokens: number }): Promise<Reply>;
};

/**
 * A failed provider call, as a kind: never the provider's message, which can carry part of the key (OpenAI echoes a
 * masked one) or the request. 'auth' covers a key that's wrong, revoked or not allowed; 'quota' an account out of credit.
 */
export type AiErrorKind = 'auth' | 'quota' | 'rate' | 'server' | 'bad_request' | 'network';

export class AiError extends Error {
  kind: AiErrorKind;
  status: number | null;
  constructor(kind: AiErrorKind, status: number | null = null) {
    super(`AI ${kind}${status ? ` ${status}` : ''}`);
    this.name = 'AiError';
    this.kind = kind;
    this.status = status;
  }
}

/** A provider's HTTP status as a kind. quota: a billing code in its error body says so (OpenAI and Gemini). */
export function kindOf(status: number, quota = false): AiErrorKind {
  if (status === 402 || quota) return 'quota';
  if (status === 401 || status === 403) return 'auth';
  if (status === 429) return 'rate';
  if (status >= 500) return 'server';
  return 'bad_request';
}

export const PROVIDER_LABEL: Record<AiProvider, string> = { anthropic: 'Claude', openai: 'OpenAI', gemini: 'Gemini' };

/**
 * A model id each provider could have, checked before it's saved (a person's choice or the admin's). Strict on
 * purpose: Gemini's goes into the URL path, so no slashes, colons or anything else that could reach another route.
 */
export const MODEL_ID: Record<AiProvider, RegExp> = {
  anthropic: /^claude-[a-z0-9-]{1,80}$/,
  openai: /^[a-z0-9][a-z0-9._:-]{1,99}$/i,
  gemini: /^[a-z0-9][a-z0-9.-]{1,80}$/,
};

/** The parts of a JSON error body that say what kind of failure it was; nothing else of it is kept. */
export async function errorCodes(res: globalThis.Response): Promise<string> {
  try {
    const body = (await res.json()) as { error?: { code?: unknown; type?: unknown; status?: unknown; details?: { reason?: unknown }[] } };
    const e = body?.error ?? {};
    return [e.code, e.type, e.status, ...(Array.isArray(e.details) ? e.details.map((d) => d?.reason) : [])].filter((x) => typeof x === 'string').join(' ');
  } catch {
    return '';
  }
}

/** fetch that turns a failure to connect into an AiError, and passes an abort through as it is. */
export async function send(fetchFn: AiFetch, url: string, init: RequestInit): Promise<globalThis.Response> {
  try {
    return await fetchFn(url, init);
  } catch (err) {
    if (init.signal?.aborted) throw err;
    throw new AiError('network');
  }
}

/** JSON text parsed as an object, or null (a model's tool arguments). */
export function objectOf(text: string): Record<string, unknown> | null {
  try {
    const v = JSON.parse(text || '{}') as unknown;
    return v && typeof v === 'object' && !Array.isArray(v) ? (v as Record<string, unknown>) : null;
  } catch {
    return null;
  }
}
