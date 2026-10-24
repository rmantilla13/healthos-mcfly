// The OpenAI and Gemini adapters (server/ai/openai.ts, gemini.ts) against scripted streams: a tool call, its result
// sent back with what the provider needs within a question (reasoning items, thought signatures), then the answer.
// Every request goes to a fake fetch; nothing here calls a provider.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { geminiProvider } from '../server/ai/gemini.ts';
import { openaiProvider } from '../server/ai/openai.ts';
import { AiError, type AiFetch, type ChatSession } from '../server/ai/provider.ts';
import { sseData } from '../server/ai/sse.ts';

type Sent = { url: string; headers: Record<string, string>; body: any };

/** A stream of these strings, as a fetch body. */
const streamOf = (chunks: string[]) =>
  new ReadableStream<Uint8Array>({
    start(c) {
      for (const s of chunks) c.enqueue(new TextEncoder().encode(s));
      c.close();
    },
  });

/** A fake fetch answering each request with the next scripted reply, recording what was sent. */
function fakeFetch(replies: (() => globalThis.Response)[]) {
  const sent: Sent[] = [];
  const fetchFn: AiFetch = async (url, init) => {
    sent.push({ url, headers: Object.fromEntries(new Headers(init?.headers).entries()), body: init?.body ? JSON.parse(String(init.body)) : null });
    const next = replies.shift();
    if (!next) throw new Error('fake fetch ran out of replies');
    return next();
  };
  return { fetchFn, sent };
}

const sse = (events: unknown[], split = false) => () => {
  const text = events.map((e) => `event: ${(e as { type?: string }).type ?? 'message'}\ndata: ${JSON.stringify(e)}\n\n`).join('');
  // Split mid-line, the way a network delivers it.
  const chunks = split ? text.match(/[\s\S]{1,7}/g)! : [text];
  return new Response(streamOf(chunks), { headers: { 'Content-Type': 'text/event-stream' } });
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
    sse(
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
    sse([
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
  // The second carries every output item as it finished (the complete reasoning, the commentary with its phase), then the result.
  const tail = sent[1].body.input.slice(HISTORY.length);
  assert.deepEqual(
    tail.map((i: { type: string }) => i.type),
    ['reasoning', 'message', 'function_call', 'function_call_output'],
  );
  assert.equal(tail[0].encrypted_content, 'ENCRYPTED-REASONING');
  assert.equal(tail[1].phase, 'commentary');
  assert.deepEqual(tail[3], { type: 'function_call_output', call_id: 'call_1', output: '{"mean":58}' });
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

test('Gemini: a function call with its thought signature sent back as it came, then the answer', async () => {
  const signed = { functionCall: { id: 'fc-1', name: 'get_metric_history', args: { metrics: ['resting_hr'] } }, thoughtSignature: 'SIGNATURE-1' };
  const { fetchFn, sent } = fakeFetch([
    sse(
      [
        { candidates: [{ content: { role: 'model', parts: [{ text: 'Checking ' }] } }] },
        { candidates: [{ content: { role: 'model', parts: [{ text: 'your data.' }, signed] }, finishReason: 'STOP' }], usageMetadata: { promptTokenCount: 300, candidatesTokenCount: 20, thoughtsTokenCount: 50 } },
      ],
      true,
    ),
    sse([{ candidates: [{ content: { role: 'model', parts: [{ text: 'About **58 bpm**.' }] }, finishReason: 'STOP' }], usageMetadata: { promptTokenCount: 400, candidatesTokenCount: 8 } }]),
  ]);
  const session = geminiProvider({ key: 'AIzaTestGeminiKey000000000000000000000', model: 'gemini-3.8-flash', fetchFn }).chat({ system: 'You are McFly.', tools: TOOLS, history: HISTORY, maxTokens: 32_000 });
  const first = await round(session);
  assert.deepEqual([first.stop, first.text], ['tool_calls', 'Checking your data.']);
  assert.deepEqual(first.calls, [{ id: 'fc-1', name: 'get_metric_history', input: { metrics: ['resting_hr'] } }]);
  assert.deepEqual(first.usage, { input: 300, output: 70 }, 'thinking tokens count as output');
  session.addResults([{ id: 'fc-1', name: 'get_metric_history', content: '{"mean":58}', isError: false }]);
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
  // Each part as it streamed in (never merged), the signed one unchanged, then the result in a user turn.
  const [model, result] = sent[1].body.contents.slice(3);
  assert.deepEqual(model, { role: 'model', parts: [{ text: 'Checking ' }, { text: 'your data.' }, signed] });
  assert.deepEqual(result, { role: 'user', parts: [{ functionResponse: { id: 'fc-1', name: 'get_metric_history', response: { output: { mean: 58 } } } }] });
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
