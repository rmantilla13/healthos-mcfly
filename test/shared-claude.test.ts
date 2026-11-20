// The shared Claude client (server/ai/sharedClaude.ts): Workload Identity Federation when its rule is set, which wins
// over a leftover ANTHROPIC_API_KEY; the API key otherwise; nothing when neither is set. Every request goes to a fake
// fetch: nothing here calls Anthropic or Vercel.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { WorkloadIdentityError } from '@anthropic-ai/sdk/lib/credentials/types';
import { anthropicError } from '../server/ai/anthropic.ts';
import { AiError } from '../server/ai/provider.ts';
import { buildSharedClaude, federationFrom, sharedClaudeAuth } from '../server/ai/sharedClaude.ts';
import type { McflyClient } from '../server/mcfly.ts';

const RULE = 'fdrl_test';
const ORG = '00000000-0000-0000-0000-000000000000';
const ACCOUNT = 'svac_test';
const FEDERATED = { ANTHROPIC_FEDERATION_RULE_ID: RULE, ANTHROPIC_ORGANIZATION_ID: ORG, ANTHROPIC_SERVICE_ACCOUNT_ID: ACCOUNT };
const ACCESS = 'sk-ant-oat01-test';

type Sent = { url: string; method: string; headers: Record<string, string>; body: any };

const message = {
  id: 'msg_test',
  type: 'message',
  role: 'assistant',
  model: 'claude-opus-5-5',
  content: [{ type: 'text', text: 'Hello' }],
  stop_reason: 'end_turn',
  stop_sequence: null,
  usage: { input_tokens: 5, output_tokens: 1 },
};

/** A fake fetch for the token endpoint and Messages, recording each request. */
function fakeApi(token: (sent: Sent) => Response = () => Response.json({ access_token: ACCESS, token_type: 'Bearer', expires_in: 3600, scope: 'workspace:inference' })) {
  const sent: Sent[] = [];
  const fetchFn = (async (input: string | URL | Request, init?: RequestInit) => {
    const req = new Request(input, init);
    const text = await req.text();
    const one: Sent = { url: req.url, method: req.method, headers: Object.fromEntries(req.headers), body: text ? JSON.parse(text) : null };
    sent.push(one);
    if (one.url.endsWith('/v1/oauth/token')) return token(one);
    if (one.url.startsWith('https://api.anthropic.com/v1/messages')) return Response.json(message);
    return new Response('not found', { status: 404 });
  }) as typeof fetch;
  return { fetchFn, sent };
}

const ask = (client: McflyClient) =>
  client.beta.messages.create({
    model: 'claude-opus-5-5',
    max_tokens: 100,
    betas: ['server-side-fallback-2026-07-01'],
    messages: [{ role: 'user', content: 'Hi' }],
  });

test('federation: trades the Vercel OIDC token once, then sends the Claude token as a bearer on every request', async () => {
  const { fetchFn, sent } = fakeApi();
  let identityCalls = 0;
  const client = buildSharedClaude({
    env: { ...FEDERATED, ANTHROPIC_API_KEY: 'sk-ant-api03-leftover' },
    fetch: fetchFn,
    identityToken: () => (identityCalls++, 'vercel.oidc.jwt'),
  });
  assert.ok(client);
  await ask(client);
  await ask(client);

  const exchanges = sent.filter((s) => s.url.endsWith('/v1/oauth/token'));
  assert.equal(exchanges.length, 1, 'the second question reuses the exchanged token');
  assert.equal(identityCalls, 1);
  assert.equal(exchanges[0].url, 'https://api.anthropic.com/v1/oauth/token');
  assert.equal(exchanges[0].method, 'POST');
  assert.deepEqual(exchanges[0].body, {
    grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
    assertion: 'vercel.oidc.jwt',
    federation_rule_id: RULE,
    organization_id: ORG,
    service_account_id: ACCOUNT,
  });

  const asks = sent.filter((s) => s.url.startsWith('https://api.anthropic.com/v1/messages'));
  assert.equal(asks.length, 2);
  for (const a of asks) {
    assert.equal(a.headers.authorization, `Bearer ${ACCESS}`);
    assert.equal(a.headers['x-api-key'], undefined, 'the leftover API key is never sent');
    const betas = (a.headers['anthropic-beta'] ?? '').split(',').map((b) => b.trim());
    assert.ok(betas.includes('oauth-2025-04-20'), `oauth beta in ${a.headers['anthropic-beta']}`);
    assert.ok(betas.includes('server-side-fallback-2026-07-01'), `fallback beta kept in ${a.headers['anthropic-beta']}`);
  }
});

test('federation: a workspace ID goes into the exchange when set', async () => {
  const { fetchFn, sent } = fakeApi();
  const client = buildSharedClaude({ env: { ...FEDERATED, ANTHROPIC_WORKSPACE_ID: 'wrkspc_test' }, fetch: fetchFn, identityToken: () => 'jwt' });
  await ask(client!);
  assert.equal(sent.find((s) => s.url.endsWith('/v1/oauth/token'))?.body.workspace_id, 'wrkspc_test');
});

test('federation: a refused exchange is a sign-in problem for the admin, not a crash', async () => {
  const { fetchFn } = fakeApi(() => Response.json({ type: 'error', error: { type: 'authentication_error', message: 'Authentication failed' } }, { status: 401 }));
  const client = buildSharedClaude({ env: FEDERATED, fetch: fetchFn, identityToken: () => 'jwt' });
  const err = await ask(client!).then(
    () => null,
    (e: unknown) => e,
  );
  assert.ok(err instanceof WorkloadIdentityError, `got ${String(err)}`);
  const mapped = anthropicError(err);
  assert.ok(mapped instanceof AiError);
  assert.equal(mapped.kind, 'auth');
  assert.equal((anthropicError(new WorkloadIdentityError('busy', 503)) as AiError).kind, 'server');
  assert.equal((anthropicError(new WorkloadIdentityError('no token')) as AiError).kind, 'auth');
});

test('without federation: ANTHROPIC_API_KEY as before, and nothing when neither is set', async () => {
  const { fetchFn, sent } = fakeApi();
  const client = buildSharedClaude({ env: { ANTHROPIC_API_KEY: 'sk-ant-api03-test' }, fetch: fetchFn });
  await ask(client!);
  assert.equal(sent.filter((s) => s.url.endsWith('/v1/oauth/token')).length, 0);
  const a = sent[0];
  assert.ok(a.headers['x-api-key'] === 'sk-ant-api03-test' || a.headers.authorization === 'Bearer sk-ant-api03-test');

  assert.equal(buildSharedClaude({ env: {} }), null);
  // Half a federation config (no organization) isn't federation; blank values count as unset.
  assert.equal(federationFrom({ ANTHROPIC_FEDERATION_RULE_ID: RULE }), null);
  assert.equal(sharedClaudeAuth({ ANTHROPIC_FEDERATION_RULE_ID: RULE, ANTHROPIC_ORGANIZATION_ID: ' ' }), null);
  assert.equal(sharedClaudeAuth({ ...FEDERATED, ANTHROPIC_API_KEY: 'k' }), 'federation');
  assert.equal(sharedClaudeAuth({ ANTHROPIC_API_KEY: 'k' }), 'api_key');
});
