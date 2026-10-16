// Prints an scrypt hash of the password in $HEALTHOS_PW (used by scripts/setup-vercel.sh).
// The same format server/auth.ts verifies: scrypt$N$r$p$salt$hash.
import { randomBytes, scryptSync } from 'node:crypto';

const pw = process.env.HEALTHOS_PW;
if (!pw || pw.length < 10) {
  console.error('Use a password of at least 10 characters.');
  process.exit(1);
}
const N = 2 ** 15, r = 8, p = 1;
const salt = randomBytes(16);
const hash = scryptSync(pw, salt, 32, { N, r, p, maxmem: 64 * 1024 * 1024 });
process.stdout.write(['scrypt', N, r, p, salt.toString('base64'), hash.toString('base64')].join('$'));
