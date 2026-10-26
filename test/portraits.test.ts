// Portraits (/api/portraits): reference photos checked by their own bytes and capped, read only by their owner, sent
// only to that person's OpenAI call (a fake here: no test calls OpenAI), made in the background, chosen and deleted.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import type { AddressInfo } from 'node:net';
import path from 'node:path';
import zlib from 'node:zlib';
import { MAX_GENERATED, MAX_REFERENCE_BASE64, MAX_REFERENCES, PORTRAITS_PER_DAY } from '../shared/portraits.ts';
import type { AiFetch } from '../server/ai/provider.ts';
import { createApp } from '../server/app.ts';
import { hashPassword } from '../server/auth.ts';
import { setUserSetting } from '../server/db.ts';
import { PORTRAIT_MODEL, jpegSize, webpSize } from '../server/portraits.ts';
import { STYLE_REFERENCE_BASE64 } from '../server/portraitStyle.ts';
import { openStore } from '../server/store.ts';

// Made-up secrets only; and no OpenAI key from the shell, so "no key" means no key.
delete process.env.OPENAI_API_KEY;
delete process.env.HEALTHOS_DATA_KEY_PREVIOUS;
process.env.HEALTHOS_DATA_KEY = 'b2'.repeat(32);
process.env.SESSION_SECRET = 'portraits-test-secret-'.padEnd(64, 'x');
const OWNER_PASSWORD = 'owner password 123';
process.env.HEALTHOS_PASSWORD_HASH = await hashPassword(OWNER_PASSWORD);

const OPENAI_KEY = 'sk-proj-TESTKEY-portraits-1234567890abcd7e2f';

/** A minimal JPEG: start, a JFIF header, a frame header with the size, end. */
function jpeg(width: number, height: number, pad = 0) {
  const app0 = Buffer.from([0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00]);
  const sof = Buffer.alloc(19);
  sof.writeUInt16BE(0xffc0, 0);
  sof.writeUInt16BE(17, 2);
  sof[4] = 8;
  sof.writeUInt16BE(height, 5);
  sof.writeUInt16BE(width, 7);
  sof[9] = 3;
  return Buffer.concat([Buffer.from([0xff, 0xd8]), app0, sof, Buffer.alloc(pad), Buffer.from([0xff, 0xd9])]);
}

/** The header of an extended WebP of the given size: all the server reads of a generated image. */
function webp(width: number, height: number) {
  const b = Buffer.alloc(30);
  b.write('RIFF', 0, 'latin1');
  b.writeUInt32LE(22, 4);
  b.write('WEBPVP8X', 8, 'latin1');
  b.writeUInt32LE(10, 16);
  b[20] = 0x10; // has alpha
  b.writeUIntLE(width - 1, 24, 3);
  b.writeUIntLE(height - 1, 27, 3);
  return b;
}

/** A real, minimal RGBA PNG (for the profile photo a chosen portrait becomes). */
function png(width: number, height: number) {
  const chunk = (type: string, data: Buffer) => {
    const head = Buffer.alloc(8);
    head.writeUInt32BE(data.length, 0);
    head.write(type, 4, 'latin1');
    const crc = Buffer.alloc(4);
    crc.writeUInt32BE(zlib.crc32(Buffer.concat([Buffer.from(type, 'latin1'), data])) >>> 0, 0);
    return Buffer.concat([head, data, crc]);
  };
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 8;
  ihdr[9] = 6;
  const rows = Buffer.alloc((width * 4 + 1) * height);
  return Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), chunk('IHDR', ihdr), chunk('IDAT', zlib.deflateSync(rows)), chunk('IEND', Buffer.alloc(0))]);
}

// OpenAI, as a fake: the model list (checking a key before it's stored) and the image edit, which waits for the test
// to let it finish so the portrait can be seen pending first.
type Mode = 'ok' | 'declined' | 'refused' | 'garbled';
let mode: Mode = 'ok';
let release: () => void = () => {};
let gate: Promise<void> = Promise.resolve();
const hold = () => {
  gate = new Promise((r) => (release = r));
};
const edits: { url: string; auth: string | null; form: FormData }[] = [];
const aiFetch: AiFetch = async (url, init) => {
  const auth = new Headers(init?.headers).get('authorization');
  if (url.endsWith('/models')) return auth === `Bearer ${OPENAI_KEY}` ? new Response(JSON.stringify({ data: [] })) : new Response('{}', { status: 401 });
  if (url.endsWith('/images/edits')) {
    edits.push({ url, auth, form: init?.body as FormData });
    await gate;
    if (mode === 'declined') return new Response(JSON.stringify({ error: { message: 'Your request was rejected by the safety system.', code: 'moderation_blocked' } }), { status: 400 });
    if (mode === 'refused') return new Response(JSON.stringify({ error: { message: `Incorrect API key provided: ${OPENAI_KEY.slice(0, 6)}***`, code: 'invalid_api_key' } }), { status: 401 });
    if (mode === 'garbled') return new Response(JSON.stringify({ data: [{ b64_json: Buffer.from('not an image at all').toString('base64') }] }));
    return new Response(JSON.stringify({ created: 1, data: [{ b64_json: webp(1024, 1536).toString('base64') }], output_format: 'webp', size: '1024x1536' }));
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
  async call(method: string, path: string, body?: unknown, headers: Record<string, string> = { 'X-HealthOS': '1' }) {
    const res = await fetch(base + path, {
      method,
      headers: { 'Content-Type': 'application/json', ...headers, ...(this.cookie ? { Cookie: this.cookie } : {}) },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const set = res.headers.get('set-cookie');
    if (set) this.cookie = set.split(';')[0];
    const buf = Buffer.from(await res.arrayBuffer());
    let json: any = null;
    try {
      json = JSON.parse(buf.toString());
    } catch {
      json = null;
    }
    return { status: res.status, json, buf, headers: res.headers };
  }
  list = async () => (await this.call('GET', '/api/portraits')).json;
  upload = (image: Buffer | string, width = 600, height = 800) =>
    this.call('POST', '/api/portraits/reference', { image: typeof image === 'string' ? image : image.toString('base64'), width, height });
}

const owner = new Client();
const bob = new Client();
const carol = new Client();
let bobId = '';

/** Polls the list, as the studio does, until the portrait isn't pending. */
async function settled(c: Client, id: string) {
  for (let i = 0; i < 100; i++) {
    const p = (await c.list()).portraits.find((x: { id: string }) => x.id === id);
    if (p && p.status !== 'pending') return p;
    await new Promise((r) => setTimeout(r, 20));
  }
  throw new Error('still pending');
}

test('setup: an owner and two invited members', async () => {
  assert.equal((await owner.call('POST', '/api/auth/login', { email: 'owner@example.com', password: OWNER_PASSWORD })).status, 200);
  for (const [c, email, name] of [
    [bob, 'bob@example.com', 'Bob'],
    [carol, 'carol@example.com', 'Carol'],
  ] as const) {
    const token = (await owner.call('POST', '/api/admin/invites', {})).json.url.split('/').at(-1);
    assert.equal((await c.call('POST', '/api/auth/invite', { token, email, name, password: `${name} password 123` })).status, 200);
  }
  bobId = (await bob.call('GET', '/api/auth/me')).json.user.id;
});

test('portraits are for signed-in people, and writes need the X-HealthOS header', async () => {
  const stranger = new Client();
  assert.equal((await stranger.call('GET', '/api/portraits')).status, 401);
  assert.equal((await stranger.upload(jpeg(600, 800))).status, 401);
  assert.equal((await bob.call('POST', '/api/portraits/reference', { image: jpeg(600, 800).toString('base64') }, {})).status, 403);
  assert.deepEqual(await bob.list(), { portraits: [], chosen: null, canGenerate: false });
});

test('a reference must be a JPEG of a sensible size, judged by its bytes', async () => {
  const cases: [string, Awaited<ReturnType<Client['call']>>, number][] = [
    ['nothing', await bob.call('POST', '/api/portraits/reference', {}), 400],
    ['a PNG', await bob.upload(png(64, 64)), 400],
    ['not base64', await bob.upload('this is not base64 at all!'), 400],
    ['a JPEG start with no frame', await bob.upload(Buffer.from([0xff, 0xd8, 0xff, 0xd9, 0, 0, 0, 0, 0, 0, 0, 0])), 400],
    ['larger than 1600 px', await bob.upload(jpeg(2400, 1600)), 413],
    ['over the base64 limit', await bob.upload('A'.repeat(MAX_REFERENCE_BASE64 + 4)), 413],
    ['far over the body limit', await bob.upload('A'.repeat(MAX_REFERENCE_BASE64 + 200_000)), 413],
  ];
  for (const [what, r, status] of cases) {
    assert.equal(r.status, status, `${what}: ${JSON.stringify(r.json)}`);
    assert.equal(typeof r.json?.error, 'string', what);
  }
  assert.equal((await bob.list()).portraits.length, 0, 'nothing refused is kept');
});

test(`POST /reference returns the saved photo, at most ${MAX_REFERENCES} of them`, async () => {
  const v0 = (await bob.call('GET', '/api/version')).json.version;
  const ids: string[] = [];
  for (let i = 0; i < MAX_REFERENCES; i++) {
    // The request claims 1x1; the bytes say 1200x1600, and the bytes win.
    const r = await bob.upload(jpeg(1200, 1600, i), 1, 1);
    assert.equal(r.status, 200, JSON.stringify(r.json));
    const p = r.json.portrait;
    assert.equal(p.kind, 'reference');
    assert.equal(p.status, 'ready');
    assert.equal(p.mime, 'image/jpeg');
    assert.deepEqual([p.width, p.height], [1200, 1600]);
    assert.equal(p.referenceId, null);
    ids.push(p.id);
  }
  assert.notEqual((await bob.call('GET', '/api/version')).json.version, v0, 'a new photo moves the data version');
  const full = await bob.upload(jpeg(600, 800));
  assert.equal(full.status, 409);
  assert.match(full.json.error, /Delete one/);
  const list = await bob.list();
  assert.deepEqual(
    list.portraits.map((p: { id: string }) => p.id),
    ids,
    'oldest first',
  );
  assert.equal(JSON.stringify(list).includes('/9j/'), false, 'the list never carries an image');
  // Deleting the oldest makes room again.
  assert.equal((await bob.call('DELETE', `/api/portraits/${ids[0]}`)).status, 200);
  assert.equal((await bob.upload(jpeg(800, 600))).status, 200);
});

test('only the owner can read a photo', async () => {
  const id = (await bob.list()).portraits[0].id;
  const mine = await bob.call('GET', `/api/portraits/${id}/image`);
  assert.equal(mine.status, 200);
  assert.equal(mine.headers.get('content-type'), 'image/jpeg');
  assert.equal(mine.headers.get('x-content-type-options'), 'nosniff');
  assert.equal(mine.headers.get('cache-control'), 'private, no-store');
  assert.deepEqual(mine.buf, jpeg(1200, 1600, 1));
  // Someone else's looks exactly like one that isn't there.
  const theirs = await carol.call('GET', `/api/portraits/${id}/image`);
  assert.equal(theirs.status, 404);
  assert.deepEqual(theirs.json, (await carol.call('GET', '/api/portraits/no-such-photo/image')).json);
  assert.equal((await owner.call('GET', `/api/portraits/${id}/image`)).status, 404, 'an admin is no exception');
  assert.equal((await new Client().call('GET', `/api/portraits/${id}/image`)).status, 401);
});

test('making a portrait needs an OpenAI key', async () => {
  const id = (await bob.list()).portraits[0].id;
  const r = await bob.call('POST', '/api/portraits/generate', { referenceId: id });
  assert.equal(r.status, 409);
  assert.equal(r.json.error, 'Connect your OpenAI key in your Profile to make a portrait.');
  assert.equal(edits.length, 0, 'nothing was sent');
  assert.equal((await bob.list()).portraits.length, MAX_REFERENCES, 'and nothing was added');
});

let readyId = '';

test('with a key: pending at once, then ready, from both images', async () => {
  assert.equal((await bob.call('PUT', '/api/ai/keys/openai', { key: OPENAI_KEY })).status, 200);
  const list = await bob.list();
  assert.equal(list.canGenerate, true);
  const ref = list.portraits[1];
  hold();
  const r = await bob.call('POST', '/api/portraits/generate', { referenceId: ref.id });
  assert.equal(r.status, 202, JSON.stringify(r.json));
  const p = r.json.portrait;
  assert.equal(p.kind, 'generated');
  assert.equal(p.status, 'pending');
  assert.equal(p.referenceId, ref.id);
  // One at a time.
  const again = await bob.call('POST', '/api/portraits/generate', { referenceId: ref.id });
  assert.equal(again.status, 409);
  assert.match(again.json.error, /still being made/);
  assert.equal((await bob.list()).portraits.find((x: { id: string }) => x.id === p.id).status, 'pending');
  assert.equal((await bob.call('GET', `/api/portraits/${p.id}/image`)).status, 404, 'no image while it is being made');
  release();
  const done = await settled(bob, p.id);
  assert.equal(done.status, 'ready', done.error);
  assert.equal(done.mime, 'image/webp');
  assert.deepEqual([done.width, done.height], [1024, 1536]);
  assert.equal(done.error, '');
  readyId = done.id;

  // What OpenAI was sent: the image edit, on Bob's key, with his photo first and the healthOS figure second.
  assert.equal(edits.length, 1);
  const [{ url, auth, form }] = edits;
  assert.equal(url, 'https://api.openai.com/v1/images/edits');
  assert.equal(auth, `Bearer ${OPENAI_KEY}`);
  assert.equal(form.get('model'), PORTRAIT_MODEL);
  assert.equal(form.get('background'), 'transparent');
  assert.equal(form.get('size'), '1024x1536');
  assert.equal(form.get('n'), '1');
  assert.equal(form.get('response_format'), null, 'not a parameter for GPT image models');
  assert.match(String(form.get('prompt')), /Image 1 is a photo of a person/);
  const images = form.getAll('image[]') as File[];
  assert.deepEqual(
    images.map((f) => f.type),
    ['image/jpeg', 'image/webp'],
  );
  assert.deepEqual(Buffer.from(await images[0].arrayBuffer()), jpeg(1200, 1600, 2));
  assert.deepEqual(Buffer.from(await images[1].arrayBuffer()), fs.readFileSync(path.join(import.meta.dirname, '..', 'public', 'figures', 'digital-man.webp')));

  const img = await bob.call('GET', `/api/portraits/${done.id}/image`);
  assert.equal(img.status, 200);
  assert.equal(img.headers.get('content-type'), 'image/webp');
  assert.deepEqual(img.buf, webp(1024, 1536));
});

test('a portrait OpenAI declines, or a key it refuses, fails in plain words and leaves the day’s count alone', async () => {
  const ref = (await bob.list()).portraits[1];
  for (const [m, words] of [
    ['declined', /declined to make a portrait/],
    ['refused', /Your OpenAI key isn't working/],
    ['garbled', /didn't send back a portrait/],
  ] as const) {
    mode = m;
    const r = await bob.call('POST', '/api/portraits/generate', { referenceId: ref.id });
    assert.equal(r.status, 202);
    const done = await settled(bob, r.json.portrait.id);
    assert.equal(done.status, 'failed', m);
    assert.match(done.error, words);
    assert.equal(done.error.includes('sk-'), false, 'nothing of the key or the provider message');
    assert.equal((await bob.call('DELETE', `/api/portraits/${done.id}`)).status, 200);
  }
  mode = 'ok';
  const usage = (await db.query<{ value: string }>(`SELECT value FROM user_settings WHERE user_id = $1 AND key = 'portrait_usage'`, [bobId]))[0];
  assert.equal(JSON.parse(usage.value).count, 1, 'only the portrait that was made counts');
  // A refused key is noted on it, as Profile shows.
  const keys = (await bob.call('GET', '/api/ai')).json.keys;
  assert.equal(keys.find((k: { provider: string }) => k.provider === 'openai').lastError, 'auth');
});

test('a run that was cut off is marked failed, and the next one can start', async () => {
  const ref = (await bob.list()).portraits[1];
  await db.query(
    `INSERT INTO portraits (user_id, id, kind, status, mime, bytes, reference_id, created_at) VALUES ($1, 'stuck', 'generated', 'pending', 'image/webp', 0, $2, $3)`,
    [bobId, ref.id, Date.now() - 10 * 60_000],
  );
  const stuck = (await bob.list()).portraits.find((p: { id: string }) => p.id === 'stuck');
  assert.equal(stuck.status, 'failed');
  assert.match(stuck.error, /took too long/);
  const r = await bob.call('POST', '/api/portraits/generate', { referenceId: ref.id });
  assert.equal(r.status, 202);
  assert.equal((await settled(bob, r.json.portrait.id)).status, 'ready');
  await bob.call('DELETE', '/api/portraits/stuck');
});

test(`at most ${PORTRAITS_PER_DAY} a day, and ${MAX_GENERATED} kept`, async () => {
  const ref = (await bob.list()).portraits[1];
  const day = new Date().toISOString().slice(0, 10);
  await setUserSetting(db, bobId, 'portrait_usage', JSON.stringify({ day, count: PORTRAITS_PER_DAY }));
  const capped = await bob.call('POST', '/api/portraits/generate', { referenceId: ref.id });
  assert.equal(capped.status, 429);
  assert.match(capped.json.error, /Try again tomorrow/);
  // Yesterday's count doesn't carry over.
  await setUserSetting(db, bobId, 'portrait_usage', JSON.stringify({ day: '2000-01-01', count: PORTRAITS_PER_DAY }));
  const kept = (await bob.list()).portraits.filter((p: { kind: string }) => p.kind === 'generated').length;
  for (let i = kept; i < MAX_GENERATED; i++) {
    await db.query(`INSERT INTO portraits (user_id, id, kind, status, mime, bytes, reference_id, created_at) VALUES ($1, $2, 'generated', 'failed', 'image/webp', 0, $3, $4)`, [
      bobId,
      `filler-${i}`,
      ref.id,
      Date.now(),
    ]);
  }
  const full = await bob.call('POST', '/api/portraits/generate', { referenceId: ref.id });
  assert.equal(full.status, 409);
  assert.match(full.json.error, /Delete one/);
  await db.query(`DELETE FROM portraits WHERE user_id = $1 AND id LIKE 'filler-%'`, [bobId]);
});

test('choosing a portrait marks it in use while it is the profile photo', async () => {
  const ref = (await bob.list()).portraits[0];
  assert.equal((await bob.call('POST', `/api/portraits/${ref.id}/choose`)).status, 400, 'a reference is never the one in use');
  // The browser saves the cut-out first (POST /api/profile/photo/upload), then marks the portrait chosen.
  const meta = {
    width: 300,
    height: 400,
    face: [0.4, 0.15, 0.3, 0.22],
    shoulderY: 0.48,
    dots: { temp: [0.58, 0.13], breathing: [0.57, 0.4], heart: [0.63, 0.6] },
  };
  const photo = { cutout: png(300, 400).toString('base64'), avatar: png(320, 320).toString('base64'), meta };
  assert.equal((await bob.call('POST', '/api/profile/photo/upload', photo)).status, 200);
  const chosen = await bob.call('POST', `/api/portraits/${readyId}/choose`);
  assert.equal(chosen.status, 200);
  assert.equal(chosen.json.chosen, readyId);
  assert.equal((await bob.list()).chosen, readyId);
  // Another photo later ("Use a photo as is"): no portrait is in use any more.
  assert.equal((await bob.call('POST', '/api/profile/photo/upload', photo)).status, 200);
  assert.equal((await bob.list()).chosen, null);
  // Chosen again, then deleted: no longer in use, and the profile photo stays.
  await bob.call('POST', `/api/portraits/${readyId}/choose`);
  const gone = await bob.call('DELETE', `/api/portraits/${readyId}`);
  assert.equal(gone.status, 200);
  assert.equal(gone.json.chosen, null);
  assert.equal(gone.json.portraits.some((p: { id: string }) => p.id === readyId), false);
  assert.equal((await bob.call('DELETE', `/api/portraits/${readyId}`)).status, 404);
  assert.notEqual((await bob.call('GET', '/api/status')).json.photo, null);
});

test("nobody else can use, choose or delete someone's photos", async () => {
  const before = await bob.list();
  const ref = before.portraits[0];
  const made = await bob.call('POST', '/api/portraits/generate', { referenceId: ref.id });
  const portrait = (await settled(bob, made.json.portrait.id)).id;
  const sent = edits.length;
  assert.equal((await carol.call('POST', '/api/portraits/generate', { referenceId: ref.id })).status, 404);
  assert.equal(edits.length, sent, "Bob's photo went nowhere");
  assert.equal((await carol.call('POST', `/api/portraits/${portrait}/choose`)).status, 404);
  assert.equal((await carol.call('DELETE', `/api/portraits/${ref.id}`)).status, 404);
  assert.equal((await carol.call('DELETE', `/api/portraits/${portrait}`)).status, 404);
  assert.equal((await owner.call('DELETE', `/api/portraits/${portrait}`)).status, 404);
  assert.deepEqual((await carol.list()).portraits, []);
  assert.deepEqual((await owner.list()).portraits, []);
  assert.equal((await bob.list()).portraits.length, before.portraits.length + 1);
});

test('the image readers agree with the formats', () => {
  assert.deepEqual(jpegSize(jpeg(640, 480)), { width: 640, height: 480 });
  assert.equal(jpegSize(png(10, 10)), null);
  assert.deepEqual(webpSize(webp(1024, 1536)), { width: 1024, height: 1536 });
  // The real figure, an extended WebP.
  const figure = fs.readFileSync(path.join(import.meta.dirname, '..', 'public', 'figures', 'digital-man.webp'));
  assert.notEqual(webpSize(figure), null);
});

test('the style reference in the server code is the figure in public/', () => {
  const figure = fs.readFileSync(path.join(import.meta.dirname, '..', 'public', 'figures', 'digital-man.webp'));
  assert.ok(
    Buffer.from(STYLE_REFERENCE_BASE64, 'base64').equals(figure),
    'public/figures/digital-man.webp changed: run node scripts/portrait-style.mjs to update server/portraitStyle.ts',
  );
});
