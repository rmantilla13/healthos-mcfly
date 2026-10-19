// Ask McFly over HTTP with a scripted fake Claude client: what it can read, for whom, and how often.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { AddressInfo } from 'node:net';
import { createApp } from '../server/app.ts';
import { hashPassword } from '../server/auth.ts';
import { addDays, todayLocal } from '../server/dates.ts';
import { OWNER_ID, getUserSetting, setUserSetting, upsertDaily } from '../server/db.ts';
import { type McflyClient, digestWeek } from '../server/mcfly.ts';
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
/** The digest's (non-streaming) call waits on this, so a test can hold it open. */
let gate: Promise<void> = Promise.resolve();
const fake = {
  beta: {
    messages: {
      async create(params: unknown) {
        requests.push(structuredClone(params));
        await gate;
        const msg = script.shift();
        if (!msg) throw new Error('fake Claude ran out of scripted replies');
        return msg;
      },
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

test("a question that fails before any answer doesn't count against the limit", async () => {
  const before = (await bob.call('GET', '/api/mcfly')).json.usedToday;
  script = []; // the fake throws: like an API error before any text
  const ev = events((await bob.ask('Will this fail?')).text);
  assert.equal(ev.at(-1)?.event, 'error');
  assert.equal((await bob.call('GET', '/api/mcfly')).json.usedToday, before);
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

test("the owner's walking speed comes back in their units", async () => {
  await upsertDaily(db, OWNER_ID, [14, 15, 16].map((d) => ({ date: day(d), metric: 'walking_speed', source: 'apple', value: 4.8 })));
  requests.length = 0;
  script = [
    reply([{ type: 'tool_use', id: 'tu_4', name: 'get_metric_history', input: { metrics: ['walking_speed'], days: 7, end_date: day(16) } }], 'tool_use'),
    reply([{ type: 'text', text: 'ok' }], 'end_turn'),
  ];
  await owner.ask('How fast do I walk?');
  const result = JSON.parse(requests[1].messages.at(-1).content[0].content);
  assert.deepEqual([result.metrics[0].label, result.metrics[0].unit, result.metrics[0].mean], ['Walking speed', 'mph', 2.98]);
});

// ---------- charts in answers ----------

test("McFly's charts carry the person's own numbers, read by the server, and McFly hears what was drawn", async () => {
  requests.length = 0;
  script = [
    reply(
      [
        { type: 'text', text: 'Steady all week.' },
        { type: 'tool_use', id: 'tv_1', name: 'show_visual', input: { kind: 'bars', metric: 'resting_hr', days: 7, end_date: day(16), title: 'Resting heart rate, this week' } },
      ],
      'tool_use',
    ),
    reply([{ type: 'text', text: '- Averaged **80 bpm**.' }], 'end_turn'),
  ];
  const ev = events((await bob.ask('Show my resting heart rate this week')).text);
  assert.deepEqual(
    ev.map((e) => e.event),
    ['text', 'tool', 'visual', 'text', 'text', 'done'],
  );
  const visual = ev.find((e) => e.event === 'visual')!.data.visual;
  assert.equal(visual.kind, 'bars');
  assert.equal(visual.unit, 'bpm');
  assert.equal(visual.points.length, 7);
  assert.ok(visual.points.every((p: { value: number }) => p.value === 80), "Bob's own 80s, never the owner's 60s");
  // McFly gets a summary of the chart, not the chart.
  const toolResult = JSON.parse(requests[1].messages.at(-1).content[0].content);
  assert.deepEqual([toolResult.shown, toolResult.averageOfDays, toolResult.daysWithData, toolResult.chartShows], ['bars', 80, 7, 'one value per day']);
  // The answer shape asks for a picture where it helps.
  assert.match(requests[0].system, /show_visual/);
  assert.ok(requests[0].tools.some((t: { name: string }) => t.name === 'show_visual'));
});

test('a comparison of two periods, and tiles, in the person\'s units', async () => {
  requests.length = 0;
  script = [
    reply(
      [
        {
          type: 'tool_use',
          id: 'tv_2',
          name: 'show_visual',
          input: { kind: 'compare', metric: 'resting_hr', title: 'Resting heart rate', periods: [{ label: 'Last 3 days', days: 3, end_date: day(16) }, { label: 'The 3 before', days: 3, end_date: day(13) }] },
        },
        { type: 'tool_use', id: 'tv_3', name: 'show_visual', input: { kind: 'stats', metrics: ['resting_hr', 'wrist_temp'], stat: 'latest', end_date: day(16), title: 'Latest readings' } },
      ],
      'tool_use',
    ),
    reply([{ type: 'text', text: 'ok' }], 'end_turn'),
  ];
  const ev = events((await owner.ask('Compare my heart rate')).text);
  const visuals = ev.filter((e) => e.event === 'visual').map((e) => e.data.visual);
  assert.deepEqual(
    visuals.map((v) => v.kind),
    ['compare', 'stats'],
    'in the order McFly asked',
  );
  assert.deepEqual(
    visuals[0].periods.map((p: { mean: number; days: number }) => [p.mean, p.days]),
    [
      [60, 3],
      [60, 3],
    ],
  );
  // The owner switched to imperial earlier: wrist temperature in °F.
  assert.deepEqual([visuals[1].items[1].unit, visuals[1].items[1].value, visuals[1].items[1].note], ['°F', 97.7, day(16)]);
});

test('nothing to draw is an error McFly reads, not an empty chart; at most three charts an answer', async () => {
  requests.length = 0;
  const draw = (id: string) => ({ type: 'tool_use' as const, id, name: 'show_visual', input: { kind: 'trend', metric: 'resting_hr', days: 7, end_date: day(16), title: 'RHR' } });
  script = [
    reply(
      [
        { type: 'tool_use', id: 'tv_4', name: 'show_visual', input: { kind: 'trend', metric: 'glucose', days: 7, end_date: day(16), title: 'Glucose' } },
        draw('tv_5'),
        draw('tv_6'),
        draw('tv_7'),
        draw('tv_8'),
      ],
      'tool_use',
    ),
    reply([{ type: 'text', text: 'ok' }], 'end_turn'),
  ];
  const ev = events((await bob.ask('Draw everything')).text);
  assert.equal(ev.filter((e) => e.event === 'visual').length, 3);
  const results = requests[1].messages.at(-1).content;
  assert.equal(results[0].is_error, true);
  assert.match(results[0].content, /nothing to draw/);
  assert.equal(results.filter((r: { is_error?: boolean }) => r.is_error).length, 2, 'the glucose one, and the fourth chart');
});

test('impossible dates, long trends, unfinished days and many sports', async () => {
  const today = todayLocal();
  await upsertDaily(
    db,
    bobId,
    Array.from({ length: 200 }, (_, i) => ({ date: addDays(today, -i), metric: 'steps', source: 'apple', value: i === 0 ? 1000 : 8000 })),
  );
  requests.length = 0;
  script = [
    reply(
      [
        { type: 'tool_use', id: 'tw_1', name: 'show_visual', input: { kind: 'trend', metric: 'resting_hr', days: 7, end_date: '2026-10-00', title: 'Bad date' } },
        { type: 'tool_use', id: 'tw_2', name: 'show_visual', input: { kind: 'trend', metric: 'steps', days: 180, title: 'Steps, six months' } },
        {
          type: 'tool_use',
          id: 'tw_3',
          name: 'show_visual',
          input: { kind: 'compare', metric: 'steps', title: 'Steps', periods: [{ label: 'This week', days: 7 }, { label: 'The week before', days: 7, end_date: addDays(today, -7) }] },
        },
      ],
      'tool_use',
    ),
    reply([{ type: 'text', text: 'ok' }], 'end_turn'),
  ];
  const ev = events((await bob.ask('Steps lately?')).text);
  const results = requests[1].messages.at(-1).content;
  // A date that doesn't exist is an error McFly reads, not a broken answer.
  assert.equal(results[0].is_error, true);
  assert.match(results[0].content, /real date/);
  assert.equal(ev.at(-1)?.event, 'done');
  // Over 120 days: weekly points, and the headline is still the daily average, today's unfinished count left out.
  const [trend, compare] = ev.filter((e) => e.event === 'visual').map((e) => e.data.visual);
  assert.equal(trend.resolution, 'week');
  assert.equal(trend.mean, 8000);
  assert.equal(trend.partialToday, true);
  const summary = JSON.parse(results[1].content);
  assert.equal(summary.chartShows, 'weekly averages of the daily values');
  assert.equal(summary.lowestDay.value, 1000, "the lowest single day is today's, so far");
  assert.deepEqual(
    compare.periods.map((p: { mean: number; days: number; partialToday: boolean }) => [p.mean, p.days, p.partialToday]),
    [
      [8000, 6, true],
      [8000, 7, false],
    ],
  );
});

// ---------- the weekly digest ----------

test('the digest covers the last completed Monday to Sunday', () => {
  assert.deepEqual(digestWeek('2026-10-19'), { start: '2026-10-12', end: '2026-10-18' }, 'on a Monday, the week that ended yesterday');
  assert.deepEqual(digestWeek('2026-10-18'), { start: '2026-10-05', end: '2026-10-11' }, 'on a Sunday, not the week still running');
  assert.deepEqual(digestWeek('2026-10-17'), { start: '2026-10-05', end: '2026-10-11' });
});

const ZONE = 'America/Chicago';
const week = digestWeek(todayLocal(ZONE));
const inWeek = (i: number) => addDays(week.start, i);

async function member(name: string) {
  const inv = await owner.call('POST', '/api/admin/invites', {});
  const c = new Client();
  const token = inv.json.url.split('/').at(-1);
  assert.equal((await c.call('POST', '/api/auth/invite', { token, email: `${name.toLowerCase()}@example.com`, name, password: `${name} password 123` })).status, 200);
  assert.equal((await c.call('PUT', '/api/settings', { timeZone: ZONE })).status, 200);
  return { c, id: (await c.call('GET', '/api/auth/me')).json.user.id as string };
}

const digest = (c: Client) => c.call('GET', '/api/mcfly/digest');
const used = async (c: Client) => (await c.call('GET', '/api/mcfly')).json.usedToday as number;
const recap = (text: string) => reply([{ type: 'text', text }], 'end_turn');
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

let carol: Awaited<ReturnType<typeof member>>;

test('setup: a member with last week and the week before on record', async () => {
  carol = await member('Carol');
  const rows = [];
  for (let i = -7; i < 6; i++) {
    rows.push(
      { date: inWeek(i), metric: 'steps', source: 'apple', value: i < 0 ? 7000 : 9500 },
      { date: inWeek(i), metric: 'sleep_hours', source: 'apple', value: i < 0 ? 6.5 : 7.25 },
      { date: inWeek(i), metric: 'resting_hr', source: 'apple', value: 58 },
    );
  }
  await upsertDaily(db, carol.id, rows);
});

test("the digest isn't offered until an API key is configured", async () => {
  configured = false;
  requests.length = 0;
  const res = await digest(carol.c);
  assert.deepEqual([res.status, res.json], [200, { configured: false, digest: null, reason: 'not_configured' }]);
  assert.equal(requests.length, 0);
  configured = true;
});

test('the digest is written once for the week, then kept', async () => {
  requests.length = 0;
  const before = await used(carol.c);
  script = [recap('A **steadier** week: more steps and more sleep than the week before.')];
  const first = await digest(carol.c);
  assert.equal(first.status, 200);
  assert.equal(first.json.configured, true);
  assert.equal(first.json.reason, undefined);
  assert.deepEqual([first.json.digest.weekStart, first.json.digest.weekEnd], [week.start, week.end]);
  assert.match(first.json.digest.text, /steadier/);

  // One non-streaming call: the platform model, fallbacks on, no tools, the chat's persona, the week as JSON.
  assert.equal(requests.length, 1);
  const sent = requests[0];
  assert.equal(sent.model, 'claude-opus-5-5');
  assert.equal(sent.fallbacks, 'default');
  assert.equal(sent.tools, undefined);
  assert.match(sent.system, /You are McFly/);
  assert.match(sent.system, /talking with Carol/);
  assert.match(sent.system, /not a doctor/);
  const input = JSON.parse(sent.messages[0].content.slice(sent.messages[0].content.indexOf('{')));
  assert.deepEqual(input.week, { start: week.start, end: week.end, daysWithData: 6 });
  assert.deepEqual(input.steps, { dailyAverage: 9500, weekBefore: 7000, goal: 10_000, daysAtGoal: 0, daysWithSteps: 6 });
  assert.deepEqual(input.sleepHoursPerNight, { thisWeek: 7.25, weekBefore: 6.5 });
  assert.equal(input.whoopRecoveryPercent, undefined, 'metrics with no data are left out');
  assert.ok(Array.isArray(input.insights) && Array.isArray(input.patterns));

  // Counted like a question, with its tokens.
  assert.equal(await used(carol.c), before + 1);
  const [usage] = await db.query<{ input_tokens: number; output_tokens: number }>('SELECT input_tokens, output_tokens FROM mcfly_usage WHERE user_id = $1', [carol.id]);
  assert.deepEqual([Number(usage.input_tokens), Number(usage.output_tokens)], [100, 20]);

  // Opening it again reads the kept copy: no model call, no charge.
  const again = await digest(carol.c);
  assert.deepEqual(again.json, first.json);
  assert.equal(requests.length, 1);
  assert.equal(await used(carol.c), before + 1);
});

test("a digest for an older week is replaced by the next week's", async () => {
  const old = { weekStart: addDays(week.start, -7), weekEnd: addDays(week.end, -7), text: 'Last time.', generatedAt: '2026-01-01T09:00:00.000Z' };
  await setUserSetting(db, carol.id, 'mcfly_digest', JSON.stringify(old));
  requests.length = 0;
  script = [recap('This week, new words.')];
  const res = await digest(carol.c);
  assert.equal(requests.length, 1);
  assert.deepEqual([res.json.digest.weekEnd, res.json.digest.text], [week.end, 'This week, new words.']);
  assert.equal(JSON.parse((await getUserSetting(db, carol.id, 'mcfly_digest'))!).weekEnd, week.end);
});

test('the digest never sees cycle data, even with tracking on and days logged', async () => {
  assert.equal((await carol.c.call('PUT', '/api/settings', { cycleTracking: true })).status, 200);
  assert.equal((await carol.c.call('POST', '/api/cycle/day', { date: inWeek(1), periodStart: true, flow: 'heavy', bbt: 36.71 })).status, 200);
  assert.equal((await carol.c.call('POST', '/api/cycle/day', { date: inWeek(3), ovulationTest: 'lh_surge', mucus: 'egg_white', sexualActivity: 'protected' })).status, 200);
  await setUserSetting(db, carol.id, 'mcfly_digest', null);
  requests.length = 0;
  script = [recap('ok')];
  assert.equal((await digest(carol.c)).status, 200);
  assert.equal(requests.length, 1);
  const sent = JSON.stringify(requests[0]);
  assert.doesNotMatch(sent, /cycle|period|menstru|ovulat|fertile|luteal|follicular|mucus|egg_white|lh_surge|36\.71|heavy|\bflow\b|sexual|protected/i);
});

test('two clients opening the digest at once share one model call and one charge', async () => {
  await setUserSetting(db, carol.id, 'mcfly_digest', null);
  requests.length = 0;
  const before = await used(carol.c);
  script = [recap('Shared.'), recap('A second copy that should never be written.')];
  let open!: () => void;
  gate = new Promise((r) => (open = r));
  const both = Promise.all([digest(carol.c), digest(carol.c)]);
  await sleep(300); // both requests are in by now, the first held at the model call
  open();
  const [a, b] = await both;
  gate = Promise.resolve();
  assert.deepEqual([a.status, b.status], [200, 200]);
  assert.deepEqual(a.json, b.json);
  assert.equal(a.json.digest.text, 'Shared.');
  assert.equal(requests.length, 1);
  assert.equal(await used(carol.c), before + 1);
  script = [];
});

test("a digest that couldn't be written isn't charged or kept", async () => {
  await setUserSetting(db, carol.id, 'mcfly_digest', null);
  const before = await used(carol.c);
  script = []; // the fake throws, like an API error
  const failed = await digest(carol.c);
  assert.equal(failed.status, 503);
  assert.match(failed.json.error, /digest/);
  script = [reply([{ type: 'text', text: 'Partial' }], 'refusal')];
  assert.equal((await digest(carol.c)).status, 503);
  assert.equal(await used(carol.c), before);
  assert.equal(await getUserSetting(db, carol.id, 'mcfly_digest'), undefined);
});

test('a week with fewer than 3 days of data gets no digest, and no charge', async () => {
  const dave = await member('Dave');
  await upsertDaily(db, dave.id, [inWeek(0), inWeek(4)].map((date) => ({ date, metric: 'steps', source: 'apple', value: 5000 })));
  requests.length = 0;
  const res = await digest(dave.c);
  assert.deepEqual([res.status, res.json], [200, { configured: true, digest: null, reason: 'no_data' }]);
  assert.equal(requests.length, 0);
  assert.equal(await used(dave.c), 0);
});

test('over the daily limit: the last digest written (or none), without calling the model; 0 turns it off', async () => {
  const old = { weekStart: addDays(week.start, -7), weekEnd: addDays(week.end, -7), text: 'Last time.', generatedAt: '2026-01-01T09:00:00.000Z' };
  await setUserSetting(db, carol.id, 'mcfly_digest', JSON.stringify(old));
  await owner.call('PUT', '/api/admin/settings', { mcfly_daily_limit: await used(carol.c) });
  requests.length = 0;
  const limited = await digest(carol.c);
  assert.deepEqual([limited.status, limited.json], [200, { configured: true, digest: old, reason: 'limit' }]);
  await setUserSetting(db, carol.id, 'mcfly_digest', null);
  assert.deepEqual((await digest(carol.c)).json, { configured: true, digest: null, reason: 'limit' });
  assert.equal(requests.length, 0);

  await owner.call('PUT', '/api/admin/settings', { mcfly_daily_limit: 0 });
  assert.deepEqual((await digest(carol.c)).json, { configured: true, digest: null, reason: 'off' });
  await owner.call('PUT', '/api/admin/settings', { mcfly_daily_limit: 50 });
});

test("a digest of the demo data isn't kept as the owner's own week once demo is off", async () => {
  // The owner (local, no time zone set) has demo rows and their own rows in last week.
  const ownerWeek = digestWeek(todayLocal());
  const dates = [0, 1, 2, 3, 4].map((i) => addDays(ownerWeek.start, i));
  await upsertDaily(
    db,
    OWNER_ID,
    dates.flatMap((date) => [
      { date, metric: 'steps', source: 'demo', value: 12_000 },
      { date, metric: 'steps', source: 'apple', value: 4000 },
    ]),
  );
  const kept = async () => JSON.parse((await getUserSetting(db, OWNER_ID, 'mcfly_digest'))!);
  requests.length = 0;

  assert.equal((await owner.call('PUT', '/api/settings', { demo: 'on' })).status, 200);
  script = [recap('A demo week.')];
  assert.equal((await digest(owner)).json.digest.text, 'A demo week.');
  assert.match(requests[0].messages[0].content, /"dailyAverage":12000/);
  assert.equal((await kept()).demo, true);

  // Demo off: the owner's own week is written, not the demo one served until next Monday.
  assert.equal((await owner.call('PUT', '/api/settings', { demo: 'auto' })).status, 200);
  script = [recap('Your own week.')];
  const real = await digest(owner);
  assert.equal(requests.length, 2);
  assert.equal(real.json.digest.text, 'Your own week.');
  assert.match(requests[1].messages[0].content, /"dailyAverage":4000/);
  assert.deepEqual(Object.keys(real.json.digest).sort(), ['generatedAt', 'text', 'weekEnd', 'weekStart'], 'the reply keeps its shape');
  assert.equal((await kept()).demo, false);
  // Then kept as usual.
  assert.deepEqual((await digest(owner)).json, real.json);
  assert.equal(requests.length, 2);
});

test('a digest kept before demo was noted counts as real; over the limit, a demo one is never shown', async () => {
  const current = { weekStart: week.start, weekEnd: week.end, text: 'Kept.', generatedAt: '2026-01-01T09:00:00.000Z' };
  await setUserSetting(db, carol.id, 'mcfly_digest', JSON.stringify(current));
  requests.length = 0;
  assert.deepEqual((await digest(carol.c)).json, { configured: true, digest: current });

  await setUserSetting(db, carol.id, 'mcfly_digest', JSON.stringify({ ...current, demo: true }));
  await owner.call('PUT', '/api/admin/settings', { mcfly_daily_limit: await used(carol.c) });
  assert.deepEqual((await digest(carol.c)).json, { configured: true, digest: null, reason: 'limit' });
  assert.equal(requests.length, 0);
  await owner.call('PUT', '/api/admin/settings', { mcfly_daily_limit: 50 });
  await setUserSetting(db, carol.id, 'mcfly_digest', null);
});

test('only members can read a digest', async () => {
  assert.equal((await new Client().call('GET', '/api/mcfly/digest')).status, 401);
});
