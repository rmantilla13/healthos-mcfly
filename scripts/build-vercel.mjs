// Builds .vercel/output (Vercel's Build Output API) for `vercel deploy --prebuilt`:
// the Vite dashboard as static files, and the Express API bundled by esbuild into one function.
// Bundling ourselves keeps the server's `.ts` import style and leaves out local-only code
// (PGlite, the Vite dev server, the macOS photo tool).
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { build } from 'esbuild';

const root = path.resolve(import.meta.dirname, '..');
const out = path.join(root, '.vercel', 'output');
const fn = path.join(out, 'functions', 'api.func');

fs.rmSync(out, { recursive: true, force: true });
execFileSync('npx', ['vite', 'build'], { cwd: root, stdio: 'inherit' });
fs.cpSync(path.join(root, 'dist'), path.join(out, 'static'), { recursive: true });

await build({
  entryPoints: [path.join(root, 'server', 'vercel.ts')],
  outfile: path.join(fn, 'index.mjs'),
  bundle: true,
  platform: 'node',
  format: 'esm',
  target: 'node22',
  // Only reached locally (no DATABASE_URL / dev server), never in the deployed function.
  external: ['@electric-sql/pglite', 'vite', '@vitejs/plugin-react', 'fsevents'],
  // Some dependencies are CommonJS and call require(); give the ESM bundle one.
  banner: { js: "import { createRequire as __createRequire } from 'node:module'; const require = __createRequire(import.meta.url);" },
  define: { 'process.env.HEALTHOS_BUILD': '"vercel"' },
  logLevel: 'warning',
});

fs.writeFileSync(
  path.join(fn, '.vc-config.json'),
  JSON.stringify({ runtime: 'nodejs22.x', handler: 'index.mjs', launcherType: 'Nodejs', shouldAddHelpers: false, maxDuration: 300 }, null, 2),
);

const securityHeaders = {
  'x-content-type-options': 'nosniff',
  'x-frame-options': 'DENY',
  'referrer-policy': 'same-origin',
  'strict-transport-security': 'max-age=63072000; includeSubDomains',
};

fs.writeFileSync(
  path.join(out, 'config.json'),
  JSON.stringify(
    {
      version: 3,
      routes: [
        { src: '/(.*)', headers: securityHeaders, continue: true },
        { src: '^/assets/(.*)$', headers: { 'cache-control': 'public, max-age=31536000, immutable' }, continue: true },
        { src: '^/api(/.*)?$', dest: '/api' },
        { handle: 'filesystem' },
        // Public, data-free pages (the WHOOP developer app needs a privacy policy URL).
        { src: '^/privacy/?$', dest: '/privacy.html' },
        { src: '/(.*)', dest: '/index.html' },
      ],
      // WHOOP sync every 6 hours (also keeps the rotating refresh token fresh).
      crons: [{ path: '/api/cron/whoop', schedule: '15 */6 * * *' }],
    },
    null,
    2,
  ),
);

const size = fs.statSync(path.join(fn, 'index.mjs')).size;
console.log(`Built .vercel/output (API bundle ${(size / 1024).toFixed(0)} KB). Deploy with: vercel deploy --prebuilt --prod`);
