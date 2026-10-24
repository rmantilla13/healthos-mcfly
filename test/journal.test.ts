// The health journal: private check-ins kept for one person only. Adding, editing and deleting; what's refused and
// how (never repeating the text); that each person sees only their own; and that a check-in never reaches the Family
// board, the summary, peer comparisons, the admin screens or McFly's tools. McFly's Claude is a fake.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { AddressInfo } from 'node:net';
import { createApp } from '../server/app.ts';
import { hashPassword } from '../server/auth.ts';
import { addDays, todayLocal } from '../server/dates.ts';
import type { McflyClient } from '../server/mcfly.ts';
import { openStore } from '../server/store.ts';

process.env.SESSION_SECRET = 'journal-test-secret-'.padEnd(64, 'x');
const OWNER_PASSWORD = 'owner password 123';
process.env.HEALTHOS_PASSWORD_HASH = await hashPassword(OWNER_PASSWORD);

// ---------- a fake Claude, for McFly's tools ----------
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
const requests: unknown[] = [];
const next = () => {
  const msg = script.shift();
  if (!msg) throw new Error('fake Claude ran out of scripted replies');
  return msg;
};
const fake = {
  beta: {
    messages: {
      async create(params: unknown) {
        requests.push(structuredClone(params));
        return next();
      },
      stream(params: unknown) {
        requests.push(structuredClone(params));
        const msg = next();
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
const server = createApp({ db, hosted: false, mcflyClient: () => fake }).listen(0, '127.0.0.1');
await new Promise((r) => server.once('listening', r));
const base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
test.after(async () => {
  server.close();
  await db.close();
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
  journal(days?: number) {
    return this.call('GET', `/api/journal${days ? `?days=${days}` : ''}`);
  }
  write(body: unknown) {
    return this.call('POST', '/api/journal', body);
  }
}

const owner = new Client();
const bob = new Client();
const today = todayLocal();
/** Planted in Bob's journal; it must never show up anywhere but his own journal. */
const SECRET = 'Felt the zebra-umbrella-7731 thing again';

test('setup: an owner and an invited member', async () => {
  assert.equal((await owner.call('POST', '/api/auth/login', { email: 'owner@example.com', password: OWNER_PASSWORD })).status, 200);
  const inv = await owner.call('POST', '/api/admin/invites', {});
  const token = inv.json.url.split('/').at(-1);
  assert.equal((await bob.call('POST', '/api/auth/invite', { token, email: 'bob@example.com', name: 'Bob', password: 'bob password 123' })).status, 200);
});

test('an empty journal is an empty list with the day it is', async () => {
  const r = await bob.journal();
  assert.equal(r.status, 200);
  assert.deepEqual(r.json, { today, entries: [], older: false });
});

test('a check-in is saved with its mood, dated now by default, and moves the data version', async () => {
  const before = (await bob.call('GET', '/api/version')).json.version;
  const r = await bob.write({ text: `  ${SECRET}\n\nand slept badly.  `, mood: 2 });
  assert.equal(r.status, 200, r.text);
  const e = r.json.entry;
  assert.equal(e.text, `${SECRET}\n\nand slept badly.`, 'trimmed at the ends, line breaks kept');
  assert.equal(e.mood, 2);
  assert.equal(e.date, today);
  assert.match(e.time, /^\d{2}:\d{2}$/);
  assert.equal(typeof e.createdAt, 'number');
  assert.notEqual((await bob.call('GET', '/api/version')).json.version, before);

  // Without a mood, and on an earlier day and time.
  const earlier = await bob.write({ text: 'Long walk, felt good.', date: addDays(today, -3), time: '07:15' });
  assert.equal(earlier.status, 200);
  assert.equal(earlier.json.entry.mood, null);
  const [row] = await db.query<{ origin: string }>('SELECT origin FROM journal_entries WHERE id = $1', [earlier.json.entry.id]);
  assert.equal(row.origin, 'web');
});

test('check-ins come back newest first, within the days asked for', async () => {
  await bob.write({ text: 'Morning, before coffee.', date: today, time: '06:00', mood: 3 });
  const r = await bob.journal();
  assert.deepEqual(
    r.json.entries.map((e: { date: string }) => e.date),
    [today, today, addDays(today, -3)],
  );
  assert.ok(r.json.entries[0].time >= r.json.entries[1].time, 'later the same day comes first');
  const two = (await bob.journal(2)).json;
  assert.deepEqual([two.entries.length, two.older], [2, true], 'two days: today only, and there are older ones');
  await bob.write({ text: 'A year ago.', date: addDays(today, -400) });
  const recent = (await bob.journal()).json;
  assert.deepEqual([recent.entries.length, recent.older], [3, true], '90 days by default');
  const all = (await bob.journal(3650)).json;
  assert.deepEqual([all.entries.length, all.older], [4, false]);
});

test('bad check-ins are refused in plain words that never repeat the text', async () => {
  const cases: [unknown, RegExp][] = [
    [{ text: '' }, /Write a few words/],
    [{ text: '   \n ' }, /Write a few words/],
    [{ mood: 3 }, /Write a few words/],
    [{ text: `${SECRET} ${'x'.repeat(4000)}` }, /up to 4,000 characters/],
    [{ text: SECRET, mood: 6 }, /Rough to Great/],
    [{ text: SECRET, mood: 2.5 }, /Rough to Great/],
    [{ text: SECRET, mood: '3' }, /Rough to Great/],
    [{ text: SECRET, date: addDays(today, 1) }, /future/],
    [{ text: SECRET, date: '2026-02-30' }, /real date/],
    [{ text: SECRET, time: '24:00' }, /HH:MM/],
    [{ text: SECRET, time: '7:15' }, /HH:MM/],
  ];
  for (const [body, error] of cases) {
    const r = await bob.write(body);
    assert.equal(r.status, 400, JSON.stringify(body).slice(0, 80));
    assert.match(r.json.error, error);
    assert.ok(!r.text.includes('zebra'), 'the text is never repeated');
  }
  assert.equal((await bob.write({ text: 'x'.repeat(4000) })).status, 200, 'exactly 4,000 is fine');
  assert.equal((await bob.write({ text: 'From the phone.', origin: 'iphone' })).status, 200);
});

test('a check-in can be edited: its text, its mood (or no mood), its day and time', async () => {
  const id = (await bob.journal()).json.entries.find((e: { text: string }) => e.text.startsWith('Morning')).id;
  const r = await bob.call('PATCH', `/api/journal/${id}`, { text: 'Morning, after coffee.', mood: 4 });
  assert.equal(r.status, 200, r.text);
  assert.deepEqual([r.json.entry.text, r.json.entry.mood, r.json.entry.time], ['Morning, after coffee.', 4, '06:00']);
  assert.ok(r.json.entry.updatedAt >= r.json.entry.createdAt);
  const cleared = await bob.call('PATCH', `/api/journal/${id}`, { mood: null, date: addDays(today, -1), time: '21:30' });
  assert.deepEqual([cleared.json.entry.text, cleared.json.entry.mood, cleared.json.entry.date, cleared.json.entry.time], ['Morning, after coffee.', null, addDays(today, -1), '21:30']);
  assert.equal((await bob.call('PATCH', `/api/journal/${id}`, { text: ' ' })).status, 400);
  assert.equal((await bob.call('PATCH', `/api/journal/${id}`, { mood: 0 })).status, 400);
  assert.equal((await bob.call('PATCH', '/api/journal/no-such-id', { mood: 3 })).status, 404);
});

test("another person can't read, change or delete them", async () => {
  const bobs = (await bob.journal()).json.entries;
  const ownerView = await owner.journal(3650);
  assert.deepEqual(ownerView.json.entries, []);
  const id = bobs[0].id;
  assert.equal((await owner.call('PATCH', `/api/journal/${id}`, { text: 'not mine' })).status, 404);
  assert.equal((await owner.call('DELETE', `/api/journal/${id}`)).status, 404);
  assert.equal((await owner.call('POST', '/api/journal/delete')).json.deleted, 0);
  assert.equal((await bob.journal()).json.entries.length, bobs.length, "Bob's are all still there");
  assert.equal((await bob.journal()).json.entries[0].text, bobs[0].text);
});

test('writes need the X-HealthOS header', async () => {
  const res = await fetch(`${base}/api/journal`, { method: 'POST', headers: { 'Content-Type': 'application/json', Cookie: bob.cookie }, body: JSON.stringify({ text: 'hi' }) });
  assert.equal(res.status, 403);
});

test('a check-in never reaches the Family board, the summary, peers, the admin screens or McFly', async () => {
  for (const [who, path] of [
    [owner, '/api/family'],
    [bob, '/api/family'],
    [bob, '/api/summary'],
    [bob, '/api/peers'],
    [bob, '/api/status'],
    [owner, '/api/admin/overview'],
  ] as const) {
    const r = await who.call('GET', path);
    assert.equal(r.status, 200, path);
    assert.ok(!r.text.includes('zebra'), `${path} for ${who === owner ? 'the owner' : 'Bob'}`);
  }

  // McFly calls every one of its read tools; nothing it's given mentions the journal.
  requests.length = 0;
  const calls: Block[] = [
    { type: 'tool_use', id: 't1', name: 'list_metrics', input: {} },
    { type: 'tool_use', id: 't2', name: 'get_day_summary', input: { date: today } },
    { type: 'tool_use', id: 't3', name: 'get_metric_history', input: { metrics: ['resting_hr'], days: 30 } },
    { type: 'tool_use', id: 't4', name: 'get_workouts', input: { days: 30 } },
    { type: 'tool_use', id: 't5', name: 'get_sleep_sessions', input: { days: 30 } },
    { type: 'tool_use', id: 't6', name: 'get_cycle', input: {} },
    { type: 'tool_use', id: 't7', name: 'get_nutrition', input: { days: 30 } },
    { type: 'tool_use', id: 't8', name: 'get_lab_results', input: {} },
  ];
  script = [reply(calls, 'tool_use'), reply([{ type: 'text', text: 'Nothing about a journal here.' }], 'end_turn')];
  const chat = await bob.call('POST', '/api/mcfly/chat', { messages: [{ role: 'user', content: 'What did I write in my journal this week?' }] });
  assert.equal(chat.status, 200);
  assert.equal(requests.length, 2, 'the tools ran and their results went back');
  const sent = JSON.stringify(requests);
  assert.ok(!sent.includes('zebra'));
  assert.ok(!sent.includes('Long walk'));
  const tools = (requests[0] as { tools: { name: string }[] }).tools.map((t) => t.name);
  assert.ok(!tools.some((t) => /journal/i.test(t)), 'no tool reads the journal');
});

test('one check-in can be deleted, then all of them', async () => {
  const entries = (await bob.journal(3650)).json.entries;
  const before = (await bob.call('GET', '/api/version')).json.version;
  assert.equal((await bob.call('DELETE', `/api/journal/${entries[0].id}`)).json.deleted, 1);
  assert.notEqual((await bob.call('GET', '/api/version')).json.version, before);
  assert.equal((await bob.call('DELETE', `/api/journal/${entries[0].id}`)).status, 404);
  assert.equal((await bob.journal(3650)).json.entries.length, entries.length - 1);
  const all = await bob.call('POST', '/api/journal/delete');
  assert.equal(all.json.deleted, entries.length - 1);
  assert.deepEqual((await bob.journal(3650)).json.entries, []);
});

test('nothing about a check-in is logged when a write fails', async () => {
  const logged: string[] = [];
  const original = console.error;
  console.error = (...args: unknown[]) => void logged.push(args.map(String).join(' '));
  try {
    // A database failure, made by moving the table away for a moment.
    await db.query('ALTER TABLE journal_entries RENAME TO journal_entries_away');
    const r = await bob.write({ text: SECRET, mood: 3 });
    assert.equal(r.status, 500);
    assert.ok(!r.text.includes('zebra'));
  } finally {
    await db.query('ALTER TABLE journal_entries_away RENAME TO journal_entries');
    console.error = original;
  }
  assert.ok(logged.length >= 1);
  assert.ok(logged.every((l) => !l.includes('zebra')));
});
