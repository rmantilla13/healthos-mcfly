// POST /api/profile/photo/upload: a photo processed on the person's own device (browser or iPhone), stored by
// the server. The server trusts nothing it's sent: real PNGs, sensible sizes, layout numbers within 0–1.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { AddressInfo } from 'node:net';
import zlib from 'node:zlib';
import { createApp } from '../server/app.ts';
import { hashPassword } from '../server/auth.ts';
import { openStore } from '../server/store.ts';

process.env.SESSION_SECRET = 'photo-test-secret-'.padEnd(64, 'x');
process.env.HEALTHOS_PASSWORD_HASH = await hashPassword('owner password 123');

const db = await openStore();
const server = createApp({ db, hosted: true }).listen(0, '127.0.0.1');
await new Promise((r) => server.once('listening', r));
const base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
test.after(() => {
  server.close();
});

/** A real, minimal RGBA PNG of the given size. */
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
  ihdr[8] = 8; // bit depth
  ihdr[9] = 6; // RGBA
  const rows = Buffer.alloc((width * 4 + 1) * height);
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr),
    chunk('IDAT', zlib.deflateSync(rows)),
    chunk('IEND', Buffer.alloc(0)),
  ]);
}

let cookie = '';
async function call(method: string, path: string, body?: unknown) {
  const res = await fetch(base + path, {
    method,
    headers: { 'X-HealthOS': '1', 'Content-Type': 'application/json', ...(cookie ? { Cookie: cookie } : {}) },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const set = res.headers.get('set-cookie');
  if (set) cookie = set.split(';')[0];
  const buf = Buffer.from(await res.arrayBuffer());
  let json: any = null;
  try {
    json = JSON.parse(buf.toString());
  } catch {
    json = null;
  }
  return { status: res.status, json, buf };
}

const meta = (over: Record<string, unknown> = {}) => ({
  width: 300,
  height: 400,
  face: [0.4, 0.15, 0.3, 0.22],
  shoulderY: 0.48,
  outline: Array.from({ length: 100 }, () => [0.1, 0.9]),
  dots: { temp: [0.58, 0.13], breathing: [0.57, 0.4], heart: [0.63, 0.6], wrist: [0.69, 0.79] },
  ...over,
});
const upload = (over: Record<string, unknown> = {}, m: Record<string, unknown> = {}) =>
  call('POST', '/api/profile/photo/upload', { cutout: png(300, 400).toString('base64'), avatar: png(320, 320).toString('base64'), meta: meta(m), ...over });

test('uploading needs a signed-in person', async () => {
  assert.equal((await upload()).status, 401);
  assert.equal((await call('POST', '/api/auth/login', { email: 'owner@example.com', password: 'owner password 123' })).status, 200);
});

test('a processed photo is stored, served, and moves the data version', async () => {
  const v0 = (await call('GET', '/api/version')).json.version;
  const r = await upload();
  assert.equal(r.status, 200, JSON.stringify(r.json));
  const status = (await call('GET', '/api/status')).json;
  assert.equal(status.photo.width, 300);
  assert.deepEqual(status.photo.dots.wrist, [0.69, 0.79]);
  const img = await call('GET', `/api/profile/cutout.png?v=${status.photo.version}`);
  assert.equal(img.status, 200);
  assert.deepEqual(img.buf.subarray(0, 8), png(1, 1).subarray(0, 8));
  assert.notEqual((await call('GET', '/api/version')).json.version, v0);

  // Replacing it mints a new version: the images are cached forever under ?v=.
  await upload();
  assert.ok((await call('GET', '/api/status')).json.photo.version > status.photo.version);
});

test('anything malformed is refused, and the stored photo is left alone', async () => {
  const before = (await call('GET', '/api/status')).json.photo.version;
  const cases: [string, Promise<{ status: number }>][] = [
    ['not a PNG', upload({ cutout: Buffer.from('hello').toString('base64') })],
    ['missing avatar', upload({ avatar: undefined })],
    ['size mismatch', upload({}, { width: 301 })],
    ['dot out of range', upload({}, { dots: { temp: [1.2, 0.1], breathing: [0.5, 0.4], heart: [0.6, 0.6] } })],
    ['unknown dot', upload({}, { dots: { temp: [0.5, 0.1], breathing: [0.5, 0.4], heart: [0.6, 0.6], nose: [0.5, 0.2] } })],
    ['missing heart', upload({}, { dots: { temp: [0.5, 0.1], breathing: [0.5, 0.4] } })],
    ['short outline', upload({}, { outline: [[0, 1]] })],
    ['face not a box', upload({}, { face: [0.4, 0.1, 0, 0.2] })],
    ['tiny cut-out', call('POST', '/api/profile/photo/upload', { cutout: png(10, 10).toString('base64'), avatar: png(320, 320).toString('base64'), meta: meta({ width: 10, height: 10 }) })],
  ];
  for (const [name, res] of cases) assert.equal((await res).status, 400, name);
  assert.equal((await call('GET', '/api/status')).json.photo.version, before);
});

test('an oversized request is refused before it is read', async () => {
  const r = await call('POST', '/api/profile/photo/upload', { cutout: 'A'.repeat(7 * 1_048_576), avatar: '', meta: {} });
  assert.equal(r.status, 413);
});

test('removing the photo works on the hosted app too', async () => {
  assert.equal((await call('POST', '/api/profile/photo/clear', {})).status, 200);
  assert.equal((await call('GET', '/api/status')).json.photo, null);
});
