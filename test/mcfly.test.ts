// Ask McFly over HTTP with a scripted fake Claude client: what it can read, for whom, and how often.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { AddressInfo } from 'node:net';
import { createApp } from '../server/app.ts';
import { hashPassword } from '../server/auth.ts';
import { OWNER_ID, upsertDaily } from '../server/db.ts';
import type { McflyClient } from '../server/mcfly.ts';
import { openStore } from '../server/store.ts';

process.env.SESSION_SECRET = 'mcfly-test-secret-'.padEnd(64, 'x');
const OWNER_PASSWORD = 'owner password 123';
process.env.HEALTHOS_PASSWORD_HASH = await hashPassword(OWNER_PASSWORD);

// ---------- a fake Claude: replays scripted replies and records every request ----------

type Block = { type: 'text'; text: string } | { type: 'tool_use'; id: string; name: string; input: unknown };
const reply = (content: Block[], stop_reason: string) => ({
  id: 'msg_test',
  type: 'message',
  role: 'assistant',
  model: 'claude-opus-5-5',
  content,
  stop_reason,
  stop_sequence: null,
  usage: { input_tokens: 100, output_tokens: 20, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 },
});
let script: ReturnType<typeof reply>[] = [];
const requests: any[] = [];
let configured = true;
const fake = {
  beta: {
    messages: {
      stream(params: unknown) {
        requests.push(structuredClone(params));
        const msg = script.shift();
        if (!msg) throw new Error('fake Claude ran out of scripted replies');
        let onText: ((t: string) => void) | undefined;
        return {
          on(event: string, fn: (t: string) => void) {
            if (event === 'text') onText = fn;
            return this;
          },
          async finalMessage() {
            for (const b of msg.content) if (b.type === 'text') onText?.(b.text);
            return msg;
          },
          abort() {},
        };
      },
    },
  },
} as unknown as McflyClient;

const db = await openStore();
const app = createApp({ db, hosted: false, mcflyClient: () => (configured ? fake : null) });
const server = app.listen(0, '127.0.0.1');
await new Promise((r) => server.once('listening', r));
const base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
test.after(() => {
  server.close();
});

class Client {
  cookie = '';
  async call(method: string, path: string, body?: unknown) {
    const res = await fetch(base + path, {
      method,
      headers: { 'X-HealthOS': '1', 'Content-Type': 'application/json', ...(this.cookie ? { Cookie: this.cookie } : {}) },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const set = res.headers.get('set-cookie');
    if (set) this.cookie = set.split(';')[0];
    const text = await res.text();
    let json: any = null;
    try {
      json = JSON.parse(text);
    } catch {
      json = null;
    }
    return { status: res.status, text, json };
  }
  ask(question: string, history: { role: string; content: string }[] = []) {
    return this.call('POST', '/api/mcfly/chat', { messages: [...history, { role: 'user', content: question }] });
  }
}

/** The server-sent events of a chat response. */
const events = (text: string) =>
  text
    .split('\n\n')
    .filter(Boolean)
    .map((chunk) => ({ event: /^event: (.+)$/m.exec(chunk)?.[1], data: JSON.parse(/^data: (.+)$/m.exec(chunk)?.[1] ?? 'null') }));

const owner = new Client();
const bob = new Client();
let bobId = '';
const day = (d: number) => `2026-10-${String(d).padStart(2, '0')}`;

test('setup: an owner and an invited member, each with their own resting heart rate', async () => {
  assert.equal((await owner.call('POST', '/api/auth/login', { email: 'owner@example.com', password: OWNER_PASSWORD })).status, 200);
  const inv = await owner.call('POST', '/api/admin/invites', {});
  const token = inv.json.url.split('/').at(-1);
  assert.equal((await bob.call('POST', '/api/auth/invite', { token, email: 'bob@example.com', name: 'Bob', password: 'bob password 123' })).status, 200);
  bobId = (await bob.call('GET', '/api/auth/me')).json.user.id;
  const rows = (rhr: number) => [10, 11, 12, 13, 14, 15, 16].map((d) => ({ date: day(d), metric: 'resting_hr', source: 'apple', value: rhr }));
  await upsertDaily(db, OWNER_ID, [...rows(60), { date: day(16), metric: 'wrist_temp', source: 'apple', value: 36.5 }]);
  await upsertDaily(db, bobId, rows(80));
});

test("McFly isn't available until an API key is configured", async () => {
  configured = false;
  assert.equal((await bob.ask('How did I sleep?')).status, 503);
  assert.equal((await bob.call('GET', '/api/mcfly')).json.configured, false);
  configured = true;
});

test("McFly's tools read only the asking person's data", async () => {
  requests.length = 0;
  script = [
    reply([{ type: 'tool_use', id: 'tu_1', name: 'get_metric_history', input: { metrics: ['resting_hr'], days: 7, end_date: day(16) } }], 'tool_use'),
    reply([{ type: 'text', text: 'Your resting heart rate averaged **80 bpm**.' }], 'end_turn'),
  ];
  const res = await bob.ask('What was my resting heart rate this week?');
  assert.equal(res.status, 200);
  const ev = events(res.text);
  assert.deepEqual(
    ev.map((e) => e.event),
    ['tool', 'text', 'done'],
  );
  assert.match(ev[0].data.label, /resting heart rate over 7 days/);

  // The model's second request carries the tool result: Bob's 80s, never the owner's 60s.
  const toolResult = requests[1].messages.at(-1).content[0];
  assert.equal(toolResult.type, 'tool_result');
  const result = JSON.parse(toolResult.content);
  assert.equal(result.metrics[0].mean, 80);
  assert.equal(result.metrics[0].daysWithData, 7);
  assert.ok(!toolResult.content.includes('60'));

  // The request itself: Bob's name, the platform model, fallbacks on, every tool eager-streamed.
  assert.match(requests[0].system, /talking with Bob/);
  assert.equal(requests[0].model, 'claude-opus-5-5');
  assert.equal(requests[0].fallbacks, 'default');
  assert.ok(requests[0].tools.every((t: { eager_input_streaming: boolean }) => t.eager_input_streaming));
});

test('the owner reads their own data, in their own units', async () => {
  await owner.call('PUT', '/api/settings', { units: 'imperial' });
  requests.length = 0;
  script = [
    reply([{ type: 'tool_use', id: 'tu_2', name: 'get_metric_history', input: { metrics: ['resting_hr', 'wrist_temp'], days: 7, end_date: day(16) } }], 'tool_use'),
    reply([{ type: 'text', text: 'ok' }], 'end_turn'),
  ];
  await owner.ask('How are my vitals?');
  const result = JSON.parse(requests[1].messages.at(-1).content[0].content);
  assert.equal(result.metrics[0].mean, 60);
  assert.deepEqual([result.metrics[1].unit, result.metrics[1].mean], ['°F', 97.7]);
});

test('a malformed tool input becomes an error result, and the answer continues', async () => {
  requests.length = 0;
  script = [
    reply([{ type: 'tool_use', id: 'tu_3', name: 'get_metric_history', input: { metrics: ['not_a_metric'], days: 7 } }], 'tool_use'),
    reply([{ type: 'text', text: "I couldn't find that metric." }], 'end_turn'),
  ];
  const res = await bob.ask('Show me my glucose');
  const toolResult = requests[1].messages.at(-1).content[0];
  assert.equal(toolResult.is_error, true);
  assert.deepEqual(events(res.text).at(-1)?.event, 'done');
});

test('a refusal is reported instead of a partial answer', async () => {
  script = [reply([{ type: 'text', text: 'Partial' }], 'refusal')];
  const ev = events((await bob.ask('Something McFly declines')).text);
  assert.ok(ev.some((e) => e.event === 'refusal'));
});

test('the history must be a well-formed conversation ending in a question', async () => {
  assert.equal((await bob.call('POST', '/api/mcfly/chat', { messages: [] })).status, 400);
  assert.equal((await bob.call('POST', '/api/mcfly/chat', { messages: [{ role: 'assistant', content: 'hi' }] })).status, 400);
  assert.equal((await bob.call('POST', '/api/mcfly/chat', { messages: [{ role: 'user', content: 'a' }, { role: 'user', content: 'b' }] })).status, 400);
  assert.equal((await bob.ask('x'.repeat(5000))).status, 400);
  // A prior question and answer are passed along as plain text.
  requests.length = 0;
  script = [reply([{ type: 'text', text: 'Sure.' }], 'end_turn')];
  await bob.ask('And last week?', [
    { role: 'user', content: 'How did I sleep?' },
    { role: 'assistant', content: 'About 7 hours.' },
  ]);
  assert.deepEqual(
    requests[0].messages.map((m: { role: string; content: string }) => [m.role, m.content]),
    [
      ['user', 'How did I sleep?'],
      ['assistant', 'About 7 hours.'],
      ['user', 'And last week?'],
    ],
  );
});

test('each person has a daily question limit, and 0 turns McFly off', async () => {
  await owner.call('PUT', '/api/admin/settings', { mcfly_daily_limit: 5 });
  // Bob has asked 4 counted questions so far (the 503 and the 400s above weren't counted).
  const status = (await bob.call('GET', '/api/mcfly')).json;
  assert.deepEqual([status.limit, status.usedToday], [5, 4]);
  script = [reply([{ type: 'text', text: 'ok' }], 'end_turn')];
  assert.equal((await bob.ask('one more')).status, 200);
  const over = await bob.ask('and another');
  assert.equal(over.status, 429);
  assert.match(over.json.error, /5 questions today/);
  // The owner's count is separate.
  script = [reply([{ type: 'text', text: 'ok' }], 'end_turn')];
  assert.equal((await owner.ask('still mine')).status, 200);

  await owner.call('PUT', '/api/admin/settings', { mcfly_daily_limit: 0 });
  assert.equal((await owner.ask('off?')).status, 403);
  await owner.call('PUT', '/api/admin/settings', { mcfly_daily_limit: 50 });
});

test('admins see how much each person used McFly, never what they asked', async () => {
  const ov = (await owner.call('GET', '/api/admin/overview')).json;
  const b = ov.users.find((u: { id: string }) => u.id === bobId);
  assert.equal(b.mcfly.questions30d, 5);
  assert.ok(b.mcfly.tokens30d > 0);
  const raw = JSON.stringify(ov);
  for (const asked of ['resting heart rate this week', 'glucose', 'one more']) assert.ok(!raw.includes(asked));
});

test('only members can use McFly', async () => {
  assert.equal((await new Client().ask('hello')).status, 401);
});
