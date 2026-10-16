import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import path from 'node:path';
import { hashPassword, verifyPassword } from '../server/auth.ts';

test('the setup script hash verifies on the server, and only for the right password', async () => {
  const script = path.join(import.meta.dirname, '..', 'scripts', 'hash-password.mjs');
  const hash = execFileSync('node', [script], { env: { ...process.env, HEALTHOS_PW: 'correct horse battery' } }).toString();
  assert.match(hash, /^scrypt\$32768\$8\$1\$/);
  assert.equal(await verifyPassword('correct horse battery', hash), true);
  assert.equal(await verifyPassword('correct horse batterz', hash), false);
  assert.equal(await verifyPassword('', hash), false);
  assert.equal(await verifyPassword('correct horse battery', 'garbage'), false);
});

test('hashPassword output verifies', async () => {
  const hash = await hashPassword('another long password');
  assert.equal(await verifyPassword('another long password', hash), true);
});

test('the setup script rejects short passwords', () => {
  const script = path.join(import.meta.dirname, '..', 'scripts', 'hash-password.mjs');
  assert.throws(() => execFileSync('node', [script], { env: { ...process.env, HEALTHOS_PW: 'short' }, stdio: 'pipe' }));
});
