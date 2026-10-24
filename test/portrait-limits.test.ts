// Portrait limits that hold with requests in parallel: one portrait being made per person (a unique index, which migration
// 16 can build on any existing rows), and PORTRAITS_PER_DAY counted under a lock. OpenAI is a fake; nothing calls it.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { AddressInfo } from 'node:net';
import { PORTRAITS_PER_DAY } from '../shared/portraits.ts';
import type { AiFetch } from '../server/ai/provider.ts';
import { createApp } from '../server/app.ts';
import { hashPassword } from '../server/auth.ts';
import { getUserSetting, setUserSetting } from '../server/db.ts';
import { claimPortrait } from '../server/portraits.ts';
import { MIGRATIONS, openStore } from '../server/store.ts';

delete process.env.OPENAI_API_KEY;
delete process.env.HEALTHOS_DATA_KEY_PREVIOUS;
process.env.HEALTHOS_DATA_KEY = 'e5'.repeat(32);
process.env.SESSION_SECRET = 'portrait-limits-test-secret-'.padEnd(64, 'x');
const OWNER_PASSWORD = 'owner password 123';
process.env.HEALTHOS_PASSWORD_HASH = await hashPassword(OWNER_PASSWORD);
const OPENAI_KEY = 'sk-proj-TESTKEY-limits-1234567890abcdef1a2b';

/** A minimal JPEG: start, a frame header with the size, end. */
function jpeg(width: number, height: number) {
  const sof = Buffer.alloc(19);
  sof.writeUInt16BE(0xffc0, 0);
  sof.writeUInt16BE(17, 2);
  sof[4] = 8;
  sof.writeUInt16BE(height, 5);
  sof.writeUInt16BE(width, 7);
  sof[9] = 3;
  return Buffer.concat([Buffer.from([0xff, 0xd8]), sof, Buffer.from([0xff, 0xd9])]);
}

/** The header of an extended WebP: all the server reads of a generated image. */
function webp(width: number, height: number) {
  const b = Buffer.alloc(30);
  b.write('RIFF', 0, 'latin1');
  b.writeUInt32LE(22, 4);
  b.write('WEBPVP8X', 8, 'latin1');
  b.writeUInt32LE(10, 16);
  b.writeUIntLE(width - 1, 24, 3);
  b.writeUIntLE(height - 1, 27, 3);
  return b;
}

// OpenAI's image edit, held until the test lets it finish, so portraits stay pending while more requests come in.
let release: () => void = () => {};
let gate: Promise<void> = Promise.resolve();
let edits = 0;
const aiFetch: AiFetch = async (url) => {
  if (url.endsWith('/models')) return new Response(JSON.stringify({ data: [] }));
  if (url.endsWith('/images/edits')) {
    edits++;
    await gate;
    return new Response(JSON.stringify({ data: [{ b64_json: webp(1024, 1536).toString('base64') }] }));
  }
  return new Response('{}', { status: 404 });
};

const db = await openStore();
const server = createApp({ db, hosted: true, mcflyClient: () => null, aiFetch }).listen(0, '127.0.0.1');
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
    return { status: res.status, json: (await res.json().catch(() => null)) as any };
  }
  list = async () => (await this.call('GET', '/api/portraits')).json;
}

const owner = new Client();
const bob = new Client();
let bobId = '';
let referenceId = '';

const today = () => new Date().toISOString().slice(0, 10);
const usedToday = async (userId: string) => JSON.parse((await getUserSetting(db, userId, 'portrait_usage')) ?? '{"count":0}').count as number;
const pending = async (userId: string) =>
  Number((await db.query<{ n: number }>("SELECT count(*)::integer AS n FROM portraits WHERE user_id = $1 AND kind = 'generated' AND status = 'pending'", [userId]))[0].n);

async function settled(c: Client) {
  for (let i = 0; i < 100; i++) {
    if (!(await c.list()).portraits.some((p: { status: string }) => p.status === 'pending')) return;
    await new Promise((r) => setTimeout(r, 20));
  }
  throw new Error('still pending');
}

test('migration 16 keeps each person’s newest pending portrait, so its unique index builds on any existing rows', async () => {
  const fresh = await openStore();
  try {
    await fresh.query('DROP INDEX portraits_one_pending');
    const row = (user: string, id: string, status: string, created: number) =>
      fresh.query(`INSERT INTO portraits (user_id, id, kind, status, mime, bytes, created_at) VALUES ($1, $2, 'generated', $3, 'image/webp', 0, $4)`, [user, id, status, created]);
    // Ann has three pending, two of them made in the same millisecond; Ben has one; Cat has none pending.
    await row('ann', 'a1', 'pending', 100);
    await row('ann', 'a2', 'pending', 200);
    await row('ann', 'a3', 'pending', 200);
    await row('ann', 'a4', 'ready', 300);
    await row('ben', 'b1', 'pending', 50);
    await row('cat', 'c1', 'failed', 10);
    // As migrate() runs them, in one transaction; the new column is already there.
    const statements = MIGRATIONS.find((m) => m.id === 16)?.statements.filter((s) => !s.startsWith('ALTER TABLE')) ?? [];
    assert.equal(statements.length, 3);
    await fresh.tx(async (q) => {
      for (const s of statements) await q.query(s);
    });
    const rows = await fresh.query<{ user_id: string; id: string; status: string; error: string }>('SELECT user_id, id, status, error FROM portraits ORDER BY user_id, id');
    assert.deepEqual(
      rows.map((r) => [r.id, r.status]),
      [
        ['a1', 'failed'],
        ['a2', 'failed'],
        ['a3', 'pending'],
        ['a4', 'ready'],
        ['b1', 'pending'],
        ['c1', 'failed'],
      ],
    );
    assert.equal(rows.find((r) => r.id === 'a1')?.error, 'Making this portrait was interrupted. Try again.');
    assert.equal(rows.find((r) => r.id === 'c1')?.error, '', 'a portrait that had already failed is left as it was');
    await assert.rejects(row('ben', 'b2', 'pending', 60), /duplicate key|unique/i);
    await row('ben', 'b3', 'ready', 70);
  } finally {
    await fresh.close();
  }
});

test('setup: an owner, and a member with an OpenAI key and a reference photo', async () => {
  assert.equal((await owner.call('POST', '/api/auth/login', { email: 'owner@example.com', password: OWNER_PASSWORD })).status, 200);
  const token = (await owner.call('POST', '/api/admin/invites', {})).json.url.split('/').at(-1);
  assert.equal((await bob.call('POST', '/api/auth/invite', { token, email: 'bob@example.com', name: 'Bob', password: 'Bob password 123' })).status, 200);
  bobId = (await bob.call('GET', '/api/auth/me')).json.user.id;
  assert.equal((await bob.call('PUT', '/api/ai/keys/openai', { key: OPENAI_KEY })).status, 200);
  const ref = await bob.call('POST', '/api/portraits/reference', { image: jpeg(600, 800).toString('base64'), width: 600, height: 800 });
  assert.equal(ref.status, 200);
  referenceId = ref.json.portrait.id;
  assert.equal((await bob.list()).canGenerate, true);
});

test('requests at once start one portrait: the others get the usual answer, and only one is counted', async () => {
  gate = new Promise((r) => (release = r));
  const results = await Promise.all(Array.from({ length: 4 }, () => bob.call('POST', '/api/portraits/generate', { referenceId })));
  assert.deepEqual(
    results.map((r) => r.status).sort(),
    [202, 409, 409, 409],
  );
  for (const r of results.filter((x) => x.status === 409)) assert.match(r.json.error, /still being made/);
  assert.equal(await pending(bobId), 1);
  assert.equal(await usedToday(bobId), 1);
  assert.equal((await bob.list()).canGenerate, true);
  release();
  await settled(bob);
  assert.equal(edits, 1, 'one image call');
});

test('the database itself refuses a second pending portrait', async () => {
  gate = new Promise((r) => (release = r));
  assert.equal((await bob.call('POST', '/api/portraits/generate', { referenceId })).status, 202);
  await assert.rejects(
    db.query(`INSERT INTO portraits (user_id, id, kind, status, mime, bytes, reference_id, created_at) VALUES ($1, 'second', 'generated', 'pending', 'image/webp', 0, $2, $3)`, [
      bobId,
      referenceId,
      Date.now(),
    ]),
    /duplicate key|unique/i,
  );
  release();
  await settled(bob);
  assert.equal(await usedToday(bobId), 2);
});

test(`claims at once can't pass ${PORTRAITS_PER_DAY} a day`, async () => {
  const day = today();
  await setUserSetting(db, bobId, 'portrait_usage', JSON.stringify({ day, count: PORTRAITS_PER_DAY - 1 }));
  const claims = await Promise.all(Array.from({ length: 5 }, () => claimPortrait(db, bobId, day)));
  assert.equal(claims.filter(Boolean).length, 1);
  assert.equal(await usedToday(bobId), PORTRAITS_PER_DAY);
  const capped = await bob.call('POST', '/api/portraits/generate', { referenceId });
  assert.equal(capped.status, 429);
  assert.equal(await usedToday(bobId), PORTRAITS_PER_DAY, 'a refused one changes nothing');
  // An earlier day's count starts again.
  await setUserSetting(db, bobId, 'portrait_usage', JSON.stringify({ day: '2000-01-01', count: PORTRAITS_PER_DAY }));
  assert.equal(await claimPortrait(db, bobId, day), true);
  assert.deepEqual(JSON.parse((await getUserSetting(db, bobId, 'portrait_usage')) ?? ''), { day, count: 1 });
});
