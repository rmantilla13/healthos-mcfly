// Your own AI keys (server/ai/keys.ts, /api/ai): sealed with HEALTHOS_DATA_KEY and bound to their owner and provider,
// checked with the provider before they're kept, and never sent back, logged or readable from the database.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { AddressInfo } from 'node:net';
import { open, ownKeys, seal } from '../server/ai/keys.ts';
import type { AiFetch } from '../server/ai/provider.ts';
import { createApp } from '../server/app.ts';
import { hashPassword } from '../server/auth.ts';
import { OWNER_ID } from '../server/db.ts';
import { openStore } from '../server/store.ts';

// Made-up secrets only; and nothing from the shell may change which AI is used.
delete process.env.OPENAI_API_KEY;
delete process.env.ANTHROPIC_API_KEY;
delete process.env.HEALTHOS_DATA_KEY_PREVIOUS;
const DATA_KEY = 'a1'.repeat(32);
process.env.HEALTHOS_DATA_KEY = DATA_KEY;
process.env.SESSION_SECRET = 'ai-keys-test-secret-'.padEnd(64, 'x');
const OWNER_PASSWORD = 'owner password 123';
process.env.HEALTHOS_PASSWORD_HASH = await hashPassword(OWNER_PASSWORD);

const OPENAI_KEY = 'sk-proj-TESTKEY-openai-1234567890abcdef9c1d';
const CLAUDE_KEY = 'sk-ant-api03-TESTKEY-claude-1234567890abcd4f2a';
const GEMINI_KEY = 'AIzaSyTESTKEY-gemini-12345678901234567x9z';

// The providers' model lists, as a fake: a key is good when it's one of ours.
const checks: { url: string; headers: Record<string, string> }[] = [];
let down = false;
const aiFetch: AiFetch = async (url, init) => {
  const headers = Object.fromEntries(new Headers(init?.headers).entries());
  checks.push({ url, headers });
  if (down) throw new TypeError('fetch failed');
  const key = headers['x-api-key'] ?? headers['x-goog-api-key'] ?? headers.authorization?.replace(/^Bearer /, '');
  const good = [OPENAI_KEY, CLAUDE_KEY, GEMINI_KEY].includes(key ?? '');
  if (good) return new Response(JSON.stringify({ data: [] }));
  // Gemini answers a key it doesn't know with a 400; the others with a 401, which echoes part of the key.
  if (url.includes('googleapis')) return new Response(JSON.stringify({ error: { code: 400, status: 'INVALID_ARGUMENT', details: [{ reason: 'API_KEY_INVALID' }] } }), { status: 400 });
  return new Response(JSON.stringify({ error: { message: `Incorrect API key provided: ${key?.slice(0, 6)}***`, code: 'invalid_api_key' } }), { status: 401 });
};

const db = await openStore();
const server = createApp({ db, hosted: false, mcflyClient: () => null, aiFetch }).listen(0, '127.0.0.1');
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
}

const owner = new Client();
const bob = new Client();
let bobId = '';

test('setup: an owner and an invited member', async () => {
  assert.equal((await owner.call('POST', '/api/auth/login', { email: 'owner@example.com', password: OWNER_PASSWORD })).status, 200);
  const inv = await owner.call('POST', '/api/admin/invites', {});
  const token = inv.json.url.split('/').at(-1);
  assert.equal((await bob.call('POST', '/api/auth/invite', { token, email: 'bob@example.com', name: 'Bob', password: 'bob password 123' })).status, 200);
  bobId = (await bob.call('GET', '/api/auth/me')).json.user.id;
});

test('sealing: a round trip, a fresh IV each time, and a row bound to its owner and provider', () => {
  const a = seal('user-a', 'openai', OPENAI_KEY);
  const b = seal('user-a', 'openai', OPENAI_KEY);
  assert.notDeepEqual(a.iv, b.iv);
  assert.notDeepEqual(a.ciphertext, b.ciphertext);
  assert.equal(a.iv.length, 12);
  assert.ok(!a.ciphertext.toString('latin1').includes('TESTKEY'));
  assert.deepEqual(open('user-a', 'openai', a), { secret: OPENAI_KEY, stale: false });
  assert.equal(open('user-b', 'openai', a), null, 'moved to another account, it does not open');
  assert.equal(open('user-a', 'gemini', a), null, 'or to another provider');
  assert.equal(open('user-a', 'openai', { ...a, tag: Buffer.alloc(16) }), null, 'or altered');
});

test('without HEALTHOS_DATA_KEY nobody can store a key, and the reason is in plain words', async () => {
  delete process.env.HEALTHOS_DATA_KEY;
  try {
    const status = (await bob.call('GET', '/api/ai')).json;
    assert.deepEqual([status.byok, status.keys, status.chat, status.chatChoice], [false, [], null, 'shared']);
    const res = await bob.call('PUT', '/api/ai/keys/openai', { key: OPENAI_KEY });
    assert.equal(res.status, 503);
    assert.equal(res.json.error, "Connecting your own key isn't set up on this server.");
    assert.equal((await bob.call('PUT', '/api/ai/chat', { provider: 'openai' })).status, 503);
    assert.equal(checks.length, 0, 'nothing was sent to a provider');
  } finally {
    process.env.HEALTHOS_DATA_KEY = DATA_KEY;
  }
});

test('a key is checked first: its shape, then with the provider; a refusal says so and stores nothing', async () => {
  checks.length = 0;
  for (const [provider, key, error] of [
    ['openai', 'short', /doesn't look like an API key/],
    ['openai', `${OPENAI_KEY} extra`, /doesn't look like an API key/],
    ['openai', CLAUDE_KEY, /looks like a Claude key/],
    ['anthropic', GEMINI_KEY, /looks like a Gemini key/],
  ] as const) {
    const res = await bob.call('PUT', `/api/ai/keys/${provider}`, { key });
    assert.equal(res.status, 400);
    assert.match(res.json.error, error);
  }
  assert.equal(checks.length, 0, 'a key that cannot be right is never sent anywhere');
  assert.equal((await bob.call('PUT', '/api/ai/keys/openai', { key: OPENAI_KEY, model: 'gpt/../../x' })).status, 400, 'a model id is checked too');
  assert.equal((await bob.call('PUT', '/api/ai/keys/mistral', { key: OPENAI_KEY })).status, 404);

  const wrong = await bob.call('PUT', '/api/ai/keys/openai', { key: 'sk-proj-WRONGKEY-1234567890abcdefgh' });
  assert.deepEqual([wrong.status, wrong.json.error], [400, "That key wasn't accepted by OpenAI."]);
  assert.ok(!wrong.text.includes('sk-pro'), "the provider's own message, which echoes the key, isn't passed on");
  const wrongGemini = await bob.call('PUT', '/api/ai/keys/gemini', { key: 'AIzaSyWRONGKEY-1234567890123456789012' });
  assert.deepEqual([wrongGemini.status, wrongGemini.json.error], [400, "That key wasn't accepted by Gemini."]);
  down = true;
  const unreachable = await bob.call('PUT', '/api/ai/keys/anthropic', { key: CLAUDE_KEY });
  down = false;
  assert.deepEqual([unreachable.status, unreachable.json.error], [502, "Couldn't reach Claude to check the key. Try again in a moment."]);
  assert.equal((await db.query('SELECT 1 FROM ai_keys')).length, 0);
});

test('each provider is asked the way its docs say: key in a header, never in the URL', async () => {
  checks.length = 0;
  for (const [provider, key] of [
    ['openai', OPENAI_KEY],
    ['anthropic', CLAUDE_KEY],
    ['gemini', GEMINI_KEY],
  ] as const) {
    assert.equal((await bob.call('PUT', `/api/ai/keys/${provider}`, { key })).status, 200, provider);
  }
  const [o, a, g] = checks;
  assert.deepEqual([o.url, o.headers.authorization], ['https://api.openai.com/v1/models', `Bearer ${OPENAI_KEY}`]);
  assert.deepEqual([a.url, a.headers['x-api-key'], a.headers['anthropic-version']], ['https://api.anthropic.com/v1/models?limit=1', CLAUDE_KEY, '2023-06-01']);
  assert.deepEqual([g.url, g.headers['x-goog-api-key']], ['https://generativelanguage.googleapis.com/v1beta/models?pageSize=1', GEMINI_KEY]);
  for (const c of checks) assert.ok(!/key=|AIza|sk-/.test(c.url));
});

test('what comes back is the provider and the last 4, never the key; the database holds only ciphertext', async () => {
  const status = await bob.call('GET', '/api/ai');
  assert.equal(status.json.byok, true);
  assert.deepEqual(
    status.json.keys.map((k: { provider: string; last4: string }) => [k.provider, k.last4]),
    [
      ['anthropic', '4f2a'],
      ['gemini', '7x9z'],
      ['openai', '9c1d'],
    ],
  );
  for (const res of [status, await bob.call('PUT', '/api/ai/keys/openai', { key: OPENAI_KEY }), await owner.call('GET', '/api/admin/overview')]) {
    for (const key of [OPENAI_KEY, CLAUDE_KEY, GEMINI_KEY]) assert.ok(!res.text.includes(key) && !res.text.includes(key.slice(0, 20)));
    assert.ok(!res.text.includes('ciphertext'));
  }
  const rows = await db.query<{ ciphertext: Uint8Array; iv: Uint8Array; tag: Uint8Array; last4: string }>('SELECT ciphertext, iv, tag, last4 FROM ai_keys WHERE user_id = $1', [bobId]);
  assert.equal(rows.length, 3);
  for (const r of rows) {
    const raw = Buffer.concat([Buffer.from(r.ciphertext), Buffer.from(r.iv), Buffer.from(r.tag)]).toString('latin1');
    assert.ok(!raw.includes('TESTKEY') && !raw.includes('sk-') && !raw.includes('AIza'));
  }
  // Nobody else's status shows them.
  assert.deepEqual((await owner.call('GET', '/api/ai')).json.keys, []);
});

test("a row copied into someone else's account doesn't open there", async () => {
  await db.query(
    `INSERT INTO ai_keys (user_id, provider, ciphertext, iv, tag, key_version, last4, model, created_at, updated_at)
     SELECT $2, provider, ciphertext, iv, tag, key_version, last4, model, created_at, updated_at FROM ai_keys WHERE user_id = $1 AND provider = 'openai'`,
    [bobId, OWNER_ID],
  );
  assert.equal((await ownKeys(db, OWNER_ID)).size, 0);
  const status = (await owner.call('GET', '/api/ai')).json;
  assert.equal(status.keys[0].lastError, 'unreadable');
  assert.equal(status.estimate, null, 'and nothing runs on it');
  assert.equal((await owner.call('DELETE', '/api/ai/keys/openai')).status, 200);
});

test('rotating HEALTHOS_DATA_KEY: rows sealed with the previous key still open, and are sealed again with the new one', async () => {
  const before = await db.query<{ key_version: number }>("SELECT key_version FROM ai_keys WHERE user_id = $1 AND provider = 'openai'", [bobId]);
  process.env.HEALTHOS_DATA_KEY = 'b2'.repeat(32);
  process.env.HEALTHOS_DATA_KEY_PREVIOUS = DATA_KEY;
  try {
    assert.equal((await ownKeys(db, bobId)).get('openai')?.key, OPENAI_KEY);
    const after = await db.query<{ key_version: number }>("SELECT key_version FROM ai_keys WHERE user_id = $1 AND provider = 'openai'", [bobId]);
    assert.notEqual(Number(after[0].key_version), Number(before[0].key_version));
    delete process.env.HEALTHOS_DATA_KEY_PREVIOUS;
    assert.equal((await ownKeys(db, bobId)).get('openai')?.key, OPENAI_KEY, 'now under the new key alone');
  } finally {
    // Back to the first key: these rows are under the second now, so keep it as the previous one.
    process.env.HEALTHOS_DATA_KEY = DATA_KEY;
    process.env.HEALTHOS_DATA_KEY_PREVIOUS = 'b2'.repeat(32);
  }
  assert.equal((await ownKeys(db, bobId)).size, 3);
  delete process.env.HEALTHOS_DATA_KEY_PREVIOUS;
});

test("the chat's provider: only one with a stored key; removing that key goes back to the shared assistant", async () => {
  assert.equal((await owner.call('PUT', '/api/ai/chat', { provider: 'gemini' })).status, 400, 'the owner has no Gemini key');
  assert.equal((await bob.call('PUT', '/api/ai/chat', { provider: 'gemini', model: 'gemini/../../keys' })).status, 400);
  assert.equal((await bob.call('PUT', '/api/ai/chat', { provider: 'nope' })).status, 400);
  const chosen = await bob.call('PUT', '/api/ai/chat', { provider: 'gemini', model: 'gemini-3.8-flash' });
  assert.deepEqual([chosen.json.chatChoice, chosen.json.chat], ['gemini', { provider: 'gemini', source: 'own', model: 'gemini-3.8-flash' }]);
  const removed = await bob.call('DELETE', '/api/ai/keys/gemini');
  assert.deepEqual([removed.json.chatChoice, removed.json.chat], ['shared', null], 'no shared key on this server: nothing');
  assert.equal((await db.query("SELECT 1 FROM user_settings WHERE user_id = $1 AND key IN ('chat_provider', 'chat_model')", [bobId])).length, 0);
});

test("a stored key's model can change without the key, and a replaced key keeps it", async () => {
  checks.length = 0;
  const changed = await bob.call('PUT', '/api/ai/keys/openai', { model: 'gpt-6-astra' });
  assert.equal(changed.status, 200);
  assert.equal(changed.json.keys.find((k: { provider: string }) => k.provider === 'openai').model, 'gpt-6-astra');
  assert.equal(checks.length, 0, 'nothing to check with OpenAI');
  const replaced = await bob.call('PUT', '/api/ai/keys/openai', { key: OPENAI_KEY });
  assert.equal(replaced.json.keys.find((k: { provider: string }) => k.provider === 'openai').model, 'gpt-6-astra');
  assert.equal((await bob.call('PUT', '/api/ai/chat', { provider: 'openai' })).json.chat.model, 'gpt-6-astra');
  assert.equal((await bob.call('PUT', '/api/ai/keys/gemini', {})).status, 400, 'no key stored there, and none sent');
});

test('an account deletion takes its keys', async () => {
  assert.ok((await db.query('SELECT 1 FROM ai_keys WHERE user_id = $1', [bobId])).length > 0);
  assert.equal((await owner.call('DELETE', `/api/admin/users/${bobId}`)).status, 200);
  assert.equal((await db.query('SELECT 1 FROM ai_keys WHERE user_id = $1', [bobId])).length, 0);
});
