// OpenAI, on the Responses API with plain fetch (POST /v1/responses, Bearer auth). store: false on every call, so
// OpenAI keeps no conversation. Within one question the session sends back every output item as it came (reasoning
// items carry their encrypted_content, messages their phase), with each function_call_output after it.
import { AiError, type AiFetch, type ChatProviderApi, type ChatSession, type Reply, type Round, type ToolCall, type Usage, errorCodes, kindOf, objectOf, send } from './provider.ts';
import { sseData } from './sse.ts';

export const OPENAI_API = 'https://api.openai.com/v1';

type Item = Record<string, unknown> & { type?: unknown };
type ResponseBody = { status?: string; output?: Item[]; usage?: { input_tokens?: number; output_tokens?: number }; incomplete_details?: { reason?: string } | null; error?: { code?: unknown } | null };

/** An error status and body as a kind. 429 is out of credit when its code says so, and otherwise a rate limit. */
export async function openaiError(res: globalThis.Response) {
  const codes = await errorCodes(res);
  return new AiError(kindOf(res.status, /insufficient_quota|credit_balance|spend_limit|usage_limit|billing/.test(codes)), res.status);
}

/** A failure reported inside a stream (response.failed, or an error event), by its code. */
function streamError(code: unknown) {
  const c = typeof code === 'string' ? code : '';
  if (/insufficient_quota|credit_balance|spend_limit|usage_limit|billing/.test(c)) return new AiError('quota');
  if (/rate_limit|slow_down/.test(c)) return new AiError('rate');
  if (/invalid|unsupported|context_length|too_large/.test(c)) return new AiError('bad_request');
  return new AiError('server');
}

const usageOf = (r: ResponseBody | undefined): Usage => ({ input: Number(r?.usage?.input_tokens) || 0, output: Number(r?.usage?.output_tokens) || 0 });

/**
 * Models that reason (the o-series, GPT-5 and later, not their -chat versions), whose reasoning items a tool round
 * sends back. Under store: false that needs each item's encrypted_content, so the chat asks for it by name: OpenAI
 * now includes it by default, but asking keeps it there. Models that don't reason have refused the include outright
 * (a 400 on every call), so they're never sent it; a reasoning model this misses still gets the default.
 */
const reasons = (model: string) => /^(o\d|gpt-([5-9]|[1-9]\d))/i.test(model) && !/chat/i.test(model);

/** The text of a finished response's messages, and whether any part of it was a refusal. */
function wordsOf(output: Item[] | undefined) {
  let text = '';
  let refusal = false;
  for (const item of output ?? []) {
    if (item.type !== 'message' || !Array.isArray(item.content)) continue;
    for (const part of item.content as { type?: string; text?: string }[]) {
      if (part.type === 'output_text' && typeof part.text === 'string') text += part.text;
      if (part.type === 'refusal') refusal = true;
    }
  }
  return { text, refusal };
}

function replyOf(r: ResponseBody): Reply {
  const { text, refusal } = wordsOf(r.output);
  const reason = r.incomplete_details?.reason;
  const stop = refusal || reason === 'content_filter' ? 'refusal' : r.status === 'incomplete' ? 'length' : 'end';
  return { text: stop === 'refusal' ? '' : text, stop, usage: usageOf(r) };
}

export function openaiProvider({ key, model, fetchFn }: { key: string; model: string; fetchFn: AiFetch }): ChatProviderApi {
  async function post(body: Record<string, unknown>, signal?: AbortSignal) {
    const res = await send(fetchFn, `${OPENAI_API}/responses`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ model, store: false, ...body }),
      signal,
    });
    if (!res.ok) throw await openaiError(res);
    return res;
  }

  return {
    id: 'openai',

    chat({ system, tools, history, maxTokens }): ChatSession {
      const input: unknown[] = history.map((t) => ({ role: t.role, content: t.content }));
      // Not strict: McFly's schemas have optional fields and ranges, and every tool checks its own input anyway.
      const apiTools = tools.map((t) => ({ type: 'function', name: t.name, description: t.description, parameters: t.schema, strict: false }));
      const include = reasons(model) ? { include: ['reasoning.encrypted_content'] } : {};
      return {
        async next(onText, signal): Promise<Round> {
          const res = await post({ instructions: system, input, tools: apiTools, stream: true, max_output_tokens: maxTokens, ...include }, signal);
          const items: Item[] = [];
          const calls: ToolCall[] = [];
          let refusal = false;
          let finished: ResponseBody | null = null;
          for await (const ev of sseData(res.body)) {
            if (ev.type === 'response.output_text.delta') {
              if (typeof ev.delta === 'string' && ev.delta) onText(ev.delta);
            } else if (ev.type === 'response.refusal.delta') refusal = true;
            else if (ev.type === 'response.output_item.done') {
              // The finished item: a reasoning item's encrypted_content is only complete here, not in .added.
              const item = ev.item as Item | undefined;
              if (!item || typeof item !== 'object') continue;
              items.push(item);
              if (item.type === 'function_call' && typeof item.call_id === 'string' && typeof item.name === 'string') {
                calls.push({ id: item.call_id, name: item.name, input: objectOf(typeof item.arguments === 'string' ? item.arguments : '') });
              }
              if (wordsOf([item]).refusal) refusal = true;
            } else if (ev.type === 'response.completed' || ev.type === 'response.incomplete') finished = (ev.response ?? {}) as ResponseBody;
            else if (ev.type === 'response.failed') throw streamError((ev.response as ResponseBody | undefined)?.error?.code);
            else if (ev.type === 'error') throw streamError(ev.code);
          }
          // The stream closed before the response finished: the connection dropped.
          if (!finished) throw new AiError('network');
          const done: ResponseBody = finished;
          input.push(...items);
          const usage = usageOf(done);
          const reason = done.incomplete_details?.reason;
          if (refusal || reason === 'content_filter') return { stop: 'refusal', calls: [], usage };
          if (done.status === 'incomplete') return { stop: 'length', calls: [], usage };
          return calls.length ? { stop: 'tool_calls', calls, usage } : { stop: 'end', calls: [], usage };
        },
        addResults(results) {
          // No error flag in function_call_output: an error says so in its words.
          for (const r of results) input.push({ type: 'function_call_output', call_id: r.id, output: r.isError ? `Error: ${r.content}` : r.content });
        },
      };
    },

    async text({ system, text, maxTokens }) {
      const res = await post({ instructions: system, input: [{ role: 'user', content: text }], max_output_tokens: maxTokens });
      const r = replyOf((await res.json()) as ResponseBody);
      return { ...r, text: r.text.trim() };
    },

    async json({ system, text, image, schema, name, maxTokens }) {
      const content: unknown[] = [];
      if (image) content.push({ type: 'input_image', image_url: `data:${image.mediaType};base64,${image.data}`, detail: 'auto' });
      content.push({ type: 'input_text', text });
      const res = await post({
        instructions: system,
        input: [{ role: 'user', content }],
        text: { format: { type: 'json_schema', name, schema, strict: true } },
        max_output_tokens: maxTokens,
      });
      return replyOf((await res.json()) as ResponseBody);
    },
  };
}
