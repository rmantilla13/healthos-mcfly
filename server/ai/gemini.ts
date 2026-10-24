// Gemini, on the generateContent API with plain fetch (streamGenerateContent?alt=sse), the key in the x-goog-api-key
// header and never in the URL. Stateless: Google keeps no conversation. Within one question the session sends back
// the model's parts exactly as they came, each on its own (a part with a thoughtSignature is never merged with
// another), then the function responses in a user turn.
import { AiError, type AiFetch, type ChatProviderApi, type ChatSession, type Reply, type Round, type ToolCall, type Usage, errorCodes, kindOf, send } from './provider.ts';
import { sseData } from './sse.ts';

export const GEMINI_API = 'https://generativelanguage.googleapis.com/v1beta';

type Part = Record<string, unknown> & { text?: unknown; thought?: unknown; functionCall?: { id?: unknown; name?: unknown; args?: unknown } };
type Chunk = {
  candidates?: { content?: { parts?: Part[] }; finishReason?: string }[];
  promptFeedback?: { blockReason?: string };
  usageMetadata?: { promptTokenCount?: number; candidatesTokenCount?: number; thoughtsTokenCount?: number };
  error?: { code?: number; status?: string };
};

/** Finish reasons that mean the answer was withheld. */
const WITHHELD = new Set(['SAFETY', 'PROHIBITED_CONTENT', 'BLOCKLIST', 'SPII', 'RECITATION', 'IMAGE_SAFETY', 'IMAGE_PROHIBITED_CONTENT', 'LANGUAGE']);
/** The model's function call itself was broken: ask again, as Claude's unparseable streamed input is. */
const MALFORMED = new Set(['MALFORMED_FUNCTION_CALL', 'UNEXPECTED_TOOL_CALL']);

/** An error status and body as a kind. A key Google doesn't accept can come back as 400 API_KEY_INVALID. */
export async function geminiError(res: globalThis.Response) {
  const codes = await errorCodes(res);
  if (/API_KEY_INVALID|API_KEY_EXPIRED|API_KEY_SERVICE_BLOCKED/.test(codes)) return new AiError('auth', res.status);
  return new AiError(kindOf(res.status), res.status);
}

// Thinking tokens are billed as output, so they count with it.
const usageOf = (u: Chunk['usageMetadata']): Usage => ({ input: Number(u?.promptTokenCount) || 0, output: (Number(u?.candidatesTokenCount) || 0) + (Number(u?.thoughtsTokenCount) || 0) });

/** A tool's JSON result as Gemini's function response, which must be an object: { output } or { error }. */
function outputOf(content: string): unknown {
  try {
    return JSON.parse(content);
  } catch {
    return content;
  }
}

function replyOf(c: Chunk): Reply {
  const cand = c.candidates?.[0];
  const text = (cand?.content?.parts ?? [])
    .filter((p) => typeof p.text === 'string' && !p.thought)
    .map((p) => p.text as string)
    .join('');
  const withheld = Boolean(c.promptFeedback?.blockReason) || WITHHELD.has(cand?.finishReason ?? '');
  return { text: withheld ? '' : text, stop: withheld ? 'refusal' : cand?.finishReason === 'MAX_TOKENS' ? 'length' : 'end', usage: usageOf(c.usageMetadata) };
}

export function geminiProvider({ key, model, fetchFn }: { key: string; model: string; fetchFn: AiFetch }): ChatProviderApi {
  async function post(method: 'generateContent' | 'streamGenerateContent', body: Record<string, unknown>, signal?: AbortSignal) {
    const url = `${GEMINI_API}/models/${encodeURIComponent(model)}:${method}${method === 'streamGenerateContent' ? '?alt=sse' : ''}`;
    const res = await send(fetchFn, url, { method: 'POST', headers: { 'x-goog-api-key': key, 'Content-Type': 'application/json' }, body: JSON.stringify(body), signal });
    if (!res.ok) throw await geminiError(res);
    return res;
  }

  return {
    id: 'gemini',

    chat({ system, tools, history, maxTokens }): ChatSession {
      const contents: { role: 'user' | 'model'; parts: unknown[] }[] = history.map((t) => ({ role: t.role === 'assistant' ? 'model' : 'user', parts: [{ text: t.content }] }));
      const declarations = tools.map((t) => ({ name: t.name, description: t.description, parametersJsonSchema: t.schema }));
      // Ids Gemini didn't give (older models): made up here to match results to calls, and not sent back.
      const madeUp = new Set<string>();
      let retries = 0;
      let calls = 0;
      return {
        async next(onText, signal): Promise<Round> {
          const res = await post(
            'streamGenerateContent',
            {
              systemInstruction: { parts: [{ text: system }] },
              contents,
              ...(declarations.length ? { tools: [{ functionDeclarations: declarations }] } : {}),
              generationConfig: { maxOutputTokens: maxTokens },
            },
            signal,
          );
          const parts: Part[] = [];
          const found: ToolCall[] = [];
          let finish = '';
          let blocked = false;
          let usage: Usage = { input: 0, output: 0 };
          for await (const raw of sseData(res.body)) {
            const chunk = raw as Chunk;
            if (chunk.error) throw new AiError(kindOf(Number(chunk.error.code) || 500), Number(chunk.error.code) || null);
            if (chunk.promptFeedback?.blockReason) blocked = true;
            const cand = chunk.candidates?.[0];
            for (const part of cand?.content?.parts ?? []) {
              if (!part || typeof part !== 'object' || Object.keys(part).length === 0) continue;
              parts.push(part);
              if (typeof part.text === 'string' && part.text && !part.thought) onText(part.text);
              const fc = part.functionCall;
              if (fc && typeof fc.name === 'string') {
                let id = typeof fc.id === 'string' && fc.id ? fc.id : '';
                if (!id) madeUp.add((id = `call_${++calls}`));
                found.push({ id, name: fc.name, input: fc.args && typeof fc.args === 'object' && !Array.isArray(fc.args) ? (fc.args as Record<string, unknown>) : null });
              }
            }
            if (cand?.finishReason) finish = cand.finishReason;
            if (chunk.usageMetadata) usage = usageOf(chunk.usageMetadata);
          }
          if (blocked || WITHHELD.has(finish)) return { stop: 'refusal', calls: [], usage };
          if (MALFORMED.has(finish) && retries++ < 2) return { stop: 'continue', calls: [], usage };
          retries = 0;
          if (parts.length) contents.push({ role: 'model', parts });
          if (finish === 'MAX_TOKENS') return { stop: 'length', calls: [], usage };
          return found.length ? { stop: 'tool_calls', calls: found, usage } : { stop: 'end', calls: [], usage };
        },
        addResults(results) {
          contents.push({
            role: 'user',
            parts: results.map((r) => ({
              functionResponse: { ...(madeUp.has(r.id) ? {} : { id: r.id }), name: r.name, response: r.isError ? { error: r.content } : { output: outputOf(r.content) } },
            })),
          });
        },
      };
    },

    async text({ system, text, maxTokens }) {
      const res = await post('generateContent', { systemInstruction: { parts: [{ text: system }] }, contents: [{ role: 'user', parts: [{ text }] }], generationConfig: { maxOutputTokens: maxTokens } });
      const r = replyOf((await res.json()) as Chunk);
      return { ...r, text: r.text.trim() };
    },

    async json({ system, text, image, schema, maxTokens }) {
      const parts: unknown[] = [];
      if (image) parts.push({ inlineData: { mimeType: image.mediaType, data: image.data } });
      parts.push({ text });
      const res = await post('generateContent', {
        systemInstruction: { parts: [{ text: system }] },
        contents: [{ role: 'user', parts }],
        generationConfig: { maxOutputTokens: maxTokens, responseMimeType: 'application/json', responseJsonSchema: schema },
      });
      return replyOf((await res.json()) as Chunk);
    },
  };
}
