// The server's shared Claude client: the one Ask McFly, meal estimates and lab reading use when a person has no key
// of their own. Two ways to authenticate it, picked from the environment:
// - Workload Identity Federation (the hosted app on Vercel): ANTHROPIC_FEDERATION_RULE_ID and ANTHROPIC_ORGANIZATION_ID
//   are set. Each Vercel function request carries a short-lived OIDC token in its x-vercel-oidc-token header; the SDK
//   trades it at POST /v1/oauth/token for a Claude token bound to a Claude Console service account, and trades again
//   before that one expires. No Claude secret is stored anywhere. This wins over ANTHROPIC_API_KEY when both are set.
// - ANTHROPIC_API_KEY (local development, or before federation is set up).
// The client is built once and kept, so the exchanged token is reused across requests instead of traded on every call.
import Anthropic from '@anthropic-ai/sdk';
import { oidcFederationProvider } from '@anthropic-ai/sdk/lib/credentials/oidc-federation';
import { WorkloadIdentityError } from '@anthropic-ai/sdk/lib/credentials/types';
import { getVercelOidcToken } from '@vercel/oidc';
import type { McflyClient } from '../mcfly.ts';

export const CLAUDE_API = 'https://api.anthropic.com';

export type Federation = { ruleId: string; organizationId: string; serviceAccountId?: string; workspaceId?: string };
export type SharedClaudeAuth = 'federation' | 'api_key';

const value = (s: string | undefined) => s?.trim() || undefined;

/** The federation rule to use, when both of its required IDs are set. */
export function federationFrom(env: NodeJS.ProcessEnv = process.env): Federation | null {
  const ruleId = value(env.ANTHROPIC_FEDERATION_RULE_ID);
  const organizationId = value(env.ANTHROPIC_ORGANIZATION_ID);
  if (!ruleId || !organizationId) return null;
  return { ruleId, organizationId, serviceAccountId: value(env.ANTHROPIC_SERVICE_ACCOUNT_ID), workspaceId: value(env.ANTHROPIC_WORKSPACE_ID) };
}

/** How the shared client authenticates, or null when it isn't set up. */
export function sharedClaudeAuth(env: NodeJS.ProcessEnv = process.env): SharedClaudeAuth | null {
  if (federationFrom(env)) return 'federation';
  return value(env.ANTHROPIC_API_KEY) ? 'api_key' : null;
}

// The newest OIDC token Vercel sent with a request (server/app.ts notes it on every hosted request). Every request's
// token names the same project and environment, and a token exchange only happens while a request is being handled,
// after its own token was noted, so this is never older than the request that needs it.
let latestOidcToken: string | undefined;

export function noteOidcToken(header: unknown) {
  if (typeof header === 'string' && header) latestOidcToken = header;
}

async function vercelIdentityToken(): Promise<string> {
  if (latestOidcToken) return latestOidcToken;
  // Locally (`vercel env pull` writes VERCEL_OIDC_TOKEN), or a request that reached us without the header.
  try {
    return await getVercelOidcToken();
  } catch {
    throw new WorkloadIdentityError(
      'No Vercel OIDC token. Turn on Settings → Security → Secure backend access with OIDC federation for the project.',
    );
  }
}

type Build = { env?: NodeJS.ProcessEnv; fetch?: typeof fetch; identityToken?: () => string | Promise<string> };

/** A new shared client for this environment, or null when neither federation nor ANTHROPIC_API_KEY is set. */
export function buildSharedClaude({ env = process.env, fetch: fetchFn = globalThis.fetch, identityToken = vercelIdentityToken }: Build = {}): McflyClient | null {
  const federation = federationFrom(env);
  if (federation) {
    const exchange = oidcFederationProvider({
      identityTokenProvider: identityToken,
      federationRuleId: federation.ruleId,
      organizationId: federation.organizationId,
      serviceAccountId: federation.serviceAccountId,
      workspaceId: federation.workspaceId,
      baseURL: CLAUDE_API,
      fetch: fetchFn,
    });
    return new Anthropic({
      // Explicit nulls, or a leftover ANTHROPIC_API_KEY in the environment would win over the federated token.
      apiKey: null,
      authToken: null,
      baseURL: CLAUDE_API,
      fetch: fetchFn,
      credentials: async (opts) => {
        try {
          return await exchange(opts);
        } catch (err) {
          // Only the status and the SDK's own (redacted) message: never a token. The reason a rule turned a token
          // down is in the Claude Console under Workload identity → Authentication history.
          console.error('claude federation:', err instanceof WorkloadIdentityError ? `${err.statusCode ?? 'no status'} ${err.message}` : err instanceof Error ? err.name : 'error');
          throw err;
        }
      },
    });
  }
  const apiKey = value(env.ANTHROPIC_API_KEY);
  return apiKey ? new Anthropic({ apiKey, fetch: fetchFn }) : null;
}

let kept: { fingerprint: string; client: McflyClient | null } | undefined;

/** The shared client, built once per configuration (tests change the environment between cases). */
export function sharedClaude(): McflyClient | null {
  const env = process.env;
  const fingerprint = JSON.stringify([federationFrom(env), value(env.ANTHROPIC_API_KEY) ?? null]);
  if (kept?.fingerprint !== fingerprint) kept = { fingerprint, client: buildSharedClaude({ env }) };
  return kept.client;
}
