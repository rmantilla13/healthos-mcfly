// Your own AI keys (Profile → Chatbot, and OpenAI · Nutrition & portraits). Keys are stored encrypted with
// HEALTHOS_DATA_KEY (server/ai/keys.ts) and never sent back: the browser only ever sees the provider and last 4.
// Without a key of their own, a person uses the server's shared Claude key, as before.

export type AiProvider = 'anthropic' | 'openai' | 'gemini';

export const AI_PROVIDERS: { provider: AiProvider; label: string }[] = [
  { provider: 'openai', label: 'OpenAI' },
  { provider: 'anthropic', label: 'Claude' },
  { provider: 'gemini', label: 'Gemini' },
];

/** Who pays for a call: the person's own key, or the server's shared one. */
export type AiSource = 'own' | 'shared';

export type AiKeyInfo = { provider: AiProvider; last4: string; model: string | null; addedAt: number; lastUsedAt: number | null; lastError: string | null };

/** The chat's provider: 'shared' is the server's McFly on its Claude key. */
export type ChatChoice = 'shared' | AiProvider;

/** GET /api/ai. */
export type AiStatus = {
  /** Keys can be stored here (HEALTHOS_DATA_KEY is set). */
  byok: boolean;
  /** The server's shared Claude key is set and the admin allows it. */
  shared: boolean;
  keys: AiKeyInfo[];
  /** What Ask McFly uses now, or null when nothing is available. */
  chat: { provider: AiProvider; source: AiSource; model: string } | null;
  /** What the person chose for the chat ('shared' when they haven't). */
  chatChoice: ChatChoice;
  /** What reads a meal photo or description now, or null. */
  estimate: { provider: AiProvider; source: AiSource } | null;
  /** Voice notes can be transcribed (needs an OpenAI key). */
  voice: boolean;
  /** Portraits can be generated (needs an OpenAI key). */
  portraits: boolean;
};

/** PUT /api/ai/keys/:provider. The key is checked with the provider before it's saved. */
export type AiKeyInput = { key: string; model?: string | null };

/** PUT /api/ai/chat. */
export type ChatChoiceInput = { provider: ChatChoice; model?: string | null };

/** POST /api/ai/transcribe (raw audio body, Content-Type audio/webm or audio/mp4): the words, for the person to check before estimating. */
export type Transcript = { text: string };
