// Claude, through the Anthropic SDK client McFly has always used (the server's shared key, or a person's own). The
// requests are the ones McFly made before other providers existed: eager input streaming on every tool, the
// server-side fallback beta, prompt caching, pause_turn, refusals, and re-issuing a round whose streamed tool input
// wasn't parseable JSON.
import Anthropic from '@anthropic-ai/sdk';
import type { McflyClient } from '../mcfly.ts';
import { AiError, type ChatProviderApi, type ChatSession, type Reply, type Usage, kindOf } from './provider.ts';

type BetaMessageParam = Anthropic.Beta.BetaMessageParam;
type BetaTool = Anthropic.Beta.BetaTool;
type BetaMessage = Anthropic.Beta.BetaMessage;
type BetaToolUseBlock = Anthropic.Beta.BetaToolUseBlock;
type BetaToolResultBlockParam = Anthropic.Beta.BetaToolResultBlockParam;
type BetaContentBlockParam = Anthropic.Beta.BetaContentBlockParam;

/** An SDK error as a kind; anything else (an abort, a bug) as it was. A 400 about the credit balance is out of credit. */
export function anthropicError(err: unknown): unknown {
  if (err instanceof Anthropic.APIUserAbortError) return err;
  if (err instanceof Anthropic.APIConnectionError) return new AiError('network');
  if (err instanceof Anthropic.APIError && typeof err.status === 'number') return new AiError(kindOf(err.status, err.status === 400 && /credit balance/i.test(err.message)), err.status);
  return err;
}

const usageOf = (m: BetaMessage): Usage => ({
  input: m.usage.input_tokens + (m.usage.cache_read_input_tokens ?? 0) + (m.usage.cache_creation_input_tokens ?? 0),
  output: m.usage.output_tokens,
});

const textOf = (m: BetaMessage) =>
  m.content
    .filter((b): b is Anthropic.Beta.BetaTextBlock => b.type === 'text')
    .map((b) => b.text)
    .join('');

const replyOf = (m: BetaMessage, text: string): Reply => ({
  text: m.stop_reason === 'refusal' ? '' : text,
  stop: m.stop_reason === 'refusal' ? 'refusal' : m.stop_reason === 'max_tokens' ? 'length' : 'end',
  usage: usageOf(m),
});

export function anthropicProvider(client: McflyClient, model: string): ChatProviderApi {
  return {
    id: 'anthropic',

    chat({ system, tools, history, maxTokens }): ChatSession {
      const messages: BetaMessageParam[] = history.map((t) => ({ role: t.role, content: t.content }));
      // Eager streaming, so tool inputs arrive unvalidated: every tool checks its own.
      const apiTools: BetaTool[] = tools.map(({ name, description, schema }) => ({ name, description, input_schema: schema as BetaTool['input_schema'], eager_input_streaming: true }));
      let jsonRetries = 0;
      return {
        async next(onText, signal) {
          const stream = client.beta.messages.stream(
            {
              model,
              max_tokens: maxTokens,
              output_config: { effort: 'medium' },
              // A classifier false positive is retried on Anthropic's recommended model instead of failing.
              betas: ['server-side-fallback-2026-07-01'],
              fallbacks: 'default',
              cache_control: { type: 'ephemeral' },
              system,
              tools: apiTools,
              messages,
            },
            { signal },
          );
          stream.on('text', onText);
          let message: BetaMessage;
          try {
            message = await stream.finalMessage();
            jsonRetries = 0;
          } catch (err) {
            // With eager input streaming, a tool input that isn't parseable JSON rejects the turn: re-issue it.
            if (err instanceof Anthropic.APIError || signal.aborted || jsonRetries++ >= 2) throw anthropicError(err);
            return { stop: 'continue', calls: [], usage: { input: 0, output: 0 } };
          }
          const usage = usageOf(message);
          if (message.stop_reason === 'refusal') return { stop: 'refusal', calls: [], usage };
          if (message.stop_reason === 'pause_turn') {
            messages.push({ role: 'assistant', content: message.content });
            return { stop: 'continue', calls: [], usage };
          }
          const calls = message.content.filter((b): b is BetaToolUseBlock => b.type === 'tool_use');
          if (message.stop_reason !== 'tool_use' || calls.length === 0) return { stop: message.stop_reason === 'max_tokens' ? 'length' : 'end', calls: [], usage };
          messages.push({ role: 'assistant', content: message.content });
          return {
            stop: 'tool_calls',
            calls: calls.map((c) => ({
              id: c.id,
              name: c.name,
              input: c.input && typeof c.input === 'object' && !Array.isArray(c.input) ? (c.input as Record<string, unknown>) : null,
            })),
            usage,
          };
        },
        addResults(results) {
          messages.push({
            role: 'user',
            content: results.map(
              (r): BetaToolResultBlockParam =>
                r.isError ? { type: 'tool_result', tool_use_id: r.id, is_error: true, content: r.content } : { type: 'tool_result', tool_use_id: r.id, content: r.content },
            ),
          });
        },
      };
    },

    async text({ system, text, maxTokens }) {
      try {
        // No cache_control: a one-off prompt is read once.
        const message = await client.beta.messages.create({
          model,
          max_tokens: maxTokens,
          output_config: { effort: 'medium' },
          betas: ['server-side-fallback-2026-07-01'],
          fallbacks: 'default',
          system,
          messages: [{ role: 'user', content: text }],
        });
        return replyOf(message, textOf(message).trim());
      } catch (err) {
        throw anthropicError(err);
      }
    },

    async json({ system, text, image, schema, maxTokens }) {
      const content: BetaContentBlockParam[] = [];
      if (image) content.push({ type: 'image', source: { type: 'base64', media_type: image.mediaType, data: image.data } });
      content.push({ type: 'text', text });
      try {
        const message = await client.beta.messages.create({
          model,
          max_tokens: maxTokens,
          output_config: { effort: 'medium', format: { type: 'json_schema', schema } },
          system,
          messages: [{ role: 'user', content }],
        });
        return replyOf(message, message.content.find((b): b is Anthropic.Beta.BetaTextBlock => b.type === 'text')?.text ?? '');
      } catch (err) {
        throw anthropicError(err);
      }
    },
  };
}
