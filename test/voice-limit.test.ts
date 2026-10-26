// Voice notes on the server's OPENAI_API_KEY: at most VOICE_NOTES_PER_DAY a person a day, counted atomically before the
// call, given back when OpenAI doesn't transcribe it, and never counted as a McFly question. A person's own key isn't
// counted. OpenAI is a fake here; nothing calls it.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { AddressInfo } from 'node:net';
import { VOICE_NOTES_PER_DAY } from '../shared/ai.ts';
import type { AiFetch } from '../server/ai/provider.ts';
import { createApp } from '../server/app.ts';
import { hashPassword } from '../server/auth.ts';
import { OWNER_ID } from '../server/db.ts';
import { usageDay } from '../server/mcfly.ts';
import { openStore } from '../server/store.ts';

delete process.env.HEALTHOS_DATA_KEY_PREVIOUS;
delete process.env.ANTHROPIC_API_KEY;
process.env.HEALTHOS_DATA_KEY = 'd4'.repeat(32);
process.env.SESSION_SECRET = 'voice-limit-test-secret-'.padEnd(64, 'x');
const OWNER_PASSWORD = 'owner password 123';
process.env.HEALTHOS_PASSWORD_HASH = await hashPassword(OWNER_PASSWORD);
// Made-up keys: the server's, and Bob's own.
const SERVER_KEY = 'sk-proj-SERVER-voice-key-0000000000000000';
const BOB_KEY = 'sk-proj-TESTKEY-voice-bob-1234567890abcd0b0b';
process.env.OPENAI_API_KEY = SERVER_KEY;

/** Transcriptions sent, by the key they were sent with. */
const sent: string[] = [];
let reply: () => Response = () => new Response(JSON.stringify({ text: 'Two eggs.' }));
const aiFetch: AiFetch = async (url, init) => {
  const auth = new Headers(init?.headers).get('authorization') ?? '';
  if (url.endsWith('/models')) return new Response(JSON.stringify({ data: [] }));
  if (url.endsWith('/audio/transcriptions')) {
    sent.push(auth.replace('Bearer ', ''));
    return reply();
  }
  return new Response('{}', { status: 404 });
};

const db = await openStore();
const server = createApp({ db, hosted: false, mcflyClient: () => null, aiFetch }).listen(0, '127.0.0.1');
await new Promise((r) => server.once('listening', r));
const base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
test.after(() => {
  server.close();
});

const webm = Buffer.concat([Buffer.from([0x1a, 0x45, 0xdf, 0xa3]), Buffer.alloc(2000, 7)]);

class Client {
  cookie = '';
  async call(method: string, path: string, body?: unknown) {
    const audio = path === '/api/ai/transcribe';
    const res = await fetch(base + path, {
      method,
      headers: { 'X-HealthOS': '1', 'Content-Type': audio ? 'audio/webm' : 'application/json', ...(this.cookie ? { Cookie: this.cookie } : {}) },
      body: audio ? new Blob([new Uint8Array(webm)]) : body === undefined ? undefined : JSON.stringify(body),
    });
    const set = res.headers.get('set-cookie');
    if (set) this.cookie = set.split(';')[0];
    return { status: res.status, json: (await res.json().catch(() => null)) as any };
  }
  note = () => this.call('POST', '/api/ai/transcribe');
}

const owner = new Client();
const bob = new Client();
let bobId = '';

async function usage(userId: string) {
  const [r] = await db.query<{ voice_notes: number; questions: number; own_questions: number }>(
    'SELECT voice_notes, questions, own_questions FROM mcfly_usage WHERE user_id = $1 AND day = $2',
    [userId, usageDay()],
  );
  return r ? { voiceNotes: Number(r.voice_notes), questions: Number(r.questions), ownQuestions: Number(r.own_questions) } : null;
}
const setUsed = (userId: string, n: number) =>
  db.query(
    `INSERT INTO mcfly_usage (user_id, day, voice_notes) VALUES ($1, $2, $3) ON CONFLICT (user_id, day) DO UPDATE SET voice_notes = excluded.voice_notes`,
    [userId, usageDay(), n],
  );

test('setup: the owner and an invited member', async () => {
  assert.equal((await owner.call('POST', '/api/auth/login', { email: 'owner@example.com', password: OWNER_PASSWORD })).status, 200);
  const token = (await owner.call('POST', '/api/admin/invites', {})).json.url.split('/').at(-1);
  assert.equal((await bob.call('POST', '/api/auth/invite', { token, email: 'bob@example.com', name: 'Bob', password: 'Bob password 123' })).status, 200);
  bobId = (await bob.call('GET', '/api/auth/me')).json.user.id;
});

test('on the shared key a voice note counts as a voice note, never as a McFly question', async () => {
  const res = await owner.note();
  assert.deepEqual([res.status, res.json], [200, { text: 'Two eggs.' }]);
  assert.deepEqual(sent, [SERVER_KEY]);
  assert.deepEqual(await usage(OWNER_ID), { voiceNotes: 1, questions: 0, ownQuestions: 0 });
});

test('a note OpenAI didn’t transcribe is given back', async () => {
  for (const [r, status] of [
    [() => new Response('{}', { status: 500 }), 503],
    [() => new Response(JSON.stringify({ error: { code: 'invalid_api_key' } }), { status: 401 }), 502],
    [() => new Response('not json'), 503],
  ] as const) {
    reply = r;
    assert.equal((await owner.note()).status, status);
  }
  reply = () => new Response(JSON.stringify({ text: 'Two eggs.' }));
  assert.equal((await usage(OWNER_ID))?.voiceNotes, 1);
});

test(`at ${VOICE_NOTES_PER_DAY} a day, the next one is refused in plain words and goes nowhere`, async () => {
  await setUsed(OWNER_ID, VOICE_NOTES_PER_DAY);
  sent.length = 0;
  const res = await owner.note();
  assert.equal(res.status, 429);
  assert.equal(
    res.json.error,
    `You've used today's ${VOICE_NOTES_PER_DAY} voice notes on healthOS's shared key. Type what you had instead, or connect your own OpenAI key in your Profile.`,
  );
  assert.equal(sent.length, 0);
  assert.equal((await usage(OWNER_ID))?.voiceNotes, VOICE_NOTES_PER_DAY);
  // Yesterday's count doesn't carry over.
  await db.query('UPDATE mcfly_usage SET day = $2 WHERE user_id = $1 AND day = $3', [OWNER_ID, '2000-01-01', usageDay()]);
  assert.equal((await owner.note()).status, 200);
  assert.equal((await usage(OWNER_ID))?.voiceNotes, 1);
});

test('notes sent at once can’t pass the limit together', async () => {
  await setUsed(OWNER_ID, VOICE_NOTES_PER_DAY - 1);
  const results = await Promise.all(Array.from({ length: 4 }, () => owner.note()));
  assert.deepEqual(results.map((r) => r.status).sort(), [200, 429, 429, 429]);
  assert.equal((await usage(OWNER_ID))?.voiceNotes, VOICE_NOTES_PER_DAY);
});

test('on their own OpenAI key a person’s notes aren’t counted or capped', async () => {
  assert.equal((await bob.call('PUT', '/api/ai/keys/openai', { key: BOB_KEY })).status, 200);
  await setUsed(bobId, VOICE_NOTES_PER_DAY);
  sent.length = 0;
  for (let i = 0; i < 3; i++) assert.equal((await bob.note()).status, 200);
  reply = () => new Response('{}', { status: 500 });
  assert.equal((await bob.note()).status, 503);
  reply = () => new Response(JSON.stringify({ text: 'Two eggs.' }));
  assert.deepEqual(sent, [BOB_KEY, BOB_KEY, BOB_KEY, BOB_KEY]);
  assert.deepEqual(await usage(bobId), { voiceNotes: VOICE_NOTES_PER_DAY, questions: 0, ownQuestions: 0 });
});
