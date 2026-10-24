// Ask McFly, meal estimates and voice notes on a person's own key: which provider answers whom, that their questions
// never use (or show in) the shared limit, what a failing key says, and that the iPhone's event stream is unchanged.
// The shared Claude key and every provider are fakes; nothing here calls an AI.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { AddressInfo } from 'node:net';
import type { AiFetch } from '../server/ai/provider.ts';
import { createApp } from '../server/app.ts';
import { hashPassword } from '../server/auth.ts';
import { addDays, todayLocal } from '../server/dates.ts';
import { upsertDaily } from '../server/db.ts';
import { type McflyClient, digestWeek } from '../server/mcfly.ts';
import { openStore } from '../server/store.ts';

delete process.env.OPENAI_API_KEY;
delete process.env.ANTHROPIC_API_KEY;
delete process.env.HEALTHOS_DATA_KEY_PREVIOUS;
process.env.HEALTHOS_DATA_KEY = 'c3'.repeat(32);
process.env.SESSION_SECRET = 'ai-chat-test-secret-'.padEnd(64, 'x');
const OWNER_PASSWORD = 'owner password 123';
process.env.HEALTHOS_PASSWORD_HASH = await hashPassword(OWNER_PASSWORD);

const OPENAI_KEY = 'sk-proj-TESTKEY-openai-1234567890abcdef9c1d';
const CLAUDE_KEY = 'sk-ant-api03-TESTKEY-claude-1234567890abcd4f2a';
const GEMINI_KEY = 'AIzaSyTESTKEY-gemini-12345678901234567x9z';

// ---------- the shared Claude key, as a fake ----------
const claude: any[] = [];
const sharedFake = {
  beta: {
    messages: {
      async create(params: unknown) {
        claude.push(structuredClone(params));
        return {
          id: 'msg_test',
          type: 'message',
          role: 'assistant',
          model: 'claude-opus-5-5',
          content: [{ type: 'text', text: JSON.stringify({ items: [{ name: 'Soup', portion: '1 bowl (300 g)', energy_kcal: 200, protein_g: 8, carbs_g: 20, fat_g: 9, fiber_g: null, sugar_g: null, sat_fat_g: null, sodium_mg: null, alcohol_drinks: 0, water_ml: null }], note: 'Assumed a bowl.' }) }],
          stop_reason: 'end_turn',
          stop_sequence: null,
          usage: { input_tokens: 10, output_tokens: 5 },
        };
      },
      stream(params: unknown) {
        claude.push(structuredClone(params));
        const msg = { content: [{ type: 'text', text: 'Shared answer.' }], stop_reason: 'end_turn', usage: { input_tokens: 10, output_tokens: 5 } };
        let onText: ((t: string) => void) | undefined;
        return {
          on(event: string, fn: (t: string) => void) {
            if (event === 'text') onText = fn;
            return this;
          },
          async finalMessage() {
            onText?.('Shared answer.');
            return msg;
          },
        };
      },
    },
  },
} as unknown as McflyClient;

// ---------- the providers, as one fake fetch ----------
type Call = { url: string; method: string; headers: Record<string, string>; body: any };
const calls: Call[] = [];
/** Scripted replies for model calls, in order (verification calls answer themselves). */
let script: (() => globalThis.Response)[] = [];
const VERIFY = ['https://api.openai.com/v1/models', 'https://api.anthropic.com/v1/models?limit=1', 'https://generativelanguage.googleapis.com/v1beta/models?pageSize=1'];
const aiFetch: AiFetch = async (url, init) => {
  const u = String(url);
  const headers = Object.fromEntries(new Headers(init?.headers).entries());
  const body = init?.body instanceof FormData ? init.body : typeof init?.body === 'string' ? JSON.parse(init.body) : null;
  if (VERIFY.includes(u)) return new Response(JSON.stringify({ data: [] }));
  calls.push({ url: u, method: init?.method ?? 'GET', headers, body });
  const next = script.shift();
  if (!next) throw new Error(`fake provider has no reply for ${u}`);
  return next();
};
const streamOf = (text: string) =>
  new ReadableStream<Uint8Array>({
    start(c) {
      c.enqueue(new TextEncoder().encode(text));
      c.close();
    },
  });
const sse = (events: unknown[]) => () => new Response(streamOf(events.map((e) => `data: ${JSON.stringify(e)}\n\n`).join('')), { headers: { 'Content-Type': 'text/event-stream' } });
const json = (body: unknown, status = 200) => () => new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });

const db = await openStore();
const server = createApp({ db, hosted: false, mcflyClient: () => sharedFake, aiFetch }).listen(0, '127.0.0.1');
await new Promise((r) => server.once('listening', r));
const base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
test.after(() => {
  server.close();
});

class Client {
  cookie = '';
  async call(method: string, path: string, body?: unknown, raw?: { type: string; data: Uint8Array }) {
    const res = await fetch(base + path, {
      method,
      headers: { 'X-HealthOS': '1', 'Content-Type': raw?.type ?? 'application/json', ...(this.cookie ? { Cookie: this.cookie } : {}) },
      body: raw ? new Blob([new Uint8Array(raw.data)]) : body === undefined ? undefined : JSON.stringify(body),
    });
    const set = res.headers.get('set-cookie');
    if (set) this.cookie = set.split(';')[0];
    const text = await res.text();
    let parsed: any = null;
    try {
      parsed = JSON.parse(text);
    } catch {
      parsed = null;
    }
    return { status: res.status, text, json: parsed };
  }
  ask(question: string) {
    return this.call('POST', '/api/mcfly/chat', { messages: [{ role: 'user', content: question }] });
  }
}
const events = (text: string) =>
  text
    .split('\n\n')
    .filter(Boolean)
    .map((chunk) => ({ event: /^event: (.+)$/m.exec(chunk)?.[1], data: JSON.parse(/^data: (.+)$/m.exec(chunk)?.[1] ?? 'null') }));

const owner = new Client();
const bob = new Client();
const carol = new Client();
let bobId = '';
const today = todayLocal();
const usage = async (userId: string) => {
  const [r] = await db.query<Record<string, number>>('SELECT questions, own_questions, input_tokens, own_input_tokens, own_output_tokens FROM mcfly_usage WHERE user_id = $1', [userId]);
  return Object.fromEntries(Object.entries(r ?? {}).map(([k, v]) => [k, Number(v)]));
};

test('setup: an owner and two members; Bob has a week of resting heart rate', async () => {
  assert.equal((await owner.call('POST', '/api/auth/login', { email: 'owner@example.com', password: OWNER_PASSWORD })).status, 200);
  for (const [c, name] of [
    [bob, 'Bob'],
    [carol, 'Carol'],
  ] as const) {
    const inv = await owner.call('POST', '/api/admin/invites', {});
    const token = inv.json.url.split('/').at(-1);
    assert.equal((await c.call('POST', '/api/auth/invite', { token, email: `${name.toLowerCase()}@example.com`, name, password: `${name} password 123` })).status, 200);
  }
  bobId = (await bob.call('GET', '/api/auth/me')).json.user.id;
  await upsertDaily(db, bobId, [0, 1, 2, 3, 4, 5, 6].map((i) => ({ date: addDays(today, -i), metric: 'resting_hr', source: 'apple', value: 62 })));
});

test('with no key of their own, everyone uses the shared Claude key, within its daily limit', async () => {
  const status = (await bob.call('GET', '/api/mcfly')).json;
  assert.deepEqual([status.configured, status.provider, status.source, status.limited, status.limit], [true, 'anthropic', 'shared', true, 50]);
  const ai = (await bob.call('GET', '/api/ai')).json;
  assert.deepEqual([ai.byok, ai.shared, ai.chat, ai.estimate, ai.voice], [true, true, { provider: 'anthropic', source: 'shared', model: 'claude-opus-5-5' }, { provider: 'anthropic', source: 'shared' }, false]);
});

test("a stored key isn't used for the chat until it's chosen; the estimate uses an OpenAI key at once", async () => {
  assert.equal((await bob.call('PUT', '/api/ai/keys/openai', { key: OPENAI_KEY })).status, 200);
  const ai = (await bob.call('GET', '/api/ai')).json;
  assert.deepEqual([ai.chat.source, ai.estimate, ai.voice, ai.portraits], ['shared', { provider: 'openai', source: 'own' }, true, true]);
  const chosen = await bob.call('PUT', '/api/ai/chat', { provider: 'openai' });
  assert.deepEqual(chosen.json.chat, { provider: 'openai', source: 'own', model: 'gpt-6.1-sol' });
  const status = (await bob.call('GET', '/api/mcfly')).json;
  assert.deepEqual(status, { configured: true, limit: 200, usedToday: 0, provider: 'openai', source: 'own', limited: false });
});

test("own-key questions work with McFly's limit at 0, never count against it, and the event stream is the same", async () => {
  await owner.call('PUT', '/api/admin/settings', { mcfly_daily_limit: 0 });
  calls.length = 0;
  script = [
    sse([
      { type: 'response.output_item.done', item: { type: 'function_call', id: 'fc_1', call_id: 'call_1', name: 'get_metric_history', arguments: JSON.stringify({ metrics: ['resting_hr'], days: 7 }) } },
      { type: 'response.completed', response: { status: 'completed', usage: { input_tokens: 500, output_tokens: 50 } } },
    ]),
    sse([
      { type: 'response.output_text.delta', delta: 'Averaged **62 bpm**.' },
      { type: 'response.completed', response: { status: 'completed', usage: { input_tokens: 700, output_tokens: 20 } } },
    ]),
  ];
  const res = await bob.ask('What was my resting heart rate this week?');
  assert.equal(res.status, 200);
  assert.deepEqual(
    events(res.text).map((e) => e.event),
    ['tool', 'text', 'done'],
  );
  // OpenAI got Bob's own numbers back, under its own call id, and McFly's persona.
  const output = calls[1].body.input.at(-1);
  assert.equal(output.type, 'function_call_output');
  assert.equal(output.call_id, 'call_1');
  assert.equal(JSON.parse(output.output).metrics[0].mean, 62);
  assert.match(calls[0].body.instructions, /You are McFly/);
  assert.equal(calls[0].headers.authorization, `Bearer ${OPENAI_KEY}`);
  assert.deepEqual(await usage(bobId), { questions: 0, own_questions: 1, input_tokens: 0, own_input_tokens: 1200, own_output_tokens: 70 });

  // Shared-key users are still off; the admin's cost view shows nothing for Bob.
  assert.equal((await carol.ask('hello?')).status, 403);
  const ov = (await owner.call('GET', '/api/admin/overview')).json;
  assert.deepEqual(ov.users.find((u: { id: string }) => u.id === bobId).mcfly, { questions30d: 0, tokens30d: 0, voiceNotes30d: 0 });
  assert.equal(claude.length, 0);
});

test("a key that stops working says so plainly (never a 401), isn't counted, and shows in Profile", async () => {
  script = [json({ error: { message: `Incorrect API key provided: ${OPENAI_KEY.slice(0, 8)}***`, code: 'invalid_api_key' } }, 401)];
  const res = await bob.ask('Still there?');
  assert.equal(res.status, 200, 'the stream opened; the failure is an event in it');
  const ev = events(res.text);
  assert.deepEqual(ev.at(-1), { event: 'error', data: { error: "Your OpenAI key isn't working. Check it in your Profile → Chatbot." } });
  assert.ok(!res.text.includes('sk-proj'));
  assert.equal((await usage(bobId)).own_questions, 1, 'given back');
  assert.equal((await bob.call('GET', '/api/ai')).json.keys[0].lastError, 'auth');

  script = [json({ error: { code: 'credit_balance_exhausted', type: 'insufficient_quota' } }, 429)];
  assert.equal(events((await bob.ask('And now?')).text).at(-1)?.data.error, 'Your OpenAI account is out of credit.');
});

test('own keys have a high daily cap of their own', async () => {
  await db.query('UPDATE mcfly_usage SET own_questions = 200 WHERE user_id = $1', [bobId]);
  const over = await bob.ask('One more?');
  assert.equal(over.status, 429);
  assert.match(over.json.error, /200 questions today on your own OpenAI key/);
  await db.query('UPDATE mcfly_usage SET own_questions = 1 WHERE user_id = $1', [bobId]);
});

test('Gemini answers when chosen, with its key in the header', async () => {
  assert.equal((await bob.call('PUT', '/api/ai/keys/gemini', { key: GEMINI_KEY })).status, 200);
  assert.equal((await bob.call('PUT', '/api/ai/chat', { provider: 'gemini' })).json.chat.model, 'gemini-3.8-flash');
  calls.length = 0;
  script = [sse([{ candidates: [{ content: { role: 'model', parts: [{ text: 'Hello from Gemini.' }] }, finishReason: 'STOP' }], usageMetadata: { promptTokenCount: 50, candidatesTokenCount: 5 } }])];
  const ev = events((await bob.ask('Hi?')).text);
  assert.deepEqual(
    ev.map((e) => [e.event, e.data.text]),
    [
      ['text', 'Hello from Gemini.'],
      ['done', undefined],
    ],
  );
  assert.equal(calls[0].url, 'https://generativelanguage.googleapis.com/v1beta/models/gemini-3.8-flash:streamGenerateContent?alt=sse');
  assert.equal(calls[0].headers['x-goog-api-key'], GEMINI_KEY);
});

test("the weekly digest runs on the person's own key too, and is counted as theirs", async () => {
  const week = digestWeek(today);
  await upsertDaily(db, bobId, [0, 1, 2, 3].map((i) => ({ date: addDays(week.start, i), metric: 'steps', source: 'apple', value: 8000 })));
  const before = await usage(bobId);
  calls.length = 0;
  script = [json({ candidates: [{ content: { parts: [{ text: 'A **steady** week.' }] }, finishReason: 'STOP' }], usageMetadata: { promptTokenCount: 80, candidatesTokenCount: 10 } })];
  const res = await bob.call('GET', '/api/mcfly/digest');
  assert.deepEqual([res.status, res.json.configured, res.json.digest.text], [200, true, 'A **steady** week.']);
  assert.match(calls[0].url, /gemini-3\.8-flash:generateContent$/);
  assert.match(calls[0].body.systemInstruction.parts[0].text, /weekly digest/);
  const after = await usage(bobId);
  assert.deepEqual([after.own_questions - before.own_questions, after.questions], [1, 0]);
});

test("meal estimates: Bob's OpenAI key with strict JSON; never the shared limit", async () => {
  assert.equal((await bob.call('PUT', '/api/settings', { nutrition: true, nutritionNumbers: 'all' })).status, 200);
  calls.length = 0;
  const items = [{ name: 'Two eggs', portion: '2 large (100 g)', energy_kcal: 143, protein_g: 12.6, carbs_g: 0.7, fat_g: 9.5, fiber_g: 0, sugar_g: 0.4, sat_fat_g: 3.1, sodium_mg: 142, alcohol_drinks: 0, water_ml: null }];
  script = [json({ status: 'completed', output: [{ type: 'message', content: [{ type: 'output_text', text: JSON.stringify({ items, note: 'Assumed boiled.' }) }] }], usage: { input_tokens: 300, output_tokens: 90 } })];
  const res = await bob.call('POST', '/api/nutrition/estimate', { description: 'two eggs' });
  assert.equal(res.status, 200);
  assert.deepEqual(
    res.json.drafts.map((d: { name: string }) => d.name),
    ['Two eggs'],
  );
  assert.equal(calls[0].url, 'https://api.openai.com/v1/responses');
  assert.deepEqual([calls[0].body.model, calls[0].body.store, calls[0].body.text.format.type, calls[0].body.text.format.strict], ['gpt-6.1-sol', false, 'json_schema', true]);
  assert.match(calls[0].body.instructions, /You estimate what was eaten/);
  assert.equal(claude.length, 0);
  assert.equal((await usage(bobId)).questions, 0);
  await bob.call('POST', '/api/nutrition/log/discard', { batch: res.json.batch });
});

test("with only a Claude key of their own, the estimate runs on it (the person's key in the header)", async () => {
  await bob.call('DELETE', '/api/ai/keys/openai');
  assert.equal((await bob.call('PUT', '/api/ai/keys/anthropic', { key: CLAUDE_KEY })).status, 200);
  assert.deepEqual((await bob.call('GET', '/api/ai')).json.estimate, { provider: 'anthropic', source: 'own' });
  calls.length = 0;
  script = [
    json({
      id: 'msg_own',
      type: 'message',
      role: 'assistant',
      model: 'claude-opus-5-5',
      content: [{ type: 'text', text: JSON.stringify({ items: [], note: 'Nothing to estimate.' }) }],
      stop_reason: 'end_turn',
      stop_sequence: null,
      usage: { input_tokens: 40, output_tokens: 8 },
    }),
  ];
  const res = await bob.call('POST', '/api/nutrition/estimate', { description: 'a glass of air' });
  assert.equal(res.status, 200);
  assert.ok(calls[0].url.startsWith('https://api.anthropic.com/v1/messages'));
  assert.equal(calls[0].headers['x-api-key'], CLAUDE_KEY);
  assert.equal(calls[0].body.output_config.format.type, 'json_schema');
  assert.equal(claude.length, 0, 'not the shared key');
});

test("the server's OPENAI_API_KEY is never used for someone's food, only for voice notes", async () => {
  await owner.call('PUT', '/api/admin/settings', { mcfly_daily_limit: 50 });
  process.env.OPENAI_API_KEY = 'sk-proj-SERVER-openai-key-000000000000';
  try {
    assert.equal((await carol.call('PUT', '/api/settings', { nutrition: true, nutritionNumbers: 'all' })).status, 200);
    calls.length = 0;
    const res = await carol.call('POST', '/api/nutrition/estimate', { description: 'soup' });
    assert.equal(res.status, 200);
    assert.equal(calls.length, 0, 'nothing went to OpenAI');
    assert.equal(claude.length, 1, 'the shared Claude key read it');
    const ai = (await carol.call('GET', '/api/ai')).json;
    assert.deepEqual([ai.estimate, ai.voice], [{ provider: 'anthropic', source: 'shared' }, true]);
  } finally {
    delete process.env.OPENAI_API_KEY;
  }
});

const webm = Buffer.concat([Buffer.from([0x1a, 0x45, 0xdf, 0xa3]), Buffer.alloc(2000, 7)]);

test('voice notes: the recording goes to OpenAI as multipart, the words come back, nothing is kept', async () => {
  assert.equal((await bob.call('PUT', '/api/ai/keys/openai', { key: OPENAI_KEY })).status, 200);
  calls.length = 0;
  script = [json({ text: ' Two eggs and toast. ' })];
  const res = await bob.call('POST', '/api/ai/transcribe', undefined, { type: 'audio/webm;codecs=opus', data: webm });
  assert.deepEqual([res.status, res.json], [200, { text: 'Two eggs and toast.' }]);
  const sent = calls[0];
  assert.equal(sent.url, 'https://api.openai.com/v1/audio/transcriptions');
  assert.equal(sent.headers.authorization, `Bearer ${OPENAI_KEY}`);
  assert.ok(!('content-type' in sent.headers), 'FormData sets its own multipart boundary');
  const form = sent.body as FormData;
  assert.deepEqual([form.get('model'), form.get('response_format')], ['gpt-transcribe', 'json']);
  const file = form.get('file') as File;
  assert.deepEqual([file.name, file.type, file.size], ['voice-note.webm', 'audio/webm', webm.length]);
});

test('voice notes: only audio OpenAI reads, that really is what it says, within the size limit, and with a key', async () => {
  calls.length = 0;
  const ogg = await bob.call('POST', '/api/ai/transcribe', undefined, { type: 'audio/ogg', data: Buffer.from('OggS0000000000000000') });
  assert.equal(ogg.status, 415);
  assert.match(ogg.json.error, /WebM, MP4, MP3 or WAV/);
  assert.equal((await bob.call('POST', '/api/ai/transcribe', undefined, { type: 'audio/webm', data: Buffer.from('not really a recording') })).status, 400);
  const big = await bob.call('POST', '/api/ai/transcribe', undefined, { type: 'audio/webm', data: Buffer.concat([webm, Buffer.alloc(4.5 * 1024 * 1024)]) });
  assert.equal(big.status, 413);
  const none = await carol.call('POST', '/api/ai/transcribe', undefined, { type: 'audio/webm', data: webm });
  assert.deepEqual([none.status, none.json.error], [503, 'Voice notes need an OpenAI key. Connect one in your Profile.']);
  assert.equal(calls.length, 0);
  assert.equal((await new Client().call('POST', '/api/ai/transcribe', undefined, { type: 'audio/webm', data: webm })).status, 401, 'members only');
});

test('choosing the shared assistant again, and the chat falls back to it', async () => {
  const back = await bob.call('PUT', '/api/ai/chat', { provider: 'shared' });
  assert.deepEqual([back.json.chatChoice, back.json.chat], ['shared', { provider: 'anthropic', source: 'shared', model: 'claude-opus-5-5' }]);
  const ev = events((await bob.ask('Hello?')).text);
  assert.deepEqual(
    ev.map((e) => e.event),
    ['text', 'done'],
  );
  assert.equal((await usage(bobId)).questions, 1);
});
