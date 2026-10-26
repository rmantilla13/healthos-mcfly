// Lab documents (Blood records → Lab documents): original reports kept in the person's account. Uploading, listing,
// opening and deleting; a copy refused; files checked by their bytes, not their label; names cleaned; nothing visible
// to anyone else (the admin included); and reading the results from a kept report, on the shared Claude key (one Ask
// McFly question) or on the person's own (counted apart, never in the admin's view). Every AI here is a fake.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { AddressInfo } from 'node:net';
import type { AiFetch } from '../server/ai/provider.ts';
import { createApp } from '../server/app.ts';
import { hashPassword } from '../server/auth.ts';
import { addDays, todayLocal } from '../server/dates.ts';
import { documentName } from '../server/labs.ts';
import type { McflyClient } from '../server/mcfly.ts';
import { openStore } from '../server/store.ts';

delete process.env.ANTHROPIC_API_KEY;
delete process.env.HEALTHOS_DATA_KEY_PREVIOUS;
process.env.HEALTHOS_DATA_KEY = 'd4'.repeat(32);
process.env.SESSION_SECRET = 'lab-documents-test-secret-'.padEnd(64, 'x');
const OWNER_PASSWORD = 'owner password 123';
process.env.HEALTHOS_PASSWORD_HASH = await hashPassword(OWNER_PASSWORD);
const CLAUDE_KEY = 'sk-ant-api03-TESTKEY-labdocs-1234567890abcd7e1f';

const today = todayLocal();
const ROW = { name: 'Glucose', value_text: '92', unit: 'mg/dL', ref_text: '70-99', ref_low: 70, ref_high: 99, collected: addDays(today, -2), lab: 'Quest', panel: 'Metabolic' };
const message = (results: unknown[], usage = { input_tokens: 1200, output_tokens: 300 }) => ({
  id: 'msg_test',
  type: 'message',
  role: 'assistant',
  model: 'claude-opus-5-5',
  content: [{ type: 'text', text: JSON.stringify({ is_lab_report: true, note: null, results }) }],
  stop_reason: 'end_turn',
  stop_sequence: null,
  usage: { ...usage, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 },
});

// ---------- the shared Claude key, as a fake ----------
const shared: any[] = [];
let sharedScript: unknown[] = [];
const sharedFake = {
  beta: {
    messages: {
      async create(params: unknown) {
        shared.push(structuredClone(params));
        const next = sharedScript.shift();
        if (!next) throw new Error('fake Claude ran out of scripted replies');
        if (next instanceof Error) throw next;
        return next;
      },
    },
  },
} as unknown as McflyClient;

// ---------- a person's own Claude key, through a fake fetch ----------
const own: { url: string; body: any }[] = [];
let ownScript: (() => Response)[] = [];
const aiFetch: AiFetch = async (url, init) => {
  const u = String(url);
  if (u === 'https://api.anthropic.com/v1/models?limit=1') return new Response(JSON.stringify({ data: [] }));
  own.push({ url: u, body: typeof init?.body === 'string' ? JSON.parse(init.body) : null });
  const next = ownScript.shift();
  if (!next) throw new Error(`fake provider has no reply for ${u}`);
  return next();
};
const json = (body: unknown, status = 200) => () => new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });

const db = await openStore();
const server = createApp({ db, hosted: false, mcflyClient: () => sharedFake, aiFetch }).listen(0, '127.0.0.1');
await new Promise((r) => server.once('listening', r));
const base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
test.after(async () => {
  server.close();
  await db.close();
});

class Client {
  cookie = '';
  async call(method: string, path: string, body?: unknown, raw?: { type: string; data: Uint8Array<ArrayBuffer>; name?: string }) {
    const res = await fetch(base + path, {
      method,
      headers: {
        'X-HealthOS': '1',
        'Content-Type': raw ? raw.type : 'application/json',
        ...(raw?.name !== undefined ? { 'X-Filename': raw.name } : {}),
        ...(this.cookie ? { Cookie: this.cookie } : {}),
      },
      body: raw ? raw.data : body === undefined ? undefined : JSON.stringify(body),
    });
    const set = res.headers.get('set-cookie');
    if (set) this.cookie = set.split(';')[0];
    const bytes = new Uint8Array(await res.arrayBuffer());
    const text = new TextDecoder().decode(bytes);
    let parsed: any = null;
    try {
      parsed = JSON.parse(text);
    } catch {
      parsed = null;
    }
    return { status: res.status, headers: res.headers, bytes, text, json: parsed };
  }
  documents() {
    return this.call('GET', '/api/labs/documents');
  }
  upload(type: string, data: Uint8Array<ArrayBuffer>, name?: string) {
    return this.call('POST', '/api/labs/documents', undefined, { type, data, name: name === undefined ? undefined : encodeURIComponent(name) });
  }
  read(id: string) {
    return this.call('POST', `/api/labs/extract?document=${encodeURIComponent(id)}`);
  }
}

const pdf = (marker = '', bytes = 3000) => {
  const b = new Uint8Array(bytes).fill(0x20);
  b.set(new TextEncoder().encode(`%PDF-1.7\n%${marker}\n`));
  return b;
};
const png = (seed = 0) => {
  const b = new Uint8Array(4096);
  b.set([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  b[100] = seed;
  return b;
};
const jpeg = () => {
  const b = new Uint8Array(4096).fill(7);
  b.set([0xff, 0xd8, 0xff, 0xe0]);
  return b;
};

const owner = new Client();
const bob = new Client();
const carol = new Client();
const ids: Record<string, string> = {};
const usage = async (userId: string) => {
  const [row] = await db.query<{ questions: number; own_questions: number; input_tokens: number; own_input_tokens: number }>(
    'SELECT questions, own_questions, input_tokens::float8 AS input_tokens, own_input_tokens::float8 AS own_input_tokens FROM mcfly_usage WHERE user_id = $1',
    [userId],
  );
  return { questions: Number(row?.questions ?? 0), own: Number(row?.own_questions ?? 0), tokens: Number(row?.input_tokens ?? 0), ownTokens: Number(row?.own_input_tokens ?? 0) };
};

test('setup: an owner (an admin) and two invited members', async () => {
  assert.equal((await owner.call('POST', '/api/auth/login', { email: 'owner@example.com', password: OWNER_PASSWORD })).status, 200);
  for (const [c, name] of [
    [bob, 'bob'],
    [carol, 'carol'],
  ] as const) {
    const token = (await owner.call('POST', '/api/admin/invites', {})).json.url.split('/').at(-1);
    assert.equal((await c.call('POST', '/api/auth/invite', { token, email: `${name}@example.com`, name, password: `${name} password 123` })).status, 200);
    ids[name] = (await c.call('GET', '/api/auth/me')).json.user.id;
  }
});

test('names are cleaned: no path, no control characters, at most 120 characters, the right extension', () => {
  assert.equal(documentName(encodeURIComponent('../../etc/Quest results — Oct.pdf'), 'application/pdf'), 'Quest results — Oct.pdf');
  assert.equal(documentName('C:%5CUsers%5Cme%5Creport.pdf', 'application/pdf'), 'report.pdf');
  assert.equal(documentName(encodeURIComponent('IMG_2041.HEIC'), 'image/jpeg'), 'IMG_2041.jpg', 'a HEIC photo made a JPEG on the device');
  assert.equal(documentName(encodeURIComponent('scan.JPEG'), 'image/jpeg'), 'scan.JPEG');
  assert.equal(documentName(encodeURIComponent('notes.txt'), 'application/pdf'), 'notes.txt.pdf');
  assert.equal(documentName(encodeURIComponent('bad\u0000na‮me\n.pdf'), 'application/pdf'), 'badname.pdf');
  assert.equal(documentName(undefined, 'image/png'), 'Lab report.png');
  assert.equal(documentName('%E0%A4%A', 'application/pdf'), '%E0%A4%A.pdf', 'not URI-encoded: used as it came');
  assert.equal(documentName(encodeURIComponent('..'), 'application/pdf'), 'Lab report.pdf');
  const long = documentName(encodeURIComponent(`${'é'.repeat(200)}.pdf`), 'application/pdf');
  assert.equal([...long].length, 120);
  assert.ok(long.endsWith('é.pdf'));
});

test('nothing kept yet: an empty list, not an error', async () => {
  const r = await bob.documents();
  assert.equal(r.status, 200);
  assert.deepEqual(r.json, { documents: [] });
});

test('a report is kept: listed newest first by name, type and size, with the data version moved', async () => {
  const before = (await bob.call('GET', '/api/version')).json.version;
  const r = await bob.upload('application/pdf', pdf('bob-first-secret', 1_000_000), '../../Quest results — Oct.pdf');
  assert.equal(r.status, 200, r.text);
  const doc = r.json.document;
  assert.deepEqual([doc.name, doc.mime, doc.size, doc.readAt], ['Quest results — Oct.pdf', 'application/pdf', 1_000_000, null]);
  assert.equal(typeof doc.uploadedAt, 'number');
  ids.first = doc.id;
  assert.notEqual((await bob.call('GET', '/api/version')).json.version, before);

  const photo = await bob.upload('image/jpeg', jpeg(), 'IMG_2041.HEIC');
  assert.equal(photo.status, 200, photo.text);
  assert.equal(photo.json.document.name, 'IMG_2041.jpg');
  ids.photo = photo.json.document.id;

  const list = (await bob.documents()).json.documents;
  assert.deepEqual(
    list.map((d: { id: string }) => d.id),
    [ids.photo, ids.first],
  );
  assert.ok(!('data' in list[0]) && !('sha256' in list[0]), 'metadata only');
});

test('opening a report sends its bytes as its own type, sandboxed, never sniffed and never cached', async () => {
  const r = await bob.call('GET', `/api/labs/documents/${ids.first}`);
  assert.equal(r.status, 200);
  assert.equal(r.bytes.length, 1_000_000);
  assert.ok(new TextDecoder().decode(r.bytes.slice(0, 30)).includes('bob-first-secret'));
  assert.equal(r.headers.get('content-type'), 'application/pdf');
  assert.equal(r.headers.get('x-content-type-options'), 'nosniff');
  assert.equal(r.headers.get('content-security-policy'), 'sandbox');
  assert.equal(r.headers.get('cache-control'), 'private, no-store');
  assert.equal(r.headers.get('content-disposition'), `inline; filename="Quest results _ Oct.pdf"; filename*=UTF-8''Quest%20results%20%E2%80%94%20Oct.pdf`);
  assert.equal((await bob.call('GET', '/api/labs/documents/no-such-id')).status, 404);
});

test("a name with quotes and brackets can't break out of the header", async () => {
  const r = await bob.upload('image/png', png(1), `Résumé "final"; (1)'*.png`);
  assert.equal(r.status, 200);
  const open = await bob.call('GET', `/api/labs/documents/${r.json.document.id}`);
  await bob.call('DELETE', `/api/labs/documents/${r.json.document.id}`);
  assert.equal(r.json.document.name, `Résumé "final"; (1)'*.png`);
  assert.equal(open.headers.get('content-disposition'), `inline; filename="R_sum_ _final_; (1)'*.png"; filename*=UTF-8''R%C3%A9sum%C3%A9%20%22final%22%3B%20%281%29%27%2A.png`);
});

test("the same report twice is refused, but another person's copy is their own", async () => {
  const again = await bob.upload('application/pdf', pdf('bob-first-secret', 1_000_000), 'Renamed.pdf');
  assert.equal(again.status, 409);
  assert.equal(again.json.error, "You've already uploaded this report.");
  assert.equal((await bob.documents()).json.documents.length, 2);
  const carols = await carol.upload('application/pdf', pdf('bob-first-secret', 1_000_000), 'Same bytes.pdf');
  assert.equal(carols.status, 200);
  ids.carolDoc = carols.json.document.id;
});

test('files are checked by their bytes: the wrong kind, a mislabelled one, an empty one or one over 4 MB is refused', async () => {
  const cases: [string, Uint8Array<ArrayBuffer>, number, RegExp][] = [
    ['application/pdf', png(9), 400, /doesn't look like a PDF/],
    ['image/png', pdf('x'), 400, /doesn't look like/],
    ['image/jpeg', png(9), 400, /doesn't look like/],
    ['image/gif', new TextEncoder().encode('GIF89a and more bytes here'), 415, /PDF, or a photo/],
    ['image/heic', new Uint8Array(100), 415, /PDF, or a photo/],
    ['text/html', new TextEncoder().encode('<script>alert(1)</script>'), 415, /PDF, or a photo/],
    ['image/svg+xml', new TextEncoder().encode('<svg onload="alert(1)"/>'), 415, /PDF, or a photo/],
    ['application/pdf', new Uint8Array(0), 400, /empty/],
    ['application/pdf', pdf('big', 4 * 1024 * 1024 + 1), 413, /over 4 MB/],
  ];
  for (const [type, data, status, error] of cases) {
    const r = await bob.upload(type, data, 'x.pdf');
    assert.equal(r.status, status, type);
    assert.match(r.json.error, error);
  }
  assert.equal((await bob.documents()).json.documents.length, 2, 'none were kept');
});

test("nobody else can list, open, read or delete someone's report, the admin included", async () => {
  assert.deepEqual(
    (await owner.documents()).json.documents,
    [],
  );
  assert.equal((await owner.call('GET', `/api/labs/documents/${ids.first}`)).status, 404);
  assert.equal((await owner.call('DELETE', `/api/labs/documents/${ids.first}`)).status, 404);
  const before = await usage(ids.bob);
  sharedScript = [message([ROW])];
  assert.equal((await owner.read(ids.first)).status, 404, "another person's report isn't read");
  assert.equal(shared.length, 0, 'and nothing went to Claude');
  sharedScript = [];
  assert.deepEqual(await usage(ids.bob), before);
  assert.equal((await carol.documents()).json.documents.length, 1);

  // Not on the Family board, the admin's screens or anywhere McFly reads.
  for (const [who, path] of [
    [owner, '/api/family'],
    [bob, '/api/family'],
    [owner, '/api/admin/overview'],
    [bob, '/api/labs'],
    [bob, '/api/summary'],
  ] as const) {
    const r = await who.call('GET', path);
    assert.equal(r.status, 200, path);
    assert.ok(!r.text.includes('Quest results') && !r.text.includes('bob-first-secret'), path);
  }
});

test('what reading would use: the shared key and its daily limit', async () => {
  const r = await bob.call('GET', '/api/labs/reader');
  assert.equal(r.status, 200);
  assert.deepEqual(r.json, { source: 'shared', reason: null, limit: 50, usedToday: 0 });
});

test('a kept report is read on the shared key: its bytes go to Claude, one question is counted, and it says it was read', async () => {
  shared.length = 0;
  sharedScript = [message([ROW, { ...ROW, name: 'Vitamin D', value_text: '42', unit: 'ng/mL', ref_text: '30-100', ref_low: 30, ref_high: 100 }])];
  const before = (await bob.call('GET', '/api/version')).json.version;
  const r = await bob.read(ids.first);
  assert.equal(r.status, 200, r.text);
  assert.equal(r.json.rows.length, 2);
  assert.deepEqual([r.json.usedToday, r.json.limit], [1, 50]);
  const block = shared[0].messages[0].content[0];
  assert.deepEqual([block.type, block.source.media_type], ['document', 'application/pdf']);
  const sent = Buffer.from(block.source.data, 'base64');
  assert.equal(sent.length, 1_000_000);
  assert.ok(sent.subarray(0, 30).toString('latin1').includes('bob-first-secret'), 'the stored bytes, not a new upload');
  assert.equal(shared[0].model, 'claude-opus-5-5');
  assert.deepEqual(await usage(ids.bob), { questions: 1, own: 0, tokens: 1200, ownTokens: 0 });
  assert.notEqual((await bob.call('GET', '/api/version')).json.version, before);
  const doc = (await bob.documents()).json.documents.find((d: { id: string }) => d.id === ids.first);
  assert.equal(typeof doc.readAt, 'number');
  // A draft only: nothing is saved until the rows are checked and added.
  assert.equal((await bob.call('GET', '/api/labs')).json.count, 0);

  // A photo goes as an image block.
  sharedScript = [message([ROW])];
  assert.equal((await bob.read(ids.photo)).status, 200);
  assert.deepEqual([shared[1].messages[0].content[0].type, shared[1].messages[0].content[0].source.media_type], ['image', 'image/jpeg']);
  assert.equal((await bob.call('GET', '/api/labs/reader')).json.usedToday, 2);
});

test('a read that fails is given back, and a report with nothing on it is not marked as read', async () => {
  const before = await usage(ids.carol);
  sharedScript = [new Error('upstream')];
  const failed = await carol.read(ids.carolDoc);
  assert.equal(failed.status, 502);
  assert.equal((await usage(ids.carol)).questions, before.questions);

  sharedScript = [{ ...message([]), content: [{ type: 'text', text: JSON.stringify({ is_lab_report: false, note: null, results: [] }) }] }];
  const empty = await carol.read(ids.carolDoc);
  assert.equal(empty.status, 200);
  assert.deepEqual(empty.json.rows, []);
  assert.equal((await carol.documents()).json.documents[0].readAt, null);
});

test("on the person's own Claude key: counted apart, never in the admin's view, and a refused key says so", async () => {
  const save = await carol.call('PUT', '/api/ai/keys/anthropic', { key: CLAUDE_KEY });
  assert.equal(save.status, 200, save.text);
  assert.deepEqual((await carol.call('GET', '/api/labs/reader')).json, { source: 'own', reason: null, limit: 200, usedToday: 0 });

  const before = await usage(ids.carol);
  shared.length = 0;
  own.length = 0;
  ownScript = [json(message([ROW], { input_tokens: 900, output_tokens: 100 }))];
  const r = await carol.read(ids.carolDoc);
  assert.equal(r.status, 200, r.text);
  assert.deepEqual([r.json.rows.length, r.json.usedToday, r.json.limit], [1, 1, 200]);
  assert.equal(shared.length, 0, 'the shared key was not used');
  assert.ok(own[0].url.startsWith('https://api.anthropic.com/v1/messages'));
  assert.equal(own[0].body.messages[0].content[0].type, 'document');
  const after = await usage(ids.carol);
  assert.deepEqual([after.questions, after.tokens], [before.questions, before.tokens], "the shared limit and the admin's cost view are untouched");
  assert.deepEqual([after.own, after.ownTokens], [before.own + 1, before.ownTokens + 900]);

  // With McFly turned off by the admin, a person's own key still reads.
  await owner.call('PUT', '/api/admin/settings', { mcfly_daily_limit: 0 });
  ownScript = [json(message([ROW]))];
  assert.equal((await carol.read(ids.carolDoc)).status, 200);
  assert.deepEqual((await bob.call('GET', '/api/labs/reader')).json, { source: null, reason: 'off', limit: 0, usedToday: 0 });
  assert.equal((await bob.read(ids.first)).status, 403);
  await owner.call('PUT', '/api/admin/settings', { mcfly_daily_limit: 50 });

  // A key the provider refuses: given back, and Profile is told.
  const mid = await usage(ids.carol);
  ownScript = [json({ type: 'error', error: { type: 'authentication_error', message: 'invalid x-api-key' } }, 401)];
  const refused = await carol.read(ids.carolDoc);
  assert.equal(refused.status, 502);
  assert.match(refused.json.error, /Your Claude key isn't working/);
  assert.equal((await usage(ids.carol)).own, mid.own);
  const [key] = await db.query<{ last_error: string | null }>("SELECT last_error FROM ai_keys WHERE user_id = $1 AND provider = 'anthropic'", [ids.carol]);
  assert.equal(key.last_error, 'auth');
  await carol.call('DELETE', '/api/ai/keys/anthropic');
});

test('the export lists a report by name and size, never its bytes', async () => {
  const r = await bob.call('GET', '/api/me/export');
  assert.equal(r.status, 200);
  assert.ok(r.text.includes('Quest results — Oct.pdf'));
  assert.ok(!r.text.includes('bob-first-secret'));
});

test('deleting a report removes it, and only it', async () => {
  const before = (await bob.call('GET', '/api/version')).json.version;
  const r = await bob.call('DELETE', `/api/labs/documents/${ids.photo}`);
  assert.deepEqual([r.status, r.json], [200, { deleted: 1 }]);
  assert.notEqual((await bob.call('GET', '/api/version')).json.version, before);
  assert.equal((await bob.call('GET', `/api/labs/documents/${ids.photo}`)).status, 404);
  assert.equal((await bob.call('DELETE', `/api/labs/documents/${ids.photo}`)).status, 404);
  assert.equal((await bob.read(ids.photo)).status, 404);
  assert.deepEqual(
    (await bob.documents()).json.documents.map((d: { id: string }) => d.id),
    [ids.first],
  );
  assert.equal((await carol.documents()).json.documents.length, 1, "Carol's copy of the same bytes stays");
  // Deleted, the same file can be kept again.
  assert.equal((await bob.upload('image/jpeg', jpeg(), 'again.jpg')).status, 200);
});

test('there is room for 200 reports each', async () => {
  const [{ n }] = await db.query<{ n: number }>('SELECT COUNT(*)::int AS n FROM lab_documents WHERE user_id = $1', [ids.carol]);
  for (let i = n; i < 200; i++) {
    await db.query("INSERT INTO lab_documents (user_id, id, name, mime, size, sha256, data, created_at) VALUES ($1, $2, 'r.pdf', 'application/pdf', 1, $3, $4, $5)", [
      ids.carol,
      `filler-${i}`,
      `sha-${i}`,
      Buffer.from('%PDF-'),
      i,
    ]);
  }
  const full = await carol.upload('image/png', png(42), 'one more.png');
  assert.equal(full.status, 409);
  assert.match(full.json.error, /200 reports/);
  assert.equal((await bob.upload('image/png', png(42), 'one more.png')).status, 200, "Bob's room is his own");
});

test('nothing about a report is logged when an upload fails', async () => {
  const logged: string[] = [];
  const original = console.error;
  console.error = (...args: unknown[]) => void logged.push(args.map(String).join(' '));
  try {
    await db.query('ALTER TABLE lab_documents RENAME TO lab_documents_away');
    const r = await bob.upload('application/pdf', pdf('fails'), 'HIV results.pdf');
    assert.equal(r.status, 500);
  } finally {
    await db.query('ALTER TABLE lab_documents_away RENAME TO lab_documents');
    console.error = original;
  }
  assert.ok(logged.length >= 1);
  assert.ok(logged.every((l) => !l.includes('HIV')));
});
