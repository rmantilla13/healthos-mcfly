// The OpenAI, Gemini and Claude adapters (server/ai/openai.ts, gemini.ts, anthropic.ts) against scripted streams: a tool
// call, its result sent back with what the provider needs within a question (reasoning items, thought signatures,
// thinking blocks), then the answer. The fakes refuse a round that leaves that out, as the providers do. Every request
// goes to a fake fetch or a fake SDK client; nothing here calls a provider.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { isDeepStrictEqual } from 'node:util';
import Anthropic from '@anthropic-ai/sdk';
import { anthropicProvider, echoable } from '../server/ai/anthropic.ts';
import { geminiProvider } from '../server/ai/gemini.ts';
import { openaiProvider } from '../server/ai/openai.ts';
import { AiError, type AiFetch, type ChatSession } from '../server/ai/provider.ts';
import { sseData } from '../server/ai/sse.ts';
import type { McflyClient } from '../server/mcfly.ts';

type Sent = { url: string; headers: Record<string, string>; body: any };

/** A stream of these strings, as a fetch body. */
const streamOf = (chunks: string[]) =>
  new ReadableStream<Uint8Array>({
    start(c) {
      for (const s of chunks) c.enqueue(new TextEncoder().encode(s));
      c.close();
    },
  });

/** A fake fetch answering each request with the next scripted reply (which may look at what was sent), recording it. */
function fakeFetch(replies: ((body: any) => globalThis.Response)[]) {
  const sent: Sent[] = [];
  const fetchFn: AiFetch = async (url, init) => {
    const body = init?.body ? JSON.parse(String(init.body)) : null;
    sent.push({ url, headers: Object.fromEntries(new Headers(init?.headers).entries()), body });
    const next = replies.shift();
    if (!next) throw new Error('fake fetch ran out of replies');
    return next(body);
  };
  return { fetchFn, sent };
}

const sse = (events: unknown[], split = false) => () => {
  const text = events.map((e) => `event: ${(e as { type?: string }).type ?? 'message'}\ndata: ${JSON.stringify(e)}\n\n`).join('');
  // Split mid-line, the way a network delivers it.
  const chunks = split ? text.match(/[\s\S]{1,7}/g)! : [text];
  return new Response(streamOf(chunks), { headers: { 'Content-Type': 'text/event-stream' } });
};

const badRequest = (error: unknown) => new Response(JSON.stringify({ error }), { status: 400 });

/**
 * OpenAI at its strictest under store: false, as it once was: a reasoning item comes back with its encrypted_content
 * only when the request asks for it by name, and one sent back without it can't be found, since nothing was kept.
 * A session that forgets either fails its second round here, as it would against the API.
 */
const statelessOpenai =
  (events: unknown[], split = false) =>
  (body: any) => {
    const lost = (body?.input ?? []).find((i: { type?: string; encrypted_content?: unknown }) => i?.type === 'reasoning' && typeof i.encrypted_content !== 'string');
    if (lost) return badRequest({ message: `Item with id '${lost.id}' not found. Items are not persisted when \`store\` is set to false.`, type: 'invalid_request_error', code: null });
    const asked = Array.isArray(body?.include) && body.include.includes('reasoning.encrypted_content');
    const kept = (e: any) => (e?.item?.type === 'reasoning' && !asked ? { ...e, item: { ...e.item, encrypted_content: undefined } } : e);
    return sse(events.map(kept), split)();
  };

const TOOLS = [{ name: 'get_metric_history', description: 'Daily values', schema: { type: 'object', properties: { metrics: { type: 'array', items: { type: 'string' }, minItems: 1 } }, additionalProperties: false } }];
const HISTORY = [
  { role: 'user' as const, content: 'How did I sleep?' },
  { role: 'assistant' as const, content: 'About 7 hours.' },
  { role: 'user' as const, content: 'And my heart rate?' },
];

async function round(session: ChatSession) {
  let text = '';
  const r = await session.next((d) => (text += d), new AbortController().signal);
  return { ...r, text };
}

test('SSE: events split anywhere, \\r\\n line ends, comments and [DONE] are all read as they should be', async () => {
  const raw = ': keep-alive\r\n\r\ndata: {"a":1}\r\n\r\nevent: x\ndata: {"b":\ndata: 2}\n\ndata: [DONE]\n\n';
  const chunks = raw.match(/[\s\S]{1,3}/g)!;
  const out = [];
  for await (const ev of sseData(streamOf(chunks))) out.push(ev);
  assert.deepEqual(out, [{ a: 1 }, { b: 2 }]);
});

test('OpenAI: a tool call, its result with the reasoning item carried back, then the answer', async () => {
  const reasoning = { type: 'reasoning', id: 'rs_1', summary: [], encrypted_content: 'ENCRYPTED-REASONING' };
  const call = { type: 'function_call', id: 'fc_1', call_id: 'call_1', name: 'get_metric_history', arguments: '{"metrics":["resting_hr"]}', status: 'completed' };
  const { fetchFn, sent } = fakeFetch([
    statelessOpenai(
      [
        { type: 'response.created', response: {} },
        { type: 'response.output_item.added', item: { ...reasoning, encrypted_content: 'PARTIAL' } },
        { type: 'response.output_item.done', item: reasoning },
        { type: 'response.output_text.delta', delta: 'Looking that up.' },
        { type: 'response.output_item.done', item: { type: 'message', id: 'msg_1', role: 'assistant', phase: 'commentary', content: [{ type: 'output_text', text: 'Looking that up.' }] } },
        { type: 'response.output_item.done', item: call },
        { type: 'response.completed', response: { status: 'completed', usage: { input_tokens: 120, output_tokens: 30 } } },
      ],
      true,
    ),
    statelessOpenai([
      { type: 'response.output_text.delta', delta: 'Your resting heart rate ' },
      { type: 'response.output_text.delta', delta: 'averaged **58 bpm**.' },
      { type: 'response.completed', response: { status: 'completed', usage: { input_tokens: 200, output_tokens: 12 } } },
    ]),
  ]);
  const session = openaiProvider({ key: 'sk-test-openai-key-0000', model: 'gpt-6.1-sol', fetchFn }).chat({ system: 'You are McFly.', tools: TOOLS, history: HISTORY, maxTokens: 32_000 });

  const first = await round(session);
  assert.equal(first.stop, 'tool_calls');
  assert.equal(first.text, 'Looking that up.');
  assert.deepEqual(first.calls, [{ id: 'call_1', name: 'get_metric_history', input: { metrics: ['resting_hr'] } }]);
  assert.deepEqual(first.usage, { input: 120, output: 30 });
  session.addResults([{ id: 'call_1', name: 'get_metric_history', content: '{"mean":58}', isError: false }]);

  const second = await round(session);
  assert.deepEqual([second.stop, second.text], ['end', 'Your resting heart rate averaged **58 bpm**.']);

  // The request: Responses API, Bearer key, nothing stored, the tools non-strict, the history as plain turns.
  assert.equal(sent[0].url, 'https://api.openai.com/v1/responses');
  assert.equal(sent[0].headers.authorization, 'Bearer sk-test-openai-key-0000');
  assert.deepEqual([sent[0].body.store, sent[0].body.stream, sent[0].body.model, sent[0].body.instructions], [false, true, 'gpt-6.1-sol', 'You are McFly.']);
  assert.deepEqual(sent[0].body.tools[0], { type: 'function', name: 'get_metric_history', description: 'Daily values', parameters: TOOLS[0].schema, strict: false });
  assert.deepEqual(sent[0].body.input, HISTORY);
  // Every round asks for the reasoning's encrypted_content, which is what lets the next one send it back.
  for (const s of sent) assert.deepEqual(s.body.include, ['reasoning.encrypted_content']);
  // The second carries every output item as it finished (the complete reasoning with its id, the commentary with its
  // phase), then the result.
  const tail = sent[1].body.input.slice(HISTORY.length);
  assert.deepEqual(
    tail.map((i: { type: string }) => i.type),
    ['reasoning', 'message', 'function_call', 'function_call_output'],
  );
  assert.deepEqual(tail[0], reasoning);
  assert.equal(tail[1].phase, 'commentary');
  assert.deepEqual(tail[2], call);
  assert.deepEqual(tail[3], { type: 'function_call_output', call_id: 'call_1', output: '{"mean":58}' });
});

test("OpenAI: only reasoning models are asked for encrypted reasoning; one that doesn't reason would refuse it", async () => {
  const asks = async (model: string) => {
    const { fetchFn, sent } = fakeFetch([sse([{ type: 'response.completed', response: { status: 'completed' } }])]);
    await round(openaiProvider({ key: 'sk-test-openai-key-0000', model, fetchFn }).chat({ system: 's', tools: TOOLS, history: HISTORY, maxTokens: 100 }));
    return sent[0].body.include !== undefined;
  };
  for (const model of ['gpt-6.1-sol', 'gpt-5', 'gpt-5.5-mini', 'gpt-10', 'o3', 'o4-mini']) assert.equal(await asks(model), true, model);
  for (const model of ['gpt-4.1', 'gpt-4o-mini', 'chatgpt-4o-latest', 'gpt-5-chat-latest']) assert.equal(await asks(model), false, model);
});

test('OpenAI: unreadable arguments, errors as words, a refusal, a cut-off and a failed key', async () => {
  const { fetchFn, sent } = fakeFetch([
    sse([
      { type: 'response.output_item.done', item: { type: 'function_call', call_id: 'call_9', name: 'get_metric_history', arguments: '{"metrics": [' } },
      { type: 'response.completed', response: { status: 'completed', usage: {} } },
    ]),
    sse([{ type: 'response.refusal.delta', delta: 'No.' }, { type: 'response.completed', response: { status: 'completed' } }]),
    () => new Response(JSON.stringify({ error: { message: 'Incorrect API key provided: sk-te***0000', type: 'invalid_request_error', code: 'invalid_api_key' } }), { status: 401 }),
    () => new Response(JSON.stringify({ error: { message: 'Credit balance exhausted', type: 'insufficient_quota', code: 'credit_balance_exhausted' } }), { status: 429 }),
    sse([{ type: 'response.incomplete', response: { status: 'incomplete', incomplete_details: { reason: 'max_output_tokens' } } }]),
  ]);
  const session = openaiProvider({ key: 'sk-test-openai-key-0000', model: 'gpt-6.1-sol', fetchFn }).chat({ system: 's', tools: TOOLS, history: HISTORY, maxTokens: 100 });
  const bad = await round(session);
  assert.deepEqual(bad.calls, [{ id: 'call_9', name: 'get_metric_history', input: null }], 'McFly answers it with an error result');
  session.addResults([{ id: 'call_9', name: 'get_metric_history', content: 'Unknown tool or malformed input', isError: true }]);
  assert.equal((await round(session)).stop, 'refusal');
  assert.equal(sent[1].body.input.at(-1).output, 'Error: Unknown tool or malformed input');

  await assert.rejects(round(session), (e: unknown) => e instanceof AiError && e.kind === 'auth' && !e.message.includes('sk-'));
  await assert.rejects(round(session), (e: unknown) => e instanceof AiError && e.kind === 'quota');
  assert.equal((await round(session)).stop, 'length');
});

test('OpenAI: the estimate is strict json_schema with the photo as a data URL', async () => {
  const { fetchFn, sent } = fakeFetch([
    () =>
      new Response(
        JSON.stringify({ status: 'completed', output: [{ type: 'message', content: [{ type: 'output_text', text: '{"items":[],"note":"ok"}' }] }], usage: { input_tokens: 900, output_tokens: 40 } }),
      ),
  ]);
  const schema = { type: 'object', additionalProperties: false, required: ['note'], properties: { note: { type: 'string' } } };
  const reply = await openaiProvider({ key: 'sk-test-openai-key-0000', model: 'gpt-6.1-sol', fetchFn }).json({
    system: 'Estimate.',
    text: 'What I had: toast',
    image: { mediaType: 'image/png', data: 'iVBORw0KGgo=' },
    schema,
    name: 'food_estimate',
    maxTokens: 8000,
  });
  assert.deepEqual(reply, { text: '{"items":[],"note":"ok"}', stop: 'end', usage: { input: 900, output: 40 } });
  assert.deepEqual(sent[0].body.text, { format: { type: 'json_schema', name: 'food_estimate', schema, strict: true } });
  assert.deepEqual(sent[0].body.input[0].content, [
    { type: 'input_image', image_url: 'data:image/png;base64,iVBORw0KGgo=', detail: 'auto' },
    { type: 'input_text', text: 'What I had: toast' },
  ]);
  assert.equal(sent[0].body.store, false);
});

/**
 * Gemini as its thinking models check a request: within the question being answered (after the person's last words),
 * each model turn's first function call must carry the thoughtSignature it came with, or the request is refused.
 */
const signedGemini =
  (events: unknown[], split = false) =>
  (body: any) => {
    const contents: { role: string; parts: Record<string, unknown>[] }[] = body?.contents ?? [];
    const asked = contents.findLastIndex((c) => c.role === 'user' && c.parts.some((p) => typeof p.text === 'string'));
    const unsigned = contents.slice(asked + 1).some((c) => c.role === 'model' && c.parts.some((p) => p.functionCall) && !c.parts.find((p) => p.functionCall)!.thoughtSignature);
    if (unsigned) return badRequest({ code: 400, status: 'INVALID_ARGUMENT', message: 'Function call is missing a thought_signature in functionCall parts.' });
    return sse(events, split)();
  };

test('Gemini: function calls with their thought signature sent back as they came, then the answer', async () => {
  const signed = { functionCall: { id: 'fc-1', name: 'get_metric_history', args: { metrics: ['resting_hr'] } }, thoughtSignature: 'SIGNATURE-1' };
  // A parallel call: only the first of a turn's calls carries a signature.
  const parallel = { functionCall: { id: 'fc-2', name: 'get_metric_history', args: { metrics: ['hrv_rmssd'] } } };
  const { fetchFn, sent } = fakeFetch([
    signedGemini(
      [
        { candidates: [{ content: { role: 'model', parts: [{ text: 'Checking ' }] } }] },
        { candidates: [{ content: { role: 'model', parts: [{ text: 'your data.' }, signed] } }] },
        { candidates: [{ content: { role: 'model', parts: [parallel] }, finishReason: 'STOP' }], usageMetadata: { promptTokenCount: 300, candidatesTokenCount: 20, thoughtsTokenCount: 50 } },
      ],
      true,
    ),
    signedGemini([{ candidates: [{ content: { role: 'model', parts: [{ text: 'About **58 bpm**.' }] }, finishReason: 'STOP' }], usageMetadata: { promptTokenCount: 400, candidatesTokenCount: 8 } }]),
  ]);
  const session = geminiProvider({ key: 'AIzaTestGeminiKey000000000000000000000', model: 'gemini-3.8-flash', fetchFn }).chat({ system: 'You are McFly.', tools: TOOLS, history: HISTORY, maxTokens: 32_000 });
  const first = await round(session);
  assert.deepEqual([first.stop, first.text], ['tool_calls', 'Checking your data.']);
  assert.deepEqual(first.calls, [
    { id: 'fc-1', name: 'get_metric_history', input: { metrics: ['resting_hr'] } },
    { id: 'fc-2', name: 'get_metric_history', input: { metrics: ['hrv_rmssd'] } },
  ]);
  assert.deepEqual(first.usage, { input: 300, output: 70 }, 'thinking tokens count as output');
  session.addResults([
    { id: 'fc-1', name: 'get_metric_history', content: '{"mean":58}', isError: false },
    { id: 'fc-2', name: 'get_metric_history', content: '{"mean":41}', isError: false },
  ]);
  const second = await round(session);
  assert.deepEqual([second.stop, second.text], ['end', 'About **58 bpm**.']);

  // The key goes in the header, never the URL; the system prompt, tools as JSON Schema, and turns as user/model.
  assert.equal(sent[0].url, 'https://generativelanguage.googleapis.com/v1beta/models/gemini-3.8-flash:streamGenerateContent?alt=sse');
  assert.ok(!sent[0].url.includes('AIza'));
  assert.equal(sent[0].headers['x-goog-api-key'], 'AIzaTestGeminiKey000000000000000000000');
  assert.deepEqual(sent[0].body.systemInstruction, { parts: [{ text: 'You are McFly.' }] });
  assert.deepEqual(sent[0].body.tools, [{ functionDeclarations: [{ name: 'get_metric_history', description: 'Daily values', parametersJsonSchema: TOOLS[0].schema }] }]);
  assert.deepEqual(
    sent[0].body.contents.map((c: { role: string }) => c.role),
    ['user', 'model', 'user'],
  );
  // Each part as it streamed in (never merged), in order, the signed one unchanged, then both results in one user turn.
  const [model, result] = sent[1].body.contents.slice(3);
  assert.deepEqual(model, { role: 'model', parts: [{ text: 'Checking ' }, { text: 'your data.' }, signed, parallel] });
  assert.deepEqual(result, {
    role: 'user',
    parts: [
      { functionResponse: { id: 'fc-1', name: 'get_metric_history', response: { output: { mean: 58 } } } },
      { functionResponse: { id: 'fc-2', name: 'get_metric_history', response: { output: { mean: 41 } } } },
    ],
  });
});

test("Gemini: a signature that comes on a part of its own (an empty text) stays with the turn, and thoughts aren't shown", async () => {
  const call = { functionCall: { id: 'fc-1', name: 'get_metric_history', args: { metrics: ['steps'] } }, thoughtSignature: 'SIGNATURE-1' };
  const thought = { text: 'Steps are a daily total.', thought: true };
  const tail = { text: '', thoughtSignature: 'SIGNATURE-2' };
  const { fetchFn, sent } = fakeFetch([
    signedGemini([
      { candidates: [{ content: { role: 'model', parts: [thought] } }] },
      { candidates: [{ content: { role: 'model', parts: [call] } }] },
      { candidates: [{ content: { role: 'model', parts: [tail] }, finishReason: 'STOP' }] },
    ]),
    signedGemini([{ candidates: [{ content: { role: 'model', parts: [{ text: 'About 8,000 a day.' }] }, finishReason: 'STOP' }] }]),
  ]);
  const session = geminiProvider({ key: 'AIzaTestGeminiKey000000000000000000000', model: 'gemini-3.8-flash', fetchFn }).chat({ system: 's', tools: TOOLS, history: HISTORY, maxTokens: 100 });
  const first = await round(session);
  assert.deepEqual([first.stop, first.text], ['tool_calls', '']);
  session.addResults([{ id: 'fc-1', name: 'get_metric_history', content: '{"mean":8000}', isError: false }]);
  assert.equal((await round(session)).text, 'About 8,000 a day.');
  assert.deepEqual(sent[1].body.contents[3], { role: 'model', parts: [thought, call, tail] });
});

test('the strict fakes refuse what a session forgot to send back, so the tests above would catch it', async () => {
  const res = signedGemini([])({
    contents: [...HISTORY.map((t) => ({ role: t.role === 'assistant' ? 'model' : 'user', parts: [{ text: t.content }] })), { role: 'model', parts: [{ functionCall: { name: 'get_metric_history', args: {} } }] }],
  });
  assert.equal(res.status, 400, 'a function call without its signature');
  const openai = statelessOpenai([])({ input: [...HISTORY, { type: 'reasoning', id: 'rs_1', summary: [] }] });
  assert.equal(openai.status, 400, 'a reasoning item without its encrypted_content');
});

test('Gemini: errors, a withheld answer and a broken function call', async () => {
  const { fetchFn } = fakeFetch([
    () => new Response(JSON.stringify({ error: { code: 400, message: 'API key not valid.', status: 'INVALID_ARGUMENT', details: [{ reason: 'API_KEY_INVALID' }] } }), { status: 400 }),
    () => new Response(JSON.stringify({ error: { code: 402, status: 'payment_required' } }), { status: 402 }),
    () => new Response(JSON.stringify({ error: { code: 429, status: 'RESOURCE_EXHAUSTED' } }), { status: 429 }),
    sse([{ promptFeedback: { blockReason: 'SAFETY' } }]),
    sse([{ candidates: [{ content: { parts: [] }, finishReason: 'MALFORMED_FUNCTION_CALL' }] }]),
  ]);
  const session = geminiProvider({ key: 'AIzaTestGeminiKey000000000000000000000', model: 'gemini-3.8-flash', fetchFn }).chat({ system: 's', tools: TOOLS, history: HISTORY, maxTokens: 100 });
  for (const kind of ['auth', 'quota', 'rate']) await assert.rejects(round(session), (e: unknown) => e instanceof AiError && e.kind === kind);
  assert.equal((await round(session)).stop, 'refusal');
  assert.equal((await round(session)).stop, 'continue', 'asked again, like an unparseable streamed input');
});

test('Gemini: a plain reply (the digest) and an estimate in JSON', async () => {
  const { fetchFn, sent } = fakeFetch([
    () => new Response(JSON.stringify({ candidates: [{ content: { parts: [{ text: 'A steady week. ' }] }, finishReason: 'STOP' }], usageMetadata: { promptTokenCount: 10, candidatesTokenCount: 5 } })),
    () => new Response(JSON.stringify({ candidates: [{ content: { parts: [{ text: '{"items":[]}' }] }, finishReason: 'STOP' }] })),
  ]);
  const gemini = geminiProvider({ key: 'AIzaTestGeminiKey000000000000000000000', model: 'gemini-3.8-flash', fetchFn });
  assert.deepEqual(await gemini.text({ system: 's', text: 'Write my digest.', maxTokens: 100 }), { text: 'A steady week.', stop: 'end', usage: { input: 10, output: 5 } });
  assert.match(sent[0].url, /gemini-3\.8-flash:generateContent$/);
  const reply = await gemini.json({ system: 's', text: 't', image: { mediaType: 'image/jpeg', data: '/9j/' }, schema: { type: 'object' }, name: 'food_estimate', maxTokens: 100 });
  assert.equal(reply.text, '{"items":[]}');
  assert.deepEqual(sent[1].body.generationConfig, { maxOutputTokens: 100, responseMimeType: 'application/json', responseJsonSchema: { type: 'object' } });
  assert.deepEqual(sent[1].body.contents[0].parts[0], { inlineData: { mimeType: 'image/jpeg', data: '/9j/' } });
});

// ---------- Claude, through a fake SDK client ----------

type ClaudeParams = { messages: { role: string; content: unknown }[] };
type ClaudeReply = Anthropic.Beta.BetaMessage | InstanceType<typeof Anthropic.APIError>;

const claudeMessage = (content: unknown[], stop_reason: string) =>
  ({
    id: 'msg_test',
    type: 'message',
    role: 'assistant',
    model: 'claude-opus-5-5',
    content,
    stop_reason,
    stop_sequence: null,
    usage: { input_tokens: 100, output_tokens: 20, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 },
  }) as unknown as Anthropic.Beta.BetaMessage;

/** A fake client whose streams answer with the next scripted reply (which may look at the request), recording each one. */
function fakeClaude(replies: ((params: ClaudeParams) => ClaudeReply)[]) {
  const sent: ClaudeParams[] = [];
  const client = {
    beta: {
      messages: {
        stream(params: ClaudeParams) {
          // A copy: the session goes on adding to the same messages array.
          sent.push(structuredClone(params));
          const next = replies.shift();
          if (!next) throw new Error('fake Claude ran out of replies');
          const reply = next(params);
          let onText: ((t: string) => void) | undefined;
          return {
            on(event: string, fn: (t: string) => void) {
              if (event === 'text') onText = fn;
              return this;
            },
            async finalMessage() {
              if (reply instanceof Anthropic.APIError) throw reply;
              for (const b of reply.content) if (b.type === 'text') onText?.(b.text);
              return reply;
            },
          };
        },
      },
    },
  } as unknown as McflyClient;
  return { client, sent };
}

/**
 * Claude as the API checks a tool round: the assistant turn before the results must be the last round's content as it
 * came, thinking blocks and their signatures included, or the request is refused (an APIError, as the SDK throws).
 */
const echoes = (before: Anthropic.Beta.BetaMessage, reply: Anthropic.Beta.BetaMessage) => (params: ClaudeParams) => {
  const turn = params.messages.findLast((m) => m.role === 'assistant');
  if (turn && isDeepStrictEqual(turn.content, before.content)) return reply;
  return new Anthropic.BadRequestError(400, { type: 'error', error: { type: 'invalid_request_error' } }, 'thinking blocks must be passed back unchanged', new Headers());
};

const thinkingRound = claudeMessage(
  [
    // Thinking text is omitted by default; the block and its signature still go back.
    { type: 'thinking', thinking: '', signature: 'SIGNATURE-THINKING-1' },
    { type: 'redacted_thinking', data: 'REDACTED-1' },
    { type: 'text', text: 'Checking.', citations: null },
    { type: 'tool_use', id: 'toolu_1', name: 'get_metric_history', input: { metrics: ['resting_hr'] } },
  ],
  'tool_use',
);

test("Claude: a tool round's thinking blocks go back with their signatures, unchanged, before the result", async () => {
  const answer = claudeMessage([{ type: 'text', text: 'About **58 bpm**.', citations: null }], 'end_turn');
  const { client, sent } = fakeClaude([() => thinkingRound, echoes(thinkingRound, answer)]);
  const session = anthropicProvider(client, 'claude-opus-5-5').chat({ system: 'You are McFly.', tools: TOOLS, history: HISTORY, maxTokens: 32_000 });
  const first = await round(session);
  assert.deepEqual([first.stop, first.text], ['tool_calls', 'Checking.']);
  assert.deepEqual(first.calls, [{ id: 'toolu_1', name: 'get_metric_history', input: { metrics: ['resting_hr'] } }]);
  session.addResults([{ id: 'toolu_1', name: 'get_metric_history', content: '{"mean":58}', isError: false }]);
  const second = await round(session);
  assert.deepEqual([second.stop, second.text], ['end', 'About **58 bpm**.']);
  assert.deepEqual(sent[0].messages, HISTORY);
  assert.deepEqual(sent[1].messages.slice(HISTORY.length), [
    { role: 'assistant', content: thinkingRound.content },
    { role: 'user', content: [{ type: 'tool_result', tool_use_id: 'toolu_1', content: '{"mean":58}' }] },
  ]);
});

test("Claude: after a mid-output fallback, the declining model's thinking and tool calls before the boundary are dropped and never run", async () => {
  const fallback = { type: 'fallback', from: { model: 'claude-opus-5-5' }, to: { model: 'claude-opus-5' }, trigger: { type: 'refusal' } };
  const handedOff = claudeMessage(
    [
      { type: 'thinking', thinking: '', signature: 'SIGNATURE-DECLINED' },
      { type: 'text', text: 'Checking. ', citations: null },
      { type: 'tool_use', id: 'toolu_declined', name: 'get_metric_history', input: { metrics: ['steps'] } },
      { type: 'server_tool_use', id: 'srvtoolu_open', name: 'web_search', input: {} },
      fallback,
      { type: 'thinking', thinking: '', signature: 'SIGNATURE-FALLBACK' },
      { type: 'tool_use', id: 'toolu_2', name: 'get_metric_history', input: { metrics: ['resting_hr'] } },
    ] as unknown as Anthropic.Beta.BetaContentBlock[],
    'tool_use',
  );
  const kept = [handedOff.content[1], handedOff.content[4], handedOff.content[5], handedOff.content[6]];
  const answer = claudeMessage([{ type: 'text', text: 'About **58 bpm**.', citations: null }], 'end_turn');
  const { client, sent } = fakeClaude([() => handedOff, echoes({ ...handedOff, content: kept } as Anthropic.Beta.BetaMessage, answer)]);
  const session = anthropicProvider(client, 'claude-opus-5-5').chat({ system: 's', tools: TOOLS, history: HISTORY, maxTokens: 100 });
  const first = await round(session);
  assert.deepEqual(first.calls, [{ id: 'toolu_2', name: 'get_metric_history', input: { metrics: ['resting_hr'] } }], 'only the fallback model\'s call runs');
  session.addResults([{ id: 'toolu_2', name: 'get_metric_history', content: '{"mean":58}', isError: false }]);
  const second = await round(session);
  assert.equal(second.text, 'About **58 bpm**.');
  assert.deepEqual(sent[1].messages.slice(HISTORY.length, HISTORY.length + 1), [{ role: 'assistant', content: kept }]);
});

test('Claude: a round with no fallback block goes back exactly as it came', () => {
  assert.equal(echoable(thinkingRound.content), thinkingRound.content);
});

test('Claude: the strict fake refuses a round whose thinking blocks were left out, and the session says so', async () => {
  const stripped = thinkingRound.content.filter((b) => b.type !== 'thinking' && b.type !== 'redacted_thinking');
  const reply = echoes(thinkingRound, claudeMessage([], 'end_turn'))({ messages: [...HISTORY, { role: 'assistant', content: stripped }] });
  assert.ok(reply instanceof Anthropic.APIError);
  // A refused request, not something to ask again.
  const { client } = fakeClaude([() => reply]);
  const session = anthropicProvider(client, 'claude-opus-5-5').chat({ system: 's', tools: TOOLS, history: HISTORY, maxTokens: 100 });
  await assert.rejects(round(session), (e: unknown) => e instanceof AiError && e.kind === 'bad_request');
});
